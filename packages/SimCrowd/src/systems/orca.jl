# ── ORCA System ────────────────────────────────────────────────────────

using Ark
using KernelAbstractions
using StaticArrays
using LinearAlgebra
using CellListMap

struct ORCAGPUContext{F, VCPU<:AbstractVector, SCPU<:AbstractVector, VGPU<:AbstractVector, SGPU<:AbstractVector}
    N::Int
    # ── CPU staging buffers (written from ECS, then copyto! device) ──────────
    cpu_positions::VCPU
    cpu_velocities::VCPU
    cpu_radii::SCPU
    cpu_forces::VCPU
    cpu_v_prefs::VCPU        # Fix A: pre-allocated, avoids Vector{SVector}(undef,N) per step
    cpu_taus::SCPU           # Fix A: pre-allocated
    cpu_masses::SCPU         # Fix A: pre-allocated
    cpu_time_horizons::SCPU  # Fix D: per-agent (no more hardcoded 2.0f0)
    # ── Device buffers (unsorted, written from CPU) ───────────────────────────
    dev_positions::VGPU
    dev_velocities::VGPU
    dev_radii::SGPU
    dev_forces::VGPU
    dev_v_prefs::VGPU        # Fix A: pre-allocated on device
    dev_taus::SGPU           # Fix A: pre-allocated
    dev_masses::SGPU         # Fix A: pre-allocated
    dev_time_horizons::SGPU  # Fix D: per-agent
    # ── Sorted device buffers (Morton-ordered for coalesced access) ───────────
    sorted_dev_positions::VGPU
    sorted_dev_velocities::VGPU
    sorted_dev_radii::SGPU
    sorted_dev_v_prefs::VGPU        # Fix A
    sorted_dev_taus::SGPU           # Fix A
    sorted_dev_masses::SGPU         # Fix A
    sorted_dev_time_horizons::SGPU  # Fix D
    # ── Grid rebuild state ───────────────────────────────────────────────────
    last_build_positions::VGPU
    sorted_last_positions::VGPU
    needs_rebuild::AbstractArray{Bool, 1}
end

function ORCAGPUContext(backend, F, N::Int)
    VCPU = Vector{SVector{2,F}}
    SCPU = Vector{F}
    
    # CPU staging
    cpu_positions        = VCPU(undef, N)
    cpu_velocities       = VCPU(undef, N)
    cpu_radii            = SCPU(undef, N)
    cpu_forces           = VCPU(undef, N)
    cpu_v_prefs          = VCPU(undef, N)
    cpu_taus             = SCPU(undef, N)
    cpu_masses           = SCPU(undef, N)
    cpu_time_horizons    = SCPU(undef, N)
    
    # Unsorted device buffers
    dev_positions        = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_velocities       = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_radii            = KernelAbstractions.zeros(backend, F, N)
    dev_forces           = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_v_prefs          = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_taus             = KernelAbstractions.zeros(backend, F, N)
    dev_masses           = KernelAbstractions.zeros(backend, F, N)
    dev_time_horizons    = KernelAbstractions.zeros(backend, F, N)
    
    # Sorted device buffers
    sorted_dev_positions      = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_dev_velocities     = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_dev_radii          = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_v_prefs        = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_dev_taus           = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_masses         = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_time_horizons  = KernelAbstractions.zeros(backend, F, N)
    
    last_build_positions  = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_last_positions = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    needs_rebuild = KernelAbstractions.ones(backend, Bool, 1)
    
    VGPU = typeof(dev_positions)
    SGPU = typeof(dev_radii)
    
    return ORCAGPUContext{F, VCPU, SCPU, VGPU, SGPU}(
        N,
        cpu_positions, cpu_velocities, cpu_radii, cpu_forces,
        cpu_v_prefs, cpu_taus, cpu_masses, cpu_time_horizons,
        dev_positions, dev_velocities, dev_radii, dev_forces,
        dev_v_prefs, dev_taus, dev_masses, dev_time_horizons,
        sorted_dev_positions, sorted_dev_velocities, sorted_dev_radii,
        sorted_dev_v_prefs, sorted_dev_taus, sorted_dev_masses, sorted_dev_time_horizons,
        last_build_positions, sorted_last_positions, needs_rebuild
    )
end

const ORCA_GPU_CONTEXTS = IdDict{World, ORCAGPUContext}()
const ORCA_GPU_CONTEXTS_LOCK = Base.Threads.SpinLock()

function get_orca_gpu_context(world::World, backend, F, N::Int)
    lock(ORCA_GPU_CONTEXTS_LOCK)
    try
        ctx = get(ORCA_GPU_CONTEXTS, world, nothing)
        if ctx === nothing || ctx.N != N
            ctx = ORCAGPUContext(backend, F, N)
            ORCA_GPU_CONTEXTS[world] = ctx
        end
        return ctx
    finally
        unlock(ORCA_GPU_CONTEXTS_LOCK)
    end
end

