import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// A region the user has selected on a particular display.
struct SelectedRegion {
    /// The display the region lives on.
    let displayID: CGDirectDisplayID
    /// The selection in *pixels*, top-left origin, relative to the display.
    /// This is the format ScreenCaptureKit's `sourceRect` expects.
    let pixelRect: CGRect
}

/// Drag-to-select region overlay, modeled after macOS Cmd+Shift+5.
///
/// The selector covers every connected display with a dimmed overlay window.
/// On mouse-up it reports a `SelectedRegion`; on Escape it cancels.
final class RegionSelector {
    private var overlays: [OverlayWindow] = []
    private var completion: ((SelectedRegion?) -> Void)?
    /// Only one overlay can be key, so its own keyDown saw Escape on one display
    /// only. The app is active while selecting, so a local monitor sees every key.
    private var escapeMonitor: Any?

    func begin(completion: @escaping (SelectedRegion?) -> Void) {
        self.completion = completion
        // Activate first so we can claim foreground even from a full-screen Space,
        // then orderFrontRegardless on the panels — `makeKey` would have failed
        // for non-activating panels in some background contexts.
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let overlay = OverlayWindow(screen: screen, owner: self)
            overlay.orderFrontRegardless()
            overlays.append(overlay)
        }
        overlays.first?.makeKey()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else { return event }
            self?.finish(with: nil)
            return nil
        }
    }

    fileprivate func finish(with region: SelectedRegion?) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        for overlay in overlays { overlay.orderOut(nil) }
        overlays.removeAll()
        let cb = completion
        completion = nil
        cb?(region)
    }
}

// MARK: - Overlay window

// Subclass NSPanel instead of NSWindow. `.nonactivatingPanel` + `.fullScreenAuxiliary`
// is the only AppKit combination that successfully overlays *another* app's
// full-screen Space — plain NSWindows with `.canJoinAllSpaces` won't appear there.
// This is the same trick Apple's Cmd+Shift+5 screenshot tool uses.
private final class OverlayWindow: NSPanel {
    private weak var owner: RegionSelector?
    private let selectionView: SelectionView

    init(screen: NSScreen, owner: RegionSelector) {
        self.owner = owner
        self.selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.18)
        // .mainMenu sits above app windows but below screen-saver-level alerts.
        // Combined with the collection-behavior flags below, this puts the overlay
        // on top of every running app, including other apps in full-screen Spaces.
        level = .mainMenu
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = selectionView
        selectionView.onCommit = { [weak self] rect in self?.commit(viewRect: rect) }
        acceptsMouseMovedEvents = true
        // Non-activating panels need this to receive mouse events properly.
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func commit(viewRect: NSRect) {
        guard let screen = self.screen else { owner?.finish(with: nil); return }
        let displayID = screen.displayID
        let scale = screen.backingScaleFactor

        // Convert AppKit (bottom-left, points, screen-local) → CG (top-left, pixels, display-local).
        // viewRect is already in screen-local points (selection view fills the screen).
        let topLeftYPoints = screen.frame.size.height - (viewRect.origin.y + viewRect.size.height)

        let pixelRect = CGRect(
            x: viewRect.origin.x * scale,
            y: topLeftYPoints * scale,
            width: viewRect.size.width * scale,
            height: viewRect.size.height * scale
        )

        let region = SelectedRegion(
            displayID: displayID,
            pixelRect: pixelRect.integral
        )
        owner?.finish(with: region)
    }
}

extension NSScreen {
    static func screen(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }

    /// The screen covering the largest part of `rect` (AppKit coordinates), or nil
    /// when it is on none of them.
    static func screen(mostlyShowing rect: CGRect) -> NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(rect)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        return screens.filter { overlap($0) > 0 }.max { overlap($0) < overlap($1) }
    }

    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }
}

// MARK: - Selection view (handles drag + draws rectangle)

private final class SelectionView: NSView {
    /// What the overlay shows while no drag is under way.
    private enum Hint {
        case howTo
        /// The last drag was smaller than `minimumSize` — taken as a slipped click.
        case tooSmall

        var text: String {
            switch self {
            case .howTo: return "Drag to select the area to record  ·  esc to cancel"
            case .tooSmall: return "Too small — drag a larger area  ·  esc to cancel"
            }
        }
    }

    /// Anything smaller in either dimension, in points, is a slipped click.
    private static let minimumSize: CGFloat = 10

    var onCommit: ((NSRect) -> Void)?

    private var dragOrigin: NSPoint?
    private var dragCurrent: NSPoint?
    private var hint = Hint.howTo

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragCurrent = dragOrigin
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    /// A slipped click used to cancel the whole flow without a word. It now clears
    /// the selection and stays up, saying why.
    override func mouseUp(with event: NSEvent) {
        guard let rect = currentRect() else { return }
        guard rect.width >= Self.minimumSize, rect.height >= Self.minimumSize else {
            dragOrigin = nil
            dragCurrent = nil
            hint = .tooSmall
            needsDisplay = true
            return
        }
        onCommit?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = currentRect() else {
            drawHint()
            return
        }
        // Carve a hole in the dim overlay so the user sees what they're selecting.
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        // Border.
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
        // Live dimensions.
        drawDimensions(in: rect)
    }

    private func drawHint() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = hint.text as NSString
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 12
        let bgRect = NSRect(
            x: bounds.midX - size.width / 2 - pad,
            y: bounds.maxY - 120,
            width: size.width + pad * 2,
            height: size.height + pad
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 8, yRadius: 8).fill()
        text.draw(at: NSPoint(x: bgRect.minX + pad, y: bgRect.minY + pad / 2), withAttributes: attrs)
    }

    private func drawDimensions(in rect: NSRect) {
        let scale = window?.backingScaleFactor ?? 1
        let label = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 6
        let bgRect = NSRect(
            x: rect.midX - size.width / 2 - pad,
            y: rect.minY - size.height - 14,
            width: size.width + pad * 2,
            height: size.height + 4
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(at: NSPoint(x: bgRect.minX + pad, y: bgRect.minY + 2), withAttributes: attrs)
    }

    private func currentRect() -> NSRect? {
        guard let a = dragOrigin, let b = dragCurrent else { return nil }
        return NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
