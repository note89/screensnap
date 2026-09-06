@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shared error for "the recording ended before any frame was captured". Easy to
/// hit now that a countdown precedes every recording, and each encoder fails in its
/// own unhelpful way otherwise — the MP4 writer worst of all, since finishing a
/// writer that was never started raises an Obj-C exception and kills the process.
enum EncoderError: LocalizedError {
    case noFrames

    var errorDescription: String? {
        switch self {
        case .noFrames:
            return "Nothing was captured — the recording stopped before the first frame arrived."
        }
    }
}

/// A streaming frame encoder. Frames arrive one at a time and the encoder
/// is finalized at the end. Encoders own their own scratch state.
@MainActor
protocol FrameEncoder: AnyObject {
    func append(_ frame: CapturedFrame) throws
    /// Returns the final URL (which may differ from a temp URL passed in earlier,
    /// e.g. for the gifski path).
    func finish() async throws -> URL
    func cancel()
}

// MARK: - ImageIO GIF

@MainActor
final class ImageIOGifEncoder: FrameEncoder {
    private let outputURL: URL
    private let framerate: Int
    private enum EncoderState {
        case active(CGImageDestination)
        case finished
        case cancelled
    }
    private var state: EncoderState
    private var lastFrameTime: CFTimeInterval = 0
    private var frameCount = 0

    init(outputURL: URL, framerate: Int) throws {
        self.outputURL = outputURL
        self.framerate = framerate
        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            0, // we'll set the count by appending
            nil
        ) else {
            throw NSError(domain: "GifRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open GIF destination"])
        }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        self.state = .active(dest)
    }

    func append(_ frame: CapturedFrame) throws {
        guard case .active(let destination) = state else { return }

        // Per-frame delay: time since previous frame, falling back to 1/framerate.
        let delay: CFTimeInterval
        if frameCount == 0 {
            delay = 1.0 / Double(framerate)
        } else {
            delay = max(0.02, frame.timestamp - lastFrameTime)
        }
        lastFrameTime = frame.timestamp
        frameCount += 1

        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]
        ]
        CGImageDestinationAddImage(destination, frame.image, frameProps as CFDictionary)
    }

    func finish() async throws -> URL {
        guard case .active(let destination) = state else {
            throw NSError(domain: "GifRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "GIF destination already finalized"])
        }
        guard frameCount > 0 else {
            state = .cancelled
            try? FileManager.default.removeItem(at: outputURL)
            throw EncoderError.noFrames
        }
        state = .finished
        if !CGImageDestinationFinalize(destination) {
            throw NSError(domain: "GifRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write GIF"])
        }
        return outputURL
    }

    func cancel() {
        state = .cancelled
        try? FileManager.default.removeItem(at: outputURL)
    }
}

// MARK: - gifski (high-quality)

/// Streams frames as PNGs into a temp directory, then invokes the bundled
/// `gifski` binary on `finish()`.
@MainActor
final class GifskiEncoder: FrameEncoder {
    private let outputURL: URL
    private let framerate: Int
    private let quality: Int
    private let tempDir: URL
    private var frameIndex = 0
    private let encodeQueue = DispatchQueue(label: "GifRecorder.gifskiEncode", qos: .userInitiated)
    private var isCancelled = false

    init(outputURL: URL, framerate: Int, quality: Int) throws {
        self.outputURL = outputURL
        self.framerate = framerate
        self.quality = quality
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func append(_ frame: CapturedFrame) throws {
        guard !isCancelled else { return }
        let index = frameIndex
        frameIndex += 1
        let image = frame.image
        let destURL = tempDir.appendingPathComponent(String(format: "frame-%06d.png", index))
        encodeQueue.async {
            guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            _ = CGImageDestinationFinalize(dest)
        }
    }

    func finish() async throws -> URL {
        // First, wait for all enqueued PNG writes to complete.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            encodeQueue.async { continuation.resume() }
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }
        guard !isCancelled else { throw CancellationError() }

        guard let gifskiURL = Self.locateGifski() else {
            throw NSError(domain: "GifRecorder", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Could not find the gifski binary. Bundle it under Resources/ or install via `brew install gifski`."
            ])
        }

        // ── User contribution point #3 ──────────────────────────────────────
        // gifski has a few flags that materially shape the output. The
        // current invocation below is a sane default but you may want to
        // tune it for your typical recording (UI screencasts vs. video).
        //
        //   --quality N      [1-100, default 90] global quality knob.
        //   --fps N          target framerate.
        //   --motion-quality lower it to spend bits on color instead of motion.
        //   --lossy-quality  lossy palette compression; massive size savings.
        //   --width / --height  resize. Useful if you want gifski to do the
        //                       downsample step instead of doing it in Swift.
        //   -o <out>         output path.
        //
        // The argument list lives in `arguments` below — adjust as you like.
        // ────────────────────────────────────────────────────────────────────

