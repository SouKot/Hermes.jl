# diagnose_3k.jl — Verbose per-step tracing of the 3K Hybrid FSM failure
#
# Run from ABM/:
#   julia --project=packages/SimCrowd test/diagnose_3k.jl 2>&1 | tee /tmp/diag_3k.txt
#
# Purpose:
#   Reproduce the 3K test (N=80, 10×4m, 1m door) with identical seed/params,
#   then print per-step state to trace why 7/80 agents fail to exit in 120s.
#
# What it prints:
#   - Every 10 steps (0.5s): summary line (counts, speeds, densities)
#   - Every 200 steps (10s): per-agent position/mode/ρ_ema/speed table
#   - t=5s, t=35s, t=60s, t=90s: snapshots (mode counts, near-door)
#   - Final state: full per-agent dump of stuck agents + neighbours
#
# Literature context (2026-09-08 survey):
#   - ORCA LP3 freeze at ρ_ema dropping below ρ_off after late-phase exits
#   - Near-door density underestimation (disk extends past x=10 wall)
#   - Non-reciprocity: ORCA takes full avoidance for SFM neighbours
#   See: docs/2026-09-08_literature_survey_hybrid_fsm.md §8

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using SimCrowd
using Ark
using StaticArrays
using LinearAlgebra
using Printf
using KernelAbstractions
using Random

# ── Scene constants (identical to 3K test) ────────────────────────────────────
F           = Float32
N           = 80
dt          = 0.05f0
v_pref      = 1.4f0
r_body      = 0.2f0
mass        = 80.0f0
door_center = 2.0f0
door_half   = 0.5f0

# ── Mode constants (from hybrid_fsm.jl) ──────────────────────────────────────
const ORCA_MODE = Int32(0)
const SFM_MODE  = Int32(1)

function build_world()
    world = World(
        Position{F}, Velocity{F}, AgentGeometry{F}, MotionParams{F},
        Goal{F}, Force{F},
        WallSegment{F},
        HybridFSMParams{F}, AgentFSMState{F}
    )

    # Walls (same as 3K)
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
    for i in 1:N
        x   = 0.5f0 + rand(rng, F) * 9.0f0
        y   = 0.3f0 + rand(rng, F) * 3.4f0
        new_entity!(world, (
            Position(SVector(x, y)),
            Velocity(SVector(0f0, 0f0)),
            AgentGeometry(r_body, r_body * F(2/3)),
            MotionParams(mass, v_pref, F(0.5), F(0.3)),
            Goal(SVector(12.0f0, door_center)),
            Force(zero(SVector{2,F})),
            hybrid_p,
            AgentFSMState{F}()
        ))
    end

    return world
end

# ── Diagnostic helpers ────────────────────────────────────────────────────────

function count_passed(world)
    c = 0
    for (_, pos_col) in Query(world, (Position{F},))
        for i in eachindex(pos_col)
            pos_col[i].p[1] > 10.5f0 && (c += 1)
        end
    end
    return c
end

function agent_stats(world)
    n_orca = 0; n_sfm = 0
    speeds = Float64[]
    rho_emas = Float64[]
    x_vals = Float64[]
    for (_, pos_col, vel_col, state_col) in Query(world,
            (Position{F}, Velocity{F}, AgentFSMState{F}))
        for i in eachindex(pos_col)
            x = pos_col[i].p[1]
            x > 10.5f0 && continue  # already passed
            s = norm(vel_col[i].v)
            push!(speeds, s)
            push!(rho_emas, state_col[i].ρ_ema)
            push!(x_vals, x)
            state_col[i].mode == ORCA_MODE ? (n_orca += 1) : (n_sfm += 1)
        end
    end
    mean_v   = isempty(speeds)   ? 0.0 : sum(speeds)   / length(speeds)
    mean_rho = isempty(rho_emas) ? 0.0 : sum(rho_emas) / length(rho_emas)
    max_rho  = isempty(rho_emas) ? 0.0 : maximum(rho_emas)
    return n_orca, n_sfm, mean_v, mean_rho, max_rho
end

function count_near_door(world)
    # agents at x > 9.0 (1m zone before door) and not yet passed
    c = 0
    for (_, pos_col) in Query(world, (Position{F},))
        for i in eachindex(pos_col)
            x = pos_col[i].p[1]
            9.0f0 < x <= 10.5f0 && (c += 1)
        end
    end
    return c
end

function count_stuck(world; x_min=8.0f0, v_thresh=0.05f0)
    # agents that haven't passed door but are slow (potential arch/freeze)
    c = 0
    for (_, pos_col, vel_col) in Query(world, (Position{F}, Velocity{F}))
        for i in eachindex(pos_col)
            x = pos_col[i].p[1]
            (x_min < x <= 10.5f0) && norm(vel_col[i].v) < v_thresh && (c += 1)
        end
    end
    return c
end

