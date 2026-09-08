@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Boxes a recording is scaled to fit inside; the number is the short edge of a
/// landscape recording, the way people say "720p".
enum ResolutionPreset: String, CaseIterable, Codable {
    case p1080
    case p720
    case p540
    case p480

    var box: Dimensions {
        switch self {
        case .p1080: return Dimensions(width: 1920, height: 1080)
        case .p720: return Dimensions(width: 1280, height: 720)
        case .p540: return Dimensions(width: 960, height: 540)
        case .p480: return Dimensions(width: 640, height: 480)
        }
    }

    var label: String { String(rawValue.dropFirst()) + "p" }

    fileprivate var exportPreset: String {
        switch self {
        case .p1080: return AVAssetExportPreset1920x1080
        case .p720: return AVAssetExportPreset1280x720
        case .p540: return AVAssetExportPreset960x540
        case .p480: return AVAssetExportPreset640x480
        }
    }

    /// Largest preset whose box does not enlarge `dimensions`; nil when the recording
    /// is already smaller than every box.
    static func largestNotEnlarging(_ dimensions: Dimensions) -> ResolutionPreset? {
        allCases.first { dimensions.fitFactor(into: $0.box) < 1 }
    }
}

enum CompressionTarget: Equatable {
    case size(ByteCount)
    case fit(ResolutionPreset)

    static let sizePresets: [ByteCount] = [5, 10, 25, 100].map { ByteCount(Int64($0) * 1_000_000) }

    var label: String {
        switch self {
        case .size(let bytes): return bytes.formatted
        case .fit(let preset): return preset.label
        }
    }

    /// Suffix for sibling files: `clip-720p.mp4`, `clip-10MB.gif`.
    fileprivate var fileSuffix: String {
        switch self {
        case .size(let bytes): return "\(Int((Double(bytes.bytes) / 1_000_000).rounded()))MB"
        case .fit(let preset): return preset.label
        }
    }
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

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Could not read the recording."
        case .exportUnavailable: return "This Mac cannot export the recording in that format."
        case .exportFailed(let reason): return "Compression failed: \(reason)"
        }
    }
}

typealias ProgressHandler = @Sendable (Double) -> Void

