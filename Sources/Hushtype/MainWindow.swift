import AppKit
import HushtypeCore
import SwiftUI

/// Sections of the main window's sidebar.
enum SidebarSection: String, CaseIterable, Identifiable {
    case home, history, dictionary, general, ai, privacy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return String(localized: "首页")
        case .history: return String(localized: "历史")
        case .dictionary: return String(localized: "词典")
        case .general: return String(localized: "通用")
        case .ai: return String(localized: "整理服务")
        case .privacy: return String(localized: "隐私")
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .general: return "gearshape"
        case .ai: return "sparkles"
        case .privacy: return "lock.shield"
        }
    }
}

@MainActor
final class MainNavigation: ObservableObject {
    @Published var section: SidebarSection? = .home
}

struct MainView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var nav: MainNavigation
    var onTriggerChanged: () -> Void

    private var current: SidebarSection {
        let s = nav.section ?? .home
        return s == .history ? .home : s
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(app: app, nav: nav)
                .frame(width: 210)
            ZStack(alignment: .topLeading) {
                switch current {
                case .home, .history: HomeView(app: app)
                case .dictionary: DictionaryTab(app: app)
                case .general: SettingsPage(title: String(localized: "通用"), subtitle: String(localized: "快捷键、麦克风、外观和权限")) {
                    GeneralTab(app: app, onTriggerChanged: onTriggerChanged) }
                case .ai: SettingsPage(title: String(localized: "整理服务"), subtitle: String(localized: "用 Claude 去口头禅、处理改口、加标点和排版")) { AITab(app: app) }
                case .privacy: SettingsPage(title: String(localized: "隐私"), subtitle: String(localized: "发送什么、保存什么，由你决定")) { PrivacyTab(app: app) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(DS.ink)
        .background(SkyBackdrop())
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 600)
    }
}

/// Settings pages: native form controls on a glass sheet.
struct SettingsPage<Content: View>: View {
    var label: String? = nil
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: title, subtitle: subtitle)
            // A live glass effect behind a scrolling list is recomposited every frame; the static card
            // looks the same over the (static) sky and scrolls smoothly.
            content
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.cardBorder))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 22)
    }
}

/// Glass sidebar over the sky, as in the design preview.
struct Sidebar: View {
    @ObservedObject var app: AppModel
    @ObservedObject var nav: MainNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                BrandMark().frame(width: 20, height: 14)
                Text("Hushtype").font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.top, 52).padding(.bottom, 18)
            ForEach([SidebarSection.home, .dictionary]) { s in NavItem(section: s, nav: nav) }
            Text(String(localized: "设置")).font(.system(size: 11)).foregroundStyle(DS.ink3)
                .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
            ForEach([SidebarSection.general, .ai, .privacy]) { s in NavItem(section: s, nav: nav) }
            Spacer()
            SidebarFooter(app: app)
        }
        .padding(.horizontal, 10)
        .background(DS.sideFill)
        .overlay(alignment: .trailing) { Rectangle().fill(DS.sideLine).frame(width: 1) }
    }
}

struct NavItem: View {
    var section: SidebarSection
    @ObservedObject var nav: MainNavigation
    @Local private var hovering = false

    private var selected: Bool { (nav.section ?? .home) == section || (section == .home && nav.section == .history) }

    var body: some View {
        Button { nav.section = section } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon).font(.system(size: 13)).frame(width: 18)
                Text(section.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? DS.ink : DS.ink2)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? DS.navOn : (hovering ? DS.navOn.opacity(0.5) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The waveform mark from the app icon.
struct BrandMark: View {
    var body: some View {
        Canvas { ctx, size in
            let heights: [CGFloat] = [0.25, 0.62, 1.0, 0.5, 0.75, 0.25]
            let w = size.width / CGFloat(heights.count * 2 - 1)
            for (i, h) in heights.enumerated() {
                let bh = size.height * h
                let r = CGRect(x: CGFloat(i) * 2 * w, y: (size.height - bh) / 2, width: w, height: bh)
                ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(DS.ink))
            }
        }
    }
}

/// Bottom of the sidebar: is Hushtype ready to listen?
struct SidebarFooter: View {
    @ObservedObject var app: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(ready ? DS.ok : DS.warn).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11.5)).foregroundStyle(DS.ink2).lineLimit(2)
            Spacer()
        }
        .padding(10)
        .padding(.bottom, 6)
    }

    private var ready: Bool { app.isReady && app.permissions.allGranted && app.rewriteConfigured && (app.isOnline || app.settings.provider == .offline) }
    private var text: String {
        if !app.permissions.allGranted { return String(localized: "需要授权（见「通用」）") }
        if !app.isReady { return app.engineStatusMessage }
        if !app.rewriteConfigured { return String(localized: "未配置整理服务") }
        if !app.isOnline && app.settings.provider != .offline { return String(localized: "没有网络 · 用本机识别，暂不整理") }
        return String(localized: "就绪 · 按 \(app.settings.hotkeyLabel) 说话")
    }
}

