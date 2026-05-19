import AppKit
import Darwin

// Capture uncaught Obj-C exceptions (AppKit/Foundation throws live here)
// and POSIX signals (SIGSEGV, SIGABRT, SIGBUS) so we always leave a trail
// in stderr / unified log before the process dies. Without this, certain
// AppKit faults vanish without producing a DiagnosticReport.
NSSetUncaughtExceptionHandler { exception in
    let trace = exception.callStackSymbols.joined(separator: "\n")
    FileHandle.standardError.write(Data("[GifRecorder] UNCAUGHT EXCEPTION: \(exception.name.rawValue) — \(exception.reason ?? "")\n\(trace)\n".utf8))
}
for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE] {
    signal(sig) { signum in
        let msg = "[GifRecorder] FATAL SIGNAL \(signum)\n"
        _ = msg.withCString { write(STDERR_FILENO, $0, strlen($0)) }
        _exit(128 + signum)
    }
}

// `main.swift` runs on the main thread but is not in a Swift actor context.
// AppDelegate is `@MainActor`, so we bridge with `assumeIsolated` — safe here
// because we know we're on the main thread by the runtime contract of `main.swift`.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
}
