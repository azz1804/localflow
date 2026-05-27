import Foundation
import XCTest
@testable import LocalFlowCore

final class DictionaryTests: XCTestCase {
    func testDictionaryNormalizesTermsAndKeepsReplacements() {
        let dictionary = PersonalDictionary(
            terms: [" Codex ", "codex", "", "OpenAI"],
            replacements: ["code ex": "Codex", "": "Ignored"]
        )

        XCTAssertEqual(dictionary.terms, ["Codex", "OpenAI"])
        XCTAssertEqual(dictionary.replacements, ["code ex": "Codex"])
        XCTAssertEqual(dictionary.promptVocabulary, "Codex, OpenAI")
    }

    func testReplacementEngineReplacesWholePhrasesCaseInsensitively() {
        let result = ReplacementEngine.apply(
            ["code ex": "Codex", "open ai": "OpenAI"],
            to: "Je parle à code ex et open ai, mais pas à mycode example."
        )

        XCTAssertEqual(result, "Je parle à Codex et OpenAI, mais pas à mycode example.")
    }
}
