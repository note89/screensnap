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
    case destinationNotWritable(URL)
    case cannotCreateFile(URL)
    case notMoved(savedAt: URL, reason: String)
    case noFrames
    case closed

    var errorDescription: String? {
        switch self {
        case .quantizationFailed: return "Could not convert a frame to GIF."
        case .unexpectedFormat(let detail): return "ImageIO produced an unexpected GIF (\(detail))."
        case .canvasTooLarge(let size): return "\(size.label) is too large for a GIF."
        case .destinationNotWritable(let folder): return "Screensnap cannot write to \(folder.path)."
        case .cannotCreateFile(let url): return "Could not create \(url.lastPathComponent)."
        case .notMoved(let savedAt, let reason): return "The GIF was saved to \(savedAt.path) but could not be moved into place: \(reason)"
        case .noFrames: return "No frames were captured."
        case .closed: return "The GIF is already closed."
        }
    }
}

// MARK: - Stream

/// Builds an animated GIF on disk from timestamped frames as they arrive. Each frame is
/// compared with the picture the animation currently ends on, and only the rectangle
/// that changed is quantized and appended. Memory holds about one frame however long
/// the recording runs, and a still screen costs a comparison per frame.
///
/// Frames go to a scratch file on the same volume as `url` and move there on
/// `finish(at:)`, so the recordings folder never shows a partial GIF and abandoning
/// never touches a file already there.
///
/// Not thread-safe: call it from one thread or serial queue at a time.
final class GIFFrameStream {
    private let url: URL
    private let scratchFolder: URL
    private var state: State = .empty

    private enum State {
        case empty
        case streaming(Progress)
        /// Ended by an error; the scratch folder is already gone.
        case failed(Error)
        /// Finished or abandoned; nothing is left to clean up.
        case closed
    }

    /// A frame is written only once the next change arrives, because its GIF delay
    /// (how long it stays up) is not known before then.
    private struct Pending {
        let frame: EncodedGIFFrame
        let origin: PixelPoint
        let time: GIFTime
        /// The whole picture once this frame is drawn; nil when its pixels cannot be
        /// read, and the next frame is then written whole.
        let picture: FramePixels?

        /// Writes the frame so it stays up until `end`, left in place afterwards.
        func write(to file: GIFFileWriter, lastingUntil end: GIFTime) throws {
            try file.append(frame, at: origin, disposal: .leaveInPlace, delay: time.delay(until: end))
        }
    }

    private struct Progress {
        let file: GIFFileWriter
        var pending: Pending
    }

    /// Fails right away when the folder of `url` is not writable, rather than after a recording.
    init(url: URL) throws {
        let folder = url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw GIFStreamError.destinationNotWritable(folder)
        }
        self.url = url
        self.scratchFolder = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true
        )
    }

    deinit {
        abandon()
    }

    private var scratch: URL { scratchFolder.appendingPathComponent(url.lastPathComponent) }

    /// `timestamp` is seconds since the recording started. The frame stays up until the
    /// next frame that differs from it, or until the end given to `finish(at:)`.
    /// After a throw the stream is failed and has deleted what it wrote.
    func add(_ image: CGImage, at timestamp: CFTimeInterval) throws {
        do {
            try append(image, at: GIFTime(seconds: timestamp))
        } catch {
            fail(error)
            throw error
        }
    }

    /// Writes the last frame so it stays up until `end`, on the same clock as `add`, and
    /// moves the GIF to `url`, replacing any file there. When that move fails the GIF is
    /// kept in the scratch folder and the error says where.
    func finish(at end: CFTimeInterval) throws {
        switch state {
        case .failed(let error):
            throw error
        case .closed:
            throw GIFStreamError.closed
        case .empty:
            abandon()
            throw GIFStreamError.noFrames
        case .streaming(let progress):
            do {
                try progress.pending.write(to: progress.file, lastingUntil: GIFTime(seconds: end))
                try progress.file.writeTrailerAndClose()
            } catch {
                fail(error)
                throw error
            }
            state = .closed
            do {
                try moveIntoPlace()
            } catch {
                throw GIFStreamError.notMoved(savedAt: scratch, reason: error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: scratchFolder)
        }
    }

    /// Stops and deletes what was written. `url` is left as it was.
    func abandon() {
        switch state {
        case .empty, .streaming:
            closeAndDeleteScratch()
            state = .closed
        case .failed, .closed:
            return
        }
    }

    private func append(_ image: CGImage, at time: GIFTime) throws {
        switch state {
        case .failed(let error):
            throw error
        case .closed:
            throw GIFStreamError.closed

        case .empty:
            let first = try EncodedGIFFrame(quantizing: image)
            let file = try GIFFileWriter(creating: scratch, canvas: image.pixelBounds.size)
            state = .streaming(Progress(
                file: file,
                pending: Pending(frame: first, origin: .zero, time: time, picture: FramePixels(image))
            ))

        case .streaming(var progress):
            let picture = FramePixels(image)
            let change: FrameChange
            if let shown = progress.pending.picture, let picture {
                change = picture.change(since: shown)
            } else {
                change = .region(image.pixelBounds)
            }
            guard case .region(let rect) = change else { return }
            guard let changed = image.cropping(to: rect.cgRect) else { throw GIFStreamError.quantizationFailed }
            let frame = try EncodedGIFFrame(quantizing: changed)

            switch picture?.opacity(in: rect) ?? .translucent {
            case .opaque:
                try progress.pending.write(to: progress.file, lastingUntil: time)
            case .translucent:
                // A frame can only paint over what is shown, so a pixel that turns
                // transparent would keep the old picture. A transparent frame over
                // `rect`, restored to background after the pending frame's last 2 cs,
                // clears the area first.
                let clearing = time.earlier(by: GIFTime.shortestDelay)
                try progress.pending.write(to: progress.file, lastingUntil: clearing)
                try progress.file.append(
                    try EncodedGIFFrame.transparent(rect.size), at: rect.origin,
                    disposal: .restoreBackground, delay: GIFTime.shortestDelay
                )
            }
            progress.pending = Pending(frame: frame, origin: rect.origin, time: time, picture: picture)
            state = .streaming(progress)
        }
    }

    private func moveIntoPlace() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
        } else {
            try FileManager.default.moveItem(at: scratch, to: url)
        }
    }

    private func fail(_ error: Error) {
        switch state {
        case .empty, .streaming:
            closeAndDeleteScratch()
            state = .failed(error)
        case .failed, .closed:
            return
        }
    }

    private func closeAndDeleteScratch() {
        if case .streaming(let progress) = state { progress.file.closeUnfinished() }
        try? FileManager.default.removeItem(at: scratchFolder)
    }
}

