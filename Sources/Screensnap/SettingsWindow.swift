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

    private var shortcutSubtitle: String {
        guard let keys = coordinator.hotkey.advertisedKeys else {
            return "Pick what to record from the menu bar. \(coordinator.hotkey.keys) could not be registered, so start and finish from the menu bar too."
        }
        return "Pick what to record from the menu bar. \(keys) starts the last mode from anywhere, and finishes."
    }

    private static let delays = [0, 3, 5, 10].map(StartDelay.init(clamping:))
    private static let gifFramerates = [10, 15, 24, 30].map(Framerate.init(clamping:))
    private static let mp4Framerates = [24, 30, 60].map(Framerate.init(clamping:))

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Capture", subtitle: shortcutSubtitle)

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
                    ForEach(Self.delays, id: \.self) { Text($0.seconds == 0 ? "None" : "\($0.seconds) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            FrameratePicker(title: "GIF frame rate", selection: $settings.gifFramerate, choices: Self.gifFramerates)
            FrameratePicker(title: "MP4 frame rate", selection: $settings.mp4Framerate, choices: Self.mp4Framerates)
            Text("15 fps is the sweet spot for GIF walkthroughs — files stay small and motion reads fine. MP4 handles 30 or 60 fps without much growth.")
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

private struct FrameratePicker: View {
    let title: String
    @Binding var selection: Framerate
    let choices: [Framerate]

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: $selection) {
                ForEach(choices, id: \.self) { Text("\($0.fps) fps").tag($0) }
                if !choices.contains(selection) {
                    Text("\(selection.fps) fps").tag(selection)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
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
            DeviceAccessRow(name: "Camera", access: coordinator.permissions.camera, pane: .camera, request: coordinator.requestCamera)
            DeviceAccessRow(name: "Microphone", access: coordinator.permissions.microphone, pane: .microphone, request: coordinator.requestMicrophone)
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
                Button("Relaunch") { coordinator.relaunch() }.buttonStyle(.borderedProminent)
            }
        case .missing:
            HStack {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.orange)
                Text("Screen Recording")
                Text("required").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Grant Access…") { coordinator.grantScreenRecording() }
            }
            Text("Drag Screensnap into the list in System Settings and turn it on. The app relaunches itself the first time you record afterwards.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

}

/// Camera/microphone: ask first (that's what adds Screensnap to the System Settings
/// list), and only send the user to System Settings once they've said no.
private struct DeviceAccessRow: View {
    let name: String
    let access: DeviceAccess
    let pane: PermissionPane
    let request: () -> Void
    var caption: String? = "only when used"

    var body: some View {
        HStack {
            switch access {
            case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            case .notAsked: Image(systemName: "minus.circle").foregroundStyle(Color.secondary)
            case .denied: Image(systemName: "xmark.circle.fill").foregroundStyle(Color.orange)
            }
            Text(name)
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            switch access {
            case .granted: EmptyView()
            case .notAsked: Button("Allow…", action: request)
            case .denied: Button("Open Settings") { Permissions.openSettings(pane) }
            }
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

    private var gifskiInstalled: Bool {
        if case .located = coordinator.gifski { return true }
        return false
    }

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

            SectionLabel("SHRINK TO FIT")
            Picker("", selection: Binding(
                get: { SizeLimitChoice(settings.sizeLimit) },
                set: { choice in
                    switch choice {
                    case .preset(let limit): settings.sizeLimit = limit
                    case .custom:
                        // Picked before typing a usable number: start from 50 MB.
                        if let ceiling = SizeLimit.Ceiling(megabytesText: customMB) ?? SizeLimit.Ceiling(megabytes: 50) {
                            settings.sizeLimit = .atMost(ceiling)
                        }
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
                        .onSubmit { if let ceiling = SizeLimit.Ceiling(megabytesText: customMB) { settings.sizeLimit = .atMost(ceiling) } }
                    Text("MB").foregroundStyle(.secondary)
                }
            }
            Text("Record as long as you like. If the file comes out bigger, it is shrunk right after you finish — smaller frame, then fewer frames — until it fits. You see the final size in the pill.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            coordinator.refreshGifski()
            if case .atMost(let ceiling) = settings.sizeLimit { customMB = String(ceiling.megabytes) }
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
            DeviceAccessRow(name: "Camera", access: coordinator.permissions.camera, pane: .camera, request: coordinator.requestCamera, caption: nil)
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
            Picker("Copy to clipboard", selection: $settings.delivery.clipboard) {
                ForEach(ClipboardCopy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
            Text("⌘V then pastes the file. GIFs only suits chats and issues; MP4s are usually uploaded instead.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Reveal in Finder", isOn: $settings.delivery.revealInFinder)
            FilenameField(settings: settings)

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

/// Edits the file name template. What is typed is a draft; the setting changes only
/// when the draft parses, and the line underneath says why when it does not.
private struct FilenameField: View {
    @Bindable var settings: Settings
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("File names")
                TextField("", text: $draft).textFieldStyle(.roundedBorder).frame(width: 220)
                Text("%Y %m %d %H %M %S").font(.caption).foregroundStyle(.secondary)
            }
            switch FilenameTemplate.parse(draft) {
            case .success(let template):
                Text("Next: \(template.stem(at: Date()).text).\(settings.output.fileExtension)")
                    .font(.caption).foregroundStyle(.secondary)
            case .failure(let error):
                Text("\(error.message) Still using \(settings.filenameTemplate.text).")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { draft = settings.filenameTemplate.text }
        .onChange(of: draft) { _, text in
            if case .success(let template) = FilenameTemplate.parse(text) { settings.filenameTemplate = template }
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let coordinator: Coordinator

    /// A draft name exists only while renaming, so there is no stale draft to commit.
    private enum NameEdit: Equatable {
        case showing
        case renaming(draft: String)
    }

    @State private var nameEdit: NameEdit = .showing
    @State private var compressing = false
    @State private var message: String?
    @State private var thumbnailHovered = false
    /// Swaps the copy-path icon for a checkmark for a moment, as the only sign it worked.
    @State private var pathCopied = false
    @FocusState private var nameFieldFocused: Bool

    private var library: RecordingsStore { coordinator.library }
    /// The compression on this file, whether the size limit or this row started it.
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
                switch nameEdit {
                case .renaming(let draft):
                    HStack(spacing: 6) {
                        TextField("Name", text: Binding(get: { draft }, set: { nameEdit = .renaming(draft: $0) }), onCommit: { commitRename(draft) })
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .focused($nameFieldFocused)
                            .onAppear { nameFieldFocused = true }
                            .onExitCommand(perform: cancelRename)
                        iconButton("checkmark", help: "Save name (Return)") { commitRename(draft) }
                            .foregroundStyle(.green)
                        iconButton("xmark", help: "Cancel (Esc)", action: cancelRename)
                            .foregroundStyle(.secondary)
                    }
                case .showing:
                    HStack(spacing: 6) {
                        Text(recording.name).fontWeight(.medium).lineLimit(1)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: startRename)
                            .help("Click to rename")
                        iconButton(pathCopied ? "checkmark" : "link", help: "Copy absolute path") {
                            Clipboard.copyPath(of: recording.url)
                            pathCopied = true
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .task(id: pathCopied) {
                            guard pathCopied else { return }
                            try? await Task.sleep(for: .seconds(1.5))
                            pathCopied = false
                        }
                    }
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
            HStack(spacing: 7) {
                iconButton("play.fill", help: "Play") { library.play(recording) }
                iconButton("doc.on.doc", help: "Copy — ⌘V pastes it") { Clipboard.copy(recording) }
                iconButton("magnifyingglass", help: "Show in Finder") { library.reveal(recording) }
                Button {
                    compressing = true
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.plain)
                .help("Make smaller…")
                .disabled(coordinator.compression != nil)
                .popover(isPresented: $compressing, arrowEdge: .bottom) {
                    CompressPopover(recording: recording, info: library.requestInfo(for: recording)) { target, placement in
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
            if let image = library.requestThumbnail(for: recording) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: recording.container == .gif ? "photo.stack" : "film").foregroundStyle(.secondary)
            }
            if thumbnailHovered {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
        }
        .frame(width: 88, height: 56)
        .contentShape(Rectangle())
        .onHover { thumbnailHovered = $0 }
        .onTapGesture { library.play(recording) }
        .help("Play")
    }

    private var meta: String {
        var parts = [recording.container.rawValue.uppercased()]
        if let info = library.requestInfo(for: recording) {
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

    private func startRename() {
        nameEdit = .renaming(draft: recording.name)
    }

    private func cancelRename() {
        nameEdit = .showing
        message = nil
    }

    /// A refused name keeps the field open with the draft, so it can be corrected.
    private func commitRename(_ draft: String) {
        do {
            try library.rename(recording, to: draft)
            nameEdit = .showing
            message = nil
        } catch {
            message = error.localizedDescription
        }
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
                    Button("Update and relaunch") { coordinator.installUpdate() }
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
            Button("Relaunch Screensnap") { coordinator.relaunch() }
        }
    }
}
