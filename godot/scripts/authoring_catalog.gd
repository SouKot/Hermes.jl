# authoring_catalog.gd
# Component Catalog for SceneSpec simulation authoring in Godot 4.
class_name SimVizAuthoringCatalog
extends RefCounted

const SceneTypes := preload("res://scripts/scenespec_types.gd")

class CatalogEntry:
	var kind: String = ""
	var display_name: String = ""
	var category: String = ""
	var description: String = ""
	var default_dimensions: Vector3 = Vector3(3.0, 2.0, 1.0)
	var default_elevation_start: float = 0.8
	var default_elevation_end: float = 0.8
	var color: Color = Color("#4A90E2")
	var default_input_ports: Array = []
	var default_output_ports: Array = []
	var default_metric_ports: Array = []
	var default_properties: Dictionary = {}
	var property_schemas: Array = []

	func get_property_schema(key: String) -> Dictionary:
		for s in property_schemas:
			if s.get("key", "") == key:
				var res: Dictionary = s.duplicate(true)
				if not res.has("edit_policy"):
					res["edit_policy"] = "live" if res.get("runtime_editable", true) else "restart_required"
				if res.get("type") == "distribution" and not res.has("supported_distributions"):
					res["supported_distributions"] = ["constant", "uniform", "triangular", "exponential", "normal"]
				return res
		return {}

	func get_schemas_by_group() -> Dictionary:
		var grouped := {}
		for s in property_schemas:
			var grp: String = s.get("group", "General")
			if not grouped.has(grp):
				grouped[grp] = []
			grouped[grp].append(s)
		return grouped

var _entries: Dictionary = {} # kind -> CatalogEntry
var _categories: Array = ["Material Handling", "Storage & Queues", "Processing", "I/O Boundary", "Crowd & Pedestrian", "Hybrid & Multi-Paradigm"]

func _init() -> void:
	_register_defaults()

func get_categories() -> Array:
	return _categories.duplicate()

func get_entries_in_category(cat: String) -> Array:
	var res: Array = []
	for kind in _entries.keys():
		var entry: CatalogEntry = _entries[kind]
		if entry.category == cat:
			res.append(entry)
	return res

func get_entry(kind: String) -> CatalogEntry:
	return _entries.get(kind, null)

func get_all_entries() -> Array:
	return _entries.values()

