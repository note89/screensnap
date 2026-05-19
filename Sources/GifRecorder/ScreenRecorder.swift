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
}

/// What to capture. Each case maps to a different `SCContentFilter` constructor.
enum CaptureSource {
    /// A rectangular region on a specific display.
    case region(SelectedRegion)
    /// An entire display.
    case display(SCDisplay)
    /// A single window — works even when the window is in a different Space.
    case window(SCWindow)

    /// Output dimensions in pixels (accounting for the backing scale on
    /// Retina displays). The region case already carries pixel-space rects;
    /// the others are in points and need to be scaled here.
    var pixelSize: CGSize {
        switch self {
        case .region(let r):
            return r.pixelRect.size
        case .display(let d):
            let scale = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID
            })?.backingScaleFactor ?? 2
            return CGSize(width: CGFloat(d.width) * scale, height: CGFloat(d.height) * scale)
        case .window(let w):
            let midPoint = CGPoint(x: w.frame.midX, y: w.frame.midY)
            let scale = NSScreen.screens.first(where: { $0.frame.contains(midPoint) })?.backingScaleFactor ?? 2
            return CGSize(width: w.frame.width * scale, height: w.frame.height * scale)
        }
    }
}

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
}

/// Wraps `SCStream` for region capture. Owns the recording lifecycle and
/// throttles the irregular SCK frame stream onto a stable output framerate
/// before forwarding frames to the sink.
@MainActor
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let source: CaptureSource
    private let framerate: Int
    private let captureCursor: Bool
    private let excludeWindowIDs: [CGWindowID]
    private weak var sink: FrameSink?

    private struct FrameThrottle {
        var startHostTime: CFTimeInterval
        var lastEmittedTime: CFTimeInterval
    }

    private enum CaptureState {
        case idle
        case capturing(stream: SCStream)
        case stopped
    }
    private var captureState: CaptureState = .idle
    private let frameQueue = DispatchQueue(label: "GifRecorder.frameQueue")

    private let throttle = OSAllocatedUnfairLock(
        initialState: FrameThrottle(startHostTime: 0, lastEmittedTime: -.infinity))
    private let isCapturingFlag = OSAllocatedUnfairLock(initialState: false)

    /// The pixel size of the output, available after `start()` succeeds.
    private(set) var pixelSize: CGSize = .zero

    init(
        source: CaptureSource,
        framerate: Int,
        captureCursor: Bool,
        excludeWindowIDs: [CGWindowID] = [],
        sink: FrameSink
    ) {
        self.source = source
        self.framerate = max(1, framerate)
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
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framerate))
        config.colorSpaceName = CGColorSpace.sRGB

        let filter: SCContentFilter
        switch source {
        case .region(let region):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw ScreenRecorderError.displayNotFound
            }
            let excluded = content.windows.filter { excludeWindowIDs.contains($0.windowID) }
            config.sourceRect = region.pixelRect
            config.width = Int(region.pixelRect.width)
            config.height = Int(region.pixelRect.height)
            pixelSize = region.pixelRect.size
            filter = SCContentFilter(display: display, excludingWindows: excluded)

        case .display(let display):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let excluded = content.windows.filter { excludeWindowIDs.contains($0.windowID) }
            // Find the NSScreen matching this display for correct Retina scale
            let scale = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }).map { $0.backingScaleFactor } ?? 2
            let w = Int(Double(display.width) * scale)
            let h = Int(Double(display.height) * scale)
            config.width = w
            config.height = h
            pixelSize = CGSize(width: w, height: h)
            filter = SCContentFilter(display: display, excludingWindows: excluded)

        case .window(let window):
            // `desktopIndependentWindow` captures the window across Space changes
            // and remains valid even when the window is minimized or on another Space.
            let midPoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let scale = NSScreen.screens.first(where: { $0.frame.contains(midPoint) })?.backingScaleFactor ?? 2
            config.width = Int(window.frame.size.width * scale)
            config.height = Int(window.frame.size.height * scale)
            pixelSize = CGSize(width: config.width, height: config.height)
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()

        throttle.withLock { state in
            state.startHostTime = CACurrentMediaTime()
            state.lastEmittedTime = -.infinity
        }
        isCapturingFlag.withLock { $0 = true }
        self.captureState = .capturing(stream: stream)
    }

    func stop() async {
        guard case .capturing(let stream) = captureState else { return }
        self.captureState = .stopped
        isCapturingFlag.withLock { $0 = false }
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

        guard isCapturingFlag.withLock({ $0 }) else { return }

        // ── User contribution point #2 ──────────────────────────────────────
        // We need to map SCStream's irregular frame stream (fires whenever
        // the screen actually updates) onto our requested output framerate.
        //
        // The simplest policy — the one below — is "drop frames that arrive
        // sooner than 1/framerate after the last accepted frame." That's
        // fine for screencasts of UI motion but it has a subtle issue: if
        // the screen is *static*, no frames arrive at all, and the GIF will
        // hold the last frame for an arbitrarily long period.
        //
        // Other policies you might pick:
        //   (a) "Drop-newest" + a heartbeat timer that re-emits the last
        //       frame if nothing has arrived for >2× the interval. Keeps
        //       the GIF timeline honest during static moments.
        //   (b) Buffer the latest frame and emit on a fixed CADisplayLink-
        //       style timer. Decouples capture rate from emit rate.
        //   (c) Emit every frame as it arrives and let the encoder set
        //       per-frame durations from the actual host-time deltas.
        //       Most accurate timing, but variable file size / encoder load.
        //
        // Pick the policy that matches how you'll use this app. The current
        // implementation is (a-without-the-heartbeat) — fine for the MVP.
        // ────────────────────────────────────────────────────────────────────

        let (shouldEmit, elapsed) = throttle.withLock { state -> (Bool, CFTimeInterval) in
            let now = CACurrentMediaTime()
            let e = now - state.startHostTime
            let interval = 1.0 / Double(framerate)
            guard e - state.lastEmittedTime >= interval else { return (false, e) }
            state.lastEmittedTime = e
            return (true, e)
        }
        guard shouldEmit else { return }

        guard let cgImage = sampleBuffer.cgImage() else { return }
        let frame = CapturedFrame(image: cgImage, timestamp: elapsed)
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
