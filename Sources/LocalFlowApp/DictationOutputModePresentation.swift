import LocalFlowCore

extension DictationOutputMode {
    var displayName: String {
        switch self {
        case .transcript:
            return "Raw mode"
        case .polish:
            return "Lissé"
        case .prompt:
            return "Prompt"
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
        }
    }

    var next: DictationOutputMode {
        switch self {
        case .transcript:
            return .polish
        case .polish:
            return .prompt
        case .prompt:
            return .transcript
        }
    }
}
