#!/usr/bin/env bash
# Build a Developer ID signed, notarized and stapled Screensnap.app, zip it, and
# (with --publish) tag the release and attach the zip on GitHub.
#
#   ./Scripts/release.sh 0.3.0            # build, sign, notarize, zip; publish nothing
#   ./Scripts/release.sh 0.3.0 --publish  # the same, then tag v0.3.0, upload, and
#                                         # bump the cask in note89/homebrew-tap
#
# Runs on the Mac that holds the Developer ID key; the key never leaves its keychain.
# Needs the `devid-notary` notarytool keychain profile. The in-app updater only
# installs builds signed by this team, so every release has to go through here.

set -euo pipefail

TEAM_ID="43BT9GR95A"
IDENTITY="${SCREENSNAP_SIGN_IDENTITY:-Developer ID Application: Nils Olof Tson Eriksson ($TEAM_ID)}"
NOTARY_PROFILE="${SCREENSNAP_NOTARY_PROFILE:-devid-notary}"
TAP_REPO="note89/homebrew-tap"
CASK_PATH="Casks/screensnap.rb"

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
    # Checked before anything is published, so a release never goes out with no way to bump its cask.
    gh api "repos/$TAP_REPO/contents/$CASK_PATH" --silent 2>/dev/null || die "cannot read $CASK_PATH in $TAP_REPO"
fi

step "Building gifski"
Scripts/build-gifski.sh

step "Building"
SCREENSNAP_SIGN_IDENTITY="$IDENTITY" Scripts/build-app.sh release
[[ -x "$APP/Contents/Resources/gifski" ]] || die "gifski is missing from the bundle; GIF · best would fall back to the fast encoder"

step "Stamping version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"

# Stamping changed Info.plist, so sign again, this time with a secure timestamp,
# which notarization requires. Nested code first, the bundle last.
step "Signing with $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/gifski"
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

# The release is public from here on; if this step fails, the message says how to finish by hand.
step "Bumping the Homebrew cask in $TAP_REPO"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
TAP_DIR="$(mktemp -d)"
trap 'rm -rf "$TAP_DIR"' EXIT
tap_die() { die "$* — set version \"$VERSION\" and sha256 \"$SHA\" in $TAP_REPO/$CASK_PATH by hand"; }
gh repo clone "$TAP_REPO" "$TAP_DIR" -- --quiet --depth 1 || tap_die "could not clone $TAP_REPO"
sed -i '' -E \
    -e "s/^  version \"[^\"]*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \"[^\"]*\"/  sha256 \"$SHA\"/" \
    "$TAP_DIR/$CASK_PATH"
grep -qF "version \"$VERSION\"" "$TAP_DIR/$CASK_PATH" && grep -qF "sha256 \"$SHA\"" "$TAP_DIR/$CASK_PATH" \
    || tap_die "the cask's version and sha256 lines did not match the expected layout"
if git -C "$TAP_DIR" diff --quiet; then
    echo "cask already at $VERSION"
else
    git -C "$TAP_DIR" commit --quiet --all --message "screensnap $VERSION"
    git -C "$TAP_DIR" push --quiet origin HEAD || tap_die "could not push to $TAP_REPO"
fi
echo "✓ note89/tap/screensnap is at $VERSION"
