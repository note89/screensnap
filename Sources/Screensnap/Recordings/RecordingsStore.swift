import AppKit
import Observation

/// What reading one fact from a file produced. A file missing from a cache has not
/// been read yet; one that failed stays `.unreadable` instead of being retried on
/// every redraw.
enum ReadOutcome<Value> {
    case read(Value)
    case unreadable

    var value: Value? {
        switch self {
        case .read(let value): return value
        case .unreadable: return nil
        }
    }
}

/// The recordings folder, as a list. Owns which folder that is, remembers it across
/// launches, and rescans when it changes on disk, so files renamed or trashed in
/// Finder disappear here too.
@MainActor @Observable
final class RecordingsStore {
    private enum Key {
        static let folder = "persist.saveFolder"
    }

    private(set) var folder: URL
    /// Newest first.
    private(set) var recordings: [Recording] = []
    /// Keyed by the whole `Recording` (URL, size, creation date), so a file replaced
    /// in place — a size-limit shrink — is a new key and never shows stale facts.
    private(set) var infos: [Recording: ReadOutcome<MediaInfo>] = [:]
    private(set) var thumbnails: [Recording: ReadOutcome<CGImage>] = [:]

    /// Reads in flight. Not observed: views call `requestInfo(for:)` from `body`, and
    /// marking a read as started must not trigger another redraw.
    @ObservationIgnored private var readingInfo: Set<Recording> = []
    @ObservationIgnored private var readingThumbnail: Set<Recording> = []
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folder = Self.resolveFolder(stored: defaults.string(forKey: Key.folder))
        ensureFolderExists()
        rescan()
        watch()
    }

    static let defaultFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Screensnap", isDirectory: true)

    /// Earlier builds saved into ~/Documents/gif-recordings with no setting written.
    /// If that folder still holds recordings, keep using it rather than orphaning them.
    private static let legacyFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("gif-recordings", isDirectory: true)

    private static func resolveFolder(stored: String?) -> URL {
        if let stored, !stored.isEmpty { return URL(fileURLWithPath: stored, isDirectory: true) }
        let legacyHasRecordings = ((try? FileManager.default.contentsOfDirectory(atPath: legacyFolder.path)) ?? [])
            .contains { OutputContainer(rawValue: ($0 as NSString).pathExtension.lowercased()) != nil }
        return legacyHasRecordings ? legacyFolder : defaultFolder
    }

    var totalBytes: ByteCount { ByteCount(recordings.reduce(0) { $0 + $1.bytes.bytes }) }

    func setFolder(_ url: URL) {
        folder = url
        defaults.set(url.path, forKey: Key.folder)
        infos = [:]
        thumbnails = [:]
        ensureFolderExists()
        rescan()
        watch()
    }

    /// The file a recording started now is saved to: named by `template` (the standard
    /// one yields `2026-05-17T14-30-00.gif`), in this folder, and never an existing
    /// file. The folder is created first, in case it went away since the last scan.
    func newRecordingURL(template: FilenameTemplate, output: Output, at date: Date = Date()) -> URL {
        ensureFolderExists()
        return FileManager.default.unusedURL(in: folder, stem: template.stem(at: date).text, pathExtension: output.fileExtension)
    }

    func rescan() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        recordings = urls.compactMap(Recording.init(url:)).sorted { $0.createdAt > $1.createdAt }
        let live = Set(recordings)
        infos = infos.filter { live.contains($0.key) }
        thumbnails = thumbnails.filter { live.contains($0.key) }
    }

    func recording(at url: URL) -> Recording? {
        recordings.first { $0.url == url }
    }

    /// The cached info, or nil while it is being read or when the file cannot be read.
    /// The first ask for a file starts its read, which is why views call this from
    /// `body`: the redraw that follows finds the answer.
    func requestInfo(for recording: Recording) -> MediaInfo? {
        if let outcome = infos[recording] { return outcome.value }
        guard readingInfo.insert(recording).inserted else { return nil }
        Task {
            let loaded = await MediaInfo.load(recording)
            readingInfo.remove(recording)
            guard recordings.contains(recording) else { return }
            infos[recording] = loaded.map(ReadOutcome.read) ?? .unreadable
        }
        return nil
    }

    /// The info, read now when it is not cached. For callers that can wait.
    func loadInfo(for recording: Recording) async -> MediaInfo? {
        if let outcome = infos[recording] { return outcome.value }
        let loaded = await MediaInfo.load(recording)
        if recordings.contains(recording) { infos[recording] = loaded.map(ReadOutcome.read) ?? .unreadable }
        return loaded
    }

    /// Like `requestInfo(for:)`, for the thumbnail.
    func requestThumbnail(for recording: Recording) -> CGImage? {
        if let outcome = thumbnails[recording] { return outcome.value }
        guard readingThumbnail.insert(recording).inserted else { return nil }
        Task {
            let image = await Thumbnail.make(for: recording)
            readingThumbnail.remove(recording)
            // A read that finishes after its file was trashed, replaced or left behind
            // by a folder change must not re-add it to the cache.
            guard recordings.contains(recording) else { return }
            thumbnails[recording] = image.map(ReadOutcome.read) ?? .unreadable
        }
        return nil
    }

    /// Plays it in the user's default app for the type — QuickTime Player for MP4 unless
    /// they changed it.
    func play(_ recording: Recording) {
        NSWorkspace.shared.open(recording.url)
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
    }

    func openFolder() {
        NSWorkspace.shared.open(folder)
    }

    func trash(_ recording: Recording) throws {
        try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
        rescan()
    }

    /// A blank or unchanged name leaves the file alone; anything else must be a
    /// `FileStem`. The file keeps its extension.
    func rename(_ recording: Recording, to text: String) throws {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != recording.name else { return }
        let stem = try FileStem.parse(name).get()
        let target = folder.appendingPathComponent(stem.text).appendingPathExtension(recording.url.pathExtension)
        // The volume is usually case-insensitive, so "clip" → "Clip" finds the file
        // itself at the target; that rename is allowed.
        let changesOnlyCase = stem.text.caseInsensitiveCompare(recording.name) == .orderedSame
        if !changesOnlyCase, FileManager.default.fileExists(atPath: target.path) { throw RenameError.taken(target.lastPathComponent) }
        try FileManager.default.moveItem(at: recording.url, to: target)
        rescan()
    }

    private func ensureFolderExists() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func watch() {
        watcher?.cancel()
        watcher = nil
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleRescan() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    /// Finder writes arrive in bursts; one rescan after the burst is enough.
    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }
}

enum RenameError: LocalizedError, Equatable {
    case taken(String)

    var errorDescription: String? {
        switch self {
        case .taken(let filename): return "“\(filename)” already exists in this folder."
        }
    }
}
