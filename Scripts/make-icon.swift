#!/usr/bin/env swift
// Generates Resources/AppIcon.icns by drawing the icon at every size macOS
// expects, writing PNGs into a .iconset directory, then running iconutil.
//
// Usage: swift Scripts/make-icon.swift

import AppKit
import Foundation

// (pixel size, iconset filename) per Apple's required layout.
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

/// One draw routine for every size. Resolution-independent — we use ratios of `s`.
func drawIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        // Rounded-rect "squircle" mask matching Apple's app icon shape.
        let cornerRadius = s * 0.22
        let bg = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        bg.addClip()

        // Background: deep purple → magenta gradient. Reads well at small sizes
        // and stands out from Apple's blue/silver system icons.
        let gradient = NSGradient(colors: [
            NSColor(red: 0.35, green: 0.10, blue: 0.55, alpha: 1.0),
            NSColor(red: 0.85, green: 0.20, blue: 0.50, alpha: 1.0),
        ])!
        gradient.draw(in: rect, angle: -90)

        // Big bold "GIF" wordmark in white.
        let fontSize = s * 0.32
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: -fontSize * 0.04,
        ]
        let text = NSAttributedString(string: "GIF", attributes: textAttrs)
        let textSize = text.size()
        let textRect = NSRect(
            x: (s - textSize.width) / 2,
            y: s * 0.30,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect)

        // Red record dot in the upper-right corner — instantly says "recorder".
        let dotSize = s * 0.18
        let dotRect = NSRect(
            x: s - dotSize - s * 0.14,
            y: s - dotSize - s * 0.14,
            width: dotSize,
            height: dotSize
        )
        // Soft white halo so the dot pops on the magenta.
        NSColor.white.withAlphaComponent(0.35).setFill()
        let halo = NSBezierPath(ovalIn: dotRect.insetBy(dx: -s * 0.025, dy: -s * 0.025))
        halo.fill()
        NSColor(red: 0.95, green: 0.12, blue: 0.20, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        return true
    }

    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: s, height: s)
    return rep.representation(using: .png, properties: [:])
}

// Find project root from this script's location (Scripts/ → ..).
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

// Run iconutil to bundle the iconset into a single .icns file.
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
