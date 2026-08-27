# diag_3m_formula.jl -- Sprint 3M Pre-Fix Diagnostic
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using LinearAlgebra, Printf, StaticArrays

r    = 0.20    # agent radius (m)
a    = 8.0     # repulsion strength
D_ours   = 0.2    # our (wrong) decay: center-to-center
D_tordeux = 0.1   # correct: surface-to-surface (Tordeux 2016)

println("="^70)
println("SPRINT 3M PRE-FIX DIAGNOSTIC: Repulsion Formula Comparison")
println("="^70)
println("OURS    : a x exp(-center_dist / D)  [wrong]")
println("TORDEUX : a x exp(-surface_gap / D)  [correct]")
println("radius r=$(r)m, sum-of-radii l=$(2r)m, a=$(a)")
println()
@printf("%-16s %-14s %-22s %-22s %-10s\n",
    "Gap (surface)", "Center dist", "Ours exp(-c/0.2)",
    "Tordeux exp(-g/0.1)", "Ratio")
println("-"^70)

for gap in [0.0, 0.01, 0.05, 0.10, 0.20, 0.30, 0.50, 1.00]
    cd  = gap + 2.0*r
    ro  = a * exp(-cd / D_ours)
    rt  = a * exp(-gap / D_tordeux)
    rat = rt / max(ro, 1e-10)
    flag = rt > 1.0 ? " (>goal!)" : ""
    @printf("%-16.3f %-14.3f %-22.5f %-22.5f %.1fx%s\n", gap, cd, ro, rt, rat, flag)
end
println()

println("SAFETY CAP: current V1 defaults a=3.0, D=0.2 — when does rep > 1.0?")
for gap in [0.0, 0.1, 0.2, 0.3, 0.5]
    cd = gap + 2.0*r
    rv = 3.0 * exp(-cd / 0.2)
    @printf("  gap=%.2fm (center=%.2fm): rep=%.4f  %s\n", gap, cd, rv,
        rv >= 1.0 ? "EXCEEDS GOAL -- safety cap fires" : "ok")
end
println()

println("NET REPULSION -- 4 symmetric neighbors (gap=0.3m)")
let gap_n=0.30, cd_n=0.30+2.0*r
    dirs4 = [SVector(cd_n,0.0),SVector(-cd_n,0.0),SVector(0.0,cd_n),SVector(0.0,-cd_n)]
    net_o = mapreduce(nb -> a*exp(-norm(nb)/D_ours)*(nb/norm(nb)), +, dirs4)
    net_t = mapreduce(nb -> a*exp(-gap_n/D_tordeux)*(nb/norm(nb)), +, dirs4)
    @printf("  Ours   : |net|=%.6f  (nonzero: c-c nonlinearity breaks symmetry)\n", norm(net_o))
    @printf("  Correct: |net|=%.6f  (perfect cancellation in symmetric crowds)\n", norm(net_t))
end
println()

println("GEOMETRY CONSTRAINT (strength=5.0, range=0.02m -- JuPedSim):")
for dist_wall in [0.0, 0.01, 0.02, 0.05, 0.10, 0.20, 0.25]
    gap_w = max(dist_wall - r, 0.0)
    rep_g = 5.0 * exp(-gap_w / 0.02)
    @printf("  dist=%.3fm gap=%.3fm: geo_rep=%.5f  %s\n", dist_wall, gap_w, rep_g,
        dist_wall <= r ? "CONTACT ZONE" : rep_g > 0.1 ? "significant" : "negligible")
end
println()
println("="^70)
println("Fix: exp(-center/D) --> exp(-max(center-2r,0)/D)")
println("Remove: safety cap, nearest-only, V2 wall repulsion, lateral filter")
println("Add:    ALL-neighbor sum (isotropic), contact geo constraint (5.0, 0.02m)")
println("="^70)

