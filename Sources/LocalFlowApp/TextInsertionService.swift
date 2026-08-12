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

enum KeyboardPasteDestination: Equatable {
    case capturedProcess(pid_t)
    case session
}

enum KeyboardPasteConfirmation: Equatable {
    case confirmed
    case unavailable
    case focusChanged
    case deltaMismatch
    case noChange
}

struct KeyboardPasteResolution: Equatable {
    var outcome: TextInsertionOutcome
    var shouldRestoreClipboard: Bool
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
        // and naturally fall through to Cmd-V below — but Chromium can also
        // accept the write and silently drop it, so success only counts when
        // the character metrics actually move. Elements without metrics are
        // unverifiable and take the keyboard path instead.
        if canPasteIntoFocusedElement,
           focusMatches(captured: target?.focusedElement, current: currentTarget.element),
           let focusedElement = currentTarget.element,
           let metricsBeforeInsert = textMetrics(for: focusedElement),
           insertUsingAccessibility(text, into: focusedElement) {
            let confirmation = await confirmKeyboardPaste(
                deliveryElement: focusedElement,
                metricsBeforePaste: metricsBeforeInsert,
                text: text
            )
            if confirmation == .confirmed {
                LocalFlowLogger.log("Paste confirmed via Accessibility chars=\(text.count)")
                return .pasted
            }
            LocalFlowLogger.log(
                "Accessibility insert unverified reason=\(String(describing: confirmation)); falling back to keyboard paste"
            )
        }

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

        // Re-resolve immediately before posting the keyboard events. Recording
        // can take several seconds and focus can move after the initial check;
        // never deliver to another process or to a newly focused secure field.
        let deliveryTarget = focusedTextTarget()
        let deliveryApplication = NSWorkspace.shared.frontmostApplication
        let deliveryProcessIdentifier = deliveryApplication?.processIdentifier
        guard Self.shouldPaste(
            accessibilityTrusted: isAccessibilityTrusted,
            currentState: deliveryTarget.state,
            capturedTarget: target,
            currentProcessIdentifier: deliveryProcessIdentifier
        ),
        let destination = Self.keyboardPasteDestination(
            capturedTarget: target,
            currentProcessIdentifier: deliveryProcessIdentifier
        ) else {
            LocalFlowLogger.log(
                "Keyboard paste skipped after focus changed; transcript retained on clipboard"
            )
            return .copiedToClipboard
        }
        let metricsBeforePaste = textMetrics(for: deliveryTarget.element)

        do {
            try await sendPasteKeystroke(to: destination)
        } catch {
            LocalFlowLogger.log(
                "Keyboard paste event failed; transcript remains on clipboard error=\(error.localizedDescription)"
            )
            return .copiedToClipboard
        }

        // Native controls expose enough AX metrics to confirm the text delta.
        // Electron and Chromium often expose neither metric even after a
        // PID-targeted event was posted. That is unavailable evidence, not a
        // failed delivery, so retain the transcript without falsely reporting
        // that it was only copied.
        var attemptCount = 1
        var confirmation = await confirmKeyboardPaste(
            deliveryElement: deliveryTarget.element,
            metricsBeforePaste: metricsBeforePaste,
            text: text
        )
        while Self.shouldRetryKeyboardPaste(
            confirmation: confirmation,
            attemptCount: attemptCount
        ) {
            guard !Task.isCancelled else {
                break
            }
            let retryTarget = focusedTextTarget()
            guard Self.shouldPaste(
                accessibilityTrusted: isAccessibilityTrusted,
                currentState: retryTarget.state,
                capturedTarget: target,
                currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
            ) else {
                LocalFlowLogger.log("Keyboard paste retry skipped after focus changed")
                break
            }
            attemptCount += 1
            LocalFlowLogger.log("Keyboard paste retry attempt=\(attemptCount)")
            do {
                try await sendPasteKeystroke(to: destination)
            } catch {
                LocalFlowLogger.log("Keyboard paste retry failed error=\(error.localizedDescription)")
                break
            }
            confirmation = await confirmKeyboardPaste(
                deliveryElement: deliveryTarget.element,
                metricsBeforePaste: metricsBeforePaste,
                text: text
            )
        }
        let resolution = Self.keyboardPasteResolution(
            destination: destination,
            confirmation: confirmation
        )

