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
    zh_dict = Dict{String, ZoneHooks}()
    for (k, v) in execution_ir.zone_hooks
        if v isa ZoneHooks
            zh_dict[k] = v
        end
    end
    # Ensure element_to_zone and zone_to_element are populated from source_map if empty
    if isempty(execution_ir.element_to_zone) && !isempty(source_map.by_element)
        for (eid, rec) in source_map.by_element
            if !isempty(rec.zone_ids)
                zid = first(rec.zone_ids)
                execution_ir.element_to_zone[eid] = zid
                if !haskey(execution_ir.zone_to_element, zid) || rec.role_in_zone in (:server_workstation, :conveyor_bed)
                    execution_ir.zone_to_element[zid] = eid
                end
            end
        end
    end
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
        zh_dict
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

        if !isempty(instance.zone_hooks) && cev.inner isa SimCore.ProcessComplete
            _fire_pre_event_hooks!(instance, cev.inner, t)
        end

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

function _make_hook_ctx(
    instance::SimulationInstance,
    ent_id::Int,
    zid::Int,
    elem_id::String,
    t::Float64;
    event_tag::Symbol = :none,
    event_payload::Any = nothing
)::SimCore.HookContext
    if isempty(instance.execution_ir.element_to_zone) && !isempty(instance.source_map.by_element)
        for (eid, rec) in instance.source_map.by_element
            if !isempty(rec.zone_ids)
                z = first(rec.zone_ids)
                instance.execution_ir.element_to_zone[eid] = z
                if !haskey(instance.execution_ir.zone_to_element, z) || rec.role_in_zone in (:server_workstation, :conveyor_bed)
                    instance.execution_ir.zone_to_element[z] = eid
                end
            end
        end
    end
    return SimCore.HookContext(
        instance.world,
        ent_id,
        zid,
        elem_id,
        t;
        rng = instance.rng,
        element_to_zone = instance.execution_ir.element_to_zone,
        zone_to_element = instance.execution_ir.zone_to_element,
        fel = instance.fel,
        configs = instance.configs,
        event_tag = event_tag,
        event_payload = event_payload
    )
end

function _fire_pre_event_hooks!(instance::SimulationInstance, ev::SimCore.ProcessComplete, t::Float64)
    zid = ev.station_id
    ent_id = Int(ev.entity_id)
    recs = get(instance.source_map.by_zone, zid, SourceMapRecord[])
    for rec in recs
        hooks = get(instance.zone_hooks, rec.element_id, nothing)
        if hooks !== nothing
            ctx = _make_hook_ctx(instance, ent_id, zid, rec.element_id, t)
            call_hook!(hooks, :on_service_complete, ctx)
            call_hook!(hooks, :on_exit, ctx)
            apply_hook_mutations!(instance.world, instance.fel, instance.configs, instance.rng, ctx)
        end
    end
    return nothing
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
                ctx = _make_hook_ctx(instance, ent_id, zid, rec.element_id, t)
                call_hook!(hooks, :on_entry, ctx)
                if started_service && agent.current_zone == zid
                    call_hook!(hooks, :on_service_start, ctx)
                end
                apply_hook_mutations!(instance.world, instance.fel, instance.configs, instance.rng, ctx)
            end
        end
        # Re-fetch agent in case on_entry mutated or dispatch! auto-pulled into downstream server
        agent = SimCore.get_des_agent(instance.world, ev.entity_id)
        cfg = get(instance.configs, zid, nothing)
        if cfg !== nothing && cfg.routing isa SimDES.FixedRoute
            dzid = cfg.routing.to
            dzs = get(instance.world.zone_states, dzid, nothing)
            drecs = get(instance.source_map.by_zone, dzid, SourceMapRecord[])
            for drec in drecs
                dhooks = get(instance.zone_hooks, drec.element_id, nothing)
                if dhooks !== nothing
                    if agent !== nothing && agent.current_zone == dzid && agent.service_start_time == t
                        ctx_d = _make_hook_ctx(instance, ent_id, dzid, drec.element_id, t)
                        call_hook!(dhooks, :on_entry, ctx_d)
                        call_hook!(dhooks, :on_service_start, ctx_d)
                        apply_hook_mutations!(instance.world, instance.fel, instance.configs, instance.rng, ctx_d)
                    elseif dhooks.on_pull !== nothing && dzs !== nothing && dzs.busy_servers < dzs.num_servers
                        ctx_p = _make_hook_ctx(instance, 0, dzid, drec.element_id, t)
                        call_hook!(dhooks, :on_pull, ctx_p)
                        apply_hook_mutations!(instance.world, instance.fel, instance.configs, instance.rng, ctx_p)
                    end
                end
            end
        end
    elseif ev isa SimCore.ProcessComplete
        zid = ev.station_id
        recs = get(instance.source_map.by_zone, zid, SourceMapRecord[])
        zs = get(instance.world.zone_states, zid, nothing)
        for rec in recs
            hooks = get(instance.zone_hooks, rec.element_id, nothing)
            if hooks !== nothing
                # Check if an entity just started service at timestamp t
                if hooks.on_service_start !== nothing
                    for (uid, ag) in instance.world.des_agents
                        if ag.current_zone == zid && ag.service_start_time == t
                            ctx_s = _make_hook_ctx(instance, Int(uid), zid, rec.element_id, t)
                            call_hook!(hooks, :on_service_start, ctx_s)
                            apply_hook_mutations!(instance.world, instance.fel, instance.configs, instance.rng, ctx_s)
                        end
                    end
                end
                # Fire on_pull if station has free server capacity
                if hooks.on_pull !== nothing && zs !== nothing && zs.busy_servers < zs.num_servers
                    ctx_p = _make_hook_ctx(instance, 0, zid, rec.element_id, t)
                    call_hook!(hooks, :on_pull, ctx_p)
                    apply_hook_mutations!(instance.world, instance.fel, instance.configs, instance.rng, ctx_p)
                end
            end
        end
    elseif ev isa SimCore.CustomUserEvent
        zid = ev.zone_id
        if !isempty(ev.element_id) && haskey(instance.zone_hooks, ev.element_id)
            hooks = instance.zone_hooks[ev.element_id]
            ctx = _make_hook_ctx(instance, 0, zid, ev.element_id, t; event_tag=ev.tag, event_payload=ev.payload)
            call_hook!(hooks, :on_event, ctx)
            apply_hook_mutations!(instance.world, instance.fel, instance.configs, instance.rng, ctx)
        elseif zid > 0
            recs = get(instance.source_map.by_zone, zid, SourceMapRecord[])
            for rec in recs
                hooks = get(instance.zone_hooks, rec.element_id, nothing)
                if hooks !== nothing
                    ctx = _make_hook_ctx(instance, 0, zid, rec.element_id, t; event_tag=ev.tag, event_payload=ev.payload)
                    call_hook!(hooks, :on_event, ctx)
                    apply_hook_mutations!(instance.world, instance.fel, instance.configs, instance.rng, ctx)
                end
            end
        end
    end
    return nothing
end