// MARK: - Timeline

/// A moment on the GIF timeline in hundredths of a second, the unit GIF delays use.
/// Delays are gaps between rounded absolute times, so rounding does not add up; only
/// gaps shorter than `shortestDelay` (above 50 fps) are stretched.
private struct GIFTime {
    /// Browsers slow any delay under 2 cs down to 10 cs.
    static let shortestDelay = 2

    let centiseconds: Int

    init(seconds: CFTimeInterval) {
        centiseconds = Int((seconds * 100).rounded())
    }

    private init(centiseconds: Int) {
        self.centiseconds = centiseconds
    }

    func earlier(by delay: Int) -> GIFTime {
        GIFTime(centiseconds: centiseconds - delay)
    }

    /// How long a frame shown at `self` stays up before `later`, in centiseconds.
    func delay(until later: GIFTime) -> Int {
        max(Self.shortestDelay, later.centiseconds - centiseconds)
    }
}

// MARK: - Codec

/// Byte values from the GIF89a specification, shared by the reader and the writer.
private enum GIFByte {
    static let extensionIntroducer: UInt8 = 0x21
    static let graphicControlLabel: UInt8 = 0xF9
    static let applicationLabel: UInt8 = 0xFF
    static let imageSeparator: UInt8 = 0x2C
    static let trailer: UInt8 = 0x3B
    /// Flags of the screen and image descriptors.
    static let hasColorTable: UInt8 = 0x80
    static let interlaced: UInt8 = 0x40
    static let colorTableSizeMask: UInt8 = 0x07
    /// Flag of the graphic control extension.
    static let hasTransparency: UInt8 = 0x01
}

private struct GIFColorTable {
    /// The table holds `2 << sizeCode` colours; the code is what GIF stores in its flags.
    let sizeCode: UInt8
    let rgb: Data
}

private enum GIFRowOrder {
    case sequential
    case interlaced
}

/// What happens to a frame's rectangle once its delay is over.
private enum GIFDisposal {
    /// It stays; the next frame paints over it.
    case leaveInPlace
    /// It is cleared to transparent.
    case restoreBackground

    var code: UInt8 {
        switch self {
        case .leaveInPlace: return 1
        case .restoreBackground: return 2
        }
    }
}

/// One frame as ImageIO quantized it: its own palette and its LZW-compressed pixels,
/// lifted out of a single-frame GIF so it can be placed anywhere in a longer animation.
private struct EncodedGIFFrame {
    /// Where ImageIO put the image inside its own canvas.
    let bounds: PixelRect
    let palette: GIFColorTable
    let rowOrder: GIFRowOrder
    let transparentIndex: UInt8?
    /// LZW minimum code size, the data sub-blocks and their terminator, verbatim.
    let imageData: Data

    /// One transparent pixel, which continues a delay too long for a single frame.
    static let transparentPixel = EncodedGIFFrame(
        bounds: PixelRect(origin: .zero, size: Dimensions(width: 1, height: 1)),
        palette: GIFColorTable(sizeCode: 0, rgb: Data(count: 6)),
        rowOrder: .sequential,
        transparentIndex: 0,
        imageData: Data([0x02, 0x02, 0x44, 0x01, 0x00]) // minimum code size 2; codes clear, 0, end
    )
}

extension EncodedGIFFrame {
    init(quantizing image: CGImage) throws {
        let gif = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(gif, UTType.gif.identifier as CFString, 1, nil) else {
            throw GIFStreamError.quantizationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GIFStreamError.quantizationFailed }
        try self.init(parsing: gif as Data)
    }

