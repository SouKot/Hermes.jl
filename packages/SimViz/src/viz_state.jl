"""
    viz_state.jl — Core visualization state and world serialization

Defines the `SimVizState` struct (Observables) and the
`serialize_world` function — the **Phase 7-compatible wire format**.

Design notes
─────────────
- The simulation `world` is an `Ark.World` (ECS), not `SimCore.SimWorld`.
  Agents are stored as ECS entities carrying `Position{F}`, `Velocity{F}`,
  `AgentFSMState{F}` components (queried via `Ark.Query`).
- `serialize_world` returns a `WorldSnapshot` NamedTuple with:
    - All array entries are `Float32` or `UInt8` — never `Float64`.
    - Field names are **frozen**: Phase 7 (Godot WebSocket) uses exactly these
      as JSON/MsgPack message keys.
- `fsm_modes[i] = 0xFF` (sentinel) when agent i has no `AgentFSMState`
  component (pure-SFM or pure-ORCA). Renderers should show a neutral color.
- Colors are stored as `NTuple{4,Float32}` = (r,g,b,a) to avoid importing
  GLMakie at the data layer. `window.jl` converts to `RGBAf` for Makie plots.
- Positions are stored as `NTuple{2,Float32}` = (x,y) for the same reason.
  `window.jl` converts to `Point2f` for Makie scatter plots.
"""

using Ark: World, Query
using Observables: Observable
using StaticArrays: SVector
using SimCrowd: Position, Velocity, AgentFSMState, ORCA_MODE, SFM_MODE

# ── Color/position type aliases ───────────────────────────────────────────────

"""
    RGBAfTuple

`(r, g, b, a)` color tuple, `Float32` each, range [0,1].
Used instead of `GLMakie.RGBAf` so the data layer is headless-safe.
`window.jl` converts via `RGBAf(c...)`.
"""
const RGBAfTuple = NTuple{4, Float32}

"""
    Pos2f

`(x, y)` position tuple, `Float32` each, in world coords (m).
Used instead of `GLMakie.Point2f` so the data layer is headless-safe.
`window.jl` converts via `Point2f(p)`.
"""
const Pos2f = NTuple{2, Float32}

# ── Overlay color mode ────────────────────────────────────────────────────────

"""
    OverlayMode

Selects which agent attribute drives the color of each agent circle.

| Value             | Color encodes                                        |
|:----------------- |:---------------------------------------------------- |
| `OVERLAY_PANIC`   | `panic_level` → green (0.0) … red (1.0)             |
| `OVERLAY_FSM`     | `AgentFSMState.mode` → blue (ORCA) / red (SFM)      |
| `OVERLAY_DENSITY` | `AgentFSMState.ρ_ema` (ped/m²) → green/yellow/red  |
"""
@enum OverlayMode begin
    OVERLAY_PANIC    # panic_level ∈ [0,1]
    OVERLAY_FSM      # FSM mode: ORCA=0, SFM=1, unknown=0xFF → gray
    OVERLAY_DENSITY  # local density ρ_ema (ped/m²)
end

# ── GLMakie-side Observable container ────────────────────────────────────────

