import Foundation

public enum HotkeyTrigger: String, Codable, Sendable, CaseIterable {
    case fn, rightOption, rightCommand, rightControl

    public var title: String {
        switch self {
        case .fn: return "fn / 🌐"
        case .rightOption: return String(localized: "右 Option ⌥")
        case .rightCommand: return String(localized: "右 Command ⌘")
        case .rightControl: return String(localized: "右 Control ⌃")
        }
    }
}

/// How long recognition models stay in memory when unused.
public enum MemoryPolicy: String, Codable, Sendable, CaseIterable {
    /// Keep loaded; release after 30 min idle or when macOS reports memory pressure.
    case automatic
    /// Never release (fastest, ~400 MB resident).
    case resident
    /// Release after 5 min idle.
    case saver

    public var idleSeconds: TimeInterval? {
        switch self {
        case .automatic: return 30 * 60
        case .resident: return nil
        case .saver: return 5 * 60
        }
    }

    public var title: String {
        switch self {
        case .automatic: return String(localized: "自动（推荐）：内存紧张或 30 分钟不用时释放")
        case .resident: return String(localized: "常驻：始终保持加载（约 400 MB），最快")
        case .saver: return String(localized: "省内存：5 分钟不用就释放")
        }
    }
}

public enum SoundTheme: String, Codable, Sendable, CaseIterable {
    case droplet, marimba, glass
    public var title: String {
        switch self { case .droplet: return String(localized: "水滴"); case .marimba: return String(localized: "木琴"); case .glass: return String(localized: "玻璃") }
    }
}

/// Simplified vs Traditional Chinese output. `.system` follows the macOS preferred language
/// (zh-Hant / zh-TW / zh-HK / zh-MO → Traditional).
public enum ScriptPreference: String, Codable, Sendable, CaseIterable {
    case system, simplified, traditional
    public var title: String {
        switch self { case .system: return String(localized: "跟随系统"); case .simplified: return String(localized: "简体"); case .traditional: return String(localized: "繁體") }
    }
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> ChineseScript {
        switch self {
        case .simplified: return .simplified
        case .traditional: return .traditional
        case .system:
            guard let zh = preferredLanguages.first(where: { $0.lowercased().hasPrefix("zh") })?.lowercased() else { return .simplified }
            return ["hant", "-tw", "-hk", "-mo"].contains(where: zh.contains) ? .traditional : .simplified
        }
    }
}

public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case system, light, dark
    public var title: String {
        switch self { case .system: return String(localized: "跟随系统"); case .light: return String(localized: "浅色"); case .dark: return String(localized: "深色") }
    }
}

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    /// User's own Anthropic API key.
    case anthropicKey
    /// Hushtype Cloud / self-hosted proxy with a user token.
    case proxy
    /// No LLM: insert the local transcript as is.
    case offline
}

/// User preferences. Secrets (API key, proxy token) live in the Keychain, not here.
public struct HushtypeSettings: Codable, Sendable, Equatable {
    public var trigger: HotkeyTrigger = .fn
    /// A recorded shortcut; overrides `trigger` when set.
    public var customHotkey: Hotkey?
    /// Double-tap the trigger to dictate hands-free until the next tap.
    public var doubleTapHandsFree = true
    /// Tap once to start, tap again to finish (default). Off: hold to talk.
    public var tapToToggle = true
    public var microphoneUID: String?
    public var provider: ProviderKind = .anthropicKey
    public var proxyURL: String = ""
    public var model: RewriteModel = .sonnet
    public var useSecondEngine = true
    public var memoryPolicy: MemoryPolicy = .automatic
    public var appearance: AppearanceMode = .system
    /// Keep a Dock icon even when no Hushtype window is open.
    public var showInDock = false
    /// Mute other audio (music, videos) while recording.
    public var muteWhileDictating = true
    public var sendContext = true
    public var script: ChineseScript = .simplified
    public var scriptPreference: ScriptPreference = .system
    public var dictionary: [String] = []
    /// Add terms the user corrects after insertion to the dictionary.
    public var learnFromEdits = true
    public var playSounds = true
    public var soundTheme: SoundTheme = .droplet
    /// nil = keep forever.
    public var historyDays: Int? = 30
    public var keepAudio = false
    public var hasOnboarded = false
    /// Bundle IDs where Hushtype never reads screen context (password managers are always excluded).
    public var contextExcluded: [String] = []

    public init() {}

    /// The dictation shortcut in effect.
    public var hotkey: Hotkey { customHotkey ?? trigger.hotkey }
    /// How to show it in the UI ("fn", "右 ⌥", "⌃⌥Space").
    public var hotkeyLabel: String { hotkey.label }

