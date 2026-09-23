// Checks for GIFStream.swift and FrameDiff.swift. Run with Scripts/check-gif-stream.sh,
// which compiles this file together with those sources. XCTest needs Xcode; this
// needs only the Command Line Tools.

import CoreGraphics
import Foundation
import ImageIO

var failures = 0

func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name) \(detail())")
    }
}

let workFolder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())

// MARK: - Pixels

struct RGBA: Equatable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    static let red = RGBA(r: 255, g: 0, b: 0, a: 255)
    static let blue = RGBA(r: 0, g: 0, b: 255, a: 255)
    static let white = RGBA(r: 255, g: 255, b: 255, a: 255)
}

/// Premultiplied BGRA pixels, the layout ScreenRecorder produces.
struct Canvas {
    let width: Int
    let height: Int
    var pixels: [RGBA]

    init(width: Int, height: Int, fill: RGBA) {
        self.width = width
        self.height = height
        pixels = Array(repeating: fill, count: width * height)
    }

    subscript(x: Int, y: Int) -> RGBA {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    mutating func fill(x: Int, y: Int, width w: Int, height h: Int, with color: RGBA) {
        for row in y..<(y + h) { for column in x..<(x + w) { self[column, row] = color } }
    }

    var image: CGImage {
        var bytes = [UInt8]()
        bytes.reserveCapacity(pixels.count * 4)
        for p in pixels { bytes += [p.b, p.g, p.r, p.a] }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        return context.makeImage()!
    }
}

/// Decodes an image to straight RGBA in top-down row order.
func decode(_ image: CGImage) -> Canvas {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var canvas = Canvas(width: image.width, height: image.height, fill: .clear)
    for i in 0..<(image.width * image.height) {
        canvas.pixels[i] = RGBA(r: bytes[i * 4], g: bytes[i * 4 + 1], b: bytes[i * 4 + 2], a: bytes[i * 4 + 3])
    }
    return canvas
}

func close(_ a: RGBA, _ b: RGBA) -> Bool {
    abs(Int(a.r) - Int(b.r)) < 24 && abs(Int(a.g) - Int(b.g)) < 24 && abs(Int(a.b) - Int(b.b)) < 24 && a.a == b.a
}

struct DecodedGIF {
    let frames: [Canvas]
    let delays: [Double]
    var duration: Double { delays.reduce(0, +) }

    init(_ url: URL) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let count = CGImageSourceGetCount(source)
        frames = (0..<count).map { decode(CGImageSourceCreateImageAtIndex(source, $0, nil)!) }
        delays = (0..<count).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as! [CFString: Any]
            let gif = properties[kCGImagePropertyGIFDictionary] as! [CFString: Any]
            return gif[kCGImagePropertyGIFUnclampedDelayTime] as! Double
        }
    }
}

func freshURL(_ name: String) -> URL {
    let url = workFolder.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    return url
}

// MARK: - FrameDiff