    /// A fully transparent frame of `size`.
    static func transparent(_ size: Dimensions) throws -> EncodedGIFFrame {
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
        ) else { throw GIFStreamError.quantizationFailed }
        context.clear(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let image = context.makeImage() else { throw GIFStreamError.quantizationFailed }
        let frame = try EncodedGIFFrame(quantizing: image)
        guard frame.transparentIndex != nil else {
            throw GIFStreamError.unexpectedFormat("a transparent image without a transparent colour")
        }
        return frame
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
        var palette = screenFlags & GIFByte.hasColorTable != 0
            ? try reader.colorTable(sizeCode: screenFlags & GIFByte.colorTableSizeMask)
            : nil
        var transparentIndex: UInt8?

        while true {
            switch try reader.byte() {
            case GIFByte.extensionIntroducer:
                let label = try reader.byte()
                let body = try reader.subBlockPayload()
                if label == GIFByte.graphicControlLabel, body.count >= 4,
                   body[body.startIndex] & GIFByte.hasTransparency != 0 {
                    transparentIndex = body[body.startIndex + 3]
                }
            case GIFByte.imageSeparator:
                let x = try reader.uint16(), y = try reader.uint16()
                let width = try reader.uint16(), height = try reader.uint16()
                let imageFlags = try reader.byte()
                if imageFlags & GIFByte.hasColorTable != 0 {
                    palette = try reader.colorTable(sizeCode: imageFlags & GIFByte.colorTableSizeMask)
                }
                guard let palette else { throw GIFStreamError.unexpectedFormat("image without a palette") }
                let dataStart = reader.position
                _ = try reader.byte() // LZW minimum code size
                try reader.skipSubBlocks()
                self.init(
                    bounds: PixelRect(origin: PixelPoint(x: x, y: y), size: Dimensions(width: width, height: height)),
                    palette: palette,
                    rowOrder: imageFlags & GIFByte.interlaced != 0 ? .interlaced : .sequential,
                    transparentIndex: transparentIndex,
                    imageData: gif[dataStart..<reader.position]
                )
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

    /// Same as `subBlockPayload`, without copying megabytes of image data.
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
private final class GIFFileWriter {
    /// A GIF delay is 16 bits of centiseconds: at most 655.35 s per frame.
    private static let longestDelay = Int(UInt16.max)

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
        header.append(contentsOf: [GIFByte.extensionIntroducer, GIFByte.applicationLabel, 0x0B])
        header.append(contentsOf: Data("NETSCAPE2.0".utf8))
        header.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00]) // loop forever
        try handle.write(contentsOf: header)
    }

    /// Draws `frame` with its top-left corner at `origin` for `delay` centiseconds. A
    /// delay longer than one GIF frame can hold continues on transparent 1×1 frames.
    func append(_ frame: EncodedGIFFrame, at origin: PixelPoint, disposal: GIFDisposal, delay: Int) throws {
        var block = Data(capacity: frame.imageData.count + frame.palette.rgb.count + 32)
        var remaining = delay
        var next = (frame: frame, origin: origin, disposal: disposal)
        repeat {
            // Never leave a remainder shorter than browsers honour.
            let chunk = remaining <= Self.longestDelay ? remaining : min(Self.longestDelay, remaining - GIFTime.shortestDelay)
            block.appendFrame(next.frame, at: next.origin, disposal: next.disposal, delay: UInt16(chunk))
            remaining -= chunk
            next = (EncodedGIFFrame.transparentPixel, .zero, .leaveInPlace)
        } while remaining > 0
        try handle.write(contentsOf: block)
    }

    func writeTrailerAndClose() throws {
        try handle.write(contentsOf: Data([GIFByte.trailer]))
        try handle.close()
    }

    /// Closes the file as it is, without a trailer.
    func closeUnfinished() {
        try? handle.close()
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    /// A graphic control extension followed by the image, with the frame's own palette.
    mutating func appendFrame(_ frame: EncodedGIFFrame, at origin: PixelPoint, disposal: GIFDisposal, delay: UInt16) {
        let transparency = frame.transparentIndex == nil ? 0 : GIFByte.hasTransparency
        append(contentsOf: [GIFByte.extensionIntroducer, GIFByte.graphicControlLabel, 0x04, disposal.code << 2 | transparency])
        appendLittleEndian(delay)
        append(contentsOf: [frame.transparentIndex ?? 0, 0x00])

        let rowOrder: UInt8
        switch frame.rowOrder {
        case .sequential: rowOrder = 0
        case .interlaced: rowOrder = GIFByte.interlaced
        }
        append(GIFByte.imageSeparator)
        appendLittleEndian(UInt16(clamping: origin.x + frame.bounds.origin.x))
        appendLittleEndian(UInt16(clamping: origin.y + frame.bounds.origin.y))
        appendLittleEndian(UInt16(clamping: frame.bounds.size.width))
        appendLittleEndian(UInt16(clamping: frame.bounds.size.height))
        append(GIFByte.hasColorTable | rowOrder | frame.palette.sizeCode)
        append(frame.palette.rgb)
        append(frame.imageData)
    }
}
