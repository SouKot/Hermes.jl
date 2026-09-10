"""
    scenario_config.jl — Complete user-facing parameter surface + world builder

# Overview

`ScenarioConfig` is the **single source of truth** for everything the user can
tweak in SimViz. It is designed to be:

1. **Serializable** — all fields are primitive Julia types (Float64, Int, Bool,
   Symbol) so the struct round-trips cleanly through TOML, JSON, or MsgPack.
   Phase 7 will pass this struct over the WebSocket as the "scenario spec".

2. **Complete** — covers geometry, agent physics (SFM/ORCA/HybridFSM/CSM),
   DES event schedule, and solver settings. Users should never need to touch
   the underlying SimCrowd structs directly.

3. **Forward-compatible** — new parameters should be added with sane defaults
   so that existing TOML files continue to load without error.

`ScenarioContext` bridges the two simulation worlds:
- `Ark.World`         — ECS agents (Position, Velocity, AgentFSMState, …)
- `SimCore.SimWorld`  — DES agents, SimStats, zone queues

`serialize_world_ctx` is the full version of `serialize_world` that includes
panic levels and DES stats from the SimCore side.

# File layout

    DoorSpec                ← one door opening on a room wall
    RoomGeometry            ← rectangular room + door list
    ScheduledEvent          ← timed DES event (alarm, burst spawn, door toggle)
    CrowdModel              ← enum: SFM / ORCA / HybridFSM / CSM
    ScenarioConfig          ← complete user-facing parameter struct
    ScenarioContext         ← runtime bridge (Ark.World + SimCore.SimWorld + clock)
    build_world!            ← constructs a ScenarioContext from a ScenarioConfig
    reset_scenario!         ← tears down and rebuilds a ScenarioContext in-place
    serialize_world_ctx     ← full WorldSnapshot with panic + DES stats
"""

# ── Top-level imports (Julia requires `using` at file/module scope only) ───────

using Random: MersenneTwister
using LinearAlgebra: norm
using StaticArrays: SVector

using Ark: World, new_entity!, Query
using SimCore: SimWorld, SimStats
using SimCrowd:
    Position, Velocity, Force, Goal, WallSegment,
    AgentGeometry, MotionParams, SFMParams, ORCAParams,
    HybridFSMParams, AgentFSMState, CSMParams,
    AgentModel, SFMModel, ORCAModel, HybridModel,
    SimConfig, SimScene, JacobiCorrection, XPBDCorrection, VelocityImpulseParams,
    CPUNeighborSearch, ORCA_MODE, SFM_MODE

# ── Enum: crowd model ─────────────────────────────────────────────────────────

"""
    CrowdModel

Selects the force/velocity model used for all agents in the scenario.

| Value              | Model                              | When to use                      |
|:------------------ |:---------------------------------- |:--------------------------------- |
| `MODEL_SFM`        | Helbing Social Force Model         | Low density, simple scenarios     |
| `MODEL_ORCA`       | Optimal Reciprocal Collision Avoid | Open spaces, no body contact      |
| `MODEL_HYBRID_FSM` | HybridFSM: ORCA↔SFM auto-switch  | Dense evacuation (recommended)    |
| `MODEL_CSM`        | Collision-Free Speed Model (CSM)  | Bottleneck / corridor benchmarks  |
"""
@enum CrowdModel begin
    MODEL_SFM
    MODEL_ORCA
    MODEL_HYBRID_FSM
    MODEL_CSM
end

# ── Geometry helpers ──────────────────────────────────────────────────────────

"""
    DoorSpec

Describes one door opening in a room wall.

# Fields
- `wall`   : `:north`, `:south`, `:east`, `:west` — which wall the door is on
- `center` : fractional position along the wall ∈ (0,1); 0.5 = midpoint
- `width`  : door opening width (m)
"""
Base.@kwdef struct DoorSpec
    wall   :: Symbol  = :east
    center :: Float64 = 0.5   # fractional position along the wall
    width  :: Float64 = 1.0   # door width (m)
end

"""
    RoomGeometry

Axis-aligned rectangular room with one or more door openings.

# Fields
- `width`  : room width (m), x-axis
- `height` : room height (m), y-axis
- `doors`  : list of `DoorSpec` entries; at least one required

The room origin is at (0,0); corners at (0,0) and (width, height).
"""
Base.@kwdef struct RoomGeometry
    width  :: Float64          = 10.0
    height :: Float64          = 6.0
    doors  :: Vector{DoorSpec} = [DoorSpec()]
