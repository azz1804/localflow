import AppKit
import Carbon
import Foundation
import IOKit.hid

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

    var carbonKeyCode: UInt32? {
        switch key {
        case .fn:
            return nil
        case .space:
            return UInt32(kVK_Space)
        }
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0

        if modifiers.contains(.maskCommand) {
            result |= UInt32(cmdKey)
        }
        if modifiers.contains(.maskAlternate) {
            result |= UInt32(optionKey)
        }
        if modifiers.contains(.maskControl) {
            result |= UInt32(controlKey)
        }
        if modifiers.contains(.maskShift) {
            result |= UInt32(shiftKey)
        }

        return result
    }

    var isCarbonRegisterable: Bool {
        guard carbonKeyCode != nil else {
            return false
        }

        guard !modifiers.contains(.maskSecondaryFn) else {
            return false
        }

        return carbonModifiers != 0
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
            // AppKit raises NSInternalInconsistencyException when isARepeat is
            // queried on a flagsChanged event. Fn emits this event type.
            isRepeat = false
        case .keyDown:
            kind = .keyDown
            isRepeat = event.isARepeat
        case .keyUp:
            kind = .keyUp
            isRepeat = false
        default:
            return nil
        }

        keyCode = event.keyCode
        modifierFlagsRawValue = event.modifierFlags.rawValue
    }
}

struct HotkeyPressGate: Equatable {
    private(set) var isPressed = false
    private var pressedAt: CFTimeInterval = 0

    mutating func begin(
        at time: CFTimeInterval,
        isRepeat: Bool
    ) -> Bool {
        guard !isRepeat else {
            return false
        }

        if isPressed, time - pressedAt < 1.5 {
            return false
        }

        isPressed = true
        pressedAt = time
        return true
    }

    mutating func end() {
        isPressed = false
        pressedAt = 0
    }
}

@MainActor
final class HotkeyController {
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var onHoldLocked: (() -> Void)?
    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDiagnosticEvent: ((String) -> Void)?

    private let holdSpec: HotkeySpec?
    private let fallbackHoldSpec: HotkeySpec?
    private let toggleSpec: HotkeySpec?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var carbonEventHandler: EventHandlerRef?
    private var carbonHotkeys: [UInt32: EventHotKeyRef] = [:]
    private var hidManager: IOHIDManager?
    private var fnIsDown = false
    private var hidFnIsDown = false
    private var holdFallbackIsDown = false
    private var activeHoldSource: String?
    private var pendingHoldTask: Task<Void, Never>?
    private var pendingHoldSource: String?
    private var pendingFnReleaseTask: Task<Void, Never>?
    private var togglePressGate = HotkeyPressGate()
    private var toggleRecordingIsActive = false
    private var applicationRecordingIsActive = false
    private var lastToggleTime: CFTimeInterval = 0
    private(set) var isRunning = false
    private(set) var activeTapDescription = "none"
    private(set) var monitorsAreInstalled = false
    private(set) var carbonHotkeysAreRegistered = false
    private(set) var hidListenerIsRunning = false

    init(holdHotkey: String, fallbackHoldHotkey: String, toggleHotkey: String) {
        self.holdSpec = HotkeySpec.parse(holdHotkey)
        self.fallbackHoldSpec = HotkeySpec.parse(fallbackHoldHotkey)
        self.toggleSpec = HotkeySpec.parse(toggleHotkey)
    }

    @discardableResult
    func start() -> Bool {
        stop()

        installCarbonHotkeys()
        installNSEventMonitors()
        installHIDListener()

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
        for tapOption in [CGEventTapOptions.defaultTap, .listenOnly] {
            for tapLocation in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
                eventTap = CGEvent.tapCreate(
                    tap: tapLocation,
                    place: .headInsertEventTap,
                    options: tapOption,
                    eventsOfInterest: CGEventMask(eventMask),
                    callback: callback,
                    userInfo: refcon
                )

                if eventTap != nil {
                    activeTapDescription = "\(Self.description(for: tapLocation))-\(Self.description(for: tapOption))"
                    break
                }
            }

            if eventTap != nil {
                break
            }
        }

