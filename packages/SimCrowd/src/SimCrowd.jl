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
end

"""
    AgentParams(social_radius, collision_radius, mass, v_pref, τ, μ) → 6-arg (full)
    AgentParams(social_radius, mass, v_pref, τ, μ)                  → 5-arg (auto collision_radius = 2/3 × social_radius)
    AgentParams(social_radius, mass, v_pref, τ)                     → 4-arg (μ defaults to 0.5, Helbing 2000 normal walking)

Outer constructors for ergonomic construction.

`collision_radius = social_radius × 2/3` is a standard Helbing ratio: the physical
body (collision) is smaller than the "personal space" (social) radius so that the
body-contact force only activates at closer range than the social force.

`μ = 0.5` is the Coulomb friction cap for normal pedestrian walking (Helbing 2000,
Table I). For panic/evacuation scenarios where Helbing's pure viscous friction (no cap)
is needed, pass `μ = Inf` or use the 6-arg constructor with the desired value.

**BUG NOTE (historical):** The 4-arg constructor previously defaulted to `μ = F(1.2e5)`,
which is the body stiffness constant `k`, not a friction coefficient. Fixed 2026-08-12.
"""
AgentParams(social_radius::F, mass::F, v_pref::F, τ::F, μ::F) where {F<:AbstractFloat} =
    AgentParams(social_radius, social_radius * F(2/3), mass, v_pref, τ, μ)

AgentParams(social_radius::F, mass::F, v_pref::F, τ::F) where {F<:AbstractFloat} =
    AgentParams(social_radius, social_radius * F(2/3), mass, v_pref, τ, F(0.5))

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
