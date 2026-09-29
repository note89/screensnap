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
    cp "$ROOT/Resources/gifski-LICENSE.txt" "$APP_DIR/Contents/Resources/gifski-LICENSE.txt"
fi

# Sign with the Developer ID when this Mac has it, so local builds and releases
# share one code identity and TCC grants survive both rebuilds and updates. The
# self-signed dev certificates are fallbacks for machines without the Developer
# ID ("GifRecorder Dev" is the one the project used before the rename). CI has
# none of them and signs ad hoc. Hardened runtime everywhere, so a missing
# entitlement shows up in development rather than only in a release.
DEVELOPER_ID="${SCREENSNAP_SIGN_IDENTITY:-Developer ID Application: Nils Olof Tson Eriksson (43BT9GR95A)}"
ENTITLEMENTS="$ROOT/Resources/Screensnap.entitlements"

has_identity() {
    # No `-v`: a self-signed cert is not trusted by the system, so find-identity
    # marks it invalid, yet codesign signs with it without complaint.
    security find-identity -p codesigning 2>&1 | grep -qF "\"$1\""
}

sign_with() {
    local gifski="$APP_DIR/Contents/Resources/gifski"
    if [[ -f "$gifski" ]]; then
        codesign --force --options runtime --timestamp=none --sign "$1" "$gifski"
    fi
    codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" --sign "$1" "$APP_DIR"
    echo "→ Signed as '$1'"
}

signed=no
for identity in "$DEVELOPER_ID" "Screensnap Dev" "GifRecorder Dev"; do
    if has_identity "$identity"; then
        sign_with "$identity"
        signed=yes
        break
    fi
done
[[ $signed == yes ]] || sign_with -

echo "✓ Built $APP_DIR"
echo
echo "First run: open the app and start a recording from the menu bar icon."
echo "macOS will ask for Screen Recording permission. Grant it, then relaunch."
echo
echo "  open \"$APP_DIR\""
