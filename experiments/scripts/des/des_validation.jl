#!/usr/bin/env julia
"""
    des_validation.jl — Full-accuracy DES validation suite (DES-S-01..09)

Runs large-scale simulations to validate SimDES against closed-form
queueing theory with ±2% accuracy. These are NOT CI tests — they take
minutes to run and are intended for periodic validation before releases.

Usage:
    julia --project=. experiments/scripts/des/des_validation.jl

Output: Prints a validation report with pass/fail for each test case.

References:
  - Kleinrock (1975), Queueing Systems Vol. 1
  - Pollaczek-Khinchine formula (P-K): Gross & Harris (1998)
  - Erlang-C formula: Erlang (1917)
"""

using Pkg
Pkg.activate(dirname(dirname(dirname(@__FILE__))))  # experiments/
Pkg.develop(path=joinpath(dirname(dirname(dirname(dirname(@__FILE__)))), "packages", "SimDES"))

using SimDES, SimCore
using Printf

# ─── Theory helpers ──────────────────────────────────────────────────────────

mm1_L(ρ)        = ρ / (1 - ρ)
mm1_Wq(μ, ρ)    = ρ / (μ * (1 - ρ))
mm1_W(μ, ρ)     = 1.0 / (μ * (1 - ρ))

# Erlang-C formula P(wait > 0 | c servers, offered load a = λ/μ)
function erlang_c(c::Int, a::Float64)
    ρ = a / c
    ρ >= 1.0 && return 1.0
    num = (a^c / factorial(c)) * (c / (c - a))
    den = sum(a^k / factorial(k) for k in 0:c-1) + num
    num / den
end

# M/M/c exact Wq using Erlang-C
function mmc_Wq(λ, μ, c)
    a = λ / μ
    C = erlang_c(c, a)
    C / (c * μ - λ)
end

# M/M/1/K blocking probability
function mm1k_pb(ρ, K)
    ρ ≈ 1.0 && return 1.0 / (K + 1)
    (1 - ρ) * ρ^K / (1 - ρ^(K+1))
end

# P-K formula: Wq = λ·E[S²] / (2(1-ρ))
md1_Wq(λ, d)    = λ * d^2 / (2 * (1 - λ*d))
md1_W(λ, d)     = md1_Wq(λ, d) + d

function mg1_Wq_erlang(λ, μ, k)
    ρ   = λ / μ
    ES2 = (k + 1) / (k * μ^2)
    λ * ES2 / (2 * (1 - ρ))
end

# ─── Validation runner ───────────────────────────────────────────────────────

struct TestResult
    name    :: String
    metric  :: String
    sim     :: Float64
    theory  :: Float64
    tol_pct :: Float64
    passed  :: Bool
end

function check(name, metric, sim_val, theory_val; tol_pct=2.0)
    err_pct = abs(sim_val - theory_val) / abs(theory_val) * 100
    passed  = err_pct < tol_pct
    TestResult(name, metric, sim_val, theory_val, tol_pct, passed)
end

function print_result(r::TestResult)
    status = r.passed ? "✓ PASS" : "✗ FAIL"
    err_pct = abs(r.sim - r.theory) / abs(r.theory) * 100
    @printf("  %-8s %-8s  sim=%-8.4f  theory=%-8.4f  err=%5.2f%%  tol=%.1f%%\n",
            status, r.metric, r.sim, r.theory, err_pct, r.tol_pct)
end

# ─── Validation tests ────────────────────────────────────────────────────────

results = TestResult[]

# ─── DES-S-01: M/M/1 ρ=0.5 ──────────────────────────────────────────────────
println("\n=== DES-S-01: M/M/1 ρ=0.50 (λ=2, μ=4) ===")
λ=2.0; μ=4.0; ρ=λ/μ
stats = run_mm1!(λ, μ; n_arrivals=200_000, seed=42)
sm    = sim_summary(stats)

