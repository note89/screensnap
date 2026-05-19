import AppKit

/// Always-visible system menu bar item. Lives in `NSStatusBar.system` so it
/// shows on every screen and every Space, regardless of the recording
/// region or which app is frontmost.
///
/// Two states:
///   .idle      — small camera icon, click to open the launcher window.
///   .recording — pulsing red dot, click reveals Stop / Cancel.
@MainActor
final class StatusItemController: NSObject {
    enum State { case idle, recording }

    private let item: NSStatusItem
    private let menu = NSMenu()
    private var pulseTimer: Timer?
    private var pulseOn = true

    private let recordRegionItem  = NSMenuItem()
    private let recordDisplayItem = NSMenuItem()
    private let recordWindowItem  = NSMenuItem()
    private let stopItem          = NSMenuItem()
    private let cancelItem        = NSMenuItem()
    private let revealLastItem    = NSMenuItem()
    private let copyLastItem      = NSMenuItem()
    private let lastFilenameItem  = NSMenuItem()

    var onShowMainWindow: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Start a recording directly without going through the launcher window.
    /// The argument is the capture mode to use; the launcher's persisted
    /// settings (framerate, format, etc.) still apply.
    var onStartRecording: ((CaptureMode) -> Void)?
    var onRevealLast: (() -> Void)?
    var onCopyLast: (() -> Void)?

    override init() {
        // Variable length so the icon sizes itself; we draw a custom image.
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configure()
        setState(.idle)
    }

    private func configure() {
        // Direct-record items — skip the launcher window entirely. These are
        // shown when idle and hidden when a recording is in progress.
        recordRegionItem.title = "Record area"
        recordRegionItem.action = #selector(recordRegion)
        recordRegionItem.target = self

        recordDisplayItem.title = "Record full screen"
        recordDisplayItem.action = #selector(recordDisplay)
        recordDisplayItem.target = self

        recordWindowItem.title = "Record window…"
        recordWindowItem.action = #selector(recordWindow)
        recordWindowItem.target = self

        // Stop = finish & save. Matches the global Cmd+Shift+. hotkey so
        // users see one consistent shortcut whether they're in the menu or not.
        stopItem.title = "Finish recording"
        stopItem.action = #selector(stop)
        stopItem.keyEquivalent = "."
        stopItem.keyEquivalentModifierMask = [.command, .shift]
        stopItem.target = self

        // Cancel = throw the recording away. No menu shortcut — clicking is
        // a deliberate destructive action, no keyboard shortcut needed.
        cancelItem.title = "Cancel recording (discard)"
        cancelItem.action = #selector(cancel)
        cancelItem.target = self

        // Disabled placeholder showing the filename of the last recording.
        lastFilenameItem.title = "—"
        lastFilenameItem.isEnabled = false

        // Quick-access to the most recent file. Disabled when there isn't one.
        revealLastItem.title = "Show last recording in Finder"
        revealLastItem.action = #selector(revealLast)
        revealLastItem.target = self

        copyLastItem.title = "Copy last recording"
        copyLastItem.action = #selector(copyLast)
        copyLastItem.target = self

        let openItem = NSMenuItem(title: "Settings…", action: #selector(openMain), keyEquivalent: ",")
        openItem.target = self
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        menu.addItem(recordRegionItem)
        menu.addItem(recordDisplayItem)
        menu.addItem(recordWindowItem)
        menu.addItem(.separator())
        menu.addItem(stopItem)
        menu.addItem(cancelItem)
        menu.addItem(.separator())
        menu.addItem(lastFilenameItem)
        menu.addItem(revealLastItem)
        menu.addItem(copyLastItem)
        menu.addItem(.separator())
        menu.addItem(openItem)
        menu.addItem(quitItem)
        item.menu = menu

        // Refresh the "last recording" filename each time the menu opens,
        // so we always show the current file rather than a stale name.
        menu.delegate = self
    }

    fileprivate func updateLastRecordingRow() {
        let last = Settings.shared.lastRecordingURL
        lastFilenameItem.title   = last.map { "Last: \($0.lastPathComponent)" } ?? "No recording yet"
        revealLastItem.isEnabled = last != nil
        copyLastItem.isEnabled   = last != nil
    }

    func setState(_ state: State) {
        stopItem.isHidden   = (state == .idle)
        cancelItem.isHidden = (state == .idle)
        recordRegionItem.isHidden  = (state == .recording)
        recordDisplayItem.isHidden = (state == .recording)
        recordWindowItem.isHidden  = (state == .recording)

        switch state {
        case .idle:
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulseOn = true
            renderIcon(recording: false, on: true)
        case .recording:
            // Pulse the red dot at ~1Hz so it's eye-catching from the menu bar.
            pulseTimer?.invalidate()
            pulseOn = true
            renderIcon(recording: true, on: pulseOn)
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor [self] in
                    self.pulseOn.toggle()
                    self.renderIcon(recording: true, on: self.pulseOn)
                }
            }
        }
    }

    private func renderIcon(recording: Bool, on: Bool) {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            if recording {
                // Solid red circle (pulses by alpha).
                let color = on
                    ? NSColor.systemRed
                    : NSColor.systemRed.withAlphaComponent(0.4)
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            } else {
                // Outlined camera-ish circle for idle.
                NSColor.labelColor.setStroke()
                let p = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
                p.lineWidth = 1.5
                p.stroke()
                NSColor.labelColor.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 7, dy: 7)).fill()
            }
            return true
        }
        // For non-recording state, treat as template so the system tints it
        // correctly in dark/light menu bars.
        img.isTemplate = !recording
        item.button?.image = img
        item.button?.toolTip = recording ? "Recording — click to finish" : "GIF Recorder"
    }

    @objc private func openMain() { onShowMainWindow?() }
    @objc private func stop() { onStop?() }
    @objc private func cancel() { onCancel?() }
    @objc private func recordRegion() { onStartRecording?(.region) }
    @objc private func recordDisplay() { onStartRecording?(.display) }
    @objc private func recordWindow() { onStartRecording?(.window) }
    @objc private func revealLast() { onRevealLast?() }
    @objc private func copyLast() { onCopyLast?() }
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateLastRecordingRow()
    }
}
