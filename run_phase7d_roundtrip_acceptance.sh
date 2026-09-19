#!/usr/bin/env bash
set -euo pipefail

ROOT="/run/media/sourabh/SANDISK-2TB/antigravity/ABM"
GODOT_DIR="$ROOT/godot"
JULIA_PROJECT="$ROOT/packages/GodotBridge"

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

export GODOT_BIN

echo "============================================================"
echo "Phase 7D-00 SceneSpec v1 Acceptance & Round-Trip Validation"
echo "============================================================"

echo ""
echo "[Step 1/3] Running Julia SceneSpec Protocol Suite..."
"$JULIA_BIN" --project="$JULIA_PROJECT" "$JULIA_PROJECT/test/test_scenespec.jl"

echo ""
echo "[Step 2/3] Running Godot Headless Golden Fixture Suite..."
"$GODOT_BIN" --headless --path "$GODOT_DIR" --script res://tests/scenespec_smoke.gd

echo ""
echo "[Step 3/5] Running End-to-End Julia <-> Godot Cross-Boundary Round-Trip..."
"$JULIA_BIN" --project="$JULIA_PROJECT" "$JULIA_PROJECT/test/test_cross_boundary_roundtrip.jl"

echo ""
echo "[Step 4/5] Running Julia SceneSpec Strongly-Typed Core & Migration Suite (Phase 7D-01)..."
"$JULIA_BIN" --project="$JULIA_PROJECT" "$JULIA_PROJECT/test/test_scenespec_typed.jl"

echo ""
echo "[Step 5/5] Running Godot Headless Typed Domain Classes Suite (Phase 7D-01)..."
"$GODOT_BIN" --headless --path "$GODOT_DIR" --script res://tests/scenespec_types_smoke.gd

echo ""
echo "============================================================"
echo "✓ Phase 7D-00 & 7D-01 SceneSpec Contracts & Typed Core ACCEPTED"
echo "============================================================"