function update_orca_system!(world::World, search::AbstractNeighborSearch, backend::Backend, dt::AbstractFloat)
    num_agents = count_entities(Query(world, (ORCAParams{Float32},)))
    if num_agents == 0
        return
    end
    
    F = typeof(search.cell_size)
    ctx = get_orca_gpu_context(world, backend, F, num_agents)
    
    # Use pre-allocated CPU staging buffers from context (Fix A: no heap alloc per step)
    positions     = ctx.cpu_positions
    velocities    = ctx.cpu_velocities
    radii         = ctx.cpu_radii
    v_prefs       = ctx.cpu_v_prefs
    taus          = ctx.cpu_taus
    masses        = ctx.cpu_masses
    time_horizons = ctx.cpu_time_horizons  # Fix D: per-agent, replaces hardcoded 2.0f0
    
    idx = 1
    for (entities, pos_col, vel_col, params_col, goal_col) in Query(world, (Position{F}, Velocity{F}, ORCAParams{F}, Goal{F}))
        for i in eachindex(pos_col)
            positions[idx]     = pos_col[i].p
            velocities[idx]    = vel_col[i].v
            radii[idx]         = params_col[i].radius
            taus[idx]          = params_col[i].τ
            masses[idx]        = params_col[i].mass
            time_horizons[idx] = params_col[i].time_horizon  # Fix D: per-agent
            
            dir  = goal_col[i].g - pos_col[i].p
            dist = norm(dir)
            v_prefs[idx] = dist > F(1e-3) ? (dir / dist) * params_col[i].v_pref : zero(SVector{2,F})
            
            idx += 1
        end
    end
    
    _update_orca_impl!(world, search, positions, velocities, radii, v_prefs, taus, masses, time_horizons, F(dt), backend, ctx)
end

@kernel function compute_orca_kernel!(
    forces, @Const(sorted_positions), @Const(sorted_velocities), @Const(sorted_radii),
    @Const(sorted_v_prefs), @Const(sorted_taus), @Const(sorted_masses),
    @Const(sorted_time_horizons),  # Fix D: per-agent time horizon (replaces scalar)
    @Const(sorted_last_positions),
    grid_min, grid_dims, cell_size, @Const(cell_starts), @Const(cell_ends), @Const(agent_indices),
    dt,
    ::Val{K}
) where {K}
    i = @index(Global, Linear)
    
    @inbounds begin
        original_i = agent_indices[i]
        
        pos_i      = sorted_positions[i]
        vel_i      = sorted_velocities[i]
        r_i        = sorted_radii[i]
        old_pos_i  = sorted_last_positions[i]
        v_pref_i   = sorted_v_prefs[i]
        tau_i      = sorted_taus[i]
        mass_i     = sorted_masses[i]
        time_h_i   = sorted_time_horizons[i]  # Fix D: per-agent time horizon
        
        idx = floor.(Int, (old_pos_i - grid_min) / cell_size)
        iter = SortedNeighborIterator(grid_min, grid_dims, cell_size, cell_starts, cell_ends, idx)
        
        # Maintain the closest K neighbors by squared distance
        best_d2 = MVector{K, typeof(cell_size)}(undef)
        best_idx = MVector{K, Int}(undef)
        best_count = 0
        
        for neighbor_idx in iter
            if neighbor_idx != i
                pos_j = sorted_positions[neighbor_idx]
                r_j = sorted_radii[neighbor_idx]
                
                # Check distance
                d2 = sum(abs2.(pos_i - pos_j))
                if d2 <= (r_i + r_j + 15.0f0)^2 # Interaction horizon
                    if best_count < K
                        best_count += 1
                        best_d2[best_count] = d2
                        best_idx[best_count] = neighbor_idx
                        # Insertion sort step
                        c = best_count
                        while c > 1 && best_d2[c] < best_d2[c-1]
                            tmp_d = best_d2[c]; best_d2[c] = best_d2[c-1]; best_d2[c-1] = tmp_d
                            tmp_i = best_idx[c]; best_idx[c] = best_idx[c-1]; best_idx[c-1] = tmp_i
                            c -= 1
                        end
                    else
                        if d2 < best_d2[K]
                            best_d2[K] = d2
                            best_idx[K] = neighbor_idx
                            c = K
                            while c > 1 && best_d2[c] < best_d2[c-1]
                                tmp_d = best_d2[c]; best_d2[c] = best_d2[c-1]; best_d2[c-1] = tmp_d
                                tmp_i = best_idx[c]; best_idx[c] = best_idx[c-1]; best_idx[c-1] = tmp_i
                                c -= 1
                            end
                        end
                    end
                end
            end
        end
        
        # Max neighbors we extract lines for (prevent register overflow)
        # We will collect lines into an MVector
        lines = MVector{K, Line{typeof(cell_size)}}(undef)
        num_lines = 0
        
        for k in 1:best_count
            n_idx = best_idx[k]
            pos_j = sorted_positions[n_idx]
            vel_j = sorted_velocities[n_idx]
            r_j   = sorted_radii[n_idx]
            
            # Fix D: use per-agent time_h_i instead of scalar time_horizon
            line = compute_orca_line(pos_i, vel_i, r_i, pos_j, vel_j, r_j, time_h_i, dt)
            num_lines += 1
            lines[num_lines] = line
        end
        
        # Now solve 2D LP
        fail_line, v_opt = linear_program_2_len(lines, num_lines, 5.0f0, v_pref_i, false, v_pref_i)
        
        if fail_line > 0
            # Fallback 3D LP (relaxing constraints)
            v_opt = linear_program_3_static(lines, num_lines, 0, fail_line, 5.0f0, v_opt)
        end
        
        # Safety net: If 3D LP somehow produced NaN/Inf due to extreme floating point edge cases, default to zero velocity
        if isnan(v_opt[1]) || isnan(v_opt[2]) || isinf(v_opt[1]) || isinf(v_opt[2])
            v_opt = SVector{2, typeof(cell_size)}(0.0f0, 0.0f0)
        end
        
        # Convert optimal velocity to steering force
        F_orca = mass_i * (v_opt - vel_i) / tau_i
        
        forces[original_i] = F_orca
    end
