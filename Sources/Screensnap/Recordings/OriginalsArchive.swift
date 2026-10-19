import Foundation

/// How long a replaced recording stays recoverable.
enum OriginalsRetention: Int, CaseIterable {
    case discard = 0
    case week = 7
    case month = 30
    case quarter = 90

    var label: String {
        switch self {
        case .discard: return "Move to the Trash"
        case .week: return "Keep for 7 days"
        case .month: return "Keep for 30 days"
        case .quarter: return "Keep for 90 days"
        }
    }

    static let folderName = "Originals"
}

/// Owns the evidence needed to expire an original: which file Screensnap archived,
/// and when it did so. Untracked files in an existing Originals folder are never
/// adopted. Hidden sidecars keep the recordings directly accessible in Finder.
enum OriginalsArchive {
    private static let recordPrefix = ".screensnap-original-"

    private struct Identity: Codable, Equatable {
        let fileNumber: UInt64
        let createdAt: Date

        static func read(_ url: URL) throws -> Identity {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let number = attributes[.systemFileNumber] as? NSNumber,
                  let createdAt = attributes[.creationDate] as? Date else {
                throw CocoaError(.fileReadUnknown)
            }
            return Identity(fileNumber: number.uint64Value, createdAt: createdAt)
        }
    }

    private struct Record: Codable {
        let version: Int
        let filename: String
        let archivedAt: Date
        let identity: Identity
    }

    /// Writes the ownership record before moving the original, so a metadata failure
    /// leaves the source in place. A failed move leaves no eligible archive record.
    @discardableResult
    static func retain(_ source: URL, now: Date = Date()) throws -> URL {
        let manager = FileManager.default
        let identity = try Identity.read(source)
        let folder = source.deletingLastPathComponent().appendingPathComponent(OriginalsRetention.folderName, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = manager.unusedURL(in: folder, stem: source.deletingPathExtension().lastPathComponent, pathExtension: source.pathExtension)
        let recordURL = folder.appendingPathComponent(recordPrefix + UUID().uuidString + ".json")
        let record = Record(version: 1, filename: destination.lastPathComponent, archivedAt: now, identity: identity)
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        do {
            try manager.moveItem(at: source, to: destination)
        } catch {
            try? manager.removeItem(at: recordURL)
            throw error
        }
        return destination
    }

    /// Missing/corrupt metadata, changed identities, directories and symlinks are
    /// left alone. File-system creation/modification dates never set the retention
    /// clock: an old recording gets a full window when it is compressed today.
    static func prune(in recordingsFolder: URL, keeping retention: OriginalsRetention, now: Date = Date()) {
        guard retention != .discard else { return }
        let manager = FileManager.default
        let folder = recordingsFolder.appendingPathComponent(OriginalsRetention.folderName, isDirectory: true)
        let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let cutoff = now.addingTimeInterval(-Double(retention.rawValue) * 86_400)
        for recordURL in files {
            let name = recordURL.lastPathComponent
            guard name.hasPrefix(recordPrefix), name.hasSuffix(".json"),
                  UUID(uuidString: String(name.dropFirst(recordPrefix.count).dropLast(5))) != nil,
                  (try? Identity.read(recordURL)) != nil,
                  let data = try? Data(contentsOf: recordURL),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.version == 1, record.archivedAt < cutoff,
                  !record.filename.isEmpty, record.filename != ".", record.filename != "..",
                  !record.filename.contains("/"), !record.filename.contains(":"),
                  !record.filename.hasPrefix(".") else { continue }
            let original = folder.appendingPathComponent(record.filename)
            guard let identity = try? Identity.read(original), identity == record.identity else { continue }
            do {
                try manager.removeItem(at: original)
                try manager.removeItem(at: recordURL)
            } catch {
                // Leave any remaining evidence in place so a later pass can retry.
            }
        }
    }
}
