#!/usr/bin/env bash
# Native AVFoundation regression checks. Requires only the macOS Command Line Tools.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -parse-as-library -o "$WORK/checks" \
    "$ROOT/Sources/Screensnap/Geometry.swift" \
    "$ROOT/Sources/Screensnap/Output.swift" \
    "$ROOT/Sources/Screensnap/GIFStream.swift" \
    "$ROOT/Sources/Screensnap/FrameDiff.swift" \
    "$ROOT/Sources/Screensnap/FilenameTemplate.swift" \
    "$ROOT/Sources/Screensnap/Recordings/Recording.swift" \
    "$ROOT/Sources/Screensnap/Recordings/CompressionPlan.swift" \
    "$ROOT/Sources/Screensnap/Recordings/OriginalsArchive.swift" \
    "$ROOT/Sources/Screensnap/Recordings/Compressor.swift" \
    "$ROOT/Sources/Screensnap/Recordings/HEVCTranscoder.swift" \
    "$ROOT/Tests/CompressionChecks/Checks.swift"
"$WORK/checks" "$WORK"
