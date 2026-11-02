// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func draw(_ s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024 // macOS icon grid: 824pt body inside a 1024 canvas

    // Aluminium squircle with a soft drop shadow
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * u
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    shadow.set()
    NSColor.white.setFill(); bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(white: 0.95, alpha: 1), NSColor(white: 0.66, alpha: 1)])!
        .draw(in: bodyPath, angle: -90)

    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ top: CGFloat, _ bottom: CGFloat) {
        let p = NSBezierPath(ovalIn: NSRect(x: (cx - r) * u, y: (cy - r) * u, width: 2 * r * u, height: 2 * r * u))
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = .black.withAlphaComponent(0.35)
        sh.shadowBlurRadius = 8 * u
        sh.shadowOffset = NSSize(width: 0, height: -4 * u)
        sh.set()
        NSColor.black.setFill(); p.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(white: top, alpha: 1), NSColor(white: bottom, alpha: 1)])!.draw(in: p, angle: -90)
    }

    // D-pad, OK ring and two keys
    circle(512, 600, 250, 0.16, 0.08)
    circle(512, 600, 135, 0.2, 0.12)
    circle(375, 250, 80, 0.18, 0.09)
    circle(649, 250, 80, 0.18, 0.09)

    NSColor.white.setStroke()
    func chevron(_ pts: [(CGFloat, CGFloat)]) {
        let p = NSBezierPath()
        p.lineWidth = 16 * u; p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: NSPoint(x: pts[0].0 * u, y: pts[0].1 * u))
        for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0 * u, y: q.1 * u)) }
        p.stroke()
    }
    chevron([(487, 780), (512, 805), (537, 780)])
    chevron([(487, 420), (512, 395), (537, 420)])
    chevron([(332, 625), (307, 600), (332, 575)])
    chevron([(692, 625), (717, 600), (692, 575)])

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try! draw(CGFloat(size * scale)).representation(using: .png, properties: [:])!
            .write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try! draw(512).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("docs/icon.png"))
