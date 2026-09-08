import AVFoundation
import AppKit
import CoreGraphics

struct PermissionReport: Equatable {
    var screenRecording: Bool
    var camera: Bool
    var microphone: Bool
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
            camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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

enum Relaunch {
    static func now() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            try? process.run()
            NSApp.terminate(nil)
        }
    }
}
