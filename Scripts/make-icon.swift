#!/usr/bin/env swift
// Generates Resources/AppIcon.icns by drawing the icon at every size macOS
// expects, writing PNGs into a .iconset directory, then running iconutil.
//
// Usage: swift Scripts/make-icon.swift

import AppKit
import Foundation

let entries: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

// The picture: a screen showing a sunset wallpaper, with a rectangle of it
// snapped out and lifted off the glass, record dot on its corner. The hole it
// left behind keeps the dashed marquee. "Snap a piece of the screen."
func drawIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }
    func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225).addClip()

        NSGradient(colors: [rgb(0.09, 0.06, 0.22), rgb(0.21, 0.12, 0.46)])!.draw(in: rect, angle: 90)
        NSGradient(colors: [rgb(1.0, 0.45, 0.30, 0.55), rgb(1.0, 0.45, 0.30, 0)])!
            .draw(in: NSBezierPath(ovalIn: r(0.30, -0.40, 1.2, 1.2)), relativeCenterPosition: .zero)
        NSGradient(colors: [rgb(0.35, 0.60, 1.0, 0.40), rgb(0.35, 0.60, 1.0, 0)])!
            .draw(in: NSBezierPath(ovalIn: r(-0.45, 0.40, 1.1, 1.1)), relativeCenterPosition: .zero)

        let screen = r(0.11, 0.19, 0.78, 0.55)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: s * 0.055, yRadius: s * 0.055)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.06, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        rgb(0.06, 0.05, 0.14).setFill()
        screenPath.fill()
        ctx.restoreGState()
        screenPath.lineWidth = max(1, s * 0.008)
        NSColor.white.withAlphaComponent(0.20).setStroke()
        screenPath.stroke()

        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: s * 0.43, y: screen.minY))
        stand.line(to: NSPoint(x: s * 0.57, y: screen.minY))
        stand.line(to: NSPoint(x: s * 0.60, y: s * 0.12))
        stand.line(to: NSPoint(x: s * 0.40, y: s * 0.12))
        stand.close()
        rgb(0.16, 0.14, 0.30).setFill()
        stand.fill()
        let base = NSBezierPath(roundedRect: r(0.33, 0.10, 0.34, 0.025), xRadius: s * 0.0125, yRadius: s * 0.0125)
        rgb(0.20, 0.18, 0.36).setFill()
        base.fill()

        let display = screen.insetBy(dx: s * 0.022, dy: s * 0.022)
        let displayPath = NSBezierPath(roundedRect: display, xRadius: s * 0.04, yRadius: s * 0.04)

        func at(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint {
            NSPoint(x: display.minX + display.width * fx, y: display.minY + display.height * fy)
        }
        // Draws the wallpaper in display coordinates, so the lifted piece can show the
        // exact pixels that are missing from the hole.
        func drawWallpaper() {
            NSGradient(colors: [rgb(0.99, 0.62, 0.28), rgb(0.95, 0.33, 0.52), rgb(0.40, 0.36, 0.96)])!
                .draw(in: display, angle: 60)
            let sunSize = display.width * 0.26
            let sunCenter = at(0.68, 0.60)
            NSGradient(colors: [rgb(1.0, 0.97, 0.85), rgb(1.0, 0.85, 0.55)])!
                .draw(in: NSBezierPath(ovalIn: NSRect(x: sunCenter.x - sunSize / 2, y: sunCenter.y - sunSize / 2, width: sunSize, height: sunSize)), angle: 90)
            let farHills = NSBezierPath()
            farHills.move(to: at(0, 0))
            farHills.line(to: at(0, 0.42))
            farHills.curve(to: at(0.55, 0.30), controlPoint1: at(0.18, 0.52), controlPoint2: at(0.38, 0.24))
            farHills.curve(to: at(1.0, 0.44), controlPoint1: at(0.72, 0.36), controlPoint2: at(0.88, 0.50))
            farHills.line(to: at(1.0, 0))
            farHills.close()
            rgb(0.30, 0.16, 0.52, 0.85).setFill()
            farHills.fill()
            let nearHills = NSBezierPath()
            nearHills.move(to: at(0, 0))
            nearHills.line(to: at(0, 0.22))
            nearHills.curve(to: at(0.50, 0.14), controlPoint1: at(0.15, 0.10), controlPoint2: at(0.35, 0.26))
            nearHills.curve(to: at(1.0, 0.20), controlPoint1: at(0.65, 0.04), controlPoint2: at(0.85, 0.28))
            nearHills.line(to: at(1.0, 0))
            nearHills.close()
            rgb(0.14, 0.09, 0.32).setFill()
            nearHills.fill()
        }

        NSGraphicsContext.saveGraphicsState()
        displayPath.addClip()
        drawWallpaper()
        NSGraphicsContext.restoreGraphicsState()

        let hole = NSRect(x: at(0.28, 0).x, y: at(0, 0.20).y, width: display.width * 0.50, height: display.height * 0.56)
        let holeRadius = s * 0.018
        NSGraphicsContext.saveGraphicsState()
        displayPath.addClip()
        rgb(0.05, 0.04, 0.12, 0.78).setFill()
        NSBezierPath(roundedRect: hole, xRadius: holeRadius, yRadius: holeRadius).fill()
        let marquee = NSBezierPath(roundedRect: hole, xRadius: holeRadius, yRadius: holeRadius)
        marquee.lineWidth = max(1, s * 0.012)
        let dash: [CGFloat] = [s * 0.035, s * 0.028]
        marquee.setLineDash(dash, count: dash.count, phase: 0)
        NSColor.white.withAlphaComponent(0.65).setStroke()
        marquee.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let pivot = NSPoint(x: hole.midX, y: hole.midY)
        let lift = NSAffineTransform()
        lift.translateX(by: pivot.x + s * 0.075, yBy: pivot.y + s * 0.085)
        lift.rotate(byDegrees: -8)
        lift.scale(by: 1.14)
        lift.translateX(by: -pivot.x, yBy: -pivot.y)
        let piece = lift.transform(NSBezierPath(roundedRect: hole, xRadius: holeRadius, yRadius: holeRadius))

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.04), blur: s * 0.08, color: NSColor.black.withAlphaComponent(0.65).cgColor)
        NSColor.white.setFill()
        piece.fill()
        ctx.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        piece.addClip()
        lift.concat()
        drawWallpaper()
        NSGraphicsContext.restoreGraphicsState()

        piece.lineWidth = max(1, s * 0.016)
        NSColor.white.setStroke()
        piece.stroke()

        let corner = lift.transform(NSPoint(x: hole.maxX, y: hole.maxY))
        let dotSize = s * 0.21
        let dotRect = NSRect(x: corner.x - dotSize / 2, y: corner.y - dotSize / 2, width: dotSize, height: dotSize)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        ctx.restoreGState()
        NSGradient(colors: [rgb(1.0, 0.45, 0.42), rgb(0.86, 0.06, 0.18)])!
            .draw(in: NSBezierPath(ovalIn: dotRect.insetBy(dx: s * 0.034, dy: s * 0.034)), angle: -90)
        NSColor.white.withAlphaComponent(0.40).setFill()
        NSBezierPath(ovalIn: NSRect(x: dotRect.minX + dotSize * 0.30, y: dotRect.minY + dotSize * 0.60, width: dotSize * 0.40, height: dotSize * 0.18)).fill()

        return true
    }

    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: s, height: s)
    return rep.representation(using: .png, properties: [:])
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = root.appendingPathComponent("build").appendingPathComponent("AppIcon.iconset")
let icnsURL = root.appendingPathComponent("Resources").appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(at: iconsetURL)
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for (pixelSize, filename) in entries {
    guard let data = drawIcon(size: pixelSize) else {
        FileHandle.standardError.write("Failed to draw \(filename)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconsetURL.appendingPathComponent(filename))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", icnsURL.path, iconsetURL.path]
try task.run()
task.waitUntilExit()

guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

print("✓ Wrote \(icnsURL.path)")
