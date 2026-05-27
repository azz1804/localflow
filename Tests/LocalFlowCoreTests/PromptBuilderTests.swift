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
}
