import AppKit
import SwiftUI

/// Visual state of the floating indicator.
enum HUDPhase: Equatable {
    case hidden
    case listening(handsFree: Bool)
    /// Recording a voice command (trigger + Shift).
    case command
    case processing
    case done(String)
    case error(String)
    /// A cancelled dictation whose text was still recognized and saved; offers a Copy button.
    case saved(String)
    /// The text had nowhere to go; it is about to fly to the menu bar.
    case noField
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var phase: HUDPhase = .hidden
    /// Why the text went to the menu bar instead of the caret.
    var parkReason = String(localized: "没找到输入框 · 已收进菜单栏")
    /// Another app (a call or meeting) is using the microphone: the other side hears the dictation.
    @Published var inCall = false
    /// When the current recording started (drives the timecode).
    var recordingStarted = Date()
    /// Seconds from release to insertion, shown on `.done`.
    var lastLatency: Double?
    /// Text the HUD's Copy button puts on the clipboard (for `.saved`).
    var copyText: String?
    /// Recent input levels (0...1), newest last.
    @Published var levels: [CGFloat] = Array(repeating: 0, count: HUDModel.bars)
    static let bars = 18

    func push(level: Float) {
        // Light smoothing so bars glide instead of flickering between buffers.
        let prev = levels.last ?? 0
        levels.removeFirst()
        levels.append(0.6 * CGFloat(level) + 0.4 * prev)
    }

    func resetLevels() { levels = Array(repeating: 0, count: Self.bars) }
}

/// Raycast-inspired palette: near-black surface, hairline border, one accent per state.
enum Palette {
    static let surface = Color(.sRGB, red: 13.0 / 255, green: 13.0 / 255, blue: 15.0 / 255, opacity: 1)
    static let hairline = Color.white.opacity(0.10)
    static let ink = Color(red: 0xf4 / 255, green: 0xf4 / 255, blue: 0xf6 / 255)
    static let mute = Color.white.opacity(0.62)
    static let blue = Color(red: 0x57 / 255, green: 0xc1 / 255, blue: 0xff / 255)
    static let green = Color(red: 0x59 / 255, green: 0xd4 / 255, blue: 0x99 / 255)
    static let red = Color(red: 0xff / 255, green: 0x61 / 255, blue: 0x61 / 255)
    static let yellow = Color(red: 0xff / 255, green: 0xc5 / 255, blue: 0x33 / 255)
    /// Brand accent (the app icon's blue → violet), used only for live speech.
    static let accent = LinearGradient(colors: [blue, Color(red: 0x8c / 255, green: 0x73 / 255, blue: 0xff / 255)],
                                       startPoint: .bottom, endPoint: .top)
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 11) { content }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening(let handsFree):
            RecLamp()
            GlassWave(levels: model.levels)
            Timecode(start: model.recordingStarted)
            if model.inCall {
                Text(String(localized: "通话中 · 未静音时对方能听到")).font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 300, alignment: .leading)
            }
            if handsFree {
                Button(action: onCancel) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.ink3)
                }
                .buttonStyle(.plain)
                .help(String(localized: "取消（Esc）"))
            }
        case .command:
            Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
            GlassWave(levels: model.levels)
            Text(String(localized: "指令")).foregroundStyle(.secondary)
        case .processing:
            BrailleSpinner()
            Text(String(localized: "整理中")).font(.system(size: 12, weight: .medium))
        case .done(let msg):
            Text("✓").foregroundStyle(DS.ok)
            Text(msg).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if let l = model.lastLatency { Text(String(format: "%.1fs", l)).foregroundStyle(DS.ink2) }
        case .noField:
            Circle().fill(DS.warn).frame(width: 7, height: 7)
            Text(model.parkReason).font(.system(size: 12, weight: .medium))
        case .saved(let msg):
            Circle().fill(DS.warn).frame(width: 7, height: 7)
            Text(msg).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Button {
                if let t = model.copyText {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(t, forType: .string)
                    model.lastLatency = nil
                    model.phase = .done(String(localized: "已复制"))
                }
            } label: {
                Text(String(localized: "复制")).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        case .error(let msg):
            Circle().fill(DS.warn).frame(width: 7, height: 7)
            Text(msg).font(.system(size: 12, weight: .medium))
                .lineLimit(2).frame(maxWidth: 380, alignment: .leading)
        }
    }
}

