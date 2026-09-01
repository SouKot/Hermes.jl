#!/usr/bin/env julia
# benchmark_niters.jl — Sprint 3T-GPU-fix + 3V: convergence benchmark
#
# Reports physically correct metrics:
#   - max_overlap = max(0, 2r - min_sep) per step  (> 0 means body penetration)
#   - overlap_fraction = fraction of steps with any penetration
#   - flow_rate (ped/s)  — only valid when overlap is resolved
#   - mean/p95 step wall-clock time
#
# Sprint 3V: also benchmarks XPBDCorrection(α=1e-6) at n_iters=8.
#   Expected: XPBD resolves the T7 dense-bottleneck penetration that Jacobi
#   struggles with (~190mm residual at 8 iterations).
#
# Usage: julia --project test/benchmark_niters.jl

using Pkg; Pkg.activate(".")
using SimCrowd, StaticArrays, LinearAlgebra, Printf, Statistics
import Random: MersenneTwister
import KernelAbstractions: CPU
import Ark: World, new_entity!, Query

function build_hybrid_t7_scene(F, n_iters, N=80; alg=JacobiCorrection(), gpu=false)
    dt     = F(0.05)
    v_pref = F(1.4)
    r_body = F(0.2)
    mass   = F(80.0)
    door_c = F(2.0); door_h = F(0.5)

    t7_walls = NTuple{2, SVector{2,F}}[
        (SVector{2,F}(0,0), SVector{2,F}(10,0)),
        (SVector{2,F}(0,4), SVector{2,F}(10,4)),
        (SVector{2,F}(0,0), SVector{2,F}(0,4)),
        (SVector{2,F}(10,0), SVector{2,F}(10,door_c-door_h)),
        (SVector{2,F}(10,door_c+door_h), SVector{2,F}(10,4)),
    ]
    nav = build_navigation_field(t7_walls, SVector{2,F}(12,2), F(0.05))

    world = World(Position{F}, Velocity{F}, AgentGeometry{F}, MotionParams{F},
                  Goal{F}, Force{F}, WallSegment{F}, HybridFSMParams{F}, AgentFSMState{F})

    for (p1,p2) in [(SVector(0f0,0f0),SVector(0f0,4f0)), (SVector(0f0,0f0),SVector(10f0,0f0)),
                    (SVector(0f0,4f0),SVector(10f0,4f0)),
                    (SVector(10f0,0f0),SVector(10f0,door_c-door_h)),
                    (SVector(10f0,door_c+door_h),SVector(10f0,4f0))]
        new_entity!(world, (WallSegment(p1,p2),))
    end

    hybrid_p = HybridFSMParams{F}(
        ρ_on=F(3.0), ρ_off=F(0.5), density_radius=F(2.0),
        sfm_params=SFMParams{F}(),
        orca_params=ORCAParams(F(2.0),F(0.5),10,F(15.0),r_body,v_pref,F(0.5),mass))

    rng = MersenneTwister(42)
    for _ in 1:N
        x = F(0.5) + rand(rng,F)*F(9.0); y = F(0.3) + rand(rng,F)*F(3.4)
        new_entity!(world, (
            Position(SVector(x,y)), Velocity(zero(SVector{2,F})),
            AgentGeometry(r_body, r_body*F(2/3)), MotionParams(mass,v_pref,F(0.5),F(0.3)),
            Goal(SVector(F(12),door_c)), Force(zero(SVector{2,F})),
            hybrid_p, AgentFSMState{F}()))
    end

    search = RadixSpatialHash(CPU(), N, SVector(-1f0,-1f0), SVector(13f0,5f0), F(2.0))
    # SimConfig{F}(dt, dt_sfm, max_speed, iters, tol, alg, sfm_contact_substeps)
    # sfm_contact_substeps=5: contact subcycled 5× at dt_sub=0.05/5=0.01s, k=120,000 N/m
    # dt_sfm=dt: no whole-step adaptive dt (subcycling only)
    config = SimConfig{F}(dt, dt, F(2.0), n_iters, F(1e-3), alg, 5)
    SimScene(world, search, nav, config), N, dt, r_body
end

function compute_max_overlap(scene, F, r_body)
    positions = SVector{2,F}[]
    for (_, pos_col) in Query(scene.world, (Position{F},))
        for i in eachindex(pos_col); push!(positions, pos_col[i].p); end
    end
    min_sep = Inf32; two_r = 2*r_body
    for i in 1:length(positions), j in (i+1):length(positions)
        d = Float32(norm(positions[i]-positions[j]))
        if d < min_sep; min_sep = d; end
    end
    max_ov = max(0f0, two_r - min_sep)
    min_sep, max_ov
end

