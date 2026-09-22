# authoring_document_store.gd
# Document management, dirty tracking, undo/redo, and atomic I/O for SceneSpec.
class_name SimVizAuthoringDocumentStore
extends RefCounted

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const SceneCodec := preload("res://scripts/scenespec_codec.gd")
const SceneValidator := preload("res://scripts/scenespec_validator.gd")

signal document_loaded(doc: SceneTypes.SceneDocument)
signal document_saved(path: String)
signal document_modified()
signal diagnostics_updated(diagnostics: Array, is_valid: bool)
signal selection_changed(selected_id: String, selected_type: String)

var active_document: SceneTypes.SceneDocument
var file_path: String = ""
var is_dirty: bool = false
var selected_id: String = ""
var selected_type: String = "" # "element", "connection", "level", "port", ""
var selected_port_id: String = ""
var selected_elements: Array[String] = []

var _undo_stack: Array = []
var _redo_stack: Array = []
const MAX_UNDO_STEPS := 50

var last_diagnostics: Array = []
var is_document_valid: bool = true

func _init() -> void:
	new_document()

func new_document() -> void:
	active_document = SceneTypes.SceneDocument.new()
	active_document.spec_version = "1.0.0"
	active_document.scene = {
		"id": "untitled_scene",
		"name": "Untitled Simulation",
		"author": "Antigravity SimViz"
	}
	active_document.simulation = {
		"time_unit": "seconds",
		"warmup_time": 0.0,
		"max_duration": 3600.0
	}

	var level := SceneTypes.SceneLevel.new()
	level.id = "level_0"
	level.name = "Ground Floor"
	level.elevation = 0.0
	level.default_height = 4.5
	active_document.spatial = {
		"levels": [level.to_dict()],
		"bounds": [-50.0, -50.0, 0.0, 50.0, 50.0, 10.0]
	}

	file_path = ""
	is_dirty = false
	_undo_stack.clear()
	_redo_stack.clear()
	selected_id = ""
	selected_type = ""
	validate()
	document_loaded.emit(active_document)

func load_from_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()

	var codec := SceneCodec.new()
	var doc = codec.load_document(text)
	if doc == null:
		return false

	active_document = doc
	file_path = path
	is_dirty = false
	_undo_stack.clear()
	_redo_stack.clear()
	selected_id = ""
	selected_type = ""
	validate()
	document_loaded.emit(active_document)
	return true

func save_to_file(path: String = "") -> bool:
	var target_path := path if not path.is_empty() else file_path
	if target_path.is_empty():
		return false

	var codec := SceneCodec.new()
	var text := codec.save_document(active_document, true)
	if text.is_empty():
		return false

	# Atomic write: save to .tmp then rename
	var tmp_path := target_path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()

	if FileAccess.file_exists(target_path):
		DirAccess.remove_absolute(target_path)
	var err := DirAccess.rename_absolute(tmp_path, target_path)
	if err == OK:
		file_path = target_path
		is_dirty = false
		document_saved.emit(target_path)
		return true
	return false

func select(id_val: String, type_val: String = "element") -> void:
	selected_id = id_val
	selected_type = type_val
	selected_port_id = ""
	if type_val == "element" and not id_val.is_empty():
		selected_elements = [id_val]
	else:
		selected_elements.clear()
	selection_changed.emit(selected_id, selected_type)

func select_port(elem_id: String, port_id: String) -> void:
	selected_id = elem_id
	selected_port_id = port_id
	selected_type = "port"
	selected_elements.clear()
	selection_changed.emit(selected_id, selected_type)

func get_selected_port() -> SceneTypes.ScenePort:
	if selected_type != "port" or selected_port_id.is_empty():
		return null
	var elem := get_element(selected_id)
	if elem == null:
		return null
	for p in elem.input_ports:
		if p.id == selected_port_id:
			return p
	for p in elem.output_ports:
		if p.id == selected_port_id:
			return p
	for p in elem.metric_ports:
		if p.id == selected_port_id:
			return p
	return null

func toggle_select_element(id_val: String) -> void:
	if id_val.is_empty():
		return
	if selected_type != "element":
		selected_elements.clear()
		selected_type = "element"
	selected_port_id = ""
	if selected_elements.has(id_val):
		selected_elements.erase(id_val)
		if selected_elements.is_empty():
			clear_selection()
			return
		else:
			selected_id = selected_elements[-1]
	else:
		selected_elements.append(id_val)
		selected_id = id_val
	selection_changed.emit(selected_id, selected_type)

