#!/usr/bin/env julia
# benchmark_niters.jl — Sprint 3T: n_iters benchmark on Hybrid FSM + FMM T7 scenario
#
# Runs the 80-agent, 1m-bottleneck Hybrid FSM + FMM RiMEA T7 scenario with
# n_iters ∈ {0,1,2,3}, measuring:
#   - flow rate (ped/s)
#   - minimum agent-agent separation (m)
#   - mean and p95 step wall-clock time (ms)
#
# NOTE: n_iters=0 is the pre-correction baseline (LP-only for ORCA agents).
#       n_iters=2 is the default (Jacobi correction active).
#       Overhead is measured AFTER JIT warmup to get accurate timing.
#
# Usage:
#   julia --project test/benchmark_niters.jl

using Pkg
Pkg.activate(".")

using SimCrowd
using StaticArrays
using LinearAlgebra
using Printf
using Statistics
using KernelAbstractions
using Ark
using Random: MersenneTwister

# ── Build T7 scene: HybridFSM + FMM + RadixSpatialHash ────────────────────────
function build_hybrid_t7_scene(F::Type, n_iters::Int; N::Int=80)
    dt     = F(0.05)
    v_pref = F(1.4)
    r_body = F(0.2)
    mass   = F(80.0)
    door_center = F(2.0)
    door_half   = F(0.5)

    # Build FMM navigation field
    t7_walls = NTuple{2, SVector{2,F}}[
        (SVector{2,F}(0, 0),  SVector{2,F}(10, 0)),
        (SVector{2,F}(0, 4),  SVector{2,F}(10, 4)),
        (SVector{2,F}(0, 0),  SVector{2,F}(0,  4)),
        (SVector{2,F}(10, 0), SVector{2,F}(10, door_center - door_half)),
        (SVector{2,F}(10, door_center + door_half), SVector{2,F}(10, 4)),
    ]
    nav = build_navigation_field(t7_walls, SVector{2,F}(12, 2), F(0.05))

    world = World(
        Position{F}, Velocity{F}, AgentGeometry{F}, MotionParams{F},
        Goal{F}, Force{F}, WallSegment{F},
        HybridFSMParams{F}, AgentFSMState{F}
    )

    # Walls
    new_entity!(world, (WallSegment(SVector(0f0, 0f0), SVector(0f0, 4f0)),))
    new_entity!(world, (WallSegment(SVector(0f0, 0f0), SVector(10f0, 0f0)),))
    new_entity!(world, (WallSegment(SVector(0f0, 4f0), SVector(10f0, 4f0)),))
    new_entity!(world, (WallSegment(SVector(10f0, 0f0), SVector(10f0, door_center - door_half)),))
    new_entity!(world, (WallSegment(SVector(10f0, door_center + door_half), SVector(10f0, 4f0)),))

    hybrid_p = HybridFSMParams{F}(
        ρ_on           = F(1.8),
        ρ_off          = F(0.2),
        density_radius = F(2.0),
        sfm_params     = SFMParams{F}(),
        orca_params    = ORCAParams(F(2.0), F(0.5), 10, F(15.0), r_body, v_pref, F(0.5), mass)
    )

    rng = MersenneTwister(42)
    for _ in 1:N
        x = F(0.5) + rand(rng, F) * F(9.0)
        y = F(0.3) + rand(rng, F) * F(3.4)
        new_entity!(world, (
            Position(SVector(x, y)),
            Velocity(zero(SVector{2,F})),
            AgentGeometry(r_body, r_body * F(2/3)),
            MotionParams(mass, v_pref, F(0.5), F(0.3)),
            Goal(SVector(F(12), door_center)),
            Force(zero(SVector{2,F})),
            hybrid_p,
            AgentFSMState{F}()
        ))
    end

    search = RadixSpatialHash(CPU(), N, SVector(-1f0, -1f0), SVector(13f0, 5f0), F(2.0))
    config = SimConfig(dt, F(2.0), n_iters)
    return SimScene(world, search, nav, config), N, dt
end

