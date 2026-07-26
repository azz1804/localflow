import AppKit
import LocalFlowCore
import XCTest
@testable import LocalFlowApp

final class HotkeyControllerTests: XCTestCase {
    func testFlagsChangedSnapshotNeverQueriesRepeatState() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: [.function],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 63
            )
        )

        let snapshot = try XCTUnwrap(HotkeyEventSnapshot(event: event))

        XCTAssertEqual(snapshot.kind, .flagsChanged)
        XCTAssertFalse(snapshot.isRepeat)
        XCTAssertEqual(snapshot.keyCode, 63)
    }

    func testTogglePressGateRejectsDelayedDuplicateUntilKeyUp() {
        var gate = HotkeyPressGate()

        XCTAssertTrue(gate.begin(at: 10, isRepeat: false))
        XCTAssertFalse(gate.begin(at: 10.4, isRepeat: false))
        XCTAssertFalse(gate.begin(at: 10.5, isRepeat: true))

        gate.end()

        XCTAssertTrue(gate.begin(at: 10.6, isRepeat: false))
    }

    func testTogglePressGateRecoversFromAMissedKeyUp() {
        var gate = HotkeyPressGate()

        XCTAssertTrue(gate.begin(at: 20, isRepeat: false))
        XCTAssertTrue(gate.begin(at: 21.6, isRepeat: false))
    }

    @MainActor
    func testEscapeCancelsAnActiveRecording() {
        XCTAssertTrue(
            HotkeyController.shouldCancelRecordingWithEscape(
                keyCode: 53,
                isRepeat: false,
                recordingIsActive: true
            )
        )
    }

    @MainActor
    func testEscapePassesThroughWhenRecordingIsInactive() {
        XCTAssertFalse(
            HotkeyController.shouldCancelRecordingWithEscape(
                keyCode: 53,
                isRepeat: false,
                recordingIsActive: false
            )
        )
    }

    @MainActor
    func testRepeatedEscapeAndOtherKeysPassThrough() {
        XCTAssertFalse(
            HotkeyController.shouldCancelRecordingWithEscape(
                keyCode: 53,
                isRepeat: true,
                recordingIsActive: true
            )
        )
        XCTAssertFalse(
            HotkeyController.shouldCancelRecordingWithEscape(
                keyCode: 49,
                isRepeat: false,
                recordingIsActive: true
            )
        )
    }

    @MainActor
    func testEscapeUsesLiveDictationStateAfterHotkeyStateWasReset() {
        let controller = HotkeyController(
            holdHotkey: "fn",
            fallbackHoldHotkey: "option+space",
            toggleHotkey: "fn+space"
        )
        var recordingIsActive = true
        var cancellationCount = 0
        controller.recordingCancellationIsAvailable = {
            recordingIsActive
        }
        controller.onCancel = {
            cancellationCount += 1
            recordingIsActive = false
        }

        XCTAssertTrue(
            controller.handleEscapeKeyDown(
                keyCode: 53,
                isRepeat: false,
                source: "test"
            )
        )
        XCTAssertEqual(cancellationCount, 1)

        XCTAssertFalse(
            controller.handleEscapeKeyDown(
                keyCode: 53,
                isRepeat: false,
                source: "test"
            )
        )
        XCTAssertEqual(cancellationCount, 1)
    }

    @MainActor
    func testDuplicateEscapeSourcesCancelOnlyOnceWhileStartIsPending() {
        let controller = HotkeyController(
            holdHotkey: "fn",
            fallbackHoldHotkey: "option+space",
            toggleHotkey: "fn+space"
        )
        var cancellationCount = 0
        controller.recordingCancellationIsAvailable = { true }
        controller.onCancel = {
            cancellationCount += 1
        }

        XCTAssertTrue(
            controller.handleEscapeKeyDown(
                keyCode: 53,
                isRepeat: false,
                source: "escape-cg-key"
            )
        )
        XCTAssertFalse(
            controller.handleEscapeKeyDown(
                keyCode: 53,
                isRepeat: false,
                source: "escape-nsevent-key"
            )
        )
        XCTAssertEqual(cancellationCount, 1)

        controller.clearToggleRecordingState()
        controller.setApplicationRecordingActive(true)
        XCTAssertTrue(
            controller.handleEscapeKeyDown(
                keyCode: 53,
                isRepeat: false,
                source: "next-recording"
            )
        )
        XCTAssertEqual(cancellationCount, 2)
    }

    func testHotkeyRestartIsDeferredUntilRecordingEnds() {
        var coordinator = HotkeyRestartCoordinator()

        XCTAssertFalse(
            coordinator.requestRestart(recordingIsActive: true)
        )
        XCTAssertTrue(coordinator.isRestartDeferred)
        XCTAssertFalse(
            coordinator.consumeDeferredRestart(recordingIsActive: true)
        )
        XCTAssertTrue(
            coordinator.consumeDeferredRestart(recordingIsActive: false)
        )
        XCTAssertFalse(coordinator.isRestartDeferred)
        XCTAssertFalse(
            coordinator.consumeDeferredRestart(recordingIsActive: false)
        )
    }

    @MainActor
    func testEscapeCancelsARecordingBeforeItsStartTaskRuns() async {
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.jsonl")
        let controller = DictationController(
            configuration: AppConfiguration(),
            dictionary: .empty,
            historyStore: HistoryStore(url: historyURL)
        )
        var statuses: [AppStatus] = []
        controller.onStatusChanged = { status, _ in
            statuses.append(status)
        }

        controller.beginHoldRecording()
        XCTAssertTrue(controller.canCancelRecording)
        controller.cancelRecording()
        XCTAssertFalse(controller.canCancelRecording)

        await Task.yield()
        await Task.yield()

        XCTAssertEqual(statuses, [.idle])
        XCTAssertFalse(controller.canCancelRecording)
    }

    @MainActor
    func testReleasingHoldCancelsARecordingBeforeItsStartTaskRuns() async {
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.jsonl")
        let controller = DictationController(
            configuration: AppConfiguration(),
            dictionary: .empty,
            historyStore: HistoryStore(url: historyURL)
        )
        var statuses: [AppStatus] = []
        controller.onStatusChanged = { status, _ in
            statuses.append(status)
        }

        controller.beginHoldRecording()
        XCTAssertTrue(controller.canCancelRecording)
        controller.endHoldRecording()
        XCTAssertFalse(controller.canCancelRecording)

        await Task.yield()
        await Task.yield()

        XCTAssertEqual(statuses, [.idle])
        XCTAssertFalse(controller.canCancelRecording)
    }

    @MainActor
    func testPendingHoldCanLockIntoToggleBeforeRecorderStarts() async {
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.jsonl")
        let controller = DictationController(
            configuration: AppConfiguration(),
            dictionary: .empty,
            historyStore: HistoryStore(url: historyURL)
        )
        var statuses: [AppStatus] = []
        controller.onStatusChanged = { status, _ in
            statuses.append(status)
        }

        controller.beginHoldRecording()
        controller.lockCurrentHoldRecording()

        XCTAssertEqual(statuses, [.recording(0, .toggle)])
        controller.cancelRecording()
        await Task.yield()

        XCTAssertEqual(statuses, [.recording(0, .toggle), .idle])
        XCTAssertFalse(controller.canCancelRecording)

        statuses.removeAll()
        controller.beginHoldRecording()
        controller.endHoldRecording()
        await Task.yield()

        XCTAssertEqual(statuses, [.idle])
        XCTAssertFalse(controller.canCancelRecording)
    }
}
