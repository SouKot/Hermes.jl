module SimCrowd

using StaticArrays
using LinearAlgebra
using KernelAbstractions
using Eikonal
using Ark

using SimCore

export Position, Velocity, AgentGeometry, MotionParams, SFMParams, Goal, Force, WallSegment
export from_agent_params
export goal_seeking_force, agent_repulsion, wall_repulsion, gcf_force
export AbstractNeighborSearch, RadixSpatialHash, CPUNeighborSearch, build_grid!, get_neighbors
export NavigationField, build_navigation_field, get_desired_direction
export update_navigation_system!, update_social_forces_system!, integrate_physics_system!
export ORCAParams, update_orca_system!
export ContactModel, NoContact, Coulomb, Viscous
# §2.1 ForceModel trait
export ForceModel, SFMModel, ORCAModel, HybridModel, AgentModel
# §2.4 SimConfig + SimScene
export SimConfig, SimScene, step!, run!

# Components
struct Position{F<:AbstractFloat}
    p::SVector{2,F}
end

struct Velocity{F<:AbstractFloat}
    v::SVector{2,F}
end

struct Force{F<:AbstractFloat}
    f::SVector{2,F}
end

"""
    AgentGeometry{F<:AbstractFloat}

Physical geometry of an agent: personal space and body collision radii.

Used by:
- Social force kernel (SFM agent-agent + wall repulsion)
- Wall navigation

Fields:
- `social_radius`:    personal space radius (m). Agents start repelling each other at 2×r.
- `collision_radius`: body radius (m). Physical contact forces activate at r_i + r_j ≥ d.
                      Standard: `2/3 × social_radius` (Helbing 2000). Set 0 for NoContact.
"""
struct AgentGeometry{F<:AbstractFloat}
    social_radius::F
    collision_radius::F
end

# Convenience: auto collision_radius = 2/3 × social_radius (Helbing 2000 standard body ratio)
AgentGeometry(sr::F) where {F<:AbstractFloat} = AgentGeometry(sr, sr * F(2/3))

"""
    MotionParams{F<:AbstractFloat}

Locomotion parameters of an agent: mass, preferred speed, relaxation time, and velocity noise.

Used by:
- Physics integrator (`mass` → acceleration, `σ` → SDE fluctuation term)
- Goal-seeking and navigation forces (computes `mass × (v_pref⋅ê − v) / τ`)
- ORCA force conversion (mass, v_pref, τ for velocity → force)
"""
struct MotionParams{F<:AbstractFloat}
    mass::F    # body mass (kg). Typical pedestrian: 80 kg.
    v_pref::F  # preferred walking speed (m/s). Normal: 1.2–1.4 m/s; panic: 3–4 m/s.
    τ::F       # relaxation time (s). Helbing 2000: 0.5 s.
    σ::F       # velocity diffusion (m/s). 0.10 evacuation, 0.05 normal, 0.0 deterministic.
end

# Convenience: σ defaults to 0.1 m/s (Helbing 2000 evacuation calibration)
MotionParams(mass::F, v_pref::F, τ::F) where {F<:AbstractFloat} = MotionParams(mass, v_pref, τ, F(0.1))

"""
    SFMParams{F<:AbstractFloat}

Social Force Model (Helbing & Molnár 1995 / Helbing, Farkas & Vicsek 2000) parameters.

Used only by the SFM force kernel. Agents using purely ORCA do not need this component.

Fields:
- `A`: social repulsion strength (N).  Helbing 2000: 2000 N.
- `B`: repulsion decay length (m).     Helbing 2000: 0.08 m.
- `λ`: anisotropy factor ∈ [0,1].     Helbing 2000: 0.5. λ=1 isotropic; λ=0.5 half attention behind.
- `μ`: Coulomb friction cap. 0=NoContact, Inf=Viscous (exact Helbing), 0.5=normal walking.
- `η`: §1.4 GCF speed-adaptation factor (s). 0.0 = Helbing (disabled), 0.5 = Chraibi 2010.
         When η>0, the personal space range grows linearly with agent speed:
         `D_i = social_radius + η × ‖v_i‖`, giving elliptical personal space that stretches ahead.
"""
struct SFMParams{F<:AbstractFloat}
    A::F
    B::F
    λ::F
    μ::F
    η::F   # §1.4 GCF speed-adaptation factor; 0.0 = Helbing behavior (GCF disabled)
