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
    met_ports = Dict{String, Any}[]
    if kind in ("queue", "server", "conveyor", "sink", "hybrid_gate")
        push!(in_ports, _ex_port("flow_in", "Flow In", "input"; cardinality="many"))
    end
    if kind == "queue"
        push!(in_ports, _ex_port("release_signal", "Release / Gate Signal", "input"; kind="signal", cardinality="one"))
        push!(met_ports, _ex_port("occupancy", "Buffer Occupancy", "output"; kind="metric", cardinality="many"))
        push!(met_ports, _ex_port("length", "Queue Length", "output"; kind="metric", cardinality="many"))
        push!(met_ports, _ex_port("wait_time", "Avg Wait Time", "output"; kind="metric", cardinality="many"))
    elseif kind == "server"
        push!(in_ports, _ex_port("pause_signal", "Pause Signal", "input"; kind="signal", cardinality="one"))
        push!(met_ports, _ex_port("utilization", "Utilization", "output"; kind="metric", cardinality="many"))
        push!(met_ports, _ex_port("busy", "Busy Channels", "output"; kind="metric", cardinality="many"))
        push!(met_ports, _ex_port("throughput", "Throughput", "output"; kind="metric", cardinality="many"))
    elseif kind == "conveyor"
        push!(in_ports, _ex_port("speed_signal", "Speed Signal", "input"; kind="signal", cardinality="one"))
        push!(met_ports, _ex_port("occupancy", "Occupancy", "output"; kind="metric", cardinality="many"))
        push!(met_ports, _ex_port("speed", "Speed", "output"; kind="metric", cardinality="many"))
        push!(met_ports, _ex_port("in_transit", "In-Transit Count", "output"; kind="metric", cardinality="many"))
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
        "metric_ports" => met_ports
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
        # Problem 1: 3-Stage Tandem ER Server Allocation (Parameter Optimization)
        # Starts with imbalanced allocation [3, 1, 1] (sum = 5, E[W_q] = 48.14 min).
        # Optimal balanced allocation [2, 2, 1] / [2, 1, 2] / [1, 2, 2] achieves E[W_q] = 26.29 min.
        elems = Dict{String, Any}[
            _ex_elem("Source_Patients", "ER Walk-In & Ambulance", "source", (-18.0, 0.0, 0.0), (2.8, 2.2, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 7.5), "priority" => 0); color="#f39c12"),
            _ex_elem("Queue_Triage", "Stage 1: Triage Queue", "queue", (-12.5, 0.0, 0.0), (3.6, 2.2, 0.8),
                Dict{String, Any}("capacity" => 60, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_Triage", "Stage 1: Triage Nurses (s1)", "server", (-7.5, 0.0, 0.0), (3.0, 2.2, 1.8),
                Dict{String, Any}("servers" => 3, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 6.0)); color="#e67e22"),
            _ex_elem("Queue_Exam", "Stage 2: Diagnostic Queue", "queue", (-2.0, 0.0, 0.0), (3.6, 2.2, 0.8),
                Dict{String, Any}("capacity" => 60, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_Exam", "Stage 2: Diagnostic / Imaging (s2)", "server", (3.0, 0.0, 0.0), (3.0, 2.2, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 6.0)); color="#e67e22"),
            _ex_elem("Queue_Treat", "Stage 3: Treatment Queue", "queue", (8.5, 0.0, 0.0), (3.6, 2.2, 0.8),
                Dict{String, Any}("capacity" => 60, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_Treat", "Stage 3: ER Physicians (s3)", "server", (13.5, 0.0, 0.0), (3.0, 2.2, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 6.0)); color="#e67e22"),
            _ex_elem("Sink_Discharge", "ER Discharge / Admit", "sink", (19.0, 0.0, 0.0), (2.8, 2.4, 1.2),
                Dict{String, Any}("record_sojourn" => true); color="#e74c3c")
        ]
        conns = Dict{String, Any}[
            _ex_conn("c1", "Source_Patients", "Queue_Triage"),
            _ex_conn("c2", "Queue_Triage", "Server_Triage"),
            _ex_conn("c3", "Server_Triage", "Queue_Exam"),
            _ex_conn("c4", "Queue_Exam", "Server_Exam"),
            _ex_conn("c5", "Server_Exam", "Queue_Treat"),
            _ex_conn("c6", "Queue_Treat", "Server_Treat"),
            _ex_conn("c7", "Server_Treat", "Sink_Discharge")
        ]
        opt_spec = Dict{String, Any}(
            "problem_id" => "opt_p1_er_allocation",
            "problem_class" => "parameter",
            "title" => "ER Server Allocation (3-Stage Tandem Queue)",
            "decision_variables" => Any[
                Dict{String, Any}("id" => "s1", "element_id" => "Server_Triage", "property" => "servers", "type" => "int", "lower" => 1, "upper" => 3, "initial" => 3, "label" => "Stage 1: Triage Staff (s1)"),
                Dict{String, Any}("id" => "s2", "element_id" => "Server_Exam", "property" => "servers", "type" => "int", "lower" => 1, "upper" => 3, "initial" => 1, "label" => "Stage 2: Exam Staff (s2)"),
                Dict{String, Any}("id" => "s3", "element_id" => "Server_Treat", "property" => "servers", "type" => "int", "lower" => 1, "upper" => 3, "initial" => 1, "label" => "Stage 3: Treatment Staff (s3)")
            ],
            "constraints" => Any[
                Dict{String, Any}(
                    "id" => "staff_budget",
                    "kind" => "linear_sum",
                    "variables" => Any["s1", "s2", "s3"],
                    "relation" => "<=",
                    "rhs" => 5.0,
                    "penalty_weight" => 50.0,
                    "description" => "Total ER shift headcount s1 + s2 + s3 <= 5"
                )
            ],
            "objective" => Dict{String, Any}(
                "sense" => "minimize",
                "metric" => "er_wait_mean",
                "secondary_metric" => "total_servers",
                "description" => "Minimize total expected queue waiting time E[W_q] (minutes)"
            ),
            "solver" => Dict{String, Any}(
                "algorithm" => "eca",
                "max_evaluations" => 27,
                "population_size" => 9,
                "replications_per_eval" => 3,
                "sim_horizon" => 500.0,
                "warmup_time" => 80.0,
                "use_crn" => true,
                "top_k" => 5
            )
        )
        return _ex_base_doc("opt_p1_er_allocation", "1. ER Server Allocation",
            "Allocate 5 clinical staff across 3 tandem ER stages (s1 + s2 + s3 <= 5) to reduce queue wait from 48.1 min ([3,1,1]) to 26.3 min ([2,2,1]).",
            elems, conns; optimization=opt_spec)

    elseif eid == "opt_p2_vip_dispatch"
        # Problem 2: VIP vs Standard Support Dispatcher (Policy & State-Dependent Threshold Optimization)
        elems = Dict{String, Any}[
            _ex_elem("Source_VIP", "VIP Enterprise Callers (P1)", "source", (-16.0, -3.5, 0.0), (2.8, 2.0, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 1.25), "priority" => 1); color="#f1c40f"),
            _ex_elem("Source_Standard", "Standard Callers (P0)", "source", (-16.0, 3.5, 0.0), (2.8, 2.0, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 1.0 / 2.4), "priority" => 0); color="#f39c12"),
            _ex_elem("Queue_Dispatch", "Central Dispatch Intake", "queue", (-8.5, 0.0, 0.0), (4.2, 2.4, 0.8),
                Dict{String, Any}("capacity" => 80, "discipline" => "priority"); color="#3498db"),
            _ex_elem("Server_Router", "State-Dependent Triage Router", "server", (-2.5, 0.0, 0.0), (3.0, 2.2, 1.8),
                Dict{String, Any}(
                    "servers" => 4,
                    "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 0.02),
                    "routing_rule" => "dynamic_policy",
                    "vip_queue_threshold" => 3.0,
                    "pool_util_threshold" => 0.85
                ); color="#9b59b6"),
            _ex_elem("Queue_PoolA", "Dedicated VIP Bay Queue (A)", "queue", (4.0, -3.5, 0.0), (3.8, 2.0, 0.8),
                Dict{String, Any}("capacity" => 60, "discipline" => "priority"); color="#3498db"),
            _ex_elem("Server_PoolA", "Dedicated VIP Specialists (srv_a)", "server", (9.5, -3.5, 0.0), (3.0, 2.0, 1.8),
                Dict{String, Any}("servers" => 2, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 1.0)); color="#e67e22"),
            _ex_elem("Queue_PoolB", "Shared Pool Queue (B)", "queue", (4.0, 3.5, 0.0), (3.8, 2.0, 0.8),
                Dict{String, Any}("capacity" => 80, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_PoolB", "Shared Pool Engineers (srv_b)", "server", (9.5, 3.5, 0.0), (3.0, 2.0, 1.8),
                Dict{String, Any}("servers" => 2, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 1.0)); color="#e67e22"),
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
            "title" => "VIP Support Dispatcher (State-Dependent Dynamic Policy)",
            "decision_variables" => Any[
                Dict{String, Any}("id" => "route_pol", "element_id" => "Server_Router", "property" => "routing_rule", "type" => "categorical", "categories" => Any["prob", "shortest_queue", "dynamic_policy"], "initial" => "dynamic_policy", "label" => "Router Dispatch Policy"),
                Dict{String, Any}("id" => "disc_b", "element_id" => "Queue_PoolB", "property" => "discipline", "type" => "categorical", "categories" => Any["fifo", "priority"], "initial" => "fifo", "label" => "Shared Pool B Discipline"),
                Dict{String, Any}("id" => "srv_a", "element_id" => "Server_PoolA", "property" => "servers", "type" => "int", "lower" => 1, "upper" => 3, "initial" => 2, "label" => "Dedicated VIP Staff (srv_a)"),
                Dict{String, Any}("id" => "srv_b", "element_id" => "Server_PoolB", "property" => "servers", "type" => "int", "lower" => 1, "upper" => 3, "initial" => 2, "label" => "Shared Pool Staff (srv_b)"),
                Dict{String, Any}("id" => "vip_q_thresh", "element_id" => "Server_Router", "property" => "vip_queue_threshold", "type" => "policy_param", "lower" => 1.0, "upper" => 4.0, "initial" => 3.0, "label" => "VIP Overflow Queue Threshold (θ_q)"),
                Dict{String, Any}("id" => "pool_util_thresh", "element_id" => "Server_Router", "property" => "pool_util_threshold", "type" => "policy_param", "lower" => 0.5, "upper" => 0.98, "initial" => 0.85, "label" => "Shared Pool Reserve Cap (θ_ρ)")
            ],
            "constraints" => Any[
                Dict{String, Any}(
                    "id" => "vip_sla",
                    "kind" => "metric_bound",
                    "metric" => "vip_wait_mean",
                    "relation" => "<=",
                    "rhs" => 3.0,
                    "penalty_weight" => 80.0,
                    "description" => "VIP SLA: E[W_q(VIP)] <= 3.0 minutes"
                ),
                Dict{String, Any}(
                    "id" => "pool_budget",
                    "kind" => "linear_sum",
                    "variables" => Any["srv_a", "srv_b"],
                    "relation" => "<=",
                    "rhs" => 4.0,
                    "penalty_weight" => 60.0,
                    "description" => "Total support engineers srv_a + srv_b <= 4"
                )
            ],
            "objective" => Dict{String, Any}(
                "sense" => "minimize",
                "metric" => "std_wait_mean",
                "secondary_metric" => "vip_wait_mean",
                "description" => "Minimize Standard customer queue wait E[W_q(Std)] subject to VIP SLA <= 3.0 min"
            ),
            "solver" => Dict{String, Any}(
                "algorithm" => "policy_search",
                "max_evaluations" => 30,
                "population_size" => 10,
                "replications_per_eval" => 3,
                "sim_horizon" => 500.0,
                "warmup_time" => 80.0,
                "use_crn" => true,
                "top_k" => 5
            )
        )
        return _ex_base_doc("opt_p2_vip_dispatch", "2. VIP Support Dispatcher",
            "Synthesize a state-dependent dynamic routing & HOL priority policy across 4 servers to satisfy VIP SLA <= 3.0m while minimizing Standard wait.",
            elems, conns; optimization=opt_spec)

    elseif eid == "opt_p3_conveyor_topology"
        # Problem 3: Sorting Hub Conveyor (Template-Free Bilevel Graph & 3D/2D Spatial Coordinate Search)
        # Starts as a 100m 1D Linear Spine (15m infeed + 3x15m spine + 4x10m accumulation spurs = 100m,
        # E[W] = 73.21s) on Ground Floor z = 0.0. Bilevel search mutates the directed graph and folds
        # 3D coordinates (with constant z = 0.0) into a 60m Closed Loop (15m x 15m square, 0m spurs, E[W] = 48.21s).
        elems = Dict{String, Any}[
            _ex_elem("Source_Inbound", "Inbound Parcel Unloader", "source", (-33.0, 0.0, 0.0), (2.8, 2.0, 1.2),
                Dict{String, Any}("interarrival_time" => Dict{String, Any}("type" => "exponential", "mean" => 7.5), "priority" => 0); color="#f39c12"),
            _ex_elem("Queue_Infeed", "Induction Staging", "queue", (-28.0, 0.0, 0.0), (3.2, 2.0, 0.8),
                Dict{String, Any}("capacity" => 25, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Conveyor_West", "Station 1 Conveyor (West)", "conveyor", (-22.5, 0.0, 0.0), (6.0, 1.2, 0.8),
                Dict{String, Any}("speed" => 1.0, "length" => 25.0, "spur_length" => 10.0, "spur_mode" => "spurs_10m", "layout_mode" => "collinear_1d", "z_constraint" => "constant_z", "capacity" => 10, "routing_rule" => "shortest_queue"); color="#2ecc71"),
            _ex_elem("Conveyor_North", "Station 2 Conveyor (North)", "conveyor", (-7.5, 0.0, 0.0), (6.0, 1.2, 0.8),
                Dict{String, Any}("speed" => 1.0, "length" => 25.0, "spur_length" => 10.0, "spur_mode" => "spurs_10m", "layout_mode" => "collinear_1d", "z_constraint" => "constant_z", "capacity" => 10, "routing_rule" => "shortest_queue"); color="#2ecc71"),
            _ex_elem("Conveyor_East", "Station 3 Conveyor (East)", "conveyor", (7.5, 0.0, 0.0), (6.0, 1.2, 0.8),
                Dict{String, Any}("speed" => 1.0, "length" => 25.0, "spur_length" => 10.0, "spur_mode" => "spurs_10m", "layout_mode" => "collinear_1d", "z_constraint" => "constant_z", "capacity" => 10, "routing_rule" => "shortest_queue"); color="#2ecc71"),
            _ex_elem("Conveyor_South", "Station 4 Conveyor (South)", "conveyor", (22.5, 0.0, 0.0), (6.0, 1.2, 0.8),
                Dict{String, Any}("speed" => 1.0, "length" => 25.0, "spur_length" => 10.0, "spur_mode" => "spurs_10m", "layout_mode" => "collinear_1d", "z_constraint" => "constant_z", "capacity" => 10, "routing_rule" => "shortest_queue"); color="#2ecc71"),
            # 4 Parallel Sorting Stations (each with finite induction buffer capacity = 2, service mean = 20.0s)
            _ex_elem("Queue_ChuteA", "Station 1 Buffer (K=2)", "queue", (-22.5, 5.0, 0.0), (2.8, 1.8, 0.8),
                Dict{String, Any}("capacity" => 2, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_SorterA", "Optical Sorter 1", "server", (-22.5, 9.5, 0.0), (2.8, 1.8, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 20.0)); color="#e67e22"),
            _ex_elem("Queue_ChuteB", "Station 2 Buffer (K=2)", "queue", (-7.5, 5.0, 0.0), (2.8, 1.8, 0.8),
                Dict{String, Any}("capacity" => 2, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_SorterB", "Optical Sorter 2", "server", (-7.5, 9.5, 0.0), (2.8, 1.8, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 20.0)); color="#e67e22"),
            _ex_elem("Queue_ChuteC", "Station 3 Buffer (K=2)", "queue", (7.5, 5.0, 0.0), (2.8, 1.8, 0.8),
                Dict{String, Any}("capacity" => 2, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_SorterC", "Optical Sorter 3", "server", (7.5, 9.5, 0.0), (2.8, 1.8, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 20.0)); color="#e67e22"),
            _ex_elem("Queue_ChuteD", "Station 4 Buffer (K=2)", "queue", (22.5, 5.0, 0.0), (2.8, 1.8, 0.8),
                Dict{String, Any}("capacity" => 2, "discipline" => "fifo"); color="#3498db"),
            _ex_elem("Server_SorterD", "Optical Sorter 4", "server", (22.5, 9.5, 0.0), (2.8, 1.8, 1.8),
                Dict{String, Any}("servers" => 1, "service_time" => Dict{String, Any}("type" => "exponential", "mean" => 20.0)); color="#e67e22"),
            _ex_elem("Sink_Outbound", "Outbound Shipping Docks", "sink", (0.0, 15.0, 0.0), (3.2, 2.4, 1.2),
                Dict{String, Any}("record_sojourn" => true); color="#e74c3c")
        ]
        # Initial 100m Linear Spine: Inbound -> Queue_Infeed -> West -> North -> East -> South
        conns = Dict{String, Any}[
            _ex_conn("c1", "Source_Inbound", "Queue_Infeed"),
            _ex_conn("c2", "Queue_Infeed", "Conveyor_West"),
            _ex_conn("c3", "Conveyor_West", "Conveyor_North"; ordering=1),
            _ex_conn("c4", "Conveyor_North", "Conveyor_East"; ordering=1),
            _ex_conn("c5", "Conveyor_East", "Conveyor_South"; ordering=1),
            _ex_conn("c6", "Conveyor_West", "Queue_ChuteA"; ordering=2),
            _ex_conn("c7", "Conveyor_North", "Queue_ChuteB"; ordering=2),
            _ex_conn("c8", "Conveyor_East", "Queue_ChuteC"; ordering=2),
            _ex_conn("c9", "Conveyor_South", "Queue_ChuteD"; ordering=1),
            _ex_conn("c10", "Queue_ChuteA", "Server_SorterA"),
            _ex_conn("c11", "Queue_ChuteB", "Server_SorterB"),
            _ex_conn("c12", "Queue_ChuteC", "Server_SorterC"),
            _ex_conn("c13", "Queue_ChuteD", "Server_SorterD"),
            _ex_conn("c14", "Server_SorterA", "Sink_Outbound"),
            _ex_conn("c15", "Server_SorterB", "Sink_Outbound"),
            _ex_conn("c16", "Server_SorterC", "Sink_Outbound"),
            _ex_conn("c17", "Server_SorterD", "Sink_Outbound")
        ]
        opt_spec = Dict{String, Any}(
            "problem_id" => "opt_p3_conveyor_topology",
            "problem_class" => "topology",
            "title" => "Sorting Hub Conveyor (Template-Free Bilevel Graph & 3D/2D Spatial Search)",
            "decision_variables" => Any[
                Dict{String, Any}("id" => "edge_w", "element_id" => "Conveyor_West", "property" => "out_edge", "type" => "grammar_edge", "candidates" => Any["none", "Conveyor_North", "Conveyor_East", "Conveyor_South"], "initial" => "Conveyor_North", "label" => "Station 1 Outgoing Belt"),
                Dict{String, Any}("id" => "edge_n", "element_id" => "Conveyor_North", "property" => "out_edge", "type" => "grammar_edge", "candidates" => Any["none", "Conveyor_West", "Conveyor_East", "Conveyor_South"], "initial" => "Conveyor_East", "label" => "Station 2 Outgoing Belt"),
                Dict{String, Any}("id" => "edge_e", "element_id" => "Conveyor_East", "property" => "out_edge", "type" => "grammar_edge", "candidates" => Any["none", "Conveyor_West", "Conveyor_North", "Conveyor_South"], "initial" => "Conveyor_South", "label" => "Station 3 Outgoing Belt"),
                Dict{String, Any}("id" => "edge_s", "element_id" => "Conveyor_South", "property" => "out_edge", "type" => "grammar_edge", "candidates" => Any["none", "Conveyor_West", "Conveyor_North", "Conveyor_East"], "initial" => "none", "label" => "Station 4 Outgoing Belt (Loop Closure)"),
                Dict{String, Any}("id" => "spur_mode", "element_id" => "Conveyor_West", "property" => "spur_mode", "type" => "categorical", "categories" => Any["spurs_10m", "direct_ring"], "initial" => "spurs_10m", "label" => "Station Induction Spur Mode"),
                Dict{String, Any}("id" => "layout_mode", "element_id" => "Conveyor_West", "property" => "layout_mode", "type" => "categorical", "categories" => Any["collinear_1d", "folded_2d"], "initial" => "collinear_1d", "label" => "Spatial Coordinate Folding"),
                Dict{String, Any}("id" => "route_rule", "element_id" => "Conveyor_West", "property" => "routing_rule", "type" => "categorical", "categories" => Any["shortest_queue", "prob", "round_robin"], "initial" => "shortest_queue", "label" => "Diverter Routing Policy")
            ],
            "constraints" => Any[
                Dict{String, Any}(
                    "id" => "max_conveyor_budget",
                    "kind" => "topology_budget",
                    "metric" => "total_conveyor_length",
                    "relation" => "<=",
                    "rhs" => 65.0,
                    "penalty_weight" => 40.0,
                    "description" => "Total 3D Euclidean belt length L_total <= 65.0m"
                ),
                Dict{String, Any}(
                    "id" => "station_separation",
                    "kind" => "metric_bound",
                    "metric" => "min_station_separation",
                    "relation" => ">=",
                    "rhs" => 15.0,
                    "penalty_weight" => 100.0,
                    "description" => "Minimum pairwise 3D station distance ||p_i - p_j||_2 >= 15.0m"
                ),
                Dict{String, Any}(
                    "id" => "constant_z_elevation",
                    "kind" => "metric_bound",
                    "metric" => "z_elevation_deviation",
                    "relation" => "<=",
                    "rhs" => 0.0,
                    "penalty_weight" => 200.0,
                    "description" => "Constant floor elevation z_i == z_0 across all conveyors"
                ),
                Dict{String, Any}(
                    "id" => "port_degree_bound",
                    "kind" => "metric_bound",
                    "metric" => "max_port_degree",
                    "relation" => "<=",
                    "rhs" => 2.0,
                    "penalty_weight" => 100.0,
                    "description" => "Binary mechanical diverter/merge port limit (in-deg <= 2, out-deg <= 2)"
                ),
                Dict{String, Any}(
                    "id" => "induction_overflow_safety",
                    "kind" => "metric_bound",
                    "metric" => "deadlock_free_spurs",
                    "relation" => ">=",
                    "rhs" => 1.0,
                    "penalty_weight" => 150.0,
                    "description" => "Open acyclic topologies require 10m accumulation spurs; closed loops allow 0m direct ring"
                )
            ],
            "objective" => Dict{String, Any}(
                "sense" => "minimize",
                "metric" => "system_sojourn_mean",
                "secondary_metric" => "total_conveyor_length",
                "description" => "Minimize expected parcel sojourn time E[W] = E[T_belt] + E[W_q] + E[S] (seconds)"
            ),
            "solver" => Dict{String, Any}(
                "algorithm" => "bilevel_graph_sa",
                "max_evaluations" => 30,
                "population_size" => 8,
                "replications_per_eval" => 2,
                "sim_horizon" => 300.0,
                "warmup_time" => 40.0,
                "use_crn" => true,
                "top_k" => 5
            )
        )
        return _ex_base_doc("opt_p3_conveyor_topology", "3. Sorting Hub Conveyor",
            "Discover a 60m 2D Closed-Loop recirculation ring (E[W]=48.2s) from a 100m 1D Linear Spine (E[W]=73.2s) via template-free bilevel graph mutation and 3D/2D coordinate folding.",
            elems, conns; optimization=opt_spec)
    else
        throw(ArgumentError("Unknown example_id '$example_id'. Valid IDs: $(join([d["id"] for d in list_examples()], ", "))"))
    end
end
