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
    func testInsertingTranscriptUpdatesHistorySelectionAndInsightsImmediately() {
        let older = record(text: "one two", app: "Messages")
        let newest = record(text: "three four five", app: "Terminal")
        let model = LocalFlowHubModel()
        model.update(
            configuration: AppConfiguration(),
            dictionary: .empty,
            historyRecords: [older],
            diagnosticInfo: diagnosticInfo
        )

        model.insertHistoryRecord(newest)

        XCTAssertEqual(model.historyRecords.map(\.id), [newest.id, older.id])
        XCTAssertEqual(model.selectedHistoryID, newest.id)
        XCTAssertEqual(model.insights.totalWords, 5)
        XCTAssertEqual(model.insights.totalDictations, 2)
    }

    @MainActor
    func testInsertingSameTranscriptDoesNotDuplicateHistory() {
        let transcript = record(text: "hello world", app: "Notes")
        let model = LocalFlowHubModel()

        model.insertHistoryRecord(transcript)
        model.insertHistoryRecord(transcript)

        XCTAssertEqual(model.historyRecords.map(\.id), [transcript.id])
        XCTAssertEqual(model.insights.totalDictations, 1)
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

    @MainActor
    func testSelectingOutputModeUpdatesImmediately() {
        let model = LocalFlowHubModel()
        var selectedMode: DictationOutputMode?
        model.outputModeChangeHandler = { mode in
            selectedMode = mode
            return .success(())
        }

        model.selectOutputMode(.prompt)

        XCTAssertEqual(model.configuration.outputMode, .prompt)
        XCTAssertEqual(selectedMode, .prompt)
        XCTAssertEqual(model.statusMessage, "Prompt active")
    }

    @MainActor
    func testSelectingOutputModeRollsBackWhenPersistenceFails() {
        let model = LocalFlowHubModel()
        model.configuration.outputMode = .polish
        model.outputModeChangeHandler = { _ in
            .failure(OutputModeTestError.persistenceFailed)
        }

        model.selectOutputMode(.prompt)

        XCTAssertEqual(model.configuration.outputMode, .polish)
        XCTAssertTrue(model.statusIsError)
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

private enum OutputModeTestError: Error {
    case persistenceFailed
}
