@preconcurrency import AVFoundation
import Foundation

/// Microphone feed. Delivers raw PCM `CMSampleBuffer`s on a private queue to
/// whatever `deliver(to:)` named (in practice: the MP4 writer's audio channel).
/// No buffering, no format conversion — `AVAssetWriterInput` handles the PCM→AAC
/// encode. Starts before the encoder exists, so a microphone that cannot run is
/// known before the file's tracks are decided.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "Screensnap.micQueue")
    private let onLevel: (Float) -> Void
    /// Read and written on `queue`, so the delegate needs no lock. Buffers arriving
    /// before it is set are dropped, as the writer would drop audio from before the
    /// first video frame anyway.
    private var sink: ((CMSampleBuffer) -> Void)?

    /// `onLevel` gets a 0…1 loudness a few times a second, so the HUD can prove the
    /// microphone is actually hearing something.
    init(onLevel: @escaping (Float) -> Void) {
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

    /// Where sample buffers go from now on.
    func deliver(to sink: @escaping (CMSampleBuffer) -> Void) {
        queue.async { self.sink = sink }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        sink?(sampleBuffer)
        if let level = connection.audioChannels.first?.averagePowerLevel {
            onLevel(Self.normalized(decibels: level))
        }
    }

    /// −50 dB (room noise) → 0, 0 dB → 1.
    private static func normalized(decibels: Float) -> Float {
        min(1, max(0, (decibels + 50) / 50))
    }
}
