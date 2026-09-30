# packages/GodotBridge/src/runtime/telemetry_adapter.jl
#
# Telemetry Adapter for Live Simulation.
# Converts live SimWorld DES and Crowd states into Protocol v1 DirectSnapshotPayload
# with accurate 2D/3D spatial coordinates, queue slot offsets, and conveyor transit interpolation.

using SimCore
using SimDES

"""
    build_snapshot(instance::SimulationInstance; scene_id::String="active_scene", step_count::UInt64=UInt64(0)) -> DirectSnapshotPayload

Extracts entities, element states, and metrics from the live `SimulationInstance`
and constructs a typed `DirectSnapshotPayload` ready for MsgPack/JSON serialization.
"""
function build_snapshot(
    instance::SimulationInstance;
    scene_id::String = "active_scene",
    step_count::UInt64 = UInt64(0)
)::DirectSnapshotPayload
    world = instance.world
    source_map = instance.source_map
    ir = instance.execution_ir
    curr_t = world.time

    # 1. Elements state
    elements_state = DirectSnapshotElement[]

    # Group zones and elements
    for (elem_id, node) in ir.nodes
        occ = UInt32(0)
        metrics = Dict{String, Any}()
        
        # Determine readable element kind
        kind_str = if node isa IRSourceNode; "source"
        elseif node isa IRQueueNode; "queue"
        elseif node isa IRServerNode; "server"
        elseif node isa IRConveyorNode; "conveyor"
        elseif node isa IRSinkNode; "sink"
        elseif node isa IRCrowdSpawnerNode; "crowd_spawner"
        else; string(typeof(node))
        end
        metrics["kind"] = kind_str

        # Find zone for this element
        if haskey(source_map.by_element, elem_id)
            map_rec = source_map.by_element[elem_id]
            for zid in map_rec.zone_ids
                if haskey(world.zone_states, zid)
                    zstate = world.zone_states[zid]
                    zcfg = get(instance.configs, zid, nothing)
                    zs = get(world.zone_stats, zid, nothing)

                    if map_rec.role_in_zone == :queue_buffer
                        occ = UInt32(zstate.queue_length)
                        cap = zcfg !== nothing ? zcfg.capacity : 20
                        metrics["queue_length"] = zstate.queue_length
                        metrics["length"] = zstate.queue_length
                        metrics["capacity"] = cap
                        metrics["occupancy_pct"] = round((Float64(zstate.queue_length) / max(1.0, Float64(cap))) * 100.0, digits=1)
                        metrics["wait_mean_wq"] = (zs !== nothing && zs.wait_time_samples > 0) ? round(zs.wait_time_sum / zs.wait_time_samples, digits=2) : 0.0
                        metrics["total_entered"] = zs !== nothing ? zs.total_arrivals : 0
                        metrics["total_departed"] = zs !== nothing ? zs.total_departures : 0
                        metrics["badge"] = "[ $(zstate.queue_length)/$(cap) ]"
                        if zs !== nothing && !isempty(zs.recent_wait_samples)
                            metrics["recent_wait_samples"] = copy(zs.recent_wait_samples)
                            empty!(zs.recent_wait_samples)
                        end
                    elseif map_rec.role_in_zone == :server_workstation
                        occ = UInt32(zstate.busy_servers)
                        n_srv = zstate.num_servers
                        metrics["busy_servers"] = zstate.busy_servers
                        metrics["num_servers"] = n_srv
                        
                        srv_state = if n_srv == 0; "DOWN"
                        elseif zstate.busy_servers >= n_srv; "BUSY"
                        elseif zstate.busy_servers > 0; "PARTIAL"
                        else; "IDLE"
                        end
                        metrics["state"] = srv_state

                        busy_t = zs !== nothing ? zs.busy_time : 0.0
                        uptime = (zs !== nothing && zs.uptime > 0.0) ? zs.uptime : max(0.001, curr_t)
                        util_pct = clamp(round((busy_t / uptime) * 100.0, digits=1), 0.0, 100.0)
                        metrics["utilization_pct"] = util_pct
                        metrics["utilization"] = util_pct
                        metrics["instant_util_pct"] = n_srv > 0 ? round((Float64(zstate.busy_servers) / Float64(n_srv)) * 100.0, digits=1) : 0.0
                        metrics["total_served"] = zs !== nothing ? zs.total_departures : 0
                        metrics["service_mean"] = (zs !== nothing && zs.sojourn_time_samples > 0) ? round(zs.sojourn_time_sum / zs.sojourn_time_samples, digits=2) : 0.0
                        metrics["badge"] = "[ $(Int(round(util_pct)))% $(srv_state) ]"
                        if zs !== nothing && !isempty(zs.recent_service_samples)
                            metrics["recent_service_samples"] = copy(zs.recent_service_samples)
                            empty!(zs.recent_service_samples)
                        end
                    elseif map_rec.role_in_zone == :conveyor_bed
                        occ = UInt32(zstate.busy_servers)
                        conv_spd = node isa IRConveyorNode ? node.speed : 1.5
                        conv_len = node isa IRConveyorNode ? node.length : 10.0
                        metrics["items_in_transit"] = zstate.busy_servers
                        metrics["in_transit"] = zstate.busy_servers
                        metrics["occupancy"] = zstate.busy_servers
                        metrics["speed"] = conv_spd
                        metrics["length"] = conv_len
                        metrics["transit_delay"] = node isa IRConveyorNode ? node.transit_delay : (conv_len / max(0.01, conv_spd))
                        metrics["total_transited"] = zs !== nothing ? zs.total_departures : 0
                        metrics["badge"] = "[ $(zstate.busy_servers) transit ]"
                    elseif map_rec.role_in_zone == :sink_drain
                        occ = UInt32(0)
                        dep_count = world.stats.total_departures
                        rate_sec = curr_t > 0.0 ? round(Float64(dep_count) / curr_t, digits=2) : 0.0
                        metrics["total_departures"] = dep_count
                        metrics["throughput_per_sec"] = rate_sec
                        metrics["throughput_per_min"] = round(rate_sec * 60.0, digits=1)
                        metrics["badge"] = "[ $(dep_count) done ]"
                    elseif map_rec.role_in_zone == :standalone
                        if node isa IRSourceNode
                            arr_count = world.stats.total_arrivals
                            rate_sec = curr_t > 0.0 ? round(Float64(arr_count) / curr_t, digits=2) : 0.0
                            metrics["total_arrivals"] = arr_count
                            metrics["rate_per_sec"] = rate_sec
                            metrics["badge"] = "[ $(arr_count) in ]"
                        else
                            occ = UInt32(zstate.queue_length + zstate.busy_servers)
                        end
                    end
                end
            end
        end

        push!(elements_state, DirectSnapshotElement(
            elem_id,
            kind_str,
            occ,
            metrics
        ))
    end

    # 2. Extract Entities
    entities = DirectSnapshotEntity[]

    for (ent_id, agent) in world.des_agents
        zid = agent.current_zone
        elem_id = "unknown"
        pos_x = 0.0
        pos_y = 0.0
        pos_z = 0.0
        vel_x = 0.0
        vel_y = 0.0
        vel_z = 0.0
        prog_val = 0.0

        if haskey(source_map.by_zone, zid)
            recs = source_map.by_zone[zid]
            
            # Check if this zone has fused queue + server
            fused_srv = nothing
            fused_q = nothing
            for r in recs
                if r.role_in_zone == :server_workstation
                    fused_srv = r
                elseif r.role_in_zone == :queue_buffer
                    fused_q = r
                end
            end

            if fused_srv !== nothing && fused_q !== nothing
                # If service has started, entity is at Server workstation
                if agent.service_start_time < Inf
                    elem_id = fused_srv.element_id
                    base_pos = get(ir.spatial_positions, elem_id, (0.0, 0.0, 0.0))
                    dim = get(ir.spatial_dimensions, elem_id, (2.0, 2.0, 1.0))
                    pos_x = base_pos[1] + dim[1] * 0.5
                    pos_y = base_pos[2] + dim[2] * 0.5
                    pos_z = base_pos[3]
                else
                    # Entity is waiting in queue buffer: compute slot position
                    elem_id = fused_q.element_id
                    base_pos = get(ir.spatial_positions, elem_id, (0.0, 0.0, 0.0))
                    dim = get(ir.spatial_dimensions, elem_id, (2.0, 2.0, 1.0))
                    # Slot offset along X axis
                    q_idx = 1
                    if haskey(world.zone_states, zid)
                        q_vec = world.zone_states[zid].queue
                        found_idx = findfirst(==(ent_id), q_vec)
                        q_idx = found_idx !== nothing ? found_idx : 1
                    end
                    slot_dx = (q_idx - 1) * 0.5
                    pos_x = (base_pos[1] + dim[1] * 0.5) - slot_dx
                    pos_y = base_pos[2] + dim[2] * 0.5
                    pos_z = base_pos[3]
                end
            else
                # Single station or conveyor
                first_rec = first(recs)
                elem_id = first_rec.element_id
                base_pos = get(ir.spatial_positions, elem_id, (0.0, 0.0, 0.0))
                dim = get(ir.spatial_dimensions, elem_id, (2.0, 2.0, 1.0))

                if first_rec.role_in_zone == :conveyor_bed
                    # Conveyor: interpolate along length based on transit progress
                    conv_node = get(ir.nodes, elem_id, nothing)
                    transit_tau = (conv_node isa IRConveyorNode) ? conv_node.transit_delay : 2.0
                    elapsed = agent.service_start_time < Inf ? max(0.0, curr_t - agent.service_start_time) : 0.0
                    prog_val = clamp(elapsed / max(0.001, transit_tau), 0.0, 1.0)

                    # Determine orientation and direction from downstream connections
                    downstreams = get(ir.downstream_conns, elem_id, Tuple{String, String, String, String}[])
                    
                    if dim[1] >= dim[2]
                        # Horizontal conveyor along X
                        reverse_dir = false
                        if !isempty(downstreams)
                            dst_id = first(downstreams)[1]
                            if haskey(ir.spatial_positions, dst_id)
                                dst_pos = ir.spatial_positions[dst_id]
                                dst_dim = get(ir.spatial_dimensions, dst_id, (2.0, 2.0, 1.0))
                                if (dst_pos[1] + dst_dim[1] * 0.5) < base_pos[1]
                                    reverse_dir = true
                                end
                            end
                        end

                        if reverse_dir
                            start_x = base_pos[1] + dim[1]
                            end_x = base_pos[1]
                        else
                            start_x = base_pos[1]
                            end_x = base_pos[1] + dim[1]
                        end
                        start_y = base_pos[2] + dim[2] * 0.5
                        end_y = start_y
                    else
                        # Vertical conveyor along Y
                        reverse_dir = false
                        if !isempty(downstreams)
                            dst_id = first(downstreams)[1]
                            if haskey(ir.spatial_positions, dst_id)
                                dst_pos = ir.spatial_positions[dst_id]
                                dst_dim = get(ir.spatial_dimensions, dst_id, (2.0, 2.0, 1.0))
                                if (dst_pos[2] + dst_dim[2] * 0.5) < base_pos[2]
                                    reverse_dir = true
                                end
                            end
                        end

                        start_x = base_pos[1] + dim[1] * 0.5
                        end_x = start_x
                        if reverse_dir
                            start_y = base_pos[2] + dim[2]
                            end_y = base_pos[2]
                        else
                            start_y = base_pos[2]
                            end_y = base_pos[2] + dim[2]
                        end
                    end

                    pos_x = start_x + prog_val * (end_x - start_x)
                    pos_y = start_y + prog_val * (end_y - start_y)
                    pos_z = base_pos[3]

                    vel_x = (end_x - start_x) / max(0.001, transit_tau)
                    vel_y = (end_y - start_y) / max(0.001, transit_tau)
                else
                    pos_x = base_pos[1] + dim[1] * 0.5
                    pos_y = base_pos[2] + dim[2] * 0.5
                    pos_z = base_pos[3]
                end
            end
        end

        spd_val = sqrt(vel_x * vel_x + vel_y * vel_y)

        props = Dict{String, Any}(
            "x" => pos_x,
            "y" => pos_y,
            "z" => pos_z,
            "vx" => vel_x,
            "vy" => vel_y,
            "vz" => vel_z,
            "speed" => spd_val,
            "progress" => prog_val,
            "element_id" => elem_id,
            "zone_id" => zid,
            "priority" => agent.priority,
            "in_service" => agent.service_start_time < Inf
        )

        push!(entities, DirectSnapshotEntity(
            string("ent_", ent_id),
            "product",
            elem_id,
            agent.arrival_time,
            [[pos_x, pos_y]],
            props
        ))
    end

    # 3. Global System KPIs & Invariant Checks
    tot_arr = world.stats.total_arrivals
    tot_dep = world.stats.total_departures
    act_wip = length(world.des_agents)
    
    act_q = 0
    act_srv = 0
    act_conv = 0
    for (elem_id, node) in ir.nodes
        if haskey(source_map.by_element, elem_id)
            map_rec = source_map.by_element[elem_id]
            for zid in map_rec.zone_ids
                if haskey(world.zone_states, zid)
                    zs_st = world.zone_states[zid]
                    if map_rec.role_in_zone == :queue_buffer
                        act_q += zs_st.queue_length
                    elseif map_rec.role_in_zone == :server_workstation
                        act_srv += zs_st.busy_servers
                    elseif map_rec.role_in_zone == :conveyor_bed
                        act_conv += zs_st.busy_servers
                    end
                end
            end
        end
    end

    sojourn_mean = world.stats.sojourn_time_samples > 0 ? round(world.stats.sojourn_time_sum / world.stats.sojourn_time_samples, digits=2) : 0.0
    wait_mean = world.stats.wait_time_samples > 0 ? round(world.stats.wait_time_sum / world.stats.wait_time_samples, digits=2) : 0.0
    th_eff = curr_t > 0.0 ? round(Float64(tot_dep) / curr_t, digits=3) : 0.0
    
    flow_err = abs(tot_arr - (tot_dep + act_wip))
    flow_ok = flow_err == 0

    # Little's Law check (L = lambda * W)
    L_obs = Float64(act_wip)
    lambda_eff = curr_t > 0.0 ? (Float64(tot_dep) / curr_t) : 0.0
    W_obs = world.stats.sojourn_time_samples > 0 ? (world.stats.sojourn_time_sum / world.stats.sojourn_time_samples) : 0.0
    
    littles_err, littles_status = if tot_dep < 15
        (0.0, "warming_up")
    else
        exp_L = lambda_eff * W_obs
        err = abs(L_obs - exp_L) / max(1.0, L_obs)
        st = err <= 0.03 ? "valid" : (err <= 0.08 ? "converging" : "investigate")
        (round(err * 100.0, digits=2), st)
    end

    abm_state_dict = Dict{String, Any}(
        "wip_total" => act_wip,
        "total_arrivals" => tot_arr,
        "total_departures" => tot_dep,
        "active_in_queues" => act_q,
        "active_in_service" => act_srv,
        "active_on_conveyors" => act_conv,
        "sojourn_mean" => sojourn_mean,
        "wait_mean" => wait_mean,
        "throughput_eff" => th_eff,
        "throughput_per_min" => round(th_eff * 60.0, digits=1),
        "flow_balance_error" => flow_err,
        "flow_balance_ok" => flow_ok,
        "warmup_complete" => tot_dep >= 30,
        "littles_law_error_pct" => littles_err,
        "littles_law_status" => littles_status
    )

    state_str = instance.is_running[] ? "running" : (instance.is_paused[] ? "paused" : "stopped")

    return DirectSnapshotPayload(
        "1.0.0",
        scene_id,
        curr_t,
        step_count,
        Float32(instance.clock_speed),
        state_str,
        elements_state,
        entities,
        abm_state_dict,
        Dict{String, Any}[],
        String[],
        false
    )
end
