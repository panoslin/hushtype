import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Reads and writes the focused text field of the frontmost app through the Accessibility API.
/// Requires the user to grant Hushtype Accessibility access.
public enum FocusedElement {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    public static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// True when typing must not be observed or produced: the screen is locked, the login window is
    /// in front, or an app has turned on Secure Event Input (password fields, Terminal "Secure
    /// Keyboard Entry", 1Password, …).
    public static var isSecureContext: Bool {
        if IsSecureEventInputEnabled() { return true }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" { return true }
        if let d = CGSessionCopyCurrentDictionary() as? [String: Any],
           (d["CGSSessionScreenIsLocked"] as? Bool) == true || (d["CGSSessionScreenIsLocked"] as? Int) == 1 {
            return true
        }
        if let el = focused(), let role: String = attr(el, kAXRoleAttribute), role == "AXSecureTextField" { return true }
        if let el = focused(), let sub: String = attr(el, kAXSubroleAttribute), sub == kAXSecureTextFieldSubrole { return true }
        return false
    }

    /// Pids we already asked to expose their accessibility tree.
    nonisolated(unsafe) private static var exposed: Set<pid_t> = []

    /// Electron apps (Obsidian, Slack, VS Code, Notion, Discord…) and Chrome build their accessibility
    /// tree only when asked; without this their editors look like an empty window.
    public static func exposeTree(of app: NSRunningApplication?) {
        guard let pid = app?.processIdentifier, !exposed.contains(pid) else { return }
        exposed.insert(pid)
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        _ = AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func focused() -> AXUIElement? {
        let front = NSWorkspace.shared.frontmostApplication
        exposeTree(of: front)
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &v) != .success, let front {
            // Some Chromium-based apps (ChatGPT for Mac) fail the system-wide query but answer when the
            // app itself is asked.
            let app = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.25)
            v = nil
            _ = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v)
        }
        guard let el = v, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        let e = el as! AXUIElement
        AXUIElementSetMessagingTimeout(e, 0.25)
        return e
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    /// A text element we can re-read later (to learn from the user's corrections).
    public struct Handle: @unchecked Sendable {
        let element: AXUIElement
        public var value: String? { FocusedElement.attr(element, kAXValueAttribute) }
        /// Caret offset (UTF-16) in the element right now.
        public var caret: Int? { FocusedElement.selectedRange(element).map { $0.location } }
    }

    public static func currentHandle() -> Handle? { focused().map(Handle.init) }

    public enum FocusKind: Equatable, Sendable {
        /// A field, text view, web text area, terminal…
        case text
        /// Definitely not somewhere to type: a file list, a button, the Finder desktop.
        case notText(role: String)
        /// The app doesn't say (no accessibility answer, or a generic window / group / web view).
        /// Many apps with their own UI toolkit (Feishu / Lark, some Chromium shells, games, remote
        /// desktops) look like this even with the caret in a chat box.
        case unknown(role: String)
    }

    /// Roles that are never a place to type.
    static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXColumn",
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle",
        "AXSlider", "AXIncrementor", "AXImage", "AXLink", "AXTabGroup", "AXToolbar",
        "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem", "AXDockItem",
    ]

    /// Where the focus is, as far as Accessibility can tell.
    public static var focusKind: FocusKind {
        guard let el = focused() else { return .unknown(role: "none") }
        let role: String = attr(el, kAXRoleAttribute) ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"].contains(role) { return .text }
        // Rich editors and web contenteditable regions expose a caret range even under other roles.
        var names: CFArray?
        if AXUIElementCopyAttributeNames(el, &names) == .success, let list = names as? [String] {
            if list.contains(kAXSelectedTextRangeAttribute as String) || list.contains(kAXInsertionPointLineNumberAttribute as String) {
                return .text
            }
        }
        if nonTextRoles.contains(role) { return .notText(role: role) }
        // Finder's only text inputs (search, rename) are real text fields; anything else there is
        // the desktop or a file view.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" { return .notText(role: role) }
        return .unknown(role: role.isEmpty ? "?" : role)
    }

    /// Whether the focused element is known to accept typed text.
    public static var focusIsTextInput: Bool { focusKind == .text }

    /// Snapshot of where the text will go. Cheap (a few AX calls, each capped at 250 ms).
    /// Selected text in a given app, read from that app's own focused element. Used when Hushtype's
    /// menu bar icon is clicked: by then the system-wide focus is the menu bar, not the app.
    public static func selectedText(inApp pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let el: AXUIElement = attr(axApp, kAXFocusedUIElementAttribute) else { return nil }
        if let sel: String = attr(el, kAXSelectedTextAttribute), !sel.isEmpty { return sel }
        // Some text views only expose the value and the selected range.
        if let value: String = attr(el, kAXValueAttribute), let r = selectedRange(el), r.length > 0 {
            let ns = value as NSString
            guard r.location + r.length <= ns.length else { return nil }
            return ns.substring(with: r)
        }
        return nil
    }

    public static func context(budget: Int = RewritePrompt.contextBudget) -> DictationContext {
        var c = DictationContext()
        let app = NSWorkspace.shared.frontmostApplication
        c.appName = app?.localizedName
        c.bundleID = app?.bundleIdentifier
        if let pid = app?.processIdentifier {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            if let win: AXUIElement = attr(axApp, kAXFocusedWindowAttribute) {
                c.windowTitle = attr(win, kAXTitleAttribute)
                if let doc: String = attr(win, kAXDocumentAttribute), doc.hasPrefix("http") { c.url = doc }
            }
        }
        guard let el = focused() else { return c }
        if let sel: String = attr(el, kAXSelectedTextAttribute), !sel.isEmpty { c.selectedText = sel }
        if let value: String = attr(el, kAXValueAttribute), let range = selectedRange(el) {
            let ns = value as NSString
            let loc = min(range.location, ns.length)
            let end = min(loc + range.length, ns.length)
            let beforeStart = max(0, loc - budget)
            c.textBefore = ns.substring(with: NSRange(location: beforeStart, length: loc - beforeStart))
            c.textAfter = ns.substring(with: NSRange(location: end, length: min(budget, ns.length - end)))
        }
        if (c.url ?? "").isEmpty, let url: URL = attr(el, kAXURLAttribute) { c.url = url.absoluteString }
        return c
    }

    static func selectedRange(_ el: AXUIElement) -> NSRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let ax = v, CFGetTypeID(ax) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(ax as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    /// Replaces the selection (or inserts at the caret) in the focused element. Returns false when
    /// the element does not accept AX text writes; callers then fall back to paste.
    public static func insertViaAX(_ text: String) -> Bool {
        guard let el = focused() else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        let before: String? = attr(el, kAXValueAttribute)
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        // Some apps (Electron, many web views) report success but ignore the write; verify.
        let after: String? = attr(el, kAXValueAttribute)
        if let b = before, let a = after { return a != b || text.isEmpty }
        return true
    }
}
