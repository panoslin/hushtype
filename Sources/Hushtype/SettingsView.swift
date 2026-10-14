import ServiceManagement
import AppKit
import HushtypeCore
import SwiftUI

// MARK: General

struct GeneralTab: View {
    @ObservedObject var app: AppModel
    var onTriggerChanged: () -> Void
    // Both are slow system queries (CoreAudio walks every device, including iPhone Continuity mics;
    // the login-item status is an XPC round trip), so they load off the main thread after the tab shows.
    @Local private var mics: [AudioDevices.Device] = GeneralTab.lastMics
    @Local private var loginOn: Bool? = nil
    private static var lastMics: [AudioDevices.Device] = []

    var body: some View {
        Form {
            Section(String(localized: "快捷键")) {
                LabeledContent(String(localized: "听写键")) { HotkeyRecorder(app: app, onChanged: onTriggerChanged) }
                Picker(String(localized: "按键方式"), selection: $app.settings.tapToToggle) {
                    Text(String(localized: "按一下开始，再按一下结束")).tag(true)
                    Text(String(localized: "按住说话，松开结束")).tag(false)
                }
                .onChange(of: app.settings.tapToToggle) { onTriggerChanged() }
                if !app.settings.tapToToggle {
                    Toggle(String(localized: "双击进入免提模式（再按一次结束）"), isOn: $app.settings.doubleTapHandsFree)
                        .onChange(of: app.settings.doubleTapHandsFree) { onTriggerChanged() }
                }
                if app.settings.hotkey == .fn && !app.permissions.fnKeyFree {
                    Label {
                        Text(String(localized: "系统设置里「按下 🌐 键时」不是「无操作」，按 fn 会同时打开表情或系统听写。"))
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                    Button(String(localized: "打开键盘设置")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                }
            }
            Section(String(localized: "麦克风")) {
                Picker(String(localized: "输入设备"), selection: $app.settings.microphoneUID) {
                    Text(String(localized: "系统默认")).tag(String?.none)
                    ForEach(mics) { Text($0.name).tag(Optional($0.uid)) }
                }
                Toggle(String(localized: "开始和结束时播放提示音"), isOn: $app.settings.playSounds)
                Toggle(String(localized: "录音时静音其他声音（音乐、视频）"), isOn: $app.settings.muteWhileDictating)
            }
            Section(String(localized: "语言")) {
                Picker(String(localized: "界面语言"), selection: Binding(get: { InterfaceLanguage.current }, set: { InterfaceLanguage.set($0) })) {
                    ForEach(InterfaceLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(String(localized: "中文输出"), selection: $app.settings.scriptPreference) {
                    ForEach(ScriptPreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(String(localized: "外观")) {
                Picker(String(localized: "主题"), selection: $app.settings.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(String(localized: "启动")) {
                Toggle(String(localized: "登录时自动启动"), isOn: Binding(get: { loginOn ?? false }, set: { app.launchAtLogin = $0; loginOn = $0 }))
                    .disabled(loginOn == nil)
                Toggle(String(localized: "在 Dock 中显示"), isOn: $app.settings.showInDock)
            }
            Section(String(localized: "权限")) {
                PermissionRow(title: String(localized: "麦克风"), granted: app.permissions.microphone == .authorized) {
                    Task { await app.requestMicrophone() }
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                PermissionRow(title: String(localized: "辅助功能（读取光标位置、插入文字、监听快捷键）"), granted: app.permissions.accessibility) {
                    FocusedElement.requestTrust()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            app.refreshPermissions()
            DispatchQueue.global(qos: .userInitiated).async {
                let m = AudioDevices.inputs()
                let on = SMAppService.mainApp.status == .enabled
                DispatchQueue.main.async { GeneralTab.lastMics = m; mics = m; loginOn = on }
            }
        }
    }
}

struct PermissionRow: View {
    var title: String
    var granted: Bool
    var action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(title)
            Spacer()
            if !granted { Button(String(localized: "去授权"), action: action) }
        }
    }
}

// MARK: AI

struct AITab: View {
    @ObservedObject var app: AppModel
    @Local private var key = ""
    @Local private var token = ""
    @Local private var testResult: String?
    @Local private var testing = false

    var body: some View {
        Form {
            Section(String(localized: "整理服务")) {
                Picker(String(localized: "来源"), selection: $app.settings.provider) {
                    Text(String(localized: "我的 Anthropic API key")).tag(ProviderKind.anthropicKey)
                    Text(String(localized: "Hushtype Cloud / 自建代理")).tag(ProviderKind.proxy)
                    Text(String(localized: "离线（不整理，只用本地识别）")).tag(ProviderKind.offline)
                }
                switch app.settings.provider {
                case .anthropicKey:
                    SecureField("API key（sk-ant-…）", text: $key, prompt: Text(Secrets.anthropicKey == nil ? String(localized: "粘贴 API key") : String(localized: "已保存，粘贴新的可替换")))
                        .onSubmit(saveKey)
                    HStack {
                        Button(String(localized: "保存"), action: saveKey).disabled(key.isEmpty)
                        Link(String(localized: "获取 API key"), destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        Spacer()
                        if Secrets.anthropicKey != nil {
                            Button(String(localized: "删除已保存的 key"), role: .destructive) { Secrets.anthropicKey = nil; app.reloadBackend() }
                        }
                    }
                case .proxy:
                    TextField(String(localized: "服务地址（https://…）"), text: $app.settings.proxyURL)
                    SecureField(String(localized: "访问令牌"), text: $token, prompt: Text(Secrets.proxyToken == nil ? String(localized: "粘贴令牌") : String(localized: "已保存")))
                    Button(String(localized: "保存令牌")) { Secrets.proxyToken = token; token = ""; app.reloadBackend() }.disabled(token.isEmpty)
                case .offline:
                    Text(String(localized: "不联网。识别结果原样插入，不删口头禅、不排版。")).font(.callout).foregroundStyle(.secondary)
                }
                if app.settings.provider != .offline {
                    HStack {
                        Button(testing ? String(localized: "测试中…") : String(localized: "测试连接"), action: test).disabled(testing || app.rewriter.backend == nil)
                        if let r = testResult { Text(r).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func saveKey() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        Secrets.anthropicKey = k
        key = ""
        app.reloadBackend()
        test()
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let r = try await app.rewriter.rewrite(system: RewritePrompt.system(script: .simplified, dictionary: [], twoHypotheses: false),
                                                       user: RewritePrompt.user(primary: String(localized: "嗯测试一下呃这个连接"), secondary: nil, context: nil),
                                                       source: String(localized: "嗯测试一下呃这个连接"))
                testResult = String(localized: "✓ 可用（\(String(format: "%.1f", r.seconds)) 秒）：\(r.text)")
            } catch {
                testResult = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            testing = false
        }
    }
}

struct StatusLine: View {
    var label: String
    var state: AppModel.EngineState

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            switch state {
            case .ready: Label(String(localized: "就绪"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .loading(let m): HStack(spacing: 6) { ProgressView().controlSize(.small); Text(m) }.foregroundStyle(.secondary)
            case .failed(let m): Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
            case .notLoaded: Text(String(localized: "未加载")).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

// MARK: Privacy

struct PrivacyTab: View {
    @ObservedObject var app: AppModel
    @Local private var migrationNote: String?

    var body: some View {
        Form {
            Section(String(localized: "发送给整理服务的内容")) {
                Toggle(String(localized: "附带光标前后的文字和窗口标题（专有名词更准）"), isOn: $app.settings.sendContext)
                Text(String(localized: "只发送光标前后各约 1,500 字和当前应用名，不读整个屏幕；其中的密钥、密码、卡号、身份证号会先在本机隐去。密码管理器和密码框里永远不读取。录音本身不上传，语音识别全部在本机完成。"))
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent(String(localized: "不读取这些 App")) {
                    Menu(String(localized: "添加…")) {
                        ForEach(runningApps, id: \.0) { id, name in
                            Button(name) { if !app.settings.contextExcluded.contains(id) { app.settings.contextExcluded.append(id) } }
                        }
                    }
                    .fixedSize()
                }
                ForEach(app.settings.contextExcluded, id: \.self) { id in
                    HStack {
                        Text(appName(id))
                        Spacer()
                        Button(String(localized: "移除")) { app.settings.contextExcluded.removeAll { $0 == id } }.buttonStyle(.borderless)
                    }
                }
            }
            Section(String(localized: "从你的修改中学习")) {
                Text(String(localized: "插入后你改了某个词时，会把改动前后的这一小段发给 Claude（Haiku），判断要不要记进词典；不发送整篇内容。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(String(localized: "本地保存")) {
                Picker(String(localized: "历史保留"), selection: $app.settings.historyDays) {
                    Text(String(localized: "不保存")).tag(Int?.some(0))
                    Text(String(localized: "7 天")).tag(Int?.some(7))
                    Text(String(localized: "30 天")).tag(Int?.some(30))
                    Text(String(localized: "永久")).tag(Int?.none)
                }
                Toggle(String(localized: "同时保存录音（用于回听）"), isOn: $app.settings.keepAudio)
                Button(String(localized: "立即清空全部历史和录音"), role: .destructive) { app.history.deleteAll(); app.lastResult = nil }
                Button(String(localized: "清空从我的修改中学到的习惯（\(app.corrections.all.count + app.corrections.allLiked.count) 条）"), role: .destructive) {
                    app.corrections.clear()
                    app.objectWillChange.send()
                }
            }
            Section(String(localized: "搬到另一台 Mac")) {
                Text(String(localized: "把历史、词典、学到的习惯和设置打包成一个文件，在另一台 Mac 的 Hushtype 里导入即可。API key 不会打包，需要在新电脑上重新填写。"))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "导出数据…"), action: exportData)
                    Button(String(localized: "导入数据…"), action: importData)
                    Spacer()
                }
                if let n = migrationNote { Text(n).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
            .sorted { $0.1 < $1.1 }
    }

    private func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }

    private func exportData() {
        let panel = NSSavePanel()
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = String(localized: "Hushtype 数据 \(day).hushtypebackup")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DataMigration.export(to: url, settings: app.settings, history: app.history,
                                     supportDir: AppModel.supportDir, includeAudio: app.settings.keepAudio)
            migrationNote = String(localized: "已导出到 \(url.lastPathComponent)")
        } catch {
            migrationNote = String(localized: "导出失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }

    private func importData() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var s = app.settings
            let sum = try DataMigration.importBackup(from: url, into: &s, history: app.history,
                                                     corrections: app.corrections, supportDir: AppModel.supportDir)
            app.settings = s
            app.lastResult = app.history.recent(limit: 1).first
            migrationNote = String(localized: "已导入：\(sum.historyAdded) 条历史、\(sum.termsAdded) 个新词条、\(sum.habits) 条习惯")
        } catch {
            migrationNote = String(localized: "导入失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }
}

// MARK: History

struct HistoryTab: View {
    @ObservedObject var app: AppModel
    @Local private var query = ""
    @Local private var items: [HistoryItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: String(localized: "历史"), subtitle: String(localized: "只保存在这台 Mac 上。取消的听写也在这里，可以随时复制。"))
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "搜索"), text: $query).textFieldStyle(.plain).onChange(of: query) { reload() }
                Spacer()
                let s = app.history.stats(since: Calendar.current.startOfDay(for: Date()))
                SpecLabel(String(localized: "今天 \(s.count) · \(s.words) 字"))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassPanel(cornerRadius: 12)
            if items.isEmpty {
                EmptyState(icon: "clock", title: query.isEmpty ? String(localized: "还没有记录") : String(localized: "没有匹配的记录"),
                           detail: query.isEmpty ? String(localized: "听写过的内容会出现在这里。") : String(localized: "换个关键词试试。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Rectangle().fill(DS.line).frame(height: 1) }
                            HistoryRow(item: item) { app.history.delete(id: item.id); reload() }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .glassPanel(cornerRadius: 16)
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 20)
        .onAppear(perform: reload)
    }

    private func reload() { items = app.history.recent(limit: 500, search: query) }
}

/// The app's UI language. "System" follows macOS; otherwise the choice is stored in the app's
/// AppleLanguages default and takes effect after a relaunch (done right away).
enum InterfaceLanguage: String, CaseIterable {
    case system, zhHans = "zh-Hans", zhHant = "zh-Hant", en

    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .zhHans: return String(localized: "简体中文")
        case .zhHant: return String(localized: "繁體中文")
        case .en: return "English"
        }
    }

    static var current: InterfaceLanguage {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = list.first else { return .system }
        return InterfaceLanguage(rawValue: first) ?? .system
    }

    static func set(_ l: InterfaceLanguage) {
        guard l != current else { return }
        if l == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([l.rawValue], forKey: "AppleLanguages") }
        UserDefaults.standard.synchronize()
        // Relaunch so every window picks up the new language.
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.arguments = Array(CommandLine.arguments.dropFirst())
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
