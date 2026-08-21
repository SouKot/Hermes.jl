# crowd_test_helpers.jl — Reusable infrastructure for crowd validation tests
#
# Design principles:
#   Modularity:      Each function has one responsibility. Config is separate from execution.
#   Flexibility:     ReservoirConfig is parameterised; all tuning knobs are explicit fields.
#   Performance:     Tight inner loop; no heap allocation per-step; diagnostics are optional.
#   Maintainability: Documented invariants and parameter meanings inline.
#   Testability:     run_reservoir_bottleneck! returns a plain NamedTuple — easily inspectable.
#
# To use in a test file:
#   include("crowd_test_helpers.jl")

using StaticArrays
using Random

# ─────────────────────────────────────────────────────────────────────────────
# ReservoirConfig
# ─────────────────────────────────────────────────────────────────────────────

"""
    ReservoirConfig{F<:AbstractFloat}

All tuning parameters for a reservoir-based bottleneck simulation.

A *reservoir* setup maintains constant crowd density by re-injecting each agent
that exits through the door back into the upstream end of the corridor. This
matches the measurement conditions of Weidmann (1993), who observed steady-state
flow from a large continuously-replenished crowd — not a finite depletion
scenario.

# Fields
| Field           | Meaning |
|-----------------|---------|
| `dt`            | Integration timestep (s). Must satisfy dt ≤ τ/10 for SFM stability. |
| `t_warmup`      | Discarded initial period (s). Flow is not counted until warmup ends. |
| `t_measure`     | Measurement window duration (s). Flow = crossings / t_measure. |
| `door_x`        | x-coordinate of the door wall. |
| `door_lo`       | Lower y-bound of the door opening. |
| `door_hi`       | Upper y-bound of the door opening. |
| `exit_thresh`   | x-coordinate that counts as "crossed the door" (door_x + small margin). |
| `inject_x_lo`   | Left bound of re-injection zone (x). Should be well upstream of door. |
| `inject_x_hi`   | Right bound of re-injection zone (x). |
| `corridor_y_lo` | Lower y-bound for re-injection (clear of walls). |
| `corridor_y_hi` | Upper y-bound for re-injection (clear of walls). |
| `goal`          | Fixed goal assigned to every agent every step (past the door). |
| `diag_interval` | Diagnostic sampling interval (s). 0 disables per-interval snapshots. |

# Invariants
- `inject_x_lo < inject_x_hi < door_x`
- `corridor_y_lo < corridor_y_hi`
- `door_lo < door_hi`
- `exit_thresh > door_x`
"""
Base.@kwdef struct ReservoirConfig{F<:AbstractFloat}
    dt            :: F
    t_warmup      :: F
    t_measure     :: F
    door_x        :: F
    door_lo       :: F
    door_hi       :: F
    exit_thresh   :: F           # = door_x + small margin (e.g. 0.1m)
    inject_x_lo   :: F
    inject_x_hi   :: F
    corridor_y_lo :: F
    corridor_y_hi :: F
    goal          :: SVector{2,F}
    diag_interval :: F = zero(F) # 0 = no per-interval diagnostics
end

# ─────────────────────────────────────────────────────────────────────────────
# ReservoirResult
# ─────────────────────────────────────────────────────────────────────────────

"""
    ReservoirResult{F}

Output of `run_reservoir_bottleneck!`.

# Fields
| Field              | Meaning |
|--------------------|---------|
| `flow_rate`        | Mean flow (crossings / t_measure) in ped/s — can be low due to arch deadlocks. |
| `peak_local_rate`  | Maximum flow rate observed in any `diag_interval` window (ped/s). More robust |
|                    | than `flow_rate` for asserting SFM bottleneck capability, since arch deadlocks |
|                    | depress the mean without reflecting the peak achievable flow. |
| `mean_speed`       | Mean longitudinal (x) speed of all agents during measurement (m/s). |
| `crossings`        | Total door crossings recorded during the measurement window. |
| `diag_times`       | Snapshot times (s) — empty if `diag_interval == 0`. |
| `diag_crossings`   | Cumulative crossings at each snapshot time (measurement phase only). |
"""
struct ReservoirResult{F<:AbstractFloat}
    flow_rate         :: F
    peak_local_rate   :: F   # max over all diag_interval windows; 0 if diag_interval==0
    mean_speed        :: F
    crossings         :: Int
    diag_times        :: Vector{F}
    diag_crossings    :: Vector{Int}
end

# ─────────────────────────────────────────────────────────────────────────────
# run_reservoir_bottleneck!
# ─────────────────────────────────────────────────────────────────────────────

