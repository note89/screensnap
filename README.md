# Screensnap

A lightweight macOS screen recorder that saves to **GIF** or **MP4**. No Electron, no subscriptions — a native [Swift](https://www.swift.org)/[AppKit](https://developer.apple.com/documentation/appkit) app that lives in your menu bar.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)

## Features

- **Three capture modes** — drag a region, full display, or pick a window (via [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit))
- **GIF or MP4** output (H.264 via [AVFoundation](https://developer.apple.com/documentation/avfoundation))
- **gifski support** — optional high-quality GIF encoding via [gifski](https://github.com/imageoptim/gifski)
- **Countdown overlay** — configurable start delay with a visible countdown and Cancel support
- **Copy to clipboard** — paste directly into Slack, Discord, iMessage, or any browser
- **Menu bar item** — start/stop/cancel from the menu bar; pulsing red dot while recording
- **Global hotkey** — `⌘⇧.` stops the current recording from anywhere
- No microphone, no network, no telemetry

## Requirements

- macOS 13 Ventura or later
- Xcode command-line tools (`xcode-select --install`)
- Swift 5.9+ (bundled with the CLI tools above)

## Quick start

```bash
git clone https://github.com/YOUR_USERNAME/screensnap.git
cd screensnap

# One-time: create a self-signed cert so Screen Recording permission
# survives every future rebuild (see "Code signing" below).
./Scripts/setup-signing.sh

# Build and assemble the .app bundle.
./Scripts/build-app.sh

# Launch.
open build/GifRecorder.app
```

On first launch macOS will ask for **Screen Recording** permission. Grant it in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app.

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

You can also drop a `gifski` binary directly into `Resources/` to bundle it inside the app — useful for distributing to machines that don't have Homebrew.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Capture mode | Region | Region / Full screen / Window |
| Output format | GIF | GIF or MP4 |
| Framerate | 15 fps | 1–60 fps |
| Downsample | 1× | 1–4× (reduces pixel dimensions) |
| Start delay | 0 s | Shows a countdown overlay; Escape cancels |
| Capture cursor | On | |
| Use gifski | Off | Requires gifski on PATH or in Resources/ |
| gifski quality | 80 | 20–100 |
| Copy to clipboard | On | Writes file URL + raw GIF/MP4 bytes |
| Reveal in Finder | Off | |
| Show notification | On | Brief toast after save |

## Project layout

```
Sources/GifRecorder/
  AppDelegate.swift       Main coordinator; recording session lifecycle
  ScreenRecorder.swift    SCStream wrapper; frame throttling
  Encoders.swift          GIF (ImageIO + gifski) and MP4 encoders
  RegionSelector.swift    Drag-to-select overlay (NSPanel, all displays)
  ControlBar.swift        Floating HUD shown while recording
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
