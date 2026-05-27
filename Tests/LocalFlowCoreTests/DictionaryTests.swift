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

    func testDictionaryStoreSavesEditableJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlowDictionary-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("dictionary.json")
        let dictionary = PersonalDictionary(
            terms: ["Codex", "Prepstr"],
            replacements: ["code ex": "Codex"]
        )

        try DictionaryStore.save(dictionary, to: url)
        let loaded = try DictionaryStore.load(candidates: [url])

        XCTAssertEqual(loaded.dictionary, dictionary)

        try? FileManager.default.removeItem(at: directory)
    }
}
