"""
    pipeline.jl — StatsPipeline: composable, warmup-aware simulation statistics

# Architecture

```
SimEvent → record_*!(pipeline, ...) → tick_warmup! → [gate] → fit!(collector, ...)
                                                                      ↓
                                                              sim_summary(pipeline)
                                                                      ↓
                                                              NamedTuple (W̄, L̄, ρ, …)
```

## Three analysis workflows

| Workflow       | Construction                                  | Overhead  |
|----------------|-----------------------------------------------|-----------|
| Fast streaming | `StatsPipeline()`                             | O(1)/obs  |
| Deep analysis  | `StatsPipeline(record_samples=true)`          | O(n) mem  |
| Monte Carlo    | `replicate_parallel(n)` (see analysis.jl)     | N × above |

## Warmup modes

| Mode              | Behaviour                                           |
|-------------------|-----------------------------------------------------|
| `WARMUP_AUTO`     | WelchDetector gates stats; auto-detects steady state|
| `WARMUP_NONE`     | No warmup; stats from first event (terminating sims)|
| `WARMUP_FIXED`    | Open after `warmup_n` departures                    |
| `WARMUP_IMMEDIATE`| Alias for `:none`; explicit user opt-in             |

Design ref: Sprint 4I · Tasks 7-13
"""

# ─────────────────────────────────────────────────────────────────────────────
# TASK 7 — WarmupPolicy
# ─────────────────────────────────────────────────────────────────────────────

"""
    @enum WarmupMode

Controls when `StatsPipeline` begins recording statistics.

| Value              | Behaviour                                            |
|--------------------|------------------------------------------------------|
| `WARMUP_AUTO`      | Default. WelchDetector gates stats; auto-detects steady state |
| `WARMUP_NONE`      | No warmup; record from first event (terminating sims)|
| `WARMUP_FIXED`     | Open after exactly `warmup_n` departures             |
| `WARMUP_IMMEDIATE` | Alias for NONE; explicit expert opt-in               |
"""
@enum WarmupMode begin
    WARMUP_AUTO       # Use WelchDetector (default for steady-state)
    WARMUP_NONE       # No warm-up — stats from first event (terminating sims)
    WARMUP_FIXED      # Open after warmup_n departures
    WARMUP_IMMEDIATE  # Alias for :none (for expert users)
end

"""
    WarmupPolicy

Encapsulates warm-up state for a `StatsPipeline`.
The pipeline delegates all warm-up gating decisions to this object.

# Fields
- `mode          :: WarmupMode`                  — active warmup strategy
- `warmup_n      :: Int`                         — departure threshold (WARMUP_FIXED only)
- `_n_departures :: Int`                         — departure counter (WARMUP_FIXED internal)
- `_welch        :: Union{WelchDetector, Nothing}` — detector (WARMUP_AUTO only)
- `complete      :: Bool`                        — true = start recording stats
"""
mutable struct WarmupPolicy
    mode          :: WarmupMode
    warmup_n      :: Int
    _n_departures :: Int
    _welch        :: Union{WelchDetector, Nothing}
    complete      :: Bool
end

"""
    WarmupPolicy(; mode=WARMUP_AUTO, warmup_n=1000,
                   welch_window_size=200, welch_threshold=0.05) → WarmupPolicy
"""
function WarmupPolicy(;
    mode              :: WarmupMode = WARMUP_AUTO,
    warmup_n          :: Int        = 1000,
    welch_window_size :: Int        = 200,
    welch_threshold   :: Float64    = 0.05,
)
    welch    = mode == WARMUP_AUTO ?
               WelchDetector(window_size=welch_window_size, threshold=welch_threshold) :
               nothing
    is_open  = mode in (WARMUP_NONE, WARMUP_IMMEDIATE)
    WarmupPolicy(mode, warmup_n, 0, welch, is_open)
end

"""
    tick_warmup!(policy, queue_length, n_departures) → Bool

Update warmup state. Returns `true` if statistics should be recorded (warmup complete).
Call this at **every event** BEFORE routing observations to collectors.

- For `WARMUP_AUTO`: feeds `queue_length` to the WelchDetector.
- For `WARMUP_FIXED`: checks whether `n_departures >= warmup_n`.
- For `WARMUP_NONE` / `WARMUP_IMMEDIATE`: always returns `true`.
"""
@inline function tick_warmup!(policy::WarmupPolicy, queue_length::Float64, n_departures::Int)
    policy.complete && return true
    if policy.mode == WARMUP_AUTO
        update!(policy._welch, queue_length)
        policy.complete = warmup_complete(policy._welch)
    elseif policy.mode == WARMUP_FIXED
        policy.complete = (n_departures >= policy.warmup_n)
    end
    return policy.complete
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 8 — StatsPipeline struct + constructor
# ─────────────────────────────────────────────────────────────────────────────

