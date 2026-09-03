import Foundation
import XCTest
@testable import LocalFlowApp
@testable import LocalFlowCore

final class DictationRecoveryTests: XCTestCase {
    /// Background recovery re-transcribes parked dictations into History. It
    /// must stay invisible: the floating bar saying "Refining your words" is
    /// only meaningful right after the user dictated something.
    @MainActor
    func testBackgroundRecoveryDoesNotShowTheProcessingBar() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-recovery-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Garbage audio is quarantined before any network request is made.
        let audioURL = root.appendingPathComponent("garbage.wav")
        try Data(repeating: 0x00, count: 64).write(to: audioURL)
        let store = PendingDictationStore(rootURL: root.appendingPathComponent("pending", isDirectory: true))
        _ = try await store.persistRecording(
            from: audioURL,
            durationSeconds: 2,
            targetApplication: nil,
            parameters: PendingDictationParameters(
                transcriptionModel: "gpt-4o-mini-transcribe",
                transcriptionLanguage: "fr",
                enablePolish: false,
                polishModel: "gpt-4o-mini",
                dictionary: PersonalDictionary(terms: [], replacements: [:])
            )
        )

        let controller = DictationController(
            configuration: AppConfiguration(openAIAPIKey: "sk-test-never-sent"),
            dictionary: PersonalDictionary(terms: [], replacements: [:]),
            historyStore: HistoryStore(url: root.appendingPathComponent("history.jsonl")),
            pendingDictationStore: store
        )
        var statuses: [AppStatus] = []
        controller.onStatusChanged = { status, _ in statuses.append(status) }

        controller.resumePendingDictations()
        for _ in 0..<200 where controller.canCancelRecording {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertFalse(controller.canCancelRecording, "recovery should have finished")
        let jobsLeft = try await store.loadAll()
        XCTAssertTrue(jobsLeft.isEmpty, "the unreadable job should have been quarantined")
        XCTAssertFalse(
            statuses.contains { if case .processing = $0 { return true } else { return false } },
            "statuses: \(statuses)"
        )
    }
}
