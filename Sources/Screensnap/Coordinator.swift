import AppKit
import Carbon.HIToolbox
import Observation
import ScreenCaptureKit

struct CompressionJob: Equatable {
    let recording: Recording
    let target: CompressionTarget
    var progress: Double
}

enum CompressionOutcome: Equatable {
    case done(CompressionResult)
    case failed(String)
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
    let area: CGRect
}

/// ⌘⇧., the shortcut that records, cancels and finishes from any app. Carbon can
/// refuse the registration; the surfaces that name the key then stop advertising it.
enum HotkeyRegistration {
    case pending
    case active(GlobalHotkey)
    case refused

    static let keys = "⌘⇧."

    /// The keys to advertise, or nil when pressing them would do nothing.
    var advertisedKeys: String? {
        switch self {
        case .pending, .active: return Self.keys
        case .refused: return nil
        }
    }
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
}

@MainActor @Observable
final class Coordinator: FrameSink {
    /// The one source of truth for the recording flow. Only `enter(_:)` writes it.
    private var activity: Activity = .idle
    /// What every surface renders. Derived, so it cannot disagree with `activity`.
    var phase: Phase { activity.phase }
    /// Zero unless recording; `enter(_:)` resets it on the way out.
    private(set) var micLevel: Float = 0
    private(set) var compression: CompressionJob?
    private(set) var permissions: PermissionReport
    private(set) var hotkey: HotkeyRegistration = .pending
    /// Pane the settings window opens on; the menu sets it before opening the window.
    var settingsSection: SettingsSection = .capture

    let settings: Settings
    let library: RecordingsStore
    let updater: Updater
    let menuBar = MenuBarStatus()

    @ObservationIgnored private let hud = HUDPanel()
    @ObservationIgnored private let countdownOverlay = CountdownOverlay()
    @ObservationIgnored private let grantPanel = GrantPanel()
    @ObservationIgnored private let permissionsAtLaunch: PermissionReport

    init() {
        permissionsAtLaunch = Permissions.check()
        permissions = permissionsAtLaunch
        settings = Settings()
        library = RecordingsStore(folder: settings.saveFolder)
        updater = Updater()
    }

    func start() {
        hud.attach(self)
        if let registered = GlobalHotkey(keyCode: kVK_ANSI_Period, modifiers: cmdKey | shiftKey, { [weak self] in self?.hotkeyPressed() }) {
            hotkey = .active(registered)
        } else {
            hotkey = .refused
            FileHandle.standardError.write(Data("[Screensnap] start: could not register \(HotkeyRegistration.keys)\n".utf8))
        }
        updater.checkIfDue(settings: settings)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        permissions = Permissions.check()
    }

    var screenRecordingAccess: ScreenRecordingAccess {
        permissions.screenRecordingAccess(since: permissionsAtLaunch)
    }

    /// Opens the pane with the drag tile beside it. No `requestScreenRecording()`
    /// here: its dialog would stack on top of the pane we're already opening.
    /// The grant only reaches a fresh process, so relaunch the moment it lands —
    /// ideally before System Settings gets to ask "Quit & Reopen?".
    func grantScreenRecording() {
        Permissions.openSettings(.screenRecording)
        grantPanel.show(isGranted: { CGPreflightScreenCaptureAccess() }) {
            Relaunch.now(after: .zero)
        }
    }

    func requestCamera() {
        Task { _ = await Permissions.ensureCameraAccess(); refreshPermissions() }
    }

    func requestMicrophone() {
        Task { _ = await Permissions.ensureMicrophoneAccess(); refreshPermissions() }
    }

    // MARK: Recording flow

    /// ⌘⇧. means "do the next obvious thing": start with the last mode, cancel a
    /// countdown, or finish a recording.
    private func hotkeyPressed() {
        switch phase {
        case .idle, .settled: record(settings.captureMode)
        case .countingDown: cancelCountdown()
        case .recording: finish()
        case .pickingSource, .starting, .finishing: break
        }
    }