"""
    SimVizState

Holds all `Observable`s that the GLMakie scene is subscribed to.
Updating an observable's value (`obs[] = new_value`) automatically
triggers the corresponding Makie plot to redraw.

All agent arrays are indexed 1..N where N = number of crowd agents
in the current frame (re-built each call to `update_viz!`).

# Fields
- `positions`     : `Pos2f[]`        — 2D positions in world coords (m)
- `agent_colors`  : `RGBAfTuple[]`   — per-agent (r,g,b,a) color tuple
- `des_positions` : `Pos2f[]`        — 2D positions of DES agents (M/M/1 dots)
- `des_colors`    : `RGBAfTuple[]`   — per-DES-agent color (green=waiting, blue=in_service)
- `density_grid`  : `Matrix{Float32}` — cell density (ped/m²); 100×100 by default
- `stats_text`    : `String`         — preformatted multi-line stats panel text
- `sim_time`      : `Float64`        — current simulated time (s)
- `agent_count`   : `Int`            — number of live crowd agents
- `fps_display`   : `String`         — "FPS: 60.3" — updated each render frame
- `overlay_mode`  : `OverlayMode`    — which attribute drives agent color
- `show_density`  : `Bool`           — whether density heatmap is visible
- `wall_segments` : `Pos2f[]`        — interleaved wall segment endpoints
                                       [start1, end1, start2, end2, ...]
                                       Updated on Reset so door-width changes
                                       are reflected in the rendered geometry.

`window.jl` converts `Pos2f` → `Point2f` and `RGBAfTuple` → `RGBAf` for
Makie scatter/heatmap primitives.
"""
Base.@kwdef mutable struct SimVizState
    positions     :: Observable{Vector{Pos2f}}        = Observable(Pos2f[])
    agent_colors  :: Observable{Vector{RGBAfTuple}}   = Observable(RGBAfTuple[])
    des_positions :: Observable{Vector{Pos2f}}        = Observable(Pos2f[])
    des_colors    :: Observable{Vector{RGBAfTuple}}   = Observable(RGBAfTuple[])
    density_grid  :: Observable{Matrix{Float32}}      = Observable(zeros(Float32, 100, 100))
    stats_text    :: Observable{String}               = Observable("")
    sim_time      :: Observable{Float64}              = Observable(0.0)
    agent_count   :: Observable{Int}                  = Observable(0)
    fps_display   :: Observable{String}               = Observable("FPS: —")
    overlay_mode  :: Observable{OverlayMode}          = Observable(OVERLAY_PANIC)
    show_density  :: Observable{Bool}                 = Observable(false)
    wall_segments :: Observable{Vector{Pos2f}}        = Observable(Pos2f[])
end

# ── Phase 7-compatible world serialization ────────────────────────────────────

"""
    WorldSnapshot

The NamedTuple returned by `serialize_world`. Field names are **frozen** —
they become the WebSocket wire format in Phase 7 (Godot JSON/MsgPack).

| Field             | Type                         | Notes                                        |
|:----------------- |:---------------------------- |:-------------------------------------------- |
| `sim_time`        | `Float64`                    | Current simulated time (s)                   |
| `positions`       | `Vector{NTuple{2,Float32}}`  | Agent (x,y) positions in world coords (m)    |
| `velocities`      | `Vector{NTuple{2,Float32}}`  | Agent (vx,vy) velocities (m/s)               |
| `panic_levels`    | `Vector{Float32}`            | Panic ∈ [0,1] — 0f0 until ScenarioContext bridges SimWorld |
| `fsm_modes`       | `Vector{UInt8}`              | 0=ORCA, 1=SFM, 0xFF=not applicable           |
| `local_densities` | `Vector{Float32}`            | ρ_ema (ped/m²) from AgentFSMState, else 0f0  |
| `n_agents`        | `Int`                        | Number of crowd agents this frame            |
| `n_des_agents`    | `Int`                        | DES agents (populated in 4B M/M/1 demo)      |
| `stats`           | `NamedTuple`                 | Flat stats from SimCore.SimWorld (if wired)  |

!!! note "Phase 7 field freeze"
    Do NOT rename, reorder, or change the types of these fields without
    updating `PROTOCOL.md` and the Godot deserializer simultaneously.
"""
const WorldSnapshot = @NamedTuple begin
    sim_time        :: Float64
    positions       :: Vector{NTuple{2, Float32}}
    velocities      :: Vector{NTuple{2, Float32}}
    panic_levels    :: Vector{Float32}
    fsm_modes       :: Vector{UInt8}
    local_densities :: Vector{Float32}
    n_agents        :: Int
    n_des_agents    :: Int
    stats           :: @NamedTuple begin
        total_events     :: Int
        total_arrivals   :: Int
        total_departures :: Int
        busy_time        :: Float64
        elapsed_sim_time :: Float64
    end
end