"""
    StatsPipeline

Composable, extensible, warmup-aware statistics pipeline for DES simulations.

Replaces the monolithic `SimStats` accumulator with a modular design:
each metric is a self-contained `AbstractCollector` with a uniform `fit!` / `value`
/ `merge!` / `reset!` protocol.

## Built-in collectors

| Field         | Type                    | Metric                        |
|---------------|-------------------------|-------------------------------|
| `sojourn`     | `MeanCollector`         | W̄ — mean sojourn time        |
| `wait`        | `MeanCollector`         | W̄q — mean wait in queue      |
| `sys_size`    | `WeightedMeanCollector` | L̄ — mean system occupancy    |
| `q_size`      | `WeightedMeanCollector` | L̄q — mean queue-only size   |
| `util`        | `WeightedMeanCollector` | ρ — server utilization        |
| `avail`       | `WeightedMeanCollector` | A — machine availability      |
| `sojourn_q`   | `P2QuantileCollector`   | P95 sojourn (or custom p)     |
| `wait_q`      | `P2QuantileCollector`   | P95 wait (or custom p)        |
| `queue_ext`   | `ExtremaCollector`      | min/max system occupancy      |
| `arrivals`    | `CounterCollector`      | post-warmup arrivals          |
| `departures`  | `CounterCollector`      | post-warmup departures        |
| `blocked`     | `CounterCollector`      | blocked entities              |
| `events`      | `CounterCollector`      | total events processed        |

## Extending the pipeline

```julia
# Add a P99 sojourn collector
p99 = P2QuantileCollector(0.99)
add_collector!(pipeline, :p99_sojourn, p99;
               trigger = :departure,
               extract = d -> d.sojourn)
```

## Workflow choice

```julia
StatsPipeline()                              # Workflow 1: streaming (default)
StatsPipeline(record_samples=true)           # Workflow 2: post-hoc / batch-means CI
StatsPipeline(warmup=WARMUP_FIXED, warmup_n=5000)  # fixed warmup period
StatsPipeline(warmup=WARMUP_NONE)            # terminating simulation
```
"""
mutable struct StatsPipeline
    warmup        :: WarmupPolicy
    # Built-in collectors ─────────────────────────────────────────────────────
    sojourn       :: MeanCollector
    wait          :: MeanCollector
    sys_size      :: WeightedMeanCollector
    q_size        :: WeightedMeanCollector
    util          :: WeightedMeanCollector
    avail         :: WeightedMeanCollector
    sojourn_q     :: P2QuantileCollector
    wait_q        :: P2QuantileCollector
    queue_ext     :: ExtremaCollector
    arrivals      :: CounterCollector
    departures    :: CounterCollector
    blocked       :: CounterCollector
    events        :: CounterCollector
    # User-registered collectors ──────────────────────────────────────────────
    _custom       :: Vector{Any}   # (name, collector, trigger, extract)
    # Raw counters (never gated by warmup) ────────────────────────────────────
    _total_arrivals_raw   :: Int
    _total_departures_raw :: Int
    _total_departures_postwarmup :: Int
    # Post-hoc sample buffers (Workflow 2; only allocated when _record_samples=true)
    _record_samples   :: Bool
    _max_samples      :: Int
    _sojourn_samples  :: Vector{Float64}
    _wait_samples     :: Vector{Float64}
end

