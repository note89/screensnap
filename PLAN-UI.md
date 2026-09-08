# PLAN — bring screensnap's UI/UX in line with hearsay

Date: 2026-09-06. Reference implementation: `../hearsay` (`Sources/hearsay/*`, `Sources/Overlay/*`)
and its `DESIGN-REVIEW.md` Part 4 ("Settings window — mapping review").

The two apps are the same shape of product: a single-purpose, permission-hungry, always-resident macOS
utility that must stay out of the way while another app has focus. hearsay solved that shape once; this
plan ports the solution rather than inventing a second one.

---

## Status (2026-09-06) — implemented

All seven phases below landed in one pass; this document is kept as the rationale. What shipped:

- **State model**: `Phase` enum on a single `@Observable Coordinator`; menu bar icon, menu, pill, and settings render from it. `Output` enum makes gifski×MP4 and microphone×GIF unrepresentable.
- **HUD**: one non-activating `HUDPanel` pill (countdown / recording with timer, format chip, mic meter / finishing with step + progress / saved with size and notes). Positioned on the screen under the mouse.
- **Menu-bar first**: `LSUIElement`, `MenuBarExtra`, no window at launch. Menu = record verbs, copy last, Recordings…, permissions warning, update prompt, Open Screensnap…, Quit.
- **Settings window**: `NavigationSplitView` with Capture · Output · Facecam · Recordings · About. Cards for exclusive choices, `needs gifski` chip, permission rows inline.
- **Recordings**: `RecordingsStore` watches the save folder (`~/Movies/Screensnap`), rows with thumbnail/dimensions/duration/size, Copy/Show/Compress…/Trash, inline rename. `Compressor` targets a size or a resolution; replace or sibling.
- **Beyond the plan** (user requests during implementation): `SizeLimit` enforced after every recording; `Updater` against GitHub Releases with in-place swap and re-sign; release workflow on `v*` tags; new icon.
- **Brand**: target `Screensnap`, bundle `local.screensnap`, version 0.2.0, macOS 14.

See `DESIGN-REVIEW.md` for the concept-level findings this addressed.

---

## Part 1 — What hearsay actually does

| # | Pattern | Where |
|---|---------|-------|
| 1 | **Menu-bar first.** `NSApp.setActivationPolicy(.accessory)`, no dock icon, no window at launch. `MenuBarExtra` is the app's front door. | `HearsayApp.swift` |
| 2 | **Quick menu = mid-flow actions only.** Status line, last-result action, permissions warning, quit. Configuration lives elsewhere, explicitly: *"The quick menu: mid-flow actions only."* | `MenuView.swift` |
| 3 | **One status line, derived from the state machine.** A single `statusLine` function switches over gesture → engine → phase and returns one honest sentence. | `MenuView.swift:60` |
| 4 | **Settings window = `NavigationSplitView`, sections named by concept, not by feature.** Dictation · Dictionary · Style · Bake-off · History. Fixed pane chrome: `PaneHeader(title:subtitle:)`, 28pt padding, 680pt max width. | `SettingsWindow.swift` |
| 5 | **Cards, not checkbox lists, for exclusive choices.** `EngineCard` / `CleanupCard`: radio glyph, title, tag chips, one-line detail, a *worked example* of what the choice does, accent border when selected, dimmed + disabled when unavailable. | `SettingsWindow.swift:135` |
| 6 | **Unavailability is shown, not discovered on failure.** `Engine.isAvailable` (key present?) drives a `needs key` chip and a disabled card; a banner explains the fallback that is actually running. | `SettingsWindow.swift:80` |
| 7 | **Permission rows inline in the pane they belong to.** ✅/❌ + "Open Settings" per permission — no polling timer, refreshed `onAppear`. | `SettingsWindow.swift:196` |
| 8 | **One floating HUD for every phase.** A non-activating borderless `NSPanel` pill: `hidden / listening(partial) / working(label) / settled(message, tone)`, live meter, fade-out, positioned on the screen *under the mouse*, never takes focus. | `Overlay/OverlayPanel.swift`, `OverlayView.swift` |
| 9 | **History is a first-class pane.** List + per-row copy/delete + Clear all + a "keep history" toggle. | `SettingsWindow.swift:376` |
| 10 | **No `NSAlert` in the happy path.** Choices are panes and lists; results are the pill. | throughout |

