import AppKit

@MainActor
enum CountdownOverlay {
    /// Set while a countdown is on screen, so the global stop hotkey can cancel it.
    private static var cancelActive: (@MainActor () -> Void)?

    /// Cancel a countdown that is currently on screen. Returns whether there was one.
    @discardableResult
    static func cancelIfRunning() -> Bool {
        guard let cancel = cancelActive else { return false }
        cancel()
        return true
    }

    /// Displays a floating countdown panel on `screen`, or the main screen when nil.
    /// Returns true if the user cancelled, false if it ran to completion.
    static func run(seconds: Int, on screen: NSScreen? = nil) async -> Bool {
        let panel = CountdownPanel()
        panel.center(on: screen ?? NSScreen.main)
        panel.orderFrontRegardless()
        panel.makeKey()

        return await withCheckedContinuation { continuation in
            var resolved = false
            @MainActor
            func finish(_ cancelled: Bool) {
                guard !resolved else { return }
                resolved = true
                cancelActive = nil
                panel.orderOut(nil)
                continuation.resume(returning: cancelled)
            }

            panel.onCancel = { finish(true) }
            // The panel is non-activating, so it only sees Escape when it happens to
            // be key. Registering here lets the global ⌘⇧. hotkey — the same one that
            // finishes a recording — back out of the countdown from any app.
            cancelActive = { finish(true) }

            Task { @MainActor in
                for remaining in stride(from: seconds, through: 1, by: -1) {
                    if resolved { return }
                    panel.setDigit(remaining)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                finish(false)
            }
        }
    }
}

private final class CountdownPanel: NSPanel {
    private let digitLabel: NSTextField
    private let hintLabel: NSTextField
    private let cancelButton: NSButton
    var onCancel: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }

    init() {
        digitLabel = NSTextField(labelWithString: "")
        digitLabel.isEditable = false
        digitLabel.drawsBackground = false
        digitLabel.isBezeled = false
        digitLabel.textColor = .white
        digitLabel.font = NSFont.boldSystemFont(ofSize: 96)
        digitLabel.alignment = .center

        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        // Escape backs out whenever the panel is key.
        cancelButton.keyEquivalent = "\u{1b}"

        hintLabel = NSTextField(labelWithString: "esc or ⌘⇧. to cancel")
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        hintLabel.alignment = .center

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.72)
        hasShadow = true
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        guard let contentView = contentView else { return }

        let stack = NSStackView(views: [digitLabel, cancelButton, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -8),
        ])
    }

    /// Place the panel in the middle of the screen that is about to be recorded,
    /// rather than always on the main one.
    func center(on screen: NSScreen?) {
        guard let screen = screen else { return }
        setFrameOrigin(NSPoint(
            x: screen.frame.midX - frame.width / 2,
            y: screen.frame.midY - frame.height / 2
        ))
    }

    func setDigit(_ n: Int) {
        digitLabel.stringValue = "\(n)"
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}
