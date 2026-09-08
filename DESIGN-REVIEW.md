# Screensnap — concept design review

A review of Screensnap as a composition of user-facing concepts, done before the
0.2 rewrite, with the resolution each finding got. Concepts are described in the
five-part form (purpose, state, actions, operational principle) where it matters.

## Concept inventory

| # | Concept | Purpose | Operational principle |
|---|---------|---------|-----------------------|
| 1 | **Capture source** [Region, Display, Window] | Say what part of the screen becomes the recording | Pick a source; the recording contains exactly that and nothing else |
| 2 | **Recording** | Turn a span of time on the source into a file | Start, do things, finish; a file appears that replays what happened |
| 3 | **Output** [GIF, GIF·best, MP4, MP4·voice] | Choose the shape of the file so it fits where it is going | Choose MP4·voice; the file plays with sound in a video player. Choose GIF; it plays inline in chat |
| 4 | **Size limit** | Guarantee a file is accepted by the destination | Set 100 MB; every saved file is ≤ 100 MB, or the app says it could not |
| 5 | **Countdown** | Give time to set the stage before frames are captured | Set 3 s; after starting, three seconds pass before the first frame |
| 6 | **Facecam bubble** | Put the presenter into the recording | Turn it on and drag the preview; the file shows the face where the preview was |
| 7 | **Voice track** | Explain while showing | Speak during an MP4 recording; the file plays your words in sync |
| 8 | **Library** | Find, judge, and manage past recordings | Open Recordings; every clip is there with its size and can be copied, compressed, or trashed |
| 9 | **Compression** | Make an existing recording fit somewhere new | Compress to 10 MB; a file ≤ 10 MB exists, original kept or replaced as chosen |
| 10 | **Delivery** | Get the fresh recording where it is going with no extra steps | Finish; ⌘V pastes it |
| 11 | **Hotkey** | Control recording without the mouse | ⌘⇧. starts, cancels, or finishes depending on the moment |
| 12 | **Permissions** | Make the OS grants required for capture visible and fixable | Missing grant → the app names it and opens the right pane |
| 13 | **Update** | Run the latest version without leaving the app | Newer release exists → one click swaps the bundle and relaunches |

### Dependence

`Recording` is the root; `Capture source` and `Output` are needed for it to make
sense. `Size limit`, `Countdown`, `Facecam`, `Voice` refine `Recording`.
`Library` depends on `Recording` having a fixed home; `Compression` depends on
`Library` (it acts on things you can see). `Delivery` and `Hotkey` are
conveniences on `Recording`. `Update` and `Permissions` are app-level.

### Compositions worth naming

- **Size limit × Recording** (automation): the limit is enforced by the same
  `Compressor` the library uses, run in *replace* mode right after encoding.
  One mechanism, two entry points.
- **Voice × Output** (bookkeeping): `Output.mp4(.microphone)` is the only
  representable way to record audio; GIF with a microphone cannot be expressed.
- **Facecam preview × Facecam bubble** (synergy): the preview *is* the
  placement. There is no second placement setting to disagree with it.
- **Hotkey × Phase** (synergy): one key, phase-dependent meaning; the menu and
  pill show the same verbs so the mapping is discoverable.

## Findings and resolutions

| # | Finding | Type | Resolution in 0.2 |
|---|---------|------|--------------------|
| 1 | *Downsample 1–4×* was a mechanism leaking through: users think in "720p" or "fits in Slack", not in integer divisors | purposeless concept | Removed. Replaced by `Size limit` (outcome the user cares about) and `Compression` targets expressed as sizes or resolutions |
| 2 | *Use gifski* toggle plus *quality 20–100* exposed the encoder; when gifski was absent the recording failed after the fact | purposeless + integrity violation | Encoder choice folded into `Output` as `GIF · best`. Availability is decided *before* recording starts (falls back to fast GIF with a note). If gifski fails at finish, the already-captured frames are assembled by ImageIO instead of being lost |
| 3 | Facecam preview did not determine bubble placement; the file disagreed with what the user saw | integrity violation | `FacecamPlacement` is derived from the preview panel's frame relative to the capture frame; the compositor reads it per frame |
| 4 | Microphone toggle existed for GIF, which cannot carry audio; silent no-op | illegal state | `Output` enum: audio only exists on `.mp4(AudioTrack)`; the UI shows the toggle only for MP4 |
| 5 | Two capture-mode clocks: a launcher window mode and a menu-bar mode that could disagree | redundant state | One `Settings.captureMode`; every entry point (menu, hotkey, settings pane) reads and writes the same value |
| 6 | No library. Files went to `~/Documents/gif-recordings` and were never seen again in the app | missing concept | `RecordingsStore` scans and watches one folder (`~/Movies/Screensnap` by default; the legacy folder is adopted if it already has clips). The folder *is* the library — nothing to keep in sync |
| 7 | No way to see what you just made before sending it; size was unknown until Finder | missing state in the UI | The pill's saved state shows name, size, and notes ("shrunk to fit 25 MB"). The library shows size, dimensions, duration for every clip |
| 8 | Countdown overlay stole key focus to accept Escape, hiding the thing being recorded | over-synchronization | Countdown is shown in the non-activating pill. Cancel via the ✕ on the pill or ⌘⇧.; focus stays where it was |
| 9 | Camera or microphone failure silently produced a recording without the feature | under-synchronization | `Degradation` values are attached to the run and reported in the pill ("Camera in use by another app — recording without facecam") |
| 10 | Settings were reachable only through a launcher window that also started recordings; two purposes in one window | overloaded concept | Menu records; a separate Settings window configures. Menu items open the window on the relevant pane |
| 11 | Clipboard copy was GIF-only and copied stale bytes if the file was later changed | integrity violation | `Clipboard.copy` puts the file URL for both formats (plus raw bytes for GIF so chat apps render it inline). Compression and rename run through the library so the URL stays right |
| 12 | Five separate state surfaces (AppDelegate flags, ControlBar, Toast, StatusItem, MainView) each holding part of "what is the app doing" | redundant state | One `Phase` enum on `Coordinator`; the menu bar icon, menu, pill, and settings all render from it |

## New concepts added by request

- **Size limit** (#4 above) — Signal's 100 MB and Discord's 8 MB are the
  motivating destinations; presets carry those names so the purpose is legible.
- **Library** and **Compression** with `CompressionPlacement { replaceOriginal,
  sibling }` — the "replace or keep both" decision is an enum so a third option
  (e.g. *versioned*) has a place to land.
- **Update** — GitHub Releases as the source of truth; local re-signing keeps
  TCC grants intact so an update does not cost the user their permissions.

## Open questions

- Compression to a size for GIFs is a ladder of scale/stride attempts; a
  bisection on quality would converge closer to the limit but gifski has no
  size target. Acceptable for now; revisit if users hit `exceeded` often.
- The library is flat. Folders or tags were deliberately left out until there is
  a purpose they serve that "sort by date, search by name" does not.
