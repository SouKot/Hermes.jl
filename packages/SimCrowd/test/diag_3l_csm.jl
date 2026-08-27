# diag_3l_csm.jl — COMPREHENSIVE Rule Zero CSM Diagnostic
#
# Follows debugging protocol: create diagnostic FIRST, observe EVERYTHING, then fix.
# This script instruments the full N=80 bottleneck and dumps per-agent, per-step state.
#
# WHAT WE OBSERVE:
#   - Per step: crossing count, speed distribution, zone occupancy
#   - Per 20 steps (1s): full agent dump sorted by x-position
#   - Per 5 steps (0.25s): arch-zone (x>8m) detailed breakdown
#   - Per agent in arch: position, gap, speed, repulsion vector, direction
#   - Gap histogram: surface-to-surface gap distribution at every snapshot
#   - Direction flip detection: agents whose direction is AWAY from door
#   - Repulsion magnitude: a*exp(-d/D) vs goal-pull (1.0)
#
# USAGE:
#   julia --project=. -t 4 test/diag_3l_csm.jl
#   julia --project=. -t 1 test/diag_3l_csm.jl   # single-threaded (serial = deterministic output)

using SimCrowd
using StaticArrays
using LinearAlgebra
using Printf
using Ark
using Random

const F = Float32

# ─────────────────────────────────────────────────────────────────────────────
# Geometry: identical to 3L-a bottleneck
# ─────────────────────────────────────────────────────────────────────────────
const DOOR_X    = 10.0f0
const DOOR_CY   = 2.0f0
const DOOR_HALF = 0.5f0
const ROOM_W    = 4.0f0
const ROOM_L    = 10.0f0
const GOAL      = SVector(12.0f0, DOOR_CY)
const EXIT_X    = 10.5f0
const PARK_X    = -50.0f0

# ─────────────────────────────────────────────────────────────────────────────
# Per-agent gap + direction computation (replicates csm.jl logic exactly)
# ─────────────────────────────────────────────────────────────────────────────

