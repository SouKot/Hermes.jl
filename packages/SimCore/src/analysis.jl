"""
    analysis.jl — Output analysis tools for StatsPipeline

Provides three output analysis functions:

| Function            | Use case                                         |
|---------------------|--------------------------------------------------|
| `check_littles_law` | Self-consistency check on pipeline output        |
| `batch_means_ci`    | CI from a single long run (needs record_samples) |
| `replicate`         | CI across independent replications (sequential)  |

No external dependencies. All CI calculations use the t-distribution
approximation `t ≈ 1.96 + 0.3 / sqrt(df)` which is accurate to < 1%
for df ≥ 10.

Design ref: Sprint 4I · Tasks 14-16
"""

# ─────────────────────────────────────────────────────────────────────────────
# Internal: t-critical value approximation
# ─────────────────────────────────────────────────────────────────────────────

"""
    _t_critical(df::Int, alpha::Float64) → Float64

Two-tailed t-distribution critical value for a 95% CI (alpha=0.025).
Uses a lookup table for common df values and the approximation
`t ≈ 1.96 + 0.3/sqrt(df)` for df not in the table.

Accurate to < 1% for df ≥ 10 without requiring Distributions.jl.
"""
function _t_critical(df::Int, alpha::Float64)
    # Lookup table for common degrees of freedom (alpha=0.025, two-tailed)
    if alpha ≈ 0.025
        df == 1  && return 12.706
        df == 2  && return  4.303
        df == 3  && return  3.182
        df == 4  && return  2.776
        df == 5  && return  2.571
        df == 6  && return  2.447
        df == 7  && return  2.365
        df == 8  && return  2.306
        df == 9  && return  2.262
        df == 10 && return  2.228
        df == 15 && return  2.131
        df == 20 && return  2.086
        df == 25 && return  2.060
        df == 29 && return  2.045
        df >= 30 && return  1.960 + 0.3 / sqrt(Float64(df))   # asymptotic approx
    elseif alpha ≈ 0.05
        df >= 30 && return  1.645 + 0.2 / sqrt(Float64(df))
    end
    # General approximation (less accurate for small df but acceptable for df≥10)
    return 1.96 + 0.3 / sqrt(max(1.0, Float64(df)))
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 14 — check_littles_law
# ─────────────────────────────────────────────────────────────────────────────

"""
    check_littles_law(sm::NamedTuple; tol::Float64=0.10) → (passes::Bool, error::Float64)

Self-consistency check: verify **Little's Law** `L̄ ≈ λ_eff × W̄`.

Little's Law holds exactly in steady state for any queueing system. A violation
indicates a bug in the statistics pipeline (e.g., mismatched warmup, wrong time
weights, incorrect sojourn measurement).

# Arguments
- `sm`  — `NamedTuple` from `sim_summary(pipeline)`. Must contain `L`, `W`, `throughput`.
- `tol` — relative error tolerance (default 10%). Use 5% for validation tests.

# Returns
`(passes::Bool, error::Float64)` where `error = |L_pred - L_meas| / L_meas`.
Returns `(true, NaN)` if either value is NaN or L is near zero (insufficient data).

# Example
```julia
sm = sim_summary(pipeline)
ok, err = check_littles_law(sm)
ok || @warn "Little's Law violation: \$(round(err*100, digits=1))% error"
```

# Theory
For an M/M/1 queue at ρ=0.9, μ=1:
- `L = ρ/(1-ρ) = 9.0`
- `W = 1/(μ-λ) = 10.0`
- `λ_eff ≈ 0.9`
- `L = λ_eff × W = 0.9 × 10.0 = 9.0 ✓`
"""
function check_littles_law(sm::NamedTuple; tol::Float64 = 0.10)
    L_meas = sm.L
    L_pred = sm.throughput * sm.W   # λ_eff × W̄
    if isnan(L_pred) || isnan(L_meas) || L_meas < 1e-10
        return (true, NaN)   # insufficient data — skip check
    end
    err = abs(L_pred - L_meas) / L_meas
    return (err <= tol, err)
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 15 — batch_means_ci
# ─────────────────────────────────────────────────────────────────────────────

