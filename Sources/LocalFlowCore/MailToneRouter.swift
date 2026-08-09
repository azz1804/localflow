import Foundation

public enum MailToneIntent: String, Codable, Equatable, Sendable {
    case adaptive
    case formal
    case relaxed
    case warm
    case direct
}

public struct MailToneDecision: Equatable, Sendable {
    public let intent: MailToneIntent
    public let matchedCues: [String]

    public init(intent: MailToneIntent, matchedCues: [String]) {
        self.intent = intent
        self.matchedCues = matchedCues
    }
}

/// Detects explicit drafting cues before the Mail Mode model call. The model
/// still interprets the full dictation, while this fast deterministic hint
/// prevents a generic corporate tone from winning by default.
public enum MailToneRouter {
    public static func decide(for text: String) -> MailToneDecision {
        let phrase = normalized(text)
        let cueGroups: [(MailToneIntent, [(String, Int)])] = [
            (
                .formal,
                [
                    ("mail corpo", 5), ("email corpo", 5),
                    ("ton corpo", 4), ("style corpo", 4),
                    ("corporate", 4), ("tres professionnel", 3),
                    ("mail professionnel", 4), ("email professionnel", 4),
                    ("ton professionnel", 3),
                    ("professionnel et formel", 4), ("formel", 2),
                    ("officiel", 2), ("institutionnel", 3),
                    ("soutenu", 2)
                ]
            ),
            (
                .relaxed,
                [
                    ("mail tranquille", 5), ("email tranquille", 5),
                    ("tranquille et propre", 4), ("chill", 4),
                    ("decontracte", 4), ("pas trop corpo", 5),
                    ("pas trop corporate", 5), ("pas trop formel", 5),
                    ("sans etre trop formel", 5),
                    ("mail naturel", 3), ("email naturel", 3),
                    ("ton naturel", 3), ("style naturel", 3),
                    ("de maniere naturelle", 3),
                    ("simple et propre", 3), ("informel", 3),
                    ("cool", 2)
                ]
            ),
            (
                .warm,
                [
                    ("chaleureux", 4), ("amical", 4),
                    ("bienveillant", 3), ("sympa", 3),
                    ("attentionne", 3), ("ton humain", 3),
                    ("mail humain", 3)
                ]
            ),
            (
                .direct,
                [
                    ("droit au but", 5), ("sans blabla", 5),
                    ("sans bla bla", 5), ("cash", 4),
                    ("tres direct", 4), ("mail direct", 3),
                    ("ton direct", 3), ("sois direct", 3),
                    ("concis", 3), ("mail court", 3),
                    ("message court", 3), ("fais court", 3)
                ]
            )
        ]

        let scores = cueGroups.map { intent, cues -> (MailToneIntent, Int, [String]) in
            let matches = cues.filter { contains($0.0, in: phrase) }
            return (
                intent,
                matches.reduce(0) { $0 + $1.1 },
                matches.map(\.0)
            )
        }
        guard let highestScore = scores.map(\.1).max(), highestScore > 0 else {
            return MailToneDecision(intent: .adaptive, matchedCues: [])
        }

        let winners = scores.filter { $0.1 == highestScore }
        guard winners.count == 1, let winner = winners.first else {
            return MailToneDecision(
                intent: .adaptive,
                matchedCues: winners.flatMap(\.2)
            )
        }
        return MailToneDecision(
            intent: winner.0,
            matchedCues: winner.2
        )
    }

    private static func normalized(_ text: String) -> String {
        let words = text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "fr_FR")
            )
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
        return " " + words.joined(separator: " ") + " "
    }

    private static func contains(_ cue: String, in phrase: String) -> Bool {
        phrase.contains(" \(cue) ")
    }
}
