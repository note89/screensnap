@preconcurrency import AVFoundation
import Foundation
import ImageIO

enum CompressionTarget: Equatable {
    case size(ByteCount, within: ResolutionCeiling)
    case fit(ResolutionPreset)

    static let sizePresets: [ByteCount] = [5, 10, 25, 100].map { ByteCount(Int64($0) * 1_000_000) }

    var label: String {
        switch self {
        case .size(let bytes, _): return bytes.formatted
        case .fit(let preset): return preset.label
        }
    }

    /// Suffix for sibling files: `clip-720p.mp4`, `clip-10MB.gif`.
    fileprivate var fileSuffix: String {
        switch self {
        case .size(let bytes, _): return "\(Int((Double(bytes.bytes) / 1_000_000).rounded()))MB"
        case .fit(let preset): return preset.label
        }
    }
}

/// How long the file a compression replaced stays recoverable. Compressing is lossy
/// and often runs unattended, right after a recording, so the raw file is moved
/// aside rather than thrown away.
enum OriginalsRetention: Int, CaseIterable {
    case discard = 0
    case week = 7
    case month = 30
    case quarter = 90

    var label: String {
        switch self {
        case .discard: return "Move to the Trash"
        case .week: return "Keep for 7 days"
        case .month: return "Keep for 30 days"
        case .quarter: return "Keep for 90 days"
        }
    }

    /// Subfolder of the recordings folder the replaced files are moved into.
    static let folderName = "Originals"
}

enum CompressionPlacement: Equatable {
    case replaceOriginal
    case sibling
}

enum SizeFit: Equatable {
    case met
    /// Smallest we could make it; still over the requested size.
    case exceeded
}

struct CompressionResult: Equatable {
    let url: URL
    let bytes: ByteCount
    let fit: SizeFit
}

enum CompressionError: LocalizedError {
    case unreadable
    case exportUnavailable
    case exportFailed(String)
    /// The one job slot is taken.
    case busy
    /// The result is complete and in the folder under a stand-in name; only the
    /// swap with the original did not happen.
    case leftBeside(URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Could not read the recording."
        case .exportUnavailable: return "This Mac cannot export the recording in that format."
        case .exportFailed(let reason): return "Compression failed: \(reason)"
        case .busy: return "Another compression is still running."
        case .leftBeside(let url, let reason): return "The compressed file is saved as \(url.lastPathComponent), but the original could not be replaced: \(reason)"
        }
    }
}

typealias ProgressHandler = @Sendable (Double) -> Void

/// Re-encodes a recording to a smaller file. MP4 is re-encoded as HEVC at a bitrate
/// worked out from the size limit; GIF is re-encoded frame by frame, shrinking and
/// thinning frames until it fits.
///
/// The result is built on the recording's own volume and moved into its folder by
/// rename, so the folder holds a complete file at every step: the original until it
/// is moved aside, the result from before that. A crash or a quit part-way loses nothing
/// that was there.
enum Compressor {
    static func compress(
        _ recording: Recording,
        info: MediaInfo,
        to target: CompressionTarget,
        placement: CompressionPlacement,
        originals: OriginalsRetention,
        progress: @escaping ProgressHandler
    ) async throws -> CompressionResult {
        let scratchFolder = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: recording.url, create: true
        )
        defer { try? FileManager.default.removeItem(at: scratchFolder) }
        let scratch = scratchFolder.appendingPathComponent("compressed").appendingPathExtension(recording.url.pathExtension)

        let fit: SizeFit
        switch recording.container {
        case .mp4: fit = try await compressMP4(recording.url, info: info, to: target, into: scratch, progress: progress)
        case .gif: fit = try await compressGIF(recording.url, info: info, to: target, into: scratch, progress: progress)
        }