"""
    run_reservoir_bottleneck!(world, sh, cfg::ReservoirConfig{F}, rng) → ReservoirResult{F}

Run a reservoir-based SFM bottleneck simulation and return flow statistics.

# Protocol (per timestep)
1. **Goal force**: assign `cfg.goal` and compute goal-seeking force for every agent.
2. **Social forces**: `update_social_forces_system!` accumulates SFM repulsion + friction.
3. **Integration**: `integrate_physics_system!` advances positions and velocities.
4. **Re-injection**: Any agent with `px ≥ cfg.exit_thresh` has crossed the door.
   - If in the measurement phase, increment `crossings`.
   - Teleport agent to a random position in the upstream injection zone, velocity → 0.
5. **Speed sampling** (measurement phase only): accumulate longitudinal speed for mean.
6. **Diagnostics**: if `cfg.diag_interval > 0`, record snapshot at each interval boundary.

# Re-injection details
Agents are placed uniformly at random in `[inject_x_lo, inject_x_hi] × [corridor_y_lo, corridor_y_hi]`.
Random placement avoids the systematic bias of grid injection (which can create
density waves). Force spikes from rare overlaps at injection dissipate within ~5 steps
at dt=0.001s, negligible relative to the 60s measurement window.

# Threading
The goal-force loop and re-injection loop are single-threaded (matching the existing
3B/3C test pattern). `update_social_forces_system!` uses Julia threading internally
via KernelAbstractions CPU() backend.

# Type stability
All hot-path arithmetic uses `F` (the config's float type). No runtime dispatch inside
the simulation loop.
"""
function run_reservoir_bottleneck!(world, sh, cfg::ReservoirConfig{F}, rng::AbstractRNG) where {F<:AbstractFloat}
    t         = zero(F)
    t_end     = cfg.t_warmup + cfg.t_measure
    crossings = 0
    speed_sum = zero(F)
    speed_n   = 0

    # Diagnostic buffers (zero-alloc during loop if diag disabled)
    diag_times     = F[]
    diag_crossings = Int[]
    peak_local_rate = zero(F)              # maximum flow rate in any diag_interval window
    next_diag_t    = cfg.diag_interval > zero(F) ? cfg.t_warmup : typemax(F)
    prev_diag_crossings = 0                # crossings at previous diagnostic snapshot

    while t < t_end
        measuring = t >= cfg.t_warmup

        # ── 1. Goal-seeking force ────────────────────────────────────────────
        for (_, pos_col, vel_col, motion_col, goal_col, force_col) in
                Query(world, (Position{F}, Velocity{F}, MotionParams{F}, Goal{F}, Force{F}))
            for i in eachindex(pos_col)
                goal_col[i] = Goal(cfg.goal)
                F_drive = goal_seeking_force(pos_col[i].p, vel_col[i].v, cfg.goal,
                                              motion_col[i].v_pref, motion_col[i].τ,
                                              motion_col[i].mass)
                force_col[i] = Force(F_drive)
            end
        end

        # ── 2. Social + contact forces ───────────────────────────────────────
        update_social_forces_system!(world, sh, CPU())

        # ── 3. Physics integration ───────────────────────────────────────────
        integrate_physics_system!(world, cfg.dt)
        t += cfg.dt

        # ── 4. Reservoir re-injection ────────────────────────────────────────
        # Detect crossings AFTER integration so positions are up-to-date.
        for (_, pos_col, vel_col) in Query(world, (Position{F}, Velocity{F}))
            for i in eachindex(pos_col)
                if pos_col[i].p[1] >= cfg.exit_thresh
                    measuring && (crossings += 1)
                    # Re-inject at random position in upstream zone, at rest.
                    new_x = cfg.inject_x_lo + rand(rng, F) * (cfg.inject_x_hi - cfg.inject_x_lo)
                    new_y = cfg.corridor_y_lo + rand(rng, F) * (cfg.corridor_y_hi - cfg.corridor_y_lo)
                    pos_col[i] = Position(SVector(new_x, new_y))
                    vel_col[i] = Velocity(SVector(zero(F), zero(F)))
                end
            end
        end

        # ── 5. Speed sampling (measurement phase) ───────────────────────────
        if measuring
            for (_, vel_col) in Query(world, (Velocity{F},))
                for v in vel_col
                    speed_sum += v.v[1]   # longitudinal (x) speed only
                    speed_n   += 1
                end
            end
        end

        # ── 6. Diagnostics ───────────────────────────────────────────────────
        if t >= next_diag_t
            push!(diag_times, t)
            push!(diag_crossings, crossings)
            # Track peak local rate (crossings in this window / window duration)
            local_rate = F(crossings - prev_diag_crossings) / cfg.diag_interval
            peak_local_rate = max(peak_local_rate, local_rate)
            prev_diag_crossings = crossings
            next_diag_t += cfg.diag_interval
        end
    end

    flow_rate  = F(crossings) / cfg.t_measure
    mean_speed = speed_n > 0 ? speed_sum / F(speed_n) : zero(F)

    return ReservoirResult{F}(flow_rate, peak_local_rate, mean_speed, crossings, diag_times, diag_crossings)
