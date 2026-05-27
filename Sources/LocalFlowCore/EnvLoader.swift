import Foundation

public enum EnvLoader {
    public static func load(from url: URL) throws -> [String: String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(contents)
    }

    public static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                continue
            }

            value = unquote(value)
            values[key] = value
        }

        return values
    }

    private static func unquote(_ rawValue: String) -> String {
        guard rawValue.count >= 2 else {
            return rawValue
        }

        if rawValue.hasPrefix("\""), rawValue.hasSuffix("\"") {
            let inner = rawValue.dropFirst().dropLast()
            return inner
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }

        if rawValue.hasPrefix("'"), rawValue.hasSuffix("'") {
            return String(rawValue.dropFirst().dropLast())
        }

        return rawValue
    }
}
