# authoring_examples_catalog.gd
# Built-in Examples Catalog for Antigravity SimViz (DES, ABM/Hybrid, and SimOptim).
extends RefCounted

static func list_examples() -> Array:
	return [
		{"id": "des_tandem_cell", "category": "des", "title": "Tandem Manufacturing Cell"},
		{"id": "des_mmc_failures", "category": "des", "title": "M/M/c Station with Failures"},
		{"id": "abm_corridor_crowd", "category": "abm", "title": "Pedestrian Corridor Flow"},
		{"id": "hybrid_security_gate", "category": "abm", "title": "Hybrid Security Checkpoint"},
		{"id": "opt_p1_er_allocation", "category": "optimization", "title": "1. ER Server Allocation (Parameter)"},
		{"id": "opt_p2_vip_dispatch", "category": "optimization", "title": "2. VIP Support Dispatcher (Policy)"},
		{"id": "opt_p3_conveyor_topology", "category": "optimization", "title": "3. Sorting Hub Conveyor (Topology)"}
	]

static func _port(id_str: String, name_str: String, dir_str: String, kind_str: String = "flow", card_str: String = "many") -> Dictionary:
	return {
		"id": id_str,
		"name": name_str,
		"direction": dir_str,
		"kind": kind_str,
		"data_type": "entity",
		"cardinality": card_str,
		"required": false
	}

static func _elem(id_str: String, name_str: String, kind_str: String, pos: Array, dims: Array, props: Dictionary, color_hex: String = "#3498db") -> Dictionary:
	var in_ports: Array = []
	var out_ports: Array = []
	if kind_str in ["queue", "server", "conveyor", "sink", "hybrid_gate"]:
		in_ports.append(_port("flow_in", "Flow In", "input", "flow", "many"))
	if kind_str in ["source", "queue", "server", "conveyor", "crowd_spawner", "hybrid_gate"]:
		out_ports.append(_port("flow_out", "Flow Out", "output", "flow", "many"))
	return {
		"id": id_str,
		"name": name_str,
		"kind": kind_str,
		"library": "SimElements/DES",
		"library_version": "1.0.0",
		"level_id": "level_0",
		"transform": {
			"position": [float(pos[0]), float(pos[1]), float(pos[2])],
			"rotation": [0.0, 0.0, 0.0],
			"scale": [1.0, 1.0, 1.0]
		},
		"geometry": {
			"shape": "box",
			"dimensions": [float(dims[0]), float(dims[1]), float(dims[2])]
		},
		"editor": {
			"graph_position": [float(pos[0]) * 20.0, float(pos[1]) * 20.0],
			"collapsed": false,
			"color": color_hex,
			"notes": ""
		},
		"properties": props,
		"input_ports": in_ports,
		"output_ports": out_ports,
		"metric_ports": []
	}

static func _conn(id_str: String, src: String, dst: String, ord: int = 1) -> Dictionary:
	return {
		"id": id_str,
		"source_element": src,
		"source_port": "flow_out",
		"target_element": dst,
		"target_port": "flow_in",
		"link_type": "flow",
		"enabled": true,
		"ordering": ord
	}

static func _base_doc(id_str: String, name_str: String, desc_str: String, elems: Array, conns: Array, mode_str: String = "des_only", abm_on: bool = false, opt: Variant = null) -> Dictionary:
	var doc := {
		"spec_version": "1.0.0",
		"scene": {
			"id": id_str,
			"name": name_str,
			"author": "Antigravity SimViz",
			"description": desc_str
		},
		"simulation": {
			"time_unit": "seconds",
			"warmup_time": 0.0,
			"max_duration": 3600.0,
			"mode": mode_str
		},
		"abm_config": {
			"enabled": abm_on,
			"model_name": "SFM",
			"parameters": {},
			"pedestrian_profiles": []
		},
		"spatial": {
			"levels": [
				{"id": "level_0", "name": "Ground Floor", "elevation": 0.0, "default_height": 4.5, "visible": true}
			],
			"bounds": [-50.0, -50.0, 0.0, 50.0, 50.0, 10.0]
		},
		"elements": elems,
		"connections": conns,
		"subgraphs": [],
		"overlays": [],
		"validation_metadata": {"is_valid": true, "diagnostic_count": 0, "validator_version": "1.0.0", "diagnostics": []},
		"product": {"name": "Entity", "mesh_type": "box", "color": [0.25, 0.75, 0.95], "width": 0.45, "height": 0.45, "depth": 0.45}
	}
	if opt is Dictionary and not opt.is_empty():
		doc["optimization"] = opt
	return doc

