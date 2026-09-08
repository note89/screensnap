import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// One file in the recordings folder. The folder is the library: anything with a
/// recording extension counts, whether Screensnap made it or the user dropped it in.
struct Recording: Identifiable, Equatable, Hashable {
    let url: URL
    let container: OutputContainer
    let createdAt: Date
    let bytes: ByteCount

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    static let extensions: Set<String> = ["gif", "mp4"]

    init?(url: URL) {
        guard Self.extensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        self.url = url
        self.container = OutputContainer(url: url)
        self.createdAt = values.creationDate ?? .distantPast
        self.bytes = ByteCount(Int64(values.fileSize ?? 0))
    }
}

/// Facts that need the file opened: read once per file and cached by the store.
struct MediaInfo: Equatable {
    let duration: TimeInterval
    let dimensions: Dimensions
    let frameCount: Int

    var durationLabel: String {
        let total = Int(duration.rounded())
        return total >= 60 ? String(format: "%d:%02d", total / 60, total % 60) : "\(total)s"
    }

    static func load(_ recording: Recording) async -> MediaInfo? {
        switch recording.container {
        case .mp4: return await loadMP4(recording.url)
        case .gif: return loadGIF(recording.url)
        }
    }

    private static func loadMP4(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let frameRate = try? await track.load(.nominalFrameRate) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return MediaInfo(duration: seconds, dimensions: Dimensions(size), frameCount: Int(seconds * Double(frameRate)))
    }

    private static func loadGIF(_ url: URL) -> MediaInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = first[kCGImagePropertyPixelWidth] as? Int,
              let height = first[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let duration = (0..<count).reduce(0.0) { $0 + GIFFrame.delay(source, index: $1) }
        return MediaInfo(duration: duration, dimensions: Dimensions(width: width, height: height), frameCount: count)
    }
}

enum GIFFrame {
    static func delay(_ source: CGImageSource, index: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let delay = unclamped ?? clamped ?? 0.1
        return delay > 0 ? delay : 0.1
    }
}

enum Thumbnail {
    static let maxEdge: CGFloat = 320

    static func make(for recording: Recording) async -> CGImage? {
        switch recording.container {
        case .mp4:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: recording.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
            return try? await generator.image(at: .zero).image
        case .gif:
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxEdge),
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(recording.url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        }
    }
}

enum Clipboard {
    /// Always the file URL (Finder, Slack, browsers take it); raw GIF bytes too, so
    /// image fields that ignore file URLs still get the animation.
    static func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        if OutputContainer(url: url) == .gif, let data = try? Data(contentsOf: url) {
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        }
    }
}
