import Foundation

/// Which GIF encoder produces the file. `best` needs the external gifski binary
/// and falls back to `fast` at pick time when it is missing (see `Output.effective`).
enum GifQuality: String, Codable, CaseIterable {
    case fast
    case best
}

enum AudioTrack: String, Codable, CaseIterable {
    case none
    case microphone
}

/// What a recording becomes on disk. Each case carries only the knobs that apply
/// to it, so "gifski on but MP4 selected" or "mic on but GIF selected" cannot exist.
enum Output: Equatable, Codable {
    case gif(GifQuality)
    case mp4(AudioTrack)

    var fileExtension: String {
        switch self {
        case .gif: return "gif"
        case .mp4: return "mp4"
        }
    }

    var label: String {
        switch self {
        case .gif(.fast): return "GIF"
        case .gif(.best): return "GIF · best"
        case .mp4(.none): return "MP4"
        case .mp4(.microphone): return "MP4 · voice"
        }
    }

    var container: OutputContainer {
        switch self {
        case .gif: return .gif
        case .mp4: return .mp4
        }
    }

    var recordsMicrophone: Bool {
        self == .mp4(.microphone)
    }

    /// What the user picked in Settings; GIF quality is stored beside it so switching
    /// GIF ↔ MP4 does not forget the quality choice.
    static func from(container: OutputContainer, gifQuality: GifQuality, audio: AudioTrack) -> Output {
        switch container {
        case .gif: return .gif(gifQuality)
        case .mp4: return .mp4(audio)
        }
    }
}

enum OutputContainer: String, Codable, CaseIterable {
    case gif
    case mp4

    init(url: URL) {
        self = url.pathExtension.lowercased() == "mp4" ? .mp4 : .gif
    }
}

/// An upper bound on the finished file. Shared per-service ceilings are named so the
/// user picks "Signal" rather than remembering a number.
enum SizeLimit: Hashable {
    case none
    case atMost(Ceiling)

    /// A positive file size. Zero or negative ceilings cannot be built, so a limit
    /// that no file could ever meet is not a state the app can be in.
    struct Ceiling: Hashable {
        let size: ByteCount

        init?(bytes: Int64) {
            guard bytes > 0 else { return nil }
            size = ByteCount(bytes)
        }

        init?(megabytes: Int) {
            guard megabytes > 0 else { return nil }
            self.init(bytes: Int64(megabytes) * 1_000_000)
        }

        /// What the user typed into the custom field, e.g. " 40 ".
        init?(megabytesText text: String) {
            guard let megabytes = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
            self.init(megabytes: megabytes)
        }

        var megabytes: Int { Int(size.bytes / 1_000_000) }
    }

    static let presets: [(label: String, limit: SizeLimit)] = [("Keep original size", .none)]
        + [(8, "Discord free"), (25, "Gmail, Slack"), (100, "Signal")].compactMap { megabytes, service in
            Ceiling(megabytes: megabytes).map { ("\(megabytes) MB · \(service)", .atMost($0)) }
        }

    var label: String {
        switch self {
        case .none: return "Off"
        case .atMost(let ceiling): return ceiling.size.formatted
        }
    }
}

struct ByteCount: Hashable, Comparable, Codable {
    let bytes: Int64

    init(_ bytes: Int64) { self.bytes = bytes }

    static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    var formatted: String { Self.formatter.string(fromByteCount: bytes) }

    static func < (lhs: ByteCount, rhs: ByteCount) -> Bool { lhs.bytes < rhs.bytes }
}

/// Pixel dimensions of a recording, kept as one value because width and height
/// only ever travel together.
struct Dimensions: Equatable, Codable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init(_ size: CGSize) {
        self.init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    var label: String { "\(width)×\(height)" }
    var shortEdge: Int { min(width, height) }

    /// Even dimensions, as H.264 requires; scaled proportionally.
    func scaled(by factor: Double) -> Dimensions {
        Dimensions(width: max(2, Int(Double(width) * factor) & ~1), height: max(2, Int(Double(height) * factor) & ~1))
    }

    /// Scale so the short edge matches `shortEdge` pixels; never upscales.
    func fitting(shortEdge target: Int) -> Dimensions {
        guard target < shortEdge else { return self }
        return scaled(by: Double(target) / Double(shortEdge))
    }
}
