import Foundation
import XCTest
@testable import LocalFlowCore

final class DictionaryTests: XCTestCase {
    func testLoadSkipsCorruptCandidateAndUsesNextValidDictionary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let corrupt = directory.appendingPathComponent("corrupt.json")
        let valid = directory.appendingPathComponent("valid.json")
        try Data("not-json".utf8).write(to: corrupt)
        try JSONEncoder().encode(
            PersonalDictionary(terms: ["LocalFlow"], replacements: [:])
        ).write(to: valid)

        let loaded = try DictionaryStore.load(candidates: [corrupt, valid])

        XCTAssertEqual(loaded.sourceURL, valid)
        XCTAssertEqual(loaded.dictionary.terms, ["LocalFlow"])
    }

    func testEnsureEditableDictionaryQuarantinesCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let dictionaryURL = directory.appendingPathComponent("dictionary.json")
        try Data("broken".utf8).write(to: dictionaryURL)

        let result = try DictionaryStore.ensureEditableDictionaryExists(
            appSupportDirectory: directory,
            fallback: PersonalDictionary(terms: ["Recovered"], replacements: [:])
        )

        XCTAssertEqual(result, dictionaryURL)
        let decoded = try JSONDecoder().decode(
            PersonalDictionary.self,
            from: Data(contentsOf: result)
        )
        XCTAssertEqual(decoded.terms, ["Recovered"])
        let recoveredFiles = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter { $0.hasPrefix("dictionary.corrupt-") }
        XCTAssertEqual(recoveredFiles.count, 1)
    }

    func testEnsureEditableDictionaryMigratesExistingFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let dictionaryURL = directory.appendingPathComponent("dictionary.json")
        try DictionaryStore.save(.empty, to: dictionaryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: dictionaryURL.path
        )

        _ = try DictionaryStore.ensureEditableDictionaryExists(
            appSupportDirectory: directory
        )

        let attributes = try FileManager.default.attributesOfItem(
            atPath: dictionaryURL.path
        )
        XCTAssertEqual(
            (attributes[FileAttributeKey.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

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
