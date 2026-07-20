import XCTest
@testable import LocalFlowApp

final class TextInsertionServiceTests: XCTestCase {
    func testCapturedEditableFieldSurvivesTransientAccessibilityMiss() {
        let target = TextInsertionTarget(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedState: .editable
        )

        XCTAssertTrue(
            TextInsertionService.shouldPaste(
                accessibilityTrusted: true,
                currentState: .notEditable,
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

    func testCurrentEditableOrUnknownTargetRemainsPasteable() {
        for state in [
            FocusedTextTargetState.editable,
            FocusedTextTargetState.unknown
        ] {
            XCTAssertTrue(
                TextInsertionService.shouldPaste(
                    accessibilityTrusted: true,
                    currentState: state,
                    capturedTarget: nil,
                    currentProcessIdentifier: 42
                )
            )
        }
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

    func testCodexUsesKeyboardPasteFallbackForItsCustomEditor() {
        let target = TextInsertionTarget(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            focusedState: .notEditable
        )

        XCTAssertTrue(
            TextInsertionService.shouldPaste(
                accessibilityTrusted: true,
                currentState: .notEditable,
                capturedTarget: target,
                currentProcessIdentifier: 42
            )
        )
    }
}