        let destination = try place(scratch, for: recording, target: target, placement: placement, originals: originals)
        let bytes = fileSize(destination)
        return CompressionResult(url: destination, bytes: bytes, fit: fit)
    }

    private static func place(_ scratch: URL, for recording: Recording, target: CompressionTarget, placement: CompressionPlacement, originals: OriginalsRetention) throws -> URL {
        let folder = recording.url.deletingLastPathComponent()
        let pathExtension = recording.url.pathExtension
        switch placement {
        case .sibling:
            let destination = FileManager.default.unusedURL(in: folder, stem: "\(recording.name)-\(target.fileSuffix)", pathExtension: pathExtension)
            try FileManager.default.moveItem(at: scratch, to: destination)
            return destination
        case .replaceOriginal:
            // Into the folder first, under a stand-in name, so the original is only
            // moved aside once its replacement is already beside it.
            let staged = FileManager.default.unusedURL(in: folder, stem: "\(recording.name)-compressing", pathExtension: pathExtension)
            try FileManager.default.moveItem(at: scratch, to: staged)
            do {
                try setAside(recording, originals: originals)
                try FileManager.default.moveItem(at: staged, to: recording.url)
            } catch {
                throw CompressionError.leftBeside(staged, reason: error.localizedDescription)
            }
            return recording.url
        }
    }

    /// Moves the file being replaced out of the library: into `Originals` for as long as
    /// `originals` says, otherwise to the Trash.
    private static func setAside(_ recording: Recording, originals: OriginalsRetention) throws {
        guard originals != .discard else {
            try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
            return
        }
        let folder = recording.url.deletingLastPathComponent().appendingPathComponent(OriginalsRetention.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = FileManager.default.unusedURL(in: folder, stem: recording.name, pathExtension: recording.url.pathExtension)
        try FileManager.default.moveItem(at: recording.url, to: destination)
    }

    /// Asks the file system every time. `URL.resourceValues` caches on the URL, and off
    /// the main run loop that cache is never cleared, so reading `scratch` after a later
    /// attempt rewrote it would return the first attempt's size.
    private static func fileSize(_ url: URL) -> ByteCount {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ByteCount((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
    }

    // MARK: MP4

    /// Encodes tried per size-limit shrink. The first aims at the limit; the rest
    /// correct the bitrate by how far the encoder landed from it.
    private static let mp4Attempts = 4

    private static func compressMP4(_ url: URL, info: MediaInfo, to target: CompressionTarget, into scratch: URL, progress: @escaping ProgressHandler) async throws -> SizeFit {
        let asset = AVURLAsset(url: url)
        let duration = max(1, info.duration)
        let framerate = max(1, Double(info.frameCount) / duration)

        switch target {
        case .fit(let preset):
            let sourceBitsPerSecond = Double(fileSize(url).bytes) * 8 / duration
            let budget = VideoPlanner.resizing(source: info.dimensions, sourceBitsPerSecond: sourceBitsPerSecond, to: preset)
            try await HEVCTranscoder.transcode(asset, to: scratch, budget: budget, framerate: framerate, progress: progress)
            return .met

        case .size(let limit, let ceiling):
            let audioBytes = try await audioByteEstimate(asset, duration: duration)
            let plan = VideoPlanner.fitting(
                limitBytes: limit.bytes, audioBytes: audioBytes, duration: duration,
                framerate: framerate, source: info.dimensions, ceiling: ceiling
            )
            let ladder = VideoPlanner.frameSizes(from: info.dimensions, ceiling: ceiling)
            var rung = ladder.firstIndex(of: plan.dimensions) ?? 0
            var bitsPerSecond = Double(plan.bitsPerSecond)

            for attempt in 0..<mp4Attempts {
                try? FileManager.default.removeItem(at: scratch)
                let budget = VideoBudget(dimensions: ladder[rung], bitsPerSecond: Int(bitsPerSecond))
                try await HEVCTranscoder.transcode(asset, to: scratch, budget: budget, framerate: framerate) { fraction in
                    progress(attemptProgress(attempt, fraction))
                }
                let bytes = fileSize(scratch).bytes
                if bytes <= limit.bytes { return .met }
                if attempt == mp4Attempts - 1 { break }

                // Over: ask for fewer bits in proportion to the overshoot, and move to a
                // smaller frame if that leaves the current one starved.
                bitsPerSecond *= Double(limit.bytes) * VideoPlanner.aimAtFractionOfLimit / Double(bytes)
                if rung < ladder.count - 1, VideoPlanner.isStarved(ladder[rung], bitsPerSecond: bitsPerSecond, framerate: framerate) {
                    rung += 1
                }
            }
            return .exceeded
        }
    }

    /// The first encode takes most of the bar; retries share the rest.
    private static func attemptProgress(_ attempt: Int, _ fraction: Double) -> Double {
        attempt == 0 ? fraction * 0.7 : 0.7 + (Double(attempt - 1) + fraction) / Double(mp4Attempts - 1) * 0.3
    }

    /// The audio is copied as is, so its size is the source's: bitrate times length.
    private static func audioByteEstimate(_ asset: AVURLAsset, duration: TimeInterval) async throws -> Int64 {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let bitsPerSecond = try await track.load(.estimatedDataRate)
        return Int64(Double(bitsPerSecond) * duration / 8)
    }

    // MARK: GIF

    private struct GIFAttempt {
        /// Below 1 shrinks every frame; 1 or more keeps the original size.
        let scale: Double
        /// Keep every n-th frame; the kept one stays up through the skipped ones after it.
        let stride: Int

        /// nil when the frame cannot be scaled; never the original size in place of a
        /// smaller one, because every frame must match the canvas the first one set.
        func resized(_ frame: CGImage) -> CGImage? {
            scale < 1 ? frame.scaled(by: scale) : frame
        }
    }

    private static func compressGIF(_ url: URL, info: MediaInfo, to target: CompressionTarget, into scratch: URL, progress: @escaping ProgressHandler) async throws -> SizeFit {
        let attempts: [GIFAttempt]
        let limit: Int64?
        switch target {
        case .fit(let preset):
            attempts = [GIFAttempt(scale: info.dimensions.fitFactor(into: preset.box), stride: 1)]
            limit = nil
        case .size(let bytes, _):
            attempts = [
                GIFAttempt(scale: 0.75, stride: 1),
                GIFAttempt(scale: 0.5, stride: 1),
                GIFAttempt(scale: 0.5, stride: 2),
                GIFAttempt(scale: 0.35, stride: 2),
                GIFAttempt(scale: 0.25, stride: 2),
                GIFAttempt(scale: 0.25, stride: 3),
            ]
            limit = bytes.bytes
        }

        for (step, attempt) in attempts.enumerated() {
            try? FileManager.default.removeItem(at: scratch)
            let total = Double(attempts.count)
            try await Task.detached(priority: .userInitiated) {
                try reencodeGIF(url, attempt: attempt, to: scratch) { fraction in
                    progress((Double(step) + fraction) / total)
                }
            }.value
            let bytes = fileSize(scratch).bytes
            if let limit, bytes > limit, step < attempts.count - 1 { continue }
            return limit.map { bytes <= $0 ? .met : .exceeded } ?? .met
        }
        throw CompressionError.unreadable
    }

    /// Streams the frames through `GIFFrameStream`, which holds about one frame at a time.
    /// A single `CGImageDestination` would keep every frame until finalize and then need
    /// ~60 MB per Retina frame to build one palette.
    private static func reencodeGIF(_ url: URL, attempt: GIFAttempt, to scratch: URL, progress: ProgressHandler) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CompressionError.unreadable }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw CompressionError.unreadable }

        let stream = try GIFFrameStream(url: scratch)
        // Each kept frame starts when it did in the source. A frame that is skipped or
        // cannot be read still advances `elapsed`, so the kept frame before it stays up
        // through it, and the last one stays up until the source ends.
        var elapsed: CFTimeInterval = 0
        for index in 0..<count {
            if index % 10 == 0 { progress(Double(index) / Double(count)) }
            let start = elapsed
            elapsed += GIFFrame.delay(source, index: index)
            guard index % attempt.stride == 0 else { continue }
            try autoreleasepool {
                guard let frame = GIFFrame.decodedImage(source, index: index) else { return }
                guard let resized = attempt.resized(frame) else { throw CompressionError.exportFailed("could not scale a frame") }
                try stream.add(resized, at: start)
            }
        }
        do {
            try stream.finish(at: elapsed)
        } catch GIFStreamError.noFrames {
            throw CompressionError.unreadable
        }
    }
}

extension CGImage {
    func scaled(by factor: Double) -> CGImage? {
        let target = Dimensions(width: width, height: height).scaled(by: factor)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(
            data: nil, width: target.width, height: target.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        return ctx.makeImage()
    }
}
