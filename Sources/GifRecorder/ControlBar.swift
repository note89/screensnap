import AppKit

/// Tiny floating HUD shown while recording. One stop button + an elapsed timer.
/// After Finish it stays up in a "Saving…" state until the encoder is done.
final class ControlBarController: NSWindowController {
    private let dot = NSView(frame: .zero)
    private let spinner = NSProgressIndicator()
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let stopButton = NSButton(title: "Finish", target: nil, action: nil)
    private let cancelButton = NSButton(title: "✕", target: nil, action: nil)
    private var timer: Timer?
    private var startedAt: Date?

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    /// `screen` is the display being recorded, so the HUD lands where the user is
    /// looking instead of always on the main display.
    convenience init(screen: NSScreen? = nil) {
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
        positionInTopRight(on: screen ?? NSScreen.main)
    }

    private func configureLayout() {
        guard let contentView = window?.contentView else { return }

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true

        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timerLabel.alignment = .left

        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.keyEquivalent = "\r"

        cancelButton.bezelStyle = .roundRect
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.toolTip = "Discard this recording"
        stopButton.toolTip = "Finish and save (⌘⇧.)"

        for v in [dot, spinner, timerLabel, stopButton, cancelButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            // The spinner takes the dot's place while saving.
            spinner.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            timerLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            timerLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            stopButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            stopButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -6),
            cancelButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func positionInTopRight(on screen: NSScreen?) {
        guard let window = window, let screen = screen else { return }
        let margin: CGFloat = 24
        let frame = NSRect(
            x: screen.visibleFrame.maxX - window.frame.width - margin,
            y: screen.visibleFrame.maxY - window.frame.height - margin,
            width: window.frame.width,
            height: window.frame.height
        )
        window.setFrame(frame, display: false)
    }

    /// Put the HUD on screen without taking focus. `showWindow` makes the window
    /// key, which deactivates the app the user is about to record — visible in the
    /// first frames as a dimmed title bar and a stopped text caret.
    func show() {
        startedAt = Date()
        window?.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    /// Reset the clock to the moment capture actually began. The HUD has to go up
    /// first so its window ID can be excluded from the stream, and starting the
    /// stream then awaits a shareable-content fetch — without this the elapsed time
    /// runs permanently ahead of the recording.
    func markCaptureStarted() {
        startedAt = Date()
        tick()
    }

    /// Swap the recording controls for a "Saving…" indicator. The recording has
    /// stopped, so the elapsed clock freezes and both buttons go away — there is
    /// nothing left to finish or discard.
    func showSaving() {
        timer?.invalidate()
        timer = nil
        timerLabel.stringValue = "Saving…"
        dot.isHidden = true
        stopButton.isHidden = true
        cancelButton.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        spinner.stopAnimation(nil)
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
