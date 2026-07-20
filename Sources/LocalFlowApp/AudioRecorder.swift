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
final class AudioRecorder {
    private let capture = MicrophoneAudioCapture()
    private var recordingURL: URL?
    private var startedAt: Date?

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
            recordingURL = url
            startedAt = Date()
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
        }

        try capture.stop()
        return RecordingResult(
            fileURL: recordingURL,
            durationSeconds: max(0, Date().timeIntervalSince(startedAt))
        )
    }

    func currentVisualizationFrame() -> AudioVisualizationFrame {
        guard isRecording else {
            return .silent
        }
        return capture.currentFrame()
    }
}
