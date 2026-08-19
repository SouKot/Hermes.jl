#!/usr/bin/env julia
# calibrate_gcf.jl — Sprint 3G GCF Calibration Sweep
#
# Sweeps (η, V₀_gcf) pairs to find the GCF parameters that minimise
# max deviation across all 4 Weidmann density points:
#   ρ ∈ {0.5, 1.0, 2.0, 3.0} ped/m²
#
# Run from SimCrowd package root:
#   julia --startup-file=no --project=. scratch/calibrate_gcf.jl
#
# Current SFM baseline (η=0):
#   ρ=0.5 ratio=1.032 ✅  ρ=1.0 ratio=1.247 ❌  ρ=2.0 ratio=0.937 ✅  ρ=3.0 ratio=2.18 ❌
#
# Target: all ratios within ±0.20 (±20%) of Weidmann + monotonic v(ρ)

using Printf
using SimCrowd
using Ark
using StaticArrays
using LinearAlgebra
using Random
using KernelAbstractions

# Load helpers (includes FundamentalDiagramConfig, run_fundamental_diagram!, etc.)
include(joinpath(@__DIR__, "..", "test", "crowd_test_helpers.jl"))

const ρs = [0.5f0, 1.0f0, 2.0f0, 3.0f0]

# ── 1. Baseline: η=0 (pure SFM) ───────────────────────────────────────────────
println("═"^90)
println("BASELINE: Pure Helbing SFM (η=0, A=2000N)")
println("─"^90)
baseline_cfg = FundamentalDiagramConfig{Float32}()
baseline_results = [run_fundamental_diagram!(ρ, baseline_cfg) for ρ in ρs]
for r in baseline_results
    print_fd_result(r; tol=0.15)
end
baseline_ratios = [r.ratio for r in baseline_results]
@printf("Monotonic: %s  Max dev: %.3f\n\n",
    all(baseline_ratios[i] >= baseline_ratios[i+1] for i in 1:3) ? "✅" : "❌",
    maximum(abs(r - 1) for r in baseline_ratios))

# ── 2. GCF sweep ──────────────────────────────────────────────────────────────
ηs   = [0.3f0, 0.5f0]
V₀s  = [30f0, 50f0, 80f0, 100f0, 120f0, 150f0, 200f0]

println("═"^90)
println("GCF SWEEP: η × V₀_gcf (target: all ratios ±20%, monotonic)")
println("─"^90)
@printf("%-6s  %-8s  %-7s  %-7s  %-7s  %-7s  %-9s  %-12s  %s\n",
        "η", "V₀ (N)", "ρ=0.5", "ρ=1.0", "ρ=2.0", "ρ=3.0", "max_dev", "monotonic", "verdict")
println("─"^90)

best_cfg      = nothing
best_max_dev  = Inf
best_row      = ""

for η in ηs
    for V₀ in V₀s
        cfg = FundamentalDiagramConfig{Float32}(η=η, V₀_gcf=V₀)
        results = [run_fundamental_diagram!(ρ, cfg) for ρ in ρs]
        ratios  = [r.ratio for r in results]
        devs    = [abs(r - 1) for r in ratios]
        max_dev = maximum(devs)
        mono    = all(ratios[i] >= ratios[i+1] for i in 1:3)
        pass20  = all(d <= 0.20 for d in devs)
        pass15  = all(d <= 0.15 for d in devs)

        verdict = if pass15 && mono
            "★ PASS ±15% + mono"
        elseif pass20 && mono
            "✅ PASS ±20% + mono"
        elseif mono
            "⚠️  mono only (max_dev=$(round(max_dev*100, digits=1))%)"
        else
            "❌"
        end

        row = @sprintf("η=%.1f  V₀=%5.0f  %5.3f   %5.3f   %5.3f   %5.3f   %.3f      %-12s  %s",
                       η, V₀, ratios[1], ratios[2], ratios[3], ratios[4],
                       max_dev, mono ? "✅ yes" : "❌ no", verdict)
        println(row)

        # Track best (monotonic + minimum max deviation)
        if mono && max_dev < best_max_dev
            best_max_dev = max_dev
            best_cfg     = cfg
            best_row     = row
        end
    end
end

println("─"^90)
println("\nBEST: $best_row")

if best_cfg !== nothing
    println("\n═"^90)
    @printf("RECOMMENDED PARAMETERS:  η=%.1f  V₀_gcf=%.0f N\n", best_cfg.η, best_cfg.V₀_gcf)
    println("Use these in FundamentalDiagramConfig and testset 3F assertions.")

    # Detailed breakdown of best config
    println("\nDetailed results for recommended config:")
    results = [run_fundamental_diagram!(ρ, best_cfg) for ρ in ρs]
    for r in results
        print_fd_result(r; tol=0.20)
    end
end
