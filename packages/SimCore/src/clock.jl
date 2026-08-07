"""
    clock.jl — Adjustable-speed simulation clock

`SimClock` lets the user choose how fast simulated time advances relative
to wall-clock time. The same clock works for serial (Tier 1) and parallel
(Tier 2) DES — every LP calls `throttle!` before processing its safe event.

Design ref: §7.8 (Configurable Simulation Clock Speed)

| speed_factor | Mode           | Use case                              |
|--------------|----------------|---------------------------------------|
| `Inf`        | Fastest        | Batch planning runs, parameter sweeps |
| `10.0`       | 10× real-time  | Quick scenario previews               |
| `1.0`        | Real-time      | Operator training, live dashboards    |
| `0.1`        | Slow motion    | Educational demos, debugging          |
| `0.0`        | Paused         | Step-by-step inspection               |
"""

"""
    SimClock(speed_factor=Inf)

A simulation clock that can throttle simulated time against wall-clock time.

# Fields
- `sim_time::Float64`: current simulated time (seconds)
- `wall_origin::Float64`: wall-clock timestamp when the simulation started
- `speed_factor::Float64`: Inf=fastest, 1.0=real-time, 0.1=slow-motion
- `paused::Threads.Atomic{Bool}`: true when simulation is paused
- `_step_once::Threads.Atomic{Bool}`: internal flag for single-step mode

# Examples
```julia
clock = SimClock()         # fastest mode
clock = SimClock(1.0)      # real-time mode
clock = SimClock(0.1)      # slow-motion (10× slower than real time)

set_speed!(clock, 2.0)     # change speed at runtime
pause!(clock)
unpause!(clock)
step_once!(clock)          # advance exactly one event, then pause
```
"""
mutable struct SimClock
    sim_time     :: Float64
    wall_origin  :: Float64
    speed_factor :: Float64
    paused       :: Threads.Atomic{Bool}
    _step_once   :: Threads.Atomic{Bool}
end

"""
    SimClock(speed_factor=Inf) -> SimClock

Construct a new simulation clock. `speed_factor=Inf` runs at maximum speed.
"""
SimClock(speed_factor::Float64 = Inf) =
    SimClock(0.0, time(), speed_factor, Threads.Atomic{Bool}(false),
             Threads.Atomic{Bool}(false))

"""
    sim_time(clock) -> Float64

Return the current simulated time.
"""
sim_time(clock::SimClock) = clock.sim_time

"""
    is_paused(clock) -> Bool

Return `true` if the clock is currently paused.
"""
is_paused(clock::SimClock) = clock.paused[]

# ── Speed controls ─────────────────────────────────────────────────────────────

"""
    set_speed!(clock, factor)

Set the simulation speed factor at runtime.

- `Inf`  → fastest possible (no throttle)
- `1.0`  → real-time (1 simulated second = 1 wall second)
- `0.5`  → half-speed (1 sim-sec = 2 wall seconds)
- `0.0`  → pause (equivalent to `pause!`)

Can be called safely from any thread (e.g., GUI event handler).
"""
function set_speed!(clock::SimClock, factor::Float64)
    factor >= 0.0 || throw(ArgumentError(
        "speed_factor must be ≥ 0.0, got $factor"
    ))
    clock.speed_factor = factor
    if factor == 0.0
        Threads.atomic_cas!(clock.paused, false, true)
    end
    return clock
end

"""
    pause!(clock)

Pause the simulation. `throttle!` will block until `unpause!` or `step_once!`
is called. Thread-safe.
"""
pause!(clock::SimClock) = Threads.atomic_cas!(clock.paused, false, true)

"""
    unpause!(clock)

Resume the simulation from a paused state. Thread-safe.
"""
function unpause!(clock::SimClock)
    Threads.atomic_cas!(clock.paused, true, false)
    return clock
end

"""
    step_once!(clock)

Advance exactly one event and then pause again.
Call from a GUI "Step" button to inspect the simulation event-by-event.
Thread-safe.
"""
function step_once!(clock::SimClock)
    # Set step flag, then unpause so one event runs
    Threads.atomic_cas!(clock._step_once, false, true)
    Threads.atomic_cas!(clock.paused, true, false)
    return clock
end

# ── Core throttle ──────────────────────────────────────────────────────────────

"""
    throttle!(clock, next_sim_time)

Called by the simulation loop **before** processing each event at `next_sim_time`.

Behaviour:
- If paused: block (sleep 10ms loops) until unpaused
- If `speed_factor == Inf`: update clock, return immediately (no sleep)
- Otherwise: sleep until wall time catches up to the expected time for `next_sim_time`
- Step-once mode: process one event, then re-pause

This function is the only place where wall-clock synchronisation happens.
"""
function throttle!(clock::SimClock, next_sim_time::Float64)
    # ── Pause loop: block until unpaused or step_once triggered
    while clock.paused[]
        sleep(0.010)   # 10ms polling interval — low CPU overhead
    end

    # ── Step-once: re-pause after this one event
    if clock._step_once[]
        Threads.atomic_cas!(clock._step_once, true, false)
        Threads.atomic_cas!(clock.paused, false, true)
    end

    # ── Advance sim time
    clock.sim_time = next_sim_time

    # ── Fastest mode: no wall-clock synchronisation needed
    isinf(clock.speed_factor) && return

    # ── Throttled mode: sleep if we are ahead of schedule
    expected_wall = clock.wall_origin + next_sim_time / clock.speed_factor
    remaining     = expected_wall - time()
    remaining > 0.001 && sleep(remaining)   # only sleep if meaningfully ahead

    return
end

"""
    reset!(clock)

Reset the simulation clock to t=0 with a fresh wall-clock origin.
Call before restarting a simulation run.
"""
function reset!(clock::SimClock)
    clock.sim_time   = 0.0
    clock.wall_origin = time()
    Threads.atomic_cas!(clock.paused, true, false)      # unpause
    Threads.atomic_cas!(clock._step_once, true, false)  # clear step flag
    return clock
end