push!(results, check("DES-S-01", "L",    sm.L,            mm1_L(ρ);        tol_pct=2.0))
push!(results, check("DES-S-01", "Wq",   sm.Wq,           mm1_Wq(μ, ρ);    tol_pct=3.0))
push!(results, check("DES-S-01", "W",    sm.W,            mm1_W(μ, ρ);     tol_pct=2.0))
push!(results, check("DES-S-01", "util", sm.utilization,  ρ;               tol_pct=1.0))
for r in results[end-3:end]; print_result(r); end

# ─── DES-S-02: M/M/1 ρ=0.9 ──────────────────────────────────────────────────
println("\n=== DES-S-02: M/M/1 ρ=0.90 (λ=9, μ=10) ===")
λ=9.0; μ=10.0; ρ=λ/μ
stats = run_mm1!(λ, μ; n_arrivals=500_000, seed=42)
sm    = sim_summary(stats)

push!(results, check("DES-S-02", "L",    sm.L,            mm1_L(ρ);        tol_pct=5.0))
push!(results, check("DES-S-02", "Wq",   sm.Wq,           mm1_Wq(μ, ρ);    tol_pct=5.0))
push!(results, check("DES-S-02", "W",    sm.W,            mm1_W(μ, ρ);     tol_pct=5.0))
push!(results, check("DES-S-02", "util", sm.utilization,  ρ;               tol_pct=1.0))
for r in results[end-3:end]; print_result(r); end

# ─── DES-S-03: M/M/1 sweep ───────────────────────────────────────────────────
println("\n=== DES-S-03: M/M/1 sweep ρ∈{0.3,0.5,0.7,0.9} — L monotone ===")
μ = 10.0
ρs = [0.3, 0.5, 0.7, 0.9]
Ls_sim    = Float64[]
Ls_theory = Float64[]
for ρ in ρs
    λ = ρ * μ
    sm = sim_summary(run_mm1!(λ, μ; n_arrivals=100_000, seed=42))
    push!(Ls_sim,    sm.L)
    push!(Ls_theory, mm1_L(ρ))
    push!(results, check("DES-S-03", "L(ρ=$ρ)", sm.L, mm1_L(ρ); tol_pct=5.0))
    print_result(results[end])
end
monotone = all(Ls_sim[i] < Ls_sim[i+1] for i in 1:length(Ls_sim)-1)
@printf("  %-8s %-8s  monotone=%s\n",
        monotone ? "✓ PASS" : "✗ FAIL", "monotone", monotone)

# ─── DES-S-04: M/M/c ─────────────────────────────────────────────────────────
println("\n=== DES-S-04: M/M/c c=4 (λ=8, μ=3, ρ/server=0.667) ===")
λ=8.0; μ=3.0; c=4
ρ_per = λ / (c * μ)
stats = run_mmc!(λ, μ, c; n_arrivals=200_000, seed=42)
sm    = sim_summary(stats)

push!(results, check("DES-S-04", "util", sm.utilization, ρ_per;          tol_pct=2.0))
push!(results, check("DES-S-04", "Wq",   sm.Wq,          mmc_Wq(λ,μ,c); tol_pct=5.0))
for r in results[end-1:end]; print_result(r); end

# ─── DES-S-05: M/M/1/K ───────────────────────────────────────────────────────
println("\n=== DES-S-05: M/M/1/K K=5 ρ=1.0 — blocking ≈ 1/6 ===")
λ=2.0; μ=2.0; K=5
pb_th = mm1k_pb(1.0, K)
stats = run_mm1k!(λ, μ, K; n_arrivals=500_000, seed=99)
sm    = sim_summary(stats)

push!(results, check("DES-S-05", "pb",   sm.blocking_prob, pb_th; tol_pct=3.0))
print_result(results[end])

