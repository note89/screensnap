#!/usr/bin/env bash
# Build the SwiftPM executable, then wrap it in a .app bundle so macOS TCC
# can identify it by a stable path. Run from the project root.
#
#   ./Scripts/build-app.sh           # Debug build into ./build/GifRecorder.app
#   ./Scripts/build-app.sh release   # Release build

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/.build/$([[ $CONFIG == release ]] && echo release || echo debug)"
APP_DIR="$ROOT/build/GifRecorder.app"

echo "→ swift build (-c $CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"

echo "→ Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/GifRecorder" "$APP_DIR/Contents/MacOS/GifRecorder"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Regenerate the icon from source whenever the draw script changes.
if [[ "$ROOT/Scripts/make-icon.swift" -nt "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "→ Regenerating AppIcon.icns"
    swift "$ROOT/Scripts/make-icon.swift"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

if [[ -f "$ROOT/Resources/gifski" ]]; then
    cp "$ROOT/Resources/gifski" "$APP_DIR/Contents/Resources/gifski"
    chmod +x "$APP_DIR/Contents/Resources/gifski"
fi

# Try the named cert first if it's trusted; otherwise fall back to ad-hoc.
# (Self-signed certs need a user-trust setting to be valid for code signing,
# and we can't add that without prompting. TODO: revisit with `security
# add-trusted-cert` once we can stomach the prompt.)
SIGN_IDENTITY="GifRecorder Dev"
if security find-identity -v -p codesigning 2>&1 | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" 2>&1 | tail -3 || true
else
    codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true
fi

echo "✓ Built $APP_DIR"
echo
echo "First run: open the app, click Record. macOS will prompt for Screen"
echo "Recording permission. Grant it, then quit and re-launch."
echo
echo "  open \"$APP_DIR\""