end

function _update_orca_impl!(world::World, search::RadixSpatialHash{AT,F}, positions, velocities, radii, v_prefs, taus, masses, time_horizons, dt::F, backend, ctx::ORCAGPUContext) where {AT,F}
    N = length(positions)
    
    # Fix A: Use pre-allocated device buffers from context — no per-step GPU malloc
    dev_positions     = ctx.dev_positions
    dev_velocities    = ctx.dev_velocities
    dev_radii         = ctx.dev_radii
    dev_forces        = ctx.dev_forces
    dev_v_prefs       = ctx.dev_v_prefs
    dev_taus          = ctx.dev_taus
    dev_masses        = ctx.dev_masses
    dev_time_horizons = ctx.dev_time_horizons
    
    # Upload all agent data to device
    copyto!(dev_positions,     positions)
    copyto!(dev_velocities,    velocities)
    copyto!(dev_radii,         radii)
    copyto!(dev_v_prefs,       v_prefs)
    copyto!(dev_taus,          taus)
    copyto!(dev_masses,        masses)
    copyto!(dev_time_horizons, time_horizons)
    
    # Lazy grid rebuild check (requires CPU read, so one mandatory sync here)
    sq_skin_radius = F(2.0)^2
    kernel_check! = check_rebuild_kernel!(backend)
    kernel_check!(ctx.needs_rebuild, dev_positions, ctx.last_build_positions, sq_skin_radius, ndrange=N)
    KernelAbstractions.synchronize(backend)  # mandatory: CPU must read needs_rebuild
    
    cpu_needs_rebuild = Vector{Bool}(undef, 1)
    copyto!(cpu_needs_rebuild, ctx.needs_rebuild)
    
    kernel_reorder! = reorder_array_kernel!(backend)
    
    if cpu_needs_rebuild[1]
        copyto!(ctx.last_build_positions, dev_positions)
        build_grid!(search, dev_positions, backend)
        kernel_reorder!(ctx.sorted_last_positions, ctx.last_build_positions, search.agent_indices, ndrange=N)
        fill!(ctx.needs_rebuild, false)
    end
    
    # Reorder all arrays to Morton order — Fix B: all submitted to same GPU stream,
    # no intermediate synchronize() needed. The ORCA kernel below will wait automatically.
    kernel_reorder!(ctx.sorted_dev_positions,     dev_positions,     search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_velocities,    dev_velocities,    search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_radii,         dev_radii,         search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_v_prefs,       dev_v_prefs,       search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_taus,          dev_taus,          search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_masses,        dev_masses,        search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_time_horizons, dev_time_horizons, search.agent_indices, ndrange=N)
    # Fix B: No synchronize() here — GPU stream ordering is automatic within the same stream.
    
    kernel! = compute_orca_kernel!(backend)
    kernel!(dev_forces,
        ctx.sorted_dev_positions, ctx.sorted_dev_velocities, ctx.sorted_dev_radii,
        ctx.sorted_dev_v_prefs, ctx.sorted_dev_taus, ctx.sorted_dev_masses,
        ctx.sorted_dev_time_horizons,  # Fix D: per-agent array
        ctx.sorted_last_positions,
        search.grid_min, search.grid_dims, search.cell_size,
        search.cell_starts, search.cell_ends, search.agent_indices,
        dt,
        Val(backend isa CPU ? 250 : 25),
        ndrange=N)
    KernelAbstractions.synchronize(backend)  # mandatory: CPU must wait for forces
    
    cpu_forces = ctx.cpu_forces
    copyto!(cpu_forces, dev_forces)
    
    idx = 1
    for (entities, pos_col, vel_col, params_col, goal_col, force_col) in Query(world, (Position{F}, Velocity{F}, ORCAParams{F}, Goal{F}, Force{F}))
        for i in eachindex(force_col)
            force_col[i] = Force(force_col[i].f + cpu_forces[idx])
            idx += 1
        end
    end
end