func bruteForceChange(_ a: Canvas, _ b: Canvas) -> FrameChange {
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<a.height { for x in 0..<a.width where a[x, y] != b[x, y] {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    guard maxX >= 0 else { return .unchanged }
    return .region(PixelRect(origin: PixelPoint(x: minX, y: minY), size: Dimensions(width: maxX - minX + 1, height: maxY - minY + 1)))
}

var generator = SystemRandomNumberGenerator()
var diffMismatches = 0
for _ in 0..<400 {
    let width = Int.random(in: 1...24, using: &generator), height = Int.random(in: 1...24, using: &generator)
    let before = Canvas(width: width, height: height, fill: .white)
    var after = before
    for _ in 0..<Int.random(in: 0...3, using: &generator) {
        after[Int.random(in: 0..<width, using: &generator), Int.random(in: 0..<height, using: &generator)] = .red
    }
    if FramePixels(after.image)!.change(since: FramePixels(before.image)!) != bruteForceChange(before, after) { diffMismatches += 1 }
}
check(diffMismatches == 0, "change(since:) matches a per-pixel comparison on 400 random frames", "\(diffMismatches) mismatches")

do {
    var canvas = Canvas(width: 8, height: 8, fill: .white)
    canvas[6, 6] = RGBA(r: 250, g: 250, b: 250, a: 250)
    let pixels = FramePixels(canvas.image)!
    check(pixels.opacity(in: PixelRect(origin: .zero, size: Dimensions(width: 5, height: 5))) == .opaque, "opacity: opaque region")
    check(pixels.opacity(in: canvas.image.pixelBounds) == .translucent, "opacity: one pixel short of opaque")
}

// MARK: - Stream

do {
    // 0.0 white, 0.1 red square, 0.2–0.5 unchanged, 0.6 square moves; stop at 1.0.
    let still = Canvas(width: 64, height: 48, fill: .white)
    var first = still
    first.fill(x: 10, y: 10, width: 8, height: 8, with: .red)
    var moved = still
    moved.fill(x: 40, y: 30, width: 8, height: 8, with: .red)
    let timeline: [(Double, Canvas)] = [(0, still), (0.1, first), (0.2, first), (0.3, first), (0.5, first), (0.6, moved)]
    let url = freshURL("round-trip.gif")
    let stream = try GIFFrameStream(url: url)
    for (time, canvas) in timeline { try stream.add(canvas.image, at: time) }
    try stream.finish(at: 1.0)
    let gif = DecodedGIF(url)
    check(gif.frames.count == 3, "unchanged frames are skipped", "\(gif.frames.count) frames")
    check(gif.delays == [0.1, 0.5, 0.4], "each frame lasts until the next change or the stop", "\(gif.delays)")
    if gif.frames.count == 3 {
        let expected = [still, first, moved]
        let matching = zip(gif.frames, expected).allSatisfy { decoded, source in zip(decoded.pixels, source.pixels).allSatisfy(close) }
        check(matching, "decoded frames match the source pictures")
    }
}

do {
    let url = freshURL("long-still.gif")
    let stream = try GIFFrameStream(url: url)
    try stream.add(Canvas(width: 4, height: 4, fill: .white).image, at: 0)
    try stream.add(Canvas(width: 4, height: 4, fill: .red).image, at: 1)
    try stream.finish(at: 1000)
    let gif = DecodedGIF(url)
    check(abs(gif.duration - 1000) < 0.001, "a still longer than 655.35 s keeps its length", "\(gif.duration) s")
    check(gif.frames.last.map { $0[0, 0] == .red } ?? false, "filler frames leave the picture unchanged")
}

do {
    let opaque = Canvas(width: 16, height: 8, fill: .red)
    var halfClear = opaque
    halfClear.fill(x: 8, y: 0, width: 8, height: 8, with: .clear)
    let url = freshURL("transparency.gif")
    let stream = try GIFFrameStream(url: url)
    try stream.add(opaque.image, at: 0)
    try stream.add(halfClear.image, at: 0.5)
    try stream.finish(at: 1.0)
    let gif = DecodedGIF(url)
    let last = gif.frames.last!
    check(last[12, 4] == .clear && close(last[2, 4], .red), "pixels that turn transparent do not keep the old picture", "\(last[12, 4])")
    check(abs(gif.duration - 1.0) < 0.001, "clearing does not change the length", "\(gif.delays)")
}

// MARK: - Files

do {
    let url = freshURL("empty.gif")
    let stream = try GIFFrameStream(url: url)
    do {
        try stream.finish(at: 1)
        check(false, "finishing without frames throws")
    } catch GIFStreamError.noFrames {
        check(!FileManager.default.fileExists(atPath: url.path), "finishing without frames throws and writes nothing")
    }
}

do {
    let url = freshURL("keep-me.gif")
    try Data("existing".utf8).write(to: url)
    let stream = try GIFFrameStream(url: url)
    try stream.add(Canvas(width: 4, height: 4, fill: .blue).image, at: 0)
    stream.abandon()
    check((try? Data(contentsOf: url)) == Data("existing".utf8), "abandoning leaves an existing file alone")

    let replacing = try GIFFrameStream(url: url)
    try replacing.add(Canvas(width: 4, height: 4, fill: .blue).image, at: 0)
    try replacing.finish(at: 1)
    check(DecodedGIF(url).frames.count == 1, "finishing replaces an existing file")
}

do {
    let folder = workFolder.appendingPathComponent("read-only")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    do {
        _ = try GIFFrameStream(url: folder.appendingPathComponent("no.gif"))
        check(false, "an unwritable folder fails before recording")
    } catch GIFStreamError.destinationNotWritable {
        check(true, "an unwritable folder fails before recording")
    }
}

do {
    let folder = workFolder.appendingPathComponent("becomes-read-only")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    let stream = try GIFFrameStream(url: folder.appendingPathComponent("late.gif"))
    try stream.add(Canvas(width: 4, height: 4, fill: .blue).image, at: 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    do {
        try stream.finish(at: 1)
        check(false, "a failed move keeps the recording")
    } catch GIFStreamError.notMoved(let savedAt, _) {
        check(DecodedGIF(savedAt).frames.count == 1, "a failed move keeps the recording and says where")
        try? FileManager.default.removeItem(at: savedAt.deletingLastPathComponent())
    }
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