// MARK: Home

/// Home: headline, the three gestures, and the full history (searchable).
struct HomeView: View {
    @ObservedObject var app: AppModel
    @Local private var items: [HistoryItem] = []
    @Local private var query = ""
    /// Rows rendered; more load on demand so a long history doesn't make the page heavy.
    @Local private var shown = 60

    /// Typing speed used to estimate time saved (mixed Chinese/English ≈ 50 units per minute).
    static let typedUnitsPerMinute = 50.0

    var body: some View {
        SettingsPage(title: String(localized: "说话，就是打字。"),
                     subtitle: String(localized: "在任何 App 里按 \(key) 开始说，再按一下插入。")) {
            Form {
                Section(String(localized: "快捷键")) {
                    keyRow([key], String(localized: "开始与结束"), String(localized: "按一下开始说，再按一下插入；按住说、松开插入也可以。"))
                    keyRow([key, "⇧"], String(localized: "指令"), String(localized: "选中文字后说「改正式一点」「翻成英文」；不选中时直接让它写。"))
                    keyRow(["esc"], String(localized: "取消也不丢"), String(localized: "说到一半取消，说过的话照样识别好存进下面的历史。"))
                }
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("", text: $query, prompt: Text(String(localized: "搜索历史"))).labelsHidden().textFieldStyle(.plain)
                            .onChange(of: query) { reload() }
                    }
                    if items.isEmpty {
                        Text(query.isEmpty ? String(localized: "还没有听写记录。点一下任意输入框，按 \(key) 说一句试试。")
                                           : String(localized: "没有匹配的记录，换个关键词试试。"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HistoryRow(item: item, onDelete: { app.history.delete(id: item.id); reload() },
                                   onRate: { r in
                                       app.history.setRating(id: item.id, r)
                                       if r == 1 { app.corrections.like(raw: item.rawText, result: item.text) }
                                       else { app.corrections.unlike(result: item.text) }
                                       Log.info("rated a result \(r)")
                                       reload()
                                   },
                                   onCorrect: { better in
                                       app.corrections.add(before: item.text, after: better)
                                       Log.info("correction from a 👎 rating")
                                   },
                                   onRedo: needsRedo(item) ? { await redo(item) } : nil)
                    }
                    if items.count >= shown {
                        Button(String(localized: "显示更多")) { shown += 100; reload() }
                            .buttonStyle(.borderless)
                    }
                } header: {
                    HStack {
                        Text(String(localized: "历史"))
                        Spacer()
                        Text(String(localized: "只保存在这台 Mac 上")).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: reload)
        .onChange(of: app.lastResult?.id) { reload() }
    }

    private func keyRow(_ keys: [String], _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                    if i > 0 { Text("+").foregroundStyle(.tertiary) }
                    Keycap(label: k)
                }
            }
            .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var key: String { app.settings.hotkeyLabel }

    /// Inserted as raw text (offline or the cleanup failed) and the cleanup service is available now.
    private func needsRedo(_ item: HistoryItem) -> Bool {
        item.outcome.hasPrefix("raw") && !item.rawText.isEmpty && app.settings.provider != .offline
    }

    private func redo(_ item: HistoryItem) async -> String? {
        guard app.isOnline else { return String(localized: "还是没有网络，联网后再试") }
        let out = await app.engine.finish(primary: Transcript(text: item.rawText, engine: "sensevoice"), secondary: nil,
                                          context: nil, options: app.engineOptions())
        if let e = out.rewriteError { return String(localized: "整理失败：\(e)") }
        app.history.updateText(id: item.id, text: out.text, outcome: "redone")
        Log.info("re-cleaned a history entry")
        reload()
        return nil
    }

    /// Reads history off the main thread (switching tabs must not wait on SQLite), newest first.
    private func reload() {
        let q = query, store = app.history, limit = shown
        Task.detached(priority: .userInitiated) {
            let rows = store.recent(limit: limit, search: q)
            await MainActor.run { items = rows }
        }
    }
}

// MARK: shared components

struct PageHeader: View {
    var label: String? = nil
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let label { SpecLabel(label) }
            Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.5)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(DS.ink2)
        }
    }
}

