# ── ORCA Math & 2D LP Solver ──────────────────────────────────────────────────

using StaticArrays
using LinearAlgebra

const RVO_EPSILON = 1f-5

struct Line{F<:AbstractFloat}
    point::SVector{2,F}
    dir::SVector{2,F}
end

@inline det(a::SVector{2,F}, b::SVector{2,F}) where {F} = a[1]*b[2] - a[2]*b[1]

# 1D Linear Program to find the optimal point on a line segment
@inline function linear_program_1(lines, line_no::Int, radius::F, opt_velocity::SVector{2,F}, direction_opt::Bool)::Tuple{Bool, SVector{2,F}} where {F}
    dot_product = dot(lines[line_no].point, lines[line_no].dir)
    discriminant = dot_product^2 + radius^2 - sum(abs2, lines[line_no].point)
    
    if discriminant < zero(F)
        return false, opt_velocity
    end
    
    sqrt_disc = sqrt(discriminant)
    t_left = -dot_product - sqrt_disc
    t_right = -dot_product + sqrt_disc
    
    for i in 1:(line_no-1)
        denominator = det(lines[line_no].dir, lines[i].dir)
        numerator = det(lines[i].dir, lines[line_no].point - lines[i].point)
        
        if abs(denominator) <= RVO_EPSILON
            if numerator < zero(F)
                return false, opt_velocity
            end
            continue
        end
        
        t = numerator / denominator
        if denominator >= zero(F)
            t_right = min(t_right, t)
        else
            t_left = max(t_left, t)
        end
        
        if t_left > t_right
            return false, opt_velocity
        end
    end
    
    if direction_opt
        if dot(opt_velocity, lines[line_no].dir) > zero(F)
            return true, lines[line_no].point + t_right * lines[line_no].dir
        else
            return true, lines[line_no].point + t_left * lines[line_no].dir
        end
    else
        t = dot(lines[line_no].dir, opt_velocity - lines[line_no].point)
        if t < t_left
            return true, lines[line_no].point + t_left * lines[line_no].dir
        elseif t > t_right
            return true, lines[line_no].point + t_right * lines[line_no].dir
        else
            return true, lines[line_no].point + t * lines[line_no].dir
        end
    end
end

# 2D Linear Program to find optimal velocity given half-plane constraints
@inline function linear_program_2(lines, radius::F, opt_velocity::SVector{2,F}, direction_opt::Bool, result::SVector{2,F})::Tuple{Int, SVector{2,F}} where {F}
    if direction_opt
        result = opt_velocity * radius
    elseif sum(abs2, opt_velocity) > radius^2
        result = normalize(opt_velocity) * radius
    else
        result = opt_velocity
    end
    
    for i in 1:length(lines)
        # BUG-ORCA-02 FIX: Removed redundant outer check. det(dir, point-result) > det(dir, 0)
        # is equivalent to > 0 since det(a,0)=0 always. Only one check needed.
        if det(lines[i].dir, lines[i].point - result) > zero(F)
            # Result does not satisfy constraint i. Compute new optimal result.
            temp_result = result
            success, result = linear_program_1(lines, i, radius, opt_velocity, direction_opt)
            if !success
                return i, temp_result
            end
        end
    end
    return 0, result
end

