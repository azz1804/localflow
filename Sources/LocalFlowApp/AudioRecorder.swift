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
        }
    }
}

enum AudioRecordingValidator {
    static func hasReadableFrames(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else {
            return false
        }
        return file.length > 0
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

    func start() async throws {
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
            try capture.start(recordingURL: url)
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

    func stop() throws -> RecordingResult {
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
        guard AudioRecordingValidator.hasReadableFrames(at: recordingURL) else {
            try? FileManager.default.removeItem(at: recordingURL)
            throw AudioRecorderError.recordingUnavailable
        }
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
