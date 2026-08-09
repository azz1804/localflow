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
        XCTAssertTrue(prompt.contains("especially backend, frontend, API"))
        XCTAssertTrue(prompt.contains("never replace them with phonetically similar French words"))
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

        XCTAssertTrue(systemPrompt.contains("Do not answer or execute the request"))
        XCTAssertTrue(systemPrompt.contains("AI receiving this request"))
        XCTAssertTrue(systemPrompt.contains("prompt you would genuinely want to receive"))
        XCTAssertTrue(systemPrompt.contains("useful result on the first attempt"))
        XCTAssertTrue(systemPrompt.contains("State the desired outcome clearly"))
        XCTAssertTrue(systemPrompt.contains("what action is expected"))
        XCTAssertTrue(systemPrompt.contains("where the receiving AI has freedom"))
        XCTAssertTrue(systemPrompt.contains("light technical vocabulary"))
        XCTAssertTrue(systemPrompt.contains("never invent facts, tools, technologies"))
        XCTAssertTrue(systemPrompt.contains("human voice, emotional intensity, priorities"))
        XCTAssertTrue(systemPrompt.contains("Never force a template or fixed headings"))
        XCTAssertTrue(systemPrompt.contains("enough detail to act but no padding"))
        XCTAssertTrue(systemPrompt.contains("translate reported behavior into testable outcomes"))
        XCTAssertTrue(systemPrompt.contains("Do not invent a root cause"))
        XCTAssertTrue(userPrompt.contains("<dictation>"))
        XCTAssertTrue(userPrompt.contains("corrige App.swift"))
    }

    func testMailModeStructuresWithoutInventingAndPreservesTechnicalTerms() {
        let systemPrompt = PromptBuilder.emailModeSystemPrompt(
            targetApplication: TargetApplicationInfo(
                localizedName: "Mail",
                bundleIdentifier: "com.apple.mail"
            ),
            toneIntent: .relaxed
        )
        let userPrompt = PromptBuilder.emailModeUserPrompt(
            text: "salut Thomas le backend plante encore merci"
        )

        XCTAssertTrue(systemPrompt.contains("ready-to-paste email"))
        XCTAssertTrue(systemPrompt.contains("Keep English technical words such as backend exactly"))
        XCTAssertTrue(systemPrompt.contains("Objet :"))
        XCTAssertTrue(systemPrompt.contains("do not invent one"))
        XCTAssertTrue(systemPrompt.contains("natural voice"))
        XCTAssertTrue(systemPrompt.contains("Default to clear, natural, and human rather than corporate"))
        XCTAssertTrue(systemPrompt.contains("relaxed greeting and sign-off"))
        XCTAssertTrue(systemPrompt.contains("Local tone detection found a relaxed request"))
        XCTAssertTrue(systemPrompt.contains("no corporate filler"))
        XCTAssertTrue(userPrompt.contains("<dictation>"))
        XCTAssertTrue(userPrompt.contains("le backend plante encore"))
    }
}
