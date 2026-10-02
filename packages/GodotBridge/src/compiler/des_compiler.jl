# packages/GodotBridge/src/compiler/des_compiler.jl
#
# Discrete-Event Simulation (DES) Sub-Compiler for SceneSpec v1.
# Lowers ExecutionGraphIR into SimDES.ZoneConfig structures, routing policies,
# arrival processes, and bi-directional source mapping records.

using SimDES: ZoneConfig, ServiceDist, RoutingPolicy, ExitSystem, FixedRoute, ProbRoute
using SimDES: ShortestQueueRoute, RoundRobinRoute, DynamicPolicyRoute
using SimDES: ArrivalProcess, NoArrival, PoissonArrival, QueueDiscipline, FIFO, PRIORITY_HOL
using SimDES: FailureModel, NoFailure, BernoulliFailure
using SimDES: deterministic_service, exponential_service, erlang_service
using Random: AbstractRNG
using Distributions: UnivariateDistribution, Dirac, Exponential

"""
    CustomArrivalProcess{F} <: ArrivalProcess

Custom callable arrival process wrapping an arbitrary sampler: `(rng::AbstractRNG) -> Float64`.
Enables any authored distribution (Triangular, Normal, Erlang, Dirac, Uniform) to drive
entity arrivals into SimDES without modifying SimDES core, preserving source priority.
"""
struct CustomArrivalProcess{F} <: ArrivalProcess
    sampler::F
    priority::Int
    last_scheduled_t::Base.RefValue{Float64}
    entity_type::String
    default_attributes::Dict{String, Any}
    spawn_counter::Base.RefValue{Int}
end
CustomArrivalProcess(sampler::F, priority::Int=0, last_t::Base.RefValue{Float64}=Ref(0.01), entity_type::String="carton", default_attrs::Dict{String, Any}=Dict{String, Any}()) where {F} =
    CustomArrivalProcess{F}(sampler, priority, last_t, entity_type, default_attrs, Ref(0))

function _seed_entity_attributes!(
    world::SimCore.SimWorld,
    rng::AbstractRNG,
    entity_id::Integer,
    t::Float64,
    default_prio::Int,
    entity_type::String,
    default_attrs::Dict{String, Any},
    spawn_counter::Base.RefValue{Int}
)::Int
    spawn_counter[] += 1
    seq = spawn_counter[]
    SimCore.set_entity_attribute!(world, entity_id, "type", entity_type)
    SimCore.set_entity_attribute!(world, entity_id, "spawn_seq", seq)
    prio = default_prio
    for (k_str, raw_v) in default_attrs
        val = if raw_v isa AbstractVector && !isempty(raw_v)
            raw_v[mod1(seq, length(raw_v))]
        elseif raw_v == "auto_increment"
            seq
        elseif raw_v isa AbstractDict && haskey(raw_v, "distribution")
            dname = lowercase(string(raw_v["distribution"]))
            if dname == "uniform"
                lo = Float64(get(raw_v, "min", 0.0))
                hi = Float64(get(raw_v, "max", 1.0))
                lo + rand(rng) * (hi - lo)
            elseif dname in ("exponential", "exp")
                m = Float64(get(raw_v, "mean", 1.0))
                -m * log(max(1e-12, rand(rng)))
            else
                get(raw_v, "value", 0.0)
            end
        else
            raw_v
        end
        if (k_str == "due_offset" || k_str == "due_date_offset") && val isa Real
            SimCore.set_entity_attribute!(world, entity_id, "due_date", t + Float64(val))
        end
        SimCore.set_entity_attribute!(world, entity_id, k_str, val)
        if k_str == "priority" && val isa Real
            prio = Int(round(val))
        end
    end
    return prio
end

