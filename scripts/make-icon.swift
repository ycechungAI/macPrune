// Draws the app icon (a white "P" with a leaf on a green squircle) and writes
// Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024  // design on a 1024 grid

    // macOS icon grid: 824pt squircle centred on the 1024 canvas, with a soft drop shadow.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor(srgbRed: 0.13, green: 0.55, blue: 0.33, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.80, blue: 0.48, alpha: 1),
                        NSColor(srgbRed: 0.08, green: 0.47, blue: 0.30, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // The "P".
    let font = NSFont.systemFont(ofSize: 640 * s, weight: .heavy)
    let p = NSAttributedString(string: "P", attributes: [.font: font, .foregroundColor: NSColor.white])
    let size = p.size()
    p.draw(at: NSPoint(x: (1024 * s - size.width) / 2 - 10 * s, y: (1024 * s - size.height) / 2 - 8 * s))

    // A leaf sprouting from the top right of the P.
    NSGraphicsContext.saveGraphicsState()
    let shift = NSAffineTransform()
    shift.translateX(by: -55 * s, yBy: -62 * s)
    shift.concat()
    let leaf = NSBezierPath()
    let base = NSPoint(x: 640 * s, y: 760 * s), tip = NSPoint(x: 800 * s, y: 860 * s)
    leaf.move(to: base)
    leaf.curve(to: tip, controlPoint1: NSPoint(x: 650 * s, y: 860 * s), controlPoint2: NSPoint(x: 730 * s, y: 880 * s))
    leaf.curve(to: base, controlPoint1: NSPoint(x: 810 * s, y: 790 * s), controlPoint2: NSPoint(x: 740 * s, y: 740 * s))
    NSColor(srgbRed: 0.80, green: 0.97, blue: 0.62, alpha: 1).setFill()
    leaf.fill()
    let vein = NSBezierPath()
    vein.move(to: NSPoint(x: base.x + 10 * s, y: base.y + 8 * s))
    vein.curve(to: NSPoint(x: tip.x - 25 * s, y: tip.y - 15 * s),
               controlPoint1: NSPoint(x: 700 * s, y: 800 * s), controlPoint2: NSPoint(x: 740 * s, y: 830 * s))
    vein.lineWidth = 7 * s
    NSColor(srgbRed: 0.13, green: 0.55, blue: 0.33, alpha: 0.6).setStroke()
    vein.stroke()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try draw(pt * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
try draw(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon.png"))
print(task.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
