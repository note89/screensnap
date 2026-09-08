@preconcurrency import AVFoundation
import Foundation

/// Microphone feed. Delivers raw PCM `CMSampleBuffer`s on a private queue;
/// the caller decides where they go (in practice: the MP4 writer's audio
/// channel). No buffering, no format conversion — `AVAssetWriterInput`
/// handles the PCM→AAC encode.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "Screensnap.micQueue")
    private let onSampleBuffer: (CMSampleBuffer) -> Void
    private let onLevel: (Float) -> Void

    /// `onLevel` gets a 0…1 loudness a few times a second, so the HUD can prove the
    /// microphone is actually hearing something.
    init(onSampleBuffer: @escaping (CMSampleBuffer) -> Void, onLevel: @escaping (Float) -> Void) {
        self.onSampleBuffer = onSampleBuffer
        self.onLevel = onLevel
    }

    func start() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw CaptureDeviceError.noMicrophone
        }
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureDeviceError.cannotConfigure("microphone input rejected")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw CaptureDeviceError.cannotConfigure("microphone output rejected")
        }
        session.addOutput(output)
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSampleBuffer(sampleBuffer)
        if let level = connection.audioChannels.first?.averagePowerLevel {
            onLevel(Self.normalized(decibels: level))
        }
    }

    /// −50 dB (room noise) → 0, 0 dB → 1.
    private static func normalized(decibels: Float) -> Float {
        min(1, max(0, (decibels + 50) / 50))
    }
}
