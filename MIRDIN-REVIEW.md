# Screensnap — design review, Mirdin lens

A review of the whole tree at `e177ec0` against the principles taught in Mirdin's
software design course (Jimmy Koppel): the three levels of software, the
Embedded Design Principle, the Representable/Valid principle, hidden coupling
and information hiding, Hoare-style contracts, consistency, dark knowledge.
`DESIGN-REVIEW.md` reviewed the *concepts*; this one reviews how faithfully the
code embeds them. Findings are ranked; each names the principle, the evidence,
and the change that would resolve it. The line references are to `e177ec0`, the
tree as reviewed; "Resolutions" at the end says what each finding became.

## Bottom line

One finding is a bug you can reproduce today: a GIF recording that was paused
comes out longer than what was recorded, because the ImageIO encoder derives
the animation's end from the wall clock while `ScreenRecorder` shifts its own
clock on every pause (finding 1). Everything else is structural. The code
already embeds its design unusually well (see "What already holds"); the
remaining gaps cluster around three things: quantities that carry their
coordinate system or clock only in comments, the same concept implemented
twice with different safety, and invariants kept by call discipline rather
than by type.

| # | Finding | Principle | Weight |
|---|---------|-----------|--------|
| 1 | GIF end time ignores pauses; four clocks for one quantity | Hidden coupling · Representable/Valid | **Bug** |
| 2 | Screen coordinates are bare `CGRect`s in four conventions | Dark knowledge · types as units | High |
| 3 | Replace-original trashes first, moves second, from a foreign volume | Contracts · consistency | High |
| 4 | Size-limit fit and manual compression: one mechanism in the design, two in the code | Embedded design | Medium |
| 5 | Two degradations, two treatments; `EncoderSetup.make` accepts contradictory inputs | Representable/Valid · consistency | Medium |
| 6 | The encoder call-order contract is unwritten; one of three encoders enforces it | Contracts · ghost state | Medium |
| 7 | Session teardown is hand-rolled three times inside `begin()` | Consistency · resource contracts | Medium |
| 8 | "A usable file stem" and "a recording extension" are each defined in two or three places | Embedded design | Medium |
| 9 | `HUDPanel` keeps six variables whose legal combinations are policed by hand | Representable/Valid | Medium |
| 10 | Sentinels stand in for absence; `SourcePicker.choose` has an impossible input and a three-way nil | Representable/Valid | Low-Medium |
| 11 | Save folder lives in `Settings` and `RecordingsStore`, kept equal by one method | Representable/Valid | Low-Medium |
| 12 | gifski availability is a design concept with no home in the code | Embedded design · parse, don't validate | Low-Medium |
| 13 | `Settlement` carries strings and recomputes facts at render time | Three levels · Representable/Valid | Low |
| 14 | Getters that start work (`info(for:)`, `thumbnail(for:)`) | Naming · locality | Low |
| 15 | `Framerate` newtype dropped at the encoder boundary | Types as contracts | Low |
| 16 | `Relaunch` is a static side channel; `PendingQuit` is half of its state | Information hiding | Low |
| 17 | Module boundary by convention only; HUD views take the whole `Coordinator` | Parnas · interface minimalism | Low |
| 18 | Per-frame facecam compositing runs on the main actor because the precondition lives there | Three levels (runtime) | Low |

---

## 1. GIF end time ignores pauses; four clocks for one quantity — Bug

**Principle.** Hidden coupling: two modules agree on an invariant that neither
states. Representable/Valid: one quantity, several representations that can
disagree.

**Evidence.** `ScreenRecorder` stamps every frame with `timestamp` (seconds of
*recorded* time) and `hostTime` (`CACurrentMediaTime()`), and on resume it moves
its origin forward by the pause so `timestamp` has no gap
(`ScreenRecorder.swift:204-211`, `:237-241`). `ImageIOGifEncoder` assumes the
two differ by a constant: it records `startHostTime = hostTime - timestamp` on
the first frame (`Encoders.swift:107`) and closes the animation at
`CACurrentMediaTime() - startHostTime` (`Encoders.swift:127`). After a pause of
*P* seconds that constant is off by *P*, so the last frame's delay, and the
GIF's total length, grow by *P*. `togglePause` tells the recorder and the audio
channel, never the encoder (`Coordinator.swift:324-337`).

