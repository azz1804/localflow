import Darwin
import Foundation
import SQLite3

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

public struct HistoryPage: Equatable, Sendable {
    public var records: [DictationRecord]
    public var offset: Int
    public var totalCount: Int

    public var hasMore: Bool {
        let safeOffset = max(0, offset)
        return safeOffset < totalCount && records.count < totalCount - safeOffset
    }

    public init(records: [DictationRecord], offset: Int, totalCount: Int) {
        self.records = records
        self.offset = offset
        self.totalCount = totalCount
    }
}

public enum HistoryStoreError: LocalizedError {
    case sqlite(message: String)
    case lockFailed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .sqlite(message):
            return "History database error: \(message)"
        case let .lockFailed(code):
            return "Could not lock history storage (errno \(code))."
        }
    }
}

/// Durable, idempotent storage for dictation history.
///
/// SQLite is the source of truth and uses WAL mode. The historical JSONL file is
/// kept as a backwards-compatible mirror and is imported whenever an older build
/// changes it. Invalid legacy lines are never discarded by a maintenance pass:
/// they are moved byte-for-byte to `history.recovery.jsonl` before a rewrite.
public final class HistoryStore {
    private static let processWideStorageLock = NSLock()

    public let url: URL
    public let databaseURL: URL
    public let recoveryURL: URL

    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let storageLockURL: URL
    private let maintenanceURL: URL
    private var database: OpaquePointer?
    private var synchronizedLegacySignature: LegacyFileSignature?
    private var legacyHasMalformedLines = false

    public init(url: URL) {
        self.url = url
        self.databaseURL = url.deletingPathExtension().appendingPathExtension("sqlite3")
        self.recoveryURL = url.deletingPathExtension().appendingPathExtension("recovery.jsonl")
        self.storageLockURL = url.deletingPathExtension().appendingPathExtension("lock")
        self.maintenanceURL = url.deletingPathExtension().appendingPathExtension("maintenance.json")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    /// Appends a record once. Replaying the same UUID after a crash is safe.
    public func append(_ record: DictationRecord) throws {
        _ = try appendIfMissing(record)
    }

    /// Returns `true` only when the record was newly persisted.
    @discardableResult
    public func appendIfMissing(_ record: DictationRecord) throws -> Bool {
        try withProcessLock {
            let database = try readyDatabaseLocked()

            return try withStorageLockLocked {
                // Re-check while holding the cross-process lock. Another LocalFlow
                // instance may have committed this job after our initial sync.
                guard try !containsLocked(id: record.id, database: database) else {
                    return false
                }

                let encoded = try encoder.encode(record)
                try appendLegacyLineLocked(encoded)

                // The JSONL write happens first on purpose. If SQLite fails, the
                // next launch imports this complete line and finishes the commit.
                do {
                    _ = try insertLocked(record, encoded: encoded, database: database)
                } catch {
                    synchronizedLegacySignature = nil
                    throw error
                }

                try recordLegacySignatureLocked(
                    try legacySignatureLocked(),
                    database: database
                )
                try hardenStoragePermissionsLocked()
                return true
            }
        }
    }

    public func contains(id: UUID) throws -> Bool {
        try withProcessLock {
            let database = try readyDatabaseLocked()
            return try containsLocked(id: id, database: database)
        }
    }

    public func load(limit: Int? = nil) throws -> [DictationRecord] {
        try withProcessLock {
            let database = try readyDatabaseLocked()
            if let limit, limit <= 0 {
                return []
            }
            return try queryLocked(database: database, limit: limit, offset: 0)
        }
    }

    /// Indexed pagination for the history UI. Pages are newest-first.
    public func loadPage(offset: Int, limit: Int) throws -> HistoryPage {
        try withProcessLock {
            let database = try readyDatabaseLocked()
            let safeLimit = max(0, limit)
            let totalCount = try countLocked(database: database)
            let safeOffset = min(max(0, offset), totalCount)
            let records = safeLimit == 0
                ? []
                : try queryLocked(database: database, limit: safeLimit, offset: safeOffset)
            return HistoryPage(records: records, offset: safeOffset, totalCount: totalCount)
        }
    }

    public func count() throws -> Int {
        try withProcessLock {
            try countLocked(database: readyDatabaseLocked())
        }
    }

    public func prune(retentionDays: Int, now: Date = Date()) throws {
        // Invalid configuration must never be interpreted as permission to erase
        // user data. The settings UI can surface/clamp the value independently.
        guard retentionDays > 0 else {
            return
        }

        try withProcessLock {
            let database = try readyDatabaseLocked()
            let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 60 * 60)

            try withStorageLockLocked {
                // Synchronize again under the rewrite lock in case an older build
                // appended to JSONL between readyDatabaseLocked() and this point.
                try synchronizeLegacyJSONContentsLocked(into: database)
                guard try hasRecordsLocked(before: cutoff, database: database)
                        || legacyHasMalformedLines else {
                    return
                }
                let operation = MaintenanceOperation(kind: .prune, cutoff: cutoff)
                try writeMaintenanceLocked(operation)
                try performMaintenanceLocked(operation, database: database)
                try removeMaintenanceMarkerLocked()
                try recordLegacySignatureLocked(
                    try legacySignatureLocked(),
                    database: database
                )
                try hardenStoragePermissionsLocked()
            }
        }
    }

