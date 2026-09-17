# SimViz

[![Build Status](https://github.com/sauravkotnala/SimViz.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/sauravkotnala/SimViz.jl/actions/workflows/CI.yml?query=branch%3Amain)

Real-time GLMakie visualization for the Antigravity crowd+DES simulation platform.
Part of the [ABM monorepo](../../README.md) · current headless and demo coverage ✅

---

## Overview

SimViz opens a GLMakie window that shows:

- **Agent scatter plot** — positions updated at every sim step, colored by overlay mode
- **Density heatmap** — real-time Gaussian kernel density estimate on a configurable grid
- **Stats panel** — arrivals, departures, utilization, flow rate, sim clock
- **Control panel** — Run/Pause/Reset, speed slider, overlay selector, agent-count slider

It bridges `SimCrowd` (ABM agents) and `SimCore` (DES events) through a single
`ScenarioConfig` struct that is the **canonical user-facing surface**.

---

## Quick Start

### Level 1 — Run a demo out of the box

```julia
using SimViz

# Classic bottleneck evacuation (T7 benchmark)
run_evacuation_demo!()                        # 80 agents, 1m door, HybridFSM
run_evacuation_demo!(n_agents=200, door_width=0.8)

# M/M/1 DES queue visualized as dots in a corridor
run_mm1_demo!()                               # λ=0.9, μ=1.0, ρ=0.9
run_mm1_demo!(lambda=0.5, mu=1.0)

# 100 ORCA agents + DES alarm fires at t=60s → panic color shift
run_integration_demo!()
run_integration_demo!(n_agents=150, evac_alarm_time=30.0)
```

### Level 2 — Customize a scenario

```julia
using SimViz

config = evacuation_scenario(
    n_agents    = 120,
    door_width  = 0.8,        # narrower door → more congestion
    crowd_model = MODEL_SFM,  # pure SFM instead of HybridFSM
    rng_seed    = 42,
)
run_visualization!(config)
```

### Level 3 — Fully custom `ScenarioConfig`

```julia
using SimViz

room = RoomGeometry(
    width  = 20.0,
    height = 10.0,
    doors  = [
        DoorSpec(wall=:east, center=5.0, width=2.0),
        DoorSpec(wall=:west, center=5.0, width=1.5),
    ],
)

config = ScenarioConfig(
    room          = room,
    n_agents      = 300,
    crowd_model   = MODEL_HYBRID_FSM,
    execution_backend = :threads,   # or :cpu / :cuda
    v_pref        = 1.5,
    rho_on        = 3.0,          # trigger SFM earlier
    flux_boundary = true,         # remove agents that exit
    rng_seed      = 7,
    label         = "My scenario",
)

run_visualization!(config)
```

### Demo guide

- **`run_evacuation_demo!()`** — the main ABM crowd demo. It defaults to
    `MODEL_HYBRID_FSM`, but you can switch to `MODEL_SFM`, `MODEL_ORCA`, or
    another supported crowd model by passing `crowd_model=...`.
- **`run_mm1_demo!()`** — a pure DES queue demo. It does not use an ABM crowd
    backend, so `execution_backend` is not the interesting knob here.
- **`run_integration_demo!()`** — DES + crowd integration with an ORCA crowd.
    It runs on CPU or GPU by setting `execution_backend`, but the crowd model is
    fixed to ORCA in the canned scenario.
- **`run_des_orca_demo!()`** — composite DES + ORCA + alarm demo. Like the
    integration demo, it can run with CPU or GPU crowd execution through
    `execution_backend`, but the built-in scenario keeps the crowd model fixed to
    ORCA.

If you want to change the crowd model in one of the fixed demos, use
`ScenarioConfig(...)` or the underlying scenario constructor directly instead of
the canned `run_*_demo!` wrapper.

---

## Architecture

```
ScenarioConfig          ← single user-facing parameter struct (primitive types only)
    │
    ▼
build_world!(config)   → ScenarioContext
    │                       ├── ark_world  :: Ark.World  (ABM/ECS agents)
    │                       ├── sim_world  :: SimCore.SimWorld (DES state)
    │                       ├── scene      :: SimScene   (backend-aware neighbor search + systems)
    │                       └── sim_time   :: Float64
    │
    ▼
run_visualization!(config)
    ├── build_world!       (headless)
    ├── make_viz_state!    (GLMakie Observables)
    ├── make_window!       (Figure + panels)
    ├── wire_controls!     (sliders, buttons → Observables)
    └── render_loop        (step! → serialize_world_ctx → update Observables → redraw)
```

### Source files

| File | Purpose |
|:-----|:--------|
| `SimViz.jl` | Module, imports, include order, exports |
| `viz_state.jl` | `SimVizState`, `serialize_world_ctx`, color helpers, `compute_agent_colors!` |
| `scenario_config.jl` | `ScenarioConfig`, `RoomGeometry`, `DoorSpec`, `build_world!`, `reset_scenario!`, `execution_backend` |
| `density.jl` | `compute_density_grid!`, `density_grid_size` |
| `window.jl` | `make_window!`, `make_stats_panel!`, `run_visualization!` |
| `controls.jl` | `wire_controls!`, slider/button wiring |
| `scenarios.jl` | `evacuation_scenario`, `mm1_scenario`, `integration_scenario`, `run_*_demo!` |

---

## Overlay Modes

| Constant | Description |
|:---------|:------------|
| `OVERLAY_PANIC` | Agent color maps panic level: 🟢 calm → 🔴 panicked |
| `OVERLAY_FSM` | HybridFSM mode: 🔵 ORCA (free flow) → 🔴 SFM (dense) |
| `OVERLAY_DENSITY` | Local density: 🟢 free → 🟡 moderate → 🔴 jam |

---

## Supported Crowd Models

| Constant | Description |
|:---------|:------------|
| `MODEL_SFM` | Social Force Model (Helbing 2000) |
| `MODEL_ORCA` | Optimal Reciprocal Collision Avoidance |
| `MODEL_HYBRID_FSM` | Adaptive ORCA↔SFM switching by local density |
| `MODEL_CSM` | Continuum Steering Model |

All four crowd models are built through the same backend-aware `RadixSpatialHash`
path, so `ScenarioConfig(execution_backend=...)` applies consistently at the
`build_world!` level.

---

## Running Tests

```bash
# Headless unit tests (no display required)
julia --project=packages/SimViz -e "using Pkg; Pkg.test()"

# Expected: headless tests pass, including ScenarioConfig/backend parity checks
```

Test coverage includes: `serialize_world_ctx` field types, `build_world!` for all 4
crowd models, `ScenarioConfig.execution_backend` parity, RNG reproducibility,
`compute_density_grid!` mass conservation, color helpers, and integration
step→snapshot smoke tests. GLMakie rendering tests are manual.

---

## Manual Verification Checklist

- [ ] `run_evacuation_demo!()` — 80 agents visible, ORCA↔SFM color switching at door, FPS ≥ 60
- [ ] `run_mm1_demo!()` — queue grows/shrinks, L stabilizes near 9.0 (λ=0.9, μ=1.0)
- [ ] `run_integration_demo!()` — at t=60s 🚨 ALARM fires, agents shift green→orange/red

---

## Roadmap

| Area | Description | Status |
|:------|:------------|:-------|
| Core | Headless scenario layer (ScenarioConfig, serialize, density, colors) | ✅ Done |
| Demo UI | Three demo scenarios + GLMakie window | ✅ Done |
| Future GUI | WebSocket bridge, Godot desktop dashboard, and extension ecosystem | 🔮 Planned |
