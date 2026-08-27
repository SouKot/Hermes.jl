# systems/csm.jl — Collision-Free Speed Model (CSM)
#
# Implements CSM V1/V2/V3 (Tordeux et al. 2016 / JuPedSim GCFVM) as a unified
# first-order pedestrian model controlled entirely by CSMParams{F}.
#
# Model variants (controlled by CSMParams fields):
#   V1:  a_wall=0, use_rotational_steering=false  (Tordeux 2016 baseline)
#   V2:  a_wall>0, use_rotational_steering=false  (wall repulsion in direction model)
#   V3:  a_wall>0, use_rotational_steering=true   (rotational steering + heading relaxation)
#
# Architecture:
#   - CSM agents carry: Position{F}, Velocity{F}, Goal{F}, CSMParams{F}
#   - V3 agents additionally: AgentCSMState{F} (per-agent heading angle)
#   - NO Force{F}, MotionParams{F}, SFMParams{F}, ORCAParams{F}
#   - physics integrator (integrate_physics_system!) skips CSM agents automatically
#   - update_csm_system! handles both velocity and position update in one call
#
# Threading: Threads.@threads double-buffer pattern
#   Pass 1: read positions/goals (read-only shared), write new_vel[i] (own slot)
#   Pass 2: write pos[i] (ECS write-back, own slot)
#   No locks, no atomics, no race conditions.
#
# GPU path (Sprint 3L+):
#   Structs are isbits. GPU kernel follows orca.jl pattern.
#   Estimated ~50 registers per thread vs ~280 for ORCA → ~3× higher SM occupancy.
#
# References:
#   Tordeux, A., Chraibi, M., Seyfried, A. (2016). Collision-free speed model for
#   pedestrian dynamics. In Traffic and Granular Flow '15, 225-232. Springer.
#   JuPedSim v10.0 — jupedsim.org (GCFVM implementation reference)

using Ark
using StaticArrays
using LinearAlgebra

# ── OV (Optimal Velocity) speed function ──────────────────────────────────────

"""
    csm_speed(s, v₀, T) → v

Collision-free speed function (OV function). Maps surface-to-surface gap s to
speed v ∈ [0, v₀]. Reference: Tordeux et al. (2016) eq. (2).

- `s`:  surface-to-surface gap to nearest forward neighbor (m, ≥ 0)
        s = max(center_dist - r_i - r_j, 0)
- `v₀`: desired free-flow speed (m/s)
- `T`:  time-gap parameter (s) — safety time headway

V(s) = v₀ × clamp(s / (T × v₀), 0, 1)
  → 0 when s = 0  (bodies touching → zero speed)
  → v₀ when s ≥ T×v₀  (free-flow safety gap maintained)

Linear in [0, T×v₀]. Matches Tordeux 2016 Fig. 1 with l = T×v₀.
‹› Note: NO body-length (ℓ) shift. The gap s is already surface-to-surface
(0 at body contact), so no additional shift is needed. Previous versions
included an ℓ shift which erroneously kept speed at 0 in normal crowds.
"""
@inline function csm_speed(s::F, v₀::F, T::F)::F where {F<:AbstractFloat}
    return v₀ * clamp(s / (T * v₀), zero(F), one(F))
end

# ── Forward-cone gap ───────────────────────────────────────────────────────────

"""
    csm_gap(pos_i, dir_ref, i_self, positions, r_all, r_i, cos_fov, nb_radius) → s

Surface-to-surface gap to the nearest agent in the forward cone.

Only agents within `nb_radius` and with `dot(r_ij/d, dir_ref) > cos_fov` considered.
Self excluded via `i_self`. Returns `Inf` if no qualifying forward neighbor.

- `r_i`:    radius of querying agent i (m)
- `r_all`:  radii of all agents (m) — uniform in Sprint 3L
- `gap`:    max(center_dist - r_i - r_j, 0) — 0 at body surface contact
"""
@inline function csm_gap(
    pos_i     :: SVector{2,F},
    dir_ref   :: SVector{2,F},
    i_self    :: Int,
    positions :: Vector{SVector{2,F}},
    r_all     :: Vector{F},
    r_i       :: F,            # individual radius of agent i (not body length!)
    cos_fov   :: F,
    nb_radius :: F
) :: F where {F<:AbstractFloat}
    min_gap = typemax(F)
    @inbounds for j in eachindex(positions)
        j == i_self && continue
        r_ij = positions[j] - pos_i
        d    = norm(r_ij)
        d > nb_radius && continue
        d > eps(F) || continue
        dot(r_ij / d, dir_ref) > cos_fov || continue   # forward cone filter
        gap = max(d - r_i - r_all[j], zero(F))          # surface-to-surface gap
        min_gap = min(min_gap, gap)
    end
    return min_gap == typemax(F) ? F(Inf) : min_gap
