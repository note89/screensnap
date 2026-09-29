import AppKit
import Darwin
import SwiftUI

@main
struct ScreensnapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(coordinator: delegate.coordinator)
        } label: {
            MenuBarLabel(status: delegate.coordinator.menuBar)
        }
        Window("Screensnap", id: "settings") {
            SettingsWindowView(coordinator: delegate.coordinator)
        }
        .defaultSize(width: 860, height: 600)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = Coordinator()

    func applicationWillFinishLaunching(_ notification: Notification) {
        CrashTrail.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator.handleQuitRequest()
    }
}

/// Uncaught Obj-C exceptions and fatal signals leave a line in stderr before the
/// process dies; some AppKit faults otherwise vanish without a DiagnosticReport.
enum CrashTrail {
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let trace = exception.callStackSymbols.joined(separator: "\n")
            FileHandle.standardError.write(Data("[Screensnap] UNCAUGHT EXCEPTION: \(exception.name.rawValue) — \(exception.reason ?? "")\n\(trace)\n".utf8))
        }
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { signum in
                let msg = "[Screensnap] FATAL SIGNAL \(signum)\n"
                _ = msg.withCString { write(STDERR_FILENO, $0, strlen($0)) }
                _exit(128 + signum)
            }
        }
    }
}