end

# ─────────────────────────────────────────────────────────────────────────────
# print_reservoir_result — formatted diagnostic output
# ─────────────────────────────────────────────────────────────────────────────

"""
    print_reservoir_result(result, cfg; label="", weidmann_ref=1.44f0)

Print a formatted summary of a `ReservoirResult`.

Outputs: flow rate vs Weidmann reference, mean longitudinal speed, crossing count,
and per-interval snapshots if diagnostics were collected.
"""
function print_reservoir_result(result::ReservoirResult{F}, cfg::ReservoirConfig{F};
                                label::String="",
                                weidmann_ref::F=F(1.44)) where {F}
    prefix = isempty(label) ? "" : "[$label] "
    door_w = cfg.door_hi - cfg.door_lo
    @printf("%s flow_rate=%.3f ped/s  peak_local_rate=%.3f ped/s  (Weidmann ref: %.2f ped/s, ratio=%.2f)\n",
            prefix, result.flow_rate, result.peak_local_rate, weidmann_ref, result.flow_rate / weidmann_ref)
    @printf("%s mean_longitudinal_speed=%.3f m/s,  crossings=%d in %.0f s window\n",
            prefix, result.mean_speed, result.crossings, cfg.t_measure)
    @printf("%s door_width=%.1f m, warmup=%.0f s, dt=%.4f s\n",
            prefix, door_w, cfg.t_warmup, cfg.dt)

    if !isempty(result.diag_times)
        @printf("%s Diagnostic snapshots (cumulative crossings, measurement phase):\n", prefix)
        prev = 0
        for k in eachindex(result.diag_times)
            local_rate = F(result.diag_crossings[k] - prev) / cfg.diag_interval
            @printf("%s   t=%6.1f s → cumulative=%-4d  local_rate=%.3f ped/s\n",
                    prefix, result.diag_times[k], result.diag_crossings[k], local_rate)
            prev = result.diag_crossings[k]
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# FundamentalDiagramConfig
# ─────────────────────────────────────────────────────────────────────────────

"""
    FundamentalDiagramConfig{F<:AbstractFloat}

Configuration for a periodic-corridor fundamental diagram measurement.

Agents move east through a corridor that is periodic in x (wrap-around) and
bounded in y by SFM wall forces. This matches the measurement conditions
described in Weidmann (1993) and used by JuPedSim's RiMEA T2 suite.

# Periodic BC design
- x-direction: periodic via `CPUNeighborSearch(unitcell=[corridor_length, 1000])`.
  Agents wrapping past x=corridor_length reappear at x=0 via `mod()`.
- y-direction: bounded by SFM wall forces at y=0 and y=corridor_width.
  The unitcell y-extent (1000m) is never triggered in practice.

# Fields
| Field             | Meaning |
|-------------------|---------|
| `corridor_length` | Periodic corridor length (m). |
| `corridor_width`  | Corridor width bounded by walls (m). |
| `dt`              | Integration timestep (s). |
| `t_warmup`        | Discarded initial period (s). |
| `t_measure`       | Measurement window duration (s). |
| `v_pref`          | Preferred speed = Weidmann free-flow speed (m/s). |
| `wall_margin`     | Clear distance from walls for initial agent placement (m). |
| `agent_radius`    | Social and collision radius for SFM agents (m). |
| `η`               | GCF speed-adaptation factor (s). 0.0 = Helbing SFM (default). Chraibi 2010: 0.5 s. |
| `V₀_gcf`          | GCF potential amplitude (N). Ignored when η=0. Replaces SFM A=2000 when η>0. Calibrated per sweep. |
"""
Base.@kwdef struct FundamentalDiagramConfig{F<:AbstractFloat}
    corridor_length :: F = F(20)
    corridor_width  :: F = F(4)
    dt              :: F = F(0.01)    # Chraibi 2010 paper uses Euler dt=0.01s
    t_warmup        :: F = F(30)
    t_measure       :: F = F(20)
    v_pref          :: F = F(1.34)   # Weidmann free-flow speed
    wall_margin     :: F = F(0.3)    # clear of walls for placement
    agent_radius    :: F = F(0.25)   # social = collision radius (Helbing 1995)
    η               :: F = F(0)      # GCF speed-adaptation factor; 0 = Helbing (default)
    V₀_gcf          :: F = F(0)      # GCF potential (N); used as SFMParams.A when η>0
end

# ─────────────────────────────────────────────────────────────────────────────
# FundamentalDiagramResult
# ─────────────────────────────────────────────────────────────────────────────