/// Live waveform: recent input levels as rounded bars.
struct GlassWave: View {
    var levels: [CGFloat]
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                Capsule().fill(Color.primary.opacity(0.35 + 0.6 * Double(l))).frame(width: 2.5, height: 4 + 15 * l)
            }
        }
        .frame(height: 20)
        .animation(.spring(response: 0.18, dampingFraction: 0.8), value: levels)
    }
}

/// Blinking REC lamp.
struct RecLamp: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Circle().fill(DS.rec).frame(width: 8, height: 8).opacity(on ? 1 : 0.35)
        }
    }
}

/// mm:ss since the recording started.
struct Timecode: View {
    var start: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(start)))
            Text(String(format: "%02d:%02d", s / 60, s % 60)).foregroundStyle(DS.ink2).monospacedDigit()
        }
    }
}

/// 12-segment LED level meter; the top two segments light red when the signal runs hot.
struct LevelMeter: View {
    var level: CGFloat
    static let segments = 12

    var body: some View {
        let lit = Int((level * CGFloat(Self.segments)).rounded())
        HStack(spacing: 2) {
            ForEach(0..<Self.segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? (i >= Self.segments - 2 ? DS.rec : DS.ledOn) : DS.ledOff)
                    .frame(width: 4, height: 12)
            }
        }
        .animation(.linear(duration: 0.06), value: lit)
    }
}

/// Braille-dot spinner (terminal style).
struct BrailleSpinner: View {
    static let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { ctx in
            let i = Int(ctx.date.timeIntervalSinceReferenceDate / 0.08) % Self.frames.count
            Text(String(Self.frames[i])).frame(width: 10)
        }
    }
}

/// Borderless, non-activating panel that floats above everything and never takes focus, so the
/// user's caret stays in the target app.
@MainActor
final class HUDController {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    var onCancel: (() -> Void)?

