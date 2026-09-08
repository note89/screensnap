@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

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

/// The encoder for an `Output`, plus the audio channel when the output records one.
struct EncoderSetup {
    let encoder: FrameEncoder
    let audioChannel: AudioWriterChannel?

    @MainActor
    static func make(output: Output, url: URL, framerate: Int, pixelSize: CGSize, audio: AudioTrack) throws -> EncoderSetup {
        switch output {
        case .gif(.fast):
            return EncoderSetup(encoder: try ImageIOGifEncoder(outputURL: url, framerate: framerate), audioChannel: nil)
        case .gif(.best):
            return EncoderSetup(encoder: try GifskiEncoder(outputURL: url, framerate: framerate, quality: GifskiEncoder.defaultQuality), audioChannel: nil)
        case .mp4:
            let encoder = try MP4Encoder(outputURL: url, framerate: framerate, pixelSize: pixelSize, audio: audio)
            return EncoderSetup(encoder: encoder, audioChannel: encoder.audioChannel)
        }
    }
}

enum GIFFrameProperties {
    static let loopForever = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary

    static func delay(_ seconds: CFTimeInterval) -> CFDictionary {
        [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: seconds,
            kCGImagePropertyGIFUnclampedDelayTime: seconds,
        ]] as CFDictionary
    }
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
            throw NSError(domain: "Screensnap", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open GIF destination"])
        }
        CGImageDestinationSetProperties(dest, GIFFrameProperties.loopForever)
        self.state = .active(dest)
    }

    func append(_ frame: CapturedFrame) throws {
        guard case .active(let destination) = state else { return }

        let delay = frameCount == 0 ? 1.0 / Double(framerate) : max(0.02, frame.timestamp - lastFrameTime)
        lastFrameTime = frame.timestamp
        frameCount += 1
        CGImageDestinationAddImage(destination, frame.image, GIFFrameProperties.delay(delay))
    }

    func finish() async throws -> URL {
        guard case .active(let destination) = state else {
            throw NSError(domain: "Screensnap", code: 2, userInfo: [NSLocalizedDescriptionKey: "GIF destination already finalized"])
        }
        state = .finished
        if !CGImageDestinationFinalize(destination) {
            throw NSError(domain: "Screensnap", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write GIF"])
        }
        return outputURL
    }

    func cancel() {
        state = .cancelled
        try? FileManager.default.removeItem(at: outputURL)
    }
}

// MARK: - gifski (high-quality)

/// Streams frames as PNGs into a temp directory, then runs `gifski` over them on
/// `finish()`. If gifski fails the same PNGs are assembled with ImageIO instead —
/// a captured recording is never lost to an encoder problem.
@MainActor
final class GifskiEncoder: FrameEncoder {
    static let defaultQuality = 80

    private let outputURL: URL
    private let framerate: Int
    private let quality: Int
    private let gifskiURL: URL
    private let tempDir: URL
    private var frameTimestamps: [CFTimeInterval] = []
    private let encodeQueue = DispatchQueue(label: "Screensnap.gifskiEncode", qos: .userInitiated)
    private var isCancelled = false

    init(outputURL: URL, framerate: Int, quality: Int) throws {
        guard let gifskiURL = Self.locateGifski() else {
            throw NSError(domain: "Screensnap", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "gifski is not installed. `brew install gifski`, or pick GIF (fast)."
            ])
        }
        self.gifskiURL = gifskiURL
        self.outputURL = outputURL
        self.framerate = framerate
        self.quality = quality
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("screensnap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func append(_ frame: CapturedFrame) throws {
        guard !isCancelled else { return }
        let index = frameTimestamps.count
        frameTimestamps.append(frame.timestamp)
        let image = frame.image
        let destURL = tempDir.appendingPathComponent(String(format: "frame-%06d.png", index))
        encodeQueue.async {
            guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            _ = CGImageDestinationFinalize(dest)
        }
    }

    func finish() async throws -> URL {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            encodeQueue.async { continuation.resume() }
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }
        guard !isCancelled else { throw CancellationError() }

