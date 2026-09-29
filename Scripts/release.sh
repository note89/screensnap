#!/usr/bin/env bash
# Build a Developer ID signed, notarized and stapled Screensnap.app, zip it, and
# (with --publish) tag the release and attach the zip on GitHub.
#
#   ./Scripts/release.sh 0.3.0            # build, sign, notarize, zip; publish nothing
#   ./Scripts/release.sh 0.3.0 --publish  # the same, then tag v0.3.0 and upload
#
# Runs on the Mac that holds the Developer ID key; the key never leaves its keychain.
# Needs the `devid-notary` notarytool keychain profile. The in-app updater only
# installs builds signed by this team, so every release has to go through here.

set -euo pipefail

TEAM_ID="43BT9GR95A"
IDENTITY="${SCREENSNAP_SIGN_IDENTITY:-Developer ID Application: Nils Olof Tson Eriksson ($TEAM_ID)}"
NOTARY_PROFILE="${SCREENSNAP_NOTARY_PROFILE:-devid-notary}"

VERSION="${1:-}"
PUBLISH="${2:-}"
[[ $VERSION =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "usage: $0 VERSION [--publish]   (VERSION like 0.3.0)" >&2; exit 2; }
[[ -z $PUBLISH || $PUBLISH == --publish ]] || { echo "unknown option: $PUBLISH" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Screensnap.app"
ZIP="$ROOT/build/Screensnap-$VERSION.zip"
TAG="v$VERSION"
cd "$ROOT"

step() { printf '\n==> %s\n' "$*"; }
die() { echo "release: $*" >&2; exit 1; }

security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" || die "no valid signing identity '$IDENTITY' in the keychain"
if [[ $PUBLISH == --publish ]]; then
    [[ -z $(git status --porcelain) ]] || die "working tree is not clean; commit first so the tag matches the build"
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
    command -v gh >/dev/null || die "gh is not installed"
fi

step "Building"
SCREENSNAP_SIGN_IDENTITY="$IDENTITY" Scripts/build-app.sh release

step "Stamping version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"

# Stamping changed Info.plist, so sign again, this time with a secure timestamp,
# which notarization requires. Nested code first, the bundle last.
step "Signing with $IDENTITY"
if [[ -f "$APP/Contents/Resources/gifski" ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/gifski"
fi
codesign --force --options runtime --timestamp --entitlements Resources/Screensnap.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

step "Notarizing (usually 1–5 minutes)"
SUBMISSION="$ROOT/build/Screensnap-$VERSION-notarize.zip"
ditto -c -k --keepParent "$APP" "$SUBMISSION"
RESULT="$(mktemp)"
xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$RESULT" || true
rm -f "$SUBMISSION"
ID="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)"
[[ -n $ID ]] || { cat "$RESULT" >&2; die "notarytool submit failed"; }
echo "submission $ID: $STATUS"
if [[ $STATUS != Accepted ]]; then
    xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization $STATUS; the log above names each rejected file"
fi

step "Stapling and checking Gatekeeper"
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"

step "Zipping"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $ZIP"

if [[ $PUBLISH != --publish ]]; then
    echo
    echo "Not published. To release it: $0 $VERSION --publish"
    exit 0
fi

step "Publishing $TAG"
git tag -a "$TAG" -m "Screensnap $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "Screensnap $VERSION" --generate-notes --verify-tag
