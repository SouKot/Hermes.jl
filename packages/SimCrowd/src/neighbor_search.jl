# ── Neighbor Search Interface ───────────────────────────────────────────────────

using KernelAbstractions
using StaticArrays
using CellListMap
import AcceleratedKernels as AK

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
    # Morton key-space: interleaved x,y bits → key ∈ [0, 2^(2×bits) − 1] where
    # bits = number of bits to represent max(dims)-1.  Sized as a power-of-two.
    max_dim  = max(dims[1], dims[2])
    bits     = max_dim <= 1 ? 0 : ceil(Int, log2(Float64(max_dim)))
    num_cells = max(1, 1 << (2 * bits))
    
    cell_hashes = KernelAbstractions.zeros(backend, Int, N)
    agent_indices = KernelAbstractions.zeros(backend, Int, N)
    cell_starts = KernelAbstractions.zeros(backend, Int, num_cells)
    cell_ends = KernelAbstractions.zeros(backend, Int, num_cells)
    
    return RadixSpatialHash{typeof(cell_hashes), F}(cell_size, grid_min, dims, cell_hashes, agent_indices, cell_starts, cell_ends)
end

"""
    get_ka_backend(sh::RadixSpatialHash) → Backend

Derive the KernelAbstractions backend from the array type of the hash.
- `Vector` (CPU arrays) → `CPU()`
- `CuArray` (CUDA arrays) → `CUDABackend()` (requires CUDA.jl loaded)

Used by `step!` to route GPU dispatches without requiring a separate
`backend` field in `SimScene`.
"""
function get_ka_backend(sh::RadixSpatialHash{AT,F}) where {AT,F}
    return get_ka_backend(AT)
end
get_ka_backend(::Type{<:Vector}) = CPU()
# CUDA dispatch: defined conditionally so SimCrowd doesn't hard-depend on CUDA.jl.
# If CUDA.jl is loaded, CuArray dispatch will be available via extension or
# explicit method definition in gpu_context.jl (where CUDA is already imported).
# Fallback for unknown array types: warn and return CPU().
function get_ka_backend(::Type{AT}) where {AT<:AbstractArray}
    @warn "get_ka_backend: unknown array type $AT, defaulting to CPU()" maxlog=1
    return CPU()
end

"""
    morton_spread_bits(v::UInt32) → UInt32

Spreads the low 16 bits of `v` into even bit positions:
  bit 0 → position 0, bit 1 → position 2, bit 2 → position 4, ...

Used to build Morton (Z-order) curve codes by interleaving x and y bit-spreads.
All operations are integer bitwise — GPU-safe.
"""
@inline function morton_spread_bits(v::UInt32)::UInt32
    v &= UInt32(0x0000ffff)
    v = (v | (v << UInt32(8)))  & UInt32(0x00ff00ff)
    v = (v | (v << UInt32(4)))  & UInt32(0x0f0f0f0f)
    v = (v | (v << UInt32(2)))  & UInt32(0x33333333)
    v = (v | (v << UInt32(1)))  & UInt32(0x55555555)
    return v
end

"""
    position_to_hash(pos, grid_min, cell_size, dims) → Int

Maps a 2D position to a 1-indexed cell ID using the **Morton (Z-order) curve**.

Morton encoding interleaves the x and y cell-coordinate bits, so spatially adjacent
cells receive nearby codes. After sorting agents by this hash, agents in neighboring
cells are closer in memory — improving cache hit rates in the GPU neighbor kernel.

GPU-safe: only integer bitwise ops (`&`, `|`, `<<`, `UInt32` casts).
"""
@inline function position_to_hash(pos::SVector{2, F}, grid_min::SVector{2, F},
                                   cell_size::F, dims::SVector{2, Int}) where {F<:AbstractFloat}
    idx = floor.(Int, (pos - grid_min) / cell_size)
    x   = UInt32(clamp(idx[1], 0, dims[1] - 1))
    y   = UInt32(clamp(idx[2], 0, dims[2] - 1))
    return Int(morton_spread_bits(x) | (morton_spread_bits(y) << UInt32(1))) + 1
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

# ── Sortperm backend dispatch ─────────────────────────────────────────────────
# AK.sortperm!(ix, v, backend) is the unified API:
#   CPU() → AK.sample_sortperm! (parallel sample sort, 24 Julia tasks)
#            Falls back to Base.sort! for small N, parallel above threshold:
#            threshold = oversampling_factor(16) × max_tasks(nthreads) → ~N>8000
#   GPU   → merge_sortperm_lowmem! (GPU shared-memory merge sort, 1× temp)
#
# Benchmark (24 threads, 2026-08-13):
#   N=   250: Base=2.3μs, AK=29.2μs (Base wins — AK threshold not reached)
#   N=  8000: Base=193.9μs, AK=134.9μs  (AK 1.4× faster ← crossover)
#   N= 64000: Base=1872μs, AK=552μs      (AK 3.4× faster)
#   N=100000: Base=3019μs, AK=1250μs     (AK 2.4× faster)
#
# AK handles the crossover automatically via its internal threshold logic.
# Pass temp=similar(ix) to reuse a buffer and avoid per-call allocation.
_sortperm!(ix::AbstractArray, v::AbstractArray, backend::Backend; kw...) =
    AK.sortperm!(ix, v, backend; kw...)