The same quantity, "recorded time excluding pauses", is also kept as
`RecordingClock` on `RecordingRun` for the pill, on the `Date` clock
(`Phase.swift:24-46`), and as `hostZero` inside `AudioWriterChannel`
(`Encoders.swift:336, 371-376`). Four clocks; three are kept in step by
`togglePause` calling each in turn; the fourth was forgotten. That is the
failure mode redundant state always has.

**Resolution.** The recorder owns the recording clock; nobody else should
reconstruct it from the host clock. Have `ScreenRecorder.stop()` return the
final elapsed time (its `FrameClock` knows it in both `.running` and `.paused`),
and change the protocol to `finish(at end: CFTimeInterval)`. `ImageIOGifEncoder`
then drops `startHostTime` and its `CACurrentMediaTime()` call; the gifski
fallback (`Encoders.swift:224`) can use the same `end` instead of guessing
`last + 1/fps`. Feed `RecordingRun.clock` from the values `pause()`/`resume()`
already return, and the pill, the file and the audio agree by construction.

## 2. Screen coordinates are bare `CGRect`s in four conventions — High

**Principle.** Dark knowledge: what you must know to change the code, held only
in comments. Types as units: a value's frame of reference is part of its type.

**Evidence.** The tree passes around at least four kinds of rectangle, all as
`CGRect`:

- display-local pixels, top-left origin: `SelectedRegion.pixelRect`
  (`RegionSelector.swift:9-11`), what `SCStreamConfiguration.sourceRect` wants;
- global AppKit points, bottom-left origin: `CaptureSource.screenFrame`
  (`ScreenRecorder.swift:57-76`), `NSScreen.frame`, the facecam preview's frame;
- global points, top-left origin: `SCWindow.frame` (`ScreenRecorder.swift:46-48`),
  `CGWindowList` bounds (`GrantPanel.swift:103-104`);
- fractions of the capture frame, y up: `FacecamPlacement` (`Facecam.swift:77-85`).

Every conversion is a hand-written formula with a comment explaining the axes
(`RegionSelector.swift:103-112`, `ScreenRecorder.swift:64-69, 73-74`,
`GrantPanel.swift:103-104`, `Facecam.swift:169-175`). The compiler cannot tell
a rect in one convention from a rect in another, so nothing stops a caller
mixing them. It has already happened once: commit `00ab8e3` fixed
`pixelSize` testing a top-left `SCWindow.frame` against bottom-left
`NSScreen.frame`, which chose the wrong display's backing scale on a second
monitor. The GIF side of the codebase shows the cure: `PixelRect`/`PixelPoint`
(`FrameDiff.swift:5-21`) say what they are, and `GIFFileWriter` cannot be
handed anything else.

**Resolution.** Two small wrapper types, `ScreenRect` (global AppKit points,
bottom-left) and `DisplayPixelRect` (display-local pixels, top-left, paired
with its `CGDirectDisplayID`), plus named conversions
(`ScreenRect(window: SCWindow)`, `DisplayPixelRect(selection:on:)`,
`ScreenRect.pixels(on screen:)`). `CaptureSource.screenFrame` becomes a
`ScreenRect`; `FacecamPreviewWindow`, `CountdownOverlay.show(over:)` and
`GrantPanel.place(beside:)` take one; the comments become constructors. The
`00ab8e3` class of bug stops compiling.

## 3. Replace-original trashes first, moves second, from a foreign volume — High

**Principle.** Hoare logic: the postcondition on failure should be "nothing
changed". Consistency: the same operation should be done the same way
everywhere. Representable/Valid: guard against a bad state by making it
unreachable, not by policing it.

**Evidence.** `Compressor.place` with `.replaceOriginal` moves the original to
the Trash and *then* moves the scratch file into its place
(`Compressor.swift:125-127, 135`). The scratch lives in `temporaryDirectory`
(`Compressor.swift:106-109`), which need not be on the recordings folder's
volume, so the move can be a copy that fails part way or takes long enough to
be interrupted. Between the two steps the user has neither file in the
library. The codebase knows this: `QuitRisk.interruptsSave` exists to stop a
quit from "leav[ing] a replaced original in the Trash with its replacement
lost" (`Coordinator.swift:72-74`). It also knows the right way: `GIFFrameStream`
writes to an `itemReplacementDirectory` on the same volume and swaps with
`replaceItemAt` (`GIFStream.swift:90-92, 201-207`), so there is never a moment
without a complete file. Two implementations of "put a new file where the old
one was", with different safety.

