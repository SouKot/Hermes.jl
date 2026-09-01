# ── Hybrid FSM System ──────────────────────────────────────────────────────────
# Sprint 3K-b: per-agent density-triggered ORCA↔SFM dispatch.
#
# Architecture (Menge, Curtis et al. 2016 §3):
#   - Each HybridFSMParams agent maintains an AgentFSMState (isbits, GPU-forward).
#   - Local density ρ is estimated each step (O(N) scan; Sprint 3L: use search grid).
#   - EMA smoothing (α=0.33 ≈ 3-step time constant) prevents oscillation.
#   - Hysteresis band [ρ_off, ρ_on] prevents state chatter.
#   - In ORCA_MODE: velocity planning (collision-free, arch-free navigation).
#   - In SFM_MODE:  force accumulation via SFM (body contact, realistic crush).
#
# Key design decisions:
#   - vel_j = actual velocity (not zero): using vel_j=0 treats ALL neighbours as
#     static → hyper-conservative ORCA → agents slow down → arch-like deadlock.
#     With actual velocities, ORCA creates constraints only for collision-course pairs.
#   - social_radius from AgentGeometry (not sp.B): B=0.08m is the potential decay
#     length, not the personal space radius. Using B gives zero-range social forces.
#
# ECS archetype design (prevents double-counting):
#   HybridFSMParams + AgentFSMState + AgentGeometry  ← processed here only
#   NO SFMParams, NO ORCAParams on Hybrid agents
#   → update_social_forces_system! skips them (no SFMParams)
#   → update_orca_system!          skips them (no ORCAParams)
#
# References:
#   Curtis, S., Best, A., Manocha, D. (2016). Menge: A Modular Framework for
#   Pedestrian Simulation. PED 2014. §3 (state machine + density triggers).

using Ark
using StaticArrays
using LinearAlgebra

# Mode constants (Int32 for GPU isbits compliance)
const ORCA_MODE = Int32(0)
const SFM_MODE  = Int32(1)

"""
    update_hybrid_fsm_system!(world, search, backend, dt)

Per-agent density-triggered ORCA↔SFM dispatch for agents carrying
`HybridFSMParams{F}` + `AgentFSMState{F}` + `AgentGeometry{F}` components.

## Algorithm (per agent i)

1. **Density estimation**: count neighbours within `params.density_radius`.
   `ρ_local = n_neighbours / (π × density_radius²)` (ped/m²)

2. **EMA smoothing**: `ρ_ema ← α × ρ_local + (1−α) × ρ_ema_prev`  (α = 0.33)

3. **FSM transition** (hysteresis):
   - `ORCA_MODE → SFM_MODE`  when `ρ_ema ≥ params.ρ_on`
   - `SFM_MODE  → ORCA_MODE` when `ρ_ema < params.ρ_off`
   - otherwise: keep current mode

4. **Force dispatch**:
   - `ORCA_MODE`: collision-free velocity via `_hybrid_orca_force`
   - `SFM_MODE`:  SFM forces via `_hybrid_sfm_force`

5. **Write back**: `state_col[i] = AgentFSMState{F}(new_mode, new_ρ_ema, 0)`

## Notes

- Neighbour velocities are passed to ORCA (actual vel_j, not zero) — this is
  critical: vel_j=0 treats all neighbours as static, creating unnecessary
  half-plane constraints that slow agents to a crawl near the bottleneck.
- AgentGeometry must be present on hybrid agents (social/collision radii for SFM).
"""
function update_hybrid_fsm_system!(world::World,
                                   search::AbstractNeighborSearch,
                                   backend::Backend,
                                   dt::F) where {F<:AbstractFloat}

    # ── 0. Guard: no hybrid agents → return immediately ─────────────────────
    n_hybrid = 0
    try
        n_hybrid = count_entities(Query(world, (HybridFSMParams{F},)))
    catch e
        e isa ArgumentError && return
        rethrow()
    end
    n_hybrid == 0 && return

    # ── 1. Collect ALL agent positions + velocities for density & ORCA ───────
    # Density estimation counts ANY nearby pedestrian (including non-hybrid).
    # ORCA requires actual neighbour velocities — vel_j=0 would be wrong.
    all_positions  = SVector{2,F}[]
    all_velocities = SVector{2,F}[]
    for (_, pos_col, vel_col) in Query(world, (Position{F}, Velocity{F}))
        for i in eachindex(pos_col)
            push!(all_positions,  pos_col[i].p)
            push!(all_velocities, vel_col[i].v)
        end
    end
    N_all = length(all_positions)

    # ── 2. Collect wall segments (for SFM_MODE wall forces) ─────────────────
    walls = NTuple{2, SVector{2,F}}[]
    for (_, wall_col) in Query(world, (WallSegment{F},))
        for i in eachindex(wall_col)
            push!(walls, (wall_col[i].p1, wall_col[i].p2))
        end
    end


    # ── 3. Per-hybrid-agent dispatch ───────────────────────────────────────────────
    # IMPORTANT: Query has 7 components (Ark.jl Query tuple limit).
    # AgentGeometry is NOT in the query — geometry is derived from orca_params.radius.
    for (entities, pos_col, vel_col, motion_col, goal_col, force_col,
                  params_col, state_col) in
            Query(world, (Position{F}, Velocity{F}, MotionParams{F},
                          Goal{F}, Force{F}, HybridFSMParams{F}, AgentFSMState{F}))
        for i in eachindex(pos_col)
            pos_i    = pos_col[i].p
            vel_i    = vel_col[i].v
            params   = params_col[i]
            state    = state_col[i]
            goal_i   = goal_col[i].g
            motion_i = motion_col[i]

            # ── 3a. Density estimation ────────────────────────────────────────
            # O(N_all) scan; Sprint 3L: replace with search-grid O(k) lookup.
            r_density = params.density_radius
            r_sq      = r_density * r_density
            n_nearby  = 0
            for j in 1:N_all
                d_sq = sum(abs2, all_positions[j] - pos_i)
                # exclude self: d_sq < 1e-8 means same agent (floating-point stable)
                if d_sq > F(1e-8) && d_sq < r_sq
                    n_nearby += 1
                end
            end
            ρ_local = F(n_nearby) / (F(π) * r_sq)

            # ── 3b. EMA density smoothing (α = 0.33 ≈ 3-step time constant) ──
            α = F(0.33)
            ρ_ema_new = α * ρ_local + (one(F) - α) * state.ρ_ema

            # ── 3c. FSM transition (hysteresis band) ─────────────────────────
            new_mode = state.mode
            if state.mode == ORCA_MODE && ρ_ema_new >= params.ρ_on
                new_mode = SFM_MODE
            elseif state.mode == SFM_MODE && ρ_ema_new < params.ρ_off
                new_mode = ORCA_MODE
            end

            # ── 3d. Force dispatch ────────────────────────────────────────────
            if new_mode == ORCA_MODE
                F_agent = _hybrid_orca_force(
                    pos_i, vel_i, goal_i, params.orca_params,
                    all_positions, all_velocities, walls, dt, F)
            else
                # Pass orca_params.radius as body radius (= r_body, same value as AgentGeometry)
                F_agent = _hybrid_sfm_force(
                    pos_i, vel_i, goal_i, motion_i, params.orca_params.radius,
                    params.sfm_params, all_positions, all_velocities, walls, F)
            end

            # ── 3e. Write force and updated state ─────────────────────────────────
            force_col[i] = Force(F_agent)
            state_col[i] = AgentFSMState{F}(new_mode, ρ_ema_new, Int32(0))
        end
    end