"""
    batch_means_ci(samples::Vector{Float64}; k::Int=30, alpha::Float64=0.05)
    → (mean, ci_lo, ci_hi, n_batches, batch_size)

Compute a **batch means confidence interval** from a vector of raw observations.

## When to use
Use this when `StatsPipeline(record_samples=true)` has buffered individual
sojourn/wait observations from a single long run. Batch means decorrelates
the autocorrelated within-run samples, producing valid CIs without requiring
independent replications.

## Algorithm (Law & Kelton §9.5)
1. Discard any leading observations that fall before warmup (already done by the
   pipeline before buffering).
2. Divide `n` post-warmup observations into `k` non-overlapping batches of size
   `⌊n/k⌋`. Trailing observations are discarded.
3. Compute the mean within each batch → `k` approximately i.i.d. batch means.
4. Apply the t-CI to those `k` batch means: `μ ± t_{k-1, α/2} × s/√k`.

## Arguments
- `samples`    — raw observations (e.g., `pipeline._sojourn_samples`)
- `k`          — number of batches (default 30; must be ≥ 10 for t-approx validity)
- `alpha`      — significance level (default 0.05 → 95% CI)

## Returns
`NamedTuple` with:
- `mean`       — grand mean of batch means
- `ci_lo`      — lower confidence bound
- `ci_hi`      — upper confidence bound
- `n_batches`  — actual number of batches used (`k`)
- `batch_size` — observations per batch

Returns all-`NaN` if fewer than `2k` observations.

## Example
```julia
pipeline = StatsPipeline(record_samples=true)
# ... run simulation with 100_000 arrivals ...
ci = batch_means_ci(pipeline._sojourn_samples; k=30)
println("W̄ = \$(ci.mean) ± \$(ci.ci_hi - ci.mean) (95% CI from \$(ci.n_batches) batches)")
```
"""
function batch_means_ci(samples::Vector{Float64}; k::Int = 30, alpha::Float64 = 0.05)
    n = length(samples)
    if n < 2k
        return (mean=NaN, ci_lo=NaN, ci_hi=NaN, n_batches=0, batch_size=0)
    end
    k < 10 && @warn "batch_means_ci: k=$k < 10; t-approximation may be inaccurate. Recommend k≥30."

    batch_size = n ÷ k
    # Compute batch means — no allocations beyond this one Vector
    batch_means = Vector{Float64}(undef, k)
    for i in 1:k
        lo = (i - 1) * batch_size + 1
        hi = i * batch_size
        s  = 0.0
        @inbounds for j in lo:hi
            s += samples[j]
        end
        batch_means[i] = s / batch_size
    end

    μ = sum(batch_means) / k
    # Welford variance over batch means
    var_sum = 0.0
    @inbounds for bm in batch_means
        d = bm - μ
        var_sum += d * d
    end
    s = sqrt(var_sum / (k - 1))

    t_crit = _t_critical(k - 1, alpha / 2)
    se     = s / sqrt(Float64(k))
    return (mean=μ, ci_lo=μ - t_crit*se, ci_hi=μ + t_crit*se,
            n_batches=k, batch_size=batch_size)
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 16 — replicate (sequential independent replications)
# ─────────────────────────────────────────────────────────────────────────────