/// Re-encodes a recording to a smaller file. MP4 goes through `AVAssetExportSession`
/// with a file-length cap; GIF is re-encoded frame by frame, shrinking and thinning
/// frames until it fits.
enum Compressor {
    static func compress(
        _ recording: Recording,
        info: MediaInfo,
        to target: CompressionTarget,
        placement: CompressionPlacement,
        progress: @escaping ProgressHandler
    ) async throws -> CompressionResult {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("screensnap-compress-\(UUID().uuidString)")
            .appendingPathExtension(recording.url.pathExtension)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let fit: SizeFit
        switch recording.container {
        case .mp4: fit = try await compressMP4(recording.url, info: info, to: target, into: scratch, progress: progress)
        case .gif: fit = try await compressGIF(recording.url, info: info, to: target, into: scratch, progress: progress)
        }

        let destination = try place(scratch, for: recording, target: target, placement: placement)
        let bytes = ByteCount(Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        return CompressionResult(url: destination, bytes: bytes, fit: fit)
    }

    private static func place(_ scratch: URL, for recording: Recording, target: CompressionTarget, placement: CompressionPlacement) throws -> URL {
        let destination: URL
        switch placement {
        case .replaceOriginal:
            try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
            destination = recording.url
        case .sibling:
            destination = uniqueURL(
                folder: recording.url.deletingLastPathComponent(),
                stem: "\(recording.name)-\(target.fileSuffix)",
                pathExtension: recording.url.pathExtension
            )
        }
        try FileManager.default.moveItem(at: scratch, to: destination)
        return destination
    }

    private static func uniqueURL(folder: URL, stem: String, pathExtension: String) -> URL {
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension(pathExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(counter)").appendingPathExtension(pathExtension)
            counter += 1
        }
        return candidate
    }

    // MARK: MP4

    /// Same bits-per-pixel budget the recorder uses, so a resolution-only compress
    /// does not come out larger than the original.
    private static func bitrateBudget(_ dimensions: Dimensions) -> Int64 {
        max(600_000, Int64(dimensions.width) * Int64(dimensions.height) * 4)
    }

    private static func compressMP4(_ url: URL, info: MediaInfo, to target: CompressionTarget, into scratch: URL, progress: @escaping ProgressHandler) async throws -> SizeFit {
        let asset = AVURLAsset(url: url)
        let ladder: [ResolutionPreset]
        let limit: Int64?
        switch target {
        case .fit(let preset):
            ladder = [preset]
            limit = nil
        case .size(let bytes):
            let start = ResolutionPreset.largestNotEnlarging(info.dimensions) ?? .p480
            ladder = ResolutionPreset.allCases.drop { $0 != start }.map { $0 }
            limit = bytes.bytes
        }

        for (step, preset) in ladder.enumerated() {
            try? FileManager.default.removeItem(at: scratch)
            let outDimensions = info.dimensions.fitted(into: preset.box)
            let budgetBytes = bitrateBudget(outDimensions) * Int64(max(1, info.duration)) / 8
            let cap = min(budgetBytes, limit.map { Int64(Double($0) * 0.97) } ?? .max)
            try await export(asset, preset: preset.exportPreset, to: scratch, fileLengthLimit: cap) { fraction in
                progress((Double(step) + fraction) / Double(ladder.count))
            }
            let bytes = Int64((try? scratch.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if let limit, bytes > limit, step < ladder.count - 1 { continue }
            return limit.map { bytes <= $0 ? .met : .exceeded } ?? .met
        }
        throw CompressionError.exportFailed("no export presets available")
    }

    private static func export(_ asset: AVURLAsset, preset: String, to url: URL, fileLengthLimit: Int64, progress: @escaping ProgressHandler) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw CompressionError.exportUnavailable
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.fileLengthLimit = fileLengthLimit

        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poller.cancel() }

        await session.export()
        switch session.status {
        case .completed: return
        case .cancelled: throw CancellationError()
        default: throw CompressionError.exportFailed(session.error?.localizedDescription ?? "unknown")
        }
    }

    // MARK: GIF

    private struct GIFAttempt {
        let scale: Double
        /// Keep every n-th frame; skipped frames donate their delay to the kept one.
        let stride: Int
    }

    private static func compressGIF(_ url: URL, info: MediaInfo, to target: CompressionTarget, into scratch: URL, progress: @escaping ProgressHandler) async throws -> SizeFit {
        let attempts: [GIFAttempt]
        let limit: Int64?
        switch target {
        case .fit(let preset):
            attempts = [GIFAttempt(scale: info.dimensions.fitFactor(into: preset.box), stride: 1)]
            limit = nil
        case .size(let bytes):
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
            let bytes = Int64((try? scratch.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if let limit, bytes > limit, step < attempts.count - 1 { continue }
            return limit.map { bytes <= $0 ? .met : .exceeded } ?? .met
        }
        throw CompressionError.unreadable
    }

    private static func reencodeGIF(_ url: URL, attempt: GIFAttempt, to scratch: URL, progress: ProgressHandler) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CompressionError.unreadable }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let destination = CGImageDestinationCreateWithURL(scratch as CFURL, UTType.gif.identifier as CFString, 0, nil) else {
            throw CompressionError.unreadable
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

        var carriedDelay: TimeInterval = 0
        for index in 0..<count {
            let delay = GIFFrame.delay(source, index: index)
            carriedDelay += delay
            guard index % attempt.stride == 0 else { continue }
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let scaled = attempt.scale < 1 ? (frame.scaled(by: attempt.scale) ?? frame) : frame
            let props: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: carriedDelay,
                    kCGImagePropertyGIFUnclampedDelayTime: carriedDelay,
                ]
            ]
            CGImageDestinationAddImage(destination, scaled, props as CFDictionary)
            carriedDelay = 0
            if index % 10 == 0 { progress(Double(index) / Double(count)) }
        }
        guard CGImageDestinationFinalize(destination) else { throw CompressionError.exportFailed("could not write GIF") }
    }
}

extension Dimensions {
    /// Factor that fits these dimensions inside `box`; ≥ 1 means it already fits.
    func fitFactor(into box: Dimensions) -> Double {
        min(Double(box.width) / Double(width), Double(box.height) / Double(height))
    }

    func fitted(into box: Dimensions) -> Dimensions {
        let factor = fitFactor(into: box)
        return factor < 1 ? scaled(by: factor) : self
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
