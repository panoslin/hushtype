// Renders the Hushtype app icon at every size macOS needs and writes an .iconset folder.
// usage: swift make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 body with ~185/1024 corner radius, centered.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 24 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -s * 10 / 1024)
    shadow.set()
    NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.14, alpha: 1),
                        NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.04, alpha: 1)])!.draw(in: path, angle: -90)
    NSColor.white.withAlphaComponent(0.10).setStroke()
    path.lineWidth = max(1, s * 3 / 1024)
    path.stroke()

    // Waveform: 7 rounded bars, blue → violet.
    let heights: [CGFloat] = [0.22, 0.42, 0.66, 0.86, 0.60, 0.38, 0.20]
    let barW = s * 54 / 1024
    let gap = s * 34 / 1024
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    let grad = NSGradient(colors: [NSColor(calibratedRed: 0.34, green: 0.76, blue: 1.0, alpha: 1),
                                   NSColor(calibratedRed: 0.55, green: 0.45, blue: 1.0, alpha: 1)])!
    for h in heights {
        let bh = body.height * 0.62 * h
        let r = NSRect(x: x, y: body.midY - bh / 2, width: barW, height: bh)
        grad.draw(in: NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2), angle: 90)
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let data = render(px).representation(using: .png, properties: [:])!
    try data.write(to: out.appendingPathComponent("icon_\(name).png"))
}
