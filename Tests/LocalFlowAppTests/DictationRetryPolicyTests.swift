import Foundation
import XCTest
@testable import LocalFlowApp
@testable import LocalFlowCore

final class DictationRetryPolicyTests: XCTestCase {
    func testPendingRecoveryBacksOffAfterRepeatedNetworkFailures() {
        XCTAssertEqual(PendingRecoveryRetryPolicy.delay(afterConsecutiveFailures: 1), 30)
        XCTAssertEqual(PendingRecoveryRetryPolicy.delay(afterConsecutiveFailures: 2), 60)
        XCTAssertEqual(PendingRecoveryRetryPolicy.delay(afterConsecutiveFailures: 3), 120)
        XCTAssertEqual(PendingRecoveryRetryPolicy.delay(afterConsecutiveFailures: 4), 240)
        XCTAssertEqual(PendingRecoveryRetryPolicy.delay(afterConsecutiveFailures: 5), 300)
        XCTAssertEqual(PendingRecoveryRetryPolicy.delay(afterConsecutiveFailures: 9), 300)
    }

    func testPendingRecoveryRunsShortlyAfterADictationSucceeds() {
        XCTAssertEqual(PendingRecoveryRetryPolicy.delayAfterSuccessfulDictation, 5)
    }

    @MainActor
    func testTransientNetworkFailureMessageExplainsTheBackgroundRetry() {
        let message = DictationController.failureMessage(for: URLError(.timedOut))

        XCTAssertTrue(message.hasPrefix("Network problem:"), message)
        XCTAssertTrue(message.contains("retried in the background"), message)
        XCTAssertTrue(message.contains("History"), message)
    }

    @MainActor
    func testOtherFailuresKeepTheirOwnDescription() {
        let message = DictationController.failureMessage(
            for: OpenAIClientError.badStatus(500, "boom")
        )

        XCTAssertTrue(message.hasPrefix("OpenAI request failed (HTTP 500)"), message)
        XCTAssertTrue(message.hasSuffix("The dictation was saved for retry."), message)
    }

    @MainActor
    func testErrorsStayVisibleLongerThanSuccesses() {
        XCTAssertEqual(
            FloatingBarController.dismissDelay(for: .done("texte", .pasted)),
            1.2
        )
        XCTAssertEqual(FloatingBarController.dismissDelay(for: .error("oops")), 4)
        XCTAssertNil(FloatingBarController.dismissDelay(for: .processing))
        XCTAssertNil(FloatingBarController.dismissDelay(for: .idle))
    }
}
