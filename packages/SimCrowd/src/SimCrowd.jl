module SimCrowd

using StaticArrays
using LinearAlgebra
using KernelAbstractions
using Eikonal
using Ark

using SimCore

export Position, Velocity, AgentGeometry, MotionParams, SFMParams, Goal, Force, WallSegment
export from_agent_params
export goal_seeking_force, agent_repulsion, wall_repulsion
export AbstractNeighborSearch, RadixSpatialHash, CPUNeighborSearch, build_grid!, get_neighbors
export NavigationField, build_navigation_field, get_desired_direction
export update_navigation_system!, update_social_forces_system!, integrate_physics_system!
export ORCAParams, update_orca_system!
export ContactModel, NoContact, Coulomb, Viscous

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
"""
struct SFMParams{F<:AbstractFloat}
    A::F
    B::F
    λ::F
    μ::F
end

# Convenience: supply only μ, use Helbing 2000 defaults for A, B, λ
SFMParams(μ::F) where {F<:AbstractFloat} = SFMParams(F(2000), F(0.08), F(0.5), μ)
# All Helbing 2000 defaults (A=2000, B=0.08, λ=0.5, μ=0.5)
SFMParams{F}() where {F<:AbstractFloat} = SFMParams(F(2000), F(0.08), F(0.5), F(0.5))

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
# 4/5-arg: auto cr = sr×2/3, σ = 0.1 default
function from_agent_params(sr::F, mass::F, v_pref::F, τ::F, μ::F=F(0.5);
                            σ::F=F(0.1), A::F=F(2000), B::F=F(0.08), λ::F=F(0.5)) where {F<:AbstractFloat}
    return (AgentGeometry(sr, sr * F(2/3)), MotionParams(mass, v_pref, τ, σ), SFMParams(A, B, λ, μ))
end

# 6-arg positional: auto cr = sr×2/3, explicit σ
function from_agent_params(sr::F, mass::F, v_pref::F, τ::F, μ::F, σ::F;
                            A::F=F(2000), B::F=F(0.08), λ::F=F(0.5)) where {F<:AbstractFloat}
    return (AgentGeometry(sr, sr * F(2/3)), MotionParams(mass, v_pref, τ, σ), SFMParams(A, B, λ, μ))
end

# 7-arg: explicit collision_radius and σ
function from_agent_params(sr::F, cr::F, mass::F, v_pref::F, τ::F, μ::F, σ::F;
                            A::F=F(2000), B::F=F(0.08), λ::F=F(0.5)) where {F<:AbstractFloat}
    return (AgentGeometry(sr, cr), MotionParams(mass, v_pref, τ, σ), SFMParams(A, B, λ, μ))
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

include("forces.jl")
include("neighbor_search.jl")
include("navigation.jl")

# Systems
include("systems/physics.jl")
include("systems/social.jl")
include("systems/orca_math.jl")
include("systems/orca.jl")
include("systems/orca_cpu.jl")

end
