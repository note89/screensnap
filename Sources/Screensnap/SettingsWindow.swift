import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case capture = "Capture"
    case output = "Output"
    case facecam = "Facecam"
    case recordings = "Recordings"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .capture: return "record.circle"
        case .output: return "doc.badge.gearshape"
        case .facecam: return "person.crop.circle"
        case .recordings: return "film.stack"
        case .about: return "info.circle"
        }
    }
}

struct SettingsWindowView: View {
    let coordinator: Coordinator

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding(
                get: { Optional(coordinator.settingsSection) },
                set: { coordinator.settingsSection = $0 ?? .capture }
            )) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            ScrollView {
                Group {
                    switch coordinator.settingsSection {
                    case .capture: CapturePane(coordinator: coordinator)
                    case .output: OutputPane(coordinator: coordinator)
                    case .facecam: FacecamPane(coordinator: coordinator)
                    case .recordings: RecordingsPane(coordinator: coordinator)
                    case .about: AboutPane(coordinator: coordinator)
                    }
                }
                .padding(28)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 780, minHeight: 540)
        .navigationTitle("Screensnap")
    }
}

struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption.bold()).foregroundStyle(.secondary) }
}

// MARK: - Capture

private struct CapturePane: View {
    @Bindable var settings: Settings
    let coordinator: Coordinator

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        self.settings = coordinator.settings
    }

    private static let delays = [0, 3, 5, 10]
    private static let framerates = [10, 15, 24, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Capture", subtitle: "Pick what to record from the menu bar. ⌘⇧. starts the last mode from anywhere, and finishes.")

            SectionLabel("WHAT")
            HStack(alignment: .top, spacing: 12) {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    ChoiceCard(
                        icon: mode.icon,
                        title: mode.label,
                        blurb: Self.blurb(mode),
                        selected: settings.captureMode == mode
                    ) { settings.captureMode = mode }
                }
            }
            Button {
                coordinator.record(settings.captureMode)
            } label: {
                Label("Record \(settings.captureMode.label.lowercased()) now", systemImage: "record.circle")
            }
            .disabled(coordinator.phase.isBusy)

            Divider().padding(.vertical, 4)

            SectionLabel("HOW")
            Toggle("Show the mouse cursor", isOn: $settings.captureCursor)
            HStack {
                Text("Start delay")
                Spacer()
                Picker("", selection: $settings.startDelay) {
                    ForEach(Self.delays, id: \.self) { Text($0 == 0 ? "None" : "\($0) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            HStack {
                Text("Frame rate")
                Spacer()
                Picker("", selection: $settings.framerate) {
                    ForEach(Self.framerates, id: \.self) { Text("\($0) fps").tag($0) }
                    if !Self.framerates.contains(settings.framerate) {
                        Text("\(settings.framerate) fps").tag(settings.framerate)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            Text("15 fps is the sweet spot for UI walkthroughs — files stay small and motion reads fine.")
                .font(.caption).foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            SectionLabel("PERMISSIONS")
            PermissionsRows(coordinator: coordinator)
        }
    }

    private static func blurb(_ mode: CaptureMode) -> String {
        switch mode {
        case .region: return "Drag a rectangle on any screen."
        case .display: return "One whole screen. No question if you only have one."
        case .window: return "Follows the window, even to another Space."
        }
    }
}

private struct ChoiceCard: View {
    let icon: String
    let title: String
    let blurb: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(title).font(.headline)
                Text(blurb).font(.caption).foregroundStyle(.secondary).frame(minHeight: 32, alignment: .top)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .quaternarySystemFill)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

struct PermissionsRows: View {
    let coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            screenRecordingRow
            optionalRow("Camera", granted: coordinator.permissions.camera, pane: .camera)
            optionalRow("Microphone", granted: coordinator.permissions.microphone, pane: .microphone)
        }
        .onAppear { coordinator.refreshPermissions() }
    }

    @ViewBuilder private var screenRecordingRow: some View {
        switch coordinator.screenRecordingAccess {
        case .granted:
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                Text("Screen Recording")
            }
        case .grantedSinceLaunch:
            HStack {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Color.orange)
                Text("Screen Recording")
                Text("granted — relaunch to activate").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Relaunch") { Relaunch.now() }.buttonStyle(.borderedProminent)
            }
        case .missing:
            HStack {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.orange)
                Text("Screen Recording")
                Text("required").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Settings") { Permissions.openSettings(.screenRecording) }
            }
            Text("Turn Screensnap on in System Settings and come back. The app relaunches itself the first time you record afterwards.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func optionalRow(_ name: String, granted: Bool, pane: PermissionPane) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
            Text(name)
            Text("only when used").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !granted { Button("Open Settings") { Permissions.openSettings(pane) } }
        }
    }
}