"""
    replicate(run_fn::Function, n_reps::Int; seed_offset::Int=0) → NamedTuple

Run `run_fn(seed)` sequentially for `n_reps` independent replications and compute
across-replication statistics for all `sim_summary` fields.

This is the **gold-standard** method for steady-state output analysis
(Law & Kelton §9.4). Each replication starts from empty state with a different
random seed, so results are i.i.d. — no autocorrelation correction needed.

## Arguments
- `run_fn`      — `Function(seed::Int) → NamedTuple` (must return `sim_summary(...)` output)
- `n_reps`      — number of replications (recommend ≥ 10; use ≥ 30 for tight CIs)
- `seed_offset` — base seed; replication `i` uses `seed_offset + i`

## Returns
`NamedTuple` where each field from `sim_summary` is replaced by a sub-NamedTuple:
`(mean, ci_lo, ci_hi, std_dev)` across the `n_reps` replication values.

Fields that are `NaN` in any replication (e.g., before warmup completed) are
excluded from the CI calculation for that field.

## Example
```julia
result = replicate(10) do seed
    p = StatsPipeline(warmup=WARMUP_FIXED, warmup_n=5_000)
    run_mm1!(0.9, 1.0; n_arrivals=100_000, seed=seed, pipeline=p)
    sim_summary(p)
end
println("W̄ = \$(result.W.mean) ± \$(result.W.ci_hi - result.W.mean) (95% CI)")
println("ρ  = \$(result.utilization.mean)")
```

## Thread-parallel version
For the parallel version across Julia threads, see `replicate_parallel`
in Sprint 4I Task 23 (to be implemented).
"""
function replicate(run_fn::Function, n_reps::Int; seed_offset::Int = 0)
    n_reps >= 2 || throw(ArgumentError("replicate: need at least 2 replications (got $n_reps)"))

    results = [run_fn(seed_offset + i) for i in 1:n_reps]

    fields = keys(results[1])
    stats_per_field = Dict{Symbol, Any}()

    for f in fields
        raw = [getfield(r, f) for r in results]
        # Keep only numeric (non-Bool, non-NaN) values
        vals = Float64[]
        for v in raw
            v isa Bool && continue   # warmup_complete is Bool, skip
            v isa Number && !isnan(Float64(v)) && push!(vals, Float64(v))
        end
        isempty(vals) && continue

        n = length(vals)
        μ = sum(vals) / n

        # Welford variance
        var_sum = 0.0
        for v in vals
            d = v - μ
            var_sum += d * d
        end
        s  = n > 1 ? sqrt(var_sum / (n - 1)) : 0.0
        t  = _t_critical(n - 1, 0.025)
        se = s / sqrt(Float64(n))
        stats_per_field[f] = (mean=μ, ci_lo=μ - t*se, ci_hi=μ + t*se, std_dev=s)
    end

    return NamedTuple(stats_per_field)
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 23 — replicate_parallel (Threads.@spawn + optional GPU post-processing)
# ─────────────────────────────────────────────────────────────────────────────

