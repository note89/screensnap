#!/usr/bin/env bash
# Exercise archive ownership, retention and safe failure in temporary folders.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -o "$WORK/checks" \
    "$ROOT/Sources/Screensnap/FilenameTemplate.swift" \
    "$ROOT/Sources/Screensnap/Recordings/OriginalsArchive.swift" \
    "$ROOT/Tests/OriginalsArchiveChecks/main.swift"
"$WORK/checks" "$WORK"
