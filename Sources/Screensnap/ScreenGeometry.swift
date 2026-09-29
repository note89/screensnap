import AppKit
import CoreGraphics
import ScreenCaptureKit

/// A rectangle in global AppKit screen coordinates: points, origin at the bottom-left
/// of the primary display, y up. `NSScreen.frame`, `NSWindow.frame` and
/// `NSEvent.mouseLocation` are in these, so a value of this type compares with them
/// without a conversion. Bounds that ScreenCaptureKit and the window list report are
/// not, and only come in through `init(topLeftOrigin:)`.
struct ScreenRect: Equatable {
    let cgRect: CGRect

    init(_ rect: CGRect) {
        cgRect = rect
    }

    /// From bounds measured from the top-left of the primary display, y down, the way
    /// `SCWindow.frame` and `CGWindowListCopyWindowInfo` report them.
    init(topLeftOrigin bounds: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        self.init(CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height))
    }

    init(window: SCWindow) {
        self.init(topLeftOrigin: window.frame)
    }

    var size: CGSize { cgRect.size }
}

/// A rectangle of whole pixels on one display: top-left origin, relative to that
/// display, backing scale applied. The form `SCStreamConfiguration.sourceRect` takes.
struct DisplayPixelRect: Equatable {
    let displayID: CGDirectDisplayID
    let rect: CGRect

    init(displayID: CGDirectDisplayID, rect: CGRect) {
        self.displayID = displayID
        self.rect = rect.integral
    }

    /// From a selection drawn on `screen` in its own points (origin at the screen's
    /// bottom-left, y up), the way a view filling the screen reports a drag. nil for
    /// a screen AppKit gives no display number.
    init?(selection: NSRect, on screen: NSScreen) {
        guard let displayID = screen.displayID else { return nil }
        let scale = screen.backingScaleFactor
        let fromTop = screen.frame.height - selection.maxY
        self.init(displayID: displayID, rect: CGRect(
            x: selection.minX * scale,
            y: fromTop * scale,
            width: selection.width * scale,
            height: selection.height * scale
        ))
    }

    var pixelSize: Dimensions { Dimensions(rect.size) }

    /// Where the pixels sit on screen. `screen` must be the display this rect is on.
    func screenRect(on screen: NSScreen) -> ScreenRect {
        let scale = screen.backingScaleFactor
        return ScreenRect(CGRect(
            x: screen.frame.minX + rect.minX / scale,
            y: screen.frame.maxY - rect.maxY / scale,
            width: rect.width / scale,
            height: rect.height / scale
        ))
    }
}

extension NSScreen {
    /// nil for a screen with no display number, which AppKit does not promise to provide.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }

    /// The screen covering the largest part of `rect`, or nil when it is on none of them.
    static func screen(mostlyShowing rect: ScreenRect) -> NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(rect.cgRect)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        return screens.filter { overlap($0) > 0 }.max { overlap($0) < overlap($1) }
    }
}