        guard let eventTap else {
            isRunning = monitorsAreInstalled || carbonHotkeysAreRegistered || hidListenerIsRunning
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
        for hotkeyRef in carbonHotkeys.values {
            UnregisterEventHotKey(hotkeyRef)
        }
        if let carbonEventHandler {
            RemoveEventHandler(carbonEventHandler)
        }
        if let hidManager {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
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
        carbonEventHandler = nil
        carbonHotkeys = [:]
        hidManager = nil
        isRunning = false
        monitorsAreInstalled = false
        carbonHotkeysAreRegistered = false
        hidListenerIsRunning = false
        activeTapDescription = "none"
        fnIsDown = false
        hidFnIsDown = false
        holdFallbackIsDown = false
        activeHoldSource = nil
        cancelPendingHoldStart()
        cancelPendingFnRelease()
        togglePressGate.end()
        toggleRecordingIsActive = false
        applicationRecordingIsActive = false
        lastToggleTime = 0
    }

    func setApplicationRecordingActive(_ isActive: Bool) {
        applicationRecordingIsActive = isActive
    }

    func clearToggleRecordingState() {
        toggleRecordingIsActive = false
        applicationRecordingIsActive = false
        activeHoldSource = nil
        cancelPendingHoldStart()
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

    private func installHIDListener() {
        guard holdSpec?.key == .fn else {
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = [
            Self.hidMatch(usagePage: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Keyboard),
            Self.hidMatch(usagePage: Self.appleVendorUsagePage, usage: 3),
            Self.hidMatch(usagePage: Self.appleVendorUsagePage, usage: 11),
            Self.hidMatch(usagePage: Self.appleVendorUsagePage, usage: 13),
            Self.hidMatch(usagePage: Self.appleVendorUsagePage, usage: 95)
        ] as CFArray

        IOHIDManagerSetDeviceMatchingMultiple(manager, matches)

        let callback: IOHIDValueCallback = { _, _, refcon, value in
            guard let refcon else {
                return
            }

            let element = IOHIDValueGetElement(value)
            let usagePage = Int(IOHIDElementGetUsagePage(element))
            let usage = Int(IOHIDElementGetUsage(element))
            let intValue = IOHIDValueGetIntegerValue(value)
            let controller = Unmanaged<HotkeyController>.fromOpaque(refcon).takeUnretainedValue()

            Task { @MainActor in
                controller.handleHIDValue(usagePage: usagePage, usage: usage, intValue: intValue)
            }
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, callback, refcon)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            LocalFlowLogger.log("HID listener failed status=\(status)")
            hidListenerIsRunning = false
            return
        }

        hidManager = manager
        hidListenerIsRunning = true
        LocalFlowLogger.log("HID listener started")
    }

    private static func hidMatch(usagePage: Int, usage: Int) -> CFDictionary {
        [
            kIOHIDDeviceUsagePageKey: usagePage,
            kIOHIDDeviceUsageKey: usage
        ] as CFDictionary
    }

    private func installCarbonHotkeys() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return noErr
            }

            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotkeyID
            )
            guard status == noErr else {
                return status
            }

