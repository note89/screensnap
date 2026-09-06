import AppKit

/// Small floating HUD that appears in the top-right of the main screen for
/// a couple of seconds and then fades out. Used to confirm "recording saved"
/// without putting an NSAlert in the user's face.
@MainActor
enum Toast {
    private static var current: NSWindowController?
    private static var dismissTask: Task<Void, Never>?

    /// `reveals`: a file to show in Finder when the toast is clicked. The moment
    /// the filename is on screen is the moment the user most wants to get at it.
    static func show(_ headline: String, detail: String? = nil, duration: TimeInterval = 2.2, reveals url: URL? = nil) {
        // Cancel any previous toast so a rapid sequence of recordings doesn't
        // stack windows on top of each other.
        dismissTask?.cancel()
        current?.window?.orderOut(nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: detail == nil ? 44 : 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = (url == nil)

        let bg = ToastView(frame: window.contentLayoutRect)
        if let url = url {
            // Weak: the window owns the view, which owns this closure.
            bg.onClick = { [weak window] in
                NSWorkspace.shared.activateFileViewerSelecting([url])
                window?.orderOut(nil)
            }
        }
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        window.contentView = bg

        let title = NSTextField(labelWithString: headline)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(title)
        if let detail = detail {
            let sub = NSTextField(labelWithString: detail)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingMiddle
            stack.addArrangedSubview(sub)
        }
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])

        if let screen = NSScreen.main {
            let margin: CGFloat = 24
            let frame = NSRect(
                x: screen.visibleFrame.maxX - window.frame.width - margin,
                y: screen.visibleFrame.maxY - window.frame.height - margin,
                width: window.frame.width,
                height: window.frame.height
            )
            window.setFrame(frame, display: false)
        }

        let controller = NSWindowController(window: window)
        window.orderFrontRegardless()
        current = controller

        // Fade out + close after the duration.
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
                if Toast.current === controller { Toast.current = nil }
            })
        }
    }
}

/// The toast's backdrop. Takes the click that would otherwise only serve to
/// activate the app — the toast is usually up while another app is frontmost —
/// and forwards it to `onClick`.
private final class ToastView: NSVisualEffectView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard let onClick = onClick else { return super.mouseUp(with: event) }
        onClick()
    }
}
