module SimCrowd

using StaticArrays
using LinearAlgebra
using KernelAbstractions
using Eikonal

using SimCore

export CrowdAgent
export Integrator, ForwardEuler, SymplecticEuler
export integrate_agent!
export goal_seeking_force, agent_repulsion, wall_repulsion
export SpatialHash, hash_position, build_grid!, get_neighbors
export NavigationField, build_navigation_field, get_desired_direction
export crowd_step_cpu!

include("forces.jl")
include("integrate.jl")
include("spatial_hash.jl")
include("navigation.jl")
include("loop.jl")

end
