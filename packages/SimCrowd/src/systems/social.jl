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
    
    # Delegate to a backend-aware method which can handle device transfers
    _update_social_forces_impl!(world, search, positions, radii, backend)
end

@kernel function compute_social_forces_kernel!(forces, @Const(positions), @Const(radii), 
    grid_min, grid_dims, cell_size, @Const(cell_starts), @Const(cell_ends), @Const(agent_indices))
    i = @index(Global, Linear)
    
    @inbounds begin
        pos_i = positions[i]
        r_i = radii[i]
        
        F_repulse = zero(SVector{2, typeof(cell_size)})
        
        idx = floor.(Int, (pos_i - grid_min) / cell_size)
        iter = NeighborIterator(grid_min, grid_dims, cell_size, cell_starts, cell_ends, agent_indices, idx)
        
        for neighbor_idx in iter
            pos_j = positions[neighbor_idx]
            r_j = radii[neighbor_idx]
            
            F_repulse += agent_repulsion(pos_i, pos_j, r_i, r_j)
        end
        forces[i] = F_repulse
    end
end

function _update_social_forces_impl!(world::World, search::RadixSpatialHash{AT,F}, positions, radii, backend) where {AT,F}
    N = length(positions)
    
    # 1. Allocate backend-specific arrays
    dev_positions = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_radii = KernelAbstractions.zeros(backend, F, N)
    dev_forces = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    
    # 2. Copy data to device
    copyto!(dev_positions, positions)
    copyto!(dev_radii, radii)
    
    # 3. Build spatial grid entirely on device
    build_grid!(search, dev_positions, backend)
    
    # 4. Launch forces kernel
    kernel! = compute_social_forces_kernel!(backend)
    kernel!(dev_forces, dev_positions, dev_radii, 
        search.grid_min, search.grid_dims, search.cell_size, 
        search.cell_starts, search.cell_ends, search.agent_indices, 
        ndrange=N)
    KernelAbstractions.synchronize(backend)
    
    # 5. Copy forces back to host
    cpu_forces = Array(dev_forces)
    
    # 6. Write back to ECS
    idx = 1
    for (entities, force_col) in Query(world, (Force{F},))
        for i in eachindex(force_col)
            force_col[i] = Force(force_col[i].f + cpu_forces[idx])
            idx += 1
        end
    end
end

function _update_social_forces_impl!(world::World, search::CPUNeighborSearch{F}, positions, radii, backend::CPU) where {F}
    build_grid!(search, positions, backend)
    
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