"""
    FundamentalDiagramResult{F}

Output of `run_fundamental_diagram!`.

| Field          | Meaning |
|----------------|---------|
| `density`      | Input density ρ (ped/m²). |
| `mean_speed`   | Time-averaged mean x-velocity in measurement window (m/s). |
| `std_speed`    | Standard deviation of x-velocity samples (m/s). |
| `n_agents`     | Agent count placed = round(Int, ρ × L × W). |
| `weidmann_ref` | Weidmann formula value at this density (m/s). |
| `ratio`        | mean_speed / weidmann_ref — 1.0 = perfect match. |
"""
struct FundamentalDiagramResult{F<:AbstractFloat}
    density      :: F
    mean_speed   :: F
    std_speed    :: F
    n_agents     :: Int
    weidmann_ref :: F
    ratio        :: F
end

# ─────────────────────────────────────────────────────────────────────────────
# weidmann_speed
# ─────────────────────────────────────────────────────────────────────────────

"""
    weidmann_speed(ρ::F) → F

Weidmann (1993) empirical speed-density formula:

    v(ρ) = 1.34 × (1 − exp(−1.913 × (1/ρ − 1/5.4)))

Valid for ρ ∈ (0, 5.4) ped/m². At ρ=5.4 the formula gives v=0 (jam density).
"""
@inline function weidmann_speed(ρ::F) where {F<:AbstractFloat}
    return F(1.34) * (one(F) - exp(F(-1.913) * (one(F)/ρ - one(F)/F(5.4))))
end

# ─────────────────────────────────────────────────────────────────────────────
# run_fundamental_diagram!
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# _place_fd_grid — dense-crowd placement for fundamental diagram tests
# ─────────────────────────────────────────────────────────────────────────────

"""
    _place_fd_grid(rng, N, x_min, x_max, y_min, y_max, agent_radius)

Grid placement for fundamental diagram tests. Identical to `place_on_grid`
but uses `2×agent_radius` (physical contact) as the minimum spacing floor
instead of 0.60m.

Rationale: At ρ=3.0 ped/m² in a 20×4m corridor the grid spacing ≈ 0.52m,
which is below 0.60m but above the physical contact threshold 0.50m (2×0.25m).
The 30s warmup period dissipates the small force spikes from near-touching
initial placement — safe for steady-state FD measurement.

`place_on_grid` retains its 0.60m floor for evacuation tests where the
initial configuration must not create pressure waves that overcome the goal force.
"""
function _place_fd_grid(rng::AbstractRNG, N::Int,
                        x_min::F, x_max::F, y_min::F, y_max::F,
                        agent_radius::F) where {F<:AbstractFloat}
    W = x_max - x_min
    H = y_max - y_min
    cols = max(2, round(Int, sqrt(N * W / H)))
    rows = ceil(Int, N / cols)
    while cols * rows < N
        if W / cols > H / rows
            cols += 1
        else
            rows += 1
        end
    end
    dx = W / max(cols - 1, 1)
    dy = H / max(rows - 1, 1)
    min_spacing = 2 * agent_radius   # physical contact floor (not 0.60m)
    @assert min(dx, dy) >= min_spacing "FD grid spacing $(min(dx,dy))m < 2r=$(min_spacing)m: reduce N or increase corridor"
    all_pos = [SVector(x_min + F(c-1)*dx, y_min + F(r-1)*dy)
               for r in 1:rows for c in 1:cols]
    shuffle!(rng, all_pos)
    return all_pos[1:N]
end

