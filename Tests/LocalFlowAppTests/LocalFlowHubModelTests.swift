import Foundation
import LocalFlowCore
import XCTest
@testable import LocalFlowApp

final class LocalFlowHubModelTests: XCTestCase {
    @MainActor
    func testUpdateSelectsFirstTranscriptAndBuildsInsights() {
        let first = record(text: "one two three", app: "Messages")
        let second = record(text: "four five", app: "Terminal")
        let model = LocalFlowHubModel()

        model.update(
            configuration: AppConfiguration(),
            dictionary: .empty,
            historyRecords: [first, second],
            diagnosticInfo: diagnosticInfo
        )

        XCTAssertEqual(model.selectedHistoryID, first.id)
        XCTAssertEqual(model.insights.totalWords, 5)
        XCTAssertEqual(model.insights.totalDictations, 2)
    }

    @MainActor
    func testHistorySearchMatchesTranscriptAndApplication() {
        let messages = record(text: "Bonjour toute l'équipe", app: "Messages")
        let terminal = record(text: "Run the migration check", app: "Terminal")
        let model = LocalFlowHubModel()
        model.update(
            configuration: AppConfiguration(),
            dictionary: .empty,
            historyRecords: [messages, terminal],
            diagnosticInfo: diagnosticInfo
        )

        model.historySearch = "migration"
        XCTAssertEqual(model.filteredHistoryRecords.map(\.id), [terminal.id])

        model.historySearch = "messages"
        XCTAssertEqual(model.filteredHistoryRecords.map(\.id), [messages.id])
    }

    @MainActor
    func testDictionaryEditorProducesNormalizedDictionary() {
        let model = LocalFlowHubModel()
        model.termsText = "Codex\ncodex\nLocalFlow"
        model.replacementsText = "code ex = Codex\nlocal flow = LocalFlow"

        var savedDictionary: PersonalDictionary?
        model.saveDictionaryHandler = {
            savedDictionary = $0
            return .success(())
        }
        model.saveDictionary()

        XCTAssertEqual(savedDictionary?.terms, ["Codex", "LocalFlow"])
        XCTAssertEqual(savedDictionary?.replacements["code ex"], "Codex")
        XCTAssertEqual(savedDictionary?.replacements["local flow"], "LocalFlow")
    }

    private func record(text: String, app: String) -> DictationRecord {
        DictationRecord(
            targetApplication: TargetApplicationInfo(localizedName: app, bundleIdentifier: nil),
            transcribedText: text,
            finalText: text,
            polished: false,
            durationSeconds: 2
        )
    }

    private var diagnosticInfo: LocalFlowDiagnosticInfo {
        LocalFlowDiagnosticInfo(
            hotkeyStatus: "Active",
            lastHotkey: "none",
            accessibilityStatus: "Granted",
            inputMonitoringStatus: "Granted",
            fnGlobeAction: "Do Nothing",
            envPath: "/tmp/.env",
            dictionaryPath: "/tmp/dictionary.json",
            historyPath: "/tmp/history.jsonl",
            localDataPath: "/tmp",
            logPath: "/tmp/localflow.log",
            appPath: "/Applications/LocalFlow.app"
        )
    }
}