    /// The pill: frosted blur of whatever is behind it on screen, plus a light or dark tint so it
    /// reads the same in light and dark mode whatever the content underneath.
    private let pill = NSView()
    private let blur: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.autoresizingMask = [.width, .height]
        // Stretchable rounded mask (behind-window effect views ignore layer corner radius).
        let r: CGFloat = 19
        let img = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        v.maskImage = img
        return v
    }()
    private let tint = NSView()
    private let host: NSHostingView<HUDView>
    private static let margin: CGFloat = 16

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 72),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        host = NSHostingView(rootView: HUDView(model: model, onCancel: {}))
        host.sizingOptions = [.intrinsicContentSize]
        // The pill is drawn by Core Animation, not SwiftUI: a SwiftUI fill inside a clear borderless
        // panel renders translucent on recent macOS, which made the HUD hard to read over text.
        pill.wantsLayer = true
        pill.layer?.masksToBounds = true
        pill.layer?.borderWidth = 1
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        pill.addSubview(blur)
        pill.addSubview(tint)
        let container = NSView()
        container.wantsLayer = true
        container.addSubview(pill)
        container.addSubview(host)
        panel.contentView = container
        host.rootView = HUDView(model: model, onCancel: { [weak self] in self?.onCancel?() })
    }

    /// Follows the app's light/dark choice. The glass is tinted so the pill reads the same over any
    /// content behind it (a dark terminal in light mode, a white page in dark mode).
    private func matchAppearance() {
        let appearance = NSApp.effectiveAppearance
        panel.appearance = appearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        blur.appearance = appearance
        tint.layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.30) : NSColor.white.withAlphaComponent(0.62)).cgColor
        pill.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)).cgColor
    }

    func show(_ phase: HUDPhase, autoHide: TimeInterval? = nil) {
        hideWork?.cancel()
        matchAppearance()
        let appearing = !panel.isVisible || model.phase == .hidden
        model.phase = phase
        switch phase {
        case .listening, .command: break
        default: model.resetLevels()
        }
        if appearing {
            placePanel()
            layout(animated: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            animateIn()
        } else {
            layout(animated: true)
        }
        // SwiftUI applies the new phase on the next pass; re-fit once it has.
        DispatchQueue.main.async { [weak self] in self?.layout(animated: !appearing) }
        if let t = autoHide {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
        }
    }

    func hide() {
        hideWork?.cancel()
        guard panel.isVisible else { model.phase = .hidden; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
                self.model.phase = .hidden
            }
        })
        scale(from: 1, to: 0.94, spring: false)
    }

    /// The pill's current frame in screen coordinates.
    var pillScreenFrame: NSRect { panel.convertToScreen(pill.convert(pill.bounds, to: nil)) }

    /// The text had no field to go into: a chip carrying it flies from the HUD along an arc into the
    /// menu bar icon at `target` (screen coordinates), shrinking as it goes. `completion` runs on arrival.
    func flyText(_ text: String, to target: NSRect, completion: @escaping () -> Void) {
        let from = pillScreenFrame
        hide()
        let chip = NSHostingView(rootView: FlyingChip(text: text))
        chip.layoutSubtreeIfNeeded()
        let size = chip.fittingSize
        let fly = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        fly.isOpaque = false
        fly.backgroundColor = .clear
        fly.hasShadow = true
        fly.level = .statusBar
        fly.ignoresMouseEvents = true
        fly.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        fly.contentView = chip
        let start = CGPoint(x: from.midX, y: from.midY)
        let end = CGPoint(x: target.midX, y: target.midY)
        // Control point above the straight line gives the throw an arc.
        let control = CGPoint(x: start.x + (end.x - start.x) * 0.35, y: max(start.y, end.y) + 120)
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.9
        let t0 = CACurrentMediaTime()
        fly.setFrame(NSRect(x: start.x - size.width / 2, y: start.y - size.height / 2, width: size.width, height: size.height), display: true)
        fly.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
            MainActor.assumeIsolated {
                let raw = min(1, (CACurrentMediaTime() - t0) / duration)
                // Ease in-out.
                let k = raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2
                let x = pow(1 - k, 2) * start.x + 2 * (1 - k) * k * control.x + k * k * end.x
                let y = pow(1 - k, 2) * start.y + 2 * (1 - k) * k * control.y + k * k * end.y
                let scale = 1 - 0.85 * k
                let w = max(8, size.width * scale), h = max(6, size.height * scale)
                fly.setFrame(NSRect(x: x - w / 2, y: y - h / 2, width: w, height: h), display: true)
                fly.alphaValue = 1 - 0.7 * k * k
                if raw >= 1 {
                    t.invalidate()
                    fly.orderOut(nil)
                    completion()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: layout & motion

    /// The panel has a fixed size; only the pill inside resizes, so state changes can animate.
    private static let panelSize = NSSize(width: 640, height: 96)

    private func placePanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let s = Self.panelSize
        panel.setFrame(NSRect(x: vf.midX - s.width / 2, y: vf.minY + 12, width: s.width, height: s.height), display: false)
    }

    private func layout(animated: Bool) {
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        size.width = min(size.width, Self.panelSize.width - 2 * Self.margin)
        let r = NSRect(x: (Self.panelSize.width - size.width) / 2, y: Self.margin, width: size.width, height: size.height)
        host.frame = r
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                ctx.allowsImplicitAnimation = true
                pill.animator().frame = r
            }
        } else {
            pill.frame = r
        }
        pill.layer?.cornerRadius = min(19, size.height / 2)
    }

    private func animateIn() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        scale(from: 0.9, to: 1, spring: true)
    }

    /// Scales the pill around its center (Core Animation sublayer transform on the container).
    private func scale(from: CGFloat, to: CGFloat, spring: Bool) {
        guard let layer = panel.contentView?.layer else { return }
        let c = CGPoint(x: Self.panelSize.width / 2, y: Self.margin + 20)
        func t(_ k: CGFloat) -> CATransform3D {
            var m = CATransform3DMakeTranslation(c.x, c.y, 0)
            m = CATransform3DScale(m, k, k, 1)
            return CATransform3DTranslate(m, -c.x, -c.y, 0)
        }
        let anim: CABasicAnimation
        if spring {
            let s = CASpringAnimation(keyPath: "sublayerTransform")
            s.damping = 14
            s.stiffness = 260
            s.mass = 0.8
            s.duration = s.settlingDuration
            anim = s
        } else {
            anim = CABasicAnimation(keyPath: "sublayerTransform")
            anim.duration = 0.14
        }
        anim.fromValue = t(from)
        anim.toValue = t(to)
        layer.sublayerTransform = t(to)
        layer.add(anim, forKey: "scale")
        if to != 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { layer.sublayerTransform = CATransform3DIdentity }
        }
    }
}

/// The chip that flies into the menu bar when there was no text field.
struct FlyingChip: View {
    var text: String
    var body: some View {
        HStack(spacing: 8) {
            Text(String(localized: "未插入")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .frame(width: 260, height: 34)
        .background(.regularMaterial, in: Capsule())
        .scaleEffect(1, anchor: .center)
    }
}