        let frameFiles = (try FileManager.default.contentsOfDirectory(atPath: tempDir.path))
            .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".png") }
            .sorted()
            .map { tempDir.appendingPathComponent($0) }

        do {
            try await runGifski(frames: frameFiles)
        } catch {
            FileHandle.standardError.write(Data("[Screensnap] gifski failed, assembling with ImageIO: \(error.localizedDescription)\n".utf8))
            try Self.assembleWithImageIO(frames: frameFiles, timestamps: frameTimestamps, framerate: framerate, outputURL: outputURL)
        }
        return outputURL
    }

    private func runGifski(frames: [URL]) async throws {
        let process = Process()
        process.executableURL = gifskiURL
        process.arguments = ["--fps", String(framerate), "--quality", String(quality), "-o", outputURL.path] + frames.map(\.path)
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = stderr.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8) ?? "unknown error"
                    continuation.resume(throwing: NSError(domain: "Screensnap", code: 7, userInfo: [
                        NSLocalizedDescriptionKey: "gifski exited with status \(p.terminationStatus): \(msg)"
                    ]))
                }
            }
        }
    }

    private static func assembleWithImageIO(frames: [URL], timestamps: [CFTimeInterval], framerate: Int, outputURL: URL) throws {
        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.gif.identifier as CFString, 0, nil) else {
            throw NSError(domain: "Screensnap", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open GIF destination"])
        }
        CGImageDestinationSetProperties(destination, GIFFrameProperties.loopForever)
        for (index, file) in frames.enumerated() {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let delay = index == 0 || index >= timestamps.count
                ? 1.0 / Double(framerate)
                : max(0.02, timestamps[index] - timestamps[index - 1])
            CGImageDestinationAddImage(destination, image, GIFFrameProperties.delay(delay))
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Screensnap", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write GIF"])
        }
    }

    func cancel() {
        isCancelled = true
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: outputURL)
    }

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

/// Audio side of the MP4 writer. A separate, lock-guarded object because mic
/// sample buffers arrive on the capture queue while the encoder itself is
/// MainActor-bound. `AVAssetWriter` supports concurrent appends to different
/// inputs; the lock only serializes appends against lifecycle transitions
/// (activation and finish), since appending to a finished input traps.
final class AudioWriterChannel: @unchecked Sendable {
    private struct State {
        /// Host-clock time of the writer timeline's zero (the first video frame).
        /// nil until video starts — audio arriving before that is dropped.
        var hostZero: CFTimeInterval?
        var isAccepting = true
    }

    private let input: AVAssetWriterInput
    private let state: OSAllocatedUnfairLock<State>

    init(input: AVAssetWriterInput) {
        self.input = input
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// Called once the writer session has started; anchors the audio timeline.
    func activate(hostZero: CFTimeInterval) {
        state.withLock { $0.hostZero = $0.hostZero ?? hostZero }
    }

    /// Rebases the buffer's host-clock PTS onto the writer timeline and appends.
    func append(_ buffer: CMSampleBuffer) {
        state.withLockUnchecked { s in
            guard s.isAccepting, let hostZero = s.hostZero, input.isReadyForMoreMediaData else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            let shifted = CMTimeSubtract(pts, CMTime(seconds: hostZero, preferredTimescale: pts.timescale))
            guard shifted >= .zero else { return } // audio from before the first video frame
            guard let retimed = Self.retimed(buffer, to: shifted) else { return }
            input.append(retimed)
        }
    }

    /// Stop accepting buffers without touching the input (for cancelWriting,
    /// where marking the input finished is invalid).
    func stopAccepting() {
        state.withLock { $0.isAccepting = false }
    }

    func markFinished() {
        state.withLock { s in
            s.isAccepting = false
            input.markAsFinished()
        }
    }

    private static func retimed(_ buffer: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        )
        return out
    }
}

@MainActor
final class MP4Encoder: FrameEncoder {
    private let outputURL: URL
    private let framerate: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var startTime: CFTimeInterval?
    /// Present iff the encoder was created with `audio: .microphone`.
    let audioChannel: AudioWriterChannel?

    init(outputURL: URL, framerate: Int, pixelSize: CGSize, audio: AudioTrack) throws {
        self.outputURL = outputURL
        self.framerate = framerate
        try? FileManager.default.removeItem(at: outputURL)
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_000_000, Int(pixelSize.width * pixelSize.height) * 4),
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
            throw NSError(domain: "Screensnap", code: 8, userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter cannot add input"])
        }
        writer.add(input)

        switch audio {
        case .microphone:
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioInput) else {
                throw NSError(domain: "Screensnap", code: 9, userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter cannot add audio input"])
            }
            writer.add(audioInput)
            self.audioChannel = AudioWriterChannel(input: audioInput)
        case .none:
            self.audioChannel = nil
        }
    }

    func append(_ frame: CapturedFrame) throws {
        if startTime == nil {
            startTime = frame.timestamp
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            audioChannel?.activate(hostZero: frame.hostTime)
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
        audioChannel?.markFinished()
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
        audioChannel?.stopAccepting()
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
