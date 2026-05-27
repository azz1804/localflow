import Foundation
import LocalFlowCore

@MainActor
final class DictationController {
    var onStatusChanged: ((AppStatus, Float) -> Void)?
    var isPolishEnabled: Bool {
        get { configuration.enablePolish }
        set { configuration.enablePolish = newValue }
    }

    private var configuration: AppConfiguration
    private var dictionary: PersonalDictionary
    private var openAIClient: OpenAIClient?
    private let historyStore: HistoryStore
    private let audioRecorder: AudioRecorder
    private let insertionService: TextInsertionService
    private let activeApplicationProvider: ActiveApplicationProvider

    private var status: AppStatus = .idle
    private var recordingTargetApplication: TargetApplicationInfo?
    private var recordingStartedAt: Date?
    private var recordingTask: Task<Void, Never>?
    private var isStarting = false
    private var isProcessing = false
    private var shouldStopWhenStarted = false
    private var recordingMode: RecordingMode = .hold

    init(
        configuration: AppConfiguration,
        dictionary: PersonalDictionary,
        historyStore: HistoryStore,
        audioRecorder: AudioRecorder = AudioRecorder(),
        insertionService: TextInsertionService = TextInsertionService(),
        activeApplicationProvider: ActiveApplicationProvider = ActiveApplicationProvider()
    ) {
        self.configuration = configuration
        self.dictionary = dictionary
        self.historyStore = historyStore
        self.audioRecorder = audioRecorder
        self.insertionService = insertionService
        self.activeApplicationProvider = activeApplicationProvider

        self.openAIClient = Self.makeOpenAIClient(configuration: configuration)
    }

    func updateConfiguration(_ configuration: AppConfiguration, dictionary: PersonalDictionary) {
        self.configuration = configuration
        self.dictionary = dictionary
        self.openAIClient = Self.makeOpenAIClient(configuration: configuration)
    }

    private static func makeOpenAIClient(configuration: AppConfiguration) -> OpenAIClient? {
        guard let apiKey = configuration.openAIAPIKey, configuration.isOpenAIConfigured else {
            return nil
        }

        return OpenAIClient(apiKey: apiKey)
    }

    func beginHoldRecording() {
        Task { await startRecording(mode: .hold) }
    }

    func endHoldRecording() {
        guard recordingMode == .hold else {
            return
        }

        if isStarting {
            shouldStopWhenStarted = true
            LocalFlowLogger.log("Recording stop queued while recorder is starting")
            return
        }

        Task { await stopAndProcessRecording() }
    }

    func toggleRecording() {
        if isStarting {
            shouldStopWhenStarted = true
            LocalFlowLogger.log("Recording toggle stop queued while recorder is starting")
            return
        }

        switch status {
        case .recording:
            Task { await stopAndProcessRecording() }
        case .idle, .done, .error:
            Task { await startRecording(mode: .toggle) }
        case .processing:
            break
        }
    }

    func lockCurrentHoldRecording() {
        guard audioRecorder.isRecording, recordingMode == .hold else {
            return
        }

        recordingMode = .toggle
        LocalFlowLogger.log("Recording locked into toggle mode")
        refreshRecordingStatus()
    }

    func startManualRecording() {
        Task { await startRecording(mode: .toggle) }
    }

    func stopManualRecording() {
        if isStarting {
            shouldStopWhenStarted = true
            LocalFlowLogger.log("Manual stop queued while recorder is starting")
            return
        }

        Task { await stopAndProcessRecording() }
    }

    private func startRecording(mode: RecordingMode) async {
        guard !isStarting, !isProcessing, !audioRecorder.isRecording else {
            return
        }

        guard openAIClient != nil else {
            LocalFlowLogger.log("Recording start failed missing OpenAI key")
            setStatus(.error("Missing OPENAI_API_KEY in .env"), level: 0)
            return
        }

        isStarting = true
        shouldStopWhenStarted = false
        recordingMode = mode
        setStatus(.recording(0, recordingMode), level: 0.1)

        do {
            recordingTargetApplication = activeApplicationProvider.currentApplication()
            LocalFlowLogger.log("Recording start target=\(recordingTargetApplication?.bundleIdentifier ?? "-")")
            try await audioRecorder.start()
            recordingStartedAt = Date()
            isStarting = false
            LocalFlowLogger.log("Recording started")

            if shouldStopWhenStarted {
                shouldStopWhenStarted = false
                LocalFlowLogger.log("Recording stopping immediately after delayed start")
                await stopAndProcessRecording()
                return
            }

            setStatus(.recording(0, recordingMode), level: 0.1)
            startRecordingStatusLoop()
        } catch {
            isStarting = false
            shouldStopWhenStarted = false
            LocalFlowLogger.log("Recording start failed error=\(error.localizedDescription)")
            setStatus(.error(error.localizedDescription), level: 0)
        }
    }

