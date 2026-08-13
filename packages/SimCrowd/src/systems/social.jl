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
    cpu_social_radii::SCPU
    cpu_collision_radii::SCPU
    cpu_mus::SCPU                # per-agent μ (ContactModel discriminant)
    cpu_As::SCPU                 # per-agent social repulsion strength A (N)
    cpu_Bs::SCPU                 # per-agent social repulsion decay length B (m)
    cpu_λs::SCPU                 # per-agent anisotropy factor λ
    cpu_velocities::VCPU     # pre-allocated: avoids Vector{SVector}(undef, N) per step
    cpu_forces::VCPU
    
    dev_positions::VGPU
    dev_social_radii::SGPU
    dev_collision_radii::SGPU
    dev_mus::SGPU                # per-agent μ on device
    dev_As::SGPU                 # per-agent A on device
    dev_Bs::SGPU                 # per-agent B on device
    dev_λs::SGPU                 # per-agent λ on device
    dev_velocities::VGPU     # pre-allocated: avoids KernelAbstractions.zeros per step
    dev_forces::VGPU
    
    sorted_dev_positions::VGPU
    sorted_dev_social_radii::SGPU
    sorted_dev_collision_radii::SGPU
    sorted_dev_mus::SGPU         # per-agent μ, sorted by radix key
    sorted_dev_As::SGPU          # per-agent A, sorted
    sorted_dev_Bs::SGPU          # per-agent B, sorted
    sorted_dev_λs::SGPU          # per-agent λ, sorted
    sorted_dev_velocities::VGPU  # pre-allocated
    
    last_build_positions::VGPU
    sorted_last_positions::VGPU
    needs_rebuild::AbstractArray{Bool, 1}
end

function SocialForcesGPUContext(backend, F, N::Int)
    VCPU = Vector{SVector{2,F}}
    SCPU = Vector{F}
    
    cpu_positions         = VCPU(undef, N)
    cpu_social_radii      = SCPU(undef, N)
    cpu_collision_radii   = SCPU(undef, N)
    cpu_mus               = SCPU(undef, N)  # per-agent μ
    cpu_As                = SCPU(undef, N)  # per-agent A
    cpu_Bs                = SCPU(undef, N)  # per-agent B
    cpu_λs                = SCPU(undef, N)  # per-agent λ
    cpu_velocities        = VCPU(undef, N)  # pre-allocated
    cpu_forces            = VCPU(undef, N)
    
    dev_positions         = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_social_radii      = KernelAbstractions.zeros(backend, F, N)
    dev_collision_radii   = KernelAbstractions.zeros(backend, F, N)
    dev_mus               = KernelAbstractions.zeros(backend, F, N)  # per-agent μ
    dev_As                = KernelAbstractions.zeros(backend, F, N)  # per-agent A
    dev_Bs                = KernelAbstractions.zeros(backend, F, N)  # per-agent B
    dev_λs                = KernelAbstractions.zeros(backend, F, N)  # per-agent λ
    dev_velocities        = KernelAbstractions.zeros(backend, SVector{2,F}, N)  # pre-allocated
    dev_forces            = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    
    sorted_dev_positions       = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_dev_social_radii    = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_collision_radii = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_mus             = KernelAbstractions.zeros(backend, F, N)  # per-agent μ, sorted
    sorted_dev_As              = KernelAbstractions.zeros(backend, F, N)  # per-agent A, sorted
    sorted_dev_Bs              = KernelAbstractions.zeros(backend, F, N)  # per-agent B, sorted
    sorted_dev_λs              = KernelAbstractions.zeros(backend, F, N)  # per-agent λ, sorted
    sorted_dev_velocities      = KernelAbstractions.zeros(backend, SVector{2,F}, N)  # pre-allocated
    
    last_build_positions  = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_last_positions = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    needs_rebuild = KernelAbstractions.ones(backend, Bool, 1)
    
    VGPU = typeof(dev_positions)
    SGPU = typeof(dev_social_radii)
    
    return SocialForcesGPUContext{F, VCPU, SCPU, VGPU, SGPU}(
        N, cpu_positions, cpu_social_radii, cpu_collision_radii,
        cpu_mus, cpu_As, cpu_Bs, cpu_λs,
        cpu_velocities, cpu_forces,
        dev_positions, dev_social_radii, dev_collision_radii,
        dev_mus, dev_As, dev_Bs, dev_λs,
        dev_velocities, dev_forces,
        sorted_dev_positions, sorted_dev_social_radii, sorted_dev_collision_radii,
        sorted_dev_mus, sorted_dev_As, sorted_dev_Bs, sorted_dev_λs,
        sorted_dev_velocities,
        last_build_positions, sorted_last_positions, needs_rebuild
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
    social_radii = ctx.cpu_social_radii
    collision_radii = ctx.cpu_collision_radii
    
    # We also need velocities now — use pre-allocated context buffer
    velocities = ctx.cpu_velocities
    
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
    @Const(As), @Const(Bs), @Const(λs),
    cutoff_sq, N)

    i = @index(Global, Linear)
    F = typeof(cutoff_sq)

    pos_i = @inbounds positions[i]
    vel_i = @inbounds velocities[i]
    s_r_i = @inbounds social_radii[i]
    A_i   = @inbounds As[i]    # per-agent social repulsion strength
    B_i   = @inbounds Bs[i]    # per-agent social repulsion decay
    λ_i   = @inbounds λs[i]   # per-agent anisotropy factor
    f_i   = zero(SVector{2, F})

    @inbounds for j in 1:N
        j == i && continue
        d2 = sum(abs2.(pos_i - positions[j]))
        d2 > cutoff_sq && continue
        f_i += psychological_force(pos_i, vel_i, s_r_i, positions[j], social_radii[j];
                                   A=A_i, B=B_i, λ=λ_i)
    end

    @inbounds psych_forces[i] = f_i