func set_selected_elements(ids: Array[String]) -> void:
	selected_elements = ids.duplicate()
	selected_port_id = ""
	if selected_elements.is_empty():
		clear_selection()
	else:
		selected_id = selected_elements[-1]
		selected_type = "element"
		selection_changed.emit(selected_id, selected_type)

func select_multiple(ids: Array) -> void:
	var typed_ids: Array[String] = []
	for id in ids:
		typed_ids.append(str(id))
	set_selected_elements(typed_ids)

func is_element_selected(id_val: String) -> bool:
	return selected_type == "element" and selected_elements.has(id_val)

func clear_selection() -> void:
	selected_id = ""
	selected_type = ""
	selected_port_id = ""
	selected_elements.clear()
	selection_changed.emit("", "")

func validate() -> Array:
	if active_document == null:
		last_diagnostics = []
		is_document_valid = true
		diagnostics_updated.emit(last_diagnostics, is_document_valid)
		return []

	var validator := SceneValidator.new()
	var res: Dictionary = validator.validate_document(active_document)
	last_diagnostics = res.get("diagnostics", [])
	is_document_valid = bool(res.get("is_valid", true))
	diagnostics_updated.emit(last_diagnostics, is_document_valid)
	return last_diagnostics

func _record_undo() -> void:
	if active_document == null:
		return
	_undo_stack.append(active_document.clone())
	if _undo_stack.size() > MAX_UNDO_STEPS:
		_undo_stack.pop_front()
	_redo_stack.clear()
	is_dirty = true
	document_modified.emit()

func undo() -> bool:
	if _undo_stack.is_empty():
		return false
	_redo_stack.append(active_document.clone())
	active_document = _undo_stack.pop_back()
	is_dirty = true
	validate()
	document_modified.emit()
	return true

func redo() -> bool:
	if _redo_stack.is_empty():
		return false
	_undo_stack.append(active_document.clone())
	active_document = _redo_stack.pop_back()
	is_dirty = true
	validate()
	document_modified.emit()
	return true

func add_element(elem: SceneTypes.SceneElement) -> void:
	_record_undo()
	active_document.elements.append(elem)
	select(elem.id, "element")
	validate()
	document_modified.emit()

func remove_element(elem_id: String) -> void:
	remove_elements([elem_id])

func remove_elements(ids: Array) -> void:
	if active_document == null or ids.is_empty():
		return
	_record_undo()
	var id_set := {}
	for id in ids:
		id_set[str(id)] = true

	for i in range(active_document.elements.size() - 1, -1, -1):
		if id_set.has(active_document.elements[i].id):
			active_document.elements.remove_at(i)

	for i in range(active_document.connections.size() - 1, -1, -1):
		var conn: SceneTypes.SceneConnection = active_document.connections[i]
		if id_set.has(conn.source_element) or id_set.has(conn.target_element):
			active_document.connections.remove_at(i)

	if id_set.has(selected_id) or selected_type == "element":
		clear_selection()

	validate()
	document_modified.emit()

func duplicate_element(elem_id: String) -> SceneTypes.SceneElement:
	var elem := get_element(elem_id)
	if elem == null or active_document == null:
		return null

	_record_undo()
	var clone := elem.clone()

	# Generate unique ID
	var base_id := elem.id
	var new_id := base_id + "_copy"
	var counter := 1
	var existing_ids := {}
	for e in active_document.elements:
		existing_ids[e.id] = true
	while existing_ids.has(new_id):
		counter += 1
		new_id = "%s_copy%02d" % [base_id, counter]

	clone.id = new_id
	clone.name = new_id

	# Offset physical position (+2.0m along X and +2.0m along Y)
	clone.transform.position.x += 2.0
	clone.transform.position.y += 2.0
	clone.editor.graph_position = Vector2(clone.transform.position.x * 20.0, clone.transform.position.y * 20.0)

	active_document.elements.append(clone)
	select(clone.id, "element")
	validate()
	document_modified.emit()
	return clone

func set_element_rotation(elem_id: String, angle_deg: float) -> bool:
	var elem := get_element(elem_id)
	if elem == null:
		return false
	_record_undo()
	elem.transform.rotation.z = fposmod(angle_deg, 360.0)
	validate()
	document_modified.emit()
	return true

func rotate_element(elem_id: String, delta_deg: float = 45.0) -> bool:
	var elem := get_element(elem_id)
	if elem == null:
		return false
	return set_element_rotation(elem_id, elem.transform.rotation.z + delta_deg)

func get_element(elem_id: String) -> SceneTypes.SceneElement:
	if active_document == null:
		return null
	for elem in active_document.elements:
		if elem.id == elem_id:
			return elem
	return null