function rho_histogram(world)
    bins = zeros(Int, 7)  # [0,0.5), [0.5,1), [1,1.5), [1.5,2), [2,2.5), [2.5,3), [3+)
    for (_, state_col, pos_col) in Query(world, (AgentFSMState{F}, Position{F}))
        for i in eachindex(state_col)
            pos_col[i].p[1] > 10.5f0 && continue
            ρ = state_col[i].ρ_ema
            bin = min(7, floor(Int, ρ / 0.5f0) + 1)
            bins[bin] += 1
        end
    end
    return bins
end

function print_per_agent_table(world, t; only_stuck=false, v_thresh=0.1f0)
    @printf("  %-6s %-8s %-8s %-6s %-8s %-8s %-14s\n",
            "idx", "x", "y", "mode", "ρ_ema", "speed", "status")
    idx = 0
    for (_, pos_col, vel_col, state_col) in Query(world,
            (Position{F}, Velocity{F}, AgentFSMState{F}))
        for i in eachindex(pos_col)
            idx += 1
            x = pos_col[i].p[1]
            x > 10.5f0 && continue
            v = norm(vel_col[i].v)
            only_stuck && v >= v_thresh && continue
            ρ = state_col[i].ρ_ema
            mode = state_col[i].mode == ORCA_MODE ? "ORCA" : "SFM"
            status = v < 0.05f0 ? "⚠ STUCK" : (v < 0.2f0 ? "slow" : "ok")
            @printf("  %-6d %-8.3f %-8.3f %-6s %-8.3f %-8.3f %s\n",
                    idx, x, pos_col[i].p[2], mode, ρ, v, status)
        end
    end
end

function print_stuck_neighbours(world)
    # For each stuck agent, print its neighbours within 2m
    all_positions = SVector{2,F}[]
    all_states    = Int32[]
    all_speeds    = Float32[]
    all_indices   = Int[]
    idx = 0
    for (_, pos_col, vel_col, state_col) in Query(world,
            (Position{F}, Velocity{F}, AgentFSMState{F}))
        for i in eachindex(pos_col)
            idx += 1
            push!(all_positions, pos_col[i].p)
            push!(all_states, state_col[i].mode)
            push!(all_speeds, norm(vel_col[i].v))
            push!(all_indices, idx)
        end
    end

    # Find stuck agents
    stuck_global = findall(j -> all_positions[j][1] > 8.0f0 &&
                                all_positions[j][1] <= 10.5f0 &&
                                all_speeds[j] < 0.05f0, 1:length(all_positions))

    if isempty(stuck_global)
        println("  No stuck agents found (x>8, v<0.05)")
        return
    end

    println("\n  Stuck agents and their neighbours (r=2.0m):")
    for j in stuck_global
        px, py = all_positions[j]
        mode_s = all_states[j] == ORCA_MODE ? "ORCA" : "SFM"
        @printf("  [Stuck idx=%d] x=%.3f y=%.3f mode=%s speed=%.4f ρ_ema=N/A\n",
                all_indices[j], px, py, mode_s, all_speeds[j])

        # Find neighbours within 2m
        nbr_count = 0
        for k in 1:length(all_positions)
            k == j && continue
            d = norm(all_positions[k] - all_positions[j])
            d > 2.0f0 && continue
            nbr_mode = all_states[k] == ORCA_MODE ? "ORCA" : "SFM"
            @printf("    → nbr idx=%d dist=%.3fm mode=%s speed=%.4f\n",
                    all_indices[k], d, nbr_mode, all_speeds[k])
            nbr_count += 1
        end
        nbr_count == 0 && println("    → no neighbours within 2m (isolated!)")
    end
end