function build_grid!(sh::RadixSpatialHash, positions::AbstractArray, backend::Backend)
    N = length(positions)
    num_cells = length(sh.cell_starts)
    
    fill!(sh.cell_starts, 0)
    fill!(sh.cell_ends, 0)
    
    kernel_hashes! = compute_hashes_kernel!(backend)
    kernel_hashes!(sh.cell_hashes, positions, sh.grid_min, sh.cell_size, sh.grid_dims, ndrange=N)
    KernelAbstractions.synchronize(backend)
    
    # AK.merge_sortperm! uses static block-size kernels (GPU shared memory) — GPU only.
    # Julia base sortperm! is CPU-only (no device array support).
    # Dispatch: CPU uses Julia base, GPU backends use AcceleratedKernels.
    _sortperm!(sh.agent_indices, sh.cell_hashes, backend)
    
    kernel_csr! = build_csr_kernel!(backend)
    kernel_csr!(sh.cell_starts, sh.cell_ends, sh.cell_hashes, sh.agent_indices, ndrange=N)
    KernelAbstractions.synchronize(backend)
end

@inline function get_neighbors(sh::RadixSpatialHash{AT, F}, pos::SVector{2, F}) where {AT, F}
    idx = floor.(Int, (pos - sh.grid_min) / sh.cell_size)
    return NeighborIterator(sh.grid_min, sh.grid_dims, sh.cell_size, sh.cell_starts, sh.cell_ends, sh.agent_indices, idx)
end

struct NeighborIterator{AT, F}
    grid_min::SVector{2, F}
    grid_dims::SVector{2, Int}
    cell_size::F
    cell_starts::AT
    cell_ends::AT
    agent_indices::AT
    center_idx::SVector{2, Int}
end

function Base.iterate(iter::NeighborIterator, state=(-1, -1, -1))
    dx, dy, current_idx = state
    while dy <= 1
        x = iter.center_idx[1] + dx
        y = iter.center_idx[2] + dy
        if x >= 0 && x < iter.grid_dims[1] && y >= 0 && y < iter.grid_dims[2]
            # Morton cell ID: interleaved x,y bits → cache-friendly neighbor access
            xi = UInt32(x); yi = UInt32(y)
            cell_id = Int(morton_spread_bits(xi) | (morton_spread_bits(yi) << UInt32(1))) + 1
            start_idx = iter.cell_starts[cell_id]
            end_idx = iter.cell_ends[cell_id]
            if start_idx != 0
                if current_idx == -1
                    current_idx = start_idx
                end
                if current_idx <= end_idx
                    agent_id = iter.agent_indices[current_idx]
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

struct SortedNeighborIterator{AT, F}
    grid_min::SVector{2, F}
    grid_dims::SVector{2, Int}
    cell_size::F
    cell_starts::AT
    cell_ends::AT
    center_idx::SVector{2, Int}
end

function Base.iterate(iter::SortedNeighborIterator, state=(-1, -1, -1))
    dx, dy, current_idx = state
    while dy <= 1
        x = iter.center_idx[1] + dx
        y = iter.center_idx[2] + dy
        if x >= 0 && x < iter.grid_dims[1] && y >= 0 && y < iter.grid_dims[2]
            # Morton cell ID: interleaved x,y bits → cache-friendly neighbor access
            xi = UInt32(x); yi = UInt32(y)
            cell_id = Int(morton_spread_bits(xi) | (morton_spread_bits(yi) << UInt32(1))) + 1
            start_idx = iter.cell_starts[cell_id]
            end_idx = iter.cell_ends[cell_id]
            if start_idx != 0
                if current_idx == -1
                    current_idx = start_idx
                end
                if current_idx <= end_idx
                    return (current_idx, (dx, dy, current_idx + 1))
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
Base.IteratorSize(::Type{SortedNeighborIterator{AT, F}}) where {AT, F} = Base.SizeUnknown()
Base.eltype(::Type{SortedNeighborIterator{AT, F}}) where {AT, F} = Int
# ── 2. CPUNeighborSearch (CellListMap) ────────────────────────────────────────