end

# ── Direction: isotropic repulsion (V1/V2) ────────────────────────────────────

"""
    csm_direction_isotropic(pos_i, dir_goal, i_self, positions, walls, params, cos_fov) → e

Compute movement direction as goal direction minus repulsion from nearest forward neighbor.

## Design rationale (diagnostic-driven fix)

Diagnostic (diag_3l_csm.jl) showed that summing repulsion over all forward neighbors
causes total |repulsion| >> 1.0 (goal pull) in dense crowds (25+ neighbors × a×exp(-d/D)).
This flips 21–26% of agents to point AWAY from the goal at t=0, causing immediate deadlock.

Fix: only the NEAREST forward neighbor contributes to direction repulsion. This matches
the spirit of "avoid the nearest obstacle" and prevents accumulation over many neighbors.
Wall repulsion (V2) is retained as-is (walls are few, contribution is bounded).

Safety cap: total |repulsion| is clamped to < 1.0 so direction can NEVER reverse past 90°
from goal even in degenerate cases (very close neighbor + wall simultaneously).

## References
Tordeux 2016 eq. (3) direction model. JuPedSim v10 GCFVM source.

Returns a unit vector.
"""
@inline function csm_direction_isotropic(
    pos_i    :: SVector{2,F},
    dir_goal :: SVector{2,F},
    i_self   :: Int,
    positions :: Vector{SVector{2,F}},
    walls    :: Vector{NTuple{2, SVector{2,F}}},
    params   :: CSMParams{F},
    cos_fov  :: F
) :: SVector{2,F} where {F<:AbstractFloat}

    # ── Find nearest forward neighbor only ──────────────────────────────────
    # (Sum over all forward neighbors creates |repulsion| >> 1 in dense crowds,
    #  reversing direction for 20-30% of agents immediately from t=0.)
    min_d  = typemax(F)
    best_j = 0
    @inbounds for j in eachindex(positions)
        j == i_self && continue
        r_ij = positions[j] - pos_i
        d    = norm(r_ij)
        d > params.neighbor_radius && continue
        d > eps(F) || continue
        dot(r_ij / d, dir_goal) > cos_fov || continue   # forward cone filter
        if d < min_d
            min_d  = d
            best_j = j
        end
    end

    # Repulsion from nearest forward neighbor only
    neighbor_repulsion = zero(SVector{2,F})
    if best_j > 0
        r_ij  = positions[best_j] - pos_i
        n_nbr = r_ij / min_d
        neighbor_repulsion = (params.a_neighbor * exp(-min_d / params.D_neighbor)) * n_nbr
    end

    # ── Wall repulsion (V2: a_wall > 0 only) ────────────────────────────────
    # SIGN: n_w = toward wall. Subtracting deflects agent AWAY from wall.
    #
    # LATERAL-ONLY FILTER (Bug 9 fix — diagnosed 2026-08-27):
    #   Walls where dot(n_w, dir_goal) > 0 are "forward-pointing" — n_w aligns
    #   with the goal direction. Subtracting such a wall_rep wipes out raw.x:
    #     A15 @ (9.75,0.75): W3(door-bot) n_w=(1,0)=+x, goal=(0.87,0.49)
    #     dot=0.87 → wall_rep=(0.88,0) → raw.x = 0.87-0.88 = -0.01 → FROZEN.
    #
    #   Forward deceleration is the OV speed model's job (gap→speed).
    #   The direction model only needs LATERAL steering (n_w ⊥ dir_goal).
    #   Filter: skip any wall with dot(n_w, dir_goal) > 0.
    #
    # Effect on 5 wall types (agents heading rightward toward door):
    #   W0 (left,  n_w=-x): dot=-0.97 ≤ 0 → INCLUDED  (boosts forward) ✓
    #   W1 (bot,   n_w=-y): dot=-0.22 ≤ 0 → INCLUDED  (steers up/away) ✓
    #   W2 (top,   n_w=+y): dot=-0.22 ≤ 0 → INCLUDED  (steers down/away) ✓
    #   W3 (door-bot,n_w=+x): dot=+0.97 > 0 → SKIPPED (forward → speed) ✓
    #   W4 (door-top,n_w=+x): dot=+0.97 > 0 → SKIPPED (forward → speed) ✓
    wall_repulsion = zero(SVector{2,F})
    if params.a_wall > zero(F)
        for (p1, p2) in walls
            pt, dw, _ = nearest_point_on_segment(p1, p2, pos_i)
            dw > params.neighbor_radius && continue
            dw < eps(F) && continue
            n_w = (pt - pos_i) / dw   # unit vector FROM agent TOWARD wall
            # Lateral-only: skip forward-pointing walls (handled by speed model)
            dot(n_w, dir_goal) > zero(F) && continue
            wall_repulsion += (params.a_wall * exp(-dw / params.D_wall)) * n_w
        end
    end

    repulsion = neighbor_repulsion + wall_repulsion

    # ── Safety cap: clamp |repulsion| < 0.99 ────────────────────────────────
    # Guarantees raw = dir_goal - repulsion has positive component along dir_goal,
    # preventing direction reversal even when a single close neighbor is very near.
    rep_mag = norm(repulsion)
    if rep_mag >= one(F)
        repulsion = repulsion * (F(0.99) / rep_mag)
    end

    # ── Movement direction ───────────────────────────────────────────────────
    raw      = dir_goal - repulsion
    raw_norm = norm(raw)
    return raw_norm > eps(F) ? raw / raw_norm : dir_goal
