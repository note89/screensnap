import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, FrameSink {
    private var mainWindow: NSWindow?
    private let regionSelector = RegionSelector()
    private struct RecordingSession {
        let recorder: ScreenRecorder
        let encoder: FrameEncoder
        let controlBar: ControlBarController
    }

    private var activeSession: RecordingSession?
    private var statusItem: StatusItemController?
    private var startHotkey: GlobalHotkey?
    private var stopHotkey: GlobalHotkey?
    private var isRecording: Bool { activeSession != nil }

    /// True while `encoder.finish()` runs after a recording stops. For gifski that
    /// is a process over thousands of PNGs and can take tens of seconds; the HUD
    /// and menu bar show a "saving" state for the duration instead of going idle.
    private var isFinishing = false

    /// Set by `applicationShouldTerminate` when the user quits during a recording
    /// or while one is being saved: `stopRecording` replies once the file is safe.
    private var replyToTerminateWhenIdle = false

    /// True from the moment a capture flow begins until it either starts recording
    /// or backs out. Region selection, the source picker and the countdown all run
    /// before `activeSession` exists, so without this a second Record click —
    /// easy to land during a three second countdown — starts a parallel flow that
    /// fights the first one over the HUD and the output file.
    private var isStartingCapture = false
    private var isBusy: Bool { isRecording || isStartingCapture || isFinishing }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pin the launch-time permission state before anything can change it.
        _ = Permissions.hadScreenRecordingAtLaunch
        buildMenu()
        installStatusItem()
        let hotkeys = installGlobalHotkeys()
        showMainWindow(hotkeysAvailable: hotkeys)
        if !hotkeys {
            // Carbon refuses a combination another app already owns. Say so once,
            // rather than letting the documented shortcut silently do nothing.
            Toast.show("Keyboard shortcuts unavailable", detail: "⌘⇧6 / ⌘⇧. are taken by another app.", duration: 4)
        }
    }

    /// Returns whether both shortcuts registered.
    private func installGlobalHotkeys() -> Bool {
        // Cmd+Shift+6 — start a recording in the default capture mode from any
        // app. Sits next to Apple's own ⌘⇧5 capture UI.
        startHotkey = GlobalHotkey(
            keyCode: kVK_ANSI_6,
            modifiers: cmdKey | shiftKey
        ) { [weak self] in
            Task { @MainActor in self?.beginCaptureFlow() }
        }

        // Cmd+Shift+. — backs out of the countdown before a recording has started,
        // and finishes the recording once it has. The countdown panel is
        // non-activating and rarely holds the keyboard, so this is the only way to
        // abort it without reaching for the mouse.
        stopHotkey = GlobalHotkey(
            keyCode: kVK_ANSI_Period,
            modifiers: cmdKey | shiftKey
        ) { [weak self] in
            Task { @MainActor in
                if CountdownOverlay.cancelIfRunning() { return }
                guard let self = self, self.isRecording else { return }
                await self.stopRecording(reason: .finish)
            }
        }

        let ok = startHotkey != nil && stopHotkey != nil
        if !ok {
            FileHandle.standardError.write(Data("[GifRecorder] global hotkey registration failed\n".utf8))
        }
        return ok
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
            // Use the chosen mode for this recording without changing the user's
            // saved default. Lets people set Region as their default and still
            // occasionally fire a Full-screen recording from the menu.
            // `beginCaptureFlow` does the busy check.
            self?.beginCaptureFlow(sessionMode: mode)
        }
        item.onRevealLast = {
            guard let url = Settings.shared.lastRecordingURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        item.onCopyLast = {
            Clipboard.copyWithFeedback(Settings.shared.lastRecordingURL)
        }
        self.statusItem = item
    }

    // Important: return `false`. We hide the launcher with `orderOut` during
    // recording, and AppKit treats that as "the last window has closed."
    // If we said `true`, the app would terminate itself the moment the user
    // hit Record. The app has a persistent status item — quit is Cmd+Q or
    // the menu bar's Quit item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon after the launcher was closed used to do nothing:
    /// there is no Window menu, and the only way back was the menu bar item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !isBusy {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Quitting mid-recording used to discard it without a word — both Quit items
    /// were wired straight to `NSApplication.terminate`. Offer to finish first,
    /// and if a save is already in flight, let it land before exiting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isFinishing {
            replyToTerminateWhenIdle = true
            return .terminateLater
        }
        guard isRecording else {
            // A countdown or picker that has not produced a frame yet has nothing
            // on disk worth keeping.
            CountdownOverlay.cancelIfRunning()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "A recording is in progress"
        alert.informativeText = "Finish and save it, or discard it and quit?"
        alert.addButton(withTitle: "Finish and Save")
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Cancel")
        let reason: StopReason
        switch alert.runModal() {
        case .alertFirstButtonReturn: reason = .finish
        case .alertSecondButtonReturn: reason = .discard
        default: return .terminateCancel
        }
        replyToTerminateWhenIdle = true
        Task { await stopRecording(reason: reason) }
        return .terminateLater
    }

    // MARK: - Main window

    private func showMainWindow(hotkeysAvailable: Bool) {
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
        window.contentView = MainView(hotkeysAvailable: hotkeysAvailable, start: { [weak self] in self?.beginCaptureFlow() })
        window.makeKeyAndOrderFront(nil)
        self.mainWindow = window
    }

    private func buildMenu() {
        let main = NSMenu()
        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About GIF Recorder",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
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
        guard !isBusy else { return }
        // Gate permission here rather than in the launcher: the menu bar's
        // "Record …" items come straight through this function, and without a check
        // they failed invisibly — SourcePicker swallows the TCC error and returns
        // nil, so the user saw the launcher blink and nothing else.
        guard ensureScreenRecordingPermission() else { return }
        isStartingCapture = true
        mainWindow?.orderOut(nil)
        let mode = sessionMode ?? Settings.shared.captureMode
        switch mode {
        case .region:
            regionSelector.begin { [weak self] region in
                guard let self = self else { return }
                guard let region = region else {
                    self.abandonCaptureFlow()
                    return
                }
                Task { await self.startRecording(source: .region(region)) }
            }

        case .display:
            Task { @MainActor in
                guard let display = await SourcePicker.pickDisplay() else {
                    self.abandonCaptureFlow()
                    return
                }
                await self.startRecording(source: .display(display))
            }

        case .window:
            Task { @MainActor in
                guard let window = await SourcePicker.pickWindow() else {
                    self.abandonCaptureFlow()
                    return
                }
                await self.startRecording(source: .window(window))
            }
        }
    }

    /// Back out of a capture flow that never reached `startRecording`.
    private func abandonCaptureFlow() {
        isStartingCapture = false
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func startRecording(source: CaptureSource) async {
        // However this returns, the flow is no longer "starting": it either becomes
        // the active session or backs out.
        defer { isStartingCapture = false }

        let settings = Settings.shared
        let outputSize = source.outputSize(downsample: settings.downsample)

        // Build the encoder *before* the countdown. A bad save folder or a missing
        // gifski then surfaces straight away instead of after the user has watched
        // 3-2-1, and the digits sit as close to the real start of capture as we can
        // get them.
        let encoder: FrameEncoder
        do {
            let folder = settings.saveFolder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            switch settings.outputFormat {
            case .gif:
                let url = try settings.availableURL(in: folder, extension: "gif")
                if settings.gifskiEnabled {
                    encoder = try GifskiEncoder(outputURL: url, framerate: settings.framerate, quality: settings.gifskiQuality)
                } else {
                    encoder = try ImageIOGifEncoder(outputURL: url, framerate: settings.framerate)
                }
            case .mp4:
                let url = try settings.availableURL(in: folder, extension: "mp4")
                encoder = try MP4Encoder(
                    outputURL: url,
                    framerate: settings.framerate,
                    pixelSize: outputSize
                )
            }
        } catch {
            presentError(error)
            mainWindow?.makeKeyAndOrderFront(nil)
            return
        }

        if settings.startDelay > 0 {
            let cancelled = await CountdownOverlay.run(seconds: settings.startDelay, on: source.screen)
            if cancelled {
                // The encoder has already opened its output file; don't leave it behind.
                encoder.cancel()
                mainWindow?.makeKeyAndOrderFront(nil)
                return
            }
        }

        // Show the floating HUD on the display being recorded.
        let bar = ControlBarController(screen: source.screen)
        bar.onStop = { [weak self] in Task { await self?.stopRecording(reason: .finish) } }
        bar.onCancel = { [weak self] in Task { await self?.stopRecording(reason: .discard) } }
        bar.show()

        // Start capture. Exclude our own control bar so it doesn't appear in the recording.
        var excluded: [CGWindowID] = []
        if let id = bar.windowID { excluded.append(id) }
        let recorder = ScreenRecorder(
            source: source,
            framerate: settings.framerate,
            downsample: settings.downsample,
            captureCursor: settings.captureCursor,
            excludeWindowIDs: excluded,
            sink: self
        )
        do {
            try await recorder.start()
            // `start()` awaits a shareable-content fetch and `startCapture`, so only
            // now is the elapsed clock honest.
            bar.markCaptureStarted()
            self.activeSession = RecordingSession(
                recorder: recorder,
                encoder: encoder,
                controlBar: bar
            )
            statusItem?.setState(.recording)
        } catch {
            encoder.cancel()
            bar.hide()
            presentError(error)
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func stopRecording(reason: StopReason) async {
        guard let session = activeSession else { return }
        activeSession = nil
        await session.recorder.stop()

        switch reason {
        case .discard:
            session.controlBar.hide()
            statusItem?.setState(.idle)
            session.encoder.cancel()
            mainWindow?.makeKeyAndOrderFront(nil)

        case .finish:
            // Keep the HUD and the menu bar dot up, in a distinct "saving" state,
            // until the file is really on disk. Tearing them down first left the
            // app looking idle for however long the encoder took — for gifski,
            // tens of seconds — with no hint anything was still happening.
            isFinishing = true
            session.controlBar.showSaving()
            statusItem?.setState(.saving)
            let saved: Result<URL, Error>
            do {
                saved = .success(try await session.encoder.finish())
            } catch {
                saved = .failure(error)
            }
            isFinishing = false
            session.controlBar.hide()
            statusItem?.setState(.idle)

            switch saved {
            case .success(let url):
                // No save dialog — the file is already on disk in the save folder
                // with a unique timestamped name. Copy to clipboard, remember it
                // as the "last recording" so the user can rename later if they want.
                Settings.shared.lastRecordingURL = url
                NotificationCenter.default.post(name: .lastRecordingChanged, object: nil)
                if Settings.shared.revealInFinder {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                var copied = false
                if Settings.shared.copyToClipboard {
                    copied = (try? await Clipboard.copy(url)) != nil
                }
                // Optional toast so the user knows it landed somewhere. Only promise
                // a paste when we actually put something on the pasteboard.
                if Settings.shared.showNotification {
                    Toast.show(copied ? "Saved — paste with ⌘V" : "Saved", detail: url.lastPathComponent, reveals: url)
                }
            case .failure(let error):
                presentError(error)
            }
        }

        if replyToTerminateWhenIdle {
            replyToTerminateWhenIdle = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    // MARK: - FrameSink

    nonisolated func sinkDidCapture(frame: CapturedFrame) {
        Task { @MainActor in
            guard let session = self.activeSession else { return }
            do {
                try session.encoder.append(frame)
            } catch {
                // Tear the session down *before* reporting. `presentError` runs a
                // modal, and capture keeps feeding us frames while it is up — the
                // old order stacked one alert per dropped frame. `stopRecording`
                // clears `activeSession` synchronously, so the frames already in
                // flight fall out at the guard above.
                await self.failRecording(with: error)
            }
        }
    }

    nonisolated func sinkDidFail(with error: Error) {
        Task { @MainActor in
            await self.failRecording(with: error)
        }
    }

    private func failRecording(with error: Error) async {
        await stopRecording(reason: .discard)
        presentError(error)
    }

    // MARK: - Save / countdown / errors

    /// Confirm we can actually capture before taking over the screen. TCC will not
    /// grant a live process, so a fresh grant needs a relaunch — say so plainly
    /// rather than letting the next recording fail with an opaque SCStream error.
    private func ensureScreenRecordingPermission() -> Bool {
        if Permissions.canCaptureNow { return true }

        if !Permissions.hasScreenRecording {
            // The first call raises the system prompt; later ones are no-ops once
            // the user has chosen.
            Permissions.requestScreenRecording()
        }

        let alert = NSAlert()
        if Permissions.hasScreenRecording {
            // Granted, but after launch — so not to this process.
            alert.messageText = "Quit and reopen to start recording"
            alert.informativeText = "macOS applies a new Screen Recording grant only to a fresh launch of \(Self.displayName)."
            if Permissions.canRelaunch {
                alert.addButton(withTitle: "Relaunch Now")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    Permissions.relaunch()
                }
            } else {
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        } else {
            alert.messageText = "Screen Recording permission required"
            alert.informativeText = "Turn on \(Self.displayName) in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.openScreenRecordingSettings()
            }
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        return false
    }

    /// The name System Settings lists us under, so permission copy matches what the
    /// user is actually looking for in that list.
    nonisolated static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "GIF Recorder"
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
