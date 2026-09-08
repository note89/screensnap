#!/usr/bin/env bash
# Build the SwiftPM executable, then wrap it in a .app bundle so macOS TCC
# can identify it by a stable path. Run from the project root.
#
#   ./Scripts/build-app.sh           # Debug build into ./build/Screensnap.app
#   ./Scripts/build-app.sh release   # Release build

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/.build/$([[ $CONFIG == release ]] && echo release || echo debug)"
APP_DIR="$ROOT/build/Screensnap.app"

echo "→ swift build (-c $CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"

echo "→ Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/Screensnap" "$APP_DIR/Contents/MacOS/Screensnap"
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

# Sign with the local dev certificate when present so TCC permissions survive
# rebuilds. "GifRecorder Dev" is the certificate the project used before the
# rename; keep honouring it so existing installs do not lose Screen Recording.
# No `-v`: the self-signed cert is not trusted by the system, so find-identity
# marks it invalid, yet codesign signs with it without complaint.
sign_with() {
    security find-identity -p codesigning 2>&1 | grep -q "\"$1\"" || return 1
    codesign --force --deep --sign "$1" "$APP_DIR" 2>&1 | tail -3 || true
    echo "→ Signed as '$1'"
}
sign_with "Screensnap Dev" || sign_with "GifRecorder Dev" || codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "✓ Built $APP_DIR"
echo
echo "First run: open the app and start a recording from the menu bar icon."
echo "macOS will ask for Screen Recording permission. Grant it, then relaunch."
echo
echo "  open \"$APP_DIR\""
