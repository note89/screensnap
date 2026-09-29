import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Lets buttons in a non-activating panel take the first click without the panel
/// having to become key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The screen edge the pill sits against, and where along it. Remembered, so the
/// pill comes back where the user last dropped it.
struct HUDDock: Equatable {
    enum Edge: String {
        case bottom
        case left
        case right
    }

    let edge: Edge
    /// The pill's centre as a fraction of the edge: 0 is the left end of the bottom
    /// edge and the bottom end of a side edge.
    let along: CGFloat

    static let standard = HUDDock(edge: .bottom, along: 0.5)

    init(edge: Edge, along: CGFloat) {
        self.edge = edge
        self.along = along.clamped(to: 0...1)
    }

    /// Drops snap to whichever of the bottom, left and right edges the pointer is
    /// closest to; the top belongs to the menu bar.
    init(nearest point: NSPoint, in area: NSRect) {
        let toBottom = point.y - area.minY
        let toLeft = point.x - area.minX
        let toRight = area.maxX - point.x
        let alongBottom = (point.x - area.minX) / max(area.width, 1)
        let alongSide = (point.y - area.minY) / max(area.height, 1)
        if toBottom <= min(toLeft, toRight) {
            self.init(edge: .bottom, along: alongBottom)
        } else if toLeft <= toRight {
            self.init(edge: .left, along: alongSide)
        } else {
            self.init(edge: .right, along: alongSide)
        }
    }

    /// The bottom corner on the pill's side of the screen, where the tucked marker goes.
    var corner: HorizontalEdge {
        switch edge {
        case .left: return .leading
        case .right: return .trailing
        case .bottom: return along < 0.5 ? .leading : .trailing
        }
    }
}

/// The full pill, or tucked away as a small marker in a corner so it stops
/// covering what is being recorded.
enum HUDPresence {
    case shown
    case tucked
}

/// What the panel holds right now. The view draws it; the panel sizes itself to it.
enum HUDLayout: Equatable {
    case pill(Axis)
    case marker

    var size: NSSize {
        switch self {
        case .pill(.horizontal): return NSSize(width: 520, height: 76)
        case .pill(.vertical): return NSSize(width: 80, height: 380)
        case .marker: return NSSize(width: 96, height: 40)
        }
    }
}

@MainActor @Observable
final class HUDChrome {
    fileprivate(set) var layout: HUDLayout = .pill(.horizontal)
}

/// The one floating pill. Countdown, recording controls, encoding progress and the
/// saved/failed message all live here, docked to the bottom, left or right edge of
/// the screen under the mouse. Never takes focus; never appears in recordings.
@MainActor
final class HUDPanel {
    /// Tucks and brings back the controls. A letter, so it cannot be misread the way
    /// "," was; far from ⌘⇧. (finish), so a slip does not end the recording; and not
    /// Escape, which editors press all day.
    static let presenceShortcut = "⌃⌘H"
    static let presenceShortcutSpoken = "Control-Command-H"
    private static let bottomGap: CGFloat = 28
    private static let sideGap: CGFloat = 8
    private static let cornerGap: CGFloat = 4
    private static let fadeOut: TimeInterval = 0.22

    private enum Key {
        static let dockEdge = "interface.hudDock.edge"
        static let dockAlong = "interface.hudDock.along"
    }

    /// Live stages carry controls and follow the dock, vertical on a side edge.
    /// Reports are messages: always read horizontally, never tucked.
    private enum Stage {
        case absent
        case live
        case report
    }

    private enum Visibility {
        case hidden
        /// Chosen when the pill appears, so it stays on one screen for the whole run.
        case shown(on: NSScreen?)
    }

    private struct Drag {
        let mouse: NSPoint
        let origin: NSPoint
    }

    let chrome = HUDChrome()
    private let panel: NSPanel
    private let defaults: UserDefaults
    private var visibility = Visibility.hidden
    private var stage = Stage.absent
    private var presence = HUDPresence.shown
    private var drag: Drag?
    private var hotkey: GlobalHotkey?
    private var dock: HUDDock {
        didSet {
            defaults.set(dock.edge.rawValue, forKey: Key.dockEdge)
            defaults.set(Double(dock.along), forKey: Key.dockAlong)
        }
    }

    var windowID: CGWindowID? {
        let number = panel.windowNumber
        return number > 0 ? CGWindowID(number) : nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dock = HUDDock.Edge(rawValue: defaults.string(forKey: Key.dockEdge) ?? "")
            .map { HUDDock(edge: $0, along: defaults.double(forKey: Key.dockAlong)) } ?? .standard
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: HUDLayout.pill(.horizontal).size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = .none
    }