end

# ── Direction: rotational steering (V3) ───────────────────────────────────────

"""
    csm_direction_rotational(pos_i, dir_goal, heading_old, i_self, positions, walls, params, dt)
    → (new_dir::SVector{2,F}, new_heading::F)

V3 rotational steering: V2 direction model + first-order heading relaxation.

Algorithm (Tordeux 2016 / JuPedSim GCFS model):
1. Compute e_target using V2's isotropic repulsion (csm_direction_isotropic).
2. Compute target angle θ_target = atan(e_target[2], e_target[1]).
3. Apply first-order heading relaxation:
       θ_new = θ_old + (dt/τ) × Δθ    where Δθ = wrap(θ_target − θ_old)
4. Return (cos(θ_new), sin(θ_new)), θ_new.

The heading relaxation τ smooths direction changes over time:
- τ → 0:  instantaneous heading change (reduces to V2 direction model)
- τ → ∞:  agents maintain initial heading (degenerate)
- τ = 0.5s (default): well-damped heading convergence over ~5 steps at dt=0.05s

# Bug 12 history (2026-08-27)
OLD algorithm: "rotate away from nearest forward neighbor's lateral offset."
Pathology: in a grid crowd, nearest neighbor is always ≈90° off goal direction
(sp_y=0.486m < sp_x=0.563m). tanh(lateral/d) ≈ tanh(1) ≈ 0.76 → max rotation.
Diagnostic showed: θ_diff 0→30° in 1s, v̄ 0.097→0.052 → complete deadlock.
FIX: use V2's isotropic repulsion (proven, working) as target.
"""
@inline function csm_direction_rotational(
    pos_i       :: SVector{2,F},
    dir_goal    :: SVector{2,F},
    heading_old :: F,
    i_self      :: Int,
    positions   :: Vector{SVector{2,F}},
    walls       :: Vector{NTuple{2, SVector{2,F}}},
    params      :: CSMParams{F},
    dt          :: F
) :: Tuple{SVector{2,F}, F} where {F<:AbstractFloat}
    cos_fov = cos(params.fov_half_angle)

    # 1. Target direction = V2 isotropic repulsion (reuse proven V2 model)
    e_target = csm_direction_isotropic(pos_i, dir_goal, i_self, positions, walls, params, cos_fov)

    # 2. Target heading angle
    θ_target = atan(e_target[2], e_target[1])

    # 3. First-order heading relaxation
    # θ_new = θ_old + (dt/τ) × Δθ, wrapped to [-π, π]
    τ   = params.heading_relaxation_τ
    Δθ  = θ_target - heading_old
    Δθ -= F(2π) * round(Δθ / F(2π))          # wrap to [-π, π]
    α   = min(dt / max(τ, eps(F)), one(F))    # clamp α ∈ [0,1]: no overshoot
    θ_new = heading_old + α * Δθ

    return SVector{2,F}(cos(θ_new), sin(θ_new)), θ_new
end

# ── V1/V2 update (Threads.@threads double-buffer) ─────────────────────────────

