import AppKit
import ApplicationServices
import Foundation

enum TextInsertionError: LocalizedError {
    case clipboardWriteFailed
    case pasteEventCreationFailed

    var errorDescription: String? {
        switch self {
        case .clipboardWriteFailed:
            return "LocalFlow could not write the dictated text to the clipboard."
        case .pasteEventCreationFailed:
            return "LocalFlow could not create the keyboard event used to paste text."
        }
    }
}

enum TextInsertionOutcome: Equatable {
    case pasted
    case copiedToClipboard
}

struct ClipboardSnapshot {
    var items: [[NSPasteboard.PasteboardType: Data]]
}

struct TextInsertionTarget {
    var processIdentifier: pid_t?
    var bundleIdentifier: String?
    var focusedState: FocusedTextTargetState
}

enum FocusedTextTargetState: String {
    case editable
    case notEditable
    case unknown
    case secure
}

@MainActor
final class TextInsertionService {
    private var clipboardRestoreTask: Task<Void, Never>?
    private var pendingClipboardSnapshot: ClipboardSnapshot?
    private var pendingClipboardChangeCount: Int?

    func captureTarget() -> TextInsertionTarget {
        let application = NSWorkspace.shared.frontmostApplication
        let target = TextInsertionTarget(
            processIdentifier: application?.processIdentifier,
            bundleIdentifier: application?.bundleIdentifier,
            focusedState: focusedTextTargetState()
        )
        LocalFlowLogger.log(
            "Insertion target captured pid=\(target.processIdentifier.map(String.init) ?? "-") bundle=\(target.bundleIdentifier ?? "-") state=\(target.focusedState.rawValue)"
        )
        return target
    }

    func paste(
        text: String,
        restoreClipboard: Bool,
        restoreDelayMilliseconds: Int,
        target: TextInsertionTarget? = nil
    ) async throws -> TextInsertionOutcome {
        let isAccessibilityTrusted = PermissionManager.isAccessibilityTrusted(
            prompt: false
        )
        if !isAccessibilityTrusted {
            _ = PermissionManager.isAccessibilityTrusted(prompt: true)
        }

        let pasteboard = NSPasteboard.general
        flushPendingClipboardRestore(on: pasteboard)
        let currentState = focusedTextTargetState()
        let currentApplication = NSWorkspace.shared.frontmostApplication
        let currentProcessIdentifier = currentApplication?.processIdentifier
        let capturedApplicationIsStillActive = Self
            .capturedApplicationIsStillActive(
                target,
                currentProcessIdentifier: currentProcessIdentifier
            )
        let canPasteIntoFocusedElement = Self.shouldPaste(
            accessibilityTrusted: isAccessibilityTrusted,
            currentState: currentState,
            capturedTarget: target,
            currentProcessIdentifier: currentProcessIdentifier
        )
        LocalFlowLogger.log(
            "Insertion target resolved captured=\(target?.focusedState.rawValue ?? "-") current=\(currentState.rawValue) sameProcess=\(capturedApplicationIsStillActive) currentPID=\(currentProcessIdentifier.map(String.init) ?? "-") currentBundle=\(currentApplication?.bundleIdentifier ?? "-") strategy=\(canPasteIntoFocusedElement ? "keyboard" : "clipboard")"
        )
        let snapshot = restoreClipboard && canPasteIntoFocusedElement
            ? capture(pasteboard: pasteboard)
            : nil

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInsertionError.clipboardWriteFailed
        }
        let insertedTextChangeCount = pasteboard.changeCount

        guard canPasteIntoFocusedElement else {
            return .copiedToClipboard
        }

        do {
            try sendPasteKeystroke()
        } catch {
            LocalFlowLogger.log(
                "Keyboard paste event failed; transcript remains on clipboard error=\(error.localizedDescription)"
            )
            return .copiedToClipboard
        }

        guard restoreClipboard, let snapshot else {
            return .pasted
        }