"""Compute detailed per-agent CSM state. Returns NamedTuple with all intermediate values."""
function agent_csm_detail(pos_i, goal_i, i_self, all_pos, walls, params::CSMParams{F}) where F
    r_i     = params.radius
    cos_fov = cos(params.fov_half_angle)

    # Goal direction
    gd = goal_i - pos_i
    nd = norm(gd)
    dir_goal = nd > eps(F) ? gd / nd : SVector(one(F), zero(F))

    # Gap scan: all forward neighbors
    min_gap = typemax(F)
    n_fwd   = 0
    nearest_j     = 0
    nearest_d     = typemax(F)
    repulsion     = zero(SVector{2,F})
    repulsion_fwd = zero(SVector{2,F})  # repulsion from forward neighbors only
    n_behind      = 0
    n_total_nbr   = 0

    # ── Find nearest forward neighbor for direction repulsion ─────────────────
    # (matches fixed csm_direction_isotropic: nearest only, not sum over all)
    min_d_fwd = typemax(F)
    nearest_fwd_j = 0
    for j in eachindex(all_pos)
        j == i_self && continue
        r_ij = all_pos[j] - pos_i
        d    = norm(r_ij)
        d > params.neighbor_radius && continue
        d > eps(F) || continue
        dp = dot(r_ij/d, dir_goal)
        in_fwd = dp > cos_fov

        # Gap (surface-to-surface)
        gap = max(d - r_i - params.radius, zero(F))

        # Track nearest forward neighbor (for gap and direction)
        if in_fwd
            n_fwd += 1
            min_gap = min(min_gap, gap)
            if d < nearest_d
                nearest_d = d; nearest_j = j
            end
            if d < min_d_fwd
                min_d_fwd = d; nearest_fwd_j = j
            end
        else
            n_behind += 1
        end

        n_total_nbr += 1
    end

    # Repulsion from nearest forward neighbor only (matches fixed csm.jl)
    neighbor_repulsion = zero(SVector{2,F})
    if nearest_fwd_j > 0
        r_ij  = all_pos[nearest_fwd_j] - pos_i
        n_nbr = r_ij / min_d_fwd
        neighbor_repulsion = (params.a_neighbor * exp(-min_d_fwd / params.D_neighbor)) * n_nbr
    end

    # Wall repulsion (V2)
    wall_repulsion = zero(SVector{2,F})
    if params.a_wall > zero(F)
        for (p1, p2) in walls
            pt, dw, _ = nearest_point_on_segment(p1, p2, pos_i)
            dw > params.neighbor_radius && continue
            dw < eps(F) && continue
            n_w = (pt - pos_i) / dw
            wall_repulsion += (params.a_wall * exp(-dw / params.D_wall)) * n_w
        end
    end

    total_repulsion = neighbor_repulsion + wall_repulsion

    # Safety cap (matches fixed csm.jl: |rep| < 1.0)
    rep_mag_total = norm(total_repulsion)
    if rep_mag_total >= one(F)
        total_repulsion = total_repulsion * (F(0.99) / rep_mag_total)
    end

    # Speed (OV function)
    s_i = min_gap == typemax(F) ? F(Inf) : min_gap
    v_i = csm_speed(s_i, params.v₀, params.T)

    # Direction
    raw      = dir_goal - total_repulsion
    raw_norm = norm(raw)
    e_i      = raw_norm > eps(F) ? raw / raw_norm : dir_goal

    # Is direction away from door? (x-component of final direction < 0)
    dir_away = e_i[1] < 0f0

    return (pos_i=pos_i, r_i=r_i,
        dir_goal      = dir_goal,
        e_final       = e_i,
        gap           = s_i,
        speed         = v_i,
        n_fwd         = n_fwd,
        n_behind      = n_behind,
        n_total_nbr   = n_total_nbr,
        nearest_d     = nearest_d,
        nearest_j     = nearest_j,
        repulsion     = neighbor_repulsion,
        repulsion_fwd = neighbor_repulsion,
        wall_rep      = wall_repulsion,
        rep_total_mag = norm(total_repulsion),
        dir_away      = dir_away,
        raw           = raw,
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# Build world (same as _make_csm_world in tier3)
# ─────────────────────────────────────────────────────────────────────────────
function build_diag_world(N::Int, params::CSMParams{F}; v3=false) where F
    comp_types = if v3
        (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, WallSegment{F}, AgentCSMState{F})
    else
        (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, WallSegment{F})
    end
    world = World(comp_types...)

    # Walls: 10×4m room, 1m door at x=10m, center y=2
    door_lo = DOOR_CY - DOOR_HALF; door_hi = DOOR_CY + DOOR_HALF
    new_entity!(world, (WallSegment(SVector(0f0,0f0), SVector(0f0,ROOM_W)),))
    new_entity!(world, (WallSegment(SVector(0f0,0f0), SVector(ROOM_L,0f0)),))
    new_entity!(world, (WallSegment(SVector(0f0,ROOM_W), SVector(ROOM_L,ROOM_W)),))
    new_entity!(world, (WallSegment(SVector(ROOM_L,0f0), SVector(ROOM_L,door_lo)),))
    new_entity!(world, (WallSegment(SVector(ROOM_L,door_hi), SVector(ROOM_L,ROOM_W)),))

    # Grid placement: prevents initial overlaps (same logic as _make_csm_world)
    rng = MersenneTwister(42)
    cols = max(1, ceil(Int, sqrt(N * (9.0f0 / 3.4f0))))
    rows = ceil(Int, N / cols)
    sp_x = F(9.0) / (cols + 1)
    sp_y = F(3.4) / (rows + 1)

    for k in 1:N
        row = (k-1) ÷ cols
        col = (k-1) % cols
        x = F(0.5) + (col + 1) * sp_x + F(0.05) * (rand(rng, F) - F(0.5))
        y = F(0.3) + (row + 1) * sp_y + F(0.05) * (rand(rng, F) - F(0.5))
        x = clamp(x, F(0.3), F(9.7))
        y = clamp(y, F(0.3), F(3.7))
        θ = atan(GOAL[2] - y, GOAL[1] - x)
        if v3
            new_entity!(world, (Position(SVector(x, y)),
                                Velocity(zero(SVector{2,F})),
                                Goal(GOAL), params, AgentCSMState{F}(θ)))
        else
            new_entity!(world, (Position(SVector(x, y)),
                                Velocity(zero(SVector{2,F})),
                                Goal(GOAL), params))
        end
    end
    return world
end

# ─────────────────────────────────────────────────────────────────────────────
# Snapshot helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Collect current agent state as arrays."""
function collect_agent_state(world, params::CSMParams{F}) where F
    positions  = SVector{2,F}[]
    velocities = SVector{2,F}[]
    goals      = SVector{2,F}[]
    for (_, pos_col, vel_col, goal_col, _) in
            Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
        for i in eachindex(pos_col)
            push!(positions,  pos_col[i].p)
            push!(velocities, vel_col[i].v)
            push!(goals,      goal_col[i].g)
        end
    end

    # Collect walls
    walls = NTuple{2, SVector{2,F}}[]
    try
        for (_, w_col) in Query(world, (WallSegment{F},))
            for i in eachindex(w_col)
                push!(walls, (w_col[i].p1, w_col[i].p2))
            end
        end
    catch; end

    return positions, velocities, goals, walls
end

"""Print one-liner step summary."""
function print_step_summary(t, n_passed, positions, velocities, params::CSMParams{F}) where F
    speeds = [norm(v) for v in velocities]
    mean_s = isempty(speeds) ? 0f0 : sum(speeds)/length(speeds)
    n_zero = count(s -> s < 0.01f0, speeds)
    n_fast = count(s -> s > params.v₀ * 0.5f0, speeds)
    n_near = count(p -> p[1] > 8.0f0, positions)
    n_arch = count(p -> p[1] > 9.0f0, positions)
    @printf("t=%6.2f s | passed=%3d | v̄=%.3f | zero=%3d | fast=%3d | x>8m=%3d | x>9m=%3d\n",
            t, n_passed, mean_s, n_zero, n_fast, n_near, n_arch)
end

"""Print full per-agent details for agents in the arch zone (x > threshold)."""
function print_arch_detail(positions, velocities, goals, walls, params::CSMParams{F};
                           x_threshold=7.0f0, label="") where F
    # Find arch agents (sorted by x descending)
    agents = [(i, positions[i]) for i in eachindex(positions)
              if positions[i][1] > x_threshold && positions[i][1] < EXIT_X + 1.0f0]
    sort!(agents, by=a -> -a[2][1])  # sort by x descending (nearest door first)

    isempty(agents) && return

    @printf("\n── Arch zone detail (x>%.1fm) %s — %d agents ──\n", x_threshold, label, length(agents))
    @printf("%-4s  %-7s %-7s  %-7s %-7s  %-6s  %-6s  %-4s  %-4s  %-8s  %-8s  %-8s  %-8s  %s\n",
            "#", "x", "y", "vx", "vy", "speed", "gap", "nfwd", "nbhd",
            "rep_x", "rep_y", "|rep|", "raw_ex", "away?")
    @printf("%-4s  %-7s %-7s  %-7s %-7s  %-6s  %-6s  %-4s  %-4s  %-8s  %-8s  %-8s  %-8s  %s\n",
            "---", "-------", "-------", "-------", "-------", "------", "------",
            "----", "----", "--------", "--------", "--------", "--------", "-----")

    for (i, _) in agents
        d = agent_csm_detail(positions[i], goals[i], i, positions, walls, params)
        v = velocities[i]
        @printf("%-4d  %-7.4f %-7.4f  %-7.4f %-7.4f  %-6.4f  %-6.4f  %-4d  %-4d  %-8.4f  %-8.4f  %-8.4f  %-8.4f  %s\n",
                i, positions[i][1], positions[i][2], v[1], v[2],
                norm(v), d.gap, d.n_fwd, d.n_total_nbr,
                d.repulsion[1], d.repulsion[2], d.rep_total_mag,
                d.raw[1],
                d.dir_away ? "AWAY ❌" : "→door ✓")
    end
end

"""Print speed and gap histograms."""
function print_histograms(positions, velocities, params::CSMParams{F}, all_gaps::Vector{F}) where F
    speeds = [norm(v) for v in velocities]

    # Speed histogram (10 bins from 0 to v₀)
    v₀ = params.v₀; bin_w = v₀ / 10
    bins = zeros(Int, 11)
    for s in speeds
        b = min(floor(Int, s / bin_w) + 1, 11)
        bins[b] += 1
    end
    @printf("\n  Speed histogram (v₀=%.2f m/s, bin_w=%.3f):\n", v₀, bin_w)
    for b in 1:11
        lo = (b-1) * bin_w; hi = b * bin_w
        bar = "█" ^ bins[b]
        @printf("  [%5.3f-%5.3f] %3d %s\n", lo, hi, bins[b], bar)
    end

    # Gap histogram (10 bins from 0 to 2m)
    finite_gaps = filter(isfinite, all_gaps)
    if !isempty(finite_gaps)
        @printf("\n  Gap histogram (surface-to-surface, bins 0-2m, %d finite / %d Inf):\n",
                length(finite_gaps), count(!isfinite, all_gaps))
        gap_bins = zeros(Int, 11)
        for g in finite_gaps
            b = min(floor(Int, g / 0.2f0) + 1, 11)
            gap_bins[b] += 1
        end
        for b in 1:11
            lo = (b-1)*0.2f0; hi = b*0.2f0
            bar = "█" ^ gap_bins[b]
            @printf("  [%4.2f-%4.2f] %3d %s\n", lo, hi, gap_bins[b], bar)
        end
    end

    # X-position histogram (bins 0-12m, skip parked agents at x<0)
    @printf("\n  X-position histogram (active agents, bins 0-12m):\n")
    xbins = zeros(Int, 13)
    n_parked = 0
    for p in positions
        if p[1] < 0f0
            n_parked += 1
            continue   # skip parked agents at x=-50
        end
        b = clamp(floor(Int, p[1] / 1.0f0) + 1, 1, 13)
        xbins[b] += 1
    end
    for b in 1:13
        lo = (b-1)*1.0f0; hi = b*1.0f0
        bar = "█" ^ xbins[b]
        @printf("  [%4.1f-%4.1f] %3d %s\n", lo, hi, xbins[b], bar)
    end
    n_parked > 0 && @printf("  (skipped %d parked agents at x≈-50m)\n", n_parked)
end

"""Compute all pairwise forward gaps for all agents."""
function compute_all_gaps(positions, params::CSMParams{F}) where F
    all_gaps = F[]
    r_i = params.radius
    cos_fov = cos(params.fov_half_angle)
    for i in eachindex(positions)
        gd = GOAL - positions[i]
        nd = norm(gd)
        dir_goal = nd > eps(F) ? gd / nd : SVector(one(F), zero(F))
        min_gap = typemax(F)
        for j in eachindex(positions)
            j == i && continue
            r_ij = positions[j] - positions[i]
            d    = norm(r_ij)
            d > params.neighbor_radius && continue
            d > eps(F) || continue
            dot(r_ij/d, dir_goal) > cos_fov || continue
            gap = max(d - r_i - params.radius, zero(F))
            min_gap = min(min_gap, gap)
        end
        push!(all_gaps, min_gap == typemax(F) ? F(Inf) : min_gap)
    end
    return all_gaps
end

"""Count agents that have crossed exit threshold."""
function count_passed(world)
    n = 0
    for (_, pos_col) in Query(world, (Position{F},))
        for i in eachindex(pos_col)
            pos_col[i].p[1] > EXIT_X && (n += 1)
        end
    end
    return n
end

# ─────────────────────────────────────────────────────────────────────────────
# Main diagnostic run
# ─────────────────────────────────────────────────────────────────────────────

function run_csm_diagnostic(;
    N          = 80,
    params     = CSMParams_V1(Float32; a_neighbor=8f0, D_neighbor=0.2f0, T=1.0f0),
    dt         = 0.05f0,
    t_max      = 60.0f0,
    # Printing controls
    step_every          = 1,    # print step summary every N steps
    arch_every          = 10,   # print arch detail every N steps (= arch_every * dt seconds)
    histogram_every     = 40,   # print histograms every N steps
    full_dump_at        = [0f0, 2f0, 5f0, 10f0, 20f0, 30f0],  # times for full dump
    arch_x_threshold    = 7.0f0,
    label               = "V1"
)
    @printf("\n╔══════════════════════════════════════════════════════════════════════════╗\n")
    @printf("║  CSM DIAGNOSTIC: %s  N=%d  dt=%.3f  t_max=%.1f s              \n", label, N, dt, t_max)
    @printf("║  params: a=%.1f D=%.3f T=%.3f v₀=%.2f r=%.3f fov=%.2f°\n",
            params.a_neighbor, params.D_neighbor, params.T, params.v₀, params.radius,
            rad2deg(params.fov_half_angle))
    @printf("╚══════════════════════════════════════════════════════════════════════════╝\n\n")

    world = build_diag_world(N, params; v3=params.use_rotational_steering)

    # Initial state
    positions, velocities, goals, walls = collect_agent_state(world, params)
    @printf("INITIAL STATE: N=%d agents in [0,%.0fm]×[0,%.0fm]\n", N, ROOM_L, ROOM_W)
    all_gaps = compute_all_gaps(positions, params)
    finite_gaps = filter(isfinite, all_gaps)
    if !isempty(finite_gaps)
        @printf("Initial gaps: min=%.4f mean=%.4f max=%.4f\n",
                minimum(finite_gaps), sum(finite_gaps)/length(finite_gaps), maximum(finite_gaps))
    end
    n_inf_gap = count(!isfinite, all_gaps)
    @printf("Agents with no forward neighbor (gap=Inf): %d/%d\n", n_inf_gap, N)
    @printf("\n%-55s\n", "step-by-step: t | passed | mean_speed | n_zero_v | n_fast | x>8m | x>9m")
    @printf("%-55s\n", "─"^80)

    t      = 0f0
    step   = 0
    n_passed = 0
    dump_idx = 1

    while t < t_max && n_passed < N
        step += 1
        t    += dt

        # Park agents that have exited
        try
            for (_, pos_col, vel_col, goal_col, _) in
                    Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
                for i in eachindex(pos_col)
                    if pos_col[i].p[1] >= EXIT_X
                        n_passed += 1
                        pos_col[i]  = Position(SVector(PARK_X, DOOR_CY))
                        vel_col[i]  = Velocity(zero(SVector{2,F}))
                        goal_col[i] = Goal(GOAL)
                    end
                end
            end
        catch; end

        # Step
        update_csm_system!(world, dt)

        # Collect state
        positions, velocities, goals, walls = collect_agent_state(world, params)
        n_passed = count_passed(world)   # re-count after step

        # ── Every step_every steps: print step summary ──────────────────────
        if step % step_every == 0
            print_step_summary(t, n_passed, positions, velocities, params)
        end

        # ── Every arch_every steps: print arch zone detail ───────────────
        if step % arch_every == 0
            print_arch_detail(positions, velocities, goals, walls, params;
                              x_threshold=arch_x_threshold,
                              label="t=$(round(t, digits=2))s")
        end

        # ── Every histogram_every steps: print distributions ─────────────
        if step % histogram_every == 0
            all_gaps = compute_all_gaps(positions, params)
            print_histograms(positions, velocities, params, all_gaps)
        end

        # ── At key times: full agent dump (sorted by x) ──────────────────
        if dump_idx <= length(full_dump_at) && t >= full_dump_at[dump_idx]
            dump_idx += 1
            all_gaps = compute_all_gaps(positions, params)
            n_dir_away = 0
            @printf("\n══ FULL DUMP at t=%.2f s (passed=%d) ══\n", t, n_passed)
            @printf("%-4s  %-7s %-7s  %-5s  %-5s  %-5s  %-5s  %-4s  %-8s  %s\n",
                    "#", "x", "y", "speed", "gap", "nfwd", "nbhd", "rep|", "raw_ex", "dir")
            order = sortperm(positions, by=p->-p[1])
            for i in order
                p = positions[i]; v = velocities[i]
                d = agent_csm_detail(p, goals[i], i, positions, walls, params)
                d.dir_away && (n_dir_away += 1)
                mark = d.dir_away ? "←AWAY" : ""
                @printf("%-4d  %-7.3f %-7.3f  %-5.3f  %-5.3f  %-5d  %-5d  %-8.3f  %-8.3f  %s\n",
                        i, p[1], p[2], norm(v), d.gap,
                        d.n_fwd, d.n_total_nbr, d.rep_total_mag, d.raw[1], mark)
            end
            @printf("→ Agents pointing AWAY from door: %d/%d (%.0f%%)\n",
                    n_dir_away, length(positions), 100.0*n_dir_away/max(1,length(positions)))
        end
    end

    # ── Final summary ────────────────────────────────────────────────────────
    positions, velocities, goals, walls = collect_agent_state(world, params)
    all_gaps = compute_all_gaps(positions, params)
    finite_gaps = filter(isfinite, all_gaps)

    @printf("\n╔══════════════════════════════════════════════════════════════════════════╗\n")
    @printf("║  FINAL: t=%.2f s  passed=%d/%d  flow=%.3f ped/s\n",
            t, n_passed, N, N > 0 ? n_passed/t : 0f0)
    @printf("╚══════════════════════════════════════════════════════════════════════════╝\n")
    print_histograms(positions, velocities, params, all_gaps)

    # Repulsion analysis on stuck agents
    n_stuck     = count(v -> norm(v) < 0.01f0, velocities)
    n_dir_away  = 0
    mean_rep    = 0f0
    for i in eachindex(positions)
        d = agent_csm_detail(positions[i], goals[i], i, positions, walls, params)
        d.dir_away && (n_dir_away += 1)
        mean_rep   += d.rep_total_mag
    end
    mean_rep /= max(1, length(positions))

    @printf("\n  Stuck agents (v < 0.01 m/s):       %d/%d\n", n_stuck, N)
    @printf("  Agents pointing AWAY from door:    %d/%d\n", n_dir_away, N)
    @printf("  Mean total repulsion magnitude:    %.4f\n", mean_rep)
    @printf("  Goal pull magnitude (constant):    1.0000\n")
    @printf("  Repulsion > goal pull → flip dir:  rep>1 means dir can flip\n")
    if !isempty(finite_gaps)
        @printf("  Final gap: min=%.4f  mean=%.4f  max=%.4f\n",
                minimum(finite_gaps), sum(finite_gaps)/length(finite_gaps), maximum(finite_gaps))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Run if executed directly
# ─────────────────────────────────────────────────────────────────────────────
if abspath(PROGRAM_FILE) == @__FILE__
    @printf("\n=== CSM COMPREHENSIVE DIAGNOSTIC ===\n")
    @printf("=== Rule Zero: observe EVERYTHING before fixing ===\n\n")

    # ── Run 1: Best sweep params (a=8, D=0.2, T=1.0)
    @printf("\n\n%s\n### RUN 1: Best sweep params (a=8.0, D=0.2, T=1.0) ###\n%s\n\n",
            "="^80, "="^80)
    run_csm_diagnostic(
        N      = 80,
        params = CSMParams_V1(Float32; a_neighbor=8f0, D_neighbor=0.2f0, T=1.0f0),
        dt     = 0.05f0,
        t_max  = 30.0f0,     # 30s is enough to see arch
        step_every      = 1,   # every step (0.05s)
        arch_every      = 10,  # every 0.5s
        histogram_every = 40,  # every 2s
        full_dump_at    = [0f0, 1f0, 3f0, 5f0, 10f0],
        arch_x_threshold = 7.0f0,
        label = "V1 a=8.0 D=0.2 T=1.0"
    )

    # ── Run 2: Very low repulsion (a=0.5, D=0.5) — does flow improve?
    @printf("\n\n%s\n### RUN 2: Low repulsion (a=0.5, D=0.5, T=0.8) ###\n%s\n\n",
            "="^80, "="^80)
    run_csm_diagnostic(
        N      = 80,
        params = CSMParams_V1(Float32; a_neighbor=0.5f0, D_neighbor=0.5f0, T=0.8f0),
        dt     = 0.05f0,
        t_max  = 30.0f0,
        step_every      = 4,   # every 0.2s
        arch_every      = 20,  # every 1s
        histogram_every = 60,  # every 3s
        full_dump_at    = [0f0, 5f0, 10f0, 20f0],
        arch_x_threshold = 7.0f0,
        label = "V1 a=0.5 D=0.5 T=0.8"
    )

    # ── Run 3: No repulsion at all (a=0) — pure speed model
    @printf("\n\n%s\n### RUN 3: Pure speed model (a=0, no repulsion direction) ###\n%s\n\n",
            "="^80, "="^80)
    run_csm_diagnostic(
        N      = 80,
        params = CSMParams_V1(Float32; a_neighbor=0f0, D_neighbor=0.2f0, T=1.0f0),
        dt     = 0.05f0,
        t_max  = 20.0f0,
        step_every      = 4,
        arch_every      = 20,
        histogram_every = 60,
        full_dump_at    = [0f0, 5f0, 10f0],
        arch_x_threshold = 7.0f0,
        label = "V1 a=0 (pure speed, no direction repulsion)"
    )

    @printf("\n\n=== DIAGNOSTIC COMPLETE ===\n")
    @printf("Interpret above output:\n")
    @printf("  1. 'AWAY❌' agents = repulsion overcoming goal pull → arch formation\n")
    @printf("  2. rep_total_mag > 1.0 → direction flips → deadlock\n")
    @printf("  3. Compare Run 1 vs Run 2 vs Run 3 to identify param range\n")
    @printf("  4. If Run 3 (a=0) flows freely → repulsion is the culprit\n")
end
