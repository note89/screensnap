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

    /// Whether the process had permission when it started. `AppDelegate` touches
    /// this first thing so the lazy `let` is pinned to launch time.
    ///
    /// TCC does not grant a live process: after the user flips the toggle,
    /// `hasScreenRecording` turns true but `SCStream` still refuses to capture
    /// until the app is relaunched. Every "can we record?" decision has to look at
    /// both, or the launcher says "granted" while every recording fails.
    static let hadScreenRecordingAtLaunch: Bool = CGPreflightScreenCaptureAccess()

    /// Granted *and* usable by this process.
    static var canCaptureNow: Bool { hasScreenRecording && hadScreenRecordingAtLaunch }

    /// Granted since launch, so only the next launch benefits.
    static var needsRelaunch: Bool { hasScreenRecording && !hadScreenRecordingAtLaunch }

    /// Relaunching only makes sense from a real `.app` bundle. A bare
    /// `swift build` executable has no bundle to reopen.
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Start a fresh copy of the app and quit this one. The half-second delay lets
    /// this process exit before the new one registers with Launch Services, so the
    /// Dock does not briefly show two icons.
    static func relaunch() {
        guard canRelaunch else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The bundle path travels as `$0`, so it never needs shell quoting.
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
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
