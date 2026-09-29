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
    func finish() async throws -> FinishedEncoding
    func cancel()
}

/// The file on disk, and the quality step it lost on the way when the encoder had
/// to fall back to a simpler one.
struct FinishedEncoding {
    let url: URL
    let degradation: Degradation?
}

/// The encoder for an `Output`, plus the audio channel when the output records one.
struct EncoderSetup {
    let encoder: FrameEncoder
    let audioChannel: AudioWriterChannel?

    @MainActor
    static func make(output: Output, url: URL, framerate: Int, pixelSize: CGSize, audio: AudioTrack) throws -> EncoderSetup {
        switch output {
        case .gif(.fast):
            return EncoderSetup(encoder: try ImageIOGifEncoder(outputURL: url), audioChannel: nil)
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

    /// How many frames wait on the encode queue, or the error that ended encoding.
    private enum Intake {
        /// A full-screen Retina frame is ~24 MB and takes ~70 ms to quantize, so a short
        /// queue only absorbs jitter.
        static let maxBacklog = 3

        case accepting(backlog: Int)
        case failed(Error)

        mutating func admit() throws -> Admission {
            switch self {
            case .failed(let error):
                throw error
            case .accepting(let backlog):
                guard backlog < Self.maxBacklog else { return .dropped }
                self = .accepting(backlog: backlog + 1)
                return .queued
            }
        }

        mutating func settle(_ outcome: Result<Void, Error>) {
            guard case .accepting(let backlog) = self else { return }
            switch outcome {
            case .success: self = .accepting(backlog: backlog - 1)
            case .failure(let error): self = .failed(error)
            }
        }
    }

    private enum EncoderState {
        case waitingForFirstFrame
        /// `startHostTime` is the host-clock moment the recording's timeline starts.
        case recording(startHostTime: CFTimeInterval)
        case closed
    }

    private let outputURL: URL
    private let stream: QueueConfined<GIFFrameStream>
    private let encodeQueue = DispatchQueue(label: "Screensnap.gifEncode", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let intake = OSAllocatedUnfairLock(initialState: Intake.accepting(backlog: 0))
    private var state: EncoderState = .waitingForFirstFrame

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        self.stream = QueueConfined(try GIFFrameStream(url: outputURL))
    }

    /// Throws the error of an earlier frame that failed to encode, so the recording
    /// stops instead of capturing into a broken file.
    func append(_ frame: CapturedFrame) throws {
        switch state {
        case .closed: return
        case .waitingForFirstFrame: state = .recording(startHostTime: frame.hostTime - frame.timestamp)
        case .recording: break
        }
        switch try intake.withLock({ try $0.admit() }) {
        case .dropped: return
        case .queued: break
        }
        encodeQueue.async { [stream, intake] in
            let outcome = Result { try stream.value.add(frame.image, at: frame.timestamp) }
            intake.withLock { $0.settle(outcome) }
        }
    }

    /// The GIF lasts until now. ScreenCaptureKit only delivers frames when the screen
    /// changes, so the last frame received stays on screen up to the moment of stopping.
    func finish() async throws -> FinishedEncoding {
        let end: CFTimeInterval
        switch state {
        case .closed: throw GIFStreamError.closed
        case .waitingForFirstFrame: end = 0
        case .recording(let startHostTime): end = CACurrentMediaTime() - startHostTime
        }
        state = .closed
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            encodeQueue.async { [stream] in
                continuation.resume(with: Result { try stream.value.finish(at: end) })
            }
        }
        return FinishedEncoding(url: outputURL, degradation: nil)
    }

    func cancel() {
        state = .closed
        encodeQueue.async { [stream] in stream.value.abandon() }
    }
}

/// A value only ever used on one serial queue. `@unchecked Sendable` because that
/// confinement is what makes handing it to the queue safe, and the compiler cannot see it.
private final class QueueConfined<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
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
    private var frames: [SavedFrame] = []
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

    func append(_ frame: CapturedFrame) throws {
        guard !isCancelled else { return }
        let saved = SavedFrame(
            file: tempDir.appendingPathComponent(String(format: "frame-%06d.png", frames.count)),
            timestamp: frame.timestamp
        )
        frames.append(saved)
        let image = frame.image
        let destURL = saved.file
        encodeQueue.async {
            guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            _ = CGImageDestinationFinalize(dest)
        }
    }

