import Foundation

public struct PromptModeDecision: Equatable, Sendable {
    public enum Route: String, Equatable, Sendable {
        case direct
        case rewriteWithAI
    }

    public enum Reason: String, Equatable, Sendable {
        case empty
        case shortAndClear
        case conciseAndClear
        case selfCorrection
        case speechNeedsCleanup
        case multipleRequirements
        case detailedDictation
    }

    public let route: Route
    public let reason: Reason
    public let wordCount: Int

    public init(route: Route, reason: Reason, wordCount: Int) {
        self.route = route
        self.reason = reason
        self.wordCount = wordCount
    }

    public var shouldUseAI: Bool {
        route == .rewriteWithAI
    }
}

/// Chooses whether Prompt Mode benefits from a model call. The router is kept
/// deterministic so its latency is negligible and its behavior is testable.
public enum PromptModeRouter {
    public static func decide(for text: String) -> PromptModeDecision {
        let analysis = Analysis(text: text)

        guard analysis.wordCount > 0 else {
            return decision(.direct, .empty, analysis)
        }

        // A genuine spoken correction changes the intended request and is
        // worth resolving even when the dictation itself is short.
        if analysis.hasStrongSelfCorrection {
            return decision(.rewriteWithAI, .selfCorrection, analysis)
        }

        // Most commands in this range are already the cheapest, clearest
        // possible prompt. Avoid adding latency and token usage to them.
        if analysis.wordCount <= 10 {
            return decision(.direct, .shortAndClear, analysis)
        }

        if analysis.speechArtifactCount >= 2 {
            return decision(.rewriteWithAI, .speechNeedsCleanup, analysis)
        }

        if analysis.wordCount >= 28 {
            return decision(.rewriteWithAI, .detailedDictation, analysis)
        }

        let complexityScore = analysis.constraintCount
            + analysis.structureCount
            + (analysis.sentenceCount >= 2 ? 1 : 0)
            + (analysis.technicalTokenCount >= 2 ? 1 : 0)

        if complexityScore >= 2 {
            return decision(.rewriteWithAI, .multipleRequirements, analysis)
        }

        // Between 20 and 27 words, a rewrite generally improves framing while
        // still preserving enough source context to avoid invention.
        if analysis.wordCount >= 20 {
            return decision(.rewriteWithAI, .detailedDictation, analysis)
        }

        // Prompt Mode is expected to produce a genuine downstream prompt.
        // Once the dictation is longer than the deliberately cheap 10-word
        // path, a rewrite is useful even when the source already sounds clear.
        return decision(.rewriteWithAI, .conciseAndClear, analysis)
    }

    private static func decision(
        _ route: PromptModeDecision.Route,
        _ reason: PromptModeDecision.Reason,
        _ analysis: Analysis
    ) -> PromptModeDecision {
        PromptModeDecision(
            route: route,
            reason: reason,
            wordCount: analysis.wordCount
        )
    }
}

private extension PromptModeRouter {
    struct Analysis {
        let words: [String]
        let normalizedPhrase: String
        let rawTokens: [Substring]
        let sentenceCount: Int

        init(text: String) {
            let folded = text
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "fr_FR")
                )
                .lowercased()
            words = folded.split { character in
                !character.isLetter && !character.isNumber
            }.map(String.init)
            normalizedPhrase = " " + words.joined(separator: " ") + " "
            rawTokens = text.split(whereSeparator: \Character.isWhitespace)
            sentenceCount = max(
                1,
                text.reduce(into: 0) { count, character in
                    if ".!?\n".contains(character) {
                        count += 1
                    }
                }
            )
        }

        var wordCount: Int {
            words.count
        }

        var hasStrongSelfCorrection: Bool {
            containsAnyPhrase([
                "enfin non",
                "je veux dire",
                "non plutot",
                "ou plutot",
                "attends non",
                "pardon je",
                "je corrige",
                "rectification"
            ])
        }

        var speechArtifactCount: Int {
            occurrenceCount(ofWords: [
                "euh", "heu", "hum", "genre", "voila", "quoi"
            ]) + occurrenceCount(ofPhrases: [
                "du coup", "en fait", "tu vois", "comment dire"
            ])
        }

        var constraintCount: Int {
            min(3, occurrenceCount(ofWords: [
                "contrainte", "contraintes", "objectif", "objectifs",
                "format", "maximum", "minimum", "uniquement", "sans",
                "obligatoire", "obligatoires"
            ]) + occurrenceCount(ofPhrases: [
                "il faut", "je veux", "j aimerais", "fais en sorte",
                "ne doit pas", "n oublie pas", "retourne seulement"
            ]))
        }

        var structureCount: Int {
            min(2, occurrenceCount(ofWords: [
                "premierement", "deuxiemement", "troisiemement", "ensuite",
                "puis", "enfin"
            ]) + occurrenceCount(ofPhrases: [
                "premier point", "deuxieme point", "d abord", "et aussi",
                "d une part", "d autre part"
            ]))
        }

        var technicalTokenCount: Int {
            rawTokens.reduce(into: 0) { count, token in
                let value = String(token)
                if value.contains("/")
                    || value.contains("--")
                    || value.contains("://")
                    || value.range(
                        of: #"\.[A-Za-z0-9]{1,8}\b"#,
                        options: .regularExpression
                    ) != nil {
                    count += 1
                }
            }
        }

        func containsAnyPhrase(_ phrases: [String]) -> Bool {
            phrases.contains { containsPhrase($0) }
        }

        func occurrenceCount(ofWords candidates: Set<String>) -> Int {
            words.reduce(into: 0) { count, word in
                if candidates.contains(word) {
                    count += 1
                }
            }
        }

        func occurrenceCount(ofPhrases phrases: [String]) -> Int {
            phrases.reduce(into: 0) { count, phrase in
                if containsPhrase(phrase) {
                    count += 1
                }
            }
        }

        func containsPhrase(_ phrase: String) -> Bool {
            normalizedPhrase.contains(" \(phrase) ")
        }
    }
}
