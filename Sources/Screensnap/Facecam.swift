import AVFoundation
import AppKit
import CoreGraphics

enum CaptureDeviceError: LocalizedError {
    case noCamera
    case noMicrophone
    case cannotConfigure(String)

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No camera found on this Mac."
        case .noMicrophone: return "No microphone found on this Mac."
        case .cannotConfigure(let what): return "Could not configure capture: \(what)"
        }
    }
}

/// Live webcam feed. Owns an `AVCaptureSession` delivering BGRA frames and
/// keeps only the most recent one; the compositor pulls it at the *screen*
/// framerate, so camera and screen rates never need to match.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "Screensnap.cameraQueue")
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?

    func start() throws {
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CaptureDeviceError.noCamera
        }
        session.beginConfiguration()
        // 640×480 is plenty for a small circular bubble and keeps per-frame
        // conversion cheap.
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureDeviceError.cannotConfigure("camera input rejected")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw CaptureDeviceError.cannotConfigure("camera output rejected")
        }
        session.addOutput(output)
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    /// Most recent camera frame as a CGImage, or nil while the camera warms up.
    var latestFrame: CGImage? {
        lock.lock()
        let buffer = latestBuffer
        lock.unlock()
        guard let buffer else { return nil }
        return CGImage.fromBGRA(pixelBuffer: buffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latestBuffer = buffer
        lock.unlock()
    }
}

/// Where the bubble sits inside the recording, as fractions of the frame so the
/// same value works in preview points and recording pixels. CG axes: y grows upward.
struct FacecamPlacement: Equatable {
    var center: CGPoint
    /// Fraction of the frame's short edge.
    var diameter: CGFloat

    static let bottomLeft = FacecamPlacement(center: CGPoint(x: 0.16, y: 0.16), diameter: 0.275)
}

/// Draws the camera frame as a mirrored circular bubble onto a screen frame.
enum FacecamCompositor {

    static func circleRect(in size: CGSize, placement: FacecamPlacement) -> CGRect {
        let diameter = min(size.width, size.height) * placement.diameter
        let rect = CGRect(
            x: size.width * placement.center.x - diameter / 2,
            y: size.height * placement.center.y - diameter / 2,
            width: diameter, height: diameter
        )
        let bounds = CGRect(origin: .zero, size: size)
        return CGRect(
            x: min(max(rect.minX, bounds.minX), bounds.maxX - diameter),
            y: min(max(rect.minY, bounds.minY), bounds.maxY - diameter),
            width: diameter, height: diameter
        )
    }

    static func composite(screen: CGImage, camera: CGImage, placement: FacecamPlacement) -> CGImage? {
        let size = CGSize(width: screen.width, height: screen.height)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(
            data: nil,
            width: screen.width,
            height: screen.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.draw(screen, in: CGRect(origin: .zero, size: size))

        let circle = circleRect(in: size, placement: placement)

        // Aspect-fill the camera frame into the circle, mirrored so the
        // recording matches what the user sees in the preview bubble.
        let camSize = CGSize(width: camera.width, height: camera.height)
        let scale = max(circle.width / camSize.width, circle.height / camSize.height)
        let drawSize = CGSize(width: camSize.width * scale, height: camSize.height * scale)
        let drawRect = CGRect(
            x: circle.midX - drawSize.width / 2,
            y: circle.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        ctx.saveGState()
        ctx.addEllipse(in: circle)
        ctx.clip()
        ctx.translateBy(x: drawRect.midX, y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.translateBy(x: -drawRect.midX, y: 0)
        ctx.draw(camera, in: drawRect)
        ctx.restoreGState()

        let ringWidth = max(2, circle.width * 0.02)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(ringWidth)
        ctx.strokeEllipse(in: circle.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))

        return ctx.makeImage()
    }
}

/// Floating circular self-view that is also the bubble's authoritative position:
/// drag it anywhere inside the captured area and the recording follows. Excluded
/// from screen capture — the bubble in the output comes from the compositor.
@MainActor
final class FacecamPreviewWindow {
    private let panel: NSPanel
    private let captureFrame: CGRect

    var windowID: CGWindowID? {
        let number = panel.windowNumber
        return number > 0 ? CGWindowID(number) : nil
    }

    /// Read per frame by the compositor; derived from where the user left the panel.
    var placement: FacecamPlacement {
        guard captureFrame.width > 0, captureFrame.height > 0 else { return .bottomLeft }
        let frame = panel.frame
        return FacecamPlacement(
            center: CGPoint(
                x: (frame.midX - captureFrame.minX) / captureFrame.width,
                y: (frame.midY - captureFrame.minY) / captureFrame.height
            ),
            diameter: frame.width / min(captureFrame.width, captureFrame.height)
        )
    }

    init(session: AVCaptureSession, captureFrame: CGRect) {
        self.captureFrame = captureFrame
        let shortEdge = min(captureFrame.width, captureFrame.height)
        let diameter = min(max(shortEdge * FacecamPlacement.bottomLeft.diameter, 60), 260)
        let margin = diameter * 0.15
        let rect = CGRect(x: captureFrame.minX + margin, y: captureFrame.minY + margin, width: diameter, height: diameter)
        panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        // Belt and braces with the SCStream exclusion list, and the layer that
        // actually holds. `SCContentFilter(excludingWindows:)` can only exclude a
        // window that turned up in `SCShareableContent.windows`, and a borderless
        // non-activating panel often does not — the filter then silently excludes
        // nothing and this preview gets captured *in addition to* the bubble the
        // compositor draws, at a different diameter, which is what a "double circle"
        // in the recording actually is. `sharingType = .none` is enforced by the
        // window server, so it does not depend on that lookup succeeding.
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = diameter / 2
        preview.masksToBounds = true
        preview.borderWidth = 2
        preview.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let connection = preview.connection {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)
        panel.contentView = view
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
}

extension CGImage {
    /// Convert a BGRA `CVPixelBuffer` into a `CGImage`. Returns nil on failure.
    static func fromBGRA(pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
}
