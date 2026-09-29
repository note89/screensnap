import AppKit
import Carbon.HIToolbox
import Observation
import ScreenCaptureKit

struct CompressionJob: Equatable {
    /// Which entry point started it: the size limit after a recording, or the
    /// Recordings pane.
    enum Origin: Equatable {
        case sizeLimit
        case manual
    }

    let recording: Recording
    let target: CompressionTarget
    let placement: CompressionPlacement
    let origin: Origin
    var progress: Double
}

enum CompressionOutcome: Equatable {
    case done(CompressionResult)
    case failed(String)
}

/// A recording's devices and encoder as `begin` brings them up, in order. Each is
/// optional until it is up; `abandon()` releases whatever is, so every failure exit
/// tears down the same way, and a device added here is released on all of them.
@MainActor private struct SessionSetup {
    var camera: CameraCapture?
    var preview: FacecamPreviewWindow?
    var microphone: MicrophoneCapture?
    var encoder: EncoderSetup?

    func abandon() {
        encoder?.encoder.cancel()
        microphone?.stop()
        camera?.stop()
        preview?.hide()
    }
}

/// Everything a running recording owns. It lives only inside `Activity.recording`,
/// so a recording without a session, or a session left over after stopping,
/// cannot be represented.
@MainActor private struct RecordingSession {
    let source: CaptureSource
    let recorder: ScreenRecorder
    let encoder: FrameEncoder
    let audio: AudioWriterChannel?
    let camera: CameraCapture?
    let microphone: MicrophoneCapture?
    let preview: FacecamPreviewWindow?

    func stopDevices() {
        microphone?.stop()
        camera?.stop()
        preview?.hide()
    }
}

private enum CountdownOutcome {
    case completed
    case cancelled
}

@MainActor private struct Countdown {
    let task: Task<CountdownOutcome, Never>
    var remaining: Int
    let output: Output
    /// Screen rectangle about to be recorded; the big number is drawn over it.
    let area: ScreenRect
}

/// What the process does once a quit goes through.
enum AfterQuit: Equatable {
    case exit
    case relaunch
}

/// What quitting now would cost.
private enum QuitRisk {
    case safe
    /// Capturing: quitting would throw the recording away.
    case losesRecording
    /// Encoding or compressing: quitting would cut a file off half-written, or throw
    /// away a compression that was asked for.
    case interruptsSave
}

/// A quit the app has accepted but not carried out, because a save is still running.
private enum PendingQuit {
    case notRequested
    case waitingForSave(then: AfterQuit)
}

/// What the coordinator is doing, together with the things that exist only while
/// doing it: the region overlay, the countdown timer, the recording session, and the
/// timer that clears a settled message. Views see `phase`, its projection.
@MainActor private enum Activity {
    case idle
    case choosingRegion(RegionSelector)
    case choosingSource(CaptureMode)
    case starting(Output)
    case countingDown(Countdown)
    case recording(RecordingSession, RecordingRun)
    case finishing(FinishStep)
    case settled(Settlement, dismissal: Task<Void, Never>)

    var phase: Phase {
        switch self {
        case .idle: return .idle
        case .choosingRegion: return .pickingSource(.region)
        case .choosingSource(let mode): return .pickingSource(mode)
        case .starting(let output): return .starting(output)
        case .countingDown(let countdown): return .countingDown(remaining: countdown.remaining, output: countdown.output)
        case .recording(_, let run): return .recording(run)
        case .finishing(let step): return .finishing(step)
        case .settled(let settlement, _): return .settled(settlement)
        }
    }

    /// A countdown or picker has produced nothing yet, so quitting there loses nothing.
    var quitRisk: QuitRisk {
        switch self {
        case .recording: return .losesRecording
        case .finishing: return .interruptsSave
        case .idle, .choosingRegion, .choosingSource, .starting, .countingDown, .settled: return .safe
        }
    }
}