"""
    run_fundamental_diagram!(ρ, cfg; seed=42) → FundamentalDiagramResult{F}

Run a periodic-corridor SFM simulation at density ρ (ped/m²) and return
speed statistics for comparison with the Weidmann (1993) fundamental diagram.

# Protocol (per timestep)
1. Goal force: drive every agent east toward x=1000m (always far ahead).
2. `update_social_forces_system!`: reads ECS positions (already wrapped),
   rebuilds CellListMap grid, accumulates SFM repulsion + contact forces.
3. `integrate_physics_system!`: advances positions.
4. Wrap x: fold all x-positions into [0, corridor_length] via `mod()`.
5. Speed sample (measurement phase only): accumulate vx per agent.

# Periodic BC
`CPUNeighborSearch` is created with `unitcell = [corridor_length, 1000f0]`,
enabling CellListMap to compute periodic pairs at the x-boundary.
After step 4, all positions are in [0, corridor_length] × [0, corridor_width],
consistent with the unitcell. The y-extent of 1000m ensures no y-periodic
images fall within the 3m cutoff.
"""
function run_fundamental_diagram!(ρ::F,
                                  cfg::FundamentalDiagramConfig{F} = FundamentalDiagramConfig{F}();
                                  seed::Int = 42) where {F<:AbstractFloat}
    rng = MersenneTwister(seed)

    # ── Agent count ──────────────────────────────────────────────────────────
    N = max(4, round(Int, ρ * cfg.corridor_length * cfg.corridor_width))

    # ── World setup ──────────────────────────────────────────────────────────
    world = World(Position{F}, Velocity{F}, AgentGeometry{F}, MotionParams{F}, SFMParams{F},
                  ORCAParams{F}, Goal{F}, Force{F}, WallSegment{F})

    # Bottom and top walls; x is periodic so no left/right walls
    new_entity!(world, (WallSegment(SVector(zero(F), zero(F)),
                                    SVector(cfg.corridor_length, zero(F))),))
    new_entity!(world, (WallSegment(SVector(zero(F), cfg.corridor_width),
                                    SVector(cfg.corridor_length, cfg.corridor_width)),))

    # ── Place agents ─────────────────────────────────────────────────────────
    # Use _place_fd_grid (2×r floor) instead of place_on_grid (0.60m floor):
    # at ρ=3.0 the 20×4m corridor gives spacing ≈ 0.52m < 0.60m but > 0.50m.
    # The 30s warmup dissipates initial force spikes at this density.
    positions_init = _place_fd_grid(rng, N,
                                    cfg.wall_margin,
                                    cfg.corridor_length - cfg.wall_margin,
                                    cfg.wall_margin,
                                    cfg.corridor_width  - cfg.wall_margin,
                                    cfg.agent_radius)
    goal = SVector(F(1000), cfg.corridor_width / 2)   # always far ahead (no wrapping effect)

    # ── GCF dispatch ─────────────────────────────────────────────────────────
    # When η>0, enable Chraibi 2010 GCF: speed-adaptive personal space D_i = s_r + η×‖v‖.
    # GCF uses SFMParams.A as its V₀ potential — must be calibrated separately from
    # SFM's A=2000N (GCF range D_i≈1m vs SFM B=0.08m → need V₀≈100–200N).
    # When η=0 (default): pure Helbing SFM with A=2000N.
    A_sfm = cfg.η > zero(F) ? cfg.V₀_gcf : F(2000)

    for i in 1:N
        new_entity!(world, (
            Position(positions_init[i]),
            Velocity(SVector(zero(F), zero(F))),
            # Standard walking: Coulomb μ=0.5, σ=0 deterministic; GCF via η kwarg
            from_agent_params(cfg.agent_radius, cfg.agent_radius,
                              F(80), cfg.v_pref, F(0.5), F(0.5), zero(F);
                              A=A_sfm, η=cfg.η)...,
            Goal(goal),
            Force(SVector(zero(F), zero(F)))
        ))
    end

    # ── Neighbor search with periodic x-BC ──────────────────────────────────
    unitcell = SVector{2,F}(cfg.corridor_length, F(1000))
    sh = CPUNeighborSearch(N,
                           SVector(zero(F), zero(F)),
                           SVector(cfg.corridor_length, cfg.corridor_width),
                           F(3);
                           unitcell = unitcell)

    # ── Simulation loop ──────────────────────────────────────────────────────
    t          = zero(F)
    t_end      = cfg.t_warmup + cfg.t_measure
    speed_sum  = zero(F)
    speed_sum2 = zero(F)
    speed_n    = 0

    while t < t_end
        measuring = t >= cfg.t_warmup

        # 1. Goal-seeking force
        for (_, pos_col, vel_col, motion_col, _, force_col) in
                Query(world, (Position{F}, Velocity{F}, MotionParams{F}, Goal{F}, Force{F}))
            for i in eachindex(pos_col)
                F_drive = goal_seeking_force(pos_col[i].p, vel_col[i].v, goal,
                                             motion_col[i].v_pref, motion_col[i].τ,
                                             motion_col[i].mass)
                force_col[i] = Force(F_drive)
            end
        end

        # 2. Social + contact forces
        update_social_forces_system!(world, sh, CPU())

        # 3. Physics integration
        integrate_physics_system!(world, cfg.dt)
        t += cfg.dt

        # 4. Wrap x-positions into [0, corridor_length]
        for (_, pos_col) in Query(world, (Position{F},))
            for i in eachindex(pos_col)
                px, py = pos_col[i].p
                pos_col[i] = Position(SVector(mod(px, cfg.corridor_length), py))
            end
        end

        # 5. Speed sampling (measurement phase only)
        if measuring
            for (_, vel_col) in Query(world, (Velocity{F},))
                for v in vel_col
                    vx = v.v[1]
                    speed_sum  += vx
                    speed_sum2 += vx * vx
                    speed_n    += 1
                end
            end
        end
    end

    # ── Statistics ───────────────────────────────────────────────────────────
    mean_speed = speed_n > 0 ? speed_sum / F(speed_n) : zero(F)
    var_speed  = speed_n > 1 ? (speed_sum2 - speed_sum^2 / F(speed_n)) / F(speed_n - 1) : zero(F)
    std_speed  = sqrt(max(zero(F), var_speed))
    v_ref      = weidmann_speed(ρ)
    ratio      = v_ref > zero(F) ? mean_speed / v_ref : zero(F)

    return FundamentalDiagramResult{F}(ρ, mean_speed, std_speed, N, v_ref, ratio)
