import Foundation
import LocalFlowCore

@MainActor
final class DictationController {
    var onStatusChanged: ((AppStatus, AudioVisualizationFrame) -> Void)?
    var onRecordingFrame: ((AppStatus, AudioVisualizationFrame) -> Void)?
    var onHistoryRecordCreated: ((DictationRecord) -> Void)?
    var onInsertionCompleted: ((TextInsertionOutcome) -> Void)?
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
    private var recordingInsertionTarget: TextInsertionTarget?
    private var recordingStartedAt: Date?
    private var recordingFrameDriver: RecordingFrameDriver?
    private var isStarting = false
    private var isProcessing = false
    private var shouldStopWhenStarted = false
    private var shouldCancelWhenStarted = false
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

    func cancelRecording() {
        if isStarting {
            shouldCancelWhenStarted = true
            shouldStopWhenStarted = false
            LocalFlowLogger.log("Recording cancel queued while recorder is starting")
            return
        }

        cancelActiveRecording()
    }

    func lockCurrentHoldRecording() {
        guard recordingMode == .hold else {
            return
        }

        if isStarting {
            recordingMode = .toggle
            LocalFlowLogger.log(
                "Recording lock queued while recorder is starting"
            )
            setStatus(.recording(0, .toggle))
            return
        }

        guard audioRecorder.isRecording else {
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
            setStatus(.error("Missing OPENAI_API_KEY in .env"))
            return
        }

        isStarting = true
        shouldStopWhenStarted = false
        shouldCancelWhenStarted = false
        recordingMode = mode
        setStatus(.recording(0, recordingMode))

        do {
            recordingTargetApplication = activeApplicationProvider.currentApplication()
            recordingInsertionTarget = insertionService.captureTarget()
            LocalFlowLogger.log("Recording start target=\(recordingTargetApplication?.bundleIdentifier ?? "-")")
            try await audioRecorder.start()
            recordingStartedAt = Date()
            isStarting = false
            LocalFlowLogger.log("Recording started")

            if shouldCancelWhenStarted {
                shouldCancelWhenStarted = false
                LocalFlowLogger.log("Recording cancelling immediately after delayed start")
                cancelActiveRecording()
                return
            }

            if shouldStopWhenStarted {
                shouldStopWhenStarted = false
                LocalFlowLogger.log("Recording stopping immediately after delayed start")
                await stopAndProcessRecording()
                return
            }

            setStatus(.recording(0, recordingMode))
            startRecordingStatusLoop()
        } catch {
            isStarting = false
            shouldStopWhenStarted = false
            shouldCancelWhenStarted = false
            recordingTargetApplication = nil
            recordingInsertionTarget = nil
            LocalFlowLogger.log("Recording start failed error=\(error.localizedDescription)")
            setStatus(.error(error.localizedDescription))
        }
    }

    private func cancelActiveRecording() {
        recordingFrameDriver?.stop()
        recordingFrameDriver = nil

        guard audioRecorder.isRecording else {
            resetRecordingState()
            setStatus(.idle)
            return
        }

        do {
            let result = try audioRecorder.stop()
            removeTemporaryFile(result.fileURL)
            LocalFlowLogger.log(
                "Recording cancelled duration=\(String(format: "%.2f", result.durationSeconds))"
            )
            resetRecordingState()
            setStatus(.idle)
        } catch {
            resetRecordingState()
            LocalFlowLogger.log(
                "Recording cancel failed error=\(error.localizedDescription)"
            )
            setStatus(.error(error.localizedDescription))
        }
    }

    private func stopAndProcessRecording() async {
        guard audioRecorder.isRecording else {
            return
        }

        recordingFrameDriver?.stop()
        recordingFrameDriver = nil

        let result: RecordingResult

        do {
            result = try audioRecorder.stop()
            LocalFlowLogger.log("Recording stopped duration=\(String(format: "%.2f", result.durationSeconds))")
        } catch {
            recordingTargetApplication = nil
            recordingInsertionTarget = nil
            recordingStartedAt = nil
            recordingMode = .hold
            LocalFlowLogger.log("Recording stop failed error=\(error.localizedDescription)")
            setStatus(.error(error.localizedDescription))
            return
        }

        guard result.durationSeconds >= 0.25 else {
            removeTemporaryFile(result.fileURL)
            recordingTargetApplication = nil
            recordingInsertionTarget = nil
            recordingStartedAt = nil
            recordingMode = .hold
            LocalFlowLogger.log("Recording discarded tooShort duration=\(String(format: "%.2f", result.durationSeconds))")
            setStatus(.error("Recording was too short."))
            return
        }

        await processRecording(result)
    }

