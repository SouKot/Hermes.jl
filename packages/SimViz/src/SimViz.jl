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

# ── Julia 1.12 / MakieCore compatibility shim ─────────────────────────────────
# MakieCore ≤ 0.9.x (shipped with Makie 0.21.x) accesses Core.TypeName.mt in
# func2string(), but Julia 1.12 removed that field from Core.TypeName.
# We override the method at runtime from __init__ so that:
#   • No installed package file is modified
#   • The fix is version-controlled alongside our code
#   • It re-applies automatically on every Julia session
#   • The isdefined guard makes it a no-op on older Julia versions where .mt exists
function __init__()
    _mc_uuid = Base.UUID("20f20a25-4f0e-4fdf-b5d1-57303727442b")
    _mc_id   = Base.PkgId(_mc_uuid, "MakieCore")
    _mk_uuid = Base.UUID("ee78f7c6-11fb-53f2-987a-cfe4a2b5a57a")
    _mk_id   = Base.PkgId(_mk_uuid, "Makie")

    # ── Shim 1: func2string ───────────────────────────────────────────────────
    # Julia 1.12 removed Core.TypeName.mt; func2string in MakieCore ≤ 0.9.x
    # accesses it → FieldError when rendering any plot type.
    if !isdefined(Core.TypeName, :mt) && haskey(Base.loaded_modules, _mc_id)
        _mc = Base.loaded_modules[_mc_id]
        Core.eval(_mc, quote
            function func2string(func::F) where F <: Function
                string(F.name.name)   # equivalent to old F.name.mt.name
            end
        end)
    end

    # ── Shim 2: uv_transform(::Automatic) ────────────────────────────────────
    # Makie 0.21.18 has NO method for uv_transform(::Automatic).
    # The varargs fallback uv_transform(packed...) wraps it into a Tuple, which
    # calls mapfoldl(uv_transform, *, (Automatic(),)) → calls the missing method
    # again → StackOverflowError.  Fix: add the missing method returning the
    # mesh UV default (Y-flip: matches convert_attribute(::Automatic, key"mesh")).
    if haskey(Base.loaded_modules, _mk_id)
        _mk = Base.loaded_modules[_mk_id]

        # ── Shim 2: uv_transform(::Automatic) ────────────────────────────────
        # Makie 0.21.18 has NO method for uv_transform(::Automatic).
        # The varargs fallback uv_transform(packed...) wraps it into a Tuple, which
        # calls mapfoldl(uv_transform, *, (Automatic(),)) → calls the missing method
        # again → StackOverflowError.  Fix: add the missing method returning the
        # mesh UV default (Y-flip: matches convert_attribute(::Automatic, key"mesh")).
        Core.eval(_mk, quote
            function uv_transform(::Automatic)
                Mat{2, 3, Float32}(0, 1, -1, 0, 1, 0)
            end
        end)

        # ── Shim 3: marker_to_sdf_shape(::Symbol) ────────────────────────────
        # GLMakie draw_atomic lifts directly on the marker Observable value and
        # passes a bare Symbol to marker_to_sdf_shape (drawing_primitives.jl:430).
        # No Symbol overload exists — the function only handles concrete geometry
        # types and Observables.  to_spritemarker(::Symbol) IS correctly defined
        # (conversions.jl:1922, uses DEFAULT_MARKER_MAP) so we just bridge it.
        Core.eval(_mk, quote
            function marker_to_sdf_shape(x::Symbol)
                marker_to_sdf_shape(to_spritemarker(x))
            end
        end)

        # ── Shim 4: convert_attribute with TYPE keys (Julia 1.12 singleton) ──
        # Julia 1.12 optimizes zero-field struct singletons captured in closures:
        # Key{:markersize}() is sometimes represented as the TYPE Key{:markersize}
        # rather than as an instance.  lift_convert_inner's inner closure then
        # calls convert_attribute(val, Key{:markersize}, Key{:scatter}) where
        # args 2/3 are the TYPES (Type{Key{K}}) rather than instances (Key{K}()).
        # No existing Makie method matches that signature → MethodError at display.
        # Fix: bridge TYPE dispatch to instance dispatch via Key{K}() construction.
        Core.eval(_mk, quote
            function convert_attribute(val,
                                       ::Type{K1},
                                       ::Type{K2}) where {K1 <: Key, K2 <: Key}
                convert_attribute(val, K1(), K2())
            end
        end)
    end
end

end