end

"""
    ScheduledEvent

A DES event that fires at a precise simulation time.

# Fields
- `time`   : simulation time (s) at which the event fires
- `type`   : event type symbol. Recognized by scenario event handlers:
    - `:evac_alarm`  → panic bump + goal redirect (4B-03)
    - `:close_door`  → block a door (wall segment inserted)
    - `:open_door`   → remove a door blockage
    - `:spawn_burst` → spawn `n` additional agents
- `params` : event-specific parameters as a `NamedTuple`

# Example
```julia
# Fire an evacuation alarm at t=60s
ScheduledEvent(time=60.0, type=:evac_alarm, params=(panic_bump=0.5,))
```
"""
Base.@kwdef struct ScheduledEvent
    time   :: Float64    = 0.0
    type   :: Symbol     = :noop
    params :: NamedTuple = NamedTuple()
end

# ── ScenarioConfig — complete user parameter surface ─────────────────────────

"""
    ScenarioConfig

**The complete user-facing parameter surface for a SimViz scenario.**

All fields are primitive Julia types (Float64, Int, Bool, Symbol, String)
so the struct round-trips cleanly through TOML / JSON / MsgPack.

Phase 7 note: this struct will be serialized as the "scenario spec" sent
over the WebSocket when a user saves or loads a simulation configuration.

# Parameter Groups

## Geometry
- `room`: `RoomGeometry` — room dimensions + door positions

## Agents
- `n_agents`:    number of pedestrian crowd agents to spawn
- `crowd_model`: `CrowdModel` enum — SFM / ORCA / HybridFSM / CSM
- `r_body`:      agent body radius (m). Typical: 0.25 m (Helbing 2000)
- `agent_mass`:  agent mass (kg). Typical: 80 kg

## Motion
- `v_pref`:      preferred walking speed (m/s). Normal: 1.2–1.4; panic: 3–4
- `sigma_noise`: velocity noise σ (m/s). 0.0 = deterministic; 0.1 = evacuation
- `tau_relax`:   relaxation time τ (s). Typical: 0.5 s (Helbing 1995)

## SFM / GCFM physics (MODEL_SFM and MODEL_HYBRID_FSM)
- `sfm_A`:       social force amplitude (N). Helbing default: 2000.0
- `sfm_B`:       social force decay length (m). Helbing default: 0.08
- `sfm_lambda`:  anisotropy factor λ ∈ [0,1]. 0=isotropic; 0.75=Helbing
- `sfm_mu`:      friction coefficient μ (Coulomb contact). 0=NoContact; Inf=Viscous
- `sfm_eta`:     GCF speed-adaptation η. 0.0 = pure Helbing (circular personal space)
- `sfm_tau_gap`: GCFM elliptical time gap (s). 0.0 = disable; >0 = GCFM-E

## HybridFSM thresholds (MODEL_HYBRID_FSM only)
- `rho_on`:         density threshold (ped/m²) for ORCA→SFM switch. Default: 3.5
- `rho_off`:        density threshold (ped/m²) for SFM→ORCA switch. Default: 2.5
- `density_radius`: neighbourhood radius for local density estimation (m)

## ORCA parameters (MODEL_ORCA and MODEL_HYBRID_FSM)
- `orca_tau`:           ORCA time horizon for agents (s). Typical: 1.5 s
- `orca_tau_wall`:      ORCA time horizon for obstacles (s). Typical: 1.0 s
- `orca_max_neighbors`: max ORCA neighbors considered per agent
- `orca_neighbor_dist`: ORCA neighbor search radius (m)
- `orca_responsibility`: ORCA responsibility ∈ [0,1]. 0.5=reciprocal; 1.0=unilateral

## CSM parameters (MODEL_CSM only)
- `csm_v0`:           CSM free-flow speed (m/s). Weidmann: 1.34
- `csm_T`:            CSM time gap (s)
- `csm_heading_tau`:  heading relaxation time constant (s). JuPedSim V3: 0.3
- `csm_strength_geo`: geometry contact constraint strength. 0.0=disabled; JuPedSim: 5.0

## Solver / integration
- `dt`:               simulation timestep (s). Typical: 0.05
- `dt_sfm`:           reduced timestep for SFM_MODE agents (s). Typical: 0.01
- `correction_iters`: position correction passes per step (0=disabled). Typical: 8
- `correction_alpha`: XPBD compliance α. 0.0=Jacobi; 1e-6=near-hard
- `vel_impulse_iters`: Maury-Venel PGS velocity impulse sweeps (0=off). Sprint 3Y: 8
- `max_speed`:        hard speed clamp post-integration (m/s). Default: 5.0

## Boundary / spawn
- `flux_boundary`: if `true`, agents removed at doors respawn at room interior edges
- `spawn_rate`:    agent/s for flux mode. 0.0 = no active spawning

## DES schedule
- `events`: `Vector{ScheduledEvent}` — timed events (alarm, spawn burst, door toggle)

## Scenario metadata
- `label`:       display name shown in the window title
- `description`: one-line description for the scenario selector menu
- `rng_seed`:    random seed for reproducible agent placement. 0 = random
"""
Base.@kwdef struct ScenarioConfig
    # ── Geometry ──────────────────────────────────────────────────────────────
    room             :: RoomGeometry   = RoomGeometry()

    # ── Agents ────────────────────────────────────────────────────────────────
    n_agents         :: Int            = 80
    crowd_model      :: CrowdModel     = MODEL_HYBRID_FSM
    r_body           :: Float64        = 0.25     # m; Helbing 2000 typical
    agent_mass       :: Float64        = 80.0     # kg

    # ── Motion ────────────────────────────────────────────────────────────────
    v_pref           :: Float64        = 1.34     # m/s; Weidmann 1993
    sigma_noise      :: Float64        = 0.10     # m/s; 0=deterministic
    tau_relax        :: Float64        = 0.50     # s; Helbing 1995

    # ── SFM / GCFM ────────────────────────────────────────────────────────────
    sfm_A            :: Float64        = 2000.0   # N; Helbing 1995
    sfm_B            :: Float64        = 0.08     # m; Helbing 1995
    sfm_lambda       :: Float64        = 0.75     # anisotropy; Helbing
    sfm_mu           :: Float64        = 0.5      # friction; 0=NoContact, Inf=Viscous
    sfm_eta          :: Float64        = 0.0      # GCF; 0=pure Helbing
    sfm_tau_gap      :: Float64        = 0.0      # s; 0=disable elliptical GCFM

    # ── HybridFSM thresholds ──────────────────────────────────────────────────
    rho_on           :: Float64        = 3.5      # ped/m²; ORCA→SFM trigger
    rho_off          :: Float64        = 2.5      # ped/m²; SFM→ORCA trigger
    density_radius   :: Float64        = 2.0      # m; neighbourhood for ρ

    # ── ORCA ──────────────────────────────────────────────────────────────────
    orca_tau             :: Float64    = 1.5      # s; agent time horizon
    orca_tau_wall        :: Float64    = 1.0      # s; wall time horizon
    orca_max_neighbors   :: Int        = 10
    orca_neighbor_dist   :: Float64    = 5.0      # m; search radius
    orca_responsibility  :: Float64    = 0.5      # 0.5=reciprocal, 1.0=unilateral

    # ── CSM ───────────────────────────────────────────────────────────────────
    csm_v0               :: Float64   = 1.34      # m/s; free-flow speed
    csm_T                :: Float64   = 1.0       # s; time gap
    csm_heading_tau      :: Float64   = 0.3       # s; JuPedSim V3 default
    csm_strength_geo     :: Float64   = 5.0       # geometry constraint; 0=off

    # ── Solver / integration ──────────────────────────────────────────────────
    dt                   :: Float64   = 0.05      # s; main timestep
    dt_sfm               :: Float64   = 0.01      # s; SFM_MODE sub-timestep
    correction_iters     :: Int       = 8         # 0 = disabled
    correction_alpha     :: Float64   = 0.0       # 0=Jacobi; 1e-6=XPBD near-hard
    vel_impulse_iters    :: Int       = 0         # 0 = disabled; Sprint 3Y: 8
    max_speed            :: Float64   = 5.0       # m/s; hard clamp

    # ── Boundary / spawn ──────────────────────────────────────────────────────
    flux_boundary        :: Bool      = false
    spawn_rate           :: Float64   = 0.0       # agent/s; 0 = no active spawn

    # ── Scheduled DES events ──────────────────────────────────────────────────
    events               :: Vector{ScheduledEvent} = ScheduledEvent[]

    # ── Metadata ──────────────────────────────────────────────────────────────
    label                :: String    = "Custom scenario"
    description          :: String    = "User-defined scenario"
    rng_seed             :: Int       = 0         # 0 = random
