import AppKit
import Foundation

enum TextInsertionError: LocalizedError {
    case accessibilityPermissionMissing
    case clipboardWriteFailed
    case pasteEventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required to paste into the active app."
        case .clipboardWriteFailed:
            return "LocalFlow could not write the dictated text to the clipboard."
        case .pasteEventCreationFailed:
            return "LocalFlow could not create the keyboard event used to paste text."
        }
    }
}

struct ClipboardSnapshot {
    var items: [[NSPasteboard.PasteboardType: Data]]
}

@MainActor
final class TextInsertionService {
    func paste(
        text: String,
        restoreClipboard: Bool,
        restoreDelayMilliseconds: Int
    ) async throws {
        guard PermissionManager.isAccessibilityTrusted(prompt: false) else {
            _ = PermissionManager.isAccessibilityTrusted(prompt: true)
            throw TextInsertionError.accessibilityPermissionMissing
        }

        let pasteboard = NSPasteboard.general
        let snapshot = restoreClipboard ? capture(pasteboard: pasteboard) : nil

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInsertionError.clipboardWriteFailed
        }
        let insertedTextChangeCount = pasteboard.changeCount

        try sendPasteKeystroke()

        guard restoreClipboard, let snapshot else {
            return
        }

        let delay = max(0, restoreDelayMilliseconds)
        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)

        // Do not overwrite clipboard content copied by the user or another app
        // while the temporary dictation text was available.
        guard pasteboard.changeCount == insertedTextChangeCount else {
            return
        }

        restore(snapshot, to: pasteboard)
    }

    private func capture(pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        }

        return ClipboardSnapshot(items: items)
    }

    private func restore(_ snapshot: ClipboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        let items = snapshot.items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }

        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private func sendPasteKeystroke() throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw TextInsertionError.pasteEventCreationFailed
        }
        let keyCode: CGKeyCode = 9 // v

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw TextInsertionError.pasteEventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
