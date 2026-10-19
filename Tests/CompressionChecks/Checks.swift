import Foundation
@preconcurrency import AVFoundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(description: message) }
    print("✓ \(message)")
}

/// Synthetic moving colour bars and a tone. No recordings, codec tools, or test
/// fixtures are downloaded; this exercises the same native frameworks as the app.
private func makeFixture(at url: URL, withAudio: Bool = true) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 640,
        AVVideoHeightKey: 360,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000],
    ])
    let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 640,
        kCVPixelBufferHeightKey as String: 360,
    ])
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ])
    writer.add(video)
    if withAudio { writer.add(audio) }
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for frame in 0..<60 {
                while !video.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error! }
                    try await Task.sleep(for: .milliseconds(2))
                }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pixels.pixelBufferPool!, &buffer) == kCVReturnSuccess,
                      let buffer else { throw CheckFailure(description: "fixture pixel buffer allocation") }
                CVPixelBufferLockBaseAddress(buffer, [])
                let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<360 {
                    for x in 0..<640 {
                        let i = y * stride + x * 4
                        bytes[i] = UInt8((x + frame * 7) % 256)
                        bytes[i + 1] = UInt8((y + frame * 3) % 256)
                        bytes[i + 2] = UInt8((x + y + frame * 11) % 256)
                        bytes[i + 3] = 255
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard pixels.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error! }
            }
            video.markAsFinished()
        }
        if withAudio {
            group.addTask {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
                for start in stride(from: 0, to: 96_000, by: 1_024) {
                    while !audio.isReadyForMoreMediaData {
                        guard writer.status == .writing else { throw writer.error! }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    let count = min(1_024, 96_000 - start)
                    let samples = (0..<count).map { Float(sin(Double(start + $0) * 2 * .pi * 440 / 48_000) * 0.2) }
                    var block: CMBlockBuffer?
                    let byteCount = count * MemoryLayout<Float>.size
                    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
                          let block else { throw CheckFailure(description: "fixture audio allocation") }
                    let copied = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }
                    guard copied == kCMBlockBufferNoErr else { throw CheckFailure(description: "fixture audio copy") }
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: Int64(start), timescale: 48_000), decodeTimeStamp: .invalid)
                    var sample: CMSampleBuffer?
                    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format.formatDescription, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
                          let sample else { throw CheckFailure(description: "fixture audio sample") }
                    guard audio.append(sample) else { throw writer.error! }
                }
                audio.markAsFinished()
            }
        }
        try await group.waitForAll()
    }
    writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error! }
}

private func audioPayloads(_ url: URL) async throws -> [Data] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
        throw CheckFailure(description: "missing audio track")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    guard reader.startReading() else { throw reader.error! }
    var payloads: [Data] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let result = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard result == kCMBlockBufferNoErr else { throw CheckFailure(description: "reading audio payload") }
        payloads.append(data)
    }
    guard reader.status == .completed else { throw reader.error! }
    return payloads
}

@main
private struct CompressionChecks {
    static func main() async {
        let deadline = Task {
            try await Task.sleep(for: .seconds(30))
            FileHandle.standardError.write(Data("Compression checks timed out.\n".utf8))
            exit(1)
        }
        defer { deadline.cancel() }
        do {
            let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let source = folder.appendingPathComponent("source.mp4")
            try await makeFixture(at: source)
            let budget = VideoBudget(dimensions: Dimensions(width: 320, height: 180), bitsPerSecond: 250_000)
            let output = folder.appendingPathComponent("compressed.mp4")
            try await HEVCTranscoder.transcode(AVURLAsset(url: source), to: output, budget: budget, framerate: 30) { _ in }
            let asset = AVURLAsset(url: output)
            let video = try await asset.loadTracks(withMediaType: .video).first!
            let size = try await video.load(.naturalSize)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            let descriptions = try await video.load(.formatDescriptions)
            try require(size == CGSize(width: 320, height: 180), "transcode respects the requested frame size")
            try require(descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_HEVC, "output is HEVC")
            try require(abs(duration - 2) < 0.05, "transcode preserves the recording duration")
            let originalAudio = try await audioPayloads(source)
            let compressedAudio = try await audioPayloads(output)
            try require(!originalAudio.isEmpty && originalAudio == compressedAudio, "audio packets are copied unchanged")

            let silentSource = folder.appendingPathComponent("silent.mp4")
            let silentOutput = folder.appendingPathComponent("silent-compressed.mp4")
            try await makeFixture(at: silentSource, withAudio: false)
            try await HEVCTranscoder.transcode(AVURLAsset(url: silentSource), to: silentOutput, budget: budget, framerate: 30) { _ in }
            let silentAsset = AVURLAsset(url: silentOutput)
            let silentTracks = try await silentAsset.loadTracks(withMediaType: .audio)
            let silentDuration = CMTimeGetSeconds(try await silentAsset.load(.duration))
            try require(silentTracks.isEmpty && abs(silentDuration - 2) < 0.05, "recordings without audio remain complete and silent")

            // A readable MP4 header with missing media data must fail. Checking only
            // writer.status incorrectly accepted the partial output as successful.
            let sourceBytes = try Data(contentsOf: source)
            let damaged = folder.appendingPathComponent("damaged.mp4")
            let damagedBytes = sourceBytes.prefix(sourceBytes.count / 2)
            try damagedBytes.write(to: damaged)
            guard let recording = Recording(url: damaged), let info = await MediaInfo.load(recording) else {
                throw CheckFailure(description: "damaged fixture must retain readable media metadata")
            }
            do {
                _ = try await Compressor.compress(recording, info: info, to: .fit(.p480), placement: .replaceOriginal, originals: .month) { _ in }
                throw CheckFailure(description: "a truncated recording was accepted and replaced")
            } catch is CompressionError {
                try require(try Data(contentsOf: damaged) == damagedBytes, "read failure leaves the original byte-for-byte intact")
                try require(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(OriginalsRetention.folderName).path), "read failure does not archive an original or publish a partial result")
            }

            let cancelled = Task {
                try await HEVCTranscoder.transcode(AVURLAsset(url: source), to: folder.appendingPathComponent("cancelled.mp4"), budget: budget, framerate: 30) { _ in }
            }
            cancelled.cancel()
            do {
                try await cancelled.value
                throw CheckFailure(description: "an already cancelled transcode succeeded")
            } catch is CancellationError {
                print("✓ cancellation before startup throws without crashing")
            }

            let progress = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let resumeAfterCancellation = DispatchSemaphore(value: 0)
            let active = Task {
                defer { progress.continuation.finish() }
                try await HEVCTranscoder.transcode(AVURLAsset(url: source), to: folder.appendingPathComponent("cancelled-active.mp4"), budget: budget, framerate: 30) { _ in
                    progress.continuation.yield(())
                    // Hold the first appended sample until the test cancels, so a
                    // fast encoder cannot finish before cancellation is exercised.
                    resumeAfterCancellation.wait()
                }
            }
            for await _ in progress.stream {
                active.cancel()
                resumeAfterCancellation.signal()
                break
            }
            do {
                try await active.value
                throw CheckFailure(description: "cancellation while transcoding succeeded")
            } catch is CancellationError {
                print("✓ cancellation while pumping finishes without a crash or hang")
            }
            print("All compression checks passed.")
        } catch {
            FileHandle.standardError.write(Data("Compression check failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
