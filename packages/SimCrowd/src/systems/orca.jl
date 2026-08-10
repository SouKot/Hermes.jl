# ── ORCA System ────────────────────────────────────────────────────────

using Ark
using KernelAbstractions
using StaticArrays
using LinearAlgebra
using CellListMap

struct ORCAGPUContext{F, VCPU<:AbstractVector, SCPU<:AbstractVector, VGPU<:AbstractVector, SGPU<:AbstractVector}
    N::Int
    cpu_positions::VCPU
    cpu_velocities::VCPU
    cpu_radii::SCPU
    cpu_forces::VCPU
    
    dev_positions::VGPU
    dev_velocities::VGPU
    dev_radii::SGPU
    dev_forces::VGPU
    
    sorted_dev_positions::VGPU
    sorted_dev_velocities::VGPU
    sorted_dev_radii::SGPU
    
    last_build_positions::VGPU
    sorted_last_positions::VGPU
    needs_rebuild::AbstractArray{Bool, 1}
end

function ORCAGPUContext(backend, F, N::Int)
    VCPU = Vector{SVector{2,F}}
    SCPU = Vector{F}
    
    cpu_positions = VCPU(undef, N)
    cpu_velocities = VCPU(undef, N)
    cpu_radii = SCPU(undef, N)
    cpu_forces = VCPU(undef, N)
    
    dev_positions = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_velocities = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_radii = KernelAbstractions.zeros(backend, F, N)
    dev_forces = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    
    sorted_dev_positions = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_dev_velocities = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_dev_radii = KernelAbstractions.zeros(backend, F, N)
    
    last_build_positions = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_last_positions = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    needs_rebuild = KernelAbstractions.ones(backend, Bool, 1) # init to true
    
    VGPU = typeof(dev_positions)
    SGPU = typeof(dev_radii)
    
    return ORCAGPUContext{F, VCPU, SCPU, VGPU, SGPU}(
        N, cpu_positions, cpu_velocities, cpu_radii, cpu_forces,
        dev_positions, dev_velocities, dev_radii, dev_forces,
        sorted_dev_positions, sorted_dev_velocities, sorted_dev_radii,
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
    
    positions = ctx.cpu_positions
    velocities = ctx.cpu_velocities
    radii = ctx.cpu_radii
    
    # Pre-allocate ORCA params arrays (cpu only for now, assume uniform params for kernel, or pass arrays)
    # To be extremely scalable, we should pass param arrays. But usually time_horizon is global.
    # Let's extract params.
    v_prefs = Vector{SVector{2,F}}(undef, num_agents)
    taus = Vector{F}(undef, num_agents)
    masses = Vector{F}(undef, num_agents)
    max_neighbors_val = 10 # Hardcoded max for array sizing
    time_horizon_val = 2.0f0
    
    idx = 1
    for (entities, pos_col, vel_col, params_col, goal_col) in Query(world, (Position{F}, Velocity{F}, ORCAParams{F}, Goal{F}))
        for i in eachindex(pos_col)
            positions[idx] = pos_col[i].p
            velocities[idx] = vel_col[i].v
            radii[idx] = params_col[i].radius
            
            # v_pref direction
            dir = goal_col[i].g - pos_col[i].p
            dist = norm(dir)
            if dist > 1e-3
                v_prefs[idx] = (dir / dist) * params_col[i].v_pref
            else
                v_prefs[idx] = zero(SVector{2,F})
            end
            
            taus[idx] = params_col[i].τ
            masses[idx] = params_col[i].mass
            
            # We assume uniform time horizon for the GPU kernel for simplicity right now.
            time_horizon_val = params_col[i].time_horizon
            
            idx += 1
        end
    end
    
    _update_orca_impl!(world, search, positions, velocities, radii, v_prefs, taus, masses, time_horizon_val, F(dt), backend, ctx)
end

@kernel function compute_orca_kernel!(
    forces, @Const(sorted_positions), @Const(sorted_velocities), @Const(sorted_radii),
    @Const(sorted_v_prefs), @Const(sorted_taus), @Const(sorted_masses), @Const(sorted_last_positions),
    grid_min, grid_dims, cell_size, @Const(cell_starts), @Const(cell_ends), @Const(agent_indices),
    time_horizon, dt
)
    i = @index(Global, Linear)
    
    @inbounds begin
        original_i = agent_indices[i]
        
        pos_i = sorted_positions[i]
        vel_i = sorted_velocities[i]
        r_i = sorted_radii[i]
        old_pos_i = sorted_last_positions[i]
        v_pref_i = sorted_v_prefs[i]
        tau_i = sorted_taus[i]
        mass_i = sorted_masses[i]
        
        idx = floor.(Int, (old_pos_i - grid_min) / cell_size)
        iter = SortedNeighborIterator(grid_min, grid_dims, cell_size, cell_starts, cell_ends, idx)
        
        # Max neighbors we extract lines for (prevent register overflow)
        # We will collect lines into an MVector
        lines = MVector{10, Line{typeof(cell_size)}}(undef)
        num_lines = 0
        
        for neighbor_idx in iter
            if neighbor_idx != i && num_lines < 10
                pos_j = sorted_positions[neighbor_idx]
                vel_j = sorted_velocities[neighbor_idx]
                r_j = sorted_radii[neighbor_idx]
                
                # Check distance
                d2 = sum(abs2.(pos_i - pos_j))
                if d2 <= (r_i + r_j + 5.0f0)^2 # Interaction horizon
                    line = compute_orca_line(pos_i, vel_i, r_i, pos_j, vel_j, r_j, time_horizon, dt)
                    num_lines += 1
                    lines[num_lines] = line
                end
            end
        end
        
        # Now solve 2D LP
        fail_line, v_opt = linear_program_2_len(lines, num_lines, 5.0f0, v_pref_i, false, v_pref_i)
        
        if fail_line > 0
            # Fallback 3D LP (relaxing constraints)
            # v_opt = linear_program_3_static(lines, num_lines, 0, fail_line, 5.0f0, v_opt)
            # Actually, to save registers and simplicity, if 2D LP fails, we just use the last valid result
            # RVO2's 3D LP is quite heavy. Let's try skipping it first to see if 2D LP suffices for our tests.
            # Usually fallback is needed in super dense situations.
            v_opt = linear_program_3_static(lines, num_lines, 0, fail_line, 5.0f0, v_opt)
        end
        
        # Convert optimal velocity to steering force
        F_orca = mass_i * (v_opt - vel_i) / tau_i
        
        forces[original_i] = F_orca
    end
end

function _update_orca_impl!(world::World, search::RadixSpatialHash{AT,F}, positions, velocities, radii, v_prefs, taus, masses, time_horizon, dt::F, backend, ctx::ORCAGPUContext) where {AT,F}
    N = length(positions)
    
    dev_positions = ctx.dev_positions
    dev_velocities = ctx.dev_velocities
    dev_radii = ctx.dev_radii
    dev_forces = ctx.dev_forces
    
    copyto!(dev_positions, positions)
    copyto!(dev_velocities, velocities)
    copyto!(dev_radii, radii)
    
    # We re-use social grid building logic exactly
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
        kernel_reorder!(ctx.sorted_last_positions, ctx.last_build_positions, search.agent_indices, ndrange=N)
        fill!(ctx.needs_rebuild, false)
    end
    
    kernel_reorder!(ctx.sorted_dev_positions, dev_positions, search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_velocities, dev_velocities, search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_radii, dev_radii, search.agent_indices, ndrange=N)
    
    # Temporary dev arrays for params
    dev_v_prefs = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_taus = KernelAbstractions.zeros(backend, F, N)
    dev_masses = KernelAbstractions.zeros(backend, F, N)
    copyto!(dev_v_prefs, v_prefs)
    copyto!(dev_taus, taus)
    copyto!(dev_masses, masses)
    
    sorted_v_prefs = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_taus = KernelAbstractions.zeros(backend, F, N)
    sorted_masses = KernelAbstractions.zeros(backend, F, N)
    
    kernel_reorder!(sorted_v_prefs, dev_v_prefs, search.agent_indices, ndrange=N)
    kernel_reorder!(sorted_taus, dev_taus, search.agent_indices, ndrange=N)
    kernel_reorder!(sorted_masses, dev_masses, search.agent_indices, ndrange=N)
    KernelAbstractions.synchronize(backend)
    
    kernel! = compute_orca_kernel!(backend)
    kernel!(dev_forces, ctx.sorted_dev_positions, ctx.sorted_dev_velocities, ctx.sorted_dev_radii,
        sorted_v_prefs, sorted_taus, sorted_masses, ctx.sorted_last_positions,
        search.grid_min, search.grid_dims, search.cell_size, 
        search.cell_starts, search.cell_ends, search.agent_indices, 
        time_horizon, dt,
        ndrange=N)
    KernelAbstractions.synchronize(backend)
    
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

function _update_orca_impl!(world::World, search::CPUNeighborSearch{F}, positions, velocities, radii, v_prefs, taus, masses, time_horizon, dt::F, backend::CPU, ctx) where {F}
    build_grid!(search, positions, backend)
    
    # For CPU backend fallback, just use the exact same kernel logic via mapping
    N = length(positions)
    forces = zeros(SVector{2,F}, N)
    
    for i in 1:N
        pos_i = positions[i]
        vel_i = velocities[i]
        r_i = radii[i]
        v_pref_i = v_prefs[i]
        
        lines = MVector{20, Line{F}}(undef)
        num_lines = 0
        
        for j in 1:N
            if i != j
                pos_j = positions[j]
                vel_j = velocities[j]
                r_j = radii[j]
                
                d2 = sum(abs2.(pos_i - pos_j))
                if d2 <= (r_i + r_j + 5.0f0)^2
                    line = compute_orca_line(pos_i, vel_i, r_i, pos_j, vel_j, r_j, time_horizon, dt)
                    num_lines += 1
                    if num_lines <= 20
                        lines[num_lines] = line
                    end
                end
            end
        end
        num_lines = min(num_lines, 20)
        
        fail_line, v_opt = linear_program_2_len(lines, num_lines, 5.0f0, v_pref_i, false, v_pref_i)
        if fail_line > 0
            v_opt = linear_program_3_static(lines, num_lines, 0, fail_line, 5.0f0, v_opt)
        end
        
        forces[i] = masses[i] * (v_opt - vel_i) / taus[i]
    end
    
    idx = 1
    for (entities, pos_col, vel_col, params_col, goal_col, force_col) in Query(world, (Position{F}, Velocity{F}, ORCAParams{F}, Goal{F}, Force{F}))
        for i in eachindex(force_col)
            force_col[i] = Force(force_col[i].f + forces[idx])
            idx += 1
        end
    end
end
