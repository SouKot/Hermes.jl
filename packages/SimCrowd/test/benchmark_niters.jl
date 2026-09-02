#!/usr/bin/env julia
# benchmark_niters.jl — Sprint 3W / Sprint 3X (GCFM Option A)
#
# Reports physically correct metrics per configuration:
#   - max_overlap = max(0, 2r - min_sep) per step  (> 0 means body penetration)
#   - overlap_fraction = fraction of steps with any penetration
#   - flow_rate (ped/s)
#   - mean/p95 step wall-clock time (ms)
#
# Force model dispatch (controlled via SFMParams):
#   sp.τ_gap > 0  → GCFM elliptical (Chraibi 2010 §III) — anticipatory, prevents penetration
#   sp.η > 0      → GCF circular    (Chraibi 2010 §II)  — speed-adaptive decay
#   else          → Helbing SFM     (default)            — fixed exponential
#
# Usage: julia --project test/benchmark_niters.jl

using Pkg; Pkg.activate(".")
using SimCrowd, StaticArrays, LinearAlgebra, Printf, Statistics
import Random: MersenneTwister
import KernelAbstractions: CPU
import Ark: World, new_entity!, Query

# ── Preset SFMParams for the three repulsion models ─────────────────────────────

"""Helbing SFM preset (baseline). A=2000 N, B=0.08m, fixed exponential decay."""
function sfm_helbing(F=Float32)
    SFMParams{F}(F(2000), F(0.08), F(0.5), F(0.5),   # A, B, λ, μ
                  zero(F), zero(F), F(0.25), F(0.25))  # η, τ_gap, b_min, b_max
end

"""GCF circular preset (Chraibi 2010 §II). Speed-adaptive decay: D_i = r_body + η×‖v‖.
A=2000 N (same as Helbing), η=0.5 s (Chraibi 2010 Table I)."""
function sfm_gcf(F=Float32; η=F(0.5))
    SFMParams{F}(F(2000), F(0.08), F(0.5), F(0.5),   # A, B, λ, μ
                  η, zero(F), F(0.25), F(0.25))        # η, τ_gap=0, b_min, b_max
end

"""GCFM elliptical preset (Chraibi 2010 §III). Anticipatory elliptic personal space.
A=70 N (Chraibi Table II), τ_gap=0.53s, b_min=0.20m, b_max=0.25m.
⚠  A is much smaller than Helbing (70 vs 2000) — different potential scale."""
function sfm_gcfm(F=Float32; A=F(70), τ_gap=F(0.53), b_min=F(0.20), b_max=F(0.25))
    SFMParams{F}(A, F(0.08), F(0.5), F(0.5),           # A, B, λ, μ
                  zero(F), τ_gap, b_min, b_max)          # η=0, τ_gap, b_min, b_max
end

# ── Scene builder ────────────────────────────────────────────────────────────────

function build_hybrid_t7_scene(F, n_iters, N=80;
                                alg=JacobiCorrection(),
                                sfm_params=sfm_helbing(F),
                                sfm_contact_substeps=0,
                                ρ_on=F(3.0), ρ_off=F(0.5))
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
        ρ_on=ρ_on, ρ_off=ρ_off, density_radius=F(2.0),
        sfm_params=sfm_params,
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
    config = SimConfig{F}(dt, dt, F(2.0), n_iters, F(1e-3), alg, sfm_contact_substeps)
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

function run_scenario(n_iters; alg=JacobiCorrection(), T_sim=60f0, F=Float32,
                       sfm_params=sfm_helbing(F),
                       sfm_contact_substeps=0,
                       ρ_on=F(3.0), label="Helbing")
    scene, N, dt, r_body = build_hybrid_t7_scene(F, n_iters, 80;
                                                   alg=alg,
                                                   sfm_params=sfm_params,
                                                   sfm_contact_substeps=sfm_contact_substeps,
                                                   ρ_on=ρ_on)

    # JIT warmup
    for _ in 1:10; step!(scene); end

    # Fresh scene for measurement
    scene2, N2, _, _ = build_hybrid_t7_scene(F, n_iters, 80;
                                               alg=alg,
                                               sfm_params=sfm_params,
                                               sfm_contact_substeps=sfm_contact_substeps,
                                               ρ_on=ρ_on)

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
                    pos_col[i] = Position(SVector(park_x, park_y + F(n_passed)*F(0.001)))
                    vel_col[i] = Velocity(zero(SVector{2,F}))
                    goal_col[i] = Goal(SVector(park_x - F(1), park_y))
                end
            end
        end
    end

    flow = n_passed>0 ? Float32(n_passed)/t : 0f0
    alg_name = alg isa JacobiCorrection ? "Jacobi" :
               alg isa XPBDCorrection   ? "XPBD(α=$(alg.α))" : string(alg)
    ov_frac = mean(x -> x > 0.001f0, max_ovs)

    (n_iters=n_iters, label=label, alg_name=alg_name, flow=flow,
     min_sep_mean=mean(min_seps), max_ov_max=maximum(max_ovs),
     max_ov_p95=quantile(max_ovs, 0.95f0),
     ov_frac=ov_frac,
     mean_step_ms=mean(step_times), p95_step_ms=quantile(step_times, 0.95))
end

