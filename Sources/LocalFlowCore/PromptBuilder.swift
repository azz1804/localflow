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
            "Transcribe common technical words exactly as spoken, especially backend, frontend, API, database, framework, repository, server, client, deploy, build, and bug; never replace them with phonetically similar French words.",
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

    public static func promptModeSystemPrompt(
        targetApplication: TargetApplicationInfo?
    ) -> String {
        var lines: [String] = [
            "Rewrite the dictation as a self-contained, immediately usable prompt addressed to another AI system.",
            "Lead with the concrete outcome the user wants. Then make the request operational: explain the relevant context, what should be done, the important constraints, and what a successful result should look like.",
            "Preserve every meaningful fact, reason, example, relationship, dependency, nuance, proper name, URL, filename, technical term, requested deliverable, and explicit limitation from the dictation.",
            "Use precise, domain-appropriate vocabulary when it makes the request clearer. Translate vague spoken wording into lightly technical, actionable language, but do not add buzzwords, unnecessary architecture, or expertise theater.",
            "You may make a directly implied requirement explicit when it is necessary to execute the request, but never invent facts, tools, technologies, causes, metrics, deadlines, or product decisions.",
            "Write in the same language as the dictation. For a request with several requirements, use localized headings for only the useful sections among: Objective, Context, Requirements, Constraints, and Expected result. Keep sections compact, concrete, and free of repetition. For a simple request, use one clear paragraph instead.",
            "Turn subjective feedback into observable direction without flattening it. Preserve the user's human voice, emotional intensity, priorities, and every stated reason, while removing filler, false starts, and genuine repetition.",
            "Correct obvious transcription, spelling, grammar, punctuation, and awkward-wording errors when the intended meaning is clear. Keep uncertain wording or unfamiliar technical terms rather than guessing a replacement.",
            "The result must contain enough detail for the receiving AI to act without rediscovering the user's intent, but no generic padding, redundant summary, fake acceptance criteria, or over-engineered specification.",
            "Do not answer or execute the request. Return only the finished prompt, without quotes, preamble, analysis, or commentary."
        ]

        if let targetApplication {
            lines.append(appPromptModeHint(for: targetApplication))
        }

        return lines.joined(separator: "\n")
    }

    public static func promptModeUserPrompt(text: String) -> String {
        """
        <dictation>
        \(text)
        </dictation>
        """
    }

    public static func emailModeSystemPrompt(
        targetApplication: TargetApplicationInfo?
    ) -> String {
        var lines: [String] = [
            "Turn the dictated source into a ready-to-paste email in the user's language.",
            "Preserve every fact, name, request, reason, technical term, and deliberate emotional nuance. Keep English technical words such as backend exactly; never replace an unfamiliar term with a guessed phrase.",
            "Correct only clear transcription, grammar, and punctuation errors. If wording is uncertain, preserve it rather than inventing or guessing.",
            "Keep the user's natural voice and intended level of formality instead of making every email corporate or overly polite.",
            "Return a concise subject line beginning with 'Objet :', then an appropriate greeting, short readable paragraphs, and a natural closing. If no recipient or sender name is provided, do not invent one.",
            "Do not answer the email, add facts, promises, dates, recipients, or requests that were not dictated.",
            "Return only the finished email."
        ]

        if let targetApplication {
            lines.append(
                "The email will be pasted into \(targetApplication.displayName); use that only as light context."
            )
        }

        return lines.joined(separator: "\n")
    }

    public static func emailModeUserPrompt(text: String) -> String {
        """
        <dictation>
        \(text)
        </dictation>
        """
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

    private static func appPromptModeHint(
        for targetApplication: TargetApplicationInfo
    ) -> String {
        let fingerprint = targetApplication.lowercasedFingerprint

        if fingerprint.contains("terminal")
            || fingerprint.contains("iterm")
            || fingerprint.contains("codex")
            || fingerprint.contains("cursor")
            || fingerprint.contains("xcode")
            || fingerprint.contains("visual studio")
            || fingerprint.contains("vscode") {
            return "The target is a coding tool or agent: use natural engineering language, preserve commands, identifiers, paths, flags, and error messages exactly, and translate reported behavior into testable outcomes when the dictation supports them. Do not invent a root cause, architecture, library, or filename."
        }

        return "The prompt will be pasted into \(targetApplication.displayName); use that only as light context and never assume capabilities the target may not have."
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
