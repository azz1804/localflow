import Foundation

public struct DictationRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var targetApplication: TargetApplicationInfo?
    public var transcribedText: String
    public var finalText: String
    public var polished: Bool
    public var durationSeconds: TimeInterval?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        targetApplication: TargetApplicationInfo?,
        transcribedText: String,
        finalText: String,
        polished: Bool,
        durationSeconds: TimeInterval?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.targetApplication = targetApplication
        self.transcribedText = transcribedText
        self.finalText = finalText
        self.polished = polished
        self.durationSeconds = durationSeconds
    }
}

public final class HistoryStore {
    public let url: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ record: DictationRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = (try? Data(contentsOf: url)) ?? Data()
        data.append(try encoder.encode(record))
        data.append(Data("\n".utf8))
        try data.write(to: url, options: .atomic)
    }

    public func load(limit: Int? = nil) throws -> [DictationRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        let records = contents
            .split(separator: "\n")
            .compactMap { line -> DictationRecord? in
                guard let data = String(line).data(using: .utf8) else {
                    return nil
                }

                return try? decoder.decode(DictationRecord.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }

        if let limit {
            return Array(records.prefix(limit))
        }

        return records
    }

    public func prune(retentionDays: Int, now: Date = Date()) throws {
        guard retentionDays > 0 else {
            try Data().write(to: url, options: .atomic)
            return
        }

        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 60 * 60)
        let kept = try load().filter { $0.createdAt >= cutoff }.sorted { $0.createdAt < $1.createdAt }
        let data = try kept.reduce(into: Data()) { partialResult, record in
            partialResult.append(try encoder.encode(record))
            partialResult.append(Data("\n".utf8))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