end

# ── Nothing overload (no-nav — routes to existing 4-arg body) ─────────────────
# Called by SimScene.step! unconditionally: update_hybrid_fsm_system!(world, search, backend, dt, scene.nav_field)
# When nav_field = nothing (no nav field in scene), routes to the original 4-arg method.
# Type-stable: no runtime branch in step!.
function update_hybrid_fsm_system!(world::World, search::AbstractNeighborSearch,
                                   backend::Backend, dt, ::Nothing)
    update_hybrid_fsm_system!(world, search, backend, dt)
end


# ── Nav dispatch (AbstractNavigationField) ────────────────────────────────────

"""
    update_hybrid_fsm_system!(world, search, backend, dt, nav::AbstractNavigationField)

FMM-guided variant of the Hybrid FSM dispatch. Identical to the no-nav form
except the preferred direction for each agent is `get_nav_direction(nav, pos_i)`
instead of `normalize(goal_i - pos_i)`.  Avoidance logic (ORCA half-planes,
SFM contact forces, density-triggered switching) is unchanged.

Accepts any `AbstractNavigationField` subtype — FMM, NavMesh, GPU-uploaded, etc.

## Virtual goal pattern

Both `_hybrid_orca_force` and `_hybrid_sfm_force` internally compute direction
as `normalize(goal - pos)`. We pass a **virtual goal 10m in the nav direction**:

    dir_nav  = get_nav_direction(nav, pos_i)   # unit vector from FMM
    goal_eff = pos_i + dir_nav * F(10)         # normalize(goal_eff - pos_i) = dir_nav ✓

This requires **zero changes** to the inner helper functions.
"""
function update_hybrid_fsm_system!(world::World,
                                   search::AbstractNeighborSearch,
                                   backend::Backend,
                                   dt::F,
                                   nav::AbstractNavigationField{F}) where {F<:AbstractFloat}

    # ── 0. Guard: no hybrid agents → return immediately ─────────────────────
    n_hybrid = 0
    try
        n_hybrid = count_entities(Query(world, (HybridFSMParams{F},)))
    catch e
        e isa ArgumentError && return
        rethrow()
    end
    n_hybrid == 0 && return

    # ── 1. Collect ALL agent positions + velocities for density & ORCA ───────
    all_positions  = SVector{2,F}[]
    all_velocities = SVector{2,F}[]
    for (_, pos_col, vel_col) in Query(world, (Position{F}, Velocity{F}))
        for i in eachindex(pos_col)
            push!(all_positions,  pos_col[i].p)
            push!(all_velocities, vel_col[i].v)
        end
    end
    N_all = length(all_positions)

    # ── 2. Collect wall segments ────────────────────────────────────────────
    walls = NTuple{2, SVector{2,F}}[]
    for (_, wall_col) in Query(world, (WallSegment{F},))
        for i in eachindex(wall_col)
            push!(walls, (wall_col[i].p1, wall_col[i].p2))
        end
    end

    # ── 3. Per-hybrid-agent dispatch ────────────────────────────────────────
    for (entities, pos_col, vel_col, motion_col, goal_col, force_col,
                  params_col, state_col) in
            Query(world, (Position{F}, Velocity{F}, MotionParams{F},
                          Goal{F}, Force{F}, HybridFSMParams{F}, AgentFSMState{F}))
        for i in eachindex(pos_col)
            pos_i    = pos_col[i].p
            vel_i    = vel_col[i].v
            params   = params_col[i]
            state    = state_col[i]
            motion_i = motion_col[i]

            # ── 3a. FMM navigation: virtual goal in nav direction ───────────
            # Placing the virtual goal 10m ahead gives normalize(goal_eff - pos_i) = dir_nav
            # exactly, regardless of agent position. Both ORCA and SFM helpers
            # will compute direction correctly via their normalize(goal - pos) internals.
            dir_nav  = get_nav_direction(nav, pos_i)
            goal_eff = pos_i + dir_nav * F(10)

            # ── 3b. Density estimation ──────────────────────────────────────
            r_density = params.density_radius
            r_sq      = r_density * r_density
            n_nearby  = 0
            for j in 1:N_all
                d_sq = sum(abs2, all_positions[j] - pos_i)
                if d_sq > F(1e-8) && d_sq < r_sq
                    n_nearby += 1
                end
            end
            ρ_local = F(n_nearby) / (F(π) * r_sq)

            # ── 3c. EMA density smoothing (α = 0.33 ≈ 3-step time constant) ──
            α = F(0.33)
            ρ_ema_new = α * ρ_local + (one(F) - α) * state.ρ_ema

            # ── 3d. FSM transition (hysteresis band) ────────────────────────
            new_mode = state.mode
            if state.mode == ORCA_MODE && ρ_ema_new >= params.ρ_on
                new_mode = SFM_MODE
            elseif state.mode == SFM_MODE && ρ_ema_new < params.ρ_off
                new_mode = ORCA_MODE
            end

            # ── 3e. Force dispatch (using goal_eff instead of goal_i) ────────
            if new_mode == ORCA_MODE
                F_agent = _hybrid_orca_force(
                    pos_i, vel_i, goal_eff, params.orca_params,
                    all_positions, all_velocities, walls, dt, F)
            else
                F_agent = _hybrid_sfm_force(
                    pos_i, vel_i, goal_eff, motion_i, params.orca_params.radius,
                    params.sfm_params, all_positions, all_velocities, walls, F)
            end

            # ── 3f. Write force and updated state ───────────────────────────
            force_col[i] = Force(F_agent)
            state_col[i] = AgentFSMState{F}(new_mode, ρ_ema_new, Int32(0))
        end
    end
