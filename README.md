# Screensnap

A lightweight macOS screen recorder that saves to **GIF** or **MP4**. No Electron, no subscriptions — a native [Swift](https://www.swift.org)/[AppKit](https://developer.apple.com/documentation/appkit) app that lives in your menu bar.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)

## Features

- **Three capture modes** — full display (the default), drag a region, or pick a window (via [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit))
- **GIF or MP4** output (H.264 via [AVFoundation](https://developer.apple.com/documentation/avfoundation))
- **gifski support** — optional high-quality GIF encoding via [gifski](https://github.com/imageoptim/gifski)
- **3-second countdown** — on by default, on the display being recorded; cancel with the button, Escape, or `⌘⇧.`
- **Copy to clipboard** — the file reference for Finder, Mail and chat apps, plus the raw bytes for anything that pastes media inline
- **Menu bar item** — start/stop/cancel from the menu bar; pulsing red dot while recording, amber while saving
- **Global hotkeys** — `⌘⇧6` starts a recording from anywhere; `⌘⇧.` cancels the countdown or finishes the recording
- No microphone, no network, no telemetry

## Requirements

- macOS 13 Ventura or later
- Xcode command-line tools (`xcode-select --install`)
- Swift 5.9+ (bundled with the CLI tools above)

## Quick start

```bash
git clone https://github.com/note89/screensnap.git
cd screensnap

# One-time: create a self-signed cert so Screen Recording permission
# survives every future rebuild (see "Code signing" below).
./Scripts/setup-signing.sh

# Build and assemble the .app bundle.
./Scripts/build-app.sh

# Launch.
open build/GifRecorder.app
```

On first launch macOS will ask for **Screen Recording** permission. Grant it in System Settings → Privacy & Security → Screen & System Audio Recording. macOS only applies the grant to a fresh launch, so the app offers a **Relaunch** button once it sees the toggle flip.

## Code signing

macOS binds Screen Recording permission to the app's code-signing identity. Without a stable identity, every rebuild produces a "new" app and the OS forgets the permission — you'd have to re-grant it each time.

`Scripts/setup-signing.sh` creates a **self-signed certificate** in your login keychain called `GifRecorder Dev`. The build script signs every `.app` with it automatically.

```bash
# Run once, ever:
./Scripts/setup-signing.sh

# Verify it was created:
security find-certificate -c "GifRecorder Dev"

# To remove it later:
security delete-certificate -c "GifRecorder Dev"
```

The certificate stays in your local keychain — it is never committed to the repository.

> **First build after setup:** you'll need to grant Screen Recording one more time because the identity changed from ad-hoc to the new cert. After that, rebuilds are silent.

### How it works

The script uses macOS's bundled LibreSSL (`/usr/bin/openssl`) to generate a 2048-bit RSA key and a self-signed X.509 certificate with the `codeSigning` extended key usage. It imports the key+cert pair into your login keychain and pre-authorises `/usr/bin/codesign` so rebuilds never prompt for a password.

## Building for release

```bash
./Scripts/build-app.sh release
```

The release binary is stripped and optimised. The `.app` lands at `build/GifRecorder.app` either way.

## gifski (optional, better GIF quality)

[gifski](https://gif.ski) ([GitHub](https://github.com/imageoptim/gifski)) produces significantly smaller and higher-quality GIFs than the built-in ImageIO encoder. Install it with Homebrew:

```bash
brew install gifski
```

Then enable it in the app's settings panel. The app locates the binary automatically from common Homebrew paths (`/opt/homebrew/bin/gifski`, `/usr/local/bin/gifski`).

gifski takes every frame as a separate command-line argument, and macOS caps the command line at 1 MiB. That works out to roughly 40,000 frames — about 45 minutes at 15 fps. Past that the app refuses up front with an explanation rather than losing the recording; for very long captures use the built-in encoder or MP4. Encoding a long gifski recording can take a while: the HUD switches to **Saving…** and the menu bar dot turns amber until the file is on disk.

You can also drop a `gifski` binary directly into `Resources/` to bundle it inside the app — useful for distributing to machines that don't have Homebrew.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Capture mode | Full screen | Full screen / Region / Window |
| Output format | GIF | GIF or MP4 (no audio track) |
| Framerate | 15 fps | 1–60 fps |
| Downsample | 1× | 1–4×; divides the recorded pixel dimensions. Worth raising for full-screen Retina GIFs |
| Countdown | 3 s | Overlay on the recorded display; cancel with the button, Escape, or `⌘⇧.`. Set to 0 to skip |
| Capture cursor | On | |
| Use gifski | Off | Requires gifski on PATH or in Resources/; see the frame ceiling above |
| gifski quality | 80 | 20–100. No UI yet — set `recording.gifskiQuality` in UserDefaults |
| Copy to clipboard | On | Writes `public.file-url` + the legacy filenames flavor, plus raw bytes for files under 64 MB |
| Reveal in Finder | Off | |
| Show notification | On | Brief toast after save. No UI yet — set `interface.showNotification` |

Files are written to `~/Documents/gif-recordings/` with an ISO-style timestamped name;
a `-2`, `-3` suffix is added if a name is already taken. The folder and the name
format have no UI yet either (`persist.saveFolder`, `interface.filenameFormat`).

## Keyboard shortcuts

| Keys | Does |
|---|---|
| `⌘⇧6` | Start a recording in the default capture mode, from any app |
| `⌘⇧.` | Cancel the countdown, or finish and save the recording |
| `Esc` | Cancel region selection, or the countdown when its panel has focus |
| `Return` | Record (launcher) / Finish (HUD) |

If another app already owns one of the global combinations the launcher says so
under the Record button instead of advertising a shortcut that does nothing.
On a Touch Bar Mac, `⌘⇧6` is also the system's "screenshot of the Touch Bar"
shortcut; turn that off under System Settings → Keyboard → Keyboard Shortcuts →
Screenshots if both fire.

Quitting during a recording asks whether to finish and save or discard it; quitting
while a recording is being saved waits for the file to land first.

## Project layout

```
Sources/GifRecorder/
  AppDelegate.swift       Main coordinator; recording session lifecycle
  ScreenRecorder.swift    SCStream wrapper; frame throttling
  Encoders.swift          GIF (ImageIO + gifski) and MP4 encoders
  RegionSelector.swift    Drag-to-select overlay (NSPanel, all displays)
  ControlBar.swift        Floating HUD shown while recording
  Clipboard.swift         Pasteboard publishing for finished recordings
  CountdownOverlay.swift  Pre-recording countdown panel
  StatusItem.swift        Menu bar item and menu
  MainView.swift          Settings / launcher window
  GlobalHotkey.swift      Carbon RegisterEventHotKey wrapper
  Settings.swift          UserDefaults-backed preferences
  SourcePicker.swift      Display / window picker sheet
  Toast.swift             Brief notification banner
  Permissions.swift       TCC screen-recording helpers
  main.swift              Entry point; crash handlers

Resources/
  Info.plist              App bundle metadata
  AppIcon.icns            App icon

Scripts/
  build-app.sh            Build + bundle + sign
  setup-signing.sh        One-time self-signed cert creation
  make-icon.swift         Icon generator (Swift script)
```

## Sending to another Mac

Build once, then zip the `.app`:

```bash
./Scripts/build-app.sh release
cd build
zip -r Screensnap.zip GifRecorder.app
```

AirDrop or copy `Screensnap.zip` to the other Mac. There, unzip it, then **right-click → Open** (not double-click) to bypass Gatekeeper's check on unsigned apps. Grant Screen Recording permission in System Settings when prompted.

## License

MIT
