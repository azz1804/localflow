import Foundation
import XCTest
@testable import LocalFlowCore

final class MailModeLiveEvaluationTests: XCTestCase {
    func testExplicitToneCuesProduceDistinctMailStyles() async throws {
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
            localizedName: "Mail",
            bundleIdentifier: "com.apple.mail"
        )
        let samples: [(
            source: String,
            expectedTone: MailToneIntent,
            required: [String],
            forbidden: [String]
        )] = [
            (
                "Fais un mail corpo à Madame Laurent pour lui confirmer que le déploiement du backend aura lieu mardi à 9 heures et qu'on lui enverra un compte rendu après.",
                .formal,
                ["madame laurent", "backend", "mardi", "9", "compte rendu"],
                ["mail corpo"]
            ),
            (
                "Fais un mail tranquille et propre pour Thomas pour lui dire que j'ai regardé son retour sur le design, que je suis d'accord et que je lui envoie une nouvelle version demain.",
                .relaxed,
                ["thomas", "design", "nouvelle version", "demain"],
                ["mail tranquille", "cordialement", "veuillez", "nous vous prions"]
            ),
            (
                "Écris à Léa pour lui dire que j'ai bien reçu les photos, qu'elles sont super et que je lui réponds plus en détail ce week-end.",
                .adaptive,
                ["lea", "photos", "super", "week"],
                ["cordialement", "veuillez", "nous vous prions"]
            )
        ]

        for sample in samples {
            let tone = MailToneRouter.decide(for: sample.source)
            XCTAssertEqual(tone.intent, sample.expectedTone)
            let output = try await client.rewriteAsPrompt(
                text: sample.source,
                model: model,
                systemPrompt: PromptBuilder.emailModeSystemPrompt(
                    targetApplication: target,
                    toneIntent: tone.intent
                ),
                userPrompt: PromptBuilder.emailModeUserPrompt(
                    text: sample.source
                )
            )
            let normalized = output.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "fr_FR")
            ).lowercased()

            print("\n--- MAIL MODE LIVE EVAL [\(tone.intent.rawValue)] ---\n\(output)\n")
            XCTAssertTrue(normalized.contains("objet :"))
            for term in sample.required {
                XCTAssertTrue(
                    normalized.contains(term),
                    "Missing required mail concept: \(term)"
                )
            }
            for term in sample.forbidden {
                XCTAssertFalse(
                    normalized.contains(term),
                    "Mail leaked or contradicted its tone instruction: \(term)"
                )
            }
        }
    }
}