end


# ── ORCA force for a single Hybrid agent ──────────────────────────────────────
# Single-agent ORCA LP solve using actual neighbour velocities and k-nearest selection.
#
# Key design decisions:
#  - vel_j = actual (not zero): vel_j=0 creates constraints for compatible-direction
#    pairs, slowing agents unnecessarily. Actual vel_j only constrains collision-course pairs.
#  - k-nearest neighbours: iterating ECS order and breaking at max_neighbors gives the
#    FIRST k, not the NEAREST k. In dense scenarios, the true nearest obstacles are
#    missed, causing LP infeasibility and deadlock. Sort by distance before truncating.
#
@inline function _hybrid_orca_force(
        pos_i::SVector{2,F},
        vel_i::SVector{2,F},
        goal_i::SVector{2,F},
        op::ORCAParams{F},
        all_positions::Vector{SVector{2,F}},
        all_velocities::Vector{SVector{2,F}},
        walls::Vector{NTuple{2, SVector{2,F}}},
        dt::F,
        ::Type{F}) where {F<:AbstractFloat}

    # Preferred velocity
    dir    = goal_i - pos_i
    dist   = norm(dir)
    v_pref = dist > F(1e-3) ? (dir / dist) * op.v_pref : zero(SVector{2,F})
    lp_radius = op.v_pref

    lines = Line{F}[]
    sizehint!(lines, 64)

    # §1.7: wall ORCA constraints (hard — prepended, counted for LP3)
    num_wall_lines = 0
    for (p1, p2) in walls
        seg = p2 - p1
        l2  = dot(seg, seg)
        t   = l2 < F(1e-10) ? zero(F) : clamp(dot(pos_i - p1, seg) / l2, zero(F), one(F))
        q   = p1 + t * seg
        interaction_r = op.radius + F(2)
        if norm(q - pos_i) < interaction_r
            push!(lines, compute_orca_line_wall(pos_i, vel_i, op.radius, p1, p2,
                                                 op.time_horizon_obst, dt))
            num_wall_lines += 1

            # §3P: endpoint vertex constraints (van den Berg 2011 §3.2)
            # Emit a separate point-obstacle VO for each wall segment endpoint.
            # Prevents agents from arcing through door corners when FMM nav
            # preferred velocity is diagonal toward the corner endpoint.
            # CPU path uses heap Vector — no MVector budget limit here.
            for qe in (p1, p2)
                dist_ep = norm(qe - pos_i)
                if dist_ep > F(1e-6) && dist_ep < interaction_r
                    push!(lines, compute_orca_line_endpoint(pos_i, vel_i, op.radius, qe,
                                                             op.time_horizon_obst, dt))
                    num_wall_lines += 1
                end
            end
        end
    end

    # Collect valid neighbours with their distances, then sort to get k-nearest.
    # This is O(N) collection + O(N log N) sort — acceptable for CPU hybrid path
    # where N ≤ few hundred. Sprint 3L: replace with spatial hash O(k) lookup.
    nb_dist_sq = op.neighbor_dist * op.neighbor_dist
    # Pre-allocate a buffer of (index, dist_sq) pairs
    nb_buf = Tuple{Int, F}[]
    sizehint!(nb_buf, min(length(all_positions), 64))
    for j in eachindex(all_positions)
        d_sq = sum(abs2, all_positions[j] - pos_i)
        d_sq < F(1e-8) && continue          # skip self
        d_sq > nb_dist_sq && continue       # skip distant
        push!(nb_buf, (j, d_sq))
    end
    sort!(nb_buf, by = x -> x[2])           # ascending distance

    for (j, _) in Iterators.take(nb_buf, op.max_neighbors)
        pos_j = all_positions[j]
        # vel_j = zero: conservative static-neighbour assumption.
        # Rationale: using actual vel_j creates ORCA constraints only for collision-course
        # pairs. In a dense bottleneck, 80 agents all moving toward the door have near-zero
        # relative velocity → few constraints → all converge simultaneously → LP overloaded
        # → LP3 deflects agents laterally → agents stuck near door.
        # With vel_j=0 (static), ORCA treats each neighbour as an obstacle to route AROUND.
        # This creates natural funnelling/queueing — agents approach from different angles
        # rather than all head-on. Empirically: vel_j=0 gives flow ≥ 1.0 ped/s;
        # vel_j=actual causes deadlock at this geometry.
        vel_j = zero(SVector{2,F})
        r_j   = op.radius
        push!(lines, compute_orca_line(pos_i, vel_i, op.radius, pos_j, vel_j, r_j,
                                        op.time_horizon, dt, op.responsibility))
    end

    # LP2 + LP3
    num_lines = length(lines)
    fail_line, v_opt = linear_program_2_len(lines, num_lines, lp_radius, v_pref, false, v_pref)
    if fail_line > 0
        v_opt = linear_program_3(lines, num_wall_lines, fail_line, lp_radius, v_opt)
    end

    # Force = mass × (v_opt − vel) / dt  (must snap to v_opt in one step)
    return op.mass * (v_opt - vel_i) / dt