    private func processRecording(_ result: RecordingResult) async {
        isProcessing = true
        defer {
            isProcessing = false
            recordingTargetApplication = nil
            recordingInsertionTarget = nil
            recordingStartedAt = nil
            recordingMode = .hold
            removeTemporaryFile(result.fileURL)
        }

        guard let openAIClient else {
            setStatus(.error("Missing OPENAI_API_KEY in .env"))
            return
        }

        setStatus(.processing)
        LocalFlowLogger.log("Processing started duration=\(String(format: "%.2f", result.durationSeconds))")

        let targetApplication = recordingTargetApplication
        let transcriptionPrompt = PromptBuilder.transcriptionPrompt(
            dictionary: dictionary,
            targetApplication: targetApplication,
            language: configuration.transcriptionLanguage
        )

        do {
            let optimizedUpload = await AudioUploadOptimizer.prepare(
                result.fileURL
            )
            defer {
                if optimizedUpload.fileURL.standardizedFileURL
                    != result.fileURL.standardizedFileURL {
                    removeTemporaryFile(optimizedUpload.fileURL)
                }
            }
            LocalFlowLogger.log(
                "Audio upload prepared originalBytes=\(optimizedUpload.originalByteCount) uploadBytes=\(optimizedUpload.uploadByteCount) durationMs=\(Int((optimizedUpload.preparationDuration * 1_000).rounded()))"
            )

            let inferenceStartedAt = ProcessInfo.processInfo.systemUptime
            let transcribedText = try await openAIClient.transcribeAudio(
                fileURL: optimizedUpload.fileURL,
                model: configuration.transcriptionModel,
                language: configuration.transcriptionLanguage,
                prompt: transcriptionPrompt
            )
            let inferenceDuration = ProcessInfo.processInfo.systemUptime
                - inferenceStartedAt
            LocalFlowLogger.log(
                "Transcription finished chars=\(transcribedText.count) durationMs=\(Int((inferenceDuration * 1_000).rounded())) model=\(configuration.transcriptionModel)"
            )

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

            let record = DictationRecord(
                targetApplication: targetApplication,
                transcribedText: transcribedText,
                finalText: finalText,
                polished: polished,
                durationSeconds: result.durationSeconds
            )
            try historyStore.append(record)
            onHistoryRecordCreated?(record)
            LocalFlowLogger.log("History appended id=\(record.id)")

            let insertionOutcome = try await insertionService.paste(
                text: finalText,
                restoreClipboard: configuration.restoreClipboardAfterPaste,
                restoreDelayMilliseconds: configuration.pasteRestoreDelayMilliseconds,
                target: recordingInsertionTarget
            )
            onInsertionCompleted?(insertionOutcome)
            switch insertionOutcome {
            case .pasted:
                LocalFlowLogger.log("Paste finished chars=\(finalText.count)")
            case .copiedToClipboard:
                LocalFlowLogger.log(
                    "No editable target; transcript kept on clipboard chars=\(finalText.count)"
                )
            }

            setStatus(.done(finalText, insertionOutcome))
        } catch {
            LocalFlowLogger.log("Processing failed error=\(error.localizedDescription)")
            setStatus(.error(error.localizedDescription))
        }
    }

    private func startRecordingStatusLoop() {
        recordingFrameDriver?.stop()
        let driver = RecordingFrameDriver { [weak self] in
            self?.refreshRecordingStatus()
        }
        recordingFrameDriver = driver
        driver.start()
    }

    private func refreshRecordingStatus() {
        guard audioRecorder.isRecording, let recordingStartedAt else {
            return
        }

        let duration = Date().timeIntervalSince(recordingStartedAt)
        let recordingStatus = AppStatus.recording(duration, recordingMode)
        status = recordingStatus
        onRecordingFrame?(
            recordingStatus,
            audioRecorder.currentVisualizationFrame()
        )
    }

    private func setStatus(
        _ status: AppStatus,
        visualization: AudioVisualizationFrame = .silent
    ) {
        self.status = status
        onStatusChanged?(status, visualization)
    }

    private func resetRecordingState() {
        shouldStopWhenStarted = false
        shouldCancelWhenStarted = false
        recordingTargetApplication = nil
        recordingInsertionTarget = nil
        recordingStartedAt = nil
        recordingMode = .hold
    }

    private func removeTemporaryFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
