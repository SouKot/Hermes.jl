"""
    events.jl — Simulation event type hierarchy

Defines the abstract event base type and all concrete event structs.
Uses Julia multiple dispatch so each event type routes to its own handler
in SimDES without any if/elseif chains.

Design ref: §7.11 (Event Handler Pattern), §7.12 (Cancel Support)
"""

# ── Global event ID counter ────────────────────────────────────────────────────

const _event_id_counter = Threads.Atomic{UInt64}(0)

"""
    next_event_id!() -> UInt64

Thread-safe monotonically increasing event ID.
"""
next_event_id!() = Threads.atomic_add!(_event_id_counter, UInt64(1)) + UInt64(1)

# ── Abstract base ─────────────────────────────────────────────────────────────

"""
    SimEvent

Abstract supertype for all simulation events.
Each concrete subtype is dispatched by `SimDES.dispatch!` via Julia multiple dispatch.
Industry-specific events should subtype the generic events below.
"""
abstract type SimEvent end

# ── Generic events (industry-agnostic) ────────────────────────────────────────

"""
    EntityArrival(entity_id, zone_id, time[, priority[, is_external]])

An entity (customer, package, patient, vehicle) arrives at a zone.

# Fields
- `entity_id::UInt64`: unique entity identifier
- `zone_id::Int`: destination zone (Logical Process ID)
- `time::Float64`: scheduled simulated time of arrival
- `priority::Int`: service priority; higher = served before lower-priority entities in queue.
  Default `0` = normal FIFO. Used by non-preemptive Head-Of-Line (HOL) priority queuing.
- `is_external::Bool`: `true` if this is a zone-owned Poisson arrival (triggers the next
  arrival to be self-scheduled); `false` if routed from another zone or spawned as a
  fork-join sub-entity. Default `true` for backward compatibility.
"""
struct EntityArrival <: SimEvent
    entity_id   :: UInt64
    zone_id     :: Int
    time        :: Float64
    priority    :: Int
    is_external :: Bool
end

""" 3-arg constructor: FIFO priority, external arrival (backward compat). """
EntityArrival(entity_id::UInt64, zone_id::Int, time::Float64) =
    EntityArrival(entity_id, zone_id, time, 0, true)

""" 4-arg constructor: custom priority, external arrival (backward compat). """
EntityArrival(entity_id::UInt64, zone_id::Int, time::Float64, priority::Int) =
    EntityArrival(entity_id, zone_id, time, priority, true)

"""
    ProcessComplete(entity_id, station_id, time)

A service/process operation completes at a station.

# Fields
- `entity_id::UInt64`: entity that was being processed
- `station_id::Int`: station that completed the process
- `time::Float64`: scheduled simulated time of completion
"""
struct ProcessComplete <: SimEvent
    entity_id  :: UInt64
    station_id :: Int
    time       :: Float64
end

"""
    ResourceFailure(resource_id, severity, time)

A resource (machine, server, vehicle) fails.

# Fields
- `resource_id::Int`: which resource failed
- `severity::Float32`: 0.0 = minor, 1.0 = complete failure
- `time::Float64`: time of failure
"""
struct ResourceFailure <: SimEvent
    resource_id :: Int
    severity    :: Float32
    time        :: Float64
end

"""
    ScheduledChange{S}(zone_id, time)

A pre-scheduled state change in a zone. Type parameter `S` is a Symbol
identifying the change type — e.g., `ScheduledChange{:Repair}`,
`ScheduledChange{:EvacAlarm}`, `ScheduledChange{:ShiftChange}`.

# Examples
```julia
# Machine repair scheduled at t=120.0
event = ScheduledChange{:Repair}(machine_id, 120.0)

# Evacuation alarm at t=60.0
event = ScheduledChange{:EvacAlarm}(building_id, 60.0)
```
"""
struct ScheduledChange{S} <: SimEvent
    zone_id :: Int
    time    :: Float64
end

"""
    TransferOut(entity_id, dest_zone, time)

An entity departs a zone and is transferred to a destination zone.
Handled by the destination zone as an `EntityArrival` after transit time.

> **Tier 2 use only.** In Tier 1 serial DES, use `FixedRoute` or `ProbRoute` in
> `ZoneConfig` instead. `TransferOut` is kept for the Chandy-Misra inter-LP
> message format in Conservative PDES (Tier 2 / Phase 5), where each LP dispatches
> `TransferOut` to send entities to downstream LP channels.
> Direct Tier 1 dispatch of `TransferOut` bypasses the `is_external` routing-loop
> guard and may cause duplicate arrival scheduling.

# Fields
- `entity_id::UInt64`: entity being transferred
- `dest_zone::Int`: destination zone LP ID
- `time::Float64`: time the transfer is initiated
"""
struct TransferOut <: SimEvent
    entity_id :: UInt64
    dest_zone :: Int
    time      :: Float64
end

"""
    NullEvent()

Chandy-Misra null message — carries a safe-time guarantee with no
actual state change. Used by Conservative PDES (Tier 2) to prevent
deadlock by announcing the minimum future event time.
"""
struct NullEvent <: SimEvent end

# ── Cancellable event wrapper ──────────────────────────────────────────────────

"""
The set of cancelled event IDs. Events with IDs in this set are
skipped by `safe_dequeue!` in SimDES.
"""
const _cancelled_events = Set{UInt64}()
const _cancel_lock      = ReentrantLock()

"""
    cancel!(id::UInt64)

Mark an event as cancelled in the **global** cancellation set. The event will be
silently skipped the next time `safe_dequeue!` encounters it.
Thread-safe (uses `ReentrantLock`).

> **Note for SimDES users**: prefer `cancel!(fel::FutureEventList, id)` instead.
> It uses a per-FEL `Set{UInt64}` with no lock — faster in Tier 1 and correct in Tier 2
> where each LP owns its own FEL. This global version is kept for SimCore-level testing.
"""
function cancel!(id::UInt64)
    lock(_cancel_lock) do
        push!(_cancelled_events, id)
    end
end

"""
    is_cancelled(id::UInt64) -> Bool

Check if an event ID has been cancelled.
"""
is_cancelled(id::UInt64) = lock(_cancel_lock) do
    id in _cancelled_events
end

"""
    _consume_cancelled!(id::UInt64)

Remove a cancelled event from the set after it has been skipped.
Called internally by `safe_dequeue!`.
"""
_consume_cancelled!(id::UInt64) = lock(_cancel_lock) do
    delete!(_cancelled_events, id)
end

"""
    CancellableEvent

Wraps any `SimEvent` with a unique ID to allow cancellation via `cancel!(id)`.

# Fields
- `id::UInt64`: unique event ID (use `cancel!(id)` to cancel)
- `inner::SimEvent`: the wrapped event
- `time::Float64`: scheduled simulated time (mirrors the FEL key)
"""
struct CancellableEvent
    id    :: UInt64
    inner :: SimEvent
    time  :: Float64
end

"""
    CancellableEvent(event, time) -> CancellableEvent

Create a cancellable event with an auto-assigned unique ID.
"""
CancellableEvent(event::SimEvent, time::Float64) =
    CancellableEvent(next_event_id!(), event, time)