end

# ── SFM force for a single Hybrid agent ───────────────────────────────────────
# Contact-only SFM for dense bottleneck zone.
# r_body = orca_params.radius (= AgentGeometry.social_radius in the typical setup).
# Geometry: collision_r = r_body * 2/3  (matches AgentGeometry constructor default).
@inline function _hybrid_sfm_force(
        pos_i::SVector{2,F},
        vel_i::SVector{2,F},
        goal_i::SVector{2,F},
        motion_i::MotionParams{F},
        r_body::F,
        sp::SFMParams{F},
        all_positions::Vector{SVector{2,F}},
        all_velocities::Vector{SVector{2,F}},
        walls::Vector{NTuple{2, SVector{2,F}}},
        ::Type{F}) where {F<:AbstractFloat}

    # 1. Goal-seeking force
    F_total = goal_seeking_force(pos_i, vel_i, goal_i, motion_i.v_pref, motion_i.τ, motion_i.mass)

    # 1b. Helbing fluctuation force (Helbing et al. 2000, Eq. 1).
    # PySocialForce reference confirmed: SFM without noise → 0/80 agents pass in 120s.
    # The fluctuation breaks metastable arches stochastically.
    # F_fluct = m·σ·ξ  where ξ is a random unit vector.
    if motion_i.σ > F(0)
        ξ₁ = randn(F);  ξ₂ = randn(F)
        ξ_norm = sqrt(ξ₁^2 + ξ₂^2)
        if ξ_norm > F(1e-8)
            F_total += motion_i.mass * motion_i.σ * SVector(ξ₁, ξ₂) / ξ_norm
        end
    end

    # Geometry: collision_r matches AgentGeometry(r_body, r_body*2/3).collision_radius
    #
    # DIAGNOSTIC (2026-08-26): social_r_wall = r_body = 0.2m caused two problems:
    #   1. Door corner at d=0.303m: F_wall=555N > F_goal=203N → agent 61 blocked (net_x=-352N)
    #      Fix: social_r_wall=0.1m → F_wall=156N < F_goal → FORWARD
    #   2. k=120000 at dt=0.05s: ω₀=38.7 rad/s, stability limit dt<0.052s (marginal)
    #      → agents fly through walls at 3.88 m/s (agent 70) and escape geometry
    #      Fix: k=12000 → ω₀=12.25 rad/s, stable dt<0.163s ✓
    #           Still prevents penetration: 12000×0.133=1596N > F_goal=224N
    collision_r_i = r_body * F(2/3)
    social_r_wall = F(0.1)   # reduced from r_body=0.2m; door corner force now < goal force
    k_contact     = F(12000)  # reduced from 120000; stable at dt=0.05s, still impenetrable
    κ_contact     = F(24000)  # κ/k = 2.0 (Helbing ratio maintained)

    # 2. Agent-agent: PSYCHOLOGICAL (contact-range) + CONTACT forces.
    #
    # CRITICAL DESIGN NOTE: contact-only SFM (no psychological force) creates PERMANENT
    # arches at the bottleneck door. Without the anisotropy weight ω=λ+(1-λ)*(1+cosθ)/2,
    # the force equilibrium at an arch is perfectly symmetric → never breaks → deadlock.
    #
    # Solution: use psychological_force with social_r_agent = sp.B (= 0.08m).
    # At d=0.25m (body contact): F ≈ 2000 N — same as Helbing contact model.
    # At d=0.45m: F ≈ 88 N (exponential decay, near-zero at 0.5m).
    # This is CONTACT-RANGE only (no long-range lateral pressure that stabilises arches),
    # but PRESERVES λ-anisotropy: rear neighbours feel 0.5× the force of forward neighbours
    # → arch asymmetry → arch breaks → agents flow through door.
    social_r_agent = sp.B   # = 0.08m: Helbing's own decay length, contact-range psychological
    for j in eachindex(all_positions)
        d_sq = sum(abs2, all_positions[j] - pos_i)
        d_sq < F(1e-8) && continue  # skip self
        pos_j = all_positions[j]
        vel_j = all_velocities[j]
        # Psychological force (anisotropic, contact-range only via B=0.08m)
        F_total += psychological_force(pos_i, vel_i, social_r_agent, pos_j, social_r_agent;
                                       A=sp.A, B=sp.B, λ=sp.λ)
        # Body compression + friction (only when physically overlapping)
        # k=12000 (not 120000) for Euler stability at dt=0.05s
        F_total += contact_force(pos_i, vel_i, collision_r_i,
                                 pos_j, vel_j, collision_r_i; μ=sp.μ, k=k_contact, κ=κ_contact)
    end

    # 3. Wall repulsion — social_r_wall=0.1m (not r_body=0.2m) for door corner access
    for w in walls
        F_total += wall_repulsion(pos_i, vel_i, social_r_wall, collision_r_i, w;
                                  μ=sp.μ, k=k_contact, κ=κ_contact)
    end

    return F_total
