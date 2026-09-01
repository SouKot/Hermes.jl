# gpu_context.jl — Shared GPU staging infrastructure
#
# Sprint 3Q-arch: Extracted from ORCAGPUContext (orca.jl) and
# SocialForcesGPUContext (social.jl) which both had verbatim copies of:
#   - cpu/dev/sorted_dev buffers for positions, velocities, radii, walls
#   - copyto! + kernel_reorder! staging sequence
#
# BaseGPUContext holds the common fields.
# stage_and_sort_base! performs the common per-step staging.
# CSMGPUContext and HybridFSMGPUContext embed BaseGPUContext directly.
# ORCAGPUContext and SocialForcesGPUContext are migrated to embed it too.

using KernelAbstractions
using StaticArrays

"""
    BaseGPUContext{F, VCPU, SCPU, VGPU, SGPU}

Common GPU staging buffers shared by all per-model GPU contexts
(ORCAGPUContext, SocialForcesGPUContext, CSMGPUContext, HybridFSMGPUContext).

## Fields

All fields come in three variants:
- `cpu_*`         — CPU staging buffer (written from ECS each step, then copyto! → device)
- `dev_*`         — Device buffer (unsorted; target of copyto!)
- `sorted_dev_*`  — Device buffer sorted by spatial hash (written by kernel_reorder!)

Shared fields: `positions`, `velocities`, `radii`, `wall_p1s`, `wall_p2s`.

## Usage

Embed in a model-specific GPU context:
```julia
struct CSMGPUContext{F, VCPU, SCPU, VGPU, SGPU}
    base         :: BaseGPUContext{F, VCPU, SCPU, VGPU, SGPU}
    cpu_goals    :: VCPU   # CSM-specific
    dev_new_vel  :: VGPU   # CSM-specific output
end
```

Call `stage_and_sort_base!` at the start of each step to fill all base buffers
before launching the model kernel.
"""
struct BaseGPUContext{F, VCPU<:AbstractVector, SCPU<:AbstractVector,
                         VGPU<:AbstractVector, SGPU<:AbstractVector, BGPU<:AbstractVector}
    # ── CPU staging buffers (ECS → CPU each step, then copyto! → device) ──────
    cpu_positions  :: VCPU     # Vector{SVector{2,F}}
    cpu_velocities :: VCPU
    cpu_radii      :: SCPU     # Vector{F}
    cpu_wall_p1s   :: VCPU
    cpu_wall_p2s   :: VCPU

    # ── Device buffers (unsorted — direct copyto! target) ─────────────────────
    dev_positions  :: VGPU
    dev_velocities :: VGPU
    dev_radii      :: SGPU
    dev_wall_p1s   :: VGPU
    dev_wall_p2s   :: VGPU

    # ── Sorted device buffers (post kernel_reorder! by RadixSpatialHash) ──────
    sorted_dev_positions  :: VGPU
    sorted_dev_velocities :: VGPU
    sorted_dev_radii      :: SGPU

    # ── Verlet skin-radius rebuild tracking ───────────────────────────────────
    needs_rebuild        :: BGPU   # Vector{Bool}, length 1; true = rebuild needed
    last_build_positions :: VGPU   # positions at last spatial-hash rebuild
end

"""
    BaseGPUContext(backend, F, N, max_walls)

Allocate all shared CPU staging and device buffers for N agents and up to
`max_walls` wall segments.
"""
function BaseGPUContext(backend, ::Type{F}, N::Int, max_walls::Int = 128) where {F<:AbstractFloat}
    # CPU staging
    cpu_positions  = Vector{SVector{2,F}}(undef, N)
    cpu_velocities = Vector{SVector{2,F}}(undef, N)
    cpu_radii      = Vector{F}(undef, N)
    cpu_wall_p1s   = Vector{SVector{2,F}}(undef, max_walls)
    cpu_wall_p2s   = Vector{SVector{2,F}}(undef, max_walls)

    # Device (unsorted)
    dev_positions  = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_velocities = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_radii      = KernelAbstractions.zeros(backend, F, N)
    dev_wall_p1s   = KernelAbstractions.zeros(backend, SVector{2,F}, max_walls)
    dev_wall_p2s   = KernelAbstractions.zeros(backend, SVector{2,F}, max_walls)

    # Sorted device
    sorted_dev_positions  = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_dev_velocities = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_dev_radii      = KernelAbstractions.zeros(backend, F, N)

    # Rebuild tracking — Bool array, starts as [true] to force first build
    needs_rebuild        = KernelAbstractions.ones(backend, Bool, 1)
    last_build_positions = KernelAbstractions.zeros(backend, SVector{2,F}, N)

    VCPU = typeof(cpu_positions)
    SCPU = typeof(cpu_radii)
    VGPU = typeof(dev_positions)
    SGPU = typeof(dev_radii)
    BGPU = typeof(needs_rebuild)

    return BaseGPUContext{F, VCPU, SCPU, VGPU, SGPU, BGPU}(
        cpu_positions, cpu_velocities, cpu_radii, cpu_wall_p1s, cpu_wall_p2s,
        dev_positions, dev_velocities, dev_radii, dev_wall_p1s, dev_wall_p2s,
        sorted_dev_positions, sorted_dev_velocities, sorted_dev_radii,
        needs_rebuild, last_build_positions
    )
