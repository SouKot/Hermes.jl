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
echo "Phase 7D SceneSpec v1 Acceptance & Verification Suite"
echo "============================================================"

echo ""
echo "[Step 1/9] Running Julia SceneSpec Protocol Suite (Phase 7D-00)..."
"$JULIA_BIN" --project="$JULIA_PROJECT" "$JULIA_PROJECT/test/test_scenespec.jl"

echo ""
echo "[Step 2/9] Running Godot Headless Golden Fixture Suite (Phase 7D-00)..."
"$GODOT_BIN" --headless --path "$GODOT_DIR" --script res://tests/scenespec_smoke.gd

echo ""
echo "[Step 3/9] Running End-to-End Julia <-> Godot Cross-Boundary Round-Trip..."
"$JULIA_BIN" --project="$JULIA_PROJECT" "$JULIA_PROJECT/test/test_cross_boundary_roundtrip.jl"

echo ""
echo "[Step 4/9] Running Julia SceneSpec Strongly-Typed Core Suite (Phase 7D-01)..."
"$JULIA_BIN" --project="$JULIA_PROJECT" "$JULIA_PROJECT/test/test_scenespec_typed.jl"

echo ""
echo "[Step 5/9] Running Godot Headless Typed Domain Classes Suite (Phase 7D-01)..."
"$GODOT_BIN" --headless --path "$GODOT_DIR" --script res://tests/scenespec_types_smoke.gd

echo ""
echo "[Step 6/9] Running Julia SceneSpec Semantic Validation Suite (Phase 7D-02)..."
"$JULIA_BIN" --project="$JULIA_PROJECT" "$JULIA_PROJECT/test/test_scenespec_validation.jl"

echo ""
echo "[Step 7/9] Running Godot Headless SimVizSceneValidator Suite (Phase 7D-02)..."
"$GODOT_BIN" --headless --path "$GODOT_DIR" --script res://tests/scenespec_validator_smoke.gd

echo ""
echo "[Step 8/9] Running Julia SceneSpec Extensions & Metadata Suite (Phase 7D-03)..."
"$JULIA_BIN" --project="$JULIA_PROJECT" "$JULIA_PROJECT/test/test_scenespec_extensions.jl"

echo ""
echo "[Step 9/9] Running Godot Headless SceneSpec Extensions & Metadata Suite (Phase 7D-03)..."
"$GODOT_BIN" --headless --path "$GODOT_DIR" --script res://tests/scenespec_extensions_smoke.gd

echo ""
echo "============================================================"
echo "✓ Phase 7D-00, 7D-01, 7D-02 & 7D-03 SceneSpec Contracts, Validation & Extensions ACCEPTED"
echo "============================================================"