        scheduleClipboardRestore(
            snapshot,
            pasteboard: pasteboard,
            insertedTextChangeCount: insertedTextChangeCount,
            delayMilliseconds: restoreDelayMilliseconds
        )
        return .pasted
    }

    private func scheduleClipboardRestore(
        _ snapshot: ClipboardSnapshot,
        pasteboard: NSPasteboard,
        insertedTextChangeCount: Int,
        delayMilliseconds: Int
    ) {
        clipboardRestoreTask?.cancel()
        pendingClipboardSnapshot = snapshot
        pendingClipboardChangeCount = insertedTextChangeCount

        // Restoring immediately can race the target application reading Cmd-V.
        // Bound the value so malformed config cannot overflow or retain a
        // clipboard snapshot indefinitely.
        let delay = min(5_000, max(150, delayMilliseconds))
        clipboardRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else {
                return
            }

            self?.completePendingClipboardRestore(
                on: pasteboard,
                expectedChangeCount: insertedTextChangeCount
            )
        }
    }

    private func flushPendingClipboardRestore(on pasteboard: NSPasteboard) {
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil

        guard let snapshot = pendingClipboardSnapshot,
              let changeCount = pendingClipboardChangeCount,
              pasteboard.changeCount == changeCount else {
            pendingClipboardSnapshot = nil
            pendingClipboardChangeCount = nil
            return
        }

        restore(snapshot, to: pasteboard)
        pendingClipboardSnapshot = nil
        pendingClipboardChangeCount = nil
    }

    private func completePendingClipboardRestore(
        on pasteboard: NSPasteboard,
        expectedChangeCount: Int
    ) {
        defer {
            clipboardRestoreTask = nil
            pendingClipboardSnapshot = nil
            pendingClipboardChangeCount = nil
        }

        // Do not overwrite clipboard content copied by the user or another
        // app while the temporary dictation text was available.
        guard pasteboard.changeCount == expectedChangeCount,
              pendingClipboardChangeCount == expectedChangeCount,
              let snapshot = pendingClipboardSnapshot else {
            return
        }

        restore(snapshot, to: pasteboard)
    }

    nonisolated static func shouldPaste(
        accessibilityTrusted: Bool,
        currentState: FocusedTextTargetState,
        capturedTarget: TextInsertionTarget?,
        currentProcessIdentifier: pid_t?
    ) -> Bool {
        guard accessibilityTrusted else {
            return false
        }

        guard currentState != .secure,
              capturedTarget?.focusedState != .secure else {
            return false
        }

        if capturedTarget?.processIdentifier != nil {
            // Custom editors such as VS Code, Claude and browser
            // contenteditables frequently expose AXGroup/AXWebArea instead of
            // a writable text role. The user explicitly started dictation in
            // this process, so Cmd-V is the most compatible insertion path.
            guard capturedApplicationIsStillActive(
                capturedTarget,
                currentProcessIdentifier: currentProcessIdentifier
            ) else {
                return false
            }

            switch currentState {
            case .secure, .notEditable:
                return false
            case .editable:
                return true
            case .unknown:
                return capturedTarget?.focusedState != .notEditable
            }
        }

        return currentState == .editable
    }

    nonisolated private static func capturedApplicationIsStillActive(
        _ target: TextInsertionTarget?,
        currentProcessIdentifier: pid_t?
    ) -> Bool {
        target?.processIdentifier != nil
            && target?.processIdentifier == currentProcessIdentifier
    }

    private func focusedTextTargetState() -> FocusedTextTargetState {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedResult == .success, let focusedValue else {
            // Electron/Monaco/contenteditable commonly reports no focused AX
            // element even though keyboard paste is supported. Treat this as
            // unavailable evidence, not as proof that the target is read-only.
            return .unknown
        }
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .unknown
        }

        let focusedElement = unsafeDowncast(
            focusedValue,
            to: AXUIElement.self
        )

        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSubroleAttribute as CFString,
            &subroleValue
        ) == .success,
           (subroleValue as? String) == "AXSecureTextField" {
            return .secure
        }

        var attributeNamesValue: CFArray?
        let attributeNamesResult = AXUIElementCopyAttributeNames(
            focusedElement,
            &attributeNamesValue
        )
        let attributeNames = attributeNamesResult == .success
            ? Set((attributeNamesValue as? [String]) ?? [])
            : []
        let editorSignalAttributes: Set<String> = [
            kAXSelectedTextAttribute,
            kAXSelectedTextRangeAttribute,
            kAXVisibleCharacterRangeAttribute,
            kAXNumberOfCharactersAttribute,
            "AXInsertionPointLineNumber"
        ]
        if !attributeNames.isDisjoint(with: editorSignalAttributes) {
            return .editable
        }

        for attribute in [kAXValueAttribute, kAXSelectedTextAttribute] {
            var attributeIsSettable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(
                focusedElement,
                attribute as CFString,
                &attributeIsSettable
            ) == .success,
               attributeIsSettable.boolValue {
                return .editable
            }
        }

        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        guard roleResult == .success, let role = roleValue as? String else {
            return .unknown
        }

        let editableRoles: Set<String> = [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole,
            "AXSearchField"
        ]
        if editableRoles.contains(role) {
            return .editable
        }

        LocalFlowLogger.log(
            "Focused target rejected role=\(role) attributes=\(attributeNames.sorted().joined(separator: ","))"
        )
        return .notEditable
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
            if !pasteboard.writeObjects(items) {
                LocalFlowLogger.log("Clipboard restore write failed")
            }
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