        switch confirmation {
        case .confirmed:
            LocalFlowLogger.log(
                "Keyboard paste confirmed via Accessibility metrics attempts=\(attemptCount)"
            )
        case .unavailable where resolution.outcome == .pasted:
            LocalFlowLogger.log(
                "Keyboard paste posted to captured process; Accessibility confirmation unavailable; transcript retained on clipboard"
            )
        case .unavailable, .focusChanged, .deltaMismatch, .noChange:
            LocalFlowLogger.log(
                "Keyboard paste unconfirmed reason=\(String(describing: confirmation)) attempts=\(attemptCount); transcript retained on clipboard"
            )
        }

        guard resolution.shouldRestoreClipboard,
              restoreClipboard,
              let snapshot else {
            return resolution.outcome
        }

        scheduleClipboardRestore(
            snapshot,
            pasteboard: pasteboard,
            insertedTextChangeCount: insertedTextChangeCount,
            delayMilliseconds: restoreDelayMilliseconds
        )
        return resolution.outcome
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

    nonisolated static func keyboardPasteDestination(
        capturedTarget: TextInsertionTarget?,
        currentProcessIdentifier: pid_t?
    ) -> KeyboardPasteDestination? {
        guard let capturedTarget else {
            return .session
        }
        guard let capturedProcessIdentifier = capturedTarget.processIdentifier else {
            return nil
        }
        guard capturedProcessIdentifier == currentProcessIdentifier else {
            return nil
        }
        return .capturedProcess(capturedProcessIdentifier)
    }

    nonisolated static func keyboardPasteConfirmation(
        focusStillMatches: Bool,
        expectedCharacterDelta: Int?,
        actualCharacterDelta: Int?
    ) -> KeyboardPasteConfirmation {
        guard focusStillMatches else {
            return .focusChanged
        }
        guard let expectedCharacterDelta, let actualCharacterDelta else {
            return .unavailable
        }
        if actualCharacterDelta == expectedCharacterDelta {
            return .confirmed
        }
        if actualCharacterDelta == 0 {
            return .noChange
        }
        return .deltaMismatch
    }

    nonisolated static func keyboardPasteResolution(
        destination: KeyboardPasteDestination,
        confirmation: KeyboardPasteConfirmation
    ) -> KeyboardPasteResolution {
        switch confirmation {
        case .confirmed:
            return KeyboardPasteResolution(
                outcome: .pasted,
                shouldRestoreClipboard: true
            )
        case .unavailable:
            switch destination {
            case .capturedProcess:
                return KeyboardPasteResolution(
                    outcome: .pasted,
                    shouldRestoreClipboard: false
                )
            case .session:
                return KeyboardPasteResolution(
                    outcome: .copiedToClipboard,
                    shouldRestoreClipboard: false
                )
            }
        case .focusChanged, .deltaMismatch, .noChange:
            return KeyboardPasteResolution(
                outcome: .copiedToClipboard,
                shouldRestoreClipboard: false
            )
        }
    }

    // Only a confirmed no-change (character count unchanged, focus intact) is
    // safe to retry: the keystroke observably did not land, so one more
    // attempt cannot double-paste. A nonzero unexpected delta means some text
    // may have landed already, so retrying that case risks double-pasting. A
    // focus change makes redelivery unsafe, and unavailable metrics could
    // hide a paste that already landed.
    nonisolated static func shouldRetryKeyboardPaste(
        confirmation: KeyboardPasteConfirmation,
        attemptCount: Int
    ) -> Bool {
        confirmation == .noChange && attemptCount < 2
    }