func update_element_geometry(elem_id: String, new_dims: Vector3, elev_start: float = -999.0, elev_end: float = -999.0) -> bool:
	var elem := get_element(elem_id)
	if elem == null:
		return false
	_record_undo()
	elem.geometry["dimensions"] = [max(0.1, new_dims.x), max(0.1, new_dims.y), max(0.05, new_dims.z)]
	if elev_start > -900.0:
		elem.geometry["elevation_start"] = max(0.0, elev_start)
	if elev_end > -900.0:
		elem.geometry["elevation_end"] = max(0.0, elev_end)
	validate()
	document_modified.emit()
	return true

func update_element_position(elem_id: String, new_pos: Vector3) -> bool:
	var elem := get_element(elem_id)
	if elem == null:
		return false
	_record_undo()
	elem.transform.position = Vector3(new_pos.x, new_pos.y, max(0.0, new_pos.z))
	elem.editor.graph_position = Vector2(new_pos.x * 20.0, new_pos.y * 20.0)
	validate()
	document_modified.emit()
	return true

func add_connection(conn: SceneTypes.SceneConnection) -> void:
	_record_undo()
	active_document.connections.append(conn)
	validate()
	document_modified.emit()

func remove_connection(conn_id: String) -> void:
	_record_undo()
	for i in range(active_document.connections.size() - 1, -1, -1):
		if active_document.connections[i].id == conn_id:
			active_document.connections.remove_at(i)
			break
	if selected_id == conn_id:
		clear_selection()
	validate()
	document_modified.emit()

func add_port_to_element(elem_id: String, port: SceneTypes.ScenePort) -> bool:
	var elem := get_element(elem_id)
	if elem == null:
		return false
	_record_undo()
	if port.direction == "input":
		elem.input_ports.append(port)
	elif port.kind == "metric":
		elem.metric_ports.append(port)
	else:
		elem.output_ports.append(port)
	validate()
	document_modified.emit()
	return true

func remove_last_port_from_element(elem_id: String, bay_action: String) -> bool:
	var elem := get_element(elem_id)
	if elem == null or active_document == null:
		return false

	var removed_port_id := ""
	match bay_action:
		"flow_in":
			var flow_ins: Array = []
			for p in elem.input_ports:
				if p.kind == "flow":
					flow_ins.append(p)
			if flow_ins.size() <= 1:
				return false # Protect core primary flow_in
			var target_port: SceneTypes.ScenePort = flow_ins[-1]
			removed_port_id = target_port.id
			elem.input_ports.erase(target_port)

		"flow_out":
			var flow_outs: Array = []
			for p in elem.output_ports:
				if p.kind == "flow":
					flow_outs.append(p)
			if flow_outs.size() <= 1:
				return false # Protect core primary flow_out
			var target_port: SceneTypes.ScenePort = flow_outs[-1]
			removed_port_id = target_port.id
			elem.output_ports.erase(target_port)

		"signal_in":
			var sig_ins: Array = []
			for p in elem.input_ports:
				if p.kind in ["signal", "control"]:
					sig_ins.append(p)
			if sig_ins.is_empty():
				return false
			var target_port: SceneTypes.ScenePort = sig_ins[-1]
			removed_port_id = target_port.id
			elem.input_ports.erase(target_port)

		"metric_out":
			if not elem.metric_ports.is_empty():
				var target_port: SceneTypes.ScenePort = elem.metric_ports[-1]
				removed_port_id = target_port.id
				elem.metric_ports.pop_back()
			else:
				var met_outs: Array = []
				for p in elem.output_ports:
					if p.kind == "metric":
						met_outs.append(p)
				if met_outs.is_empty():
					return false
				var target_port: SceneTypes.ScenePort = met_outs[-1]
				removed_port_id = target_port.id
				elem.output_ports.erase(target_port)

	if removed_port_id.is_empty():
		return false

	_record_undo()

	# Cascade delete any connections referencing the removed port
	for i in range(active_document.connections.size() - 1, -1, -1):
		var c: SceneTypes.SceneConnection = active_document.connections[i]
		if (c.source_element == elem_id and c.source_port == removed_port_id) or \
		   (c.target_element == elem_id and c.target_port == removed_port_id):
			active_document.connections.remove_at(i)
			if selected_id == c.id:
				clear_selection()

	validate()
	document_modified.emit()
	return true

func disconnect_port(elem_id: String, port_id: String) -> int:
	if active_document == null:
		return 0

	var removed_count := 0
	for i in range(active_document.connections.size() - 1, -1, -1):
		var c: SceneTypes.SceneConnection = active_document.connections[i]
		if (c.source_element == elem_id and c.source_port == port_id) or \
		   (c.target_element == elem_id and c.target_port == port_id):
			if removed_count == 0:
				_record_undo()
			active_document.connections.remove_at(i)
			if selected_id == c.id:
				clear_selection()
			removed_count += 1

	if removed_count > 0:
		validate()
		document_modified.emit()

	return removed_count

