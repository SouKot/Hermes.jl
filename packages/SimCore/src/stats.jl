"""
    stats.jl — Simulation statistics accumulator

`SimStats` collects per-run statistics for DES validation:
  - Queue length samples (for mean L and Lq)
  - Wait/sojourn time samples (for mean W and Wq)
  - Server utilisation
  - Event and entity counts

Statistics are collected only after warm-up (Welch method trigger or
fixed warm-up period). The caller controls when sampling begins.

Design ref: Validation test cases DES-S-01..09
"""

"""
    SimStats

Accumulates simulation output statistics.
All mutable fields — updated in the simulation hot path.

# Fields
- `total_events::Int`: total events processed (including warmup)
- `total_arrivals::Int`: total entity arrivals (system-wide)
- `total_departures::Int`: total entity departures (system-wide)
- `blocked_count::Int`: entities rejected due to finite buffer (M/M/1/K)
- `queue_length_sum::Float64`: area-under-L(t) for mean L computation
- `queue_length_samples::Int`: number of L samples
- `wait_time_sum::Float64`: sum of individual wait times (for mean Wq)
- `wait_time_samples::Int`: number of Wq samples
- `sojourn_time_sum::Float64`: sum of individual sojourn times (for mean W)
- `sojourn_time_samples::Int`: number of W samples
- `busy_time::Float64`: total server busy time (for utilisation ρ)
- `uptime::Float64`: total machine uptime (> 0 when servers available; for availability A)
- `elapsed_sim_time::Float64`: total simulated time of this stats window
- `warmup_complete::Bool`: flag — only record after warmup
"""
mutable struct SimStats
    total_events         :: Int
    total_arrivals       :: Int
    total_departures     :: Int
    blocked_count        :: Int
    queue_length_sum     :: Float64
    queue_length_samples :: Int
    wait_time_sum        :: Float64
    wait_time_samples    :: Int
    sojourn_time_sum     :: Float64
    sojourn_time_samples :: Int
    busy_time            :: Float64
    uptime               :: Float64   # machine uptime: Σ dt where num_servers > 0
    elapsed_sim_time     :: Float64
    warmup_complete      :: Bool
end

"""
    SimStats() -> SimStats

Create a fresh statistics accumulator (all zeros, warmup incomplete).
"""
SimStats() = SimStats(0, 0, 0, 0,
                      0.0, 0, 0.0, 0, 0.0, 0,
                      0.0, 0.0, 0.0, false)

"""
    reset_stats!(stats)

Reset all counters to zero and mark warmup as incomplete.
"""
function reset_stats!(stats::SimStats)
    stats.total_events         = 0
    stats.total_arrivals       = 0
    stats.total_departures     = 0
    stats.blocked_count        = 0
    stats.queue_length_sum     = 0.0
    stats.queue_length_samples = 0
    stats.wait_time_sum        = 0.0
    stats.wait_time_samples    = 0
    stats.sojourn_time_sum     = 0.0
    stats.sojourn_time_samples = 0
    stats.busy_time            = 0.0
    stats.uptime               = 0.0
    stats.elapsed_sim_time     = 0.0
    stats.warmup_complete      = false
    return stats
end

# ── Recording functions (called from SimDES event handlers) ───────────────────

"""
    record_arrival!(stats)

Increment arrival count. Call when an entity enters the system.
"""
function record_arrival!(stats::SimStats)
    stats.total_events   += 1
    stats.total_arrivals += 1
    return stats
end

"""
    record_departure!(stats, wait_time, sojourn_time)

Record a departing entity's wait time (Wq) and sojourn time (W).
Only records if warmup is complete.
"""
function record_departure!(stats::SimStats, wait_time::Float64, sojourn_time::Float64)
    stats.total_events    += 1
    stats.total_departures += 1
    stats.warmup_complete || return stats
    stats.wait_time_sum        += wait_time
    stats.wait_time_samples    += 1
    stats.sojourn_time_sum     += sojourn_time
    stats.sojourn_time_samples += 1
    return stats