end

# ── ScenarioContext — runtime bridge ──────────────────────────────────────────

"""
    ScenarioContext

Holds all runtime state for one live simulation scenario:
- `ark_world`:   `Ark.World` — ECS agents (Position, Velocity, AgentFSMState, …)
- `sim_world`:   `SimCore.SimWorld` — DES agents, SimStats, zone queues
- `scene`:       `SimScene` — wraps `ark_world` + neighbor search + config
- `config`:      `ScenarioConfig` — the parameter set that built this context
- `sim_time`:    current simulated time (s)
- `boundaries`:  active `BoundaryCondition{Float32}` list — called after each
                 `step!` to remove/spawn agents (e.g. `AbsorbingBoundary`).
                 Populated by `build_world!` when `config.flux_boundary == true`.

The `SimCore.SimWorld` reference is needed to read `panic_level` (stored on
`CrowdAgent`) and `SimStats` (arrivals, busy time) in the stats panel.

Mutated in-place by `reset_scenario!`. GLMakie Observables in `SimVizState`
subscribe to slices of this object.
"""
mutable struct ScenarioContext
    ark_world  :: World
    sim_world  :: SimWorld
    scene      :: SimScene
    config     :: ScenarioConfig
    sim_time   :: Float64
    boundaries :: Vector{BoundaryCondition{Float32}}
