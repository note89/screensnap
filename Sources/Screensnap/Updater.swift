import AppKit
import Foundation
import Observation

struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let parts: [Int]

    init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parsed = trimmed.split(separator: ".").map { Int($0) }
        guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else { return nil }
        parts = parsed.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let l = index < lhs.parts.count ? lhs.parts[index] : 0
            let r = index < rhs.parts.count ? rhs.parts[index] : 0
            if l != r { return l < r }
        }
        return false
    }
}

struct Release: Equatable {
    let version: SemanticVersion
    let assetURL: URL
    let pageURL: URL
    let notes: String
}

enum UpdateState: Equatable {
    case idle
    case checking
    case noReleases
    case upToDate
    case available(Release)
    case downloading(Release, progress: Double)
    case installing(Release)
    /// The new build is unpacked but this bundle's location is read-only; it waits in Finder.
    case readyInFinder(URL)
    case failed(String)
}

enum UpdateError: LocalizedError {
    case notABundle
    case badResponse(Int)
    case noZipAsset
    case unpackFailed(String)
    case noAppInArchive
    case untrustedSignature

    var errorDescription: String? {
        switch self {
        case .notABundle: return "Updates need Screensnap to run from a .app bundle."
        case .badResponse(let code): return "GitHub answered \(code)."
        case .noZipAsset: return "The latest release has no .zip to download."
        case .unpackFailed(let reason): return "Could not unpack the update: \(reason)"
        case .noAppInArchive: return "The downloaded archive holds no .app."
        case .untrustedSignature: return "The download is not signed by Screensnap's developer, so it was not installed."
        }
    }
}

/// What `install()` did. `installed` means the bundle on disk is the new version and
/// this process is stale; the caller relaunches.
enum InstallOutcome {
    case installed
    case parkedInFinder
    case failed
    case nothingToInstall
}

/// Checks GitHub Releases for a newer tag, downloads the zip and swaps the bundle in
/// place. Only builds signed with the team's Developer ID install; that same
/// identity is what lets TCC keep treating the update as the same app.
@MainActor @Observable
final class Updater {
    static let repository = "note89/screensnap"
    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// Apple-issued certificate belonging to this team: a Developer ID release, never
    /// a download someone swapped on the way. Keep in step with Scripts/release.sh.
    static let signingRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "43BT9GR95A""#

    private(set) var state: UpdateState = .idle
    let currentVersion: SemanticVersion?

    init() {
        currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init)
    }

    var releasesPage: URL { URL(string: "https://github.com/\(Self.repository)/releases")! }

    func checkIfDue(settings: Settings) {
        let due = settings.lastUpdateCheck.map { Date().timeIntervalSince($0) > Self.checkInterval } ?? true
        guard due else { return }
        settings.lastUpdateCheck = Date()
        Task { await check() }
    }

    func check() async {
        guard let currentVersion else {
            state = .failed(UpdateError.notABundle.localizedDescription)
            return
        }
        state = .checking
        do {
            guard let release = try await Self.fetchLatest() else {
                state = .noReleases
                return
            }
            state = release.version > currentVersion ? .available(release) : .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install() async -> InstallOutcome {
        guard case .available(let release) = state else { return .nothingToInstall }
        do {
            let bundleURL = Bundle.main.bundleURL
            guard bundleURL.pathExtension == "app" else { throw UpdateError.notABundle }

            state = .downloading(release, progress: 0)
            let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("screensnap-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zipURL = try await download(release, to: workDir)

            state = .installing(release)
            let newApp = try await Self.unpack(zipURL, into: workDir)
            try await Self.verifySignature(newApp)

            let parent = bundleURL.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? parent
                let parked = downloads.appendingPathComponent("Screensnap \(release.version).app")
                try? FileManager.default.removeItem(at: parked)
                try FileManager.default.moveItem(at: newApp, to: parked)
                NSWorkspace.shared.activateFileViewerSelecting([parked])
                state = .readyInFinder(parked)
                return .parkedInFinder
            }
            try Self.swap(current: bundleURL, with: newApp, backupIn: workDir)
            return .installed
        } catch {
            state = .failed(error.localizedDescription)
            return .failed
        }
    }

    // MARK: GitHub

    private struct ReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]
    }

    private static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError.badResponse(status) }
        let decoded = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        guard let version = SemanticVersion(decoded.tag_name) else { return nil }
        guard let asset = decoded.assets.first(where: { $0.name.hasSuffix(".zip") }) else { throw UpdateError.noZipAsset }
        return Release(version: version, assetURL: asset.browser_download_url, pageURL: decoded.html_url, notes: decoded.body ?? "")
    }

    private func download(_ release: Release, to workDir: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: release.assetURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }
        let zipURL = workDir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: temp, to: zipURL)
        state = .downloading(release, progress: 1)
        return zipURL
    }

    // MARK: Install steps

    private static func unpack(_ zipURL: URL, into workDir: URL) async throws -> URL {
        let target = workDir.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let result = try await Shell.run("/usr/bin/ditto", ["-xk", zipURL.path, target.path])
        guard result.status == 0 else { throw UpdateError.unpackFailed(result.output) }
        let apps = (try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noAppInArchive }
        return app
    }

    /// The leading "=" makes codesign read the requirement as text, not a file path.
    private static func verifySignature(_ app: URL) async throws {
        let result = try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(signingRequirement)", app.path])
        guard result.status == 0 else { throw UpdateError.untrustedSignature }
    }

    private static func swap(current: URL, with replacement: URL, backupIn workDir: URL) throws {
        let backup = workDir.appendingPathComponent("previous.app")
        try FileManager.default.moveItem(at: current, to: backup)
        do {
            try FileManager.default.moveItem(at: replacement, to: current)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: current)
            throw error
        }
    }
}

enum Shell {
    struct Result {
        let status: Int32
        let output: String
    }

    static func run(_ executable: String, _ arguments: [String]) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: Result(status: finished.terminationStatus, output: String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}
