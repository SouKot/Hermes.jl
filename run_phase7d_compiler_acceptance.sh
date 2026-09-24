#!/usr/bin/env bash
set -e

PORT=9107
JULIA_BIN="/home/sourabh/.juliaup/bin/julia"
GODOT_BIN="/home/sourabh/.local/bin/godot"

echo "========================================================================"
echo "Phase 7D-12A Acceptance Test: Core Compiler, Staging & Live Server"
echo "========================================================================"

# Kill any existing process on port 9107
fuser -k ${PORT}/tcp 2>/dev/null || true
sleep 0.5

# 1. Run Julia unit and integration test suite
echo "Step 1: Running Julia compiler test suite..."
${JULIA_BIN} --project=packages/GodotBridge packages/GodotBridge/test/test_scenespec_compiler.jl
echo "Step 1 PASSED: Julia compiler test suite passed."

# 2. Launch production live simulation server on port 9107
echo "Step 2: Starting Live Simulation Server on port ${PORT}..."
${JULIA_BIN} --project=packages/GodotBridge packages/GodotBridge/src/server/live_simulation_server.jl &
SERVER_PID=$!

cleanup() {
    echo "Stopping live simulation server (PID ${SERVER_PID})..."
    kill ${SERVER_PID} 2>/dev/null || true
    wait ${SERVER_PID} 2>/dev/null || true
    fuser -k ${PORT}/tcp 2>/dev/null || true
}
trap cleanup EXIT

# Wait for server to bind
echo "Waiting for server to listen on port ${PORT}..."
for i in {1..30}; do
    if nc -z 127.0.0.1 ${PORT} 2>/dev/null; then
        echo "Server is listening on port ${PORT}."
        break
    fi
    sleep 0.2
done

# 3. Run Godot Authoring Compiler Smoke Test
echo "Step 3: Running Godot authoring compiler smoke test..."
${GODOT_BIN} --headless --path godot -s res://tests/authoring_compiler_smoke.gd
echo "Step 3 PASSED: Godot authoring compiler smoke test succeeded."

# 4. Run Godot Live Interop Smoke Test (Backward compatibility check)
echo "Step 4: Running Godot live interop backward compatibility smoke test..."
${GODOT_BIN} --headless --path godot -s res://tests/live_interop_smoke.gd
echo "Step 4 PASSED: Godot live interop backward compatibility verified."

# 5. Run Godot Live Entity Visualization & Continuous Movement Smoke Test
echo "Step 5: Running Godot live entity continuous visualization smoke test..."
${GODOT_BIN} --headless --path godot -s res://tests/live_entity_visualization_smoke.gd
echo "Step 5 PASSED: Godot live entity continuous visualization verified."

echo "========================================================================"
echo "ALL PHASE 7D-12A ACCEPTANCE TESTS PASSED 100%!"
echo "========================================================================"

