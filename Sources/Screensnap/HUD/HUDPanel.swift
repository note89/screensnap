import AppKit
import SwiftUI

/// Lets buttons in a non-activating panel take the first click without the panel
/// having to become key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The one floating pill. Countdown, recording controls, encoding progress and the
/// saved/failed message all live here, at the bottom of the screen under the mouse.
/// Never takes focus; never appears in recordings.
@MainActor
final class HUDPanel {
    static let size = NSSize(width: 480, height: 76)
    private static let bottomMargin: CGFloat = 28
    private static let fadeOut: TimeInterval = 0.22

    private let panel: NSPanel
    private var visible = false

    var windowID: CGWindowID? {
        let number = panel.windowNumber
        return number > 0 ? CGWindowID(number) : nil
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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
        panel.contentView = FirstMouseHostingView(rootView: HUDView(coordinator: coordinator))
    }

    func render(_ phase: Phase) {
        switch phase {
        case .idle, .pickingSource: hide()
        case .countingDown, .recording, .finishing, .settled: show()
        }
    }

    /// Positioned once per appearance so it does not jump between phases.
    private func show() {
        if !visible {
            panel.setFrameOrigin(Self.origin(on: Self.screenUnderMouse()))
        }
        visible = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func hide() {
        guard visible else { return }
        visible = false
        let panel = panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOut
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.visible else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private static func origin(on screen: NSScreen?) -> NSPoint {
        guard let frame = screen?.visibleFrame else { return .zero }
        return NSPoint(x: frame.midX - size.width / 2, y: frame.minY + bottomMargin)
    }
}
