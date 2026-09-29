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

/// The recordings folder, as a list. Rescans when the folder changes on disk, so
/// files renamed or trashed in Finder disappear here too.
@MainActor @Observable
final class RecordingsStore {
    private(set) var folder: URL
    /// Newest first.
    private(set) var recordings: [Recording] = []
    /// Keyed by the whole `Recording` (URL, size, creation date), so a file replaced
    /// in place — a size-limit shrink — is a new key and never shows stale facts.
    private(set) var infos: [Recording: ReadOutcome<MediaInfo>] = [:]
    private(set) var thumbnails: [Recording: ReadOutcome<CGImage>] = [:]

    /// Reads in flight. Not observed: views call `info(for:)` from `body`, and
    /// marking a read as started must not trigger another redraw.
    @ObservationIgnored private var readingInfo: Set<Recording> = []
    @ObservationIgnored private var readingThumbnail: Set<Recording> = []
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
        ensureFolderExists()
        rescan()
        watch()
    }

    var totalBytes: ByteCount { ByteCount(recordings.reduce(0) { $0 + $1.bytes.bytes }) }

    func setFolder(_ url: URL) {
        folder = url
        infos = [:]
        thumbnails = [:]
        ensureFolderExists()
        rescan()
        watch()
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

    /// The cached info, or nil while it is being read (one read per file, started
    /// by the first ask) or when the file cannot be read.
    func info(for recording: Recording) -> MediaInfo? {
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

    func thumbnail(for recording: Recording) -> CGImage? {
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

    /// A blank or unchanged name leaves the file alone. The file keeps its extension.
    func rename(_ recording: Recording, to stem: String) throws {
        let name = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != recording.name else { return }
        if let character = name.first(where: FilenameTemplate.forbiddenCharacters.contains) { throw RenameError.forbidden(character) }
        guard !name.hasPrefix(".") else { throw RenameError.startsWithDot }
        let target = folder.appendingPathComponent(name).appendingPathExtension(recording.url.pathExtension)
        // The volume is usually case-insensitive, so "clip" → "Clip" finds the file
        // itself at the target; that rename is allowed.
        let changesOnlyCase = name.caseInsensitiveCompare(recording.name) == .orderedSame
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
    case forbidden(Character)
    case startsWithDot
    case taken(String)

    var errorDescription: String? {
        switch self {
        case .forbidden(let character): return "File names cannot contain “\(character)”."
        case .startsWithDot: return "A name starting with “.” would be hidden in Finder."
        case .taken(let filename): return "“\(filename)” already exists in this folder."
        }
    }
}
