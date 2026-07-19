import XCTest
@testable import LocalFlowApp

final class HotkeyControllerTests: XCTestCase {
    @MainActor
    func testEscapeStopsAnActiveToggleRecording() {
        XCTAssertTrue(
            HotkeyController.shouldStopToggleRecordingWithEscape(
                keyCode: 53,
                isRepeat: false,
                toggleRecordingIsActive: true
            )
        )
    }

    @MainActor
    func testEscapePassesThroughWhenToggleRecordingIsInactive() {
        XCTAssertFalse(
            HotkeyController.shouldStopToggleRecordingWithEscape(
                keyCode: 53,
                isRepeat: false,
                toggleRecordingIsActive: false
            )
        )
    }

    @MainActor
    func testRepeatedEscapeAndOtherKeysPassThrough() {
        XCTAssertFalse(
            HotkeyController.shouldStopToggleRecordingWithEscape(
                keyCode: 53,
                isRepeat: true,
                toggleRecordingIsActive: true
            )
        )
        XCTAssertFalse(
            HotkeyController.shouldStopToggleRecordingWithEscape(
                keyCode: 49,
                isRepeat: false,
                toggleRecordingIsActive: true
            )
        )
    }
}
