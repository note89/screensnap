# Specs

TLA+ models of the parts of Screensnap where the bugs are interleavings rather
than code: what can happen between two `await`s on the main actor.

## Coordinator.tla

The recording flow as the main actor sees it. Each action is the code between
two suspension points in `Coordinator.begin`, `stop`, `fit` and `compress`, plus
the user actions and the quit protocol that can run in between. Threads off the
main actor only hand results back as main-actor steps, so they appear as the
steps that consume them.

What it checks, in the spec's own words:

| Property | Promise |
|----------|---------|
| `ReplyProtocol` | `reply(toApplicationShouldTerminate:)` only ever answers a `.terminateLater`, once |
| `TerminateSafe` | the process never ends while a file is half-written or a recording would be lost |
| `IntentKept` | a quit does what the one who asked for it meant: exit, or relaunch |
| `OneCompressor` | one `Compressor` at a time, whoever asked |
| `EncodedNeverFailed` | a recording the encoder finished is on disk; the pill must not call it failed |
| `EncoderClosedAtRest`, `ContractsKept` | no encoder is left open once the flow is over; `finish` and `stop` are never called out of order |
| `DevicesOffAtRest` | camera, microphone and preview are off whenever the flow is at rest |
| `NoNewWorkWhileQuitting` | once a quit is accepted and waiting, no new recording starts under it |
| `NoLeakAtQuit` | nothing is left running or half-made when the process exits |
| `QuitAnswered`, `FinishSettles` | every accepted quit is eventually answered; every finish settles |

Run it with `./Scripts/check-model.sh` (needs Java; fetches the TLA+ tools once).
The invariants take seconds; the two liveness properties, with strong fairness,
take minutes.

### What the first run found

Checked against the code as it stood after the Mirdin review landed, the model
found four things that code review had not, each fixed in the same change:

1. `fit()` checked the compression slot, awaited `loadInfo`, and only then claimed
   the slot. A Recordings-pane compression started in that window took the slot,
   and a recording that was already on disk settled as *failed*. `run(_:)` now
   claims the slot before anything is awaited, and a shrink that cannot run is a
   note on the saved recording (`FitOutcome.notShrunk`), never a failure.
2. A `stop(_:)` task spawned for one recording could run after that recording
   ended and the next one began, and finish the wrong one. Sessions carry an id;
   a stop that finds a different session does nothing.
3. A quit accepted while a recording was being set up (`.starting` is a safe
   moment, nothing is on disk yet) left the camera running and an encoder's
   scratch folder behind. `Coordinator.willTerminate()` abandons the setup in
   flight on the way out.
4. `record()` and `compress()` accepted new work under a quit that was waiting
   for a save, so the quit could wait indefinitely. Both now refuse while
   `isQuitting`, and the menu says why.

### Keeping it honest

The model is only worth what it matches. When `Coordinator` gains an `await`, a
new way to end a recording, or a new thing a quit can wait on, add the step
here first, run the checker, then write the code. The spec's comments name the
Swift it stands for, line by line.