# LP3 Fallback: minimize constraint violations when LP2 is infeasible.
# When all velocities violate at least one constraint, LP3 finds the velocity
# that penetrates constraints as little as possible.
#
# Algorithm (van den Berg 2011 §3.2 / RVO2 Agent.cc):
#   For each violated constraint i, project all previous constraints onto i's
#   boundary and re-run LP2 with the goal direction perpendicular to i.
#   If LP2 succeeds: use the new result.
#   If LP2 fails: restore temp_result (LP3 iteration start). RVO2 comment:
#     "This should in principle not happen. [...] due to small floating point
#      error, and the current result is kept."
#   ALWAYS update distance (ensures greedy ordering of violations).
#
# CPU path only (uses Vector heap allocation — acceptable since LP3 is only
# invoked when LP2 is infeasible, i.e. in crowded transients).
@inline function linear_program_3(lines, num_obst_lines::Int, begin_line::Int, radius::F, result::SVector{2,F})::SVector{2,F} where {F}
    distance = zero(F)

    for i in begin_line:length(lines)
        if det(lines[i].dir, lines[i].point - result) > distance
            # Allocate proj_lines large enough to hold:
            #   - The first num_obst_lines obstacle lines (copied verbatim below)
            #   - Projected agent-agent lines from j=num_obst_lines+1 to i-1
            # When begin_line ≤ num_obst_lines and i=begin_line, i-1 < num_obst_lines.
            # Using only i-1 would cause a BoundsError on the obstacle-copy loop.
            proj_lines = Vector{Line{F}}(undef, max(i - 1, num_obst_lines))

            for j in 1:num_obst_lines
                proj_lines[j] = lines[j]
            end

            num_proj_lines = num_obst_lines
            for j in (num_obst_lines+1):(i-1)
                determinant = det(lines[i].dir, lines[j].dir)
                if abs(determinant) <= RVO_EPSILON
                    if dot(lines[i].dir, lines[j].dir) > zero(F)
                        continue
                    else
                        point = (lines[i].point + lines[j].point) * F(0.5)
                    end
                else
                    point = lines[i].point + (det(lines[j].dir, lines[i].point - lines[j].point) / determinant) * lines[i].dir
                end

                dir = normalize(lines[j].dir - lines[i].dir)
                num_proj_lines += 1
                proj_lines[num_proj_lines] = Line(point, dir)
            end

            # Save LP3 iteration start — this is the conservative fallback.
            # By construction, temp_result already satisfies all projLines
            # (it was produced by satisfying previous LP3 iterations).
            temp_result = result
            perp = SVector(-lines[i].dir[2], lines[i].dir[1])
            fail_line, new_res = linear_program_2_len(proj_lines, num_proj_lines, radius,
                                                       perp, true, temp_result)

            if fail_line == 0
                # LP2 succeeded: new_res satisfies constraint i and all projLines
                result = new_res
            else
                # LP2 failed (floating point edge case per RVO2). Restore conservative
                # fallback — temp_result satisfies all previous LP3 constraints.
                result = temp_result
            end
            # ALWAYS update distance (tracks greedy max-violation threshold)
            distance = det(lines[i].dir, lines[i].point - result)
        end
    end
    return result
end

@inline function linear_program_2_len(lines, num_lines::Int, radius::F, opt_velocity::SVector{2,F}, direction_opt::Bool, result::SVector{2,F})::Tuple{Int, SVector{2,F}} where {F}
    if direction_opt
        result = opt_velocity * radius
    elseif sum(abs2, opt_velocity) > radius^2
        result = normalize(opt_velocity) * radius
    else
        result = opt_velocity
    end
    
    for i in 1:num_lines
        if det(lines[i].dir, lines[i].point - result) > zero(F)
            temp_result = result
            success, result = linear_program_1(lines, i, radius, opt_velocity, direction_opt)
            if !success
                return i, temp_result
            end
        end
    end
    return 0, result
end

# LP3 (static / GPU-safe variant) — same algorithm as linear_program_3 but
# operates on a fixed-size MVector for zero heap allocation.
# Used from the GPU ORCA kernel where Vector is not allowed.
@inline function linear_program_3_static(lines, num_lines::Int, num_obst_lines::Int, begin_line::Int, radius::F, result::SVector{2,F})::SVector{2,F} where {F}
    distance = zero(F)

    for i in begin_line:num_lines
        if det(lines[i].dir, lines[i].point - result) > distance
            proj_lines = typeof(lines)(undef)
            for j in 1:num_obst_lines
                proj_lines[j] = lines[j]
            end

            num_proj_lines = num_obst_lines
            for j in (num_obst_lines+1):(i-1)
                determinant = det(lines[i].dir, lines[j].dir)
                if abs(determinant) <= RVO_EPSILON
                    if dot(lines[i].dir, lines[j].dir) > zero(F)
                        continue
                    else
                        point = (lines[i].point + lines[j].point) * F(0.5)
                    end
                else
                    point = lines[i].point + (det(lines[j].dir, lines[i].point - lines[j].point) / determinant) * lines[i].dir
                end

                dir = normalize(lines[j].dir - lines[i].dir)
                num_proj_lines += 1
                # Bounds check: num_proj_lines ≤ K-1 by construction (j loops to i-1, i ≤ K).
                # The previous hardcoded `<= 25` was wrong for K=250 (CPU path) and
                # would silently drop proj_lines, degrading LP3 quality at high density.
                proj_lines[num_proj_lines] = Line(point, dir)
            end

            temp_result = result
            perp = SVector(-lines[i].dir[2], lines[i].dir[1])
            fail_line, new_res = linear_program_2_len(proj_lines, num_proj_lines, radius,
                                                       perp, true, temp_result)

            if fail_line == 0
                result = new_res
            else
                # Floating point edge case: restore conservative LP3-iteration start
                result = temp_result
            end
            # ALWAYS update distance (matches RVO2)
            distance = det(lines[i].dir, lines[i].point - result)
        end
    end
    return result
