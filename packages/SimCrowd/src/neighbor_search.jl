# ── Neighbor Search Interface ───────────────────────────────────────────────────

using KernelAbstractions
using StaticArrays
using CellListMap

"""
    AbstractNeighborSearch{F}

Abstract type for all spatial hashing and neighbor lookup algorithms.
`F` is the floating point precision (e.g., `Float32`, `Float64`).
"""
abstract type AbstractNeighborSearch{F<:AbstractFloat} end

# ── 1. Radix Spatial Hash (GPU & KA Fallback) ─────────────────────────────────

"""
    RadixSpatialHash{AT<:AbstractArray, F<:AbstractFloat}

A grid-based spatial hash using a Compressed Sparse Row (CSR) structure, 
designed to be generic over the array type `AT` (e.g., `Vector` for CPU, `CuArray` for GPU).
"""
struct RadixSpatialHash{AT<:AbstractArray, F<:AbstractFloat} <: AbstractNeighborSearch{F}
    cell_size::F
    grid_min::SVector{2, F}
    grid_dims::SVector{2, Int}
    
    cell_hashes::AT        # Length N: Hash of the cell each agent belongs to
    agent_indices::AT      # Length N: Sorted agent indices
    cell_starts::AT        # Length NumCells: Start index for each cell
    cell_ends::AT          # Length NumCells: End index for each cell
end

function RadixSpatialHash(backend::Backend, N::Int, grid_min::SVector{2,F}, grid_max::SVector{2,F}, cell_size::F) where {F<:AbstractFloat}
    dims = ceil.(Int, (grid_max - grid_min) / cell_size)
    num_cells = dims[1] * dims[2]
    
    cell_hashes = KernelAbstractions.zeros(backend, Int, N)
    agent_indices = KernelAbstractions.zeros(backend, Int, N)
    cell_starts = KernelAbstractions.zeros(backend, Int, num_cells)
    cell_ends = KernelAbstractions.zeros(backend, Int, num_cells)
    
    return RadixSpatialHash{typeof(cell_hashes), F}(cell_size, grid_min, dims, cell_hashes, agent_indices, cell_starts, cell_ends)
end

@inline function position_to_hash(pos::SVector{2, F}, grid_min::SVector{2, F}, cell_size::F, dims::SVector{2, Int}) where {F<:AbstractFloat}
    idx = floor.(Int, (pos - grid_min) / cell_size)
    x = clamp(idx[1], 0, dims[1] - 1)
    y = clamp(idx[2], 0, dims[2] - 1)
    return x + y * dims[1] + 1
end

@kernel function compute_hashes_kernel!(cell_hashes, @Const(positions), grid_min, cell_size, dims)
    i = @index(Global, Linear)
    @inbounds cell_hashes[i] = position_to_hash(positions[i], grid_min, cell_size, dims)
end

@kernel function build_csr_kernel!(cell_starts, cell_ends, @Const(cell_hashes), @Const(agent_indices))
    i = @index(Global, Linear)
    @inbounds begin
        cell_id = cell_hashes[agent_indices[i]]
        if i == 1 || cell_hashes[agent_indices[i-1]] != cell_id
            cell_starts[cell_id] = i
        end
        if i == length(agent_indices) || cell_hashes[agent_indices[i+1]] != cell_id
            cell_ends[cell_id] = i
        end
    end
end

function build_grid!(sh::RadixSpatialHash, positions::AbstractArray, backend::Backend)
    N = length(positions)
    num_cells = length(sh.cell_starts)
    
    fill!(sh.cell_starts, 0)
    fill!(sh.cell_ends, 0)
    
    kernel_hashes! = compute_hashes_kernel!(backend)
    kernel_hashes!(sh.cell_hashes, positions, sh.grid_min, sh.cell_size, sh.grid_dims, ndrange=N)
    KernelAbstractions.synchronize(backend)
    
    sortperm!(sh.agent_indices, sh.cell_hashes)
    
    kernel_csr! = build_csr_kernel!(backend)
    kernel_csr!(sh.cell_starts, sh.cell_ends, sh.cell_hashes, sh.agent_indices, ndrange=N)
    KernelAbstractions.synchronize(backend)
end

@inline function get_neighbors(sh::RadixSpatialHash{AT, F}, pos::SVector{2, F}) where {AT, F}
    idx = floor.(Int, (pos - sh.grid_min) / sh.cell_size)
    return NeighborIterator(sh, idx)
end

struct NeighborIterator{AT, F}
    sh::RadixSpatialHash{AT, F}
    center_idx::SVector{2, Int}
end

function Base.iterate(iter::NeighborIterator, state=(-1, -1, -1))
    dx, dy, current_idx = state
    while dy <= 1
        x = iter.center_idx[1] + dx
        y = iter.center_idx[2] + dy
        if x >= 0 && x < iter.sh.grid_dims[1] && y >= 0 && y < iter.sh.grid_dims[2]
            cell_id = x + y * iter.sh.grid_dims[1] + 1
            start_idx = iter.sh.cell_starts[cell_id]
            end_idx = iter.sh.cell_ends[cell_id]
            if start_idx != 0
                if current_idx == -1
                    current_idx = start_idx
                end
                if current_idx <= end_idx
                    agent_id = iter.sh.agent_indices[current_idx]
                    return (agent_id, (dx, dy, current_idx + 1))
                end
            end
        end
        current_idx = -1
        dx += 1
        if dx > 1
            dx = -1
            dy += 1
        end
    end
    return nothing
end
Base.IteratorSize(::Type{NeighborIterator{AT, F}}) where {AT, F} = Base.SizeUnknown()
Base.eltype(::Type{NeighborIterator{AT, F}}) where {AT, F} = Int


# ── 2. CPUNeighborSearch (CellListMap) ────────────────────────────────────────

"""
    CPUNeighborSearch{F<:AbstractFloat}

A spatial hash specialized for the CPU, wrapping `CellListMap` for maximum performance.
"""
mutable struct CPUNeighborSearch{F<:AbstractFloat, Sys} <: AbstractNeighborSearch{F}
    cell_size::F
    grid_min::SVector{2, F}
    grid_max::SVector{2, F}
    system::Sys
end

function CPUNeighborSearch(N::Int, grid_min::SVector{2,F}, grid_max::SVector{2,F}, cell_size::F) where {F<:AbstractFloat}
    sides = grid_max - grid_min
    
    # Initialize CellListMap ParticleSystem with dummy positions
    dummy_positions = [grid_min + SVector{2,F}(rand()*sides[1], rand()*sides[2]) for _ in 1:N]
    sys = CellListMap.ParticleSystem(
        positions = dummy_positions,
        cutoff = cell_size,
        unitcell = sides,
        output = zeros(SVector{2,F}, N)
    )
    
    return CPUNeighborSearch{F, typeof(sys)}(cell_size, grid_min, grid_max, sys)
end

function build_grid!(search::CPUNeighborSearch, positions::AbstractArray, backend::CPU)
    CellListMap.update!(search.system; positions=positions)
end