end

# Backward-compatible 4-arg constructor: η defaults to 0.0 (Helbing, GCF disabled)
SFMParams(A::F, B::F, λ::F, μ::F) where {F<:AbstractFloat} = SFMParams(A, B, λ, μ, zero(F))

# Convenience: supply only μ, use Helbing 2000 defaults for A, B, λ, η=0
SFMParams(μ::F) where {F<:AbstractFloat} = SFMParams(F(2000), F(0.08), F(0.5), μ, zero(F))
# All Helbing 2000 defaults (A=2000, B=0.08, λ=0.5, μ=0.5, η=0)
SFMParams{F}() where {F<:AbstractFloat} = SFMParams(F(2000), F(0.08), F(0.5), F(0.5), zero(F))

"""
    ContactModel

Specifies how body-contact forces are modeled in the Helbing SFM.
The model is encoded in `SFMParams.μ` and `AgentGeometry.collision_radius` at construction time:

| ContactModel | `collision_radius`  | `μ` value | Physical meaning |
|--------------|---------------------|-----------|------------------|
| `NoContact`  | 0 (disabled)        | 0.0       | Social force only — low-density normal walking |
| `Coulomb`    | `2/3 × social_r`   | supplied  | Coulomb-capped viscous friction — default, good for lane formation |
| `Viscous`    | `2/3 × social_r`   | Inf       | Pure viscous κ×g×Δv_t — Helbing 2000 exact; enables Faster-is-Slower |
"""
@enum ContactModel::Int32 begin
    NoContact   # collision_radius = 0; μ = 0  → no body contact forces
    Coulomb     # collision_radius = 2/3 r; μ ∈ (0, ∞) → Coulomb-capped friction
    Viscous     # collision_radius = 2/3 r; μ = Inf → pure viscous, Helbing exact
end

"""
    from_agent_params(social_radius, mass, v_pref, τ [, μ=0.5 [, σ=0.1]]) → (AgentGeometry, MotionParams, SFMParams)
    from_agent_params(social_radius, collision_radius, mass, v_pref, τ, μ, σ)  → (AgentGeometry, MotionParams, SFMParams)

# DEPRECATED migration helper for §2.2

Converts old `AgentParams(…)` call patterns to the 3 ECS components introduced in §2.2.
Use by splatting the result directly into `new_entity!`:

```julia
new_entity!(world, (pos, vel, from_agent_params(r, 80f0, v0, τ, 0.5f0)…, goal, force))
```

This helper exists to ease migration. When all call sites use explicit `AgentGeometry`,
`MotionParams`, and `SFMParams` constructors, this helper can be removed.

See: §2.2 in `simcrowd_improvement_plan.md`.
"""
# 4/5-arg: auto cr = sr×2/3, σ = 0.1 default; η=0.0 (Helbing, GCF disabled)
function from_agent_params(sr::F, mass::F, v_pref::F, τ::F, μ::F=F(0.5);
                            σ::F=F(0.1), A::F=F(2000), B::F=F(0.08), λ::F=F(0.5),
                            η::F=zero(F)) where {F<:AbstractFloat}
    return (AgentGeometry(sr, sr * F(2/3)), MotionParams(mass, v_pref, τ, σ), SFMParams(A, B, λ, μ, η))
end

# 6-arg positional: auto cr = sr×2/3, explicit σ
function from_agent_params(sr::F, mass::F, v_pref::F, τ::F, μ::F, σ::F;
                            A::F=F(2000), B::F=F(0.08), λ::F=F(0.5),
                            η::F=zero(F)) where {F<:AbstractFloat}
    return (AgentGeometry(sr, sr * F(2/3)), MotionParams(mass, v_pref, τ, σ), SFMParams(A, B, λ, μ, η))
end

