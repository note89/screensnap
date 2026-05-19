import Foundation

enum OutputFormat: String, CaseIterable {
    case gif
    case mp4
}

enum CaptureMode: String, CaseIterable {
    case region
    case display
    case window
}

/// User-tunable recording knobs. Mirrors the peek `recording-*` GSettings keys.
/// Each property is backed by `UserDefaults.standard` so changes persist across launches.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let framerate = "recording.framerate"
        static let downsample = "recording.downsample"
        static let startDelay = "recording.startDelay"
        static let captureCursor = "recording.captureCursor"
        static let outputFormat = "recording.outputFormat"
        static let captureMode = "recording.captureMode"
        static let gifskiEnabled = "recording.gifskiEnabled"
        static let gifskiQuality = "recording.gifskiQuality"
        static let showNotification = "interface.showNotification"
        static let revealInFinder = "interface.revealInFinder"
        static let copyToClipboard = "interface.copyToClipboard"
        static let saveFolder = "persist.saveFolder"
        static let filenameFormat = "interface.filenameFormat"
        static let lastRecordingPath = "persist.lastRecordingPath"
    }

    private init() {
        defaults.register(defaults: [
            Key.framerate: 15,
            Key.downsample: 1,
            Key.startDelay: 0,
            Key.captureCursor: true,
            Key.outputFormat: OutputFormat.gif.rawValue,
            Key.captureMode: CaptureMode.region.rawValue,
            Key.gifskiEnabled: false,
            Key.gifskiQuality: 80,
            Key.showNotification: true,
            Key.revealInFinder: false,
            Key.copyToClipboard: true,
            Key.filenameFormat: "%Y-%m-%dT%H-%M-%S",
        ])
    }

    var framerate: Int {
        get { defaults.integer(forKey: Key.framerate) }
        set { defaults.set(newValue.clamped(to: 1...60), forKey: Key.framerate) }
    }

    var downsample: Int {
        get { defaults.integer(forKey: Key.downsample) }
        set { defaults.set(newValue.clamped(to: 1...4), forKey: Key.downsample) }
    }

    var startDelay: Int {
        get { defaults.integer(forKey: Key.startDelay) }
        set { defaults.set(newValue.clamped(to: 0...60), forKey: Key.startDelay) }
    }

    var captureCursor: Bool {
        get { defaults.bool(forKey: Key.captureCursor) }
        set { defaults.set(newValue, forKey: Key.captureCursor) }
    }

    var outputFormat: OutputFormat {
        get { OutputFormat(rawValue: defaults.string(forKey: Key.outputFormat) ?? "") ?? .gif }
        set { defaults.set(newValue.rawValue, forKey: Key.outputFormat) }
    }

    var captureMode: CaptureMode {
        get { CaptureMode(rawValue: defaults.string(forKey: Key.captureMode) ?? "") ?? .region }
        set { defaults.set(newValue.rawValue, forKey: Key.captureMode) }
    }

    var gifskiEnabled: Bool {
        get { defaults.bool(forKey: Key.gifskiEnabled) }
        set { defaults.set(newValue, forKey: Key.gifskiEnabled) }
    }

    var gifskiQuality: Int {
        get { defaults.integer(forKey: Key.gifskiQuality) }
        set { defaults.set(newValue.clamped(to: 20...100), forKey: Key.gifskiQuality) }
    }

    var showNotification: Bool {
        get { defaults.bool(forKey: Key.showNotification) }
        set { defaults.set(newValue, forKey: Key.showNotification) }
    }

    var revealInFinder: Bool {
        get { defaults.bool(forKey: Key.revealInFinder) }
        set { defaults.set(newValue, forKey: Key.revealInFinder) }
    }

    var copyToClipboard: Bool {
        get { defaults.bool(forKey: Key.copyToClipboard) }
        set { defaults.set(newValue, forKey: Key.copyToClipboard) }
    }

    var filenameFormat: String {
        get { defaults.string(forKey: Key.filenameFormat) ?? "Recording %Y-%m-%d %H-%M-%S" }
        set { defaults.set(newValue, forKey: Key.filenameFormat) }
    }

    /// URL of the most recent successfully-saved recording. nil if nothing
    /// has been recorded yet, or if the file at the saved path no longer exists.
    var lastRecordingURL: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastRecordingPath),
                  !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set { defaults.set(newValue?.path ?? "", forKey: Key.lastRecordingPath) }
    }

    /// Default: ~/Documents/gif-recordings/ — auto-created on first access.
    /// Set explicitly via `Settings.shared.saveFolder = ...` to override.
    var saveFolder: URL {
        get {
            if let path = defaults.string(forKey: Key.saveFolder), !path.isEmpty {
                return URL(fileURLWithPath: path)
            } else {
                return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("gif-recordings", isDirectory: true)
            }
        }
        set { defaults.set(newValue.path, forKey: Key.saveFolder) }
    }

    /// Short, sortable filename derived from `filenameFormat`.
    /// The default format produces ISO-style names like `2026-05-17T14-30-00.gif`.
    func defaultFilename(extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let fmt = filenameFormat
            .replacingOccurrences(of: "%Y", with: "yyyy")
            .replacingOccurrences(of: "%m", with: "MM")
            .replacingOccurrences(of: "%d", with: "dd")
            .replacingOccurrences(of: "%H", with: "HH")
            .replacingOccurrences(of: "%M", with: "mm")
            .replacingOccurrences(of: "%S", with: "ss")
        formatter.dateFormat = fmt
        return "\(formatter.string(from: Date())).\(ext)"
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
