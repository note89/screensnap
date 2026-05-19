import AppKit

/// Tiny floating HUD shown while recording. One stop button + an elapsed timer.
final class ControlBarController: NSWindowController {
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let stopButton = NSButton(title: "Finish", target: nil, action: nil)
    private let cancelButton = NSButton(title: "✕", target: nil, action: nil)
    private var timer: Timer?
    private var startedAt: Date?

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        // .statusBar keeps the bar above app windows AND on top across Spaces.
        // .floating alone gets stranded when you switch desktops.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.hasShadow = true
        window.backgroundColor = NSColor.windowBackgroundColor

        self.init(window: window)
        configureLayout()
        positionInTopRight()
    }

    private func configureLayout() {
        guard let contentView = window?.contentView else { return }

        let dot = NSView(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5

        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timerLabel.alignment = .left

        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.keyEquivalent = "\r"

        cancelButton.bezelStyle = .roundRect
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        for v in [dot, timerLabel, stopButton, cancelButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            timerLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            timerLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            stopButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            stopButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -6),
            cancelButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func positionInTopRight() {
        guard let window = window, let screen = NSScreen.main else { return }
        let margin: CGFloat = 24
        let frame = NSRect(
            x: screen.visibleFrame.maxX - window.frame.width - margin,
            y: screen.visibleFrame.maxY - window.frame.height - margin,
            width: window.frame.width,
            height: window.frame.height
        )
        window.setFrame(frame, display: false)
    }

    func show() {
        startedAt = Date()
        showWindow(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
    }

    private func tick() {
        guard let started = startedAt else { return }
        let elapsed = Int(Date().timeIntervalSince(started))
        timerLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    @objc private func stopClicked() { onStop?() }
    @objc private func cancelClicked() { onCancel?() }

    /// CoreGraphics window ID, so SCStream can exclude this HUD from the recording.
    var windowID: CGWindowID? {
        guard let nsWindow = window else { return nil }
        return CGWindowID(nsWindow.windowNumber)
    }
}