    public func clear() throws {
        try withProcessLock {
            let database = try readyDatabaseLocked()
            try withStorageLockLocked {
                let operation = MaintenanceOperation(kind: .clear, cutoff: nil)
                try writeMaintenanceLocked(operation)
                try performMaintenanceLocked(operation, database: database)
                try removeMaintenanceMarkerLocked()
                try recordLegacySignatureLocked(
                    try legacySignatureLocked(),
                    database: database
                )
                try hardenStoragePermissionsLocked()
            }
        }
    }

    // MARK: - Database lifecycle

    private func readyDatabaseLocked() throws -> OpaquePointer {
        try ensureStorageDirectoryLocked()

        if database == nil {
            var opened: OpaquePointer?
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            let result = sqlite3_open_v2(databaseURL.path, &opened, flags, nil)
            guard result == SQLITE_OK, let opened else {
                let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
                if let opened {
                    sqlite3_close_v2(opened)
                }
                throw HistoryStoreError.sqlite(message: message)
            }

            database = opened
            sqlite3_busy_timeout(opened, 5_000)
            try executeLocked("PRAGMA journal_mode=WAL;", database: opened)
            try executeLocked("PRAGMA synchronous=FULL;", database: opened)
            try executeLocked("PRAGMA foreign_keys=ON;", database: opened)
            try executeLocked(
                """
                CREATE TABLE IF NOT EXISTS dictation_records (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                """,
                database: opened
            )
            try executeLocked(
                "CREATE INDEX IF NOT EXISTS dictation_records_created_at ON dictation_records(created_at DESC, id ASC);",
                database: opened
            )
            try executeLocked(
                """
                CREATE TABLE IF NOT EXISTS storage_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                """,
                database: opened
            )
        }

        guard let database else {
            throw HistoryStoreError.sqlite(message: "Database was unexpectedly unavailable")
        }
        try withStorageLockLocked {
            // Import the JSONL mirror first even when a maintenance marker exists.
            // This also recovers safely if the SQLite file disappeared mid-prune;
            // the idempotent maintenance operation is applied immediately after.
            try synchronizeLegacyJSONContentsLocked(into: database)
            try recoverInterruptedMaintenanceLocked(database: database)
        }
        try hardenStoragePermissionsLocked()
        return database
    }

