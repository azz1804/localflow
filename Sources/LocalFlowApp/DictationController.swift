import Foundation
import LocalFlowCore

@MainActor
final class DictationController {
    var onStatusChanged: ((AppStatus, AudioVisualizationFrame) -> Void)?
    var onRecordingFrame: ((AppStatus, AudioVisualizationFrame) -> Void)?
    var onHistoryRecordCreated: ((DictationRecord) -> Void)?
    var onInsertionCompleted: ((TextInsertionOutcome) -> Void)?
    var onSetupRequired: ((String) -> Void)?

    var canCancelRecording: Bool {
        pendingRecordingStartTask != nil
            || isStarting
            || audioRecorder.isRecording
            || finalizationTask != nil
            || isFinalizingRecording
            || processingTask != nil
            || isProcessing
    }

    private var configuration: AppConfiguration
    private var dictionary: PersonalDictionary
    private var openAIClient: OpenAIClient?
    private let historyStore: HistoryStore
    private let audioRecorder: AudioRecorder
    private let insertionService: TextInsertionService
    private let activeApplicationProvider: ActiveApplicationProvider
    private let pendingDictationStore: PendingDictationStore

    private var status: AppStatus = .idle
    private var recordingTargetApplication: TargetApplicationInfo?
    private var recordingInsertionTarget: TextInsertionTarget?
    private var recordingStartedAt: Date?
    private var recordingFrameDriver: RecordingFrameDriver?
    private var pendingRecordingStartTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var pendingRecordingMode: RecordingMode?
    private var pendingDoubleClapTargetRestoration = false
    private var activePendingJobID: UUID?
    private var completedForegroundStatus: AppStatus?
    private var finalizationGeneration = UUID()
    private var processingGeneration = UUID()
    private var isStarting = false
    private var isFinalizingRecording = false
    private var isProcessing = false
    private var isRecoveringPendingJobs = false
    private var shouldStopWhenStarted = false
    private var shouldCancelWhenStarted = false
    private var recordingMode: RecordingMode = .hold

    init(
        configuration: AppConfiguration,
        dictionary: PersonalDictionary,
        historyStore: HistoryStore,
        audioRecorder: AudioRecorder = AudioRecorder(),
        insertionService: TextInsertionService = TextInsertionService(),
        activeApplicationProvider: ActiveApplicationProvider = ActiveApplicationProvider(),
        pendingDictationStore: PendingDictationStore = PendingDictationStore()
    ) {
        self.configuration = configuration
        self.dictionary = dictionary
        self.historyStore = historyStore
        self.audioRecorder = audioRecorder
        self.insertionService = insertionService
        self.activeApplicationProvider = activeApplicationProvider
        self.pendingDictationStore = pendingDictationStore
        openAIClient = Self.makeOpenAIClient(configuration: configuration)
    }

    func updateConfiguration(
        _ configuration: AppConfiguration,
        dictionary: PersonalDictionary
    ) {
        self.configuration = configuration
        self.dictionary = dictionary
        openAIClient = Self.makeOpenAIClient(configuration: configuration)
    }

    private static func makeOpenAIClient(
        configuration: AppConfiguration
    ) -> OpenAIClient? {
        guard let apiKey = configuration.openAIAPIKey,
              configuration.isOpenAIConfigured else {
            return nil
        }
        return OpenAIClient(apiKey: apiKey)
    }

    func beginHoldRecording() {
        scheduleRecordingStart(mode: .hold)
    }

    func endHoldRecording() {
        guard recordingMode == .hold else {
            return
        }

        if cancelPendingRecordingStart() {
            LocalFlowLogger.log("Pending hold recording cancelled before start")
            setStatus(.idle)
            return
        }

        if isStarting {
            shouldStopWhenStarted = true
            LocalFlowLogger.log("Recording stop queued while recorder is starting")
            return
        }

        requestRecordingStop()
    }

