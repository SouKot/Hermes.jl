"""
    SimCore

Shared foundation for the Hermes simulation platform.

Provides:
- Abstract event hierarchy and cancellable event wrapper
- `SimClock` — adjustable-speed simulation clock
- ECS component structs (`CrowdAgent`, `FluidParticle`, `DESAgent`, etc.)
- `SimWorld` — global simulation state container
- `SimStats` — statistics accumulator
- `SimEntity` ID management
"""
module SimCore

using DataStructures: PriorityQueue, enqueue!, dequeue!, dequeue_pair!, peek, isempty
using StaticArrays: SVector

# ── Source files ──────────────────────────────────────────────────────────────
include("events.jl")
include("clock.jl")
include("components.jl")
include("stats.jl")    # SimStats must be defined before SimWorld uses it
include("world.jl")

# ── Public API exports ────────────────────────────────────────────────────────

# Events
export SimEvent
export EntityArrival, ProcessComplete, ResourceFailure, ScheduledChange,
       TransferOut, NullEvent
export CancellableEvent, cancel!, next_event_id!, is_cancelled

# Clock
export SimClock, throttle!, pause!, unpause!, set_speed!, step_once!, reset!,
       is_paused, sim_time

# Components
export DESAgent, CrowdAgent, FluidParticle, CrowdObstacle,
       width, height, center

# World
export SimWorld, ZoneState, new_entity_id!, 
       add_des_agent!, remove_des_agent!, 
       add_crowd_agent!, remove_crowd_agent!,
       add_fluid_particle!, add_obstacle!, remove_entity!,
       get_des_agent, get_crowd_agent, update_crowd_agent!,
       add_zone!, get_zone, entity_count

# Stats
export SimStats, record_arrival!, record_departure!, record_queue_length!,
       record_utilization!, record_uptime!, record_blocked!, reset_stats!, sim_summary,
       mean_queue_length, mean_wait_time, mean_sojourn_time,
       utilization, blocking_probability

end