@MainActor @Observable
final class Coordinator: FrameSink, HUDModel {
    /// The one source of truth for the recording flow. Only `enter(_:)` writes it.
    private var activity: Activity = .idle
    /// What every surface renders. Derived, so it cannot disagree with `activity`.
    var phase: Phase { activity.phase }
    /// Zero unless recording; `enter(_:)` resets it on the way out.
    private(set) var micLevel: Float = 0
    /// The one compression under way, whether the size limit or the Recordings pane
    /// asked for it. Only `run(_:info:)` writes it.
    private(set) var compression: CompressionJob?
    private(set) var permissions: PermissionReport
    private(set) var gifski: GifskiAvailability
    /// ⌘⇧., the shortcut that records, cancels and finishes from any app.
    private(set) var hotkey = AdvertisedHotkey(keys: "⌘⇧.", registration: .pending)
    /// Pane the settings window opens on; the menu sets it before opening the window.
    var settingsSection: SettingsSection = .capture
    /// What the process does once a quit goes through. The app delegate reads it on
    /// the way out.
    private(set) var afterQuit: AfterQuit = .exit

    let settings: Settings
    let library: RecordingsStore
    let updater: Updater
    let menuBar = MenuBarStatus()

    @ObservationIgnored private let hud = HUDPanel()
    @ObservationIgnored private let countdownOverlay = CountdownOverlay()
    @ObservationIgnored private let grantPanel = GrantPanel()
    @ObservationIgnored private let permissionsAtLaunch: PermissionReport
    @ObservationIgnored private var pendingQuit = PendingQuit.notRequested
    /// Set by `quit(then:)` just before it asks AppKit to terminate and consumed by
    /// the terminate reply, so a ⌘Q from anywhere else is a plain exit.
    @ObservationIgnored private var requestedAfterQuit: AfterQuit = .exit

    init() {
        permissionsAtLaunch = Permissions.check()
        permissions = permissionsAtLaunch
        gifski = GifskiAvailability.locate()
        settings = Settings()
        library = RecordingsStore()
        updater = Updater()
    }

