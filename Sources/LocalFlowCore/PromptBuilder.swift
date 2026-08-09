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
            "Imagine you are the AI receiving this request. Rewrite the dictation into the prompt you would genuinely want to receive to understand the user correctly and produce a useful result on the first attempt.",
            "State the desired outcome clearly and include the context that materially changes how the request should be handled. Make clear what action is expected, what matters most, what must be preserved, where the receiving AI has freedom, and what would make the result useful whenever the dictation supports those points.",
            "Preserve every meaningful fact, reason, example, relationship, nuance, proper name, URL, filename, technical term, requested deliverable, explicit limitation, and uncertainty from the dictation.",
            "Use precise, natural, domain-appropriate language. Turn vague spoken phrasing into actionable wording and use light technical vocabulary when it clarifies the task, without adding buzzwords, unnecessary architecture, generic best practices, or expertise theater.",
            "You may make a strongly implied relationship explicit when the receiving AI needs it to understand the request, but never invent facts, tools, technologies, root causes, metrics, deadlines, decisions, or constraints.",
            "Write in the same language as the dictation and preserve the user's human voice, emotional intensity, priorities, and stated reasons. Remove only filler, false starts, speech artifacts, and genuine repetition.",
            "Choose the structure the receiving AI would find easiest to use. Never force a template or fixed headings: keep a simple request as natural prose, and use short paragraphs or bullets only when they materially improve a more complex request.",
            "Correct obvious transcription, spelling, grammar, punctuation, and awkward-wording errors when the intended meaning is clear. Preserve uncertain wording or unfamiliar technical terms rather than guessing a replacement.",
            "Do not answer or execute the request. Return only the finished downstream prompt, with enough detail to act but no padding, preamble, analysis, commentary, or invented content."
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
        targetApplication: TargetApplicationInfo?,
        toneIntent: MailToneIntent = .adaptive
    ) -> String {
        var lines: [String] = [
            "Turn the dictated source into a ready-to-paste email in the user's language.",
            "First infer the intended relationship and tone from the user's wording. Treat phrases about how to write the email, such as corporate, formal, professional, chill, relaxed, natural, warm, friendly, direct, or concise, as drafting instructions; do not include those instructions as message content.",
            "Explicit tone cues take priority. Corporate or formal means measured, polished, and appropriately formal. Chill, relaxed, tranquille, or natural means simple, fluid, human wording with a relaxed greeting and sign-off. Warm or friendly means personal and considerate. Direct or concise means brief and straight to the point.",
            "When no tone is requested, infer it from the recipient, purpose, and wording. Default to clear, natural, and human rather than corporate. Never make an email formal merely because it is an email.",
            "Preserve every fact, name, request, reason, technical term, and deliberate emotional nuance. Keep English technical words such as backend exactly; never replace an unfamiliar term with a guessed phrase.",
            "Correct only clear transcription, grammar, and punctuation errors. If wording is uncertain, preserve it rather than inventing or guessing.",
            "Keep the user's natural voice. Match sentence length, vocabulary, greeting, and sign-off to the inferred tone; avoid stock corporate phrases unless a formal style is actually requested.",
            "Return a concise subject line beginning with 'Objet :', then a tone-appropriate greeting, short readable paragraphs, and a matching closing. If no recipient or sender name is provided, do not invent one.",
            "Do not answer the email, add facts, promises, dates, recipients, or requests that were not dictated.",
            "Return only the finished email."
        ]

        lines.append(mailToneInstruction(for: toneIntent))

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

    private static func mailToneInstruction(
        for intent: MailToneIntent
    ) -> String {
        switch intent {
        case .adaptive:
            return "Local tone detection found no single dominant explicit cue. Interpret the full dictation semantically and choose the least formal tone that fits the relationship and purpose."
        case .formal:
            return "Local tone detection found a formal or corporate request. Use professional vocabulary, measured phrasing, respectful address, and a formal closing without becoming stiff or inflated."
        case .relaxed:
            return "Local tone detection found a relaxed request. Write like a thoughtful person speaking naturally: simple fluid sentences, a casual but clean greeting and sign-off, no administrative stiffness, and no corporate filler."
        case .warm:
            return "Local tone detection found a warm request. Sound personal, considerate, and sincere, while staying clear and avoiding exaggerated sentiment."
        case .direct:
            return "Local tone detection found a direct request. Get to the point quickly, keep only useful context, and use a brief natural closing."
        }
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
