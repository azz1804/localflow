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
}

@MainActor
final class TextInsertionService {
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
        let currentState = focusedTextTargetState()
        let currentProcessIdentifier = NSWorkspace.shared
            .frontmostApplication?
            .processIdentifier
        let capturedEditableTargetIsStillActive = Self
            .capturedEditableTargetIsStillActive(
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
            "Insertion target resolved captured=\(target?.focusedState.rawValue ?? "-") current=\(currentState.rawValue) sameApp=\(capturedEditableTargetIsStillActive) paste=\(canPasteIntoFocusedElement)"
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

        try sendPasteKeystroke()

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
        let delay = max(0, delayMilliseconds)
        Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay) * 1_000_000
            )
            guard !Task.isCancelled else {
                return
            }

            // Do not overwrite clipboard content copied by the user or another
            // app while the temporary dictation text was available.
            guard pasteboard.changeCount == insertedTextChangeCount else {
                return
            }

            self?.restore(snapshot, to: pasteboard)
        }
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
        return currentState != .notEditable
            || capturedEditableTargetIsStillActive(
                capturedTarget,
                currentProcessIdentifier: currentProcessIdentifier
            )
            || keyboardPasteFallbackIsSafe(
                capturedTarget,
                currentProcessIdentifier: currentProcessIdentifier
            )
    }

    nonisolated private static func capturedEditableTargetIsStillActive(
        _ target: TextInsertionTarget?,
        currentProcessIdentifier: pid_t?
    ) -> Bool {
        target?.focusedState == .editable
            && target?.processIdentifier != nil
            && target?.processIdentifier == currentProcessIdentifier
    }

    nonisolated private static func keyboardPasteFallbackIsSafe(
        _ target: TextInsertionTarget?,
        currentProcessIdentifier: pid_t?
    ) -> Bool {
        guard target?.processIdentifier != nil,
              target?.processIdentifier == currentProcessIdentifier,
              let bundleIdentifier = target?.bundleIdentifier else {
            return false
        }
        return keyboardPasteFallbackBundleIdentifiers.contains(
            bundleIdentifier
        )
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
            return focusedResult == .noValue ? .notEditable : .unknown
        }
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .unknown
        }

        let focusedElement = unsafeDowncast(
            focusedValue,
            to: AXUIElement.self
        )

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

    nonisolated private static let keyboardPasteFallbackBundleIdentifiers:
        Set<String> = [
            "com.openai.codex"
        ]
}
