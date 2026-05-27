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

    private func normalizedModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn])
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
    private var fnIsDown = false
    private var holdFallbackIsDown = false
    private(set) var isRunning = false

    init(holdHotkey: String, fallbackHoldHotkey: String, toggleHotkey: String) {
        self.holdSpec = HotkeySpec.parse(holdHotkey)
        self.fallbackHoldSpec = HotkeySpec.parse(fallbackHoldHotkey)
        self.toggleSpec = HotkeySpec.parse(toggleHotkey)
    }

    @discardableResult
    func start() -> Bool {
        stop()

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
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: refcon
        )

        guard let eventTap else {
            isRunning = false
            return false
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
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isRunning = false
        fnIsDown = false
        holdFallbackIsDown = false
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
            onToggle?()
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
}
