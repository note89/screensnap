import Accelerate
import CoreGraphics
import Foundation

struct PixelPoint: Equatable {
    let x: Int
    let y: Int

    static let zero = PixelPoint(x: 0, y: 0)
}

/// A rectangle of whole pixels. The origin is the top-left corner, matching the
/// order image rows are stored in and the way GIF places frames.
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

/// What differs between a frame and the one before it.
enum FrameChange: Equatable {
    case unchanged
    case region(PixelRect)
}

/// Whether a region holds any pixel short of fully opaque. GIF transparency is on or
/// off per pixel, so such a pixel may come out transparent.
enum Opacity: Equatable {
    case opaque
    case translucent
}

/// Where a pixel's alpha lives.
private enum AlphaChannel: Equatable {
    case absent
    /// Offset of the alpha byte inside an 8-bit, four-channel pixel.
    case byte(offset: Int)
    /// A layout this code does not read. Treated as possibly translucent.
    case unreadable

    init(_ image: CGImage) {
        let alphaFirst: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            self = .absent
            return
        case .premultipliedFirst, .first:
            alphaFirst = true
        case .premultipliedLast, .last:
            alphaFirst = false
        case .alphaOnly:
            self = .unreadable
            return
        @unknown default:
            self = .unreadable
            return
        }
        guard image.bitsPerPixel == 32, image.bitsPerComponent == 8 else {
            self = .unreadable
            return
        }
        switch image.byteOrderInfo {
        case .orderDefault, .order32Big: self = .byte(offset: alphaFirst ? 0 : 3)
        case .order32Little: self = .byte(offset: alphaFirst ? 3 : 0)
        default: self = .unreadable
        }
    }
}

/// Everything that decides where a pixel's bytes live. Two frames can only be
/// compared byte for byte when these match.
private struct PixelLayout: Equatable {
    let size: Dimensions
    let bitsPerPixel: Int
    let bytesPerRow: Int
    let bitmapInfo: UInt32
    let alpha: AlphaChannel

    init(_ image: CGImage) {
        size = image.pixelBounds.size
        bitsPerPixel = image.bitsPerPixel
        bytesPerRow = image.bytesPerRow
        bitmapInfo = image.bitmapInfo.rawValue
        alpha = AlphaChannel(image)
    }

    var bytesPerPixel: Int { bitsPerPixel / 8 }
    var bounds: PixelRect { PixelRect(origin: .zero, size: size) }
}

/// A frame's raw pixel bytes, kept so the next frame can be compared against it.
/// For a bitmap-backed `CGImage` (every captured frame) this retains the image's
/// buffer rather than copying it.
struct FramePixels {
    private let layout: PixelLayout
    private let bytes: CFData

    /// nil when the image has no byte-addressable pixels to compare.
    init?(_ image: CGImage) {
        let layout = PixelLayout(image)
        guard layout.bitsPerPixel % 8 == 0, let bytes = image.dataProvider?.data else { return nil }
        let lastRowEnd = layout.bytesPerRow * (layout.size.height - 1) + layout.size.width * layout.bytesPerPixel
        guard CFDataGetLength(bytes) >= lastRowEnd else { return nil }
        self.layout = layout
        self.bytes = bytes
    }

    /// The smallest rectangle holding every pixel that differs from `previous`.
    /// Frames laid out differently cannot be compared, so all of this one counts as changed.
    func change(since previous: FramePixels) -> FrameChange {
        guard layout == previous.layout,
              let old = CFDataGetBytePtr(previous.bytes),
              let new = CFDataGetBytePtr(bytes) else { return .region(layout.bounds) }
        let width = layout.size.width
        let fullRow = 0..<width
        func row(_ y: Int) -> RowComparison {
            RowComparison(old: old + y * layout.bytesPerRow, new: new + y * layout.bytesPerRow, bytesPerPixel: layout.bytesPerPixel)
        }

        let rows = 0..<layout.size.height
        guard let top = rows.first(where: { row($0).differs(fullRow) }),
              let bottom = rows.last(where: { row($0).differs(fullRow) }) else { return .unchanged }

        // Start with an empty column range; the first differing row widens it.
        var left = width
        var right = -1
        for y in top...bottom {
            let pair = row(y)
            if pair.differs(0..<left) {
                left = pair.firstDifference(in: 0..<left)
            }
            if pair.differs((right + 1)..<width) {
                right = pair.lastDifference(in: (right + 1)..<width)
            }
        }
        return .region(PixelRect(
            origin: PixelPoint(x: left, y: top),
            size: Dimensions(width: right - left + 1, height: bottom - top + 1)
        ))
    }

    /// Whether every pixel inside `rect` is fully opaque. `rect` must lie within the frame.
    func opacity(in rect: PixelRect) -> Opacity {
        switch layout.alpha {
        case .absent:
            return .opaque
        case .unreadable:
            return .translucent
        case .byte(let offset):
            guard let base = CFDataGetBytePtr(bytes) else { return .translucent }
            let start = base + rect.origin.y * layout.bytesPerRow + rect.origin.x * layout.bytesPerPixel
            var region = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: start),
                height: vImagePixelCount(rect.size.height),
                width: vImagePixelCount(rect.size.width),
                rowBytes: layout.bytesPerRow
            )
            // One 256-bin histogram per byte of the pixel, in memory order.
            let counts = UnsafeMutablePointer<vImagePixelCount>.allocate(capacity: 4 * 256)
            defer { counts.deallocate() }
            var channels: [UnsafeMutablePointer<vImagePixelCount>?] = (0..<4).map { counts + $0 * 256 }
            guard vImageHistogramCalculation_ARGB8888(&region, &channels, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                return .translucent
            }
            let fullyOpaque = counts[offset * 256 + 255]
            return fullyOpaque == vImagePixelCount(rect.size.width * rect.size.height) ? .opaque : .translucent
        }
    }
}

/// The same row in two frames. Searches bisect with `memcmp`, so finding an edge
/// costs a couple of passes over the row rather than a loop per pixel.
private struct RowComparison {
    let old: UnsafePointer<UInt8>
    let new: UnsafePointer<UInt8>
    let bytesPerPixel: Int

    func differs(_ pixels: Range<Int>) -> Bool {
        guard !pixels.isEmpty else { return false }
        let offset = pixels.lowerBound * bytesPerPixel
        return memcmp(old + offset, new + offset, pixels.count * bytesPerPixel) != 0
    }

    /// Leftmost differing pixel. `pixels` must contain one.
    func firstDifference(in pixels: Range<Int>) -> Int {
        var candidates = pixels
        while candidates.count > 1 {
            let lowerHalf = candidates.lowerBound..<(candidates.lowerBound + candidates.count / 2)
            candidates = differs(lowerHalf) ? lowerHalf : lowerHalf.upperBound..<candidates.upperBound
        }
        return candidates.lowerBound
    }

    /// Rightmost differing pixel. `pixels` must contain one.
    func lastDifference(in pixels: Range<Int>) -> Int {
        var candidates = pixels
        while candidates.count > 1 {
            let upperHalf = (candidates.upperBound - candidates.count / 2)..<candidates.upperBound
            candidates = differs(upperHalf) ? upperHalf : candidates.lowerBound..<upperHalf.lowerBound
        }
        return candidates.lowerBound
    }
}