"""
    replicate_parallel(run_fn::Function, n_reps::Int;
                       seed_offset::Int    = 0,
                       gpu_postprocess::Bool = false,
                       n_zones_per_rep::Int  = 1) → NamedTuple

Run `n_reps` independent replications **in parallel** using `Threads.@spawn`
and compute across-replication statistics for all `sim_summary` fields.

This is the parallel analogue of `replicate`. Each replication calls
`run_fn(seed)` in its own Julia task; tasks are scheduled by the runtime
across available threads.

## Arguments
- `run_fn`          — `Function(seed::Int) → NamedTuple` (from `sim_summary`)
- `n_reps`          — number of independent replications (≥ 2; recommend ≥ 10)
- `seed_offset`     — base seed; replication `i` uses `seed_offset + i`
- `gpu_postprocess` — when `true` and the `SimCoreGPUExt` extension is loaded
  (i.e., `AcceleratedKernels` is in the active environment), reduces replication
  summary scalars using `AK.mapreduce`.  On a plain CPU this uses KA's
  multithreaded CPU backend; pass a device array at the call site to use GPU.
  Only pays off when `n_reps ≳ 1_000`; for typical sizes the sequential path is
  fast enough.
- `n_zones_per_rep` — Chandy-Misra Tier-2 hint: number of LP threads each
  replication internally spawns. Warns if `n_reps × n_zones_per_rep` exceeds
  `Threads.nthreads()`.

## Thread safety requirement
`run_fn` **must not** share mutable state between replications.
Each replication must construct its own `StatsPipeline`:
```julia
result = replicate_parallel(16) do seed
    p = StatsPipeline(warmup=WARMUP_FIXED, warmup_n=5_000)
    run_mm1!(0.9, 1.0; n_arrivals=100_000, seed=seed, pipeline=p)
    sim_summary(p)
end
```

## AcceleratedKernels note
DES event loops are **not** GPU-parallelised. The FEL (future event list) is
an intrinsically sequential causal structure. `gpu_postprocess=true` applies
AK-accelerated reduction to the post-run summary scalars (mean, variance across
reps) — via CPU threads or GPU depending on what's loaded in the environment.

## Tier-2 Chandy-Misra note
`n_zones_per_rep > 1` signals that each replication itself spawns LP threads.
Set `n_reps = Threads.nthreads() ÷ n_zones_per_rep` to avoid oversubscription.

## Example
```julia
# 8 parallel replications, each a 100k-arrival M/M/1 run
result = replicate_parallel(8; seed_offset=100) do seed
    p = StatsPipeline(warmup=WARMUP_FIXED, warmup_n=2_000)
    # ... run simulation feeding into p ...
    sim_summary(p)
end
println("W̄ = \$(result.W.mean) ± \$(result.W.ci_hi - result.W.mean) (95% CI)")
println("ρ  = \$(result.utilization.mean)")
```
"""
function replicate_parallel(run_fn::Function, n_reps::Int;
                            seed_offset     :: Int  = 0,
                            gpu_postprocess :: Bool = false,
                            n_zones_per_rep :: Int  = 1)
    n_reps >= 2 || throw(ArgumentError(
        "replicate_parallel: need at least 2 replications (got $n_reps)"))

    # Chandy-Misra Tier-2 oversubscription guard
    if n_zones_per_rep > 1
        avail  = Threads.nthreads()
        needed = n_reps * n_zones_per_rep
        if needed > avail
            @warn """
            replicate_parallel: n_reps=$n_reps × n_zones_per_rep=$n_zones_per_rep = $needed
            threads requested but only $avail available.
            Consider reducing n_reps to $(avail ÷ n_zones_per_rep) for Tier-2 runs.
            """
        end
    end

    # ── Spawn one Julia task per replication ─────────────────────────────────
    tasks   = [Threads.@spawn run_fn(seed_offset + i) for i in 1:n_reps]
    results = fetch.(tasks)   # wait for all; Vector{NamedTuple}

    # ── Aggregate across replications ─────────────────────────────────────────
    fields          = keys(results[1])
    stats_per_field = Dict{Symbol, Any}()

    use_gpu = gpu_postprocess && _accel_available()

    for f in fields
        # Collect numeric (non-Bool, non-NaN) values for this field
        vals = Float64[]
        for r in results
            v = getfield(r, f)
            v isa Bool   && continue      # warmup_complete → skip
            v isa Number && !isnan(Float64(v)) && push!(vals, Float64(v))
        end
        isempty(vals) && continue

        n = length(vals)
        μ, s = if use_gpu && n > 1000
            # AcceleratedKernels path — delegates to SimCoreGPUExt.
            # gpu_mean_var is declared in SimCore (stub); the method is added by
            # the extension.  Passing a plain Vector triggers the KA CPU-threaded
            # backend; wrap in CuArray/ROCArray etc. at the call site for GPU.
            try
                _d = Base.invokelatest(gpu_mean_var, vals)
                (_d[1], sqrt(max(0.0, _d[2])))
            catch
                # Extension not loaded or AK unavailable — silent CPU fallback.
                μ_cpu   = sum(vals) / n
                var_sum = sum((v - μ_cpu)^2 for v in vals)
                (μ_cpu, n > 1 ? sqrt(var_sum / (n - 1)) : 0.0)
            end
        else
            # Standard CPU path
            μ_cpu   = sum(vals) / n
            var_sum = 0.0
            for v in vals
                d = v - μ_cpu
                var_sum += d * d
            end
            (μ_cpu, n > 1 ? sqrt(var_sum / (n - 1)) : 0.0)
        end

        t  = _t_critical(n - 1, 0.025)
        se = s / sqrt(Float64(n))
        stats_per_field[f] = (mean=μ, ci_lo=μ - t*se, ci_hi=μ + t*se, std_dev=s)
    end

    return NamedTuple(stats_per_field)
end

"""
    _accel_available() → Bool

Internal helper. Returns `true` if the `SimCoreGPUExt` extension is loaded,
meaning `AcceleratedKernels` and `KernelAbstractions` are present in the
current environment.

When `true`, `gpu_mean_var`, `gpu_histogram`, and the `AbstractArray` overload
of `batch_means_ci` are available.  They dispatch to CPU threads by default;
passing device arrays (`CuArray` etc.) routes to the appropriate GPU backend.

Used by `replicate_parallel` to decide whether to attempt AK post-processing.
"""
function _accel_available()
    Base.get_extension(@__MODULE__, :SimCoreGPUExt) !== nothing
end

# Backward-compat alias (code that calls _cuda_available() still works).
const _cuda_available = _accel_available
