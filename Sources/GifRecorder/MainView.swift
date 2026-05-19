import AppKit

/// Plain AppKit launcher view. Avoids SwiftUI to keep the binary small and
/// the dependency surface tight — peek's UI is essentially a button + a
/// few preference toggles, so we don't need declarative layout here.
final class MainView: NSView {
    private let onStart: () -> Void
    private let formatPicker = NSPopUpButton()
    private let modePicker = NSPopUpButton()
    private let permissionStatus = NSTextField(labelWithString: "")
    private let openSettingsButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let requestPermissionButton = NSButton(title: "Request permission", target: nil, action: nil)
    private var permissionTimer: Timer?
    private let framerateField = NSTextField()
    private let downsampleField = NSTextField()
    private let delayField = NSTextField()
    private let cursorCheckbox = NSButton(checkboxWithTitle: "Capture cursor", target: nil, action: nil)
    private let gifskiCheckbox = NSButton(checkboxWithTitle: "Use gifski (high quality)", target: nil, action: nil)
    private let revealCheckbox = NSButton(checkboxWithTitle: "Reveal in Finder after save", target: nil, action: nil)
    private let clipboardCheckbox = NSButton(checkboxWithTitle: "Copy to clipboard after recording", target: nil, action: nil)
    private let lastRecordingLabel = NSTextField(labelWithString: "No recording yet")
    private let renameButton = NSButton(title: "Rename…", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let copyAgainButton = NSButton(title: "Copy again", target: nil, action: nil)

    init(start: @escaping () -> Void) {
        self.onStart = start
        super.init(frame: .zero)
        build()
        loadFromSettings()
        refreshPermissionStatus()
        refreshLastRecording()
        // Poll only while we're still in the "not granted" state. Each
        // CGPreflightScreenCaptureAccess goes through a TCC IPC roundtrip,
        // so this used to spam the system log every second forever.
        startPollingIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshLastRecording),
            name: .lastRecordingChanged,
            object: nil
        )
    }

    deinit {
        permissionTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let title = NSTextField(labelWithString: "Choose a capture mode, then click Record.")
        title.font = .systemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor

        let gifItem = NSMenuItem(title: "GIF", action: nil, keyEquivalent: "")
        gifItem.representedObject = OutputFormat.gif
        let mp4Item = NSMenuItem(title: "MP4 (H.264)", action: nil, keyEquivalent: "")
        mp4Item.representedObject = OutputFormat.mp4
        formatPicker.menu?.addItem(gifItem)
        formatPicker.menu?.addItem(mp4Item)
        formatPicker.target = self
        formatPicker.action = #selector(saveSettings)

        let regionItem = NSMenuItem(title: "Region (drag to select)", action: nil, keyEquivalent: "")
        regionItem.representedObject = CaptureMode.region
        let displayItem = NSMenuItem(title: "Full screen", action: nil, keyEquivalent: "")
        displayItem.representedObject = CaptureMode.display
        let windowItem = NSMenuItem(title: "Window…", action: nil, keyEquivalent: "")
        windowItem.representedObject = CaptureMode.window
        modePicker.menu?.addItem(regionItem)
        modePicker.menu?.addItem(displayItem)
        modePicker.menu?.addItem(windowItem)
        modePicker.target = self
        modePicker.action = #selector(saveSettings)

        framerateField.placeholderString = "fps"
        framerateField.target = self
        framerateField.action = #selector(saveSettings)

        downsampleField.placeholderString = "downsample"
        downsampleField.target = self
        downsampleField.action = #selector(saveSettings)

        delayField.placeholderString = "delay (s)"
        delayField.target = self
        delayField.action = #selector(saveSettings)

        cursorCheckbox.target = self
        cursorCheckbox.action = #selector(saveSettings)
        gifskiCheckbox.target = self
        gifskiCheckbox.action = #selector(saveSettings)
        revealCheckbox.target = self
        revealCheckbox.action = #selector(saveSettings)
        clipboardCheckbox.target = self
        clipboardCheckbox.action = #selector(saveSettings)

        let recordButton = NSButton(title: "Record", target: self, action: #selector(recordTapped))
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .large
        recordButton.keyEquivalent = "\r"

        // Permission row at the very top so it's the first thing the user sees.
        permissionStatus.font = .systemFont(ofSize: 12)
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettingsTapped)
        requestPermissionButton.bezelStyle = .rounded
        requestPermissionButton.target = self
        requestPermissionButton.action = #selector(requestPermissionTapped)
        let permissionRow = NSStackView(views: [permissionStatus, openSettingsButton, requestPermissionButton])
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 8

        let formRow0 = labeledRow("Capture", control: modePicker)
        let formRow1 = labeledRow("Format", control: formatPicker)
        let formRow2 = labeledRow("Framerate", control: framerateField)
        let formRow3 = labeledRow("Downsample", control: downsampleField)
        let formRow4 = labeledRow("Start delay", control: delayField)

        // "Last recording" section — shown at the bottom so it doesn't compete
        // with the Record button for attention but is easy to find when needed.
        lastRecordingLabel.font = .systemFont(ofSize: 11)
        lastRecordingLabel.textColor = .secondaryLabelColor
        lastRecordingLabel.lineBreakMode = .byTruncatingMiddle
        for btn in [renameButton, revealButton, copyAgainButton] {
            btn.bezelStyle = .rounded
            btn.controlSize = .small
        }
        renameButton.target = self
        renameButton.action = #selector(renameTapped)
        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        copyAgainButton.target = self
        copyAgainButton.action = #selector(copyAgainTapped)

        let lastButtons = NSStackView(views: [renameButton, revealButton, copyAgainButton])
        lastButtons.orientation = .horizontal
        lastButtons.spacing = 6
        let lastRow = NSStackView(views: [
            NSTextField(labelWithString: "Last recording:"),
            lastRecordingLabel,
            lastButtons,
        ])
        lastRow.orientation = .vertical
        lastRow.alignment = .leading
        lastRow.spacing = 4

        let stack = NSStackView(views: [
            permissionRow,
            NSBox.separator(),
            title, formRow0, formRow1, formRow2, formRow3, formRow4,
            cursorCheckbox, gifskiCheckbox, clipboardCheckbox, revealCheckbox,
            recordButton,
            NSBox.separator(),
            lastRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    private func labeledRow(_ label: String, control: NSView) -> NSStackView {
        let lbl = NSTextField(labelWithString: label)
        lbl.alignment = .right
        lbl.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let row = NSStackView(views: [lbl, control])
        row.orientation = .horizontal
        row.spacing = 8
        if let tf = control as? NSTextField {
            tf.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        return row
    }

    private func loadFromSettings() {
        let s = Settings.shared
        modePicker.selectItem(withRepresentedObject: s.captureMode)
        formatPicker.selectItem(withRepresentedObject: s.outputFormat)
        framerateField.integerValue = s.framerate
        downsampleField.integerValue = s.downsample
        delayField.integerValue = s.startDelay
        cursorCheckbox.state = s.captureCursor ? .on : .off
        gifskiCheckbox.state = s.gifskiEnabled ? .on : .off
        revealCheckbox.state = s.revealInFinder ? .on : .off
        clipboardCheckbox.state = s.copyToClipboard ? .on : .off
    }

    @objc private func saveSettings() {
        let s = Settings.shared
        if let mode = modePicker.selectedItem?.representedObject as? CaptureMode {
            s.captureMode = mode
        }
        if let format = formatPicker.selectedItem?.representedObject as? OutputFormat {
            s.outputFormat = format
        }
        s.framerate = framerateField.integerValue
        s.downsample = downsampleField.integerValue
        s.startDelay = delayField.integerValue
        s.captureCursor = cursorCheckbox.state == .on
        s.gifskiEnabled = gifskiCheckbox.state == .on
        s.revealInFinder = revealCheckbox.state == .on
        s.copyToClipboard = clipboardCheckbox.state == .on
    }

    @objc private func refreshLastRecording() {
        if let url = Settings.shared.lastRecordingURL {
            lastRecordingLabel.stringValue = url.lastPathComponent
            renameButton.isEnabled = true
            revealButton.isEnabled = true
            copyAgainButton.isEnabled = true
        } else {
            lastRecordingLabel.stringValue = "No recording yet"
            renameButton.isEnabled = false
            revealButton.isEnabled = false
            copyAgainButton.isEnabled = false
        }
    }

    @objc private func renameTapped() {
        guard let url = Settings.shared.lastRecordingURL else { return }
        let alert = NSAlert()
        alert.messageText = "Rename last recording"
        alert.informativeText = "Pick a name. The file extension stays the same."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = url.deletingPathExtension().lastPathComponent
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let stem = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { return }
        let newURL = url.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            Settings.shared.lastRecordingURL = newURL
            refreshLastRecording()
        } catch {
            let err = NSAlert(error: error)
            err.runModal()
        }
    }

    @objc private func revealTapped() {
        guard let url = Settings.shared.lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyAgainTapped() {
        guard let url = Settings.shared.lastRecordingURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        (url as NSURL).write(to: pb)
        guard url.pathExtension.lowercased() == "gif" else { return }
        Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return }
            await MainActor.run {
                _ = pb.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            }
        }
    }

    @objc private func recordTapped() {
        saveSettings()
        if !Permissions.hasScreenRecording {
            let alert = NSAlert()
            alert.messageText = "Screen Recording permission required"
            alert.informativeText = "Toggle GifRecorder on in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch the app."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.openScreenRecordingSettings()
            }
            return
        }
        onStart()
    }

    @objc private func openSettingsTapped() {
        Permissions.openScreenRecordingSettings()
    }

    @objc private func requestPermissionTapped() {
        // First call shows the system prompt; later calls are no-ops if the
        // user already chose. We open System Settings as a follow-up so the
        // user can find and flip the toggle.
        _ = Permissions.requestScreenRecording()
        Permissions.openScreenRecordingSettings()
    }

    private func refreshPermissionStatus() {
        let ok = Permissions.hasScreenRecording
        permissionStatus.stringValue = ok
            ? "Screen Recording: ✅ granted"
            : "Screen Recording: ❌ not granted"
        permissionStatus.textColor = ok ? .systemGreen : .systemRed
        // Hide the action buttons once we're good — keeps the launcher tidy.
        openSettingsButton.isHidden = ok
        requestPermissionButton.isHidden = ok
        if ok {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    private func startPollingIfNeeded() {
        guard permissionTimer == nil, !Permissions.hasScreenRecording else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatus()
        }
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

private extension NSPopUpButton {
    func selectItem<T: Equatable>(withRepresentedObject obj: T) {
        for item in itemArray {
            if let rep = item.representedObject as? T, rep == obj {
                select(item)
                return
            }
        }
    }
}
