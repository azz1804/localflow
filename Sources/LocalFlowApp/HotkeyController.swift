import AppKit
import Carbon
import Foundation

struct HotkeySpec: Equatable {
    enum Key: Equatable {
        case fn
        case space
    }

    var key: Key
    var modifiers: CGEventFlags

    static func parse(_ rawValue: String) -> HotkeySpec? {
        let parts = rawValue
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else {
            return nil
        }

        var modifiers: CGEventFlags = []
        var key: Key?

        for part in parts {
            switch part {
            case "cmd", "command", "⌘":
                modifiers.insert(.maskCommand)
            case "ctrl", "control", "⌃":
                modifiers.insert(.maskControl)
            case "alt", "option", "opt", "⌥":
                modifiers.insert(.maskAlternate)
            case "shift", "⇧":
                modifiers.insert(.maskShift)
            case "fn", "globe":
                if parts.count == 1 {
                    key = .fn
                } else {
                    modifiers.insert(.maskSecondaryFn)
                }
            case "space", "spacebar":
                key = .space
            default:
                return nil
            }
        }

        guard let key else {
            return nil
        }

        return HotkeySpec(key: key, modifiers: modifiers)
    }

    func matchesKeyEvent(_ event: CGEvent) -> Bool {
        guard key == .space else {
            return false
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == 49 else {
            return false
        }

        return normalizedModifiers(event.flags) == normalizedModifiers(modifiers)
    }

    func matchesFnFlags(_ flags: CGEventFlags) -> Bool {
        key == .fn && flags.contains(.maskSecondaryFn)
    }

    func matchesFnKeyEvent(_ event: CGEvent) -> Bool {
        guard key == .fn else {
            return false
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        return keyCode == 63 // kVK_Function
    }

    func matchesKeyEvent(_ snapshot: HotkeyEventSnapshot) -> Bool {
        guard key == .space else {
            return false
        }

        guard snapshot.keyCode == 49 else {
            return false
        }

        return normalizedModifiers(snapshot.cgFlags) == normalizedModifiers(modifiers)
    }

    func matchesFnFlags(_ snapshot: HotkeyEventSnapshot) -> Bool {
        key == .fn && snapshot.nsFlags.contains(.function)
    }

    func matchesFnKeyEvent(_ snapshot: HotkeyEventSnapshot) -> Bool {
        key == .fn && snapshot.keyCode == 63
    }

    private func normalizedModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn])
    }
}

struct HotkeyEventSnapshot: Sendable {
    enum EventKind: Sendable {
        case flagsChanged
        case keyDown
        case keyUp
    }

    var kind: EventKind
    var keyCode: UInt16
    var modifierFlagsRawValue: UInt
    var isRepeat: Bool

    var nsFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }

    var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        let nsFlags = nsFlags

        if nsFlags.contains(.command) {
            flags.insert(.maskCommand)
        }
        if nsFlags.contains(.control) {
            flags.insert(.maskControl)
        }
        if nsFlags.contains(.option) {
            flags.insert(.maskAlternate)
        }
        if nsFlags.contains(.shift) {
            flags.insert(.maskShift)
        }
        if nsFlags.contains(.function) {
            flags.insert(.maskSecondaryFn)
        }

        return flags
    }

    init?(event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            kind = .flagsChanged
        case .keyDown:
            kind = .keyDown
        case .keyUp:
            kind = .keyUp
        default:
            return nil
        }

        keyCode = event.keyCode
        modifierFlagsRawValue = event.modifierFlags.rawValue
        isRepeat = event.isARepeat
    }
}

@MainActor
final class HotkeyController {
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var onToggle: (() -> Void)?

    private let holdSpec: HotkeySpec?
    private let fallbackHoldSpec: HotkeySpec?
    private let toggleSpec: HotkeySpec?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fnIsDown = false
    private var holdFallbackIsDown = false
    private var lastToggleTime: CFTimeInterval = 0
    private(set) var isRunning = false
    private(set) var activeTapDescription = "none"
    private(set) var monitorsAreInstalled = false

    init(holdHotkey: String, fallbackHoldHotkey: String, toggleHotkey: String) {
        self.holdSpec = HotkeySpec.parse(holdHotkey)
        self.fallbackHoldSpec = HotkeySpec.parse(fallbackHoldHotkey)
        self.toggleSpec = HotkeySpec.parse(toggleHotkey)
    }

