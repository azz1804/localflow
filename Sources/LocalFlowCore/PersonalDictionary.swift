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
            let data = try Data(contentsOf: candidate)
            let dictionary = try JSONDecoder().decode(PersonalDictionary.self, from: data)
            return LoadedDictionary(dictionary: dictionary, sourceURL: candidate)
        }

        return LoadedDictionary(dictionary: .empty, sourceURL: nil)
    }

    public static func ensureEditableDictionaryExists(appSupportDirectory: URL, fallback: PersonalDictionary = .empty) throws -> URL {
        let url = appSupportDirectory.appendingPathComponent("dictionary.json")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return url
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(fallback)
        try data.write(to: url, options: .atomic)
        return url
    }
}
