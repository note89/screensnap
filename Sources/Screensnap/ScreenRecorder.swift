import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import os
import ScreenCaptureKit

/// One captured frame plus the time (in seconds since recording start) it was sampled.
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
    case region(SelectedRegion)
    /// An entire display.
    case display(SCDisplay)
    /// A single window — works even when the window is in a different Space.
    case window(SCWindow)

    /// Output dimensions in whole pixels (accounting for the backing scale on
    /// Retina displays). The region case already carries pixel-space rects;
    /// the others are in points and need to be scaled here. The stream, the
    /// encoder and the HUD all read this one value.
    var pixelSize: CGSize {
        let size: CGSize
        switch self {
        case .region(let r):
            size = r.pixelRect.size
        case .display(let d):
            let scale = NSScreen.screen(displayID: d.displayID)?.backingScaleFactor ?? 2
            size = CGSize(width: CGFloat(d.width) * scale, height: CGFloat(d.height) * scale)
        case .window(let w):
            let midPoint = CGPoint(x: w.frame.midX, y: w.frame.midY)
            let scale = NSScreen.screens.first(where: { $0.frame.contains(midPoint) })?.backingScaleFactor ?? 2
            size = CGSize(width: w.frame.width * scale, height: w.frame.height * scale)
        }
        return CGSize(width: size.width.rounded(.down), height: size.height.rounded(.down))
    }

    /// Where the captured area sits on screen, in AppKit points (bottom-left origin).
    /// The facecam preview compares its own frame against this to place the bubble.
    var screenFrame: CGRect {
        switch self {
        case .region(let r):
            guard let screen = NSScreen.screen(displayID: r.displayID) else { return .zero }
            let scale = screen.backingScaleFactor
            return CGRect(
                x: screen.frame.minX + r.pixelRect.minX / scale,
                y: screen.frame.maxY - r.pixelRect.maxY / scale,
                width: r.pixelRect.width / scale,
                height: r.pixelRect.height / scale
            )
        case .display(let d):
            return NSScreen.screen(displayID: d.displayID)?.frame ?? .zero
        case .window(let w):
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: w.frame.minX, y: primaryHeight - w.frame.maxY, width: w.frame.width, height: w.frame.height)
        }
    }
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

/// Wraps `SCStream`. Owns the recording lifecycle and
/// throttles the irregular SCK frame stream onto a stable output framerate
/// before forwarding frames to the sink.
@MainActor
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let source: CaptureSource
    private let framerate: Framerate
    private let captureCursor: Bool
    private let excludeWindowIDs: [CGWindowID]
    private weak var sink: FrameSink?

    private enum CaptureState {
        case idle
        case capturing(stream: SCStream)
        case stopped
    }
    private var captureState: CaptureState = .idle
    private let frameQueue = DispatchQueue(label: "Screensnap.frameQueue")

    /// Frame pacing, shared with the capture queue. While `.stopped` every frame is
    /// dropped; while `.running` at most one per frame interval passes. One value,
    /// so "capturing but no start time" cannot be represented.
    private enum FrameClock {
        case stopped
        case running(startedAt: CFTimeInterval, lastEmitted: CFTimeInterval?)
    }
    private let clock = OSAllocatedUnfairLock(initialState: FrameClock.stopped)

    init(
        source: CaptureSource,
        framerate: Framerate,
        captureCursor: Bool,
        excludeWindowIDs: [CGWindowID] = [],
        sink: FrameSink
    ) {
        self.source = source
        self.framerate = framerate
        self.captureCursor = captureCursor
        self.excludeWindowIDs = excludeWindowIDs
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
        config.width = Int(source.pixelSize.width)
        config.height = Int(source.pixelSize.height)

        let filter: SCContentFilter
        switch source {
        case .region(let region):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw ScreenRecorderError.displayNotFound
            }
            config.sourceRect = region.pixelRect
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

    func stop() async {
        guard case .capturing(let stream) = captureState else { return }
        self.captureState = .stopped
        clock.withLock { $0 = .stopped }
        try? await stream.stopCapture()
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

        guard let cgImage = sampleBuffer.cgImage() else { return }
        let frame = CapturedFrame(image: cgImage, timestamp: tick.elapsed, hostTime: tick.hostTime)
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