        // Every frame is its own argument, and the kernel caps the whole argv at
        // ARG_MAX (1 MiB on macOS). Passing full temp-directory paths blew that at
        // roughly 9,000 frames — ten minutes at 15 fps — and the whole recording
        // died with a cryptic E2BIG. Running gifski *inside* the frame directory
        // and passing bare filenames stretches the ceiling several-fold; past
        // that, fail before launch with an explanation rather than after.
        let frameFiles = (try FileManager.default.contentsOfDirectory(atPath: tempDir.path))
            .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".png") }
            .sorted()

        guard !frameFiles.isEmpty else { throw EncoderError.noFrames }

        var arguments = [
            "--fps", String(framerate),
            "--quality", String(quality),
            "-o", outputURL.path,
        ]
        arguments.append(contentsOf: frameFiles)

        // Bytes for each string plus its NUL, plus the pointer table; leave room
        // for the environment, which counts against the same limit.
        let argvBytes = arguments.reduce(0) { $0 + $1.utf8.count + 1 + MemoryLayout<UnsafePointer<CChar>>.size }
        guard argvBytes < Self.maxArgvBytes else {
            throw NSError(domain: "GifRecorder", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "This recording has too many frames (\(frameFiles.count)) for gifski to take in one go. Record for less time, lower the framerate, or switch off gifski for long recordings.",
            ])
        }

        let process = Process()
        process.executableURL = gifskiURL
        process.currentDirectoryURL = tempDir
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()

        let outputURL = self.outputURL
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume(returning: outputURL)
                } else {
                    let data = stderr.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8) ?? "unknown error"
                    continuation.resume(throwing: NSError(domain: "GifRecorder", code: 7, userInfo: [
                        NSLocalizedDescriptionKey: "gifski exited with status \(p.terminationStatus): \(msg)"
                    ]))
                }
            }
        }
    }

    func cancel() {
        isCancelled = true
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// Conservative share of macOS's 1 MiB ARG_MAX, leaving headroom for the
    /// environment block.
    private static let maxArgvBytes = 900 * 1024

    /// Look for gifski in (1) the app bundle Resources dir, (2) common Homebrew paths.
    static func locateGifski() -> URL? {
        if let bundled = Bundle.main.url(forResource: "gifski", withExtension: nil) {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/bin/gifski",
            "/usr/local/bin/gifski",
            "/usr/bin/gifski",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

// MARK: - MP4 (H.264 via AVAssetWriter)

@MainActor
final class MP4Encoder: FrameEncoder {
    private let outputURL: URL
    private let framerate: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var startTime: CFTimeInterval?

    init(outputURL: URL, framerate: Int, pixelSize: CGSize) throws {
        self.outputURL = outputURL
        self.framerate = framerate
        try? FileManager.default.removeItem(at: outputURL)
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                // Bits per *second* have to scale with frames per second; the old
                // formula ignored the framerate entirely, so 5 fps and 60 fps got
                // the same budget — and a 5K display got ~59 Mbps at any rate.
                // 0.12 bits per pixel per frame is generous for screen content.
                AVVideoAverageBitRateKey: max(1_000_000, Int(pixelSize.width * pixelSize.height * CGFloat(framerate) * 0.12)),
                AVVideoMaxKeyFrameIntervalKey: framerate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        self.input = input

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(pixelSize.width),
            kCVPixelBufferHeightKey as String: Int(pixelSize.height),
        ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)

        guard writer.canAdd(input) else {
            throw NSError(domain: "GifRecorder", code: 8, userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter cannot add input"])
        }
        writer.add(input)
    }

    func append(_ frame: CapturedFrame) throws {
        if startTime == nil {
            startTime = frame.timestamp
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
        }
        let elapsed = frame.timestamp - (startTime ?? frame.timestamp)
        let pts = CMTime(seconds: elapsed, preferredTimescale: 600)

        guard input.isReadyForMoreMediaData else { return } // drop if not ready
        guard let pool = adaptor.pixelBufferPool, let pixelBuffer = makePixelBuffer(from: frame.image, pool: pool) else {
            return
        }
        adaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    func finish() async throws -> URL {
        // `startWriting` only runs on the first appended frame. Finishing a writer
        // still in `.unknown` raises `NSInternalInconsistencyException`, which is an
        // Obj-C exception rather than a Swift error — it takes the process down.
        guard startTime != nil else {
            try? FileManager.default.removeItem(at: outputURL)
            throw EncoderError.noFrames
        }
        input.markAsFinished()
        let writer = self.writer
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .failed, let err = writer.error {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume()
                }
            }
        }
        return outputURL
    }

    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func makePixelBuffer(from image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pixelBuffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(
            data: base,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixelBuffer
    }
}