end

"""
    stage_and_sort_base!(base, positions, velocities, radii,
                         wall_p1s, wall_p2s, n_walls,
                         search, backend, sorted_last_positions)

Per-step shared staging for all GPU contexts:
1. `copyto!` positions, velocities, radii, wall segments → device
2. Lazy grid rebuild: if any agent moved > skin radius since last build,
   call `build_grid!` and reorder `sorted_last_positions`
3. `kernel_reorder!` positions, velocities, radii by `search.agent_indices` → sorted device

**Ordering guarantee**: `build_grid!` is called BEFORE any `kernel_reorder!`, so
`search.agent_indices` is always valid when reordering starts.

Called once per step by every GPU context's `_update_*_impl!` before launching
the model-specific kernel. Returns `needs_rebuild_flag::Bool` so callers know
whether the grid was rebuilt this step (useful for profiling).
"""
function stage_and_sort_base!(
    base                 :: BaseGPUContext,
    positions            :: AbstractVector,
    velocities           :: AbstractVector,
    radii                :: AbstractVector,
    wall_p1s             :: AbstractVector,
    wall_p2s             :: AbstractVector,
    n_walls              :: Int,
    search               :: RadixSpatialHash,
    backend,
    sorted_last_positions :: AbstractVector   # caller-owned: reordered on rebuild
) :: Bool   # returns true if grid was rebuilt
    N = length(positions)
    F = eltype(radii)

    # 1. Copy per-agent data to device
    copyto!(base.dev_positions,  positions)
    copyto!(base.dev_velocities, velocities)
    copyto!(base.dev_radii,      radii)

    # 2. Copy wall segments (static, not sorted)
    if n_walls > 0
        copyto!(@view(base.dev_wall_p1s[1:n_walls]), @view(wall_p1s[1:n_walls]))
        copyto!(@view(base.dev_wall_p2s[1:n_walls]), @view(wall_p2s[1:n_walls]))
    end

    # 3. Lazy grid rebuild check — MUST happen before any kernel_reorder!
    #    so that search.agent_indices is valid when we reorder below.
    sq_skin_radius = F(2.0)^2
    kernel_check! = check_rebuild_kernel!(backend)
    kernel_check!(base.needs_rebuild, base.dev_positions, base.last_build_positions,
                  sq_skin_radius, ndrange=N)
    KernelAbstractions.synchronize(backend)

    cpu_needs_rebuild = Vector{Bool}(undef, 1)
    copyto!(cpu_needs_rebuild, base.needs_rebuild)
    rebuilt = cpu_needs_rebuild[1]

    reorder! = reorder_array_kernel!(backend)

    if rebuilt
        copyto!(base.last_build_positions, base.dev_positions)
        build_grid!(search, base.dev_positions, backend)
        # Reorder last positions once so they're coalesced for the kernel
        reorder!(sorted_last_positions, base.last_build_positions,
                 search.agent_indices, ndrange=N)
        fill!(base.needs_rebuild, false)
    end

    # 4. Reorder per-agent arrays using (now-valid) agent_indices
    reorder!(base.sorted_dev_positions,  base.dev_positions,  search.agent_indices, ndrange=N)
    reorder!(base.sorted_dev_velocities, base.dev_velocities, search.agent_indices, ndrange=N)
    reorder!(base.sorted_dev_radii,      base.dev_radii,      search.agent_indices, ndrange=N)
    KernelAbstractions.synchronize(backend)

    return rebuilt
end
