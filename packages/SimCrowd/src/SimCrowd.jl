module SimCrowd

using StaticArrays
using LinearAlgebra
using KernelAbstractions
using Eikonal
using Ark

using SimCore

export Position, Velocity, AgentParams, Goal, Force, WallSegment
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

struct AgentParams{F<:AbstractFloat}
    social_radius::F
    collision_radius::F
    mass::F
    v_pref::F
    τ::F
    μ::F
    σ::F      # velocity diffusion (Helbing SDE noise, m/s).
              # 0.10 m/s — Helbing 2000 evacuation calibration (arch-break in ~1.5 s)
              # 0.05 m/s — Helbing 1995 normal pedestrian flow
              # 0.00     — deterministic (disable stochastic fluctuation term)
    A::F      # social repulsion strength (N) — Helbing 2000: 2000 N
    B::F      # social repulsion decay length (m) — Helbing 2000: 0.08 m
    λ::F      # anisotropy: attention behind vs. ahead — Helbing 2000: 0.5
              # λ=1 → isotropic; λ=0.5 → agents pay half-attention to threats from behind
end

"""
    AgentParams(sr, cr, m, vp, τ, μ, σ, A, B, λ) → 10-arg full struct literal
    AgentParams(sr, cr, m, vp, τ, μ, σ)           → 7-arg  (A=2000, B=0.08, λ=0.5)
    AgentParams(sr, m, vp, τ, μ, σ)               → 6-arg  (auto cr, A=2000, B=0.08, λ=0.5)
    AgentParams(sr, m, vp, τ, μ)                  → 5-arg  (auto cr, σ=0.1, A=2000, B=0.08, λ=0.5)
    AgentParams(sr, m, vp, τ)                     → 4-arg  (all defaults)

Outer constructors for ergonomic construction.

`collision_radius = social_radius × 2/3` is the standard Helbing body/personal-space ratio.

`μ = 0.5` is the Coulomb friction cap for normal pedestrian walking (Helbing 2000, Table I).
For panic/evacuation scenarios using Helbing's pure viscous friction set `μ = Inf` or use
the `ContactModel` constructor.

`σ = 0.1 m/s` (Helbing 2000 evacuation default). For normal low-density flow use 0.05 m/s.
Set to 0 for deterministic simulations.

`A = 2000 N`, `B = 0.08 m`, `λ = 0.5` are Helbing 2000 calibrated social force parameters.
Vary for heterogeneous crowds: Johansson 2007 found 2× variation across countries/cultures.

**BUG NOTE (historical):** 4-arg constructor previously defaulted `μ = F(1.2e5)` (body
stiffness constant `k`, not friction coefficient). Fixed 2026-08-12.
"""
# 7-arg: (sr, cr, m, vp, τ, μ, σ) — fills in Helbing defaults for A, B, λ.
# Catches the common full-constructor pattern where cr is specified explicitly.
AgentParams(sr::F, cr::F, m::F, vp::F, τ::F, μ::F, σ::F) where {F<:AbstractFloat} =
    AgentParams(sr, cr, m, vp, τ, μ, σ, F(2000), F(0.08), F(0.5))

# 6-arg: (sr, m, vp, τ, μ, σ) — auto collision_radius = 2/3 × social_radius
AgentParams(sr::F, m::F, vp::F, τ::F, μ::F, σ::F) where {F<:AbstractFloat} =
    AgentParams(sr, sr * F(2/3), m, vp, τ, μ, σ, F(2000), F(0.08), F(0.5))

# 5-arg: (sr, m, vp, τ, μ) — σ defaults to 0.1 m/s (Helbing 2000 evacuation)
AgentParams(sr::F, m::F, vp::F, τ::F, μ::F) where {F<:AbstractFloat} =
    AgentParams(sr, sr * F(2/3), m, vp, τ, μ, F(0.1), F(2000), F(0.08), F(0.5))

# 4-arg: (sr, m, vp, τ) — all defaults: μ=0.5, σ=0.1, A=2000, B=0.08, λ=0.5
AgentParams(sr::F, m::F, vp::F, τ::F) where {F<:AbstractFloat} =
    AgentParams(sr, sr * F(2/3), m, vp, τ, F(0.5), F(0.1), F(2000), F(0.08), F(0.5))

"""
    ContactModel

Specifies how body-contact forces are modeled in the Helbing SFM.
The model is encoded in `AgentParams.μ` at construction time:

| ContactModel | `collision_radius`  | `μ` value | Physical meaning |
|--------------|---------------------|-----------|------------------|
| `NoContact`  | 0 (disabled)        | 0.0       | Social force only — low-density normal walking (svenkreiss approach) |
| `Coulomb`    | `2/3 × social_r`   | supplied  | Coulomb-capped viscous friction — default, good for lane formation |
| `Viscous`    | `2/3 × social_r`   | Inf       | Pure viscous κ×g×Δv_t — Helbing 2000 exact; enables Faster-is-Slower effect |

Usage:
```julia
p = AgentParams(0.25f0, 80f0, 1.4f0, 0.5f0, NoContact)          # social force only
p = AgentParams(0.25f0, 80f0, 4.0f0, 0.5f0, Viscous)             # FiS-capable
p = AgentParams(0.25f0, 80f0, 1.4f0, 0.5f0, Coulomb, 0.3f0)      # custom μ
```
"""
@enum ContactModel::Int32 begin
    NoContact   # collision_radius = 0; μ = 0  → no body contact forces
    Coulomb     # collision_radius = 2/3 r; μ ∈ (0, ∞) → Coulomb-capped friction
    Viscous     # collision_radius = 2/3 r; μ = Inf → pure viscous, Helbing exact
end

"""
    AgentParams(social_radius, mass, v_pref, τ, model::ContactModel [, μ=0.5f0 [, σ=0.1f0]])

Convenience constructor that sets both `collision_radius` and `μ` from a `ContactModel`.
A, B, λ default to Helbing 2000 calibrated values.
"""
function AgentParams(social_radius::F, mass::F, v_pref::F, τ::F,
                     model::ContactModel, μ::F=F(0.5), σ::F=F(0.1)) where {F<:AbstractFloat}
    if model == NoContact
        return AgentParams(social_radius, zero(F), mass, v_pref, τ, zero(F), σ, F(2000), F(0.08), F(0.5))
    elseif model == Viscous
        return AgentParams(social_radius, social_radius * F(2/3), mass, v_pref, τ, F(Inf), σ, F(2000), F(0.08), F(0.5))
    else  # Coulomb
        return AgentParams(social_radius, social_radius * F(2/3), mass, v_pref, τ, μ, σ, F(2000), F(0.08), F(0.5))
    end
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
end

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
