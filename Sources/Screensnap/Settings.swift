import Foundation
import Observation

enum CaptureMode: String, CaseIterable, Codable {
    case region
    case display
    case window

    var label: String {
        switch self {
        case .region: return "Area"
        case .display: return "Full screen"
        case .window: return "Window"
        }
    }

    var icon: String {
        switch self {
        case .region: return "rectangle.dashed"
        case .display: return "display"
        case .window: return "macwindow"
        }
    }
}

enum Facecam: String, CaseIterable, Codable {
    case off
    case bubble
}

/// Where a finished recording goes beyond the recordings folder.
struct Delivery: Equatable, Codable {
    var copyToClipboard: Bool
    var revealInFinder: Bool
}

/// User preferences. UserDefaults-backed so they survive relaunches; `@Observable`
/// so SwiftUI panes bind straight to them.
@MainActor @Observable
final class Settings {
    private enum Key {
        static let framerate = "recording.framerate"
        static let startDelay = "recording.startDelay"
        static let captureCursor = "recording.captureCursor"
        static let outputContainer = "recording.outputContainer"
        static let gifQuality = "recording.gifQuality"
        static let audioTrack = "recording.audioTrack"
        static let captureMode = "recording.captureMode"
        static let facecam = "recording.facecam"
        static let sizeLimitBytes = "recording.sizeLimitBytes"
        static let revealInFinder = "interface.revealInFinder"
        static let copyToClipboard = "interface.copyToClipboard"
        static let saveFolder = "persist.saveFolder"
        static let filenameFormat = "interface.filenameFormat"
        static let lastUpdateCheck = "updates.lastCheck"
    }

    static let defaultFilenameFormat = "%Y-%m-%dT%H-%M-%S"
    static let framerateRange = 1...60
    static let startDelayRange = 0...10

    @ObservationIgnored private let defaults: UserDefaults

    var framerate: Int { didSet { framerate = framerate.clamped(to: Self.framerateRange); defaults.set(framerate, forKey: Key.framerate) } }
    var startDelay: Int { didSet { startDelay = startDelay.clamped(to: Self.startDelayRange); defaults.set(startDelay, forKey: Key.startDelay) } }
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
            case .bytes(let bytes): defaults.set(bytes, forKey: Key.sizeLimitBytes)
            }
        }
    }
    var delivery: Delivery {
        didSet {
            defaults.set(delivery.copyToClipboard, forKey: Key.copyToClipboard)
            defaults.set(delivery.revealInFinder, forKey: Key.revealInFinder)
        }
    }
    var filenameFormat: String { didSet { defaults.set(filenameFormat, forKey: Key.filenameFormat) } }
    var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Key.saveFolder) } }
    var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: Key.lastUpdateCheck) } }

    var output: Output {
        Output.from(container: outputContainer, gifQuality: gifQuality, audio: audioTrack)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.framerate: 15,
            Key.startDelay: 0,
            Key.captureCursor: true,
            Key.copyToClipboard: true,
            Key.revealInFinder: false,
            Key.filenameFormat: Self.defaultFilenameFormat,
        ])
        framerate = defaults.integer(forKey: Key.framerate).clamped(to: Self.framerateRange)
        startDelay = defaults.integer(forKey: Key.startDelay).clamped(to: Self.startDelayRange)
        captureCursor = defaults.bool(forKey: Key.captureCursor)
        outputContainer = OutputContainer(rawValue: defaults.string(forKey: Key.outputContainer) ?? "") ?? .gif
        gifQuality = GifQuality(rawValue: defaults.string(forKey: Key.gifQuality) ?? "") ?? .fast
        audioTrack = AudioTrack(rawValue: defaults.string(forKey: Key.audioTrack) ?? "") ?? .microphone
        captureMode = CaptureMode(rawValue: defaults.string(forKey: Key.captureMode) ?? "") ?? .region
        facecam = Facecam(rawValue: defaults.string(forKey: Key.facecam) ?? "") ?? .off
        let limitBytes = Int64(defaults.integer(forKey: Key.sizeLimitBytes))
        sizeLimit = limitBytes > 0 ? .bytes(limitBytes) : .none
        delivery = Delivery(
            copyToClipboard: defaults.bool(forKey: Key.copyToClipboard),
            revealInFinder: defaults.bool(forKey: Key.revealInFinder)
        )
        filenameFormat = defaults.string(forKey: Key.filenameFormat) ?? Self.defaultFilenameFormat
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

    /// Sortable filename from `filenameFormat`; the default yields `2026-05-17T14-30-00.gif`.
    func newRecordingURL(for output: Output) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = filenameFormat
            .replacingOccurrences(of: "%Y", with: "yyyy")
            .replacingOccurrences(of: "%m", with: "MM")
            .replacingOccurrences(of: "%d", with: "dd")
            .replacingOccurrences(of: "%H", with: "HH")
            .replacingOccurrences(of: "%M", with: "mm")
            .replacingOccurrences(of: "%S", with: "ss")
        let stem = formatter.string(from: Date())
        return saveFolder.appendingPathComponent(stem).appendingPathExtension(output.fileExtension)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
