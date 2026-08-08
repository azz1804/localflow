import Foundation

public struct AppConfiguration: Equatable, Sendable {
    public var openAIAPIKey: String?
    public var transcriptionModel: String
    public var transcriptionLanguage: String
    public var enablePolish: Bool
    public var polishModel: String
    public var holdHotkey: String
    public var fallbackHoldHotkey: String
    public var toggleHotkey: String
    public var historyRetentionDays: Int
    public var restoreClipboardAfterPaste: Bool
    public var pasteRestoreDelayMilliseconds: Int
    public var orbThemeOverride: String
    public var preferBuiltInMicrophoneForBluetooth: Bool

    public var isOpenAIConfigured: Bool {
        guard let openAIAPIKey else {
            return false
        }

        return !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && openAIAPIKey != "sk-your-key"
    }

    public init(
        openAIAPIKey: String? = nil,
        transcriptionModel: String = "gpt-4o-mini-transcribe",
        transcriptionLanguage: String = "fr",
        enablePolish: Bool = false,
        polishModel: String = "gpt-4o-mini",
        holdHotkey: String = "fn",
        fallbackHoldHotkey: String = "option+space",
        toggleHotkey: String = "fn+space",
        historyRetentionDays: Int = 0,
        restoreClipboardAfterPaste: Bool = true,
        pasteRestoreDelayMilliseconds: Int = 900,
        orbThemeOverride: String = "automatic",
        preferBuiltInMicrophoneForBluetooth: Bool = true
    ) {
        self.openAIAPIKey = openAIAPIKey
        self.transcriptionModel = transcriptionModel
        self.transcriptionLanguage = transcriptionLanguage
        self.enablePolish = enablePolish
        self.polishModel = polishModel
        self.holdHotkey = holdHotkey
        self.fallbackHoldHotkey = fallbackHoldHotkey
        self.toggleHotkey = toggleHotkey
        self.historyRetentionDays = max(0, historyRetentionDays)
        self.restoreClipboardAfterPaste = restoreClipboardAfterPaste
        self.pasteRestoreDelayMilliseconds = pasteRestoreDelayMilliseconds
        self.orbThemeOverride = orbThemeOverride
        self.preferBuiltInMicrophoneForBluetooth = preferBuiltInMicrophoneForBluetooth
    }

    public init(env: [String: String]) {
        self.init(
            openAIAPIKey: env["OPENAI_API_KEY"],
            transcriptionModel: env["TRANSCRIPTION_MODEL"]?.nonEmpty ?? "gpt-4o-mini-transcribe",
            transcriptionLanguage: env["TRANSCRIPTION_LANGUAGE"]?.nonEmpty ?? "fr",
            enablePolish: Self.boolValue(env["ENABLE_POLISH"], default: false),
            polishModel: env["POLISH_MODEL"]?.nonEmpty ?? "gpt-4o-mini",
            holdHotkey: env["HOLD_HOTKEY"]?.nonEmpty ?? "fn",
            fallbackHoldHotkey: env["FALLBACK_HOLD_HOTKEY"]?.nonEmpty ?? "option+space",
            toggleHotkey: env["TOGGLE_HOTKEY"]?.nonEmpty ?? "fn+space",
            historyRetentionDays: Self.intValue(env["HISTORY_RETENTION_DAYS"], default: 0),
            restoreClipboardAfterPaste: Self.boolValue(env["RESTORE_CLIPBOARD_AFTER_PASTE"], default: true),
            pasteRestoreDelayMilliseconds: Self.intValue(env["PASTE_RESTORE_DELAY_MS"], default: 900),
            orbThemeOverride: env["ORB_THEME"]?.nonEmpty ?? "automatic",
            preferBuiltInMicrophoneForBluetooth: Self.boolValue(
                env["PREFER_BUILT_IN_MIC_FOR_BLUETOOTH"],
                default: true
            )
        )
    }

    public func envFileContents() -> String {
        let values: [(String, String)] = [
            ("OPENAI_API_KEY", openAIAPIKey ?? ""),
            ("TRANSCRIPTION_MODEL", transcriptionModel),
            ("TRANSCRIPTION_LANGUAGE", transcriptionLanguage),
            ("ENABLE_POLISH", enablePolish ? "true" : "false"),
            ("POLISH_MODEL", polishModel),
            ("HOLD_HOTKEY", holdHotkey),
            ("FALLBACK_HOLD_HOTKEY", fallbackHoldHotkey),
            ("TOGGLE_HOTKEY", toggleHotkey),
            ("HISTORY_RETENTION_DAYS", String(historyRetentionDays)),
            ("RESTORE_CLIPBOARD_AFTER_PASTE", restoreClipboardAfterPaste ? "true" : "false"),
            ("PASTE_RESTORE_DELAY_MS", String(pasteRestoreDelayMilliseconds)),
            ("ORB_THEME", orbThemeOverride),
            (
                "PREFER_BUILT_IN_MIC_FOR_BLUETOOTH",
                preferBuiltInMicrophoneForBluetooth ? "true" : "false"
            )
        ]

        return values
            .map { "\($0)=\(Self.escapedEnvValue($1))" }
            .joined(separator: "\n") + "\n"
    }

    private static func escapedEnvValue(_ value: String) -> String {
        let needsQuoting = value.contains { character in
            character.isWhitespace || character == "#" || character == "\"" || character == "'"
        }

        guard needsQuoting else {
            return value
        }

        return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func boolValue(_ value: String?, default defaultValue: Bool) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return defaultValue
        }

        switch value {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return defaultValue
        }
    }

    private static func intValue(_ value: String?, default defaultValue: Int) -> Int {
        guard let value, let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return defaultValue
        }

        return intValue
    }
}

public enum ConfigurationStore {
    public static func save(_ configuration: AppConfiguration, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try configuration.envFileContents().write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
