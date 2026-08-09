import XCTest
@testable import LocalFlowCore

final class MailToneRouterTests: XCTestCase {
    func testDetectsExplicitCorporateTone() {
        let decision = MailToneRouter.decide(
            for: "Fais un mail corpo et formel à Madame Laurent"
        )

        XCTAssertEqual(decision.intent, .formal)
        XCTAssertTrue(decision.matchedCues.contains("mail corpo"))
    }

    func testDetectsRelaxedNaturalTone() {
        let decision = MailToneRouter.decide(
            for: "Fais un mail tranquille et propre pour Thomas, un truc chill et naturel"
        )

        XCTAssertEqual(decision.intent, .relaxed)
        XCTAssertTrue(decision.matchedCues.contains("mail tranquille"))
        XCTAssertTrue(decision.matchedCues.contains("chill"))
    }

    func testNegativeCorporateCueBeatsProfessionalWording() {
        let decision = MailToneRouter.decide(
            for: "Fais un mail professionnel mais pas trop corpo, plutôt simple et propre"
        )

        XCTAssertEqual(decision.intent, .relaxed)
        XCTAssertTrue(decision.matchedCues.contains("pas trop corpo"))
    }

    func testDetectsWarmAndDirectIntent() {
        XCTAssertEqual(
            MailToneRouter.decide(
                for: "Fais un message chaleureux et bienveillant"
            ).intent,
            .warm
        )
        XCTAssertEqual(
            MailToneRouter.decide(
                for: "Fais un mail droit au but et sans blabla"
            ).intent,
            .direct
        )
    }

    func testContentWordDoesNotCreateAFalseToneCue() {
        let decision = MailToneRouter.decide(
            for: "Explique que le produit naturel sera livré vendredi"
        )

        XCTAssertEqual(decision.intent, .adaptive)
        XCTAssertTrue(decision.matchedCues.isEmpty)
    }
}
