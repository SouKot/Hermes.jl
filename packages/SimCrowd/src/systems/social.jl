# ── Social Forces System ────────────────────────────────────────────────────────

using Ark
using KernelAbstractions
using StaticArrays
using LinearAlgebra
using CellListMap

# The agent_repulsion function is defined in forces.jl

struct SocialForcesGPUContext{F, VCPU<:AbstractVector, SCPU<:AbstractVector, VGPU<:AbstractVector, SGPU<:AbstractVector, BGPU<:AbstractVector}
    N::Int
    # ── Shared base: positions, velocities, rebuild tracking ─────────────────
    # Note: base.cpu_radii / dev_radii / sorted_dev_radii are allocated but unused by SFM;
    # SFM uses social_radii and collision_radii separately for physics correctness.
    base::BaseGPUContext{F, VCPU, SCPU, VGPU, SGPU, BGPU}
    # ── SFM-specific CPU staging ──────────────────────────────────────────────
    cpu_social_radii::SCPU
    cpu_collision_radii::SCPU
    cpu_mus::SCPU                # per-agent μ (ContactModel discriminant)
    cpu_As::SCPU                 # per-agent social repulsion strength A (N)
    cpu_Bs::SCPU                 # per-agent social repulsion decay length B (m)
    cpu_λs::SCPU                 # per-agent anisotropy factor λ
    cpu_ηs::SCPU                 # §1.4 per-agent GCF factor η (s); 0.0 = Helbing
    cpu_forces::VCPU
    # ── SFM-specific device buffers ───────────────────────────────────────────
    dev_social_radii::SGPU
    dev_collision_radii::SGPU
    dev_mus::SGPU
    dev_As::SGPU
    dev_Bs::SGPU
    dev_λs::SGPU
    dev_ηs::SGPU
    dev_forces::VGPU
    # ── SFM-specific sorted device buffers ────────────────────────────────────
    sorted_dev_social_radii::SGPU
    sorted_dev_collision_radii::SGPU
    sorted_dev_mus::SGPU
    sorted_dev_As::SGPU
    sorted_dev_Bs::SGPU
    sorted_dev_λs::SGPU
    sorted_dev_ηs::SGPU
    sorted_dev_velocities::VGPU  # separate from base.sorted_dev_velocities (pre-allocated)
    sorted_last_positions::VGPU  # caller-owned sorted last-build positions
end