static func get_example_scenespec(example_id: String) -> Dictionary:
	var eid := example_id.strip_edges().to_lower()
	if eid == "des_tandem_cell":
		var elems := [
			_elem("Source_Raw", "Raw Parts Infeed", "source", [-18.0, 0.0, 0.0], [2.5, 2.0, 1.2], {"interarrival_time": {"type": "exponential", "mean": 2.8}, "priority": 0}, "#f39c12"),
			_elem("Queue_CNC", "CNC Staging Buffer", "queue", [-13.0, 0.0, 0.0], [3.5, 2.0, 0.8], {"capacity": 20, "discipline": "fifo"}, "#3498db"),
			_elem("Server_CNC", "CNC Machining Center", "server", [-8.0, 0.0, 0.0], [3.0, 2.2, 1.8], {"servers": 2, "service_time": {"type": "triangular", "min": 3.0, "mode": 4.5, "max": 6.5}}, "#e67e22"),
			_elem("Conveyor_Transfer", "Inter-Bay Conveyor", "conveyor", [-2.0, 0.0, 0.0], [6.0, 1.2, 0.8], {"speed": 1.5, "length": 6.0, "capacity": 8}, "#2ecc71"),
			_elem("Queue_Assembly", "Assembly Buffer", "queue", [6.0, 0.0, 0.0], [3.5, 2.0, 0.8], {"capacity": 20, "discipline": "fifo"}, "#3498db"),
			_elem("Server_Assembly", "Robotic Assembly", "server", [11.0, 0.0, 0.0], [3.0, 2.2, 1.8], {"servers": 1, "service_time": {"type": "exponential", "mean": 2.2}}, "#e67e22"),
			_elem("Sink_Finished", "Finished Goods Dock", "sink", [16.5, 0.0, 0.0], [2.5, 2.0, 1.2], {"record_sojourn": true}, "#e74c3c")
		]
		var conns := [
			_conn("c1", "Source_Raw", "Queue_CNC"),
			_conn("c2", "Queue_CNC", "Server_CNC"),
			_conn("c3", "Server_CNC", "Conveyor_Transfer"),
			_conn("c4", "Conveyor_Transfer", "Queue_Assembly"),
			_conn("c5", "Queue_Assembly", "Server_Assembly"),
			_conn("c6", "Server_Assembly", "Sink_Finished")
		]
		return _base_doc("des_tandem_cell", "Tandem Manufacturing Cell", "Two-stage CNC machining and robotic assembly line connected by a transfer conveyor.", elems, conns)

	elif eid == "des_mmc_failures":
		var elems := [
			_elem("Source_Jobs", "Work Order Arrivals", "source", [-12.0, 0.0, 0.0], [2.5, 2.0, 1.2], {"interarrival_time": {"type": "exponential", "mean": 1.5}, "priority": 0}, "#f39c12"),
			_elem("Queue_Staging", "Main Job Buffer", "queue", [-6.0, 0.0, 0.0], [4.5, 2.2, 0.8], {"capacity": 40, "discipline": "fifo"}, "#3498db"),
			_elem("Server_Cluster", "Parallel Processing Bank (c=3)", "server", [1.0, 0.0, 0.0], [3.5, 2.8, 1.8], {"servers": 3, "service_time": {"type": "exponential", "mean": 3.8}, "failure_model": "mtbf_mttr", "mtbf": 45.0, "mttr": 8.0}, "#e67e22"),
			_elem("Sink_Completed", "Completed Orders", "sink", [8.0, 0.0, 0.0], [2.5, 2.0, 1.2], {"record_sojourn": true}, "#e74c3c")
		]
		var conns := [
			_conn("c1", "Source_Jobs", "Queue_Staging"),
			_conn("c2", "Queue_Staging", "Server_Cluster"),
			_conn("c3", "Server_Cluster", "Sink_Completed")
		]
		return _base_doc("des_mmc_failures", "M/M/c Station with Failures", "Parallel 3-server cluster subject to stochastic breakdown and repair cycles.", elems, conns)

	elif eid == "abm_corridor_crowd":
		var elems := [
			_elem("Crowd_West", "West Concourse Spawner", "crowd_spawner", [-14.0, -4.0, 0.0], [2.5, 2.5, 1.0], {"spawn_rate": 1.2, "goal_x": 14.0, "goal_y": -4.0}, "#9b59b6"),
			_elem("Source_Visitors", "Visitor Entry", "source", [-14.0, 2.0, 0.0], [2.5, 2.0, 1.2], {"interarrival_time": {"type": "exponential", "mean": 2.0}, "priority": 0}, "#f39c12"),
			_elem("Queue_Lobby", "Lobby Queue", "queue", [-7.0, 2.0, 0.0], [4.0, 2.0, 0.8], {"capacity": 25, "discipline": "fifo"}, "#3498db"),
			_elem("Server_Desk", "Reception Desk", "server", [-1.0, 2.0, 0.0], [3.0, 2.2, 1.8], {"servers": 2, "service_time": {"type": "triangular", "min": 2.0, "mode": 3.5, "max": 5.0}}, "#e67e22"),
			_elem("Conveyor_Walkway", "Moving Walkway", "conveyor", [4.5, 2.0, 0.0], [6.0, 1.4, 0.5], {"speed": 1.8, "length": 6.0, "capacity": 12}, "#2ecc71"),
			_elem("Sink_Concourse", "East Concourse Exit", "sink", [13.0, 2.0, 0.0], [2.5, 2.0, 1.2], {"record_sojourn": true}, "#e74c3c")
		]
		var conns := [
			_conn("c1", "Source_Visitors", "Queue_Lobby"),
			_conn("c2", "Queue_Lobby", "Server_Desk"),
			_conn("c3", "Server_Desk", "Conveyor_Walkway"),
			_conn("c4", "Conveyor_Walkway", "Sink_Concourse")
		]
		return _base_doc("abm_corridor_crowd", "Pedestrian Corridor Flow", "Combined pedestrian concourse flow and visitor reception checkpoint.", elems, conns, "hybrid", true)

	elif eid == "hybrid_security_gate":
		var elems := [
			_elem("Source_Pax", "Passenger Arrival", "source", [-15.0, 0.0, 0.0], [2.5, 2.0, 1.2], {"interarrival_time": {"type": "exponential", "mean": 1.6}, "priority": 0}, "#f39c12"),
			_elem("Queue_PreCheck", "Document Check Queue", "queue", [-10.0, 0.0, 0.0], [3.5, 2.0, 0.8], {"capacity": 30, "discipline": "fifo"}, "#3498db"),
			_elem("Server_DocCheck", "Boarding Pass Desk", "server", [-5.0, 0.0, 0.0], [2.8, 2.0, 1.8], {"servers": 2, "service_time": {"type": "exponential", "mean": 2.4}, "routing_rule": "shortest_queue"}, "#e67e22"),
			_elem("Queue_LaneA", "X-Ray Lane A Buffer", "queue", [1.5, -3.5, 0.0], [3.5, 1.8, 0.8], {"capacity": 15, "discipline": "fifo"}, "#3498db"),
			_elem("Server_ScannerA", "X-Ray Scanner A", "server", [6.5, -3.5, 0.0], [3.0, 1.8, 1.8], {"servers": 1, "service_time": {"type": "triangular", "min": 2.0, "mode": 3.0, "max": 5.0}}, "#e67e22"),
			_elem("Queue_LaneB", "X-Ray Lane B Buffer", "queue", [1.5, 3.5, 0.0], [3.5, 1.8, 0.8], {"capacity": 15, "discipline": "fifo"}, "#3498db"),
			_elem("Server_ScannerB", "X-Ray Scanner B", "server", [6.5, 3.5, 0.0], [3.0, 1.8, 1.8], {"servers": 1, "service_time": {"type": "triangular", "min": 2.0, "mode": 3.0, "max": 5.0}}, "#e67e22"),
			_elem("Sink_Gates", "Departure Gates", "sink", [13.0, 0.0, 0.0], [2.5, 2.2, 1.2], {"record_sojourn": true}, "#e74c3c")
		]
		var conns := [
			_conn("c1", "Source_Pax", "Queue_PreCheck"),
			_conn("c2", "Queue_PreCheck", "Server_DocCheck"),
			_conn("c3", "Server_DocCheck", "Queue_LaneA", 1),
			_conn("c4", "Server_DocCheck", "Queue_LaneB", 2),
			_conn("c5", "Queue_LaneA", "Server_ScannerA"),
			_conn("c6", "Queue_LaneB", "Server_ScannerB"),
			_conn("c7", "Server_ScannerA", "Sink_Gates"),
			_conn("c8", "Server_ScannerB", "Sink_Gates")
		]
		return _base_doc("hybrid_security_gate", "Hybrid Security Checkpoint", "Dual-lane passenger screening checkpoint with shortest-queue lane balancing.", elems, conns)

	elif eid == "opt_p1_er_allocation":
		var elems := [
			_elem("Source_Patients", "ER Walk-In & Ambulance", "source", [-18.0, 0.0, 0.0], [2.8, 2.2, 1.2], {"interarrival_time": {"type": "exponential", "mean": 2.0}, "priority": 0}, "#f39c12"),
			_elem("Queue_Triage", "Triage Waiting Room", "queue", [-12.5, 0.0, 0.0], [3.8, 2.2, 0.8], {"capacity": 50, "discipline": "fifo"}, "#3498db"),
			_elem("Server_Triage", "Triage Nurses (c1)", "server", [-7.0, 0.0, 0.0], [3.0, 2.2, 1.8], {"servers": 1, "service_time": {"type": "exponential", "mean": 3.2}, "routing_rule": "prob", "routing_weights": {"Queue_FastTrack": 0.50, "Queue_Acute": 0.35, "Queue_Trauma": 0.15}}, "#e67e22"),
			_elem("Queue_FastTrack", "Fast-Track Waiting", "queue", [0.0, -6.0, 0.0], [3.8, 1.8, 0.8], {"capacity": 40, "discipline": "fifo"}, "#3498db"),
			_elem("Server_FastTrack", "Fast-Track PA/NP (c2)", "server", [5.5, -6.0, 0.0], [3.0, 1.8, 1.8], {"servers": 1, "service_time": {"type": "exponential", "mean": 4.2}}, "#e67e22"),
			_elem("Queue_Acute", "Acute Care Bays", "queue", [0.0, 0.0, 0.0], [3.8, 1.8, 0.8], {"capacity": 40, "discipline": "fifo"}, "#3498db"),
			_elem("Server_Acute", "Acute Physicians (c3)", "server", [5.5, 0.0, 0.0], [3.0, 1.8, 1.8], {"servers": 1, "service_time": {"type": "exponential", "mean": 6.0}}, "#e67e22"),
			_elem("Queue_Trauma", "Trauma Resus Queue", "queue", [0.0, 6.0, 0.0], [3.8, 1.8, 0.8], {"capacity": 40, "discipline": "fifo"}, "#3498db"),
			_elem("Server_Trauma", "Trauma Team (c4)", "server", [5.5, 6.0, 0.0], [3.0, 1.8, 1.8], {"servers": 7, "service_time": {"type": "exponential", "mean": 8.0}}, "#e67e22"),
			_elem("Sink_Discharge", "ER Discharge / Admit", "sink", [13.0, 0.0, 0.0], [2.8, 2.4, 1.2], {"record_sojourn": true}, "#e74c3c")
		]
		var conns := [
			_conn("c1", "Source_Patients", "Queue_Triage"),
			_conn("c2", "Queue_Triage", "Server_Triage"),
			_conn("c3", "Server_Triage", "Queue_FastTrack", 1),
			_conn("c4", "Server_Triage", "Queue_Acute", 2),
			_conn("c5", "Server_Triage", "Queue_Trauma", 3),
			_conn("c6", "Queue_FastTrack", "Server_FastTrack"),
			_conn("c7", "Queue_Acute", "Server_Acute"),
			_conn("c8", "Queue_Trauma", "Server_Trauma"),
			_conn("c9", "Server_FastTrack", "Sink_Discharge"),
			_conn("c10", "Server_Acute", "Sink_Discharge"),
			_conn("c11", "Server_Trauma", "Sink_Discharge")
		]
		var opt := {
			"problem_id": "opt_p1_er_allocation",
			"problem_class": "parameter",
			"title": "ER Server Allocation (Discrete Resource Budgeting)",
			"decision_variables": [
				{"id": "c1", "element_id": "Server_Triage", "property": "servers", "type": "int", "lower": 1, "upper": 6, "initial": 1, "label": "Triage Nurses (c1)"},
				{"id": "c2", "element_id": "Server_FastTrack", "property": "servers", "type": "int", "lower": 1, "upper": 6, "initial": 1, "label": "Fast-Track Staff (c2)"},
				{"id": "c3", "element_id": "Server_Acute", "property": "servers", "type": "int", "lower": 1, "upper": 6, "initial": 1, "label": "Acute Physicians (c3)"},
				{"id": "c4", "element_id": "Server_Trauma", "property": "servers", "type": "int", "lower": 1, "upper": 6, "initial": 7, "label": "Trauma Team (c4)"}
			],
			"constraints": [
				{"id": "staff_budget", "kind": "linear_sum", "variables": ["c1", "c2", "c3", "c4"], "relation": "<=", "rhs": 10.0, "penalty_weight": 50.0, "description": "Total ER shift headcount c1 + c2 + c3 + c4 <= 10"}
			],
			"objective": {"sense": "minimize", "metric": "system_sojourn_mean", "description": "Minimize mean end-to-end patient sojourn time E[W] (seconds)"},
			"solver": {"algorithm": "eca", "max_evaluations": 40, "population_size": 10, "replications_per_eval": 4, "sim_horizon": 500.0, "warmup_time": 80.0, "use_crn": true, "top_k": 5}
		}
		return _base_doc("opt_p1_er_allocation", "1. ER Server Allocation", "Allocate 10 clinical staff across Triage, Fast-Track, Acute Care, and Trauma to minimize patient sojourn time.", elems, conns, "des_only", false, opt)

	elif eid == "opt_p2_vip_dispatch":
		var elems := [
			_elem("Source_VIP", "VIP Enterprise Callers (P1)", "source", [-16.0, -3.5, 0.0], [2.8, 2.0, 1.2], {"interarrival_time": {"type": "exponential", "mean": 4.5}, "priority": 1}, "#f1c40f"),
			_elem("Source_Standard", "Standard Callers (P0)", "source", [-16.0, 3.5, 0.0], [2.8, 2.0, 1.2], {"interarrival_time": {"type": "exponential", "mean": 1.8}, "priority": 0}, "#f39c12"),
			_elem("Queue_Dispatch", "Central Dispatch Queue", "queue", [-8.5, 0.0, 0.0], [4.2, 2.4, 0.8], {"capacity": 60, "discipline": "fifo"}, "#3498db"),
			_elem("Server_Router", "Automated Triage Router", "server", [-2.5, 0.0, 0.0], [3.0, 2.2, 1.8], {"servers": 2, "service_time": {"type": "exponential", "mean": 1.2}, "routing_rule": "prob"}, "#e67e22"),
			_elem("Queue_PoolA", "Support Pool A Queue", "queue", [4.0, -3.5, 0.0], [3.8, 2.0, 0.8], {"capacity": 40, "discipline": "fifo"}, "#3498db"),
			_elem("Server_PoolA", "Support Engineers A", "server", [9.5, -3.5, 0.0], [3.0, 2.0, 1.8], {"servers": 2, "service_time": {"type": "exponential", "mean": 4.2}}, "#e67e22"),
			_elem("Queue_PoolB", "Support Pool B Queue", "queue", [4.0, 3.5, 0.0], [3.8, 2.0, 0.8], {"capacity": 40, "discipline": "fifo"}, "#3498db"),
			_elem("Server_PoolB", "Support Engineers B", "server", [9.5, 3.5, 0.0], [3.0, 2.0, 1.8], {"servers": 2, "service_time": {"type": "exponential", "mean": 4.2}}, "#e67e22"),
			_elem("Sink_Resolved", "Tickets Resolved", "sink", [16.0, 0.0, 0.0], [2.8, 2.2, 1.2], {"record_sojourn": true}, "#e74c3c")
		]
		var conns := [
			_conn("c1", "Source_VIP", "Queue_Dispatch", 1),
			_conn("c2", "Source_Standard", "Queue_Dispatch", 2),
			_conn("c3", "Queue_Dispatch", "Server_Router"),
			_conn("c4", "Server_Router", "Queue_PoolA", 1),
			_conn("c5", "Server_Router", "Queue_PoolB", 2),
			_conn("c6", "Queue_PoolA", "Server_PoolA"),
			_conn("c7", "Queue_PoolB", "Server_PoolB"),
			_conn("c8", "Server_PoolA", "Sink_Resolved"),
			_conn("c9", "Server_PoolB", "Sink_Resolved")
		]
		var opt := {
			"problem_id": "opt_p2_vip_dispatch",
			"problem_class": "policy",
			"title": "VIP Support Dispatcher (Queue Discipline & Routing Policy)",
			"decision_variables": [
				{"id": "disc_main", "element_id": "Queue_Dispatch", "property": "discipline", "type": "categorical", "categories": ["fifo", "priority"], "initial": "fifo", "label": "Dispatch Queue Discipline"},
				{"id": "route_pol", "element_id": "Server_Router", "property": "routing_rule", "type": "categorical", "categories": ["prob", "round_robin", "shortest_queue"], "initial": "prob", "label": "Pool Routing Policy"},
				{"id": "disc_a", "element_id": "Queue_PoolA", "property": "discipline", "type": "categorical", "categories": ["fifo", "priority"], "initial": "fifo", "label": "Pool A Discipline"},
				{"id": "disc_b", "element_id": "Queue_PoolB", "property": "discipline", "type": "categorical", "categories": ["fifo", "priority"], "initial": "fifo", "label": "Pool B Discipline"},
				{"id": "srv_a", "element_id": "Server_PoolA", "property": "servers", "type": "int", "lower": 1, "upper": 5, "initial": 2, "label": "Pool A Engineers"},
				{"id": "srv_b", "element_id": "Server_PoolB", "property": "servers", "type": "int", "lower": 1, "upper": 5, "initial": 2, "label": "Pool B Engineers"}
			],
			"constraints": [
				{"id": "vip_sla", "kind": "metric_bound", "metric": "vip_wait_mean", "relation": "<=", "rhs": 1.5, "penalty_weight": 60.0, "description": "VIP mean queue wait W_q(VIP) <= 1.5s SLA"},
				{"id": "pool_budget", "kind": "linear_sum", "variables": ["srv_a", "srv_b"], "relation": "<=", "rhs": 6.0, "penalty_weight": 40.0, "description": "Total support engineers srv_a + srv_b <= 6"}
			],
			"objective": {"sense": "minimize", "metric": "weighted_vip_std_cost", "description": "Minimize 5*W_q(VIP) + 1*W_q(Std) + 0.8*(srv_a + srv_b)"},
			"solver": {"algorithm": "mixed_ga", "max_evaluations": 36, "population_size": 9, "replications_per_eval": 4, "sim_horizon": 500.0, "warmup_time": 80.0, "use_crn": true, "top_k": 5}
		}
		return _base_doc("opt_p2_vip_dispatch", "2. VIP Support Dispatcher", "Optimize queue discipline (FIFO vs Priority HOL), pool routing rule, and engineer staffing under a VIP SLA.", elems, conns, "des_only", false, opt)

	elif eid == "opt_p3_conveyor_topology":
		var elems := [
			_elem("Source_Inbound", "Inbound Parcel Unloader", "source", [-18.0, -4.0, 0.0], [2.8, 2.0, 1.2], {"interarrival_time": {"type": "exponential", "mean": 1.1}, "priority": 0}, "#f39c12"),
			_elem("Queue_Infeed", "Induction Staging", "queue", [-12.5, -4.0, 0.0], [3.5, 2.0, 0.8], {"capacity": 12, "discipline": "fifo"}, "#3498db"),
			_elem("Conveyor_West", "West Induction Belt", "conveyor", [-7.0, -4.0, 0.0], [5.5, 1.2, 0.8], {"speed": 1.2, "length": 5.5, "capacity": 6, "routing_rule": "prob"}, "#2ecc71"),
			_elem("Conveyor_North", "North Spine Belt", "conveyor", [0.5, -4.0, 0.0], [6.0, 1.2, 0.8], {"speed": 1.2, "length": 6.0, "capacity": 6, "routing_rule": "prob"}, "#2ecc71"),
			_elem("Conveyor_East", "East Transfer Belt", "conveyor", [7.5, 0.0, 0.0], [1.2, 6.0, 0.8], {"speed": 1.2, "length": 6.0, "capacity": 6, "routing_rule": "prob"}, "#2ecc71"),
			_elem("Conveyor_South", "South Distribution Belt", "conveyor", [0.5, 4.0, 0.0], [6.0, 1.2, 0.8], {"speed": 1.2, "length": 6.0, "capacity": 6, "routing_rule": "prob"}, "#2ecc71"),
			_elem("Queue_ChuteA", "Chute A Buffer", "queue", [9.5, -4.5, 0.0], [3.2, 1.8, 0.8], {"capacity": 10, "discipline": "fifo"}, "#3498db"),
			_elem("Server_SorterA", "Optical Sorter A", "server", [14.0, -4.5, 0.0], [2.8, 1.8, 1.8], {"servers": 1, "service_time": {"type": "exponential", "mean": 2.8}}, "#e67e22"),
			_elem("Queue_ChuteB", "Chute B Buffer", "queue", [9.5, 0.0, 0.0], [3.2, 1.8, 0.8], {"capacity": 10, "discipline": "fifo"}, "#3498db"),
			_elem("Server_SorterB", "Optical Sorter B", "server", [14.0, 0.0, 0.0], [2.8, 1.8, 1.8], {"servers": 1, "service_time": {"type": "exponential", "mean": 2.8}}, "#e67e22"),
			_elem("Queue_ChuteC", "Chute C Buffer", "queue", [9.5, 4.5, 0.0], [3.2, 1.8, 0.8], {"capacity": 10, "discipline": "fifo"}, "#3498db"),
			_elem("Server_SorterC", "Optical Sorter C", "server", [14.0, 4.5, 0.0], [2.8, 1.8, 1.8], {"servers": 1, "service_time": {"type": "exponential", "mean": 2.8}}, "#e67e22"),
			_elem("Sink_Outbound", "Outbound Shipping Docks", "sink", [19.5, 0.0, 0.0], [2.8, 2.4, 1.2], {"record_sojourn": true}, "#e74c3c")
		]
		var conns := [
			_conn("c1", "Source_Inbound", "Queue_Infeed"),
			_conn("c2", "Queue_Infeed", "Conveyor_West"),
			_conn("c3", "Conveyor_West", "Conveyor_North"),
			_conn("c4", "Conveyor_North", "Conveyor_East"),
			_conn("c5", "Conveyor_East", "Conveyor_South"),
			_conn("c6", "Conveyor_North", "Queue_ChuteA", 1),
			_conn("c7", "Conveyor_East", "Queue_ChuteB", 1),
			_conn("c8", "Conveyor_South", "Queue_ChuteC", 1),
			_conn("c9", "Queue_ChuteA", "Server_SorterA"),
			_conn("c10", "Queue_ChuteB", "Server_SorterB"),
			_conn("c11", "Queue_ChuteC", "Server_SorterC"),
			_conn("c12", "Server_SorterA", "Sink_Outbound"),
			_conn("c13", "Server_SorterB", "Sink_Outbound"),
			_conn("c14", "Server_SorterC", "Sink_Outbound")
		]
		var opt := {
			"problem_id": "opt_p3_conveyor_topology",
			"problem_class": "topology",
			"title": "Sorting Hub Conveyor (Grammar-Based Topology Evolution)",
			"decision_variables": [
				{"id": "spd_w", "element_id": "Conveyor_West", "property": "speed", "type": "float", "lower": 1.0, "upper": 3.5, "initial": 1.2, "label": "West Belt Speed (m/s)"},
				{"id": "spd_n", "element_id": "Conveyor_North", "property": "speed", "type": "float", "lower": 1.0, "upper": 3.5, "initial": 1.2, "label": "North Belt Speed (m/s)"},
				{"id": "spd_e", "element_id": "Conveyor_East", "property": "speed", "type": "float", "lower": 1.0, "upper": 3.5, "initial": 1.2, "label": "East Belt Speed (m/s)"},
				{"id": "spd_s", "element_id": "Conveyor_South", "property": "speed", "type": "float", "lower": 1.0, "upper": 3.5, "initial": 1.2, "label": "South Belt Speed (m/s)"},
				{"id": "route_n", "element_id": "Conveyor_North", "property": "routing_rule", "type": "categorical", "categories": ["prob", "shortest_queue", "round_robin"], "initial": "prob", "label": "North Diverter Rule"},
				{"id": "route_e", "element_id": "Conveyor_East", "property": "routing_rule", "type": "categorical", "categories": ["prob", "shortest_queue", "round_robin"], "initial": "prob", "label": "East Diverter Rule"},
				{"id": "topology_loop", "element_id": "Conveyor_South", "property": "recirculation_edge", "type": "grammar_edge", "candidates": ["none", "Conveyor_West", "Queue_ChuteA", "Queue_ChuteB"], "initial": "none", "label": "Recirculation / Bypass Link"}
			],
			"constraints": [
				{"id": "max_conveyor_budget", "kind": "topology_budget", "metric": "total_conveyor_length", "relation": "<=", "rhs": 35.0, "penalty_weight": 25.0, "description": "Total conveyor network length <= 35m and DAG/Loop reachability to Sink"}
			],
			"objective": {"sense": "minimize", "metric": "conveyor_jam_and_sojourn", "description": "Minimize parcel sojourn time E[W] + congestion penalty (maximize sorting throughput)"},
			"solver": {"algorithm": "grammar_ga", "max_evaluations": 36, "population_size": 9, "replications_per_eval": 3, "sim_horizon": 400.0, "warmup_time": 60.0, "use_crn": true, "top_k": 5}
		}
		return _base_doc("opt_p3_conveyor_topology", "3. Sorting Hub Conveyor", "Evolve a congested linear spine conveyor into a closed-loop recirculation sorting hub.", elems, conns, "des_only", false, opt)
	return {}