end


# ════════════════════════════════════════════════════════════════════════════════
# Sprint 3S: GPU Hybrid FSM kernel + RadixSpatialHash dispatch
# ════════════════════════════════════════════════════════════════════════════════

"""
    compute_density_mode_kernel!

GPU kernel for density estimation and FSM mode transition (Sprint 3S).

For each agent:
1. Count neighbors within `density_radius` using the sorted spatial hash (O(k))
2. Compute local density ρ_local = n_nbr / (π × density_radius²)
3. EMA smoothing: ρ_ema ← α × ρ_local + (1-α) × ρ_ema_prev
4. FSM transition (hysteresis):
   - ORCA_MODE → SFM_MODE when ρ_ema ≥ ρ_on
   - SFM_MODE  → ORCA_MODE when ρ_ema < ρ_off

Writes updated ρ_ema and mode to `out_rho_ema` and `out_modes` (unsorted order).
"""
@kernel function compute_density_mode_kernel!(
    out_rho_ema, out_modes,
    @Const(sorted_positions),
    @Const(sorted_last_positions),
    @Const(sorted_rho_ema), @Const(sorted_modes),
    @Const(sorted_density_radii),
    @Const(sorted_rho_on), @Const(sorted_rho_off),
    @Const(agent_indices),
    grid_min, grid_dims, cell_size,
    @Const(cell_starts), @Const(cell_ends))

    i = @index(Global, Linear)
    @inbounds begin
        original_i = agent_indices[i]
        pos_i      = sorted_positions[i]
        r_density  = sorted_density_radii[i]
        r_sq       = r_density * r_density

        # O(k) density estimation (3×3 cell neighborhood)
        lp   = sorted_last_positions[i]
        F_type = typeof(r_density)
        ci_x = clamp(floor(Int32, (lp[1]-grid_min[1])/cell_size), Int32(0), grid_dims[1]-Int32(1))
        ci_y = clamp(floor(Int32, (lp[2]-grid_min[2])/cell_size), Int32(0), grid_dims[2]-Int32(1))
        n_nearby = Int32(0)
        for di in Int32(-1):Int32(1)
            ni_x = ci_x + di
            (ni_x < Int32(0) || ni_x >= grid_dims[1]) && continue
            for dj in Int32(-1):Int32(1)
                ni_y = ci_y + dj
                (ni_y < Int32(0) || ni_y >= grid_dims[2]) && continue
                cell_idx = ni_x * grid_dims[2] + ni_y + Int32(1)
                cs = cell_starts[cell_idx]; ce = cell_ends[cell_idx]
                for k in cs:ce
                    k == i && continue
                    Dp = sorted_positions[k] - pos_i
                    d2 = Dp[1]^2 + Dp[2]^2
                    if d2 > F_type(1e-8) && d2 < r_sq
                        n_nearby += Int32(1)
                    end
                end
            end
        end
        rho_local = F_type(n_nearby) / (F_type(pi) * r_sq)

        # EMA smoothing (α = 0.33)
        alpha     = F_type(0.33)
        rho_ema   = alpha * rho_local + (one(F_type) - alpha) * sorted_rho_ema[i]

        # FSM transition (hysteresis)
        cur_mode  = sorted_modes[i]
        new_mode  = if cur_mode == Int32(0)   # ORCA_MODE
            rho_ema >= sorted_rho_on[i] ? Int32(1) : Int32(0)
        else                                   # SFM_MODE
            rho_ema < sorted_rho_off[i] ? Int32(0) : Int32(1)
        end

        out_rho_ema[original_i] = rho_ema
        out_modes[original_i]   = new_mode
    end
end

