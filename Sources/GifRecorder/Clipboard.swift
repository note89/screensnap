import AppKit
import UniformTypeIdentifiers

/// Publishes finished recordings on the system pasteboard.
///
/// This lives in one place because there used to be three copies of the logic —
/// the menu bar's "Copy last recording", the launcher's "Copy again" button, and
/// the automatic copy after a recording finishes — and all three shared the same
/// two defects:
///
///   1. They published the file with `NSURL.write(to:)`, the deprecated call that
///      declares only the Carbon-era `NSURLPboardType`. Finder, Mail, Slack,
///      Messages and browsers all read `public.file-url` (or the legacy filenames
///      flavor), so ⌘V after "Copy last recording" quietly did nothing.
///   2. The media bytes were pushed afterwards from a detached task via
///      `setData(_:forType:)`. That only succeeds for a type declared by the most
///      recent declaration, which the URL write had already replaced — so the data
///      flavor was dropped too, and whatever did land raced the user's paste.
///
/// Video was the worst case: the byte-copy was gated on a `.gif` extension, so an
/// MP4 got nothing but the flavor no modern app reads.
///
/// The payload is now assembled first and published in a single declaration.
@MainActor
enum Clipboard {
    /// Above this size the recording is published as a file reference only. The
    /// pasteboard server keeps inlined bytes resident, and a few minutes of
    /// full-screen capture runs to hundreds of megabytes.
    private static let maxInlineBytes = 64 * 1024 * 1024

    /// The pre-UTI flavor. Deprecated for a decade, and still the first thing a
    /// number of apps check when deciding whether a paste is "a file".
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    enum CopyError: LocalizedError {
        case fileMissing(URL)
        case pasteboardRejected

        var errorDescription: String? {
            switch self {
            case .fileMissing(let url):
                return "\"\(url.lastPathComponent)\" is no longer on disk."
            case .pasteboardRejected:
                return "The system pasteboard refused the recording."
            }
        }
    }

    /// Put a recording on the general pasteboard.
    ///
    /// Always publishes the file reference, which is what Finder, Mail and the chat
    /// apps use to attach the recording. Small enough files also carry their raw
    /// bytes under the file's own UTI, so apps that paste media inline can do that
    /// instead. Returns whether the bytes were inlined.
    @discardableResult
    static func copy(_ url: URL) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CopyError.fileMissing(url)
        }

        // Read before touching the pasteboard: a partially-populated pasteboard is
        // worse than a slow one, and the read happens off the main actor so a large
        // recording doesn't freeze the UI.
        let inline = await inlinePayload(for: url)

        // Apps take the first type they understand. Images paste inline usefully
        // (an animated GIF really does show up in Slack), video almost never does,
        // so the byte flavor only leads for images.
        var types: [NSPasteboard.PasteboardType] = []
        if let inline = inline, inline.preferred { types.append(inline.type) }
        types.append(.fileURL)
        types.append(filenamesType)
        if let inline = inline, !inline.preferred { types.append(inline.type) }

        // `declareTypes` clears the pasteboard itself, and it is what makes the
        // subsequent `setData`/`setString` calls succeed — each of them fails for a
        // type that was not declared. Their results are checked rather than
        // discarded, so a refused write reaches the user instead of looking like a
        // successful copy that pastes nothing.
        let pasteboard = NSPasteboard.general
        _ = pasteboard.declareTypes(types, owner: nil)
        let wroteURL = pasteboard.setString(url.absoluteString, forType: .fileURL)
        let wrotePath = pasteboard.setPropertyList([url.path], forType: filenamesType)
        var wroteBytes = false
        if let inline = inline {
            wroteBytes = pasteboard.setData(inline.data, forType: inline.type)
        }
        guard wroteURL || wrotePath || wroteBytes else { throw CopyError.pasteboardRejected }
        return wroteBytes
    }

    /// Copy and tell the user what happened. Callable from any context.
    nonisolated static func copyWithFeedback(_ url: URL?) {
        Task { @MainActor in
            guard let url = url else {
                Toast.show("Nothing to copy", detail: "No recording yet.")
                return
            }
            do {
                try await copy(url)
                Toast.show("Copied — paste with ⌘V", detail: url.lastPathComponent)
            } catch {
                Toast.show("Couldn't copy", detail: error.localizedDescription)
            }
        }
    }

    // MARK: - Inline bytes

    private struct Inline {
        let type: NSPasteboard.PasteboardType
        let data: Data
        /// Whether apps should be offered the bytes ahead of the file reference.
        let preferred: Bool
    }

    private static func inlinePayload(for url: URL) async -> Inline? {
        guard let utType = UTType(filenameExtension: url.pathExtension), utType.isDeclared else {
            return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= maxInlineBytes else { return nil }

        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data = data else { return nil }

        return Inline(
            type: NSPasteboard.PasteboardType(utType.identifier),
            data: data,
            preferred: utType.conforms(to: .image)
        )
    }
}
