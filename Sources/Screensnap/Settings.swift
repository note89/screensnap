import Foundation
import Observation

enum CaptureMode: String, CaseIterable, Codable {
    case display
    case window
    case region

    var label: String {
        switch self {
        case .display: return "Full screen"
        case .window: return "Window"
        case .region: return "Area"
        }
    }

    var icon: String {
        switch self {
        case .display: return "display"
        case .window: return "macwindow"
        case .region: return "rectangle.dashed"
        }
    }
}

/// Seconds between choosing what to record and the first frame. Always within
/// `range`: the value is clamped once, when it is made, so no setter has to.
struct StartDelay: Hashable {
    static let range = 0...10
    let seconds: Int

    init(clamping seconds: Int) { self.seconds = seconds.clamped(to: Self.range) }
}

/// Frames captured per second. Always within `range`, for the same reason.
struct Framerate: Hashable {
    static let range = 1...60
    let fps: Int

    init(clamping fps: Int) { self.fps = fps.clamped(to: Self.range) }
}

enum Facecam: String, CaseIterable, Codable {
    case off
    case bubble
}

/// Which finished recordings land on the clipboard. GIFs are what people paste
/// into chats and issues; MP4s are usually uploaded or kept.
enum ClipboardCopy: String, CaseIterable, Codable {
    case always
    case gifsOnly
    case never

    var label: String {
        switch self {
        case .always: return "Always"
        case .gifsOnly: return "GIFs only"
        case .never: return "Never"
        }
    }

    func applies(to output: OutputContainer) -> Bool {
        switch self {
        case .always: return true
        case .gifsOnly: return output == .gif
        case .never: return false
        }
    }
}

/// Where a finished recording goes beyond the recordings folder.
struct Delivery: Equatable, Codable {
    var clipboard: ClipboardCopy
    var revealInFinder: Bool
}

/// User preferences. UserDefaults-backed so they survive relaunches; `@Observable`
/// so SwiftUI panes bind straight to them.
@MainActor @Observable
final class Settings {
    private enum Key {
        /// Legacy single rate, read once to seed `gifFramerate`.
        static let framerate = "recording.framerate"
        static let gifFramerate = "recording.framerate.gif"
        static let mp4Framerate = "recording.framerate.mp4"
        static let startDelay = "recording.startDelay"
        static let captureCursor = "recording.captureCursor"
        static let outputContainer = "recording.outputContainer"
        static let gifQuality = "recording.gifQuality"
        static let audioTrack = "recording.audioTrack"
        static let captureMode = "recording.captureMode"
        static let facecam = "recording.facecam"
        static let sizeLimitBytes = "recording.sizeLimitBytes"
        static let revealInFinder = "interface.revealInFinder"
        /// Legacy on/off switch, read once to seed `clipboardCopy`.
        static let copyToClipboard = "interface.copyToClipboard"
        static let clipboardCopy = "interface.clipboardCopy"
        static let saveFolder = "persist.saveFolder"
        static let filenameFormat = "interface.filenameFormat"
        static let lastUpdateCheck = "updates.lastCheck"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// GIFs stay small at low rates; MP4 compresses motion well, so it can afford more.
    var gifFramerate: Framerate { didSet { defaults.set(gifFramerate.fps, forKey: Key.gifFramerate) } }
    var mp4Framerate: Framerate { didSet { defaults.set(mp4Framerate.fps, forKey: Key.mp4Framerate) } }

