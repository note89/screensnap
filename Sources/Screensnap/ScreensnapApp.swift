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
            MenuBarLabel(coordinator: delegate.coordinator)
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

private struct MenuBarLabel: View {
    let coordinator: Coordinator

    var body: some View {
        switch coordinator.phase {
        case .recording:
            TimelineView(.periodic(from: .now, by: 0.7)) { context in
                Image(nsImage: MenuBarIcon.recording(dimmed: Int(context.date.timeIntervalSinceReferenceDate / 0.7) % 2 == 0))
            }
        case .countingDown:
            Image(systemName: "timer")
        case .finishing:
            Image(systemName: "hourglass")
        case .idle, .pickingSource, .settled:
            Image(systemName: "record.circle")
        }
    }
}

enum MenuBarIcon {
    /// A real red dot — non-template so the menu bar shows the colour — inside the
    /// same ring as the idle symbol, pulsing between two alphas.
    static func recording(dimmed: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = rect.insetBy(dx: 2, dy: 2)
            NSColor.labelColor.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(ovalIn: ring)
            path.lineWidth = 1.5
            path.stroke()
            NSColor.systemRed.withAlphaComponent(dimmed ? 0.35 : 1).setFill()
            NSBezierPath(ovalIn: ring.insetBy(dx: 3.5, dy: 3.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
