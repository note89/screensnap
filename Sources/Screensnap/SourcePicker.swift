import AppKit
import ScreenCaptureKit
import SwiftUI

/// One thing the user can point the recorder at, with what the picker needs to show it.
struct PickerItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: NSImage?
    let source: CaptureSource
    let filter: SCContentFilter
    let aspect: CGFloat

    static func displays(in content: SCShareableContent) -> [PickerItem] {
        content.displays.enumerated().map { index, display in
            let screen = NSScreen.screen(displayID: display.displayID)
            let source = CaptureSource.display(display)
            return PickerItem(
                id: "display-\(display.displayID)",
                title: screen?.localizedName ?? "Display \(index + 1)",
                subtitle: source.resolveGeometry()?.pixelSize.label ?? "\(display.width)×\(display.height)",
                icon: nil,
                source: source,
                filter: SCContentFilter(display: display, excludingWindows: []),
                aspect: CGFloat(display.width) / CGFloat(max(1, display.height))
            )
        }
    }

    static func windows(in content: SCShareableContent) -> [PickerItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window in
            guard let app = window.owningApplication, app.processID != ownPID,
                  let title = window.title, !title.isEmpty,
                  window.windowLayer == 0, window.isOnScreen,
                  window.frame.width >= 100, window.frame.height >= 60 else { return nil }
            return PickerItem(
                id: "window-\(window.windowID)",
                title: title,
                subtitle: app.applicationName,
                icon: NSRunningApplication(processIdentifier: app.processID)?.icon,
                source: .window(window),
                filter: SCContentFilter(desktopIndependentWindow: window),
                aspect: window.frame.width / max(1, window.frame.height)
            )
        }
    }
}

/// What the picker chooses between. A region is drawn, not picked, so it is not an
/// option here.
enum PickableKind {
    case display
    case window

    var captureMode: CaptureMode {
        switch self {
        case .display: return .display
        case .window: return .window
        }
    }
}

/// How a pick ended. Each outcome asks something different of the caller.
enum SourceChoice {
    case picked(CaptureSource)
    case cancelled
    /// ScreenCaptureKit would not list what is on screen.
    case unavailable(Error)
}

/// Resolves a kind of source to a concrete one. A lone display needs no question;
/// everything else gets a picker window with live thumbnails.
@MainActor
enum SourcePicker {
    static func choose(_ kind: PickableKind) async -> SourceChoice {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            return .unavailable(error)
        }
        let items: [PickerItem]
        switch kind {
        case .display:
            if content.displays.count == 1, let only = content.displays.first { return .picked(.display(only)) }
            items = PickerItem.displays(in: content)
        case .window:
            items = PickerItem.windows(in: content)
        }
        let picked: CaptureSource? = await withCheckedContinuation { (continuation: CheckedContinuation<CaptureSource?, Never>) in
            let panel = SourcePickerPanel(kind: kind, items: items) { continuation.resume(returning: $0) }
            panel.present()
        }
        return picked.map(SourceChoice.picked) ?? .cancelled
    }
}

@MainActor
private final class SourcePickerPanel: NSPanel, NSWindowDelegate {
    private var completion: ((CaptureSource?) -> Void)?

    init(kind: PickableKind, items: [PickerItem], completion: @escaping (CaptureSource?) -> Void) {
        self.completion = completion
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Record \(kind.captureMode.label.lowercased())"
        titlebarAppearsTransparent = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        delegate = self
        contentView = NSHostingView(rootView: SourcePickerView(kind: kind, items: items) { [weak self] source in
            self?.finish(with: source)
        })
    }

    func present() {
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        finish(with: nil)
    }

    func windowWillClose(_ notification: Notification) {
        deliver(nil)
    }

    private func finish(with source: CaptureSource?) {
        deliver(source)
        close()
    }

    private func deliver(_ source: CaptureSource?) {
        guard let completion else { return }
        self.completion = nil
        completion(source)
    }
}

private struct SourcePickerView: View {
    let kind: PickableKind
    let items: [PickerItem]
    let pick: (CaptureSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .window ? "Which window?" : "Which display?")
                .font(.title2.bold())
            Text("Click one to start recording. Esc to cancel.")
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Spacer()
                Text("Nothing to record — no visible windows with a title.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(items) { item in
                            PickerCard(item: item) { pick(item.source) }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(24)
        .padding(.top, 12)
        .frame(minWidth: 640, minHeight: 420)
    }
}

private struct PickerCard: View {
    let item: PickerItem
    let select: () -> Void

    @State private var thumbnail: CGImage?
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill))
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(4)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 140)
                HStack(spacing: 8) {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).fontWeight(.medium).lineLimit(1)
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hovering ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: hovering ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task { thumbnail = await Self.capture(item) }
    }

    private static func capture(_ item: PickerItem) async -> CGImage? {
        let config = SCStreamConfiguration()
        config.width = 480
        config.height = max(1, Int(480 / item.aspect))
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: item.filter, configuration: config)
    }
}