            let controller = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
            let eventKind = GetEventKind(event)
            Task { @MainActor in
                controller.handleCarbonHotkey(id: hotkeyID.id, eventKind: eventKind)
            }
            return noErr
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            refcon,
            &carbonEventHandler
        )
        guard installStatus == noErr else {
            carbonEventHandler = nil
            carbonHotkeysAreRegistered = false
            return
        }

        registerCarbonHotkey(spec: fallbackHoldSpec, id: Self.carbonFallbackHoldID)
        registerCarbonHotkey(spec: toggleSpec, id: Self.carbonToggleID)
        carbonHotkeysAreRegistered = !carbonHotkeys.isEmpty
    }

    private func registerCarbonHotkey(spec: HotkeySpec?, id: UInt32) {
        guard let spec, spec.isCarbonRegisterable, let keyCode = spec.carbonKeyCode else {
            return
        }

        var hotkeyRef: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: Self.carbonSignature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            spec.carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotkeyRef
        )

        if status == noErr, let hotkeyRef {
            carbonHotkeys[id] = hotkeyRef
        }
    }

    private func handleHIDValue(usagePage: Int, usage: Int, intValue: Int) {
        guard holdSpec?.key == .fn, Self.isFnHIDUsage(usagePage: usagePage, usage: usage) else {
            return
        }

        let isDown = intValue != 0
        guard isDown != hidFnIsDown else {
            return
        }

        hidFnIsDown = isDown
        if isDown {
            requestFnHoldStart(source: "fn-hid")
        } else {
            endHold(source: "fn-hid")
        }
    }

    private static func isFnHIDUsage(usagePage: Int, usage: Int) -> Bool {
        if usagePage == kHIDPage_KeyboardOrKeypad {
            return usage == keyboardFnUsage
        }

        if usagePage == appleVendorUsagePage {
            return appleVendorFnUsages.contains(usage)
        }

        return false
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
                    requestFnHoldStart(source: "fn-cg-flags")
                } else {
                    endHold(source: "fn-cg-flags")
                }
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if Self.shouldCancelRecordingWithEscape(
            keyCode: keyCode,
            isRepeat: isRepeat,
            recordingIsActive: escapeCanCancelRecording
        ), cancelRecordingWithEscape(source: "escape-cg-key") {
            return nil
        }

        if let holdSpec, holdSpec.matchesFnKeyEvent(event), !isRepeat {
            if !fnIsDown {
                fnIsDown = true
                requestFnHoldStart(source: "fn-cg-key")
            }
            return nil
        }

        if let toggleSpec, toggleSpec.matchesKeyEvent(event), !isRepeat {
            guard togglePressGate.begin(
                at: ProcessInfo.processInfo.systemUptime,
                isRepeat: isRepeat
            ) else {
                return nil
            }
            guard handleToggleKeyDown(source: "toggle-cg-key") else {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }

        if let fallbackHoldSpec, fallbackHoldSpec.matchesKeyEvent(event), !isRepeat {
            if !holdFallbackIsDown {
                holdFallbackIsDown = true
                startHold(source: "fallback-cg-key")
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(
            event.getIntegerValueField(.keyboardEventKeycode)
        )
        if keyCode == CGKeyCode(kVK_Space), togglePressGate.isPressed {
            togglePressGate.end()
            return nil
        }

        if let holdSpec, holdSpec.matchesFnKeyEvent(event) {
            if fnIsDown {
                fnIsDown = false
                endHold(source: "fn-cg-key")
            }
            return nil
        }

        if let fallbackHoldSpec, fallbackHoldSpec.matchesKeyEvent(event) {
            if holdFallbackIsDown {
                holdFallbackIsDown = false
                endHold(source: "fallback-cg-key")
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
                    requestFnHoldStart(source: "fn-nsevent-flags")
                } else {
                    endHold(source: "fn-nsevent-flags")
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

        if Self.shouldCancelRecordingWithEscape(
            keyCode: snapshot.keyCode,
            isRepeat: snapshot.isRepeat,
            recordingIsActive: escapeCanCancelRecording
        ),
           cancelRecordingWithEscape(source: "escape-nsevent-key") {
            return true
        }

        if let holdSpec, holdSpec.matchesFnKeyEvent(snapshot) {
            if !fnIsDown {
                fnIsDown = true
                requestFnHoldStart(source: "fn-nsevent-key")
            }
            return true
        }

        if let toggleSpec, toggleSpec.matchesKeyEvent(snapshot) {
            guard togglePressGate.begin(
                at: ProcessInfo.processInfo.systemUptime,
                isRepeat: snapshot.isRepeat
            ) else {
                return true
            }
            guard handleToggleKeyDown(source: "toggle-nsevent-key") else {
                return false
            }
            return true
        }

        if let fallbackHoldSpec, fallbackHoldSpec.matchesKeyEvent(snapshot) {
            if !holdFallbackIsDown {
                holdFallbackIsDown = true
                startHold(source: "fallback-nsevent-key")
            }
            return true
        }

        return false
    }

    private func startHold(source: String) {
        guard !toggleRecordingIsActive else {
            return
        }

        guard activeHoldSource == nil else {
            return
        }

        activeHoldSource = source
        LocalFlowLogger.log("Hotkey hold start source=\(source)")
        onDiagnosticEvent?("hold start: \(Self.displayName(for: source))")
        onHoldStart?()
    }

    private func endHold(source: String) {
        if cancelPendingHoldStart() {
            return
        }

        guard activeHoldSource != nil else {
            return
        }

        if source.hasPrefix("fn-") {
            scheduleFnHoldEnd(source: source)
            return
        }

        completeHoldEnd(source: source)
    }

    private func scheduleFnHoldEnd(source: String) {
        pendingFnReleaseTask?.cancel()
        pendingFnReleaseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self, !Task.isCancelled else {
                return
            }

            self.pendingFnReleaseTask = nil
            let fnIsStillDown = CGEventSource.flagsState(
                .combinedSessionState
            ).contains(.maskSecondaryFn)
            guard !fnIsStillDown else {
                return
            }

            self.fnIsDown = false
            self.hidFnIsDown = false
            self.completeHoldEnd(source: source)
        }
    }

    private func completeHoldEnd(source: String) {
        guard activeHoldSource != nil else {
            return
        }

        activeHoldSource = nil
        LocalFlowLogger.log("Hotkey hold end source=\(source)")
        onDiagnosticEvent?("hold end: \(Self.displayName(for: source))")
        onHoldEnd?()
    }

    private func requestFnHoldStart(source: String) {
        cancelPendingFnRelease()

        guard toggleUsesFnModifier else {
            startHold(source: source)
            return
        }

        guard activeHoldSource == nil else {
            return
        }

        pendingHoldSource = source
        pendingHoldTask?.cancel()
        pendingHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.fnCombinationDelayNanoseconds)
            await MainActor.run {
                guard let self, !Task.isCancelled else {
                    return
                }

                let source = self.pendingHoldSource ?? "fn"
                self.pendingHoldTask = nil
                self.pendingHoldSource = nil
                self.startHold(source: source)
            }
        }
    }

    @discardableResult
    private func cancelPendingHoldStart() -> Bool {
        let hadPendingHold = pendingHoldTask != nil
        pendingHoldTask?.cancel()
        pendingHoldTask = nil
        pendingHoldSource = nil
        return hadPendingHold
    }

    private func cancelPendingFnRelease() {
        pendingFnReleaseTask?.cancel()
        pendingFnReleaseTask = nil
    }

    private var toggleUsesFnModifier: Bool {
        toggleSpec?.modifiers.contains(.maskSecondaryFn) == true
    }

    private func handleToggleKeyDown(source: String) -> Bool {
        guard toggleUsesFnModifier else {
            triggerToggleIfNeeded(source: source)
            return true
        }

        guard fnIsDown || hidFnIsDown || pendingHoldTask != nil || activeHoldSource != nil else {
            return false
        }

        if activeHoldSource != nil, !toggleRecordingIsActive {
            lockActiveHoldAsToggle(source: source)
            return true
        }

        activeHoldSource = nil
        cancelPendingHoldStart()
        triggerToggleIfNeeded(source: source)
        return true
    }

    private func lockActiveHoldAsToggle(source: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggleTime > 0.25 else {
            return
        }

        let holdSource = activeHoldSource ?? "fn"
        lastToggleTime = now
        activeHoldSource = nil
        cancelPendingHoldStart()
        cancelPendingFnRelease()
        toggleRecordingIsActive = true
        LocalFlowLogger.log("Hotkey hold locked source=\(source) holdSource=\(holdSource)")
        onDiagnosticEvent?("hold locked: \(Self.displayName(for: source))")
        onHoldLocked?()
    }

    private var escapeCanCancelRecording: Bool {
        applicationRecordingIsActive
            || toggleRecordingIsActive
            || activeHoldSource != nil
            || pendingHoldTask != nil
    }

    private func cancelRecordingWithEscape(source: String) -> Bool {
        guard escapeCanCancelRecording else {
            return false
        }

        toggleRecordingIsActive = false
        activeHoldSource = nil
        cancelPendingHoldStart()
        cancelPendingFnRelease()
        LocalFlowLogger.log("Hotkey cancel source=\(source)")
        onDiagnosticEvent?("cancel: \(Self.displayName(for: source))")
        onCancel?()
        return true
    }

    static func shouldCancelRecordingWithEscape(
        keyCode: UInt16,
        isRepeat: Bool,
        recordingIsActive: Bool
    ) -> Bool {
        keyCode == escapeKeyCode && !isRepeat && recordingIsActive
    }

    private func triggerToggleIfNeeded(source: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggleTime > 0.25 else {
            return
        }

        lastToggleTime = now
        toggleRecordingIsActive.toggle()
        LocalFlowLogger.log("Hotkey toggle source=\(source)")
        onDiagnosticEvent?("toggle: \(Self.displayName(for: source))")
        onToggle?()
    }

    private func handleCarbonHotkey(id: UInt32, eventKind: UInt32) {
        switch (id, eventKind) {
        case (Self.carbonFallbackHoldID, UInt32(kEventHotKeyPressed)):
            if !holdFallbackIsDown {
                holdFallbackIsDown = true
                startHold(source: "fallback-carbon")
            }
        case (Self.carbonFallbackHoldID, UInt32(kEventHotKeyReleased)):
            if holdFallbackIsDown {
                holdFallbackIsDown = false
                endHold(source: "fallback-carbon")
            }
        case (Self.carbonToggleID, UInt32(kEventHotKeyPressed)):
            triggerToggleIfNeeded(source: "toggle-carbon")
        default:
            break
        }
    }

    private func handleNSEventKeyUp(_ snapshot: HotkeyEventSnapshot) -> Bool {
        if snapshot.keyCode == UInt16(kVK_Space),
           togglePressGate.isPressed {
            togglePressGate.end()
            return true
        }

        if let holdSpec, holdSpec.matchesFnKeyEvent(snapshot) {
            if fnIsDown {
                fnIsDown = false
                endHold(source: "fn-nsevent-key")
            }
            return true
        }

        if let fallbackHoldSpec, fallbackHoldSpec.matchesKeyEvent(snapshot) {
            if holdFallbackIsDown {
                holdFallbackIsDown = false
                endHold(source: "fallback-nsevent-key")
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

    private static func description(for tapOption: CGEventTapOptions) -> String {
        switch tapOption {
        case .defaultTap:
            return "active"
        case .listenOnly:
            return "listen"
        @unknown default:
            return "unknown"
        }
    }

    private static func displayName(for source: String) -> String {
        switch source {
        case "fn-cg-flags":
            return "Fn via CG flags"
        case "fn-cg-key":
            return "Fn via CG key"
        case "fn-nsevent-flags":
            return "Fn via NSEvent flags"
        case "fn-nsevent-key":
            return "Fn via NSEvent key"
        case "fn-hid":
            return "Fn via HID"
        case "fallback-carbon":
            return "Option+Space via Carbon"
        case "fallback-cg-key":
            return "Option+Space via CG key"
        case "fallback-nsevent-key":
            return "Option+Space via NSEvent"
        case "toggle-carbon":
            return "toggle via Carbon"
        case "toggle-cg-key":
            return "toggle via CG key"
        case "toggle-nsevent-key":
            return "toggle via NSEvent"
        case "escape-cg-key":
            return "Escape via CG key"
        case "escape-nsevent-key":
            return "Escape via NSEvent"
        default:
            return source
        }
    }

    private static let carbonSignature: OSType = 0x4C464C57 // LFLW
    private static let carbonFallbackHoldID: UInt32 = 1
    private static let carbonToggleID: UInt32 = 2
    private static let keyboardFnUsage = 0xE8
    private static let appleVendorUsagePage = 0xFF00
    private static let appleVendorFnUsages: Set<Int> = [3, 11, 13, 95]
    private static let escapeKeyCode: UInt16 = 53
    private static let fnCombinationDelayNanoseconds: UInt64 = 180_000_000
}
