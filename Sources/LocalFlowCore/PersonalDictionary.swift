import Foundation

public struct PersonalDictionary: Codable, Equatable, Sendable {
    public var terms: [String]
    public var replacements: [String: String]

    public static let empty = PersonalDictionary(terms: [], replacements: [:])

    public init(terms: [String], replacements: [String: String]) {
        self.terms = Self.normalizedTerms(terms)
        self.replacements = replacements.filter { key, value in
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var promptVocabulary: String {
        terms.joined(separator: ", ")
    }

    private static func normalizedTerms(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            let key = trimmed.lowercased()
            guard !seen.contains(key) else {
                continue
            }

            seen.insert(key)
            normalized.append(trimmed)
        }

        return normalized
    }
}

public struct LoadedDictionary: Equatable, Sendable {
    public var dictionary: PersonalDictionary
    public var sourceURL: URL?
}

public enum DictionaryStore {
    public static func load(candidates: [URL]) throws -> LoadedDictionary {
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            do {
                let data = try Data(contentsOf: candidate)
                let dictionary = try JSONDecoder().decode(
                    PersonalDictionary.self,
                    from: data
                )
                return LoadedDictionary(
                    dictionary: dictionary,
                    sourceURL: candidate
                )
            } catch {
                // Continue to the bundled/default candidate. A broken editable
                // dictionary must not prevent LocalFlow from starting.
                continue
            }
        }

        return LoadedDictionary(dictionary: .empty, sourceURL: nil)
    }

    public static func ensureEditableDictionaryExists(appSupportDirectory: URL, fallback: PersonalDictionary = .empty) throws -> URL {
        let url = appSupportDirectory.appendingPathComponent("dictionary.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                _ = try JSONDecoder().decode(PersonalDictionary.self, from: data)
                // Existing installations may have created this file with the
                // user's default umask. Migrate it to the same private mode as
                // newly-created dictionaries on every launch.
                try setPrivatePermissions(on: url)
                return url
            } catch {
                let recoveryURL = appSupportDirectory.appendingPathComponent(
                    "dictionary.corrupt-\(UUID().uuidString).json"
                )
                try FileManager.default.moveItem(at: url, to: recoveryURL)
                try setPrivatePermissions(on: recoveryURL)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(fallback)
        try data.write(to: url, options: .atomic)
        try setPrivatePermissions(on: url)
        return url
    }

    public static func save(_ dictionary: PersonalDictionary, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dictionary)
        try data.write(to: url, options: .atomic)
        try setPrivatePermissions(on: url)
    }

    private static func setPrivatePermissions(on url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