    @discardableResult
    func start() -> Bool {
        stop()

        installNSEventMonitors()

        let eventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let controller = Unmanaged<HotkeyController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handle(proxy: proxy, type: type, event: event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for tapLocation in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            eventTap = CGEvent.tapCreate(
                tap: tapLocation,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: callback,
                userInfo: refcon
            )

            if eventTap != nil {
                activeTapDescription = Self.description(for: tapLocation)
                break
            }
        }

        guard let eventTap else {
            isRunning = monitorsAreInstalled
            activeTapDescription = "none"
            return isRunning
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        globalMonitor = nil
        localMonitor = nil
        isRunning = false
        monitorsAreInstalled = false
        activeTapDescription = "none"
        fnIsDown = false
        holdFallbackIsDown = false
        lastToggleTime = 0
    }

    private func installNSEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let snapshot = HotkeyEventSnapshot(event: event) else {
                return
            }

            Task { @MainActor in
                self?.handleNSEventSnapshot(snapshot)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let snapshot = HotkeyEventSnapshot(event: event) else {
                return event
            }

            var shouldConsume = false
            MainActor.assumeIsolated {
                shouldConsume = self?.handleNSEventSnapshot(snapshot) ?? false
            }
            return shouldConsume ? nil : event
        }

        monitorsAreInstalled = globalMonitor != nil || localMonitor != nil
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown:
            return handleKeyDown(event)
        case .keyUp:
            return handleKeyUp(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if let holdSpec, holdSpec.key == .fn {
            let isDown = holdSpec.matchesFnFlags(event.flags)
            if isDown != fnIsDown {
                fnIsDown = isDown
                if isDown {
                    onHoldStart?()
                } else {
                    onHoldEnd?()
                }
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if let holdSpec, holdSpec.matchesFnKeyEvent(event), !isRepeat {
            if !fnIsDown {
                fnIsDown = true
                onHoldStart?()
            }
            return nil
        }

        if let toggleSpec, toggleSpec.matchesKeyEvent(event), !isRepeat {
            triggerToggleIfNeeded()
            return nil
        }

        if let fallbackHoldSpec, fallbackHoldSpec.matchesKeyEvent(event), !isRepeat {
            if !holdFallbackIsDown {
                holdFallbackIsDown = true
                onHoldStart?()
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if let holdSpec, holdSpec.matchesFnKeyEvent(event) {
            if fnIsDown {
                fnIsDown = false
                onHoldEnd?()
            }
            return nil
        }

        if let fallbackHoldSpec, fallbackHoldSpec.matchesKeyEvent(event) {
            if holdFallbackIsDown {
                holdFallbackIsDown = false
                onHoldEnd?()
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    @discardableResult
    private func handleNSEventSnapshot(_ snapshot: HotkeyEventSnapshot) -> Bool {
        switch snapshot.kind {
        case .flagsChanged:
            return handleNSEventFlagsChanged(snapshot)
        case .keyDown:
            return handleNSEventKeyDown(snapshot)
        case .keyUp:
            return handleNSEventKeyUp(snapshot)
        }
    }

    private func handleNSEventFlagsChanged(_ snapshot: HotkeyEventSnapshot) -> Bool {
        if let holdSpec, holdSpec.key == .fn {
            let isDown = holdSpec.matchesFnFlags(snapshot)
            if isDown != fnIsDown {
                fnIsDown = isDown
                if isDown {
                    onHoldStart?()
                } else {
                    onHoldEnd?()
                }
                return true
            }
        }

        return false
    }

    private func handleNSEventKeyDown(_ snapshot: HotkeyEventSnapshot) -> Bool {
        guard !snapshot.isRepeat else {
            return false
        }

        if let holdSpec, holdSpec.matchesFnKeyEvent(snapshot) {
            if !fnIsDown {
                fnIsDown = true
                onHoldStart?()
            }
            return true
        }

        if let toggleSpec, toggleSpec.matchesKeyEvent(snapshot) {
            triggerToggleIfNeeded()
            return true
        }

        if let fallbackHoldSpec, fallbackHoldSpec.matchesKeyEvent(snapshot) {
            if !holdFallbackIsDown {
                holdFallbackIsDown = true
                onHoldStart?()
            }
            return true
        }

        return false
    }

    private func triggerToggleIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggleTime > 0.25 else {
            return
        }

        lastToggleTime = now
        onToggle?()
    }

    private func handleNSEventKeyUp(_ snapshot: HotkeyEventSnapshot) -> Bool {
        if let holdSpec, holdSpec.matchesFnKeyEvent(snapshot) {
            if fnIsDown {
                fnIsDown = false
                onHoldEnd?()
            }
            return true
        }

        if let fallbackHoldSpec, fallbackHoldSpec.matchesKeyEvent(snapshot) {
            if holdFallbackIsDown {
                holdFallbackIsDown = false
                onHoldEnd?()
            }
            return true
        }

        return false
    }

    private static func description(for tapLocation: CGEventTapLocation) -> String {
        switch tapLocation {
        case .cghidEventTap:
            return "hid"
        case .cgSessionEventTap:
            return "session"
        case .cgAnnotatedSessionEventTap:
            return "annotated-session"
        @unknown default:
            return "unknown"
        }
    }
}
