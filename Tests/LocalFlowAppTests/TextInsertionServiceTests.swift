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

    func testChangedFocusIsFocusChangedEvenWhenAccessibilityMetricsAreMissing() {
        XCTAssertEqual(
            TextInsertionService.keyboardPasteConfirmation(
                focusStillMatches: false,
                expectedCharacterDelta: nil,
                actualCharacterDelta: nil
            ),
            .focusChanged
        )
    }

    func testChangedFocusMakesAvailableMetricsFocusChanged() {
        XCTAssertEqual(
            TextInsertionService.keyboardPasteConfirmation(
                focusStillMatches: false,
                expectedCharacterDelta: 12,
                actualCharacterDelta: 12
            ),
            .focusChanged
        )
    }

    func testDifferentMetricsAreDeltaMismatch() {
        XCTAssertEqual(
            TextInsertionService.keyboardPasteConfirmation(
                focusStillMatches: true,
                expectedCharacterDelta: 12,
                actualCharacterDelta: 0
            ),
            .deltaMismatch
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

    func testDeltaMismatchKeepsTranscriptOnClipboard() {
        let resolution = TextInsertionService.keyboardPasteResolution(
            destination: .capturedProcess(42),
            confirmation: .deltaMismatch
        )

        XCTAssertEqual(resolution.outcome, .copiedToClipboard)
        XCTAssertFalse(resolution.shouldRestoreClipboard)
    }

    func testFocusChangeKeepsTranscriptOnClipboard() {
        let resolution = TextInsertionService.keyboardPasteResolution(
            destination: .capturedProcess(42),
            confirmation: .focusChanged
        )

        XCTAssertEqual(resolution.outcome, .copiedToClipboard)
        XCTAssertFalse(resolution.shouldRestoreClipboard)
    }

    func testDeltaMismatchRetriesOnce() {
        XCTAssertTrue(
            TextInsertionService.shouldRetryKeyboardPaste(
                confirmation: .deltaMismatch,
                attemptCount: 1
            )
        )
        XCTAssertFalse(
            TextInsertionService.shouldRetryKeyboardPaste(
                confirmation: .deltaMismatch,
                attemptCount: 2
            )
        )
    }

    func testFocusChangeAndUnavailableAndConfirmedNeverRetry() {
        for confirmation: KeyboardPasteConfirmation in [.focusChanged, .unavailable, .confirmed] {
            XCTAssertFalse(
                TextInsertionService.shouldRetryKeyboardPaste(
                    confirmation: confirmation,
                    attemptCount: 1
                )
            )
        }
    }

    func testIdenticalElementsMatchRegardlessOfMetadata() {
        XCTAssertTrue(
            TextInsertionService.focusIdentityMatches(
                identityEqual: true,
                capturedPid: nil,
                currentPid: nil,
                capturedRole: nil,
                currentRole: nil
            )
        )
    }

    func testRegeneratedElementMatchesOnSamePidAndRole() {
        XCTAssertTrue(
            TextInsertionService.focusIdentityMatches(
                identityEqual: false,
                capturedPid: 42,
                currentPid: 42,
                capturedRole: "AXTextArea",
                currentRole: "AXTextArea"
            )
        )
    }

    func testDifferentProcessNeverMatches() {
        XCTAssertFalse(
            TextInsertionService.focusIdentityMatches(
                identityEqual: false,
                capturedPid: 42,
                currentPid: 84,
                capturedRole: "AXTextArea",
                currentRole: "AXTextArea"
            )
        )
    }

    func testDifferentRoleDoesNotMatch() {
        XCTAssertFalse(
            TextInsertionService.focusIdentityMatches(
                identityEqual: false,
                capturedPid: 42,
                currentPid: 42,
                capturedRole: "AXTextArea",
                currentRole: "AXButton"
            )
        )
    }

    func testMissingPidOrRoleDoesNotMatch() {
        XCTAssertFalse(
            TextInsertionService.focusIdentityMatches(
                identityEqual: false,
                capturedPid: nil,
                currentPid: nil,
                capturedRole: "AXTextArea",
                currentRole: "AXTextArea"
            )
        )
        XCTAssertFalse(
            TextInsertionService.focusIdentityMatches(
                identityEqual: false,
                capturedPid: 42,
                currentPid: 42,
                capturedRole: nil,
                currentRole: nil
            )
        )
    }
}
