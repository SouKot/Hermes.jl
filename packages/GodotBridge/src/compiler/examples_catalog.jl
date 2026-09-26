# packages/GodotBridge/src/compiler/examples_catalog.jl
#
# Built-in Examples Catalog for Antigravity SimViz (DES, ABM/Hybrid, and SimOptim).
# Generates canonical SceneSpec v1.0.0 dictionaries that pass both Julia and Godot
# SceneSpec validators and include 2D/3D spatial layout and optimization metadata.

"""
    list_examples() -> Vector{Dict{String, Any}}

Returns metadata for all built-in example models grouped by category (`"des"`, `"abm"`, `"optimization"`).
"""
function list_examples()::Vector{Dict{String, Any}}
    return Dict{String, Any}[
        Dict{String, Any}(
            "id" => "des_tandem_cell",
            "category" => "des",
            "title" => "Tandem Manufacturing Cell",
            "description" => "Two-stage CNC machining and assembly line connected by a transfer conveyor."
        ),
        Dict{String, Any}(
            "id" => "des_mmc_failures",
            "category" => "des",
            "title" => "M/M/c Station with Failures",
            "description" => "Parallel multi-server workstation with stochastic MTBF/MTTR breakdown and repair cycles."
        ),
        Dict{String, Any}(
            "id" => "abm_corridor_crowd",
            "category" => "abm",
            "title" => "Pedestrian Corridor Flow",
            "description" => "Social-Force pedestrian crowd flow combined with a lobby reception desk."
        ),
        Dict{String, Any}(
            "id" => "hybrid_security_gate",
            "category" => "abm",
            "title" => "Hybrid Security Checkpoint",
            "description" => "Dual-lane passenger screening checkpoint feeding a terminal transit walkway."
        ),
        Dict{String, Any}(
            "id" => "opt_p1_er_allocation",
            "category" => "optimization",
            "title" => "1. ER Server Allocation (Parameter)",
            "description" => "Allocate 10 medical staff across Triage, Fast-Track, Acute Care, and Trauma to minimize patient sojourn time W."
        ),
        Dict{String, Any}(
            "id" => "opt_p2_vip_dispatch",
            "category" => "optimization",
            "title" => "2. VIP Support Dispatcher (Policy)",
            "description" => "Optimize queue discipline (FIFO vs Priority HOL) and Tier-1/Specialist staffing under a strict VIP wait-time SLA."
        ),
        Dict{String, Any}(
            "id" => "opt_p3_conveyor_topology",
            "category" => "optimization",
            "title" => "3. Sorting Hub Conveyor (Topology)",
            "description" => "Evolve a congested linear spine conveyor into a high-throughput recirculation network via grammar mutations."
        )
    ]
end

function _ex_port(id::String, name::String, direction::String; kind::String="flow", cardinality::String="many", required::Bool=false)
    return Dict{String, Any}(
        "id" => id,
        "name" => name,
        "direction" => direction,
        "kind" => kind,
        "data_type" => "entity",
        "cardinality" => cardinality,
        "required" => required
    )
end

function _ex_elem(
    id::String,
    name::String,
    kind::String,
    pos::Tuple{Float64, Float64, Float64},
    dims::Tuple{Float64, Float64, Float64},
    props::Dict{String, Any};
    color::String = "#3498db"
)::Dict{String, Any}
    in_ports = Dict{String, Any}[]
    out_ports = Dict{String, Any}[]
    if kind in ("queue", "server", "conveyor", "sink", "hybrid_gate")
        push!(in_ports, _ex_port("flow_in", "Flow In", "input"; cardinality="many"))
    end
    if kind in ("source", "queue", "server", "conveyor", "crowd_spawner", "hybrid_gate")
        push!(out_ports, _ex_port("flow_out", "Flow Out", "output"; cardinality="many"))
    end
    return Dict{String, Any}(
        "id" => id,
        "name" => name,
        "kind" => kind,
        "library" => "SimElements/DES",
        "library_version" => "1.0.0",
        "level_id" => "level_0",
        "transform" => Dict{String, Any}(
            "position" => [pos[1], pos[2], pos[3]],
            "rotation" => [0.0, 0.0, 0.0],
            "scale" => [1.0, 1.0, 1.0]
        ),
        "geometry" => Dict{String, Any}(
            "shape" => "box",
            "dimensions" => [dims[1], dims[2], dims[3]]
        ),
        "editor" => Dict{String, Any}(
            "graph_position" => [pos[1] * 20.0, pos[2] * 20.0],
            "collapsed" => false,
            "color" => color,
            "notes" => ""
        ),
        "properties" => props,
        "input_ports" => in_ports,
        "output_ports" => out_ports,
        "metric_ports" => Dict{String, Any}[]
    )
