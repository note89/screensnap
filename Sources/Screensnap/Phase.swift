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

struct RecordingRun: Equatable {
    let startedAt: Date
    let output: Output
    let dimensions: Dimensions
    let degradations: [Degradation]
}

enum FinishStep: Equatable {
    case encoding(Output)
    case fittingToLimit(ByteCount, progress: Double)

    var label: String {
        switch self {
        case .encoding(let output): return "Encoding \(output.label)…"
        case .fittingToLimit(let limit, _): return "Fitting under \(limit.formatted)…"
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
    case countingDown(remaining: Int, output: Output)
    case recording(RecordingRun)
    case finishing(FinishStep)
    case settled(Settlement)

    var isBusy: Bool {
        switch self {
        case .idle, .settled: return false
        case .pickingSource, .countingDown, .recording, .finishing: return true
        }
    }
}
