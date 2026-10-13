import AppKit
import HushtypeCore
import SwiftUI

/// First-run quick start, one step per screen:
/// permissions → cleanup service + models → find the key → first dictation → two more tricks →
/// dictionary cold start → done. Each step reacts live (permissions tick on, the keycap lights up
/// when fn is pressed, the practice box fills when the dictation lands).
struct OnboardingView: View {
    @ObservedObject var app: AppModel
    var onFinish: () -> Void
    var onOpenDictionary: () -> Void = {}
    @Local private var step = 0
    @Local private var key = ""
    @Local private var practice = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let titles = [String(localized: "权限"), String(localized: "准备"), String(localized: "快捷键"), String(localized: "第一次听写"), String(localized: "两个技巧"), String(localized: "词典"), String(localized: "完成")]

    var body: some View {
        ZStack {
            SkyBackdrop()
            VStack(alignment: .leading, spacing: 18) {
                header
                Group {
                    switch step {
                    case 0: permissions
                    case 1: prepare
                    case 2: findKey
                    case 3: firstDictation
                    case 4: tricks
                    case 5: dictionary
                    default: done
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(step)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
                footer
            }
            .padding(28)
        }
        .animation(.easeOut(duration: 0.22), value: step)
        .frame(width: 640, height: 560)
        .onReceive(timer) { _ in app.refreshPermissions() }
        .onAppear {
            Task { await app.prepareEngines() }
            let a = CommandLine.arguments
            if let i = a.firstIndex(of: "--qa-onboarding-step"), i + 1 < a.count, let n = Int(a[i + 1]) { step = n }
        }
    }

    // MARK: chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "欢迎使用 Hushtype 轻语")).font(.system(size: 22, weight: .bold))
                    Text(String(localized: "说话，就是打字。两分钟带你上手。")).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(step + 1) / \(titles.count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { i in
                    Capsule().fill(i <= step ? Color.primary.opacity(0.75) : Color.primary.opacity(0.15))
                        .frame(height: 4)
                        .help(titles[i])
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 && step < titles.count - 1 { Button(String(localized: "上一步")) { step -= 1 }.buttonStyle(GhostButtonStyle()) }
            Spacer()
            if skippable { Button(String(localized: "跳过")) { step += 1 }.buttonStyle(GhostButtonStyle()) }
            Button(step == titles.count - 1 ? String(localized: "开始使用") : String(localized: "继续")) {
                if step == titles.count - 1 { onFinish() } else { advance() }
            }
            .buttonStyle(SolidButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
    }

    private var skippable: Bool { [3, 4, 5].contains(step) }

    private var canContinue: Bool {
        switch step {
        case 0: return app.permissions.allGranted
        case 1: return app.rewriteConfigured && app.isReady
        default: return true
        }
    }

    private func advance() { step += 1 }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: 18)
    }

    private func stepTitle(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.system(size: 18, weight: .semibold))
            Text(sub).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keyName: String { app.settings.hotkeyLabel }

    // MARK: 1 · permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(String(localized: "先开两个权限"), String(localized: "Hushtype 需要听到你说话，并把文字放进其他 App。授权成功会自动打勾。"))
            PermissionCard(icon: "mic.fill", title: String(localized: "麦克风"), detail: String(localized: "只在你按下快捷键后录音，录音在本机识别，不上传。"),
                           granted: app.permissions.microphone == .authorized) {
                Task {
                    await app.requestMicrophone()
                    if app.permissions.microphone != .authorized {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }
            PermissionCard(icon: "accessibility", title: String(localized: "辅助功能"),
                           detail: String(localized: "用来监听快捷键、知道光标在哪、把文字插进去。在系统设置里打开 Hushtype，然后回到这里。"),
                           granted: app.permissions.accessibility) { FocusedElement.requestTrust() }
            if !app.permissions.fnKeyFree {
                card {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "globe").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "建议：把「按下 🌐 键时」改成「无操作」")).font(.system(size: 13, weight: .medium))
                            Text(String(localized: "否则按 fn 会同时弹出表情或系统听写。")).font(.system(size: 12)).foregroundStyle(.secondary)
                            Button(String(localized: "打开键盘设置")) {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                    }
                }
            }
        }
    }

    // MARK: 2 · cleanup service + models

    private var prepare: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(String(localized: "整理服务和语音模型"), String(localized: "语音识别在本机完成；整理（去口头禅、加标点、排版）交给 Claude。"))
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $app.settings.provider) {
                        Text(String(localized: "我的 Anthropic API key")).tag(ProviderKind.anthropicKey)
                        Text("Hushtype Cloud").tag(ProviderKind.proxy)
                        Text(String(localized: "先不整理")).tag(ProviderKind.offline)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    if app.settings.provider == .anthropicKey {
                        HStack {
                            SecureField(Secrets.anthropicKey == nil ? String(localized: "粘贴 API key（sk-ant-…）") : String(localized: "已保存在钥匙串"), text: $key)
                                .textFieldStyle(.roundedBorder)
                            Button(String(localized: "保存")) {
                                Secrets.anthropicKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                                key = ""
                                app.reloadBackend()
                            }
                            .disabled(key.isEmpty)
                        }
                        Text(String(localized: "key 只存在本机钥匙串。日常用量每月通常只要几美元。")).font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if app.settings.provider == .proxy {
                        Text(String(localized: "在 设置 › 整理与模型 里填写服务地址和令牌。")).font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "只插入本地识别的原文，不删口头禅、不排版。之后随时可以开。")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 8) {
                    StatusLine(label: String(localized: "中文 / 英文语音模型"), state: app.engineState)
                    Toggle(String(localized: "英文增强（推荐，英文专有名词更准）"), isOn: $app.settings.useSecondEngine)
                    if app.settings.useSecondEngine { StatusLine(label: String(localized: "英文增强模型"), state: app.whisperState) }
                    if let d = app.download { ProgressView(value: d.fraction) { Text(d.message).font(.system(size: 12)) } }
                    if case .failed = app.engineState { Button(String(localized: "重试")) { Task { await app.prepareEngines() } } }
                }
            }
        }
    }

    // MARK: 3 · find the key

    private var findKey: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(String(localized: "找到你的听写键"), String(localized: "按一下键盘左下角的 \(keyName) 键，下面的键帽会亮起来。"))
            card {
                HStack(spacing: 24) {
                    Spacer()
                    BigKeycap(label: keyName, pressed: app.triggerDown)
                    VStack(alignment: .leading, spacing: 6) {
                        Label(app.triggerSeen ? String(localized: "收到了，快捷键可用") : String(localized: "等你按一下…"),
                              systemImage: app.triggerSeen ? "checkmark.circle.fill" : "hand.point.down")
                            .foregroundStyle(app.triggerSeen ? .green : .secondary)
                            .font(.system(size: 14, weight: .medium))
                        Text(String(localized: "习惯用别的键？可以录制任意按键或组合键。")).font(.system(size: 12)).foregroundStyle(.secondary)
                        HotkeyRecorder(app: app, onChanged: { app.onHotkeyChanged?() }).frame(width: 260)
                    }
                    Spacer()
                }
                .padding(.vertical, 18)
            }
        }
    }

    // MARK: 4 · first dictation

    private var firstDictation: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(String(localized: "第一次听写"), String(localized: "点一下下面的框，按 \(keyName) 开始，读出示范句（口头禅也照念），再按一下 \(keyName)。"))
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "示范句")).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    Text(String(localized: "「嗯，帮我约一下明天下午三点，不对，四点的会，然后呃把议程发给大家」"))
                        .font(.system(size: 14))
                }
            }
            TextEditor(text: $practice)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 96)
                .glassPanel(cornerRadius: 14)
            if let last = app.lastResult, !practice.isEmpty {
                card {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Hushtype 帮你做了这些")).font(.system(size: 13, weight: .semibold))
                            Text(String(localized: "去掉了「嗯」「呃」「然后」，把「三点，不对，四点」改成了「四点」，补上了标点。"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(String(format: String(localized: "松开到出字 %.1f 秒"), last.latencySeconds)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 5 · two tricks

    private var tricks: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(String(localized: "再学两招"), String(localized: "都可以在下面的框里直接试。"))
            card {
                HStack(alignment: .top, spacing: 12) {
                    HStack(spacing: 4) { Keycap(label: keyName); Text("+").foregroundStyle(.tertiary); Keycap(label: "⇧") }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "指令模式")).font(.system(size: 13, weight: .semibold))
                        Text(String(localized: "选中一段文字，按住 ⇧ 再按 \(keyName)，说「改正式一点」或「翻成英文」。没选中时，说「写一封请假邮件」它会直接写。"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            card {
                HStack(alignment: .top, spacing: 12) {
                    Keycap(label: "esc")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "取消也不丢")).font(.system(size: 13, weight: .semibold))
                        Text(String(localized: "说到一半按 esc 取消，说过的话照样会识别好存进历史；菜单栏里随时能复制。没找到输入框时，文字会飞到菜单栏等你。"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            TextEditor(text: $practice)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 80)
                .glassPanel(cornerRadius: 14)
        }
    }

    // MARK: 6 · dictionary

    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(String(localized: "让它认识你的专有名词"), String(localized: "人名、宠物名、公司和项目名。导入一次，以后识别就按你的写法。"))
            card {
                VStack(alignment: .leading, spacing: 10) {
                    DictionaryStartRow(icon: "folder", title: String(localized: "从知识库 / 笔记文件夹导入"), detail: String(localized: "比如 Obsidian 库；扫描后你勾选要的词"), action: onOpenDictionary)
                    if DictionaryImport.typelessInstalled {
                        Divider()
                        DictionaryStartRow(icon: "arrow.down.doc", title: String(localized: "从 Typeless 导入"), detail: String(localized: "从它的历史里找出你常用的词"), action: onOpenDictionary)
                    }
                    Divider()
                    DictionaryStartRow(icon: "pencil", title: String(localized: "以后再说"), detail: String(localized: "你改正过的词也会自动记进词典")) { step += 1 }
                }
            }
        }
    }

    // MARK: 7 · done

    private var done: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 46)).foregroundStyle(.green)
            Text(String(localized: "准备好了")).font(.system(size: 22, weight: .bold))
            Text(String(localized: "在任何 App 里按 \(keyName) 开始说，再按一下插入。Hushtype 住在右上角的菜单栏。"))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct PermissionCard: View {
    var icon: String
    var title: String
    var detail: String
    var granted: Bool
    var action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 30).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label(String(localized: "已开启"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 13, weight: .medium))
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(String(localized: "开启"), action: action).buttonStyle(SolidButtonStyle())
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: granted)
        .padding(16)
        .glassPanel(cornerRadius: 18)
    }
}

/// A large key that sinks and lights while the trigger is held.
struct BigKeycap: View {
    var label: String
    var pressed: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .frame(width: 96, height: 96)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(pressed ? Color.accentColor : Color.primary.opacity(0.08)))
            .foregroundStyle(pressed ? Color.white : Color.primary)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            .shadow(color: pressed ? Color.accentColor.opacity(0.5) : .black.opacity(0.12), radius: pressed ? 16 : 6, y: pressed ? 2 : 5)
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
    }
}

struct DictionaryStartRow: View {
    var icon: String
    var title: String
    var detail: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