Underneath all ten: one `@Observable` `Coordinator` owns the state; views are pure mappings over it.

---

## Part 2 — Where screensnap stands

| Area | Today | Consequence |
|------|-------|-------------|
| Front door | `showMainWindow()` at launch — a 480×460 AppKit form of 6 checkboxes + 5 label/field rows | The app's first impression is a preferences dialog, not a verb |
| HUD | **three** separate floating windows: `ControlBar` (titled window, buttons), `CountdownOverlay` (black panel), `Toast` (visual-effect card) | Three codepaths, three geometries, three ideas of "top right of `NSScreen.main`" — none follow the mouse |
| State | `activeSession != nil` + `statusItem.setState(.idle/.recording)` + timers | Recording state exists in three places; no representation at all for *encoding* (the GIF encode after Finish is invisible — the app looks idle while gifski runs) |
| Settings | `Settings.shared` singleton read/written manually by `MainView.loadFromSettings/saveSettings` | Menu-bar-initiated changes and window widgets can drift; no observation |
| Choices | `micCheckbox` titled "Record microphone (MP4 only)", `gifskiCheckbox`, `cameraCheckbox` | Boolean blindness + illegal states: mic-on + GIF is representable and silently ignored; `gifskiEnabled`+`gifskiQuality` is a tandem pair |
| Availability | gifski binary is located at `finish()` (`Encoders.swift:137`) | A missing binary is discovered **after** the recording, as an error alert — the recording is lost. hearsay's `needs key` chip is the exact fix |
| Pickers | `NSAlert` + `NSPopUpButton` for display and window (`SourcePicker.swift`) | Modal, app-activating, no thumbnails — the opposite of Cmd+Shift+5, which the region selector already imitates well |
| Permissions | Status label + button at top of the launcher + a 1 s `Timer` poll | Polls TCC forever while ungranted; permission UI competes with the Record button |
| History | `Settings.lastRecordingURL` only (one slot) | "Rename…/Show in Finder/Copy again" apply to exactly one file; anything older is unreachable |
| Brand | Target `GifRecorder`, bundle `local.gifrecorder`, window title "GIF Recorder", README says **Screensnap** | Three names for one product |

---

## Part 3 — Decisions to take first