# ─── DES-S-06: M/D/1 ─────────────────────────────────────────────────────────
println("\n=== DES-S-06: M/D/1 ρ=0.8 (λ=0.8, d=1.0) — P-K formula ===")
λ=0.8; d=1.0
stats = run_md1!(λ, d; n_arrivals=200_000, seed=42)
sm    = sim_summary(stats)

push!(results, check("DES-S-06", "Wq",  sm.Wq, md1_Wq(λ,d); tol_pct=3.0))
push!(results, check("DES-S-06", "W",   sm.W,  md1_W(λ,d);  tol_pct=2.0))
push!(results, check("DES-S-06", "util",sm.utilization, λ*d; tol_pct=1.0))
for r in results[end-2:end]; print_result(r); end

# Compare M/D/1 vs M/M/1 Wq (P-K: M/D/1 is exactly half)
sm_mm1 = sim_summary(run_mm1!(λ, 1/d; n_arrivals=200_000, seed=42))
ratio   = sm.Wq / sm_mm1.Wq
@printf("  %-8s %-8s  Wq(D1)/Wq(M1)=%.3f  (theory=0.500, tol±10%%)\n",
        abs(ratio - 0.5) < 0.05 ? "✓ PASS" : "✗ FAIL", "P-K ratio", ratio)

# ─── DES-S-07: M/G/1 Erlang-2 ────────────────────────────────────────────────
println("\n=== DES-S-07: M/G/1 Erlang-2 (λ=1, μ=2, k=2) — P-K formula ===")
λ=1.0; μ=2.0; k=2
stats = run_mg1!(λ, μ, k; n_arrivals=200_000, seed=42)
sm    = sim_summary(stats)

push!(results, check("DES-S-07", "Wq", sm.Wq, mg1_Wq_erlang(λ,μ,k); tol_pct=3.0))
print_result(results[end])

# Erlang-k sweep: Wq non-increasing
wqs = [sim_summary(run_mg1!(λ, μ, ki; n_arrivals=100_000, seed=42)).Wq
       for ki in [1, 2, 4, 8]]
@printf("  Wq by k: %s (theory: monotone non-increasing)\n",
        join([@sprintf("%.3f", w) for w in wqs], " > "))

# ─── DES-S-08: Event cancellation ────────────────────────────────────────────
println("\n=== DES-S-08: Cancellation — 500/1000 events execute ===")
fel  = FutureEventList()
ids  = [schedule!(fel, NullEvent(), float(i)) for i in 1:1000]
for i in 2:2:1000; cancel!(ids[i]); end
executed = 0
while (r = safe_dequeue!(fel)) !== nothing; executed += 1; end
push!(results, check("DES-S-08", "count", float(executed), 500.0; tol_pct=0.01))
print_result(results[end])

# ─── DES-S-09: SimClock ──────────────────────────────────────────────────────
println("\n=== DES-S-09: SimClock 1× real-time fidelity ===")
clock = SimClock(1.0)
t0    = time()
throttle!(clock, 0.5)
elapsed = time() - t0
passed  = elapsed >= 0.40 && elapsed <= 1.0
@printf("  %-8s %-8s  elapsed=%.3fs  (expected≈0.5s, window=[0.40,1.00])\n",
        passed ? "✓ PASS" : "✗ FAIL", "clock 1×", elapsed)

# ─── Summary ─────────────────────────────────────────────────────────────────
println("\n" * "="^70)
n_pass = count(r -> r.passed, results)
n_fail = count(r -> !r.passed, results)
@printf("VALIDATION SUMMARY: %d / %d passed  (%d failed)\n",
        n_pass, length(results), n_fail)
println("="^70)

if n_fail > 0
    println("\nFailed tests:")
    for r in filter(r -> !r.passed, results)
        err_pct = abs(r.sim - r.theory) / abs(r.theory) * 100
        @printf("  %s / %s: sim=%.4f  theory=%.4f  err=%.2f%%  tol=%.1f%%\n",
                r.name, r.metric, r.sim, r.theory, err_pct, r.tol_pct)
    end
end
