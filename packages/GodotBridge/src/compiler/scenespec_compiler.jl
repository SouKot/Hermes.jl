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

    # 0. Extract top-level "product" key from raw dict before type conversion
    raw_product_dict = if raw_spec isa AbstractDict
        str_key = "product"
        sym_key = :product
        haskey(raw_spec, str_key) ? raw_spec[str_key] :
        haskey(raw_spec, sym_key) ? raw_spec[sym_key] : nothing
    else
        nothing
    end

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
            default_attrs = _parse_default_attributes(get(props, "default_attributes", nothing))
            raw_prio = get(props, "priority", get(default_attrs, "priority", 0))
            prio = raw_prio isa Real ? Int(round(raw_prio)) : 0
            ir.nodes[elem_id] = IRSourceNode(elem_id, string(get(props, "entity_type", "carton")), sampler, prio, default_attrs)

        elseif kind == "queue" || endswith(kind, "/queue")
            cap = Int(get(props, "capacity", 20))
            if cap <= 0
                push!(all_diagnostics, CompilerDiagnostic("COMPILER_CAPACITY", elem_id, "Queue capacity must be > 0, got $cap"; property_path="properties.capacity"))
                cap = 1
            end
            disc_str = lowercase(strip(string(get(props, "discipline", "fifo"))))
            disc = if disc_str in ("priority", "hol", "priority_hol")
                :priority
            elseif disc_str in ("lifo", "last_in_first_out", "stack")
                :lifo
            elseif disc_str in ("edd", "earliest_due_date")
                :edd
            elseif disc_str in ("spt", "shortest_processing_time")
                :spt
            elseif disc_str in ("custom", "comparator", "custom_comparator")
                :custom
            else
                :fifo
            end
            init_occ = Int(get(props, "initial_occupancy", 0))
            r_rule = Symbol(lowercase(string(get(props, "routing_rule", "fixed"))))
            r_weights = _parse_routing_weights(get(props, "routing_weights", nothing))
            custom_disc_code = strip(string(get(props, "custom_discipline", "")))
            ir.nodes[elem_id] = IRQueueNode(elem_id, cap, disc, init_occ, r_rule, r_weights, custom_disc_code)

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
            r_rule = Symbol(lowercase(string(get(props, "routing_rule", "fixed"))))
            r_weights = _parse_routing_weights(get(props, "routing_weights", nothing))
            intake_m = Symbol(lowercase(strip(string(get(props, "intake_mode", "slot_order")))))
            proc_m = Symbol(lowercase(strip(string(get(props, "process_mode", "standard")))))
            ir.nodes[elem_id] = IRServerNode(elem_id, num_srv, dist_obj, sampler, f_model, mtbf_v, mttr_v, r_rule, r_weights, intake_m, proc_m)

        elseif kind == "conveyor" || endswith(kind, "/conveyor")
            spd = max(0.01, Float64(get(props, "speed", 1.5)))
            cap = max(1, Int(get(props, "capacity", 10)))
            # Compute length: if 'length' property given, use it; otherwise Euclidean length of dimensions
            len = Float64(get(props, "length", ir.spatial_dimensions[elem_id][1]))
            if len <= 0.0
                len = 2.0
            end
            transit_tau = len / spd
            r_rule = Symbol(lowercase(string(get(props, "routing_rule", "fixed"))))
            r_weights = _parse_routing_weights(get(props, "routing_weights", nothing))
            cmode = Symbol(lowercase(strip(string(get(props, "conveyor_mode", "free_flow")))))
            pitch = max(0.01, Float64(get(props, "accumulation_pitch", get(props, "pitch", 0.5))))
            idx_iv = max(0.01, Float64(get(props, "index_interval", 1.0)))
            gap = max(0.0, Float64(get(props, "accumulation_gap", 0.0)))
            ir.nodes[elem_id] = IRConveyorNode(elem_id, len, spd, transit_tau, cap, r_rule, r_weights, cmode, pitch, idx_iv, gap)

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

        elseif kind in ["chart_station", "scope_2d", "digital_meter", "histogram_sink", "state_space_3d", "xy_scatter"] || any(k -> endswith(kind, "/" * k), ["chart_station", "scope_2d", "digital_meter", "histogram_sink", "state_space_3d", "xy_scatter"])
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

        # Compile authored lifecycle hooks if present in properties["hooks"]
        raw_hooks = get(props, "hooks", nothing)
        if raw_hooks isa AbstractDict && !isempty(raw_hooks)
            zh = ZoneHooks()
            has_any_hook = false
            for (ev_k, ev_sym) in (
                ("on_entry", :on_entry),
                ("on_service_start", :on_service_start),
                ("on_service_complete", :on_service_complete),
                ("on_exit", :on_exit),
                ("on_event", :on_event),
                ("on_pull", :on_pull)
            )
                code_str = strip(string(get(raw_hooks, ev_k, get(raw_hooks, ev_sym, ""))))
                if !isempty(code_str)
                    try
                        fn = parse_hook_expr(code_str)
                        setfield!(zh, ev_sym, fn)
                        has_any_hook = true
                    catch err
                        push!(all_diagnostics, CompilerDiagnostic(
                            "COMPILER_HOOK_SYNTAX",
                            elem_id,
                            "Hook '$ev_k' failed to compile: $(sprint(showerror, err))";
                            severity = DIAG_WARNING,
                            property_path = "properties.hooks.$ev_k"
                        ))
                    end
                end
            end
            if has_any_hook
                ir.zone_hooks[elem_id] = zh
                if zh.on_pull !== nothing && haskey(ir.nodes, elem_id) && ir.nodes[elem_id] isa IRServerNode
                    sn = ir.nodes[elem_id]::IRServerNode
                    if sn.intake_mode === :slot_order
                        ir.nodes[elem_id] = IRServerNode(
                            sn.id, sn.num_servers, sn.service_dist_obj, sn.service_sampler,
                            sn.failure_model, sn.mtbf, sn.mttr, sn.routing_rule, sn.routing_weights,
                            :custom, sn.process_mode
                        )
                    end
                end
            end
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

    # 3b. Parse ProductDefinition from raw spec (if present) and rebuild IR with it
    product_def = if raw_product_dict !== nothing
        pd = raw_product_dict
        _get(k, default) = begin
            sk = string(k); sy = Symbol(k)
            haskey(pd, sk) ? pd[sk] : (haskey(pd, sy) ? pd[sy] : default)
        end
        pname     = string(_get("name", "Product"))
        pw        = Float64(_get("width",  0.4))
        ph        = Float64(_get("height", 0.4))
        pdepth    = Float64(_get("depth",  0.4))
        raw_color = _get("color", nothing)
        pcolor = if raw_color !== nothing && length(raw_color) >= 3
            (Float64(raw_color[1]), Float64(raw_color[2]), Float64(raw_color[3]))
        else
            (0.3, 0.75, 1.0)
        end
        mt_raw = _get("mesh_type", "box")
        pmesh = Symbol(lowercase(string(mt_raw)))
        ProductDefinition(pname, pw, ph, pdepth, pcolor, pmesh)
    else
        ProductDefinition()
    end

    # Reconstruct IR with parsed product_def (struct is immutable)
    ir = ExecutionGraphIR(
        ir.nodes,
        ir.element_to_zone,
        ir.zone_to_element,
        ir.downstream_conns,
        ir.spatial_positions,
        ir.spatial_dimensions,
        product_def,
        ir.conveyor_curves,
        ir.zone_hooks
    )

    # 3c. Bake 3D/2D parametric conveyor curves & resolve C¹ junction poses
    bake_all_conveyor_curves!(ir, flat_spec)

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
    # Register synthetic zone 0 for end-to-end system sojourn W and per-priority stats (-100 - priority)
    world.zone_stats[0] = SimCore.SimStats()
    for zs in values(world.zone_stats)
        zs.warmup_complete = true
    end

    # Add crowd obstacles if any
    for obs in crowd_artifacts.obstacles
        SimCore.add_obstacle!(world, obs)
    end

    # Populate PortDirectory, containment hierarchy, and entity groups
    _populate_port_directory_and_containment!(world, typed_spec, flat_spec, ir)

    # 8. Seed initial events and initial entity attributes
    init_rng = default_rng()
    for (zid, t_arr, prio) in des_artifacts.initial_arrivals
        ent_id = SimCore.new_entity_id!(world)
        seeded_prio = prio
        cfg = get(des_artifacts.zone_configs, zid, nothing)
        if cfg !== nothing
            arr = cfg.arrival
            if arr isa CustomArrivalProcess
                seeded_prio = _seed_entity_attributes!(
                    world, init_rng, ent_id, t_arr, prio,
                    arr.entity_type, arr.default_attributes, arr.spawn_counter
                )
            elseif arr isa CompositeArrivalProcess
                for proc in arr.processes
                    if abs(proc.last_scheduled_t[] - t_arr) < 1e-6
                        seeded_prio = _seed_entity_attributes!(
                            world, init_rng, ent_id, t_arr, prio,
                            proc.entity_type, proc.default_attributes, proc.spawn_counter
                        )
                        break
                    end
                end
            end
        end
        SimDES.schedule!(fel, SimCore.EntityArrival(ent_id, zid, t_arr, seeded_prio, true), t_arr)
    end

    # First breakdown of every machine with a failure model; later ones are chained by the repair handler.
    for (zid, cfg) in des_artifacts.zone_configs
        if cfg.failures isa SimDES.BernoulliFailure
            t_fail = rand(init_rng, Exponential(1.0 / cfg.failures.α))
            SimDES.schedule!(fel, SimCore.ResourceFailure(zid, 1.0f0, t_fail), t_fail)
        end
    end
    return CompilationResult(true, world, fel, des_artifacts.zone_configs, des_artifacts.source_map, all_diagnostics, ir)
