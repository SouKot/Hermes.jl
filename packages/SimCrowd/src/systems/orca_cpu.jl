using KernelAbstractions
using StaticArrays
using LinearAlgebra
import AcceleratedKernels as AK

# Per-thread pre-allocated neighbor buffers — eliminates per-agent heap allocation
# inside the parallel loop. Initialized lazily on first call, reused every step.
# This removes ~4MB/step of GC pressure at N=1000.
# NOTE: Indexed by Threads.threadid() which is stable within AK.foreachindex tasks
# (Julia tasks don't migrate threads once started — no race condition risk).
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

# CPU-only implementation that uses dynamic Vectors to handle infinite neighbors.
#
# Returns the number of agents that invoked LP3 (the 3D fallback solver) this step.
# LP3 is called when LP2 is infeasible (all velocities violate at least one constraint).
# High LP3 rates indicate crowd density exceeds ORCA's guaranteed-feasibility threshold.
function update_orca_system_cpu!(world, dt::F) where {F<:AbstractFloat}
    # Count agents that have ORCA components (ignore non-ORCA entities like SFM-only agents)
    N = 0
    for (entities, pos_col, vel_col, params_col, orca_col, goal_col) in Query(world, (Position{F}, Velocity{F}, AgentParams{F}, ORCAParams{F}, Goal{F}))
        N += length(pos_col)
    end
    if N == 0
        return 0
    end
    # Pre-extract all per-agent data (avoids repeated Query inside the hot loop)
    positions           = Vector{SVector{2,F}}(undef, N)
    velocities          = Vector{SVector{2,F}}(undef, N)
    radii               = Vector{F}(undef, N)
    v_prefs             = Vector{F}(undef, N)
    lp_radii            = Vector{F}(undef, N)   # LP velocity-disc radius = orca.v_pref (max speed)
    time_horizons       = Vector{F}(undef, N)
    time_horizon_obsts  = Vector{F}(undef, N)   # §1.7: per-agent obstacle time horizon
    max_neighbors       = Vector{Int}(undef, N) # per-agent cap on ORCA constraints (RVO2: 10)
    neighbor_dists      = Vector{F}(undef, N)   # per-agent neighbor search radius (RVO2: 15m)
    goals               = Vector{SVector{2,F}}(undef, N)
    masses              = Vector{F}(undef, N)
    responsibilities    = Vector{F}(undef, N)   # §1.8: ORCA velocity-change responsibility
    
    idx = 1
    for (entities, pos_col, vel_col, params_col, orca_col, goal_col) in Query(world, (Position{F}, Velocity{F}, AgentParams{F}, ORCAParams{F}, Goal{F}))
        for i in eachindex(pos_col)
            positions[idx]          = pos_col[i].p
            velocities[idx]         = vel_col[i].v
            radii[idx]              = orca_col[i].radius
            v_prefs[idx]            = orca_col[i].v_pref
            lp_radii[idx]           = orca_col[i].v_pref  # LP disc radius = max speed
            time_horizons[idx]      = orca_col[i].time_horizon
            time_horizon_obsts[idx] = orca_col[i].time_horizon_obst  # §1.7: wall horizon
            max_neighbors[idx]      = orca_col[i].max_neighbors
            neighbor_dists[idx]     = orca_col[i].neighbor_dist
            goals[idx]              = goal_col[i].g
            masses[idx]             = params_col[i].mass
            responsibilities[idx]   = orca_col[i].responsibility  # §1.8: non-reciprocal weight
            idx += 1
        end
    end
    
    if N == 0
        return 0
    end
    
    # §1.7: Extract wall segments once per step (shared across all threads — read-only)
    wall_segs = Tuple{SVector{2,F}, SVector{2,F}}[]
    for (_, wall_col) in Query(world, (WallSegment{F},))
        for i in eachindex(wall_col)
            push!(wall_segs, (wall_col[i].p1, wall_col[i].p2))
        end
    end
    n_walls = length(wall_segs)
    
    new_velocities = copy(velocities)
    
    # Fix C: Get pre-allocated per-thread neighbor buffers (zero allocation per step)
    neighbor_bufs = _get_neighbor_bufs()
    
    # §1.6 LP3 profiling: thread-safe counter for LP3 invocations this step.
    # LP3 is the 3D fallback when LP2 is infeasible (over-constrained crowd).
    lp3_count = Threads.Atomic{Int}(0)
    
    # O(N²) LP solve — each agent's computation is fully independent.
    # AK.foreachindex(CPU()) uses Julia tasks (same threading model as @threads),
    # but routes through the KA/AK abstraction layer — consistent with our
    # "KA/AK for all threading" convention (no bare Base.Threads usage).
    #
    # NOTE: Base.Threads.@threads was previously used here — replaced per §§Opp-A.
    # TODO [deprecated]: Remove _ORCA_NEIGHBOR_BUFS + Threads.threadid() call when
    # a clean per-task scratch API is available in AK (tracked: AK issue #TBD).
    AK.foreachindex(1:N, CPU()) do i
        pos_i         = positions[i]
        vel_i         = velocities[i]
        r_i           = radii[i]
        v_pref_i      = v_prefs[i]
        lp_radius_i   = lp_radii[i]
        goal_i        = goals[i]
        time_h_i      = time_horizons[i]
        time_h_obst_i = time_horizon_obsts[i]  # §1.7: wall time horizon
        max_nb_i      = max_neighbors[i]        # per-agent neighbor cap (e.g. 10 for RVO2 benchmark)
        nb_dist_i     = neighbor_dists[i]       # per-agent search radius  (e.g. 15m for RVO2 benchmark)
        resp_i        = responsibilities[i]     # §1.8: velocity-change fraction
        
        # Preferred velocity direction
        dir  = goal_i - pos_i
        dist = norm(dir)
        pref_vel = dist > 1e-5 ? (dir / dist) * v_pref_i : SVector{2, F}(0, 0)
        
        # ── §1.7: Wall ORCA lines (obstacle lines — PREPENDED before agent-agent lines) ──
        # Static obstacle ORCA lines must appear first in the constraint set.
        # LP3 treats the first num_obst_lines constraints as hard (non-relaxable).
        # The agent takes FULL responsibility (wall cannot adapt its velocity).
        wall_lines = Line{F}[]
        for (p1, p2) in wall_segs
            # Quick distance check: skip walls far from agent
            seg = p2 - p1
            l2  = dot(seg, seg)
            t   = l2 < F(1e-10) ? zero(F) : clamp(dot(pos_i - p1, seg) / l2, zero(F), one(F))
            q   = p1 + t * seg
            dist_to_wall = norm(q - pos_i)
            # Interaction radius: agent radius + 2m slack for time-horizon lookahead
            if dist_to_wall < r_i + F(2)
                wline = compute_orca_line_wall(pos_i, vel_i, r_i, p1, p2, time_h_obst_i, dt)
                push!(wall_lines, wline)
            end
        end
        num_obst_lines = length(wall_lines)  # count for LP3's hard-constraint boundary
        
        # ── Agent-agent neighbor search ────────────────────────────────────────────
        # Fix C: Reuse thread-local buffer — empty!() reuses existing capacity
        buf = neighbor_bufs[Threads.threadid()]
        empty!(buf)
        nb_dist_sq_i = (nb_dist_i)^2
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
        K = min(length(buf), max_nb_i)
        
        # ── Build complete constraint set: [wall lines | agent-agent lines] ─────────
        # Wall lines first (obstacle priority in LP3), then agent-agent ORCA lines.
        all_lines = sizehint!(copy(wall_lines), num_obst_lines + K)
        for k in 1:K
            n_idx = buf[k][2]
            pos_j = positions[n_idx]
            vel_j = velocities[n_idx]
            r_j   = radii[n_idx]
            # BUG-ORCA-01 FIX: use per-agent time_horizon
            push!(all_lines, compute_orca_line(pos_i, vel_i, r_i, pos_j, vel_j, r_j, time_h_i, dt, resp_i))
        end
        total_lines = length(all_lines)
        
        # Solve 2D LP — radius is agent's max_speed (velocity disc constraint)
        fail_line, v_opt = linear_program_2_len(all_lines, total_lines, lp_radius_i, pref_vel, false, pref_vel)
        if fail_line > 0
            # §1.6: Count LP3 invocations (profiling — shows how often LP2 is infeasible)
            Threads.atomic_add!(lp3_count, 1)
            # LP3: minimize constraint violations (fallback for over-constrained scenarios).
            # num_obst_lines: obstacle lines treated as hard constraints (cannot be relaxed).
            # begin_line: the first failing agent-agent constraint from LP2.
            v_opt = linear_program_3(all_lines, num_obst_lines, fail_line, lp_radius_i, v_opt)
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
    
    return Int(lp3_count[])  # caller can accumulate or display the LP3 rate
end