end

# Compute the Velocity Obstacle Half-Plane for an agent-agent interaction.
#
# §1.8 Non-reciprocal ORCA weights:
#   resp_i  — fraction of the velocity change `u` that agent i absorbs [0, 1].
#   0.5  = standard reciprocal ORCA (van den Berg 2011): both agents take half.
#   1.0  = full responsibility: use when j is non-cooperative (unaware robot,
#          wall-adjacent agent that has no room to manoeuvre, etc.).
#   Values > 0.5 make agent i more conservative: it moves further from the VO
#   boundary, reducing near-miss probability at the cost of a larger detour.
@inline function compute_orca_line(
    pos_i, vel_i, r_i,
    pos_j, vel_j, r_j,
    time_horizon, dt,
    resp_i = typeof(r_i)(0.5)  # §1.8: default 0.5 = reciprocal ORCA
)
    F = typeof(r_i)
    relative_pos = pos_j - pos_i
    relative_vel = vel_i - vel_j
    dist_sq = sum(abs2, relative_pos)
    combined_radius = r_i + r_j
    combined_radius_sq = combined_radius^2
    
    # If there is a collision right now
    if dist_sq <= combined_radius_sq
        w = relative_vel - relative_pos / dt
        w_len_sq = sum(abs2, w)
        if w_len_sq <= RVO_EPSILON
            w = SVector{2,F}(1.0f0, 0.0f0)
            w_len_sq = F(1.0)
        end
        w_len = sqrt(w_len_sq)
        unit_w = w / w_len
        dir = SVector(unit_w[2], -unit_w[1])
        u = (combined_radius / dt - w_len) * unit_w
        return Line(vel_i + u * resp_i, dir)  # §1.8: resp_i fraction
    end
    
    # No immediate collision. Compute VO truncated by time_horizon.
    w = relative_vel - relative_pos / time_horizon
    w_len_sq = sum(abs2, w)
    dot_product = dot(w, relative_pos)
    
    # Project on cut-off circle
    if dot_product < zero(F) && dot_product^2 > combined_radius_sq * w_len_sq
        if w_len_sq <= RVO_EPSILON
            w = SVector{2,F}(1.0f0, 0.0f0)
            w_len_sq = F(1.0)
        end
        w_len = sqrt(w_len_sq)
        unit_w = w / w_len
        dir = SVector(unit_w[2], -unit_w[1])
        u = (combined_radius / time_horizon - w_len) * unit_w
        return Line(vel_i + u * resp_i, dir)  # §1.8
    end
    
    # Project on legs of VO cone
    leg = sqrt(dist_sq - combined_radius_sq)
    if det(relative_pos, w) > zero(F)
        dir = SVector(relative_pos[1]*leg - relative_pos[2]*combined_radius, relative_pos[1]*combined_radius + relative_pos[2]*leg) / dist_sq
    else
        dir = -SVector(relative_pos[1]*leg + relative_pos[2]*combined_radius, -relative_pos[1]*combined_radius + relative_pos[2]*leg) / dist_sq
    end
    
    dot_w_dir = dot(relative_vel, dir)
    u = dot_w_dir * dir - relative_vel
    return Line(vel_i + u * resp_i, dir)  # §1.8
end