function _csm_update_v1v2!(
    all_pos  :: Vector{SVector{2,F}},
    all_goal :: Vector{SVector{2,F}},
    r_all    :: Vector{F},
    walls    :: Vector{NTuple{2, SVector{2,F}}},
    params   :: CSMParams{F},
    new_vel  :: Vector{SVector{2,F}}   # write-only output (own slot per thread)
) where {F<:AbstractFloat}
    N       = length(all_pos)
    r_i     = params.radius      # individual agent radius (NOT body length)
    cos_fov = cos(params.fov_half_angle)

    Threads.@threads for i in 1:N
        pos_i  = all_pos[i]
        goal_i = all_goal[i]

        # Goal direction (reference for forward-cone filter and repulsion direction)
        gd       = goal_i - pos_i
        goal_d   = norm(gd)
        dir_goal = goal_d > eps(F) ? gd / goal_d : SVector(one(F), zero(F))

        # Surface-to-surface gap to nearest forward neighbor
        # r_i = individual radius; gap = max(d - r_i - r_j, 0) [surface contact at gap=0]
        s_i = csm_gap(pos_i, dir_goal, i, all_pos, r_all, r_i, cos_fov, params.neighbor_radius)

        # Speed (OV function — Tordeux 2016 eq. 2, no body-length shift)
        v_i = csm_speed(s_i, params.v₀, params.T)

        # Direction (isotropic repulsion, V1 = no walls, V2 = with walls)
        e_i = csm_direction_isotropic(pos_i, dir_goal, i, all_pos, walls, params, cos_fov)

        # Write own velocity slot — thread-safe (no other thread writes new_vel[i])
        new_vel[i] = v_i * e_i
    end
end

# ── V3 update (Threads.@threads double-buffer) ────────────────────────────────

function _csm_update_v3!(
    all_pos      :: Vector{SVector{2,F}},
    all_goal     :: Vector{SVector{2,F}},
    r_all        :: Vector{F},
    walls        :: Vector{NTuple{2, SVector{2,F}}},
    params       :: CSMParams{F},
    dt           :: F,
    new_vel      :: Vector{SVector{2,F}},   # write-only output
    new_headings :: Vector{F}               # write-only output (own slot per thread)
) where {F<:AbstractFloat}
    N   = length(all_pos)
    r_i = params.radius    # individual agent radius

    Threads.@threads for i in 1:N
        pos_i  = all_pos[i]
        goal_i = all_goal[i]

        gd       = goal_i - pos_i
        goal_d   = norm(gd)
        dir_goal = goal_d > eps(F) ? gd / goal_d : SVector(one(F), zero(F))

        # Surface-to-surface gap to nearest forward neighbor
        s_i = csm_gap(pos_i, dir_goal, i, all_pos, r_all, r_i,
                      cos(params.fov_half_angle), params.neighbor_radius)

        # Speed (Tordeux 2016 OV function)
        v_i = csm_speed(s_i, params.v₀, params.T)

        # V3 rotational steering + heading relaxation (target = V2 direction)
        new_dir, θ_new = csm_direction_rotational(
            pos_i, dir_goal, new_headings[i], i, all_pos, walls, params, dt)

        new_vel[i]      = v_i * new_dir
        new_headings[i] = θ_new   # own slot — thread-safe
    end
end

# ── Top-level entry point ──────────────────────────────────────────────────────

