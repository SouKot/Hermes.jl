"""
    collectors.jl — Streaming statistics collectors for StatsPipeline

Implements the `AbstractCollector` protocol and five concrete collectors:

| Type                   | Tracks                         | Algorithm           |
|------------------------|--------------------------------|---------------------|
| `MeanCollector`        | W̄, W̄q (mean sojourn/wait)    | Welford online      |
| `WeightedMeanCollector`| L̄, L̄q, ρ, A (time-weighted)  | Exact weighted mean |
| `P2QuantileCollector`  | P50/P95/P99 sojourn/wait       | Jain & Chlamtac P²  |
| `ExtremaCollector`     | min/max queue length, sojourn  | Running min/max     |
| `CounterCollector`     | arrivals, departures, events   | Integer accumulator |

## Protocol

Every collector satisfies this interface:

```julia
fit!(c, x::Float64)            # O(1) unweighted observation
fit!(c, x::Float64, w::Float64)# O(1) weighted observation (w = Δt)
value(c)                       # → Float64 or NamedTuple; NaN/sentinel if n=0
merge!(dst, src)               # combine src into dst (for Tier-2 PDES LP merge)
reset!(c)                      # clear all state; c is reusable
```

## Design constraints

- **Zero allocation** in `fit!` / `value` for all collectors.
- **No dependencies** on OnlineStats.jl or any external package.
- **Thread safety**: individual collectors are NOT thread-safe. StatsPipeline
  creates one pipeline per LP (Chandy-Misra Tier-2) and merges after simulation.
- All `fit!` hot-paths are `@inline` for inlining at call sites.
- P² marker inner loop uses `@inbounds` (indices are always 1–5).

Design ref: Sprint 4I · Tasks 1-6
"""

# ─────────────────────────────────────────────────────────────────────────────
# TASK 1 — AbstractCollector protocol
# ─────────────────────────────────────────────────────────────────────────────

"""
    AbstractCollector

Abstract supertype for all streaming statistics collectors.

## Required methods

Every concrete subtype must implement:

```julia
fit!(c::MyCollector, x::Float64)             # unweighted observation
fit!(c::MyCollector, x::Float64, w::Float64) # weighted (w = Δt); may ignore w
value(c::MyCollector)                        # current estimate; NaN if n=0
merge!(dst::MyCollector, src::MyCollector)   # combine src into dst; return dst
reset!(c::MyCollector)                       # clear all state; return c
```

## Protocol compatibility

Method names match OnlineStatsBase (`fit!`, `value`, `merge!`) for potential
future interoperability, but this package intentionally avoids depending on it.
"""
abstract type AbstractCollector end

# Extend Base.merge! for all collector types (avoids export ambiguity with Base.merge!)
import Base: merge!

# ─────────────────────────────────────────────────────────────────────────────
# TASK 2 — MeanCollector
# Numerically stable running mean via Welford's online algorithm.
# Used for: W̄ (mean sojourn time), W̄q (mean wait time in queue).
# ─────────────────────────────────────────────────────────────────────────────

"""
    MeanCollector <: AbstractCollector

Numerically stable running mean using Welford's online algorithm.
Processes one unweighted observation at a time in O(1) time and O(1) memory.

## Fields
- `n    :: Int`     — number of observations received
- `mean :: Float64` — current running mean

## Accuracy
Welford's update `mean += (x - mean) / n` avoids catastrophic cancellation
that plagues naive `sum / n` accumulation for large n or values far from zero.

## Merge
`merge!(dst, src)` uses the exact parallel mean formula:
`n_new = dst.n + src.n; mean_new = (dst.n × dst.mean + src.n × src.mean) / n_new`
This is used for combining per-LP statistics in Chandy-Misra Tier-2 PDES.
"""
mutable struct MeanCollector <: AbstractCollector
    n    :: Int
    mean :: Float64
end

"""    MeanCollector() → MeanCollector"""
MeanCollector() = MeanCollector(0, 0.0)

"""
    fit!(c::MeanCollector, x::Float64) → c

Update running mean with one observation x (Welford step).
"""
@inline function fit!(c::MeanCollector, x::Float64)
    c.n   += 1
    c.mean += (x - c.mean) / c.n
    return c
end

