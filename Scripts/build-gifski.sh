#!/usr/bin/env bash
# Build the gifski command-line encoder into Resources/gifski, where build-app.sh
# bundles it. A pinned version with its default features only: the `video`
# feature is off, so there is no ffmpeg and the binary links nothing but system
# libraries. Run from anywhere; release.sh runs it before every release.
#
#   ./Scripts/build-gifski.sh
#
# gifski is AGPL-3.0 and Screensnap runs it as a separate program. The bundle
# carries its licence (Resources/gifski-LICENSE.txt, from the same tag) and the
# README links the source of this exact version. Bump both together.

set -euo pipefail

GIFSKI_VERSION="1.34.0"
# Package.swift's platform; a newer SDK would otherwise stamp its own version in.
MACOS_TARGET="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/gifski"
WORK="$ROOT/.build/gifski-$GIFSKI_VERSION"

if [[ -x $OUT && "$("$OUT" --version 2>/dev/null)" == "gifski $GIFSKI_VERSION" ]]; then
    echo "✓ gifski $GIFSKI_VERSION already in Resources/"
    exit 0
fi
command -v cargo >/dev/null || { echo "build-gifski: cargo is not installed — see https://rustup.rs" >&2; exit 1; }

echo "→ cargo install gifski $GIFSKI_VERSION"
MACOSX_DEPLOYMENT_TARGET="$MACOS_TARGET" cargo install gifski --version "$GIFSKI_VERSION" --locked --root "$WORK"
cp "$WORK/bin/gifski" "$OUT"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
