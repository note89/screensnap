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
enum SizeLimit: Hashable, Codable {
    case none
    case bytes(Int64)

    static let presets: [(label: String, limit: SizeLimit)] = [
        ("No limit", .none),
        ("8 MB · Discord free", .bytes(8 * 1_000_000)),
        ("25 MB · Gmail, Slack", .bytes(25 * 1_000_000)),
        ("100 MB · Signal", .bytes(100 * 1_000_000)),
    ]

    var label: String {
        switch self {
        case .none: return "No limit"
        case .bytes(let bytes): return ByteCount(bytes).formatted
        }
    }

    func fits(_ bytes: Int64) -> Bool {
        switch self {
        case .none: return true
        case .bytes(let limit): return bytes <= limit
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