// MARK: - Output

private struct OutputPane: View {
    @Bindable var settings: Settings
    let coordinator: Coordinator
    @State private var customMB: String = ""

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        self.settings = coordinator.settings
    }

    private var gifskiInstalled: Bool { GifskiEncoder.locateGifski() != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Output", subtitle: "What a recording becomes on disk, and how big it is allowed to get.")

            SectionLabel("FORMAT")
            OutputCard(
                title: "GIF", detail: "Plays everywhere, no audio. Built-in encoder, ready in a second.",
                tags: [Tag(text: "no audio", tone: .secondary)],
                selected: settings.output == .gif(.fast), available: true
            ) { settings.outputContainer = .gif; settings.gifQuality = .fast }
            OutputCard(
                title: "GIF · best", detail: "Same GIF, encoded by gifski: smoother colour, smaller files, a few seconds of encoding.",
                tags: [Tag(text: "no audio", tone: .secondary), gifskiInstalled ? Tag(text: "gifski found", tone: .green) : Tag(text: "needs gifski", tone: .orange)],
                selected: settings.output == .gif(.best), available: gifskiInstalled
            ) { settings.outputContainer = .gif; settings.gifQuality = .best }
            OutputCard(
                title: "MP4", detail: "H.264 video. A tenth the size of a GIF and the only format that carries your voice.",
                tags: [Tag(text: "smallest", tone: .green), Tag(text: "voice", tone: .green)],
                selected: settings.outputContainer == .mp4, available: true
            ) { settings.outputContainer = .mp4 }
            if !gifskiInstalled {
                Text("For GIF · best: `brew install gifski`, or drop a gifski binary into the app's Resources.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.outputContainer == .mp4 {
                Toggle(isOn: Binding(
                    get: { settings.audioTrack == .microphone },
                    set: { settings.audioTrack = $0 ? .microphone : .none }
                )) {
                    VStack(alignment: .leading) {
                        Text("Record my voice")
                        Text("Microphone into the MP4. The pill shows a level meter while recording so you can see it hears you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Divider().padding(.vertical, 4)

            SectionLabel("SIZE LIMIT")
            Picker("", selection: Binding(
                get: { SizeLimitChoice(settings.sizeLimit) },
                set: { choice in
                    switch choice {
                    case .preset(let limit): settings.sizeLimit = limit
                    case .custom: settings.sizeLimit = .bytes(Int64((Int(customMB) ?? 50) * 1_000_000))
                    }
                }
            )) {
                ForEach(SizeLimit.presets, id: \.label) { preset in
                    Text(preset.label).tag(SizeLimitChoice.preset(preset.limit))
                }
                Text("Custom…").tag(SizeLimitChoice.custom)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if case .custom = SizeLimitChoice(settings.sizeLimit) {
                HStack {
                    TextField("MB", text: $customMB)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit { if let mb = Int(customMB), mb > 0 { settings.sizeLimit = .bytes(Int64(mb) * 1_000_000) } }
                    Text("MB").foregroundStyle(.secondary)
                }
            }
            Text("A recording that lands over the limit is shrunk right after encoding — smaller frame, then fewer frames — until it fits. You see the final size in the pill.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            if case .bytes(let bytes) = settings.sizeLimit { customMB = String(bytes / 1_000_000) }
        }
    }
}

private enum SizeLimitChoice: Hashable {
    case preset(SizeLimit)
    case custom

    init(_ limit: SizeLimit) {
        self = SizeLimit.presets.contains { $0.limit == limit } ? .preset(limit) : .custom
    }
}

private struct OutputCard: View {
    let title: String
    let detail: String
    let tags: [Tag]
    let selected: Bool
    let available: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title).fontWeight(.semibold)
                        ForEach(tags.indices, id: \.self) { tags[$0] }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
    }
}

struct Tag: View {
    enum Tone { case green, orange, secondary }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch tone {
        case .green: return .green
        case .orange: return .orange
        case .secondary: return .secondary
        }
    }
}

// MARK: - Facecam

private struct FacecamPane: View {
    @Bindable var settings: Settings
    let coordinator: Coordinator

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        self.settings = coordinator.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Facecam", subtitle: "Your face in a round bubble, drawn into the recording.")
            Toggle(isOn: Binding(
                get: { settings.facecam == .bubble },
                set: { settings.facecam = $0 ? .bubble : .off }
            )) {
                VStack(alignment: .leading) {
                    Text("Show facecam bubble")
                    Text("A live preview appears when recording starts. Drag it anywhere inside the recorded area — the bubble in the file sits exactly where the preview is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("If the camera is busy or denied, the recording still happens and the pill says why the bubble is missing.")
                .font(.caption).foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            SectionLabel("PERMISSION")
            HStack {
                Image(systemName: coordinator.permissions.camera ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundStyle(coordinator.permissions.camera ? Color.green : Color.secondary)
                Text("Camera")
                Spacer()
                if !coordinator.permissions.camera { Button("Open Settings") { Permissions.openSettings(.camera) } }
            }
            .onAppear { coordinator.refreshPermissions() }
        }
    }
}

// MARK: - Recordings

private struct RecordingsPane: View {
    @Bindable var settings: Settings
    let coordinator: Coordinator

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        self.settings = coordinator.settings
    }

    private var library: RecordingsStore { coordinator.library }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Recordings", subtitle: "Every clip lands in one folder. This is that folder.")

            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(library.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…") { chooseFolder() }
                Button("Show in Finder") { library.openFolder() }
            }
            Text("\(library.recordings.count) recording\(library.recordings.count == 1 ? "" : "s") · \(library.totalBytes.formatted)")
                .font(.caption).foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            SectionLabel("AFTER SAVING")
            Toggle("Copy to clipboard — ⌘V pastes the file", isOn: $settings.delivery.copyToClipboard)
            Toggle("Reveal in Finder", isOn: $settings.delivery.revealInFinder)
            HStack {
                Text("File names")
                TextField("", text: $settings.filenameFormat).textFieldStyle(.roundedBorder).frame(width: 220)
                Text("%Y %m %d %H %M %S").font(.caption).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)

            SectionLabel("LIBRARY")
            if library.recordings.isEmpty {
                Text("No recordings yet. The first one shows up here the moment it is saved.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
            } else {
                VStack(spacing: 0) {
                    ForEach(library.recordings) { recording in
                        RecordingRow(recording: recording, coordinator: coordinator)
                        Divider()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = library.folder
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coordinator.setSaveFolder(url)
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let coordinator: Coordinator

    @State private var editing = false
    @State private var draftName = ""
    @State private var compressing = false
    @State private var message: String?

    private var library: RecordingsStore { coordinator.library }
    private var job: CompressionJob? { coordinator.compression?.recording == recording ? coordinator.compression : nil }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                if editing {
                    TextField("Name", text: $draftName, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onExitCommand { editing = false }
                } else {
                    Text(recording.name).fontWeight(.medium).lineLimit(1)
                        .onTapGesture(count: 2) { draftName = recording.name; editing = true }
                }
                Text(meta).font(.caption).foregroundStyle(.secondary)
                if let job {
                    ProgressView(value: job.progress).frame(maxWidth: 200)
                    Text("Compressing to \(job.target.label)…").font(.caption).foregroundStyle(.secondary)
                } else if let message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                iconButton("doc.on.doc", help: "Copy — ⌘V pastes it") { Clipboard.copy(recording.url) }
                iconButton("magnifyingglass", help: "Show in Finder") { library.reveal(recording) }
                Button {
                    compressing = true
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.plain)
                .help("Compress…")
                .disabled(coordinator.compression != nil)
                .popover(isPresented: $compressing, arrowEdge: .bottom) {
                    CompressPopover(recording: recording, info: library.info(for: recording)) { target, placement in
                        compressing = false
                        Task { await run(target: target, placement: placement) }
                    }
                }
                iconButton("trash", help: "Move to Trash") { try? library.trash(recording) }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
            if let image = library.thumbnail(for: recording) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: recording.container == .gif ? "photo.stack" : "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: 88, height: 56)
    }

    private var meta: String {
        var parts = [recording.container.rawValue.uppercased()]
        if let info = library.info(for: recording) {
            parts.append(info.dimensions.label)
            parts.append(info.durationLabel)
        }
        parts.append(recording.bytes.formatted)
        parts.append(Self.timestamp.string(from: recording.createdAt))
        return parts.joined(separator: " · ")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .help(help)
    }

    private func commitRename() {
        editing = false
        do { try library.rename(recording, to: draftName) } catch { message = error.localizedDescription }
    }

    private func run(target: CompressionTarget, placement: CompressionPlacement) async {
        message = nil
        switch await coordinator.compress(recording, to: target, placement: placement) {
        case .done(let result):
            switch result.fit {
            case .met: message = placement == .sibling ? "Saved \(result.url.lastPathComponent) · \(result.bytes.formatted)" : "Now \(result.bytes.formatted)"
            case .exceeded: message = "Smallest possible was \(result.bytes.formatted) — still over \(target.label)"
            }
        case .failed(let reason):
            message = reason
        }
    }
}

private struct CompressPopover: View {
    let recording: Recording
    let info: MediaInfo?
    let start: (CompressionTarget, CompressionPlacement) -> Void

    @State private var target: CompressionTarget = .fit(.p720)
    @State private var placement: CompressionPlacement = .sibling

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compress \(recording.name)").font(.headline)
            if let info {
                Text("Now \(info.dimensions.label) · \(recording.bytes.formatted)").font(.caption).foregroundStyle(.secondary)
            }
            SectionLabel("TO A SIZE")
            HStack {
                ForEach(CompressionTarget.sizePresets, id: \.bytes) { size in
                    choice(.size(size))
                }
            }
            SectionLabel("TO A RESOLUTION")
            HStack {
                ForEach(ResolutionPreset.allCases, id: \.self) { preset in
                    choice(.fit(preset))
                }
            }
            SectionLabel("RESULT")
            Picker("", selection: $placement) {
                Text("Keep both").tag(CompressionPlacement.sibling)
                Text("Replace original").tag(CompressionPlacement.replaceOriginal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(placement == .sibling ? "A new file next to the original, named after the target." : "The original goes to the Trash.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Compress") { start(target, placement) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func choice(_ candidate: CompressionTarget) -> some View {
        Button(candidate.label) { target = candidate }
            .buttonStyle(.bordered)
            .tint(target == candidate ? .accentColor : nil)
    }
}

// MARK: - About

private struct AboutPane: View {
    let coordinator: Coordinator

    private var updater: Updater { coordinator.updater }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screensnap").font(.title.bold())
                    Text("Version \(updater.currentVersion.map(String.init(describing:)) ?? "dev")").foregroundStyle(.secondary)
                    Text("Screen to GIF or MP4, from the menu bar.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider().padding(.vertical, 4)

            SectionLabel("UPDATES")
            HStack(spacing: 10) {
                switch updater.state {
                case .idle:
                    Button("Check for updates") { Task { await updater.check() } }
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                case .noReleases:
                    Text("No releases published yet.").foregroundStyle(.secondary)
                    Button("Check again") { Task { await updater.check() } }
                case .upToDate:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                    Text("You are on the latest version.")
                    Button("Check again") { Task { await updater.check() } }
                case .available(let release):
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    Text("Version \(release.version.description) is available.")
                    Button("Update and relaunch") { Task { await updater.install() } }
                        .buttonStyle(.borderedProminent)
                    Link("What's new", destination: release.pageURL)
                case .downloading(let release, _):
                    ProgressView().controlSize(.small)
                    Text("Downloading \(release.version.description)…").foregroundStyle(.secondary)
                case .installing(let release):
                    ProgressView().controlSize(.small)
                    Text("Installing \(release.version.description)…").foregroundStyle(.secondary)
                case .readyInFinder(let url):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                    Text("This copy's folder is read-only. The new build is in \(url.deletingLastPathComponent().lastPathComponent) — drag it over the old one.")
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                    Text(message)
                    Button("Retry") { Task { await updater.check() } }
                }
            }
            Text("Checked once a day against GitHub Releases. Updates keep your permissions when the local signing certificate from Scripts/setup-signing.sh is present.")
                .font(.caption).foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            SectionLabel("LINKS")
            Link("Source and releases on GitHub", destination: updater.releasesPage)
            Button("Relaunch Screensnap") { Relaunch.now() }
        }
    }
}