    func framerate(for container: OutputContainer) -> Framerate {
        switch container {
        case .gif: return gifFramerate
        case .mp4: return mp4Framerate
        }
    }
    var startDelay: StartDelay { didSet { defaults.set(startDelay.seconds, forKey: Key.startDelay) } }
    var captureCursor: Bool { didSet { defaults.set(captureCursor, forKey: Key.captureCursor) } }
    var outputContainer: OutputContainer { didSet { defaults.set(outputContainer.rawValue, forKey: Key.outputContainer) } }
    var gifQuality: GifQuality { didSet { defaults.set(gifQuality.rawValue, forKey: Key.gifQuality) } }
    var audioTrack: AudioTrack { didSet { defaults.set(audioTrack.rawValue, forKey: Key.audioTrack) } }
    var captureMode: CaptureMode { didSet { defaults.set(captureMode.rawValue, forKey: Key.captureMode) } }
    var facecam: Facecam { didSet { defaults.set(facecam.rawValue, forKey: Key.facecam) } }
    var sizeLimit: SizeLimit {
        didSet {
            switch sizeLimit {
            case .none: defaults.set(0, forKey: Key.sizeLimitBytes)
            case .atMost(let ceiling): defaults.set(ceiling.size.bytes, forKey: Key.sizeLimitBytes)
            }
        }
    }
    var delivery: Delivery {
        didSet {
            defaults.set(delivery.clipboard.rawValue, forKey: Key.clipboardCopy)
            defaults.set(delivery.revealInFinder, forKey: Key.revealInFinder)
        }
    }
    var filenameTemplate: FilenameTemplate { didSet { defaults.set(filenameTemplate.text, forKey: Key.filenameFormat) } }
    var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Key.saveFolder) } }
    var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: Key.lastUpdateCheck) } }

    var output: Output {
        Output.from(container: outputContainer, gifQuality: gifQuality, audio: audioTrack)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.framerate: 15,
            Key.mp4Framerate: 30,
            Key.startDelay: 0,
            Key.captureCursor: true,
            Key.revealInFinder: false,
            Key.sizeLimitBytes: 100_000_000,
        ])
        gifFramerate = Framerate(clamping: defaults.object(forKey: Key.gifFramerate) as? Int ?? defaults.integer(forKey: Key.framerate))
        mp4Framerate = Framerate(clamping: defaults.integer(forKey: Key.mp4Framerate))
        startDelay = StartDelay(clamping: defaults.integer(forKey: Key.startDelay))
        captureCursor = defaults.bool(forKey: Key.captureCursor)
        outputContainer = OutputContainer(rawValue: defaults.string(forKey: Key.outputContainer) ?? "") ?? .gif
        gifQuality = GifQuality(rawValue: defaults.string(forKey: Key.gifQuality) ?? "") ?? .fast
        audioTrack = AudioTrack(rawValue: defaults.string(forKey: Key.audioTrack) ?? "") ?? .microphone
        captureMode = CaptureMode(rawValue: defaults.string(forKey: Key.captureMode) ?? "") ?? .region
        facecam = Facecam(rawValue: defaults.string(forKey: Key.facecam) ?? "") ?? .off
        sizeLimit = SizeLimit.Ceiling(bytes: Int64(defaults.integer(forKey: Key.sizeLimitBytes))).map(SizeLimit.atMost) ?? .none
        delivery = Delivery(
            clipboard: ClipboardCopy(rawValue: defaults.string(forKey: Key.clipboardCopy) ?? "")
                ?? (defaults.object(forKey: Key.copyToClipboard) as? Bool == false ? .never : .gifsOnly),
            revealInFinder: defaults.bool(forKey: Key.revealInFinder)
        )
        filenameTemplate = FilenameTemplate.parseOrStandard(defaults.string(forKey: Key.filenameFormat))
        saveFolder = Self.resolveSaveFolder(stored: defaults.string(forKey: Key.saveFolder))
        lastUpdateCheck = defaults.object(forKey: Key.lastUpdateCheck) as? Date
    }

    static let defaultSaveFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Screensnap", isDirectory: true)

    /// Earlier builds saved into ~/Documents/gif-recordings with no setting written.
    /// If that folder still holds recordings, keep using it rather than orphaning them.
    private static let legacySaveFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("gif-recordings", isDirectory: true)

    private static func resolveSaveFolder(stored: String?) -> URL {
        if let stored, !stored.isEmpty { return URL(fileURLWithPath: stored, isDirectory: true) }
        let legacyHasRecordings = ((try? FileManager.default.contentsOfDirectory(atPath: legacySaveFolder.path)) ?? [])
            .contains { ["gif", "mp4"].contains(($0 as NSString).pathExtension.lowercased()) }
        return legacyHasRecordings ? legacySaveFolder : defaultSaveFolder
    }

    /// Where a recording started now gets saved: named by `filenameTemplate` (the
    /// standard one yields `2026-05-17T14-30-00.gif`) and never an existing file.
    func newRecordingURL(for output: Output, at date: Date = Date()) -> URL {
        FileManager.default.unusedURL(in: saveFolder, stem: filenameTemplate.stem(at: date), pathExtension: output.fileExtension)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