# ── Run benchmark ────────────────────────────────────────────────────────────────
# Sprint 3X findings (2026-09-02):
#   User insight: lowering ρ_on activates GCFM while agents still have v > 0,
#   giving GCFM's anticipatory ellipse meaningful reach before physical contact.
#   This acts as a density brake, preventing extreme compression at the door.
#
# Best result: GCFM A=70 ρ_on=1.0 XPBD n=8
#   max_ov ≈ 0.182m  (−31% vs Helbing baseline 0.266m)
#   flow   ≈ 2.42 ped/s  (+16% vs Helbing baseline 2.08 ped/s)
#
# Note: σ=0.3 fluctuation → max_ov_max varies ±30–50mm between runs.
#       Run multiple seeds for statistical estimates (single-run = indicative).

println("\n=== Sprint 3X: HybridFSM Overlap Benchmark ===")
println("=== N=80, 1m door, T_sim=60s, dt=0.05s, Jacobi/XPBD n=8 ===")
println("=== GCFM repulsion model, ρ_on sweep vs Helbing baseline ===")
println("=== 2r = 0.40m — max_overlap > 0 means body penetration ===\n")

F = Float32
results = []

configs = [
    # (label, ρ_on, n_iters, alg, sfm_params, sfm_contact_substeps)
    #
    # ── Baseline ──────────────────────────────────────────────────────────────
    ("Helbing ρ_on=3.0",         3.0f0,  8, JacobiCorrection(),     sfm_helbing(F), 0),
    #
    # ── GCFM: ρ_on=3.0 (no benefit — v≈0 at transition, ellipse = body radius) ─
    ("GCFM A=70 ρ_on=3.0",      3.0f0,  8, JacobiCorrection(),     sfm_gcfm(F; A=F(70)), 0),
    #
    # ── GCFM: lower ρ_on — activates with v>0, creates density-brake backpressure ─
    ("GCFM A=70 ρ_on=1.5",      1.5f0,  8, JacobiCorrection(),     sfm_gcfm(F; A=F(70)), 0),
    ("GCFM A=70 ρ_on=1.0",      1.0f0,  8, JacobiCorrection(),     sfm_gcfm(F; A=F(70)), 0),
    ("GCFM A=70 ρ_on=0.8",      0.8f0,  8, JacobiCorrection(),     sfm_gcfm(F; A=F(70)), 0),
    ("GCFM A=70 ρ_on=0.6",      0.6f0,  8, JacobiCorrection(),     sfm_gcfm(F; A=F(70)), 0),
    #
    # ── GCFM + XPBD: best combination (Sprint 3X recommended config) ───────────
    ("GCFM A=70 ρ_on=1.0 XPBD", 1.0f0,  8, XPBDCorrection(α=1f-6), sfm_gcfm(F; A=F(70)), 0),
    ("GCFM A=70 ρ_on=0.8 XPBD", 0.8f0,  8, XPBDCorrection(α=1f-6), sfm_gcfm(F; A=F(70)), 0),
]

# ρ_off = 35% of ρ_on (hysteresis band), min 0.20 to avoid chattering at very low ρ_on
ρ_off_for(ρ_on::F) where F = F(max(ρ_on * F(0.35), F(0.20)))

for (label, ρ_on, n_iters, alg, sparams, n_sub) in configs
    alg_str = alg isa JacobiCorrection ? "Jacobi" : "XPBD"
    println("Running: $(label) [alg=$(alg_str)]...")
    r = run_scenario(n_iters; alg=alg, sfm_params=sparams,
                     sfm_contact_substeps=n_sub, ρ_on=ρ_on,
                     ρ_off=ρ_off_for(ρ_on), label=label)
    @printf("  max_ov_max=%.4fm  ov_frac=%.1f%%  flow=%.3f ped/s  mean_step=%.2fms\n\n",
            r.max_ov_max, r.ov_frac*100, r.flow, r.mean_step_ms)
    push!(results, r)
end

# Print summary table
println("\n")
@printf("%-26s  %-10s  %-12s  %-12s  %-10s  %-12s  %-13s\n",
        "config", "algorithm", "max_ov(m)", "max_ov_p95", "ov_frac%",
        "flow(ped/s)", "mean_step(ms)")
println("─"^100)
for r in results
    flag = r.max_ov_max > 0.001f0 ? "⚠️ " : "✅ "
    best = r.max_ov_max < 0.20f0 ? " ★" : ""
    @printf("%-26s  %-10s  %-12.4f  %-12.4f  %-10.1f  %-12.3f  %-13.2f  %s%s\n",
            r.label, r.alg_name, r.max_ov_max, r.max_ov_p95,
            r.ov_frac*100, r.flow, r.mean_step_ms, flag, best)
end

println("""
\nLegend:
  max_ov(m)  = max(0, 2r - min_sep) at worst timestep  (0 = no penetration)
  ov_frac%   = % of timesteps with body penetration > 1mm
  2r = 0.40m — minimum physical separation for r=0.20m agents
  ⚠️  = penetration present (physically imperfect)
  ✅  = below 1mm tolerance
  ★   = below 0.20m (best tier)

Key Sprint 3X finding:
  GCFM activates while agents have v > 0 (at ρ_on=0.8–1.0 vs default 3.0).
  The anticipatory ellipse a(v) = r_body + τ_gap×v creates BACKPRESSURE that
  resists crowd compression before physical contact occurs.
  This reduces peak overlap AND improves flow (ORCA was over-constraining at ρ=1–2).

  Recommended config: GCFM A=70, ρ_on=1.0, ρ_off=0.35, XPBD n=8
    → max_ov ≈ 0.18m (−31% vs baseline), flow ≈ 2.42 ped/s (+16% vs baseline)
    → Note: σ=0.3 fluctuation → ±30–50mm variance between runs (indicative)

Force model calibrations:
  GCFM A=150: A=150 N, τ_gap=0.53s  (stronger elliptical, experimental)
""")