function run_scenario(n_iters; alg=JacobiCorrection(), T_sim=60f0, F=Float32)
    scene, N, dt, r_body = build_hybrid_t7_scene(F, n_iters, 80; alg=alg)

    # JIT warmup
    for _ in 1:10; step!(scene); end

    # Fresh scene for measurement
    scene2, N2, _, _ = build_hybrid_t7_scene(F, n_iters, 80; alg=alg)

    step_times=Float64[]; min_seps=Float32[]; max_ovs=Float32[]
    n_passed=0; t=F(0)
    exit_x=F(10.5); park_x=F(-60); park_y=F(2); door_lo=F(1.5); door_hi=F(2.5)

    while n_passed < N2 && t < T_sim
        t0 = time_ns(); step!(scene2); t1 = time_ns()
        push!(step_times, (t1-t0)/1e6)
        t += dt

        # Measure max overlap EVERY step (samples post-correction state)
        min_sep, max_ov = compute_max_overlap(scene2, F, r_body)
        push!(min_seps, min_sep); push!(max_ovs, max_ov)

        for (_, pos_col, vel_col, goal_col) in
                Query(scene2.world, (Position{F}, Velocity{F}, Goal{F}, HybridFSMParams{F}))
            for i in eachindex(pos_col)
                if pos_col[i].p[1] >= exit_x
                    n_passed += 1
                    pos_col[i]=Position(SVector(park_x,park_y))
                    vel_col[i]=Velocity(zero(SVector{2,F}))
                    goal_col[i]=Goal(SVector(park_x-F(100),park_y))
                end
            end
        end
    end

    flow = n_passed>0 ? Float32(n_passed)/t : 0f0
    ov_frac = count(x->x>0f0, max_ovs)/length(max_ovs)
    alg_name = alg isa XPBDCorrection ? @sprintf("XPBD(α=%.0e)", (alg::XPBDCorrection).α) : "Jacobi"
    (n_iters=n_iters, alg_name=alg_name, flow=flow, min_sep_mean=mean(min_seps),
     max_ov_mean=mean(max_ovs), max_ov_p95=quantile(max_ovs,0.95f0),
     max_ov_max=maximum(max_ovs), ov_frac=ov_frac,
     mean_step_ms=mean(step_times), p95_step_ms=quantile(step_times,0.95),
     n_passed=n_passed, t_sim=t)
end

println("\n=== Sprint 3T/3V: Convergence Benchmark ===")
println("=== Hybrid FSM + FMM, N=80, 1m door, T_sim=60s, SAMPLED EVERY STEP ===")
println("=== ρ_on=3.0, dt=0.05s, contact subcycled 5× at dt_sub=0.01s, k=120,000 N/m ===")
println("=== 2r = 0.40m — max_overlap > 0 means body penetration ===\n")

results=[]
for (ni, alg) in [(0, JacobiCorrection()), (2, JacobiCorrection()),
                  (8, JacobiCorrection()), (20, JacobiCorrection()),
                  (8, XPBDCorrection()), (20, XPBDCorrection())]
    label = alg isa XPBDCorrection ? "XPBD(α=1e-6)" : "Jacobi"
    @printf("Running n_iters=%d alg=%s...\n", ni, label)
    r = run_scenario(ni; alg=alg)
    push!(results, r)
    @printf("  max_ov_max=%.4fm  ov_frac=%.1f%%  flow=%.3f ped/s  mean_step=%.2fms\n\n",
            r.max_ov_max, r.ov_frac*100, r.flow, r.mean_step_ms)
end

println()
@printf("%-8s  %-16s  %-12s  %-12s  %-12s  %-12s  %-14s  %-14s\n",
        "n_iters", "algorithm", "max_ov(m)", "max_ov_p95", "ov_frac%", "flow(ped/s)", "mean_step(ms)", "p95_step(ms)")
println(repeat("─", 110))
for r in results
    flag = r.max_ov_max > 0.001f0 ? " ⚠️" : " ✅"
    @printf("%-8d  %-16s  %-12.4f  %-12.4f  %-12.1f  %-12.3f  %-14.2f  %-14.2f%s\n",
            r.n_iters, r.alg_name, r.max_ov_max, r.max_ov_p95, r.ov_frac*100,
            r.flow, r.mean_step_ms, r.p95_step_ms, flag)
end

println()
println("Legend:")
println("  max_ov(m)  = max(0, 2r - min_sep) at worst timestep  (0 = no penetration)")
println("  ov_frac%   = % of timesteps with ANY body penetration")
println("  2r = 0.40m — minimum physical separation for r=0.20m agents")
println("  ⚠️  = penetration > 1mm (physically invalid)")
println("  ✅  = below 1mm tolerance (correct)")
println()
println("Sprint 3V target: XPBD n_iters=8 → max_ov < 0.010m (vs Jacobi ~0.190m)")
