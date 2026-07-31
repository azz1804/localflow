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

    func testKeyboardPasteTargetsCapturedProcessWhenItRemainsActive() {
        let target = TextInsertionTarget(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedState: .unknown
        )

        XCTAssertEqual(
            TextInsertionService.keyboardPasteDestination(
                capturedTarget: target,
                currentProcessIdentifier: 42
            ),
            .capturedProcess(42)
        )
    }

    func testKeyboardPasteHasNoDestinationAfterApplicationChanges() {
        let target = TextInsertionTarget(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedState: .unknown
        )

        XCTAssertNil(
            TextInsertionService.keyboardPasteDestination(
                capturedTarget: target,
                currentProcessIdentifier: 84
            )
        )
    }

    func testCapturedTargetWithoutProcessIdentifierHasNoDeliveryDestination() {
        let target = TextInsertionTarget(
            processIdentifier: nil,
            bundleIdentifier: nil,
            focusedState: .editable
        )

        XCTAssertNil(
            TextInsertionService.keyboardPasteDestination(
                capturedTarget: target,
                currentProcessIdentifier: 42
            )
        )
    }

    func testCurrentEditableTargetWithoutCaptureUsesSessionDelivery() {
        XCTAssertEqual(
            TextInsertionService.keyboardPasteDestination(
                capturedTarget: nil,
                currentProcessIdentifier: 42
            ),
            .session
        )
    }

    func testMissingAccessibilityMetricsAreUnavailableNotMismatch() {
        XCTAssertEqual(
            TextInsertionService.keyboardPasteConfirmation(
                focusStillMatches: true,
                expectedCharacterDelta: nil,
                actualCharacterDelta: nil
            ),
            .unavailable
        )
    }

    func testChangedFocusIsMismatchEvenWhenAccessibilityMetricsAreMissing() {
        XCTAssertEqual(
            TextInsertionService.keyboardPasteConfirmation(
                focusStillMatches: false,
                expectedCharacterDelta: nil,
                actualCharacterDelta: nil
            ),
            .mismatch
        )
    }

    func testChangedFocusMakesAvailableMetricsMismatch() {
        XCTAssertEqual(
            TextInsertionService.keyboardPasteConfirmation(
                focusStillMatches: false,
                expectedCharacterDelta: 12,
                actualCharacterDelta: 12
            ),
            .mismatch
        )
    }

    func testMatchingAccessibilityMetricsConfirmKeyboardPaste() {
        XCTAssertEqual(
            TextInsertionService.keyboardPasteConfirmation(
                focusStillMatches: true,
                expectedCharacterDelta: 12,
                actualCharacterDelta: 12
            ),
            .confirmed
        )
    }

    func testTargetedPasteWithoutAccessibilityMetricsReportsPastedAndRetainsClipboard() {
        let resolution = TextInsertionService.keyboardPasteResolution(
            destination: .capturedProcess(42),
            confirmation: .unavailable
        )

        XCTAssertEqual(resolution.outcome, .pasted)
        XCTAssertFalse(resolution.shouldRestoreClipboard)
    }

    func testSessionPasteWithoutAccessibilityMetricsRemainsClipboardOnly() {
        let resolution = TextInsertionService.keyboardPasteResolution(
            destination: .session,
            confirmation: .unavailable
        )

        XCTAssertEqual(resolution.outcome, .copiedToClipboard)
        XCTAssertFalse(resolution.shouldRestoreClipboard)
    }

    func testConfirmedPasteCanRestorePreviousClipboard() {
        let resolution = TextInsertionService.keyboardPasteResolution(
            destination: .capturedProcess(42),
            confirmation: .confirmed
        )

        XCTAssertEqual(resolution.outcome, .pasted)
        XCTAssertTrue(resolution.shouldRestoreClipboard)
    }

    func testMismatchedMetricsKeepTranscriptOnClipboard() {
        let resolution = TextInsertionService.keyboardPasteResolution(
            destination: .capturedProcess(42),
            confirmation: .mismatch
        )

        XCTAssertEqual(resolution.outcome, .copiedToClipboard)
        XCTAssertFalse(resolution.shouldRestoreClipboard)
    }
}
