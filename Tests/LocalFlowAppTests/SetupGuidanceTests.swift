import LocalFlowCore
import XCTest
@testable import LocalFlowApp

final class SetupGuidanceTests: XCTestCase {
    @MainActor
    func testAuthenticationFailuresOpenActionableSettings() {
        XCTAssertEqual(
            DictationController.setupGuidance(
                for: OpenAIClientError.badStatus(401, "invalid key")
            ),
            "OpenAI rejected this API key. Replace it in LocalFlow Settings."
        )
        XCTAssertEqual(
            DictationController.setupGuidance(
                for: OpenAIClientError.badStatus(404, "model missing")
            ),
            "The configured OpenAI model is unavailable for this account. Choose an available model in Settings."
        )
    }

    @MainActor
    func testTransientErrorsDoNotStealFocusForSetup() {
        XCTAssertNil(
            DictationController.setupGuidance(
                for: OpenAIClientError.badStatus(503, "unavailable")
            )
        )
        XCTAssertNil(
            DictationController.setupGuidance(
                for: URLError(.notConnectedToInternet)
            )
        )
    }
}
