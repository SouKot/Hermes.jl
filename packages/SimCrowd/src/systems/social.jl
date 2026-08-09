# ── Social Forces System ────────────────────────────────────────────────────────

using Ark
using KernelAbstractions
using StaticArrays
using LinearAlgebra
using CellListMap

# The agent_repulsion function is defined in forces.jl

"""
    update_social_forces_system!(world, search, backend)

Dispatches to the correct social force computation based on the neighbor search algorithm.
"""
function update_social_forces_system!(world::World, search::AbstractNeighborSearch, backend::Backend)
    # 1. Extract positions and radii from ECS into contiguous arrays for building the grid
    num_agents = count_entities(Query(world, (Position{Float32},))) # We will parameterize this properly below
    
    # For now, to keep it simple, we infer F from the search struct
    F = typeof(search.cell_size)
    positions = Vector{SVector{2,F}}(undef, num_agents)
    radii = Vector{F}(undef, num_agents)
    
    idx = 1
    for (entities, pos_col, params_col) in Query(world, (Position{F}, AgentParams{F}))
        for i in eachindex(pos_col)
            positions[idx] = pos_col[i].p
            radii[idx] = params_col[i].radius
            idx += 1
        end
    end
    
    # 2. Build the spatial grid
    build_grid!(search, positions, backend)
    
    # 3. Compute forces based on the algorithm type
    _compute_social_forces!(world, search, positions, radii, backend)
end

# GPU / RadixSpatialHash Implementation
function _compute_social_forces!(world::World, search::RadixSpatialHash{AT,F}, positions, radii, backend) where {AT,F}
    for (entities, pos_col, params_col, force_col) in Query(world, (Position{F}, AgentParams{F}, Force{F}))
        Threads.@threads for i in eachindex(pos_col)
            pos_i = pos_col[i].p
            r_i = params_col[i].radius
            
            F_repulse = zero(SVector{2,F})
            for neighbor_idx in get_neighbors(search, pos_i)
                pos_j = positions[neighbor_idx]
                r_j = radii[neighbor_idx]
                
                # The repulsion function handles self-interaction gracefully via distance check
                F_repulse += agent_repulsion(pos_i, pos_j, r_i, r_j)
            end
            force_col[i] = Force(force_col[i].f + F_repulse)
        end
    end
end

# CPU / CellListMap Implementation
function _compute_social_forces!(world::World, search::CPUNeighborSearch{F}, positions, radii, backend::CPU) where {F}
    
    # Define the closure for CellListMap mapping
    function compute_repulsion(pair, forces)
        (; i, j, d2, d) = pair
        if d > F(1e-6)
            pos_i = positions[i]
            pos_j = positions[j]
            r_i = radii[i]
            r_j = radii[j]
            
            # agent_repulsion already checks distance, but we can reuse d
            A = F(2000.0)
            B = F(0.08)
            r_ij = pos_i - pos_j
            f = A * exp((r_i + r_j - d) / B) * (r_ij / d)
            
            forces[i] += f
            forces[j] -= f
        end
        return forces
    end
    
    forces = CellListMap.pairwise!(compute_repulsion, search.system)
    
    # Write forces back to the ECS
    idx = 1
    for (entities, force_col) in Query(world, (Force{F},))
        for i in eachindex(force_col)
            force_col[i] = Force(force_col[i].f + forces[idx])
            idx += 1
        end
    end
end