    func attach(_ coordinator: Coordinator) {
        let host = FirstMouseHostingView(rootView: HUDView(coordinator: coordinator, hud: self))
        // The panel's frame follows `chrome.layout`, set here; the view must not resize it.
        host.sizingOptions = []
        panel.contentView = host
    }

    func render(_ phase: Phase) {
        stage = Self.stage(of: phase)
        switch stage {
        case .absent:
            presence = .shown
            hotkey = nil
            hide()
        case .live:
            claimHotkey()
            show()
        case .report:
            presence = .shown
            hotkey = nil
            show()
        }
    }

    /// Held only while there are controls to tuck, so ⌃⌘H reaches other apps the
    /// rest of the time.
    private func claimHotkey() {
        guard hotkey == nil else { return }
        hotkey = GlobalHotkey(keyCode: kVK_ANSI_H, modifiers: controlKey | cmdKey) { [weak self] in
            self?.togglePresence()
        }
    }

    func togglePresence() {
        guard case .live = stage else { return }
        drag = nil
        switch presence {
        case .shown: presence = .tucked
        case .tucked: presence = .shown
        }
        relayout(animated: false)
    }

    // MARK: Dragging

    /// Called for every movement of a drag on the pill. The pointer is read in screen
    /// coordinates because the view's own coordinates move with the panel.
    func dragMoved() {
        let mouse = NSEvent.mouseLocation
        guard let drag else {
            drag = Drag(mouse: mouse, origin: panel.frame.origin)
            return
        }
        panel.setFrameOrigin(NSPoint(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y))
    }

    func dragEnded() {
        guard drag != nil else { return }
        drag = nil
        let mouse = NSEvent.mouseLocation
        let screen = Self.screen(containing: mouse)
        visibility = .shown(on: screen)
        if let area = screen?.visibleFrame { dock = HUDDock(nearest: mouse, in: area) }
        relayout(animated: true)
    }

    // MARK: Layout

    private static func stage(of phase: Phase) -> Stage {
        switch phase {
        case .idle, .pickingSource: return .absent
        case .starting, .countingDown, .recording: return .live
        case .finishing, .settled: return .report
        }
    }

    private var layout: HUDLayout {
        switch presence {
        case .tucked:
            return .marker
        case .shown:
            switch (stage, dock.edge) {
            case (.live, .left), (.live, .right): return .pill(.vertical)
            case (.live, .bottom), (.report, _), (.absent, _): return .pill(.horizontal)
            }
        }
    }

    private func show() {
        if case .hidden = visibility {
            visibility = .shown(on: Self.screen(containing: NSEvent.mouseLocation))
        }
        relayout(animated: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func hide() {
        guard case .shown = visibility else { return }
        visibility = .hidden
        drag = nil
        let panel = panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOut
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, case .hidden = self.visibility else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    /// Puts the panel where the dock says, at the size the current layout needs.
    /// Leaves it alone mid-drag so a countdown tick does not yank it from the pointer.
    private func relayout(animated: Bool) {
        let layout = layout
        if chrome.layout != layout { chrome.layout = layout }
        guard drag == nil, case .shown(let screen) = visibility, let area = screen?.visibleFrame else { return }
        let frame = Self.frame(for: layout, docked: dock, in: area)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: animated) }
    }

    private static func frame(for layout: HUDLayout, docked dock: HUDDock, in area: NSRect) -> NSRect {
        let size = layout.size
        var origin: NSPoint
        switch layout {
        case .marker:
            switch dock.corner {
            case .leading: origin = NSPoint(x: area.minX + cornerGap, y: area.minY + cornerGap)
            case .trailing: origin = NSPoint(x: area.maxX - size.width - cornerGap, y: area.minY + cornerGap)
            }
        case .pill:
            let alongX = area.minX + dock.along * area.width - size.width / 2
            let alongY = area.minY + dock.along * area.height - size.height / 2
            switch dock.edge {
            case .bottom: origin = NSPoint(x: alongX, y: area.minY + bottomGap)
            case .left: origin = NSPoint(x: area.minX + sideGap, y: alongY)
            case .right: origin = NSPoint(x: area.maxX - size.width - sideGap, y: alongY)
            }
        }
        origin.x = origin.x.clamped(to: area.minX...max(area.minX, area.maxX - size.width))
        origin.y = origin.y.clamped(to: area.minY...max(area.minY, area.maxY - size.height))
        return NSRect(origin: origin, size: size)
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}