**Resolution.** Stage the result *beside* the original first
(`FileManager.unusedURL` in the recordings folder; that move is on-volume and
atomic), then trash the original, then rename the staged file to the original
name. Every intermediate state has a complete file with a recording extension,
so the library shows something at every step and a crash loses nothing. The
Trash copy the design promises is kept. With that ordering, quitting during a
compression no longer needs to be held; `interruptsSave` shrinks to encoding.

## 4. Size-limit fit and manual compression: one mechanism in the design, two in the code — Medium

**Principle.** Embedded Design Principle: when the design says "one mechanism,
two entry points" (`DESIGN-REVIEW.md`, *Size limit × Recording*), the code
should have one mechanism.

**Evidence.** Both paths call `Compressor.compress`, but their bookkeeping
differs. The post-recording fit is a case of `Activity.finishing`
(`Coordinator.swift:522-531`); a manual compression is a separate
`compression: CompressionJob?` slot (`Coordinator.swift:127, 622-651`). The
manual entry guards only on its own slot, and the Recordings pane disables its
button only on that slot (`SettingsWindow.swift:649`), not while a fit is
running. So a fit and a manual compression of the *same file*, both with
`.replaceOriginal`, are representable: the library shows the fresh row before
the fit starts (`Coordinator.swift:506-511`). Two concurrent trash-and-move
sequences on one URL is exactly the race finding 3 makes survivable but not
correct.

**Resolution.** One job slot. Either give `CompressionJob` an origin
(`.sizeLimit` / `.manual`) and have `fit` claim it through the same `compress`
path, or fold the slot into `Activity` (a compression is something the
coordinator is doing). Then "two compressions at once" is unrepresentable and
`quitRisk` no longer needs its `compression == nil` special case
(`Coordinator.swift:223-229`).

## 5. Two degradations, two treatments; `EncoderSetup.make` accepts contradictory inputs — Medium

**Principle.** Consistency: two instances of the same concept should be handled
the same way. Representable/Valid on inputs.

**Evidence.** When gifski is missing, `effective()` *rewrites the output* to
`.gif(.fast)` and adds a note (`Coordinator.swift:453-456`), so `RecordingRun.
output` is what will actually be produced. When the microphone is denied, the
output stays `.mp4(.microphone)` and a boolean rides beside it
(`Coordinator.swift:375-379`); the encoder is told separately
(`audio: microphoneGranted ? .microphone : .none`, `:404`). Consequences:

- `EncoderSetup.make(output:audio:)` (`Encoders.swift:30-40`) can be asked for
  `.gif(_)` with `audio: .microphone` (silently ignored) or
  `.mp4(.microphone)` with `audio: .none` (the degraded case), so the `Output`
  algebra that `DESIGN-REVIEW.md` finding 4 introduced to make "mic with GIF"
  unrepresentable is undone one layer down.
- The pill renders the run from `run.output`, so a denied microphone still
  shows the "MP4 · voice" chip and a `MicMeter` pinned at zero
  (`HUDView.swift:191-196`), contradicted only by a note underneath.

**Resolution.** Decide the effective output once, before `.starting`: apply
the gifski fallback *and* the microphone fallback to produce a single `Output`
plus its `[Degradation]`, and let `EncoderSetup.make(output:)` read the audio
track from the output alone. The run, the pill and the encoder then cannot
disagree about whether voice is being recorded.

## 6. The encoder call-order contract is unwritten; one of three encoders enforces it — Medium

**Principle.** Contracts: a protocol's legal call sequences are part of its
interface. Ghost state: when the sequence matters, the position in it is state,
and should be represented.

