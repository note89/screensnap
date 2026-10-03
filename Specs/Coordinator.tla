---------------------------- MODULE Coordinator ----------------------------
(***************************************************************************)
(* Screensnap's recording flow as the main actor sees it.                  *)
(*                                                                         *)
(* Every `await` in Coordinator.begin, stop, fit and compress is a point   *)
(* where other main-actor work runs: user actions, other tasks' next       *)
(* steps, the quit protocol. Each action below is the code between two     *)
(* such points, so TLC explores exactly the interleavings the main actor   *)
(* allows and no others. Threads off the main actor (capture queue, mic    *)
(* queue) only ever hand results back as main-actor steps, so they appear  *)
(* here as the steps that consume their results.                           *)
(*                                                                         *)
(* releasePendingQuitIfSafe() runs synchronously inside enter(_:); the     *)
(* model marks `needsRelease` and runs DoRelease as the only enabled step  *)
(* right after, which is the same thing with less repetition. Because that *)
(* step briefly disables every other one, task steps get strong fairness:  *)
(* a resumed task on the main actor is never starved by bookkeeping.       *)
(*                                                                         *)
(* The first version of this model, checked against the code as it stood  *)
(* after PR #7, found four things, each fixed in the code and here:        *)
(*  - fit() checked the compression slot, awaited loadInfo, then claimed   *)
(*    it; a Recordings-pane compression in that window made a recording   *)
(*    that was already on disk settle as "failed" (EncodedNeverFailed).    *)
(*  - a stop(_:) task spawned for one recording could run after the next  *)
(*    one began and finish that one instead (ContractsKept).               *)
(*  - a quit accepted while a recording was being set up left the camera  *)
(*    running and an encoder's scratch space behind (NoLeakAtQuit).        *)
(*  - record() and compress() accepted new work under a quit that was      *)
(*    waiting for a save, so the quit could wait forever                   *)
(*    (NoNewWorkWhileQuitting, QuitAnswered).                              *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANT StopSlots      \* how many stop(_:) tasks may be in flight at once

Intents == {"exit", "relaunch"}
Settled == {"saved", "failed", "discarded"}
Rest == Settled \cup {"idle"}
StopReasons == {"finish", "discard", "restart", "abort"}

VARIABLES
  activity,       \* Activity, as Phase sees it
  compression,    \* the one compression job slot: "none" | "sizeLimit" | "manual"
  pendingQuit,    \* PendingQuit: "none" | the AfterQuit intent being waited on
  afterQuit,      \* what applicationWillTerminate will do
  terminated,     \* AppKit was told to terminate now, or replied true
  outstanding,    \* AppKit is waiting on reply(toApplicationShouldTerminate:)
  badReply,       \* a reply was sent with nothing outstanding
  accepted,       \* the intent of the quit that went through
  encoder,        \* the current session's encoder: "none" | "open" | "finished" | "failed" | "cancelled"
  encoderMisuse,  \* finish(at:) called on an encoder that was not open
  recorder,       \* "none" | "started" | "stopped"
  recorderMisuse, \* stop() called on a recorder that was not started
  devices,        \* camera, microphone, preview: "off" | "on"
  beginPc,        \* where begin(source:) is suspended: "none" | "camera" | "mic" | "countdown" | "encoder" | "recorderStart"
  countdown,      \* the countdown task: "none" | "running" | "completed" | "cancelled"
  picker,         \* the source picker: "none" | "open"
  stops,          \* stop(_:) tasks: [1..StopSlots -> [reason, pc]]
  manual,         \* the Recordings pane's compress(): "none" | "load" | "compress"
  quitPc,         \* "none" | "alert": the "A recording is in progress" alert is up
  quitIntent,     \* the intent of the quit whose alert is up
  delayedQuit,    \* a quit(then:) task sleeping its 400 ms: "none" | intent
  needsRelease    \* enter(_:) just ran; releasePendingQuitIfSafe() is next

vars == <<activity, compression, pendingQuit, afterQuit, terminated, outstanding, badReply,
          accepted, encoder, encoderMisuse, recorder, recorderMisuse, devices, beginPc,
          countdown, picker, stops, manual, quitPc, quitIntent, delayedQuit, needsRelease>>

quitVars == <<pendingQuit, afterQuit, terminated, outstanding, badReply, accepted, quitPc, quitIntent, delayedQuit>>
sessionVars == <<encoder, encoderMisuse, recorder, recorderMisuse, devices>>
taskVars == <<beginPc, countdown, picker, stops, manual>>

NoStop == [reason |-> "none", pc |-> "none"]

TypeOK ==
  /\ activity \in {"idle", "choosing", "starting", "countdown", "recording", "finishing"} \cup Settled
  /\ compression \in {"none", "sizeLimit", "manual"}
  /\ pendingQuit \in {"none"} \cup Intents
  /\ afterQuit \in Intents
  /\ terminated \in BOOLEAN /\ outstanding \in BOOLEAN /\ badReply \in BOOLEAN
  /\ accepted \in {"none"} \cup Intents
  /\ encoder \in {"none", "open", "finished", "failed", "cancelled"}
  /\ encoderMisuse \in BOOLEAN /\ recorderMisuse \in BOOLEAN
  /\ recorder \in {"none", "started", "stopped"}
  /\ devices \in {"off", "on"}
  /\ beginPc \in {"none", "camera", "mic", "countdown", "encoder", "recorderStart"}
  /\ countdown \in {"none", "running", "completed", "cancelled"}
  /\ picker \in {"none", "open"}
  /\ stops \in [1..StopSlots -> [reason: {"none"} \cup StopReasons, pc: {"none", "start", "recorderStop", "encoderFinish", "fitLoad", "fitCompress"}]]
  /\ manual \in {"none", "load", "compress"}
  /\ quitPc \in {"none", "alert"}
  /\ quitIntent \in Intents
  /\ delayedQuit \in {"none"} \cup Intents
  /\ needsRelease \in BOOLEAN

Init ==
  /\ activity = "idle" /\ compression = "none"
  /\ pendingQuit = "none" /\ afterQuit = "exit" /\ terminated = FALSE /\ outstanding = FALSE
  /\ badReply = FALSE /\ accepted = "none"
  /\ encoder = "none" /\ encoderMisuse = FALSE /\ recorder = "none" /\ recorderMisuse = FALSE /\ devices = "off"
  /\ beginPc = "none" /\ countdown = "none" /\ picker = "none"
  /\ stops = [i \in 1..StopSlots |-> NoStop]
  /\ manual = "none" /\ quitPc = "none" /\ quitIntent = "exit" /\ delayedQuit = "none"
  /\ needsRelease = FALSE

Busy(a) == a \in {"choosing", "starting", "countdown", "recording", "finishing"}

\* Coordinator.quitRisk
RiskOf(act, comp) ==
  IF act = "recording" THEN "loses"
  ELSE IF act = "finishing" \/ comp /= "none" THEN "interrupts"
  ELSE "safe"

Risk == RiskOf(activity, compression)

\* Everything that runs on the main actor while the app is up, except the release step.
Live == ~terminated /\ ~needsRelease

\* begin(source:) resumed under an accepted quit: setup.abandon(); enter(.idle)
BeginQuits ==
  /\ devices' = "off" /\ encoder' = (IF encoder = "open" THEN "cancelled" ELSE encoder)
  /\ activity' = "idle" /\ beginPc' = "none" /\ needsRelease' = TRUE

\* Coordinator.willTerminate(): whatever begin() had brought up is released on the way out.
Exit == devices' = "off" /\ encoder' = (IF encoder = "open" THEN "cancelled" ELSE encoder)

----------------------------------------------------------------------------
(* releasePendingQuitIfSafe(), run right after the step that entered a phase *)

DoRelease ==
  /\ needsRelease
  /\ needsRelease' = FALSE
  /\ IF pendingQuit /= "none" /\ Risk = "safe"
       THEN /\ badReply' = (badReply \/ ~outstanding)
            /\ outstanding' = FALSE
            /\ pendingQuit' = "none"
            /\ IF activity = "failed"
                 THEN UNCHANGED <<afterQuit, terminated, accepted, devices, encoder>>
                 ELSE /\ afterQuit' = pendingQuit
                      /\ terminated' = TRUE
                      /\ accepted' = pendingQuit
                      /\ Exit
       ELSE UNCHANGED <<badReply, outstanding, pendingQuit, afterQuit, terminated, accepted, devices, encoder>>
  /\ UNCHANGED <<activity, compression, quitPc, quitIntent, delayedQuit, encoderMisuse, recorder, recorderMisuse, taskVars>>

----------------------------------------------------------------------------
(* Choosing a source: record(_:) and the picker's answer *)

\* `encoder` describes the current flow's encoder; a new flow starts without one.
Record ==
  /\ Live /\ ~Busy(activity) /\ picker = "none" /\ pendingQuit = "none"
  /\ activity' = "choosing" /\ picker' = "open" /\ needsRelease' = TRUE /\ encoder' = "none"
  /\ UNCHANGED <<compression, quitVars, encoderMisuse, recorder, recorderMisuse, devices, beginPc, countdown, stops, manual>>

\* begin(source:) up to its first await: geometry resolved and .starting entered, or the display is gone
PickerPicked ==
  /\ Live /\ picker = "open" /\ activity = "choosing"
  /\ picker' = "none" /\ needsRelease' = TRUE
  /\ \/ activity' = "starting" /\ beginPc' = "camera"
     \/ activity' = "failed" /\ beginPc' = "none"
  /\ UNCHANGED <<compression, quitVars, sessionVars, countdown, stops, manual>>

PickerCancelled ==
  /\ Live /\ picker = "open" /\ activity = "choosing"
  /\ picker' = "none" /\ activity' = "idle" /\ needsRelease' = TRUE
  /\ UNCHANGED <<compression, quitVars, sessionVars, beginPc, countdown, stops, manual>>

PickerUnavailable ==
  /\ Live /\ picker = "open" /\ activity = "choosing"
  /\ picker' = "none" /\ activity' = "failed" /\ needsRelease' = TRUE
  /\ UNCHANGED <<compression, quitVars, sessionVars, beginPc, countdown, stops, manual>>

----------------------------------------------------------------------------
(* begin(source:), one step per await *)

\* after `await Permissions.ensureCameraAccess()`: the camera is up
BeginCamera ==
  /\ Live /\ beginPc = "camera"
  /\ IF pendingQuit /= "none"
       THEN BeginQuits
       ELSE devices' = "on" /\ beginPc' = "mic" /\ UNCHANGED <<activity, encoder, needsRelease>>
  /\ UNCHANGED <<compression, quitVars, encoderMisuse, recorder, recorderMisuse, countdown, picker, stops, manual>>

\* after `await Permissions.ensureMicrophoneAccess()`: preview shown; a start delay enters the countdown
BeginMic ==
  /\ Live /\ beginPc = "mic"
  /\ IF pendingQuit /= "none"
       THEN BeginQuits /\ UNCHANGED countdown
       ELSE \/ /\ beginPc' = "countdown" /\ countdown' = "running" /\ activity' = "countdown" /\ needsRelease' = TRUE
               /\ UNCHANGED <<devices, encoder>>
            \/ /\ beginPc' = "encoder" /\ UNCHANGED <<countdown, activity, needsRelease, devices, encoder>>
  /\ UNCHANGED <<compression, quitVars, encoderMisuse, recorder, recorderMisuse, picker, stops, manual>>

CountdownFires ==
  /\ Live /\ countdown = "running" /\ countdown' = "completed"
  /\ UNCHANGED <<activity, compression, quitVars, sessionVars, beginPc, picker, stops, manual, needsRelease>>

\* cancelCountdown(), from the pill, the menu or the hotkey
CancelCountdown ==
  /\ Live /\ countdown = "running" /\ countdown' = "cancelled"
  /\ UNCHANGED <<activity, compression, quitVars, sessionVars, beginPc, picker, stops, manual, needsRelease>>

\* after `await countdown(...)`
BeginAfterCountdown ==
  /\ Live /\ beginPc = "countdown" /\ countdown \in {"completed", "cancelled"}
  /\ countdown' = "none"
  /\ IF countdown = "cancelled" \/ pendingQuit /= "none"
       THEN BeginQuits                                                   \* setup.abandon(); enter(.idle)
       ELSE activity' = "starting" /\ beginPc' = "encoder" /\ needsRelease' = TRUE /\ UNCHANGED <<devices, encoder>>
  /\ UNCHANGED <<compression, quitVars, encoderMisuse, recorder, recorderMisuse, picker, stops, manual>>

\* EncoderSetup.make, then `await recorder.start()` begins
BeginEncoder ==
  /\ Live /\ beginPc = "encoder"
  /\ \/ /\ encoder' = "open" /\ beginPc' = "recorderStart"
        /\ UNCHANGED <<activity, devices, needsRelease>>
     \/ /\ devices' = "off" /\ activity' = "failed" /\ beginPc' = "none" /\ needsRelease' = TRUE   \* make threw
        /\ UNCHANGED encoder
  /\ UNCHANGED <<compression, quitVars, encoderMisuse, recorder, recorderMisuse, countdown, picker, stops, manual>>

\* after `await recorder.start()`
BeginRecorderStart ==
  /\ Live /\ beginPc = "recorderStart"
  /\ beginPc' = "none" /\ needsRelease' = TRUE
  /\ \/ /\ pendingQuit = "none"
        /\ recorder' = "started" /\ activity' = "recording" /\ UNCHANGED <<encoder, devices>>
     \/ /\ pendingQuit /= "none"                                       \* started, then stopped again: isQuitting
        /\ recorder' = "stopped" /\ encoder' = "cancelled" /\ devices' = "off" /\ activity' = "idle"
     \/ /\ encoder' = "cancelled" /\ devices' = "off" /\ activity' = "failed" /\ UNCHANGED recorder   \* start threw
  /\ UNCHANGED <<compression, quitVars, encoderMisuse, recorderMisuse, countdown, picker, stops, manual>>

----------------------------------------------------------------------------
(* stop(_:) tasks: finish(), discard(), restart(), and abort(_:) from a capture failure *)

SpawnStop(reason) ==
  /\ activity = "recording"
  /\ \E i \in 1..StopSlots:
       /\ stops[i].pc = "none"
       /\ stops' = [stops EXCEPT ![i] = [reason |-> reason, pc |-> "start"]]

\* The hotkey works through the quit alert; the pill and menu do not.
Finish ==
  /\ Live /\ SpawnStop("finish")
  /\ UNCHANGED <<activity, compression, quitVars, sessionVars, beginPc, countdown, picker, manual, needsRelease>>

Discard ==
  /\ Live /\ quitPc = "none" /\ SpawnStop("discard")
  /\ UNCHANGED <<activity, compression, quitVars, sessionVars, beginPc, countdown, picker, manual, needsRelease>>

Restart ==
  /\ Live /\ quitPc = "none" /\ SpawnStop("restart")
  /\ UNCHANGED <<activity, compression, quitVars, sessionVars, beginPc, countdown, picker, manual, needsRelease>>

Abort ==
  /\ Live /\ SpawnStop("abort")
  /\ UNCHANGED <<activity, compression, quitVars, sessionVars, beginPc, countdown, picker, manual, needsRelease>>

\* stop(_:) up to `await recorder.stop()`: a task that finds the recording gone, or a
\* different recording than the one it was spawned for, does nothing
StopStart(i) ==
  /\ Live /\ stops[i].pc = "start"
  /\ IF activity /= "recording"
       THEN /\ stops' = [stops EXCEPT ![i] = NoStop]
            /\ UNCHANGED <<activity, encoder, needsRelease>>
       ELSE /\ stops' = [j \in 1..StopSlots |->
                          IF j = i THEN [stops[i] EXCEPT !.pc = "recorderStop"]
                          ELSE IF stops[j].pc = "start" THEN NoStop
                          ELSE stops[j]]
            /\ needsRelease' = TRUE
            /\ \/ stops[i].reason = "finish" /\ activity' = "finishing" /\ UNCHANGED encoder
               \/ stops[i].reason = "discard" /\ activity' = "finishing" /\ encoder' = "cancelled"   \* .stopping
               \/ stops[i].reason = "restart" /\ activity' = "starting" /\ encoder' = "cancelled"
               \/ stops[i].reason = "abort" /\ activity' = "finishing" /\ encoder' = "cancelled"     \* .stopping
  /\ UNCHANGED <<compression, quitVars, encoderMisuse, recorder, recorderMisuse, devices, beginPc, countdown, picker, manual>>

\* after `await recorder.stop()`: stopDevices(); then the reason's next step
StopRecorderStop(i) ==
  /\ Live /\ stops[i].pc = "recorderStop"
  /\ recorderMisuse' = (recorderMisuse \/ recorder /= "started")
  /\ recorder' = "stopped" /\ devices' = "off"
  /\ \/ /\ stops[i].reason = "finish"
        /\ stops' = [stops EXCEPT ![i].pc = "encoderFinish"]
        /\ UNCHANGED <<activity, beginPc, needsRelease>>
     \/ /\ stops[i].reason = "discard"                                 \* settle(.discarded)
        /\ stops' = [stops EXCEPT ![i] = NoStop]
        /\ activity' = "discarded" /\ needsRelease' = TRUE /\ UNCHANGED beginPc
     \/ /\ stops[i].reason = "abort"                                   \* settle(.failed)
        /\ stops' = [stops EXCEPT ![i] = NoStop]
        /\ activity' = "failed" /\ needsRelease' = TRUE /\ UNCHANGED beginPc
     \/ /\ stops[i].reason = "restart"                       \* begin(source:) again, up to its first await
        /\ stops' = [stops EXCEPT ![i] = NoStop]
        /\ needsRelease' = TRUE
        /\ \/ activity' = "starting" /\ beginPc' = "camera"
           \/ activity' = "failed" /\ beginPc' = "none"
  /\ UNCHANGED <<compression, quitVars, encoder, encoderMisuse, countdown, picker, manual>>

\* after `await encoder.finish(at:)`: rescan, size-limit check, and fit() up to its first await
StopEncoderFinish(i) ==
  /\ Live /\ stops[i].pc = "encoderFinish"
  /\ encoderMisuse' = (encoderMisuse \/ encoder /= "open")
  /\ needsRelease' = TRUE
  /\ \/ /\ encoder' = "failed" /\ activity' = "failed"                 \* finish threw
        /\ stops' = [stops EXCEPT ![i] = NoStop] /\ UNCHANGED compression
     \/ /\ encoder' = "finished" /\ activity' = "saved"                 \* under the limit, or no limit
        /\ stops' = [stops EXCEPT ![i] = NoStop] /\ UNCHANGED compression
     \/ /\ encoder' = "finished"                                        \* over the limit: fit()
        /\ IF compression /= "none"
             THEN /\ activity' = "saved"                                \* .skipped
                  /\ stops' = [stops EXCEPT ![i] = NoStop]
                  /\ UNCHANGED compression
             ELSE /\ activity' = "finishing"                            \* enter(.finishing(.fittingToLimit))
                  /\ compression' = "sizeLimit"                        \* run(_:) claims the slot before awaiting
                  /\ stops' = [stops EXCEPT ![i].pc = "fitLoad"]
  /\ UNCHANGED <<quitVars, recorder, recorderMisuse, devices, beginPc, countdown, picker, manual>>

\* after `await library.loadInfo(for:)`: the slot is held; an unreadable file is a note on the saved recording
FitLoad(i) ==
  /\ Live /\ stops[i].pc = "fitLoad"
  /\ \/ /\ stops' = [stops EXCEPT ![i].pc = "fitCompress"]
        /\ UNCHANGED <<activity, compression, needsRelease>>
     \/ /\ compression' = "none" /\ activity' = "saved"                 \* .notShrunk
        /\ stops' = [stops EXCEPT ![i] = NoStop] /\ needsRelease' = TRUE
  /\ UNCHANGED <<quitVars, sessionVars, beginPc, countdown, picker, manual>>

\* after `await Compressor.compress(...)`: the slot is freed; the recording is saved either way
FitCompress(i) ==
  /\ Live /\ stops[i].pc = "fitCompress"
  /\ compression' = "none" /\ stops' = [stops EXCEPT ![i] = NoStop] /\ needsRelease' = TRUE
  /\ activity' = "saved"                                                \* shrunk, still over, or .notShrunk
  /\ UNCHANGED <<quitVars, sessionVars, beginPc, countdown, picker, manual>>

----------------------------------------------------------------------------
(* compress(_:to:placement:) from the Recordings pane *)

CompressStart ==
  /\ Live /\ quitPc = "none" /\ manual = "none" /\ compression = "none" /\ pendingQuit = "none"
  /\ compression' = "manual" /\ manual' = "load"                        \* run(_:) claims the slot before awaiting
  /\ UNCHANGED <<activity, quitVars, sessionVars, beginPc, countdown, picker, stops, needsRelease>>

\* after `await library.loadInfo(for:)`: on to the Compressor, or done with an unreadable file
CompressLoad ==
  /\ Live /\ manual = "load"
  /\ \/ manual' = "compress" /\ UNCHANGED <<compression, needsRelease>>
     \/ compression' = "none" /\ manual' = "none" /\ needsRelease' = TRUE
  /\ UNCHANGED <<activity, quitVars, sessionVars, beginPc, countdown, picker, stops>>

CompressDone ==
  /\ Live /\ manual = "compress"
  /\ compression' = "none" /\ manual' = "none" /\ needsRelease' = TRUE
  /\ UNCHANGED <<activity, quitVars, sessionVars, beginPc, countdown, picker, stops>>

----------------------------------------------------------------------------
(* Quitting *)

\* handleQuitRequest() with its consumed intent. Atomic, unless it opens the alert.
HandleQuit(intent) ==
  /\ IF outstanding
       THEN /\ quitPc' = "none"                                         \* .terminateCancel
            /\ UNCHANGED <<pendingQuit, afterQuit, terminated, accepted, outstanding, quitIntent, devices, encoder, activity, picker, countdown, needsRelease>>
       ELSE \/ /\ Risk = "safe"                                         \* .terminateNow
               /\ terminated' = TRUE /\ afterQuit' = intent /\ accepted' = intent /\ quitPc' = "none"
               /\ Exit
               /\ UNCHANGED <<pendingQuit, outstanding, quitIntent, activity, picker, countdown, needsRelease>>
            \/ /\ Risk = "interrupts"                                   \* .terminateLater; abandonSetupForQuit()
               /\ pendingQuit' = intent /\ outstanding' = TRUE /\ quitPc' = "none"
               /\ IF activity = "choosing"
                    THEN activity' = "idle" /\ picker' = "none" /\ needsRelease' = TRUE
                    ELSE UNCHANGED <<activity, picker, needsRelease>>
               /\ countdown' = (IF countdown = "running" THEN "cancelled" ELSE countdown)
               /\ UNCHANGED <<afterQuit, terminated, accepted, quitIntent, devices, encoder>>
            \/ /\ Risk = "loses"                                        \* the alert opens
               /\ quitPc' = "alert" /\ quitIntent' = intent
               /\ UNCHANGED <<pendingQuit, afterQuit, terminated, accepted, outstanding, devices, encoder, activity, picker, countdown, needsRelease>>
  /\ UNCHANGED <<badReply, delayedQuit>>

\* ⌘Q, from the menu or the system
QuitNow ==
  /\ Live /\ quitPc = "none"
  /\ HandleQuit("exit")
  /\ UNCHANGED <<compression, encoderMisuse, recorder, recorderMisuse, beginPc, stops, manual>>

\* relaunch(): a quit(then: .relaunch) task goes to sleep
RequestRelaunch ==
  /\ Live /\ delayedQuit = "none"
  /\ delayedQuit' = "relaunch"
  /\ UNCHANGED <<activity, compression, pendingQuit, afterQuit, terminated, outstanding, badReply, accepted, quitPc, quitIntent, sessionVars, taskVars, needsRelease>>

\* the sleeping quit(then:) task wakes and terminates with its intent
DelayedQuitFires ==
  /\ Live /\ quitPc = "none" /\ delayedQuit /= "none"
  /\ HandleQuit(delayedQuit) /\ delayedQuit' = "none"
  /\ UNCHANGED <<compression, encoderMisuse, recorder, recorderMisuse, beginPc, stops, manual>>

AlertCancel ==
  /\ Live /\ quitPc = "alert"
  /\ quitPc' = "none"
  /\ UNCHANGED <<activity, compression, pendingQuit, afterQuit, terminated, outstanding, badReply, accepted, quitIntent, delayedQuit, sessionVars, taskVars, needsRelease>>

\* "Finish and Quit" or "Discard and Quit". The alert ran a modal loop; the recording may be gone.
AlertChoose(reason) ==
  /\ Live /\ quitPc = "alert"
  /\ IF activity /= "recording"
       THEN /\ HandleQuit(quitIntent)                                   \* return handleQuitRequest()
            /\ UNCHANGED stops
       ELSE /\ pendingQuit' = quitIntent /\ outstanding' = TRUE /\ quitPc' = "none"
            /\ SpawnStop(reason)
            /\ UNCHANGED <<afterQuit, terminated, accepted, badReply, quitIntent, delayedQuit, devices, encoder, activity, picker, countdown, needsRelease>>
  /\ UNCHANGED <<compression, encoderMisuse, recorder, recorderMisuse, beginPc, manual>>

----------------------------------------------------------------------------
(* The settled message goes away: its timer, the ✕, or Show *)

DismissSettled ==
  /\ Live /\ quitPc = "none" /\ activity \in Settled
  /\ activity' = "idle" /\ needsRelease' = TRUE
  /\ UNCHANGED <<compression, quitVars, sessionVars, taskVars>>

----------------------------------------------------------------------------

UserSteps ==
  \/ Record \/ PickerPicked \/ PickerCancelled \/ PickerUnavailable
  \/ CancelCountdown \/ Finish \/ Discard \/ Restart \/ Abort
  \/ CompressStart \/ QuitNow \/ RequestRelaunch \/ AlertCancel
  \/ AlertChoose("finish") \/ AlertChoose("discard") \/ DismissSettled

TaskSteps ==
  \/ DoRelease
  \/ BeginCamera \/ BeginMic \/ CountdownFires \/ BeginAfterCountdown \/ BeginEncoder \/ BeginRecorderStart
  \/ \E i \in 1..StopSlots: StopStart(i) \/ StopRecorderStop(i) \/ StopEncoderFinish(i) \/ FitLoad(i) \/ FitCompress(i)
  \/ CompressLoad \/ CompressDone \/ DelayedQuitFires

Next == UserSteps \/ TaskSteps

\* Tasks and timers always get to run; people need not act. Strong fairness, because
\* DoRelease disables every other step for one state and must not count as starving them.
Fairness ==
  /\ WF_vars(DoRelease)
  /\ SF_vars(BeginCamera) /\ SF_vars(BeginMic) /\ SF_vars(CountdownFires) /\ SF_vars(BeginAfterCountdown)
  /\ SF_vars(BeginEncoder) /\ SF_vars(BeginRecorderStart)
  /\ \A i \in 1..StopSlots:
       SF_vars(StopStart(i)) /\ SF_vars(StopRecorderStop(i)) /\ SF_vars(StopEncoderFinish(i))
       /\ SF_vars(FitLoad(i)) /\ SF_vars(FitCompress(i))
  /\ SF_vars(CompressLoad) /\ SF_vars(CompressDone) /\ SF_vars(DelayedQuitFires)

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* What the design promises *)

\* reply(toApplicationShouldTerminate:) only ever answers a .terminateLater, once.
ReplyProtocol == ~badReply

\* The process never ends while a file is half-written or a recording would be lost.
TerminateSafe == terminated => activity \notin {"recording", "finishing"} /\ compression = "none"

\* A quit does what the one who asked for it meant: exit, or relaunch.
IntentKept == terminated => afterQuit = accepted

\* One Compressor at a time, whoever asked.
OneCompressor ==
  /\ ~(manual = "compress" /\ \E i \in 1..StopSlots: stops[i].pc = "fitCompress")
  /\ Cardinality({i \in 1..StopSlots : stops[i].pc = "fitCompress"}) <= 1

\* A recording the encoder finished is on disk; the pill must not call it failed.
EncodedNeverFailed == ~(encoder = "finished" /\ activity = "failed")

\* No encoder is left open once the flow is over, and the encoder/recorder contracts are kept.
EncoderClosedAtRest == activity \in Rest => encoder /= "open"
ContractsKept == ~encoderMisuse /\ ~recorderMisuse

\* Devices are off whenever the flow is at rest.
DevicesOffAtRest == activity \in Rest => devices = "off"

\* Once a quit is accepted and waiting, a pick or a countdown ends on the spot...
NoNewWorkWhileQuitting == pendingQuit /= "none" => activity /= "choosing" /\ countdown /= "running"

\* ...and no recording starts under it, however far a setup had come.
NoRecordingStartsWhileQuitting == [][activity /= "recording" /\ activity' = "recording" => pendingQuit = "none"]_vars

\* Nothing is left running or half-made when the process exits.
NoLeakAtQuit == terminated => encoder /= "open" /\ devices = "off"

\* Every quit that was accepted is eventually answered, and every finish settles.
QuitAnswered == [](pendingQuit /= "none" => <>(pendingQuit = "none"))
FinishSettles == [](activity = "finishing" => <>(activity \in Settled))

=============================================================================