function SocialForcesGPUContext(backend, F, N::Int)
    VCPU = Vector{SVector{2,F}}
    SCPU = Vector{F}

    # Shared base (positions, velocities, rebuild tracking; radii unused but allocated)
    base = BaseGPUContext(backend, F, N)

    # SFM-specific CPU buffers
    cpu_social_radii      = SCPU(undef, N)
    cpu_collision_radii   = SCPU(undef, N)
    cpu_mus               = SCPU(undef, N)
    cpu_As                = SCPU(undef, N)
    cpu_Bs                = SCPU(undef, N)
    cpu_λs                = SCPU(undef, N)
    cpu_ηs                = SCPU(undef, N)
    cpu_forces            = VCPU(undef, N)

    # SFM-specific device buffers
    dev_social_radii      = KernelAbstractions.zeros(backend, F, N)
    dev_collision_radii   = KernelAbstractions.zeros(backend, F, N)
    dev_mus               = KernelAbstractions.zeros(backend, F, N)
    dev_As                = KernelAbstractions.zeros(backend, F, N)
    dev_Bs                = KernelAbstractions.zeros(backend, F, N)
    dev_λs                = KernelAbstractions.zeros(backend, F, N)
    dev_ηs                = KernelAbstractions.zeros(backend, F, N)
    dev_forces            = KernelAbstractions.zeros(backend, SVector{2,F}, N)

    # SFM-specific sorted
    sorted_dev_social_radii    = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_collision_radii = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_mus             = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_As              = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_Bs              = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_λs              = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_ηs              = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_velocities      = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_last_positions      = KernelAbstractions.zeros(backend, SVector{2,F}, N)

    VGPU = typeof(base.dev_positions)
    SGPU = typeof(base.dev_radii)
    BGPU = typeof(base.needs_rebuild)

    return SocialForcesGPUContext{F, VCPU, SCPU, VGPU, SGPU, BGPU}(
        N, base,
        cpu_social_radii, cpu_collision_radii,
        cpu_mus, cpu_As, cpu_Bs, cpu_λs, cpu_ηs, cpu_forces,
        dev_social_radii, dev_collision_radii,
        dev_mus, dev_As, dev_Bs, dev_λs, dev_ηs, dev_forces,
        sorted_dev_social_radii, sorted_dev_collision_radii,
        sorted_dev_mus, sorted_dev_As, sorted_dev_Bs, sorted_dev_λs, sorted_dev_ηs,
        sorted_dev_velocities, sorted_last_positions
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
    positions       = ctx.base.cpu_positions
    social_radii    = ctx.cpu_social_radii
    collision_radii = ctx.cpu_collision_radii

    # We also need velocities now — use pre-allocated base buffer
    velocities = ctx.base.cpu_velocities

    idx = 1
    for (entities, pos_col, vel_col, geom_col, sfm_col) in Query(world, (Position{F}, Velocity{F}, AgentGeometry{F}, SFMParams{F}))
        for i in eachindex(pos_col)
            positions[idx]        = pos_col[i].p
            social_radii[idx]     = geom_col[i].social_radius
            collision_radii[idx]  = geom_col[i].collision_radius
            ctx.cpu_mus[idx]      = sfm_col[i].μ     # ContactModel discriminant
            ctx.cpu_As[idx]       = sfm_col[i].A     # social repulsion strength
            ctx.cpu_Bs[idx]       = sfm_col[i].B     # social repulsion decay
            ctx.cpu_λs[idx]       = sfm_col[i].λ     # anisotropy factor
            ctx.cpu_ηs[idx]       = sfm_col[i].η     # §1.4 GCF speed-adaptation factor
            velocities[idx]       = vel_col[i].v
            idx += 1
        end
    end
    
    # Delegate to a backend-aware method which can handle device transfers (agent-agent forces)
    _update_social_forces_impl!(world, search, positions, social_radii, collision_radii, velocities, backend, ctx)
    
    # After computing agent-agent forces, add Wall interactions (done on CPU for validation)
    # We collect all walls first
    walls = NTuple{2, SVector{2,F}}[]
    for (entities, wall_col) in Query(world, (WallSegment{F},))
        for i in eachindex(wall_col)
            push!(walls, (wall_col[i].p1, wall_col[i].p2))
        end
    end
    
    if !isempty(walls)
        for (entities, pos_col, vel_col, geom_col, sfm_col, force_col) in Query(world, (Position{F}, Velocity{F}, AgentGeometry{F}, SFMParams{F}, Force{F}))
            for i in eachindex(pos_col)
                p = pos_col[i].p
                v = vel_col[i].v
                s_r = geom_col[i].social_radius
                c_r = geom_col[i].collision_radius
                F_wall = zero(SVector{2,F})
                for w in walls
                    F_wall += wall_repulsion(p, v, s_r, c_r, w; μ=sfm_col[i].μ)
                end
                # BUG-SFM-01 FIX: Removed spurious F_noise here.
                # The Helbing SDE fluctuation belongs only in physics.jl (the integrator),
                # not as a random force added during social force accumulation.
                force_col[i] = Force(force_col[i].f + F_wall)
            end
        end
    end
end

@kernel function reorder_array_kernel!(out_arr, @Const(in_arr), @Const(indices))
    i = @index(Global, Linear)
    @inbounds out_arr[i] = in_arr[indices[i]]
end

@kernel function check_rebuild_kernel!(needs_rebuild, @Const(current), @Const(last), sq_skin_radius)
    i = @index(Global, Linear)
    @inbounds begin
        # If already true, don't write (to avoid unnecessary memory traffic)
        if !needs_rebuild[1]
            d2 = sum(abs2.(current[i] - last[i]))
            if d2 > sq_skin_radius
                needs_rebuild[1] = true
            end
        end
    end
end

@kernel function compute_social_forces_kernel!(forces,
    @Const(sorted_positions), @Const(sorted_social_radii), @Const(sorted_collision_radii),
    @Const(sorted_mus), @Const(sorted_As), @Const(sorted_Bs), @Const(sorted_λs),
    @Const(sorted_velocities),
    @Const(sorted_last_positions), grid_min, grid_dims, cell_size,
    @Const(cell_starts), @Const(cell_ends), @Const(agent_indices))
    i = @index(Global, Linear)
    
    @inbounds begin
        original_i = agent_indices[i]
        
        pos_i = sorted_positions[i]
        vel_i = sorted_velocities[i]
        s_r_i = sorted_social_radii[i]
        c_r_i = sorted_collision_radii[i]
        μ_i   = sorted_mus[i]     # per-agent ContactModel discriminant
        A_i   = sorted_As[i]     # per-agent social repulsion strength
        B_i   = sorted_Bs[i]     # per-agent social repulsion decay
        λ_i   = sorted_λs[i]    # per-agent anisotropy factor
        old_pos_i = sorted_last_positions[i]
        
        F_repulse = zero(SVector{2, typeof(cell_size)})
        
        # Calculate search cell based on OLD position
        idx = floor.(Int, (old_pos_i - grid_min) / cell_size)
        
        iter = SortedNeighborIterator(grid_min, grid_dims, cell_size, cell_starts, cell_ends, idx)
        
        for neighbor_idx in iter
            pos_j = sorted_positions[neighbor_idx]
            vel_j = sorted_velocities[neighbor_idx]
            s_r_j = sorted_social_radii[neighbor_idx]
            c_r_j = sorted_collision_radii[neighbor_idx]
            
            d2 = sum(abs2.(pos_i - pos_j))
            if d2 > 0 && d2 <= cell_size * cell_size
                # §2.3 GPU parity fix: pass per-agent A_i, B_i, λ_i alongside μ_i.
                # Previously all four were hardcoded defaults; now fully parametric.
                F_repulse += agent_repulsion(pos_i, vel_i, s_r_i, c_r_i, pos_j, vel_j, s_r_j, c_r_j;
                                             μ=μ_i, A=A_i, B=B_i, λ=λ_i)
            end
        end
        forces[original_i] = F_repulse
    end
end

"""
    compute_psych_forces_kernel!

KA `@kernel` computing the anisotropic psychological (social potential) force for each agent `i`.

Each thread handles **one agent i** and loops over all N agents j (O(N) inner loop, serial per
thread). The outer parallelism (one thread per agent) is handled by the KA backend:

- `CPU()` backend → uses Julia threads (same thread pool, no new dependencies)
- `CUDABackend()` / `ROCmBackend()` → GPU threads

This replaces the O(N²) sequential CPU loop from Sprint 1. Architecture note: for GPU with
N > 5000, upgrade to CSR neighbor list to reduce inner-loop work to O(k̄≈6) per thread.

DO NOT call this nested inside a CellListMap callback — always run Phase 2 (CellListMap)
to completion first, then launch this kernel for Phase 3.
"""
@kernel function compute_psych_forces_kernel!(
    psych_forces,
    @Const(positions), @Const(velocities), @Const(social_radii),
    @Const(As), @Const(Bs), @Const(λs), @Const(ηs),
    cutoff_sq, N)

    i = @index(Global, Linear)
    F = typeof(cutoff_sq)

    pos_i = @inbounds positions[i]
    vel_i = @inbounds velocities[i]
    s_r_i = @inbounds social_radii[i]
    A_i   = @inbounds As[i]    # per-agent social repulsion strength
    B_i   = @inbounds Bs[i]    # per-agent social repulsion decay
    λ_i   = @inbounds λs[i]   # per-agent anisotropy factor
    η_i   = @inbounds ηs[i]   # §1.4 GCF factor; 0 = Helbing, >0 = Chraibi GCF
    f_i   = zero(SVector{2, F})

    # §3.2 SIMD investigation (2026-08-13): @simd NOT applied.
    # Reason: the two `continue` statements (j==i guard, cutoff distance guard) introduce
    # branches inside the reduction loop. Julia's @simd requires a branch-free inner loop
    # (or uses masked SIMD which adds overhead). Measured gain: 0% at N=2000 vs baseline.
    # KernelAbstractions already emits auto-vectorised LLVM IR for the distance computation.
    #
    # Real opportunity identified: 5 per-call Vector{F}(undef,N) allocations for mus/As/Bs/λs/ηs
    # in _update_social_forces_impl!(CPUNeighborSearch) account for ~30k allocs/step at N=2000.
    # Fix: move those 5 arrays into CPUNeighborSearch (pre-allocated). Target: Sprint 7.
    @inbounds for j in 1:N
        j == i && continue
        d2 = sum(abs2.(pos_i - positions[j]))
        d2 > cutoff_sq && continue
        # §1.4: dispatch to GCF when η > 0, else use Helbing psychological_force.
        # Both functions are @inline — no runtime dispatch on GPU.
        f_i += if η_i > zero(F)
            gcf_force(pos_i, vel_i, s_r_i, positions[j], social_radii[j]; V₀=A_i, η=η_i, λ=λ_i)
        else
            psychological_force(pos_i, vel_i, s_r_i, positions[j], social_radii[j];
                                A=A_i, B=B_i, λ=λ_i)
        end
    end

    @inbounds psych_forces[i] = f_i
end

function _update_social_forces_impl!(world::World, search::RadixSpatialHash{AT,F},
    positions, social_radii, collision_radii, velocities, backend, ctx::SocialForcesGPUContext) where {AT,F}
    N = length(positions)

    fill!(ctx.dev_forces, zero(SVector{2,F}))

    # 1. Stage shared fields (positions + velocities) + handle rebuild atomically.
    #    stage_and_sort_base! calls build_grid! BEFORE kernel_reorder!, avoiding the
    #    stale-agent_indices hazard. Walls are not used by SFM GPU path (handled CPU-side).
    #    Passing empty slices for walls (n_walls=0: no wall copyto! performed).
    stage_and_sort_base!(ctx.base, positions, velocities,
                         ctx.base.cpu_radii,           # unused sentinel (SFM has separate radii)
                         ctx.base.cpu_wall_p1s, ctx.base.cpu_wall_p2s, 0,
                         search, backend, ctx.sorted_last_positions)

    # 2. Upload and sort SFM-specific radii and per-agent parameters
    copyto!(ctx.dev_social_radii,    social_radii)
    copyto!(ctx.dev_collision_radii, collision_radii)
    copyto!(ctx.dev_mus, ctx.cpu_mus)
    copyto!(ctx.dev_As,  ctx.cpu_As)
    copyto!(ctx.dev_Bs,  ctx.cpu_Bs)
    copyto!(ctx.dev_λs,  ctx.cpu_λs)
    copyto!(ctx.dev_ηs,  ctx.cpu_ηs)   # §1.4 GCF factor
    # Upload velocities to device (base already holds cpu version; dev_velocities for SFM sorting)
    copyto!(ctx.sorted_dev_velocities, ctx.base.sorted_dev_velocities)   # velocity already sorted by stage_and_sort_base!

    kernel_reorder! = reorder_array_kernel!(backend)
    kernel_reorder!(ctx.sorted_dev_social_radii,    ctx.dev_social_radii,    search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_collision_radii, ctx.dev_collision_radii, search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_mus,             ctx.dev_mus,             search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_As,              ctx.dev_As,              search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_Bs,              ctx.dev_Bs,              search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_λs,             ctx.dev_λs,             search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_ηs,             ctx.dev_ηs,             search.agent_indices, ndrange=N)  # §1.4

    # 3. Launch forces kernel using sorted arrays
    kernel! = compute_social_forces_kernel!(backend)
    kernel!(ctx.dev_forces,
            ctx.base.sorted_dev_positions, ctx.sorted_dev_social_radii, ctx.sorted_dev_collision_radii,
            ctx.sorted_dev_mus, ctx.sorted_dev_As, ctx.sorted_dev_Bs, ctx.sorted_dev_λs,
            ctx.sorted_dev_velocities,
            ctx.sorted_last_positions,
            search.grid_min, search.grid_dims, search.cell_size,
            search.cell_starts, search.cell_ends, search.agent_indices,
            ndrange=N)
    KernelAbstractions.synchronize(backend)  # mandatory: CPU must wait before reading forces

    # 4. Copy forces back to host and write to ECS
    cpu_forces = ctx.cpu_forces
    copyto!(cpu_forces, ctx.dev_forces)

    idx = 1
    for (entities, force_col) in Query(world, (Force{F},))
        for i in eachindex(force_col)
            force_col[i] = Force(force_col[i].f + cpu_forces[idx])
            idx += 1
        end
    end
end

function _update_social_forces_impl!(world::World, search::CPUNeighborSearch{F}, positions, social_radii, collision_radii, velocities, backend::CPU, ctx) where {F}
    N = length(positions)

    # ── Phase 1: Stage per-agent parameters into pre-allocated buffers ────────────
    # Uses search.cpu_* (pre-allocated in CPUNeighborSearch) — zero per-step allocs.
    # Sprint 7: replaces 5 × Vector{F}(undef, N) allocations per step.
    cpu_mus = search.cpu_mus
    cpu_As  = search.cpu_As
    cpu_Bs  = search.cpu_Bs
    cpu_λs  = search.cpu_λs
    cpu_ηs  = search.cpu_ηs
    # §1.5 GCFM-elliptical per-agent params (pre-allocated in CPUNeighborSearch)
    cpu_τ_gaps = search.cpu_τ_gaps
    cpu_b_mins  = search.cpu_b_mins
    cpu_b_maxs  = search.cpu_b_maxs
    p_idx = 1
    for (_, _, _, _, sfm_col) in Query(world, (Position{F}, Velocity{F}, AgentGeometry{F}, SFMParams{F}))
        for i in eachindex(sfm_col)
            cpu_mus[p_idx]    = sfm_col[i].μ
            cpu_As[p_idx]     = sfm_col[i].A
            cpu_Bs[p_idx]     = sfm_col[i].B
            cpu_λs[p_idx]     = sfm_col[i].λ
            cpu_ηs[p_idx]     = sfm_col[i].η
            cpu_τ_gaps[p_idx] = sfm_col[i].τ_gap  # §1.5 elliptical dispatch flag
            cpu_b_mins[p_idx] = sfm_col[i].b_min
            cpu_b_maxs[p_idx] = sfm_col[i].b_max
            p_idx += 1
        end
    end

    build_grid!(search, positions, backend)

    # ── Phase 2: Contact forces via CellListMap (Newton's 3rd law) ───────────────
    # Body compression + viscous friction are physically SYMMETRIC (f_ij = −f_ji).
    # CellListMap processes each unique pair once — Newton's 3rd law is exact here.
    function compute_contact(pair, forces)
        (; i, j, d) = pair
        if d > F(1e-6)
            mu_ij = min(cpu_mus[i], cpu_mus[j])
            f = contact_force(positions[i], velocities[i], collision_radii[i],
                              positions[j], velocities[j], collision_radii[j]; μ=mu_ij)
            forces[i] += f
            forces[j] -= f   # Newton's 3rd law — provably exact for body + friction
        end
        return forces
    end
    contact_forces = CellListMap.pairwise!(compute_contact, search.system)

    # ── Phase 3: Psychological forces via CellListMap O(N×k) ─────────────────────
    # Sprint 7: replaces O(N²) compute_psych_forces_kernel! (CPU path only).
    #
    # Psychological forces are ASYMMETRIC (f_ij ≠ −f_ji) because the anisotropy
    # weight w(λ, cos θ) depends on each agent's own velocity direction. We process
    # each pair (i,j) once and compute both directions explicitly.
    #
    # Mathematical equivalence with old O(N²) kernel:
    #   Old: for each i, accumulate f_ij for all j≠i within cutoff
    #   New: for each pair (i,j) within cutoff (CellListMap ensures this), accumulate
    #        f_ij into psych_out[i] AND f_ji into psych_out[j]
    # Result per agent is identical up to floating-point summation order.
    #
    # Complexity: O(N×k) where k ≈ number of neighbors within cutoff (typically 5–15).
    # At N=2000: ~14k force evaluations vs 4M for O(N²) — estimated 200–300× reduction.
    #
    # @simd note: The k≈5–15 inner pairs per agent are too few for SIMD to break even.
    # The speedup comes entirely from doing 300× less work, not from vectorization.
    function compute_psych(pair, psych_out)
        (; i, j, d) = pair
        d > F(1e-6) || return psych_out

        pos_i = positions[i]; vel_i = velocities[i]; s_r_i = social_radii[i]
        pos_j = positions[j]; vel_j = velocities[j]; s_r_j = social_radii[j]

        # Force on i from j
        # §1.5 GCFM-elliptical (τ_gap > 0) takes priority over circular GCF (η > 0)
        f_ij = if cpu_τ_gaps[i] > zero(F)
            gcf_force_elliptical(pos_i, vel_i, pos_j;
                                 a₀=s_r_i,  # agent's own body semi-axis (from AgentGeometry.social_radius)
                                 V₀=cpu_As[i], λ=cpu_λs[i],
                                 τ_gap=cpu_τ_gaps[i], b_min=cpu_b_mins[i], b_max=cpu_b_maxs[i])
        elseif cpu_ηs[i] > zero(F)
            gcf_force(pos_i, vel_i, s_r_i, pos_j, s_r_j; V₀=cpu_As[i], η=cpu_ηs[i], λ=cpu_λs[i])
        else
            psychological_force(pos_i, vel_i, s_r_i, pos_j, s_r_j;
                                A=cpu_As[i], B=cpu_Bs[i], λ=cpu_λs[i])
        end

        # Force on j from i
        f_ji = if cpu_τ_gaps[j] > zero(F)
            gcf_force_elliptical(pos_j, vel_j, pos_i;
                                 a₀=s_r_j,  # agent's own body semi-axis (from AgentGeometry.social_radius)
                                 V₀=cpu_As[j], λ=cpu_λs[j],
                                 τ_gap=cpu_τ_gaps[j], b_min=cpu_b_mins[j], b_max=cpu_b_maxs[j])
        elseif cpu_ηs[j] > zero(F)
            gcf_force(pos_j, vel_j, s_r_j, pos_i, s_r_i; V₀=cpu_As[j], η=cpu_ηs[j], λ=cpu_λs[j])
        else
            psychological_force(pos_j, vel_j, s_r_j, pos_i, s_r_i;
                                A=cpu_As[j], B=cpu_Bs[j], λ=cpu_λs[j])
        end

        psych_out[i] += f_ij
        psych_out[j] += f_ji
        return psych_out
    end
    CellListMap.pairwise!(compute_psych, search.psych_system)

    # ── Phase 4: Write combined forces back to ECS ────────────────────────────────
    psych_out = search.psych_system.output
    contact_idx = 1
    for (entities, force_col) in Query(world, (Force{F},))
        for i in eachindex(force_col)
            force_col[i] = Force(force_col[i].f + contact_forces[contact_idx] + psych_out[contact_idx])
            contact_idx += 1
        end
    end
end