"""
    fit!(c::MeanCollector, x::Float64, w::Float64) → c

Weight is ignored for MeanCollector (use WeightedMeanCollector for time-weighted means).
Provided for protocol compatibility with the AbstractCollector interface.
"""
@inline fit!(c::MeanCollector, x::Float64, ::Float64) = fit!(c, x)

"""
    value(c::MeanCollector) → Float64

Return the current running mean, or `NaN` if no observations have been received.
"""
@inline value(c::MeanCollector) = c.n == 0 ? NaN : c.mean

"""
    merge!(dst::MeanCollector, src::MeanCollector) → dst

Combine `src` into `dst` using the exact parallel mean formula.
After merging, `dst` reflects all observations from both collectors.
`src` is left unchanged.
"""
function Base.merge!(dst::MeanCollector, src::MeanCollector)
    src.n == 0 && return dst
    if dst.n == 0
        dst.n    = src.n
        dst.mean = src.mean
    else
        n_new    = dst.n + src.n
        dst.mean = (dst.n * dst.mean + src.n * src.mean) / n_new
        dst.n    = n_new
    end
    return dst
end

"""
    reset!(c::MeanCollector) → c

Clear all state. `c` is reusable after reset.
"""
function reset!(c::MeanCollector)
    c.n    = 0
    c.mean = 0.0
    return c
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 3 — WeightedMeanCollector
# Time-weighted mean for area-under-curve metrics.
# Used for: L̄ (mean system size), L̄q (queue size), ρ (utilization), A (avail).
# ─────────────────────────────────────────────────────────────────────────────

"""
    WeightedMeanCollector <: AbstractCollector

Computes the time-weighted (area-under-curve) mean.

The weighted mean is `Σ(x·w) / Σ(w)`, where `w = Δt` (time elapsed at level x).
This is the correct formula for PASTA-based queue statistics:

- `L̄ = Σ(L·Δt) / total_elapsed_time`   (mean system occupancy)
- `ρ  = Σ(busy_Δt) / total_elapsed_time` (server utilization)
- `A  = Σ(uptime_Δt) / total_elapsed_time` (machine availability)

## Fields
- `weighted_sum  :: Float64` — Σ (x × w)
- `total_weight  :: Float64` — Σ w  (= total elapsed simulation time for L̄)
"""
mutable struct WeightedMeanCollector <: AbstractCollector
    weighted_sum  :: Float64
    total_weight  :: Float64
end

"""    WeightedMeanCollector() → WeightedMeanCollector"""
WeightedMeanCollector() = WeightedMeanCollector(0.0, 0.0)

"""
    fit!(c::WeightedMeanCollector, x::Float64, w::Float64) → c

Update weighted accumulator: `weighted_sum += x × w`, `total_weight += w`.
`w` should be the time interval (Δt) during which the system was at level `x`.
"""
@inline function fit!(c::WeightedMeanCollector, x::Float64, w::Float64)
    c.weighted_sum  += x * w
    c.total_weight  += w
    return c
end

"""
    fit!(c::WeightedMeanCollector, x::Float64) → c

Convenience overload: equivalent to `fit!(c, x, 1.0)`.
Used when each observation has uniform weight (e.g., for testing).
"""
@inline fit!(c::WeightedMeanCollector, x::Float64) = fit!(c, x, 1.0)

"""
    value(c::WeightedMeanCollector) → Float64

Return `weighted_sum / total_weight`, or `NaN` if `total_weight == 0`.
"""
@inline value(c::WeightedMeanCollector) =
    c.total_weight == 0.0 ? NaN : c.weighted_sum / c.total_weight

"""
    merge!(dst::WeightedMeanCollector, src::WeightedMeanCollector) → dst

Merge `src` into `dst` by summing weighted sums and total weights.
Exact: `(Σ₁ x·w + Σ₂ x·w) / (Σ₁ w + Σ₂ w)`.
"""
function Base.merge!(dst::WeightedMeanCollector, src::WeightedMeanCollector)
    dst.weighted_sum += src.weighted_sum
    dst.total_weight += src.total_weight
    return dst
end

"""
    reset!(c::WeightedMeanCollector) → c

Clear all state.
"""
function reset!(c::WeightedMeanCollector)
    c.weighted_sum = 0.0
    c.total_weight = 0.0
    return c
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 4 — P2QuantileCollector
# O(1) memory quantile estimation using Jain & Chlamtac (1985) P² algorithm.
# Used for: P50, P95, P99 sojourn time and wait time.
# ─────────────────────────────────────────────────────────────────────────────