    func toggleRecording() {
        if cancelPendingRecordingStart() {
            LocalFlowLogger.log("Pending toggle recording cancelled before start")
            setStatus(.idle)
            return
        }

        if isStarting {
            shouldStopWhenStarted = true
            LocalFlowLogger.log("Recording toggle stop queued while recorder is starting")
            return
        }

        switch status {
        case .recording:
            requestRecordingStop()
        case .idle, .done, .error:
            scheduleRecordingStart(mode: .toggle)
        case .processing:
            break
        }
    }

    func toggleRecordingFromDoubleClap() {
        switch status {
        case .idle, .done, .error:
            scheduleRecordingStart(
                mode: .toggle,
                restoresExternalTarget: true
            )
        case .recording:
            requestRecordingStop()
        case .processing:
            break
        }
    }

    func cancelRecording() {
        if finalizationTask != nil || isFinalizingRecording {
            finalizationGeneration = UUID()
            finalizationTask?.cancel()
            LocalFlowLogger.log(
                "Recording finalization cancelled; queued audio will be discarded"
            )
            return
        }

        if processingTask != nil || isProcessing {
            cancelProcessing()
            return
        }

        if cancelPendingRecordingStart() {
            LocalFlowLogger.log("Pending recording cancelled before start")
            setStatus(.idle)
            return
        }

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

        if pendingRecordingStartTask != nil {
            pendingRecordingMode = .toggle
            recordingMode = .toggle
            LocalFlowLogger.log("Recording lock queued before recorder starts")
            setStatus(.recording(0, .toggle))
            return
        }

        if isStarting {
            recordingMode = .toggle
            LocalFlowLogger.log("Recording lock queued while recorder is starting")
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
        scheduleRecordingStart(mode: .toggle)
    }

    func stopManualRecording() {
        if cancelPendingRecordingStart() {
            LocalFlowLogger.log("Pending manual recording cancelled before start")
            setStatus(.idle)
            return
        }

        if isStarting {
            shouldStopWhenStarted = true
            LocalFlowLogger.log("Manual stop queued while recorder is starting")
            return
        }

        requestRecordingStop()
    }

    private func scheduleRecordingStart(
        mode: RecordingMode,
        restoresExternalTarget: Bool = false
    ) {
        interruptPendingRecoveryForRecording()
        guard pendingRecordingStartTask == nil,
              !isStarting,
              finalizationTask == nil,
              !isFinalizingRecording,
              !isProcessing,
              !audioRecorder.isRecording else {
            return
        }

        pendingRecordingMode = mode
        pendingDoubleClapTargetRestoration = restoresExternalTarget
        pendingRecordingStartTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else {
                return
            }
            let requestedMode = self.pendingRecordingMode ?? mode
            let shouldRestoreExternalTarget =
                self.pendingDoubleClapTargetRestoration
            self.pendingRecordingStartTask = nil
            self.pendingRecordingMode = nil
            self.pendingDoubleClapTargetRestoration = false
            await self.startRecording(
                mode: requestedMode,
                restoresExternalTarget: shouldRestoreExternalTarget
            )
        }
    }

    @discardableResult
    private func cancelPendingRecordingStart() -> Bool {
        guard let pendingRecordingStartTask else {
            return false
        }
        pendingRecordingStartTask.cancel()
        self.pendingRecordingStartTask = nil
        pendingRecordingMode = nil
        pendingDoubleClapTargetRestoration = false
        recordingMode = .hold
        return true
    }