end

function _ex_conn(id::String, src::String, dst::String; ordering::Int=1)::Dict{String, Any}
    return Dict{String, Any}(
        "id" => id,
        "source_element" => src,
        "source_port" => "flow_out",
        "target_element" => dst,
        "target_port" => "flow_in",
        "link_type" => "flow",
        "enabled" => true,
        "ordering" => ordering
    )
end

function _ex_base_doc(
    id::String,
    name::String,
    description::String,
    elements::Vector{Dict{String, Any}},
    connections::Vector{Dict{String, Any}};
    mode::String = "des_only",
    abm_enabled::Bool = false,
    product::Dict{String, Any} = Dict{String, Any}(
        "name" => "Entity",
        "mesh_type" => "box",
        "color" => [0.25, 0.75, 0.95],
        "width" => 0.45,
        "height" => 0.45,
        "depth" => 0.45
    ),
    optimization::Union{Dict{String, Any}, Nothing} = nothing
)::Dict{String, Any}
    doc = Dict{String, Any}(
        "spec_version" => "1.0.0",
        "scene" => Dict{String, Any}(
            "id" => id,
            "name" => name,
            "author" => "Antigravity SimViz",
            "description" => description
        ),
        "simulation" => Dict{String, Any}(
            "time_unit" => "seconds",
            "warmup_time" => 0.0,
            "max_duration" => 3600.0,
            "mode" => mode
        ),
        "abm_config" => Dict{String, Any}(
            "enabled" => abm_enabled,
            "model_name" => "SFM",
            "parameters" => Dict{String, Any}(),
            "pedestrian_profiles" => Any[]
        ),
        "spatial" => Dict{String, Any}(
            "levels" => Any[
                Dict{String, Any}(
                    "id" => "level_0",
                    "name" => "Ground Floor",
                    "elevation" => 0.0,
                    "default_height" => 4.5,
                    "visible" => true
                )
            ],
            "bounds" => [-50.0, -50.0, 0.0, 50.0, 50.0, 10.0]
        ),
        "elements" => elements,
        "connections" => connections,
        "subgraphs" => Any[],
        "overlays" => Any[],
        "validation_metadata" => Dict{String, Any}(
            "is_valid" => true,
            "diagnostic_count" => 0,
            "validator_version" => "1.0.0",
            "diagnostics" => Any[]
        ),
        "product" => product
    )
    if optimization !== nothing
        doc["optimization"] = optimization
    end
    return doc
end

