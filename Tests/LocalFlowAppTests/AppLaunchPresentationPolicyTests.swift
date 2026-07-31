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
                ],
                arguments: ["LocalFlow"]
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
                ],
                arguments: ["LocalFlow"]
            )
        )
    }

    func testExplicitDashboardArgumentOverridesBackgroundLaunch() {
        XCTAssertTrue(
            AppLaunchPresentationPolicy.shouldOpenMainWindow(
                userInfo: [
                    NSApplication.launchIsDefaultUserInfoKey: NSNumber(
                        value: false
                    )
                ],
                arguments: ["LocalFlow", "--show-dashboard"]
            )
        )
    }

    func testMissingLaunchHintPreservesDashboardBehavior() {
        XCTAssertTrue(
            AppLaunchPresentationPolicy.shouldOpenMainWindow(
                userInfo: nil,
                arguments: ["LocalFlow"]
            )
        )
    }

    func testDashboardActivationRequestSurvivesAnEarlyNotification() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let requestURL = directory
            .appendingPathComponent("show-dashboard.request")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(
            LocalFlowActivationSignal.persistDashboardRequest(at: requestURL)
        )
        XCTAssertTrue(
            LocalFlowActivationSignal.consumeDashboardRequest(at: requestURL)
        )
        XCTAssertFalse(
            LocalFlowActivationSignal.consumeDashboardRequest(at: requestURL)
        )
    }
}
