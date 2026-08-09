import LocalFlowCore

extension DictationOutputMode {
    static let selectableModes: [DictationOutputMode] = [
        .transcript,
        .prompt,
        .email
    ]

    var displayName: String {
        switch self {
        case .transcript:
            return "Raw mode"
        case .polish:
            return "Lissé (ancien)"
        case .prompt:
            return "Prompt"
        case .email:
            return "Mail"
        }
    }

    var systemSymbolName: String {
        switch self {
        case .transcript:
            return "text.quote"
        case .polish:
            return "wand.and.stars"
        case .prompt:
            return "sparkles"
        case .email:
            return "envelope.fill"
        }
    }

    var compactDisplayName: String {
        switch self {
        case .transcript:
            return "Raw"
        case .polish:
            return "Lissé"
        case .prompt:
            return "Prompt"
        case .email:
            return "Mail"
        }
    }

    var next: DictationOutputMode {
        switch self {
        case .transcript:
            return .prompt
        case .prompt:
            return .email
        case .email, .polish:
            return .transcript
        }
    }
}
