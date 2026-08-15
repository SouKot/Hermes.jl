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
| Field          | Meaning |
|----------------|---------|
| `flow_rate`    | Steady-state flow (crossings / t_measure) in ped/s. |
| `mean_speed`   | Mean longitudinal (x) speed of all agents during measurement (m/s). |
| `crossings`    | Total door crossings recorded during the measurement window. |
| `diag_times`   | Snapshot times (s) — empty if `diag_interval == 0`. |
| `diag_crossings`| Cumulative crossings at each snapshot time (measurement phase only). |
"""
struct ReservoirResult{F<:AbstractFloat}
    flow_rate      :: F
    mean_speed     :: F
    crossings      :: Int
    diag_times     :: Vector{F}
    diag_crossings :: Vector{Int}
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
    next_diag_t    = cfg.diag_interval > zero(F) ? cfg.t_warmup : typemax(F)

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
            next_diag_t += cfg.diag_interval
        end
    end

    flow_rate  = F(crossings) / cfg.t_measure
    mean_speed = speed_n > 0 ? speed_sum / F(speed_n) : zero(F)

    return ReservoirResult{F}(flow_rate, mean_speed, crossings, diag_times, diag_crossings)
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
    @printf("%s flow_rate=%.3f ped/s  (Weidmann ref: %.2f ped/s, ratio=%.2f)\n",
            prefix, result.flow_rate, weidmann_ref, result.flow_rate / weidmann_ref)
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
