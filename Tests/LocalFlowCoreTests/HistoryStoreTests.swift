import Foundation
import XCTest
@testable import LocalFlowCore

final class HistoryStoreTests: XCTestCase {
    func testAppendLoadPruneAndClear() throws {
        try withStore { store, _ in
            let old = record(text: "ancien", timestamp: 100)
            let recent = record(text: "récent", timestamp: 200_000, polished: true)

            try store.append(old)
            try store.append(recent)

            XCTAssertEqual(try store.load().map(\.finalText), ["récent", "ancien"])

            try store.prune(retentionDays: 1, now: Date(timeIntervalSince1970: 200_000))
            XCTAssertEqual(try store.load().map(\.finalText), ["récent"])

            try store.clear()
            XCTAssertEqual(try store.load(), [])
            XCTAssertEqual(try store.count(), 0)
        }
    }

    func testAppendIsIdempotentAcrossStoreInstances() throws {
        try withStore { store, url in
            let duplicate = record(text: "saved exactly once", timestamp: 200)
            XCTAssertTrue(try store.appendIfMissing(duplicate))
            XCTAssertFalse(try store.appendIfMissing(duplicate))

            let secondInstance = HistoryStore(url: url)
            XCTAssertTrue(try secondInstance.contains(id: duplicate.id))
            XCTAssertFalse(try secondInstance.appendIfMissing(duplicate))
            XCTAssertEqual(try secondInstance.count(), 1)

            let jsonLines = try Data(contentsOf: url)
                .split(separator: UInt8(ascii: "\n"))
            XCTAssertEqual(jsonLines.count, 1)
        }
    }

    func testMigratesExistingJSONLAndDetectsLaterLegacyAppend() throws {
        try withStore { store, url in
            let first = record(text: "legacy one", timestamp: 100)
            try writeLegacy([first], to: url)

            XCTAssertEqual(try store.load(), [first])

            let second = record(text: "legacy two", timestamp: 200)
            try appendLegacy(second, to: url)

            XCTAssertEqual(try store.load().map(\.id), [second.id, first.id])
            XCTAssertEqual(try store.count(), 2)
        }
    }

    func testInterruptedLegacyTailDoesNotSwallowNextRecord() throws {
        try withStore { store, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("{\"incomplete\":".utf8).write(to: url)

            let complete = record(text: "survives", timestamp: 200)
            try store.append(complete)

            XCTAssertEqual(try store.load(), [complete])

            try store.prune(retentionDays: 365, now: Date(timeIntervalSince1970: 200))
            let recovery = try String(contentsOf: store.recoveryURL, encoding: .utf8)
            XCTAssertTrue(recovery.contains("{\"incomplete\":"))
            XCTAssertEqual(try store.load(), [complete])
        }
    }

    func testPruneQuarantinesMalformedLinesWithoutDiscardingBytes() throws {
        try withStore { store, url in
            let old = record(text: "old", timestamp: 100)
            let recent = record(text: "recent", timestamp: 200_000)
            try writeLegacy([old], to: url)
            let malformed = Data([0xFF, 0xFE, 0x7B, 0x0A])
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: malformed)
            try handle.close()
            try appendLegacy(recent, to: url)

            try store.prune(retentionDays: 1, now: Date(timeIntervalSince1970: 200_000))

            XCTAssertEqual(try store.load(), [recent])
            let recovery = try Data(contentsOf: store.recoveryURL)
            XCTAssertTrue(recovery.starts(with: malformed))
            let rewritten = try Data(contentsOf: url)
            XCTAssertFalse(rewritten.contains(0xFF))
        }
    }

    func testNonPositiveRetentionNeverErasesData() throws {
        try withStore { store, url in
            let original = record(text: "must stay", timestamp: 100)
            try writeLegacy([original], to: url)
            let bytesBefore = try Data(contentsOf: url)

            try store.prune(retentionDays: 0, now: Date(timeIntervalSince1970: 999_999))
            XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
            XCTAssertEqual(try store.load(), [original])

            try store.prune(retentionDays: -30, now: Date(timeIntervalSince1970: 999_999))
            XCTAssertEqual(try store.load(), [original])
        }
    }

    func testIndexedPaginationReportsTotalAndContinuation() throws {
        try withStore { store, _ in
            for index in 0..<7 {
                try store.append(record(text: "record \(index)", timestamp: TimeInterval(index)))
            }

            let first = try store.loadPage(offset: 0, limit: 3)
            XCTAssertEqual(first.records.map(\.finalText), ["record 6", "record 5", "record 4"])
            XCTAssertEqual(first.totalCount, 7)
            XCTAssertTrue(first.hasMore)

            let final = try store.loadPage(offset: 6, limit: 3)
            XCTAssertEqual(final.records.map(\.finalText), ["record 0"])
            XCTAssertFalse(final.hasMore)

            let empty = try store.loadPage(offset: -20, limit: 0)
            XCTAssertEqual(empty.offset, 0)
            XCTAssertEqual(empty.totalCount, 7)
            XCTAssertTrue(empty.records.isEmpty)
        }
    }

    func testInterruptedPruneIsCompletedBeforeLegacyMigration() throws {
        try withStore { store, url in
            let old = record(text: "must be pruned", timestamp: 100)
            let recent = record(text: "must remain", timestamp: 200_000)
            try store.append(old)
            try store.append(recent)

            let cutoff = Date(timeIntervalSince1970: 200_000 - 86_400)
            let marker = try JSONSerialization.data(withJSONObject: [
                "kind": "prune",
                "cutoff": ISO8601DateFormatter().string(from: cutoff)
            ])
            let markerURL = url.deletingPathExtension().appendingPathExtension("maintenance.json")
            try marker.write(to: markerURL, options: .atomic)

            // A fresh process sees the marker before importing the still-unpruned
            // JSONL mirror, completes the delete, then rebuilds the mirror.
            let relaunched = HistoryStore(url: url)
            XCTAssertEqual(try relaunched.load(), [recent])
            XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
            XCTAssertEqual(try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")).count, 1)
        }
    }

    func testStorageUsesPrivatePermissions() throws {
        try withStore { store, url in
            try store.append(record(text: "private", timestamp: 100))

            XCTAssertEqual(try permissions(at: url.deletingLastPathComponent()), 0o700)
            XCTAssertEqual(try permissions(at: url), 0o600)
            XCTAssertEqual(try permissions(at: store.databaseURL), 0o600)
        }
    }

    private func withStore(
        _ body: (HistoryStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlowHistoryTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(HistoryStore(url: url), url)
    }

    private func record(
        text: String,
        timestamp: TimeInterval,
        polished: Bool = false
    ) -> DictationRecord {
        DictationRecord(
            createdAt: Date(timeIntervalSince1970: timestamp),
            targetApplication: TargetApplicationInfo(
                localizedName: "Terminal",
                bundleIdentifier: "com.apple.Terminal"
            ),
            transcribedText: text,
            finalText: text,
            polished: polished,
            durationSeconds: 2
        )
    }

    private func writeLegacy(_ records: [DictationRecord], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = Data()
        for record in records {
            data.append(try encoded(record))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: url)
    }

    private func appendLegacy(_ record: DictationRecord, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try writeLegacy([], to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encoded(record))
        try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
        try handle.synchronize()
    }

    private func encoded(_ record: DictationRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(record)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