"""
    P2QuantileCollector <: AbstractCollector

O(1) memory streaming quantile estimator using the P² algorithm.

## Algorithm
Jain, R. & Chlamtac, I. (1985). *The P² algorithm for dynamic calculation of
quantiles and histograms without storing observations.* CACM 28(10), 1076–1085.

Maintains 5 marker heights and positions that track the 0%, p/2, p, (1+p)/2,
and 100% quantiles. Each `fit!` call is O(1) with no allocations. Accuracy
is sufficient for simulation output analysis (typically within 1–3% of true
quantile for large n).

## Fields
- `p   :: Float64`          — target quantile (e.g., 0.95 for P95)
- `n   :: Int`              — total observations received
- `q   :: Vector{Float64}`  — 5 marker heights (quantile estimates)
- `dn  :: Vector{Float64}`  — per-step desired position increments (constant)
- `np  :: Vector{Float64}`  — desired marker positions (updated each step)
- `pos :: Vector{Int}`      — actual marker positions (integers)

## Merge
Merging two independent P² streams is **not supported** and raises `ArgumentError`.
For parallel/multi-thread use, collect raw samples (`record_samples=true`) or
use per-thread collectors and report them separately.

## Usage
```julia
c = P2QuantileCollector(0.95)   # track P95
for x in observations
    fit!(c, x)
end
p95 = value(c)   # NaN if fewer than 5 observations
```
"""
mutable struct P2QuantileCollector <: AbstractCollector
    p   :: Float64          # target quantile ∈ (0, 1)
    n   :: Int              # total observations
    q   :: Vector{Float64}  # 5 marker heights
    dn  :: Vector{Float64}  # 5 desired-position increments (constant after init)
    np  :: Vector{Float64}  # 5 desired marker positions (floats, updated per obs)
    pos :: Vector{Int}      # 5 actual marker positions (integers)
end

"""
    P2QuantileCollector(p::Float64) → P2QuantileCollector

Construct a P² quantile collector for quantile `p ∈ (0, 1)`.

Initial desired positions after 5 bootstrap observations:
`np = [1, 1+2p, 1+4p, 3+2p, 5]`

Per-step desired-position increments:
`dn = [0, p/2, p, (1+p)/2, 1]`
"""
function P2QuantileCollector(p::Float64)
    @assert 0.0 < p < 1.0 "Quantile p must be in (0,1), got p=$p"
    dn  = [0.0, p/2, p, (1+p)/2, 1.0]
    np  = [1.0, 1+2p, 1+4p, 3+2p, 5.0]
    pos = [1, 2, 3, 4, 5]
    P2QuantileCollector(p, 0, zeros(5), dn, np, pos)
end

"""
    fit!(c::P2QuantileCollector, x::Float64) → c

Update quantile estimate with one observation `x`.

For the first 5 observations, values are stored directly (initialization phase).
After 5 observations, the full P² update runs in O(1) per call.
"""
@inline function fit!(c::P2QuantileCollector, x::Float64)
    c.n += 1
    n = c.n

    # ── Initialization phase (first 5 observations) ───────────────────────
    if n <= 5
        @inbounds c.q[n] = x
        if n == 5
            sort!(c.q)
            # pos and np were already set to their post-5 initial values
        end
        return c
    end

    # ── Full P² update (n > 5) ────────────────────────────────────────────
    q   = c.q
    np  = c.np
    dn  = c.dn
    pos = c.pos

    @inbounds begin
        # Step 1: find cell j where q[j] ≤ x < q[j+1]
        # Special cases: update extremes
        if x < q[1]
            q[1] = x
            j = 1
        elseif x < q[2]
            j = 1
        elseif x < q[3]
            j = 2
        elseif x < q[4]
            j = 3
        elseif x <= q[5]
            j = 4
        else
            q[5] = x
            j = 4
        end

        # Step 2: increment actual positions for markers j+1 to 5
        for i in (j+1):5
            pos[i] += 1
        end

        # Step 3: update desired positions
        for i in 1:5
            np[i] += dn[i]
        end

        # Step 4: adjust marker heights (markers 2, 3, 4 only)
        for i in 2:4
            d = np[i] - pos[i]
            if (d >= 1.0 && pos[i+1] - pos[i] > 1) ||
               (d <= -1.0 && pos[i-1] - pos[i] < -1)
                ds = d > 0.0 ? 1 : -1

                # Parabolic (P²) interpolation formula
                qi   = q[i]
                qi_p = q[i + ds]    # marker in direction of adjustment
                qi_n = q[i - ds]    # marker opposite direction
                pi   = Float64(pos[i])
                pi_p = Float64(pos[i + ds])
                pi_n = Float64(pos[i - ds])

                q_new = qi + ds / (pi_p - pi_n) * (
                    (pi - pi_n + ds) * (qi_p - qi) / (pi_p - pi) +
                    (pi_p - pi - ds) * (qi - qi_n) / (pi - pi_n)
                )

                # Check monotonicity; fall back to linear if violated
                if qi_n < q_new < qi_p
                    q[i] = q_new
                else
                    # Linear interpolation fallback
                    q[i] = qi + ds * (q[i + ds] - qi) / (pos[i + ds] - pos[i])
                end

                pos[i] += ds
            end
        end
    end # @inbounds

    return c