    private func stopAndProcessRecording() async {
        guard audioRecorder.isRecording else {
            return
        }

        recordingTask?.cancel()
        recordingTask = nil

        let result: RecordingResult

        do {
            result = try audioRecorder.stop()
            LocalFlowLogger.log("Recording stopped duration=\(String(format: "%.2f", result.durationSeconds))")
        } catch {
            LocalFlowLogger.log("Recording stop failed error=\(error.localizedDescription)")
            setStatus(.error(error.localizedDescription), level: 0)
            return
        }

        guard result.durationSeconds >= 0.25 else {
            removeTemporaryFile(result.fileURL)
            LocalFlowLogger.log("Recording discarded tooShort duration=\(String(format: "%.2f", result.durationSeconds))")
            setStatus(.error("Recording was too short."), level: 0)
            return
        }

        await processRecording(result)
    }

    private func processRecording(_ result: RecordingResult) async {
        guard let openAIClient else {
            setStatus(.error("Missing OPENAI_API_KEY in .env"), level: 0)
            return
        }

        isProcessing = true
        setStatus(.processing, level: 0)
        LocalFlowLogger.log("Processing started duration=\(String(format: "%.2f", result.durationSeconds))")

        let targetApplication = recordingTargetApplication
        let transcriptionPrompt = PromptBuilder.transcriptionPrompt(
            dictionary: dictionary,
            targetApplication: targetApplication,
            language: configuration.transcriptionLanguage
        )

        do {
            let transcribedText = try await openAIClient.transcribeAudio(
                fileURL: result.fileURL,
                model: configuration.transcriptionModel,
                language: configuration.transcriptionLanguage,
                prompt: transcriptionPrompt
            )
            LocalFlowLogger.log("Transcription finished chars=\(transcribedText.count)")

            var finalText = ReplacementEngine.apply(dictionary.replacements, to: transcribedText)
            var polished = false

            if configuration.enablePolish {
                finalText = try await openAIClient.polish(
                    text: finalText,
                    model: configuration.polishModel,
                    systemPrompt: PromptBuilder.polishSystemPrompt(targetApplication: targetApplication),
                    userPrompt: PromptBuilder.polishUserPrompt(text: finalText)
                )
                polished = true
            }

            try historyStore.append(
                DictationRecord(
                    targetApplication: targetApplication,
                    transcribedText: transcribedText,
                    finalText: finalText,
                    polished: polished,
                    durationSeconds: result.durationSeconds
                )
            )

            try await insertionService.paste(
                text: finalText,
                restoreClipboard: configuration.restoreClipboardAfterPaste,
                restoreDelayMilliseconds: configuration.pasteRestoreDelayMilliseconds
            )
            LocalFlowLogger.log("Paste finished chars=\(finalText.count)")

            setStatus(.done(finalText), level: 0)
        } catch {
            LocalFlowLogger.log("Processing failed error=\(error.localizedDescription)")
            setStatus(.error(error.localizedDescription), level: 0)
        }

        isProcessing = false
        recordingTargetApplication = nil
        recordingStartedAt = nil
        recordingMode = .hold
        removeTemporaryFile(result.fileURL)
    }

    private func startRecordingStatusLoop() {
        recordingTask?.cancel()
        recordingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                await MainActor.run {
                    self?.refreshRecordingStatus()
                }
            }
        }
    }

    private func refreshRecordingStatus() {
        guard audioRecorder.isRecording, let recordingStartedAt else {
            return
        }

        let duration = Date().timeIntervalSince(recordingStartedAt)
        setStatus(.recording(duration, recordingMode), level: audioRecorder.currentPowerLevel())
    }

    private func setStatus(_ status: AppStatus, level: Float) {
        self.status = status
        onStatusChanged?(status, level)
    }

    private func removeTemporaryFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