    // Chromium regenerates AX wrapper objects for the same DOM node, so
    // pointer inequality is not evidence that focus moved. Same process and
    // same role is the strongest identity signal still available; missing
    // metadata stays conservative and reports a mismatch.
    nonisolated static func focusIdentityMatches(
        identityEqual: Bool,
        capturedPid: pid_t?,
        currentPid: pid_t?,
        capturedRole: String?,
        currentRole: String?
    ) -> Bool {
        if identityEqual {
            return true
        }
        guard let capturedPid, let currentPid, capturedPid == currentPid else {
            return false
        }
        guard let capturedRole, let currentRole else {
            return false
        }
        return capturedRole == currentRole
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
            if CFEqual(captured, current) {
                return true
            }
            return Self.focusIdentityMatches(
                identityEqual: false,
                capturedPid: processIdentifier(of: captured),
                currentPid: processIdentifier(of: current),
                capturedRole: role(of: captured),
                currentRole: role(of: current)
            )
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t? {
        var elementPid: pid_t = 0
        guard AXUIElementGetPid(element, &elementPid) == .success else {
            return nil
        }
        return elementPid
    }

    private func role(of element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success else {
            return nil
        }
        return roleValue as? String
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

    private func confirmKeyboardPaste(
        deliveryElement: AXUIElement?,
        metricsBeforePaste: TextMetrics?,
        text: String
    ) async -> KeyboardPasteConfirmation {
        // Electron editors regularly need several hundred milliseconds to
        // process a synthetic Cmd-V; a single early check misreads slow
        // delivery as failure. Without baseline metrics no amount of polling
        // can produce evidence, so a single focus check suffices.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1_000))
        var confirmation: KeyboardPasteConfirmation = .unavailable
        repeat {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else {
                return confirmation
            }
            let focusedAfterPaste = focusedTextTarget()
            let focusStillMatches = focusMatches(
                captured: deliveryElement,
                current: focusedAfterPaste.element
            )
            let metricsAfterPaste = textMetrics(for: focusedAfterPaste.element)
            let expectedCharacterDelta = metricsBeforePaste.map {
                text.utf16.count - $0.selectedCharacterCount
            }
            let actualCharacterDelta: Int?
            if let metricsBeforePaste, let metricsAfterPaste {
                actualCharacterDelta = metricsAfterPaste.characterCount
                    - metricsBeforePaste.characterCount
            } else {
                actualCharacterDelta = nil
            }
            confirmation = Self.keyboardPasteConfirmation(
                focusStillMatches: focusStillMatches,
                expectedCharacterDelta: expectedCharacterDelta,
                actualCharacterDelta: actualCharacterDelta
            )
            if confirmation == .confirmed || metricsBeforePaste == nil {
                return confirmation
            }
        } while ContinuousClock.now < deadline
        return confirmation
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

    private func sendPasteKeystroke(
        to destination: KeyboardPasteDestination
    ) async throws {
        try Self.postPasteEvent(keyDown: true, to: destination)
        // Some Chromium/Electron editors miss an effectively simultaneous
        // down/up pair. Keep the chord short but observable by their event loop.
        try? await Task.sleep(for: .milliseconds(12))
        try Self.postPasteEvent(keyDown: false, to: destination)
    }

    nonisolated private static func postPasteEvent(
        keyDown: Bool,
        to destination: KeyboardPasteDestination
    ) throws {
        // Chromium/Electron apps drop or defer events injected with
        // postToPid; the HID tap is the delivery path they reliably handle.
        // shouldPaste re-verifies the captured process is frontmost right
        // before posting, so the global event cannot reach another app.
        let stateID: CGEventSourceStateID
        switch destination {
        case .capturedProcess:
            stateID = .hidSystemState
        case .session:
            stateID = .combinedSessionState
        }
        guard let source = CGEventSource(stateID: stateID) else {
            throw TextInsertionError.pasteEventCreationFailed
        }
        let keyCode: CGKeyCode = 9 // v

        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else {
            throw TextInsertionError.pasteEventCreationFailed
        }
        event.flags = .maskCommand

        switch destination {
        case .capturedProcess:
            event.post(tap: .cghidEventTap)
        case .session:
            event.post(tap: .cgSessionEventTap)
        }
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
