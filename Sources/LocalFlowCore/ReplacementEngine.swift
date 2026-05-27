import Foundation

public enum ReplacementEngine {
    public static func apply(_ replacements: [String: String], to input: String) -> String {
        var result = input

        for (source, target) in replacements.sorted(by: { $0.key.count > $1.key.count }) {
            let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSource.isEmpty else {
                continue
            }

            result = replaceWholePhrase(trimmedSource, with: target, in: result)
        }

        return result
    }

    private static func replaceWholePhrase(_ phrase: String, with replacement: String, in input: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = #"(?i)(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }

        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
    }
}
