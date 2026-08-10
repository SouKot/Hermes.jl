# ── Social Forces System ────────────────────────────────────────────────────────

using Ark
using KernelAbstractions
using StaticArrays
using LinearAlgebra
using CellListMap

# The agent_repulsion function is defined in forces.jl

struct SocialForcesGPUContext{F, VCPU<:AbstractVector, SCPU<:AbstractVector, VGPU<:AbstractVector, SGPU<:AbstractVector}
    N::Int
    cpu_positions::VCPU
    cpu_radii::SCPU
    cpu_forces::VCPU
    
    dev_positions::VGPU
    dev_radii::SGPU
    dev_forces::VGPU
    
    sorted_dev_positions::VGPU
    sorted_dev_radii::SGPU
end

function SocialForcesGPUContext(backend, F, N::Int)
    VCPU = Vector{SVector{2,F}}
    SCPU = Vector{F}
    
    cpu_positions = VCPU(undef, N)
    cpu_radii = SCPU(undef, N)
    cpu_forces = VCPU(undef, N)
    
    dev_positions = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_radii = KernelAbstractions.zeros(backend, F, N)
    dev_forces = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    
    sorted_dev_positions = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_dev_radii = KernelAbstractions.zeros(backend, F, N)
    
    VGPU = typeof(dev_positions)
    SGPU = typeof(dev_radii)
    
    return SocialForcesGPUContext{F, VCPU, SCPU, VGPU, SGPU}(
        N, cpu_positions, cpu_radii, cpu_forces,
        dev_positions, dev_radii, dev_forces,
        sorted_dev_positions, sorted_dev_radii
    )
end

const GPU_CONTEXTS = IdDict{World, SocialForcesGPUContext}()
const GPU_CONTEXTS_LOCK = Base.Threads.SpinLock()

function get_gpu_context(world::World, backend, F, N::Int)
    lock(GPU_CONTEXTS_LOCK)
    try
        ctx = get(GPU_CONTEXTS, world, nothing)
        if ctx === nothing || ctx.N != N
            ctx = SocialForcesGPUContext(backend, F, N)
            GPU_CONTEXTS[world] = ctx
        end
        return ctx
    finally
        unlock(GPU_CONTEXTS_LOCK)
    end
end


"""
    update_social_forces_system!(world, search, backend)

Dispatches to the correct social force computation based on the neighbor search algorithm.
"""
function update_social_forces_system!(world::World, search::AbstractNeighborSearch, backend::Backend)
    # 1. Extract positions and radii from ECS into contiguous arrays for building the grid
    num_agents = count_entities(Query(world, (Position{Float32},))) # We will parameterize this properly below
    
    # For now, to keep it simple, we infer F from the search struct
    F = typeof(search.cell_size)
    
    # Lazily get or create context
    ctx = get_gpu_context(world, backend, F, num_agents)
    positions = ctx.cpu_positions
    radii = ctx.cpu_radii
    
    idx = 1
    for (entities, pos_col, params_col) in Query(world, (Position{F}, AgentParams{F}))
        for i in eachindex(pos_col)
            positions[idx] = pos_col[i].p
            radii[idx] = params_col[i].radius
            idx += 1
        end
    end
    
    # Delegate to a backend-aware method which can handle device transfers
    _update_social_forces_impl!(world, search, positions, radii, backend, ctx)
end

@kernel function reorder_array_kernel!(out_arr, @Const(in_arr), @Const(indices))
    i = @index(Global, Linear)
    @inbounds out_arr[i] = in_arr[indices[i]]
end

@kernel function compute_social_forces_kernel!(forces, @Const(sorted_positions), @Const(sorted_radii), 
    grid_min, grid_dims, cell_size, @Const(cell_starts), @Const(cell_ends), @Const(agent_indices))
    i = @index(Global, Linear)
    
    @inbounds begin
        original_i = agent_indices[i]
        
        pos_i = sorted_positions[i]
        r_i = sorted_radii[i]
        
        F_repulse = zero(SVector{2, typeof(cell_size)})
        
        idx = floor.(Int, (pos_i - grid_min) / cell_size)
        
        # NeighborIterator no longer needs agent_indices! 
        # cell_starts and cell_ends point to the indices of the *sorted* array!
        iter = SortedNeighborIterator(grid_min, grid_dims, cell_size, cell_starts, cell_ends, idx)
        
        for neighbor_idx in iter
            pos_j = sorted_positions[neighbor_idx]
            r_j = sorted_radii[neighbor_idx]
            
            F_repulse += agent_repulsion(pos_i, pos_j, r_i, r_j)
        end
        forces[original_i] = F_repulse
    end
end

function _update_social_forces_impl!(world::World, search::RadixSpatialHash{AT,F}, positions, radii, backend, ctx::SocialForcesGPUContext) where {AT,F}
    N = length(positions)
    
    dev_positions = ctx.dev_positions
    dev_radii = ctx.dev_radii
    dev_forces = ctx.dev_forces
    
    fill!(dev_forces, zero(SVector{2,F}))
    
    # 2. Copy data to device
    copyto!(dev_positions, positions)
    copyto!(dev_radii, radii)
    
    # 3. Build spatial grid entirely on device
    build_grid!(search, dev_positions, backend)
    
    # Reorder arrays to achieve coalesced memory access
    kernel_reorder! = reorder_array_kernel!(backend)
    kernel_reorder!(ctx.sorted_dev_positions, dev_positions, search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_radii, dev_radii, search.agent_indices, ndrange=N)
    KernelAbstractions.synchronize(backend)
    
    # 4. Launch forces kernel using sorted arrays
    kernel! = compute_social_forces_kernel!(backend)
    kernel!(dev_forces, ctx.sorted_dev_positions, ctx.sorted_dev_radii, 
        search.grid_min, search.grid_dims, search.cell_size, 
        search.cell_starts, search.cell_ends, search.agent_indices, 
        ndrange=N)
    KernelAbstractions.synchronize(backend)
    
    # 5. Copy forces back to host
    cpu_forces = ctx.cpu_forces
    copyto!(cpu_forces, dev_forces)
    
    # 6. Write back to ECS
    idx = 1
    for (entities, force_col) in Query(world, (Force{F},))
        for i in eachindex(force_col)
            force_col[i] = Force(force_col[i].f + cpu_forces[idx])
            idx += 1
        end
    end
end

function _update_social_forces_impl!(world::World, search::CPUNeighborSearch{F}, positions, radii, backend::CPU, ctx) where {F}
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
