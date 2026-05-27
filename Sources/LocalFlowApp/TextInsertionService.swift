import AppKit
import Foundation

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
        let pasteboard = NSPasteboard.general
        let snapshot = restoreClipboard ? capture(pasteboard: pasteboard) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        sendPasteKeystroke()

        guard restoreClipboard, let snapshot else {
            return
        }

        let delay = max(0, restoreDelayMilliseconds)
        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
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

    private func sendPasteKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode: CGKeyCode = 9 // v

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