    private func startRecording(
        mode: RecordingMode,
        restoresExternalTarget: Bool
    ) async {
        guard !isStarting,
              finalizationTask == nil,
              !isFinalizingRecording,
              !isProcessing,
              !audioRecorder.isRecording else {
            return
        }

        guard openAIClient != nil else {
            LocalFlowLogger.log("Recording start failed missing OpenAI key")
            let message = "Add a valid OpenAI API key in LocalFlow Settings."
            setStatus(.error(message))
            onSetupRequired?(message)
            return
        }

        isStarting = true
        shouldStopWhenStarted = false
        shouldCancelWhenStarted = false
        recordingMode = mode
        setStatus(.recording(0, recordingMode))

        do {
            if restoresExternalTarget {
                await activeApplicationProvider
                    .restoreExternalTargetForDoubleClap()
            }
            recordingTargetApplication = activeApplicationProvider.currentApplication()
            recordingInsertionTarget = insertionService.captureTarget()
            LocalFlowLogger.log(
                "Recording start target=\(recordingTargetApplication?.bundleIdentifier ?? "-")"
            )
            try await audioRecorder.start(
                preferBuiltInMicrophoneForBluetooth:
                    configuration.preferBuiltInMicrophoneForBluetooth,
                detectsDoubleClap:
                    configuration.enableDoubleClapControl
            )
            recordingStartedAt = Date()
            isStarting = false
            LocalFlowLogger.log("Recording started")

            if shouldCancelWhenStarted {
                shouldCancelWhenStarted = false
                LocalFlowLogger.log(
                    "Recording cancelling immediately after delayed start"
                )
                cancelActiveRecording()
                return
            }

            if shouldStopWhenStarted {
                shouldStopWhenStarted = false
                LocalFlowLogger.log(
                    "Recording stopping immediately after delayed start"
                )
                requestRecordingStop()
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
            LocalFlowLogger.log(
                "Recording start failed error=\(error.localizedDescription)"
            )
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
            let result = try audioRecorder.stop(mode: .discard)
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

    private func requestRecordingStop() {
        guard finalizationTask == nil else {
            return
        }
        finalizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopAndQueueRecording()
            self.finalizationTask = nil
        }
    }

    private func stopAndQueueRecording() async {
        guard audioRecorder.isRecording, !isFinalizingRecording else {
            return
        }

        let generation = UUID()
        finalizationGeneration = generation
        isFinalizingRecording = true
        setStatus(.processing)

        recordingFrameDriver?.stop()
        recordingFrameDriver = nil

        let result: RecordingResult
        do {
            result = try audioRecorder.stop()
            LocalFlowLogger.log(
                "Recording stopped duration=\(String(format: "%.2f", result.durationSeconds))"
            )
        } catch {
            clearFinalizationOwnership()
            recordingTargetApplication = nil
            recordingInsertionTarget = nil
            recordingStartedAt = nil
            recordingMode = .hold
            LocalFlowLogger.log(
                "Recording stop failed error=\(error.localizedDescription)"
            )
            setStatus(.error(error.localizedDescription))
            return
        }

        guard result.durationSeconds >= 0.25 else {
            removeTemporaryFile(result.fileURL)
            clearFinalizationOwnership()
            resetRecordingState()
            LocalFlowLogger.log(
                "Recording discarded tooShort duration=\(String(format: "%.2f", result.durationSeconds))"
            )
            setStatus(.error("Recording was too short."))
            return
        }

        let targetApplication = recordingTargetApplication
        let insertionTarget = recordingInsertionTarget
        let context = makeProcessingContext()
        let parameters = makePendingParameters()

        do {
            let job = try await pendingDictationStore.persistRecording(
                from: result.fileURL,
                durationSeconds: result.durationSeconds,
                targetApplication: targetApplication,
                parameters: parameters
            )
            guard finalizationGeneration == generation,
                  !Task.isCancelled else {
                try? await pendingDictationStore.discard(job)
                clearFinalizationOwnership()
                resetRecordingState()
                setStatus(.idle)
                return
            }
            resetRecordingState()
            clearFinalizationOwnership()
            startProcessing(
                jobs: [job],
                context: context,
                insertionTarget: insertionTarget,
                shouldInsert: true
            )
        } catch {
            let wasCancelled = finalizationGeneration != generation
                || Task.isCancelled
            clearFinalizationOwnership()
            resetRecordingState()
            if wasCancelled {
                removeTemporaryFile(result.fileURL)
                setStatus(.idle)
                return
            }
            LocalFlowLogger.log(
                "Recording spool failed audioKept=\(result.fileURL.path) error=\(error.localizedDescription)"
            )
            setStatus(
                .error(
                    "The recording was kept, but LocalFlow could not queue it: \(error.localizedDescription)"
                )
            )
        }
    }

    /// Resumes jobs left by a network error, crash, or normal shutdown.
    /// Recovered text is saved to History but is never pasted into whatever app
    /// happens to be focused after relaunch.
    func resumePendingDictations() {
        guard processingTask == nil,
              !isStarting,
              !audioRecorder.isRecording,
              let context = makeProcessingContext() else {
            return
        }

        let generation = UUID()
        processingGeneration = generation
        isProcessing = true
        isRecoveringPendingJobs = true
        completedForegroundStatus = nil
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let jobs = try await self.pendingDictationStore.loadAll()
                try Task.checkCancellation()
                guard self.processingGeneration == generation,
                      self.isRecoveringPendingJobs else {
                    throw CancellationError()
                }
                guard !jobs.isEmpty else {
                    self.finishProcessing(
                        generation: generation,
                        recovered: true
                    )
                    return
                }
                self.setStatus(.processing)
                LocalFlowLogger.log(
                    "Pending recovery started count=\(jobs.count)"
                )
                try await self.process(
                    jobs: jobs,
                    context: context,
                    insertionTarget: nil,
                    shouldInsert: false,
                    generation: generation
                )
                self.finishProcessing(
                    generation: generation,
                    recovered: true
                )
            } catch is CancellationError {
                self.finishCancelledProcessing(generation: generation)
            } catch {
                self.finishFailedProcessing(error, generation: generation)
            }
        }
    }

