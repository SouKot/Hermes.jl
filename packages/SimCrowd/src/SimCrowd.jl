module SimCrowd

using StaticArrays
using LinearAlgebra
using KernelAbstractions
using Eikonal
using Ark

using SimCore

export Position, Velocity, AgentParams, Goal, Force
export goal_seeking_force, agent_repulsion, wall_repulsion
export AbstractNeighborSearch, RadixSpatialHash, CPUNeighborSearch, build_grid!, get_neighbors
export NavigationField, build_navigation_field, get_desired_direction
export update_navigation_system!, update_social_forces_system!, integrate_physics_system!

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
    radius::F
    v_pref::F
    τ::F
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

end
