@preconcurrency import AVFoundation
import Foundation

/// Re-encodes an MP4 as HEVC at a bitrate the caller chooses, and copies the audio
/// across untouched. `AVAssetExportSession` cannot do this: its presets pick their own
/// bitrate, which for a screen recording is several times what the picture needs.
enum HEVCTranscoder {
    static func transcode(_ asset: AVURLAsset, to url: URL, budget: VideoBudget, framerate: Double, progress: @escaping ProgressHandler) async throws {
        try Task.checkCancellation()
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
            guard reader.canAdd(output), writer.canAdd(input) else { throw CompressionError.exportUnavailable }
            reader.add(output)
            writer.add(input)
            audio = (output, input)
        }

        // Cancel only after all pumps have stopped. Cancelling the writer from a
        // separate cancellation handler can race input registration or append and
        // raise an Objective-C exception instead of throwing CancellationError.
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        guard reader.startReading() else { throw CompressionError.exportFailed(reader.error?.localizedDescription ?? "could not read the recording") }
        guard writer.startWriting() else { throw CompressionError.exportFailed(writer.error?.localizedDescription ?? "could not start writing") }
        writer.startSession(atSourceTime: .zero)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await pump(videoOutput, into: videoInput, reader: reader, writer: writer) { sample in
                    progress(min(1, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) / duration))
                }
            }
            if let audio {
                group.addTask { try await pump(audio.output, into: audio.input, reader: reader, writer: writer, onSample: nil) }
            }
            try await group.waitForAll()
        }
        try Task.checkCancellation()
        // A nil sample means either end-of-stream or a read/decode failure. A
        // writer can successfully finish the partial samples in the latter case;
        // never let that partial file replace the original recording.
        guard reader.status == .completed else {
            throw CompressionError.exportFailed(reader.error?.localizedDescription ?? "could not read the complete recording")
        }
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw CompressionError.exportFailed(writer.error?.localizedDescription ?? "could not finish writing")
        }
    }

    /// Each pump owns one input. While backpressured it yields briefly, checking
    /// terminal states and task cancellation instead of waiting indefinitely for a
    /// readiness callback that a failed/cancelled writer will never deliver.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, reader: AVAssetReader, writer: AVAssetWriter, onSample: (@Sendable (CMSampleBuffer) -> Void)?) async throws {
        while true {
            try Task.checkCancellation()
            guard reader.status != .failed else {
                throw CompressionError.exportFailed(reader.error?.localizedDescription ?? "could not read the complete recording")
            }
            guard writer.status == .writing else {
                throw CompressionError.exportFailed(writer.error?.localizedDescription ?? "could not write the recording")
            }
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            guard let sample = output.copyNextSampleBuffer() else {
                guard reader.status != .failed else {
                    throw CompressionError.exportFailed(reader.error?.localizedDescription ?? "could not read the complete recording")
                }
                input.markAsFinished()
                return
            }
            guard input.append(sample) else {
                throw CompressionError.exportFailed(writer.error?.localizedDescription ?? "could not write a sample")
            }
            onSample?(sample)
        }
    }
}