    /// Persists a live recording before AppKit allows the process to terminate.
    func prepareForTermination() async {
        if let finalizationTask {
            await finalizationTask.value
        }
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        isRecoveringPendingJobs = false
        cancelPendingRecordingStart()

        guard audioRecorder.isRecording else {
            return
        }
        recordingFrameDriver?.stop()
        recordingFrameDriver = nil

        do {
            let result = try audioRecorder.stop()
            guard result.durationSeconds >= 0.25 else {
                removeTemporaryFile(result.fileURL)
                return
            }
            _ = try await pendingDictationStore.persistRecording(
                from: result.fileURL,
                durationSeconds: result.durationSeconds,
                targetApplication: recordingTargetApplication,
                parameters: makePendingParameters()
            )
            LocalFlowLogger.log("Recording persisted during termination")
        } catch {
            LocalFlowLogger.log(
                "Recording termination persistence failed error=\(error.localizedDescription)"
            )
        }
        resetRecordingState()
    }

    private struct ProcessingContext {
        var client: OpenAIClient
        var restoreClipboard: Bool
        var restoreDelayMilliseconds: Int
    }

    private func makeProcessingContext() -> ProcessingContext? {
        guard let openAIClient else {
            return nil
        }
        return ProcessingContext(
            client: openAIClient,
            restoreClipboard: configuration.restoreClipboardAfterPaste,
            restoreDelayMilliseconds: configuration.pasteRestoreDelayMilliseconds
        )
    }

    private func makePendingParameters() -> PendingDictationParameters {
        PendingDictationParameters(
            transcriptionModel: configuration.transcriptionModel,
            transcriptionLanguage: configuration.transcriptionLanguage,
            enablePolish: configuration.enablePolish,
            polishModel: configuration.polishModel,
            outputMode: configuration.outputMode,
            promptModel: configuration.promptModel,
            dictionary: dictionary
        )
    }