    /// The caller must hold the stable storage lock.
    private func synchronizeLegacyJSONContentsLocked(
        into database: OpaquePointer
    ) throws {
        let signature = try legacySignatureLocked()
        guard signature != synchronizedLegacySignature else {
            return
        }
        if try storedLegacySignatureLocked(database: database) == signature?.serialized {
            synchronizedLegacySignature = signature
            return
        }

        let parsed = try readLegacyLinesLocked()
        legacyHasMalformedLines = !parsed.malformed.isEmpty
        if !parsed.records.isEmpty {
            try transactionLocked(database: database) {
                for record in parsed.records {
                    let encoded = try encoder.encode(record)
                    _ = try insertLocked(record, encoded: encoded, database: database)
                }
            }
        }

        try recordLegacySignatureLocked(signature, database: database)
    }

    // MARK: - SQLite operations

    private func insertLocked(
        _ record: DictationRecord,
        encoded: Data,
        database: OpaquePointer
    ) throws -> Bool {
        let statement = try prepareLocked(
            "INSERT OR IGNORE INTO dictation_records(id, created_at, payload) VALUES (?, ?, ?);",
            database: database
        )
        defer { sqlite3_finalize(statement) }

        try bindTextLocked(record.id.uuidString, index: 1, statement: statement, database: database)
        sqlite3_bind_double(statement, 2, record.createdAt.timeIntervalSince1970)
        try bindBlobLocked(encoded, index: 3, statement: statement, database: database)
        try stepDoneLocked(statement, database: database)
        return sqlite3_changes(database) > 0
    }

    private func containsLocked(id: UUID, database: OpaquePointer) throws -> Bool {
        let statement = try prepareLocked(
            "SELECT 1 FROM dictation_records WHERE id = ? LIMIT 1;",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bindTextLocked(id.uuidString, index: 1, statement: statement, database: database)

        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return true
        }
        guard result == SQLITE_DONE else {
            throw sqliteErrorLocked(database)
        }
        return false
    }

