#!/usr/bin/env swift
// Draws the xFinder app icon in code and writes every macOS icon size into
// App/Resources/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make_app_icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let setDir = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: setDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // Background squircle with a blue gradient.
    let inset = 100 * s
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 1),
               ending: NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.62, alpha: 1))!
        .draw(in: bg, angle: -90)
    // Folder shape.
    let folder = NSBezierPath()
    let fx = 250 * s, fy = 300 * s, fw = 524 * s, fh = 360 * s
    folder.move(to: NSPoint(x: fx, y: fy))
    folder.line(to: NSPoint(x: fx + fw, y: fy))
    folder.line(to: NSPoint(x: fx + fw, y: fy + fh))
    folder.line(to: NSPoint(x: fx + 240 * s, y: fy + fh))
    folder.line(to: NSPoint(x: fx + 200 * s, y: fy + fh + 50 * s))
    folder.line(to: NSPoint(x: fx, y: fy + fh + 50 * s))
    folder.close()
    NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
    folder.fill()
    // Up/down transfer arrows.
    NSColor(calibratedRed: 0.08, green: 0.35, blue: 0.85, alpha: 1).setFill()
    func arrow(x: CGFloat, up: Bool) {
        let p = NSBezierPath()
        let w = 70 * s, baseY = fy + 60 * s, topY = fy + 290 * s
        if up {
            p.move(to: NSPoint(x: x - w / 2, y: baseY)); p.line(to: NSPoint(x: x + w / 2, y: baseY))
            p.line(to: NSPoint(x: x + w / 2, y: topY - 80 * s)); p.line(to: NSPoint(x: x + w * 1.3, y: topY - 80 * s))
            p.line(to: NSPoint(x: x, y: topY)); p.line(to: NSPoint(x: x - w * 1.3, y: topY - 80 * s))
            p.line(to: NSPoint(x: x - w / 2, y: topY - 80 * s))
        } else {
            p.move(to: NSPoint(x: x - w / 2, y: topY)); p.line(to: NSPoint(x: x + w / 2, y: topY))
            p.line(to: NSPoint(x: x + w / 2, y: baseY + 80 * s)); p.line(to: NSPoint(x: x + w * 1.3, y: baseY + 80 * s))
            p.line(to: NSPoint(x: x, y: baseY)); p.line(to: NSPoint(x: x - w * 1.3, y: baseY + 80 * s))
            p.line(to: NSPoint(x: x - w / 2, y: baseY + 80 * s))
        }
        p.close(); p.fill()
    }
    arrow(x: fx + fw * 0.36, up: true)
    arrow(x: fx + fw * 0.64, up: false)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try drawIcon(size: CGFloat(px)).write(to: setDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: setDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(setDir.path)")
