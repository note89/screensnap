import AppKit
import SwiftUI

/// The quick menu: start, stop, grab the last clip. Configuration lives in the window.
struct MenuView: View {
    let coordinator: Coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
            .onAppear { coordinator.refreshPermissions() }
        Divider()
        switch coordinator.phase {
        case .recording:
            Button("Finish recording") { coordinator.finish() }
            Button("Discard recording") { coordinator.discard() }
        case .countingDown:
            Button("Cancel countdown") { coordinator.cancelCountdown() }
        case .idle, .settled, .pickingSource, .finishing:
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    coordinator.record(mode)
                } label: {
                    Label("Record \(mode.label.lowercased())", systemImage: mode.icon)
                }
                .disabled(coordinator.phase.isBusy)
            }
        }
        Divider()
        RecordingOptions(settings: coordinator.settings)
            .disabled(coordinator.phase.isBusy)
        Divider()
        if let last = coordinator.lastRecording {
            Button("Copy last recording · \(last.bytes.formatted)") { coordinator.copyLast() }
        }
        Button("Recordings…") { open(.recordings) }
        switch coordinator.screenRecordingAccess {
        case .granted:
            EmptyView()
        case .grantedSinceLaunch:
            Divider()
            Button("Relaunch to activate Screen Recording") { Relaunch.now() }
        case .missing:
            Divider()
            Button("⚠ Fix permissions…") { open(.capture) }
        }
        if case .available(let release) = coordinator.updater.state {
            Divider()
            Button("Update to \(release.version.description)…") { open(.about) }
        }
        Divider()
        Button("Open Screensnap…") { open(.capture) }
        Button("Quit Screensnap") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ section: SettingsSection) {
        coordinator.settingsSection = section
        coordinator.refreshPermissions()
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var statusLine: String {
        switch coordinator.phase {
        case .idle:
            switch coordinator.screenRecordingAccess {
            case .granted: return "⌘⇧. records \(coordinator.settings.captureMode.label.lowercased())"
            case .grantedSinceLaunch: return "Screen Recording granted — relaunch to activate"
            case .missing: return "Screen Recording permission missing"
            }
        case .pickingSource(let mode): return "choosing \(mode.label.lowercased())…"
        case .countingDown(let remaining, _): return "recording in \(remaining)…"
        case .recording(let run): return "recording \(run.output.label) — ⌘⇧. to finish"
        case .finishing(let step): return step.label
        case .settled(.saved(let recording, _)): return "saved \(recording.name) · \(recording.bytes.formatted)"
        case .settled(.discarded): return "discarded"
        case .settled(.failed(let message)): return message
        }
    }
}

/// The two choices people flip between recordings: file type and size cap. Everything
/// finer (GIF quality, microphone, custom sizes) stays in the settings window.
private struct RecordingOptions: View {
    @Bindable var settings: Settings

    var body: some View {
        Picker("Format", selection: $settings.outputContainer) {
            Text("GIF").tag(OutputContainer.gif)
            Text("MP4").tag(OutputContainer.mp4)
        }
        .pickerStyle(.inline)
        Picker(selection: $settings.sizeLimit) {
            ForEach(SizeLimit.presets, id: \.limit) { Text($0.label).tag($0.limit) }
            if !SizeLimit.presets.contains(where: { $0.limit == settings.sizeLimit }) {
                Text(settings.sizeLimit.label).tag(settings.sizeLimit)
            }
        } label: {
            Text("Size limit · \(settings.sizeLimit.label)")
        }
        .pickerStyle(.menu)
    }
}
