import AppKit
import SwiftUI

/// Floating tile that sits under the System Settings window and holds Screensnap's
/// app bundle as a drag source, so the user can drop it into a privacy list instead
/// of hunting through the `+` file picker. Follows the Settings window and closes
/// itself once access is granted or System Settings goes away.
///
/// Only some panes accept drops (Screen Recording, Accessibility, Input Monitoring,
/// Full Disk Access). Camera and microphone do not — see `DeviceAccess`.
@MainActor
final class GrantPanel {
    private static let systemSettingsBundleID = "com.apple.systempreferences"
    private static let size = CGSize(width: 340, height: 84)
    private static let gap: CGFloat = 10
    /// Fast enough to beat System Settings' "Quit & Reopen?" sheet in most cases.
    private static let pollInterval: Duration = .milliseconds(100)
    /// System Settings needs a moment to launch after the deeplink opens it.
    private static let launchGrace: Duration = .seconds(5)

    private var panel: NSPanel?
    private var followTask: Task<Void, Never>?

    /// `isGranted` is polled while the panel is up; returning true dismisses it.
    func show(isGranted: @escaping () -> Bool, onGranted: @escaping () -> Void) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        followTask?.cancel()
        followTask = Task { [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                if isGranted() {
                    self?.hide()
                    onGranted()
                    return
                }
                switch Self.systemSettingsFrame() {
                case .some(let frame):
                    self?.place(beside: frame)
                case .none where ContinuousClock.now - start > Self.launchGrace:
                    self?.hide()
                    return
                case .none:
                    break
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func hide() {
        followTask?.cancel()
        followTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = DragTileView(close: { [weak self] in self?.hide() })
        return panel
    }

    private func place(beside settingsWindow: ScreenRect) {
        guard let panel else { return }
        let settings = settingsWindow.cgRect
        let screen = NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? settings
        var origin = CGPoint(x: settings.midX - Self.size.width / 2, y: settings.minY - Self.gap - Self.size.height)
        if origin.y < visible.minY {
            // No room below: tuck it inside the bottom of the Settings window, where the
            // privacy lists usually leave empty space.
            origin.y = settings.minY + Self.gap
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - Self.size.width)
        let frame = CGRect(origin: origin, size: Self.size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Frame of System Settings' main window. Window bounds and owner PIDs are
    /// readable without Screen Recording (titles are not), which matters because
    /// this panel exists for users who don't have it yet.
    private static func systemSettingsFrame() -> ScreenRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: systemSettingsBundleID).first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let bounds = windows
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
            .max { $0.width * $0.height < $1.width * $1.height }
        guard let bounds else { return nil }
        return ScreenRect(topLeftOrigin: bounds)
    }
}

private struct GrantTile: View {
    let icon: NSImage

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drag Screensnap into the list").font(.headline)
                Text("Then turn it on. Screensnap restarts by itself.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The whole tile is the drag source. It carries a file URL to the running bundle —
/// the same thing System Settings receives when you drag the app from Finder.
/// SwiftUI draws the tile but takes no clicks; only the close button is hit-testable.
private final class DragTileView: NSView, NSDraggingSource {
    private let bundleURL = Bundle.main.bundleURL
    private let icon: NSImage

    init(close: @escaping () -> Void) {
        icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        super.init(frame: .zero)
        toolTip = "Drag into the System Settings list"

        let tile = PassthroughHostingView(rootView: GrantTile(icon: icon))
        tile.autoresizingMask = [.width, .height]
        addSubview(tile)

        let closeButton = ClosureButton(action: close)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    // The panel is non-activating, so the first click must start the drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        let side: CGFloat = 48
        item.setDraggingFrame(CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class ClosureButton: NSButton {
    private let onPress: () -> Void

    init(action: @escaping () -> Void) {
        onPress = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(press)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func press() { onPress() }
}