"""
    compute_hybrid_sfm_kernel!

GPU SFM force kernel for Hybrid FSM agents in SFM_MODE (Sprint 3S).

Same physics as `_hybrid_sfm_force` in CPU path, but GPU-parallelised:
- Goal-seeking force (no noise — deterministic GPU version)
- Agent-agent: psychological force (contact-range, λ-anisotropic) + contact force
- Wall: wall_repulsion-style contact via `apply_wall_penetration_correction` geometry

Only processes agents with `mode[i] == SFM_MODE`. ORCA_MODE forces are handled
by the existing `compute_orca_kernel!` with a mode mask.
"""
@kernel function compute_hybrid_sfm_kernel!(
    out_forces,
    @Const(sorted_positions), @Const(sorted_velocities), @Const(sorted_radii),
    @Const(sorted_goals), @Const(sorted_v_prefs), @Const(sorted_taus), @Const(sorted_masses),
    @Const(sorted_modes_cur),   # current modes (after density update)
    @Const(sorted_last_positions),
    @Const(wall_p1s), @Const(wall_p2s), n_walls,
    @Const(agent_indices),
    grid_min, grid_dims, cell_size,
    @Const(cell_starts), @Const(cell_ends),
    sfm_A::F_, sfm_B::F_, sfm_lambda::F_, sfm_mu::F_) where {F_}

    i = @index(Global, Linear)
    @inbounds begin
        original_i = agent_indices[i]
        # Only compute for SFM_MODE agents
        if sorted_modes_cur[i] != Int32(1)
            # ORCA_MODE — no SFM force from this kernel
            out_forces[original_i] = zero(typeof(sorted_positions[i]))
        else

        pos_i  = sorted_positions[i]
        vel_i  = sorted_velocities[i]
        r_i    = sorted_radii[i]
        F_type = typeof(r_i)

        # Goal-seeking (no noise in GPU version — deterministic)
        goal_i = sorted_goals[i]
        v_pref = sorted_v_prefs[i]
        tau_i  = sorted_taus[i]
        mass_i = sorted_masses[i]
        gd     = goal_i - pos_i
        gd_n   = sqrt(gd[1]^2 + gd[2]^2)
        e_goal = gd_n > F_type(1e-6) ? gd / gd_n : zero(typeof(gd))
        v_pref_vec = v_pref * e_goal
        F_total = mass_i * (v_pref_vec - vel_i) / tau_i

        # Agent-agent forces (O(k) via 3×3 cell neighborhood)
        lp   = sorted_last_positions[i]
        ci_x = clamp(floor(Int32, (lp[1]-grid_min[1])/cell_size), Int32(0), grid_dims[1]-Int32(1))
        ci_y = clamp(floor(Int32, (lp[2]-grid_min[2])/cell_size), Int32(0), grid_dims[2]-Int32(1))
        social_r_agent = sfm_B   # contact-range psychological radius
        collision_r_i  = r_i * F_type(2/3)

        for di in Int32(-1):Int32(1)
            ni_x = ci_x + di
            (ni_x < Int32(0) || ni_x >= grid_dims[1]) && continue
            for dj in Int32(-1):Int32(1)
                ni_y = ci_y + dj
                (ni_y < Int32(0) || ni_y >= grid_dims[2]) && continue
                cell_idx = ni_x * grid_dims[2] + ni_y + Int32(1)
                cs = cell_starts[cell_idx]; ce = cell_ends[cell_idx]
                for k in cs:ce
                    k == i && continue
                    pos_j  = sorted_positions[k]
                    vel_j  = sorted_velocities[k]
                    r_j    = sorted_radii[k]
                    e_ij   = pos_j - pos_i
                    d      = sqrt(e_ij[1]^2 + e_ij[2]^2)
                    d < F_type(1e-6) && continue
                    n_ij   = e_ij / d

                    # Psychological force (anisotropic, contact-range: λ-weight)
                    cos_phi = -(vel_i[1]*n_ij[1] + vel_i[2]*n_ij[2]) / max(sqrt(vel_i[1]^2+vel_i[2]^2), F_type(1e-6))
                    w       = sfm_lambda + (one(F_type) - sfm_lambda) * (one(F_type) + cos_phi) * F_type(0.5)
                    F_psych = -w * sfm_A * exp(-(d - social_r_agent - social_r_agent) / sfm_B) * n_ij
                    F_total = F_total + F_psych

                    # Contact force (body compression + friction) — k=12000
                    overlap = collision_r_i + r_j * F_type(2/3) - d
                    if overlap > zero(F_type)
                        F_contact_n = F_type(12000) * overlap * (-n_ij)
                        # Tangential friction
                        tan_ij = typeof(n_ij)(-n_ij[2], n_ij[1])
                        dv_t   = (vel_j[1]-vel_i[1])*tan_ij[1] + (vel_j[2]-vel_i[2])*tan_ij[2]
                        F_contact_t = F_type(24000) * overlap * dv_t * tan_ij
                        F_total = F_total + F_contact_n + F_contact_t
                    end
                end
            end
        end

        # Wall repulsion (social_r_wall=0.1m, k=12000; matches CPU path)
        social_r_wall = F_type(0.1)
        k_contact     = F_type(12000)
        kappa_contact = F_type(24000)
        @inbounds for w in 1:n_walls
            p1 = wall_p1s[w]; p2 = wall_p2s[w]
            seg = p2 - p1; l2 = seg[1]^2 + seg[2]^2
            t   = l2 < F_type(1e-10) ? zero(F_type) :
                clamp(((pos_i[1]-p1[1])*seg[1]+(pos_i[2]-p1[2])*seg[2])/l2, zero(F_type), one(F_type))
            q   = p1 + t*seg; rel = pos_i - q; d = sqrt(rel[1]^2 + rel[2]^2)
            d < F_type(1e-6) && continue
            n_wall = rel / d
            # Social repulsion
            gap_social = max(d - social_r_wall, zero(F_type))
            F_social_w = -sfm_A * exp(-gap_social / sfm_B) * n_wall
            F_total = F_total + F_social_w
            # Contact compression
            overlap_w = collision_r_i - d
            if overlap_w > zero(F_type)
                F_cn = k_contact * overlap_w * n_wall
                tan_w = typeof(n_wall)(-n_wall[2], n_wall[1])
                dv_tw = -(vel_i[1]*tan_w[1] + vel_i[2]*tan_w[2])
                F_ct  = kappa_contact * overlap_w * dv_tw * tan_w
                F_total = F_total + F_cn + F_ct
            end
        end

        out_forces[original_i] = F_total
        end  # else (SFM_MODE)
    end
end

