import XCTest
@testable import LocalFlowApp

final class TextInsertionServiceTests: XCTestCase {
    func testCapturedApplicationSurvivesTransientAccessibilityMiss() {
        let target = TextInsertionTarget(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedState: .unknown
        )

        XCTAssertTrue(
            TextInsertionService.shouldPaste(
                accessibilityTrusted: true,
                currentState: .unknown,
                capturedTarget: target,
                currentProcessIdentifier: 42
            )
        )
    }

    func testCapturedFieldDoesNotPasteIntoAnotherApplication() {
        let target = TextInsertionTarget(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedState: .editable
        )

        XCTAssertFalse(
            TextInsertionService.shouldPaste(
                accessibilityTrusted: true,
                currentState: .notEditable,
                capturedTarget: target,
                currentProcessIdentifier: 84
            )
        )
    }

    func testCurrentEditableTargetRemainsPasteableWithoutCapture() {
        XCTAssertTrue(
            TextInsertionService.shouldPaste(
                accessibilityTrusted: true,
                currentState: .editable,
                capturedTarget: nil,
                currentProcessIdentifier: 42
            )
        )
    }

    func testUnknownTargetWithoutCapturedApplicationStaysClipboardOnly() {
        XCTAssertFalse(
            TextInsertionService.shouldPaste(
                accessibilityTrusted: true,
                currentState: .unknown,
                capturedTarget: nil,
                currentProcessIdentifier: 42
            )
        )
    }

    func testAccessibilityPermissionIsStillRequiredForPaste() {
        XCTAssertFalse(
            TextInsertionService.shouldPaste(
                accessibilityTrusted: false,
                currentState: .editable,
                capturedTarget: nil,
                currentProcessIdentifier: 42
            )
        )
    }

    func testAnyCapturedApplicationUsesKeyboardPasteFallbackForCustomEditor() {
        let target = TextInsertionTarget(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            focusedState: .unknown
        )

        XCTAssertTrue(
            TextInsertionService.shouldPaste(
                accessibilityTrusted: true,
                currentState: .unknown,
                capturedTarget: target,
                currentProcessIdentifier: 42
            )
        )
    }

    func testResolvedNonEditableTargetDoesNotReceiveAutomaticPaste() {
        let target = TextInsertionTarget(
            processIdentifier: 42,
            bundleIdentifier: "com.example.app",
            focusedState: .notEditable
        )

        XCTAssertFalse(
            TextInsertionService.shouldPaste(
                accessibilityTrusted: true,
                currentState: .notEditable,
                capturedTarget: target,
                currentProcessIdentifier: 42
            )
        )
    }

    func testSecureTargetNeverReceivesAutomaticPaste() {
        let target = TextInsertionTarget(
            processIdentifier: 42,
            bundleIdentifier: "com.example.password-manager",
            focusedState: .secure
        )

        XCTAssertFalse(
            TextInsertionService.shouldPaste(
                accessibilityTrusted: true,
                currentState: .secure,
                capturedTarget: target,
                currentProcessIdentifier: 42
            )
        )
    }
}
