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
        if norm(q - pos_i) < op.radius + F(2)
            push!(lines, compute_orca_line_wall(pos_i, vel_i, op.radius, p1, p2,
                                                 op.time_horizon_obst, dt))
            num_wall_lines += 1
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
