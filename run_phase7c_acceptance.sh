#!/usr/bin/env bash
set -euo pipefail

ROOT="/run/media/sourabh/SANDISK-2TB/antigravity/ABM"
GODOT_DIR="$ROOT/godot"
JULIA_PROJECT="$ROOT/packages/GodotBridge"
FIXTURE="$JULIA_PROJECT/test/fixture_server_phase7c.jl"
JULIA_BIN="${JULIA_BIN:-$(command -v julia || true)}"
GODOT_BIN="${GODOT_BIN:-$(command -v godot || true)}"

[[ -x "$JULIA_BIN" ]] || { echo "Julia not found" >&2; exit 127; }
[[ -x "$GODOT_BIN" ]] || { echo "Godot not found" >&2; exit 127; }

if (echo >/dev/tcp/127.0.0.1/9107) 2>/dev/null; then
  echo "Port 9107 is already in use; stop the existing fixture before acceptance."
  exit 2
fi

julia_pid=""
godot_pid=""
cleanup() {
  [[ -n "$godot_pid" ]] && kill "$godot_pid" 2>/dev/null || true
  [[ -n "$julia_pid" ]] && kill "$julia_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

"$JULIA_BIN" --project="$JULIA_PROJECT" "$FIXTURE" >/tmp/phase7c_acceptance_julia.log 2>&1 &
julia_pid=$!

for _ in $(seq 1 100); do
  if (echo >/dev/tcp/127.0.0.1/9107) 2>/dev/null; then
    break
  fi
  kill -0 "$julia_pid" 2>/dev/null || { cat /tmp/phase7c_acceptance_julia.log; exit 1; }
  /usr/bin/sleep 0.1
done

if ! (echo >/dev/tcp/127.0.0.1/9107) 2>/dev/null; then
  cat /tmp/phase7c_acceptance_julia.log
  echo "Fixture did not open port 9107" >&2
  exit 1
fi

"$GODOT_BIN" --headless --path "$GODOT_DIR" --script res://tests/live_interop_smoke.gd >/tmp/phase7c_acceptance_godot.log 2>&1 &
godot_pid=$!
wait "$godot_pid"
cat /tmp/phase7c_acceptance_godot.log
printf 'Phase 7C launcher acceptance passed\n'