# 7-arg: explicit collision_radius and σ
function from_agent_params(sr::F, cr::F, mass::F, v_pref::F, τ::F, μ::F, σ::F;
                            A::F=F(2000), B::F=F(0.08), λ::F=F(0.5),
                            η::F=zero(F)) where {F<:AbstractFloat}
    return (AgentGeometry(sr, cr), MotionParams(mass, v_pref, τ, σ), SFMParams(A, B, λ, μ, η))
end

struct ORCAParams{F<:AbstractFloat}
    time_horizon::F
    time_horizon_obst::F
    max_neighbors::Int
    neighbor_dist::F
    radius::F
    v_pref::F
    τ::F
    mass::F
    responsibility::F  # §1.8: fraction of ORCA velocity-change taken by agent i ∈ [0,1]
                       # 0.5 = reciprocal ORCA (standard — both agents share equally)
                       # 1.0 = full (use for walls or when j is known non-cooperative)
                       # values ∈ (0.5, 1.0] make agent i more conservative (safer under uncertainty)
end

"""
    ORCAParams(time_horizon, time_horizon_obst, max_neighbors, neighbor_dist,
               radius, v_pref, τ, mass [, responsibility=0.5])

Constructors for `ORCAParams`. The 8-arg form defaults `responsibility = 0.5` (standard
reciprocal ORCA). Pass `responsibility = 1.0` for agents that cannot rely on neighbours
to cooperate (e.g., robot in a pedestrian crowd, or agent approaching a wall boundary).
"""
# 8-arg backward-compatible: defaults responsibility = 0.5 (reciprocal ORCA)
ORCAParams(th::F, tho::F, mn::Int, nd::F, r::F, vp::F, τ::F, m::F) where {F<:AbstractFloat} =
    ORCAParams(th, tho, mn, nd, r, vp, τ, m, F(0.5))

struct WallSegment{F<:AbstractFloat}
    p1::SVector{2,F}
    p2::SVector{2,F}
end

struct Goal{F<:AbstractFloat}
    g::SVector{2,F}
end

# ── §2.4 SimConfig (defined here so physics.jl can reference it) ──────────────────

"""
    SimConfig{F<:AbstractFloat}

Simulation-level parameters shared across all system update calls.
Eliminates hardcoded constants from `physics.jl` and `social.jl`.

Fields:
- `dt`:        timestep (s). Default: 0.05 s (20 Hz — good for SFM; use 0.01 s for ORCA).
- `max_speed`: hard speed clamp applied after integration (m/s). Default: 5.0 (panic speed).
"""
struct SimConfig{F<:AbstractFloat}
    dt::F
    max_speed::F
end

# Convenience constructors
SimConfig{F}() where {F<:AbstractFloat} = SimConfig(F(0.05), F(5.0))
SimConfig() = SimConfig{Float32}()
SimConfig(dt::F) where {F<:AbstractFloat} = SimConfig(dt, F(5.0))

include("forces.jl")
include("neighbor_search.jl")
include("navigation.jl")

# Systems
include("systems/physics.jl")
include("systems/social.jl")
include("systems/orca_math.jl")
include("systems/orca.jl")
include("systems/orca_cpu.jl")

# ── §2.1 ForceModel Trait ─────────────────────────────────────────────────────
# Marker types that declare which force model an agent uses.
# Systems do NOT require this tag — they filter via Query on SFMParams/ORCAParams.
# AgentModel is additive metadata for introspection, logging, and future dispatch.

"""Abstract supertype for all force model markers."""
abstract type ForceModel end

"""Marker: agent uses the Helbing Social Force Model (SFM) + `SFMParams`."""
struct SFMModel  <: ForceModel end

"""Marker: agent uses Optimal Reciprocal Collision Avoidance (ORCA) + `ORCAParams`."""
struct ORCAModel <: ForceModel end

"""Marker: agent uses both SFM social forces and ORCA avoidance simultaneously."""
struct HybridModel <: ForceModel end

