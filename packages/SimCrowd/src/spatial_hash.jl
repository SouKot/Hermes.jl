# ── Spatial Hashing (Radix Sort + CSR) ──────────────────────────────────────

using KernelAbstractions

"""
    SpatialHash{AT<:AbstractArray}

A grid-based spatial hash using a Compressed Sparse Row (CSR) structure.
Designed to be generic over the array type `AT` (e.g., `Vector` for CPU, `CuArray` for GPU).
"""
struct SpatialHash{AT<:AbstractArray}
    cell_size::Float32
    grid_min::SVector{2, Float32}
    grid_dims::SVector{2, Int}
    
    cell_hashes::AT        # Length N: Hash of the cell each agent belongs to
    agent_indices::AT      # Length N: Sorted agent indices
    cell_starts::AT        # Length NumCells: Start index for each cell
    cell_ends::AT          # Length NumCells: End index for each cell
end

function SpatialHash(backend::Backend, N::Int, grid_min::SVector{2,Float32}, grid_max::SVector{2,Float32}, cell_size::Float32)
    dims = ceil.(Int, (grid_max - grid_min) / cell_size)
    num_cells = dims[1] * dims[2]
    
    cell_hashes = KernelAbstractions.zeros(backend, Int, N)
    agent_indices = KernelAbstractions.zeros(backend, Int, N)
    cell_starts = KernelAbstractions.zeros(backend, Int, num_cells)
    cell_ends = KernelAbstractions.zeros(backend, Int, num_cells)
    
    return SpatialHash{typeof(cell_hashes)}(cell_size, grid_min, dims, cell_hashes, agent_indices, cell_starts, cell_ends)
end

@inline function position_to_hash(pos::SVector{2, Float32}, grid_min::SVector{2, Float32}, cell_size::Float32, dims::SVector{2, Int})
    # Compute 0-based cell coordinates
    idx = floor.(Int, (pos - grid_min) / cell_size)
    
    # Clamp to grid boundaries
    x = clamp(idx[1], 0, dims[1] - 1)
    y = clamp(idx[2], 0, dims[2] - 1)
    
    # 1D index (1-based for Julia)
    return x + y * dims[1] + 1
end

@kernel function compute_hashes_kernel!(cell_hashes, @Const(positions), grid_min, cell_size, dims)
    i = @index(Global, Linear)
    @inbounds cell_hashes[i] = position_to_hash(positions[i], grid_min, cell_size, dims)
end

@kernel function build_csr_kernel!(cell_starts, cell_ends, @Const(cell_hashes), @Const(agent_indices))
    i = @index(Global, Linear)
    
    # We are looking at the sorted array of agents
    @inbounds begin
        cell_id = cell_hashes[agent_indices[i]]
        
        # If this is the first agent, or the previous agent is in a different cell
        if i == 1 || cell_hashes[agent_indices[i-1]] != cell_id
            cell_starts[cell_id] = i
        end
        
        # If this is the last agent, or the next agent is in a different cell
        if i == length(agent_indices) || cell_hashes[agent_indices[i+1]] != cell_id
            cell_ends[cell_id] = i
        end
    end
end

"""
    build_grid!(sh::SpatialHash, positions::AbstractArray, backend::Backend)

Rebuilds the spatial hash grid from scratch. 
1. Hashes all positions to cells.
2. Sorts agents by cell hash.
3. Builds the CSR `cell_starts` and `cell_ends` arrays.
"""
function build_grid!(sh::SpatialHash, positions::AbstractArray, backend::Backend)
    N = length(positions)
    num_cells = length(sh.cell_starts)
    
    # Clear previous CSR arrays
    fill!(sh.cell_starts, 0)
    fill!(sh.cell_ends, 0)
    
    # 1. Compute hashes
    kernel_hashes! = compute_hashes_kernel!(backend)
    kernel_hashes!(sh.cell_hashes, positions, sh.grid_min, sh.cell_size, sh.grid_dims, ndrange=N)
    KernelAbstractions.synchronize(backend)
    
    # 2. Sort agent indices by cell hash
    # For Phase 3A (CPU), standard sortperm! works perfectly.
    # Note: On GPU, we will dispatch to CUDA.sortperm! in Phase 3B.
    sortperm!(sh.agent_indices, sh.cell_hashes)
    
    # 3. Build CSR boundaries
    kernel_csr! = build_csr_kernel!(backend)
    kernel_csr!(sh.cell_starts, sh.cell_ends, sh.cell_hashes, sh.agent_indices, ndrange=N)
    KernelAbstractions.synchronize(backend)
end

"""
    get_neighbors(sh, pos, radius)

Returns an iterator over the agent indices that are in the 3x3 cell neighborhood of `pos`.
"""
@inline function get_neighbors(sh::SpatialHash, pos::SVector{2, Float32})
    idx = floor.(Int, (pos - sh.grid_min) / sh.cell_size)
    
    # Create an iterator/array of all agents in the 3x3 neighborhood
    # For high performance on CPU, we can return a channel or simple array.
    # We will build a small struct iterator.
    return NeighborIterator(sh, idx)
end

struct NeighborIterator{AT}
    sh::SpatialHash{AT}
    center_idx::SVector{2, Int}
end

# Iterator state: (dx, dy, current_agent_idx_in_cell)
function Base.iterate(iter::NeighborIterator, state=(-1, -1, -1))
    dx, dy, current_idx = state
    
    # Loop over the 3x3 neighborhood
    while dy <= 1
        x = iter.center_idx[1] + dx
        y = iter.center_idx[2] + dy
        
        # Check if cell is in bounds
        if x >= 0 && x < iter.sh.grid_dims[1] && y >= 0 && y < iter.sh.grid_dims[2]
            cell_id = x + y * iter.sh.grid_dims[1] + 1
            
            start_idx = iter.sh.cell_starts[cell_id]
            end_idx = iter.sh.cell_ends[cell_id]
            
            # If the cell is not empty
            if start_idx != 0
                # If we just moved to this cell
                if current_idx == -1
                    current_idx = start_idx
                end
                
                # If we are within the cell's agents
                if current_idx <= end_idx
                    agent_id = iter.sh.agent_indices[current_idx]
                    return (agent_id, (dx, dy, current_idx + 1))
                end
            end
        end
        
        # Move to next cell
        current_idx = -1
        dx += 1
        if dx > 1
            dx = -1
            dy += 1
        end
    end
    
    return nothing
end

Base.IteratorSize(::Type{NeighborIterator{AT}}) where {AT} = Base.SizeUnknown()
Base.eltype(::Type{NeighborIterator{AT}}) where {AT} = Int
