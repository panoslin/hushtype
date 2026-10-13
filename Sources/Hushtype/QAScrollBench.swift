import AppKit
import HushtypeCore

/// QA hook: `--qa-scroll-bench home|dictionary` scrolls the main window's list down and up with the
/// pointer over it (so hover effects fire as rows pass) and logs frame pacing from the display link.
@MainActor
final class QAScrollBench: NSObject {
    private let window: NSWindow
    private let scroll: NSScrollView
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var direction: CGFloat = 1
    private var passes = 0
    private let label: String
    private static var running: QAScrollBench?

    static func start(in window: NSWindow, label: String) {
        guard let content = window.contentView, let scroll = largestScrollView(in: content) else {
            Log.info("scroll bench: no scroll view")
            return
        }
        // Test on the fastest display (a ProMotion laptop screen if there is one): that's where jank shows.
        if let fast = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }),
           fast != window.screen {
            let f = fast.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.midX - window.frame.width / 2, y: f.midY - window.frame.height / 2))
        }
        let b = QAScrollBench(window: window, scroll: scroll, label: label)
        running = b
        b.begin()
    }

    private init(window: NSWindow, scroll: NSScrollView, label: String) {
        self.window = window
        self.scroll = scroll
        self.label = label
    }

    private static func largestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, (s.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        walk(view)
        return best
    }

    private func begin() {
        // Put the pointer over the list so hover tracking runs while rows move under it.
        let r = scroll.convert(scroll.bounds, to: nil)
        let onScreen = window.convertToScreen(r)
        let primary = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.midX, y: primary - onScreen.midY))
        scroll.contentView.scroll(to: .zero)
        Log.info("scroll bench on \(window.screen?.localizedName ?? "?") (max \(window.screen?.maximumFramesPerSecond ?? 0) Hz)")
        let l = scroll.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        stamps.append(l.timestamp)
        let clip = scroll.contentView
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        var y = clip.bounds.origin.y + 12 * direction
        if y >= maxY { y = maxY; direction = -1; passes += 1 }
        if y <= 0, direction < 0 { y = 0; direction = 1; passes += 1 }
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        if passes >= 4 || stamps.count > 2400 { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }.sorted()
        guard !gaps.isEmpty else { return }
        let nominal = gaps[gaps.count / 2]
        let total = stamps.last! - stamps.first!
        let hitches = gaps.filter { $0 > nominal * 1.5 }.count
        let p95 = gaps[Int(Double(gaps.count) * 0.95)]
        let worst = gaps.last!
        Log.info(String(format: "scroll bench %@: %.0f fps avg (display %.0f Hz), %d/%d frames late (%.1f%%), p95 %.1f ms, worst %.1f ms, doc %.0f pt",
                        label, Double(gaps.count) / total, 1 / nominal, hitches, gaps.count,
                        100 * Double(hitches) / Double(gaps.count), p95 * 1000, worst * 1000,
                        scroll.documentView?.frame.height ?? 0))
        Self.running = nil
    }
}