# Extend SimDES arrival scheduling for CustomArrivalProcess via multiple dispatch
function SimDES._schedule_next_arrival!(world::SimCore.SimWorld, fel::SimDES.FutureEventList,
                                        rng::AbstractRNG, zone_id::Int,
                                        a::CustomArrivalProcess, t::Float64)
    Δt = max(0.0001, Float64(a.sampler(rng)))
    t_next = t + Δt
    a.last_scheduled_t[] = t_next
    ent_id = SimCore.new_entity_id!(world)
    prio = _seed_entity_attributes!(world, rng, ent_id, t_next, a.priority, a.entity_type, a.default_attributes, a.spawn_counter)
    SimDES.schedule!(fel, SimCore.EntityArrival(ent_id, zone_id, t_next, prio, true), t_next)
    return nothing
end

"""
    CompositeArrivalProcess <: ArrivalProcess

Superposes multiple independent `CustomArrivalProcess` streams feeding a single target zone
(e.g., a high-priority VIP source and a standard source feeding the same dispatch queue).
"""
struct CompositeArrivalProcess <: ArrivalProcess
    processes::Vector{CustomArrivalProcess}
end

function SimDES._schedule_next_arrival!(world::SimCore.SimWorld, fel::SimDES.FutureEventList,
                                        rng::AbstractRNG, zone_id::Int,
                                        a::CompositeArrivalProcess, t::Float64)
    isempty(a.processes) && return nothing
    # Find the sub-process whose scheduled arrival just fired at time `t`
    best_idx = 1
    best_diff = Inf
    for (idx, proc) in enumerate(a.processes)
        d = abs(proc.last_scheduled_t[] - t)
        if d < best_diff
            best_diff = d
            best_idx = idx
        end
    end
    SimDES._schedule_next_arrival!(world, fel, rng, zone_id, a.processes[best_idx], t)
    return nothing
end

"""
    CallableServiceDist{F}

Wraps a custom zero-allocation sampler function `(rng::AbstractRNG) -> Float64`
into a SimDES-compatible service distribution.
"""
struct CallableServiceDist{F}
    sampler::F
end

(csd::CallableServiceDist)(rng::AbstractRNG) = max(0.0001, Float64(csd.sampler(rng)))

"""
    DESCompilationArtifacts

Result of lowering ExecutionGraphIR into DES runtime structures.
"""
struct DESCompilationArtifacts
    zone_configs::Dict{Int, ZoneConfig}
    source_map::SourceMap
    initial_arrivals::Vector{Tuple{Int, Float64, Int}} # (zone_id, t_arrival, priority)
    diagnostics::Vector{CompilerDiagnostic}
end