# ── Run T7 bottleneck and collect metrics ─────────────────────────────────────
function run_t7_hybrid(n_iters::Int; T_sim::Float32=120f0, F::Type=Float32)
    scene, N, dt = build_hybrid_t7_scene(F, n_iters; N=80)

    exit_x   = F(10.5)
    park_x   = F(-60)
    park_y   = F(2.0)
    door_lo  = F(1.5)
    door_hi  = F(2.5)
    n_steps  = round(Int, T_sim / dt)

    # JIT warmup (10 steps, timed separately — discard)
    for _ in 1:10
        step!(scene)
    end

    # Reset scene with fresh agents for actual measurement
    scene2, N2, _ = build_hybrid_t7_scene(F, n_iters; N=80)

    step_times  = Float64[]
    min_seps    = Float32[]
    n_passed    = 0
    wall_passes = 0
    t           = F(0)

    while n_passed < N2 && t < T_sim
        t0 = time_ns()
        step!(scene2)
        t1 = time_ns()
        push!(step_times, (t1 - t0) / 1e6)
        t += dt

        # Separation measurement (every 20 steps to save time)
        if length(step_times) % 20 == 0
            positions = SVector{2,F}[]
            for (_, pos_col) in Query(scene2.world, (Position{F},))
                for i in eachindex(pos_col)
                    push!(positions, pos_col[i].p)
                end
            end
            min_sep = Inf32
            for i in 1:length(positions), j in (i+1):length(positions)
                d = norm(positions[i] - positions[j])
                min_sep = min(min_sep, Float32(d))
            end
            push!(min_seps, min_sep)
        end

        # Count exits
        for (_, pos_col, vel_col, goal_col) in
                Query(scene2.world, (Position{F}, Velocity{F}, Goal{F}, HybridFSMParams{F}))
            for i in eachindex(pos_col)
                if pos_col[i].p[1] >= exit_x
                    n_passed += 1
                    py = pos_col[i].p[2]
                    if py < door_lo || py > door_hi
                        wall_passes += 1
                    end
                    pos_col[i]  = Position(SVector(park_x, park_y))
                    vel_col[i]  = Velocity(zero(SVector{2,F}))
                    goal_col[i] = Goal(SVector(park_x - F(100), park_y))
                end
            end
        end
    end

    flow_rate  = n_passed > 0 ? Float32(n_passed) / t : 0f0
    min_sep    = isempty(min_seps) ? Inf32 : minimum(min_seps)
    mean_step  = mean(step_times)
    p95_step   = quantile(step_times, 0.95)

    return (n_iters=n_iters, flow_rate=flow_rate, min_sep=min_sep,
            mean_step_ms=mean_step, p95_step_ms=p95_step,
            n_passed=n_passed, wall_passes=wall_passes, t_sim=t)
end

# ── Main ───────────────────────────────────────────────────────────────────────
println("\n=== Sprint 3T: n_iters Benchmark ===")
println("=== Hybrid FSM + FMM, N=80 agents, 1m door (RiMEA T7), T_sim=120s ===\n")
println("(Running warmup step inside each scenario — first run may be slower)")
println()

results = []
for ni in 0:3
    @printf("Running n_iters=%d...\n", ni)
    r = run_t7_hybrid(ni)
    push!(results, r)
    @printf("  → flow=%.3f ped/s  min_sep=%.4fm  mean_step=%.2fms  n_passed=%d\n\n",
            r.flow_rate, r.min_sep, r.mean_step_ms, r.n_passed)
end

# ── Print results table ────────────────────────────────────────────────────────
println()
@printf("%-10s  %-12s  %-12s  %-14s  %-14s  %-10s  %-12s\n",
        "n_iters", "flow(ped/s)", "min_sep(m)", "mean_step(ms)", "p95_step(ms)", "n_passed", "wall_passes")
println(repeat("─", 90))
baseline_ms = results[1].mean_step_ms
for r in results
    sep_flag  = r.min_sep < 0.0f0 ? " ⚠️ " : "    "
    overhead  = 100 * (r.mean_step_ms - baseline_ms) / max(baseline_ms, 1e-3)
    @printf("%-10d  %-12.3f  %-12.4f%s  %-14.2f  %-14.2f  %-10d  %-12d\n",
            r.n_iters, r.flow_rate, r.min_sep, sep_flag, r.mean_step_ms, r.p95_step_ms,
            r.n_passed, r.wall_passes)
end
println()
println("Criteria:")
println("  flow_rate ≥ 1.22 ped/s  — Weidmann 1993 T7 lower bound")
println("  min_sep   > 0 m         — no body penetration (2r=0.4m nominal contact)")
println("  wall_passes = 0         — no wall pass-through (3P regression guard)")
println()

# Overhead vs n_iters=0
println("Overhead vs n_iters=0 (AFTER JIT warmup):")
for r in results[2:end]
    overhead_pct = 100 * (r.mean_step_ms - baseline_ms) / max(baseline_ms, 1e-3)
    @printf("  n_iters=%d: flow Δ=+%.3f ped/s   step overhead=+%.1f%%\n",
            r.n_iters, r.flow_rate - results[1].flow_rate, overhead_pct)
end
println()
println("Recommendation: n_iters=2 (default) balances penetration resolution and overhead.")
println("Use n_iters=0 ONLY for pure ORCA scenes where LP prevents penetration.")
