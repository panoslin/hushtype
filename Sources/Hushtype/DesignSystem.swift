import AppKit
import SwiftUI

/// Hushtype's visual language: Liquid Glass. Content floats on glass panels over a soft sky backdrop;
/// all colours are the system's semantic ones, so light and dark mode both follow macOS.
/// On macOS 26+ panels use the system `glassEffect`; earlier systems fall back to materials.
enum DS {
    /// A colour with separate light and dark values (follows the window's appearance).
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static let navy = NSColor(srgbRed: 0x0c / 255, green: 0x1b / 255, blue: 0x33 / 255, alpha: 1)
    private static func navyA(_ a: CGFloat) -> NSColor { navy.withAlphaComponent(a) }
    private static func whiteA(_ a: CGFloat) -> NSColor { NSColor.white.withAlphaComponent(a) }

    // Text on glass (design preview: light #0c1b33, dark white).
    static let ink = dyn(navy, .white)
    static let ink2 = dyn(navyA(0.72), whiteA(0.75))
    static let ink3 = dyn(navyA(0.50), whiteA(0.55))
    // Glass surfaces.
    static let cardFill = dyn(whiteA(0.38), whiteA(0.10))
    static let cardBorder = dyn(whiteA(0.70), whiteA(0.22))
    static let cardHighlight = dyn(whiteA(0.85), whiteA(0.35))
    static let cardLine = dyn(navyA(0.08), whiteA(0.14))
    static let sideFill = dyn(whiteA(0.22), whiteA(0.06))
    static let sideLine = dyn(whiteA(0.55), whiteA(0.12))
    static let navOn = dyn(whiteA(0.50), whiteA(0.16))

    static let line = cardLine
    static let line2 = cardBorder
    /// Light tint used for fields and chips sitting on glass.
    static let panel = dyn(whiteA(0.45), whiteA(0.10))
    static let panel2 = dyn(whiteA(0.60), whiteA(0.16))
    static let rec = Color(nsColor: .systemRed)
    static let ok = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemOrange)
    static let accent = Color.accentColor

    // Legacy names used by older views.
    static var bg: Color { .clear }
    static var side: Color { sideFill }
    static var surface: Color { panel }
    static var hairline: Color { line }
    static var green: Color { ok }
    static var amber: Color { warn }
    static var blue: Color { accent }
    static var violet: Color { accent }
    static var canvas: Color { .clear }
    static var ledOn: Color { ink }
    static var ledOff: Color { cardLine }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: glass

extension View {
    /// The design preview's glass card: frosted blur of the sky, a light or dark wash, a bright hairline
    /// and an inner top highlight.
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial).opacity(0.55)
                    shape.fill(DS.cardFill)
                    shape.strokeBorder(LinearGradient(colors: [DS.cardHighlight, .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
            }
            .overlay(shape.strokeBorder(DS.cardBorder, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.15), radius: 12, y: 8)
    }

    /// A Liquid Glass panel (macOS 26+), or a material panel on older systems.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            // Clear glass keeps the sky visible through the panel (the "liquid" look); a faint white
            // tint keeps text legible over bright clouds.
            self.glassEffect((interactive ? Glass.clear.interactive() : Glass.clear).tint(Color.white.opacity(0.06)),
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.25)))
        }
    }

    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }
}

