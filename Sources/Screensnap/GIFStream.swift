import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ImageIO's animated-GIF writer keeps every added frame until `CGImageDestinationFinalize`
// and then needs ~60 MB per Retina frame to build one palette for the whole file, so
// memory grows with recording length. The types here write the animation one frame at a
// time instead: ImageIO quantizes each frame on its own, and its image block is spliced
// into a single growing file.

enum GIFStreamError: LocalizedError {
    case quantizationFailed
    case unexpectedFormat(String)
    case canvasTooLarge(Dimensions)
    case cannotCreateFile(URL)
    case noFrames
    case closed

    var errorDescription: String? {
        switch self {
        case .quantizationFailed: return "Could not convert a frame to GIF."
        case .unexpectedFormat(let detail): return "ImageIO produced an unexpected GIF (\(detail))."
        case .canvasTooLarge(let size): return "\(size.label) is too large for a GIF."
        case .cannotCreateFile(let url): return "Could not create \(url.lastPathComponent)."
        case .noFrames: return "No frames were captured."
        case .closed: return "The GIF is already closed."
        }
    }
}

/// A moment on the GIF timeline in hundredths of a second, the unit GIF delays use.
/// Delays are the gaps between rounded absolute times, so rounding never accumulates.
struct GIFTime {
    let centiseconds: Int

    init(seconds: CFTimeInterval) {
        centiseconds = Int((seconds * 100).rounded())
    }

    /// How long a frame shown at `self` stays up before `next`. Browsers slow any delay
    /// under 2 cs down to 10 cs, so shorter gaps are stretched to 2.
    func delay(until next: GIFTime) -> UInt16 {
        UInt16(clamping: max(2, next.centiseconds - centiseconds))
    }
}

struct GIFColorTable {
    /// The table holds `2 << sizeCode` colours; the code is what GIF stores in its flags.
    let sizeCode: UInt8
    let rgb: Data
}

enum GIFRowOrder {
    case sequential
    case interlaced
}

/// One frame as ImageIO quantized it: its own palette and its LZW-compressed pixels,
/// lifted out of a single-frame GIF so it can be placed anywhere in a longer animation.
struct EncodedGIFFrame {
    /// Where ImageIO put the image inside its own canvas.
    let bounds: PixelRect
    let palette: GIFColorTable
    let rowOrder: GIFRowOrder
    let transparentIndex: UInt8?
    /// LZW minimum code size, the data sub-blocks and their terminator, verbatim.
    let imageData: Data

    init(quantizing image: CGImage) throws {
        let gif = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(gif, UTType.gif.identifier as CFString, 1, nil) else {
            throw GIFStreamError.quantizationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GIFStreamError.quantizationFailed }
        try self.init(parsing: gif as Data)
    }

    /// Reads the first image of a GIF file, and the palette and transparency that apply to it.
    init(parsing gif: Data) throws {
        var reader = GIFReader(gif)
        let signature = try String(decoding: reader.bytes(6), as: UTF8.self)
        guard signature == "GIF87a" || signature == "GIF89a" else {
            throw GIFStreamError.unexpectedFormat("signature \(signature)")
        }
        _ = try reader.bytes(4) // logical screen width and height
        let screenFlags = try reader.byte()
        _ = try reader.bytes(2) // background colour index, pixel aspect ratio
        var palette = screenFlags & 0x80 != 0 ? try reader.colorTable(sizeCode: screenFlags & 0x07) : nil
        var transparentIndex: UInt8?

        while true {
            switch try reader.byte() {
            case 0x21:
                let label = try reader.byte()
                let body = try reader.subBlockPayload()
                if label == 0xF9, body.count >= 4, body[body.startIndex] & 0x01 != 0 {
                    transparentIndex = body[body.startIndex + 3]
                }
            case 0x2C:
                let x = try reader.uint16(), y = try reader.uint16()
                let width = try reader.uint16(), height = try reader.uint16()
                let imageFlags = try reader.byte()
                if imageFlags & 0x80 != 0 {
                    palette = try reader.colorTable(sizeCode: imageFlags & 0x07)
                }
                guard let palette else { throw GIFStreamError.unexpectedFormat("image without a palette") }
                let dataStart = reader.position
                _ = try reader.byte() // LZW minimum code size
                try reader.skipSubBlocks()
                self.bounds = PixelRect(origin: PixelPoint(x: x, y: y), size: Dimensions(width: width, height: height))
                self.palette = palette
                self.rowOrder = imageFlags & 0x40 != 0 ? .interlaced : .sequential
                self.transparentIndex = transparentIndex
                self.imageData = gif[dataStart..<reader.position]
                return
            case let block:
                throw GIFStreamError.unexpectedFormat("block 0x\(String(block, radix: 16)) before the first image")
            }
        }
    }
}

