using KernelAbstractions
using StaticArrays
using LinearAlgebra

# Fix C: Per-thread pre-allocated neighbor buffers — eliminates per-agent heap allocation
# inside the @threads loop. Initialized lazily on first call, reused every step.
# This removes ~4MB/step of GC pressure at N=1000.
const _ORCA_NEIGHBOR_BUFS = Ref{Vector{Vector{Tuple{Float32, Int}}}}()

function _get_neighbor_bufs()
    # Julia 1.12: Threads.threadid() inside @threads can return IDs up to
    # Threads.maxthreadid() (includes interactive helper threads), not just nthreads().
    # Allocate for maxthreadid() to prevent BoundsError.
    n = Threads.maxthreadid()
    if !isassigned(_ORCA_NEIGHBOR_BUFS) || length(_ORCA_NEIGHBOR_BUFS[]) < n
        _ORCA_NEIGHBOR_BUFS[] = [Tuple{Float32, Int}[] for _ in 1:n]
    end
    return _ORCA_NEIGHBOR_BUFS[]
end

# CPU-only implementation that uses dynamic Vectors to handle infinite neighbors
function update_orca_system_cpu!(world, dt::F) where {F<:AbstractFloat}
    # Count entities
    N = 0
    for (entities, pos_col) in Query(world, (Position{F},))
        N += length(pos_col)
    end
    
    # Pre-extract all per-agent data (avoids repeated Query inside the hot loop)
    positions      = Vector{SVector{2,F}}(undef, N)
    velocities     = Vector{SVector{2,F}}(undef, N)
    radii          = Vector{F}(undef, N)
    v_prefs        = Vector{F}(undef, N)
    lp_radii       = Vector{F}(undef, N)   # LP velocity-disc radius = orca.v_pref (max speed)
    time_horizons  = Vector{F}(undef, N)
    max_neighbors  = Vector{Int}(undef, N) # per-agent cap on ORCA constraints (RVO2: 10)
    neighbor_dists = Vector{F}(undef, N)   # per-agent neighbor search radius (RVO2: 15m)
    goals          = Vector{SVector{2,F}}(undef, N)
    masses         = Vector{F}(undef, N)
    
    idx = 1
    for (entities, pos_col, vel_col, params_col, orca_col, goal_col) in Query(world, (Position{F}, Velocity{F}, AgentParams{F}, ORCAParams{F}, Goal{F}))
        for i in eachindex(pos_col)
            positions[idx]     = pos_col[i].p
            velocities[idx]    = vel_col[i].v
            radii[idx]         = orca_col[i].radius
            v_prefs[idx]       = orca_col[i].v_pref
            lp_radii[idx]      = orca_col[i].v_pref  # LP disc radius = max speed (stored as v_pref in ORCAParams)
            time_horizons[idx] = orca_col[i].time_horizon
            max_neighbors[idx] = orca_col[i].max_neighbors
            neighbor_dists[idx]= orca_col[i].neighbor_dist
            goals[idx]         = goal_col[i].g
            masses[idx]        = params_col[i].mass
            idx += 1
        end
    end
    
    if N == 0
        return
    end
    
    new_velocities = copy(velocities)
    
    # Fix C: Get pre-allocated per-thread neighbor buffers (zero allocation per step)
    neighbor_bufs = _get_neighbor_bufs()
    
    # O(N²) LP solve — each agent's computation is fully independent (safe for @threads)
    Threads.@threads for i in 1:N
        pos_i         = positions[i]
        vel_i         = velocities[i]
        r_i           = radii[i]
        v_pref_i      = v_prefs[i]
        lp_radius_i   = lp_radii[i]
        goal_i        = goals[i]
        time_h_i      = time_horizons[i]
        max_nb_i      = max_neighbors[i]   # per-agent neighbor cap (e.g. 10 for RVO2 benchmark)
        nb_dist_i     = neighbor_dists[i]  # per-agent search radius  (e.g. 15m for RVO2 benchmark)
        
        # Preferred velocity direction
        dir  = goal_i - pos_i
        dist = norm(dir)
        pref_vel = dist > 1e-5 ? (dir / dist) * v_pref_i : SVector{2, F}(0, 0)
        
        # Fix C: Reuse thread-local buffer — empty!() reuses existing capacity
        buf = neighbor_bufs[Threads.threadid()]
        empty!(buf)
        nb_dist_sq_i = (nb_dist_i)^2  # use per-agent neighbor_dist from ORCAParams
        for j in 1:N
            if i != j
                d2 = sum(abs2.(pos_i - positions[j]))
                if d2 <= nb_dist_sq_i
                    push!(buf, (d2, j))
                end
            end
        end

        # Sort by distance and cap at per-agent max_neighbors
        sort!(buf, by = x -> x[1])
        K = min(length(buf), max_nb_i)  # use per-agent max_neighbors from ORCAParams
        
        lines = Vector{Line{F}}(undef, K)
        for k in 1:K
            n_idx = buf[k][2]
            pos_j = positions[n_idx]
            vel_j = velocities[n_idx]
            r_j   = radii[n_idx]
            # BUG-ORCA-01 FIX: use per-agent time_horizon
            lines[k] = compute_orca_line(pos_i, vel_i, r_i, pos_j, vel_j, r_j, time_h_i, dt)
        end
        
        # Solve 2D LP — radius is agent's max_speed (velocity disc constraint)
        fail_line, v_opt = linear_program_2_len(lines, K, lp_radius_i, pref_vel, false, pref_vel)
        if fail_line > 0
            v_opt = linear_program_3(lines, 0, fail_line, lp_radius_i, v_opt)
        end
        
        new_velocities[i] = v_opt
    end
    
    # Write back forces
    idx = 1
    for (entities, pos_col, vel_col, params_col, force_col) in Query(world, (Position{F}, Velocity{F}, ORCAParams{F}, Force{F}))
        for i in eachindex(pos_col)
            force_col[i] = Force(masses[idx] * (new_velocities[idx] - velocities[idx]) / dt)
            idx += 1
        end
    end
end

