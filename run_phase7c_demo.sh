#!/usr/bin/env bash
set -euo pipefail

ROOT="/run/media/sourabh/SANDISK-2TB/antigravity/ABM"
JULIA_DIR="$ROOT/packages/GodotBridge"
GODOT_DIR="$ROOT/godot"

JULIA_BIN="${JULIA_BIN:-$(command -v julia || true)}"
if [[ -z "$JULIA_BIN" ]]; then
  JULIA_BIN="$HOME/.juliaup/bin/julia"
fi
if [[ ! -x "$JULIA_BIN" ]]; then
  echo "Julia executable not found: $JULIA_BIN" >&2
  exit 127
fi

GODOT_BIN="${GODOT_BIN:-$(command -v godot || true)}"
if [[ -z "$GODOT_BIN" ]]; then
  GODOT_BIN="$HOME/.local/bin/godot"
fi
if [[ ! -x "$GODOT_BIN" ]]; then
  echo "Godot executable not found: $GODOT_BIN" >&2
  exit 127
fi

echo "Starting Phase 7C demo..."
cd "$JULIA_DIR"
("$JULIA_BIN" --project=. test/fixture_server_phase7c.jl) &
JULIA_PID=$!

sleep 1

cd "$GODOT_DIR"
"$GODOT_BIN" --path . &
GODOT_PID=$!

cleanup() {
  kill "$JULIA_PID" 2>/dev/null || true
  kill "$GODOT_PID" 2>/dev/null || true
  exit 0
}

trap cleanup INT TERM

wait "$GODOT_PID"
kill "$JULIA_PID" 2>/dev/null || true
