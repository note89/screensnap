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

@MainActor private struct RecordingSession {
    let recorder: ScreenRecorder
    let encoder: FrameEncoder
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

@MainActor @Observable
final class Coordinator: FrameSink {
    private(set) var phase: Phase = .idle
    private(set) var micLevel: Float = 0
    private(set) var compression: CompressionJob?
    private(set) var permissions: PermissionReport
    /// Pane the settings window opens on; the menu sets it before opening the window.
    var settingsSection: SettingsSection = .capture

    let settings: Settings
    let library: RecordingsStore
    let updater: Updater

    @ObservationIgnored private let hud = HUDPanel()
    @ObservationIgnored private let permissionsAtLaunch: PermissionReport
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var hotkey: GlobalHotkey?
    @ObservationIgnored private var regionSelector: RegionSelector?
    @ObservationIgnored private var countdownTask: Task<CountdownOutcome, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    init() {
        permissionsAtLaunch = Permissions.check()
        permissions = permissionsAtLaunch
        settings = Settings()
        library = RecordingsStore(folder: settings.saveFolder)
        updater = Updater()
    }

    func start() {
        hud.attach(self)
        hotkey = GlobalHotkey(keyCode: kVK_ANSI_Period, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.hotkeyPressed()
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

    // MARK: Recording flow

    /// ⌘⇧. means "do the next obvious thing": start with the last mode, cancel a
    /// countdown, or finish a recording.
    private func hotkeyPressed() {
        switch phase {
        case .idle, .settled: record(settings.captureMode)
        case .countingDown: cancelCountdown()
        case .recording: finish()
        case .pickingSource, .finishing: break
        }
    }

    func record(_ mode: CaptureMode) {
        guard !phase.isBusy else { return }
        settleTask?.cancel()
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
        transition(.pickingSource(mode))
        switch mode {
        case .region:
            let selector = RegionSelector()
            regionSelector = selector
            selector.begin { [weak self] region in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.regionSelector = nil
                    guard let region else { self.transition(.idle); return }
                    await self.begin(source: .region(region))
                }
            }
        case .display, .window:
            Task { [weak self] in
                let source = await SourcePicker.choose(mode)
                guard let self else { return }
                guard let source else { self.transition(.idle); return }
                await self.begin(source: source)
            }
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
    }

    func finish() {
        Task { await stop(.finish) }
    }

    func discard() {
        Task { await stop(.discard) }
    }

    func dismissSettled() {
        guard case .settled = phase else { return }
        settleTask?.cancel()
        transition(.idle)
    }

    private func begin(source: CaptureSource) async {
        let (output, fallback) = Self.effective(settings.output)
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

        if settings.startDelay > 0, await countdown(seconds: settings.startDelay, output: output) == .cancelled {
            camera?.stop()
            transition(.idle)
            return
        }

        let preview = camera.map { FacecamPreviewWindow(session: $0.session, captureFrame: source.screenFrame) }
        preview?.show()

        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        let url = settings.newRecordingURL(for: output)
        let encoderSetup: EncoderSetup
        do {
            encoderSetup = try EncoderSetup.make(
                output: output, url: url, framerate: settings.framerate,
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
                onLevel: { [weak self] level in Task { @MainActor [weak self] in self?.micLevel = level } }
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
            framerate: settings.framerate,
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

        session = RecordingSession(recorder: recorder, encoder: encoderSetup.encoder, camera: camera, microphone: microphone, preview: preview)
        transition(.recording(RecordingRun(
            startedAt: Date(),
            output: output,
            dimensions: Dimensions(recorder.pixelSize),
            degradations: degradations
        )))
    }

    /// "GIF · best" needs gifski. Decided here, before a single frame is captured,
    /// so a missing binary costs a quality step rather than the recording.
    private static func effective(_ output: Output) -> (Output, Degradation?) {
        guard output == .gif(.best), GifskiEncoder.locateGifski() == nil else { return (output, nil) }
        return (.gif(.fast), .gifskiMissing)
    }

    private func countdown(seconds: Int, output: Output) async -> CountdownOutcome {
        let task = Task<CountdownOutcome, Never> { [weak self] in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                self?.transition(.countingDown(remaining: remaining, output: output))
                do { try await Task.sleep(for: .seconds(1)) } catch { return .cancelled }
            }
            return .completed
        }
        countdownTask = task
        let outcome = await task.value
        countdownTask = nil
        return outcome
    }

    private func stop(_ reason: StopReason) async {
        guard let session, case .recording(let run) = phase else { return }
        self.session = nil
        await session.recorder.stop()
        session.stopDevices()
        micLevel = 0

        switch reason {
        case .discard:
            session.encoder.cancel()
            settle(.discarded)
        case .finish:
            transition(.finishing(.encoding(run.output)))
            do {
                let url = try await session.encoder.finish()
                var notes = run.degradations.map(\.message)
                library.rescan()
                guard var recording = library.recording(at: url) ?? Recording(url: url) else {
                    throw CompressionError.unreadable
                }
                if case .bytes(let limitBytes) = settings.sizeLimit, recording.bytes.bytes > limitBytes {
                    let limit = ByteCount(limitBytes)
                    recording = try await fit(recording, under: limit)
                    notes.append(recording.bytes.bytes <= limitBytes ? "shrunk to fit \(limit.formatted)" : "could not get under \(limit.formatted)")
                }
                deliver(recording)
                settle(.saved(recording, notes: notes))
            } catch {
                settle(.failed(error.localizedDescription))
            }
        }
    }

    private func fit(_ recording: Recording, under limit: ByteCount) async throws -> Recording {
        transition(.finishing(.fittingToLimit(limit, progress: 0)))
        guard let info = await MediaInfo.load(recording) else { throw CompressionError.unreadable }
        let result = try await Compressor.compress(recording, info: info, to: .size(limit), placement: .replaceOriginal) { [weak self] progress in
            Task { @MainActor [weak self] in self?.transition(.finishing(.fittingToLimit(limit, progress: progress))) }
        }
        library.rescan()
        guard let fitted = library.recording(at: result.url) ?? Recording(url: result.url) else { throw CompressionError.unreadable }
        return fitted
    }

    private func deliver(_ recording: Recording) {
        if settings.delivery.copyToClipboard { Clipboard.copy(recording.url) }
        if settings.delivery.revealInFinder { library.reveal(recording) }
    }

    private func abort(_ error: Error) async {
        guard let session else { return }
        self.session = nil
        await session.recorder.stop()
        session.stopDevices()
        session.encoder.cancel()
        micLevel = 0
        settle(.failed(error.localizedDescription))
    }

    private func settle(_ settlement: Settlement) {
        transition(.settled(settlement))
        let linger: Duration
        switch settlement {
        case .saved: linger = .seconds(5)
        case .discarded: linger = .seconds(1.5)
        case .failed: linger = .seconds(8)
        }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled, let self, case .settled = self.phase else { return }
            self.transition(.idle)
        }
    }

    private func transition(_ next: Phase) {
        phase = next
        hud.render(next)
    }

    // MARK: FrameSink

    func sinkDidCapture(frame: CapturedFrame) {
        guard let session else { return }
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
                Task { @MainActor [weak self] in self?.compression?.progress = progress }
            }
            library.rescan()
            return .done(result)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
