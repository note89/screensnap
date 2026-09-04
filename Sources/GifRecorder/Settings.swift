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
        static let defaultsVersion = "persist.defaultsVersion"
    }

    private init() {
        defaults.register(defaults: [
            Key.framerate: 15,
            Key.downsample: 1,
            Key.startDelay: 3,
            Key.captureCursor: true,
            Key.outputFormat: OutputFormat.gif.rawValue,
            Key.captureMode: CaptureMode.display.rawValue,
            Key.gifskiEnabled: false,
            Key.gifskiQuality: 80,
            Key.showNotification: true,
            Key.revealInFinder: false,
            Key.copyToClipboard: true,
            Key.filenameFormat: "%Y-%m-%dT%H-%M-%S",
        ])
        migrateDefaults()
    }

    /// Registered defaults only reach installs that have never written the key,
    /// and the launcher writes every key the first time any control is touched.
    /// So existing installs would keep no countdown and region capture forever.
    /// This nudges those two keys once, and only where they still hold the value
    /// we used to ship, so a deliberate choice survives.
    private func migrateDefaults() {
        guard defaults.integer(forKey: Key.defaultsVersion) < 1 else { return }
        if defaults.integer(forKey: Key.startDelay) == 0 {
            defaults.set(3, forKey: Key.startDelay)
        }
        if defaults.string(forKey: Key.captureMode) == CaptureMode.region.rawValue {
            defaults.set(CaptureMode.display.rawValue, forKey: Key.captureMode)
        }
        defaults.set(1, forKey: Key.defaultsVersion)
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
        get { CaptureMode(rawValue: defaults.string(forKey: Key.captureMode) ?? "") ?? .display }
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
        get { defaults.string(forKey: Key.filenameFormat) ?? "%Y-%m-%dT%H-%M-%S" }
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

    /// Short, sortable filename stem derived from `filenameFormat`.
    /// The default format produces ISO-style names like `2026-05-17T14-30-00`.
    func defaultStem() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Self.dateFormat(from: filenameFormat)
        let stem = formatter.string(from: Date())
        // An unusable pattern produces an empty string, which would name every
        // recording ".gif" — a hidden file the next recording then overwrites.
        return stem.isEmpty ? Self.fallbackStem() : stem
    }

    /// A URL in `folder` that nothing occupies yet.
    ///
    /// Two recordings finishing in the same second produced the same timestamped
    /// name, and both encoders overwrite without asking (`AVAssetWriter` even
    /// deletes the existing file first), so the earlier recording simply vanished.
    func availableURL(in folder: URL, extension ext: String) throws -> URL {
        let stem = defaultStem()
        for attempt in 0..<100 {
            let name = attempt == 0 ? "\(stem).\(ext)" : "\(stem)-\(attempt + 1).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw NSError(domain: "GifRecorder", code: 9, userInfo: [
            NSLocalizedDescriptionKey: "Could not find an unused filename in \(folder.path).",
        ])
    }

    /// Translate the `%`-token format into a `DateFormatter` pattern.
    ///
    /// Everything that is not a token gets quoted. Unicode TR35 reserves every
    /// ASCII letter as a pattern character, so the bare `T` in the default
    /// `%Y-%m-%dT%H-%M-%S` has to be escaped — an unescaped one risks an invalid
    /// pattern, and an invalid pattern formats to nothing at all.
    private static func dateFormat(from format: String) -> String {
        let tokens: [Character: String] = [
            "Y": "yyyy", "m": "MM", "d": "dd", "H": "HH", "M": "mm", "S": "ss",
        ]
        var pattern = ""
        var literal = ""

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            // A single quote is the escape character, so a literal one doubles up.
            pattern += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
            literal = ""
        }

        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            let next = format.index(after: index)
            guard character == "%", next < format.endIndex else {
                literal.append(character)
                index = next
                continue
            }
            if let token = tokens[format[next]] {
                flushLiteral()
                pattern += token
            } else {
                // Unknown token, including `%%`, passes through as a literal.
                literal.append(format[next])
            }
            index = format.index(after: next)
        }
        flushLiteral()
        return pattern
    }

    private static func fallbackStem() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: Date())
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
