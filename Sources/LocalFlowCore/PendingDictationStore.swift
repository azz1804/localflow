import Foundation

public struct PendingDictationParameters: Codable, Equatable, Sendable {
    public var transcriptionModel: String
    public var transcriptionLanguage: String
    public var enablePolish: Bool
    public var polishModel: String
    public var outputMode: DictationOutputMode?
    public var promptModel: String?
    public var dictionary: PersonalDictionary

    public var resolvedOutputMode: DictationOutputMode {
        outputMode ?? (enablePolish ? .polish : .transcript)
    }

    public init(
        transcriptionModel: String,
        transcriptionLanguage: String,
        enablePolish: Bool,
        polishModel: String,
        outputMode: DictationOutputMode? = nil,
        promptModel: String? = nil,
        dictionary: PersonalDictionary
    ) {
        self.transcriptionModel = transcriptionModel
        self.transcriptionLanguage = transcriptionLanguage
        self.enablePolish = enablePolish
        self.polishModel = polishModel
        self.outputMode = outputMode
        self.promptModel = promptModel
        self.dictionary = dictionary
    }
}

public struct PendingDictationJob: Codable, Equatable, Identifiable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case recorded
        case transcribed
        case ready
        case historySaved
    }

    public var id: UUID
    public var recordID: UUID
    public var createdAt: Date
    public var audioFilename: String
    public var durationSeconds: TimeInterval
    public var targetApplication: TargetApplicationInfo?
    public var parameters: PendingDictationParameters
    public var stage: Stage
    public var transcribedText: String?
    public var finalText: String?
    public var polished: Bool
    public var outputMode: DictationOutputMode?
    public var emptyTranscriptionResponseCount: Int?

    public init(
        id: UUID = UUID(),
        recordID: UUID = UUID(),
        createdAt: Date = Date(),
        audioFilename: String = "recording.wav",
        durationSeconds: TimeInterval,
        targetApplication: TargetApplicationInfo?,
        parameters: PendingDictationParameters,
        stage: Stage = .recorded,
        transcribedText: String? = nil,
        finalText: String? = nil,
        polished: Bool = false,
        outputMode: DictationOutputMode? = nil,
        emptyTranscriptionResponseCount: Int? = nil
    ) {
        self.id = id
        self.recordID = recordID
        self.createdAt = Date(
            timeIntervalSince1970: (
                createdAt.timeIntervalSince1970 * 1_000
            ).rounded() / 1_000
        )
        self.audioFilename = audioFilename
        self.durationSeconds = durationSeconds
        self.targetApplication = targetApplication
        self.parameters = parameters
        self.stage = stage
        self.transcribedText = transcribedText
        self.finalText = finalText
        self.polished = polished
        self.outputMode = outputMode
        self.emptyTranscriptionResponseCount = emptyTranscriptionResponseCount
    }

    public func makeHistoryRecord() -> DictationRecord? {
        guard let transcribedText, let finalText else {
            return nil
        }

        return DictationRecord(
            id: recordID,
            createdAt: createdAt,
            targetApplication: targetApplication,
            transcribedText: transcribedText,
            finalText: finalText,
            polished: polished,
            outputMode: outputMode,
            durationSeconds: durationSeconds
        )
    }
}

/// Crash-safe spool for dictations that have not completed every durable step.
/// Files live outside the temporary directory so a network failure or process
/// crash never destroys the user's only copy of a recording.
public actor PendingDictationStore {
    public let rootURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL = LocalFlowPaths.appSupportDirectory.appendingPathComponent("pending", isDirectory: true)) {
        self.rootURL = rootURL
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        // Millisecond precision is deterministic across a JSON round-trip and
        // sufficient for ordering user dictations while preserving stable jobs.
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
    }

    public func persistRecording(
        from sourceURL: URL,
        durationSeconds: TimeInterval,
        targetApplication: TargetApplicationInfo?,
        parameters: PendingDictationParameters
    ) throws -> PendingDictationJob {
        try ensureRootDirectory()

        let extensionName = sourceURL.pathExtension.isEmpty
            ? "wav"
            : sourceURL.pathExtension.lowercased()
        let job = PendingDictationJob(
            audioFilename: "recording.\(extensionName)",
            durationSeconds: durationSeconds,
            targetApplication: targetApplication,
            parameters: parameters
        )
        let directory = directoryURL(for: job.id)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let destinationURL = directory.appendingPathComponent(job.audioFilename)
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                try? FileManager.default.removeItem(at: sourceURL)
            }
            try setPrivateFilePermissions(destinationURL)
            try save(job)
            return job
        } catch {
            // If the source was already moved, keep the directory for forensic
            // recovery rather than deleting the user's audio.
            try? quarantineDirectory(directory, suffix: "incomplete")
            throw error
        }
    }

    public func save(_ job: PendingDictationJob) throws {
        try ensureRootDirectory()
        let directory = directoryURL(for: job.id)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let manifestURL = manifestURL(for: job.id)
        let data = try encoder.encode(job)
        try data.write(to: manifestURL, options: [.atomic])
        try setPrivateFilePermissions(manifestURL)
    }

    public func loadAll() throws -> [PendingDictationJob] {
        try ensureRootDirectory()
        let directories = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var jobs: [PendingDictationJob] = []
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  UUID(uuidString: directory.lastPathComponent) != nil else {
                continue
            }

            let manifestURL = directory.appendingPathComponent("job.json")
            do {
                let data = try Data(contentsOf: manifestURL)
                let job = try decoder.decode(PendingDictationJob.self, from: data)
                guard FileManager.default.fileExists(atPath: audioURL(for: job).path)
                        || job.stage == .historySaved else {
                    throw CocoaError(.fileNoSuchFile)
                }
                jobs.append(job)
            } catch {
                // Never silently delete an unreadable job. Move it out of the
                // retry queue and leave both manifest/audio available to repair.
                try? quarantineDirectory(directory, suffix: "corrupt")
            }
        }

        return jobs.sorted { $0.createdAt < $1.createdAt }
    }

    public func audioURL(for job: PendingDictationJob) -> URL {
        directoryURL(for: job.id).appendingPathComponent(job.audioFilename)
    }

    public func discard(_ job: PendingDictationJob) throws {
        let directory = directoryURL(for: job.id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    public func discard(id: UUID) throws {
        let directory = directoryURL(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    /// Removes a permanently unprocessable job from the automatic retry queue
    /// without deleting its manifest or audio. This keeps forensic/manual
    /// recovery possible while allowing newer dictations to proceed.
    public func quarantine(
        _ job: PendingDictationJob,
        reason: String
    ) throws {
        let safeReason = reason
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { result, character in
                if character != "-" || result.last != "-" {
                    result.append(character)
                }
            }
            .prefix(48)
        let suffix = safeReason.isEmpty
            ? "quarantined"
            : String(safeReason)
        try quarantineDirectory(directoryURL(for: job.id), suffix: suffix)
    }

    private func ensureRootDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }

    private func directoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func manifestURL(for id: UUID) -> URL {
        directoryURL(for: id).appendingPathComponent("job.json")
    }

    private func setPrivateFilePermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func quarantineDirectory(_ directory: URL, suffix: String) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        let quarantineRoot = rootURL.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: quarantineRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = quarantineRoot.appendingPathComponent(
            "\(directory.lastPathComponent)-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: directory, to: destination)
    }
}
