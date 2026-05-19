import AppKit
import CoreGraphics

/// Screen Recording permission helpers. TCC governs access; this thin
/// wrapper makes the state visible and gives the user direct buttons to
/// the relevant System Settings pane.
enum Permissions {

    /// Returns whether the *current process* has Screen Recording permission.
    /// No prompt is shown. Cheap to call; safe to poll.
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system Screen Recording permission dialog the first time
    /// the app asks. After the user grants, the running process still has to
    /// be restarted — TCC won't retroactively grant access to a live process.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Open System Settings to the Screen Recording pane.
    /// On macOS 13+ this URL scheme is the only documented way to deep-link
    /// into a specific privacy pane.
    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Open the top-level Privacy & Security pane (fallback if the deep link
    /// gets rejected on some macOS update).
    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        NSWorkspace.shared.open(url)
    }
}