    func finish() async throws -> FinishedEncoding {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            encodeQueue.async { continuation.resume() }
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }
        guard !isCancelled else { throw CancellationError() }

        // A frame whose PNG failed to write is skipped. gifski spaces the rest evenly
        // by --fps; the fallback keeps each frame's own timestamp.
        let written = frames.filter { FileManager.default.fileExists(atPath: $0.file.path) }

        do {
            try await runGifski(frames: written.map(\.file))
            return FinishedEncoding(url: outputURL, degradation: nil)
        } catch {
            FileHandle.standardError.write(Data("[Screensnap] gifski failed, assembling with ImageIO: \(error.localizedDescription)\n".utf8))
            let end = (written.last?.timestamp ?? 0) + 1.0 / Double(max(1, framerate))
            let outputURL = self.outputURL
            try await Task.detached(priority: .userInitiated) {
                try Self.assembleWithImageIO(written, end: end, outputURL: outputURL)
            }.value
            switch error {
            case GifskiError.tooManyFrames(let count): return FinishedEncoding(url: outputURL, degradation: .gifskiTooManyFrames(count))
            default: return FinishedEncoding(url: outputURL, degradation: .gifskiFailed)
            }
        }
    }

    /// Every frame is its own argument, and the kernel caps argv plus the environment
    /// at ARG_MAX (1 MiB). gifski runs inside the frame directory so each argument is
    /// a bare filename rather than a temp path four times as long — roughly 36,000
    /// frames instead of 9,000. Past the ceiling it is not launched at all.
    private func runGifski(frames: [URL]) async throws {
        let arguments = ["--fps", String(framerate), "--quality", String(quality), "-o", outputURL.path] + frames.map(\.lastPathComponent)
        guard Self.argvBytes(arguments) <= Self.argvBudget else { throw GifskiError.tooManyFrames(frames.count) }

        let process = Process()
        process.executableURL = gifskiURL
        process.currentDirectoryURL = tempDir
        process.arguments = arguments
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
                    continuation.resume(throwing: GifskiError.exited(status: p.terminationStatus, stderr: msg))
                }
            }
        }
    }

    /// ARG_MAX less room for the environment, which counts against the same limit.
    private static let argvBudget = 900 * 1024

    /// What `execve` charges for an argument vector: each string, its NUL, and its
    /// pointer, with the executable path as argv[0].
    private nonisolated static func argvBytes(_ arguments: [String]) -> Int {
        let pointer = MemoryLayout<UnsafePointer<CChar>>.size
        return (arguments + ["gifski"]).reduce(0) { $0 + $1.utf8.count + 1 + pointer }
    }

    private nonisolated static func assembleWithImageIO(_ frames: [SavedFrame], end: CFTimeInterval, outputURL: URL) throws {
        // gifski may have left a partial file, and the stream replaces it only on success.
        try? FileManager.default.removeItem(at: outputURL)
        let stream = try GIFFrameStream(url: outputURL)
        let decodeOnDemand = [kCGImageSourceShouldCache: false] as CFDictionary
        for frame in frames {
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(frame.file as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOnDemand) else { return }
                try stream.add(image, at: frame.timestamp)
            }
        }
        try stream.finish(at: end)
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

enum GifskiError: LocalizedError {
    case tooManyFrames(Int)
    case exited(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .tooManyFrames(let count): return "\(count) frames are more than one gifski command line can hold"
        case .exited(let status, let stderr): return "gifski exited with status \(status): \(stderr)"
        }
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

    /// While paused, buffers are dropped. Resuming shifts the timeline zero by the
    /// pause so the audio after it lines up with the video after it.
    func pause() {
        state.withLock { $0.isAccepting = false }
    }

    func resume(pausedFor: CFTimeInterval) {
        state.withLock { s in
            s.hostZero = s.hostZero.map { $0 + pausedFor }
            s.isAccepting = true
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

    func finish() async throws -> FinishedEncoding {
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
        return FinishedEncoding(url: outputURL, degradation: nil)
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
