# Phase 7C-07 Acceptance Checklist

## Automated

- [x] Godot project starts offline.
- [x] Protocol Hello decoding.
- [x] Full snapshot application.
- [x] One-command Julia/Godot startup.
- [x] Live Hello/snapshot/ACK interop.
- [x] Delta add/update/remove/resync behavior.
- [x] Viewport state wiring.
- [x] Stale-delta resync behavior.
- [x] State-store and viewport smoke tests.
- [x] 10K/100K/500K synthetic performance paths.
- [x] Frame-time p50/p99 measurement.
- [x] Slow transport/dropped snapshot check.
- [x] Client reconnect/full snapshot recovery check.
- [x] Process-level repeated RSS comparison.

## GUI Confirmed

- [x] Julia fixture connects to Godot.
- [x] Six entities and one queue are visible.
- [x] Entities move and trajectories render.
- [x] GRID and HEAT layers render.
- [x] FPS and snapshot update-rate metrics are visible.
- [x] PLAY, PAUSE, STEP, RESET, and SPEED visibly affect the fixture.
- [x] Entity and queue selection/inspector behavior works.

## Open

- [x] Scripted live delta-stream acceptance.
- [x] Client reconnect and full snapshot recovery.
- [x] Normal-scene GUI acceptance.
- [ ] Connected compact 500K Julia-to-Godot GUI acceptance.
- [ ] Detail request/property edit workflow for compact entities.

## Evidence

- Automated smoke: `godot/tests/phase7c_acceptance_smoke.gd`
- Joint launcher: `run_phase7c_acceptance.sh`
- Delta stream: `godot/tests/delta_stream_smoke.gd`
- Performance/resilience: `godot/tests/performance_resilience_smoke.gd`
- Frame timing: `godot/tests/frame_time_smoke.gd`
- Live recovery: `godot/tests/live_reconnect_smoke.gd`, `godot/tests/full_recovery_smoke.gd`
- Scale report: `docs/2026-09-17_phase7c_06_memory_and_scale_report.md`
- Compact-path design: `docs/2026-09-17_phase7c_generic_vs_compact_render_paths.md`