struct EmptyState: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(DS.ink3)
            Text(title).font(.system(size: 13.5, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(DS.ink3).multilineTextAlignment(.center)
        }
    }
}

/// One dictation in a log: time column, text, source, actions.
struct HistoryRow: View {
    var item: HistoryItem
    var onDelete: (() -> Void)?
    var onRate: ((Int) -> Void)? = nil
    /// The user's better version after a 👎 (feeds the correction memory).
    var onCorrect: ((String) -> Void)? = nil
    /// Clean up again (entries inserted as raw text, e.g. while offline). Returns an error message or nil.
    var onRedo: (() async -> String?)? = nil
    @Local private var redoing = false
    @Local private var redoError: String?
    @Local private var hovering = false
    @Local private var better = ""
    @Local private var saved = false
    @Local private var copied = false
    @Local private var showRaw = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.stamp(item.createdAt))
                .font(DS.mono(11)).foregroundStyle(DS.ink3).frame(width: 40, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if item.outcome == "cancelled" { Badge(text: String(localized: "已取消"), color: DS.warn) }
                    if onRedo != nil { Badge(text: String(localized: "未整理"), color: DS.warn) }
                    Text(item.text.replacingOccurrences(of: "\n\n", with: "\n")).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(DS.ink).lineLimit(3)
                }
                Text([item.appName, String(format: "%.1fs", item.latencySeconds)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(DS.ink3)
                if let e = redoError { Text(e).font(.system(size: 11)).foregroundStyle(DS.warn) }
                if showRaw && !item.rawText.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "原始识别（整理前）")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(DS.ink3)
                        Text(item.rawText).font(.system(size: 12)).foregroundStyle(DS.ink2).textSelection(.enabled)
                        if let onCorrect {
                            HStack(spacing: 6) {
                                TextField(String(localized: "应该整理成什么样？写下来，Hushtype 以后会照着改（可选）"), text: $better)
                                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                                    .onSubmit { submit(onCorrect) }
                                Button(saved ? String(localized: "已记住") : String(localized: "记住")) { submit(onCorrect) }
                                    .buttonStyle(PillButtonStyle())
                                    .disabled(better.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.panel))
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let onRedo {
                    Button(redoing ? String(localized: "整理中…") : String(localized: "重新整理")) {
                        redoing = true
                        redoError = nil
                        Task {
                            redoError = await onRedo()
                            redoing = false
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(redoing)
                }
                // Hover-only controls are always laid out and only fade in: if they appeared and
                // disappeared, the text beside them would re-wrap (and the row change height) every
                // time a row scrolled under the pointer.
                if let onRate {
                    let shown = hovering || item.rating != 0
                    Group {
                        RateButton(symbol: "hand.thumbsup", active: item.rating == 1) { onRate(item.rating == 1 ? 0 : 1) }
                        RateButton(symbol: "hand.thumbsdown", active: item.rating == -1) {
                            let r = item.rating == -1 ? 0 : -1
                            onRate(r)
                            showRaw = r == -1
                        }
                    }
                    .opacity(shown ? 1 : 0).allowsHitTesting(shown)
                }
                if let onDelete {
                    Button(String(localized: "删除"), action: onDelete).buttonStyle(PillButtonStyle())
                        .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
                }
                Button(copied ? String(localized: "已复制") : String(localized: "复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { copied = false }
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { if hovering != $0 { hovering = $0 } }
    }

    private static let timeFormat = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
    private static let dayFormat = Date.FormatStyle.dateTime.month(.defaultDigits).day()

    static func stamp(_ date: Date) -> String {
        date.formatted(Calendar.current.isDateInToday(date) ? timeFormat : dayFormat)
    }
}

/// Small outlined pill (the preview's "复制").
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundStyle(DS.ink2)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(configuration.isPressed ? DS.panel : .clear))
            .overlay(Capsule().strokeBorder(DS.cardBorder))
    }
}

extension HistoryRow {
    func submit(_ onCorrect: (String) -> Void) {
        let t = better.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onCorrect(t)
        saved = true
    }
}

/// Thumb button for rating a result.
struct RateButton: View {
    var symbol: String
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: active ? symbol + ".fill" : symbol)
                .font(.system(size: 11))
                .foregroundStyle(active ? DS.ink : DS.ink3)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(symbol.contains("up") ? String(localized: "整理得好") : String(localized: "整理得不好（查看原始识别）"))
    }
}
