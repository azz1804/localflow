import Foundation
import XCTest
@testable import LocalFlowCore

final class HistoryStoreTests: XCTestCase {
    func testAppendLoadAndPrune() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlowTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.jsonl")
        let store = HistoryStore(url: url)

        let old = DictationRecord(
            createdAt: Date(timeIntervalSince1970: 100),
            targetApplication: nil,
            transcribedText: "ancien",
            finalText: "ancien",
            polished: false,
            durationSeconds: 1
        )
        let recent = DictationRecord(
            createdAt: Date(timeIntervalSince1970: 200_000),
            targetApplication: TargetApplicationInfo(localizedName: "Terminal", bundleIdentifier: "com.apple.Terminal"),
            transcribedText: "récent",
            finalText: "récent",
            polished: true,
            durationSeconds: 2
        )

        try store.append(old)
        try store.append(recent)

        XCTAssertEqual(try store.load().map(\.finalText), ["récent", "ancien"])

        try store.prune(retentionDays: 1, now: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(try store.load().map(\.finalText), ["récent"])

        try? FileManager.default.removeItem(at: directory)
    }
}