end

# ── Internal: SimConfig builder ───────────────────────────────────────────────

function _make_simconfig(config::ScenarioConfig, ::Type{F}) where {F<:AbstractFloat}
    alg = config.correction_alpha ≈ 0.0 ?
        JacobiCorrection() :
        XPBDCorrection(; α = F(config.correction_alpha))
    vi = VelocityImpulseParams(F; n_iters = config.vel_impulse_iters)
    return SimConfig{F}(
        F(config.dt),
        F(config.dt_sfm),
        F(config.max_speed),
        config.correction_iters,
        F(1e-3),            # position correction tolerance
        alg,
        0,                  # sfm_contact_substeps (Sprint 3Y SFM sub-stepping)
        vi,
    )
end

# ── Internal: CPUNeighborSearch builder ───────────────────────────────────────

function _make_neighbor_search(config::ScenarioConfig, ::Type{F}) where {F<:AbstractFloat}
    # cell size = neighbor search radius; room bounds add 1 body radius margin
    r_search  = F(config.orca_neighbor_dist)
    grid_min  = SVector{2,F}(zero(F), zero(F))
    grid_max  = SVector{2,F}(F(config.room.width), F(config.room.height))
    return CPUNeighborSearch(config.n_agents, grid_min, grid_max, r_search)
end

# ── Internal: geometry helpers ────────────────────────────────────────────────

