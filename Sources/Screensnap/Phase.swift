import Foundation

/// Something the user asked for that this recording could not deliver. Carried
/// through the run so the settled message can say so instead of failing silently.
enum Degradation: Equatable {
    case camera(String)
    case microphone(String)
    case gifskiMissing

    var message: String {
        switch self {
        case .camera(let reason): return "no facecam — \(reason)"
        case .microphone(let reason): return "no voice — \(reason)"
        case .gifskiMissing: return "gifski not installed — used the fast encoder"
        }
    }
}

/// Recorded time, excluding pauses. Either counting from a moment on, or frozen.
enum RecordingClock: Equatable {
    case running(since: Date, before: TimeInterval)
    case paused(total: TimeInterval)

    static func started(at date: Date) -> RecordingClock { .running(since: date, before: 0) }

    func elapsed(at now: Date) -> TimeInterval {
        switch self {
        case .running(let since, let before): return before + now.timeIntervalSince(since)
        case .paused(let total): return total
        }
    }

    func pausing(at now: Date) -> RecordingClock {
        guard case .running = self else { return self }
        return .paused(total: elapsed(at: now))
    }

    func resuming(at now: Date) -> RecordingClock {
        guard case .paused(let total) = self else { return self }
        return .running(since: now, before: total)
    }
}

struct RecordingRun: Equatable {
    var clock: RecordingClock
    let output: Output
    let degradations: [Degradation]
}

enum FinishStep: Equatable {
    case encoding(Output)
    case fittingToLimit(ByteCount, progress: Double)

    var label: String {
        switch self {
        case .encoding(let output): return "Encoding \(output.label)…"
        case .fittingToLimit(let limit, _): return "Shrinking to fit \(limit.formatted)…"
        }
    }
}

enum Settlement: Equatable {
    case saved(Recording, notes: [String])
    case discarded
    case failed(String)
}

/// The one place the app's state lives. Every surface (menu, HUD pill, settings
/// window) renders from this; nothing keeps its own copy.
enum Phase: Equatable {
    case idle
    case pickingSource(CaptureMode)
    /// The source is chosen; devices, permissions and the encoder are coming up.
    case starting(Output)
    case countingDown(remaining: Int, output: Output)
    case recording(RecordingRun)
    case finishing(FinishStep)
    case settled(Settlement)

    var isBusy: Bool {
        switch self {
        case .idle, .settled: return false
        case .pickingSource, .starting, .countingDown, .recording, .finishing: return true
        }
    }
}
