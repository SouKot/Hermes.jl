# systems/csm.jl -- Collision-Free Speed Model (CSM)
#
# Implements CSM Classic (Tordeux et al. 2016) and CSM V3 (JuPedSim V3)
# as a unified first-order pedestrian model.
#
# Model variants (controlled by CSMParams fields):
#   Classic: use_rotational_steering=false   (Tordeux 2016 -- faithful paper implementation)
#   V3:      use_rotational_steering=true    (JuPedSim V3 heading relaxation)
#
# Key design decisions (Sprint 3M -- 2026-08-27):
#   - Repulsion formula: a*exp(-gap/D) where gap = surface-to-surface distance (Tordeux 2016).
#     Previously used center-to-center distance -- 5-54x too weak at relevant gaps.
#   - ALL neighbors summed isotropically (no nearest-only filter). Symmetric crowds
#     naturally cancel. Asymmetric situations (near walls, bottleneck) create deflection.
#   - Geometry constraint: JuPedSim contact-level push-out (strength=5.0, range=0.02m),
#     applied in ALL directions (no lateral filter). Negligible at >0.30m from wall.
#   - No safety cap: removed. With correct formula + geometry constraint, cap not needed.
#   - V2 wall repulsion in direction model: DELETED. Not in Tordeux 2016. Was a workaround.
#
# Sprint 3N-a fixes (2026-08-27 -- matching JuPedSim GetSpacing exactly):
#   - csm_gap: replaced full-360 FOV with JuPedSim forward half-plane + narrow lateral corridor.
#     JuPedSim GetSpacing: inFront=(dir·Δp≥0) AND inCorridor=(|lat·Δp|≤r_i+r_j).
#     Old code (fov=π): ALL neighbors counted as speed blockers → everyone slowed → deadlock.
#   - Computation order: direction e_i computed FIRST, then gap measured in e_i direction.
#     JuPedSim: direction = normalize(e0 + repulsions), THEN spacing = GetSpacing(dir).
#     Old code: gap measured in dir_goal, then direction computed separately (inconsistent).
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
# References:
#   Tordeux, A., Chraibi, M., Seyfried, A. (2016). Collision-free speed model for
#   pedestrian dynamics. In Traffic and Granular Flow '15, 225-232. Springer.
#   JuPedSim v1.4.2 -- libsimulator/src/CollisionFreeSpeedModel.cpp (reference implementation)


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
    csm_gap(pos_i, dir, i_self, positions, r_all, r_i, nb_radius) → s

Surface-to-surface gap to the nearest agent that blocks movement in direction `dir`.

Matches JuPedSim `GetSpacing` exactly (CollisionFreeSpeedModel.cpp):
  1. **Forward half-plane**: `dir · Δp ≥ 0`  (Δp = pos_j - pos_i)
     Only agents ahead in the current movement direction are considered.
  2. **Lateral corridor**: `|perp(dir) · Δp| ≤ r_i + r_j`
     Only agents within a corridor of width 2(r_i+r_j) ≈ 0.4m count.
  3. **Gap**: `|Δp| - (r_i + r_j)` = surface-to-surface distance.

Returns `Inf` if no agent qualifies (open path ahead).

## Why this matters (Sprint 3N-a)

Old code used a full-360° FOV (fov_half_angle=π). In a dense crowd with N=80 in
10×4m, every agent's nearest neighbor is within ~0.3m in SOME direction, making
gap≈0 for all → speed→0 → deadlock. With JuPedSim's narrow forward corridor,
an agent in orderly lane flow has a clear lane ahead → normal speed.
"""
@inline function csm_gap(
    pos_i     :: SVector{2,F},
    dir       :: SVector{2,F},   # current movement direction (unit vector)
    i_self    :: Int,
    positions :: Vector{SVector{2,F}},
    r_all     :: Vector{F},
    r_i       :: F,
    nb_radius :: F
) :: F where {F<:AbstractFloat}
    # Lateral direction (perpendicular to dir, 90° CCW)
    dir_lat  = SVector{2,F}(-dir[2], dir[1])
    min_gap  = typemax(F)
    @inbounds for j in eachindex(positions)
        j == i_self && continue
        Δp = positions[j] - pos_i
        d  = norm(Δp)
        d > nb_radius && continue
        d > eps(F)    || continue
        # 1. Forward half-plane check (JuPedSim: inFront = direction.ScalarProduct(distp12) >= 0)
        dot(dir, Δp) >= zero(F) || continue
        # 2. Lateral corridor check (JuPedSim: |left.ScalarProduct(distp12)| <= l)
        l = r_i + r_all[j]     # contact distance (sum of radii)
        abs(dot(dir_lat, Δp)) <= l || continue
        # 3. Surface-to-surface gap
        gap = max(d - l, zero(F))
        min_gap = min(min_gap, gap)
    end
    return min_gap == typemax(F) ? F(Inf) : min_gap
end

# -- Direction: isotropic repulsion (Classic / V3 reference direction) ----------

"""
    csm_direction_isotropic(pos_i, dir_goal, i_self, positions, r_all, r_i, walls, params) -> e

Compute movement direction: goal direction minus isotropic repulsion from ALL neighbors
plus all-direction geometry contact constraint.

## Algorithm (Tordeux 2016 eq. 3 -- corrected surface-to-surface gap formula)

1. Sum repulsion over ALL neighbors (isotropic, no FOV filter):
   - In symmetric crowds, opposite repulsions cancel (diagnostic confirmed |net|=0).
   - Only asymmetric configurations (near walls, bottleneck entry) produce net deflection.
   - Formula: a * exp(-gap_ij / D) where gap_ij = max(center_dist - r_i - r_j, 0)
   - Previously used center-to-center distance -- 5-54x weaker than paper specifies.