end

function _populate_port_directory_and_containment!(
    world::SimCore.SimWorld,
    typed_spec::TypedSceneSpec,
    flat_spec::TypedSceneSpec,
    ir::ExecutionGraphIR
)
    # 1. Register explicit subgraphs as container handles (is_container = true)
    for sg in typed_spec.subgraphs
        SimCore.register_entity_handle!(world, sg.id, :subgraph; is_container=true, zone_id=0)
    end

    # 2. Register all elements, ports, groups, and containment links
    for elem in flat_spec.elements
        ksym = Symbol(split(lowercase(strip(elem.kind)), '/')[end])
        zid = get(ir.element_to_zone, elem.id, 0)
        is_cont = ksym in (:subgraph, :container, :cell, :zone)
        h = SimCore.register_entity_handle!(world, elem.id, ksym; is_container=is_cont, zone_id=zid)
        if zid > 0 && ksym in (:server, :conveyor)
            world.port_directory.zone_to_handle[zid] = h
        end
        SimCore.register_port!(world, h, :in_flow, :in; domain=:flow)
        SimCore.register_port!(world, h, :out_flow, :out; domain=:flow)
        SimCore.register_port!(world, h, :in_signal, :in; domain=:signal)
        SimCore.register_port!(world, h, :out_signal, :out; domain=:signal)
        SimCore.register_port!(world, h, :in_event, :in; domain=:event)
        SimCore.register_port!(world, h, :out_event, :out; domain=:event)
        SimCore.register_port!(world, h, :out_metric, :out; domain=:metric)

        props = elem.properties
        # Groups
        raw_g = get(props, "group", nothing)
        if raw_g !== nothing && !isempty(strip(string(raw_g)))
            gvec = get!(world.port_directory.by_group, Symbol(strip(string(raw_g))), SimCore.EntityHandle[])
            !(h in gvec) && push!(gvec, h)
        end
        raw_gs = get(props, "groups", nothing)
        if raw_gs isa AbstractVector
            for g in raw_gs
                gs = strip(string(g))
                if !isempty(gs)
                    gvec = get!(world.port_directory.by_group, Symbol(gs), SimCore.EntityHandle[])
                    !(h in gvec) && push!(gvec, h)
                end
            end
        end

        # Containment (explicit container/parent property or slash-separated subgraph prefix)
        parent_str = strip(string(get(props, "container", get(props, "parent", ""))))
        if isempty(parent_str) && occursin('/', elem.id)
            parts = split(elem.id, '/')
            parent_str = join(parts[1:end-1], "/")
        end
        if !isempty(parent_str)
            ph = SimCore.register_entity_handle!(world, parent_str, :subgraph; is_container=true, zone_id=0)
            world.containment_parent[h] = ph
            cvec = get!(world.containment_children, ph, SimCore.EntityHandle[])
            !(h in cvec) && push!(cvec, h)
        end
    end

    # 3. Register all enabled connections as bidirectional port wires
    for conn in flat_spec.connections
        !conn.enabled && continue
        sh = get(world.port_directory.name_to_handle, conn.source_element, SimCore.INVALID_HANDLE)
        dh = get(world.port_directory.name_to_handle, conn.target_element, SimCore.INVALID_HANDLE)
        if isvalid(sh) && isvalid(dh)
            lt = Symbol(lowercase(string(conn.link_type)))
            sp_raw = lowercase(strip(conn.source_port))
            dp_raw = lowercase(strip(conn.target_port))
            sp = (lt === :flow && sp_raw in ("out", "flow_out", "out_flow", "")) ? :out_flow : Symbol(sp_raw)
            dp = (lt === :flow && dp_raw in ("in", "flow_in", "in_flow", "")) ? :in_flow : Symbol(dp_raw)
            SimCore.register_port_wire!(world, sh, sp, dh, dp; wire_id=conn.id)
        end
    end
    return nothing
end

function _parse_routing_weights(raw)::Dict{String, Float64}
    res = Dict{String, Float64}()
    if raw isa AbstractDict
        for (k, v) in raw
            if v isa Real
                res[string(k)] = Float64(v)
            end
        end
    end
    return res
end

function _parse_default_attributes(raw)::Dict{String, Any}
    res = Dict{String, Any}()
    if raw isa AbstractDict
        for (k, v) in raw
            res[string(k)] = v
        end
    end
    return res
end

