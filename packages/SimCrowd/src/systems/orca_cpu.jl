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
    # Collect data
    positions = Vector{SVector{2, F}}()
    velocities = Vector{SVector{2, F}}()
    radii = Vector{F}()
    v_prefs = Vector{F}()
    taus = Vector{F}()
    masses = Vector{F}()
    time_horizons = Vector{F}()  # BUG-ORCA-01 FIX: per-agent time horizons
    goals = Vector{SVector{2, F}}()
    indices = Vector{Int}()
    
    for (entities, pos_col, vel_col, params_col, goal_col) in Query(world, (Position{F}, Velocity{F}, ORCAParams{F}, Goal{F}))
        for i in eachindex(pos_col)
            push!(positions, pos_col[i].p)
            push!(velocities, vel_col[i].v)
            push!(radii, params_col[i].radius)
            push!(v_prefs, params_col[i].v_pref)
            push!(taus, params_col[i].τ)
            push!(masses, params_col[i].mass)
            push!(time_horizons, params_col[i].time_horizon)  # BUG-ORCA-01 FIX
            push!(goals, goal_col[i].g)
            push!(indices, i)
        end
    end
    
    N = length(positions)
    if N == 0
        return
    end
    
    new_velocities = copy(velocities)
    
    # Fix C: Get pre-allocated per-thread neighbor buffers (zero allocation per step)
    neighbor_bufs = _get_neighbor_bufs()
    
    # O(N²) LP solve — each agent's computation is fully independent (safe for @threads)
    Threads.@threads for i in 1:N
        pos_i    = positions[i]
        vel_i    = velocities[i]
        r_i      = radii[i]
        v_pref_i = v_prefs[i]
        goal_i   = goals[i]
        time_h_i = time_horizons[i]
        
        # Preferred velocity direction
        dir  = goal_i - pos_i
        dist = norm(dir)
        pref_vel = dist > 1e-5 ? (dir / dist) * v_pref_i : SVector{2, F}(0, 0)
        
        # Fix C: Reuse thread-local buffer — empty!() reuses existing capacity
        buf = neighbor_bufs[Threads.threadid()]
        empty!(buf)
        for j in 1:N
            if i != j
                d2 = sum(abs2.(pos_i - positions[j]))
                if d2 <= (r_i + radii[j] + 120.0f0)^2
                    push!(buf, (d2, j))
                end
            end
        end
        
        # Sort by distance
        sort!(buf, by = x -> x[1])
        
        # Compute ORCA lines for K closest neighbors
        K = min(length(buf), 250)
        
        lines = Vector{Line{F}}(undef, K)
        for k in 1:K
            n_idx = buf[k][2]
            pos_j = positions[n_idx]
            vel_j = velocities[n_idx]
            r_j   = radii[n_idx]
            # BUG-ORCA-01 FIX: use per-agent time_horizon
            lines[k] = compute_orca_line(pos_i, vel_i, r_i, pos_j, vel_j, r_j, time_h_i, dt)
        end
        
        # Solve 2D LP
        fail_line, v_opt = linear_program_2_len(lines, K, 20.0f0, pref_vel, false, pref_vel)
        if fail_line > 0
            v_opt = linear_program_3(lines, 0, fail_line, 20.0f0, v_opt)
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