end

"""
    fit!(c::P2QuantileCollector, x::Float64, w::Float64) → c

Weight is ignored for P2QuantileCollector (P² is sample-based, not time-weighted).
Provided for protocol compatibility.
"""
@inline fit!(c::P2QuantileCollector, x::Float64, ::Float64) = fit!(c, x)

"""
    value(c::P2QuantileCollector) → Float64

Return the current quantile estimate (height of marker 3 = the target quantile).
Returns `NaN` if fewer than 5 observations have been received.
"""
@inline value(c::P2QuantileCollector) =
    c.n < 5 ? NaN : @inbounds c.q[3]

"""
    merge!(::P2QuantileCollector, ::P2QuantileCollector)

**Not supported.** Raises `ArgumentError`.

P² maintains marker positions relative to a single observation stream.
Merging two independent P² instances produces an undefined quantile estimate
because the desired-position increments are calibrated to the total n of each stream.

### Alternatives for parallel / multi-thread use:

1. **Raw samples** — `StatsPipeline(record_samples=true)` buffers raw sojourn/wait
   values and computes exact quantiles post-hoc.
2. **Per-replication reporting** — `replicate_parallel()` returns CI across replications;
   each replication has its own P² estimate.
3. **Multiple collectors** — report P² from each LP thread independently (Tier-2 PDES).
"""
function Base.merge!(::P2QuantileCollector, ::P2QuantileCollector)
    throw(ArgumentError("""
        P2QuantileCollector does not support merge!.

        The P² algorithm maintains marker positions calibrated to the observation
        count of a single stream — combining two streams produces an undefined result.

        Alternatives:
          • StatsPipeline(record_samples=true) → exact post-hoc quantiles
          • replicate_parallel() → CI across replication summaries
          • Report per-LP P² estimates separately (Tier-2 PDES)
    """))
end

"""
    reset!(c::P2QuantileCollector) → c

Reinitialize all P² state. `c` is reusable after reset.
Marker heights, desired positions, and actual positions return to their
post-construction defaults for quantile `c.p`.
"""
function reset!(c::P2QuantileCollector)
    c.n = 0
    fill!(c.q, 0.0)
    p = c.p
    @inbounds begin
        c.dn[1] = 0.0;   c.dn[2] = p/2;   c.dn[3] = p;
        c.dn[4] = (1+p)/2;                  c.dn[5] = 1.0
        c.np[1] = 1.0;   c.np[2] = 1+2p;  c.np[3] = 1+4p
        c.np[4] = 3+2p;                     c.np[5] = 5.0
        c.pos[1] = 1;    c.pos[2] = 2;     c.pos[3] = 3
        c.pos[4] = 4;                       c.pos[5] = 5
    end
    return c
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 5 — ExtremaCollector
# Running minimum and maximum.
# Used for: peak queue length, min/max sojourn, min/max L.
# ─────────────────────────────────────────────────────────────────────────────