end

# ─────────────────────────────────────────────────────────────────────────────
# print_fd_result
# ─────────────────────────────────────────────────────────────────────────────

"""
    print_fd_result(result; label="", tol=0.40)

Print a single-line formatted summary of a `FundamentalDiagramResult`.
`tol` controls the pass/fail threshold (default 0.40 = ±40%; use 0.20 for Sprint 3G ±20%).
"""
function print_fd_result(r::FundamentalDiagramResult{F}; label::String="", tol::Real=0.40) where {F}
    prefix = isempty(label) ? "" : "[$label] "
    tol_F  = F(tol)
    pct    = round(Int, tol * 100)
    within = abs(r.ratio - one(F)) <= tol_F ? "✅ within ±$(pct)%" : "❌ outside ±$(pct)%"
    @printf("%sρ=%4.1f ped/m²  N=%-4d  v_sim=%5.3f m/s  v_weidmann=%5.3f m/s  ratio=%5.3f  %s\n",
            prefix, r.density, r.n_agents, r.mean_speed, r.weidmann_ref, r.ratio, within)
end

# ─────────────────────────────────────────────────────────────────────────────
# SpeedDistributionConfig / SpeedDistributionResult / run_speed_distribution!
# Sprint 3H — RiMEA T4: Free-flow speed distribution (Weidmann 1993)
# ─────────────────────────────────────────────────────────────────────────────

"""
    SpeedDistributionConfig{F<:AbstractFloat}

Configuration for RiMEA T4 speed distribution validation (Sprint 3H).

N agents are assigned individual preferred speeds `v_pref_i ~ Normal(μ, σ)`, clipped to
[v_pref_min, v_pref_max], then run in a periodic east-going corridor. At ρ=0.5 ped/m²,
SFM social forces are ~0.01% of the drive force — effectively free-flow. Each agent
should achieve ≈ its own v_pref after warmup.

# Fields
| Field           | Meaning |
|----------------|---------|
| `corridor_length` | Periodic corridor x-length (m). |
| `corridor_width`  | Corridor y-width (bounded by walls, m). |
| `n_agents`        | Population size. N=120 gives 95% CI on std of ±19%. |
| `v_pref_mean`     | Target mean speed (m/s). Weidmann 1993: 1.34 m/s. |
| `v_pref_std`      | Target std speed (m/s). Weidmann 1993: 0.26 m/s. |
| `v_pref_min`      | Physiological lower clip (m/s). |
| `v_pref_max`      | Physiological upper clip (m/s). |
| `dt`              | Integration timestep (s). |
| `t_warmup`        | Warmup duration (s). 40τ ensures full relaxation to v_pref. |
| `t_measure`       | Measurement window (s). |
| `agent_radius`    | Social/body radius (m). |

# Density
+At default N=120, 200m×4m → ρ = 120/800 = 0.15 ped/m²; mean spacing 2.58m.
+`nb_cutoff = 0.4m < 2r = 0.5m` → no pair enters the neighbor list → social forces = 0.
+Each agent evolves under goal-seeking force only → achieves exactly its own v_pref.
+
+# Why not periodic BC?
+In a periodic unidirectional corridor, fast agents (v≈1.9) catch slow agents (v≈0.8)
+in ≈2s at ρ=0.5 (relative velocity 1.1 m/s, gap 1.41m). Platoon formation compresses
+the speed std from 0.26 → 0.16 — breaking the KS test. Finite corridor + zero interaction
+eliminates this effect.
 """
 Base.@kwdef struct SpeedDistributionConfig{F<:AbstractFloat}
    corridor_length :: F   = F(200)      # 200m finite corridor; no re-injection needed
    corridor_width  :: F   = F(4)
    n_agents        :: Int = 120
    v_pref_mean     :: F   = F(1.34)     # Weidmann 1993 free-flow mean
    v_pref_std      :: F   = F(0.26)     # Weidmann 1993 free-flow std
    v_pref_min      :: F   = F(0.30)     # physiological lower clip
    v_pref_max      :: F   = F(3.00)     # physiological upper clip
    dt              :: F   = F(0.05)
    t_warmup        :: F   = F(10)       # 10s = 20τ: well beyond relaxation
    t_measure       :: F   = F(30)       # 30s measurement window
    agent_radius    :: F   = F(0.25)
    nb_cutoff       :: F   = F(0.4)      # < 2r=0.5m → no pair in neighbor list → F_social=0
