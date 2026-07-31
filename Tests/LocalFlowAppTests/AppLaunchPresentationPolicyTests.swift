import AppKit
import XCTest
@testable import LocalFlowApp

@MainActor
final class AppLaunchPresentationPolicyTests: XCTestCase {
    func testDefaultLaunchOpensDashboard() {
        XCTAssertTrue(
            AppLaunchPresentationPolicy.shouldOpenMainWindow(
                userInfo: [
                    NSApplication.launchIsDefaultUserInfoKey: NSNumber(
                        value: true
                    )
                ]
            )
        )
    }

    func testBackgroundLaunchStaysInMenuBar() {
        XCTAssertFalse(
            AppLaunchPresentationPolicy.shouldOpenMainWindow(
                userInfo: [
                    NSApplication.launchIsDefaultUserInfoKey: NSNumber(
                        value: false
                    )
                ]
            )
        )
    }

    func testMissingLaunchHintPreservesDashboardBehavior() {
        XCTAssertTrue(
            AppLaunchPresentationPolicy.shouldOpenMainWindow(userInfo: nil)
        )
    }
}