"""
    ExtremaCollector <: AbstractCollector

Tracks the minimum and maximum observed value over a stream of observations.

## Fields
- `min_val :: Float64` — running minimum (initialized to `Inf`)
- `max_val :: Float64` — running maximum (initialized to `-Inf`)
- `n       :: Int`     — number of observations

## Value
`value(c)` returns a `NamedTuple{(:min, :max), Tuple{Float64,Float64}}`.
Returns `(min=NaN, max=NaN)` if no observations have been received.
"""
mutable struct ExtremaCollector <: AbstractCollector
    min_val :: Float64
    max_val :: Float64
    n       :: Int
end

"""    ExtremaCollector() → ExtremaCollector"""
ExtremaCollector() = ExtremaCollector(Inf, -Inf, 0)

"""
    fit!(c::ExtremaCollector, x::Float64) → c

Update running extrema with observation `x`.
"""
@inline function fit!(c::ExtremaCollector, x::Float64)
    c.n += 1
    x < c.min_val && (c.min_val = x)
    x > c.max_val && (c.max_val = x)
    return c
end

"""
    fit!(c::ExtremaCollector, x::Float64, w::Float64) → c

Weight is ignored. Provided for protocol compatibility.
"""
@inline fit!(c::ExtremaCollector, x::Float64, ::Float64) = fit!(c, x)

"""
    value(c::ExtremaCollector) → NamedTuple

Return `(min=..., max=...)`, or `(min=NaN, max=NaN)` if no observations.
"""
@inline function value(c::ExtremaCollector)
    c.n == 0 && return (min=NaN, max=NaN)
    return (min=c.min_val, max=c.max_val)
end

"""
    merge!(dst::ExtremaCollector, src::ExtremaCollector) → dst

Combine by taking the global min and max of both collectors.
"""
function Base.merge!(dst::ExtremaCollector, src::ExtremaCollector)
    src.n == 0 && return dst
    dst.n += src.n
    dst.min_val = min(dst.min_val, src.min_val)
    dst.max_val = max(dst.max_val, src.max_val)
    return dst
end

"""
    reset!(c::ExtremaCollector) → c

Clear all state. Sentinels return to `Inf` / `-Inf`.
"""
function reset!(c::ExtremaCollector)
    c.min_val = Inf
    c.max_val = -Inf
    c.n       = 0
    return c
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 6 — CounterCollector
# Integer event counter.
# Used for: total_arrivals, total_departures, blocked_count, total_events.
# ─────────────────────────────────────────────────────────────────────────────

"""
    CounterCollector <: AbstractCollector

Simple integer counter for event counts.

## Fields
- `count :: Int` — accumulated count (starts at 0)

## Usage
```julia
c = CounterCollector()
fit!(c, 1)      # increment by 1 (most common)
fit!(c, 3)      # increment by 3 (batch events)
value(c)        # → 4
```
"""
mutable struct CounterCollector <: AbstractCollector
    count :: Int
end

"""    CounterCollector() → CounterCollector"""
CounterCollector() = CounterCollector(0)

"""
    fit!(c::CounterCollector, n::Int = 1) → c

Increment the counter by `n` (default: 1).
"""
@inline function fit!(c::CounterCollector, n::Int = 1)
    c.count += n
    return c
end

"""
    fit!(c::CounterCollector, x::Float64) → c

Protocol-compatible overload: increments by 1 regardless of `x`.
`x` is treated as a presence signal (like `fit!(arrivals, 1.0)` from a pipeline).
For explicit increment amounts, use the `Int` overload.
"""
@inline fit!(c::CounterCollector, ::Float64) = fit!(c, 1)

"""
    fit!(c::CounterCollector, x::Float64, ::Float64) → c

Weight is ignored. Provided for protocol compatibility.
"""
@inline fit!(c::CounterCollector, ::Float64, ::Float64) = fit!(c, 1)

"""
    value(c::CounterCollector) → Int

Return the current count.
"""
@inline value(c::CounterCollector) = c.count

"""
    merge!(dst::CounterCollector, src::CounterCollector) → dst

Add `src.count` to `dst.count`.
"""
@inline function Base.merge!(dst::CounterCollector, src::CounterCollector)
    dst.count += src.count
    return dst
end

"""
    reset!(c::CounterCollector) → c

Reset count to zero.
"""
@inline function reset!(c::CounterCollector)
    c.count = 0
    return c
end
