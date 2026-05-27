import Foundation

public struct TargetApplicationInfo: Codable, Equatable, Sendable {
    public var localizedName: String?
    public var bundleIdentifier: String?

    public init(localizedName: String?, bundleIdentifier: String?) {
        self.localizedName = localizedName
        self.bundleIdentifier = bundleIdentifier
    }

    public var displayName: String {
        localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Unknown app"
    }

    public var lowercasedFingerprint: String {
        [localizedName, bundleIdentifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
    }
}

public enum PromptBuilder {
    public static func transcriptionPrompt(
        dictionary: PersonalDictionary,
        targetApplication: TargetApplicationInfo?,
        language: String
    ) -> String {
        var lines: [String] = [
            "Transcribe French speech accurately.",
            "Preserve natural English words, product names, developer tools, and code-related terms used inside French sentences.",
            "Add punctuation only when it is strongly implied by the speech.",
            "Do not translate, summarize, or add content."
        ]

        if let targetApplication {
            lines.append("The user is dictating into \(targetApplication.displayName).")
            lines.append(appHint(for: targetApplication))
        }

        if !dictionary.terms.isEmpty {
            lines.append("Important vocabulary: \(dictionary.promptVocabulary).")
        }

        lines.append("Language hint: \(language).")

        return lines.joined(separator: "\n")
    }

    public static func polishSystemPrompt(targetApplication: TargetApplicationInfo?) -> String {
        var lines: [String] = [
            "You lightly polish dictated French text.",
            "Keep the user's intent, wording, and tone.",
            "Remove obvious filler words and speech artifacts.",
            "Fix punctuation, casing, and small grammar issues.",
            "Return only the final text, with no quotes or explanation."
        ]

        if let targetApplication {
            lines.append(appPolishHint(for: targetApplication))
        }

        return lines.joined(separator: "\n")
    }

    public static func polishUserPrompt(text: String) -> String {
        "Polish this dictated text:\n\n\(text)"
    }

    private static func appHint(for targetApplication: TargetApplicationInfo) -> String {
        let fingerprint = targetApplication.lowercasedFingerprint

        if fingerprint.contains("terminal") || fingerprint.contains("iterm") || fingerprint.contains("codex") {
            return "For terminal or coding-agent prompts, preserve direct instructions, command names, file names, flags, and technical wording."
        }

        if fingerprint.contains("cursor") || fingerprint.contains("xcode") || fingerprint.contains("visual studio") || fingerprint.contains("vscode") {
            return "For coding tools, preserve developer terminology, identifiers, filenames, and mixed French-English phrasing."
        }

        if fingerprint.contains("whatsapp") || fingerprint.contains("telegram") || fingerprint.contains("messages") {
            return "For messaging apps, keep the text conversational and natural."
        }

        return "Use the target app only as light context for punctuation and wording."
    }

    private static func appPolishHint(for targetApplication: TargetApplicationInfo) -> String {
        let fingerprint = targetApplication.lowercasedFingerprint

        if fingerprint.contains("terminal") || fingerprint.contains("iterm") || fingerprint.contains("codex") {
            return "Because the target is a terminal or coding agent, keep the output concise and instruction-like. Do not make it sound like a formal email."
        }

        if fingerprint.contains("whatsapp") || fingerprint.contains("telegram") || fingerprint.contains("messages") {
            return "Because the target is a messaging app, keep a casual spoken style and avoid over-formal wording."
        }

        return "Adapt lightly to the target app without over-rewriting."
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