end

function _update_social_forces_impl!(world::World, search::RadixSpatialHash{AT,F},
    positions, social_radii, collision_radii, velocities, backend, ctx::SocialForcesGPUContext) where {AT,F}
    N = length(positions)
    
    dev_positions = ctx.dev_positions
    dev_social_radii = ctx.dev_social_radii
    dev_collision_radii = ctx.dev_collision_radii
    dev_forces = ctx.dev_forces
    
    fill!(dev_forces, zero(SVector{2,F}))
    
    # 2. Copy data to device
    copyto!(dev_positions, positions)
    copyto!(dev_social_radii, social_radii)
    copyto!(dev_collision_radii, collision_radii)
    
    # 3. Lazy Rebuild Check
    sq_skin_radius = F(2.0)^2
    kernel_check! = check_rebuild_kernel!(backend)
    kernel_check!(ctx.needs_rebuild, dev_positions, ctx.last_build_positions, sq_skin_radius, ndrange=N)
    KernelAbstractions.synchronize(backend)
    
    cpu_needs_rebuild = Vector{Bool}(undef, 1)
    copyto!(cpu_needs_rebuild, ctx.needs_rebuild)
    
    kernel_reorder! = reorder_array_kernel!(backend)
    
    if cpu_needs_rebuild[1]
        copyto!(ctx.last_build_positions, dev_positions)
        build_grid!(search, dev_positions, backend)
        
        # Reorder the last_build_positions ONCE so it's coalesced for the physics kernel
        kernel_reorder!(ctx.sorted_last_positions, ctx.last_build_positions, search.agent_indices, ndrange=N)
        
        fill!(ctx.needs_rebuild, false)
    end
    
    # 4. ALWAYS reorder current positions/radii/velocities/mus/A/B/λ using current agent_indices
    kernel_reorder!(ctx.sorted_dev_positions,       dev_positions,           search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_social_radii,    dev_social_radii,        search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_collision_radii, dev_collision_radii,     search.agent_indices, ndrange=N)
    # Upload and sort per-agent μ, A, B, λ (GPU parameter parity — §2.3)
    copyto!(ctx.dev_mus, ctx.cpu_mus)
    copyto!(ctx.dev_As,  ctx.cpu_As)
    copyto!(ctx.dev_Bs,  ctx.cpu_Bs)
    copyto!(ctx.dev_λs,  ctx.cpu_λs)
    kernel_reorder!(ctx.sorted_dev_mus,             ctx.dev_mus,             search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_As,              ctx.dev_As,              search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_Bs,              ctx.dev_Bs,              search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_λs,             ctx.dev_λs,             search.agent_indices, ndrange=N)
    # Use pre-allocated ctx buffers for velocities (Fix A: no per-step GPU malloc)
    copyto!(ctx.dev_velocities, velocities)
    kernel_reorder!(ctx.sorted_dev_velocities,      ctx.dev_velocities,      search.agent_indices, ndrange=N)
    # Fix B: No synchronize() here — GPU stream ordering is automatic.
    # The compute kernel below will wait for all reorders on the same stream.
    
    # 5. Launch forces kernel using sorted arrays
    kernel! = compute_social_forces_kernel!(backend)
    kernel!(dev_forces,
            ctx.sorted_dev_positions, ctx.sorted_dev_social_radii, ctx.sorted_dev_collision_radii,
            ctx.sorted_dev_mus, ctx.sorted_dev_As, ctx.sorted_dev_Bs, ctx.sorted_dev_λs,
            ctx.sorted_dev_velocities,
            ctx.sorted_last_positions,
            search.grid_min, search.grid_dims, search.cell_size,
            search.cell_starts, search.cell_ends, search.agent_indices,
            ndrange=N)
    KernelAbstractions.synchronize(backend)  # mandatory: CPU must wait before reading forces
    
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