    // Tolerant decoding: a field added in a later version (or removed) must not reset the user's
    // other settings, so every key is optional with the property default as fallback.
    enum CodingKeys: String, CodingKey {
        case trigger, customHotkey, doubleTapHandsFree, tapToToggle, microphoneUID, provider, proxyURL, model, useSecondEngine, memoryPolicy, appearance, showInDock, muteWhileDictating,
             sendContext, script, scriptPreference, dictionary, learnFromEdits, playSounds, soundTheme, historyDays, keepAudio, hasOnboarded, contextExcluded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HushtypeSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
        trigger = v(.trigger, d.trigger)
        customHotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .customHotkey)) ?? nil
        doubleTapHandsFree = v(.doubleTapHandsFree, d.doubleTapHandsFree)
        tapToToggle = v(.tapToToggle, d.tapToToggle)
        microphoneUID = (try? c.decodeIfPresent(String.self, forKey: .microphoneUID)) ?? nil
        provider = v(.provider, d.provider)
        proxyURL = v(.proxyURL, d.proxyURL)
        model = v(.model, d.model)
        useSecondEngine = v(.useSecondEngine, d.useSecondEngine)
        memoryPolicy = v(.memoryPolicy, d.memoryPolicy)
        appearance = v(.appearance, d.appearance)
        showInDock = v(.showInDock, d.showInDock)
        muteWhileDictating = v(.muteWhileDictating, d.muteWhileDictating)
        sendContext = v(.sendContext, d.sendContext)
        script = v(.script, d.script)
        scriptPreference = v(.scriptPreference, d.scriptPreference)
        dictionary = v(.dictionary, d.dictionary)
        learnFromEdits = v(.learnFromEdits, d.learnFromEdits)
        playSounds = v(.playSounds, d.playSounds)
        soundTheme = v(.soundTheme, d.soundTheme)
        // Stored as days, with -1 meaning "keep forever" (nil would be indistinguishable from missing).
        let days = v(.historyDays, d.historyDays ?? -1)
        historyDays = days < 0 ? nil : days
        keepAudio = v(.keepAudio, d.keepAudio)
        hasOnboarded = v(.hasOnboarded, d.hasOnboarded)
        contextExcluded = v(.contextExcluded, d.contextExcluded)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trigger, forKey: .trigger)
        try c.encodeIfPresent(customHotkey, forKey: .customHotkey)
        try c.encode(doubleTapHandsFree, forKey: .doubleTapHandsFree)
        try c.encode(tapToToggle, forKey: .tapToToggle)
        try c.encodeIfPresent(microphoneUID, forKey: .microphoneUID)
        try c.encode(provider, forKey: .provider)
        try c.encode(proxyURL, forKey: .proxyURL)
        try c.encode(model, forKey: .model)
        try c.encode(useSecondEngine, forKey: .useSecondEngine)
        try c.encode(memoryPolicy, forKey: .memoryPolicy)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(showInDock, forKey: .showInDock)
        try c.encode(muteWhileDictating, forKey: .muteWhileDictating)
        try c.encode(sendContext, forKey: .sendContext)
        try c.encode(script, forKey: .script)
        try c.encode(scriptPreference, forKey: .scriptPreference)
        try c.encode(dictionary, forKey: .dictionary)
        try c.encode(learnFromEdits, forKey: .learnFromEdits)
        try c.encode(playSounds, forKey: .playSounds)
        try c.encode(soundTheme, forKey: .soundTheme)
        try c.encode(historyDays ?? -1, forKey: .historyDays)
        try c.encode(keepAudio, forKey: .keepAudio)
        try c.encode(hasOnboarded, forKey: .hasOnboarded)
        try c.encode(contextExcluded, forKey: .contextExcluded)
    }

    public static let key = "hushtype.settings.v1"

    public static func load(_ d: UserDefaults = .standard) -> HushtypeSettings {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(HushtypeSettings.self, from: data) else {
            return HushtypeSettings()
        }
        return s
    }

    public func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }

    public func engineOptions() -> EngineOptions {
        var o = EngineOptions()
        o.script = scriptPreference.resolved()
        o.dictionary = dictionary
        o.useSecondEngine = useSecondEngine
        o.rewriteEnabled = provider != .offline
        return o
    }

    /// Apps whose text Hushtype must never read, regardless of settings.
    public static let neverReadContext: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
    ]

    public func allowsContext(for bundleID: String?) -> Bool {
        guard sendContext, let b = bundleID else { return sendContext }
        return !Self.neverReadContext.contains(b) && !contextExcluded.contains(b)
    }
}

/// API key and proxy token, stored in the Keychain and cached in memory.
///
/// The cache is filled by `load()` off the main thread: a Keychain read can block on a system
/// access prompt, and that must never freeze the UI or the hotkey path.
public enum Secrets {
    static let service = "app.hushtype.Hushtype"
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static var loaded = false

    /// Reads both secrets from the Keychain into memory. Call from a background task.
    public static func load() {
        var fresh: [String: String] = [:]
        for account in ["anthropic-api-key", "proxy-token"] {
            if let v = try? Keychain.read(service: service, account: account), !v.isEmpty { fresh[account] = v }
        }
        lock.lock(); cache = fresh; loaded = true; lock.unlock()
    }

    public static var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded }

    private static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[account]
    }

    private static func set(_ account: String, _ value: String?) {
        lock.lock()
        if let v = value, !v.isEmpty { cache[account] = v } else { cache[account] = nil }
        lock.unlock()
        if let v = value, !v.isEmpty { try? Keychain.write(v, service: service, account: account) }
        else { Keychain.delete(service: service, account: account) }
    }

    public static var anthropicKey: String? {
        get { get("anthropic-api-key") }
        set { set("anthropic-api-key", newValue) }
    }

    public static var proxyToken: String? {
        get { get("proxy-token") }
        set { set("proxy-token", newValue) }
    }

    /// QA only: `--qa-key-file <path>` (a 0600 file) supplies the key without touching the
    /// Keychain, for unattended end-to-end tests.
    static let qaKey: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--qa-key-file"), i + 1 < a.count,
              let k = try? String(contentsOfFile: a[i + 1], encoding: .utf8) else { return nil }
        let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }()

    public static func backend(for s: HushtypeSettings) -> RewriteBackend? {
        switch s.provider {
        case .anthropicKey:
            if let k = qaKey { return .anthropic(apiKey: k) }
            return anthropicKey.map { .anthropic(apiKey: $0) }
        case .proxy:
            guard let url = URL(string: s.proxyURL), url.scheme == "https", let t = proxyToken else { return nil }
            return .proxy(baseURL: url, token: t)
        case .offline:
            return nil
        }
    }
}