"""
    compute_orca_line_wall(pos_i, vel_i, r_i, p1, p2, time_horizon_obst, dt)

Compute the ORCA half-plane constraint imposed by the static wall segment [p1, p2]
on agent i.

Static obstacles have zero velocity and infinite mass, so the agent takes **full
responsibility** for the velocity change (no 1/2 factor, unlike agent-agent ORCA).
Nearest-point projection is used for finite wall segments.

Returns the constraint as a `Line{F}` with:
- `line.point`: a point on the ORCA half-plane boundary
- `line.dir`: the direction along the half-plane boundary

The half-plane {v : det(dir, point - v) ≤ 0} contains the set of safe velocities.

Algorithm follows van den Berg 2011 (ORCA) §3.1 with obstacle responsibility = 1.0.
"""
@inline function compute_orca_line_wall(
    pos_i::SVector{2,F}, vel_i::SVector{2,F}, r_i::F,
    p1::SVector{2,F}, p2::SVector{2,F},
    time_horizon_obst::F, dt::F
) where {F<:AbstractFloat}
    # ── 1. Nearest point on wall segment to agent i ──────────────────────────────
    seg = p2 - p1
    l2  = dot(seg, seg)
    t   = l2 < F(1e-10) ? zero(F) : clamp(dot(pos_i - p1, seg) / l2, zero(F), one(F))
    q   = p1 + t * seg           # nearest wall point

    relative_pos    = q - pos_i  # vector from agent to wall
    dist_sq         = sum(abs2, relative_pos)
    combined_radius = r_i        # wall has zero physical radius

    # ── 2. Collision right now (agent overlaps wall) ──────────────────────────────
    if dist_sq <= combined_radius^2
        dist = sqrt(dist_sq)
        unit_w = if dist < F(1e-6)
            SVector{2,F}(one(F), zero(F))  # degenerate: push right
        else
            -relative_pos / dist           # outward (away from wall)
        end
        dir = SVector(unit_w[2], -unit_w[1])
        u   = (combined_radius / dt - dist) * unit_w
        # Full responsibility: no 0.5 factor (wall cannot adapt velocity)
        return Line(vel_i + u, dir)
    end

    # ── 3. No current collision — truncated velocity obstacle ──────────────────────
    # Velocity of wall is zero, so relative_vel = vel_i - 0 = vel_i.
    # VO apex is at relative_pos / time_horizon_obst; w = vel_i - apex.
    w        = vel_i - relative_pos / time_horizon_obst
    w_len_sq = sum(abs2, w)
    dot_wp   = dot(w, relative_pos)

    if dot_wp < zero(F) && dot_wp^2 > combined_radius^2 * w_len_sq
        # Project on cut-off circle (inside VO cone)
        w_len  = sqrt(max(w_len_sq, F(1e-12)))
        unit_w = w / w_len
        dir    = SVector(unit_w[2], -unit_w[1])
        u      = (combined_radius / time_horizon_obst - w_len) * unit_w
        return Line(vel_i + u, dir)  # full responsibility
    end

    # Project on VO cone legs
    leg = sqrt(max(zero(F), dist_sq - combined_radius^2))
    if det(relative_pos, w) > zero(F)
        dir = SVector(
             relative_pos[1]*leg - relative_pos[2]*combined_radius,
             relative_pos[1]*combined_radius + relative_pos[2]*leg
        ) / dist_sq
    else
        dir = -SVector(
              relative_pos[1]*leg + relative_pos[2]*combined_radius,
             -relative_pos[1]*combined_radius + relative_pos[2]*leg
        ) / dist_sq
    end
    dot_w_dir = dot(vel_i, dir)
    u         = dot_w_dir * dir - vel_i
    return Line(vel_i + u, dir)  # full responsibility
end

