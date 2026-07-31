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
    var focusedElement: AXUIElement?

    init(
        processIdentifier: pid_t?,
        bundleIdentifier: String?,
        focusedState: FocusedTextTargetState,
        focusedElement: AXUIElement? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.focusedState = focusedState
        self.focusedElement = focusedElement
    }
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
        let focusedTarget = focusedTextTarget()
        let target = TextInsertionTarget(
            processIdentifier: application?.processIdentifier,
            bundleIdentifier: application?.bundleIdentifier,
            focusedState: focusedTarget.state,
            focusedElement: focusedTarget.element
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
        var isAccessibilityTrusted = PermissionManager.isAccessibilityTrusted(
            prompt: false
        )
        if !isAccessibilityTrusted {
            _ = PermissionManager.isAccessibilityTrusted(prompt: true)
            isAccessibilityTrusted = PermissionManager.isAccessibilityTrusted(
                prompt: false
            )
        }

        let pasteboard = NSPasteboard.general
        flushPendingClipboardRestore(on: pasteboard)
        let currentTarget = focusedTextTarget()
        let currentState = currentTarget.state
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

        // AXSelectedText is a confirmed insertion path and avoids touching the
        // user's clipboard altogether. Custom web editors generally reject it
        // and naturally fall through to Cmd-V below.
        if canPasteIntoFocusedElement,
           focusMatches(captured: target?.focusedElement, current: currentTarget.element),
           insertUsingAccessibility(text, into: currentTarget.element) {
            LocalFlowLogger.log("Paste confirmed via Accessibility chars=\(text.count)")
            return .pasted
        }

        let snapshot = restoreClipboard && canPasteIntoFocusedElement
            ? capture(pasteboard: pasteboard)
            : nil
        let metricsBeforePaste = textMetrics(for: currentTarget.element)

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

        // A posted CGEvent has no success result. Confirm native text targets
        // from their character count before claiming `.pasted` or restoring the
        // previous clipboard. If confirmation is impossible (common in Electron),
        // retain the transcript on the clipboard as a lossless fallback.
        try? await Task.sleep(for: .milliseconds(90))
        let focusedAfterPaste = focusedTextTarget()
        let pasteWasConfirmed = focusMatches(
            captured: currentTarget.element,
            current: focusedAfterPaste.element
        ) && textMetricsConfirmInsertion(
            before: metricsBeforePaste,
            after: textMetrics(for: focusedAfterPaste.element),
            insertedText: text
        )

        guard pasteWasConfirmed else {
            LocalFlowLogger.log(
                "Keyboard paste unconfirmed; transcript retained on clipboard"
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

    private struct FocusedTextTarget {
        var state: FocusedTextTargetState
        var element: AXUIElement?
    }

    private struct TextMetrics {
        var characterCount: Int
        var selectedCharacterCount: Int
    }

    private func focusedTextTarget() -> FocusedTextTarget {
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
            return FocusedTextTarget(state: .unknown, element: nil)
        }
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return FocusedTextTarget(state: .unknown, element: nil)
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
            return FocusedTextTarget(state: .secure, element: focusedElement)
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
            return FocusedTextTarget(state: .editable, element: focusedElement)
        }

        for attribute in [kAXValueAttribute, kAXSelectedTextAttribute] {
            var attributeIsSettable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(
                focusedElement,
                attribute as CFString,
                &attributeIsSettable
            ) == .success,
               attributeIsSettable.boolValue {
                return FocusedTextTarget(state: .editable, element: focusedElement)
            }
        }

        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        guard roleResult == .success, let role = roleValue as? String else {
            return FocusedTextTarget(state: .unknown, element: focusedElement)
        }

        let editableRoles: Set<String> = [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole,
            "AXSearchField"
        ]
        if editableRoles.contains(role) {
            return FocusedTextTarget(state: .editable, element: focusedElement)
        }

        LocalFlowLogger.log(
            "Focused target rejected role=\(role) attributes=\(attributeNames.sorted().joined(separator: ","))"
        )
        return FocusedTextTarget(state: .notEditable, element: focusedElement)
    }

    private func capture(pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        guard pasteboardItems.count <= 32 else {
            LocalFlowLogger.log("Clipboard restore skipped items=\(pasteboardItems.count)")
            return nil
        }

        var totalBytes = 0
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboardItems {
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard Self.restorableClipboardTypes.contains(type) else {
                    LocalFlowLogger.log(
                        "Clipboard restore skipped unsupportedType=\(type.rawValue)"
                    )
                    return nil
                }
                if let data = item.data(forType: type) {
                    totalBytes += data.count
                    guard totalBytes <= Self.maximumClipboardSnapshotBytes else {
                        LocalFlowLogger.log(
                            "Clipboard restore skipped bytes=\(totalBytes)"
                        )
                        return nil
                    }
                    values[type] = data
                }
            }
            items.append(values)
        }

        return ClipboardSnapshot(items: items)
    }

    private func insertUsingAccessibility(
        _ text: String,
        into element: AXUIElement?
    ) -> Bool {
        guard let element else {
            return false
        }
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        ) == .success,
        isSettable.boolValue else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    private func focusMatches(
        captured: AXUIElement?,
        current: AXUIElement?
    ) -> Bool {
        switch (captured, current) {
        case let (.some(captured), .some(current)):
            return CFEqual(captured, current)
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func textMetrics(for element: AXUIElement?) -> TextMetrics? {
        guard let element else {
            return nil
        }
        var countValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &countValue
        ) == .success,
        let characterCount = (countValue as? NSNumber)?.intValue else {
            return nil
        }

        var selectedTextValue: CFTypeRef?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )
        let selectedCount = selectedTextResult == .success
            ? (selectedTextValue as? String)?.utf16.count ?? 0
            : 0
        return TextMetrics(
            characterCount: characterCount,
            selectedCharacterCount: selectedCount
        )
    }

    private func textMetricsConfirmInsertion(
        before: TextMetrics?,
        after: TextMetrics?,
        insertedText: String
    ) -> Bool {
        guard let before, let after else {
            return false
        }
        let expectedDelta = insertedText.utf16.count
            - before.selectedCharacterCount
        return after.characterCount - before.characterCount == expectedDelta
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

    private static let maximumClipboardSnapshotBytes = 8 * 1_024 * 1_024
    private static let restorableClipboardTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .rtf,
        .html,
        .URL,
        .fileURL
    ]

}
