import AppKit
import SwiftUI

/// The big 3, 2, 1 drawn over the area about to be recorded, so the user sees the
/// countdown where they are looking rather than only in the pill. Click-through and
/// kept out of screen capture; it is gone before the first frame anyway.
@MainActor
final class CountdownOverlay {
    private let panel: NSPanel
    private let model = CountdownModel()

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: CountdownNumber(model: model))
    }

    func show(_ remaining: Int, over area: ScreenRect) {
        model.remaining = remaining
        if panel.frame != area.cgRect { panel.setFrame(area.cgRect, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

@MainActor @Observable
private final class CountdownModel {
    var remaining = 0
}

private struct CountdownNumber: View {
    let model: CountdownModel

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            Text("\(model.remaining)")
                .font(.system(size: max(48, side * 0.35), weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 18)
                .contentTransition(.numericText(countsDown: true))
                .padding(side * 0.08)
                .background(Circle().fill(.black.opacity(0.35)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.25), value: model.remaining)
        }
    }
}
