# packages/GodotBridge/src/runtime/simulation_instance.jl
#
# SimulationInstance — Active in-memory simulation container.
# Holds mutable SimWorld, FutureEventList, ZoneConfigs, SimClock, and RNG.
# Supports multi-unit stepping (s, m, h, d), interruptible execution, and periodic tick callbacks.

using SimCore
import SimCore: pause!, set_speed!
using SimDES
using Random: AbstractRNG, MersenneTwister

"""
    SimulationInstance

Self-contained executable instance of a compiled simulation model.
"""
mutable struct SimulationInstance
    id::String
    world::SimCore.SimWorld
    fel::SimDES.FutureEventList
    configs::Dict{Int, SimDES.ZoneConfig}
    source_map::SourceMap
    clock::SimCore.SimClock
    rng::Random.AbstractRNG
    execution_ir::ExecutionGraphIR
    is_running::Threads.Atomic{Bool}
    is_paused::Threads.Atomic{Bool}
    interrupt_requested::Threads.Atomic{Bool}
    clock_speed::Float64
    created_at::Float64
    zone_hooks::Dict{String, ZoneHooks}
end

function SimulationInstance(
    id::String,
    world::SimCore.SimWorld,
    fel::SimDES.FutureEventList,
    configs::Dict{Int, SimDES.ZoneConfig},
    source_map::SourceMap,
    execution_ir::ExecutionGraphIR;
    seed::Integer = 42,
    clock_speed::Float64 = 1.0
)
    return SimulationInstance(
        id,
        world,
        fel,
        configs,
        source_map,
        SimCore.SimClock(clock_speed),
        Random.MersenneTwister(seed),
        execution_ir,
        Threads.Atomic{Bool}(false),
        Threads.Atomic{Bool}(true),
        Threads.Atomic{Bool}(false),
        clock_speed,
        time(),
        Dict{String, ZoneHooks}()
    )
end

"""
    step_until!(instance::SimulationInstance, t_target::Float64; on_tick::Function=(t)->nothing, tick_interval_sec::Float64=0.033) -> Float64

Advances simulation time up to `t_target`. Supports unrestricted intervals (seconds, minutes, hours, days).
During long steps, periodically invokes `on_tick(current_sim_time)` to emit real-time visualization snapshots.
Can be interrupted at any moment by setting `instance.interrupt_requested[] = true`.
"""
function step_until!(
    instance::SimulationInstance,
    t_target::Float64;
    on_tick::Function = (t) -> nothing,
    tick_interval_sec::Float64 = 0.033,
    fast_forward::Bool = false
)::Float64
    instance.interrupt_requested[] = false
    last_tick_wall = time()
    events_since_tick = 0

    while !Base.isempty(instance.fel)
        # Check for immediate cooperative pause / interrupt
        if instance.interrupt_requested[]
            break
        end

        # Check timestamp of next event without dequeuing
        t_next = SimDES.peek_time(instance.fel)
        if t_next > t_target
            break
        end

        # Dequeue and process next event
        res = SimDES.safe_dequeue!(instance.fel)
        res === nothing && break
        cev, t = res

        # Throttle with SimClock (honors real-time factor if not running in headless fast-forward)
        if !fast_forward && isfinite(instance.clock.speed_factor)
            SimCore.throttle!(instance.clock, t)
        end
        instance.world.time = t

        SimDES.dispatch!(instance.world, instance.fel, instance.configs, instance.rng, cev.inner, t)

        if !isempty(instance.zone_hooks)
            _fire_event_hooks!(instance, cev.inner, t)
        end

        events_since_tick += 1
        now_wall = time()
        if (now_wall - last_tick_wall) >= tick_interval_sec || events_since_tick >= 2000
            on_tick(t)
            last_tick_wall = now_wall
            events_since_tick = 0
        end
    end

    # Advance world clock to target if not interrupted
    if !instance.interrupt_requested[]
        instance.world.time = max(instance.world.time, t_target)
        if !fast_forward && isfinite(instance.clock.speed_factor)
            SimCore.throttle!(instance.clock, instance.world.time)
        end
    end

    on_tick(instance.world.time)
    return instance.world.time
end

"""
    pause!(instance::SimulationInstance)

Signals running execution loops to pause immediately.
"""
function pause!(instance::SimulationInstance)
    instance.is_running[] = false
    instance.is_paused[] = true
    instance.interrupt_requested[] = true
end

"""
    set_speed!(instance::SimulationInstance, speed::Float64)

Updates clock speed multiplier (1.0 = real-time, 10.0 = 10x, Inf = max compute speed).
"""
function set_speed!(instance::SimulationInstance, speed::Float64)
    instance.clock_speed = max(0.001, speed)
    SimCore.set_speed!(instance.clock, instance.clock_speed)
end

function _fire_event_hooks!(instance::SimulationInstance, ev, t::Float64)
    if ev isa SimCore.EntityArrival
        zid = ev.zone_id
        ent_id = Int(ev.entity_id)
        recs = get(instance.source_map.by_zone, zid, SourceMapRecord[])
        agent = SimCore.get_des_agent(instance.world, ev.entity_id)
        started_service = agent !== nothing && agent.service_start_time == t
        for rec in recs
            hooks = get(instance.zone_hooks, rec.element_id, nothing)
            if hooks !== nothing
                call_hook!(hooks, :on_entry, ent_id, rec.element_id, t)
                if started_service
                    call_hook!(hooks, :on_service_start, ent_id, rec.element_id, t)
                end
            end
        end
    elseif ev isa SimCore.ProcessComplete
        zid = ev.station_id
        ent_id = Int(ev.entity_id)
        recs = get(instance.source_map.by_zone, zid, SourceMapRecord[])
        for rec in recs
            hooks = get(instance.zone_hooks, rec.element_id, nothing)
            if hooks !== nothing
                call_hook!(hooks, :on_service_complete, ent_id, rec.element_id, t)
                call_hook!(hooks, :on_exit, ent_id, rec.element_id, t)
            end
        end
    end
    return nothing
end
