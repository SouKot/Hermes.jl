"""
    SimViz

GLMakie desktop visualization prototype for the Hermes simulation platform.

Phase 4A: Core rendering + scenario framework.
Phase 4B: Three built-in demo scenarios.
Phase 4C (optional): Bonito web server mode.

# Quick start

```julia
using SimViz

# Level 1 — default hybrid-FSM scenario, all defaults
run_visualization!(ScenarioConfig())

# Level 2 — custom agent count + crowd model
run_visualization!(ScenarioConfig(
    n_agents    = 200,
    crowd_model = MODEL_ORCA,
    v_pref      = 1.5,
))

# Level 3 — built-in demo scenarios (Phase 4B)
run_evacuation_demo!()
run_mm1_demo!()
run_integration_demo!()
```

# Architecture

```
SimViz
├── viz_state.jl       headless: SimVizState, WorldSnapshot, serialize_world, color helpers
├── scenario_config.jl headless: ScenarioConfig, ScenarioContext, build_world!, reset_scenario!
├── density.jl         headless: compute_density_grid!, density_grid_size
├── window.jl          GLMakie:  create_window!, update_viz!, run_visualization!
├── controls.jl        GLMakie:  wire_controls!, parameter sliders, playback buttons
└── scenarios.jl       GLMakie:  evacuation_scenario, mm1_scenario, integration_scenario (4B)
```

The headless layer (first 3 files) can be tested without a display server.
`window.jl` and `controls.jl` load GLMakie and require an OpenGL context.

# Exports

See individual source files for full documentation of each exported symbol.
"""
module SimViz

# ── Module-level dependencies ─────────────────────────────────────────────────
# Headless-safe packages — loaded at module level, no display needed
using Observables                       # Observable{T}
using Accessors: @set                   # immutable struct field update
using Ark: World, Query                 # ECS world + archetype query
using StaticArrays: SVector             # SVector{2,F}
using SimCore                           # SimWorld, SimStats, entity_count, sim_summary
using SimCrowd                          # all agent component types + step!
using Random: MersenneTwister           # reproducible RNG for agent placement
using LinearAlgebra: norm               # distance helpers

# ── Source files (include order = dependency order) ───────────────────────────
# Headless layer — display-safe, no GLMakie
include("viz_state.jl")          # 4A-02: SimVizState, WorldSnapshot, serialize_world
include("scenario_config.jl")    # 4A-03: ScenarioConfig, ScenarioContext, build_world!
include("density.jl")            # 4A-04: compute_density_grid!, density_grid_size

# GLMakie layer — requires an OpenGL context / display server
# NOTE: These files call `using GLMakie` internally. They must be included
# AFTER the headless layer because they reference types defined there.
include("window.jl")             # 4A-05: create_window!, update_viz!, run_visualization!
include("controls.jl")           # 4A-06: wire_controls!, parameter sliders

# Demo scenarios (Phase 4B)
include("scenarios.jl")          # 4B: evacuation_scenario, mm1_scenario, integration_scenario

# ── Exports ───────────────────────────────────────────────────────────────────

# ── viz_state.jl ──────────────────────────────────────────────────────────────
export OverlayMode, OVERLAY_PANIC, OVERLAY_FSM, OVERLAY_DENSITY
export RGBAfTuple, Pos2f
export SimVizState
export WorldSnapshot
export serialize_world
export compute_agent_colors!
export _panic_to_color, _fsm_to_color, _density_to_color

# ── scenario_config.jl ────────────────────────────────────────────────────────
export CrowdModel, MODEL_SFM, MODEL_ORCA, MODEL_HYBRID_FSM, MODEL_CSM
export RoomGeometry, DoorSpec, ScheduledEvent
export ScenarioConfig, ScenarioContext
export build_world!, reset_scenario!, serialize_world_ctx

# ── density.jl ────────────────────────────────────────────────────────────────
export compute_density_grid!, density_grid_size

# ── window.jl ─────────────────────────────────────────────────────────────────
export create_window!
export update_viz!
export run_visualization!

# ── controls.jl ───────────────────────────────────────────────────────────────
export wire_controls!

# ── scenarios.jl (Phase 4B) ──────────────────────────────────────────────────
export evacuation_scenario, run_evacuation_demo!
export mm1_scenario, run_mm1_demo!
export integration_scenario, run_integration_demo!

# ── Module initialisation ─────────────────────────────────────────────────────
# All Julia 1.12 / MakieCore compatibility shims removed on 2026-09-10.
# They were workarounds for Makie 0.21.18 (GLMakie 0.10.18) incompatibilities:
#   • func2string — Core.TypeName.mt removed in Julia 1.12 (MakieCore ≤ 0.9)
#   • uv_transform(::Automatic) — missing method in Makie 0.21
#   • marker_to_sdf_shape(::Symbol) — missing overload in Makie 0.21
#   • convert_attribute TYPE-key dispatch — Julia 1.12 singleton optimisation
# All fixed upstream in Makie 0.24.14 / GLMakie 0.13.14.
function __init__()
    nothing
end

end
