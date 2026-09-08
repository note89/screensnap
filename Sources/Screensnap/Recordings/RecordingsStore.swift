import AppKit
import Observation

/// The recordings folder, as a list. Rescans when the folder changes on disk, so
/// files renamed or trashed in Finder disappear here too.
@MainActor @Observable
final class RecordingsStore {
    private(set) var folder: URL
    /// Newest first.
    private(set) var recordings: [Recording] = []
    private(set) var infos: [URL: MediaInfo] = [:]
    private(set) var thumbnails: [URL: CGImage] = [:]

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
        let live = Set(recordings.map(\.url))
        infos = infos.filter { live.contains($0.key) }
        thumbnails = thumbnails.filter { live.contains($0.key) }
    }

    func recording(at url: URL) -> Recording? {
        recordings.first { $0.url == url }
    }

    func info(for recording: Recording) -> MediaInfo? {
        if let cached = infos[recording.url] { return cached }
        Task {
            guard let loaded = await MediaInfo.load(recording) else { return }
            infos[recording.url] = loaded
        }
        return nil
    }

    func thumbnail(for recording: Recording) -> CGImage? {
        if let cached = thumbnails[recording.url] { return cached }
        Task {
            guard let image = await Thumbnail.make(for: recording) else { return }
            thumbnails[recording.url] = image
        }
        return nil
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

    func rename(_ recording: Recording, to stem: String) throws {
        let cleaned = stem.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != recording.name else { return }
        let target = folder.appendingPathComponent(cleaned).appendingPathExtension(recording.url.pathExtension)
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