2. All-direction geometry contact constraint (JuPedSim approach):
   - strength_geo=5.0, range_geo=0.02m (contact-level only)
   - Applied in ALL directions (no lateral filter needed -- range so small it's negligible at >0.3m)
   - Formula: strength_geo * exp(-gap_wall / range_geo) toward wall
   - Subtracted from goal direction (pushes agent away from wall)

3. No safety cap: removed. With correct formula and contact constraint,
   direction reversal only occurs in genuinely blocked situations (correct behavior).

## References
Tordeux 2016 eq. (3). JuPedSim v1.4.2 CollisionFreeSpeedModel.cpp lines 69-89, 196-217.

Returns a unit vector. Falls back to dir_goal if result is zero.
"""
@inline function csm_direction_isotropic(
    pos_i    :: SVector{2,F},
    dir_goal :: SVector{2,F},
    i_self   :: Int,
    positions :: Vector{SVector{2,F}},
    r_all    :: Vector{F},
    r_i      :: F,
    walls    :: Vector{NTuple{2, SVector{2,F}}},
    params   :: CSMParams{F}
) :: SVector{2,F} where {F<:AbstractFloat}

    # -- Neighbor repulsion: sum over ALL neighbors isotropically ------------------
    # Surface-to-surface gap formula: gap = max(center_dist - r_i - r_j, 0)
    # Symmetric crowds: opposing vectors cancel (diagnostic: |net_sym|=0). Only
    # asymmetric configurations (door entry, near wall) produce net deflection.
    nbr_rep = zero(SVector{2,F})
    @inbounds for j in eachindex(positions)
        j == i_self && continue
        r_ij = positions[j] - pos_i
        d    = norm(r_ij)
        d > params.neighbor_radius && continue
        d > eps(F)                 || continue
        n_ij = r_ij / d                                    # unit vector FROM i TO j
        gap  = max(d - r_i - r_all[j], zero(F))           # surface-to-surface gap
        nbr_rep = nbr_rep + (params.a_neighbor * exp(-gap / params.D_neighbor)) * n_ij
    end

    # -- Geometry contact constraint (all-direction, JuPedSim approach) -----------
    # Contact-level only (range_geo=0.02m). Negligible at dist > 0.30m from wall.
    # Applied in ALL directions -- no lateral filter needed with small range.
    geo_rep = zero(SVector{2,F})
    if params.strength_geo > zero(F)
        for (p1, p2) in walls
            pt, dw, _ = nearest_point_on_segment(p1, p2, pos_i)
            dw < eps(F) && continue
            n_w   = (pt - pos_i) / dw                     # unit vector TOWARD wall
            gap_w = max(dw - r_i, zero(F))                # surface-to-surface gap to wall
            geo_rep = geo_rep + (params.strength_geo * exp(-gap_w / params.range_geo)) * n_w
        end
    end

    # -- Movement direction: normalize (dir_goal - all_repulsion) -----------------
    # JuPedSim: direction = (desired + neighbor_rep + boundary_rep).Normalized()
    # Fallback to dir_goal if result is zero (fully symmetric cancellation).
    raw      = dir_goal - nbr_rep - geo_rep
    raw_norm = norm(raw)
    return raw_norm > eps(F) ? raw / raw_norm : dir_goal
end

# -- Direction: rotational steering (V3) ----------------------------------------

"""
    csm_direction_rotational(pos_i, dir_goal, heading_old, i_self, positions, r_all, r_i, walls, params, dt)
    -> (new_dir::SVector{2,F}, new_heading::F)

V3 rotational steering: isotropic direction model + first-order heading relaxation.

Algorithm:
1. Compute e_target using the corrected isotropic direction model (csm_direction_isotropic).
2. Compute target heading angle theta_target = atan(e_target[2], e_target[1]).
3. Apply first-order heading relaxation:
       theta_new = theta_old + (dt/tau) x Delta_theta    where Delta_theta = wrap(theta_target - theta_old)
4. Return (cos(theta_new), sin(theta_new)), theta_new.

The heading relaxation tau smooths direction changes over time:
- tau = 0:  instantaneous heading change (reduces to Classic direction model)
- tau = 0.3s (JuPedSim V3 default): well-damped heading convergence

Note: Sprint 3N+O will replace this with the proper JuPedSim V3 rotation
(relative angle from reference_direction, 2D anisotropic FOV).
"""
@inline function csm_direction_rotational(
    pos_i       :: SVector{2,F},
    dir_goal    :: SVector{2,F},
    heading_old :: F,
    i_self      :: Int,
    positions   :: Vector{SVector{2,F}},
    r_all       :: Vector{F},
    r_i         :: F,
    walls       :: Vector{NTuple{2, SVector{2,F}}},
    params      :: CSMParams{F},
    dt          :: F
) :: Tuple{SVector{2,F}, F} where {F<:AbstractFloat}
    # 1. Target direction = corrected isotropic direction (surface-to-surface gap)
    e_target = csm_direction_isotropic(pos_i, dir_goal, i_self, positions, r_all, r_i, walls, params)

    # 2. Target heading angle
    θ_target = atan(e_target[2], e_target[1])

    # 3. First-order heading relaxation
    # θ_new = θ_old + (dt/τ) × Δθ, wrapped to [-π, π]
    τ   = params.heading_relaxation_tau
    Δθ  = θ_target - heading_old
    Δθ -= F(2π) * round(Δθ / F(2π))          # wrap to [-π, π]
    α   = min(dt / max(τ, eps(F)), one(F))    # clamp α ∈ [0,1]: no overshoot
    θ_new = heading_old + α * Δθ

    return SVector{2,F}(cos(θ_new), sin(θ_new)), θ_new
end

# -- Classic (V1) update (Threads.@threads double-buffer) ------------------------

function _csm_update_v1v2!(
    all_pos  :: Vector{SVector{2,F}},
    all_goal :: Vector{SVector{2,F}},
    r_all    :: Vector{F},
    walls    :: Vector{NTuple{2, SVector{2,F}}},
    params   :: CSMParams{F},
    new_vel  :: Vector{SVector{2,F}}   # write-only output (own slot per thread)
) where {F<:AbstractFloat}
    N   = length(all_pos)
    r_i = params.radius      # individual agent radius (NOT body length)

    Threads.@threads for i in 1:N
        pos_i  = all_pos[i]
        goal_i = all_goal[i]

        # Goal direction (nominal desired direction -- used by direction model)
        gd       = goal_i - pos_i
        goal_d   = norm(gd)
        dir_goal = goal_d > eps(F) ? gd / goal_d : SVector(one(F), zero(F))

        # Sprint 3N-a: compute direction FIRST (matches JuPedSim ordering).
        # JuPedSim: direction = normalize(e0 + repulsions), THEN spacing = GetSpacing(direction).
        # Gap is measured in e_i direction (repulsion-corrected), NOT dir_goal.
        e_i = csm_direction_isotropic(pos_i, dir_goal, i, all_pos, r_all, r_i, walls, params)

        # Surface-to-surface gap to nearest corridor-blocking agent (in e_i direction)
        s_i = csm_gap(pos_i, e_i, i, all_pos, r_all, r_i, params.neighbor_radius)

        # Speed (OV function -- Tordeux 2016 eq. 2)
        v_i = csm_speed(s_i, params.v0, params.T)

        # Write own velocity slot -- thread-safe (no other thread writes new_vel[i])
        new_vel[i] = v_i * e_i
    end
end


# -- V3 update (Threads.@threads double-buffer) ----------------------------------

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

        # Sprint 3N-a: V3 also computes direction (rotational) first, gap in new_dir.
        new_dir, theta_new = csm_direction_rotational(
            pos_i, dir_goal, new_headings[i], i, all_pos, r_all, r_i, walls, params, dt)

        # Gap in the rotational-corrected direction (matches JuPedSim ordering)
        s_i = csm_gap(pos_i, new_dir, i, all_pos, r_all, r_i, params.neighbor_radius)

        # Speed (Tordeux 2016 OV function)
        v_i = csm_speed(s_i, params.v0, params.T)

        new_vel[i]      = v_i * new_dir
        new_headings[i] = theta_new   # own slot -- thread-safe
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

# ════════════════════════════════════════════════════════════════════════════════
# Sprint 3N-b: Navigation-aware dispatch
# update_csm_system!(world, dt, nav::AbstractNavigationField{F})
# ════════════════════════════════════════════════════════════════════════════════

"""
    update_csm_system!(world, dt, nav::AbstractNavigationField)

Advance all CSM agents by `dt` seconds using FMM navigation for global routing.

The navigation field replaces raw goal-pointing `(goal-pos)/|.|` with
`get_nav_direction(nav, pos)` — a precomputed FMM gradient that routes agents
through the geometry correctly. Local avoidance (neighbor repulsion, geometry
contact) is identical to the no-nav version.

Accepts any `AbstractNavigationField` subtype — FMM, NavMesh, or custom.

## Build a nav field
```julia
walls = [(wall_col[i].p1, wall_col[i].p2) for i in ...]
nav   = build_navigation_field(walls, SVector(12f0, 2f0))
update_csm_system!(world, dt, nav)
```
"""
function update_csm_system!(world::World, dt::F, nav::AbstractNavigationField{F}) where {F<:AbstractFloat}
    n_csm = 0
    try
        n_csm = count_entities(Query(world, (CSMParams{F},)))
    catch e
        e isa ArgumentError && return; rethrow()
    end
    n_csm == 0 && return

    local params::CSMParams{F}
    for (_, params_col) in Query(world, (CSMParams{F},))
        params = params_col[1]; break
    end

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
        _update_csm_v3_ecs_nav!(world, walls, params, dt, nav)
    else
        _update_csm_v1v2_ecs_nav!(world, walls, params, dt, nav)
    end
end

# ── Nav-aware Classic ECS wrapper ─────────────────────────────────────────────
function _update_csm_v1v2_ecs_nav!(
    world  :: World, walls :: Vector{NTuple{2, SVector{2,F}}},
    params :: CSMParams{F}, dt :: F, nav :: AbstractNavigationField{F}
) where {F<:AbstractFloat}
    all_pos = SVector{2,F}[]; all_goal = SVector{2,F}[]
    try
        for (_, pos_col, _, goal_col, _) in
                Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
            for i in eachindex(pos_col)
                push!(all_pos, pos_col[i].p); push!(all_goal, goal_col[i].g)
            end
        end
    catch e; e isa ArgumentError && return; rethrow(); end
    N = length(all_pos); N == 0 && return
    r_all = fill(params.radius, N)
    new_vel = Vector{SVector{2,F}}(undef, N)
    N_i = N; r_i = params.radius
    Threads.@threads for i in 1:N_i
        dir_nav = get_nav_direction(nav, all_pos[i])
        e_i = csm_direction_isotropic(all_pos[i], dir_nav, i, all_pos, r_all, r_i, walls, params)
        s_i = csm_gap(all_pos[i], e_i, i, all_pos, r_all, r_i, params.neighbor_radius)
        new_vel[i] = csm_speed(s_i, params.v0, params.T) * e_i
    end
    idx = 0
    for (_, pos_col, vel_col, _, _) in
            Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
        for i in eachindex(pos_col)
            idx += 1
            vel_col[i] = Velocity(new_vel[idx])
            pos_col[i] = Position(pos_col[i].p + new_vel[idx] * dt)
        end
    end
end

# ── Nav-aware V3 ECS wrapper ──────────────────────────────────────────────────
function _update_csm_v3_ecs_nav!(
    world  :: World, walls :: Vector{NTuple{2, SVector{2,F}}},
    params :: CSMParams{F}, dt :: F, nav :: AbstractNavigationField{F}
) where {F<:AbstractFloat}
    all_pos = SVector{2,F}[]; all_goal = SVector{2,F}[]; headings = F[]
    try
        for (_, pos_col, _, goal_col, _, state_col) in
                Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
            for i in eachindex(pos_col)
                push!(all_pos, pos_col[i].p); push!(all_goal, goal_col[i].g)
                push!(headings, state_col[i].heading)
            end
        end
    catch e; e isa ArgumentError && return; rethrow(); end
    N = length(all_pos); N == 0 && return
    r_all = fill(params.radius, N)
    new_vel = Vector{SVector{2,F}}(undef, N); new_headings = copy(headings)
    N_i = N; r_i = params.radius
    Threads.@threads for i in 1:N_i
        dir_nav = get_nav_direction(nav, all_pos[i])
        new_dir, theta_new = csm_direction_rotational(
            all_pos[i], dir_nav, new_headings[i], i, all_pos, r_all, r_i, walls, params, dt)
        s_i = csm_gap(all_pos[i], new_dir, i, all_pos, r_all, r_i, params.neighbor_radius)
        new_vel[i] = csm_speed(s_i, params.v0, params.T) * new_dir
        new_headings[i] = theta_new
    end
    idx = 0
    for (_, pos_col, vel_col, _, _, state_col) in
            Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
        for i in eachindex(pos_col)
            idx += 1
            vel_col[i]   = Velocity(new_vel[idx])
            pos_col[i]   = Position(pos_col[i].p + new_vel[idx] * dt)
            state_col[i] = AgentCSMState{F}(new_headings[idx])
        end
    end
end


# ════════════════════════════════════════════════════════════════════════════════
# Sprint 3R: O(N×k) CPU dispatch using CellListMap
# ════════════════════════════════════════════════════════════════════════════════

# ── Internal: per-agent state for O(N×k) direction + gap computation ─────────
# Built by CellListMap.pairwise! then read in the per-agent loop.
struct _CSMNeighborAccum{F<:AbstractFloat}
    nbr_rep::SVector{2,F}   # accumulated repulsion vector (isotropic)
    min_gap_forward::F       # minimum forward-corridor gap (asymmetric)
end

# ── Per-step O(N×k) CSM update: Classic (V1/V2) ──────────────────────────────

"""
    update_csm_system!(world, search::CPUNeighborSearch, dt)

O(N×k) CSM dispatch using `CellListMap.pairwise!`. Builds the CellListMap
grid once per step, then for each agent accumulates:
1. Isotropic neighbor repulsion (symmetric pair — computed once per pair)
2. Per-agent minimum forward-corridor gap (asymmetric — direction-dependent)

Complexity: O(N×k) per step (k ≈ 5–20 for typical pedestrian densities).
Compared to the O(N²) path at N=1000: ~10k vs 1M distance evaluations.
"""
function update_csm_system!(world::World, search::CPUNeighborSearch{F}, dt::F) where {F<:AbstractFloat}
    n_csm = 0
    try
        n_csm = count_entities(Query(world, (CSMParams{F},)))
    catch e
        e isa ArgumentError && return; rethrow()
    end
    n_csm == 0 && return

    local params::CSMParams{F}
    for (_, params_col) in Query(world, (CSMParams{F},))
        params = params_col[1]; break
    end

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
        _update_csm_v3_ecs_pairwise!(world, search, walls, params, dt)
    else
        _update_csm_classic_ecs_pairwise!(world, search, walls, params, dt)
    end
end

# ── Classic V1/V2 pairwise ────────────────────────────────────────────────────
function _update_csm_classic_ecs_pairwise!(
    world  :: World,
    search :: CPUNeighborSearch{F},
    walls  :: Vector{NTuple{2, SVector{2,F}}},
    params :: CSMParams{F},
    dt     :: F
) where {F<:AbstractFloat}
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
    catch e; e isa ArgumentError && return; rethrow(); end
    N = length(all_pos); N == 0 && return
    r_i = params.radius

    # Build neighbor list (positions only; radii uniform)
    build_grid!(search, all_pos, CPU())

    # Accumulate symmetric repulsion using pairwise! (O(N×k))
    nbr_reps = zeros(SVector{2,F}, N)
    function accum_rep(pair, out)
        (; i, j, d) = pair
        d < F(1e-6) && return out
        n_ij = (all_pos[j] - all_pos[i]) / d
        gap  = max(d - F(2) * r_i, zero(F))
        f    = params.a_neighbor * exp(-gap / params.D_neighbor)
        out[i] = out[i] + f * n_ij
        out[j] = out[j] - f * n_ij   # Newton 3rd: j repelled away from i
        return out
    end
    fill!(nbr_reps, zero(SVector{2,F})); nbr_reps = CellListMap.pairwise!(accum_rep, search.system)

    # Per-agent direction + gap + velocity computation (can be threaded)
    new_vel = Vector{SVector{2,F}}(undef, N)
    Threads.@threads for i in 1:N
        pos_i  = all_pos[i]
        gd     = all_goal[i] - pos_i
        gd_n   = norm(gd)
        dir_goal = gd_n > eps(F) ? gd / gd_n : SVector(one(F), zero(F))

        # Wall geometry contact
        geo_rep = zero(SVector{2,F})
        if params.strength_geo > zero(F)
            for (p1, p2) in walls
                seg = p2 - p1; l2 = seg[1]^2 + seg[2]^2
                t   = l2 < F(1e-10) ? zero(F) :
                    clamp(((pos_i[1]-p1[1])*seg[1] + (pos_i[2]-p1[2])*seg[2]) / l2, zero(F), one(F))
                q   = p1 + t * seg; rel = pos_i - q; dw = norm(rel)
                dw < eps(F) && continue
                n_w   = (q - pos_i) / dw   # toward wall
                gap_w = max(dw - r_i, zero(F))
                geo_rep = geo_rep + (params.strength_geo * exp(-gap_w / params.range_geo)) * n_w
            end
        end

        raw   = dir_goal - nbr_reps[i] - geo_rep
        raw_n = norm(raw)
        e_i   = raw_n > eps(F) ? raw / raw_n : dir_goal

        # Forward-corridor gap: O(N²) fallback — asymmetric, can't use pairwise!
        # Acceptable: this is the direction-dependent part; repulsion is the expensive step.
        dir_lat = SVector{2,F}(-e_i[2], e_i[1])
        min_gap = typemax(F)
        for j in 1:N
            j == i && continue
            Dp = all_pos[j] - pos_i; d = norm(Dp)
            d > params.neighbor_radius && continue
            d > eps(F)    || continue
            dot(e_i, Dp) >= zero(F) || continue
            l = F(2) * r_i
            abs(dot(dir_lat, Dp)) <= l || continue
            gap = max(d - l, zero(F))
            min_gap = min(min_gap, gap)
        end
        s_i = min_gap == typemax(F) ? F(Inf) : min_gap
        new_vel[i] = csm_speed(s_i, params.v0, params.T) * e_i
    end

    idx = 0
    for (_, pos_col, vel_col, _, _) in
            Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
        for i in eachindex(pos_col)
            idx += 1; vel_col[i] = Velocity(new_vel[idx])
            pos_col[i] = Position(pos_col[i].p + new_vel[idx] * dt)
        end
    end
end

# ── V3 rotational steering pairwise ──────────────────────────────────────────
function _update_csm_v3_ecs_pairwise!(
    world  :: World,
    search :: CPUNeighborSearch{F},
    walls  :: Vector{NTuple{2, SVector{2,F}}},
    params :: CSMParams{F},
    dt     :: F
) where {F<:AbstractFloat}
    all_pos  = SVector{2,F}[]; all_goal = SVector{2,F}[]; headings = F[]
    try
        for (_, pos_col, _, goal_col, _, state_col) in
                Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
            for i in eachindex(pos_col)
                push!(all_pos, pos_col[i].p); push!(all_goal, goal_col[i].g)
                push!(headings, state_col[i].heading)
            end
        end
    catch e; e isa ArgumentError && return; rethrow(); end
    N = length(all_pos); N == 0 && return
    r_i = params.radius

    build_grid!(search, all_pos, CPU())

    nbr_reps = zeros(SVector{2,F}, N)
    function accum_rep_v3(pair, out)
        (; i, j, d) = pair
        d < F(1e-6) && return out
        n_ij = (all_pos[j] - all_pos[i]) / d
        gap  = max(d - F(2) * r_i, zero(F))
        f    = params.a_neighbor * exp(-gap / params.D_neighbor)
        out[i] = out[i] + f * n_ij
        out[j] = out[j] - f * n_ij
        return out
    end
    fill!(nbr_reps, zero(SVector{2,F})); nbr_reps = CellListMap.pairwise!(accum_rep_v3, search.system)

    new_vel      = Vector{SVector{2,F}}(undef, N)
    new_headings = copy(headings)

    Threads.@threads for i in 1:N
        pos_i    = all_pos[i]
        gd       = all_goal[i] - pos_i; gd_n = norm(gd)
        dir_goal = gd_n > eps(F) ? gd / gd_n : SVector(one(F), zero(F))
        geo_rep  = zero(SVector{2,F})
        if params.strength_geo > zero(F)
            for (p1, p2) in walls
                seg = p2 - p1; l2 = seg[1]^2 + seg[2]^2
                t = l2 < F(1e-10) ? zero(F) :
                    clamp(((pos_i[1]-p1[1])*seg[1]+(pos_i[2]-p1[2])*seg[2])/l2, zero(F), one(F))
                q = p1 + t*seg; rel = pos_i - q; dw = norm(rel)
                dw < eps(F) && continue
                n_w = (q - pos_i)/dw; gap_w = max(dw - r_i, zero(F))
                geo_rep = geo_rep + (params.strength_geo * exp(-gap_w/params.range_geo)) * n_w
            end
        end
        raw = dir_goal - nbr_reps[i] - geo_rep; raw_n = norm(raw)
        e_target = raw_n > eps(F) ? raw / raw_n : dir_goal
        theta_target = atan(e_target[2], e_target[1])
        tau = params.heading_relaxation_tau; Dtheta = theta_target - new_headings[i]
        Dtheta -= F(2pi) * round(Dtheta / F(2pi))
        alpha = min(dt / max(tau, eps(F)), one(F)); theta_new = new_headings[i] + alpha * Dtheta
        new_dir = SVector{2,F}(cos(theta_new), sin(theta_new))
        dir_lat = SVector{2,F}(-new_dir[2], new_dir[1]); min_gap = typemax(F)
        for j in 1:N
            j == i && continue; Dp = all_pos[j] - pos_i; d = norm(Dp)
            d > params.neighbor_radius && continue; d > eps(F) || continue
            dot(new_dir, Dp) >= zero(F) || continue; l = F(2) * r_i
            abs(dot(dir_lat, Dp)) <= l || continue; gap = max(d - l, zero(F))
            min_gap = min(min_gap, gap)
        end
        s_i = min_gap == typemax(F) ? F(Inf) : min_gap
        new_vel[i] = csm_speed(s_i, params.v0, params.T) * new_dir
        new_headings[i] = theta_new
    end

    idx = 0
    for (_, pos_col, vel_col, _, _, state_col) in
            Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
        for i in eachindex(pos_col)
            idx += 1; vel_col[i] = Velocity(new_vel[idx])
            pos_col[i] = Position(pos_col[i].p + new_vel[idx] * dt)
            state_col[i] = AgentCSMState{F}(new_headings[idx])
        end
    end
end

# Sprint 3R: GPU CSM kernel + RadixSpatialHash dispatch
# ════════════════════════════════════════════════════════════════════════════════

"""
    compute_csm_kernel!

GPU kernel for Classic CSM (Sprint 3R). Each thread computes one agent's new
velocity using the sorted spatial hash grid for O(k) neighbor queries.
"""
@kernel function compute_csm_kernel!(
    out_vels, out_headings,
    @Const(sorted_positions), @Const(sorted_goals), @Const(sorted_radii),
    @Const(sorted_headings),
    @Const(sorted_last_positions),
    grid_min, grid_dims, cell_size,
    @Const(cell_starts), @Const(cell_ends), @Const(agent_indices),
    @Const(wall_p1s), @Const(wall_p2s), n_walls,
    a_neighbor, D_neighbor, strength_geo, range_geo,
    v0, T, heading_relaxation_tau, neighbor_radius,
    dt, use_rotational::Bool)

    i = @index(Global, Linear)
    @inbounds begin
        original_i = agent_indices[i]
        pos_i = sorted_positions[i]; r_i = sorted_radii[i]
        goal_i = sorted_goals[i]; gd = goal_i - pos_i; gd_n = sqrt(gd[1]^2 + gd[2]^2)
        F_type = typeof(r_i)
        dir_goal = gd_n > F_type(1e-6) ? gd/gd_n : typeof(gd)(one(F_type), zero(F_type))

        # Cell index for this agent (using last-build positions for stable cell lookup)
        lp = sorted_last_positions[i]
        ci_x = clamp(floor(Int32, (lp[1]-grid_min[1])/cell_size), Int32(0), grid_dims[1]-Int32(1))
        ci_y = clamp(floor(Int32, (lp[2]-grid_min[2])/cell_size), Int32(0), grid_dims[2]-Int32(1))

        # O(k) isotropic repulsion via 3×3 cell neighborhood
        # Morton (Z-order) cell lookup matches build_csr_kernel!/position_to_hash.
        # cs==0 sentinel: build_grid! initialises cell_starts with fill!(…,0);
        # unoccupied cells are never written → cs==0 means "empty, skip".
        nbr_rep = zero(typeof(pos_i))
        for di in Int32(-1):Int32(1)
            ni_x = ci_x + di
            (ni_x < Int32(0) || ni_x >= grid_dims[1]) && continue
            for dj in Int32(-1):Int32(1)
                ni_y = ci_y + dj
                (ni_y < Int32(0) || ni_y >= grid_dims[2]) && continue
                cell_idx = Int(morton_spread_bits(UInt32(ni_x)) |
                               (morton_spread_bits(UInt32(ni_y)) << UInt32(1))) + Int32(1)
                cs = cell_starts[cell_idx]; ce = cell_ends[cell_idx]
                cs == 0 && continue   # empty cell — sentinel 0 from build_grid! fill!
                for k in cs:ce
                    k == i && continue
                    r_ij = sorted_positions[k] - pos_i
                    d = sqrt(r_ij[1]^2 + r_ij[2]^2)
                    d > neighbor_radius && continue; d > F_type(1e-6) || continue
                    n_ij = r_ij / d; gap = max(d - r_i - sorted_radii[k], zero(F_type))
                    nbr_rep = nbr_rep + (a_neighbor * exp(-gap/D_neighbor)) * n_ij
                end
            end
        end

        # Wall geometry
        geo_rep = zero(typeof(pos_i))
        if strength_geo > zero(F_type)
            @inbounds for w in 1:n_walls
                p1=wall_p1s[w]; p2=wall_p2s[w]; seg=p2-p1; l2=seg[1]^2+seg[2]^2
                tt = l2<F_type(1e-10) ? zero(F_type) :
                    clamp(((pos_i[1]-p1[1])*seg[1]+(pos_i[2]-p1[2])*seg[2])/l2, zero(F_type), one(F_type))
                q=p1+tt*seg; rel=pos_i-q; dw=sqrt(rel[1]^2+rel[2]^2)
                dw<F_type(1e-6) && continue
                n_w=(q-pos_i)/dw; gap_w=max(dw-r_i, zero(F_type))
                geo_rep=geo_rep+(strength_geo*exp(-gap_w/range_geo))*n_w
            end
        end

        raw=dir_goal-nbr_rep-geo_rep; raw_n=sqrt(raw[1]^2+raw[2]^2)
        e_target = raw_n > F_type(1e-6) ? raw/raw_n : dir_goal

        local e_i; local theta_new::F_type
        if use_rotational
            theta_target=atan(e_target[2],e_target[1]); tau=heading_relaxation_tau
            Dtheta=theta_target-sorted_headings[i]
            Dtheta-=F_type(2*pi)*round(Dtheta/F_type(2*pi))
            alpha=min(dt/max(tau,F_type(1e-10)), one(F_type))
            theta_new=sorted_headings[i]+alpha*Dtheta
            e_i=typeof(e_target)(cos(theta_new), sin(theta_new))
        else
            e_i=e_target; theta_new=zero(F_type)
        end

        # Forward-corridor gap (Morton cell lookup + empty-cell guard, matching repulsion loop above)
        dir_lat=typeof(e_i)(-e_i[2],e_i[1]); min_gap=F_type(Inf)
        @inbounds for di in Int32(-1):Int32(1)
            ni_x=ci_x+di
            (ni_x<Int32(0)||ni_x>=grid_dims[1]) && continue
            for dj in Int32(-1):Int32(1)
                ni_y=ci_y+dj
                (ni_y<Int32(0)||ni_y>=grid_dims[2]) && continue
                cell_idx=Int(morton_spread_bits(UInt32(ni_x))|
                             (morton_spread_bits(UInt32(ni_y))<<UInt32(1)))+Int32(1)
                cs2=cell_starts[cell_idx]; ce2=cell_ends[cell_idx]
                cs2 == 0 && continue   # empty cell
                for k in cs2:ce2
                    k==i && continue; Dp=sorted_positions[k]-pos_i
                    d=sqrt(Dp[1]^2+Dp[2]^2)
                    d>neighbor_radius && continue; d>F_type(1e-6) || continue
                    (e_i[1]*Dp[1]+e_i[2]*Dp[2])>=zero(F_type) || continue
                    l=r_i+sorted_radii[k]
                    abs(dir_lat[1]*Dp[1]+dir_lat[2]*Dp[2])<=l || continue
                    gap=max(d-l,zero(F_type)); min_gap=min(min_gap,gap)
                end
            end
        end
        s_i=isinf(min_gap) ? F_type(Inf) : min_gap
        v_i=v0*clamp(s_i/(T*v0), zero(F_type), one(F_type))
        out_vels[original_i]=v_i*e_i
        out_headings[original_i]=use_rotational ? theta_new : sorted_headings[i]
    end
end

"""
    update_csm_system!(world, search::RadixSpatialHash, backend, dt)

GPU CSM dispatch. Builds the sorted spatial hash, then launches `compute_csm_kernel!`.
"""
function update_csm_system!(world::World, search::RadixSpatialHash{AT,F},
                             backend::Backend, dt::F;
                             n_iters_corr::Int = 8,
                             alg::AbstractCorrectionAlgorithm = JacobiCorrection()) where {AT,F}
    n_csm = 0
    try
        n_csm = count_entities(Query(world, (CSMParams{F},)))
    catch e; e isa ArgumentError && return; rethrow(); end
    n_csm == 0 && return

    local params::CSMParams{F}
    for (_, params_col) in Query(world, (CSMParams{F},))
        params = params_col[1]; break
    end

    N = n_csm; n_walls = 0
    ctx = get_csm_gpu_context(world, backend, F, N, 64)

    idx = 1
    for (_, pos_col, vel_col, goal_col, params_col) in
            Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
        for i in eachindex(pos_col)
            ctx.base.cpu_positions[idx]  = pos_col[i].p
            ctx.base.cpu_velocities[idx] = vel_col[i].v
            ctx.base.cpu_radii[idx]      = params_col[i].radius
            ctx.cpu_goals[idx]           = goal_col[i].g
            ctx.cpu_headings[idx]        = zero(F)
            idx += 1
        end
    end
    if params.use_rotational_steering
        idx = 1
        for (_, _, _, _, _, state_col) in
                Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
            for i in eachindex(state_col)
                ctx.cpu_headings[idx] = state_col[i].heading; idx += 1
            end
        end
    end

    try
        for (_, wall_col) in Query(world, (WallSegment{F},))
            for i in eachindex(wall_col)
                n_walls += 1
                ctx.base.cpu_wall_p1s[n_walls] = wall_col[i].p1
                ctx.base.cpu_wall_p2s[n_walls] = wall_col[i].p2
            end
        end
    catch e; e isa ArgumentError || rethrow(); end

    stage_and_sort_base!(ctx.base, ctx.base.cpu_positions, ctx.base.cpu_velocities,
                         ctx.base.cpu_radii, ctx.base.cpu_wall_p1s, ctx.base.cpu_wall_p2s,
                         n_walls, search, backend, ctx.sorted_last_positions)

    copyto!(ctx.dev_goals,    ctx.cpu_goals)
    copyto!(ctx.dev_headings, ctx.cpu_headings)

    kernel_reorder! = reorder_array_kernel!(backend)
    kernel_reorder!(ctx.sorted_dev_goals,    ctx.dev_goals,    search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_headings, ctx.dev_headings, search.agent_indices, ndrange=N)

    kernel! = compute_csm_kernel!(backend)
    kernel!(ctx.dev_new_vels, ctx.dev_new_headings,
            ctx.base.sorted_dev_positions, ctx.sorted_dev_goals, ctx.base.sorted_dev_radii,
            ctx.sorted_dev_headings, ctx.sorted_last_positions,
            search.grid_min, search.grid_dims, search.cell_size,
            search.cell_starts, search.cell_ends, search.agent_indices,
            ctx.base.dev_wall_p1s, ctx.base.dev_wall_p2s, n_walls,
            params.a_neighbor, params.D_neighbor, params.strength_geo, params.range_geo,
            params.v0, params.T, params.heading_relaxation_tau, params.neighbor_radius,
            dt, params.use_rotational_steering,
            ndrange=N)
    KernelAbstractions.synchronize(backend)

    # ── Sprint 3T-GPU-fix: GPU position integration + Jacobi correction ───────
    # 1. Reorder dev_new_vels (ECS order) → sorted_dev_new_vels (Morton order)
    kernel_reorder!(ctx.sorted_dev_new_vels, ctx.dev_new_vels, search.agent_indices, ndrange=N)
    KernelAbstractions.synchronize(backend)

    # 2. Integrate positions on device: sorted_pos[i] += sorted_new_vel[i] * dt
    #    Now sorted_dev_positions holds POST-STEP positions.
    kern_integrate = integrate_positions_kernel!(backend)
    kern_integrate(ctx.base.sorted_dev_positions, ctx.sorted_dev_new_vels,
                   dt, Int32(N); ndrange=N)
    KernelAbstractions.synchronize(backend)

    # 3. Jacobi/XPBD agent non-penetration correction on post-step positions
    apply_agent_correction_gpu!(ctx.base, search, backend;
                                n_iters = n_iters_corr,
                                alg     = alg)

    # ── Scatter-back: corrected positions from device, new vels from kernel ───
    # sorted_dev_positions now holds post-step, Jacobi-corrected positions.
    # dev_new_vels holds new velocities in ECS (unsorted) order.
    cpu_new_pos      = Vector{SVector{2,F}}(undef, N)
    cpu_new_vels     = Vector{SVector{2,F}}(undef, N)
    cpu_new_headings = Vector{F}(undef, N)
    # Scatter sorted corrected positions back to ECS order via agent_indices
    cpu_sorted_pos = Vector{SVector{2,F}}(undef, N)
    copyto!(cpu_sorted_pos,   ctx.base.sorted_dev_positions)
    copyto!(cpu_new_vels,     ctx.dev_new_vels)
    copyto!(cpu_new_headings, ctx.dev_new_headings)

    # Invert Morton permutation: cpu_new_pos[original_i] = cpu_sorted_pos[sorted_i]
    cpu_agent_indices = Vector{Int32}(undef, N)
    copyto!(cpu_agent_indices, search.agent_indices)
    for sorted_i in 1:N
        original_i = Int(cpu_agent_indices[sorted_i])
        cpu_new_pos[original_i] = cpu_sorted_pos[sorted_i]
    end

    idx = 1
    for (_, pos_col, vel_col, _, _) in Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
        for i in eachindex(pos_col)
            vel_col[i] = Velocity(cpu_new_vels[idx])
            pos_col[i] = Position(cpu_new_pos[idx])   # corrected post-step position
            idx += 1
        end
    end
    if params.use_rotational_steering
        idx = 1
        for (_, _, _, _, _, state_col) in
                Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
            for i in eachindex(state_col)
                state_col[i] = AgentCSMState{F}(cpu_new_headings[idx]); idx += 1
            end
        end
    end
end

# ── Navigation-aware O(N×k) CPU dispatcher ─────────────────────────────────────

"""
    update_csm_system!(world, search::CPUNeighborSearch, dt, nav)

O(N×k) CSM with FMM navigation field for global routing.
"""
function update_csm_system!(world::World, search::CPUNeighborSearch{F}, dt::F,
                             nav::AbstractNavigationField{F}) where {F<:AbstractFloat}
    n_csm = 0
    try
        n_csm = count_entities(Query(world, (CSMParams{F},)))
    catch e
        e isa ArgumentError && return; rethrow()
    end
    n_csm == 0 && return

    local params::CSMParams{F}
    for (_, params_col) in Query(world, (CSMParams{F},))
        params = params_col[1]; break
    end

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
        _update_csm_v3_pairwise_nav!(world, search, walls, params, dt, nav)
    else
        _update_csm_classic_pairwise_nav!(world, search, walls, params, dt, nav)
    end
end

function _update_csm_classic_pairwise_nav!(
    world  :: World,
    search :: CPUNeighborSearch{F},
    walls  :: Vector{NTuple{2, SVector{2,F}}},
    params :: CSMParams{F},
    dt     :: F,
    nav    :: AbstractNavigationField{F}
) where {F<:AbstractFloat}
    all_pos = SVector{2,F}[]
    try
        for (_, pos_col, _, _, _) in Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
            for i in eachindex(pos_col)
                push!(all_pos, pos_col[i].p)
            end
        end
    catch e
        e isa ArgumentError && return; rethrow()
    end
    N = length(all_pos); N == 0 && return
    r_i = params.radius

    build_grid!(search, all_pos, CPU())

    function accum_rep_nav(pair, out)
        (; i, j, d) = pair
        d < F(1e-6) && return out
        n_ij = (all_pos[j] - all_pos[i]) / d
        gap  = max(d - F(2) * r_i, zero(F))
        f    = params.a_neighbor * exp(-gap / params.D_neighbor)
        out[i] = out[i] + f * n_ij
        out[j] = out[j] - f * n_ij
        return out
    end
    nbr_reps = CellListMap.pairwise!(accum_rep_nav, search.system)

    new_vel = Vector{SVector{2,F}}(undef, N)
    Threads.@threads for i in 1:N
        pos_i    = all_pos[i]
        dir_goal = get_nav_direction(nav, pos_i)
        geo_rep  = zero(SVector{2,F})
        if params.strength_geo > zero(F)
            for (p1, p2) in walls
                seg = p2 - p1
                l2  = seg[1]^2 + seg[2]^2
                t   = if l2 < F(1e-10)
                    zero(F)
                else
                    clamp(((pos_i[1]-p1[1])*seg[1] + (pos_i[2]-p1[2])*seg[2]) / l2,
                          zero(F), one(F))
                end
                q   = p1 + t * seg
                rel = pos_i - q
                dw  = norm(rel)
                dw < eps(F) && continue
                n_w   = (q - pos_i) / dw
                gap_w = max(dw - r_i, zero(F))
                geo_rep = geo_rep + (params.strength_geo * exp(-gap_w / params.range_geo)) * n_w
            end
        end
        raw   = dir_goal - nbr_reps[i] - geo_rep
        raw_n = norm(raw)
        e_i   = raw_n > eps(F) ? raw / raw_n : dir_goal
        dir_lat = SVector{2,F}(-e_i[2], e_i[1])
        min_gap = typemax(F)
        for j in 1:N
            j == i && continue
            Dp = all_pos[j] - pos_i
            d  = norm(Dp)
            d > params.neighbor_radius && continue
            d > eps(F) || continue
            dot(e_i, Dp) >= zero(F) || continue
            l = F(2) * r_i
            abs(dot(dir_lat, Dp)) <= l || continue
            gap = max(d - l, zero(F))
            min_gap = min(min_gap, gap)
        end
        s_i = min_gap == typemax(F) ? F(Inf) : min_gap
        new_vel[i] = csm_speed(s_i, params.v0, params.T) * e_i
    end
    idx = 0
    for (_, pos_col, vel_col, _, _) in Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
        for i in eachindex(pos_col)
            idx += 1
            vel_col[i] = Velocity(new_vel[idx])
            pos_col[i] = Position(pos_col[i].p + new_vel[idx] * dt)
        end
    end
end

function _update_csm_v3_pairwise_nav!(
    world  :: World,
    search :: CPUNeighborSearch{F},
    walls  :: Vector{NTuple{2, SVector{2,F}}},
    params :: CSMParams{F},
    dt     :: F,
    nav    :: AbstractNavigationField{F}
) where {F<:AbstractFloat}
    all_pos  = SVector{2,F}[]
    headings = F[]
    try
        for (_, pos_col, _, _, _, state_col) in
                Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
            for i in eachindex(pos_col)
                push!(all_pos,  pos_col[i].p)
                push!(headings, state_col[i].heading)
            end
        end
    catch e
        e isa ArgumentError && return; rethrow()
    end
    N = length(all_pos); N == 0 && return
    r_i = params.radius

    build_grid!(search, all_pos, CPU())

    function accum_v3nav(pair, out)
        (; i, j, d) = pair
        d < F(1e-6) && return out
        n_ij = (all_pos[j] - all_pos[i]) / d
        gap  = max(d - F(2) * r_i, zero(F))
        f    = params.a_neighbor * exp(-gap / params.D_neighbor)
        out[i] = out[i] + f * n_ij
        out[j] = out[j] - f * n_ij
        return out
    end
    nbr_reps = CellListMap.pairwise!(accum_v3nav, search.system)

    new_vel      = Vector{SVector{2,F}}(undef, N)
    new_headings = copy(headings)

    Threads.@threads for i in 1:N
        pos_i    = all_pos[i]
        dir_goal = get_nav_direction(nav, pos_i)
        geo_rep  = zero(SVector{2,F})
        if params.strength_geo > zero(F)
            for (p1, p2) in walls
                seg = p2 - p1
                l2  = seg[1]^2 + seg[2]^2
                t   = if l2 < F(1e-10)
                    zero(F)
                else
                    clamp(((pos_i[1]-p1[1])*seg[1] + (pos_i[2]-p1[2])*seg[2]) / l2,
                          zero(F), one(F))
                end
                q   = p1 + t * seg
                rel = pos_i - q
                dw  = norm(rel)
                dw < eps(F) && continue
                n_w   = (q - pos_i) / dw
                gap_w = max(dw - r_i, zero(F))
                geo_rep = geo_rep + (params.strength_geo * exp(-gap_w / params.range_geo)) * n_w
            end
        end
        raw      = dir_goal - nbr_reps[i] - geo_rep
        raw_n    = norm(raw)
        e_target = raw_n > eps(F) ? raw / raw_n : dir_goal

        theta_target = atan(e_target[2], e_target[1])
        tau          = params.heading_relaxation_tau
        Dtheta       = theta_target - new_headings[i]
        Dtheta       -= F(2pi) * round(Dtheta / F(2pi))
        alpha        = min(dt / max(tau, eps(F)), one(F))
        theta_new    = new_headings[i] + alpha * Dtheta
        new_dir      = SVector{2,F}(cos(theta_new), sin(theta_new))

        dir_lat = SVector{2,F}(-new_dir[2], new_dir[1])
        min_gap = typemax(F)
        for j in 1:N
            j == i && continue
            Dp = all_pos[j] - pos_i
            d  = norm(Dp)
            d > params.neighbor_radius && continue
            d > eps(F) || continue
            dot(new_dir, Dp) >= zero(F) || continue
            l = F(2) * r_i
            abs(dot(dir_lat, Dp)) <= l || continue
            gap = max(d - l, zero(F))
            min_gap = min(min_gap, gap)
        end
        s_i = min_gap == typemax(F) ? F(Inf) : min_gap
        new_vel[i]      = csm_speed(s_i, params.v0, params.T) * new_dir
        new_headings[i] = theta_new
    end

    idx = 0
    for (_, pos_col, vel_col, _, _, state_col) in
            Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
        for i in eachindex(pos_col)
            idx += 1
            vel_col[i]   = Velocity(new_vel[idx])
            pos_col[i]   = Position(pos_col[i].p + new_vel[idx] * dt)
            state_col[i] = AgentCSMState{F}(new_headings[idx])
        end
    end
end