    private func startProcessing(
        jobs: [PendingDictationJob],
        context: ProcessingContext?,
        insertionTarget: TextInsertionTarget?,
        shouldInsert: Bool
    ) {
        guard let context else {
            setStatus(
                .error(
                    "Missing OPENAI_API_KEY in .env. The recording was saved for retry."
                )
            )
            return
        }

        let generation = UUID()
        processingGeneration = generation
        activePendingJobID = jobs.first?.id
        isProcessing = true
        isRecoveringPendingJobs = !shouldInsert
        completedForegroundStatus = nil
        setStatus(.processing)
        LocalFlowLogger.log(
            "Processing started jobs=\(jobs.count) duration=\(String(format: "%.2f", jobs.first?.durationSeconds ?? 0))"
        )

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.process(
                    jobs: jobs,
                    context: context,
                    insertionTarget: insertionTarget,
                    shouldInsert: shouldInsert,
                    generation: generation
                )
                self.finishProcessing(
                    generation: generation,
                    recovered: !shouldInsert
                )
            } catch is CancellationError {
                self.finishCancelledProcessing(generation: generation)
            } catch {
                self.finishFailedProcessing(error, generation: generation)
            }
        }
    }

    private func process(
        jobs: [PendingDictationJob],
        context: ProcessingContext,
        insertionTarget: TextInsertionTarget?,
        shouldInsert: Bool,
        generation: UUID
    ) async throws {
        for initialJob in jobs {
            try Task.checkCancellation()
            guard processingGeneration == generation else {
                throw CancellationError()
            }
            activePendingJobID = initialJob.id
            var job = initialJob

            if job.stage == .recorded {
                let audioURL = await pendingDictationStore.audioURL(for: job)
                let validation = AudioRecordingValidator.validate(at: audioURL)
                guard validation == .usable else {
                    let reason = validation == .digitalSilence
                        ? "silent-audio"
                        : "invalid-audio"
                    try await pendingDictationStore.quarantine(
                        job,
                        reason: reason
                    )
                    LocalFlowLogger.log(
                        "Pending job quarantined reason=\(reason) id=\(job.id)"
                    )
                    if shouldInsert {
                        setStatus(
                            .error(
                                "The microphone produced no readable audio. Please try again."
                            )
                        )
                    }
                    continue
                }
                do {
                    job = try await transcribe(job, client: context.client)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Self.isEmptyTranscription(error) {
                        try await pendingDictationStore.quarantine(
                            job,
                            reason: "no-speech"
                        )
                        LocalFlowLogger.log(
                            "Pending job quarantined after repeated empty transcriptions id=\(job.id)"
                        )
                        if shouldInsert {
                            setStatus(
                                .error(
                                    "No speech was detected after multiple attempts. Please try again."
                                )
                            )
                        }
                        continue
                    }

                    if Self.isPermanentPendingFailure(error) {
                        try await pendingDictationStore.quarantine(
                            job,
                            reason: "permanent-transcription-error"
                        )
                        LocalFlowLogger.log(
                            "Pending job quarantined permanentError id=\(job.id) error=\(error.localizedDescription)"
                        )
                        if shouldInsert {
                            setStatus(
                                .error(
                                    error.localizedDescription
                                )
                            )
                        }
                        continue
                    }
                    throw error
                }
            }
            try Task.checkCancellation()

            if job.stage == .transcribed {
                job = try await finishText(job, client: context.client)
            }
            try Task.checkCancellation()

            var historyWasSaved = job.stage == .historySaved
            if job.stage == .ready, let record = job.makeHistoryRecord() {
                do {
                    try historyStore.append(record)
                    job.stage = .historySaved
                    try await pendingDictationStore.save(job)
                    historyWasSaved = true
                    onHistoryRecordCreated?(record)
                    LocalFlowLogger.log("History appended id=\(record.id)")
                } catch {
                    // Insertion remains useful while the durable `.ready` job
                    // waits for the history store to become writable again.
                    LocalFlowLogger.log(
                        "History append deferred id=\(record.id) error=\(error.localizedDescription)"
                    )
                }
            }

            try Task.checkCancellation()
            guard let finalText = job.finalText else {
                throw OpenAIClientError.emptyTranscription
            }

            if shouldInsert {
                let outcome = try await insertionService.paste(
                    text: finalText,
                    restoreClipboard: context.restoreClipboard,
                    restoreDelayMilliseconds: context.restoreDelayMilliseconds,
                    target: insertionTarget
                )
                try Task.checkCancellation()
                onInsertionCompleted?(outcome)
                completedForegroundStatus = .done(finalText, outcome)
                switch outcome {
                case .pasted:
                    LocalFlowLogger.log("Paste finished chars=\(finalText.count)")
                case .copiedToClipboard:
                    LocalFlowLogger.log(
                        "Transcript kept on clipboard chars=\(finalText.count)"
                    )
                }
            }

            if historyWasSaved {
                try await pendingDictationStore.discard(job)
                LocalFlowLogger.log("Pending job completed id=\(job.id)")
            }
        }
    }

    private func transcribe(
        _ initialJob: PendingDictationJob,
        client: OpenAIClient
    ) async throws -> PendingDictationJob {
        var job = initialJob
        let audioURL = await pendingDictationStore.audioURL(for: job)
        let optimizedUpload = await AudioUploadOptimizer.prepare(audioURL)
        defer {
            if optimizedUpload.fileURL.standardizedFileURL
                != audioURL.standardizedFileURL {
                removeTemporaryFile(optimizedUpload.fileURL)
            }
        }
        try Task.checkCancellation()
        LocalFlowLogger.log(
            "Audio upload prepared originalBytes=\(optimizedUpload.originalByteCount) uploadBytes=\(optimizedUpload.uploadByteCount) durationMs=\(Int((optimizedUpload.preparationDuration * 1_000).rounded()))"
        )

        let parameters = job.parameters
        let prompt = PromptBuilder.transcriptionPrompt(
            dictionary: parameters.dictionary,
            targetApplication: job.targetApplication,
            language: parameters.transcriptionLanguage
        )
        let inferenceStartedAt = ProcessInfo.processInfo.systemUptime
        var uploadURL = optimizedUpload.fileURL
        var retriedWithOriginalAudio = false
        while true {
            do {
                job.transcribedText = try await client.transcribeAudio(
                    fileURL: uploadURL,
                    model: parameters.transcriptionModel,
                    language: parameters.transcriptionLanguage,
                    prompt: prompt
                )
                try Task.checkCancellation()
                job.emptyTranscriptionResponseCount = nil
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard Self.isEmptyTranscription(error) else {
                    throw error
                }

                if uploadURL.standardizedFileURL
                    != audioURL.standardizedFileURL,
                   !retriedWithOriginalAudio {
                    retriedWithOriginalAudio = true
                    uploadURL = audioURL
                    LocalFlowLogger.log(
                        "Optimized audio returned empty transcription; retrying original recording id=\(job.id)"
                    )
                    continue
                }

                let responseCount = (
                    job.emptyTranscriptionResponseCount ?? 0
                ) + 1
                job.emptyTranscriptionResponseCount = responseCount
                try await pendingDictationStore.save(job)
                if responseCount
                    >= Self.maximumEmptyTranscriptionResponses {
                    throw error
                }

                LocalFlowLogger.log(
                    "Empty transcription retry id=\(job.id) attempt=\(responseCount)"
                )
                try await Task.sleep(
                    for: .milliseconds(250 * responseCount)
                )
            }
        }
        job.stage = .transcribed
        try await pendingDictationStore.save(job)
        LocalFlowLogger.log(
            "Transcription checkpoint saved chars=\(job.transcribedText?.count ?? 0) durationMs=\(Int(((ProcessInfo.processInfo.systemUptime - inferenceStartedAt) * 1_000).rounded())) model=\(parameters.transcriptionModel)"
        )
        return job
    }

    private func finishText(
        _ initialJob: PendingDictationJob,
        client: OpenAIClient
    ) async throws -> PendingDictationJob {
        var job = initialJob
        guard let transcribedText = job.transcribedText else {
            throw OpenAIClientError.emptyTranscription
        }

        let parameters = job.parameters
        var finalText = ReplacementEngine.apply(
            parameters.dictionary.replacements,
            to: transcribedText
        )
        var polished = false
        var outputMode = DictationOutputMode.transcript

        switch parameters.resolvedOutputMode {
        case .email:
            outputMode = .email
            let toneDecision = MailToneRouter.decide(for: finalText)
            LocalFlowLogger.log(
                "Mail Mode tone=\(toneDecision.intent.rawValue) cues=\(toneDecision.matchedCues.joined(separator: ","))"
            )
            do {
                let emailStartedAt = ProcessInfo.processInfo.systemUptime
                finalText = try await client.rewriteAsPrompt(
                    text: finalText,
                    model: parameters.promptModel ?? "gpt-5.6-luna",
                    systemPrompt: PromptBuilder.emailModeSystemPrompt(
                        targetApplication: job.targetApplication,
                        toneIntent: toneDecision.intent
                    ),
                    userPrompt: PromptBuilder.emailModeUserPrompt(
                        text: finalText
                    )
                )
                try Task.checkCancellation()
                polished = true
                LocalFlowLogger.log(
                    "Mail Mode finished chars=\(finalText.count) durationMs=\(Int(((ProcessInfo.processInfo.systemUptime - emailStartedAt) * 1_000).rounded())) model=\(parameters.promptModel ?? "gpt-5.6-luna")"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                LocalFlowLogger.log(
                    "Mail Mode failed; using raw transcript error=\(error.localizedDescription)"
                )
            }
        case .prompt:
            outputMode = .prompt
            let decision = PromptModeRouter.decide(for: finalText)
            LocalFlowLogger.log(
                "Prompt Mode route=\(decision.route.rawValue) reason=\(decision.reason.rawValue) words=\(decision.wordCount)"
            )

            if decision.shouldUseAI {
                do {
                    let promptStartedAt = ProcessInfo.processInfo.systemUptime
                    finalText = try await client.rewriteAsPrompt(
                        text: finalText,
                        model: parameters.promptModel ?? "gpt-5.6-luna",
                        systemPrompt: PromptBuilder.promptModeSystemPrompt(
                            targetApplication: job.targetApplication
                        ),
                        userPrompt: PromptBuilder.promptModeUserPrompt(
                            text: finalText
                        )
                    )
                    try Task.checkCancellation()
                    polished = true
                    LocalFlowLogger.log(
                        "Prompt Mode finished chars=\(finalText.count) durationMs=\(Int(((ProcessInfo.processInfo.systemUptime - promptStartedAt) * 1_000).rounded())) model=\(parameters.promptModel ?? "gpt-5.6-luna")"
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    LocalFlowLogger.log(
                        "Prompt Mode failed; using raw transcript error=\(error.localizedDescription)"
                    )
                }
            }
        case .polish:
            do {
                finalText = try await client.polish(
                    text: finalText,
                    model: parameters.polishModel,
                    systemPrompt: PromptBuilder.polishSystemPrompt(
                        targetApplication: job.targetApplication
                    ),
                    userPrompt: PromptBuilder.polishUserPrompt(text: finalText)
                )
                try Task.checkCancellation()
                polished = true
                outputMode = .polish
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Both optional rewrite modes fall back to the valid raw
                // transcript instead of losing a dictation on a second call.
                LocalFlowLogger.log(
                    "Polish failed; using raw transcript error=\(error.localizedDescription)"
                )
            }
        case .transcript:
            break
        }

        job.finalText = finalText
        job.polished = polished
        job.outputMode = outputMode
        job.stage = .ready
        try await pendingDictationStore.save(job)
        return job
    }

    private func cancelProcessing() {
        let jobID = activePendingJobID
        let wasRecovering = isRecoveringPendingJobs
        processingGeneration = UUID()
        processingTask?.cancel()
        processingTask = nil
        activePendingJobID = nil
        isProcessing = false
        isRecoveringPendingJobs = false
        completedForegroundStatus = nil
        resetRecordingState()
        setStatus(.idle)
        LocalFlowLogger.log(
            wasRecovering
                ? "Pending recovery cancelled; job preserved"
                : "Processing cancelled and discarded by user"
        )

        if let jobID, !wasRecovering {
            Task {
                try? await pendingDictationStore.discard(id: jobID)
            }
        }
    }

    private func finishProcessing(generation: UUID, recovered: Bool) {
        guard processingGeneration == generation else {
            return
        }
        processingTask = nil
        activePendingJobID = nil
        isProcessing = false
        isRecoveringPendingJobs = false
        resetRecordingState()
        if recovered {
            completedForegroundStatus = nil
            setStatus(.idle)
            LocalFlowLogger.log("Pending recovery finished")
        } else if let completedForegroundStatus {
            self.completedForegroundStatus = nil
            setStatus(completedForegroundStatus)
        }
    }

    private func finishCancelledProcessing(generation: UUID) {
        guard processingGeneration == generation else {
            return
        }
        processingTask = nil
        activePendingJobID = nil
        isProcessing = false
        isRecoveringPendingJobs = false
        completedForegroundStatus = nil
        resetRecordingState()
        setStatus(.idle)
    }

    private func finishFailedProcessing(_ error: Error, generation: UUID) {
        guard processingGeneration == generation else {
            return
        }
        processingTask = nil
        activePendingJobID = nil
        isProcessing = false
        isRecoveringPendingJobs = false
        completedForegroundStatus = nil
        resetRecordingState()
        LocalFlowLogger.log(
            "Processing deferred for retry error=\(error.localizedDescription)"
        )
        if let guidance = Self.setupGuidance(for: error) {
            onSetupRequired?(guidance)
        }
        setStatus(
            .error(
                "\(error.localizedDescription) The dictation was saved for retry."
            )
        )
    }

    private func startRecordingStatusLoop() {
        recordingFrameDriver?.stop()
        let driver = RecordingFrameDriver { [weak self] in
            self?.refreshRecordingStatus()
        }
        recordingFrameDriver = driver
        driver.start()
    }

    private func clearFinalizationOwnership() {
        isFinalizingRecording = false
        finalizationTask = nil
    }

    private func interruptPendingRecoveryForRecording() {
        guard isRecoveringPendingJobs else {
            return
        }
        processingGeneration = UUID()
        processingTask?.cancel()
        processingTask = nil
        activePendingJobID = nil
        isProcessing = false
        isRecoveringPendingJobs = false
        completedForegroundStatus = nil
        LocalFlowLogger.log("Pending recovery paused for foreground recording")
    }

    private static func isPermanentPendingFailure(_ error: Error) -> Bool {
        guard let error = error as? OpenAIClientError else {
            return false
        }
        switch error {
        case let .badStatus(statusCode, _):
            return (400..<500).contains(statusCode)
                && ![401, 403, 408, 409, 425, 429].contains(statusCode)
        case .audioFileUnavailable,
             .audioFileEmpty,
             .audioFileTooLarge,
             .invalidURL:
            return true
        default:
            return false
        }
    }

    private static func isEmptyTranscription(_ error: Error) -> Bool {
        guard let error = error as? OpenAIClientError else {
            return false
        }
        if case .emptyTranscription = error {
            return true
        }
        return false
    }

    private static let maximumEmptyTranscriptionResponses = 3

    static func setupGuidance(for error: Error) -> String? {
        guard let error = error as? OpenAIClientError else {
            return nil
        }
        switch error {
        case .missingAPIKey:
            return "Add a valid OpenAI API key in LocalFlow Settings."
        case .badStatus(401, _):
            return "OpenAI rejected this API key. Replace it in LocalFlow Settings."
        case .badStatus(403, _):
            return "This API key cannot access the configured OpenAI model. Check the key and model in Settings."
        case .badStatus(404, _):
            return "The configured OpenAI model is unavailable for this account. Choose an available model in Settings."
        default:
            return nil
        }
    }

    private func refreshRecordingStatus() {
        guard audioRecorder.isRecording, let recordingStartedAt else {
            return
        }
        let duration = Date().timeIntervalSince(recordingStartedAt)
        if configuration.enableDoubleClapControl {
            let detectionReceived = audioRecorder
                .consumeDoubleClapDetection()
            if DoubleClapRecordingStopPolicy.shouldStop(
                detectionReceived: detectionReceived,
                recordingDuration: duration
            ) {
                LocalFlowLogger.log(
                    "Double-clap control requested recording finish"
                )
                requestRecordingStop()
                return
            }
            if detectionReceived {
                LocalFlowLogger.log(
                    "Double-clap startup echo ignored duration=\(String(format: "%.2f", duration))"
                )
            }
        }
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
        cancelPendingRecordingStart()
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
