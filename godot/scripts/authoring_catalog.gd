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

var _entries: Dictionary = {} # kind -> CatalogEntry
var _categories: Array = ["Material Handling", "Storage & Queues", "Processing", "I/O Boundary"]

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
	conv.default_properties = {
		"speed": 1.5,
		"capacity": 10,
		"reversible": false
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
		{"id": "length", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Queue Length"},
		{"id": "wait_time", "kind": "metric", "direction": "output", "cardinality": "many", "name": "Avg Wait Time"}
	]
	queue.default_properties = {
		"capacity": 20,
		"discipline": "FIFO"
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
	server.default_properties = {
		"service_time": 4.5,
		"servers": 1
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
	source.default_properties = {
		"interarrival_time": 3.0,
		"entity_type": "carton"
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
	sink.default_properties = {}
	_entries["sink"] = sink

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
