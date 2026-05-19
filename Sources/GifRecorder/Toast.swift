import AppKit

/// Small floating HUD that appears in the top-right of the main screen for
/// a couple of seconds and then fades out. Used to confirm "recording saved"
/// without putting an NSAlert in the user's face.
@MainActor
enum Toast {
    private static var current: NSWindowController?
    private static var dismissTask: Task<Void, Never>?

    static func show(_ headline: String, filename: String? = nil, duration: TimeInterval = 2.2) {
        // Cancel any previous toast so a rapid sequence of recordings doesn't
        // stack windows on top of each other.
        dismissTask?.cancel()
        current?.window?.orderOut(nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: filename == nil ? 44 : 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true

        let bg = NSVisualEffectView(frame: window.contentLayoutRect)
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
        if let filename = filename {
            let sub = NSTextField(labelWithString: filename)
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
        controller.showWindow(nil)
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