/// The sky behind the glass: soft clouds over a vertical gradient, darker at night (dark mode).
struct SkyBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    private static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    var body: some View {
        let dark = scheme == .dark
        // Same palette as the design preview (option 05).
        let sky = dark ? [Self.hex(0x0f1d3a), Self.hex(0x36507f), Self.hex(0x8b6a7a)]
                       : [Self.hex(0x6fa8e6), Self.hex(0xbcd8f5), Self.hex(0xffd9c2)]
        let cloud = dark ? Color(red: 170 / 255, green: 190 / 255, blue: 230 / 255).opacity(0.35) : Color.white.opacity(0.75)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(stops: [.init(color: sky[0], location: 0), .init(color: sky[1], location: 0.6),
                                       .init(color: sky[2], location: 1)], startPoint: .top, endPoint: .bottom)
                ForEach(Array(Self.clouds.enumerated()), id: \.offset) { _, c in
                    Circle()
                        .fill(RadialGradient(colors: [cloud, .clear], center: .center, startRadius: 0, endRadius: c.w * 0.5))
                        .frame(width: c.w, height: c.w)
                        .scaleEffect(x: 1, y: c.h / c.w)
                        .position(x: w * c.x, y: h * c.y)
                }
            }
        }
        .ignoresSafeArea()
    }

    /// (x, y) as fractions of the window, (w, h) in points: the preview's four clouds, scaled up a little.
    private static let clouds: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = [
        (0.20, 0.30, 520, 180), (0.70, 0.20, 680, 220), (0.55, 0.75, 600, 200), (0.15, 0.85, 480, 160),
    ]
}

/// Small secondary label above a value ("今天", "最近 7 天").
struct SpecLabel: View {
    var text: String
    var color: Color = DS.ink2

    init(_ text: String, color: Color = DS.ink2) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(color)
    }
}

/// Glass card.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: 16, interactive: true)
    }
}

typealias GlowCard = Panel

/// Number that rolls to its new value.
struct RollingNumber: View {
    var value: Int
    var size: CGFloat = 24

    var body: some View {
        Text(value.formatted(.number.grouping(.automatic)))
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(value)))
            .animation(.spring(response: 0.6, dampingFraction: 0.9), value: value)
    }
}

/// Headline whose characters rise in one after another.
struct RevealText: View {
    var text: String
    var size: CGFloat
    @Local private var shown = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { i, c in
                Text(String(c))
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 6)
                    .animation(.easeOut(duration: 0.45).delay(Double(i) * 0.04), value: shown)
            }
        }
        .font(.system(size: size, weight: .bold))
        .tracking(-size * 0.02)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onAppear { shown = true }
    }
}

struct GradientText: View {
    var text: String
    var size: CGFloat

    var body: some View {
        Text(text).font(.system(size: size, weight: .bold)).tracking(-size * 0.02)
    }
}

/// A keyboard key on glass.
struct Keycap: View {
    var label: String
    var glow = false

    var body: some View {
        Text(label)
            .font(DS.mono(11))
            .foregroundStyle(DS.ink)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.cardBorder))
    }
}

/// Small tinted tag ("已取消").
struct Badge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// Status lamp: green when ready, blinking red while recording, orange while busy.
struct Lamp: View {
    enum Kind { case ready, recording, busy, attention }
    var kind: Kind
    @Local private var blink = false

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .opacity(kind == .recording && blink ? 0.35 : 1)
            .onAppear {
                guard kind == .recording else { return }
                withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: true)) { blink = true }
            }
    }

    private var color: Color {
        switch kind {
        case .ready: return DS.ok
        case .recording: return DS.rec
        case .busy, .attention: return DS.warn
        }
    }
}

/// Primary button: glass-prominent on macOS 26, bordered-prominent before.
struct GlowButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.glassProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.borderedProminent)
        }
    }
}

typealias SolidButtonStyle = GlowButtonStyle

/// Secondary button: plain glass.
struct GhostButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label.font(.system(size: 12)) }
                .buttonStyle(.glass).controlSize(.small)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label.font(.system(size: 12)) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }
}

/// Seven-day bars; today's bar is solid, the rest translucent.
struct DayBars: View {
    var values: [Int]
    var height: CGFloat = 80
    @Local private var shown = false

    var body: some View {
        let maxV = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(i == values.count - 1 ? Color.primary.opacity(0.85) : Color.primary.opacity(0.18))
                    .frame(height: shown ? max(5, height * CGFloat(v) / CGFloat(maxV)) : 5)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height, alignment: .bottom)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.1)) { shown = true } }
    }
}

struct AuroraBackground: View {
    var body: some View { SkyBackdrop() }
}

