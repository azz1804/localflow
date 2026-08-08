import XCTest
@testable import LocalFlowCore

final class PromptBuilderTests: XCTestCase {
    func testTranscriptionPromptIncludesAppHintsAndVocabulary() {
        let prompt = PromptBuilder.transcriptionPrompt(
            dictionary: PersonalDictionary(terms: ["Codex", "Cursor"], replacements: [:]),
            targetApplication: TargetApplicationInfo(localizedName: "Terminal", bundleIdentifier: "com.apple.Terminal"),
            language: "fr"
        )

        XCTAssertTrue(prompt.contains("Transcribe French speech accurately"))
        XCTAssertTrue(prompt.contains("Important vocabulary: Codex, Cursor"))
        XCTAssertTrue(prompt.contains("terminal or coding-agent prompts"))
        XCTAssertTrue(prompt.contains("Language hint: fr"))
    }

    func testPolishPromptForMessagingKeepsCasualStyle() {
        let prompt = PromptBuilder.polishSystemPrompt(
            targetApplication: TargetApplicationInfo(localizedName: "Telegram", bundleIdentifier: "org.telegram.desktop")
        )

        XCTAssertTrue(prompt.contains("casual spoken style"))
        XCTAssertTrue(prompt.contains("Return only the final text"))
    }

    func testPromptModePreservesCodingDetailsWithoutAnswering() {
        let systemPrompt = PromptBuilder.promptModeSystemPrompt(
            targetApplication: TargetApplicationInfo(
                localizedName: "Codex",
                bundleIdentifier: "com.openai.codex"
            )
        )
        let userPrompt = PromptBuilder.promptModeUserPrompt(
            text: "corrige App.swift et lance swift test"
        )

        XCTAssertTrue(systemPrompt.contains("Do not answer the request"))
        XCTAssertTrue(systemPrompt.contains("sent to another AI system"))
        XCTAssertTrue(systemPrompt.contains("Prioritize completeness over brevity"))
        XCTAssertTrue(systemPrompt.contains("Never summarize or shorten detailed material"))
        XCTAssertTrue(systemPrompt.contains("rationale, examples, relationships, dependencies, nuances"))
        XCTAssertTrue(systemPrompt.contains("paths, flags, error messages"))
        XCTAssertTrue(systemPrompt.contains("If the request is already clear"))
        XCTAssertTrue(systemPrompt.contains("human voice, directness, emotional tone, and intensity"))
        XCTAssertTrue(systemPrompt.contains("every stated reason"))
        XCTAssertTrue(systemPrompt.contains("Correct obvious transcription, spelling, grammar"))
        XCTAssertTrue(systemPrompt.contains("when meaning is ambiguous, preserve it rather than guessing"))
        XCTAssertTrue(userPrompt.contains("<dictation>"))
        XCTAssertTrue(userPrompt.contains("corrige App.swift"))
    }
}
