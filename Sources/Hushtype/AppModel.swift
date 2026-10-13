import AppKit
import Network
import AVFoundation
import HushtypeCore
import ServiceManagement
import SwiftUI

/// App-wide state shared by the menu bar, settings, onboarding and the dictation controller.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: HushtypeSettings { didSet { if settings != oldValue { settingsChanged(oldValue) } } }
    @Published private(set) var engineState: EngineState = .notLoaded
    @Published private(set) var whisperState: EngineState = .notLoaded
    @Published var download: ModelManager.Progress?
    @Published var lastResult: HistoryItem?
    /// Text that had no field to go into; waits in the menu bar panel until copied.
    @Published var pendingText: String?
    /// The dictation key is held right now (onboarding shows it live).
    @Published var triggerDown = false
    /// Network reachability; without it Hushtype skips the cleanup step and inserts the local transcript.
    @Published private(set) var isOnline = true
    private let pathMonitor = NWPathMonitor()
    /// Set by the app delegate: pauses the global shortcut while a new one is being recorded.
    var setHotkeySuspended: ((Bool) -> Void)?
    /// Set by the app delegate: re-reads the shortcut after it changed.
    var onHotkeyChanged: (() -> Void)?
    /// Set by the app delegate: re-applies the Dock icon policy.
    var onDockPolicyChange: (() -> Void)?
    /// The dictation key has been pressed at least once since launch.
    @Published var triggerSeen = false
    @Published var permissions = Permissions.current()

    enum EngineState: Equatable { case notLoaded, loading(String), ready, failed(String) }

    let models = ModelManager()
    let history: HistoryStore
    /// The user's edits to inserted text, fed back into the prompt as preferences.
    let corrections = CorrectionMemory(directory: AppModel.supportDir)
    let rewriter: Rewriter
    let engine: DictationEngine
    /// Speech recognition runs in the `hushtype-engine` helper process (see RemoteEngine).
    let engines: RemoteEngine
    /// Whether models are currently in memory (for the status line only).
    @Published private(set) var modelsResident = false
    private var idleTimer: Timer?
    private var pressure: DispatchSourceMemoryPressure?

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushtype", isDirectory: true)
    }

    init() {
        LegacyMigration.run()
        // History, recordings and learned habits are personal: owner-only permissions.
        for d in [Self.supportDir, Self.supportDir.appendingPathComponent("History")] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
        }
        let s = HushtypeSettings.load()
        settings = s
        history = (try? HistoryStore(directory: Self.supportDir.appendingPathComponent("History")))
            ?? (try! HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("HushtypeHistory")))
        // Secrets load in the background (a Keychain prompt must not block launch); see loadSecrets().
        rewriter = Rewriter(backend: nil, model: s.model)
        engine = DictationEngine(rewriter: rewriter)
        engines = RemoteEngine(executable: RemoteEngine.bundled)
        history.prune(olderThanDays: s.historyDays)
        lastResult = history.recent(limit: 1).first
        startResourceManagement()
        loadSecrets()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                Log.info("network \(online ? "online" : "offline")")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "hushtype.network"))
    }

    /// Light / dark / follow system. `--qa-appearance light|dark` overrides for screenshots.
    func applyAppearance() {
        let a = CommandLine.arguments
        var mode = settings.appearance
        if let i = a.firstIndex(of: "--qa-appearance"), i + 1 < a.count, let m = AppearanceMode(rawValue: a[i + 1]) { mode = m }
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func loadSecrets() {
        Task.detached(priority: .userInitiated) {
            Secrets.load()
            await MainActor.run { self.reloadBackend() }
        }
    }

    /// Models are installed; they may or may not be in memory right now.
    var isReady: Bool { engineState == .ready }

    var rewriteConfigured: Bool { settings.provider == .offline || rewriter.backend != nil }

    /// Engine options for the next utterance, including what Hushtype learned from the user's edits.
    func engineOptions() -> EngineOptions {
        var o = settings.engineOptions()
        o.corrections = corrections.promptSection()
        return o
    }

    var wantsWhisper: Bool { settings.useSecondEngine && settings.provider != .offline && models.hasWhisper }

    func reloadBackend() {
        rewriter.backend = Secrets.backend(for: settings)
        rewriter.model = settings.model
        objectWillChange.send()
    }

    private func settingsChanged(_ old: HushtypeSettings) {
        settings.save()
        if old.provider != settings.provider || old.proxyURL != settings.proxyURL || old.model != settings.model {
            reloadBackend()
        }
        if old.useSecondEngine != settings.useSecondEngine {
            if settings.useSecondEngine {
                Task { await installWhisperIfNeeded() }
            } else {
                engines.stop()
                Task { await refreshResidency() }
            }
        }
        if old.appearance != settings.appearance { applyAppearance() }
        if old.showInDock != settings.showInDock { onDockPolicyChange?() }
        if old.historyDays != settings.historyDays { history.prune(olderThanDays: settings.historyDays) }
    }

    // MARK: engines

    /// Downloads missing models (with progress), then loads them so the first dictation is instant.
    func prepareEngines() async {
        if case .loading = engineState { return }
        if !models.hasSenseVoice {
            engineState = .loading(String(localized: "下载语音模型"))
            do {
                try await models.installSenseVoice { p in Task { @MainActor in self.download = p } }
            } catch {
                download = nil
                engineState = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
                return
            }
            download = nil
        }
        engineState = .loading(String(localized: "加载语音模型"))
        engines.warmUp(whisper: false)
        let loaded = await engines.waitLoaded(whisper: false, timeout: 60)
        engineState = loaded.sense ? .ready : .failed(String(localized: "语音模型加载失败，请在设置里重新下载"))
        await refreshResidency()
        await installWhisperIfNeeded()
    }

    func installWhisperIfNeeded() async {
        guard settings.useSecondEngine else { whisperState = .notLoaded; return }
        if case .loading = whisperState { return }
        do {
            if !models.hasWhisper {
                whisperState = .loading(String(localized: "下载英文增强模型"))
                try await models.installWhisper { p in Task { @MainActor in self.download = p } }
                download = nil
            }
            // The first load on a new Mac compiles the model for the Neural Engine (~2 min); do it now,
            // in the background, rather than during someone's first dictation.
            whisperState = .loading(String(localized: "准备英文增强模型（首次约 2 分钟）"))
            engines.warmUp(whisper: true)
            let loaded = await engines.waitLoaded(whisper: true, timeout: 900)
            whisperState = loaded.whisper ? .ready : .failed(String(localized: "英文增强模型加载失败"))
        } catch {
            download = nil
            whisperState = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        await refreshResidency()
    }

    /// Called when the hotkey goes down: start loading anything that was released, in parallel
    /// with the user speaking.
    func warmUpForDictation() {
        let w = wantsWhisper
        engines.warmUp(whisper: w)
        Task { await refreshResidency() }
    }

    func refreshResidency() async {
        modelsResident = engines.isRunning
    }

    // MARK: memory

    private func startResourceManagement() {
        // Idle check once a minute: a single cheap timer, tolerant so the system can coalesce wakeups.
        let t = Timer(timeInterval: Self.qaIdleSeconds.map { max(5, $0 / 2) } ?? 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.releaseIfIdle() }
        }
        t.tolerance = 20
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t

        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.settings.memoryPolicy != .resident else { return }
                if self.engines.stop() { Log.info("released models under memory pressure") }
                await self.refreshResidency()
            }
        }
        src.resume()
        pressure = src
    }

    /// QA hook: `--qa-idle <seconds>` overrides the idle-release threshold.
    static let qaIdleSeconds: TimeInterval? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--qa-idle"), i + 1 < a.count else { return nil }
        return TimeInterval(a[i + 1])
    }()

    private func releaseIfIdle() async {
        guard let idle = Self.qaIdleSeconds ?? settings.memoryPolicy.idleSeconds else { return }
        if engines.stopIfIdle(idle) {
            Log.info("released models after \(Int(idle))s idle")
            await refreshResidency()
        }
    }

    // MARK: permissions & login item

    struct Permissions: Equatable {
        var microphone: AVAuthorizationStatus
        var accessibility: Bool
        /// System Settings › Keyboard › "Press 🌐 key to": 0 = Do Nothing.
        var fnKeyFree: Bool

        static func current() -> Permissions {
            let fnUsage = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
            return Permissions(microphone: AVCaptureDevice.authorizationStatus(for: .audio),
                               accessibility: FocusedElement.isTrusted,
                               fnKeyFree: fnUsage == nil || fnUsage == 0)
        }

        var allGranted: Bool { microphone == .authorized && accessibility }
    }

    func refreshPermissions() { permissions = .current() }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refreshPermissions()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.info("login item change failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}
