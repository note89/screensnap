import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import os
import ScreenCaptureKit

/// One captured frame plus the time (in seconds since recording start, pauses
/// excluded) it was sampled.
struct CapturedFrame {
    let image: CGImage
    let timestamp: CFTimeInterval
    /// Absolute host-clock time (`CACurrentMediaTime()` base) of the sample.
    /// Microphone sample buffers carry PTS on the same clock, so the encoder
    /// uses this to line the audio track up with the video track.
    let hostTime: CFTimeInterval
}

/// What to capture. Each case maps to a different `SCContentFilter` constructor.
enum CaptureSource {
    /// A rectangular region on a specific display.
    case region(DisplayPixelRect)
    /// An entire display.
    case display(SCDisplay)
    /// A single window — works even when the window is in a different Space.
    case window(SCWindow)

    /// The source measured against the displays present now, or nil when its
    /// display is gone. A window belongs to the display showing most of it.
    func resolveGeometry() -> CaptureGeometry? {
        switch self {
        case .region(let region):
            guard let screen = NSScreen.screen(displayID: region.displayID) else { return nil }
            return CaptureGeometry(pixelSize: region.pixelSize, screenFrame: region.screenRect(on: screen))
        case .display(let display):
            guard let screen = NSScreen.screen(displayID: display.displayID) else { return nil }
            let points = CGSize(width: display.width, height: display.height)
            return CaptureGeometry(pixelSize: Self.pixels(points, on: screen), screenFrame: ScreenRect(screen.frame))
        case .window(let window):
            let frame = ScreenRect(window: window)
            guard let screen = NSScreen.screen(mostlyShowing: frame) else { return nil }
            return CaptureGeometry(pixelSize: Self.pixels(frame.size, on: screen), screenFrame: frame)
        }
    }

    /// Points to whole pixels at the screen's backing scale, rounded down so the
    /// stream is never asked for a partial pixel.
    private static func pixels(_ points: CGSize, on screen: NSScreen) -> Dimensions {
        let scale = screen.backingScaleFactor
        return Dimensions(width: Int((points.width * scale).rounded(.down)), height: Int((points.height * scale).rounded(.down)))
    }
}

/// A source measured against the displays present when recording starts. The
/// stream, the encoder and the HUD read one pixel size; the facecam preview and the
/// countdown are placed against one on-screen rectangle.
struct CaptureGeometry: Equatable {
    /// Output dimensions in whole pixels, backing scale applied.
    let pixelSize: Dimensions
    /// Where the captured area sits on screen.
    let screenFrame: ScreenRect
}

@MainActor
protocol FrameSink: AnyObject {
    func sinkDidCapture(frame: CapturedFrame)
    func sinkDidFail(with error: Error)
}

enum ScreenRecorderError: Error {
    case displayNotFound
    case alreadyRunning
}

enum StopReason {
    case finish
    case discard
    /// Discard, then record the same source again without asking what to record.
    case restart
}