"""
    compile_des_graph(ir::ExecutionGraphIR) -> DESCompilationArtifacts

Compiles discrete-event nodes and flow connections in the intermediate representation
into executable `ZoneConfig` dictionaries and `SourceMap` registries.
"""
function compile_des_graph(ir::ExecutionGraphIR)::DESCompilationArtifacts
    diagnostics = CompilerDiagnostic[]
    zone_configs = Dict{Int, ZoneConfig}()
    source_map = SourceMap()
    initial_arrivals = Tuple{Int, Float64, Int}[]

    # 1. Topology analysis: classify connections and find Queue -> Server fusion candidates
    # Count how many queues feed each server so multi-queue servers (N queues -> 1 server) do NOT fuse
    server_incoming_queues = Dict{String, Int}()
    for (elem_id, node) in ir.nodes
        if node isa IRQueueNode
            conns = get(ir.downstream_conns, elem_id, Tuple{String, String, String, String}[])
            for (dest_id, _, _, _) in conns
                if get(ir.nodes, dest_id, nothing) isa IRServerNode
                    server_incoming_queues[dest_id] = get(server_incoming_queues, dest_id, 0) + 1
                end
            end
        end
    end

    fused_pairs = Dict{String, String}() # queue_id => server_id
    server_to_queue = Dict{String, String}() # server_id => queue_id

    for (elem_id, node) in ir.nodes
        if node isa IRQueueNode
            conns = get(ir.downstream_conns, elem_id, Tuple{String, String, String, String}[])
            if length(conns) == 1
                dest_id, _, _, _ = first(conns)
                dest_node = get(ir.nodes, dest_id, nothing)
                if dest_node isa IRServerNode &&
                   get(server_incoming_queues, dest_id, 0) == 1 &&
                   dest_node.intake_mode === :slot_order &&
                   !haskey(ir.zone_hooks, elem_id)
                    # Fuse single-queue -> single-server when queue has no standalone hooks
                    fused_pairs[elem_id] = dest_id
                    server_to_queue[dest_id] = elem_id
                end
            end
        end
    end

    # 2. Assign unique zone IDs to stations
    # If Queue and Server are fused, they share a single ZoneID.
    element_to_zone = Dict{String, Int}()
    next_zone_id = 1

    # First pass: assign zone IDs in deterministic sorted order
    for elem_id in sort!(collect(keys(ir.nodes)))
        node = ir.nodes[elem_id]
        if node isa IRSourceNode || node isa IRSinkNode || node isa IRCrowdSpawnerNode || node isa IRHybridGateNode
            continue
        elseif node isa IRQueueNode
            if haskey(fused_pairs, elem_id)
                srv_id = fused_pairs[elem_id]
                if !haskey(element_to_zone, srv_id)
                    zid = next_zone_id
                    next_zone_id += 1
                    element_to_zone[elem_id] = zid
                    element_to_zone[srv_id] = zid
                else
                    element_to_zone[elem_id] = element_to_zone[srv_id]
                end
            else
                element_to_zone[elem_id] = next_zone_id
                next_zone_id += 1
            end
        elseif node isa IRServerNode
            if !haskey(element_to_zone, elem_id)
                element_to_zone[elem_id] = next_zone_id
                next_zone_id += 1
            end
        elseif node isa IRConveyorNode
            element_to_zone[elem_id] = next_zone_id
            next_zone_id += 1
        end
    end

    # Populate ir.element_to_zone and ir.zone_to_element
    merge!(ir.element_to_zone, element_to_zone)
    for (eid, zid) in element_to_zone
        if !haskey(ir.zone_to_element, zid) || (ir.nodes[eid] isa IRServerNode)
            ir.zone_to_element[zid] = eid
        end
    end

    # 3. Determine arrival processes for nodes fed by IRSourceNodes
    zone_arrivals = Dict{Int, ArrivalProcess}()
    zone_proc_lists = Dict{Int, Vector{CustomArrivalProcess}}()

    for (elem_id, node) in ir.nodes
        if node isa IRSourceNode
            conns = get(ir.downstream_conns, elem_id, Tuple{String, String, String, String}[])
            if isempty(conns)
                push!(diagnostics, CompilerDiagnostic(
                    "DES_DISCONNECTED_SOURCE",
                    elem_id,
                    "Source node '$elem_id' has no outgoing flow connections.";
                    severity = DIAG_WARNING,
                    suggested_fix = "Connect the source's 'flow_out' port to a queue, server, or conveyor."
                ))
                continue
            end

            for (dest_id, _, _, _) in conns
                dest_zone = get(element_to_zone, dest_id, nothing)
                if dest_zone === nothing
                    # Target might be a sink or invalid
                    push!(diagnostics, CompilerDiagnostic(
                        "DES_INVALID_FEED",
                        elem_id,
                        "Source '$elem_id' connects to '$dest_id' which is not an active processing or transport station.";
                        severity = DIAG_ERROR,
                        suggested_fix = "Connect source to a valid Queue, Server, or Conveyor."
                    ))
                    continue
                end

                plist = get!(zone_proc_lists, dest_zone, CustomArrivalProcess[])
                stream_offset = length(plist) * 0.0001
                initial_t = 0.01 + stream_offset
                arr_proc = CustomArrivalProcess(node.arrival_sampler, node.priority, Ref(initial_t), node.entity_type, node.default_attributes)
                push!(plist, arr_proc)
                push!(initial_arrivals, (dest_zone, initial_t, node.priority))
            end
        end
    end

    for (zid, plist) in zone_proc_lists
        zone_arrivals[zid] = length(plist) == 1 ? plist[1] : CompositeArrivalProcess(plist)
    end

    # 4. Helper to resolve downstream routing for a given station
    function resolve_routing(from_elem_id::String)::RoutingPolicy
        conns = get(ir.downstream_conns, from_elem_id, Tuple{String, String, String, String}[])
        if isempty(conns)
            return ExitSystem()
        end

        from_node = get(ir.nodes, from_elem_id, nothing)
        r_rule = :fixed
        r_weights = Dict{String, Float64}()
        if from_node isa IRServerNode || from_node isa IRQueueNode || from_node isa IRConveyorNode
            r_rule = from_node.routing_rule
            r_weights = from_node.routing_weights
        end
        # If fused server has default :fixed rule, check if its paired queue specified a rule
        if r_rule == :fixed && haskey(server_to_queue, from_elem_id)
            q_node = get(ir.nodes, server_to_queue[from_elem_id], nothing)
            if q_node isa IRQueueNode && q_node.routing_rule != :fixed
                r_rule = q_node.routing_rule
                r_weights = q_node.routing_weights
            end
        end

        valid_targets = Tuple{Union{Int, Nothing}, Float64}[]
        for (dest_id, _, _, _) in conns
            dest_node = get(ir.nodes, dest_id, nothing)
            w = max(0.0, get(r_weights, dest_id, 1.0))
            if dest_node isa IRSinkNode
                push!(valid_targets, (nothing, w))
            elseif haskey(element_to_zone, dest_id)
                target_zid = element_to_zone[dest_id]
                push!(valid_targets, (target_zid, w))
            else
                push!(diagnostics, CompilerDiagnostic(
                    "DES_UNKNOWN_DESTINATION",
                    from_elem_id,
                    "Station '$from_elem_id' connects to unknown or unsupported element '$dest_id'.";
                    severity = DIAG_ERROR,
                    suggested_fix = "Verify connections or delete invalid link."
                ))
            end
        end

        if isempty(valid_targets)
            return ExitSystem()
        elseif length(valid_targets) == 1
            dest, _ = first(valid_targets)
            return dest === nothing ? ExitSystem() : FixedRoute(dest)
        else
            if r_rule in (:shortest_queue, :sq)
                cands = Int[dest for (dest, _) in valid_targets if dest !== nothing]
                return isempty(cands) ? ExitSystem() : ShortestQueueRoute(cands)
            elseif r_rule in (:round_robin, :rr)
                cands = Int[dest for (dest, _) in valid_targets if dest !== nothing]
                return isempty(cands) ? ExitSystem() : RoundRobinRoute(cands)
            elseif r_rule in (:dynamic_policy, :state_threshold, :vip_threshold)
                cands = Int[dest for (dest, _) in valid_targets if dest !== nothing]
                isempty(cands) && return ExitSystem()
                θ_q = get(r_weights, "vip_queue_threshold", 1.0)
                θ_ρ = get(r_weights, "pool_util_threshold", 0.85)
                policy_fn = (world, entity_id, agent, cand_ids) -> begin
                    length(cand_ids) == 1 && return cand_ids[1]
                    z_ded = get(world.zone_states, cand_ids[1], nothing)
                    z_pool = get(world.zone_states, cand_ids[2], nothing)
                    (z_ded === nothing || z_pool === nothing) && return cand_ids[1]
                    if agent.priority >= 1
                        # State-dependent VIP policy π*(s):
                        # effective_vip_q = 0 if a dedicated server is free, else 1 + queue_length
                        eff_q = z_ded.busy_servers < z_ded.num_servers ? 0 : (1 + z_ded.queue_length)
                        ρ_pool = z_pool.busy_servers / max(1, z_pool.num_servers)
                        if eff_q < θ_q || ρ_pool > θ_ρ
                            return cand_ids[1]
                        else
                            return cand_ids[2]
                        end
                    else
                        # Standard customer -> route to shared pool (cand_ids[2])
                        return cand_ids[2]
                    end
                end
                return DynamicPolicyRoute(cands, policy_fn)
            else
                total_w = sum(w for (_, w) in valid_targets)
                if total_w <= 0.0
                    p = 1.0 / length(valid_targets)
                    choices = [(dest, p) for (dest, _) in valid_targets]
                    return ProbRoute(choices)
                else
                    choices = [(dest, w / total_w) for (dest, w) in valid_targets]
                    return ProbRoute(choices)
                end
            end
        end
    end

    # 5. Build ZoneConfigs
    # Track processed zones so we don't compile fused zones twice
    compiled_zones = Set{Int}()

    for (elem_id, node) in ir.nodes
        zid = get(element_to_zone, elem_id, nothing)
        zid === nothing && continue
        zid in compiled_zones && continue

        if haskey(fused_pairs, elem_id)
            # Fused Queue + Server
            q_node = node::IRQueueNode
            srv_id = fused_pairs[elem_id]
            srv_node = ir.nodes[srv_id]::IRServerNode

            # Station capacity = queue capacity + server count
            total_capacity = q_node.capacity + srv_node.num_servers
            rule = parse_discipline(q_node.discipline)
            discipline = to_simdes_discipline(rule)
            srv_dist = srv_node.service_dist_obj isa UnivariateDistribution ?
                       ServiceDist(srv_node.service_dist_obj) : ServiceDist(Dirac(1.0))
            arrival = get(zone_arrivals, zid, NoArrival())
            routing = resolve_routing(srv_id)

            failures = srv_node.failure_model == :mtbf_mttr ?
                       BernoulliFailure(1.0 / max(1.0, srv_node.mtbf), 1.0 / max(1.0, srv_node.mttr)) :
                       NoFailure()

            c_disc_fn = if q_node.custom_discipline_fn isa Function
                q_node.custom_discipline_fn
            elseif q_node.custom_discipline_fn isa AbstractString && !isempty(strip(q_node.custom_discipline_fn))
                parse_discipline_expr(String(q_node.custom_discipline_fn))
            else
                nothing
            end

            # Create ZoneConfig
            cfg = ZoneConfig(
                id = zid,
                num_servers = max(1, srv_node.num_servers),
                capacity = max(1, total_capacity),
                service_dist = srv_dist,
                arrival = arrival,
                routing = routing,
                queue_discipline = discipline,
                failures = failures,
                custom_discipline = c_disc_fn,
                intake_mode = srv_node.intake_mode,
                process_mode = srv_node.process_mode
            )
            zone_configs[zid] = cfg
            push!(compiled_zones, zid)

            # Register source mappings for both elements
            register_mapping!(source_map, SourceMapRecord(
                elem_id, "queue", [zid], true, srv_id, :queue_buffer
            ))
            register_mapping!(source_map, SourceMapRecord(
                srv_id, "server", [zid], true, elem_id, :server_workstation
            ))

        elseif node isa IRServerNode && !haskey(server_to_queue, elem_id)
            # Standalone Server
            srv_node = node
            srv_dist = srv_node.service_dist_obj isa UnivariateDistribution ?
                       ServiceDist(srv_node.service_dist_obj) : ServiceDist(Dirac(1.0))
            arrival = get(zone_arrivals, zid, NoArrival())
            routing = resolve_routing(elem_id)
            failures = srv_node.failure_model == :mtbf_mttr ?
                       BernoulliFailure(1.0 / max(1.0, srv_node.mtbf), 1.0 / max(1.0, srv_node.mttr)) :
                       NoFailure()

            cfg = ZoneConfig(
                id = zid,
                num_servers = max(1, srv_node.num_servers),
                capacity = max(1, srv_node.num_servers),
                service_dist = srv_dist,
                arrival = arrival,
                routing = routing,
                queue_discipline = FIFO,
                failures = failures,
                intake_mode = srv_node.intake_mode,
                process_mode = srv_node.process_mode
            )
            zone_configs[zid] = cfg
            push!(compiled_zones, zid)

            register_mapping!(source_map, SourceMapRecord(
                elem_id, "server", [zid], false, nothing, :server_workstation
            ))

        elseif node isa IRConveyorNode
            # Conveyor as M/D/c delay line where c = capacity
            conv_node = node
            transit_tau = max(0.01, conv_node.transit_delay)
            arrival = get(zone_arrivals, zid, NoArrival())
            routing = resolve_routing(elem_id)

            cfg = ZoneConfig(
                id = zid,
                num_servers = max(1, conv_node.capacity),
                capacity = max(1, conv_node.capacity),
                service_dist = deterministic_service(transit_tau),
                arrival = arrival,
                routing = routing,
                queue_discipline = FIFO,
                failures = NoFailure(),
                conveyor_mode = conv_node.conveyor_mode,
                conveyor_pitch = conv_node.conveyor_pitch,
                conveyor_index_interval = conv_node.conveyor_index_interval,
                path_length = max(0.1, conv_node.length),
                nominal_speed = max(0.01, conv_node.speed),
                is_conveyor = true,
                conveyor_gap = conv_node.conveyor_gap
            )
            zone_configs[zid] = cfg
            push!(compiled_zones, zid)

            register_mapping!(source_map, SourceMapRecord(
                elem_id, "conveyor", [zid], false, nothing, :conveyor_bed
            ))

        elseif node isa IRQueueNode && !haskey(fused_pairs, elem_id)
            # Standalone Queue with pass-through delay
            q_node = node
            arrival = get(zone_arrivals, zid, NoArrival())
            routing = resolve_routing(elem_id)
            rule = parse_discipline(q_node.discipline)
            discipline = to_simdes_discipline(rule)
            c_disc_fn = if q_node.custom_discipline_fn isa Function
                q_node.custom_discipline_fn
            elseif q_node.custom_discipline_fn isa AbstractString && !isempty(strip(q_node.custom_discipline_fn))
                parse_discipline_expr(String(q_node.custom_discipline_fn))
            else
                nothing
            end

            cfg = ZoneConfig(
                id = zid,
                num_servers = 1,
                capacity = max(1, q_node.capacity),
                service_dist = deterministic_service(0.01),
                arrival = arrival,
                routing = routing,
                queue_discipline = discipline,
                failures = NoFailure(),
                custom_discipline = c_disc_fn
            )
            zone_configs[zid] = cfg
            push!(compiled_zones, zid)

            register_mapping!(source_map, SourceMapRecord(
                elem_id, "queue", [zid], false, nothing, :queue_buffer
            ))
        end
    end

    # Also register Source and Sink mappings in SourceMap
    for (elem_id, node) in ir.nodes
        if node isa IRSourceNode
            conns = get(ir.downstream_conns, elem_id, Tuple{String, String, String, String}[])
            target_zids = Int[]
            for (dest_id, _, _, _) in conns
                if haskey(element_to_zone, dest_id)
                    push!(target_zids, element_to_zone[dest_id])
                end
            end
            register_mapping!(source_map, SourceMapRecord(
                elem_id, "source", target_zids, false, nothing, :standalone
            ))
        elseif node isa IRSinkNode
            register_mapping!(source_map, SourceMapRecord(
                elem_id, "sink", Int[], false, nothing, :sink_drain
            ))
        end
    end

    return DESCompilationArtifacts(zone_configs, source_map, initial_arrivals, diagnostics)
end