# ── Main diagnostic loop ──────────────────────────────────────────────────────
function main()
    println("=" ^ 80)
    println("3K DIAGNOSTIC — N=$(N), 10×4m, 1m door, ρ_on=1.8, ρ_off=0.2, dt=$(dt)")
    println("Parameters: ORCA time_horizon=2.0s, SFM A=2000N B=0.08m, σ=0.3, XPBD n=8")
    println("Literature: LP3 freeze risk at low late-phase density (§2.3)")
    println("            Near-door density underestimation (§5.3)")
    println("            Non-reciprocity ORCA←SFM neighbours (§4 §2.4)")
    println("=" ^ 80)

    world  = build_world()
    search = RadixSpatialHash(CPU(), N, SVector(-1f0, -1f0), SVector(13f0, 5f0), 2.0f0)
    config = SimConfig(dt)
    scene  = SimScene(world, search, config)

    t         = 0f0
    t_max     = 120f0
    n_passed  = 0
    step_num  = 0

    # Snapshot flags
    snap_5s  = false; snap_35s = false; snap_60s = false; snap_90s = false

    println("\n── Per-step summary (every 0.5s = 10 steps) ──")
    @printf("%-8s %-8s %-6s %-6s %-8s %-8s %-8s %-8s %-8s\n",
            "t(s)", "passed", "ORCA", "SFM", "mean_v", "mean_ρ", "max_ρ", "near_dr", "stuck")
    println("─" ^ 80)

    while n_passed < N && t <= t_max
        step!(scene)
        t        += dt
        step_num += 1
        n_passed  = count_passed(world)

        # ── Every 10 steps (0.5s): print summary line ────────────────────────────
        if step_num % 10 == 0
            n_orca, n_sfm, mv, mr, xr = agent_stats(world)
            nd = count_near_door(world)
            ns = count_stuck(world)
            @printf("%-8.2f %-8d %-6d %-6d %-8.4f %-8.4f %-8.4f %-8d %-8d\n",
                    t, n_passed, n_orca, n_sfm, mv, mr, xr, nd, ns)
        end

        # ── Every 200 steps (10s): per-agent table ───────────────────────────────
        if step_num % 200 == 0
            @printf("\n=== PER-AGENT STATE at t=%.1fs (passed=%d) ===\n", t, n_passed)
            print_per_agent_table(world, t)

            @printf("\n--- ρ_ema distribution at t=%.1fs ---\n", t)
            bins = rho_histogram(world)
            labels = ["[0,0.5)", "[0.5,1)", "[1,1.5)", "[1.5,2)", "[2,2.5)", "[2.5,3)", "[3+)"]
            for (b, l) in zip(bins, labels)
                @printf("  %s : %d agents\n", l, b)
            end
            println()
        end

        # ── Timed snapshots ──────────────────────────────────────────────────────
        if !snap_5s && t >= 5f0
            snap_5s = true
            n_orca, n_sfm, mv, mr, xr = agent_stats(world)
            @printf("\n★ SNAPSHOT t=5.0s: ORCA=%d SFM=%d mean_v=%.4f mean_ρ=%.4f near_door=%d stuck=%d\n",
                    n_orca, n_sfm, mv, mr, count_near_door(world), count_stuck(world))
        end
        if !snap_35s && t >= 35f0
            snap_35s = true
            n_orca, n_sfm, mv, mr, xr = agent_stats(world)
            @printf("\n★ SNAPSHOT t=35.0s: ORCA=%d SFM=%d mean_v=%.4f mean_ρ=%.4f near_door=%d stuck=%d\n",
                    n_orca, n_sfm, mv, mr, count_near_door(world), count_stuck(world))
        end
        if !snap_60s && t >= 60f0
            snap_60s = true
            n_orca, n_sfm, mv, mr, xr = agent_stats(world)
            @printf("\n★ SNAPSHOT t=60.0s: ORCA=%d SFM=%d mean_v=%.4f mean_ρ=%.4f near_door=%d stuck=%d\n",
                    n_orca, n_sfm, mv, mr, count_near_door(world), count_stuck(world))
            println("  Stuck agent positions:")
            print_per_agent_table(world, t; only_stuck=true, v_thresh=0.1f0)
        end
        if !snap_90s && t >= 90f0
            snap_90s = true
            n_orca, n_sfm, mv, mr, xr = agent_stats(world)
            @printf("\n★ SNAPSHOT t=90.0s: ORCA=%d SFM=%d mean_v=%.4f mean_ρ=%.4f near_door=%d stuck=%d\n",
                    n_orca, n_sfm, mv, mr, count_near_door(world), count_stuck(world))
            println("  Stuck agent positions:")
            print_per_agent_table(world, t; only_stuck=true, v_thresh=0.1f0)
        end
    end

    # ── FINAL STATE ───────────────────────────────────────────────────────────────
    flow_rate = N / t
    println("\n" * "=" ^ 80)
    @printf("FINAL: t=%.2fs, n_passed=%d/%d, flow_rate=%.4f ped/s (target ≥1.0)\n",
            t, n_passed, N, flow_rate)
    @printf("       Elapsed steps: %d\n", step_num)

    n_orca, n_sfm, mv, mr, xr = agent_stats(world)
    @printf("       ORCA=%d SFM=%d mean_v=%.4f mean_ρ=%.4f max_ρ=%.4f\n",
            n_orca, n_sfm, mv, mr, xr)

    println("\n── Remaining agents (not passed) ──")
    print_per_agent_table(world, t; only_stuck=false, v_thresh=Inf32)

    println("\n── Stuck agent neighbour analysis ──")
    print_stuck_neighbours(world)

    println("\n── ρ_ema distribution at end ──")
    bins = rho_histogram(world)
    labels = ["[0,0.5)", "[0.5,1)", "[1,1.5)", "[1.5,2)", "[2,2.5)", "[2.5,3)", "[3+)"]
    for (b, l) in zip(bins, labels)
        @printf("  %s : %d agents\n", l, b)
    end

    println("\n── Key diagnostic questions to answer from this output ──")
    println("  1. Are stuck agents in ORCA_MODE or SFM_MODE at the end?")
    println("  2. What is their ρ_ema — near 0.2 (ρ_off boundary) or higher?")
    println("  3. Are they spatially clustered (arch) or scattered?")
    println("  4. Do they have neighbours within 2m (if not → isolated LP3 freeze)")
    println("  5. When did their speed first drop below 0.05?")
    println("     (look for 'stuck=1' first appearance in per-step summary)")
    println("  6. Check SNAPSHOT t=60s and t=90s for mode counts of stuck agents")
    println("=" ^ 80)
end

main()