private struct GIFReader {
    let data: Data
    private(set) var position: Data.Index

    init(_ data: Data) {
        self.data = data
        self.position = data.startIndex
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard data.endIndex - position >= count else { throw GIFStreamError.unexpectedFormat("truncated") }
        defer { position += count }
        return data[position..<(position + count)]
    }

    mutating func byte() throws -> UInt8 {
        let one = try bytes(1)
        return one[one.startIndex]
    }

    mutating func uint16() throws -> Int {
        let pair = try bytes(2)
        return Int(pair[pair.startIndex]) | Int(pair[pair.startIndex + 1]) << 8
    }

    mutating func colorTable(sizeCode: UInt8) throws -> GIFColorTable {
        GIFColorTable(sizeCode: sizeCode, rgb: try bytes(3 * (2 << Int(sizeCode))))
    }

    /// Sub-blocks up to and including the zero-length terminator; returns their payload.
    mutating func subBlockPayload() throws -> Data {
        var payload = Data()
        while true {
            let length = Int(try byte())
            if length == 0 { return payload }
            payload.append(try bytes(length))
        }
    }

    mutating func skipSubBlocks() throws {
        while true {
            let length = Int(try byte())
            if length == 0 { return }
            _ = try bytes(length)
        }
    }
}

/// An animated GIF file written front to back. Every frame carries its own palette,
/// so nothing about earlier frames has to be kept.
final class GIFFileWriter {
    private let handle: FileHandle

    init(creating url: URL, canvas: Dimensions) throws {
        guard let width = UInt16(exactly: canvas.width), let height = UInt16(exactly: canvas.height) else {
            throw GIFStreamError.canvasTooLarge(canvas)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw GIFStreamError.cannotCreateFile(url)
        }
        handle = try FileHandle(forWritingTo: url)

        var header = Data("GIF89a".utf8)
        header.appendLittleEndian(width)
        header.appendLittleEndian(height)
        header.append(contentsOf: [0x70, 0x00, 0x00]) // no global palette, 8-bit colour resolution
        header.append(contentsOf: [0x21, 0xFF, 0x0B])
        header.append(contentsOf: Data("NETSCAPE2.0".utf8))
        header.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00]) // loop forever
        try handle.write(contentsOf: header)
    }

    /// Draws `frame` with its top-left corner at `origin`, over whatever is already shown.
    func append(_ frame: EncodedGIFFrame, at origin: PixelPoint, delay: UInt16) throws {
        var block = Data(capacity: frame.imageData.count + frame.palette.rgb.count + 20)

        let keepPreviousFrame: UInt8 = 1 << 2
        let hasTransparency: UInt8 = frame.transparentIndex == nil ? 0 : 1
        block.append(contentsOf: [0x21, 0xF9, 0x04, keepPreviousFrame | hasTransparency])
        block.appendLittleEndian(delay)
        block.append(contentsOf: [frame.transparentIndex ?? 0, 0x00])

        block.append(0x2C)
        block.appendLittleEndian(UInt16(clamping: origin.x + frame.bounds.origin.x))
        block.appendLittleEndian(UInt16(clamping: origin.y + frame.bounds.origin.y))
        block.appendLittleEndian(UInt16(clamping: frame.bounds.size.width))
        block.appendLittleEndian(UInt16(clamping: frame.bounds.size.height))
        let interlaced: UInt8
        switch frame.rowOrder {
        case .sequential: interlaced = 0
        case .interlaced: interlaced = 0x40
        }
        block.append(0x80 | interlaced | frame.palette.sizeCode)
        block.append(frame.palette.rgb)
        block.append(frame.imageData)
        try handle.write(contentsOf: block)
    }

    func close() throws {
        try handle.write(contentsOf: Data([0x3B]))
        try handle.close()
    }

    func abandon() {
        try? handle.close()
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }
}

