import Foundation

/// Something the user asked for that this recording could not deliver. Carried
/// through the run so the settled message can say so instead of failing silently.
enum Degradation: Equatable {
    case camera(String)
    case microphone(String)
    case gifskiMissing
    case gifskiTooManyFrames(Int)
    case gifskiFailed

    var message: String {
        switch self {
        case .camera(let reason): return "no facecam — \(reason)"
        case .microphone(let reason): return "no voice — \(reason)"
        case .gifskiMissing: return "gifski not installed — used the fast encoder"
        case .gifskiTooManyFrames(let count): return "\(count.formatted()) frames is too long for gifski — used the fast encoder"
        case .gifskiFailed: return "gifski failed — used the fast encoder"
        }
    }
}

/// Recorded time as the pill shows it: counting from a moment on, or frozen at the
/// total the recorder reported when it paused. The recorder's own clock is the
/// one the file is cut to; this one is fed from it at every pause and resume.
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
}

struct RecordingRun: Equatable {
    var clock: RecordingClock
    let output: Output
    let degradations: [Degradation]
}

/// The recording is over and its session is being wound down. Busy, whichever way
/// it ends: the next recording starts only once this one has let go of its
/// recorder and devices.
enum FinishStep: Equatable {
    case encoding(Output)
    /// The shrink runs as the coordinator's one compression job; its progress lives there.
    case fittingToLimit(ByteCount)
    /// Discarded or aborted: the capture is stopping, nothing is being written.
    case stopping

    var label: String {
        switch self {
        case .encoding(let output): return "Encoding \(output.label)…"
        case .fittingToLimit(let limit): return "Shrinking to fit \(limit.formatted)…"
        case .stopping: return "Stopping…"
        }
    }
}

/// How the size limit was applied to a fresh recording that came out over it. The
/// recording is on disk before any of this runs, so none of these is a failure.
enum FitOutcome: Equatable {
    case shrunk(under: ByteCount)
    case stillOver(ByteCount)
    /// Another compression held the job slot, so the recording was saved as it was.
    case skipped(ByteCount)
    /// The shrink could not read or re-encode the file; the original was kept.
    case notShrunk(ByteCount, reason: String)

    var message: String {
        switch self {
        case .shrunk(let limit): return "shrunk to fit \(limit.formatted)"
        case .stillOver(let limit): return "could not get under \(limit.formatted)"
        case .skipped(let limit): return "not shrunk to \(limit.formatted) — another compression was running"
        case .notShrunk(let limit, let reason): return "not shrunk to \(limit.formatted) — \(reason)"
        }
    }
}

/// What `deliver` did with a fresh recording, so the settled message reports what
/// happened rather than what the settings say now.
struct Delivered: Equatable {
    let copiedToClipboard: Bool
    let revealedInFinder: Bool
}

/// A recording that made it to disk, with everything the pill says about it.
struct SavedRecording: Equatable {
    let recording: Recording
    let degradations: [Degradation]
    let fit: FitOutcome?
    let delivered: Delivered

    var notes: [String] {
        degradations.map(\.message) + (fit.map { [$0.message] } ?? [])
    }
}

enum Settlement: Equatable {
    case saved(SavedRecording)
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
