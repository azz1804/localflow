import XCTest
@testable import LocalFlowCore

final class PromptModeRouterTests: XCTestCase {
    func testShortClearRequestSkipsAI() {
        let decision = PromptModeRouter.decide(
            for: "Résume ce document en cinq points"
        )

        XCTAssertEqual(decision.route, .direct)
        XCTAssertEqual(decision.reason, .shortAndClear)
        XCTAssertEqual(decision.wordCount, 6)
    }

    func testShortTechnicalRequestStillSkipsAI() {
        let decision = PromptModeRouter.decide(
            for: "Corrige App.swift puis lance swift test"
        )

        XCTAssertEqual(decision.route, .direct)
        XCTAssertEqual(decision.reason, .shortAndClear)
    }

    func testShortSelfCorrectionUsesAI() {
        let decision = PromptModeRouter.decide(
            for: "Euh corrige, enfin non, supprime le bug audio"
        )

        XCTAssertEqual(decision.route, .rewriteWithAI)
        XCTAssertEqual(decision.reason, .selfCorrection)
    }

    func testRepeatedSpeechArtifactsUseAI() {
        let decision = PromptModeRouter.decide(
            for: "En fait le rendu est genre trop froid et je veux garder mon ton naturel"
        )

        XCTAssertEqual(decision.route, .rewriteWithAI)
        XCTAssertEqual(decision.reason, .speechNeedsCleanup)
    }

    func testMultipleRequirementsUseAI() {
        let decision = PromptModeRouter.decide(
            for: "Je veux une réponse sans jargon et aussi un tableau avec les trois risques principaux"
        )

        XCTAssertEqual(decision.route, .rewriteWithAI)
        XCTAssertEqual(decision.reason, .multipleRequirements)
    }

    func testDetailedDictationUsesAI() {
        let decision = PromptModeRouter.decide(
            for: "Analyse le problème de collage automatique dans toutes les zones de texte, conserve le presse-papiers existant, explique la cause précise et ajoute des tests qui couvrent les applications lentes avant de construire la version finale."
        )

        XCTAssertEqual(decision.route, .rewriteWithAI)
        XCTAssertEqual(decision.reason, .detailedDictation)
        XCTAssertGreaterThanOrEqual(decision.wordCount, 28)
    }

    func testConciseNaturalRequestSkipsAI() {
        let decision = PromptModeRouter.decide(
            for: "Explique pourquoi cette animation donne une impression de latence quand je parle"
        )

        XCTAssertEqual(decision.route, .direct)
        XCTAssertEqual(decision.reason, .conciseAndClear)
    }

    func testEmptyTextSkipsAI() {
        let decision = PromptModeRouter.decide(for: "  \n ")

        XCTAssertEqual(decision.route, .direct)
        XCTAssertEqual(decision.reason, .empty)
        XCTAssertEqual(decision.wordCount, 0)
    }
}
