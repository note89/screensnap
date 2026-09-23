#!/usr/bin/env bash
# Compile and run the GIF stream checks (Tests/GIFStreamChecks). They need only the
# Command Line Tools, unlike `swift test`, which needs Xcode for XCTest.
#
#   ./Scripts/check-gif-stream.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT

swiftc -o "$WORK/checks" \
    "$ROOT/Sources/Screensnap/GIFStream.swift" \
    "$ROOT/Sources/Screensnap/FrameDiff.swift" \
    "$ROOT/Sources/Screensnap/Output.swift" \
    "$ROOT/Tests/GIFStreamChecks/main.swift"
"$WORK/checks" "$WORK"