/// Builds an animated GIF on disk from timestamped frames as they arrive. Each frame is
/// compared with the last one written and only the rectangle that changed is quantized
/// and appended, so memory holds about one frame however long the recording runs, and a
/// still screen costs a comparison per frame.
///
/// Frames go to a scratch file that moves to `url` on `finish()`, so the recordings
/// folder never shows a partial GIF and abandoning never touches a file already there.
///
/// Not thread-safe: `@unchecked Sendable` only so an owner can hand it to the one
/// serial queue that then makes every call.
final class GIFFrameStream: @unchecked Sendable {
    private let url: URL
    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("screensnap-\(UUID().uuidString).gif")
    /// How long the final frame stays up after the last frame seen.
    private let frameDuration: CFTimeInterval
    private var state: State = .empty

    private enum State {
        case empty
        case streaming(Progress)
        case closed
    }

    /// A frame is written only once the next change arrives, because its GIF delay
    /// (how long it stays up) is not known before then.
    private struct Pending {
        let frame: EncodedGIFFrame
        let origin: PixelPoint
        let time: GIFTime
    }

    private struct Progress {
        let file: GIFFileWriter
        /// What the animation shows once `pending` is drawn; nil when the frame's
        /// pixels cannot be read, and the next frame is then written whole.
        var shown: FramePixels?
        var pending: Pending
        /// Unchanged frames are not written, but a still stretch at the end must last.
        var lastSeen: CFTimeInterval
    }

    init(url: URL, framerate: Int) {
        self.url = url
        self.frameDuration = 1.0 / Double(max(1, framerate))
    }

    /// `timestamp` is seconds since the recording started.
    func add(_ image: CGImage, at timestamp: CFTimeInterval) throws {
        let pixels = FramePixels(image)
        switch state {
        case .closed:
            return

        case .empty:
            let first = try EncodedGIFFrame(quantizing: image)
            let file = try GIFFileWriter(creating: scratch, canvas: Dimensions(width: image.width, height: image.height))
            state = .streaming(Progress(
                file: file,
                shown: pixels,
                pending: Pending(frame: first, origin: .zero, time: GIFTime(seconds: timestamp)),
                lastSeen: timestamp
            ))

        case .streaming(var progress):
            progress.lastSeen = timestamp
            defer { state = .streaming(progress) }
            let change: FrameChange
            if let shown = progress.shown, let pixels {
                change = pixels.change(since: shown)
            } else {
                change = .region(PixelRect(origin: .zero, size: Dimensions(width: image.width, height: image.height)))
            }
            guard case .region(let rect) = change else { return }
            guard let changed = image.cropping(to: rect.cgRect) else { throw GIFStreamError.quantizationFailed }
            let frame = try EncodedGIFFrame(quantizing: changed)
            let now = GIFTime(seconds: timestamp)
            try progress.file.append(progress.pending.frame, at: progress.pending.origin, delay: progress.pending.time.delay(until: now))
            progress.pending = Pending(frame: frame, origin: rect.origin, time: now)
            progress.shown = pixels
        }
    }

    /// Writes the last frame and moves the GIF to `url`, replacing any file there.
    func finish() throws {
        switch state {
        case .empty:
            abandon()
            throw GIFStreamError.noFrames
        case .closed:
            throw GIFStreamError.closed
        case .streaming(let progress):
            let end = GIFTime(seconds: progress.lastSeen + frameDuration)
            do {
                try progress.file.append(progress.pending.frame, at: progress.pending.origin, delay: progress.pending.time.delay(until: end))
                try progress.file.close()
                state = .closed
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: scratch, to: url)
            } catch {
                abandon()
                throw error
            }
        }
    }

    /// Stops and deletes the scratch file. `url` is left as it was.
    func abandon() {
        if case .streaming(let progress) = state { progress.file.abandon() }
        state = .closed
        try? FileManager.default.removeItem(at: scratch)
    }
}