**Evidence.** `FrameEncoder` (`Encoders.swift:10-15`) says nothing about
ordering, yet every implementation has one: `append*` then exactly one of
`finish` or `cancel`, then nothing. `ImageIOGifEncoder` represents its position
(`EncoderState`, `:84-89`) and refuses out-of-order calls (`:104-109, 122-129`).
`GifskiEncoder` uses a bare `isCancelled` (`:170`) and has no "finished" state.
`MP4Encoder` uses `startTime: CFTimeInterval?` as a started flag (`:416`) and
has neither: a second `finish()` reaches `finishWriting` twice, and `cancel()`
after `finish()` calls `cancelWriting` on a completed writer, both of which
AVFoundation treats as programmer errors. `AudioWriterChannel` has the same
shape: `resume()` after `markFinished()` sets `isAccepting = true` and the next
buffer appends to a finished input (`Encoders.swift:333-338, 367-389`).

None of this fires today because `Coordinator` only calls each method from the
one `Activity` case where it is legal. That is the definition of hidden
coupling: the encoder's precondition is enforced by a state machine in another
file.

**Resolution.** Write the contract on the protocol, and make it cheap to obey:
one small `enum Lifecycle { case open, finished, cancelled }` used by all three
encoders, or a single wrapper that enforces the sequence once and delegates.
`AudioWriterChannel.State` becomes `{ waitingForVideo, live(hostZero),
paused(hostZero), finished }` so "resume a finished channel" is a no-op by
construction.

## 7. Session teardown is hand-rolled three times inside `begin()` — Medium

**Principle.** Consistency and resource contracts: what was acquired must be
released, and the release should be written once.

**Evidence.** `begin()` acquires camera, preview, encoder, microphone and
recorder in sequence, and each failure exit releases whatever exists so far by
hand: after a cancelled countdown (`Coordinator.swift:388-392`), after
`EncoderSetup.make` throws (`:406-411`), after `recorder.start()` throws
(`:434-443`). The three lists already differ, correctly, because different
things exist at each point. `RecordingSession.stopDevices()` (`:29-33`) exists
for the happy path only, because the struct cannot be built until everything
succeeded. The next acquisition added to `begin()` has to be threaded into
every exit by hand.

**Resolution.** An accumulator: `var setup = SessionSetup()` whose optional
fields fill in as each device comes up and whose single `abandon()` releases
whatever is set. `RecordingSession.init(setup)` consumes it when all are
present. One teardown, one place to add the next device.

## 8. "A usable file stem" and "a recording extension" are each defined in two or three places — Medium

**Principle.** Embedded Design Principle: one concept, one definition.

**Evidence.**

- *Valid file stem.* `FilenameTemplate.parse` rejects blank, leading dot and
  forbidden characters (`FilenameTemplate.swift:63-70`); `RecordingsStore.rename`
  re-implements the same three checks (`RecordingsStore.swift:117-120`).
  `ParseError` and `RenameError` carry the same two message strings verbatim
  (`FilenameTemplate.swift:43-44`, `RecordingsStore.swift:164-165`). A new rule
  (say, trailing spaces) must be added twice or the two surfaces disagree.
- *Recording extension.* `Recording.extensions` (`Recording.swift:17`),
  the literal `["gif", "mp4"]` in `Settings.resolveSaveFolder`
  (`Settings.swift:186`) and the cases of `OutputContainer` (`Output.swift:58-65`)
  all encode "which files count". `OutputContainer(url:)` then re-derives the
  container from the URL in three places that already hold a `Recording` with
  a `container` field (`Coordinator.swift:541`, `HUDView.swift:231`,
  `Recording.swift:127`).

**Resolution.** A `FileStem` value with one failable parser and one error
enum; `FilenameTemplate.stem(at:)` returns it and `rename` takes it. Derive
`Recording.extensions` from `OutputContainer.allCases` and use it in
`resolveSaveFolder`. Give `Clipboard.copy` a `Recording` and delete the
`OutputContainer(url:)` calls at the three sites; the initializer's "anything
not mp4 is gif" then only ever sees URLs that passed the extension filter.

## 9. `HUDPanel` keeps six variables whose legal combinations are policed by hand — Medium

**Principle.** Representable/Valid: if two fields may only take certain
combinations, they are one field.

**Evidence.** `visibility`, `stage`, `presence`, `drag`, `hotkey`, `dock`
(`HUDPanel.swift:130-140`). The invariants: `presence == .tucked` only while
`stage == .live`; `hotkey != nil` iff `stage == .live`; `drag != nil` only
while `visibility` is `.shown`. Each is maintained by resetting fields in
`render` (`:176-191`), `togglePresence` (`:203`) and `hide` (`:286`). The
`layout` computation has to switch on a tuple and dismiss combinations that
"cannot happen" (`:264-266`).

