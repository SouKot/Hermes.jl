# Phase 7C Restart Handoff

## Current Position

Phase 7C-00 through 7C-06 are implemented and validated for the normal GUI path. Normal-scene 7C-07 acceptance is also complete. 7C-06A remains partially open only for connected 500K compact GUI delivery and detail-on-demand editing.

## Working GUI

- Godot 4.7.2 project: `godot/`
- Julia fixture: `packages/GodotBridge/test/fixture_server_phase7c.jl`
- Port: `127.0.0.1:9107`
- Launcher: `run_phase7c_demo.sh`
- Clean acceptance launcher: `run_phase7c_acceptance.sh`

The normal fixture GUI shows six moving entities, one queue, trajectories, GRID/HEAT layers, FPS/update metrics, selection, inspector, and working PLAY/PAUSE/STEP/RESET/SPEED controls with ACKs.

## Architecture

- Under 10,000 entities: generic dictionaries preserve rich inspector state.
- At or above 10,000 entities: compact binary positions -> packed arrays -> `MultiMeshInstance2D`.
- Julia remains authoritative; compact render state is a projection.
- Detail-on-demand `DetailRequest/DetailResponse` and property-edit commands are planned but not implemented.

## Key Evidence

- Generic 500K path: peak RSS `6,369,472 KB` (~6.08 GiB).
- Compact binary 500K path: peak RSS `239,056 KB` (~234 MiB).
- Generic-to-compact end-to-end reduction: ~26.6x.
- Isolated MultiMesh 500K: peak RSS `102,428 KB`, frame p50 `6.899 ms`, p99 `6.914 ms`.
- Compact end-to-end 500K: decode p99 `1.621 ms`, state apply p99 `182.435 ms`, render publication p99 `0.003 ms`, viewport submission p99 `0.005 ms`.
- 10K frame time: p50 `16.713 ms`, p99 `32.947 ms`.
- Slow transport: 150 ms delay, every fourth snapshot dropped, 66 snapshots received.
- Recovery smoke: forced client reconnect, 2 Hello messages, 398 snapshots, 6 entities.
- Repeated 10K RSS: `228500`, `228160`, `228520 KB`, no monotonic growth.

## Tests and Reports

- `godot/tests/phase7c_acceptance_smoke.gd`
- `godot/tests/delta_stream_smoke.gd`
- `godot/tests/performance_resilience_smoke.gd`
- `godot/tests/frame_time_smoke.gd`
- `godot/tests/slow_transport_smoke.gd`
- `godot/tests/full_recovery_smoke.gd`
- `godot/tests/large_scale_memory_benchmark.gd`
- `godot/tests/multimesh_large_scale_smoke.gd`
- `godot/tests/live_reconnect_smoke.gd`
- `docs/2026-09-17_phase7c_07_acceptance_checklist.md`
- `docs/2026-09-17_phase7c_06_memory_and_scale_report.md`
- `docs/2026-09-17_phase7c_generic_vs_compact_render_paths.md`

## Remaining Work

1. Connected 500K compact Julia-to-Godot GUI acceptance.
2. Detail-on-demand inspection for compact entities.
3. Property-update commands for compact entities.
4. Then proceed with Phase 7D foundation: SceneSpec round-trip, typed ports, authoring model, layout editor, process graph editor, ABM model selection, import/export.

## Restart Prompt

Say: `Resume from docs/2026-09-17_phase7c_restart_handoff.md. Check git status, verify the normal launcher and tests, then continue with connected 500K compact acceptance or begin 7D foundation as I direct.`