"""
    serialize_world(world::World, sim_time::Float64 = 0.0) :: WorldSnapshot

Extract all agent state from the Ark ECS world into a plain `NamedTuple`
suitable for:
- Feeding GLMakie Observables in `update_viz!`
- JSON/MsgPack encoding for Phase 7 Godot WebSocket

Queries `Position{Float32}` + `Velocity{Float32}` (mandatory — every crowd
agent has these). Optionally queries `AgentFSMState{Float32}` — agents
without this component (pure-SFM / pure-ORCA worlds) get `fsm_modes = 0xFF`
and `local_densities = 0.0f0`.

!!! warning "Ark world type"
    `world` must be `Ark.World`, NOT `SimCore.SimWorld`.
    `SimScene.world` is always `Ark.World`. If you have a `SimScene`, pass
    `scene.world`.

!!! note "Panic levels / DES stats"
    Panic levels are stubbed as `0f0` here — they require a `SimCore.SimWorld`
    reference (held by `ScenarioContext` in 4A-03). DES stats are likewise
    zeroed until the ScenarioContext bridge is wired.
"""

# ── World component type check ────────────────────────────────────────────────

"""
    _world_has_component(world::World, ::Type{C}) :: Bool

Return `true` if component type `C` was registered in `world` (i.e. passed
to `World(C1, C2, ...)` at construction time). Ark throws `ArgumentError`
if you `Query` an unregistered component — this helper avoids that.

Uses the world's compile-time type parameter (fast, no allocation).
"""
function _world_has_component(world::World, ::Type{C}) where {C}
    # Ark.World{CS, TS, N, ...} — TS (param 2) = Tuple{Type{C1}, Type{C2}, ...}
    # We check if Type{C} appears among the type parameters of TS.
    # This is purely compile-time: no allocation, no runtime dispatch.
    TS = typeof(world).parameters[2]  # Tuple{Type{Position{F}}, Type{Velocity{F}}, ...}
    return Type{C} in TS.parameters
end

function serialize_world(world::World, sim_time::Float64 = 0.0) :: WorldSnapshot
    F = Float32

    # ── Pass 1: Positions + Velocities (mandatory — all crowd agents) ─────────
    positions_buf  = NTuple{2, F}[]
    velocities_buf = NTuple{2, F}[]

    for (_, pos_col, vel_col) in Query(world, (Position{F}, Velocity{F}))
        n = length(pos_col)
        sizehint!(positions_buf,  length(positions_buf) + n)
        sizehint!(velocities_buf, length(velocities_buf) + n)
        for i in eachindex(pos_col)
            p = pos_col[i].p
            v = vel_col[i].v
            push!(positions_buf,  (p[1], p[2]))
            push!(velocities_buf, (v[1], v[2]))
        end
    end

    n_agents = length(positions_buf)

    # ── Pass 2: FSM state (optional — HybridFSM agents only) ─────────────────
    # Agents without AgentFSMState get sentinel 0xFF (no FSM) and density 0.
    # IMPORTANT: Ark throws ArgumentError if you Query a component type that was
    # never registered in the World (e.g. querying AgentFSMState in a pure-SFM
    # world). We check the world's type signature before querying.
    fsm_modes_buf       = fill(0xFF % UInt8, n_agents)
    local_densities_buf = zeros(F, n_agents)

    if _world_has_component(world, AgentFSMState{F})
        fsm_idx = 1
        for (_, fsm_col) in Query(world, (AgentFSMState{F},))
            for i in eachindex(fsm_col)
                if fsm_idx <= n_agents
                    fsm_modes_buf[fsm_idx]       = UInt8(fsm_col[i].mode)
                    local_densities_buf[fsm_idx] = F(fsm_col[i].ρ_ema)
                    fsm_idx += 1
                end
            end
        end
    end

    # ── Panic levels: stubbed — requires SimCore.SimWorld bridge (4A-03) ──────
    panic_levels_buf = zeros(F, n_agents)

    # ── Stats: stubbed — requires SimCore.SimWorld.stats bridge (4A-03) ──────
    stats_snap = (
        total_events     = 0,
        total_arrivals   = 0,
        total_departures = 0,
        busy_time        = 0.0,
        elapsed_sim_time = sim_time,
    )

    return (
        sim_time        = sim_time,
        positions       = positions_buf,
        velocities      = velocities_buf,
        panic_levels    = panic_levels_buf,
        fsm_modes       = fsm_modes_buf,
        local_densities = local_densities_buf,
        n_agents        = n_agents,
        n_des_agents    = 0,
        stats           = stats_snap,
    )
end

# ── Color mapping helpers ─────────────────────────────────────────────────────
# All return NTuple{4,Float32} = (r,g,b,a) so the data layer needs no GLMakie.
# window.jl converts to RGBAf via `RGBAf(c...)`.

