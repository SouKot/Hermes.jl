# packages/GodotBridge/src/compiler/scenespec_compiler.jl
#
# Unified SceneSpec Compiler Pipeline for Antigravity / Hermes.jl.
# Lowers authored SceneSpec v1 (declarative JSON/MsgPack or TypedSceneSpec)
# into an in-memory execution graph, registers SimDES ZoneConfigs,
# pre-seeds FutureEventList arrivals, and builds bi-directional telemetry source maps.

using SimCore
using SimDES
using Random: AbstractRNG, default_rng
using StaticArrays: SVector

"""
    CompilationResult

Container holding the compiled simulation world, event list, configurations,
source map, diagnostics, and intermediate representation.
"""
struct CompilationResult
    success::Bool
    world::Union{SimCore.SimWorld, Nothing}
    fel::Union{SimDES.FutureEventList, Nothing}
    zone_configs::Dict{Int, SimDES.ZoneConfig}
    source_map::SourceMap
    diagnostics::Vector{CompilerDiagnostic}
    execution_ir::Union{ExecutionGraphIR, Nothing}
end

"""
    compile_scenespec(raw_spec; time_unit::String="seconds") -> CompilationResult

Compiles an authored SceneSpec (TypedSceneSpec, SceneSpecPayload, or Dict) into an executable
SimWorld with pre-seeded FutureEventList and ZoneConfigs ready for simulation.
"""
function compile_scenespec(raw_spec; time_unit::String="seconds")::CompilationResult
    all_diagnostics = CompilerDiagnostic[]

    # 1. Convert to TypedSceneSpec if needed
    typed_spec = if raw_spec isa TypedSceneSpec
        raw_spec
    elseif raw_spec isa SceneSpecPayload
        GodotBridge.to_typed_scenespec(raw_spec)
    elseif raw_spec isa AbstractDict
        payload = GodotBridge.parse_scenespec(raw_spec)
        GodotBridge.to_typed_scenespec(payload)
    else
        push!(all_diagnostics, CompilerDiagnostic(
            "COMPILER_INVALID_INPUT",
            "root",
            "Expected TypedSceneSpec, SceneSpecPayload, or AbstractDict, got $(typeof(raw_spec))";
            severity = DIAG_ERROR
        ))
        return CompilationResult(false, nothing, nothing, Dict{Int, SimDES.ZoneConfig}(), SourceMap(), all_diagnostics, nothing)
    end

    # 2. Expand hierarchical subgraphs if present
    flat_spec = if !isempty(typed_spec.subgraphs)
        csg = GodotBridge.expand_subgraphs(typed_spec)
        csg.flat_spec
    else
        typed_spec
    end

    base_time_unit = isempty(flat_spec.simulation.time_unit) ? time_unit : flat_spec.simulation.time_unit

    # 3. Build ExecutionGraphIR
    ir = ExecutionGraphIR()

    for elem in flat_spec.elements
        elem_id = elem.id
        kind = lowercase(strip(elem.kind))
        props = elem.properties

        # Store spatial metadata
        pos = elem.transform.position
        ir.spatial_positions[elem_id] = (pos[1], pos[2], pos[3])
        dims = elem.geometry.dimensions
        if length(dims) >= 3
            ir.spatial_dimensions[elem_id] = (dims[1], dims[2], dims[3])
        elseif length(dims) == 2
            ir.spatial_dimensions[elem_id] = (dims[1], dims[2], 1.0)
        else
            ir.spatial_dimensions[elem_id] = (2.0, 2.0, 1.0)
        end

        # Map by kind
        if kind == "source" || endswith(kind, "/source")
            sampler, errs = parse_arrival_sampler(props, base_time_unit)
            for e in errs
                push!(all_diagnostics, CompilerDiagnostic("COMPILER_ARRIVAL_DIST", elem_id, e; property_path="properties.interarrival_time"))
            end
            prio = Int(get(props, "priority", 0))
            ir.nodes[elem_id] = IRSourceNode(elem_id, string(get(props, "entity_type", "carton")), sampler, prio)

        elseif kind == "queue" || endswith(kind, "/queue")
            cap = Int(get(props, "capacity", 20))
            if cap <= 0
                push!(all_diagnostics, CompilerDiagnostic("COMPILER_CAPACITY", elem_id, "Queue capacity must be > 0, got $cap"; property_path="properties.capacity"))
                cap = 1
            end
            disc_str = lowercase(string(get(props, "discipline", "fifo")))
            disc = disc_str == "priority" ? :priority : (disc_str == "lifo" ? :lifo : :fifo)
            init_occ = Int(get(props, "initial_occupancy", 0))
            ir.nodes[elem_id] = IRQueueNode(elem_id, cap, disc, init_occ)

        elseif kind == "server" || endswith(kind, "/server")
            num_srv = Int(get(props, "servers", 1))
            if num_srv <= 0
                push!(all_diagnostics, CompilerDiagnostic("COMPILER_SERVERS", elem_id, "Server count must be >= 1, got $num_srv"; property_path="properties.servers"))
                num_srv = 1
            end
            dist_obj, sampler, errs = parse_service_sampler(props, base_time_unit)
            for e in errs
                push!(all_diagnostics, CompilerDiagnostic("COMPILER_SERVICE_DIST", elem_id, e; property_path="properties.service_time"))
            end
            f_model = Symbol(lowercase(string(get(props, "failure_model", "none"))))
            mtbf_v = Float64(get(props, "mtbf", 3600.0))
            mttr_v = Float64(get(props, "mttr", 120.0))
            ir.nodes[elem_id] = IRServerNode(elem_id, num_srv, dist_obj, sampler, f_model, mtbf_v, mttr_v)

        elseif kind == "conveyor" || endswith(kind, "/conveyor")
            spd = max(0.01, Float64(get(props, "speed", 1.5)))
            cap = max(1, Int(get(props, "capacity", 10)))
            # Compute length: if 'length' property given, use it; otherwise Euclidean length of dimensions
            len = Float64(get(props, "length", ir.spatial_dimensions[elem_id][1]))
            if len <= 0.0
                len = 2.0
            end
            transit_tau = len / spd
            ir.nodes[elem_id] = IRConveyorNode(elem_id, len, spd, transit_tau, cap)

        elseif kind == "sink" || endswith(kind, "/sink")
            rec_soj = Bool(get(props, "record_sojourn", true))
            ir.nodes[elem_id] = IRSinkNode(elem_id, rec_soj)

        elseif kind == "crowd_spawner" || endswith(kind, "/crowd_spawner")
            s_rate = Float64(get(props, "spawn_rate", 1.0))
            gx = Float64(get(props, "goal_x", 0.0))
            gy = Float64(get(props, "goal_y", 0.0))
            ir.nodes[elem_id] = IRCrowdSpawnerNode(elem_id, s_rate, (gx, gy))

        elseif kind == "hybrid_gate" || endswith(kind, "/hybrid_gate")
            cap = Int(get(props, "capacity", 1))
            transit = Float64(get(props, "transit_delay", 1.0))
            ir.nodes[elem_id] = IRHybridGateNode(elem_id, cap, transit)

        elseif kind in ["scope_2d", "digital_meter", "histogram_sink", "state_space_3d", "xy_scatter"] || any(k -> endswith(kind, "/" * k), ["scope_2d", "digital_meter", "histogram_sink", "state_space_3d", "xy_scatter"])
            # Telemetry scope / instrumentation sink (client-side visualization)
            continue
        else
            # Generic passthrough or unknown element
            push!(all_diagnostics, CompilerDiagnostic(
                "COMPILER_UNKNOWN_KIND",
                elem_id,
                "Element '$elem_id' has unrecognized kind '$kind'. Treated as generic passthrough.";
                severity = DIAG_WARNING
            ))
        end
    end

    # Extract flow connections (ignoring pure telemetry signal, event, metric, and control links)
    for conn in flat_spec.connections
        lt = Symbol(conn.link_type)
        if !conn.enabled || lt != :flow
            continue
        end
        src = conn.source_element
        dst = conn.target_element
        src_port = conn.source_port
        dst_port = conn.target_port
        cid = conn.id

        if !haskey(ir.downstream_conns, src)
            ir.downstream_conns[src] = Tuple{String, String, String, String}[]
        end
        push!(ir.downstream_conns[src], (dst, src_port, dst_port, cid))
    end

    # 4. Check for blocking compilation errors
    if has_errors(all_diagnostics)
        return CompilationResult(false, nothing, nothing, Dict{Int, SimDES.ZoneConfig}(), SourceMap(), all_diagnostics, ir)
    end

    # 5. Compile DES graph
    des_artifacts = compile_des_graph(ir)
    append!(all_diagnostics, des_artifacts.diagnostics)

    if has_errors(all_diagnostics)
        return CompilationResult(false, nothing, nothing, Dict{Int, SimDES.ZoneConfig}(), des_artifacts.source_map, all_diagnostics, ir)
    end

    # 6. Compile Crowd graph
    crowd_artifacts = compile_crowd_graph(ir)
    append!(all_diagnostics, crowd_artifacts.diagnostics)

    # 7. Initialize SimWorld & FutureEventList
    world = SimCore.SimWorld()
    world.stats.warmup_complete = true
    fel = SimDES.FutureEventList()

    # Build zones in world
    for (_, cfg) in des_artifacts.zone_configs
        SimDES.build_world!(world, cfg)
    end
    for zs in values(world.zone_stats)
        zs.warmup_complete = true
    end

    # Add crowd obstacles if any
    for obs in crowd_artifacts.obstacles
        SimCore.add_obstacle!(world, obs)
    end

    # 8. Seed initial events
    for (zid, t_arr) in des_artifacts.initial_arrivals
        ent_id = SimCore.new_entity_id!(world)
        SimDES.schedule!(fel, SimCore.EntityArrival(ent_id, zid, t_arr), t_arr)
    end

    return CompilationResult(true, world, fel, des_artifacts.zone_configs, des_artifacts.source_map, all_diagnostics, ir)
end
