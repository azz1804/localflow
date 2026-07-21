import XCTest
@testable import LocalFlowApp

final class HotkeyControllerTests: XCTestCase {
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
}