1. **Deployment target.** `@Observable` (the thing that makes hearsay's views pure mappings) needs
   macOS 14. `MenuBarExtra` and `NavigationSplitView` need 13. **Recommendation: bump `Package.swift`
   to `.macOS(.v14)`** and use `@Observable`. Staying on 13 means `ObservableObject`/`@Published`
   everywhere — workable, but a second idiom to maintain against the sibling.
2. **SwiftUI.** `MainView.swift:3` justifies AppKit with "keep the binary small". hearsay ships SwiftUI
   for exactly this UI surface and is fine. **Recommendation: SwiftUI for menu + settings + HUD; keep
   AppKit for `RegionSelector`, the panels' window plumbing, and the facecam preview layer** — hearsay
   does the same (`OverlayPanel` is AppKit hosting a SwiftUI root).
3. **Rename to Screensnap** (Part 9). Note up front: changing `CFBundleIdentifier` **resets every TCC
   grant** — screen recording, camera, microphone must be granted again once. Do it now, while the app
   has one user, or never.

---

## Part 4 — Phase 1: the state model (before any pixels)

New `Sources/Screensnap/RecordingPhase.swift`. Nothing renders until the app can *say* what it is doing.

```swift
enum Phase {
    case idle
    case selectingSource(CaptureMode)      // region drag / display / window picker on screen
    case countingDown(remaining: Int)
    case recording(RecordingRun)           // started, source, output, hud
    case encoding(Output)                  // the currently-invisible state
    case settled(Settlement)
}

enum Settlement {
    case saved(Recording)
    case discarded
    case failed(String)
}
```

And the output algebra that kills today's illegal states:

```swift
enum Output {
    case gif(GifEncoder)                  // .imageIO | .gifski(GifskiQuality)
    case mp4(audio: AudioTrack)           // .silent | .microphone
}
```

- `mic-on + GIF` becomes unrepresentable — the "(MP4 only)" parenthetical in the checkbox title disappears
  because the UI can no longer offer it.
- `gifskiEnabled` + `gifskiQuality` (a tandem pair) collapse into one case with its payload.
- `GifEncoder.gifski` gains `isAvailable` (binary located at *pick* time, `Encoders.swift:205`) — the
  direct analogue of `Engine.isAvailable`.

An `@Observable final class Coordinator` (mirroring `hearsay/Coordinator.swift`) owns `phase`, `settings`,
`recordings`, and exposes `start(mode:)`, `finish()`, `discard()`. `AppDelegate` shrinks to lifecycle +
hotkey + status item wiring; today it is 392 lines of flow control.

## Part 5 — Phase 2: one HUD, four states

Delete `ControlBar.swift`, `Toast.swift`, and `CountdownOverlay.swift`'s panel; replace with
`Sources/Screensnap/HUD/` — a port of `Overlay/OverlayPanel.swift` + `OverlayView.swift`.

| Phase | Pill content |
|-------|--------------|
| `countingDown(n)` | big digit, `Cancel`, Esc to cancel |
| `recording` | pulsing red dot · `00:14` monospaced · mic level meter (reuse hearsay's `Waveform` when `Output.mp4(.microphone)`) · `Finish` · `✕` |
| `encoding` | `ProgressView` + "encoding GIF…" — the state the app currently hides |
| `settled(.saved)` | ✓ "Saved — ⌘V to paste" + filename, 0.62 opacity, fades after 2.2 s |
| `settled(.failed)` | ⚠ message, tone `.warn`, stays until dismissed |

Ported verbatim from hearsay: capsule geometry, `pillOpacity` (good news steps back), the fade-out that
survives re-entry, `screenUnderMouse()` placement, `.canJoinAllSpaces/.stationary/.fullScreenAuxiliary`.

Two deliberate divergences, both because screensnap's pill has buttons and hearsay's does not:
- `ignoresMouseEvents = false` while `recording`/`countingDown`, `true` when `settled`.
- Keep `panel.sharingType = .none` (`ControlBar.swift:37`) — screensnap must keep its own HUD out of the
  capture; hearsay has no such constraint. Keep the `windowID` exclusion list too.

## Part 6 — Phase 3: menu-bar first

- `applicationDidFinishLaunching`: `setActivationPolicy(.accessory)`, **no** `showMainWindow()`.
- Port `MenuView.swift` shape: `Record area / Record full screen / Record window…` → status line →
  `Copy last recording` → `⚠ Fix permissions…` when a grant is missing → `Open Screensnap…` → Quit.
- `statusLine` derived from `Phase`, one sentence, hearsay's exact structure:
  `"⌘⇧5-style drag, then Finish"` / `"recording 00:14 — ⌘⇧. to finish"` / `"encoding…"` /
  `"Screen Recording denied — grant it, then relaunch"`.
- The status-item icon keeps its idle/recording render (`StatusItem.swift:180`) — it is already the
  right idea; it just reads `phase` instead of a separate `setState` call.

## Part 7 — Phase 4: the settings window

`Sources/Screensnap/SettingsWindow.swift` — `NavigationSplitView`, `PaneHeader`, 28pt padding,
680pt max width, sections **named by concept**:

| Pane | Contents |
|------|----------|
| **Capture** | Mode cards (Region / Full screen / Window) · cursor toggle · start-delay stepper · **permission rows** (Screen Recording, Camera, Microphone) at the bottom, hearsay-style |
| **Output** | `Output` cards: **GIF · ImageIO** ("fast, 256 colours"), **GIF · gifski** (chip `high quality`, chip `needs gifski` + disabled when the binary is missing), **MP4** (chip `has audio`) · framerate · downsample · quality slider inside the gifski card |
| **Facecam** | camera bubble toggle + live preview + bubble size/corner · mic picker, shown only when output is MP4 |
| **Recordings** | the history list (Part 8) · save folder · filename format · copy-to-clipboard / reveal-in-Finder toggles |

Cards carry a worked example the way `CleanupCard` shows a sample utterance: for Output, show the
*same* 3-second clip's resulting file size per encoder ("~1.4 MB · 256 colours" / "~2.1 MB · dithered" /
"~0.4 MB · H.264"). That is the screen-recorder translation of hearsay's "see what this choice does".

## Part 8 — Phase 5: recordings history

Port `History/HistoryStore.swift` → `Recordings/RecordingsStore.swift`, holding a real record instead of
one URL:

```swift
struct Recording: Identifiable {
    let url: URL
    let at: Date
    let output: Output
    let duration: Duration
    let bytes: Int
}
```

Pane: rows with thumbnail, filename, duration/size/time, per-row **copy · reveal · rename · delete**,
`Clear all`, and a "keep history" toggle — hearsay's `HistoryPane` one-for-one. `Settings.lastRecordingURL`
becomes `recordings.first`; the `.lastRecordingChanged` `NotificationCenter` hop disappears with it
(observation replaces it).

## Part 9 — Phase 6: kill the remaining `NSAlert`s

- **Display / window picker** (`SourcePicker.swift`): replace both `NSAlert`+popup with one SwiftUI
  panel — a thumbnail grid (`SCScreenshotManager` on macOS 14+), app icon + title per window, Esc to
  cancel — matching the region selector's Cmd+Shift+5 feel that already works.
- **Rename** (`MainView.swift:249`): inline `TextField` in the Recordings row, not a modal.
- **Permission required** (`MainView.swift:305`): the pill's `.failed` state + the Capture pane's rows.
- **Errors** (`presentError`): pill `.failed` tone `.warn`; keep the stderr line.

## Part 10 — Phase 7: brand + build parity

- Target `GifRecorder` → `Screensnap`; `CFBundleName`/`DisplayName` → "Screensnap"; bundle id
  `local.gifrecorder` → `local.screensnap`; window title likewise. **One-time TCC re-grant** (Part 3.3).
- Adopt hearsay's `scripts/fix-permissions.sh` idea: a stable local signing cert so grants survive
  rebuilds. `Scripts/build-app.sh:44` currently falls back to ad-hoc signing, which resets TCC on every
  build — the single biggest day-to-day UX tax while developing this app.
- README: drop the stale "No microphone" bullet (mic exists), match the menu paths.
- Optional, mirrors hearsay's `Package.swift`: split targets — `Capture`, `Encoding`, `HUD`, `Recordings`,
  `Screensnap` — so `HUD` cannot import capture code (Parnas: the general must not depend on the specific).

---

## Order and effort

| # | Phase | Depends on | Rough size |
|---|-------|-----------|-----------|
| 1 | State model + Coordinator | Part 3 decisions | M — touches `AppDelegate`, `Settings`, `Encoders` call sites |
| 2 | One HUD | 1 | M — deletes 3 files, adds 2 |
| 3 | Menu-bar first | 1 | S |
| 4 | Settings window | 1, 3 | L — the bulk of the visible change |
| 5 | Recordings history | 1, 4 | M |
| 6 | Kill `NSAlert`s | 4 | M (thumbnail grid is the only real work) |
| 7 | Brand + build | — | S, but do it before 4 so strings are written once |

Each phase builds and ships on its own, hearsay's Part-3 rule.

## What we deliberately keep

- `RegionSelector.swift` — already the best-in-class part of this app, and the `.nonactivatingPanel` +
  `.fullScreenAuxiliary` note is hard-won knowledge.
- The `sharingType = .none` belt-and-braces on every own-window (`Facecam.swift:174` comment) — a
  screen recorder has a constraint hearsay does not.
- The status-item pulse renderer.
- The no-save-dialog flow: file lands on disk with a timestamped name, clipboard gets it, the pill says so.
  That is already the hearsay philosophy — the result goes where the user was, not into a dialog.
