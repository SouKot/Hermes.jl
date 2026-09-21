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
var selected_type: String = "" # "element", "connection", "level", ""

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
	selection_changed.emit(selected_id, selected_type)

func clear_selection() -> void:
	selected_id = ""
	selected_type = ""
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
	_record_undo()
	for i in range(active_document.elements.size() - 1, -1, -1):
		if active_document.elements[i].id == elem_id:
			active_document.elements.remove_at(i)
			break
	# Remove connected links
	for i in range(active_document.connections.size() - 1, -1, -1):
		var conn: SceneTypes.SceneConnection = active_document.connections[i]
		if conn.source_element == elem_id or conn.target_element == elem_id:
			active_document.connections.remove_at(i)
	if selected_id == elem_id:
		clear_selection()
	validate()
	document_modified.emit()

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
