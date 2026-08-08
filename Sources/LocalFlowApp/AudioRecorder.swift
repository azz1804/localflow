import Accelerate
import AudioToolbox
import AVFoundation
import Foundation

struct RecordingResult {
    var fileURL: URL
    var durationSeconds: TimeInterval
    var wasDurationLimited = false
}

enum AudioRecorderError: Error, LocalizedError {
    case microphoneDenied
    case alreadyRecording
    case notRecording
    case couldNotStart
    case recordingUnavailable
    case recordingSilent

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone permission is not granted."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "No recording is in progress."
        case .couldNotStart:
            return "The audio recorder could not start."
        case .recordingUnavailable:
            return "The recording could not be finalized."
        case .recordingSilent:
            return "The microphone is returning silence. Check the selected input device or reconnect your headset, then try again."
        }
    }
}

enum AudioRecorderStopMode: Equatable {
    case finalize
    case discard
}

enum AudioRecordingValidator {
    enum Result: Equatable {
        case usable
        case missingOrUnreadable
        case noFrames
        case digitalSilence
    }

    /// Below -120 dBFS, samples are indistinguishable from digital silence for
    /// this voice capture pipeline. This catches all-zero buffers returned by a
    /// broken CoreAudio route without rejecting genuinely quiet speech.
    static let digitalSilenceThreshold: Float = 0.000_001

    static func hasReadableFrames(at url: URL) -> Bool {
        switch validate(at: url) {
        case .usable, .digitalSilence:
            return true
        case .missingOrUnreadable, .noFrames:
            return false
        }
    }

    static func hasUsableSignal(at url: URL) -> Bool {
        validate(at: url) == .usable
    }

    static func validate(at url: URL) -> Result {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else {
            return .missingOrUnreadable
        }
        guard file.length > 0 else {
            return .noFrames
        }

        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 4_096
              ) else {
            return .missingOrUnreadable
        }

        do {
            while file.framePosition < file.length {
                let remaining = file.length - file.framePosition
                let requestedFrames = AVAudioFrameCount(
                    min(AVAudioFramePosition(buffer.frameCapacity), remaining)
                )
                try file.read(into: buffer, frameCount: requestedFrames)
                guard buffer.frameLength > 0 else {
                    break
                }

                let audioBuffers = UnsafeMutableAudioBufferListPointer(
                    buffer.mutableAudioBufferList
                )
                for audioBuffer in audioBuffers {
                    guard let data = audioBuffer.mData else {
                        continue
                    }
                    let sampleCount = Int(audioBuffer.mDataByteSize)
                        / MemoryLayout<Float>.size
                    guard sampleCount > 0 else {
                        continue
                    }
                    var peak: Float = 0
                    vDSP_maxmgv(
                        data.assumingMemoryBound(to: Float.self),
                        1,
                        &peak,
                        vDSP_Length(sampleCount)
                    )
                    if peak.isFinite, peak > digitalSilenceThreshold {
                        return .usable
                    }
                }
            }
        } catch {
            return .missingOrUnreadable
        }
        return .digitalSilence
    }
}

@MainActor
final class AudioRecorder {
    private let capture = MicrophoneAudioCapture()
    private var recordingURL: URL?
    private var startedAt: Date?
    private var durationLimitTask: Task<Void, Never>?
    private var captureStoppedAtDurationLimit = false

    static let maximumRecordingDuration: TimeInterval = 10 * 60

    var isRecording: Bool {
        recordingURL != nil
    }

