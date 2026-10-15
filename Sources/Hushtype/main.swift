import AppKit
import Combine
import HushtypeCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let app = AppModel()
    lazy var dictation = DictationController(app: app)
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private let panelModel = MenuBarModel()
    private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let actions = MenuBarActions(
            toggleDictation: { [weak self] in self?.popover.performClose(nil); self?.dictation.toggleFromMenu() },
            recover: { [weak self] in self?.popover.performClose(nil); self?.dictation.recoverLast() },
            open: { [weak self] s in self?.popover.performClose(nil); self?.showMain(s) },
            quit: { NSApp.terminate(nil) })
        p.contentViewController = NSHostingController(rootView: MenuBarPanel(app: app, model: panelModel, actions: actions))
        return p
    }()

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        app.refreshPermissions()
        panelModel.recoverableSeconds = dictation.recoverable.map { $0.samples.count / 16000 }
        // Read the selection now, from the app that was in front (clicking the icon doesn't activate us).
        let front = NSWorkspace.shared.frontmostApplication
        let frontID = front?.bundleIdentifier
        let readable = frontID != Bundle.main.bundleIdentifier && !HushtypeSettings.neverReadContext.contains(frontID ?? "")
            && !app.settings.contextExcluded.contains(frontID ?? "")
        let raw = readable ? front.flatMap { FocusedElement.selectedText(inApp: $0.processIdentifier) } : nil
        let sel = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        panelModel.selection = sel.flatMap { !$0.isEmpty && $0.count <= 40 && !$0.contains("\n") ? $0 : nil }
        Log.info("panel opened over \(frontID ?? "?"): selection \(raw == nil ? "none" : "\(raw!.count) chars")\(panelModel.selection == nil && raw != nil ? " (not a single term)" : "")")
        panelModel.addedTerm = nil
        popover.appearance = NSApp.effectiveAppearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    private let mainNav = MainNavigation()
    private var onboardingWindow: NSWindow?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.info("launch \(v), mic \(app.permissions.microphone.rawValue), ax \(app.permissions.accessibility)")
        NSApp.setActivationPolicy(app.settings.showInDock ? .regular : .accessory)
        NSApp.mainMenu = Self.makeMainMenu()
        app.onDockPolicyChange = { [weak self] in self?.applyDockPolicy() }
        app.setHotkeySuspended = { [weak self] on in self?.dictation.hotkey.suspended = on }
        app.onHotkeyChanged = { [weak self] in self?.dictation.applySettings() }
        app.applyAppearance()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Hushtype")
        statusItem.button?.wantsLayer = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        dictation.onActivity = { [weak self] a in
            self?.updateStatusIcon(a)
            self?.panelModel.activity = a
        }
        dictation.statusItemFrame = { [weak self] in
            guard let b = self?.statusItem.button, let w = b.window else { return nil }
            return w.convertToScreen(b.convert(b.bounds, to: nil))
        }
        dictation.onParked = { [weak self] in self?.catchParkedText() }
        pendingObserver = app.$pendingText.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusIcon(self?.panelModel.activity ?? .idle) }
        }

        if LaunchArgs.all.contains("--qa-onboarding") {
            Task { await app.prepareEngines() }
            showOnboarding()
        } else if LaunchArgs.all.contains("--selftest") || (app.settings.hasOnboarded && app.permissions.allGranted) {
            Task { await app.prepareEngines() }
        } else {
            showOnboarding()
        }
        startHotkeyWhenTrusted()
        let args = LaunchArgs.all
        if let i = args.firstIndex(of: "--qa-scroll-bench"), i + 1 < args.count {
            let section: SidebarSection = args[i + 1] == "dictionary" ? .dictionary : .home
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.showMain(section)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    if let w = self?.mainWindow { QAScrollBench.start(in: w, label: args[i + 1]) }
                }
            }
        }
        if let i = args.firstIndex(of: "--qa-open"), i + 1 < args.count {
            let m: [String: SidebarSection] = ["home": .home, "dictionary": .dictionary, "general": .general, "ai": .ai, "privacy": .privacy]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    self?.showMain(m[args[i + 1]] ?? .home); NSApp.activate(ignoringOtherApps: true)
                    if args.contains("--qa-scroll-end") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            if let w = self?.mainWindow { QAScrollBench.scrollToEnd(in: w) }
                        }
                    }
                }
            }
        }
        if let i = args.firstIndex(of: "--qa-mute-others"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            // QA: silence other apps for a few seconds (process tap) while Hushtype's own sound plays.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    let m = OtherAppsMuter()
                    Sounds.play(.start, theme: .droplet, route: OutputMuter.currentRoute())
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        Log.info("qa mute-others: \(m.mute())")
                        DispatchQueue.main.asyncAfter(deadline: .now() + secs / 2) {
                            MainActor.assumeIsolated { Sounds.play(.stop, theme: .droplet, route: OutputMuter.currentRoute()) }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { m.restore() }
                    }
                }
            }
        }
        if let i = args.firstIndex(of: "--qa-hud"), i + 1 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.dictation.qaShowHUD(args[i + 1]) }
            }
        }
        if args.contains("--qa-tab-bench") {
            // QA: time each sidebar tab from the click to the finished layout (main thread), 3 rounds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.showMain(.home)
                let order: [SidebarSection] = [.dictionary, .general, .ai, .privacy, .home]
                var k = 0
                @MainActor func step() {
                    guard k < order.count * 3, let w = self.mainWindow else { return }
                    let s = order[k % order.count]; k += 1
                    let t0 = CFAbsoluteTimeGetCurrent()
                    self.showMain(s)
                    w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded()
                    let t1 = CFAbsoluteTimeGetCurrent()
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        Log.info(String(format: "tab bench %@: layout %.0f ms, next turn %.0f ms", "\(s)", (t1 - t0) * 1000, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { step() } }
                    } }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { step() } }
            }
        }
        if args.contains("--qa-show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.togglePanel() }
        }
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            Task {
                // Same readiness wait as a user would experience after launch.
                while !app.isReady { try? await Task.sleep(nanoseconds: 200_000_000) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let samples = try? AudioFile.read16kMono(url) { dictation.selfTest(samples: samples) }
            }
        }
    }

    /// The event tap only works once Accessibility is granted; poll until then.
    private func startHotkeyWhenTrusted() {
        if dictation.startMonitoring() { Log.info("hotkey monitor started"); return }
        Log.info("hotkey monitor unavailable (accessibility: \(app.permissions.accessibility)); polling")
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                self.app.refreshPermissions()
                if self.dictation.startMonitoring() { t.invalidate() }
            }
        }
    }

    /// Standard app menus. Even a menu bar app needs them: ⌘W, ⌘Q, ⌘C/⌘V/⌘A and undo in text fields
    /// are all dispatched through the main menu's key equivalents.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            main.addItem(host)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        sub("Hushtype", [
            item(String(localized: "关于 Hushtype"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item(String(localized: "设置…"), #selector(AppDelegate.openSettingsFromMenu), ","),
            .separator(),
            item(String(localized: "隐藏 Hushtype"), #selector(NSApplication.hide(_:)), "h"),
            item(String(localized: "隐藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item(String(localized: "退出 Hushtype"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub(String(localized: "编辑"), [
            item(String(localized: "撤销"), Selector(("undo:")), "z"),
            item(String(localized: "重做"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "剪切"), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "拷贝"), #selector(NSText.copy(_:)), "c"),
            item(String(localized: "粘贴"), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "全选"), #selector(NSText.selectAll(_:)), "a"),
        ])
        sub(String(localized: "窗口"), [
            item(String(localized: "关闭"), #selector(NSWindow.performClose(_:)), "w"),
            item(String(localized: "最小化"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }

    @objc func openSettingsFromMenu() { showMain(.general) }

    // MARK: status icon

    private var processingTimer: Timer?
    private var pendingObserver: AnyCancellable?

    /// The flying text just landed: the icon "catches" it with a quick bounce.
    private func catchParkedText() {
        updateStatusIcon(panelModel.activity)
        guard let layer = statusItem.button?.layer else { return }
        let b = CAKeyframeAnimation(keyPath: "transform.scale")
        b.values = [1, 1.35, 0.92, 1]
        b.keyTimes = [0, 0.35, 0.7, 1]
        b.duration = 0.45
        layer.add(b, forKey: "catch")
    }

    /// The menu bar icon, with an amber dot when text is waiting to be copied.
    private func iconImage(_ symbol: String, pending: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Hushtype") else { return nil }
        guard pending else { return base }
        let size = NSSize(width: 22, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            base.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))?
                .draw(in: NSRect(x: 1, y: 1, width: 16, height: 14))
            NSColor(srgbRed: 0xf2 / 255, green: 0xb9 / 255, blue: 0x4b / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 6, height: 6)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    private func updateStatusIcon(_ a: DictationController.Activity) {
        processingTimer?.invalidate()
        processingTimer = nil
        guard let button = statusItem.button else { return }
        switch a {
        case .idle:
            button.image = iconImage("waveform", pending: app.pendingText != nil)
            button.contentTintColor = nil
        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: String(localized: "Hushtype 正在听"))
            button.contentTintColor = .systemRed
        case .processing:
            button.contentTintColor = nil
            var step = 0
            let frames = ["ellipsis", "ellipsis.circle", "ellipsis.circle.fill"]
            button.image = NSImage(systemSymbolName: frames[0], accessibilityDescription: String(localized: "Hushtype 正在整理"))
            let t = Timer(timeInterval: 0.3, repeats: true) { [weak button] _ in
                step = (step + 1) % frames.count
                button?.image = NSImage(systemSymbolName: frames[step], accessibilityDescription: String(localized: "Hushtype 正在整理"))
            }
            RunLoop.main.add(t, forMode: .common)
            processingTimer = t
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let today = app.history.stats(since: Calendar.current.startOfDay(for: Date()))
        if today.count > 0 {
            let s = NSMenuItem(title: String(localized: "今天 \(today.count) 次 · \(today.words) 字"), action: nil, keyEquivalent: "")
            s.isEnabled = false
            menu.addItem(s)
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "开始 / 结束免提听写"), #selector(toggleDictation)))
        if let r = dictation.recoverable {
            menu.addItem(item(String(localized: "恢复上一段录音（\(r.samples.count / 16000) 秒）"), #selector(recoverLast)))
        }
        if let last = app.lastResult {
            let preview = last.text.count > 28 ? String(last.text.prefix(28)) + "…" : last.text
            menu.addItem(item(String(localized: "复制上一条：\(preview)"), #selector(copyLast)))
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "打开 Hushtype"), #selector(openHome)))
        menu.addItem(item(String(localized: "历史记录…"), #selector(openHistory)))
        menu.addItem(item(String(localized: "设置…"), #selector(openSettings), key: ","))
        if !app.settings.hasOnboarded || !app.permissions.allGranted {
            menu.addItem(item(String(localized: "完成设置…"), #selector(reopenOnboarding)))
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "退出 Hushtype"), #selector(quit), key: "q"))
    }

    private var statusTitle: String {
        if !app.permissions.allGranted { return String(localized: "需要授权") }
        switch app.engineState {
        case .ready:
            return app.rewriteConfigured ? String(localized: "就绪 · 按 \(app.settings.hotkeyLabel) 开始说话") : String(localized: "就绪（未配置整理服务）")
        case .loading(let m): return "\(m)…"
        case .failed(let m): return String(localized: "出错：\(m)")
        case .notLoaded: return String(localized: "启动中…")
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleDictation() { dictation.toggleFromMenu() }
    @objc private func recoverLast() { dictation.recoverLast() }

    @objc private func copyLast() {
        guard let t = app.lastResult?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    @objc private func openHistory() { showMain(.history) }
    @objc private func openSettings() { showMain(.general) }
    @objc private func openHome() { showMain(.home) }
    @objc private func reopenOnboarding() { showOnboarding() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// The main window. While it is open Hushtype shows in the Dock and app switcher; closing it returns
    /// Hushtype to a menu-bar-only app.
    func showMain(_ section: SidebarSection) {
        if mainWindow == nil {
            let view = MainView(app: app, nav: mainNav,
                                onTriggerChanged: { [weak self] in self?.dictation.applySettings() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Hushtype"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 1040, height: 700))
            w.contentMaxSize = NSSize(width: 1600, height: 1400)
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.app.settings.showInDock else { return }
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            mainWindow = w
        }
        mainNav.section = section
        app.refreshPermissions()
        bringToFront(mainWindow)
    }

    /// Shows a window as a regular app. After switching from menu-bar-only (.accessory) to .regular,
    /// macOS only hands over the menu bar once the app is activated *after* the policy change has
    /// taken effect; activating in the same run-loop pass leaves the previous app's menus showing.
    func bringToFront(_ window: NSWindow?) {
        let wasAccessory = NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        if wasAccessory {
            // Hand focus to the Dock (always running) and back: forces the menu bar to switch to us.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applyDockPolicy() {
        if app.settings.showInDock { NSApp.setActivationPolicy(.regular) }
        else if mainWindow?.isVisible != true && onboardingWindow?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation.cancel()  // never quit with other apps' audio left muted
    }

    /// Opening Hushtype again from Finder / Launchpad / Dock shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain(mainNav.section ?? .home)
        return false
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(app: app, onFinish: { [weak self] in self?.finishOnboarding() },
                                      onOpenDictionary: { [weak self] in
                                          self?.finishOnboarding()
                                          self?.showMain(.dictionary)
                                      })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Hushtype"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.center()
            onboardingWindow = w
        }
        bringToFront(onboardingWindow)
    }

    private func finishOnboarding() {
        app.settings.hasOnboarded = true
        onboardingWindow?.close()
        onboardingWindow = nil
        startHotkeyWhenTrusted()
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
