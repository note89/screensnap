import CoreGraphics
import Foundation

/// Pixel dimensions of an image or recording, kept as one value because width and
/// height only ever travel together.
struct Dimensions: Equatable, Codable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Rounded to the nearest whole pixel.
    init(_ size: CGSize) {
        self.init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    var label: String { "\(width)×\(height)" }
    var shortEdge: Int { min(width, height) }
    var cgSize: CGSize { CGSize(width: width, height: height) }

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

struct PixelPoint: Equatable {
    let x: Int
    let y: Int

    static let zero = PixelPoint(x: 0, y: 0)
}

/// A rectangle of whole pixels inside an image. The origin is the top-left corner,
/// matching the order image rows are stored in and the way GIF places frames.
struct PixelRect: Equatable {
    let origin: PixelPoint
    let size: Dimensions

    var cgRect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }
}

extension CGImage {
    var pixelBounds: PixelRect {
        PixelRect(origin: .zero, size: Dimensions(width: width, height: height))
    }
}