"""
    CPUNeighborSearch{F<:AbstractFloat, Sys}

A spatial hash specialized for the CPU, wrapping `CellListMap` for maximum performance.

Two separate `ParticleSystem` objects are maintained:
- `system`: contact forces (symmetric — Newton's 3rd law; each pair processed once)
- `psych_system`: psychological forces (asymmetric — f_ij ≠ −f_ji; both directions
  computed per pair in a single `pairwise!` pass at O(N×k) cost)

Eight parameter buffers (`cpu_mus`, `cpu_As`, `cpu_Bs`, `cpu_λs`, `cpu_ηs`,
`cpu_τ_gaps`, `cpu_b_mins`, `cpu_b_maxs`) are
pre-allocated in the struct and filled from ECS once per step, eliminating the
per-step Vector allocations that previously occurred.
"""
mutable struct CPUNeighborSearch{F<:AbstractFloat, Sys} <: AbstractNeighborSearch{F}
    cell_size::F
    grid_min::SVector{2, F}
    grid_max::SVector{2, F}
    unitcell::Union{Nothing, SVector{2, F}}
    system::Sys
    psych_system::Sys
    # Pre-allocated per-agent parameter buffers — staged from ECS once per step.
    cpu_mus::Vector{F}    # Coulomb friction cap μ
    cpu_As::Vector{F}     # Social repulsion strength A
    cpu_Bs::Vector{F}     # Social repulsion decay length B
    cpu_λs::Vector{F}     # Anisotropy factor λ
    cpu_ηs::Vector{F}     # §1.4 GCF speed-adaptation factor η (0 = Helbing/circular)
    cpu_τ_gaps::Vector{F} # §1.5 GCFM-elliptical time-gap τ_gap (0 = circular)
    cpu_b_mins::Vector{F} # §1.5 lateral semi-axis minimum b_min (m)
    cpu_b_maxs::Vector{F} # §1.5 lateral semi-axis maximum b_max (m)
end

function CPUNeighborSearch(N::Int, grid_min::SVector{2,F}, grid_max::SVector{2,F}, cell_size::F;
                            unitcell::Union{Nothing, SVector{2,F}} = nothing) where {F<:AbstractFloat}
    sides = grid_max - grid_min

    # Initialize CellListMap ParticleSystem with dummy positions
    dummy_positions = [grid_min + SVector{2,F}(rand()*sides[1], rand()*sides[2]) for _ in 1:N]

    # Conditionally enable periodic boundary conditions.
    # Non-periodic (unitcell=nothing): CellListMap uses NonPeriodicCellList — identical to previous behaviour.
    # Periodic (unitcell provided): CellListMap uses PeriodicCellList; positions must be in [0, Lx]×[0, Ly].
    # Both ParticleSystems must use the same boundary type so that `Sys` is a concrete type.
    if isnothing(unitcell)
        sys = CellListMap.ParticleSystem(
            positions = dummy_positions,
            cutoff    = cell_size,
            output    = zeros(SVector{2,F}, N)
        )
        psych_sys = CellListMap.ParticleSystem(
            positions = copy(dummy_positions),
            cutoff    = cell_size,
            output    = zeros(SVector{2,F}, N)
        )
    else
        uc = collect(unitcell)  # CellListMap expects AbstractVector, not SVector
        sys = CellListMap.ParticleSystem(
            positions = dummy_positions,
            unitcell  = uc,
            cutoff    = cell_size,
            output    = zeros(SVector{2,F}, N)
        )
        psych_sys = CellListMap.ParticleSystem(
            positions = copy(dummy_positions),
            unitcell  = uc,
            cutoff    = cell_size,
            output    = zeros(SVector{2,F}, N)
        )
    end

    # Pre-allocate parameter buffers (filled from ECS in _update_social_forces_impl!)
    cpu_mus    = Vector{F}(undef, N)
    cpu_As     = Vector{F}(undef, N)
    cpu_Bs     = Vector{F}(undef, N)
    cpu_λs     = Vector{F}(undef, N)
    cpu_ηs     = Vector{F}(undef, N)
    cpu_τ_gaps = Vector{F}(undef, N)  # §1.5 GCFM-elliptical
    cpu_b_mins = Vector{F}(undef, N)  # §1.5
    cpu_b_maxs = Vector{F}(undef, N)  # §1.5

    return CPUNeighborSearch{F, typeof(sys)}(
        cell_size, grid_min, grid_max, unitcell,
        sys, psych_sys,
        cpu_mus, cpu_As, cpu_Bs, cpu_λs, cpu_ηs,
        cpu_τ_gaps, cpu_b_mins, cpu_b_maxs
    )
end

function build_grid!(search::CPUNeighborSearch, positions::AbstractArray, backend::CPU)
    # Update both cell lists (each call is O(N) — negligible vs force computation)
    CellListMap.update!(search.system;       positions=positions)
    CellListMap.update!(search.psych_system; positions=positions)
end
