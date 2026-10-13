import Foundation

/// A user-chosen dictation shortcut: either a single modifier key pressed on its own (fn, right ⌥…,
/// told apart left/right), or a regular key with modifiers (⌃⌥Space, ⌘⇧D, F5…).
public struct Hotkey: Codable, Sendable, Equatable, Hashable {
    public var keyCode: UInt16
    /// Modifier flags for combos, in NSEvent.ModifierFlags raw values (⌘ ⌥ ⌃ ⇧ only). Empty for modifier-only.
    public var modifiers: UInt

    public init(keyCode: UInt16, modifiers: UInt = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // NSEvent.ModifierFlags raw values (kept here so HushtypeCore stays AppKit-free).
    public static let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20
    public static let modifierMask = shift | control | option | command

    /// Physical modifier keys, by virtual keycode.
    public static let modifierKeys: [UInt16: String] = [
        63: "fn", 54: String(localized: "右 ⌘"), 55: String(localized: "左 ⌘"), 61: String(localized: "右 ⌥"), 58: String(localized: "左 ⌥"), 62: String(localized: "右 ⌃"), 59: String(localized: "左 ⌃"), 60: String(localized: "右 ⇧"), 56: String(localized: "左 ⇧"),
    ]

    public var isModifierOnly: Bool { Self.modifierKeys[keyCode] != nil }

    public static let fn = Hotkey(keyCode: 63)

    public var label: String {
        if let m = Self.modifierKeys[keyCode] { return m }
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? String(localized: "键\(keyCode)"))
    }

    /// A combo is acceptable when it can't be confused with ordinary typing.
    public var isValid: Bool {
        if isModifierOnly { return true }
        let isFunctionKey = Self.functionKeys.contains(keyCode)
        return isFunctionKey || modifiers & (Self.command | Self.control | Self.option) != 0
    }

    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    static let keyNames: [UInt16: String] = {
        var m: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "esc", 117: "⌦",
                                   123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
                                   50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/"]
        let letters: [(UInt16, String)] = [(0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
                                           (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"),
                                           (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z")]
        for (k, v) in letters { m[k] = v }
        for (k, v) in [(29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9")] as [(UInt16, String)] { m[k] = v }
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, k) in fkeys.enumerated() { m[k] = "F\(i + 1)" }
        return m
    }()
}

extension HotkeyTrigger {
    public var hotkey: Hotkey {
        switch self {
        case .fn: return Hotkey(keyCode: 63)
        case .rightOption: return Hotkey(keyCode: 61)
        case .rightCommand: return Hotkey(keyCode: 54)
        case .rightControl: return Hotkey(keyCode: 62)
        }
    }
}