/// Wraps `SCStream`. Owns the recording lifecycle and its clock, throttles the
/// irregular SCK frame stream onto a stable output framerate, draws the facecam
/// overlay on the capture queue, and forwards frames to the sink.
@MainActor
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let source: CaptureSource
    private let geometry: CaptureGeometry
    private let framerate: Framerate
    private let captureCursor: Bool
    private let excludeWindowIDs: [CGWindowID]
    private let overlay: FacecamOverlay?
    private weak var sink: FrameSink?

    private enum CaptureState {
        case idle
        case capturing(stream: SCStream)
        case stopped
    }
    private var captureState: CaptureState = .idle
    private let frameQueue = DispatchQueue(label: "Screensnap.frameQueue")

    /// The recording's clock, shared with the capture queue. While `.stopped` or
    /// `.paused` every frame is dropped; while `.running` at most one per frame
    /// interval passes. One value, so "capturing but no start time" cannot be
    /// represented. Resuming moves `startedAt` forward by the pause, so frame
    /// timestamps have no gap in them. Everything else that needs recorded time,
    /// the pill, the audio track, the end of the file, reads it from here.
    private enum FrameClock {
        case stopped
        case running(startedAt: CFTimeInterval, lastEmitted: CFTimeInterval?)
        case paused(startedAt: CFTimeInterval, lastEmitted: CFTimeInterval?, since: CFTimeInterval)

        /// Recorded seconds so far, pauses excluded.
        func elapsed(at now: CFTimeInterval) -> CFTimeInterval {
            switch self {
            case .stopped: return 0
            case .running(let startedAt, _): return now - startedAt
            case .paused(let startedAt, _, let since): return since - startedAt
            }
        }
    }
    private let clock = OSAllocatedUnfairLock(initialState: FrameClock.stopped)

    init(
        source: CaptureSource,
        geometry: CaptureGeometry,
        framerate: Framerate,
        captureCursor: Bool,
        excludeWindowIDs: [CGWindowID] = [],
        overlay: FacecamOverlay?,
        sink: FrameSink
    ) {
        self.source = source
        self.geometry = geometry
        self.framerate = framerate
        self.captureCursor = captureCursor
        self.excludeWindowIDs = excludeWindowIDs
        self.overlay = overlay
        self.sink = sink
    }

    func start() async throws {
        guard case .idle = captureState else { throw ScreenRecorderError.alreadyRunning }

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = captureCursor
        config.queueDepth = 6
        // `minimumFrameInterval` is a *floor*, not a hard rate. We still throttle in software
        // to keep encoder timestamps regular.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framerate.fps))
        config.colorSpaceName = CGColorSpace.sRGB
        config.width = geometry.pixelSize.width
        config.height = geometry.pixelSize.height

        let filter: SCContentFilter
        switch source {
        case .region(let region):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw ScreenRecorderError.displayNotFound
            }
            config.sourceRect = region.rect
            filter = Self.displayFilter(display: display, content: content, excludeWindowIDs: excludeWindowIDs)

        case .display(let display):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            filter = Self.displayFilter(display: display, content: content, excludeWindowIDs: excludeWindowIDs)

        case .window(let window):
            // `desktopIndependentWindow` captures the window across Space changes
            // and remains valid even when the window is minimized or on another Space.
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()

        clock.withLock { $0 = .running(startedAt: CACurrentMediaTime(), lastEmitted: nil) }
        self.captureState = .capturing(stream: stream)
    }

    /// Excludes every window belonging to this process (HUD pill, facecam preview),
    /// plus any explicit IDs. Matching by PID is robust to the HUD not yet being listed
    /// in shareable content when the filter is built.
    private static func displayFilter(display: SCDisplay, content: SCShareableContent, excludeWindowIDs: [CGWindowID]) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        if ownApps.isEmpty {
            let excludedWindows = content.windows.filter { excludeWindowIDs.contains($0.windowID) }
            return SCContentFilter(display: display, excludingWindows: excludedWindows)
        }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
    }

    /// Returns the recorded time so far, which the pill freezes on.
    func pause() -> CFTimeInterval {
        clock.withLock { (state: inout FrameClock) -> CFTimeInterval in
            let now = CACurrentMediaTime()
            guard case .running(let startedAt, let lastEmitted) = state else { return state.elapsed(at: now) }
            state = .paused(startedAt: startedAt, lastEmitted: lastEmitted, since: now)
            return now - startedAt
        }
    }

    /// Returns how long the recording was paused, so audio can be shifted to match.
    func resume() -> CFTimeInterval {
        clock.withLock { (state: inout FrameClock) -> CFTimeInterval in
            guard case .paused(let startedAt, let lastEmitted, let since) = state else { return 0 }
            let pausedFor = CACurrentMediaTime() - since
            state = .running(startedAt: startedAt + pausedFor, lastEmitted: lastEmitted)
            return pausedFor
        }
    }

    /// Returns the recording's length on its clock, pauses excluded: the moment the
    /// encoder cuts the file at.
    func stop() async -> CFTimeInterval {
        let end = clock.withLock { (state: inout FrameClock) -> CFTimeInterval in
            let end = state.elapsed(at: CACurrentMediaTime())
            state = .stopped
            return end
        }
        guard case .capturing(let stream) = captureState else { return end }
        self.captureState = .stopped
        try? await stream.stopCapture()
        return end
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Verify the frame is "complete" (status .complete = pixels are fresh).
        guard let infoArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = infoArray.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else {
            return
        }

        let interval = 1.0 / Double(framerate.fps)
        let tick: (elapsed: CFTimeInterval, hostTime: CFTimeInterval)? = clock.withLock { state in
            guard case .running(let startedAt, let lastEmitted) = state else { return nil }
            let now = CACurrentMediaTime()
            let elapsed = now - startedAt
            if let lastEmitted, elapsed - lastEmitted < interval { return nil }
            state = .running(startedAt: startedAt, lastEmitted: elapsed)
            return (elapsed, now)
        }
        guard let tick else { return }

        guard let captured = sampleBuffer.cgImage() else { return }
        let image = overlay?.apply(to: captured) ?? captured
        let frame = CapturedFrame(image: image, timestamp: tick.elapsed, hostTime: tick.hostTime)
        Task { @MainActor [weak self] in
            self?.sink?.sinkDidCapture(frame: frame)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.sink?.sinkDidFail(with: error)
        }
    }
}

// MARK: - Helpers

private extension CMSampleBuffer {
    /// Convert a BGRA `CMSampleBuffer` into a `CGImage`. Returns nil on failure.
    func cgImage() -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(self) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
}
