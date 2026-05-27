import AVFoundation
import Foundation

struct RecordingResult {
    var fileURL: URL
    var durationSeconds: TimeInterval
}

enum AudioRecorderError: Error, LocalizedError {
    case microphoneDenied
    case alreadyRecording
    case notRecording
    case couldNotStart

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
        }
    }
}

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var startedAt: Date?

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func start() async throws {
        guard recorder == nil else {
            throw AudioRecorderError.alreadyRecording
        }

        let granted = await PermissionManager.requestMicrophoneAccess()
        guard granted else {
            throw AudioRecorderError.microphoneDenied
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        audioRecorder.delegate = self
        audioRecorder.isMeteringEnabled = true
        audioRecorder.prepareToRecord()

        guard audioRecorder.record() else {
            throw AudioRecorderError.couldNotStart
        }

        recorder = audioRecorder
        recordingURL = url
        startedAt = Date()
    }

    func stop() throws -> RecordingResult {
        guard let recorder, let recordingURL, let startedAt else {
            throw AudioRecorderError.notRecording
        }

        recorder.stop()
        self.recorder = nil
        self.recordingURL = nil
        self.startedAt = nil

        return RecordingResult(
            fileURL: recordingURL,
            durationSeconds: max(0, Date().timeIntervalSince(startedAt))
        )
    }

    func currentPowerLevel() -> Float {
        guard let recorder, recorder.isRecording else {
            return 0
        }

        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalized = max(0, min(1, (power + 55) / 55))
        return normalized
    }
}