func _register_defaults() -> void:
	# 1. Conveyor
	var conv := CatalogEntry.new()
	conv.kind = "conveyor"
	conv.display_name = "Belt / Roller Conveyor"
	conv.category = "Material Handling"
	conv.description = "Continuous material transport bed with support legs and variable elevation."
	conv.default_dimensions = Vector3(8.0, 1.2, 0.8)
	conv.default_elevation_start = 0.8
	conv.default_elevation_end = 0.8
	conv.color = Color("#2ecc71")
	conv.default_input_ports = [
		{"id": "flow_in", "kind": "flow", "direction": "input", "cardinality": "one", "name": "Flow In"},
		{"id": "speed_signal", "kind": "signal", "direction": "input", "cardinality": "one", "name": "Speed Signal"}
	]
	conv.default_output_ports = [
		{"id": "flow_out", "kind": "flow", "direction": "output", "cardinality": "one", "name": "Flow Out"}
	]
	conv.default_metric_ports = [
		{"id": "occupancy", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Occupancy"},
		{"id": "speed", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Speed"}
	]
	conv.property_schemas = [
		{"key": "speed", "display_name": "Conveyor Velocity", "type": "float", "default_value": 1.5, "unit": "m/s", "range": [0.1, 10.0, 0.1], "runtime_editable": true, "group": "Kinematics", "description": "Linear surface speed of the transport bed."},
		{"key": "capacity", "display_name": "Bed Item Capacity", "type": "int", "default_value": 10, "unit": "items", "range": [1, 500, 1], "runtime_editable": false, "group": "Capacity & Buffers", "description": "Maximum item accumulation on the belt before upstream blockage."},
		{"key": "reversible", "display_name": "Reversible Flow", "type": "bool", "default_value": false, "unit": "", "range": [], "runtime_editable": true, "group": "Kinematics", "description": "Allow reverse direction conveying via control signals."},
		{"key": "acceleration", "display_name": "Bed Acceleration", "type": "float", "default_value": 2.0, "unit": "m/s²", "range": [0.1, 10.0, 0.1], "runtime_editable": true, "group": "Kinematics", "description": "Rate of speed change when starting or stopping."}
	]
	conv.default_properties = {
		"speed": 1.5,
		"capacity": 10,
		"reversible": false,
		"acceleration": 2.0
	}
	_entries["conveyor"] = conv

	# 2. Queue (Buffer)
	var queue := CatalogEntry.new()
	queue.kind = "queue"
	queue.display_name = "Queue / Staging Buffer"
	queue.category = "Storage & Queues"
	queue.description = "Accumulation buffer or floor staging zone with capacity limits."
	queue.default_dimensions = Vector3(4.0, 2.0, 0.8)
	queue.default_elevation_start = 0.8
	queue.default_elevation_end = 0.8
	queue.color = Color("#3498db")
	queue.default_input_ports = [
		{"id": "flow_in", "kind": "flow", "direction": "input", "cardinality": "many", "name": "Flow In"}
	]
	queue.default_output_ports = [
		{"id": "flow_out", "kind": "flow", "direction": "output", "cardinality": "one", "name": "Flow Out"}
	]
	queue.default_metric_ports = [
		{"id": "occupancy", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Buffer Occupancy"},
		{"id": "length", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Queue Length"},
		{"id": "wait_time", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Avg Wait Time"}
	]
	queue.property_schemas = [
		{"key": "capacity", "display_name": "Buffer Capacity", "type": "int", "default_value": 20, "unit": "items", "range": [1, 1000, 1], "runtime_editable": false, "group": "Storage Policy", "description": "Maximum accumulation buffer storage capacity."},
		{"key": "discipline", "display_name": "Queue Discipline", "type": "enum", "default_value": "FIFO", "enum_options": [{"value": "FIFO", "label": "FIFO (First-In First-Out)"}, {"value": "LIFO", "label": "LIFO (Last-In First-Out)"}, {"value": "Priority", "label": "Priority (Attribute-Based)"}], "runtime_editable": false, "group": "Storage Policy", "description": "Queuing sequence policy for items in this buffer."},
		{"key": "max_wait_time", "display_name": "Max Wait Time", "type": "float", "default_value": 300.0, "unit": "s", "range": [1.0, 7200.0, 10.0], "runtime_editable": true, "group": "Storage Policy", "description": "Threshold before items timeout or trigger secondary routing."}
	]
	queue.default_properties = {
		"capacity": 20,
		"discipline": "FIFO",
		"max_wait_time": 300.0
	}
	_entries["queue"] = queue

	# 3. Server (Workstation)
	var server := CatalogEntry.new()
	server.kind = "server"
	server.display_name = "Server / Assembly Station"
	server.category = "Processing"
	server.description = "Processing workstation with work table, HMI, and 3-color Andon status beacon."
	server.default_dimensions = Vector3(3.0, 2.0, 1.8)
	server.default_elevation_start = 0.8
	server.default_elevation_end = 0.8
	server.color = Color("#e67e22")
	server.default_input_ports = [
		{"id": "flow_in", "kind": "flow", "direction": "input", "cardinality": "one", "name": "Flow In"},
		{"id": "pause_signal", "kind": "signal", "direction": "input", "cardinality": "one", "name": "Pause Signal"}
	]
	server.default_output_ports = [
		{"id": "flow_out", "kind": "flow", "direction": "output", "cardinality": "one", "name": "Flow Out"}
	]
	server.default_metric_ports = [
		{"id": "utilization", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Utilization"},
		{"id": "state", "kind": "metric", "direction": "output", "cardinality": "many", "name": "State"}
	]
	server.property_schemas = [
		{
			"key": "service_time",
			"display_name": "Service Time",
			"type": "distribution",
			"default_value": {"type": "triangular", "min": 2.0, "mode": 4.5, "max": 7.0},
			"unit": "s",
			"range": [0.1, 3600.0, 0.1],
			"runtime_editable": true,
			"group": "DES Processing",
			"description": "Duration required to process one entity through this station."
		},
		{
			"key": "servers",
			"display_name": "Parallel Channels",
			"type": "int",
			"default_value": 1,
			"unit": "channels",
			"range": [1, 16, 1],
			"runtime_editable": false,
			"group": "Capacity & Resources",
			"description": "Number of parallel processing units / heads in this station."
		},
		{
			"key": "failure_model",
			"display_name": "Failure Model",
			"type": "enum",
			"default_value": "None",
			"enum_options": [{"value": "None", "label": "None (100% Availability)"}, {"value": "MTBF_MTTR", "label": "MTBF / MTTR Stochastic Breakdowns"}],
			"runtime_editable": true,
			"group": "Reliability",
			"description": "Machine downtime and maintenance model."
		},
		{
			"key": "mtbf",
			"display_name": "Mean Time Between Failures",
			"type": "float",
			"default_value": 3600.0,
			"unit": "s",
			"range": [60.0, 86400.0, 60.0],
			"runtime_editable": true,
			"group": "Reliability",
			"description": "Average operational time between random breakdown events."
		},
		{
			"key": "mttr",
			"display_name": "Mean Time To Repair",
			"type": "float",
			"default_value": 120.0,
			"unit": "s",
			"range": [5.0, 3600.0, 5.0],
			"runtime_editable": true,
			"edit_policy": "live",
			"group": "Reliability",
			"description": "Average time required to clear an active fault."
		},
		{
			"key": "failure_rate",
			"display_name": "Failure Rate",
			"type": "float",
			"default_value": 0.001,
			"unit": "1/s",
			"range": [0.0, 1.0, 0.0001],
			"runtime_editable": false,
			"edit_policy": "restart_required",
			"group": "Reliability",
			"description": "Rate of unexpected operational failures per unit time."
		}
	]
	server.default_properties = {
		"service_time": {"type": "triangular", "min": 2.0, "mode": 4.5, "max": 7.0},
		"servers": 1,
		"failure_model": "None",
		"mtbf": 3600.0,
		"mttr": 120.0,
		"failure_rate": 0.001
	}
	_entries["server"] = server

	# 4. Source (Infeed)
	var source := CatalogEntry.new()
	source.kind = "source"
	source.display_name = "Source / Infeed"
	source.category = "I/O Boundary"
	source.description = "Generates incoming parts, pallets, or customers into the system."
	source.default_dimensions = Vector3(2.0, 1.5, 1.0)
	source.default_elevation_start = 0.8
	source.default_elevation_end = 0.8
	source.color = Color("#27ae60")
	source.default_input_ports = []
	source.default_output_ports = [
		{"id": "flow_out", "kind": "flow", "direction": "output", "cardinality": "one", "name": "Flow Out"}
	]
	source.default_metric_ports = [
		{"id": "generation_count", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Generated Count"}
	]
	source.property_schemas = [
		{
			"key": "interarrival_time",
			"display_name": "Interarrival Time",
			"type": "distribution",
			"default_value": {"type": "exponential", "mean": 3.0},
			"unit": "s",
			"range": [0.1, 3600.0, 0.1],
			"runtime_editable": true,
			"group": "Infeed Generation",
			"description": "Time delay between successive entity arrivals."
		},
		{
			"key": "entity_type",
			"display_name": "Entity Type",
			"type": "string",
			"default_value": "carton",
			"unit": "",
			"range": [],
			"runtime_editable": false,
			"group": "Infeed Generation",
			"description": "Payload entity identifier generated by this source."
		},
		{
			"key": "batch_size",
			"display_name": "Arrival Batch Size",
			"type": "int",
			"default_value": 1,
			"unit": "pcs",
			"range": [1, 50, 1],
			"runtime_editable": true,
			"group": "Infeed Generation",
			"description": "Number of entities spawned simultaneously on each arrival event."
		},
		{
			"key": "max_entities",
			"display_name": "Max Generations",
			"type": "int",
			"default_value": 0,
			"unit": "pcs (0=inf)",
			"range": [0, 100000, 10],
			"runtime_editable": true,
			"group": "Infeed Generation",
			"description": "Stop generation after this many entities (0 = infinite)."
		}
	]
	source.default_properties = {
		"interarrival_time": {"type": "exponential", "mean": 3.0},
		"entity_type": "carton",
		"batch_size": 1,
		"max_entities": 0
	}
	_entries["source"] = source

	# 5. Sink (Discharge)
	var sink := CatalogEntry.new()
	sink.kind = "sink"
	sink.display_name = "Sink / Discharge"
	sink.category = "I/O Boundary"
	sink.description = "Exits completed parts or customers from the simulation."
	sink.default_dimensions = Vector3(2.0, 1.5, 0.8)
	sink.default_elevation_start = 0.8
	sink.default_elevation_end = 0.8
	sink.color = Color("#8e44ad")
	sink.default_input_ports = [
		{"id": "flow_in", "kind": "flow", "direction": "input", "cardinality": "many", "name": "Flow In"}
	]
	sink.default_output_ports = []
	sink.default_metric_ports = [
		{"id": "completed_count", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Completed Count"}
	]
	sink.property_schemas = [
		{
			"key": "collect_metrics",
			"display_name": "Collect Metrics",
			"type": "bool",
			"default_value": true,
			"unit": "",
			"range": [],
			"runtime_editable": true,
			"group": "Discharge & Metrics",
			"description": "Record cycle time, throughput, and lead time metrics on exited entities."
		}
	]
	sink.default_properties = {
		"collect_metrics": true
	}
	_entries["sink"] = sink

	# 6. Crowd Spawner (Ingress)
	var spawner := CatalogEntry.new()
	spawner.kind = "crowd_spawner"
	spawner.display_name = "Crowd Spawner"
	spawner.category = "Crowd & Pedestrian"
	spawner.description = "Generates agent streams into a room, corridor, or concourse."
	spawner.default_dimensions = Vector3(2.0, 4.0, 2.0)
	spawner.default_elevation_start = 0.0
	spawner.default_elevation_end = 0.0
	spawner.color = Color("#8bc34a")
	spawner.default_input_ports = []
	spawner.default_output_ports = [
		{"id": "crowd_out", "kind": "flow", "direction": "output", "cardinality": "many", "name": "Crowd Stream"}
	]
	spawner.default_metric_ports = [
		{"id": "spawned_count", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Spawned Total"}
	]
	spawner.property_schemas = [
		{"key": "agent_count", "display_name": "Target Agent Count", "type": "int", "default_value": 50, "unit": "peds", "range": [1, 100000, 10], "runtime_editable": false, "group": "Population", "description": "Total number of agents to generate."},
		{"key": "spawn_rate", "display_name": "Spawn Rate", "type": "float", "default_value": 2.0, "unit": "ped/s", "range": [0.1, 100.0, 0.5], "runtime_editable": true, "group": "Ingress Dynamics", "description": "Frequency of pedestrian entry into the simulation space."},
		{"key": "initial_speed", "display_name": "Initial Velocity", "type": "float", "default_value": 1.34, "unit": "m/s", "range": [0.2, 5.0, 0.1], "runtime_editable": true, "group": "Ingress Dynamics", "description": "Initial desired velocity assigned to newly spawned agents."},
		{"key": "spawn_distribution", "display_name": "Inter-Arrival Pattern", "type": "enum", "default_value": "constant", "options": ["constant", "poisson", "burst"], "runtime_editable": true, "group": "Ingress Dynamics", "description": "Statistical arrival distribution for spawned pedestrians."}
	]
	spawner.default_properties = {
		"agent_count": 50,
		"spawn_rate": 2.0,
		"initial_speed": 1.34,
		"spawn_distribution": "constant"
	}
	_entries["crowd_spawner"] = spawner

	# 7. Exit Goal (Egress)
	var exit_g := CatalogEntry.new()
	exit_g.kind = "exit_goal"
	exit_g.display_name = "Exit Goal / Doorway"
	exit_g.category = "Crowd & Pedestrian"
	exit_g.description = "Destination portal or doorway where agents complete their journey and leave the crowd."
	exit_g.default_dimensions = Vector3(1.0, 2.0, 2.4)
	exit_g.default_elevation_start = 0.0
	exit_g.default_elevation_end = 0.0
	exit_g.color = Color("#4caf50")
	exit_g.default_input_ports = [
		{"id": "crowd_in", "kind": "flow", "direction": "input", "cardinality": "many", "name": "Crowd In"}
	]
	exit_g.default_output_ports = []
	exit_g.default_metric_ports = [
		{"id": "egress_flow", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Egress Rate"},
		{"id": "exited_total", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Exited Total"}
	]
	exit_g.property_schemas = [
		{"key": "door_width", "display_name": "Door Opening Width", "type": "float", "default_value": 2.0, "unit": "m", "range": [0.5, 20.0, 0.5], "runtime_editable": true, "group": "Doorway Geometry", "description": "Clear doorway width determining egress bottleneck throughput."},
		{"key": "remove_on_exit", "display_name": "Remove Agent on Exit", "type": "bool", "default_value": true, "runtime_editable": false, "group": "Egress Rules", "description": "Instantly purge agent from simulation upon reaching the exit threshold."}
	]
	exit_g.default_properties = {
		"door_width": 2.0,
		"remove_on_exit": true
	}
	_entries["exit_goal"] = exit_g

	# 8. Walkable Room / Concourse
	var room := CatalogEntry.new()
	room.kind = "walkable_room"
	room.display_name = "Walkable Concourse / Room"
	room.category = "Crowd & Pedestrian"
	room.description = "Navigable floor polygon defining continuous walking territory for agents."
	room.default_dimensions = Vector3(10.0, 10.0, 2.8)
	room.default_elevation_start = 0.0
	room.default_elevation_end = 0.0
	room.color = Color("#95a5a6")
	room.default_input_ports = []
	room.default_output_ports = []
	room.default_metric_ports = [
		{"id": "density", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Area Density"}
	]
	room.property_schemas = [
		{"key": "navmesh_enabled", "display_name": "Generate Navmesh", "type": "bool", "default_value": true, "runtime_editable": false, "group": "Navigation", "description": "Bake navigation mesh over this floor surface for pathfinding."},
		{"key": "speed_factor", "display_name": "Walking Speed Multiplier", "type": "float", "default_value": 1.0, "unit": "x", "range": [0.1, 2.0, 0.1], "runtime_editable": true, "group": "Surface Properties", "description": "Modulates pedestrian velocity (e.g. 0.7 for stairs/carpet, 1.2 for moving sidewalks)."}
	]
	room.default_properties = {
		"navmesh_enabled": true,
		"speed_factor": 1.0
	}
	_entries["walkable_room"] = room

	# 9. Obstacle Barrier / Wall
	var obst := CatalogEntry.new()
	obst.kind = "obstacle_wall"
	obst.display_name = "Obstacle Barrier / Pillar"
	obst.category = "Crowd & Pedestrian"
	obst.description = "Solid architectural column or partition wall that repels crowd agents."
	obst.default_dimensions = Vector3(0.4, 6.0, 2.8)
	obst.default_elevation_start = 0.0
	obst.default_elevation_end = 0.0
	obst.color = Color("#7f8c8d")
	obst.default_input_ports = []
	obst.default_output_ports = []
	obst.default_metric_ports = []
	obst.property_schemas = [
		{"key": "is_passable", "display_name": "Passable Barrier", "type": "bool", "default_value": false, "runtime_editable": false, "group": "Collision", "description": "Defines whether agents can pass through (e.g. transparent queue stanchions vs solid walls)."}
	]
	obst.default_properties = {
		"is_passable": false
	}
	_entries["obstacle_wall"] = obst

	# 10. Hybrid Portal (Turnstile / Gateway)
	var portal := CatalogEntry.new()
	portal.kind = "hybrid_portal"
	portal.display_name = "Hybrid Turnstile / Portal"
	portal.category = "Hybrid & Multi-Paradigm"
	portal.description = "Boundary gateway converting discrete event parts/queue entities into continuous crowd agents, or vice versa."
	portal.default_dimensions = Vector3(1.0, 2.5, 2.2)
	portal.default_elevation_start = 0.0
	portal.default_elevation_end = 0.0
	portal.color = Color("#9b59b6")
	portal.default_input_ports = [
		{"id": "flow_in", "kind": "flow", "direction": "input", "cardinality": "one", "name": "DES In"},
		{"id": "gate_control", "kind": "control", "direction": "input", "cardinality": "one", "name": "Gate Control"}
	]
	portal.default_output_ports = [
		{"id": "crowd_out", "kind": "flow", "direction": "output", "cardinality": "many", "name": "Crowd Stream"}
	]
	portal.default_metric_ports = [
		{"id": "throughput", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Throughput"}
	]
	portal.property_schemas = [
		{"key": "conversion_mode", "display_name": "Conversion Paradigm", "type": "enum", "default_value": "des_to_crowd", "options": ["des_to_crowd", "crowd_to_des"], "runtime_editable": false, "group": "Hybrid Coupling", "description": "Direction of conversion between discrete items and continuous agents."},
		{"key": "initial_speed", "display_name": "Egress Pedestrian Speed", "type": "float", "default_value": 1.2, "unit": "m/s", "range": [0.2, 3.0, 0.1], "runtime_editable": true, "group": "Hybrid Coupling", "description": "Initial walking velocity imparted to pedestrians as they leave the turnstile."},
		{"key": "gate_latency_sec", "display_name": "Handshake Latency", "type": "float", "default_value": 0.5, "unit": "s", "range": [0.0, 10.0, 0.1], "runtime_editable": true, "group": "Hybrid Coupling", "description": "Physical transaction delay at turnstile badge scanner before admission."}
	]
	portal.default_properties = {
		"conversion_mode": "des_to_crowd",
		"initial_speed": 1.2,
		"gate_latency_sec": 0.5
	}
	_entries["hybrid_portal"] = portal

func create_element_instance(kind: String, id_val: String, pos: Vector2) -> SceneTypes.SceneElement:
	var entry := get_entry(kind)
	if entry == null:
		entry = get_entry("server")

	var elem := SceneTypes.SceneElement.new()
	elem.id = id_val
	elem.name = "%s_%s" % [entry.display_name.split("/")[0].strip_edges(), id_val]
	elem.kind = entry.kind
	elem.transform.position = Vector3(pos.x, pos.y, entry.default_elevation_start)
	elem.transform.rotation = Vector3.ZERO
	elem.transform.scale = Vector3.ONE

	elem.geometry = {
		"shape": "box",
		"dimensions": [entry.default_dimensions.x, entry.default_dimensions.y, entry.default_dimensions.z],
		"elevation_start": entry.default_elevation_start,
		"elevation_end": entry.default_elevation_end
	}

	elem.editor.graph_position = Vector2(pos.x * 20.0, pos.y * 20.0) # Scale to pixel coordinates
	elem.editor.color = "#%s" % entry.color.to_html(false)

	for p in entry.default_input_ports:
		var port := SceneTypes.ScenePort.new()
		port.id = p["id"]
		port.kind = p["kind"]
		port.direction = p["direction"]
		port.cardinality = p["cardinality"]
		port.name = p["name"]
		elem.input_ports.append(port)

	for p in entry.default_output_ports:
		var port := SceneTypes.ScenePort.new()
		port.id = p["id"]
		port.kind = p["kind"]
		port.direction = p["direction"]
		port.cardinality = p["cardinality"]
		port.name = p["name"]
		elem.output_ports.append(port)

	for p in entry.default_metric_ports:
		var port := SceneTypes.ScenePort.new()
		port.id = p["id"]
		port.kind = p["kind"]
		port.direction = p["direction"]
		port.cardinality = p["cardinality"]
		port.name = p["name"]
		elem.metric_ports.append(port)

	elem.properties = entry.default_properties.duplicate(true)
	return elem
