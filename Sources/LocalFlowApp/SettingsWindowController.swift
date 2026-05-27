import AppKit
import LocalFlowCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private let textView = NSTextView()

    init() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 460))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalFlow Settings"
        window.contentView = scrollView
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        configuration: AppConfiguration,
        envSource: URL?,
        dictionarySource: URL?,
        historyURL: URL,
        appSupportURL: URL
    ) {
        let keyStatus = configuration.isOpenAIConfigured ? "configured" : "missing"
        let accessibilityStatus = PermissionManager.isAccessibilityTrusted(prompt: false) ? "granted" : "missing"

        textView.string = """
        LocalFlow

        OpenAI API key: \(keyStatus)
        Transcription model: \(configuration.transcriptionModel)
        Transcription language: \(configuration.transcriptionLanguage)
        Polish enabled: \(configuration.enablePolish)
        Polish model: \(configuration.polishModel)

        Hold hotkey: \(configuration.holdHotkey)
        Fallback hold hotkey: \(configuration.fallbackHoldHotkey)
        Toggle hotkey: \(configuration.toggleHotkey)

        Restore clipboard after paste: \(configuration.restoreClipboardAfterPaste)
        Paste restore delay: \(configuration.pasteRestoreDelayMilliseconds) ms
        History retention: \(configuration.historyRetentionDays) days

        Accessibility permission: \(accessibilityStatus)

        .env source:
        \(envSource?.path ?? "not found")

        Dictionary source:
        \(dictionarySource?.path ?? "empty dictionary")

        Support folder:
        \(appSupportURL.path)

        History file:
        \(historyURL.path)

        Notes:
        - Microphone permission is requested when recording starts.
        - Accessibility permission is needed for global hotkeys and automatic paste.
        - Fn/Globe handling depends on macOS keyboard settings; use Option+Space if Fn is not delivered to apps.
        """
    }
}
