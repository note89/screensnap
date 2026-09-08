import SwiftUI

struct HUDView: View {
    let coordinator: Coordinator

    private var pillOpacity: Double {
        if case .settled(.saved) = coordinator.phase { return 0.72 }
        return 0.86
    }

    var body: some View {
        HStack(spacing: 12) {
            switch coordinator.phase {
            case .idle, .pickingSource:
                EmptyView()
            case .countingDown(let remaining, let output):
                Text("\(remaining)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 28)
                    .contentTransition(.numericText(countsDown: true))
                Text("Recording \(output.label) in…").foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 0)
                PillButton(title: "Cancel", role: .quiet) { coordinator.cancelCountdown() }
            case .recording(let run):
                RecordingRow(run: run, micLevel: coordinator.micLevel, finish: coordinator.finish, discard: coordinator.discard)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .frame(maxWidth: HUDPanel.size.width - 24)
        .background(Capsule().fill(Color.black.opacity(pillOpacity)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .frame(width: HUDPanel.size.width, height: HUDPanel.size.height)
        .animation(.easeOut(duration: 0.18), value: coordinator.phase)
    }
}

private struct RecordingRow: View {
    let run: RecordingRun
    let micLevel: Float
    let finish: () -> Void
    let discard: () -> Void

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .opacity(pulse ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
        TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
            Text(Self.elapsed(from: run.startedAt, to: context.date))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        Chip(text: run.output.label)
        Text(run.dimensions.label).font(.caption).foregroundStyle(.white.opacity(0.5))
        if run.output.recordsMicrophone {
            MicMeter(level: micLevel)
        }
        Spacer(minLength: 4)
        PillButton(title: "Finish", role: .primary, action: finish)
            .help("⌘⇧.")
        PillButton(systemImage: "xmark", role: .quiet, action: discard)
            .help("Discard")
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
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
                Text("Saved · \(recording.bytes.formatted)\(coordinator.settings.delivery.copyToClipboard ? " · ⌘V to paste" : "")")
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
