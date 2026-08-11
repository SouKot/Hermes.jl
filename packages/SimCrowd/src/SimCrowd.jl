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

# Provide an outer constructor for backward compatibility and easy defaulting
AgentParams(social_radius::F, mass::F, v_pref::F, τ::F, μ::F) where {F<:AbstractFloat} = 
    AgentParams(social_radius, social_radius * F(2/3), mass, v_pref, τ, μ)

AgentParams(social_radius::F, mass::F, v_pref::F, τ::F) where {F<:AbstractFloat} =
    AgentParams(social_radius, social_radius * F(2/3), mass, v_pref, τ, F(1.2e5))

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
