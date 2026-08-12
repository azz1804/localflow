import XCTest
@testable import LocalFlowApp

final class HandsFreeTargetRestorationTests: XCTestCase {
    func testRestoresExternalTargetWhenLocalFlowIsFrontmost() {
        XCTAssertTrue(
            HandsFreeTargetRestorationPolicy.shouldRestore(
                currentProcessIdentifier: 10,
                localProcessIdentifier: 10,
                candidateProcessIdentifier: 20,
                candidateIsTerminated: false
            )
        )
    }

    func testDoesNotStealFocusFromCurrentExternalApplication() {
        XCTAssertFalse(
            HandsFreeTargetRestorationPolicy.shouldRestore(
                currentProcessIdentifier: 30,
                localProcessIdentifier: 10,
                candidateProcessIdentifier: 20,
                candidateIsTerminated: false
            )
        )
    }

    func testDoesNotRestoreTerminatedOrLocalCandidate() {
        XCTAssertFalse(
            HandsFreeTargetRestorationPolicy.shouldRestore(
                currentProcessIdentifier: 10,
                localProcessIdentifier: 10,
                candidateProcessIdentifier: 20,
                candidateIsTerminated: true
            )
        )
        XCTAssertFalse(
            HandsFreeTargetRestorationPolicy.shouldRestore(
                currentProcessIdentifier: 10,
                localProcessIdentifier: 10,
                candidateProcessIdentifier: 10,
                candidateIsTerminated: false
            )
        )
    }
}