"""
    AgentModel{M<:ForceModel}

Zero-field ECS component that tags an agent with its force model intent.

This is OPTIONAL — existing systems query `SFMParams` / `ORCAParams` directly and
do not require this tag. Add it for introspection, debugging, or future dispatch:

```julia
new_entity!(world, (pos, vel, geom, motion, sfm_params, AgentModel{SFMModel}(), goal, force))
```
"""
struct AgentModel{M<:ForceModel} end

# ── §2.4 SimScene (defined after includes since it references NavigationField etc.) ───


"""
    SimScene{F, S<:AbstractNeighborSearch, N}

Top-level scene object that owns a simulation world, neighbor search, optional
navigation field, and configuration. Call `step!` or `run!` to advance it.

Creating a scene:
```julia
scene = SimScene(world, search, config)              # no nav field
scene = SimScene(world, search, nav_field, config)   # with nav field
```

Running a scene:
```julia
step!(scene)          # advance one timestep
run!(scene, 60.0f0)   # advance for T simulation seconds
```
"""
struct SimScene{F<:AbstractFloat, S<:AbstractNeighborSearch, N}
    world::World
    search::S
    nav_field::N    # Union{NavigationField{F}, Nothing} — Nothing for ORCA-only worlds
    config::SimConfig{F}
end

# Constructor without nav field (ORCA-only or manually-managed navigation)
SimScene(world::World, search::S, config::SimConfig{F}) where {F, S<:AbstractNeighborSearch} =
    SimScene{F, S, Nothing}(world, search, nothing, config)

# Constructor with nav field (SFM worlds with automatic Eikonal-based goal updates)
SimScene(world::World, search::S, nav_field::NavigationField{F}, config::SimConfig{F}) where {F, S<:AbstractNeighborSearch} =
    SimScene{F, S, NavigationField{F}}(world, search, nav_field, config)

"""
    step!(scene::SimScene)

Advance the simulation by one timestep (`scene.config.dt`).

System order:
1. Navigation update (if nav_field is set) — updates `Goal` components from the potential field
2. SFM social forces — `update_social_forces_system!` (resets + accumulates Force)
3. ORCA velocity update — `update_orca_system_cpu!` (for ORCA-tagged agents)
4. Physics integration — `integrate_physics_system!` (vel/pos update + speed clamp)
"""
function step!(scene::SimScene{F}) where {F}
    dt = scene.config.dt
    # 1. Navigation: update Goal components from Eikonal field (if present)
    if scene.nav_field !== nothing
        update_navigation_system!(scene.world, scene.nav_field)
    end
    # Guard: Ark.Query throws ArgumentError if a component type was never registered
    # (i.e. the world has no entities). Return early rather than crashing.
    local n_force::Int
    try
        n_force = count_entities(Query(scene.world, (Force{F},)))
    catch e
        e isa ArgumentError && return scene
        rethrow()
    end
    n_force == 0 && return scene
    # 2. Reset Force components to zero before accumulation
    for (_, force_col) in Query(scene.world, (Force{F},))
        for i in eachindex(force_col)
            force_col[i] = Force(zero(SVector{2,F}))
        end
    end
    # 3. SFM agent-agent + wall forces (only for agents with SFMParams)
    local n_sfm::Int
    try; n_sfm = count_entities(Query(scene.world, (SFMParams{F},))); catch; n_sfm = 0; end
    if n_sfm > 0
        update_social_forces_system!(scene.world, scene.search, CPU())
    end
    # 4. ORCA velocity update (only for agents with ORCAParams)
    local n_orca::Int
    try; n_orca = count_entities(Query(scene.world, (ORCAParams{F},))); catch; n_orca = 0; end
    if n_orca > 0
        update_orca_system_cpu!(scene.world, dt)
    end
    # 5. Integrate: velocity + position update with speed clamp from config
    integrate_physics_system!(scene.world, scene.config)
    return scene
end

"""
    run!(scene::SimScene, T)

Run the simulation for `T` seconds of simulated time, calling `step!` each timestep.
Returns `scene` for chaining.
"""
function run!(scene::SimScene{F}, T::Real) where {F}
    t    = zero(F)
    T_F  = F(T)
    dt   = scene.config.dt
    while t < T_F
        step!(scene)
        t += dt
    end
    return scene
end

end