"""
    compute_orca_line_endpoint(pos_i, vel_i, r_i, q, time_horizon_obst, dt)

Compute the ORCA half-plane constraint imposed by a **wall segment endpoint** (a
zero-radius point obstacle at `q`) on agent i.

This is the correct treatment of convex obstacle vertices per van den Berg (2011)
§3.2 "Static Obstacles" and the RVO2 reference implementation (`Agent.cpp`,
`computeNewVelocity`, obstacle-vertex section). Each endpoint of a wall segment
must generate its own constraint, independent of the segment interior constraint,
to prevent agents from arcing through corners.

Mathematically identical to `compute_orca_line_wall` with `p1 = p2 = q`
(i.e. the degenerate case where the nearest point is always the endpoint itself).

Full agent responsibility (no 0.5 factor): the point obstacle cannot adapt velocity.

GPU-safe: @inline, no heap allocation, all inputs isbits.
"""
@inline function compute_orca_line_endpoint(
    pos_i::SVector{2,F}, vel_i::SVector{2,F}, r_i::F,
    q::SVector{2,F},
    time_horizon_obst::F, dt::F
) where {F<:AbstractFloat}
    relative_pos = q - pos_i
    dist_sq      = sum(abs2, relative_pos)

    # ── Collision right now (agent overlaps endpoint) ─────────────────────────
    if dist_sq <= r_i^2
        dist   = sqrt(dist_sq)
        unit_w = if dist < F(1e-6)
            SVector{2,F}(one(F), zero(F))   # degenerate: push right
        else
            -relative_pos / dist             # outward (away from point)
        end
        dir = SVector(unit_w[2], -unit_w[1])
        u   = (r_i / dt - dist) * unit_w
        return Line(vel_i + u, dir)          # full responsibility
    end

    # ── No current collision — truncated velocity obstacle ────────────────────
    w        = vel_i - relative_pos / time_horizon_obst
    w_len_sq = sum(abs2, w)
    dot_wp   = dot(w, relative_pos)

    if dot_wp < zero(F) && dot_wp^2 > r_i^2 * w_len_sq
        # Inside VO cone — project on cut-off circle
        w_len  = sqrt(max(w_len_sq, F(1e-12)))
        unit_w = w / w_len
        dir    = SVector(unit_w[2], -unit_w[1])
        u      = (r_i / time_horizon_obst - w_len) * unit_w
        return Line(vel_i + u, dir)          # full responsibility
    end

    # ── Project on VO cone legs ───────────────────────────────────────────────
    leg = sqrt(max(zero(F), dist_sq - r_i^2))
    if det(relative_pos, w) > zero(F)
        dir = SVector(
             relative_pos[1]*leg - relative_pos[2]*r_i,
             relative_pos[1]*r_i  + relative_pos[2]*leg
        ) / dist_sq
    else
        dir = -SVector(
              relative_pos[1]*leg + relative_pos[2]*r_i,
             -relative_pos[1]*r_i  + relative_pos[2]*leg
        ) / dist_sq
    end
    u = dot(vel_i, dir) * dir - vel_i
    return Line(vel_i + u, dir)              # full responsibility
end

"""
    apply_wall_penetration_correction(pos, vel, r_i, p1, p2)
        → (corrected_pos, corrected_vel)

Model-agnostic geometric non-penetration correction for a single wall segment.

If the agent body (centre `pos`, radius `r_i`) overlaps the wall segment [p1, p2],
push `pos` back to the surface and zero out the velocity component directed into
the wall. Returns unchanged `(pos, vel)` if no penetration.

## Scientific basis

Standard non-penetration constraint from rigid-body dynamics (RVO2 §4, Menge —
Curtis & Manocha 2016). Equivalent to an infinite-stiffness elastic wall at
distance `r_i` from the wall segment.

## Properties

- **GPU-safe**: `@inline`, no heap allocation, all inputs/outputs are `isbits`
  (`SVector{2,F}` and `F`).
- **Model-agnostic**: no ECS types, no archetype query. Callable from any GPU
  kernel (`compute_orca_kernel!`, `compute_csm_kernel!`, …) or CPU ECS loop.
- **Idempotent**: applying it twice gives the same result as once (convergence
  to the contact surface).

## CPU ECS usage

```julia
for (p1, p2) in walls
    pos, vel = apply_wall_penetration_correction(pos, vel, r_i, p1, p2)
end
```

## GPU kernel usage

```julia
@inbounds for w in 1:n_walls
    corrected_pos, corrected_vel =
        apply_wall_penetration_correction(corrected_pos, corrected_vel, r_i,
                                          wall_p1s[w], wall_p2s[w])
end
```

Replaces the per-model `wall_penetration_correction!` CPU ECS loops in
`hybrid_fsm.jl` and `csm.jl` — those loops call this function for each wall pair.
"""
@inline function apply_wall_penetration_correction(
    pos::SVector{2,F},
    vel::SVector{2,F},
    r_i::F,
    p1::SVector{2,F},
    p2::SVector{2,F}
) :: Tuple{SVector{2,F}, SVector{2,F}} where {F<:AbstractFloat}
    seg = p2 - p1
    l2  = dot(seg, seg)
    t   = l2 < F(1e-10) ? zero(F) : clamp(dot(pos - p1, seg) / l2, zero(F), one(F))
    q   = p1 + t * seg
    rel = pos - q             # vector from wall surface point → agent centre
    d   = norm(rel)

    # Only correct if agent body genuinely overlaps wall (not just ORCA exclusion zone)
    if d < r_i && d > F(1e-6)
        n_out  = rel / d          # outward unit normal (away from wall)
        # 1. Position: push agent back to contact surface
        pos    = q + n_out * r_i
        # 2. Velocity: cancel any inward component (prevents immediate re-penetration)
        v_into = dot(vel, -n_out)  # positive = agent moving INTO wall
        if v_into > zero(F)
            vel = vel + v_into * n_out
        end
    end
    return pos, vel
end