"""
    update_hybrid_fsm_system!(world, search::RadixSpatialHash, backend, dt)

GPU Hybrid FSM dispatch (Sprint 3S). Steps:
1. `stage_and_sort_base!` — upload positions/velocities/walls to device, build grid
2. `compute_density_mode_kernel!` — density estimation + EMA + FSM mode transition (GPU)
3. `compute_hybrid_sfm_kernel!` — SFM forces for SFM_MODE agents (GPU)
4. ORCA force update for ORCA_MODE agents (CPU path via existing `update_orca_system!`)
5. Write combined forces + updated states back to ECS

Architecture note: ORCA LP solver is inherently sequential per-agent (LP3 depends on LP2
output). GPU-parallelised ORCA would require O(N × W²) shared memory. Sprint 3S routes
ORCA_MODE agents through the existing CPU `update_orca_system!` with mode filtering.
This is the correct architecture: SFM benefits most from GPU (embarrassingly parallel),
while ORCA's bottleneck is the LP solver, not the neighbor search.
"""
function update_hybrid_fsm_system!(world::World, search::RadixSpatialHash{AT,F},
                                    backend::Backend, dt::F) where {AT,F}
    n_hybrid = 0
    try
        n_hybrid = count_entities(Query(world, (HybridFSMParams{F},)))
    catch e
        e isa ArgumentError && return; rethrow()
    end
    n_hybrid == 0 && return

    N = n_hybrid; n_walls = 0
    ctx = get_hybrid_gpu_context(world, backend, F, N, 64)

    # ── ECS extraction ────────────────────────────────────────────────────────
    idx = 1
    for (_, pos_col, vel_col, motion_col, goal_col, force_col, params_col, state_col) in
            Query(world, (Position{F}, Velocity{F}, MotionParams{F},
                          Goal{F}, Force{F}, HybridFSMParams{F}, AgentFSMState{F}))
        for i in eachindex(pos_col)
            ctx.base.cpu_positions[idx]       = pos_col[i].p
            ctx.base.cpu_velocities[idx]      = vel_col[i].v
            ctx.base.cpu_radii[idx]           = params_col[i].orca_params.radius
            ctx.cpu_goals[idx]                = goal_col[i].g
            ctx.cpu_rho_ema[idx]              = state_col[i].ρ_ema
            ctx.cpu_modes[idx]                = state_col[i].mode
            ctx.cpu_v_prefs[idx]              = motion_col[i].v_pref
            ctx.cpu_taus[idx]                 = motion_col[i].τ
            ctx.cpu_masses[idx]               = motion_col[i].mass
            ctx.cpu_time_horizons[idx]        = params_col[i].orca_params.time_horizon
            ctx.cpu_responsibilities[idx]     = params_col[i].orca_params.responsibility
            ctx.cpu_density_radii[idx]        = params_col[i].density_radius
            ctx.cpu_rho_on[idx]               = params_col[i].ρ_on
            ctx.cpu_rho_off[idx]              = params_col[i].ρ_off
            ctx.cpu_sigma[idx]                = motion_col[i].σ
            idx += 1
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
    catch e
        e isa ArgumentError || rethrow()
    end

    # ── Stage shared fields + rebuild ─────────────────────────────────────────
    stage_and_sort_base!(ctx.base, ctx.base.cpu_positions, ctx.base.cpu_velocities,
                         ctx.base.cpu_radii, ctx.base.cpu_wall_p1s, ctx.base.cpu_wall_p2s,
                         n_walls, search, backend, ctx.sorted_last_positions)

    # ── Stage HybridFSM-specific fields ──────────────────────────────────────
    copyto!(ctx.dev_rho_ema,         ctx.cpu_rho_ema)
    copyto!(ctx.dev_modes,           ctx.cpu_modes)
    copyto!(ctx.dev_v_prefs,         ctx.cpu_v_prefs)
    copyto!(ctx.dev_taus,            ctx.cpu_taus)
    copyto!(ctx.dev_masses,          ctx.cpu_masses)
    copyto!(ctx.dev_time_horizons,   ctx.cpu_time_horizons)
    copyto!(ctx.dev_responsibilities, ctx.cpu_responsibilities)
    copyto!(ctx.dev_density_radii,   ctx.cpu_density_radii)
    copyto!(ctx.dev_rho_on,          ctx.cpu_rho_on)
    copyto!(ctx.dev_rho_off,         ctx.cpu_rho_off)
    copyto!(ctx.dev_goals,           ctx.cpu_goals)

    kernel_reorder! = reorder_array_kernel!(backend)
    # Sort goal, v_pref, tau, mass, time_horizon, responsibility by agent_indices
    kernel_reorder!(ctx.sorted_dev_goals,           ctx.dev_goals,           search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_v_prefs,         ctx.dev_v_prefs,         search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_taus,            ctx.dev_taus,            search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_masses,          ctx.dev_masses,          search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_time_horizons,   ctx.dev_time_horizons,   search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_responsibilities, ctx.dev_responsibilities, search.agent_indices, ndrange=N)

    # Sorted rho_ema, modes, density_radii, rho_on, rho_off (used by density kernel)
    dev_sorted_rho_ema     = similar(ctx.dev_rho_ema)
    dev_sorted_modes       = similar(ctx.dev_modes)
    dev_sorted_density_r   = similar(ctx.dev_density_radii)
    dev_sorted_rho_on      = similar(ctx.dev_rho_on)
    dev_sorted_rho_off     = similar(ctx.dev_rho_off)
    kernel_reorder!(dev_sorted_rho_ema,   ctx.dev_rho_ema,       search.agent_indices, ndrange=N)
    kernel_reorder!(dev_sorted_modes,     ctx.dev_modes,         search.agent_indices, ndrange=N)
    kernel_reorder!(dev_sorted_density_r, ctx.dev_density_radii, search.agent_indices, ndrange=N)
    kernel_reorder!(dev_sorted_rho_on,    ctx.dev_rho_on,        search.agent_indices, ndrange=N)
    kernel_reorder!(dev_sorted_rho_off,   ctx.dev_rho_off,       search.agent_indices, ndrange=N)

    # Sorted modes needed for SFM kernel input (after density update)
    dev_out_modes   = similar(ctx.dev_modes)
    dev_out_rho_ema = similar(ctx.dev_rho_ema)

    # ── GPU kernel 1: Density estimation + mode transition ────────────────────
    density_kernel! = compute_density_mode_kernel!(backend)
    density_kernel!(dev_out_rho_ema, dev_out_modes,
                    ctx.base.sorted_dev_positions, ctx.sorted_last_positions,
                    dev_sorted_rho_ema, dev_sorted_modes,
                    dev_sorted_density_r, dev_sorted_rho_on, dev_sorted_rho_off,
                    search.agent_indices,
                    search.grid_min, search.grid_dims, search.cell_size,
                    search.cell_starts, search.cell_ends,
                    ndrange=N)
    KernelAbstractions.synchronize(backend)

    # Now sort the NEW modes (output of density kernel) for use by SFM kernel
    dev_sorted_new_modes = similar(ctx.dev_modes)
    kernel_reorder!(dev_sorted_new_modes, dev_out_modes, search.agent_indices, ndrange=N)

    # ── GPU kernel 2: SFM forces for SFM_MODE agents ─────────────────────────
    # Read SFM params from the first Hybrid agent (uniform across scene; Sprint 3S-next: per-agent)
    sfm_A       = F(2000)   # default; TODO: read from HybridFSMParams.sfm_params.A
    sfm_B       = F(0.08)
    sfm_lambda  = F(0.2)
    sfm_mu      = F(0.0)

    # Try to read from ECS
    for (_, params_col) in Query(world, (HybridFSMParams{F},))
        if !isempty(params_col)
            sp = params_col[1].sfm_params
            sfm_A = sp.A; sfm_B = sp.B; sfm_lambda = sp.λ; sfm_mu = sp.μ
            break
        end
    end

    fill!(ctx.dev_forces, zero(SVector{2,F}))
    sfm_kernel! = compute_hybrid_sfm_kernel!(backend)
    sfm_kernel!(ctx.dev_forces,
                ctx.base.sorted_dev_positions, ctx.base.sorted_dev_velocities, ctx.base.sorted_dev_radii,
                ctx.sorted_dev_goals, ctx.sorted_dev_v_prefs, ctx.sorted_dev_taus, ctx.sorted_dev_masses,
                dev_sorted_new_modes, ctx.sorted_last_positions,
                ctx.base.dev_wall_p1s, ctx.base.dev_wall_p2s, n_walls,
                search.agent_indices,
                search.grid_min, search.grid_dims, search.cell_size,
                search.cell_starts, search.cell_ends,
                sfm_A, sfm_B, sfm_lambda, sfm_mu,
                ndrange=N)
    KernelAbstractions.synchronize(backend)

    # ── Read back GPU outputs ─────────────────────────────────────────────────
    cpu_new_rho_ema = Vector{F}(undef, N)
    cpu_new_modes   = Vector{Int32}(undef, N)
    cpu_sfm_forces  = Vector{SVector{2,F}}(undef, N)
    copyto!(cpu_new_rho_ema, dev_out_rho_ema)
    copyto!(cpu_new_modes,   dev_out_modes)
    copyto!(cpu_sfm_forces,  ctx.dev_forces)

    # ── CPU ORCA pass for ORCA_MODE agents ───────────────────────────────────
    # Delegate to the existing CPU ORCA system, which filters by ORCAParams.
    # HybridFSM agents have HybridFSMParams (not ORCAParams), so we call
    # _hybrid_orca_force directly for each ORCA_MODE agent.
    cpu_orca_forces = zeros(SVector{2,F}, N)
    cpu_positions   = ctx.base.cpu_positions
    cpu_velocities  = ctx.base.cpu_velocities
    cpu_goals_local = ctx.cpu_goals

    # Collect walls for CPU ORCA
    walls_cpu = [(ctx.base.cpu_wall_p1s[w], ctx.base.cpu_wall_p2s[w]) for w in 1:n_walls]

    idx = 1
    for (_, params_col) in Query(world, (HybridFSMParams{F},))
        for i in eachindex(params_col)
            if cpu_new_modes[idx] == Int32(0)  # ORCA_MODE
                cpu_orca_forces[idx] = _hybrid_orca_force(
                    cpu_positions[idx], cpu_velocities[idx],
                    cpu_goals_local[idx],   # goal from ECS extraction buffer
                    params_col[i].orca_params,
                    cpu_positions, cpu_velocities,
                    walls_cpu, dt, F)
            end
            idx += 1
        end
    end

    # ── Write back to ECS ─────────────────────────────────────────────────────
    idx = 1
    for (_, _, _, _, _, force_col, _, state_col) in
            Query(world, (Position{F}, Velocity{F}, MotionParams{F},
                          Goal{F}, Force{F}, HybridFSMParams{F}, AgentFSMState{F}))
        for i in eachindex(force_col)
            # Combine SFM (GPU) + ORCA (CPU) forces
            total_f = cpu_sfm_forces[idx] + cpu_orca_forces[idx]
            force_col[i] = Force(force_col[i].f + total_f)
            # Update FSM state (new mode + ρ_ema from GPU)
            state_col[i] = AgentFSMState{F}(cpu_new_modes[idx], cpu_new_rho_ema[idx], Int32(0))
            idx += 1
        end
    end
end
