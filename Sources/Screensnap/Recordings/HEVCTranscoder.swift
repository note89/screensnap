@preconcurrency import AVFoundation
import Foundation

/// Re-encodes an MP4 as HEVC at a bitrate the caller chooses, and copies the audio
/// across untouched. `AVAssetExportSession` cannot do this: its presets pick their own
/// bitrate, which for a screen recording is several times what the picture needs.
enum HEVCTranscoder {
    static func transcode(_ asset: AVURLAsset, to url: URL, budget: VideoBudget, framerate: Double, progress: @escaping ProgressHandler) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw CompressionError.unreadable }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = max(0.001, CMTimeGetSeconds(try await asset.load(.duration)))
        let transform = try await videoTrack.load(.preferredTransform)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: budget.dimensions.width,
            kCVPixelBufferHeightKey as String: budget.dimensions.height,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw CompressionError.exportUnavailable }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: budget.dimensions.width,
            AVVideoHeightKey: budget.dimensions.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: budget.bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: Int(framerate.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int(framerate.rounded()) * 2,
            ],
        ])
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { throw CompressionError.exportUnavailable }
        writer.add(videoInput)

        var audio: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            let hint = try await audioTrack.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audio = (output, input)
            }
        }

        guard reader.startReading() else { throw CompressionError.exportFailed(reader.error?.localizedDescription ?? "could not read the recording") }
        guard writer.startWriting() else { throw CompressionError.exportFailed(writer.error?.localizedDescription ?? "could not start writing") }
        writer.startSession(atSourceTime: .zero)

        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump(videoOutput, into: videoInput) { sample in
                        progress(min(1, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) / duration))
                    }
                }
                if let audio {
                    group.addTask { await pump(audio.output, into: audio.input, onSample: nil) }
                }
            }
        } onCancel: {
            reader.cancelReading()
            writer.cancelWriting()
        }
        try Task.checkCancellation()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CompressionError.exportFailed((writer.error ?? reader.error)?.localizedDescription ?? "unknown")
        }
    }

    /// Feeds samples from `output` into `input` as the writer asks for them, until the
    /// reader runs dry or the writer stops accepting. Why it stopped is read off the
    /// reader and writer afterwards.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, onSample: (@Sendable (CMSampleBuffer) -> Void)?) async {
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "screensnap.transcode.\(input.mediaType.rawValue)")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        finished.resume()
                        return
                    }
                    onSample?(sample)
                    guard input.append(sample) else {
                        input.markAsFinished()
                        finished.resume()
                        return
                    }
                }
            }
        }
    }
}
