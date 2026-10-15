import AppKit
import Carbon.HIToolbox
import Foundation

/// Puts the finished text where the user's caret is.
public enum TextInserter {
    public enum Method: String, Sendable { case accessibility, paste, clipboardOnly }

    /// Apps where AX writes look successful but corrupt undo or formatting; always paste there.
    static let pasteOnly: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.tinyspeck.slackmacgap",
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "notion.id", "com.figma.Desktop", "md.obsidian", "com.hnc.Discord", "ru.keepcoder.Telegram",
        "com.tencent.xinWeChat", "com.electron.lark", "com.bytedance.lark",
    ]

    /// Adds a leading space when the new text would otherwise glue onto a preceding Latin word or
    /// sentence ("…done.Next" → "…done. Next"). CJK never gets a space.
    public static func spaced(_ text: String, after before: String?) -> String {
        guard let prev = before?.last, let first = text.first else { return text }
        if prev.isWhitespace || first.isWhitespace { return text }
        func latin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        let prevEndsSentence = ".!?,;:".contains(prev)
        if latin(first) && (latin(prev) || prevEndsSentence) { return " " + text }
        return text
    }

    /// - Returns: how the text was delivered.
    @MainActor
    public static func insert(_ text: String, bundleID: String?) async -> Method {
        guard !text.isEmpty else { return .accessibility }
        let forcePaste = bundleID.map(pasteOnly.contains) ?? false
        if !forcePaste, FocusedElement.insertViaAX(text) { return .accessibility }
        guard FocusedElement.isTrusted else {
            setPasteboard(text)
            return .clipboardOnly
        }
        await paste(text)
        return .paste
    }

    /// Paste through the clipboard, then restore whatever the user had copied.
    @MainActor
    static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        setPasteboard(text)
        let marker = pb.changeCount
        sendCommandV()
        // Give the target app time to read the pasteboard before restoring it.
        try? await Task.sleep(nanoseconds: 400_000_000)
        if pb.changeCount == marker { restore(saved, to: pb) }
    }

    public static func setPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Ask clipboard managers not to record this transient write.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
    }

    static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { dict in
            let it = NSPasteboardItem()
            for (t, v) in dict { it.setData(v, forType: t) }
            return it
        })
    }

    /// The key that produces "v" together with ⌘ in the current keyboard layout. Apps match ⌘V by
    /// character, so on Dvorak, AZERTY variants, Colemak… the ANSI "V" position would send another
    /// shortcut (Dvorak: ⌘K). "Dvorak – QWERTY ⌘" layouts are handled too: translation uses the ⌘ state.
    public static func commandVKeyCode() -> CGKeyCode {
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let src = source?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            if let code = keyCode(producing: "v", layoutData: data) { return code }
        }
        return CGKeyCode(kVK_ANSI_V)
    }

    /// Searches a 'uchr' keyboard layout for the key that types `char` while ⌘ is held.
    static func keyCode(producing char: Character, layoutData: Data) -> CGKeyCode? {
        layoutData.withUnsafeBytes { buf -> CGKeyCode? in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            let cmd = UInt32((cmdKey >> 8) & 0xFF)
            for code in 0..<UInt16(128) {
                var dead: UInt32 = 0
                var len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), cmd, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
                if st == noErr, len == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == String(char) {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }

    static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = commandVKeyCode()
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
