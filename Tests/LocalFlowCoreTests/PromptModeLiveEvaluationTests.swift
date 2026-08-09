import Foundation
import XCTest
@testable import LocalFlowCore

final class PromptModeLiveEvaluationTests: XCTestCase {
    func testRepresentativeFrenchDictationsProduceActionablePrompts() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALFLOW_RUN_LIVE_OPENAI_EVALS"] == "1",
            "Set LOCALFLOW_RUN_LIVE_OPENAI_EVALS=1 to run paid API evaluations."
        )
        let apiKey = try XCTUnwrap(
            ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        )
        let model = ProcessInfo.processInfo.environment["PROMPT_MODEL"]
            ?? "gpt-5.6-luna"
        let client = OpenAIClient(apiKey: apiKey)
        let target = TargetApplicationInfo(
            localizedName: "Codex",
            bundleIdentifier: "com.openai.codex"
        )
        let samples: [(source: String, requiredTerms: [String])] = [
            (
                "Je veux que tu corriges le bug du backend qui fait parfois perdre le collage automatique. Trouve la vraie cause, garde le comportement actuel des raccourcis et ajoute des tests pour être sûr que ça ne revienne pas.",
                ["backend", "collage automatique", "cause", "raccourcis", "tests"]
            ),
            (
                "L'animation du spectre a encore une latence et ça fait vraiment pas pro. Je veux qu'elle suive ma voix presque instantanément, mais sans trembler pendant les petits silences ni consommer trop de CPU.",
                ["spectre", "latence", "voix", "silences", "cpu", "professionnel"]
            )
        ]

        for sample in samples {
            let source = sample.source
            let output = try await client.rewriteAsPrompt(
                text: source,
                model: model,
                systemPrompt: PromptBuilder.promptModeSystemPrompt(
                    targetApplication: target
                ),
                userPrompt: PromptBuilder.promptModeUserPrompt(text: source)
            )
            let normalized = output.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "fr_FR")
            )

            print("\n--- PROMPT MODE LIVE EVAL ---\n\(output)\n")
            XCTAssertGreaterThan(output.count, source.count)
            XCTAssertLessThan(output.count, source.count * 6)
            for requiredTerm in sample.requiredTerms {
                XCTAssertTrue(
                    normalized.contains(requiredTerm),
                    "Missing required concept: \(requiredTerm)"
                )
            }
            XCTAssertFalse(normalized.contains("en tant qu'expert"))
        }
    }
}