"""
    StatsPipeline(; warmup=WARMUP_AUTO, warmup_n=1000,
                    sojourn_quantile=0.95, wait_quantile=0.95,
                    welch_window=200, welch_threshold=0.05,
                    record_samples=false, max_samples=500_000) → StatsPipeline

Construct a new statistics pipeline.

# Key options
- `warmup` : warmup mode (`WARMUP_AUTO` / `WARMUP_FIXED` / `WARMUP_NONE` / `WARMUP_IMMEDIATE`)
- `warmup_n` : departure count for `WARMUP_FIXED` (ignored for other modes)
- `sojourn_quantile` : target quantile for P² sojourn estimator (default 0.95 = P95)
- `wait_quantile`    : target quantile for P² wait estimator (default 0.95)
- `record_samples` : when `true`, buffers raw sojourn/wait per departure for
  post-hoc analysis (`batch_means_ci`, GPU histogram). Default `false` — zero overhead.
- `max_samples` : cap on sample buffer size to prevent unbounded memory growth
  (default 500_000 ≈ 4 MB per buffer).

# Examples
```julia
# Workflow 1: fast streaming stats
p = StatsPipeline()

# Workflow 2: deep single-run analysis with raw samples
p = StatsPipeline(record_samples=true, max_samples=1_000_000)

# Terminating simulation (no warmup)
p = StatsPipeline(warmup=WARMUP_NONE)

# Fixed warmup: ignore first 10_000 departures
p = StatsPipeline(warmup=WARMUP_FIXED, warmup_n=10_000)
```
"""
function StatsPipeline(;
    warmup            :: WarmupMode = WARMUP_AUTO,
    warmup_n          :: Int        = 1000,
    sojourn_quantile  :: Float64    = 0.95,
    wait_quantile     :: Float64    = 0.95,
    welch_window      :: Int        = 200,
    welch_threshold   :: Float64    = 0.05,
    record_samples    :: Bool       = false,
    max_samples       :: Int        = 500_000,
)
    policy = WarmupPolicy(mode=warmup, warmup_n=warmup_n,
                          welch_window_size=welch_window,
                          welch_threshold=welch_threshold)
    sj_buf, wt_buf = if record_samples
        sizehint!(Float64[], max_samples), sizehint!(Float64[], max_samples)
    else
        Float64[], Float64[]   # empty; never grown when record_samples=false
    end
    StatsPipeline(
        policy,
        MeanCollector(), MeanCollector(),
        WeightedMeanCollector(), WeightedMeanCollector(),
        WeightedMeanCollector(), WeightedMeanCollector(),
        P2QuantileCollector(sojourn_quantile),
        P2QuantileCollector(wait_quantile),
        ExtremaCollector(),
        CounterCollector(), CounterCollector(), CounterCollector(), CounterCollector(),
        Any[],
        0, 0, 0,
        record_samples, max_samples, sj_buf, wt_buf,
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 9 — record_*! overloads for StatsPipeline
# Drop-in replacements for the SimStats record_*! functions.
# ─────────────────────────────────────────────────────────────────────────────

"""
    record_arrival!(p::StatsPipeline) → p

Record one entity arriving to the system.
Always increments raw arrival counter and `events`/`arrivals` collectors.
Custom `:arrival` collectors are fired regardless of warmup state.
"""
function record_arrival!(p::StatsPipeline)
    p._total_arrivals_raw += 1
    fit!(p.arrivals, 1)
    fit!(p.events, 1)
    _fire_custom!(p, :arrival, nothing)
    return p
end

"""
    record_departure!(p::StatsPipeline, wait_time::Float64, sojourn_time::Float64) → p

Record one entity departure with its wait and sojourn times.

- Always increments raw departure counter and `departures`/`events` collectors.
- Feeds `sojourn_time` to the WelchDetector (for `WARMUP_AUTO`).
- **After warmup**: updates `sojourn`, `sojourn_q`, `wait`, `wait_q` collectors.
- **If `record_samples=true`**: appends to raw sample buffers (Workflow 2).

# Arguments
- `wait_time`    — time spent waiting in queue (Wq for this entity)
- `sojourn_time` — total time in system (W for this entity) = wait + service
"""
function record_departure!(p::StatsPipeline, wait_time::Float64, sojourn_time::Float64)
    p._total_departures_raw += 1
    fit!(p.departures, 1)
    fit!(p.events, 1)

    # Warmup check — use queue_length=0 as placeholder; Welch watches sojourn itself
    tick_warmup!(p.warmup, sojourn_time, p._total_departures_raw)
    p.warmup.complete || return p
    p._total_departures_postwarmup += 1

    # Post-warmup: streaming stats (always)
    fit!(p.sojourn,   sojourn_time)
    fit!(p.sojourn_q, sojourn_time)
    fit!(p.wait,      wait_time)
    fit!(p.wait_q,    wait_time)

    # Post-warmup: raw sample buffer (Workflow 2 opt-in only)
    if p._record_samples && length(p._sojourn_samples) < p._max_samples
        push!(p._sojourn_samples, sojourn_time)
        push!(p._wait_samples,    wait_time)
    end

    _fire_custom!(p, :departure, (wait=wait_time, sojourn=sojourn_time))
    return p
end

"""
    record_queue_length!(p::StatsPipeline, length_sys::Int, length_q::Int, dt::Float64) → p

Record the current system occupancy held for time interval `dt`.

- `length_sys` — total entities in system (queue + in service)
- `length_q`   — entities waiting in queue only
- `dt`         — time elapsed since last event (the Δt weight for L̄ computation)

After warmup, updates `sys_size`, `q_size`, and `queue_ext`.
"""
function record_queue_length!(p::StatsPipeline, length_sys::Int, length_q::Int, dt::Float64)
    # Feed queue length to WelchDetector (used when mode=WARMUP_AUTO)
    tick_warmup!(p.warmup, Float64(length_sys), p._total_departures_raw)
    p.warmup.complete || return p

    dt <= 0.0 && return p   # guard: skip zero-width intervals
    fit!(p.sys_size,  Float64(length_sys), dt)
    fit!(p.q_size,    Float64(length_q),   dt)
    fit!(p.queue_ext, Float64(length_sys))
    _fire_custom!(p, :queue_change, (sys=length_sys, q=length_q, dt=dt))
    return p
end

"""
    record_queue_length!(p::StatsPipeline, length_sys::Int, dt::Float64) → p

Backward-compatible 2-argument overload. Lq is estimated as `max(0, L - 1)`.
"""
function record_queue_length!(p::StatsPipeline, length_sys::Int, dt::Float64)
    record_queue_length!(p, length_sys, max(0, length_sys - 1), dt)
end

"""
    record_utilization!(p::StatsPipeline, busy_dt::Float64) → p

Record time interval `busy_dt` during which the server was busy.
After warmup, updates the `util` (server utilization) weighted mean collector.
`ρ = busy_time / elapsed_time` is recovered via `value(p.util)`.
"""
function record_utilization!(p::StatsPipeline, busy_dt::Float64)
    p.warmup.complete || return p
    fit!(p.util, 1.0, busy_dt)   # 1.0 = "busy"; weight = duration
    return p
end

"""
    record_idle!(p::StatsPipeline, idle_dt::Float64) → p

Record time interval `idle_dt` during which the server was idle.
Required to correctly normalize utilization when the server is not always busy.

Calling pattern:
```julia
# At every state transition:
record_utilization!(p, server_was_busy ? dt : 0.0)
record_idle!(p,         server_was_busy ? 0.0 : dt)
```
"""
function record_idle!(p::StatsPipeline, idle_dt::Float64)
    p.warmup.complete || return p
    fit!(p.util, 0.0, idle_dt)   # 0.0 = "idle"; weight = duration → keeps denominator growing
    return p
end

"""
    record_uptime!(p::StatsPipeline, dt::Float64) → p

Record time interval `dt` during which the resource was available.
Used to compute machine availability: A = uptime / elapsed_sim_time.
"""
function record_uptime!(p::StatsPipeline, dt::Float64)
    p.warmup.complete || return p
    fit!(p.avail, 1.0, dt)
    return p
end

"""
    record_blocked!(p::StatsPipeline) → p

Record one entity rejected due to a finite buffer (M/M/1/K model).
Always increments regardless of warmup state.
"""
function record_blocked!(p::StatsPipeline)
    p._total_arrivals_raw += 1
    fit!(p.blocked, 1)
    fit!(p.events, 1)
    return p
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 10 — add_collector! (user extension API)
# ─────────────────────────────────────────────────────────────────────────────

"""
    add_collector!(pipeline, name, collector; trigger, extract) → pipeline

Register a user-defined collector with the pipeline.

# Arguments
- `pipeline`  — target `StatsPipeline`
- `name`      — `Symbol` key; appears in `sim_summary()` output
- `collector` — any `AbstractCollector` subtype (fit!/value/merge!/reset!)
- `trigger`   — when to call `fit!`; one of:
    - `:departure`   — called on each departure (post-warmup)
    - `:arrival`     — called on each arrival (always)
    - `:queue_change`— called on each queue length update (post-warmup)
    - `:utilization` — NOT auto-fired; call manually from event handler
- `extract`   — `Function(event_data) → Float64` — extracts value to pass to `fit!`

# Example
```julia
# Track 99th-percentile sojourn time
p99 = P2QuantileCollector(0.99)
add_collector!(pipeline, :p99_sojourn, p99;
               trigger = :departure,
               extract = d -> d.sojourn)

# Track peak queue length (post-warmup)
peak = ExtremaCollector()
add_collector!(pipeline, :peak_queue, peak;
               trigger = :queue_change,
               extract = d -> Float64(d.sys))
```
"""
function add_collector!(pipeline::StatsPipeline, name::Symbol,
                        collector::AbstractCollector;
                        trigger  :: Symbol,
                        extract  :: Function)
    trigger in (:departure, :arrival, :queue_change, :utilization) ||
        throw(ArgumentError("Unknown trigger :$trigger. Valid: :departure, :arrival, :queue_change, :utilization"))
    push!(pipeline._custom, (name, collector, trigger, extract))
    return pipeline
end

"""
    _fire_custom!(p, trigger, data) — internal

Dispatch all user-registered collectors whose trigger matches.
`data` is the event payload (a NamedTuple or `nothing`).
"""
function _fire_custom!(p::StatsPipeline, trigger::Symbol, data)
    isempty(p._custom) && return   # fast path: no user collectors
    for (_, collector, ctrigger, extract) in p._custom
        ctrigger === trigger || continue
        val = data === nothing ? 1.0 : extract(data)
        fit!(collector, val)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 11 — sim_summary for StatsPipeline
# ─────────────────────────────────────────────────────────────────────────────

"""
    sim_summary(p::StatsPipeline) → NamedTuple

Return all derived metrics as a NamedTuple.

## Backward-compatible keys (identical to `sim_summary(::SimStats)`)
`L`, `Wq`, `W`, `utilization`, `blocking_prob`, `total_arrivals`,
`total_departures`, `blocked_count`, `total_events`

## New keys
`Lq`, `availability`, `throughput`, `W_quantile`, `Wq_quantile`,
`queue_min`, `queue_max`, `warmup_complete`

## User-collector keys
Any collectors registered via `add_collector!` appear here by their name.

# Example
```julia
sm = sim_summary(pipeline)
# Backward-compat:
sm.L, sm.W, sm.Wq, sm.utilization
# New:
sm.Lq, sm.W_quantile, sm.throughput, sm.warmup_complete
# Little's Law check:
check_littles_law(sm)
```
"""
function sim_summary(p::StatsPipeline)
    qt_sojourn = value(p.sojourn_q)
    qt_wait    = value(p.wait_q)
    ext        = value(p.queue_ext)
    total_arr  = p._total_arrivals_raw
    total_dep  = p._total_departures_raw
    total_dep_post = p._total_departures_postwarmup
    blocked_n  = value(p.blocked)

    # Effective throughput λ_eff = departures / elapsed time
    # elapsed time is tracked via the total_weight of sys_size collector
    λ_eff = p.sys_size.total_weight > 0.0 ?
            total_dep_post / p.sys_size.total_weight : NaN

    base = (
        # ── Backward-compatible (same keys as sim_summary(::SimStats)) ──
        L                = value(p.sys_size),
        Wq               = value(p.wait),
        W                = value(p.sojourn),
        utilization      = value(p.util),
        blocking_prob    = total_arr > 0 ? blocked_n / total_arr : 0.0,
        total_arrivals   = total_arr,
        total_departures = total_dep,
        blocked_count    = blocked_n,
        total_events     = value(p.events),
        # ── New metrics ──
        Lq               = value(p.q_size),
        availability     = value(p.avail),
        throughput       = λ_eff,
        W_quantile       = qt_sojourn,
        Wq_quantile      = qt_wait,
        queue_min        = ext.min,
        queue_max        = ext.max,
        warmup_complete  = p.warmup.complete,
    )

    isempty(p._custom) && return base

    # Merge user-defined collector results
    user_vals = Dict{Symbol, Any}()
    for (name, collector, _, _) in p._custom
        user_vals[name] = value(collector)
    end
    return merge(base, NamedTuple(user_vals))
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 12 — reset! for StatsPipeline
# ─────────────────────────────────────────────────────────────────────────────

"""
    reset!(p::StatsPipeline) → p

Reset all collectors and warmup state. `p` is fully reusable after reset.
Warmup mode and parameters are preserved — only the state counters are cleared.
"""
function reset!(p::StatsPipeline)
    reset!(p.sojourn);    reset!(p.wait)
    reset!(p.sys_size);   reset!(p.q_size)
    reset!(p.util);       reset!(p.avail)
    reset!(p.sojourn_q);  reset!(p.wait_q)
    reset!(p.queue_ext)
    reset!(p.arrivals);   reset!(p.departures)
    reset!(p.blocked);    reset!(p.events)

    p._total_arrivals_raw   = 0
    p._total_departures_raw = 0
    p._total_departures_postwarmup = 0

    # Re-open sample buffers
    empty!(p._sojourn_samples)
    empty!(p._wait_samples)

    # Re-arm warmup
    p.warmup.complete      = p.warmup.mode in (WARMUP_NONE, WARMUP_IMMEDIATE)
    p.warmup._n_departures = 0
    if p.warmup._welch !== nothing
        p.warmup._welch = WelchDetector(
            window_size = p.warmup._welch.window_size,
            threshold   = p.warmup._welch.threshold)
    end

    # Reset user collectors
    for (_, collector, _, _) in p._custom
        reset!(collector)
    end

    return p
end

# ─────────────────────────────────────────────────────────────────────────────
# TASK 13 — merge! for StatsPipeline (Chandy-Misra Tier-2 thread safety)
# ─────────────────────────────────────────────────────────────────────────────

"""
    merge!(dst::StatsPipeline, src::StatsPipeline) → dst

Combine two independently-run `StatsPipeline`s into `dst`.

Used for Chandy-Misra Tier-2 PDES: each Logical Process (LP/zone) runs its own
`StatsPipeline`, then all LPs are merged at simulation end.

## What IS merged
All collectors that support `merge!`: `MeanCollector`, `WeightedMeanCollector`,
`ExtremaCollector`, `CounterCollector`, and raw count fields.

## What is NOT merged
`P2QuantileCollector` — P² markers cannot be combined across streams.
After merge, `dst.sojourn_q` and `dst.wait_q` reflect only `dst`'s LP data.
For cross-LP quantiles, use `record_samples=true` and pool the raw sample buffers.

## User collectors
User-registered collectors are merged by calling `merge!(dst_c, src_c)`.
If a collector does not support `merge!` it will throw; register only
mergeable collectors (or use `record_samples` for P2-style use cases).

## Usage pattern (Tier-2 Chandy-Misra)
```julia
# Each zone gets its own pipeline
pipelines = [StatsPipeline() for _ in 1:n_zones]

# Run Chandy-Misra simulation; each LP feeds its own pipeline

# Combine at end
final_pipeline = foldl(Base.merge!, pipelines[2:end]; init=pipelines[1])
sm = sim_summary(final_pipeline)
```
"""
function Base.merge!(dst::StatsPipeline, src::StatsPipeline)
    merge!(dst.sojourn,    src.sojourn)
    merge!(dst.wait,       src.wait)
    merge!(dst.sys_size,   src.sys_size)
    merge!(dst.q_size,     src.q_size)
    merge!(dst.util,       src.util)
    merge!(dst.avail,      src.avail)
    # NOTE: P2QuantileCollectors are intentionally NOT merged.
    # dst.sojourn_q and dst.wait_q retain their own LP's stream.
    merge!(dst.queue_ext,  src.queue_ext)
    merge!(dst.arrivals,   src.arrivals)
    merge!(dst.departures, src.departures)
    merge!(dst.blocked,    src.blocked)
    merge!(dst.events,     src.events)

    dst._total_arrivals_raw   += src._total_arrivals_raw
    dst._total_departures_raw += src._total_departures_raw
    dst._total_departures_postwarmup += src._total_departures_postwarmup

    # Merge raw sample buffers (if both use Workflow 2)
    if dst._record_samples && src._record_samples
        remaining = dst._max_samples - length(dst._sojourn_samples)
        if remaining > 0
            n = min(remaining, length(src._sojourn_samples))
            append!(dst._sojourn_samples, view(src._sojourn_samples, 1:n))
            append!(dst._wait_samples,    view(src._wait_samples,    1:n))
        end
    end

    # Merge user collectors
    if !isempty(dst._custom) && !isempty(src._custom)
        for i in eachindex(dst._custom)
            i > length(src._custom) && break
            (dst_name, dst_c, _, _) = dst._custom[i]
            (src_name, src_c, _, _) = src._custom[i]
            dst_name === src_name && merge!(dst_c, src_c)
        end
    end

    # Warmup: dst is complete if either LP declared completion
    dst.warmup.complete = dst.warmup.complete || src.warmup.complete

    return dst
end