    func start() {
        hud.attach(self)
        hotkey.registration = .register(keyCode: kVK_ANSI_Period, modifiers: cmdKey | shiftKey) { [weak self] in self?.hotkeyPressed() }
        if case .refused = hotkey.registration {
            FileHandle.standardError.write(Data("[Screensnap] start: could not register \(hotkey.keys)\n".utf8))
        }
        updater.checkIfDue(settings: settings)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissions()
                self?.refreshGifski()
            }
        }
    }

    func refreshPermissions() {
        permissions = Permissions.check()
    }

    /// gifski can be installed or removed while the app runs; the Output pane and
    /// the next recording both read the answer from here.
    func refreshGifski() {
        gifski = GifskiAvailability.locate()
    }

    var screenRecordingAccess: ScreenRecordingAccess {
        permissions.screenRecordingAccess(since: permissionsAtLaunch)
    }

    var finishKeys: String? { hotkey.advertisedKeys }

    /// The keys that tuck the pill, while there is a pill to tuck.
    var controlsKeys: String? { hud.chrome.presenceKeys }

    /// Opens the pane with the drag tile beside it. No `requestScreenRecording()`
    /// here: its dialog would stack on top of the pane we're already opening.
    /// The grant only reaches a fresh process, so relaunch the moment it lands —
    /// ideally before System Settings gets to ask "Quit & Reopen?".
    func grantScreenRecording() {
        Permissions.openSettings(.screenRecording)
        grantPanel.show(isGranted: { CGPreflightScreenCaptureAccess() }) { [weak self] in
            self?.quit(then: .relaunch, after: .zero)
        }
    }

    func requestCamera() {
        Task { _ = await Permissions.ensureCameraAccess(); refreshPermissions() }
    }

    func requestMicrophone() {
        Task { _ = await Permissions.ensureMicrophoneAccess(); refreshPermissions() }
    }

    func installUpdate() {
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.updater.install()
            if case .installed = outcome { self.relaunch() }
        }
    }

    // MARK: Quitting

    /// Quits, then opens a fresh copy. The copy is launched only once the quit is
    /// accepted: a quit can be held up by a recording or a save, or cancelled, and
    /// two instances must never run side by side.
    func relaunch() {
        quit(then: .relaunch)
    }

    /// The default delay lets the menu or button that asked finish closing.
    private func quit(then outcome: AfterQuit, after delay: Duration = .milliseconds(400)) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.requestedAfterQuit = outcome
            NSApp.terminate(nil)
        }
    }

    /// The app delegate's answer to ⌘Q. A recording in progress is finished or
    /// discarded first, as the user chooses; a save in progress is waited for.
    /// `enter(_:)` releases the quit once nothing is left to lose.
    func handleQuitRequest() -> NSApplication.TerminateReply {
        let outcome = requestedAfterQuit
        requestedAfterQuit = .exit
        // The first quit is still waiting; a second must not open a nested wait
        // that the single reply cannot end.
        if case .waitingForSave = pendingQuit { return .terminateCancel }
        switch quitRisk {
        case .safe:
            afterQuit = outcome
            return .terminateNow
        case .interruptsSave:
            pendingQuit = .waitingForSave(then: outcome)
            return .terminateLater
        case .losesRecording:
            guard let reason = askHowToEndRecording() else { return .terminateCancel }
            // The alert ran a modal loop, and ⌘⇧. or a failure may have ended the
            // recording meanwhile.
            guard case .recording = activity else {
                requestedAfterQuit = outcome
                return handleQuitRequest()
            }
            pendingQuit = .waitingForSave(then: outcome)
            Task { await stop(reason) }
            return .terminateLater
        }
    }

    /// A manual compression runs beside the recording flow, so it counts too.
    private var quitRisk: QuitRisk {
        switch activity.quitRisk {
        case .losesRecording: return .losesRecording
        case .interruptsSave: return .interruptsSave
        case .safe: return compression == nil ? .safe : .interruptsSave
        }
    }

    /// Called whenever something that can hold up a quit ends.
    private func releasePendingQuitIfSafe() {
        guard case .waitingForSave(let outcome) = pendingQuit, case .safe = quitRisk else { return }
        pendingQuit = .notRequested
        // A save that failed cancels the quit, so its message stays on screen.
        if case .settled(.failed, _) = activity {
            NSApp.reply(toApplicationShouldTerminate: false)
        } else {
            afterQuit = outcome
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    private func askHowToEndRecording() -> StopReason? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "A recording is in progress"
        alert.informativeText = "Finish and save it before quitting, or discard it?"
        alert.addButton(withTitle: "Finish and Quit")
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .finish
        case .alertSecondButtonReturn: return .discard
        default: return nil
        }
    }

    // MARK: Recording flow

    /// ⌘⇧. means "do the next obvious thing": start with the last mode, back out of
    /// a region selection or a countdown, or finish a recording.
    private func hotkeyPressed() {
        switch activity {
        case .idle, .settled: record(settings.captureMode)
        case .choosingRegion(let selector): selector.cancel()
        case .countingDown: cancelCountdown()
        case .recording: finish()
        case .choosingSource, .starting, .finishing: break
        }
    }

    func record(_ mode: CaptureMode) {
        guard !phase.isBusy else { return }
        settings.captureMode = mode
        refreshPermissions()
        refreshGifski()
        switch screenRecordingAccess {
        case .missing:
            Permissions.requestScreenRecording()
            settle(.failed("Screen Recording is off — turn Screensnap on in System Settings, then record again"))
            return
        case .grantedSinceLaunch:
            relaunch()
            return
        case .granted:
            break
        }
        switch mode {
        case .region:
            let selector = RegionSelector()
            enter(.choosingRegion(selector))
            selector.begin { [weak self] region in
                Task { @MainActor [weak self] in
                    guard let self, case .choosingRegion = self.activity else { return }
                    guard let region else { self.enter(.idle); return }
                    await self.begin(source: .region(region))
                }
            }
        case .display:
            pick(.display)
        case .window:
            pick(.window)
        }
    }

    private func pick(_ kind: PickableKind) {
        enter(.choosingSource(kind.captureMode))
        Task { [weak self] in
            let choice = await SourcePicker.choose(kind)
            guard let self, case .choosingSource = self.activity else { return }
            switch choice {
            case .picked(let source): await self.begin(source: source)
            case .cancelled: self.enter(.idle)
            case .unavailable(let error): self.settle(.failed("Could not list what is on screen — \(error.localizedDescription)"))
            }
        }
    }

    func cancelCountdown() {
        guard case .countingDown(let countdown) = activity else { return }
        countdown.task.cancel()
    }

    func finish() {
        Task { await stop(.finish) }
    }

    func discard() {
        Task { await stop(.discard) }
    }

    /// Frames and audio stop reaching the file; the finished recording has no gap.
    /// The pill's clock is fed from the recorder's, so the two cannot drift apart.
    func togglePause() {
        guard case .recording(let session, var run) = activity else { return }
        switch run.clock {
        case .running:
            let elapsed = session.recorder.pause()
            session.audio?.pause()
            run.clock = .paused(total: elapsed)
        case .paused(let total):
            let pausedFor = session.recorder.resume()
            session.audio?.resume(pausedFor: pausedFor)
            run.clock = .running(since: Date(), before: total)
        }
        enter(.recording(session, run))
    }

    /// Tucks the pill into a corner marker, or brings it back.
    func toggleControls() {
        hud.togglePresence()
    }

    /// For the take that went wrong: throw it away and record the same screen,
    /// window or area again, start delay included.
    func restart() {
        Task { await stop(.restart) }
    }

    func dismissSettled() {
        guard case .settled = activity else { return }
        enter(.idle)
    }

    private func begin(source: CaptureSource) async {
        guard let geometry = source.resolveGeometry() else {
            settle(.failed("The display to record is no longer connected"))
            return
        }
        var (encoder, degradations) = Self.plan(settings.output, gifski: gifski)
        enter(.starting(encoder.output))
        var setup = SessionSetup()

        if settings.facecam == .bubble {
            if await Permissions.ensureCameraAccess() {
                let capture = CameraCapture()
                do {
                    try capture.start()
                    setup.camera = capture
                } catch {
                    degradations.append(.camera(error.localizedDescription))
                }
            } else {
                degradations.append(.camera("camera access denied"))
            }
        }

        // The microphone comes up before the encoder is made, so a microphone that
        // cannot deliver takes the voice track out of the plan instead of leaving an
        // empty one in the file with a chip that says "voice".
        if case .mp4(.microphone) = encoder {
            if await Permissions.ensureMicrophoneAccess() {
                let capture = MicrophoneCapture { [weak self] level in
                    Task { @MainActor [weak self] in self?.showMicLevel(level) }
                }
                do {
                    try capture.start()
                    setup.microphone = capture
                } catch {
                    encoder = .mp4(.none)
                    degradations.append(.microphone(error.localizedDescription))
                }
            } else {
                encoder = .mp4(.none)
                degradations.append(.microphone("microphone access denied"))
            }
            enter(.starting(encoder.output))
        }

        // Up before the countdown, like a selfie timer: the delay is the time to frame
        // yourself and drag the bubble where it should sit.
        let placement = FacecamPlacementSource()
        if let camera = setup.camera {
            let preview = FacecamPreviewWindow(session: camera.session, captureFrame: geometry.screenFrame, placement: placement)
            preview.show()
            setup.preview = preview
        }

        if settings.startDelay.seconds > 0 {
            switch await countdown(seconds: settings.startDelay.seconds, output: encoder.output, over: geometry.screenFrame) {
            case .cancelled:
                setup.abandon()
                enter(.idle)
                return
            case .completed:
                enter(.starting(encoder.output))
            }
        }

        let url = library.newRecordingURL(template: settings.filenameTemplate, output: encoder.output)
        let framerate = settings.framerate(for: encoder.output.container)
        let encoderSetup: EncoderSetup
        do {
            encoderSetup = try EncoderSetup.make(encoder, url: url, framerate: framerate, pixelSize: geometry.pixelSize)
        } catch {
            setup.abandon()
            settle(.failed(error.localizedDescription))
            return
        }
        setup.encoder = encoderSetup
        if let channel = encoderSetup.audioChannel {
            setup.microphone?.deliver(to: { channel.append($0) })
        }

        let overlay = setup.camera.map { FacecamOverlay(camera: $0, placement: placement) }
        let recorder = ScreenRecorder(
            source: source,
            geometry: geometry,
            framerate: framerate,
            captureCursor: settings.captureCursor,
            excludeWindowIDs: [hud.windowID, setup.preview?.windowID].compactMap { $0 },
            overlay: overlay,
            sink: self
        )
        do {
            try await recorder.start()
        } catch {
            setup.abandon()
            settle(.failed(error.localizedDescription))
            return
        }

        enter(.recording(
            RecordingSession(
                source: source, recorder: recorder, encoder: encoderSetup.encoder, audio: encoderSetup.audioChannel,
                camera: setup.camera, microphone: setup.microphone, preview: setup.preview
            ),
            RecordingRun(clock: .started(at: Date()), output: encoder.output, degradations: degradations)
        ))
    }

    /// "GIF · best" needs gifski. Decided here, before a single frame is captured,
    /// so a missing binary costs a quality step rather than the recording.
    private static func plan(_ output: Output, gifski: GifskiAvailability) -> (EncoderChoice, [Degradation]) {
        switch (output, gifski) {
        case (.gif(.fast), _): return (.imageIOGif, [])
        case (.gif(.best), .located(let url)): return (.gifski(url), [])
        case (.gif(.best), .missing): return (.imageIOGif, [.gifskiMissing])
        case (.mp4(let audio), _): return (.mp4(audio), [])
        }
    }

    private func countdown(seconds: Int, output: Output, over area: ScreenRect) async -> CountdownOutcome {
        let task = Task<CountdownOutcome, Never> { [weak self] in
            for remaining in stride(from: seconds - 1, through: 0, by: -1) {
                do { try await Task.sleep(for: .seconds(1)) } catch { return .cancelled }
                if remaining > 0 { self?.showCountdown(remaining) }
            }
            return .completed
        }
        enter(.countingDown(Countdown(task: task, remaining: seconds, output: output, area: area)))
        return await task.value
    }

    private func showCountdown(_ remaining: Int) {
        guard case .countingDown(var countdown) = activity else { return }
        countdown.remaining = remaining
        enter(.countingDown(countdown))
    }

    /// Levels arrive on their own tasks and can land after the recording ended.
    private func showMicLevel(_ level: Float) {
        guard case .recording = activity else { return }
        micLevel = level
    }

    private func stop(_ reason: StopReason) async {
        guard case .recording(let session, let run) = activity else { return }
        switch reason {
        case .discard:
            // Before settling, so the partial file is out of the save folder by the
            // time a pending quit is released. The sink ignores frames that arrive after.
            session.encoder.cancel()
            settle(.discarded)
            _ = await session.recorder.stop()
            session.stopDevices()
        case .restart:
            session.encoder.cancel()
            enter(.starting(run.output))
            _ = await session.recorder.stop()
            session.stopDevices()
            await begin(source: session.source)
        case .finish:
            enter(.finishing(.encoding(run.output)))
            let end = await session.recorder.stop()
            session.stopDevices()
            do {
                let encoded = try await session.encoder.finish(at: end)
                library.rescan()
                guard var recording = library.recording(at: encoded.url) ?? Recording(url: encoded.url) else {
                    throw CompressionError.unreadable
                }
                var fit: FitOutcome?
                if case .atMost(let ceiling) = settings.sizeLimit, recording.bytes > ceiling.size {
                    let fitted = try await self.fit(recording, under: ceiling.size)
                    recording = fitted.recording
                    fit = fitted.outcome
                }
                let delivered = deliver(recording)
                settle(.saved(SavedRecording(
                    recording: recording,
                    degradations: run.degradations + [encoded.degradation].compactMap { $0 },
                    fit: fit,
                    delivered: delivered
                )))
            } catch {
                settle(.failed(error.localizedDescription))
            }
        }
    }

    /// Shrinks a fresh recording under the limit through the same job slot the
    /// Recordings pane uses. A slot already taken leaves the recording as it is and
    /// says so, rather than running two compressions at once.
    private func fit(_ recording: Recording, under limit: ByteCount) async throws -> (recording: Recording, outcome: FitOutcome) {
        guard compression == nil else { return (recording, .skipped(limit)) }
        enter(.finishing(.fittingToLimit(limit)))
        guard let info = await library.loadInfo(for: recording) else { throw CompressionError.unreadable }
        let job = CompressionJob(recording: recording, target: .size(limit), placement: .replaceOriginal, origin: .sizeLimit, progress: 0)
        let result = try await run(job, info: info)
        guard let fitted = library.recording(at: result.url) ?? Recording(url: result.url) else { throw CompressionError.unreadable }
        switch result.fit {
        case .met: return (fitted, .shrunk(under: limit))
        case .exceeded: return (fitted, .stillOver(limit))
        }
    }

    private func deliver(_ recording: Recording) -> Delivered {
        let copy = settings.delivery.clipboard.applies(to: recording.container)
        if copy { Clipboard.copy(recording) }
        let reveal = settings.delivery.revealInFinder
        if reveal { library.reveal(recording) }
        return Delivered(copiedToClipboard: copy, revealedInFinder: reveal)
    }

    private func abort(_ error: Error) async {
        guard case .recording(let session, _) = activity else { return }
        session.encoder.cancel()
        settle(.failed(error.localizedDescription))
        _ = await session.recorder.stop()
        session.stopDevices()
    }

    private func settle(_ settlement: Settlement) {
        let linger: Duration
        switch settlement {
        case .saved: linger = .seconds(5)
        case .discarded: linger = .seconds(1.5)
        case .failed: linger = .seconds(8)
        }
        let dismissal = Task { [weak self] in
            do { try await Task.sleep(for: linger) } catch { return }
            // Leaving `.settled` cancels this; the check covers a wake-up that was
            // already queued when that happened.
            guard !Task.isCancelled else { return }
            self?.enter(.idle)
        }
        enter(.settled(settlement, dismissal: dismissal))
    }

    /// The only writer of `activity`. Releases what the old activity owned that the
    /// new one does not carry, then shows the new phase on every surface.
    private func enter(_ next: Activity) {
        if case .settled(_, let dismissal) = activity { dismissal.cancel() }
        activity = next
        switch next {
        case .recording: break
        case .idle, .choosingRegion, .choosingSource, .starting, .countingDown, .finishing, .settled:
            if micLevel != 0 { micLevel = 0 }
        }
        switch next {
        case .countingDown(let countdown): countdownOverlay.show(countdown.remaining, over: countdown.area)
        case .idle, .choosingRegion, .choosingSource, .starting, .recording, .finishing, .settled: countdownOverlay.hide()
        }
        hud.render(phase)
        menuBar.render(phase)
        releasePendingQuitIfSafe()
    }

    // MARK: FrameSink

    /// The frame arrives with the facecam already drawn in on the capture queue; all
    /// that is left is to hand it to the encoder of the recording it belongs to.
    func sinkDidCapture(frame: CapturedFrame) {
        guard case .recording(let session, _) = activity else { return }
        do {
            try session.encoder.append(frame)
        } catch {
            Task { await abort(error) }
        }
    }

    func sinkDidFail(with error: Error) {
        Task { await abort(error) }
    }

    // MARK: Library

    var lastRecording: Recording? { library.recordings.first }

    func copyLast() {
        guard let last = lastRecording else { return }
        Clipboard.copy(last)
    }

    func reveal(_ recording: Recording) {
        library.reveal(recording)
    }

    func setSaveFolder(_ url: URL) {
        library.setFolder(url)
    }

    func compress(_ recording: Recording, to target: CompressionTarget, placement: CompressionPlacement) async -> CompressionOutcome {
        guard compression == nil else { return .failed(CompressionError.busy.localizedDescription) }
        guard let info = await library.loadInfo(for: recording) else {
            return .failed(CompressionError.unreadable.localizedDescription)
        }
        do {
            let job = CompressionJob(recording: recording, target: target, placement: placement, origin: .manual, progress: 0)
            return .done(try await run(job, info: info))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The one way a compression runs. Claims the single job slot for its duration,
    /// so two compressions, whoever asked for them, never run at once.
    private func run(_ job: CompressionJob, info: MediaInfo) async throws -> CompressionResult {
        guard compression == nil else { throw CompressionError.busy }
        compression = job
        defer {
            compression = nil
            releasePendingQuitIfSafe()
        }
        let result = try await Compressor.compress(job.recording, info: info, to: job.target, placement: job.placement) { [weak self] progress in
            Task { @MainActor [weak self] in
                // A late update from a finished job must not move another job's bar.
                guard self?.compression?.recording == job.recording else { return }
                self?.compression?.progress = progress
            }
        }
        library.rescan()
        return result
    }
}