"""
    update_csm_system!(world, dt)

Advance all CSM agents (carrying `CSMParams{F}`) by one timestep `dt` (seconds).

Dispatches to V1/V2 or V3 path based on `params.use_rotational_steering`.

## ECS Archetype

CSM agents are identified by the `CSMParams{F}` component. They must carry:
  - `Position{F}`, `Velocity{F}`, `Goal{F}`, `CSMParams{F}`
  - V3 additionally: `AgentCSMState{F}` (per-agent heading angle, updated in-place)
  - **NOT**: `SFMParams`, `ORCAParams`, `HybridFSMParams`, `Force{F}` — those
    systems skip CSM agents automatically (different ECS archetypes).

## Threading

Two-pass double-buffer:
  - Pass 1 (Threads.@threads): reads `positions` (read-only array), writes
    `new_velocities[i]` (own index only). Zero data hazards.
  - Pass 2 (single-thread ECS write-back): writes Velocity and Position components.

## Complexity

O(N²) neighbor scan (Sprint 3L). Sprint 3L+ will use the spatial hash grid for O(N×k).
Acceptable for N ≤ 1000 (N=80 T7 test: ~6400 distance checks per step × 2400 steps ≈ 15M fp ops total).
"""
function update_csm_system!(world::World, dt::F) where {F<:AbstractFloat}
    # ── Guard ────────────────────────────────────────────────────────────────
    n_csm = 0
    try
        n_csm = count_entities(Query(world, (CSMParams{F},)))
    catch e
        e isa ArgumentError && return
        rethrow()
    end
    n_csm == 0 && return

    # ── Retrieve shared params from first agent ───────────────────────────────
    # Sprint 3L: all CSM agents share one params struct. Sprint 3L+: per-agent override.
    local params::CSMParams{F}
    for (_, params_col) in Query(world, (CSMParams{F},))
        params = params_col[1]
        break
    end

    # ── Collect walls ─────────────────────────────────────────────────────────
    walls = NTuple{2, SVector{2,F}}[]
    try
        for (_, wall_col) in Query(world, (WallSegment{F},))
            for i in eachindex(wall_col)
                push!(walls, (wall_col[i].p1, wall_col[i].p2))
            end
        end
    catch e
        e isa ArgumentError || rethrow()
    end

    if params.use_rotational_steering
        _update_csm_v3_ecs!(world, walls, params, dt)
    else
        _update_csm_v1v2_ecs!(world, walls, params, dt)
    end
end

# ── V1/V2 ECS wrapper ─────────────────────────────────────────────────────────
function _update_csm_v1v2_ecs!(
    world  :: World,
    walls  :: Vector{NTuple{2, SVector{2,F}}},
    params :: CSMParams{F},
    dt     :: F
) where {F<:AbstractFloat}
    # 1. Collect positions and goals into plain arrays
    all_pos  = SVector{2,F}[]
    all_goal = SVector{2,F}[]
    try
        for (_, pos_col, _, goal_col, _) in
                Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
            for i in eachindex(pos_col)
                push!(all_pos,  pos_col[i].p)
                push!(all_goal, goal_col[i].g)
            end
        end
    catch e
        e isa ArgumentError && return
        rethrow()
    end
    N = length(all_pos)
    N == 0 && return

    r_all = fill(params.radius, N)   # uniform radius in Sprint 3L

    # 2. Compute new velocities (threaded)
    new_vel = Vector{SVector{2,F}}(undef, N)
    _csm_update_v1v2!(all_pos, all_goal, r_all, walls, params, new_vel)

    # 3. Write back to ECS (single-threaded, each archetype column in order)
    idx = 0
    for (_, pos_col, vel_col, goal_col, _) in
            Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
        for i in eachindex(pos_col)
            idx += 1
            vel_col[i] = Velocity(new_vel[idx])
            pos_col[i] = Position(pos_col[i].p + new_vel[idx] * dt)
        end
    end
end

# ── V3 ECS wrapper ────────────────────────────────────────────────────────────
function _update_csm_v3_ecs!(
    world  :: World,
    walls  :: Vector{NTuple{2, SVector{2,F}}},
    params :: CSMParams{F},
    dt     :: F
) where {F<:AbstractFloat}
    # 1. Collect positions, goals, and current headings
    all_pos  = SVector{2,F}[]
    all_goal = SVector{2,F}[]
    headings = F[]
    try
        for (_, pos_col, _, goal_col, _, state_col) in
                Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
            for i in eachindex(pos_col)
                push!(all_pos,  pos_col[i].p)
                push!(all_goal, goal_col[i].g)
                push!(headings, state_col[i].heading)
            end
        end
    catch e
        e isa ArgumentError && return
        rethrow()
    end
    N = length(all_pos)
    N == 0 && return

    r_all = fill(params.radius, N)

    # 2. Compute new velocities and headings (threaded)
    new_vel      = Vector{SVector{2,F}}(undef, N)
    new_headings = copy(headings)   # pass old headings in; function overwrites with new
    _csm_update_v3!(all_pos, all_goal, r_all, walls, params, dt, new_vel, new_headings)

    # 3. Write back to ECS
    idx = 0
    for (_, pos_col, vel_col, goal_col, _, state_col) in
            Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
        for i in eachindex(pos_col)
            idx += 1
            vel_col[i]   = Velocity(new_vel[idx])
            pos_col[i]   = Position(pos_col[i].p + new_vel[idx] * dt)
            state_col[i] = AgentCSMState{F}(new_headings[idx])
        end
    end
end