"""
    _panic_to_color(p::Float32) :: RGBAfTuple

Map panic level p ∈ [0, 1] to an RdYlGn_r-inspired color:
- p = 0.0 → green  (calm)
- p = 0.5 → yellow (elevated)
- p = 1.0 → red    (full panic)
"""
function _panic_to_color(p::Float32) :: RGBAfTuple
    p_c = clamp(p, 0f0, 1f0)
    if p_c < 0.5f0
        t = p_c * 2f0
        r = t * 0.996f0
        g = 0.502f0 + t * (0.878f0 - 0.502f0)
        b = 0.267f0 * (1f0 - t)
    else
        t = (p_c - 0.5f0) * 2f0
        r = 0.996f0 + t * (0.647f0 - 0.996f0)
        g = 0.878f0 * (1f0 - t)
        b = 0.0f0
    end
    return (r, g, b, 0.9f0)
end

"""
    _fsm_to_color(mode::UInt8) :: RGBAfTuple

Map FSM mode to a categorical color:
- ORCA mode (0)  → cornflower blue `#6495ED`
- SFM  mode (1)  → tomato red      `#FF6347`
- Unknown (0xFF) → medium gray     (no FSM component)
"""
function _fsm_to_color(mode::UInt8) :: RGBAfTuple
    if mode == UInt8(ORCA_MODE)
        return (0.392f0, 0.584f0, 0.929f0, 0.9f0)  # cornflowerblue
    elseif mode == UInt8(SFM_MODE)
        return (1.000f0, 0.388f0, 0.278f0, 0.9f0)  # tomato
    else
        return (0.55f0, 0.55f0, 0.55f0, 0.9f0)      # gray (no FSM)
    end
end

"""
    _density_to_color(ρ::Float32) :: RGBAfTuple

Map local pedestrian density ρ (ped/m²) to a traffic-light color:
- ρ < 1.0        → emerald green (free flow)
- 1.0 ≤ ρ < 3.0  → yellow-green  (moderate)
- 3.0 ≤ ρ < 5.0  → orange        (dense)
- ρ ≥ 5.0        → crimson red   (jam / crush risk)
"""
function _density_to_color(ρ::Float32) :: RGBAfTuple
    if ρ < 1.0f0
        return (0.18f0, 0.80f0, 0.44f0, 0.9f0)  # emerald green
    elseif ρ < 3.0f0
        t = (ρ - 1.0f0) / 2.0f0
        r = 0.18f0 + t * (1.0f0 - 0.18f0)
        g = 0.80f0 - t * (0.80f0 - 0.76f0)
        return (r, g, 0.1f0, 0.9f0)
    elseif ρ < 5.0f0
        t = (ρ - 3.0f0) / 2.0f0
        g = 0.76f0 * (1.0f0 - t)
        return (1.0f0, g, 0.0f0, 0.9f0)
    else
        return (0.85f0, 0.10f0, 0.10f0, 0.9f0)  # crimson
    end
end

"""
    compute_agent_colors!(colors::Vector{RGBAfTuple}, snapshot::WorldSnapshot,
                          mode::OverlayMode) -> colors

Fill `colors` (in-place, auto-resized when N changes) from `snapshot` data
according to the active `mode`. Called each frame from `update_viz!`.

This is a hot path — `@inbounds` is used; no allocations inside the loop.
`window.jl` converts `colors::Vector{RGBAfTuple}` to `Vector{RGBAf}` once
before passing to Makie (or wraps via `reinterpret`).
"""
function compute_agent_colors!(colors::Vector{RGBAfTuple},
                                snapshot::WorldSnapshot,
                                mode::OverlayMode)
    n = snapshot.n_agents
    length(colors) == n || resize!(colors, n)  # only on agent count change
    if mode === OVERLAY_PANIC
        @inbounds for i in 1:n
            colors[i] = _panic_to_color(snapshot.panic_levels[i])
        end
    elseif mode === OVERLAY_FSM
        @inbounds for i in 1:n
            colors[i] = _fsm_to_color(snapshot.fsm_modes[i])
        end
    else  # OVERLAY_DENSITY
        @inbounds for i in 1:n
            colors[i] = _density_to_color(snapshot.local_densities[i])
        end
    end
    return colors
end