A related inconsistency: the tucked-controls hotkey ⌃⌘H is claimed with a
plain `GlobalHotkey?` (`:195-200`) and, if Carbon refuses it, the marker, the
tooltip and the menu keep advertising it (`HUDView.swift:115, 130`,
`MenuView.swift:23, 26`). The other hotkey got `HotkeyRegistration` for exactly
this case (`Coordinator.swift:49-65`). Same concept, two treatments.

**Resolution.** `enum Stage { case absent; case live(presence:, hotkey:
HotkeyRegistration, drag: Drag?); case report }` leaves `dock` and
`visibility` as the only other fields, and the invalid combinations have no
spelling. Reuse `HotkeyRegistration` for ⌃⌘H and let the marker read
`advertisedKeys`.

## 10. Sentinels stand in for absence; `SourcePicker.choose` has an impossible input and a three-way nil — Low-Medium

**Principle.** Representable/Valid: absence is a value, not a magic number;
a function's parameter type should be its domain.

**Evidence.**

- `CaptureSource.screenFrame` returns `.zero` when the display is gone
  (`ScreenRecorder.swift:62, 71`); the countdown overlay then sets a zero
  frame and orders front, and the preview guards `width > 0` to detect it.
- `pixelSize` guesses a backing scale of `2` when it cannot find the screen
  (`:37, 40`): a silent half-size or double-size stream rather than an error.
- `NSScreen.displayID` answers `CGMainDisplayID()` for a screen with no
  display number (`RegionSelector.swift:137-140`), so an unidentifiable
  display is captured as the main one.
- `SourcePicker.choose(_ mode: CaptureMode)` accepts `.region`, which it can
  only answer with `nil` (`SourcePicker.swift:58-59`); its `nil` also means
  "cancelled" and "`SCShareableContent` failed". `Coordinator` treats all
  three as "back to idle" without a word (`Coordinator.swift:301-306`).

**Resolution.** `screenFrame: ScreenRect?` (with finding 2) and let `begin`
fail with a message when the display is gone. A two-case `PickableKind
{ display, window }` for the picker, and a `Result<CaptureSource?, Error>` or
an enum `{ picked, cancelled, unavailable(Error) }` so a failed content query
reaches the pill.

## 11. Save folder lives in `Settings` and `RecordingsStore`, kept equal by one method — Low-Medium

**Principle.** Representable/Valid: one fact, one owner.

**Evidence.** `Settings.saveFolder` (`Settings.swift:138`) and
`RecordingsStore.folder` (`RecordingsStore.swift:23`) are the same fact.
`Coordinator.setSaveFolder` writes both (`Coordinator.swift:617-620`), but
`settings.saveFolder` is a public `var` any view can assign, after which the
library watches the wrong folder. `begin()` also creates the folder itself
(`:398`) although `RecordingsStore.ensureFolderExists` already does.

**Resolution.** Make `Settings.saveFolder` `private(set)` with the coordinator
as its one writer, or have the store take the folder from `Settings` and
observe it. Drop the second `createDirectory`.

## 12. gifski availability is a design concept with no home in the code — Low-Medium

**Principle.** Embedded Design Principle; parse, don't validate: locate once,
pass the located thing.

**Evidence.** `DESIGN-REVIEW.md` finding 2 made "gifski available?" a decision
taken before recording. In code it is a filesystem probe made in three places:
`Coordinator.effective` (`Coordinator.swift:454`), `GifskiEncoder.init`, which
probes again and throws a different message if the binary vanished in between
(`Encoders.swift:172-178`), and `OutputPane.gifskiInstalled`, evaluated inside
SwiftUI `body` on every redraw (`SettingsWindow.swift:281`).

**Resolution.** `Coordinator.gifski: GifskiAvailability { located(URL),
missing }`, refreshed with `refreshPermissions()` on activation. `effective()`
consumes it and hands the `URL` to `GifskiEncoder.init(gifski: URL, …)`, which
then cannot fail for that reason; the pane reads the same value.

