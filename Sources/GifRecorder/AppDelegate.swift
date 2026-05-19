import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, FrameSink {
    private var mainWindow: NSWindow?
    private let regionSelector = RegionSelector()
    private struct RecordingSession {
        let recorder: ScreenRecorder
        let encoder: FrameEncoder
        let controlBar: ControlBarController
        let outputURL: URL
    }

    private var activeSession: RecordingSession?
    private var statusItem: StatusItemController?
    private var stopHotkey: GlobalHotkey?
    private var isRecording: Bool { activeSession != nil }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        installStatusItem()
        installGlobalHotkey()
        showMainWindow()
    }

    private func installGlobalHotkey() {
        // Cmd+Shift+. — only meaningful while a recording is in progress.
        stopHotkey = GlobalHotkey(
            keyCode: kVK_ANSI_Period,
            modifiers: cmdKey | shiftKey
        ) { [weak self] in
            guard let self = self, self.isRecording else { return }
            Task { await self.stopRecording(reason: .finish) }
        }
    }

    private func installStatusItem() {
        let item = StatusItemController()
        item.onShowMainWindow = { [weak self] in
            self?.mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        item.onStop = { [weak self] in
            guard let self = self, self.isRecording else { return }
            Task { await self.stopRecording(reason: .finish) }
        }
        item.onCancel = { [weak self] in
            guard let self = self, self.isRecording else { return }
            Task { await self.stopRecording(reason: .discard) }
        }
        item.onStartRecording = { [weak self] mode in
            guard let self = self, !self.isRecording else { return }
            // Use the chosen mode for this recording without changing the
            // user's saved default. Lets people set Region as their default
            // and still occasionally fire a Full-screen recording from the menu.
            self.beginCaptureFlow(sessionMode: mode)
        }
        item.onRevealLast = {
            guard let url = Settings.shared.lastRecordingURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        item.onCopyLast = {
            guard let url = Settings.shared.lastRecordingURL else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            (url as NSURL).write(to: pb)
            guard url.pathExtension.lowercased() == "gif" else { return }
            Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return }
                await MainActor.run {
                    pb.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
                }
            }
        }
        self.statusItem = item
    }

    // Important: return `false`. We hide the launcher with `orderOut` during
    // recording, and AppKit treats that as "the last window has closed."
    // If we said `true`, the app would terminate itself the moment the user
    // hit Record. The app has a persistent status item — quit is Cmd+Q or
    // the menu bar's Quit item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Main window

    private func showMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GIF Recorder"
        window.center()
        // .moveToActiveSpace: when the user activates the app from any Space,
        // the launcher follows them rather than yanking them to its Space.
        // Lets you record sections of different workspaces without losing context.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = MainView(start: { [weak self] in self?.beginCaptureFlow() })
        window.makeKeyAndOrderFront(nil)
        self.mainWindow = window
    }

    private func buildMenu() {
        let main = NSMenu()
        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About GIF Recorder", action: nil, keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        main.addItem(editMenuItem)

        NSApp.mainMenu = main
    }

    // MARK: - Capture flow

    private func beginCaptureFlow(sessionMode: CaptureMode? = nil) {
        mainWindow?.orderOut(nil)
        let mode = sessionMode ?? Settings.shared.captureMode
        switch mode {
        case .region:
            regionSelector.begin { [weak self] region in
                guard let self = self else { return }
                guard let region = region else {
                    self.mainWindow?.makeKeyAndOrderFront(nil)
                    return
                }
                Task { await self.startRecording(source: .region(region)) }
            }

        case .display:
            Task { @MainActor in
                guard let display = await SourcePicker.pickDisplay() else {
                    self.mainWindow?.makeKeyAndOrderFront(nil)
                    return
                }
                await self.startRecording(source: .display(display))
            }

        case .window:
            Task { @MainActor in
                guard let window = await SourcePicker.pickWindow() else {
                    self.mainWindow?.makeKeyAndOrderFront(nil)
                    return
                }
                await self.startRecording(source: .window(window))
            }
        }
    }

    private func startRecording(source: CaptureSource) async {
        let settings = Settings.shared

        if settings.startDelay > 0 {
            let cancelled = await CountdownOverlay.run(seconds: settings.startDelay)
            if cancelled {
                mainWindow?.makeKeyAndOrderFront(nil)
                return
            }
        }

        // Prepare encoder.
        let outputURL: URL
        let encoder: FrameEncoder
        do {
            switch settings.outputFormat {
            case .gif:
                let folder = settings.saveFolder
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                outputURL = folder.appendingPathComponent(settings.defaultFilename(extension: "gif"))
                if settings.gifskiEnabled {
                    encoder = try GifskiEncoder(outputURL: outputURL, framerate: settings.framerate, quality: settings.gifskiQuality)
                } else {
                    encoder = try ImageIOGifEncoder(outputURL: outputURL, framerate: settings.framerate)
                }
            case .mp4:
                let folder = settings.saveFolder
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                outputURL = folder.appendingPathComponent(settings.defaultFilename(extension: "mp4"))
                encoder = try MP4Encoder(
                    outputURL: outputURL,
                    framerate: settings.framerate,
                    pixelSize: source.pixelSize
                )
            }
        } catch {
            presentError(error)
            mainWindow?.makeKeyAndOrderFront(nil)
            return
        }
        // Show floating HUD.
        let bar = ControlBarController()
        bar.onStop = { [weak self] in Task { await self?.stopRecording(reason: .finish) } }
        bar.onCancel = { [weak self] in Task { await self?.stopRecording(reason: .discard) } }
        bar.show()

        // Start capture. Exclude our own control bar so it doesn't appear in the recording.
        var excluded: [CGWindowID] = []
        if let id = bar.windowID { excluded.append(id) }
        let recorder = ScreenRecorder(
            source: source,
            framerate: settings.framerate,
            captureCursor: settings.captureCursor,
            excludeWindowIDs: excluded,
            sink: self
        )
        do {
            try await recorder.start()
            self.activeSession = RecordingSession(
                recorder: recorder,
                encoder: encoder,
                controlBar: bar,
                outputURL: outputURL
            )
            statusItem?.setState(.recording)
        } catch {
            presentError(error)
            bar.hide()
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func stopRecording(reason: StopReason) async {
        guard let session = activeSession else { return }
        activeSession = nil
        await session.recorder.stop()
        session.controlBar.hide()
        statusItem?.setState(.idle)

        switch reason {
        case .discard:
            session.encoder.cancel()
            mainWindow?.makeKeyAndOrderFront(nil)
        case .finish:
            do {
                let url = try await session.encoder.finish()
                // No save dialog — the file is already on disk in the save folder
                // with a unique timestamped name. Copy to clipboard, remember it
                // as the "last recording" so the user can rename later if they want.
                if Settings.shared.copyToClipboard {
                    copyToClipboard(url)
                }
                Settings.shared.lastRecordingURL = url
                NotificationCenter.default.post(name: .lastRecordingChanged, object: nil)
                if Settings.shared.revealInFinder {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                // Optional toast so the user knows it landed somewhere.
                if Settings.shared.showNotification {
                    Toast.show("Saved — paste with ⌘V", filename: url.lastPathComponent)
                }
            } catch {
                presentError(error)
            }
        }
    }

    // MARK: - FrameSink

    nonisolated func sinkDidCapture(frame: CapturedFrame) {
        Task { @MainActor in
            do { try self.activeSession?.encoder.append(frame) } catch { self.presentError(error) }
        }
    }

    nonisolated func sinkDidFail(with error: Error) {
        Task { @MainActor in
            self.presentError(error)
            await self.stopRecording(reason: .discard)
        }
    }

    // MARK: - Save / countdown / errors

    /// Put the recording on the system clipboard. Writes both the file URL
    /// (for Finder/Mail) and the raw bytes under the format's UTI (for chat
    /// apps that paste image/video data directly).
    private func copyToClipboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()

        // File URL — works for Finder, Mail, and anything that accepts a path.
        (url as NSURL).write(to: pb)

        // Raw data with UTI — works for Slack, Discord, iMessage, browsers.
        // GIF data is read off the main actor to avoid blocking the UI on large files.
        guard Settings.shared.outputFormat == .gif else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let data = try? Data(contentsOf: url) else { return }
            await self?.writeGifDataToClipboard(data)
        }
    }

    @MainActor
    private func writeGifDataToClipboard(_ data: Data) {
        NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
    }

    private func presentError(_ error: Error) {
        let msg = "[GifRecorder] ERROR: \(error.localizedDescription)\n\(error)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        let alert = NSAlert(error: error)
        alert.runModal()
    }

}

extension Notification.Name {
    /// Posted on the main thread whenever `Settings.lastRecordingURL` changes.
    /// The launcher window listens for this to refresh its "Last recording" row.
    static let lastRecordingChanged = Notification.Name("GifRecorder.lastRecordingChanged")
}