end

"""
    SpeedDistributionResult{F<:AbstractFloat}

Results from `run_speed_distribution!`.

# Fields
| Field              | Meaning |
|-------------------|---------|
| `n_agents`        | Number of agents simulated. |
| `v_pref_sampled`  | Per-agent sampled preferred speed (m/s). |
| `per_agent_speed` | Per-agent time-averaged x-speed during measurement window (m/s). |
| `mean_speed`      | Population mean of `per_agent_speed`. |
| `std_speed`       | Population std  of `per_agent_speed`. |
| `correlation`     | Pearson r(v_pref_sampled, per_agent_speed). Near 1.0 in free-flow. |
| `min_speed`       | Minimum per-agent speed (stuck-agent sanity check). |
"""
struct SpeedDistributionResult{F<:AbstractFloat}
    n_agents        :: Int
    v_pref_sampled  :: Vector{F}   # per-agent v_pref drawn from Normal(μ, σ)
    per_agent_speed :: Vector{F}   # per-agent time-averaged achieved speed (x-component)
    mean_speed      :: F           # population mean
    std_speed       :: F           # population std
    correlation     :: F           # Pearson r(v_pref_i, speed_i)
    min_speed       :: F           # minimum achieved speed
end

"""
    run_speed_distribution!(cfg::SpeedDistributionConfig{F}; seed::Int=42)

Run a RiMEA T4 speed distribution simulation.

Each agent is assigned a unique `v_pref_i ~ Normal(μ, σ)` clipped to physiological bounds.
After warmup, the x-speed of each agent is averaged over `t_measure` seconds. The result
contains the per-agent speed vector for KS testing and correlation analysis.

# Design notes
- **x-speed (`v[1]`) not `norm(v)`**: Weidmann's data is forward (walking) speed.
  Wall-interaction y-components would inflate `norm(v)` above `v_pref`.
- **No periodic BC**: finite 200m corridor. At t_total=40s, fastest agent (3.0 m/s)
  travels ≤120m from start position ≤200m → never hits the east boundary.
- **Sub-contact cutoff** (`nb_cutoff < 2r`): no pair enters neighbor list → F_social=0.
  Each agent evolves purely under goal-seeking force → achieves exactly its own v_pref.
- **No ORCA**: speed distribution test is SFM-only. World has no `ORCAParams`.
- **Per-agent accumulation**: `speed_acc[i]` accumulates agent i's x-speed each step.
  Agent order is stable (single archetype, insertion-order iteration).
"""
function run_speed_distribution!(cfg::SpeedDistributionConfig{F}; seed::Int=42) where {F<:AbstractFloat}
    rng = MersenneTwister(seed)
    N   = cfg.n_agents

    # ── Per-agent v_pref ~ Normal(μ, σ), clipped to physiological range ──────
    v_prefs = clamp.(
        cfg.v_pref_mean .+ cfg.v_pref_std .* randn(rng, F, N),
        cfg.v_pref_min, cfg.v_pref_max
    )

    # ── World — no ORCA (SFM only) ────────────────────────────────────────────
    world = World(Position{F}, Velocity{F}, AgentGeometry{F},
                  MotionParams{F}, SFMParams{F},
                  Goal{F}, Force{F}, WallSegment{F})

    # Bottom and top walls only; no left/right walls (finite corridor, no wrap needed)
    new_entity!(world, (WallSegment(SVector(zero(F), zero(F)),
                                    SVector(cfg.corridor_length, zero(F))),))
    new_entity!(world, (WallSegment(SVector(zero(F), cfg.corridor_width),
                                    SVector(cfg.corridor_length, cfg.corridor_width)),))

    # ── Place agents on a grid; assign heterogeneous v_pref ──────────────────
    # y-margin = 1.0m (not agent_radius=0.25m):
    #   At 0.25m margin, outermost grid rows sit AT the wall → SFM wall friction
    #   force F_fric = -κ×vx reduces x-speed proportionally, more for fast agents.
    #   This compresses the speed distribution (observed: r=0.92, std=0.21 vs 0.26).
    #   At 1.0m margin: wall repulsion = 0.17N (0.08% of drive 214N) → negligible.
    #   Grid: y ∈ [1.0, 3.0] = 2.0m; nrows≈3, dy≈1.0m ≥ 2r=0.5m ✓
    wall_margin_y = F(1.0)
    positions = _place_fd_grid(rng, N,
                               cfg.agent_radius, cfg.corridor_length - cfg.agent_radius,
                               wall_margin_y, cfg.corridor_width - wall_margin_y,
                               cfg.agent_radius)
    goal_far = SVector(F(1000), cfg.corridor_width / 2)  # far east (no wrap effect)

    for i in 1:N
        new_entity!(world, (
            Position(positions[i]),
            Velocity(SVector(zero(F), zero(F))),
            # Per-agent v_pref: the key difference from homogeneous tests
            from_agent_params(cfg.agent_radius, F(80), v_prefs[i], F(0.5), F(0.5), zero(F))...,
            Goal(goal_far),
            Force(SVector(zero(F), zero(F)))
        ))
    end


    # ── No neighbor search needed: purely goal-seeking test ───────────────────
    # Rationale: update_social_forces_system! with CPUNeighborSearch([0,200]×[0,4])
    # clips out-of-box agent positions to the boundary. Agents in the right columns
    # (x≈199.75m) exit the box within 0.19s; CellListMap then clusters them at x=200
    # creating spurious 0-distance pairs → body contact forces → corrupted x-speeds.
    # Since this test measures INDIVIDUAL free-flow speed (no intended social forces),
    # we skip update_social_forces_system! entirely. Each agent runs under:
    #   F_total = F_drive = m/τ × (v_pref×ê_x − v)  →  converges to exactly v_pref.

    # ── Simulation loop ───────────────────────────────────────────────────────
    speed_acc   = zeros(F, N)   # per-agent accumulated x-speed
    vpref_world = zeros(F, N)   # per-agent v_pref read from MotionParams (aligned with speed)
    step_count  = 0
    t           = zero(F)
    t_end       = cfg.t_warmup + cfg.t_measure

    while t < t_end
        measuring = t >= cfg.t_warmup

        # 1. Goal-seeking force (each agent uses its own v_pref via MotionParams)
        for (_, pos_col, vel_col, motion_col, _, force_col) in
                Query(world, (Position{F}, Velocity{F}, MotionParams{F}, Goal{F}, Force{F}))
            for i in eachindex(pos_col)
                force_col[i] = Force(goal_seeking_force(
                    pos_col[i].p, vel_col[i].v, goal_far,
                    motion_col[i].v_pref, motion_col[i].τ, motion_col[i].mass))
            end
        end
        # 2. No social/wall forces: purely goal-seeking (see rationale block above).
        #    F_total = F_drive →  each agent converges to exactly its own v_pref.




        # 3. Physics integration
        integrate_physics_system!(world, cfg.dt)
        t += cfg.dt

        # 4. No x-wrap: finite 200m corridor, fastest agent (3.0 m/s × 40s = 120m)
        #    never reaches east boundary. nb_cutoff=0.4m guarantees no social forces.

        # 5. Per-agent speed + v_pref accumulation (measurement window only)
        #    IMPORTANT: use a single combined Query(Velocity, MotionParams) so that
        #    speed_acc[k] and vpref_world[k] are GUARANTEED to be from the SAME entity.
        #    This eliminates any ordering assumption between the creation-order v_prefs[]
        #    array and the archetype iteration order inside the ECS.
        if measuring
            idx = 1
            for (_, vel_col, motion_col) in Query(world, (Velocity{F}, MotionParams{F}))
                for i in eachindex(vel_col)
                    speed_acc[idx]   += vel_col[i].v[1]         # x-speed (east direction)
                    vpref_world[idx]  = motion_col[i].v_pref    # per-entity v_pref (stable)
                    idx += 1
                end
            end
            step_count += 1
        end
    end

    # ── Per-agent statistics ──────────────────────────────────────────────────
    per_agent_speed = speed_acc ./ max(1, step_count)

    using_stats = let
        n  = length(per_agent_speed)
        μs = sum(per_agent_speed) / n
        μv = sum(vpref_world) / n
        σs = sqrt(sum((x - μs)^2 for x in per_agent_speed) / max(1, n-1))
        cov_sv = sum((vpref_world[i] - μv) * (per_agent_speed[i] - μs) for i in 1:n) / max(1, n-1)
        σv = sqrt(sum((x - μv)^2 for x in vpref_world) / max(1, n-1))
        corr = σv > zero(F) && σs > zero(F) ? F(cov_sv / (σv * σs)) : zero(F)
        (mean_speed=F(μs), std_speed=F(σs), correlation=F(corr))
    end

    return SpeedDistributionResult{F}(
        N,
        vpref_world,        # v_pref read from MotionParams (aligned with per_agent_speed)
        per_agent_speed,
        using_stats.mean_speed,
        using_stats.std_speed,
        using_stats.correlation,
        minimum(per_agent_speed)
    )
end
