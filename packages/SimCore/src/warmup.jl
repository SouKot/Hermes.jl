"""
    warmup.jl — Welch Warmup Detector (moved to SimCore in Sprint 4I)

Detects when a DES simulation has reached steady state using
Welch's moving-average method. Statistics are only collected
after the warmup period ends.

Welch's method (1983):
1. Divide the run into windows of size `w`
2. For each window compute mean queue length
3. When variance across consecutive windows drops below threshold,
   declare steady state

Design ref: §2A-10 (warmup detection requirement)
Reference: Welch, P.D. (1983). The statistical analysis of simulation results.

Moved from SimDES → SimCore in Sprint 4I so that StatsPipeline (in SimCore)
can use WelchDetector without a circular dependency on SimDES.
"""

"""
    WelchDetector

Online steady-state detector using Welch's moving-average method.

# Fields
- `window_size   :: Int`     — number of observation points per window
- `threshold     :: Float64` — relative CV threshold to declare steady state
- `_buffer       :: Vector{Float64}` — current window observations
- `_window_means :: Vector{Float64}` — mean of each completed window
- `complete      :: Bool`    — true when steady state detected

# Usage
```julia
wd = WelchDetector(window_size=200, threshold=0.05)
for each event in simulation
    update!(wd, queue_length_observation)
    warmup_complete(wd) && break   # start collecting stats
end
```
"""
mutable struct WelchDetector
    window_size    :: Int
    threshold      :: Float64
    _buffer        :: Vector{Float64}
    _window_means  :: Vector{Float64}
    complete       :: Bool
end

"""    WelchDetector(; window_size=200, threshold=0.05) → WelchDetector"""
WelchDetector(; window_size::Int = 200, threshold::Float64 = 0.05) =
    WelchDetector(window_size, threshold,
                  sizehint!(Float64[], window_size),
                  Float64[],
                  false)

"""    warmup_complete(wd) → Bool"""
warmup_complete(wd::WelchDetector) = wd.complete

"""
    update!(wd::WelchDetector, obs::Float64)

Add one observation (e.g., queue length at an event time).
Checks for steady state after each completed window.
"""
function update!(wd::WelchDetector, obs::Float64)
    wd.complete && return   # already declared

    push!(wd._buffer, obs)

    if length(wd._buffer) >= wd.window_size
        window_mean = sum(wd._buffer) / length(wd._buffer)
        push!(wd._window_means, window_mean)
        empty!(wd._buffer)

        if length(wd._window_means) >= 3
            means = wd._window_means
            last3 = means[end-2:end]
            μ̄ = sum(last3) / 3
            if μ̄ > 1e-10
                cv = sqrt(sum((m - μ̄)^2 for m in last3) / 3) / μ̄
                cv < wd.threshold && (wd.complete = true)
            else
                wd.complete = true   # zero queue → steady state
            end
        end
    end
end