    func start(
        preferBuiltInMicrophoneForBluetooth: Bool = true
    ) async throws {
        guard !isRecording else {
            throw AudioRecorderError.alreadyRecording
        }

        let granted = await PermissionManager.requestMicrophoneAccess()
        guard granted else {
            throw AudioRecorderError.microphoneDenied
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        do {
            let route: AudioInputRoutePreparation?
            do {
                route = try await AudioInputRouteManager
                    .preparePreferredInput(
                        preferBuiltInForBluetooth:
                            preferBuiltInMicrophoneForBluetooth
                    )
            } catch {
                // Route protection is best-effort: a transient CoreAudio
                // enumeration failure must not prevent dictation entirely.
                // The fresh capture graph below can still use the active mic.
                LocalFlowLogger.log(
                    "Audio route preparation unavailable error=\(error.localizedDescription); continuing with active input"
                )
                route = nil
            }
            try await startCaptureWithRouteRecovery(
                recordingURL: url,
                route: route
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            recordingURL = url
            startedAt = Date()
            captureStoppedAtDurationLimit = false
            scheduleDurationLimit()
        } catch {
            try? capture.stop()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func startCaptureWithRouteRecovery(
        recordingURL: URL,
        route: AudioInputRoutePreparation?
    ) async throws {
        do {
            try capture.start(recordingURL: recordingURL)
        } catch {
            let errorCode = (error as NSError).code
            guard route?.didSwitchDevice == true
                    || errorCode == Int(kAudioUnitErr_FormatNotSupported) else {
                throw error
            }

            LocalFlowLogger.log(
                "Audio capture retry after route transition code=\(errorCode) selected=\(route?.selectedDevice.name ?? "active-input")"
            )
            try? capture.stop()
            try await Task.sleep(for: .milliseconds(180))
            try capture.start(recordingURL: recordingURL)
        }
    }

    func stop(mode: AudioRecorderStopMode = .finalize) throws -> RecordingResult {
        guard let recordingURL, let startedAt else {
            throw AudioRecorderError.notRecording
        }

        defer {
            self.recordingURL = nil
            self.startedAt = nil
            self.captureStoppedAtDurationLimit = false
        }

        durationLimitTask?.cancel()
        durationLimitTask = nil
        var finalizationError: Error?
        if !captureStoppedAtDurationLimit {
            do {
                try capture.stop()
            } catch {
                finalizationError = error
            }
        }
        let duration = min(
            Self.maximumRecordingDuration,
            max(0, Date().timeIntervalSince(startedAt))
        )
        let result = RecordingResult(
            fileURL: recordingURL,
            durationSeconds: duration,
            wasDurationLimited: captureStoppedAtDurationLimit
        )

        // Explicit cancellation still has to tear down CoreAudio, but it must
        // never turn a short or silent recording into a user-facing error.
        // The caller owns removal of the temporary URL, whether or not the
        // lazy capture sink had time to create a file there.
        if mode == .discard {
            if let finalizationError {
                LocalFlowLogger.log(
                    "Recording discard finalized with error=\(finalizationError.localizedDescription)"
                )
            }
            return result
        }

        if let finalizationError {
            let byteCount = Self.byteCount(of: recordingURL)
            // AVAudioFile write failures can happen after a valid prefix was
            // flushed. Preserve and process that recoverable audio rather than
            // orphaning it because the final buffer failed.
            LocalFlowLogger.log(
                "Recording finalized with recoverable error bytes=\(byteCount) error=\(finalizationError.localizedDescription)"
            )
        }

        // A WAV container can be several kilobytes while containing zero audio
        // packets. Validate decoded frames instead of trusting file size.
        let validation = AudioRecordingValidator.validate(at: recordingURL)
        guard validation == .usable else {
            LocalFlowLogger.log(
                "Recording rejected validation=\(String(describing: validation))"
            )
            try? FileManager.default.removeItem(at: recordingURL)
            if validation == .digitalSilence {
                throw AudioRecorderError.recordingSilent
            }
            throw AudioRecorderError.recordingUnavailable
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: recordingURL.path
        )
        return result
    }

    func currentVisualizationFrame() -> AudioVisualizationFrame {
        guard isRecording, !captureStoppedAtDurationLimit else {
            return .silent
        }
        return capture.currentFrame()
    }

    private func scheduleDurationLimit() {
        durationLimitTask?.cancel()
        durationLimitTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        Self.maximumRecordingDuration * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            guard let self, self.isRecording else {
                return
            }
            do {
                try self.capture.stop()
                self.captureStoppedAtDurationLimit = true
                LocalFlowLogger.log(
                    "Recording reached duration limit seconds=\(Int(Self.maximumRecordingDuration))"
                )
            } catch {
                // stop() still tears down the engine before reporting a writer
                // failure. Keep the file recoverable for the normal stop path.
                self.captureStoppedAtDurationLimit = true
                LocalFlowLogger.log(
                    "Recording duration-limit finalization error=\(error.localizedDescription)"
                )
            }
        }
    }

    private static func byteCount(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

}
