import AppKit

@MainActor
enum CountdownOverlay {
    /// Displays a floating countdown panel. Returns true if the user cancelled, false if it ran to completion.
    static func run(seconds: Int) async -> Bool {
        let panel = CountdownPanel()
        panel.orderFrontRegardless()
        panel.makeKey()

        return await withCheckedContinuation { continuation in
            var resolved = false
            @MainActor
            func finish(_ cancelled: Bool) {
                guard !resolved else { return }
                resolved = true
                panel.orderOut(nil)
                continuation.resume(returning: cancelled)
            }

            panel.onCancel = { finish(true) }

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
    private let cancelButton: NSButton
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    init() {
        digitLabel = NSTextField(labelWithString: "")
        digitLabel.isEditable = false
        digitLabel.drawsBackground = false
        digitLabel.isBezeled = false
        digitLabel.textColor = .white
        digitLabel.font = NSFont.boldSystemFont(ofSize: 110)
        digitLabel.alignment = .center

        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
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

        let stack = NSStackView(views: [digitLabel, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -8),
        ])

        if let screen = NSScreen.main {
            let origin = NSPoint(
                x: screen.frame.midX - frame.width / 2,
                y: screen.frame.midY - frame.height / 2
            )
            setFrameOrigin(origin)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    func setDigit(_ n: Int) {
        digitLabel.stringValue = "\(n)"
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}
