import AppKit
import Carbon.HIToolbox
import CoreGraphics
import HushtypeCore

/// Watches the dictation shortcut system-wide with a CGEventTap. A modifier-only shortcut (fn, right ⌥…)
/// is observed and passed through; a key combo (⌃⌥Space…) is swallowed so it doesn't also type.
///
/// Gestures:
/// - Hold the trigger: push-to-talk; release to finish.
/// - Tap the trigger (when `tapToToggle`): starts dictating; tap again to finish.
/// - Double-tap the trigger (when not `tapToToggle`): hands-free; tap once more to finish.
/// - Esc while dictating: cancel.
/// - Any other key while holding (e.g. fn+arrow): treated as a shortcut, the dictation is discarded.
@MainActor
final class HotkeyMonitor {
    enum Event { case begin, finish, cancel, handsFree, command }

    var hotkey: Hotkey = .fn
    /// While recording a new shortcut in Settings, presses must not start dictation.
    var suspended = false
    var doubleTapHandsFree = true
    /// Tap the trigger once to start and again to finish (holding still works as push-to-talk).
    var tapToToggle = true
    var onEvent: ((Event) -> Void)?
    /// Raw trigger key state, for the onboarding key test.
    var onTriggerState: ((Bool) -> Void)?
    /// True while a dictation is in progress (set by the controller), so Esc is only swallowed then.
    var isDictating = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var down = false
    /// Timestamp of the event being handled (seconds since boot, from the event itself).
    var eventTime: TimeInterval = 0
    private var downAt: TimeInterval = -1_000
    private var lastTapUp: TimeInterval = -1_000
    private var handsFree = false
    private var otherKeyWhileDown = false

    /// Shorter than this counts as a tap, not a hold.
    static let tapThreshold: TimeInterval = 0.25
    /// Another key pressed this soon after the trigger means a shortcut (fn+←, fn+F5…). Later key
    /// presses are ignored: they are accidental touches during dictation and must never discard it.
    static let shortcutWindow: TimeInterval = 0.5
    static let doubleTapWindow: TimeInterval = 0.4

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { monitor.reenable() }
                return Unmanaged.passUnretained(event)
            }
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // When the key actually went down/up (ns since boot): handling can lag behind, e.g. while
            // the microphone starts, and tap-vs-hold must not depend on that.
            let at = TimeInterval(event.timestamp) / 1_000_000_000
            let swallow = MainActor.assumeIsolated {
                monitor.eventTime = at
                return monitor.handle(type: type, keycode: keycode, flags: flags, isRepeat: isRepeat)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }

    private func reenable() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
    }

    /// Called by the controller when a dictation ends for any reason other than the trigger.
    func reset() {
        handsFree = false
        down = false
    }

    /// Which CGEventFlags bit a physical modifier key sets.
    static func flag(forModifierKey code: UInt16) -> CGEventFlags {
        switch code {
        case 63: return .maskSecondaryFn
        case 54, 55: return .maskCommand
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        default: return .maskShift
        }
    }

    private func comboModifiersMatch(_ flags: CGEventFlags) -> Bool {
        var have: UInt = 0
        if flags.contains(.maskCommand) { have |= Hotkey.command }
        if flags.contains(.maskAlternate) { have |= Hotkey.option }
        if flags.contains(.maskControl) { have |= Hotkey.control }
        if flags.contains(.maskShift) { have |= Hotkey.shift }
        // Extra ⇧ on top of a shortcut without ⇧ means voice command mode.
        if hotkey.modifiers & Hotkey.shift == 0 { have &= ~Hotkey.shift }
        return have == hotkey.modifiers
    }

    /// - Returns: true to swallow the event (combo shortcuts only).
    private func handle(type: CGEventType, keycode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        if suspended { return false }
        if hotkey.isModifierOnly {
            handleModifierOnly(type: type, keycode: keycode, flags: flags)
            return false
        }
        // Combo shortcut: key down/up of the chosen key with the chosen modifiers.
        if keycode == Int64(hotkey.keyCode) {
            if type == .keyDown && (down || comboModifiersMatch(flags)) {
                if !isRepeat { triggerChanged(pressed: true, flags: flags) }
                return true
            }
            if type == .keyUp && down {
                triggerChanged(pressed: false, flags: flags)
                return true
            }
        }
        if type == .keyDown, keycode == Int64(kVK_Escape), isDictating {
            handsFree = false
            down = false
            onEvent?(.cancel)
        }
        return false
    }

    private func handleModifierOnly(type: CGEventType, keycode: Int64, flags: CGEventFlags) {
        if type == .keyDown {
            if keycode == Int64(kVK_Escape), isDictating {
                handsFree = false
                down = false
                onEvent?(.cancel)
                return
            }
            if down, (eventTime - downAt) < Self.shortcutWindow { otherKeyWhileDown = true }
            return
        }
        guard type == .flagsChanged, keycode == Int64(hotkey.keyCode) else {
            if down, type == .flagsChanged {
                // Shift with the trigger switches to voice command mode; any other modifier means the
                // user is typing a shortcut, so the dictation is discarded.
                if keycode == Int64(kVK_Shift) || keycode == Int64(kVK_RightShift) {
                    if flags.contains(.maskShift) { onEvent?(.command) }
                } else {
                    if (eventTime - downAt) < Self.shortcutWindow { otherKeyWhileDown = true }
                }
            }
            return
        }
        triggerChanged(pressed: flags.contains(Self.flag(forModifierKey: hotkey.keyCode)), flags: flags)
    }

    private func triggerChanged(pressed: Bool, flags: CGEventFlags) {
        Log.info("trigger \(pressed ? "down" : "up")")
        onTriggerState?(pressed)
        if pressed && !down {
            down = true
            downAt = eventTime
            otherKeyWhileDown = false
            if handsFree {
                // Tap during hands-free ends it.
                return
            }
            onEvent?(.begin)
            if flags.contains(.maskShift) && hotkey.modifiers & Hotkey.shift == 0 && Self.flag(forModifierKey: hotkey.keyCode) != .maskShift {
                onEvent?(.command)
            }
        } else if !pressed && down {
            down = false
            let held = (eventTime - downAt)
            if handsFree {
                handsFree = false
                onEvent?(.finish)
                return
            }
            if otherKeyWhileDown {
                onEvent?(.cancel)
                return
            }
            if held >= Self.tapThreshold {
                onEvent?(.finish)
                return
            }
            // A short tap.
            if tapToToggle {
                // Tap once to start, tap again to finish; the recording started on this press keeps going.
                handsFree = true
                onEvent?(.handsFree)
                return
            }
            let now = eventTime
            if doubleTapHandsFree, (now - lastTapUp) < Self.doubleTapWindow {
                handsFree = true
                lastTapUp = -1_000
                // Recording has been running since this press began; keep it going.
                onEvent?(.handsFree)
            } else {
                lastTapUp = now
                onEvent?(.cancel)
            }
        }
    }
}
