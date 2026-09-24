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

echo "============================================================"
echo "      ANTIGRAVITY SIMVIZ — LIVE SIMULATION GUI DEMO"
echo "============================================================"
echo "Starting backend Julia bridge server on port 9107..."

# Clean up any lingering process on port 9107 to guarantee fresh server
fuser -k 9107/tcp 2>/dev/null || true
sleep 0.4

JULIA_PID=""
cd "$JULIA_DIR"
"$JULIA_BIN" --project=. src/server/live_simulation_server.jl &
JULIA_PID=$!

# Poll until port 9107 is actively listening
echo "Waiting for JuliaBridge server to bind 127.0.0.1:9107..."
READY=0
for i in {1..30}; do
  if (echo >/dev/tcp/127.0.0.1/9107) 2>/dev/null; then
    READY=1
    echo "● JuliaBridge server is ready and listening on port 9107!"
    break
  fi
  sleep 0.3
done

if [[ "$READY" -ne 1 ]]; then
  echo "ERROR: Timed out waiting for Julia server to listen on port 9107." >&2
  if [[ -n "$JULIA_PID" ]]; then
    kill "$JULIA_PID" 2>/dev/null || true
  fi
  exit 1
fi

echo ""
echo "Launching Godot 4 GUI client..."
echo "------------------------------------------------------------"
echo "WHAT TO EXPECT IN THE GUI:"
echo "1. Top Status: '● CONNECTED · MESSAGE' (green light)"
echo "2. Viewport:"
echo "   - Live orbiting entities with trailing paths"
echo "   - Interactive 2D spatial grid & dynamic density heatmap"
echo "3. Interactivity:"
echo "   - LEFT-CLICK: Select any entity or queue to view properties"
echo "   - MIDDLE-MOUSE DRAG: Pan canvas"
echo "   - MOUSE WHEEL: Zoom in/out (0.2x to 8.0x)"
echo "   - BOTTOM TRANSPORT: PAUSE, STEP (+0.1s), PLAY, RESET"
echo "   - SPEED SLIDER: Adjust simulation speed (0.25x to 4.00x)"
echo "   - TOGGLES: TRAJ (trajectories), GRID (density), HEAT (heatmap)"
echo "4. Inspector (Right Panel): Live entity metrics, state updates"
echo "------------------------------------------------------------"
echo "Closing the Godot window will cleanly terminate the demo."
echo "============================================================"

cleanup() {
  echo ""
  echo "Shutting down Phase 7C demo..."
  if [[ -n "${GODOT_PID:-}" ]]; then
    kill "$GODOT_PID" 2>/dev/null || true
  fi
  if [[ -n "${JULIA_PID:-}" ]]; then
    kill "$JULIA_PID" 2>/dev/null || true
  fi
  fuser -k 9107/tcp 2>/dev/null || true
  exit 0
}

trap cleanup INT TERM EXIT

cd "$GODOT_DIR"
"$GODOT_BIN" --path . &
GODOT_PID=$!

wait "$GODOT_PID" || true

if [[ -n "${JULIA_PID:-}" ]]; then
  kill "$JULIA_PID" 2>/dev/null || true
fi
fuser -k 9107/tcp 2>/dev/null || true
echo "Phase 7C demo finished."
