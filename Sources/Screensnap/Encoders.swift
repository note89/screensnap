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
            return EncoderSetup(encoder: ImageIOGifEncoder(outputURL: url, framerate: framerate), audioChannel: nil)
        case .gif(.best):
            return EncoderSetup(encoder: try GifskiEncoder(outputURL: url, framerate: framerate, quality: GifskiEncoder.defaultQuality), audioChannel: nil)
        case .mp4:
            let encoder = try MP4Encoder(outputURL: url, framerate: framerate, pixelSize: pixelSize, audio: audio)
            return EncoderSetup(encoder: encoder, audioChannel: encoder.audioChannel)
        }
    }
}

// MARK: - ImageIO GIF

/// Streams frames into a `GIFFrameStream` on a background queue. When encoding falls
/// behind capture, new frames are dropped rather than queued, so memory stays bounded;
/// the frame before a gap simply stays up longer.
@MainActor
final class ImageIOGifEncoder: FrameEncoder {
    private enum Admission {
        case queued
        case dropped
    }

    /// Frames handed to the encode queue and not yet encoded, and the first encode error.
    private struct Intake {
        /// A full-screen Retina frame is ~24 MB and takes ~70 ms to quantize, so a short
        /// queue only absorbs jitter.
        static let maxBacklog = 3

        var backlog = 0
        var failure: Error?

        mutating func admit() throws -> Admission {
            if let failure { throw failure }
            guard backlog < Self.maxBacklog else { return .dropped }
            backlog += 1
            return .queued
        }
    }

    private enum EncoderState {
        case active
        case finished
        case cancelled
    }

    private let outputURL: URL
    /// Touched only on `encodeQueue`.
    private let stream: GIFFrameStream
    private let encodeQueue = DispatchQueue(label: "Screensnap.gifEncode", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let intake = OSAllocatedUnfairLock(initialState: Intake())
    private var state: EncoderState = .active

    init(outputURL: URL, framerate: Int) {
        self.outputURL = outputURL
        self.stream = GIFFrameStream(url: outputURL, framerate: framerate)
    }

    /// Throws the error of an earlier frame that failed to encode, so the recording
    /// stops instead of capturing into a broken file.
    func append(_ frame: CapturedFrame) throws {
        guard case .active = state else { return }
        switch try intake.withLock({ try $0.admit() }) {
        case .dropped: return
        case .queued: break
        }
        encodeQueue.async { [stream, intake] in
            do {
                try stream.add(frame.image, at: frame.timestamp)
                intake.withLock { $0.backlog -= 1 }
            } catch {
                intake.withLock { $0.failure = $0.failure ?? error }
            }
        }
    }

    func finish() async throws -> URL {
        guard case .active = state else {
            throw NSError(domain: "Screensnap", code: 2, userInfo: [NSLocalizedDescriptionKey: "GIF destination already finalized"])
        }
        state = .finished
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            encodeQueue.async { [stream, intake] in
                if let failure = intake.withLock({ $0.failure }) {
                    stream.abandon()
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume(with: Result { try stream.finish() })
                }
            }
        }
        return outputURL
    }

    func cancel() {
        state = .cancelled
        encodeQueue.async { [stream] in stream.abandon() }
    }
}

// MARK: - gifski (high-quality)

/// Streams frames as PNGs into a temp directory, then runs `gifski` over them on
/// `finish()`. If gifski fails the same PNGs are streamed through `GIFFrameStream`
/// instead — a captured recording is never lost to an encoder problem.
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

    private struct SavedFrame {
        let file: URL
        let timestamp: CFTimeInterval
    }

    private func frameFile(_ index: Int) -> URL {
        tempDir.appendingPathComponent(String(format: "frame-%06d.png", index))
    }

    func append(_ frame: CapturedFrame) throws {
        guard !isCancelled else { return }
        let index = frameTimestamps.count
        frameTimestamps.append(frame.timestamp)
        let image = frame.image
        let destURL = frameFile(index)
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

        // A frame whose PNG failed to write is skipped; its neighbours keep their own timestamps.
        let frames = frameTimestamps.enumerated()
            .map { SavedFrame(file: frameFile($0.offset), timestamp: $0.element) }
            .filter { FileManager.default.fileExists(atPath: $0.file.path) }

        do {
            try await runGifski(frames: frames.map(\.file))
        } catch {
            FileHandle.standardError.write(Data("[Screensnap] gifski failed, assembling with ImageIO: \(error.localizedDescription)\n".utf8))
            let framerate = self.framerate, outputURL = self.outputURL
            try await Task.detached(priority: .userInitiated) {
                try Self.assembleWithImageIO(frames, framerate: framerate, outputURL: outputURL)
            }.value
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

    private nonisolated static func assembleWithImageIO(_ frames: [SavedFrame], framerate: Int, outputURL: URL) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let stream = GIFFrameStream(url: outputURL, framerate: framerate)
        let decodeOnDemand = [kCGImageSourceShouldCache: false] as CFDictionary
        do {
            for frame in frames {
                try autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(frame.file as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOnDemand) else { return }
                    try stream.add(image, at: frame.timestamp)
                }
            }
            try stream.finish()
        } catch {
            stream.abandon()
            throw error
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
