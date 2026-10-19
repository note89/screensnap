import Foundation

/// Boxes a recording is scaled to fit inside; the number is the short edge of a
/// landscape recording, the way people say "720p".
enum ResolutionPreset: String, CaseIterable, Codable {
    case p1440
    case p1080
    case p720
    case p540
    case p480

    var box: Dimensions {
        switch self {
        case .p1440: return Dimensions(width: 2560, height: 1440)
        case .p1080: return Dimensions(width: 1920, height: 1080)
        case .p720: return Dimensions(width: 1280, height: 720)
        case .p540: return Dimensions(width: 960, height: 540)
        case .p480: return Dimensions(width: 640, height: 480)
        }
    }

    var label: String { String(rawValue.dropFirst()) + "p" }

    /// Largest preset whose box does not enlarge `dimensions`; nil when the recording
    /// is already smaller than every box.
    static func largestNotEnlarging(_ dimensions: Dimensions) -> ResolutionPreset? {
        allCases.first { dimensions.fitFactor(into: $0.box) < 1 }
    }
}

/// How sharp a shrink to a size limit may stay. The shrink picks the sharpest frame
/// size the limit pays for; a ceiling stops it going above what the viewer needs.
enum ResolutionCeiling: String, CaseIterable, Codable {
    case best
    case p1080
    case p720

    var label: String {
        switch self {
        case .best: return "Sharpest that fits"
        case .p1080: return "Up to 1080p"
        case .p720: return "Up to 720p"
        }
    }

    /// nil: the recording's own size is allowed.
    var preset: ResolutionPreset? {
        switch self {
        case .best: return nil
        case .p1080: return .p1080
        case .p720: return .p720
        }
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

/// The frame size and average bitrate an MP4 is encoded with.
struct VideoBudget: Equatable {
    let dimensions: Dimensions
    let bitsPerSecond: Int
}

/// Turns "make this fit" into a frame size and a bitrate. The encoder is told the
/// bitrate directly; picking a canned export preset instead lets the preset choose,
/// and the presets spend far more bits than a screen recording needs.
enum VideoPlanner {
    /// Aim under the limit; the muxer and the encoder's rate control both overshoot a little.
    static let aimAtFractionOfLimit = 0.95

    /// Fewest bits per pixel per frame that still keeps text readable in HEVC screen
    /// content. Below it a smaller frame at the same bitrate looks better than a
    /// bigger, blockier one.
    static let minimumBitsPerPixel = 0.010

    /// HEVC needs about this share of the bits H.264 does for the same picture.
    static let hevcShareOfH264 = 0.7

    /// Share of the limit the picture gets at the least, so a limit the audio alone
    /// overruns still yields a plan; the result is then reported as over the limit.
    static let leastShareForVideo = 0.05

    /// Frame size and bitrate for a file of at most `limitBytes`.
    static func fitting(
        limitBytes: Int64,
        audioBytes: Int64,
        duration: TimeInterval,
        framerate: Double,
        source: Dimensions,
        ceiling: ResolutionCeiling
    ) -> VideoBudget {
        let videoBytes = max(Double(limitBytes) * aimAtFractionOfLimit - Double(audioBytes), Double(limitBytes) * leastShareForVideo)
        let bitsPerSecond = videoBytes * 8 / max(1, duration)
        let fps = max(1, framerate)

        let ladder = frameSizes(from: source, ceiling: ceiling)
        let chosen = ladder.first { !isStarved($0, bitsPerSecond: bitsPerSecond, framerate: fps) } ?? ladder.last ?? source
        return VideoBudget(dimensions: chosen, bitsPerSecond: Int(bitsPerSecond))
    }

    /// Whether `bitsPerSecond` is too few for a picture this big at this frame rate.
    static func isStarved(_ size: Dimensions, bitsPerSecond: Double, framerate: Double) -> Bool {
        Double(size.width * size.height) * max(1, framerate) * minimumBitsPerPixel > bitsPerSecond
    }

    /// A resolution-only compress: the requested frame size, and the source's bitrate
    /// scaled down with the pixel count, so the file shrinks without being starved.
    static func resizing(source: Dimensions, sourceBitsPerSecond: Double, to preset: ResolutionPreset) -> VideoBudget {
        let target = source.fitted(into: preset.box).scaled(by: 1)
        let pixelRatio = Double(target.width * target.height) / Double(source.width * source.height)
        return VideoBudget(dimensions: target, bitsPerSecond: max(200_000, Int(sourceBitsPerSecond * pixelRatio * hevcShareOfH264)))
    }

    /// Largest first: the source itself (or the ceiling's box), then every smaller preset.
    static func frameSizes(from source: Dimensions, ceiling: ResolutionCeiling) -> [Dimensions] {
        let top = ceiling.preset.map { source.fitted(into: $0.box) } ?? source
        let first = top.scaled(by: 1)
        let smaller = ResolutionPreset.allCases
            .map { source.fitted(into: $0.box).scaled(by: 1) }
            .filter { $0.width * $0.height < first.width * first.height }
        var seen = Set([first.label])
        return [first] + smaller.filter { seen.insert($0.label).inserted }
    }
}