function _update_social_forces_impl!(world::World, search::CPUNeighborSearch{F}, positions, social_radii, collision_radii, velocities, backend::CPU, ctx) where {F}
    N = length(positions)

    # ── Phase 1: Per-agent parameter extraction ────────────────────────────────────────────
    # μ: Coulomb friction cap is per-agent (scenarios differ: μ=0.5 walking, μ=10 panic).
    # A, B, λ: social force parameters for heterogeneous crowd support (§2.3 CPU parity).
    # These allocations are N×4 bytes each; negligible compared to CellListMap overhead.
    mus = Vector{F}(undef, N)
    As  = Vector{F}(undef, N)
    Bs  = Vector{F}(undef, N)
    λs  = Vector{F}(undef, N)
    p_idx = 1
    for (_, _, _, sfm_col) in Query(world, (Position{F}, Velocity{F}, AgentGeometry{F}, SFMParams{F}))
        for i in eachindex(sfm_col)
            mus[p_idx] = sfm_col[i].μ
            As[p_idx]  = sfm_col[i].A
            Bs[p_idx]  = sfm_col[i].B
            λs[p_idx]  = sfm_col[i].λ
            p_idx += 1
        end
    end

    build_grid!(search, positions, backend)

    # ── Phase 2: Contact forces via CellListMap (Newton's 3rd law) ──────────────────
    # Body compression + viscous friction are physically SYMMETRIC (f_ij = −f_ji).
    # CellListMap processes each unique pair once — Newton's 3rd law is exact here.
    function compute_contact(pair, forces)
        (; i, j, d) = pair
        if d > F(1e-6)
            mu_ij = min(mus[i], mus[j])
            f = contact_force(positions[i], velocities[i], collision_radii[i],
                              positions[j], velocities[j], collision_radii[j]; μ=mu_ij)
            forces[i] += f
            forces[j] -= f   # Newton's 3rd law — provably exact for body + friction
        end
        return forces
    end
    contact_forces = CellListMap.pairwise!(compute_contact, search.system)

    # ── Phase 3: Psychological forces via KA @kernel ──────────────────────────────
    # The anisotropy weight w depends on each agent's own velocity direction, so
    # f_ij ≠ −f_ji — must be computed per-agent. The KA kernel parallelises
    # over agents (outer loop) while the inner j-loop stays serial per thread.
    #
    # CPU() backend: uses Julia threads. No Polyester, no new dependencies.
    # Any GPU backend: same kernel, zero code changes.
    # Called AFTER Phase 2 (CellListMap) completes — no nested thread pool conflict.
    psych_forces = search.psych_forces
    cutoff_sq    = search.cell_size * search.cell_size

    psych_kernel! = compute_psych_forces_kernel!(backend)
    psych_kernel!(psych_forces, positions, velocities, social_radii, As, Bs, λs, cutoff_sq, N, ndrange=N)
    KernelAbstractions.synchronize(backend)

    # ── Phase 4: Write combined forces back to ECS ────────────────────────────────
    contact_idx = 1
    for (entities, force_col) in Query(world, (Force{F},))
        for i in eachindex(force_col)
            force_col[i] = Force(force_col[i].f + contact_forces[contact_idx] + psych_forces[contact_idx])
            contact_idx += 1
        end
    end
end