"""
    _wall_segments(room, ::Type{F})

Generate wall segment `(p1, p2)` tuples for a rectangular room, respecting
door gaps. Returns `Vector{Tuple{SVector{2,F}, SVector{2,F}}}`.
"""
function _wall_segments(room::RoomGeometry, ::Type{F}) where {F<:AbstractFloat}
    W = F(room.width)
    H = F(room.height)

    # Collect door gaps per wall — sorted by position along wall axis
    gaps = Dict{Symbol, Vector{Tuple{F,F}}}(
        :south => Tuple{F,F}[],
        :north => Tuple{F,F}[],
        :west  => Tuple{F,F}[],
        :east  => Tuple{F,F}[],
    )
    for d in room.doors
        wall_len = d.wall ∈ (:north, :south) ? room.width : room.height
        half = F(d.width / 2)
        ctr  = F(d.center * wall_len)
        push!(gaps[d.wall], (max(zero(F), ctr - half), min(F(wall_len), ctr + half)))
    end

    segs = Tuple{SVector{2,F}, SVector{2,F}}[]

    # Build segments along a wall, interrupted by door gaps.
    # `horizontal=true` → wall runs along x-axis (north/south)
    # `horizontal=false` → wall runs along y-axis (east/west)
    function _add_segs!(fixed::F, along_gaps, len, horizontal::Bool)
        sorted = sort(along_gaps)
        cursor = zero(F)
        for (lo, hi) in sorted
            if cursor < lo
                if horizontal
                    push!(segs, (SVector{2,F}(cursor, fixed), SVector{2,F}(lo, fixed)))
                else
                    push!(segs, (SVector{2,F}(fixed, cursor), SVector{2,F}(fixed, lo)))
                end
            end
            cursor = hi
        end
        if cursor < len
            if horizontal
                push!(segs, (SVector{2,F}(cursor, fixed), SVector{2,F}(len, fixed)))
            else
                push!(segs, (SVector{2,F}(fixed, cursor), SVector{2,F}(fixed, len)))
            end
        end
    end

    _add_segs!(zero(F), gaps[:south], W, true)  # south: y=0, x∈[0,W]
    _add_segs!(H,       gaps[:north], W, true)  # north: y=H, x∈[0,W]
    _add_segs!(zero(F), gaps[:west],  H, false) # west:  x=0, y∈[0,H]
    _add_segs!(W,       gaps[:east],  H, false) # east:  x=W, y∈[0,H]

    return segs
end

"""
    _door_centers(room, ::Type{F})

Return the 2D center point of each door in world coordinates.
Used to set agent goal = nearest door (evacuation scenario).
"""
function _door_centers(room::RoomGeometry, ::Type{F}) where {F<:AbstractFloat}
    # Goals are placed 0.5 m BEYOND the wall so agents must physically cross
    # the door plane before apply_boundary! removes them.
    offset = F(0.5)
    centers = SVector{2,F}[]
    for d in room.doors
        if d.wall == :east
            push!(centers, SVector{2,F}(F(room.width) + offset,  F(d.center * room.height)))
        elseif d.wall == :west
            push!(centers, SVector{2,F}(-offset,                  F(d.center * room.height)))
        elseif d.wall == :north
            push!(centers, SVector{2,F}(F(d.center * room.width), F(room.height) + offset))
        else  # :south
            push!(centers, SVector{2,F}(F(d.center * room.width), -offset))
        end
    end
    return centers
end

"""
    _random_positions(n, room, r_body, rng)

Sample `n` agent positions uniformly inside the room using rejection sampling
with a minimum inter-agent distance of `2 * r_body`. Falls back to a uniform
grid for agents that cannot be placed after 1000 attempts.
"""
function _random_positions(n::Int, room::RoomGeometry, r_body::F,
                            rng::MersenneTwister) where {F<:AbstractFloat}
    W = F(room.width)
    H = F(room.height)
    margin = r_body * F(1.1)
    x_lo, x_hi = margin, W - margin
    y_lo, y_hi = margin, H - margin

    positions = SVector{2,F}[]
    sizehint!(positions, n)
    min_d = F(2.0) * r_body

    for idx in 1:n
        placed = false
        for _ in 1:1000
            x = x_lo + (x_hi - x_lo) * F(rand(rng))
            y = y_lo + (y_hi - y_lo) * F(rand(rng))
            p = SVector{2,F}(x, y)
            ok = all(norm(p - q) >= min_d for q in positions)
            if ok
                push!(positions, p)
                placed = true
                break
            end
        end
        if !placed
            # Grid fallback: lay out remaining agents on a uniform grid
            cols = max(1, floor(Int, (x_hi - x_lo) / (F(2.1) * r_body)))
            row  = (idx - 1) ÷ cols
            col  = (idx - 1) % cols
            x = clamp(x_lo + col * F(2.1) * r_body, x_lo, x_hi)
            y = clamp(y_lo + row * F(2.1) * r_body, y_lo, y_hi)
            push!(positions, SVector{2,F}(x, y))
        end
    end
    return positions
end

# ── Model-specific world builders (internal) ──────────────────────────────────