## 13. `Settlement` carries strings and recomputes facts at render time — Low

**Principle.** Three levels: code that happens to show the right thing is
not the same as code that records what happened. Representable/Valid:
structure over strings.

**Evidence.** `Settlement.saved(Recording, notes: [String])`
(`Phase.swift:67`): the notes are `Degradation.message` values plus two
sentences composed in `stop()` ("shrunk to fit …", "could not get under …",
`Coordinator.swift:505, 512`), so the pill cannot treat a failed fit differently
from a note. The "⌘V to paste" suffix is recomputed from the *current* clipboard
setting when the pill draws (`HUDView.swift:231`), not from whether
`deliver()` copied; change the setting during the five-second linger and the
message changes.

**Resolution.** `Settlement.saved(Recording, degradations: [Degradation],
fit: FitOutcome?, delivered: Delivery)`. Rendering becomes a pure function of
what happened.

## 14. Getters that start work — Low

**Principle.** Naming and locality: a call that looks like a read should be a
read.

**Evidence.** `RecordingsStore.info(for:)` and `thumbnail(for:)` return `nil`
*and* kick off an async load on first call (`RecordingsStore.swift:68-94`).
That is the right behaviour for a SwiftUI `body`, but the name hides it, and
`Coordinator.compress` reads `info(for:)`, gets `nil`, and loads the same file
a second time itself (`Coordinator.swift:624-629`).

**Resolution.** Name the side effect (`infoIfLoaded(for:)` / `requestInfo(for:)`)
or expose an `async func loadInfo(for:)` that the coordinator awaits and the
view's getter shares.

## 15. `Framerate` newtype dropped at the encoder boundary — Low

**Principle.** Types as contracts: a validated value should stay validated
across boundaries.

**Evidence.** `Framerate` guarantees 1…60 (`Settings.swift:36-41`) and
`ScreenRecorder` takes it (`Coordinator.swift:429`), but `EncoderSetup.make`
takes `framerate: Int` (`Encoders.swift:30`, `Coordinator.swift:403` unwraps
`.fps`). `GifskiEncoder` then re-guards with `max(1, framerate)`
(`Encoders.swift:224`): a defensive check that exists only because the type
was thrown away one call earlier.

**Resolution.** Pass `Framerate` through; delete the re-guard.

## 16. `Relaunch` is a static side channel; `PendingQuit` is half of its state — Low

**Principle.** Information hiding: the decision "what happens when the process
exits" should have one owner.

**Evidence.** `Relaunch.request` is process-global mutable state
(`Permissions.swift:103-134`) written from the menu, two settings buttons, the
updater and the coordinator (`MenuView.swift:50`, `SettingsWindow.swift:224,
850`, `Updater.swift:138`, `Coordinator.swift:181, 283`) and read by
`AppDelegate`. `Coordinator.PendingQuit` (`Coordinator.swift:77-81`) is the
other half of the same question, and the coordinator has to remember to call
`Relaunch.cancel()` on each path that cancels a quit (`:210, 237`).

**Resolution.** One `Coordinator.quit(then: .exit | .relaunch)` entry point
that views and the updater call; `PendingQuit` carries the intent; `Relaunch`
becomes a private detail the delegate asks the coordinator about.

## 17. Module boundary by convention only; HUD views take the whole `Coordinator` — Low

**Principle.** Parnas: a module boundary the compiler enforces is worth more
than one in a document. Interface minimalism.

**Evidence.** `PLAN-UI.md` Part 10 proposed splitting targets so HUD code
cannot import capture code; `Package.swift` still has one target. `HUDView`
and `Pill` take the entire `Coordinator` (`HUDView.swift:3-5, 20-23`) and reach
through it to `settings.delivery` and `library.reveal` (`:231, 239`). The
hand-listed sources in `Scripts/check-gif-stream.sh:13-17` are the same
boundary drawn by hand: `Output.swift` is compiled into the GIF checks only
because `Dimensions` lives there.

**Resolution.** Views take `Phase` plus a small action protocol (`finish`,
`discard`, `togglePause`, `restart`, `reveal`). Move `Dimensions`, `PixelRect`,
`PixelPoint` into a geometry file. When a second target appears, `HUD` and
`GIF` are the two that fall out first.

