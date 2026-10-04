#!/usr/bin/env bash
# Model-check Specs/Coordinator.tla with TLC: every interleaving of the recording
# flow, the quit protocol and the compression slot that the main actor allows,
# against the properties at the end of the spec. Needs Java 11 or newer; the TLA+
# tools jar is fetched into .build/ the first time.
#
#   ./Scripts/check-model.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAR="${TLA2TOOLS_JAR:-$ROOT/.build/tla2tools.jar}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v java >/dev/null || { echo "check-model: java is not installed" >&2; exit 1; }
if [[ ! -f $JAR ]]; then
    mkdir -p "$(dirname "$JAR")"
    echo "→ Fetching tla2tools.jar"
    curl -sSL -o "$JAR" https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
fi

# TLC writes its state files next to the spec; a scratch copy keeps Specs/ clean.
cp "$ROOT/Specs/Coordinator.tla" "$ROOT/Specs/Coordinator.cfg" "$WORK/"
cd "$WORK"
java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -deadlock -workers auto -cleanup Coordinator.tla