function _build_sfm_world(config::ScenarioConfig, ::Type{F},
                          rng::MersenneTwister) where {F<:AbstractFloat}
    r  = F(config.r_body)
    m  = F(config.agent_mass)
    vp = F(config.v_pref)
    τ  = F(config.tau_relax)
    σ  = F(config.sigma_noise)

    world = World(
        Position{F}, Velocity{F}, AgentGeometry{F}, MotionParams{F},
        SFMParams{F}, AgentModel{SFMModel}, Goal{F}, Force{F}, WallSegment{F},
    )

    # Insert room walls
    for (p1, p2) in _wall_segments(config.room, F)
        new_entity!(world, (WallSegment{F}(p1, p2),))
    end

    geom   = AgentGeometry(r)
    motion = MotionParams(m, vp, τ, σ)
    sfm    = SFMParams(
        F(config.sfm_A), F(config.sfm_B), F(config.sfm_lambda), F(config.sfm_mu),
        F(config.sfm_eta), F(config.sfm_tau_gap), F(0.20), F(0.25),
    )
    door_cs = _door_centers(config.room, F)
    isempty(door_cs) && error("ScenarioConfig: room must have ≥1 door")

    positions = _random_positions(config.n_agents, config.room, r, rng)
    for pos in positions
        goal_pt = door_cs[argmin([norm(pos - dc) for dc in door_cs])]
        new_entity!(world, (
            Position{F}(pos), Velocity{F}(zero(SVector{2,F})),
            geom, motion, sfm, AgentModel{SFMModel}(),
            Goal{F}(goal_pt), Force{F}(zero(SVector{2,F})),
        ))
    end

    sim_cfg = _make_simconfig(config, F)
    search  = _make_neighbor_search(config, F)
    scene   = SimScene(world, search, sim_cfg)
    bcs = config.flux_boundary ?
        BoundaryCondition{Float32}[AbsorbingBoundary(0.75f0)] :
        BoundaryCondition{Float32}[]
    return ScenarioContext(world, SimWorld(), scene, config, 0.0, bcs)
end

function _build_orca_world(config::ScenarioConfig, ::Type{F},
                           rng::MersenneTwister) where {F<:AbstractFloat}
    r  = F(config.r_body)
    m  = F(config.agent_mass)
    vp = F(config.v_pref)
    τ  = F(config.tau_relax)

    world = World(
        Position{F}, Velocity{F}, AgentGeometry{F}, MotionParams{F},
        ORCAParams{F}, AgentModel{ORCAModel}, Goal{F}, Force{F}, WallSegment{F},
    )

    for (p1, p2) in _wall_segments(config.room, F)
        new_entity!(world, (WallSegment{F}(p1, p2),))
    end

    geom   = AgentGeometry(r)
    motion = MotionParams(m, vp, τ)   # σ not used by ORCA
    orca   = ORCAParams(
        F(config.orca_tau), F(config.orca_tau_wall),
        config.orca_max_neighbors, F(config.orca_neighbor_dist),
        r, vp, τ, m, F(config.orca_responsibility),
    )
    door_cs = _door_centers(config.room, F)
    isempty(door_cs) && error("ScenarioConfig: room must have ≥1 door")

    positions = _random_positions(config.n_agents, config.room, r, rng)
    for pos in positions
        goal_pt = door_cs[argmin([norm(pos - dc) for dc in door_cs])]
        new_entity!(world, (
            Position{F}(pos), Velocity{F}(zero(SVector{2,F})),
            geom, motion, orca, AgentModel{ORCAModel}(),
            Goal{F}(goal_pt), Force{F}(zero(SVector{2,F})),
        ))
    end

    sim_cfg = _make_simconfig(config, F)
    search  = _make_neighbor_search(config, F)
    scene   = SimScene(world, search, sim_cfg)
    bcs = config.flux_boundary ?
        BoundaryCondition{Float32}[AbsorbingBoundary(0.75f0)] :
        BoundaryCondition{Float32}[]
    return ScenarioContext(world, SimWorld(), scene, config, 0.0, bcs)
end

