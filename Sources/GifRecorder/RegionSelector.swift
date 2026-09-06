import AppKit
import CoreGraphics

/// A region the user has selected on a particular display.
struct SelectedRegion {
    /// The display the region lives on.
    let displayID: CGDirectDisplayID
    /// The display's full pixel size (already accounting for backing scale).
    let displayPixelSize: CGSize
    /// The selection in *pixels*, top-left origin, relative to the display.
    /// This is the format ScreenCaptureKit's `sourceRect` expects.
    let pixelRect: CGRect
}

/// Drag-to-select region overlay, modeled after macOS Cmd+Shift+5.
///
/// The selector covers every connected display with a dimmed overlay window.
/// On mouse-up it reports a `SelectedRegion`; on Escape (or Cmd-period) it cancels.
final class RegionSelector {
    private var overlays: [OverlayWindow] = []
    private var completion: ((SelectedRegion?) -> Void)?
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
        // Promote first overlay to key so it gets keyboard events (Esc to cancel).
        overlays.first?.makeKey()
        // Only one overlay can be key, so the panel's own keyDown only ever saw
        // Escape on that one display. A local monitor sees every key event while
        // we are the active app, whichever screen the cursor is on.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 /* esc */ else { return event }
            self?.finish(with: nil)
            return nil
        }
    }

    fileprivate func finish(with region: SelectedRegion?) {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
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
        selectionView.onCancel = { [weak self] in self?.owner?.finish(with: nil) }
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
        let cgBounds = CGDisplayBounds(displayID)
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
            displayPixelSize: CGSize(width: cgBounds.width * scale, height: cgBounds.height * scale),
            pixelRect: pixelRect.integral
        )
        owner?.finish(with: region)
    }
}

extension NSScreen {
    /// The `CGDirectDisplayID` behind this screen, falling back to the main display.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }
}

// MARK: - Selection view (handles drag + draws rectangle)

private final class SelectionView: NSView {
    var onCommit: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var dragOrigin: NSPoint?
    private var dragCurrent: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // ── User contribution point #1 ──────────────────────────────────────────
    // The drag handlers below are intentionally minimal. They commit any
    // rectangle the user draws, even a 2x2 px misclick. There are real UX
    // choices here that are worth your judgment:
    //
    //   • Minimum size: how small is "too small to record"? Reject? Snap up?
    //   • Modifier keys: should holding Shift constrain to a square?
    //   • Snap-to-edge: snap rectangle edges to screen edges within a few px?
    //   • Live size readout: draw "320×200" near the rectangle while dragging?
    //
    // See the TODO inside `mouseUp` — that's where the commit logic lives.
    // The other handlers (mouseDown, mouseDragged) are fine as-is for MVP.
    // ────────────────────────────────────────────────────────────────────────

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragCurrent = dragOrigin
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = currentRect() else { onCancel?(); return }

        // Minimum-size policy: anything under 10×10 pt is treated as a slipped
        // click. Reset and stay up so the user can try again — this used to
        // cancel the whole flow and drop them back at the launcher with no
        // explanation. Escape is the way out, and the hint says so.
        if rect.width < 10 || rect.height < 10 {
            dragOrigin = nil
            dragCurrent = nil
            needsDisplay = true
            return
        }
        onCommit?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 /* esc */ {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
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

    /// The overlay used to appear with no explanation at all — just a dimmed
    /// screen and a crosshair. Shown until the first drag begins.
    private func drawHint() {
        let text = "Drag to select the area to record   ·   esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 14
        let bgRect = NSRect(
            x: bounds.midX - size.width / 2 - pad,
            y: bounds.maxY - 96,
            width: size.width + pad * 2,
            height: size.height + pad
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: bgRect.minX + pad, y: bgRect.minY + pad / 2), withAttributes: attrs)
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
