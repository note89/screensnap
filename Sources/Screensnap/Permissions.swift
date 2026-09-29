import AVFoundation
import AppKit
import CoreGraphics

struct PermissionReport: Equatable {
    var screenRecording: Bool
    var camera: DeviceAccess
    var microphone: DeviceAccess
}

/// Camera and microphone lists in System Settings only contain apps that have asked
/// at least once, and they accept no drops — so `notAsked` must be answered with the
/// system prompt, and only `denied` with a trip to System Settings.
enum DeviceAccess: Equatable {
    case granted
    case notAsked
    case denied

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notAsked
        default: self = .denied
        }
    }
}

enum PermissionPane {
    case screenRecording
    case camera
    case microphone

    fileprivate var anchor: String {
        switch self {
        case .screenRecording: return "Privacy_ScreenCapture"
        case .camera: return "Privacy_Camera"
        case .microphone: return "Privacy_Microphone"
        }
    }
}

enum ScreenRecordingAccess {
    case granted
    /// TCC says yes, but this process started before the grant; ScreenCaptureKit
    /// only sees the grant in a fresh process.
    case grantedSinceLaunch
    case missing
}

extension PermissionReport {
    func screenRecordingAccess(since launch: PermissionReport) -> ScreenRecordingAccess {
        switch (launch.screenRecording, screenRecording) {
        case (_, false): return .missing
        case (true, true): return .granted
        case (false, true): return .grantedSinceLaunch
        }
    }
}

/// TCC state, made visible. Screen Recording is the one that needs a relaunch after
/// granting; camera and microphone apply to the live process.
enum Permissions {
    static func check() -> PermissionReport {
        PermissionReport(
            screenRecording: CGPreflightScreenCaptureAccess(),
            camera: DeviceAccess(AVCaptureDevice.authorizationStatus(for: .video)),
            microphone: DeviceAccess(AVCaptureDevice.authorizationStatus(for: .audio))
        )
    }

    /// Shows the system dialog the first time; later calls are no-ops, so pair with
    /// `openSettings(.screenRecording)` for users who already declined.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSettings(_ pane: PermissionPane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func ensureCameraAccess() async -> Bool {
        await ensureCaptureAccess(for: .video)
    }

    static func ensureMicrophoneAccess() async -> Bool {
        await ensureCaptureAccess(for: .audio)
    }

    private static func ensureCaptureAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: mediaType)
        default: return false
        }
    }
}

/// Quits, then opens a fresh copy. The copy is launched only once the quit is
/// accepted: a quit can be held up by a recording or a save, or cancelled, and two
/// instances must never run side by side.
@MainActor
enum Relaunch {
    private enum Request {
        case none
        case afterQuit
    }

    private static var request = Request.none

    /// The default delay lets the menu or HUD that triggered the relaunch finish closing.
    static func now(after delay: Duration = .milliseconds(400)) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            request = .afterQuit
            NSApp.terminate(nil)
        }
    }

    /// The quit this relaunch rode on was cancelled.
    static func cancel() {
        request = .none
    }

    /// From `applicationWillTerminate`, when the quit can no longer be cancelled.
    static func launchIfRequested() {
        guard case .afterQuit = request else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        try? process.run()
    }
}