end

"""
    record_queue_length!(stats, length, dt)

Record the current queue length `length` observed for a time interval `dt`.
Uses the time-average formula: L̄ = (Σ L·Δt) / total_time.
Only records if warmup is complete.
"""
function record_queue_length!(stats::SimStats, length::Int, dt::Float64)
    stats.warmup_complete || return stats
    stats.queue_length_sum     += length * dt
    stats.queue_length_samples += 1
    stats.elapsed_sim_time     += dt
    return stats
end

"""
    record_utilization!(stats, busy_dt)

Record a time interval `busy_dt` during which the server was busy.
"""
function record_utilization!(stats::SimStats, busy_dt::Float64)
    stats.warmup_complete || return stats
    stats.busy_time += busy_dt
    return stats
end

"""
    record_uptime!(stats, dt)

Record time interval `dt` during which the resource was available (num_servers > 0).
Used to compute machine availability: A = uptime / elapsed_sim_time.
"""
function record_uptime!(stats::SimStats, dt::Float64)
    stats.warmup_complete || return stats
    stats.uptime += dt
    return stats
end

"""
    record_blocked!(stats)

Record one entity rejected due to finite buffer.
"""
function record_blocked!(stats::SimStats)
    stats.total_events   += 1
    stats.total_arrivals += 1   # blocked = arrival attempt that was rejected
    stats.blocked_count  += 1
    return stats
end

# ── Derived metrics ────────────────────────────────────────────────────────────

"""
    mean_queue_length(stats) -> Float64

Time-average mean number of entities in system (L).
Returns `NaN` if no samples collected.
"""
mean_queue_length(stats::SimStats) =
    stats.elapsed_sim_time > 0.0 ?
    stats.queue_length_sum / stats.elapsed_sim_time : NaN

"""
    mean_wait_time(stats) -> Float64

Sample-average mean waiting time in queue (Wq) in simulated seconds.
Returns `NaN` if no samples collected.
"""
mean_wait_time(stats::SimStats) =
    stats.wait_time_samples > 0 ?
    stats.wait_time_sum / stats.wait_time_samples : NaN

"""
    mean_sojourn_time(stats) -> Float64

Sample-average mean time in system (W) in simulated seconds.
Returns `NaN` if no samples collected.
"""
mean_sojourn_time(stats::SimStats) =
    stats.sojourn_time_samples > 0 ?
    stats.sojourn_time_sum / stats.sojourn_time_samples : NaN

"""
    utilization(stats) -> Float64

Server utilisation ρ = busy_time / elapsed_sim_time.
Returns `NaN` if no time has elapsed.
"""
utilization(stats::SimStats) =
    stats.elapsed_sim_time > 0.0 ?
    stats.busy_time / stats.elapsed_sim_time : NaN

"""
    blocking_probability(stats) -> Float64

Fraction of arrivals that were blocked (for M/M/1/K finite buffer).
Returns 0.0 if no arrivals.
"""
blocking_probability(stats::SimStats) =
    stats.total_arrivals > 0 ?
    stats.blocked_count / stats.total_arrivals : 0.0

"""
    sim_summary(stats) -> NamedTuple

Return all derived metrics as a named tuple for easy inspection.
Named `sim_summary` (not `summary`) to avoid shadowing `Base.summary`.

# Example
```julia
sm = sim_summary(stats)
println("L=\$(sm.L)  Wq=\$(sm.Wq)  util=\$(sm.utilization)")
```
"""
function sim_summary(stats::SimStats)
    return (
        L                = mean_queue_length(stats),
        Wq               = mean_wait_time(stats),
        W                = mean_sojourn_time(stats),
        utilization      = utilization(stats),
        blocking_prob    = blocking_probability(stats),
        total_arrivals   = stats.total_arrivals,
        total_departures = stats.total_departures,
        blocked_count    = stats.blocked_count,
        total_events     = stats.total_events,
    )
end