function _build_hybrid_world(config::ScenarioConfig, ::Type{F},
                             rng::MersenneTwister) where {F<:AbstractFloat}
    r  = F(config.r_body)
    m  = F(config.agent_mass)
    vp = F(config.v_pref)
    τ  = F(config.tau_relax)
    σ  = F(config.sigma_noise)

    sfm_p  = SFMParams(
        F(config.sfm_A), F(config.sfm_B), F(config.sfm_lambda), F(config.sfm_mu),
        F(config.sfm_eta), F(config.sfm_tau_gap), F(0.20), F(0.25),
    )
    orca_p = ORCAParams(
        F(config.orca_tau), F(config.orca_tau_wall),
        config.orca_max_neighbors, F(config.orca_neighbor_dist),
        r, vp, τ, m, F(config.orca_responsibility),
    )
    fsm_p  = HybridFSMParams{F}(
        ρ_on           = F(config.rho_on),
        ρ_off          = F(config.rho_off),
        density_radius = F(config.density_radius),
        sfm_params     = sfm_p,
        orca_params    = orca_p,
    )

    world = World(
        Position{F}, Velocity{F}, AgentGeometry{F}, MotionParams{F},
        HybridFSMParams{F}, AgentFSMState{F}, Goal{F}, Force{F}, WallSegment{F},
    )

    for (p1, p2) in _wall_segments(config.room, F)
        new_entity!(world, (WallSegment{F}(p1, p2),))
    end

    geom    = AgentGeometry(r)
    motion  = MotionParams(m, vp, τ, σ)
    door_cs = _door_centers(config.room, F)
    isempty(door_cs) && error("ScenarioConfig: room must have ≥1 door")

    positions = _random_positions(config.n_agents, config.room, r, rng)
    for pos in positions
        goal_pt = door_cs[argmin([norm(pos - dc) for dc in door_cs])]
        new_entity!(world, (
            Position{F}(pos), Velocity{F}(zero(SVector{2,F})),
            geom, motion, fsm_p, AgentFSMState{F}(),
            Goal{F}(goal_pt), Force{F}(zero(SVector{2,F})),
        ))
    end

    sim_cfg = _make_simconfig(config, F)
    search  = _make_neighbor_search(config, F)
    scene   = SimScene(world, search, sim_cfg)
    bcs = config.flux_boundary ?
        BoundaryCondition{Float32}[AbsorbingBoundary(0.75f0)] :
        BoundaryCondition{Float32}[]
    return ScenarioContext(world, SimWorld(), scene, config, 0.0, bcs)
end

function _build_csm_world(config::ScenarioConfig, ::Type{F},
                          rng::MersenneTwister) where {F<:AbstractFloat}
    r  = F(config.r_body)

    csm_p = CSMParams{F}(
        v0                     = F(config.csm_v0),
        T                      = F(config.csm_T),
        radius                 = r,
        heading_relaxation_tau = F(config.csm_heading_tau),
        strength_geo           = F(config.csm_strength_geo),
    )

    world = World(
        Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, WallSegment{F},
    )

    for (p1, p2) in _wall_segments(config.room, F)
        new_entity!(world, (WallSegment{F}(p1, p2),))
    end

    door_cs = _door_centers(config.room, F)
    isempty(door_cs) && error("ScenarioConfig: room must have ≥1 door")

    positions = _random_positions(config.n_agents, config.room, r, rng)
    for pos in positions
        goal_pt = door_cs[argmin([norm(pos - dc) for dc in door_cs])]
        new_entity!(world, (
            Position{F}(pos), Velocity{F}(zero(SVector{2,F})),
            Goal{F}(goal_pt), csm_p,
        ))
    end

    sim_cfg = _make_simconfig(config, F)
    # CSM uses a wider search radius (v0×T×safety factor) to catch approaching agents
    r_search_csm = F(max(config.orca_neighbor_dist, config.csm_v0 * config.csm_T * 3.0))
    grid_min = SVector{2,F}(zero(F), zero(F))
    grid_max = SVector{2,F}(F(config.room.width), F(config.room.height))
    search   = CPUNeighborSearch(config.n_agents, grid_min, grid_max, r_search_csm)
    scene    = SimScene(world, search, sim_cfg)
    bcs = config.flux_boundary ?
        BoundaryCondition{Float32}[AbsorbingBoundary(0.75f0)] :
        BoundaryCondition{Float32}[]
    return ScenarioContext(world, SimWorld(), scene, config, 0.0, bcs)
end

# ── build_world! ─────────────────────────────────────────────────────────────