## 18. Per-frame facecam compositing runs on the main actor because the precondition lives there — Low

**Principle.** Three levels: a design decision at the logic level (the
coordinator owns "are we recording") has a runtime cost the design did not
choose.

**Evidence.** `FrameSink` is `@MainActor` (`ScreenRecorder.swift:79-83`);
every captured frame hops to the main actor (`:247-249`) so `sinkDidCapture`
can check `case .recording` and then draws a full-frame `CGContext` composite
there (`Coordinator.swift:591-602`, `Facecam.swift:105-149`) before handing
the frame to an encoder that hops back to a background queue. The check is
there because the state is there.

**Resolution.** At `enter(.recording)`, hand the recorder a `Sendable` frame
pipeline (encoder, camera, placement source) whose lifetime *is* the recording;
the recorder delivers frames to it off-main, and the coordinator keeps only
the failure callback. "Frames after stop are ignored" then follows from the
pipeline being gone rather than from a check.

---

## What already holds

These are the places the code embeds its design well; they set the standard
the findings above are measured against, and are worth keeping as they are.

- **The output algebra.** `Output { gif(GifQuality), mp4(AudioTrack) }`
  (`Output.swift:15-19`) makes "gifski with MP4" and "mic with GIF"
  unrepresentable, and `Settings` keeps the three remembered preferences
  separate from the one valid projection (`Settings.swift:141-143`).
- **`Activity` and its `Phase` projection.** Resources live only in the
  activity that owns them (`Coordinator.swift:17-19, 83-107`); `enter(_:)` is
  the single writer that releases the old and renders the new (`:570-587`).
  Every surface renders from one value; the quit logic is a function of it.
- **Parse, don't validate, at the edges.** `FilenameTemplate` can only be made
  by parsing (`FilenameTemplate.swift:3-6`); `SizeLimit.Ceiling` cannot be
  zero (`Output.swift:72-95`); `StartDelay` and `Framerate` are clamped once
  at construction (`Settings.swift:26-41`); `DeviceAccess` turns
  `AVAuthorizationStatus` into the three cases the UI can act on
  (`Permissions.swift:11-26`).
- **State machines where the sequence matters.** `GIFFrameStream.State`
  (`GIFStream.swift:53-60`), `ScreenRecorder.FrameClock` with the comment
  explaining why it is one value (`ScreenRecorder.swift:116-125`),
  `ImageIOGifEncoder.Intake` and `EncoderState`, `MenuBarGlyph` with
  `afterBeat` (`MenuBarStatus.swift:5-43`), `RegionSelector`'s `Hint`.
- **Dark knowledge written down where it bites.** `MENUBAR_LABEL_IS_STATIC`
  (`MenuBarStatus.swift:72-76`), the `sharingType = .none` explanation of the
  double-circle bug (`Facecam.swift:191-198`), the `URL.resourceValues` cache
  note (`Compressor.swift:139-141`), the `.nonactivatingPanel +
  .fullScreenAuxiliary` note (`RegionSelector.swift:61-64`), ARG_MAX
  accounting for gifski (`Encoders.swift:236-239, 265-273`). These are the
  comments Mirdin asks for: the *why* the code cannot say.
- **Stated preconditions.** `FramePixels.opacity(in:)` says `rect` must lie
  within the frame (`FrameDiff.swift:151`); `firstDifference`/`lastDifference`
  say the range must contain one (`:193, 203`).
- **A pure core with checks.** `GIFFrameStream` and `FrameDiff` are testable
  without Xcode and are tested, including the property check against a
  brute-force diff (`Tests/GIFStreamChecks/main.swift:106-126`). The same
  treatment would suit `FilenameTemplate`, `RecordingClock`, `HUDDock`,
  `SemanticVersion` and `Dimensions.scaled`, all of which are already pure.

## Suggested order

1. Finding 1 (bug, small, contained in `ScreenRecorder`/`Encoders`/`Coordinator`).
2. Finding 3, then 4 (both touch `Compressor.place` and the job slot; do together).
3. Finding 2 (mechanical, wide; best done in one pass with the compiler driving).
4. Findings 5, 6, 7 (all inside `begin()`/`Encoders.swift`; one PR).
5. The rest as they are touched.

---

## Resolutions

