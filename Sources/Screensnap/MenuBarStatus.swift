import AppKit
import Observation
import SwiftUI

/// Everything the menu bar icon can show. A finite set: the icon changes only when
/// this value changes, never on its own.
enum MenuBarGlyph: Equatable {
    case ready
    case countingDown
    case recording(Beat)
    case finishing

    /// Which half of the pulse the recording dot is in.
    enum Beat {
        case bright
        case dim

        var next: Beat {
            switch self {
            case .bright: return .dim
            case .dim: return .bright
            }
        }
    }

    static let beatInterval: Duration = .milliseconds(700)

    init(_ phase: Phase) {
        switch phase {
        case .idle, .pickingSource, .starting, .settled: self = .ready
        case .countingDown: self = .countingDown
        case .recording: self = .recording(.bright)
        case .finishing: self = .finishing
        }
    }

    /// The same glyph one beat later. Only the recording dot pulses, so a beat can
    /// never turn one kind of glyph into another.
    var afterBeat: MenuBarGlyph {
        guard case .recording(let beat) = self else { return self }
        return .recording(beat.next)
    }
}

/// The menu bar icon's state. The coordinator pushes every phase in, the same way
/// it drives the HUD; while recording, the dot pulses on a timer owned here.
@MainActor @Observable
final class MenuBarStatus {
    private(set) var glyph: MenuBarGlyph = .ready
    @ObservationIgnored private var pulse: Task<Void, Never>?

    func render(_ phase: Phase) {
        let next = MenuBarGlyph(phase)
        guard next != glyph else { return }
        glyph = next
        pulse?.cancel()
        pulse = nil
        if case .recording = next { pulse = startPulse() }
    }

    private func startPulse() -> Task<Void, Never> {
        Task { [weak self] in
            while true {
                do { try await Task.sleep(for: MenuBarGlyph.beatInterval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.glyph = self.glyph.afterBeat
            }
        }
    }
}

/// MENUBAR_LABEL_IS_STATIC (nils 2026.09.23): this body must stay a pure function of
/// `status.glyph`. SwiftUI renders a MenuBarExtra label off-screen into the status
/// item's image, so a TimelineView (or any view that schedules its own redraws) here
/// re-renders in a loop: 100% CPU and a ~50 MB/s leak until macOS kills the app.
/// To animate the icon, change the glyph from MenuBarStatus.
struct MenuBarLabel: View {
    let status: MenuBarStatus

    var body: some View {
        switch status.glyph {
        case .ready: Image(systemName: "record.circle")
        case .countingDown: Image(systemName: "timer")
        case .recording(let beat): Image(nsImage: MenuBarIcon.recording(beat))
        case .finishing: Image(systemName: "hourglass")
        }
    }
}

enum MenuBarIcon {
    /// A real red dot — non-template so the menu bar shows the colour — inside the
    /// same ring as the idle symbol.
    static func recording(_ beat: MenuBarGlyph.Beat) -> NSImage {
        let dotAlpha: CGFloat
        switch beat {
        case .bright: dotAlpha = 1
        case .dim: dotAlpha = 0.35
        }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = rect.insetBy(dx: 2, dy: 2)
            NSColor.labelColor.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(ovalIn: ring)
            path.lineWidth = 1.5
            path.stroke()
            NSColor.systemRed.withAlphaComponent(dotAlpha).setFill()
            NSBezierPath(ovalIn: ring.insetBy(dx: 3.5, dy: 3.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