"""
    build_world!(config::ScenarioConfig) :: ScenarioContext

Build a complete `ScenarioContext` from a `ScenarioConfig`:

1. Creates an `Ark.World` with the correct component archetypes for the chosen model
2. Inserts `WallSegment` entities from `RoomGeometry` (with door gaps)
3. Spawns `n_agents` crowd agents at random non-overlapping positions
4. Sets each agent's `Goal` to the nearest door center
5. Wraps world + `CPUNeighborSearch` + `SimConfig` into a `SimScene`
6. Creates an empty `SimCore.SimWorld` for DES stats and panic level bridge

Returns a `ScenarioContext` ready to step with `step!(ctx.scene)`.

!!! note "Crowd model dispatch"
    The function dispatches on `config.crowd_model` to build the correct ECS
    archetype. Each model requires different component sets:
    - `MODEL_SFM`:        Position, Velocity, AgentGeometry, MotionParams, SFMParams, AgentModel{SFMModel}, Goal, Force
    - `MODEL_ORCA`:       Position, Velocity, AgentGeometry, MotionParams, ORCAParams, AgentModel{ORCAModel}, Goal, Force
    - `MODEL_HYBRID_FSM`: Position, Velocity, AgentGeometry, MotionParams, HybridFSMParams, AgentFSMState, Goal, Force
    - `MODEL_CSM`:        Position, Velocity, Goal, CSMParams
"""
function build_world!(config::ScenarioConfig) :: ScenarioContext
    F   = Float32
    rng = config.rng_seed == 0 ? MersenneTwister() : MersenneTwister(config.rng_seed)

    if config.crowd_model == MODEL_SFM
        return _build_sfm_world(config, F, rng)
    elseif config.crowd_model == MODEL_ORCA
        return _build_orca_world(config, F, rng)
    elseif config.crowd_model == MODEL_HYBRID_FSM
        return _build_hybrid_world(config, F, rng)
    else  # MODEL_CSM
        return _build_csm_world(config, F, rng)
    end
end

# ── reset_scenario! ───────────────────────────────────────────────────────────

"""
    reset_scenario!(ctx::ScenarioContext; config = ctx.config) :: ScenarioContext

Tear down the current simulation and rebuild from `config` (defaults to
`ctx.config` if not provided). Modifies `ctx` in-place and returns it.

Used by the Reset button in the controls panel (4A-06).
"""
function reset_scenario!(ctx::ScenarioContext;
                          config::ScenarioConfig = ctx.config) :: ScenarioContext
    new_ctx        = build_world!(config)
    ctx.ark_world  = new_ctx.ark_world
    ctx.sim_world  = new_ctx.sim_world
    ctx.scene      = new_ctx.scene
    ctx.config     = new_ctx.config
    ctx.sim_time   = 0.0
    ctx.boundaries = new_ctx.boundaries
    return ctx
end

# ── serialize_world_ctx — full WorldSnapshot with panic + DES stats ───────────

"""
    serialize_world_ctx(ctx::ScenarioContext) :: WorldSnapshot

Full version of `serialize_world` that also populates:
- `n_des_agents` — from `SimCore.SimWorld.crowd_agents` dict length
- `stats`        — from `SimCore.SimWorld.stats` (SimStats)

For Phase 4, `panic_levels` remain stubbed as `0f0` — they require a
live `CrowdAgent.panic_level` bridge that is wired in Phase 4B-03.
"""
function serialize_world_ctx(ctx::ScenarioContext) :: WorldSnapshot
    # Base serialization from Ark ECS
    snap = serialize_world(ctx.ark_world, ctx.sim_time)

    # Overlay SimCore stats (populated in 4B DES scenarios)
    sc   = ctx.sim_world.stats
    stats_snap = (
        total_events     = sc.total_events,
        total_arrivals   = sc.total_arrivals,
        total_departures = sc.total_departures,
        busy_time        = sc.busy_time,
        elapsed_sim_time = ctx.sim_time,
    )

    return (
        sim_time        = snap.sim_time,
        positions       = snap.positions,
        velocities      = snap.velocities,
        panic_levels    = snap.panic_levels,   # TODO 4B-03: bridge CrowdAgent.panic_level
        fsm_modes       = snap.fsm_modes,
        local_densities = snap.local_densities,
        n_agents        = snap.n_agents,
        n_des_agents    = length(ctx.sim_world.crowd_agents),
        stats           = stats_snap,
    )
end