What each finding became in the tree that followed the review.

| # | Resolution |
|---|------------|
| 1 | `ScreenRecorder.stop()` returns the recording's length on its own clock and `FrameEncoder.finish(at:)` takes it; the ImageIO encoder no longer reads the host clock, and the gifski fallback closes at the same `end`. `pause()` returns the elapsed time and the pill's `RecordingClock` is fed from it, so the pill, the file and the audio agree by construction. |
| 2 | `ScreenRect` (global AppKit points) and `DisplayPixelRect` (display-local pixels, with its display) in `ScreenGeometry.swift`, with the conversions as constructors. `CaptureSource.resolveGeometry()` measures a source once into a `CaptureGeometry` that the recorder, the encoder, the preview and the countdown all read. |
| 3 | `Compressor` builds on the recording's volume (`itemReplacementDirectory`) and, for replace-original, stages the result beside the original before trashing it; a failed swap leaves the staged file and says so (`CompressionError.leftBeside`). |
| 4 | One job slot: `Coordinator.run(_:info:)` is the only way a compression runs, and the size-limit fit goes through it with `CompressionJob.origin == .sizeLimit`. `FinishStep.fittingToLimit` shows the slot's progress; a slot already taken yields `FitOutcome.skipped` instead of a second compression. |
| 5 | `EncoderChoice` is decided once by `Coordinator.plan` and the microphone fallback rewrites it, so `RecordingRun.output` is what the encoder produces. `EncoderSetup.make(_:)` takes the choice alone; `MicrophoneCapture.deliver(to:)` lets the microphone come up before the encoder exists. |
| 6 | The sequence is written on `FrameEncoder` and kept by one `EncoderLifecycle` in all three encoders. `AudioWriterChannel.State` and `MP4Encoder.Session` are enums; a finished writer cannot be resumed, appended to, or finished twice. |
| 7 | `SessionSetup` accumulates what `begin()` brings up and `abandon()` releases whatever is there; every exit calls it. |
| 8 | `FileStem` is the one parser for a usable file name; the template renders to one and rename takes one. `OutputContainer`'s cases are the one list of recording extensions; `Recording` and the legacy-folder check derive from it. `Clipboard.copy` takes a `Recording`. |
| 9 | `HUDPanel.Stage.live(Live)` carries presence and the hotkey; `Visibility.shown(on:drag:)` carries the drag. ⌃⌘H is an `AdvertisedHotkey`, and every surface reads its keys from `HUDChrome.presenceKeys`, nil when Carbon refused it. |
| 10 | A source whose display is gone fails `begin()` with a message instead of a zero rectangle or a guessed scale; `NSScreen.displayID` is optional. `SourcePicker.choose` takes a `PickableKind` and answers with `SourceChoice`, so a failed content query reaches the pill. |
| 11 | `RecordingsStore` owns the folder and remembers it; `Settings.saveFolder` is gone, and `newRecordingURL` lives with the folder it names into. |
| 12 | `GifskiAvailability` on the coordinator, refreshed with the permissions; `plan` consumes it and `GifskiEncoder.init(gifski:)` takes the located URL. |
| 13 | `Settlement.saved(SavedRecording)` carries the degradations, the `FitOutcome` and what `deliver` did (`Delivered`); the pill renders those. |
| 14 | `requestInfo(for:)` / `requestThumbnail(for:)` for views, `loadInfo(for:)` for callers that wait. |
| 15 | `Framerate` reaches every encoder; the re-clamp is gone. |
| 16 | `Coordinator.quit(then:)` is the one entry; `PendingQuit.waitingForSave(then:)` carries the intent and `afterQuit` records the accepted one for the delegate. `Relaunch` only launches. `Updater.install()` reports an `InstallOutcome` and the coordinator relaunches. |
| 17 | The pill sees a `HUDModel` protocol, not the coordinator. `Dimensions`, `PixelPoint` and `PixelRect` live in `Geometry.swift`; the check script lists it and CI runs the checks. A second SwiftPM target is still deferred. |
| 18 | `FacecamOverlay` draws the bubble on the capture queue, reading `CameraCapture` and a `FacecamPlacementSource` the preview publishes to on every move. The main-actor hop remains only to hand the finished frame to the encoder, which is main-actor bound. |