"""
    get_example_scenespec(example_id::String) -> Dict{String, Any}

Returns a complete, ready-to-compile SceneSpec dictionary for `example_id`.
Throws `ArgumentError` if `example_id` is not recognized.
"""
function get_example_scenespec(example_id::String)::Dict{String, Any}
    eid = lowercase(strip(example_id))

    if eid == "des_tandem_cell"
        elems = Dict{String, Any}[
            _ex_elem("Source_Raw", "Raw Parts Infeed", "source", (-18.0, 0.0, 0.0), (2.5, 2.0, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 2.8), "priority" => 0); color="#f39c12"),
            _ex_elem("Queue_CNC", "CNC Staging Buffer", "queue", (-13.0, 0.0, 0.0), (3.5, 2.0, 0.8),
                Dict{String, Any}("capacity" => 20, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_CNC", "CNC Machining Center", "server", (-8.0, 0.0, 0.0), (3.0, 2.2, 1.8),
                Dict{String, Any}("servers" => 2, "service_time" => Dict{String, Any}("type" => "triangular", "min" => 3.0, "mode" => 4.5, "max" => 6.5)); color="#e67e22"),
            _ex_elem("Conveyor_Transfer", "Inter-Bay Conveyor", "conveyor", (-2.0, 0.0, 0.0), (6.0, 1.2, 0.8),
                Dict{String, Any}("speed" => 1.5, "length" => 6.0, "capacity" => 8); color="#2ecc71"),
            _ex_elem("Queue_Assembly", "Assembly Buffer", "queue", (6.0, 0.0, 0.0), (3.5, 2.0, 0.8),
                Dict{String, Any}("capacity" => 20, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_Assembly", "Robotic Assembly", "server", (11.0, 0.0, 0.0), (3.0, 2.2, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 2.2)); color="#e67e22"),
            _ex_elem("Sink_Finished", "Finished Goods Dock", "sink", (16.5, 0.0, 0.0), (2.5, 2.0, 1.2),
                Dict{String, Any}("record_sojourn" => true); color="#e74c3c")
        ]
        conns = Dict{String, Any}[
            _ex_conn("c1", "Source_Raw", "Queue_CNC"),
            _ex_conn("c2", "Queue_CNC", "Server_CNC"),
            _ex_conn("c3", "Server_CNC", "Conveyor_Transfer"),
            _ex_conn("c4", "Conveyor_Transfer", "Queue_Assembly"),
            _ex_conn("c5", "Queue_Assembly", "Server_Assembly"),
            _ex_conn("c6", "Server_Assembly", "Sink_Finished")
        ]
        return _ex_base_doc("des_tandem_cell", "Tandem Manufacturing Cell",
            "Two-stage CNC machining and robotic assembly line connected by a transfer conveyor.", elems, conns)

    elseif eid == "des_mmc_failures"
        elems = Dict{String, Any}[
            _ex_elem("Source_Jobs", "Work Order Arrivals", "source", (-12.0, 0.0, 0.0), (2.5, 2.0, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 1.5), "priority" => 0); color="#f39c12"),
            _ex_elem("Queue_Staging", "Main Job Buffer", "queue", (-6.0, 0.0, 0.0), (4.5, 2.2, 0.8),
                Dict{String, Any}("capacity" => 40, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_Cluster", "Parallel Processing Bank (c=3)", "server", (1.0, 0.0, 0.0), (3.5, 2.8, 1.8),
                Dict{String, Any}(
                    "servers" => 3,
                    "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 3.8),
                    "failure_model" => "mtbf_mttr",
                    "mtbf" => 45.0,
                    "mttr" => 8.0
                ); color="#e67e22"),
            _ex_elem("Sink_Completed", "Completed Orders", "sink", (8.0, 0.0, 0.0), (2.5, 2.0, 1.2),
                Dict{String, Any}("record_sojourn" => true); color="#e74c3c")
        ]
        conns = Dict{String, Any}[
            _ex_conn("c1", "Source_Jobs", "Queue_Staging"),
            _ex_conn("c2", "Queue_Staging", "Server_Cluster"),
            _ex_conn("c3", "Server_Cluster", "Sink_Completed")
        ]
        return _ex_base_doc("des_mmc_failures", "M/M/c Station with Failures",
            "Parallel 3-server cluster subject to stochastic breakdown and repair cycles.", elems, conns)

    elseif eid == "abm_corridor_crowd"
        elems = Dict{String, Any}[
            _ex_elem("Crowd_West", "West Concourse Spawner", "crowd_spawner", (-14.0, -4.0, 0.0), (2.5, 2.5, 1.0),
                Dict{String, Any}("spawn_rate" => 1.2, "goal_x" => 14.0, "goal_y" => -4.0); color="#9b59b6"),
            _ex_elem("Source_Visitors", "Visitor Entry", "source", (-14.0, 2.0, 0.0), (2.5, 2.0, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 2.0), "priority" => 0); color="#f39c12"),
            _ex_elem("Queue_Lobby", "Lobby Queue", "queue", (-7.0, 2.0, 0.0), (4.0, 2.0, 0.8),
                Dict{String, Any}("capacity" => 25, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_Desk", "Reception Desk", "server", (-1.0, 2.0, 0.0), (3.0, 2.2, 1.8),
                Dict{String, Any}("servers" => 2, "service_time" => Dict{String, Any}("type" => "triangular", "min" => 2.0, "mode" => 3.5, "max" => 5.0)); color="#e67e22"),
            _ex_elem("Conveyor_Walkway", "Moving Walkway", "conveyor", (4.5, 2.0, 0.0), (6.0, 1.4, 0.5),
                Dict{String, Any}("speed" => 1.8, "length" => 6.0, "capacity" => 12); color="#2ecc71"),
            _ex_elem("Sink_Concourse", "East Concourse Exit", "sink", (13.0, 2.0, 0.0), (2.5, 2.0, 1.2),
                Dict{String, Any}("record_sojourn" => true); color="#e74c3c")
        ]
        conns = Dict{String, Any}[
            _ex_conn("c1", "Source_Visitors", "Queue_Lobby"),
            _ex_conn("c2", "Queue_Lobby", "Server_Desk"),
            _ex_conn("c3", "Server_Desk", "Conveyor_Walkway"),
            _ex_conn("c4", "Conveyor_Walkway", "Sink_Concourse")
        ]
        return _ex_base_doc("abm_corridor_crowd", "Pedestrian Corridor Flow",
            "Combined pedestrian concourse flow and visitor reception checkpoint.", elems, conns;
            mode="hybrid", abm_enabled=true)

    elseif eid == "hybrid_security_gate"
        elems = Dict{String, Any}[
            _ex_elem("Source_Pax", "Passenger Arrival", "source", (-15.0, 0.0, 0.0), (2.5, 2.0, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 1.6), "priority" => 0); color="#f39c12"),
            _ex_elem("Queue_PreCheck", "Document Check Queue", "queue", (-10.0, 0.0, 0.0), (3.5, 2.0, 0.8),
                Dict{String, Any}("capacity" => 30, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_DocCheck", "Boarding Pass Desk", "server", (-5.0, 0.0, 0.0), (2.8, 2.0, 1.8),
                Dict{String, Any}("servers" => 2, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 2.4), "routing_rule" => "shortest_queue"); color="#e67e22"),
            _ex_elem("Queue_LaneA", "X-Ray Lane A Buffer", "queue", (1.5, -3.5, 0.0), (3.5, 1.8, 0.8),
                Dict{String, Any}("capacity" => 15, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_ScannerA", "X-Ray Scanner A", "server", (6.5, -3.5, 0.0), (3.0, 1.8, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "triangular", "min" => 2.0, "mode" => 3.0, "max" => 5.0)); color="#e67e22"),
            _ex_elem("Queue_LaneB", "X-Ray Lane B Buffer", "queue", (1.5, 3.5, 0.0), (3.5, 1.8, 0.8),
                Dict{String, Any}("capacity" => 15, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_ScannerB", "X-Ray Scanner B", "server", (6.5, 3.5, 0.0), (3.0, 1.8, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "triangular", "min" => 2.0, "mode" => 3.0, "max" => 5.0)); color="#e67e22"),
            _ex_elem("Sink_Gates", "Departure Gates", "sink", (13.0, 0.0, 0.0), (2.5, 2.2, 1.2),
                Dict{String, Any}("record_sojourn" => true); color="#e74c3c")
        ]
        conns = Dict{String, Any}[
            _ex_conn("c1", "Source_Pax", "Queue_PreCheck"),
            _ex_conn("c2", "Queue_PreCheck", "Server_DocCheck"),
            _ex_conn("c3", "Server_DocCheck", "Queue_LaneA"; ordering=1),
            _ex_conn("c4", "Server_DocCheck", "Queue_LaneB"; ordering=2),
            _ex_conn("c5", "Queue_LaneA", "Server_ScannerA"),
            _ex_conn("c6", "Queue_LaneB", "Server_ScannerB"),
            _ex_conn("c7", "Server_ScannerA", "Sink_Gates"),
            _ex_conn("c8", "Server_ScannerB", "Sink_Gates")
        ]
        return _ex_base_doc("hybrid_security_gate", "Hybrid Security Checkpoint",
            "Dual-lane passenger screening checkpoint with shortest-queue lane balancing.", elems, conns)

    elseif eid == "opt_p1_er_allocation"
        # Problem 1: ER Server Allocation (Parameter Optimization)
        # Starts with an intentionally imbalanced allocation (c1=1, c2=1, c3=1, c4=7 -> sum=10)
        # where Triage and Fast-Track are heavily congested while Trauma is over-staffed.
        elems = Dict{String, Any}[
            _ex_elem("Source_Patients", "ER Walk-In & Ambulance", "source", (-18.0, 0.0, 0.0), (2.8, 2.2, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 2.0), "priority" => 0); color="#f39c12"),
            _ex_elem("Queue_Triage", "Triage Waiting Room", "queue", (-12.5, 0.0, 0.0), (3.8, 2.2, 0.8),
                Dict{String, Any}("capacity" => 50, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_Triage", "Triage Nurses (c1)", "server", (-7.0, 0.0, 0.0), (3.0, 2.2, 1.8),
                Dict{String, Any}(
                    "servers" => 1,
                    "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 3.2),
                    "routing_rule" => "prob",
                    "routing_weights" => Dict{String, Any}(
                        "Queue_FastTrack" => 0.50,
                        "Queue_Acute" => 0.35,
                        "Queue_Trauma" => 0.15
                    )
                ); color="#e67e22"),
            # Wing 1: Fast-Track (50% of patients)
            _ex_elem("Queue_FastTrack", "Fast-Track Waiting", "queue", (0.0, -6.0, 0.0), (3.8, 1.8, 0.8),
                Dict{String, Any}("capacity" => 40, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_FastTrack", "Fast-Track PA/NP (c2)", "server", (5.5, -6.0, 0.0), (3.0, 1.8, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 4.2)); color="#e67e22"),
            # Wing 2: Acute Care (35% of patients)
            _ex_elem("Queue_Acute", "Acute Care Bays", "queue", (0.0, 0.0, 0.0), (3.8, 1.8, 0.8),
                Dict{String, Any}("capacity" => 40, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_Acute", "Acute Physicians (c3)", "server", (5.5, 0.0, 0.0), (3.0, 1.8, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 6.0)); color="#e67e22"),
            # Wing 3: Trauma (15% of patients)
            _ex_elem("Queue_Trauma", "Trauma Resus Queue", "queue", (0.0, 6.0, 0.0), (3.8, 1.8, 0.8),
                Dict{String, Any}("capacity" => 40, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_Trauma", "Trauma Team (c4)", "server", (5.5, 6.0, 0.0), (3.0, 1.8, 1.8),
                Dict{String, Any}("servers" => 7, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 8.0)); color="#e67e22"),
            # Discharge Sink
            _ex_elem("Sink_Discharge", "ER Discharge / Admit", "sink", (13.0, 0.0, 0.0), (2.8, 2.4, 1.2),
                Dict{String, Any}("record_sojourn" => true); color="#e74c3c")
        ]
        conns = Dict{String, Any}[
            _ex_conn("c1", "Source_Patients", "Queue_Triage"),
            _ex_conn("c2", "Queue_Triage", "Server_Triage"),
            _ex_conn("c3", "Server_Triage", "Queue_FastTrack"; ordering=1),
            _ex_conn("c4", "Server_Triage", "Queue_Acute"; ordering=2),
            _ex_conn("c5", "Server_Triage", "Queue_Trauma"; ordering=3),
            _ex_conn("c6", "Queue_FastTrack", "Server_FastTrack"),
            _ex_conn("c7", "Queue_Acute", "Server_Acute"),
            _ex_conn("c8", "Queue_Trauma", "Server_Trauma"),
            _ex_conn("c9", "Server_FastTrack", "Sink_Discharge"),
            _ex_conn("c10", "Server_Acute", "Sink_Discharge"),
            _ex_conn("c11", "Server_Trauma", "Sink_Discharge")
        ]
        opt_spec = Dict{String, Any}(
            "problem_id" => "opt_p1_er_allocation",
            "problem_class" => "parameter",
            "title" => "ER Server Allocation (Discrete Resource Budgeting)",
            "decision_variables" => Any[
                Dict{String, Any}("id" => "c1", "element_id" => "Server_Triage", "property" => "servers", "type" => "int", "lower" => 1, "upper" => 6, "initial" => 1, "label" => "Triage Nurses (c1)"),
                Dict{String, Any}("id" => "c2", "element_id" => "Server_FastTrack", "property" => "servers", "type" => "int", "lower" => 1, "upper" => 6, "initial" => 1, "label" => "Fast-Track Staff (c2)"),
                Dict{String, Any}("id" => "c3", "element_id" => "Server_Acute", "property" => "servers", "type" => "int", "lower" => 1, "upper" => 6, "initial" => 1, "label" => "Acute Physicians (c3)"),
                Dict{String, Any}("id" => "c4", "element_id" => "Server_Trauma", "property" => "servers", "type" => "int", "lower" => 1, "upper" => 6, "initial" => 7, "label" => "Trauma Team (c4)")
            ],
            "constraints" => Any[
                Dict{String, Any}(
                    "id" => "staff_budget",
                    "kind" => "linear_sum",
                    "variables" => Any["c1", "c2", "c3", "c4"],
                    "relation" => "<=",
                    "rhs" => 10.0,
                    "penalty_weight" => 50.0,
                    "description" => "Total ER shift headcount c1 + c2 + c3 + c4 <= 10"
                )
            ],
            "objective" => Dict{String, Any}(
                "sense" => "minimize",
                "metric" => "system_sojourn_mean",
                "description" => "Minimize mean end-to-end patient sojourn time E[W] (seconds)"
            ),
            "solver" => Dict{String, Any}(
                "algorithm" => "eca",
                "max_evaluations" => 40,
                "population_size" => 10,
                "replications_per_eval" => 4,
                "sim_horizon" => 500.0,
                "warmup_time" => 80.0,
                "use_crn" => true,
                "top_k" => 5
            )
        )
        return _ex_base_doc("opt_p1_er_allocation", "1. ER Server Allocation",
            "Allocate 10 clinical staff across Triage, Fast-Track, Acute Care, and Trauma to minimize patient sojourn time.",
            elems, conns; optimization=opt_spec)

    elseif eid == "opt_p2_vip_dispatch"
        # Problem 2: VIP vs Standard Support Dispatcher (Policy & Priority Optimization)
        # Two sources (VIP priority=1, Standard priority=0) feed a unified dispatch queue and specialist pool.
        # Baseline uses FIFO discipline with under-provisioned specialists, violating VIP wait SLA.
        elems = Dict{String, Any}[
            _ex_elem("Source_VIP", "VIP Enterprise Callers (P1)", "source", (-16.0, -3.5, 0.0), (2.8, 2.0, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 4.5), "priority" => 1); color="#f1c40f"),
            _ex_elem("Source_Standard", "Standard Callers (P0)", "source", (-16.0, 3.5, 0.0), (2.8, 2.0, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 1.8), "priority" => 0); color="#f39c12"),
            _ex_elem("Queue_Dispatch", "Central Dispatch Queue", "queue", (-8.5, 0.0, 0.0), (4.2, 2.4, 0.8),
                Dict{String, Any}("capacity" => 60, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_Router", "Automated Triage Router", "server", (-2.5, 0.0, 0.0), (3.0, 2.2, 1.8),
                Dict{String, Any}(
                    "servers" => 2,
                    "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 1.2),
                    "routing_rule" => "prob"
                ); color="#e67e22"),
            _ex_elem("Queue_PoolA", "Support Pool A Queue", "queue", (4.0, -3.5, 0.0), (3.8, 2.0, 0.8),
                Dict{String, Any}("capacity" => 40, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_PoolA", "Support Engineers A", "server", (9.5, -3.5, 0.0), (3.0, 2.0, 1.8),
                Dict{String, Any}("servers" => 2, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 4.2)); color="#e67e22"),
            _ex_elem("Queue_PoolB", "Support Pool B Queue", "queue", (4.0, 3.5, 0.0), (3.8, 2.0, 0.8),
                Dict{String, Any}("capacity" => 40, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_PoolB", "Support Engineers B", "server", (9.5, 3.5, 0.0), (3.0, 2.0, 1.8),
                Dict{String, Any}("servers" => 2, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 4.2)); color="#e67e22"),
            _ex_elem("Sink_Resolved", "Tickets Resolved", "sink", (16.0, 0.0, 0.0), (2.8, 2.2, 1.2),
                Dict{String, Any}("record_sojourn" => true); color="#e74c3c")
        ]
        conns = Dict{String, Any}[
            _ex_conn("c1", "Source_VIP", "Queue_Dispatch"; ordering=1),
            _ex_conn("c2", "Source_Standard", "Queue_Dispatch"; ordering=2),
            _ex_conn("c3", "Queue_Dispatch", "Server_Router"),
            _ex_conn("c4", "Server_Router", "Queue_PoolA"; ordering=1),
            _ex_conn("c5", "Server_Router", "Queue_PoolB"; ordering=2),
            _ex_conn("c6", "Queue_PoolA", "Server_PoolA"),
            _ex_conn("c7", "Queue_PoolB", "Server_PoolB"),
            _ex_conn("c8", "Server_PoolA", "Sink_Resolved"),
            _ex_conn("c9", "Server_PoolB", "Sink_Resolved")
        ]
        opt_spec = Dict{String, Any}(
            "problem_id" => "opt_p2_vip_dispatch",
            "problem_class" => "policy",
            "title" => "VIP Support Dispatcher (Queue Discipline & Routing Policy)",
            "decision_variables" => Any[
                Dict{String, Any}("id" => "disc_main", "element_id" => "Queue_Dispatch", "property" => "discipline", "type" => "categorical", "categories" => Any["fifo", "priority"], "initial" => "fifo", "label" => "Dispatch Queue Discipline"),
                Dict{String, Any}("id" => "route_pol", "element_id" => "Server_Router", "property" => "routing_rule", "type" => "categorical", "categories" => Any["prob", "round_robin", "shortest_queue"], "initial" => "prob", "label" => "Pool Routing Policy"),
                Dict{String, Any}("id" => "disc_a", "element_id" => "Queue_PoolA", "property" => "discipline", "type" => "categorical", "categories" => Any["fifo", "priority"], "initial" => "fifo", "label" => "Pool A Discipline"),
                Dict{String, Any}("id" => "disc_b", "element_id" => "Queue_PoolB", "property" => "discipline", "type" => "categorical", "categories" => Any["fifo", "priority"], "initial" => "fifo", "label" => "Pool B Discipline"),
                Dict{String, Any}("id" => "srv_a", "element_id" => "Server_PoolA", "property" => "servers", "type" => "int", "lower" => 1, "upper" => 5, "initial" => 2, "label" => "Pool A Engineers"),
                Dict{String, Any}("id" => "srv_b", "element_id" => "Server_PoolB", "property" => "servers", "type" => "int", "lower" => 1, "upper" => 5, "initial" => 2, "label" => "Pool B Engineers")
            ],
            "constraints" => Any[
                Dict{String, Any}(
                    "id" => "vip_sla",
                    "kind" => "metric_bound",
                    "metric" => "vip_wait_mean",
                    "relation" => "<=",
                    "rhs" => 1.5,
                    "penalty_weight" => 60.0,
                    "description" => "VIP mean queue wait W_q(VIP) <= 1.5s SLA"
                ),
                Dict{String, Any}(
                    "id" => "pool_budget",
                    "kind" => "linear_sum",
                    "variables" => Any["srv_a", "srv_b"],
                    "relation" => "<=",
                    "rhs" => 6.0,
                    "penalty_weight" => 40.0,
                    "description" => "Total support engineers srv_a + srv_b <= 6"
                )
            ],
            "objective" => Dict{String, Any}(
                "sense" => "minimize",
                "metric" => "weighted_vip_std_cost",
                "description" => "Minimize 5*W_q(VIP) + 1*W_q(Std) + 0.8*(srv_a + srv_b)"
            ),
            "solver" => Dict{String, Any}(
                "algorithm" => "mixed_ga",
                "max_evaluations" => 36,
                "population_size" => 9,
                "replications_per_eval" => 4,
                "sim_horizon" => 500.0,
                "warmup_time" => 80.0,
                "use_crn" => true,
                "top_k" => 5
            )
        )
        return _ex_base_doc("opt_p2_vip_dispatch", "2. VIP Support Dispatcher",
            "Optimize queue discipline (FIFO vs Priority HOL), pool routing rule, and engineer staffing under a VIP SLA.",
            elems, conns; optimization=opt_spec)

    elseif eid == "opt_p3_conveyor_topology"
        # Problem 3: Sorting Hub Conveyor (Grammar-Based Topology & Flow Optimization)
        # Starts as a congested Linear Spine where parcels travel sequentially through
        # Conveyor_North -> Conveyor_Center -> Conveyor_South before reaching sorting stations.
        # Grammar mutations can add recirculation loop/bypass conveyors and re-route flow.
        elems = Dict{String, Any}[
            _ex_elem("Source_Inbound", "Inbound Parcel Unloader", "source", (-18.0, -4.0, 0.0), (2.8, 2.0, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 1.1), "priority" => 0); color="#f39c12"),
            _ex_elem("Queue_Infeed", "Induction Staging", "queue", (-12.5, -4.0, 0.0), (3.5, 2.0, 0.8),
                Dict{String, Any}("capacity" => 12, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Conveyor_West", "West Induction Belt", "conveyor", (-7.0, -4.0, 0.0), (5.5, 1.2, 0.8),
                Dict{String, Any}("speed" => 1.2, "length" => 5.5, "capacity" => 6, "routing_rule" => "prob"); color="#2ecc71"),
            _ex_elem("Conveyor_North", "North Spine Belt", "conveyor", (0.5, -4.0, 0.0), (6.0, 1.2, 0.8),
                Dict{String, Any}("speed" => 1.2, "length" => 6.0, "capacity" => 6, "routing_rule" => "prob"); color="#2ecc71"),
            _ex_elem("Conveyor_East", "East Transfer Belt", "conveyor", (7.5, 0.0, 0.0), (1.2, 6.0, 0.8),
                Dict{String, Any}("speed" => 1.2, "length" => 6.0, "capacity" => 6, "routing_rule" => "prob"); color="#2ecc71"),
            _ex_elem("Conveyor_South", "South Distribution Belt", "conveyor", (0.5, 4.0, 0.0), (6.0, 1.2, 0.8),
                Dict{String, Any}("speed" => 1.2, "length" => 6.0, "capacity" => 6, "routing_rule" => "prob"); color="#2ecc71"),
            # Parallel sorting chutes
            _ex_elem("Queue_ChuteA", "Chute A Buffer", "queue", (9.5, -4.5, 0.0), (3.2, 1.8, 0.8),
                Dict{String, Any}("capacity" => 10, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_SorterA", "Optical Sorter A", "server", (14.0, -4.5, 0.0), (2.8, 1.8, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 2.8)); color="#e67e22"),
            _ex_elem("Queue_ChuteB", "Chute B Buffer", "queue", (9.5, 0.0, 0.0), (3.2, 1.8, 0.8),
                Dict{String, Any}("capacity" => 10, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_SorterB", "Optical Sorter B", "server", (14.0, 0.0, 0.0), (2.8, 1.8, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 2.8)); color="#e67e22"),
            _ex_elem("Queue_ChuteC", "Chute C Buffer", "queue", (9.5, 4.5, 0.0), (3.2, 1.8, 0.8),
                Dict{String, Any}("capacity" => 10, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_SorterC", "Optical Sorter C", "server", (14.0, 4.5, 0.0), (2.8, 1.8, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 2.8)); color="#e67e22"),
            _ex_elem("Sink_Outbound", "Outbound Shipping Docks", "sink", (19.5, 0.0, 0.0), (2.8, 2.4, 1.2),
                Dict{String, Any}("record_sojourn" => true); color="#e74c3c")
        ]
        # Initial Linear Spine topology: Inbound -> Queue_Infeed -> West -> North -> East -> South -> ChuteC only (or unbalanced)
        conns = Dict{String, Any}[
            _ex_conn("c1", "Source_Inbound", "Queue_Infeed"),
            _ex_conn("c2", "Queue_Infeed", "Conveyor_West"),
            _ex_conn("c3", "Conveyor_West", "Conveyor_North"),
            _ex_conn("c4", "Conveyor_North", "Conveyor_East"),
            _ex_conn("c5", "Conveyor_East", "Conveyor_South"),
            _ex_conn("c6", "Conveyor_North", "Queue_ChuteA"; ordering=1),
            _ex_conn("c7", "Conveyor_East", "Queue_ChuteB"; ordering=1),
            _ex_conn("c8", "Conveyor_South", "Queue_ChuteC"; ordering=1),
            _ex_conn("c9", "Queue_ChuteA", "Server_SorterA"),
            _ex_conn("c10", "Queue_ChuteB", "Server_SorterB"),
            _ex_conn("c11", "Queue_ChuteC", "Server_SorterC"),
            _ex_conn("c12", "Server_SorterA", "Sink_Outbound"),
            _ex_conn("c13", "Server_SorterB", "Sink_Outbound"),
            _ex_conn("c14", "Server_SorterC", "Sink_Outbound")
        ]
        opt_spec = Dict{String, Any}(
            "problem_id" => "opt_p3_conveyor_topology",
            "problem_class" => "topology",
            "title" => "Sorting Hub Conveyor (Grammar-Based Topology Evolution)",
            "decision_variables" => Any[
                Dict{String, Any}("id" => "spd_w", "element_id" => "Conveyor_West", "property" => "speed", "type" => "float", "lower" => 1.0, "upper" => 3.5, "initial" => 1.2, "label" => "West Belt Speed (m/s)"),
                Dict{String, Any}("id" => "spd_n", "element_id" => "Conveyor_North", "property" => "speed", "type" => "float", "lower" => 1.0, "upper" => 3.5, "initial" => 1.2, "label" => "North Belt Speed (m/s)"),
                Dict{String, Any}("id" => "spd_e", "element_id" => "Conveyor_East", "property" => "speed", "type" => "float", "lower" => 1.0, "upper" => 3.5, "initial" => 1.2, "label" => "East Belt Speed (m/s)"),
                Dict{String, Any}("id" => "spd_s", "element_id" => "Conveyor_South", "property" => "speed", "type" => "float", "lower" => 1.0, "upper" => 3.5, "initial" => 1.2, "label" => "South Belt Speed (m/s)"),
                Dict{String, Any}("id" => "route_n", "element_id" => "Conveyor_North", "property" => "routing_rule", "type" => "categorical", "categories" => Any["prob", "shortest_queue", "round_robin"], "initial" => "prob", "label" => "North Diverter Rule"),
                Dict{String, Any}("id" => "route_e", "element_id" => "Conveyor_East", "property" => "routing_rule", "type" => "categorical", "categories" => Any["prob", "shortest_queue", "round_robin"], "initial" => "prob", "label" => "East Diverter Rule"),
                Dict{String, Any}("id" => "topology_loop", "element_id" => "Conveyor_South", "property" => "recirculation_edge", "type" => "grammar_edge", "candidates" => Any["none", "Conveyor_West", "Queue_ChuteA", "Queue_ChuteB"], "initial" => "none", "label" => "Recirculation / Bypass Link")
            ],
            "constraints" => Any[
                Dict{String, Any}(
                    "id" => "max_conveyor_budget",
                    "kind" => "topology_budget",
                    "metric" => "total_conveyor_length",
                    "relation" => "<=",
                    "rhs" => 35.0,
                    "penalty_weight" => 25.0,
                    "description" => "Total conveyor network length <= 35m and DAG/Loop reachability to Sink"
                )
            ],
            "objective" => Dict{String, Any}(
                "sense" => "minimize",
                "metric" => "conveyor_jam_and_sojourn",
                "description" => "Minimize parcel sojourn time E[W] + congestion penalty (maximize sorting throughput)"
            ),
            "solver" => Dict{String, Any}(
                "algorithm" => "grammar_ga",
                "max_evaluations" => 36,
                "population_size" => 9,
                "replications_per_eval" => 3,
                "sim_horizon" => 400.0,
                "warmup_time" => 60.0,
                "use_crn" => true,
                "top_k" => 5
            )
        )
        return _ex_base_doc("opt_p3_conveyor_topology", "3. Sorting Hub Conveyor",
            "Evolve a congested linear spine conveyor into a closed-loop recirculation sorting hub.",
            elems, conns; optimization=opt_spec)
    else
        throw(ArgumentError("Unknown example_id '$example_id'. Valid IDs: $(join([d["id"] for d in list_examples()], ", "))"))
    end
end