    func record(_ mode: CaptureMode) {
        guard !phase.isBusy else { return }
        settings.captureMode = mode
        refreshPermissions()
        switch screenRecordingAccess {
        case .missing:
            Permissions.requestScreenRecording()
            settle(.failed("Screen Recording is off — turn Screensnap on in System Settings, then record again"))
            return
        case .grantedSinceLaunch:
            Relaunch.now()
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
        case .display, .window:
            enter(.choosingSource(mode))
            Task { [weak self] in
                let source = await SourcePicker.choose(mode)
                guard let self, case .choosingSource = self.activity else { return }
                guard let source else { self.enter(.idle); return }
                await self.begin(source: source)
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
    func togglePause() {
        guard case .recording(let session, var run) = activity else { return }
        switch run.clock {
        case .running:
            session.recorder.pause()
            session.audio?.pause()
            run.clock = run.clock.pausing(at: Date())
        case .paused:
            let pausedFor = session.recorder.resume()
            session.audio?.resume(pausedFor: pausedFor)
            run.clock = run.clock.resuming(at: Date())
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
        let (output, fallback) = Self.effective(settings.output)
        enter(.starting(output))
        var degradations: [Degradation] = fallback.map { [$0] } ?? []

        var camera: CameraCapture?
        if settings.facecam == .bubble {
            if await Permissions.ensureCameraAccess() {
                let capture = CameraCapture()
                do {
                    try capture.start()
                    camera = capture
                } catch {
                    degradations.append(.camera(error.localizedDescription))
                }
            } else {
                degradations.append(.camera("camera access denied"))
            }
        }

        var microphoneGranted = false
        if output.recordsMicrophone {
            microphoneGranted = await Permissions.ensureMicrophoneAccess()
            if !microphoneGranted { degradations.append(.microphone("microphone access denied")) }
        }

        // Up before the countdown, like a selfie timer: the delay is the time to frame
        // yourself and drag the bubble where it should sit.
        let preview = camera.map { FacecamPreviewWindow(session: $0.session, captureFrame: source.screenFrame) }
        preview?.show()

        if settings.startDelay.seconds > 0 {
            switch await countdown(seconds: settings.startDelay.seconds, output: output, over: source.screenFrame) {
            case .cancelled:
                camera?.stop()
                preview?.hide()
                enter(.idle)
                return
            case .completed:
                enter(.starting(output))
            }
        }

        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        let url = settings.newRecordingURL(for: output)
        let encoderSetup: EncoderSetup
        do {
            encoderSetup = try EncoderSetup.make(
                output: output, url: url, framerate: settings.framerate(for: output.container).fps,
                pixelSize: source.pixelSize, audio: microphoneGranted ? .microphone : .none
            )
        } catch {
            camera?.stop()
            preview?.hide()
            settle(.failed(error.localizedDescription))
            return
        }

        var microphone: MicrophoneCapture?
        if let channel = encoderSetup.audioChannel {
            let capture = MicrophoneCapture(
                onSampleBuffer: { channel.append($0) },
                onLevel: { [weak self] level in Task { @MainActor [weak self] in self?.showMicLevel(level) } }
            )
            do {
                try capture.start()
                microphone = capture
            } catch {
                degradations.append(.microphone(error.localizedDescription))
            }
        }

        let recorder = ScreenRecorder(
            source: source,
            framerate: settings.framerate(for: output.container),
            captureCursor: settings.captureCursor,
            excludeWindowIDs: [hud.windowID, preview?.windowID].compactMap { $0 },
            sink: self
        )
        do {
            try await recorder.start()
        } catch {
            microphone?.stop()
            camera?.stop()
            preview?.hide()
            encoderSetup.encoder.cancel()
            settle(.failed(error.localizedDescription))
            return
        }

        enter(.recording(
            RecordingSession(source: source, recorder: recorder, encoder: encoderSetup.encoder, audio: encoderSetup.audioChannel, camera: camera, microphone: microphone, preview: preview),
            RecordingRun(clock: .started(at: Date()), output: output, degradations: degradations)
        ))
    }

    /// "GIF · best" needs gifski. Decided here, before a single frame is captured,
    /// so a missing binary costs a quality step rather than the recording.
    private static func effective(_ output: Output) -> (Output, Degradation?) {
        guard output == .gif(.best), GifskiEncoder.locateGifski() == nil else { return (output, nil) }
        return (.gif(.fast), .gifskiMissing)
    }

    private func countdown(seconds: Int, output: Output, over area: CGRect) async -> CountdownOutcome {
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
            settle(.discarded)
            await session.recorder.stop()
            session.stopDevices()
            session.encoder.cancel()
        case .restart:
            enter(.starting(run.output))
            await session.recorder.stop()
            session.stopDevices()
            session.encoder.cancel()
            await begin(source: session.source)
        case .finish:
            enter(.finishing(.encoding(run.output)))
            await session.recorder.stop()
            session.stopDevices()
            do {
                let encoded = try await session.encoder.finish()
                let url = encoded.url
                var notes = (run.degradations + [encoded.degradation].compactMap { $0 }).map(\.message)
                library.rescan()
                guard var recording = library.recording(at: url) ?? Recording(url: url) else {
                    throw CompressionError.unreadable
                }
                if case .atMost(let ceiling) = settings.sizeLimit, recording.bytes > ceiling.size {
                    recording = try await fit(recording, under: ceiling.size)
                    notes.append(recording.bytes <= ceiling.size ? "shrunk to fit \(ceiling.size.formatted)" : "could not get under \(ceiling.size.formatted)")
                }
                deliver(recording)
                settle(.saved(recording, notes: notes))
            } catch {
                settle(.failed(error.localizedDescription))
            }
        }
    }

    private func fit(_ recording: Recording, under limit: ByteCount) async throws -> Recording {
        enter(.finishing(.fittingToLimit(limit, progress: 0)))
        guard let info = await MediaInfo.load(recording) else { throw CompressionError.unreadable }
        let result = try await Compressor.compress(recording, info: info, to: .size(limit), placement: .replaceOriginal) { [weak self] progress in
            Task { @MainActor [weak self] in self?.showFitProgress(progress) }
        }
        library.rescan()
        guard let fitted = library.recording(at: result.url) ?? Recording(url: result.url) else { throw CompressionError.unreadable }
        return fitted
    }

    /// Progress arrives on its own tasks and can land after the fit is over. It only
    /// ever moves the bar of a fit that is still showing, never reopens one.
    private func showFitProgress(_ progress: Double) {
        guard case .finishing(.fittingToLimit(let limit, _)) = activity else { return }
        enter(.finishing(.fittingToLimit(limit, progress: progress)))
    }

    private func deliver(_ recording: Recording) {
        if settings.delivery.clipboard.applies(to: OutputContainer(url: recording.url)) { Clipboard.copy(recording.url) }
        if settings.delivery.revealInFinder { library.reveal(recording) }
    }

    private func abort(_ error: Error) async {
        guard case .recording(let session, _) = activity else { return }
        settle(.failed(error.localizedDescription))
        await session.recorder.stop()
        session.stopDevices()
        session.encoder.cancel()
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
    }

    // MARK: FrameSink

    func sinkDidCapture(frame: CapturedFrame) {
        guard case .recording(let session, _) = activity else { return }
        var image = frame.image
        if let camera = session.camera, let preview = session.preview, let face = camera.latestFrame {
            image = FacecamCompositor.composite(screen: image, camera: face, placement: preview.placement) ?? image
        }
        do {
            try session.encoder.append(CapturedFrame(image: image, timestamp: frame.timestamp, hostTime: frame.hostTime))
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
        Clipboard.copy(last.url)
    }

    func setSaveFolder(_ url: URL) {
        settings.saveFolder = url
        library.setFolder(url)
    }

    func compress(_ recording: Recording, to target: CompressionTarget, placement: CompressionPlacement) async -> CompressionOutcome {
        guard compression == nil else { return .failed("Another compression is still running.") }
        let loaded: MediaInfo?
        if let cached = library.info(for: recording) {
            loaded = cached
        } else {
            loaded = await MediaInfo.load(recording)
        }
        guard let info = loaded else {
            return .failed(CompressionError.unreadable.localizedDescription)
        }
        compression = CompressionJob(recording: recording, target: target, progress: 0)
        defer { compression = nil }
        do {
            let result = try await Compressor.compress(recording, info: info, to: target, placement: placement) { [weak self] progress in
                Task { @MainActor [weak self] in
                    // A late update from a finished job must not move another job's bar.
                    guard self?.compression?.recording == recording else { return }
                    self?.compression?.progress = progress
                }
            }
            library.rescan()
            return .done(result)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
