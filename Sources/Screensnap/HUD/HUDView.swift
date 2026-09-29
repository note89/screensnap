import SwiftUI

struct HUDView: View {
    let coordinator: Coordinator
    let hud: HUDPanel

    var body: some View {
        switch hud.chrome.layout {
        case .pill(let axis):
            Pill(coordinator: coordinator, hud: hud, axis: axis)
        case .marker:
            TuckedMarker(phase: coordinator.phase, show: hud.togglePresence)
                .frame(width: HUDLayout.marker.size.width, height: HUDLayout.marker.size.height)
        }
    }
}

/// Horizontal along the bottom edge, a narrow column on a side edge. Messages
/// (encoding, saved, failed) are always horizontal; the panel sizes for that.
private struct Pill: View {
    let coordinator: Coordinator
    let hud: HUDPanel
    let axis: Axis

    private var pillOpacity: Double {
        if case .settled(.saved) = coordinator.phase { return 0.72 }
        return 0.86
    }

    private var stack: AnyLayout {
        switch axis {
        case .horizontal: return AnyLayout(HStackLayout(spacing: 10))
        case .vertical: return AnyLayout(VStackLayout(spacing: 10))
        }
    }

    var body: some View {
        let size = HUDLayout.pill(axis).size
        stack {
            DragGrip(axis: axis)
            switch coordinator.phase {
            case .idle, .pickingSource:
                EmptyView()
            case .starting(let output):
                ProgressView().controlSize(.small).tint(.white)
                if axis == .horizontal {
                    Text("Starting \(output.label)…").foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 0)
                }
            case .countingDown(let remaining, let output):
                Text("\(remaining)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 28)
                    .contentTransition(.numericText(countsDown: true))
                switch axis {
                case .horizontal:
                    Text("Recording \(output.label) in…").foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 0)
                    PillButton(title: "Cancel", role: .quiet) { coordinator.cancelCountdown() }
                case .vertical:
                    PillButton(systemImage: "xmark", role: .quiet) { coordinator.cancelCountdown() }.help("Cancel")
                }
                TuckButton(tuck: hud.togglePresence)
            case .recording(let run):
                RecordingRow(run: run, axis: axis, micLevel: coordinator.micLevel, finishKeys: coordinator.hotkey.advertisedKeys, finish: coordinator.finish, togglePause: coordinator.togglePause, restart: coordinator.restart, discard: coordinator.discard)
                TuckButton(tuck: hud.togglePresence)
            case .finishing(let step):
                ProgressView().controlSize(.small).tint(.white)
                Text(step.label).foregroundStyle(.white.opacity(0.85))
                if case .fittingToLimit(_, let progress) = step {
                    ProgressView(value: progress).tint(.white).frame(width: 90)
                }
            case .settled(let settlement):
                SettledRow(settlement: settlement, coordinator: coordinator)
            }
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .padding(.horizontal, axis == .horizontal ? 16 : 8)
        .padding(.vertical, axis == .horizontal ? 10 : 14)
        .frame(minWidth: 48, minHeight: 48)
        .frame(maxWidth: axis == .horizontal ? size.width - 24 : nil)
        .background(Capsule().fill(Color.black.opacity(pillOpacity)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in hud.dragMoved() }
                .onEnded { _ in hud.dragEnded() }
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.18), value: coordinator.phase)
    }
}

/// Says "this can be moved"; the whole pill is the handle, not just the grip.
private struct DragGrip: View {
    let axis: Axis

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.35))
            .rotationEffect(.degrees(axis == .horizontal ? 90 : 0))
            .help("Drag to the bottom, left or right edge")
    }
}

private struct TuckButton: View {
    let tuck: () -> Void

    var body: some View {
        PillButton(systemImage: "eye.slash", role: .quiet, action: tuck)
            .help("Hide controls — \(HUDPanel.presenceShortcut) (\(HUDPanel.presenceShortcutSpoken)) brings them back")
    }
}