    private func countLocked(database: OpaquePointer) throws -> Int {
        let statement = try prepareLocked("SELECT COUNT(*) FROM dictation_records;", database: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteErrorLocked(database)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func hasRecordsLocked(before cutoff: Date, database: OpaquePointer) throws -> Bool {
        let statement = try prepareLocked(
            "SELECT 1 FROM dictation_records WHERE created_at < ? LIMIT 1;",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return true
        }
        guard result == SQLITE_DONE else {
            throw sqliteErrorLocked(database)
        }
        return false
    }

    private func storedLegacySignatureLocked(database: OpaquePointer) throws -> String? {
        let statement = try prepareLocked(
            "SELECT value FROM storage_metadata WHERE key = 'legacy_signature' LIMIT 1;",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else {
            throw sqliteErrorLocked(database)
        }
        return String(cString: pointer)
    }

    private func recordLegacySignatureLocked(
        _ signature: LegacyFileSignature?,
        database: OpaquePointer
    ) throws {
        synchronizedLegacySignature = signature
        guard let value = signature?.serialized else {
            return
        }

        let statement = try prepareLocked(
            """
            INSERT INTO storage_metadata(key, value) VALUES ('legacy_signature', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bindTextLocked(value, index: 1, statement: statement, database: database)
        try stepDoneLocked(statement, database: database)
    }

    private func queryLocked(
        database: OpaquePointer,
        limit: Int?,
        offset: Int
    ) throws -> [DictationRecord] {
        let sql: String
        if limit == nil {
            sql = "SELECT payload FROM dictation_records ORDER BY created_at DESC, id ASC;"
        } else {
            sql = "SELECT payload FROM dictation_records ORDER BY created_at DESC, id ASC LIMIT ? OFFSET ?;"
        }

        let statement = try prepareLocked(sql, database: database)
        defer { sqlite3_finalize(statement) }
        if let limit {
            sqlite3_bind_int64(statement, 1, sqlite3_int64(limit))
            sqlite3_bind_int64(statement, 2, sqlite3_int64(max(0, offset)))
        }

        var records: [DictationRecord] = []
        if let limit {
            records.reserveCapacity(min(limit, 4_096))
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let length = Int(sqlite3_column_bytes(statement, 0))
                guard length > 0, let bytes = sqlite3_column_blob(statement, 0) else {
                    continue
                }
                let data = Data(bytes: bytes, count: length)
                // A damaged row must not prevent LocalFlow from launching or make
                // every healthy transcript inaccessible.
                if let record = try? decoder.decode(DictationRecord.self, from: data) {
                    records.append(record)
                }
            case SQLITE_DONE:
                return records
            default:
                throw sqliteErrorLocked(database)
            }
        }
    }

    private func prepareLocked(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteErrorLocked(database)
        }
        return statement
    }

    private func executeLocked(_ sql: String, database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw HistoryStoreError.sqlite(message: message)
        }
    }

    private func transactionLocked(database: OpaquePointer, body: () throws -> Void) throws {
        try executeLocked("BEGIN IMMEDIATE TRANSACTION;", database: database)
        do {
            try body()
            try executeLocked("COMMIT;", database: database)
        } catch {
            try? executeLocked("ROLLBACK;", database: database)
            throw error
        }
    }

    private func stepDoneLocked(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteErrorLocked(database)
        }
    }

    private func bindTextLocked(
        _ value: String,
        index: Int32,
        statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw sqliteErrorLocked(database)
        }
    }

    private func bindBlobLocked(
        _ value: Data,
        index: Int32,
        statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw sqliteErrorLocked(database)
        }
    }

    private func sqliteErrorLocked(_ database: OpaquePointer) -> HistoryStoreError {
        HistoryStoreError.sqlite(message: String(cString: sqlite3_errmsg(database)))
    }

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    // MARK: - Legacy JSONL and file safety

    private func readLegacyLinesLocked() throws -> (records: [DictationRecord], malformed: [Data]) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ([], [])
        }

        let contents = try Data(contentsOf: url, options: .mappedIfSafe)
        var records: [DictationRecord] = []
        var malformed: [Data] = []

        for rawLine in contents.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            var line = Data(rawLine)
            if line.last == UInt8(ascii: "\r") {
                line.removeLast()
            }
            guard !line.isEmpty else {
                continue
            }
            if let record = try? decoder.decode(DictationRecord.self, from: line) {
                records.append(record)
            } else {
                malformed.append(Data(rawLine))
            }
        }
        return (records, malformed)
    }

    private func appendLegacyLineLocked(_ encoded: Data) throws {
        try ensureLegacyFileLocked()
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let lastByte = try handle.read(upToCount: 1)?.first
            try handle.seekToEnd()
            // Preserve an interrupted last record as its own recovery candidate;
            // never concatenate a new valid JSON object onto it.
            if lastByte != UInt8(ascii: "\n") {
                try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
            }
        }
        try handle.write(contentsOf: encoded)
        try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
        try handle.synchronize()
    }

    private func rewriteLegacyLocked(records: [DictationRecord]) throws {
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(UInt8(ascii: "\n"))
        }
        try writeAtomicallyLocked(data, to: url)
        legacyHasMalformedLines = false
    }

    private func appendRecoveryLinesLocked(_ lines: [Data]) throws {
        guard !lines.isEmpty else {
            return
        }

        var recovery = (try? Data(contentsOf: recoveryURL)) ?? Data()
        for line in lines where !line.isEmpty {
            var candidate = line
            candidate.append(UInt8(ascii: "\n"))
            guard recovery.range(of: candidate) == nil else {
                continue
            }
            recovery.append(candidate)
        }
        try writeAtomicallyLocked(recovery, to: recoveryURL)
    }

    // MARK: - Crash-safe maintenance

    private func writeMaintenanceLocked(_ operation: MaintenanceOperation) throws {
        try writeAtomicallyLocked(try encoder.encode(operation), to: maintenanceURL)
    }

    private func recoverInterruptedMaintenanceLocked(database: OpaquePointer) throws {
        guard FileManager.default.fileExists(atPath: maintenanceURL.path) else {
            return
        }
        let operation = try decoder.decode(
            MaintenanceOperation.self,
            from: Data(contentsOf: maintenanceURL)
        )
        try performMaintenanceLocked(operation, database: database)
        try removeMaintenanceMarkerLocked()
        try recordLegacySignatureLocked(
            try legacySignatureLocked(),
            database: database
        )
    }

    private func performMaintenanceLocked(
        _ operation: MaintenanceOperation,
        database: OpaquePointer
    ) throws {
        switch operation.kind {
        case .prune:
            guard let cutoff = operation.cutoff else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try transactionLocked(database: database) {
                let statement = try prepareLocked(
                    "DELETE FROM dictation_records WHERE created_at < ?;",
                    database: database
                )
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
                try stepDoneLocked(statement, database: database)
            }

            let legacy = try readLegacyLinesLocked()
            if !legacy.malformed.isEmpty {
                try appendRecoveryLinesLocked(legacy.malformed)
            }
            let kept = try queryLocked(database: database, limit: nil, offset: 0)
                .sorted { $0.createdAt < $1.createdAt }
            try rewriteLegacyLocked(records: kept)

        case .clear:
            try transactionLocked(database: database) {
                try executeLocked("DELETE FROM dictation_records;", database: database)
            }
            try writeAtomicallyLocked(Data(), to: url)
            try writeAtomicallyLocked(Data(), to: recoveryURL)
            legacyHasMalformedLines = false
            _ = sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        }
    }

    private func removeMaintenanceMarkerLocked() throws {
        guard FileManager.default.fileExists(atPath: maintenanceURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: maintenanceURL)
    }

    private func writeAtomicallyLocked(_ data: Data, to destination: URL) throws {
        try ensureStorageDirectoryLocked()
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func ensureLegacyFileLocked() throws {
        try ensureFileLocked(at: url)
    }

    private func ensureFileLocked(at fileURL: URL) throws {
        try ensureStorageDirectoryLocked()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func ensureStorageDirectoryLocked() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func hardenStoragePermissionsLocked() throws {
        try ensureStorageDirectoryLocked()
        for candidate in [url, recoveryURL, storageLockURL, maintenanceURL, databaseURL,
                          URL(fileURLWithPath: databaseURL.path + "-wal"),
                          URL(fileURLWithPath: databaseURL.path + "-shm")]
        where FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
        }
    }

    private func withStorageLockLocked<T>(_ body: () throws -> T) throws -> T {
        Self.processWideStorageLock.lock()
        defer { Self.processWideStorageLock.unlock() }

        try ensureFileLocked(at: storageLockURL)
        let handle = try FileHandle(forUpdating: storageLockURL)
        defer { try? handle.close() }

        var advisoryLock = Darwin.flock()
        advisoryLock.l_type = Int16(F_WRLCK)
        advisoryLock.l_whence = Int16(SEEK_SET)
        advisoryLock.l_start = 0
        advisoryLock.l_len = 0
        guard Darwin.fcntl(handle.fileDescriptor, F_SETLKW, &advisoryLock) == 0 else {
            throw HistoryStoreError.lockFailed(code: errno)
        }
        defer {
            advisoryLock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(handle.fileDescriptor, F_SETLK, &advisoryLock)
        }
        return try body()
    }

    private func legacySignatureLocked() throws -> LegacyFileSignature? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return LegacyFileSignature(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modifiedAt: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        )
    }

    private func withProcessLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private struct LegacyFileSignature: Equatable {
    var size: UInt64
    var modifiedAt: TimeInterval
    var fileNumber: UInt64

    var serialized: String {
        "\(size):\(modifiedAt.bitPattern):\(fileNumber)"
    }
}

private struct MaintenanceOperation: Codable {
    enum Kind: String, Codable {
        case prune
        case clear
    }

    var kind: Kind
    var cutoff: Date?
}
