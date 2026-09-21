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