/// What is left of the pill when tucked: small, faint, in a corner, and clickable.
private struct TuckedMarker: View {
    let phase: Phase
    let show: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: show) {
            HStack(spacing: 5) {
                indicator
                Text(HUDPanel.presenceShortcut)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help("Show controls — \(HUDPanel.presenceShortcut) (\(HUDPanel.presenceShortcutSpoken))")
    }

    @ViewBuilder private var indicator: some View {
        switch phase {
        case .recording(let run):
            switch run.clock {
            case .running: Circle().fill(Color.red).frame(width: 7, height: 7)
            case .paused: Image(systemName: "pause.fill").font(.system(size: 8)).foregroundStyle(.orange)
            }
        case .countingDown(let remaining, _):
            Text("\(remaining)").monospacedDigit()
        case .idle, .pickingSource, .starting, .finishing, .settled:
            Circle().fill(Color.white.opacity(0.6)).frame(width: 7, height: 7)
        }
    }
}

private struct RecordingRow: View {
    let run: RecordingRun
    let axis: Axis
    let micLevel: Float
    /// nil when the global shortcut could not be registered.
    let finishKeys: String?
    let finish: () -> Void
    let togglePause: () -> Void
    let restart: () -> Void
    let discard: () -> Void

    @State private var pulse = false

    var body: some View {
        switch run.clock {
        case .running(let since, _):
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Self.format(run.clock.elapsed(at: context.date)))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        case .paused(let total):
            Image(systemName: "pause.fill").font(.system(size: 10)).foregroundStyle(.orange)
            Text(Self.format(total)).monospacedDigit().foregroundStyle(.orange)
        }
        if axis == .horizontal {
            Chip(text: run.output.label)
        }
        if run.output.recordsMicrophone {
            MicMeter(level: micLevel)
        }
        switch axis {
        case .horizontal:
            Spacer(minLength: 4)
            PillButton(title: "Finish", role: .primary, action: finish).help(finishKeys ?? "Finish")
        case .vertical:
            PillButton(systemImage: "stop.fill", role: .primary, action: finish).help(finishKeys.map { "Finish (\($0))" } ?? "Finish")
        }
        switch run.clock {
        case .running:
            PillButton(systemImage: "pause.fill", role: .quiet, action: togglePause).help("Pause")
        case .paused:
            PillButton(systemImage: "play.fill", role: .quiet, action: togglePause).help("Resume")
        }
        PillButton(systemImage: "arrow.counterclockwise", role: .quiet, action: restart)
            .help("Start over")
        PillButton(systemImage: "xmark", role: .quiet, action: discard)
            .help("Discard")
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct SettledRow: View {
    let settlement: Settlement
    let coordinator: Coordinator

    var body: some View {
        switch settlement {
        case .saved(let recording, let notes):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved · \(recording.bytes.formatted)\(coordinator.settings.delivery.clipboard.applies(to: OutputContainer(url: recording.url)) ? " · ⌘V to paste" : "")")
                    .foregroundStyle(.white)
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · ")).font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            PillButton(title: "Show", role: .quiet) {
                coordinator.library.reveal(recording)
                coordinator.dismissSettled()
            }
        case .discarded:
            Image(systemName: "trash").foregroundStyle(.white.opacity(0.7))
            Text("Discarded").foregroundStyle(.white.opacity(0.8))
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
            Text(message).foregroundStyle(.white).lineLimit(2)
            Spacer(minLength: 4)
            PillButton(systemImage: "xmark", role: .quiet) { coordinator.dismissSettled() }
        }
    }
}

private struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
    }
}

private struct MicMeter: View {
    let level: Float

    private static let bars = 5

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<Self.bars, id: \.self) { index in
                let threshold = Float(index + 1) / Float(Self.bars)
                RoundedRectangle(cornerRadius: 1)
                    .fill(level >= threshold * 0.9 ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 3, height: 6 + CGFloat(index) * 3)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .help("Microphone level")
    }
}

private struct PillButton: View {
    enum Role { case primary, quiet }

    var title: String?
    var systemImage: String?
    let role: Role
    let action: () -> Void

    init(title: String, role: Role, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    init(systemImage: String, role: Role, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .bold)) }
                if let title { Text(title) }
            }
            .padding(.horizontal, title == nil ? 8 : 12)
            .padding(.vertical, 6)
            .foregroundStyle(role == .primary ? Color.black : Color.white)
            .background(Capsule().fill(role == .primary ? Color.white : Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}