func set_element_property(elem_id: String, prop_key: String, value: Variant) -> bool:
	var elem := get_element(elem_id)
	if elem == null:
		return false
	_record_undo()
	elem.properties[prop_key] = value
	validate()
	document_modified.emit()
	return true

func set_elements_property_batch(elem_ids: Array, prop_key: String, value: Variant) -> bool:
	if elem_ids.is_empty() or active_document == null:
		return false
	_record_undo()
	var any_updated := false
	for eid in elem_ids:
		var elem := get_element(str(eid))
		if elem != null:
			elem.properties[prop_key] = value
			any_updated = true
	if any_updated:
		validate()
		document_modified.emit()
		return true
	return false

func update_port_properties(elem_id: String, port_id: String, props: Dictionary) -> bool:
	var elem := get_element(elem_id)
	if elem == null:
		return false
	var target_port: SceneTypes.ScenePort = null
	for p in elem.input_ports:
		if p.id == port_id:
			target_port = p
			break
	if target_port == null:
		for p in elem.output_ports:
			if p.id == port_id:
				target_port = p
				break
	if target_port == null:
		for p in elem.metric_ports:
			if p.id == port_id:
				target_port = p
				break
	if target_port == null:
		return false

	_record_undo()
	for k in props.keys():
		var sk := str(k)
		var val = props[k]
		if sk in ["cardinality", "required", "unit", "description", "data_type", "name"]:
			target_port.set(sk, val)
		else:
			target_port.set_extension(sk, val)

	validate()
	document_modified.emit()
	return true

func update_connection_condition(conn_id: String, condition_dict: Dictionary) -> bool:
	if active_document == null:
		return false
	var target_conn: SceneTypes.SceneConnection = null
	for c in active_document.connections:
		if c.id == conn_id:
			target_conn = c
			break
	if target_conn == null:
		return false

	_record_undo()
	target_conn.condition = condition_dict.duplicate(true)
	validate()
	document_modified.emit()
	return true

func auto_layout_dag(spacing_x: float = 240.0, spacing_y: float = 120.0) -> bool:
	if active_document == null or active_document.elements.is_empty():
		return false

	var elems: Array = active_document.elements
	var in_degree := {}
	var adj := {}
	var elem_map := {}

	for elem in elems:
		in_degree[elem.id] = 0
		adj[elem.id] = []
		elem_map[elem.id] = elem

	for conn in active_document.connections:
		var src: String = conn.source_element
		var tgt: String = conn.target_element
		if elem_map.has(src) and elem_map.has(tgt):
			if not adj[src].has(tgt):
				adj[src].append(tgt)
				in_degree[tgt] = in_degree.get(tgt, 0) + 1

	# Assign layers using BFS / longest path from roots (in_degree == 0 or kind == "source")
	var layers := {}
	var queue: Array = []
	for elem in elems:
		if in_degree[elem.id] == 0 or elem.kind == "source":
			layers[elem.id] = 0
			queue.append(elem.id)

	# If all nodes are in a cycle or no root found, pick first element
	if queue.is_empty() and not elems.is_empty():
		var first_id: String = elems[0].id
		layers[first_id] = 0
		queue.append(first_id)

	var max_layer := 0
	while not queue.is_empty():
		var u: String = queue.pop_front()
		var u_layer: int = layers.get(u, 0)
		for v in adj.get(u, []):
			var v_layer: int = max(layers.get(v, 0), u_layer + 1)
			layers[v] = v_layer
			max_layer = max(max_layer, v_layer)
			if not queue.has(v):
				queue.append(v)

	# Group elements by layer
	var layer_groups := {}
	for elem in elems:
		var l: int = layers.get(elem.id, 0)
		if not layer_groups.has(l):
			layer_groups[l] = []
		layer_groups[l].append(elem)

	_record_undo()
	# Position elements cleanly along layers
	var base_x := 40.0
	var base_y := 40.0
	for l in range(max_layer + 1):
		if not layer_groups.has(l):
			continue
		var group: Array = layer_groups[l]
		for i in range(group.size()):
			var elem: SceneTypes.SceneElement = group[i]
			var gx: float = base_x + float(l) * spacing_x
			var gy: float = base_y + float(i) * spacing_y
			elem.editor.graph_position = Vector2(gx, gy)
			elem.transform.position = Vector3(gx / 20.0, gy / 20.0, elem.transform.position.z)

	validate()
	document_modified.emit()
	return true
