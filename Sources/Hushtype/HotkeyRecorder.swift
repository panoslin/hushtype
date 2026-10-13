import AppKit
import HushtypeCore
import SwiftUI

/// "Press the shortcut you want": records a single modifier key (fn, right ⌥…) or a combo (⌃⌥Space).
struct HotkeyRecorder: View {
    @ObservedObject var app: AppModel
    var onChanged: () -> Void
    @Local private var recording = false
    @Local private var hint: String?
    @Local private var monitor: Any?
    @Local private var pendingModifier: UInt16?
    @Local private var sawKey = false

    var body: some View {
        HStack(spacing: 10) {
            if recording {
                Text(String(localized: "请按下新的快捷键…")).foregroundStyle(.secondary)
            } else {
                Keycap(label: app.settings.hotkeyLabel)
            }
            Spacer()
            if let hint { Text(hint).font(.callout).foregroundStyle(.orange) }
            if recording {
                Button(String(localized: "取消")) { stop() }
            } else {
                if app.settings.customHotkey != nil {
                    Button(String(localized: "恢复 fn")) {
                        app.settings.customHotkey = nil
                        app.settings.trigger = .fn
                        onChanged()
                    }
                }
                Button(String(localized: "录制快捷键")) { start() }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = nil
        recording = true
        pendingModifier = nil
        sawKey = false
        app.setHotkeySuspended?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { e in
            handle(e)
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        app.setHotkeySuspended?(false)
    }

    private func save(_ hk: Hotkey) {
        app.settings.customHotkey = hk
        stop()
        onChanged()
    }

    private func handle(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if e.type == .keyDown {
            sawKey = true
            if e.keyCode == 53 && mods.intersection([.command, .option, .control, .shift]).isEmpty { stop(); return }
            let raw = mods.rawValue & Hotkey.modifierMask
            let hk = Hotkey(keyCode: e.keyCode, modifiers: raw)
            if hk.isValid { save(hk) } else { hint = String(localized: "组合键需要带 ⌘、⌥ 或 ⌃，或者只按一个修饰键") }
            return
        }
        // flagsChanged: a lone modifier pressed and released (no other key) becomes the shortcut.
        guard Hotkey.modifierKeys[e.keyCode] != nil else { return }
        let pressed = !mods.intersection([.command, .option, .control, .shift, .function]).isEmpty
            && Self.isDown(e.keyCode, mods)
        if pressed {
            pendingModifier = pendingModifier == nil ? e.keyCode : 0  // 0 = more than one modifier held
            sawKey = false
        } else if let p = pendingModifier, p == e.keyCode, !sawKey {
            save(Hotkey(keyCode: p))
        } else if mods.intersection([.command, .option, .control, .shift, .function]).isEmpty {
            pendingModifier = nil
        }
    }

    static func isDown(_ code: UInt16, _ mods: NSEvent.ModifierFlags) -> Bool {
        switch code {
        case 63: return mods.contains(.function)
        case 54, 55: return mods.contains(.command)
        case 58, 61: return mods.contains(.option)
        case 59, 62: return mods.contains(.control)
        default: return mods.contains(.shift)
        }
    }
}
