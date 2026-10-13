import AppKit
import HushtypeCore
import SwiftUI

/// What the menu bar panel needs from the app delegate.
@MainActor
struct MenuBarActions {
    var toggleDictation: () -> Void
    var recover: () -> Void
    var open: (SidebarSection) -> Void
    var quit: () -> Void
}

/// Live values for the panel (the menu bar icon mirrors `activity`).
@MainActor
final class MenuBarModel: ObservableObject {
    @Published var activity: DictationController.Activity = .idle
    @Published var recoverableSeconds: Int?
    /// Text selected in the app that was in front when the panel opened (for "add to dictionary").
    @Published var selection: String?
    @Published var addedTerm: String?
}

/// The panel that opens from the menu bar icon: text waiting to be copied (when there was no field),
/// status, today's numbers, the last result with Copy, recovery, quick switches and navigation.
struct MenuBarPanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: MenuBarModel
    var actions: MenuBarActions
    @Local private var copied = false

    var body: some View {
        let today = app.history.stats(since: Calendar.current.startOfDay(for: Date()))
        VStack(alignment: .leading, spacing: 0) {
            if let pending = app.pendingText { pendingCard(pending) }
            HStack(spacing: 10) {
                Lamp(kind: lampKind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.system(size: 13, weight: .semibold))
                    Text(statusSub).font(.system(size: 11.5)).foregroundStyle(DS.ink3)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 12)
            line
            HStack(spacing: 0) {
                stat(String(localized: "今天"), today.words.formatted(), first: true)
                stat(String(localized: "次数"), "\(today.count)")
                stat(String(localized: "省下"), "\(Int(max(0, Double(today.words) / HomeView.typedUnitsPerMinute - today.seconds / 60)))", unit: "min")
            }
            line
            if let last = app.lastResult {
                lastCard(last)
                line
            }
            VStack(spacing: 0) {
                PanelRow(title: model.activity == .recording ? String(localized: "结束并插入") : String(localized: "开始免提听写"),
                         key: app.settings.hotkeyLabel, action: actions.toggleDictation)
                if let sel = model.selection {
                    PanelRow(title: model.addedTerm == sel ? String(localized: "已加入词典：\(sel)") : String(localized: "把「\(sel)」加入词典"), key: nil) {
                        if !app.settings.dictionary.contains(where: { $0.caseInsensitiveCompare(sel) == .orderedSame }) {
                            app.settings.dictionary.append(sel)
                        }
                        model.addedTerm = sel
                    }
                }
                if let s = model.recoverableSeconds {
                    PanelRow(title: String(localized: "恢复上一段录音"), key: String(format: "%02d:%02d", s / 60, s % 60), action: actions.recover)
                }
                sep
                toggleRow(String(localized: "离线模式"), isOn: Binding(get: { app.settings.provider == .offline },
                                                  set: { app.settings.provider = $0 ? .offline : .anthropicKey }))
                sep
                PanelRow(title: String(localized: "打开 Hushtype"), key: "⌘O") { actions.open(.home) }
                PanelRow(title: String(localized: "历史记录"), key: nil) { actions.open(.history) }
                PanelRow(title: String(localized: "设置…"), key: "⌘,") { actions.open(.general) }
                sep
                PanelRow(title: String(localized: "退出 Hushtype"), key: "⌘Q", action: actions.quit)
            }
            .padding(.vertical, 4)
        }
        .padding(8)
        .frame(width: 320)
    }

    private var line: some View { Rectangle().fill(DS.line).frame(height: 1) }
    private var sep: some View { Rectangle().fill(DS.line).frame(height: 1).padding(.vertical, 4) }

    private var lampKind: Lamp.Kind {
        switch model.activity {
        case .recording: return .recording
        case .processing: return .busy
        case .idle: return app.permissions.allGranted && app.isReady && (app.isOnline || app.settings.provider == .offline) ? .ready : .attention
        }
    }

    private var statusTitle: String {
        switch model.activity {
        case .recording: return String(localized: "正在听")
        case .processing: return String(localized: "整理中")
        case .idle:
            if !app.permissions.allGranted { return String(localized: "需要授权") }
            if !app.isReady { return app.engineStatusMessage }
            return String(localized: "就绪")
        }
    }

    private var statusSub: String {
        let key = app.settings.hotkeyLabel
        switch model.activity {
        case .recording: return String(localized: "再按 \(key) 插入 · esc 取消")
        case .processing: return String(localized: "识别完成，正在整理")
        case .idle:
            if !app.permissions.allGranted { return String(localized: "打开 Hushtype › 通用 授权") }
            if !app.rewriteConfigured { return String(localized: "未配置整理服务") }
            if !app.isOnline && app.settings.provider != .offline { return String(localized: "没有网络 · 先用本机识别，不整理") }
            return String(localized: "按 \(key) 开始说话，再按一下插入")
        }
    }

    private func pendingCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SpecLabel(String(localized: "没找到输入框 · 待复制"), color: DS.warn)
                Spacer()
                Button(String(localized: "复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    app.pendingText = nil
                }
                .buttonStyle(SolidButtonStyle())
            }
            Text(text).font(.system(size: 12.5)).lineLimit(3)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.warn.opacity(0.12)))
        .padding(.bottom, 6)
    }

    private func stat(_ label: String, _ value: String, unit: String? = nil, first: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SpecLabel(label)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                if let unit { SpecLabel(unit) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { if !first { Rectangle().fill(DS.line).frame(width: 1) } }
    }

    private func lastCard(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SpecLabel(String(localized: "上一条\(item.appName.map { " · \($0)" } ?? "") · \(String(format: "%.1fs", item.latencySeconds))"))
                Spacer()
                Button(copied ? String(localized: "已复制") : String(localized: "复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                .buttonStyle(GhostButtonStyle())
            }
            Text(item.text).font(.system(size: 12.5)).lineLimit(2)
        }
        .padding(10)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }
}

struct PanelRow: View {
    var title: String
    var key: String?
    var action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 13))
                Spacer()
                if let key { Text(key).font(.system(size: 11.5)).foregroundStyle(DS.ink3) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
