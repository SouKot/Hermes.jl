# authoring_document_store.gd
# Document management, dirty tracking, undo/redo, and atomic I/O for SceneSpec.
class_name SimVizAuthoringDocumentStore
extends RefCounted

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const SceneCodec := preload("res://scripts/scenespec_codec.gd")
const SceneValidator := preload("res://scripts/scenespec_validator.gd")
const SceneRepository := preload("res://scripts/scenespec_repository.gd")

signal document_loaded(doc: SceneTypes.SceneDocument)
signal document_saved(path: String)
signal document_modified()
signal diagnostics_updated(diagnostics: Array, is_valid: bool)
signal selection_changed(selected_id: String, selected_type: String)
signal scope_changed(scope_id: String, scope_name: String)
signal subgraphs_modified()
signal autosave_completed(path: String, timestamp: float)
signal recovery_detected(recovery_info: Dictionary)

var active_document: SceneTypes.SceneDocument
var file_path: String = ""
var is_dirty: bool = false
var selected_id: String = ""
var selected_type: String = "" # "element", "connection", "level", "port", "subgraph", ""
var selected_port_id: String = ""
var selected_elements: Array[String] = []
var current_scope_id: String = "" # "" denotes root scene

var repository := SceneRepository.new()
var autosave_enabled: bool = true
var autosave_interval_sec: float = 45.0
var _autosave_timer: float = 0.0
var last_autosave_time: float = 0.0
var last_autosave_path: String = ""

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
		"max_duration": 3600.0,
		"mode": "des_only"
	}
	active_document.abm_config = {
		"enabled": false,
		"model_name": "SFM",
		"parameters": {},
		"pedestrian_profiles": []
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
	current_scope_id = ""
	_undo_stack.clear()
	_redo_stack.clear()
	selected_id = ""
	selected_type = ""
	validate()
	scope_changed.emit("", "Root")
	document_loaded.emit(active_document)

static func clean_file_basename(path: String) -> String:
	var fname := path.get_file()
	for ext in [".scenespec.mp", ".scenespec", ".json", ".mp", ".simviz"]:
		if fname.ends_with(ext):
			fname = fname.trim_suffix(ext)
			break
	return fname

func get_display_title() -> String:
	if not file_path.is_empty():
		return file_path.get_file()
	var sname: String = str(active_document.scene.get("name", "")).strip_edges() if active_document != null else ""
	return sname if not sname.is_empty() else "Untitled Simulation"

func load_from_file(path: String) -> bool:
	if path.ends_with(".simviz") or (DirAccess.dir_exists_absolute(path) and FileAccess.file_exists(path.path_join("project.json"))):
		return load_from_bundle(path)

	if not FileAccess.file_exists(path):
		return false

	var codec := SceneCodec.new()
	var doc: SceneTypes.SceneDocument = null
	var fmt_type := "canonical_json"

	if path.ends_with(".mp") or path.ends_with(".scenespec.mp"):
		doc = codec.load_from_msgpack_file(path)
		fmt_type = "msgpack"
	else:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			return false
		var text := f.get_as_text()
		f.close()
		doc = codec.load_document(text)

	if doc == null:
		return false

	active_document = doc
	file_path = path
	is_dirty = false
	current_scope_id = ""
	_undo_stack.clear()
	_redo_stack.clear()
	selected_id = ""
	selected_type = ""
	var cur_sname: String = str(active_document.scene.get("name", "")).strip_edges()
	if cur_sname.is_empty() or cur_sname in ["Untitled Simulation", "Untitled Scene", "Untitled"]:
		var base := clean_file_basename(path)
		if not base.is_empty():
			active_document.scene["name"] = base.replace("_", " ").capitalize()
	repository.add_recent_scene(path, active_document.scene.get("name", ""), fmt_type, active_document.elements.size(), active_document.subgraphs.size())
	validate()
	scope_changed.emit("", "Root")
	document_loaded.emit(active_document)
	return true

func save_to_file(path: String = "", format_hint: String = "auto") -> bool:
	var target_path := path if not path.is_empty() else file_path
	if target_path.is_empty():
		return false

	if active_document != null:
		var cur_sname: String = str(active_document.scene.get("name", "")).strip_edges()
		if cur_sname.is_empty() or cur_sname in ["Untitled Simulation", "Untitled Scene", "Untitled"]:
			var base := clean_file_basename(target_path)
			if not base.is_empty():
				active_document.scene["name"] = base.replace("_", " ").capitalize()

	if target_path.ends_with(".simviz") or format_hint == "bundle":
		return save_to_bundle(target_path, true)

	var is_msgpack := (target_path.ends_with(".mp") or target_path.ends_with(".scenespec.mp") or format_hint == "msgpack")
	var codec := SceneCodec.new()

	if is_msgpack:
		var ok := codec.save_to_msgpack_file(active_document, target_path)
		if ok:
			file_path = target_path
			is_dirty = false
			clear_autosave(target_path)
			repository.add_recent_scene(target_path, active_document.scene.get("name", ""), "msgpack", active_document.elements.size(), active_document.subgraphs.size())
			document_saved.emit(target_path)
			return true
		return false

	# Canonical JSON with atomic multi-stage write & backup protection
	var text := codec.save_canonical_document(active_document, true)
	if text.is_empty():
		return false

	var tmp_path := target_path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.flush()
	f.close()

	var bak_path := target_path + ".bak"
	if FileAccess.file_exists(target_path):
		var err_bak := DirAccess.rename_absolute(target_path, bak_path)
		if err_bak != OK:
			DirAccess.remove_absolute(tmp_path)
			return false

	var err_rename := DirAccess.rename_absolute(tmp_path, target_path)
	if err_rename == OK:
		if FileAccess.file_exists(bak_path):
			DirAccess.remove_absolute(bak_path)
		file_path = target_path
		is_dirty = false
		clear_autosave(target_path)
		repository.add_recent_scene(target_path, active_document.scene.get("name", ""), "canonical_json", active_document.elements.size(), active_document.subgraphs.size())
		document_saved.emit(target_path)
		return true
	else:
		if FileAccess.file_exists(bak_path):
			DirAccess.rename_absolute(bak_path, target_path)
		DirAccess.remove_absolute(tmp_path)
		return false

func save_to_bundle(bundle_dir: String, shard_subgraphs: bool = true) -> bool:
	if bundle_dir.is_empty():
		return false
	if active_document != null:
		var cur_sname: String = str(active_document.scene.get("name", "")).strip_edges()
		if cur_sname.is_empty() or cur_sname in ["Untitled Simulation", "Untitled Scene", "Untitled"]:
			var base := clean_file_basename(bundle_dir)
			if not base.is_empty():
				active_document.scene["name"] = base.replace("_", " ").capitalize()
	if not repository.create_bundle_skeleton(bundle_dir, active_document.scene.get("name", "Untitled")):
		return false

	var codec := SceneCodec.new()
	var root_doc_dict: Dictionary = active_document.to_dict()

	if shard_subgraphs and not active_document.subgraphs.is_empty():
		var subgraphs_dir := bundle_dir.path_join("graph").path_join("subgraphs")
		DirAccess.make_dir_recursive_absolute(subgraphs_dir)
		for sub in active_document.subgraphs:
			if sub is SceneTypes.SceneSubgraph:
				var sub_path := subgraphs_dir.path_join(sub.id + ".scenespec")
				var sub_json := codec.save_to_canonical_json_string(sub.to_dict(), true)
				var sf := FileAccess.open(sub_path, FileAccess.WRITE)
				if sf != null:
					sf.store_string(sub_json)
					sf.flush()
					sf.close()

	var root_path := bundle_dir.path_join("graph").path_join("root.scenespec")
	var root_json := codec.save_to_canonical_json_string(root_doc_dict, true)
	var rf := FileAccess.open(root_path, FileAccess.WRITE)
	if rf == null:
		return false
	rf.store_string(root_json)
	rf.flush()
	rf.close()

	file_path = bundle_dir
	is_dirty = false
	clear_autosave(bundle_dir)
	repository.add_recent_scene(bundle_dir, active_document.scene.get("name", ""), "bundle", active_document.elements.size(), active_document.subgraphs.size())
	document_saved.emit(bundle_dir)
	return true

func load_from_bundle(bundle_dir: String) -> bool:
	var root_path := bundle_dir.path_join("graph").path_join("root.scenespec")
	if not FileAccess.file_exists(root_path):
		root_path = bundle_dir.path_join("root.scenespec")
	if not FileAccess.file_exists(root_path):
		return false

	var f := FileAccess.open(root_path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()

	var codec := SceneCodec.new()
	var doc = codec.load_document(text)
	if doc == null:
		return false

	var subgraphs_dir := bundle_dir.path_join("graph").path_join("subgraphs")
	if DirAccess.dir_exists_absolute(subgraphs_dir):
		var dir := DirAccess.open(subgraphs_dir)
		if dir != null:
			dir.list_dir_begin()
			var fn := dir.get_next()
			while not fn.is_empty():
				if not dir.current_is_dir() and fn.ends_with(".scenespec"):
					var sp := subgraphs_dir.path_join(fn)
					var sf := FileAccess.open(sp, FileAccess.READ)
					if sf != null:
						var st := sf.get_as_text()
						sf.close()
						var s_dict := codec.load_from_json_string(st)
						if not s_dict.is_empty():
							var sub_id := str(s_dict.get("id", ""))
							var found := false
							for existing_sub in doc.subgraphs:
								if existing_sub is SceneTypes.SceneSubgraph and existing_sub.id == sub_id:
									found = true
									break
							if not found:
								doc.subgraphs.append(SceneTypes.SceneSubgraph.from_dict(s_dict))
				fn = dir.get_next()
			dir.list_dir_end()

	active_document = doc
	file_path = bundle_dir
	is_dirty = false
	current_scope_id = ""
	_undo_stack.clear()
	_redo_stack.clear()
	selected_id = ""
	selected_type = ""
	var cur_sname: String = str(active_document.scene.get("name", "")).strip_edges()
	if cur_sname.is_empty() or cur_sname in ["Untitled Simulation", "Untitled Scene", "Untitled"]:
		var base := clean_file_basename(bundle_dir)
		if not base.is_empty():
			active_document.scene["name"] = base.replace("_", " ").capitalize()
	repository.add_recent_scene(bundle_dir, active_document.scene.get("name", ""), "bundle", active_document.elements.size(), active_document.subgraphs.size())
	validate()
	scope_changed.emit("", "Root")
	document_loaded.emit(active_document)
	return true

func merge_document(source_doc: Variant, position_offset: Vector3 = Vector3.ZERO, namespace_prefix: String = "") -> Dictionary:
	var src_doc: SceneTypes.SceneDocument
	if source_doc is SceneTypes.SceneDocument:
		src_doc = source_doc
	elif source_doc is Dictionary:
		src_doc = SceneTypes.SceneDocument.from_dict(source_doc)
	else:
		return {"error": "Invalid source document"}

	var prefix := namespace_prefix
	if prefix.is_empty():
		prefix = "m_" + str(src_doc.scene.get("id", "scene")).substr(0, 8) + "_"

	_record_undo()

	var existing_elem_ids := {}
	for e in active_document.elements:
		if e is SceneTypes.SceneElement:
			existing_elem_ids[e.id] = true

	var id_remap := {}
	var added_elements: Array[String] = []
	for e in src_doc.elements:
		if e is SceneTypes.SceneElement:
			var target_id: String = e.id
			if existing_elem_ids.has(target_id) or not namespace_prefix.is_empty():
				target_id = prefix + e.id
			id_remap[e.id] = target_id

			var new_elem: SceneTypes.SceneElement = e.clone()
			new_elem.id = target_id
			if new_elem.transform != null:
				new_elem.transform.position += position_offset
			active_document.elements.append(new_elem)
			added_elements.append(target_id)

	var added_connections: Array[String] = []
	for c in src_doc.connections:
		if c is SceneTypes.SceneConnection:
			var new_conn: SceneTypes.SceneConnection = c.clone()
			var target_conn_id: String = c.id
			if active_document.get_connection(target_conn_id) != null or not namespace_prefix.is_empty():
				target_conn_id = prefix + c.id
			new_conn.id = target_conn_id
			if id_remap.has(c.source_element):
				new_conn.source_element = id_remap[c.source_element]
			if id_remap.has(c.target_element):
				new_conn.target_element = id_remap[c.target_element]
			active_document.connections.append(new_conn)
			added_connections.append(target_conn_id)

	var added_subgraphs: Array[String] = []
	for s in src_doc.subgraphs:
		if s is SceneTypes.SceneSubgraph:
			var new_sub: SceneTypes.SceneSubgraph = s.clone()
			var target_sub_id: String = s.id
			if active_document.get_subgraph(target_sub_id) != null or not namespace_prefix.is_empty():
				target_sub_id = prefix + s.id
			new_sub.id = target_sub_id
			active_document.subgraphs.append(new_sub)
			added_subgraphs.append(target_sub_id)

	is_dirty = true
	validate()
	document_modified.emit()
	return {
		"added_elements": added_elements.size(),
		"added_connections": added_connections.size(),
		"added_subgraphs": added_subgraphs.size(),
		"prefix": prefix
	}

# ============================================================================
# Autosave & Crash Recovery Engine
# ============================================================================

func tick_autosave(delta: float) -> void:
	if not autosave_enabled or not is_dirty:
		return
	_autosave_timer += delta
	if _autosave_timer >= autosave_interval_sec:
		_autosave_timer = 0.0
		trigger_autosave()

func get_autosave_path(for_path: String = "") -> String:
	var target := for_path if not for_path.is_empty() else file_path
	if not target.is_empty():
		return target + ".autosave.json"
	var draft_id := str(active_document.scene.get("id", "draft")) if active_document != null else "draft"
	return "user://autosaves/untitled_" + draft_id + ".autosave.json"

func trigger_autosave() -> bool:
	if not is_dirty or active_document == null:
		return false
	var auto_path := get_autosave_path(file_path)
	var parent_dir := auto_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent_dir):
		DirAccess.make_dir_recursive_absolute(parent_dir)

	var codec := SceneCodec.new()
	var json_str := codec.save_canonical_document(active_document, true)
	if json_str.is_empty():
		return false

	var tmp_path := auto_path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(json_str)
	f.flush()
	f.close()

	if FileAccess.file_exists(auto_path):
		DirAccess.remove_absolute(auto_path)
	var err := DirAccess.rename_absolute(tmp_path, auto_path)
	if err == OK:
		last_autosave_time = Time.get_unix_time_from_system()
		last_autosave_path = auto_path
		autosave_completed.emit(auto_path, last_autosave_time)
		return true
	return false

func check_recovery_available(for_path: String) -> Dictionary:
	var auto_path := get_autosave_path(for_path)
	if not FileAccess.file_exists(auto_path):
		return {"available": false}

	var auto_mod := FileAccess.get_modified_time(auto_path)
	var file_mod: int = 0
	if FileAccess.file_exists(for_path):
		file_mod = FileAccess.get_modified_time(for_path)

	if auto_mod > file_mod:
		var f := FileAccess.open(auto_path, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var codec := SceneCodec.new()
			var auto_doc = codec.load_document(text)
			if auto_doc != null:
				return {
					"available": true,
					"autosave_path": auto_path,
					"autosave_time": auto_mod,
					"file_time": file_mod,
					"file_path": for_path,
					"scene_name": auto_doc.scene.get("name", "Untitled"),
					"element_count": auto_doc.elements.size(),
					"autosave_document": auto_doc
				}
	return {"available": false}

func recover_from_autosave(autosave_path: String) -> bool:
	if not FileAccess.file_exists(autosave_path):
		return false
	var f := FileAccess.open(autosave_path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()

	var codec := SceneCodec.new()
	var doc = codec.load_document(text)
	if doc == null:
		return false

	active_document = doc
	is_dirty = true
	validate()
	document_loaded.emit(active_document)
	return true

func clear_autosave(for_path: String = "") -> void:
	var auto_path := get_autosave_path(for_path)
	if FileAccess.file_exists(auto_path):
		DirAccess.remove_absolute(auto_path)

func select(id_val: String, type_val: String = "element") -> void:
	selected_id = id_val
	selected_type = type_val
	selected_port_id = ""
	if (type_val == "element" or type_val == "subgraph") and not id_val.is_empty():
		selected_elements = [id_val]
	else:
		selected_elements.clear()
	selection_changed.emit(selected_id, selected_type)

func get_selected_subgraph() -> SceneTypes.SceneSubgraph:
	if selected_type != "subgraph" or selected_id.is_empty():
		return null
	return get_subgraph(selected_id)

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

func rename_element(elem_id: String, new_name: String) -> bool:
	var elem := get_element(elem_id)
	if elem == null:
		return false
	var clean := new_name.strip_edges()
	if clean.is_empty() or clean == elem.name:
		return false
	_record_undo()
	elem.name = clean
	validate()
	document_modified.emit()
	return true

func rename_element_id(old_id: String, new_id: String) -> bool:
	if active_document == null:
		return false
	var clean_id := new_id.strip_edges()
	if clean_id.is_empty() or clean_id == old_id:
		return false
	for elem in active_document.elements:
		if elem.id == clean_id:
			return false
	for sub in active_document.subgraphs:
		if sub.id == clean_id:
			return false
	var target_elem := get_element(old_id)
	if target_elem == null:
		return false

	_record_undo()
	target_elem.id = clean_id

	for conn in active_document.connections:
		if conn.source_element == old_id:
			conn.source_element = clean_id
		if conn.target_element == old_id:
			conn.target_element = clean_id

	for sub in active_document.subgraphs:
		for i in range(sub.elements.size()):
			if sub.elements[i] == old_id:
				sub.elements[i] = clean_id

	if selected_id == old_id:
		selected_id = clean_id

	validate()
	document_modified.emit()
	return true

func rename_subgraph(sub_id: String, new_name: String) -> bool:
	var sub := get_subgraph(sub_id)
	if sub == null:
		return false
	var clean := new_name.strip_edges()
	if clean.is_empty() or clean == sub.name:
		return false
	_record_undo()
	sub.name = clean
	validate()
	document_modified.emit()
	return true

func set_scene_name(new_name: String) -> bool:
	if active_document == null:
		return false
	var clean := new_name.strip_edges()
	if clean.is_empty() or clean == active_document.scene.get("name", ""):
		return false
	_record_undo()
	active_document.scene["name"] = clean
	validate()
	document_modified.emit()
	return true

func set_scene_author(new_author: String) -> bool:
	if active_document == null:
		return false
	var clean := new_author.strip_edges()
	if clean == active_document.scene.get("author", ""):
		return false
	_record_undo()
	active_document.scene["author"] = clean
	validate()
	document_modified.emit()
	return true

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

func update_element_geometry_and_position(elem_id: String, new_dims: Vector3, new_pos: Vector3, orig_dims: Vector3 = Vector3.ZERO, orig_pos: Vector3 = Vector3.ZERO) -> bool:
	var elem := get_element(elem_id)
	if elem == null:
		return false
	if orig_dims != Vector3.ZERO and orig_pos != Vector3.ZERO:
		elem.geometry["dimensions"] = [orig_dims.x, orig_dims.y, orig_dims.z]
		elem.transform.position = Vector3(orig_pos.x, orig_pos.y, orig_pos.z)
		elem.editor.graph_position = Vector2(orig_pos.x * 20.0, orig_pos.y * 20.0)
	_record_undo()
	elem.geometry["dimensions"] = [max(0.1, new_dims.x), max(0.1, new_dims.y), max(0.05, new_dims.z)]
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

func add_connection_direct(id_val: String, src_elem: String, src_port: String, tgt_elem: String, tgt_port: String, kind: String = "flow") -> SceneTypes.SceneConnection:
	var conn := SceneTypes.SceneConnection.new()
	conn.id = id_val
	conn.source_element = src_elem
	conn.source_port = src_port
	conn.target_element = tgt_elem
	conn.target_port = tgt_port
	conn.link_type = kind
	add_connection(conn)
	return conn

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

# ============================================================================
# Phase 7D-10: Subgraphs, Groups, Templates & Hierarchical Scopes
# ============================================================================

func enter_subgraph_scope(sub_id: String) -> bool:
	var sub := get_subgraph(sub_id)
	if sub == null:
		return false
	current_scope_id = sub_id
	clear_selection()
	scope_changed.emit(current_scope_id, get_current_scope_name())
	return true

func exit_to_root_scope() -> void:
	current_scope_id = ""
	clear_selection()
	scope_changed.emit("", "Root")

func get_current_scope_name() -> String:
	if current_scope_id.is_empty():
		return "Root"
	var sub := get_subgraph(current_scope_id)
	return sub.name if sub != null else current_scope_id

func get_subgraph(sub_id: String) -> SceneTypes.SceneSubgraph:
	if active_document == null:
		return null
	for i in range(active_document.subgraphs.size()):
		var s = active_document.subgraphs[i]
		var sid: String = s.id if s is SceneTypes.SceneSubgraph else str(s.get("id", ""))
		if sid == sub_id:
			if not (s is SceneTypes.SceneSubgraph):
				s = SceneTypes.SceneSubgraph.from_dict(s)
				active_document.subgraphs[i] = s
			return s
	return null

func get_template(tmpl_id: String) -> SceneTypes.SceneSubgraph:
	if active_document == null:
		return null
	for s in active_document.subgraphs:
		var sub: SceneTypes.SceneSubgraph = s if s is SceneTypes.SceneSubgraph else SceneTypes.SceneSubgraph.from_dict(s)
		if sub.id == tmpl_id and sub.role == "template":
			return sub
	if tmpl_id == "queue_server_station":
		var built_in := SceneTypes.SceneSubgraph.new()
		built_in.id = "queue_server_station"
		built_in.name = "Queue-Server Workcell"
		built_in.role = "template"
		built_in.template_version = "1.0.0"
		built_in.exposed_ports = [
			{"id": "flow_in", "name": "Station Infeed", "kind": "flow", "direction": "input", "cardinality": "many", "target_element": "q_in", "target_port": "flow_in"},
			{"id": "flow_out", "name": "Station Outfeed", "kind": "flow", "direction": "output", "cardinality": "many", "target_element": "srv_core", "target_port": "flow_out"},
			{"id": "throughput", "name": "Cell Throughput", "kind": "metric", "direction": "output", "cardinality": "many", "target_element": "srv_core", "target_port": "utilization"}
		]
		built_in.set_extension("description", "Built-in modular workcell with queue buffer and processing server.")
		active_document.subgraphs.append(built_in)
		return built_in
	return null

func get_templates() -> Array:
	var list: Array = []
	if active_document == null:
		return list
	for s in active_document.subgraphs:
		var sub: SceneTypes.SceneSubgraph = s if s is SceneTypes.SceneSubgraph else SceneTypes.SceneSubgraph.from_dict(s)
		if sub.role == "template":
			list.append(sub)
	return list

func get_scoped_elements() -> Array:
	if active_document == null:
		return []
	if current_scope_id.is_empty():
		var child_elem_ids := {}
		for s in active_document.subgraphs:
			var sub: SceneTypes.SceneSubgraph = s if s is SceneTypes.SceneSubgraph else SceneTypes.SceneSubgraph.from_dict(s)
			for eid in sub.elements:
				child_elem_ids[str(eid)] = true
		var root_elems: Array = []
		for e in active_document.elements:
			if not child_elem_ids.has(e.id):
				root_elems.append(e)
		return root_elems
	else:
		var sub := get_subgraph(current_scope_id)
		if sub == null:
			return []
		var scoped: Array = []
		var elem_set := {}
		for eid in sub.elements:
			elem_set[str(eid)] = true
		for e in active_document.elements:
			if elem_set.has(e.id):
				scoped.append(e)
		return scoped

func get_scoped_subgraphs() -> Array:
	if active_document == null:
		return []
	if current_scope_id.is_empty():
		var list: Array = []
		for s in active_document.subgraphs:
			var sub: SceneTypes.SceneSubgraph = s if s is SceneTypes.SceneSubgraph else SceneTypes.SceneSubgraph.from_dict(s)
			if sub.role in ["compound", "group"]:
				list.append(sub)
		return list
	else:
		return []

func get_scoped_connections() -> Array:
	if active_document == null:
		return []
	if current_scope_id.is_empty():
		var scoped_elem_ids := {}
		for e in get_scoped_elements():
			scoped_elem_ids[e.id] = true
		for s in get_scoped_subgraphs():
			scoped_elem_ids[s.id] = true
		var list: Array = []
		for c in active_document.connections:
			if scoped_elem_ids.has(c.source_element) and scoped_elem_ids.has(c.target_element):
				list.append(c)
		return list
	else:
		var sub := get_subgraph(current_scope_id)
		if sub == null:
			return []
		var sub_conn_ids := {}
		for cid in sub.connections:
			sub_conn_ids[str(cid)] = true
		var list: Array = []
		for c in active_document.connections:
			if sub_conn_ids.has(c.id):
				list.append(c)
		return list

func add_subgraph(sub: SceneTypes.SceneSubgraph) -> void:
	_record_undo()
	active_document.subgraphs.append(sub)
	validate()
	subgraphs_modified.emit()
	document_modified.emit()

func remove_subgraph(sub_id: String) -> bool:
	if active_document == null:
		return false
	var found_idx := -1
	for i in range(active_document.subgraphs.size()):
		var s = active_document.subgraphs[i]
		var sid: String = s.id if s is SceneTypes.SceneSubgraph else str(s.get("id", ""))
		if sid == sub_id:
			found_idx = i
			break
	if found_idx < 0:
		return false

	_record_undo()
	var sub: SceneTypes.SceneSubgraph = active_document.subgraphs[found_idx] if active_document.subgraphs[found_idx] is SceneTypes.SceneSubgraph else SceneTypes.SceneSubgraph.from_dict(active_document.subgraphs[found_idx])
	active_document.subgraphs.remove_at(found_idx)

	# Clean up encapsulated elements and internal connections
	if sub != null:
		var del_elem_set := {}
		for eid in sub.elements:
			del_elem_set[str(eid)] = true
		for i in range(active_document.elements.size() - 1, -1, -1):
			if del_elem_set.has(active_document.elements[i].id):
				active_document.elements.remove_at(i)

		var del_conn_set := {}
		for cid in sub.connections:
			del_conn_set[str(cid)] = true
		for i in range(active_document.connections.size() - 1, -1, -1):
			var c: SceneTypes.SceneConnection = active_document.connections[i]
			if del_conn_set.has(c.id) or c.source_element == sub_id or c.target_element == sub_id or del_elem_set.has(c.source_element) or del_elem_set.has(c.target_element):
				active_document.connections.remove_at(i)
	else:
		for i in range(active_document.connections.size() - 1, -1, -1):
			var c: SceneTypes.SceneConnection = active_document.connections[i]
			if c.source_element == sub_id or c.target_element == sub_id:
				active_document.connections.remove_at(i)

	if selected_id == sub_id:
		clear_selection()

	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return true

func group_elements(elem_ids: Array, group_name: String = "", role: String = "group") -> SceneTypes.SceneSubgraph:
	if active_document == null or elem_ids.is_empty():
		return null

	_record_undo()

	var sum_x := 0.0
	var sum_y := 0.0
	var sum_z := 0.0
	var valid_count := 0
	var id_set := {}
	var min_x := 999999.0
	var min_y := 999999.0
	var max_x := -999999.0
	var max_y := -999999.0

	for eid in elem_ids:
		var elem := get_element(str(eid))
		if elem != null:
			id_set[str(eid)] = true
			var ex: float = float(elem.transform.position.x)
			var ey: float = float(elem.transform.position.y)
			var ez: float = float(elem.transform.position.z)
			var ew := 4.0
			var eh := 2.0
			if elem.geometry.has("dimensions") and elem.geometry["dimensions"] is Array and elem.geometry["dimensions"].size() >= 2:
				ew = float(elem.geometry["dimensions"][0])
				eh = float(elem.geometry["dimensions"][1])
			sum_x += ex
			sum_y += ey
			sum_z += ez
			min_x = min(min_x, ex)
			min_y = min(min_y, ey)
			max_x = max(max_x, ex + ew)
			max_y = max(max_y, ey + eh)
			valid_count += 1

	if valid_count == 0:
		return null

	var center := Vector3(sum_x / float(valid_count), sum_y / float(valid_count), sum_z / float(valid_count))
	var bbox_w: float = maxf(8.0, snapped(max_x - min_x + 1.0, 0.5))
	var bbox_h: float = maxf(4.0, snapped(max_y - min_y + 1.0, 0.5))

	var internal_conns: Array = []
	for c in active_document.connections:
		if id_set.has(c.source_element) and id_set.has(c.target_element):
			internal_conns.append(c.id)

	var base_id := "group" if role == "group" else "compound"
	var new_id := "%s_%02d" % [base_id, active_document.subgraphs.size() + 1]
	var existing_ids := {}
	for s in active_document.subgraphs:
		existing_ids[s.id if s is SceneTypes.SceneSubgraph else str(s.get("id", ""))] = true
	var counter := 1
	while existing_ids.has(new_id):
		counter += 1
		new_id = "%s_%02d" % [base_id, counter]

	var sub := SceneTypes.SceneSubgraph.new()
	sub.id = new_id
	sub.name = group_name if not group_name.is_empty() else new_id.capitalize()
	sub.role = role
	sub.transform.position = center
	sub.transform.scale = Vector3(bbox_w, bbox_h, 2.0)
	sub.editor.graph_position = Vector2(center.x * 20.0, center.y * 20.0)
	if sub.editor != null:
		sub.editor.extensions["dimensions"] = [bbox_w, bbox_h, 2.0]
	sub.elements = elem_ids.duplicate()
	sub.connections = internal_conns

	# Synthesize exposed boundary ports so external wires can attach cleanly to the subsystem block
	sub.exposed_ports = _synthesize_exposed_ports(elem_ids)

	# Rewire existing external connections targeting internal elements to the exposed ports of the subgraph
	var port_lookup := {} # "elem_id::port_id" -> exposed_port_id
	for ep in sub.exposed_ports:
		var exp_id: String = str(ep.get("id", ""))
		var telem: String = str(ep.get("target_element", ""))
		var tport: String = str(ep.get("target_port", ""))
		if not exp_id.is_empty() and not telem.is_empty() and not tport.is_empty():
			port_lookup["%s::%s" % [telem, tport]] = exp_id

	for conn in active_document.connections:
		var src_in := id_set.has(conn.source_element)
		var tgt_in := id_set.has(conn.target_element)
		if src_in and not tgt_in:
			var key := "%s::%s" % [conn.source_element, conn.source_port]
			if port_lookup.has(key):
				conn.source_element = sub.id
				conn.source_port = port_lookup[key]
		elif tgt_in and not src_in:
			var key := "%s::%s" % [conn.target_element, conn.target_port]
			if port_lookup.has(key):
				conn.target_element = sub.id
				conn.target_port = port_lookup[key]

	active_document.subgraphs.append(sub)
	select(sub.id, "subgraph")
	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return sub

func _synthesize_exposed_ports(elem_ids: Array) -> Array:
	var exposed: Array = []
	for eid in elem_ids:
		var elem := get_element(str(eid))
		if elem == null:
			continue
		for p in elem.input_ports:
			if p.kind == "flow":
				var exp_id := "%s_%s" % [elem.id, p.id]
				exposed.append({
					"id": exp_id,
					"name": "%s %s" % [elem.name, p.name],
					"kind": p.kind,
					"direction": "input",
					"data_type": p.data_type,
					"cardinality": p.cardinality,
					"target_element": elem.id,
					"target_port": p.id
				})
		for p in elem.output_ports:
			if p.kind == "flow":
				var exp_id := "%s_%s" % [elem.id, p.id]
				exposed.append({
					"id": exp_id,
					"name": "%s %s" % [elem.name, p.name],
					"kind": p.kind,
					"direction": "output",
					"data_type": p.data_type,
					"cardinality": p.cardinality,
					"target_element": elem.id,
					"target_port": p.id
				})
		for p in elem.metric_ports:
			var exp_id := "%s_%s" % [elem.id, p.id]
			exposed.append({
				"id": exp_id,
				"name": "%s %s" % [elem.name, p.name],
				"kind": "metric",
				"direction": "output",
				"data_type": p.data_type,
				"cardinality": p.cardinality,
				"target_element": elem.id,
				"target_port": p.id
			})
	return exposed

func ungroup(subgraph_id: String) -> bool:
	var sub := get_subgraph(subgraph_id)
	if sub == null or active_document == null:
		return false

	_record_undo()

	for i in range(active_document.subgraphs.size() - 1, -1, -1):
		var s = active_document.subgraphs[i]
		var sid: String = s.id if s is SceneTypes.SceneSubgraph else str(s.get("id", ""))
		if sid == subgraph_id:
			active_document.subgraphs.remove_at(i)
			break

	var port_map := {}
	for ep in sub.exposed_ports:
		var pid: String = str(ep.get("id", ep.get("port_id", "")))
		var telem: String = str(ep.get("target_element", ep.get("internal_element_id", "")))
		var tport: String = str(ep.get("target_port", ep.get("internal_port_id", "")))
		if not pid.is_empty() and not telem.is_empty() and not tport.is_empty():
			port_map[pid] = { "elem": telem, "port": tport }

	for conn in active_document.connections:
		if conn.source_element == subgraph_id and port_map.has(conn.source_port):
			conn.source_element = port_map[conn.source_port]["elem"]
			conn.source_port = port_map[conn.source_port]["port"]
		if conn.target_element == subgraph_id and port_map.has(conn.target_port):
			conn.target_element = port_map[conn.target_port]["elem"]
			conn.target_port = port_map[conn.target_port]["port"]

	clear_selection()
	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return true

func package_as_template(target_ids: Array, tmpl_id: String, tmpl_name: String, version: String = "1.0.0", description: String = "", custom_exposed_ports: Array = []) -> SceneTypes.SceneSubgraph:
	if active_document == null or target_ids.is_empty():
		return null

	_record_undo()

	var elem_ids: Array = []
	var internal_conn_ids: Array = []
	var exposed_ports: Array = []
	var bbox_w: float = 0.0
	var bbox_h: float = 0.0

	if target_ids.size() == 1 and get_subgraph(str(target_ids[0])) != null:
		var src_sub := get_subgraph(str(target_ids[0]))
		elem_ids = src_sub.elements.duplicate(true)
		internal_conn_ids = src_sub.connections.duplicate(true)
		exposed_ports = custom_exposed_ports if not custom_exposed_ports.is_empty() else src_sub.exposed_ports.duplicate(true)
		if src_sub.transform != null and src_sub.transform.scale.x > 0.1:
			bbox_w = float(src_sub.transform.scale.x)
			bbox_h = float(src_sub.transform.scale.y)
	else:
		elem_ids = target_ids.duplicate(true)
		var id_set := {}
		for eid in elem_ids:
			id_set[str(eid)] = true
		for c in active_document.connections:
			if id_set.has(c.source_element) and id_set.has(c.target_element):
				internal_conn_ids.append(c.id)
		exposed_ports = custom_exposed_ports if not custom_exposed_ports.is_empty() else _synthesize_exposed_ports(elem_ids)

	var proto_elems_data: Array = []
	var proto_conns_data: Array = []
	var min_px: float = 999999.0
	var min_py: float = 999999.0
	var max_px: float = -999999.0
	var max_py: float = -999999.0

	for eid in elem_ids:
		var elem := get_element(str(eid))
		if elem != null:
			proto_elems_data.append(elem.to_dict())
			var ex: float = float(elem.transform.position.x)
			var ey: float = float(elem.transform.position.y)
			var ew: float = 4.0
			var eh: float = 2.0
			if elem.geometry.has("dimensions") and elem.geometry["dimensions"] is Array and elem.geometry["dimensions"].size() >= 2:
				ew = float(elem.geometry["dimensions"][0])
				eh = float(elem.geometry["dimensions"][1])
			min_px = min(min_px, ex)
			min_py = min(min_py, ey)
			max_px = max(max_px, ex + ew)
			max_py = max(max_py, ey + eh)

	for cid in internal_conn_ids:
		for c in active_document.connections:
			if c.id == str(cid):
				proto_conns_data.append(c.to_dict())
				break

	if bbox_w <= 1.0 or bbox_h <= 1.0:
		if min_px < 900000.0:
			bbox_w = maxf(8.0, snapped(max_px - min_px + 1.0, 0.5))
			bbox_h = maxf(4.0, snapped(max_py - min_py + 1.0, 0.5))
		else:
			bbox_w = 8.0
			bbox_h = 4.0

	var tmpl := SceneTypes.SceneSubgraph.new()
	tmpl.id = tmpl_id
	tmpl.name = tmpl_name
	tmpl.role = "template"
	tmpl.template_version = version
	tmpl.elements = elem_ids
	tmpl.connections = internal_conn_ids
	tmpl.exposed_ports = exposed_ports
	tmpl.transform.scale = Vector3(bbox_w, bbox_h, 2.0)
	if tmpl.editor != null:
		tmpl.editor.extensions["dimensions"] = [bbox_w, bbox_h, 2.0]
	tmpl.set_extension("dimensions", [bbox_w, bbox_h, 2.0])
	if min_px < 900000.0:
		tmpl.set_extension("base_anchor", [min_px, min_py, 0.0])
	tmpl.set_extension("prototype_elements", proto_elems_data)
	tmpl.set_extension("prototype_connections", proto_conns_data)
	if not description.is_empty():
		tmpl.set_extension("description", description)

	var replaced := false
	for i in range(active_document.subgraphs.size()):
		var s = active_document.subgraphs[i]
		var sid: String = s.id if s is SceneTypes.SceneSubgraph else str(s.get("id", ""))
		if sid == tmpl_id:
			active_document.subgraphs[i] = tmpl
			replaced = true
			break
	if not replaced:
		active_document.subgraphs.append(tmpl)

	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return tmpl

func instantiate_template(template_id: String, instance_name: String = "", world_pos: Vector3 = Vector3.ZERO, overrides: Dictionary = {}) -> SceneTypes.SceneSubgraph:
	if active_document == null:
		return null

	var tmpl := get_template(template_id)
	if tmpl == null:
		return null

	_record_undo()

	var base_id := instance_name.to_snake_case() if not instance_name.is_empty() else template_id.replace("tpl_", "")
	if base_id.is_empty():
		base_id = "station"
	var new_id := base_id
	var counter := 1
	var existing_ids := {}
	for s in active_document.subgraphs:
		var sid: String = s.id if s is SceneTypes.SceneSubgraph else str(s.get("id", ""))
		existing_ids[sid] = true
	for e in active_document.elements:
		existing_ids[e.id] = true

	while existing_ids.has(new_id):
		counter += 1
		new_id = "%s_%02d" % [base_id, counter]

	var inst := SceneTypes.SceneSubgraph.new()
	inst.id = new_id
	inst.name = instance_name if not instance_name.is_empty() else new_id.capitalize()
	inst.role = "compound"
	inst.template_id = template_id
	inst.template_version = tmpl.template_version
	inst.transform.position = world_pos
	inst.editor.graph_position = Vector2(world_pos.x * 20.0, world_pos.y * 20.0)
	inst.exposed_ports = tmpl.exposed_ports.duplicate(true)
	inst.parameter_overrides = overrides.duplicate(true)
	inst.elements = []
	inst.connections = []

	# Gather prototype elements to clone
	var proto_elements_list: Array = []
	var proto_conns_list: Array = []

	var ext_protos = tmpl.get_extension("prototype_elements", [])
	if ext_protos is Array and not ext_protos.is_empty():
		for pdata in ext_protos:
			if pdata is Dictionary:
				proto_elements_list.append(SceneTypes.SceneElement.from_dict(pdata))
			elif pdata is SceneTypes.SceneElement:
				proto_elements_list.append(pdata)

	var ext_conns = tmpl.get_extension("prototype_connections", [])
	if ext_conns is Array and not ext_conns.is_empty():
		for cdata in ext_conns:
			if cdata is Dictionary:
				proto_conns_list.append(SceneTypes.SceneConnection.from_dict(cdata))
			elif cdata is SceneTypes.SceneConnection:
				proto_conns_list.append(cdata)

	# Fallback to looking up tmpl.elements in active_document if not serialized in extensions
	if proto_elements_list.is_empty():
		for eid in tmpl.elements:
			var elem := get_element(str(eid))
			if elem != null:
				proto_elements_list.append(elem)

	if proto_conns_list.is_empty():
		for cid in tmpl.connections:
			for c in active_document.connections:
				if c.id == str(cid):
					proto_conns_list.append(c)
					break

	# Special fallback for built-in queue_server_station if empty
	if proto_elements_list.is_empty() and template_id == "queue_server_station":
		var q_elem := SceneTypes.SceneElement.new()
		q_elem.id = "q_in"
		q_elem.name = "Infeed Queue"
		q_elem.kind = "queue"
		q_elem.transform.position = Vector3(0, 0, 0)
		q_elem.geometry["dimensions"] = [4.0, 2.0, 1.0]
		var q_in_p := SceneTypes.ScenePort.new()
		q_in_p.id = "flow_in"
		q_in_p.name = "Flow In"
		q_in_p.kind = "flow"
		q_in_p.direction = "input"
		var q_out_p := SceneTypes.ScenePort.new()
		q_out_p.id = "flow_out"
		q_out_p.name = "Flow Out"
		q_out_p.kind = "flow"
		q_out_p.direction = "output"
		q_elem.input_ports = [q_in_p]
		q_elem.output_ports = [q_out_p]
		q_elem.properties = {"capacity": 50, "discipline": "fifo"}

		var srv_elem := SceneTypes.SceneElement.new()
		srv_elem.id = "srv_core"
		srv_elem.name = "Process Server"
		srv_elem.kind = "server"
		srv_elem.transform.position = Vector3(6, 0, 0)
		srv_elem.geometry["dimensions"] = [4.0, 2.0, 1.0]
		var s_in_p := SceneTypes.ScenePort.new()
		s_in_p.id = "flow_in"
		s_in_p.name = "Flow In"
		s_in_p.kind = "flow"
		s_in_p.direction = "input"
		var s_out_p := SceneTypes.ScenePort.new()
		s_out_p.id = "flow_out"
		s_out_p.name = "Flow Out"
		s_out_p.kind = "flow"
		s_out_p.direction = "output"
		var s_met_p := SceneTypes.ScenePort.new()
		s_met_p.id = "utilization"
		s_met_p.name = "Utilization"
		s_met_p.kind = "metric"
		s_met_p.direction = "output"
		srv_elem.input_ports = [s_in_p]
		srv_elem.output_ports = [s_out_p]
		srv_elem.metric_ports = [s_met_p]
		srv_elem.properties = {"service_time": 2.5, "capacity": 1}

		proto_elements_list = [q_elem, srv_elem]

		var internal_c := SceneTypes.SceneConnection.new()
		internal_c.id = "c_q_to_srv"
		internal_c.source_element = "q_in"
		internal_c.source_port = "flow_out"
		internal_c.target_element = "srv_core"
		internal_c.target_port = "flow_in"
		internal_c.link_type = "flow"
		proto_conns_list = [internal_c]

	# Compute base anchor for relative placement
	var base_anchor: Vector3 = Vector3.ZERO
	var has_anchor: bool = false
	var ext_anchor = tmpl.get_extension("base_anchor", null)
	if ext_anchor is Array and ext_anchor.size() >= 2:
		base_anchor = Vector3(float(ext_anchor[0]), float(ext_anchor[1]), 0.0)
		has_anchor = true
	else:
		var min_x: float = 999999.0
		var min_y: float = 999999.0
		for p_elem in proto_elements_list:
			min_x = min(min_x, float(p_elem.transform.position.x))
			min_y = min(min_y, float(p_elem.transform.position.y))
		if min_x < 900000.0:
			base_anchor = Vector3(min_x, min_y, 0.0)
			has_anchor = true

	# Clone elements into active document
	var elem_map: Dictionary = {} # proto.id -> new_eid
	var instantiated_elem_ids: Array = []

	for p_elem in proto_elements_list:
		var clone: SceneTypes.SceneElement = p_elem.clone()
		var clean_proto_id: String = p_elem.id.replace("tpl_", "")
		var new_eid := "%s_%s" % [new_id, clean_proto_id]
		var eid_counter := 1
		while existing_ids.has(new_eid):
			eid_counter += 1
			new_eid = "%s_%s_%02d" % [new_id, clean_proto_id, eid_counter]
		existing_ids[new_eid] = true

		clone.id = new_eid
		clone.name = "%s %s" % [inst.name, p_elem.name]
		var rel_pos: Vector3 = (p_elem.transform.position - base_anchor) if has_anchor else p_elem.transform.position
		clone.transform.position = world_pos + rel_pos
		clone.editor.graph_position = Vector2(clone.transform.position.x * 20.0, clone.transform.position.y * 20.0)

		# Apply overrides
		for k in overrides.keys():
			var sk := str(k)
			if sk.begins_with(p_elem.id + "."):
				var prop_name := sk.substr(p_elem.id.length() + 1)
				clone.properties[prop_name] = overrides[k]
			elif sk == p_elem.id and overrides[k] is Dictionary:
				for p in overrides[k].keys():
					clone.properties[p] = overrides[k][p]

		active_document.elements.append(clone)
		instantiated_elem_ids.append(new_eid)
		elem_map[p_elem.id] = new_eid

	# Clone internal connections
	var instantiated_conn_ids: Array = []
	for p_conn in proto_conns_list:
		if elem_map.has(p_conn.source_element) and elem_map.has(p_conn.target_element):
			var conn_clone: SceneTypes.SceneConnection = p_conn.clone()
			var clean_cid: String = p_conn.id.replace("tpl_", "")
			var new_cid := "%s_%s" % [new_id, clean_cid]
			var cid_counter := 1
			while existing_ids.has(new_cid):
				cid_counter += 1
				new_cid = "%s_%s_%02d" % [new_id, clean_cid, cid_counter]
			existing_ids[new_cid] = true

			conn_clone.id = new_cid
			conn_clone.source_element = elem_map[p_conn.source_element]
			conn_clone.target_element = elem_map[p_conn.target_element]
			active_document.connections.append(conn_clone)
			instantiated_conn_ids.append(new_cid)

	# Remap exposed ports targets to new cloned elements
	for ep in inst.exposed_ports:
		var orig_telem: String = str(ep.get("target_element", ep.get("internal_element_id", "")))
		if elem_map.has(orig_telem):
			ep["target_element"] = elem_map[orig_telem]
			if ep.has("internal_element_id"):
				ep["internal_element_id"] = elem_map[orig_telem]

	inst.elements = instantiated_elem_ids
	inst.connections = instantiated_conn_ids

	# Set compound bounding dimensions
	var bbox_w: float = 8.0
	var bbox_h: float = 4.0
	var ext_dims = tmpl.get_extension("dimensions", null)
	if ext_dims is Array and ext_dims.size() >= 2:
		bbox_w = float(ext_dims[0])
		bbox_h = float(ext_dims[1])
	elif tmpl.transform != null and tmpl.transform.scale.x > 0.1:
		bbox_w = float(tmpl.transform.scale.x)
		bbox_h = float(tmpl.transform.scale.y)

	inst.transform.scale = Vector3(bbox_w, bbox_h, 2.0)
	if inst.editor != null:
		inst.editor.extensions["dimensions"] = [bbox_w, bbox_h, 2.0]

	active_document.subgraphs.append(inst)
	select(inst.id, "subgraph")
	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return inst

func detach_subgraph(subgraph_id: String) -> bool:
	var sub := get_subgraph(subgraph_id)
	if sub == null or sub.role != "compound" or sub.template_id == null or active_document == null:
		return false

	var tmpl := get_template(str(sub.template_id))
	if tmpl == null:
		return false

	_record_undo()

	# If the compound instance already has its elements instantiated:
	if not sub.elements.is_empty():
		for eid in sub.elements:
			var elem := get_element(str(eid))
			if elem == null:
				continue
			for k in sub.parameter_overrides.keys():
				var sk := str(k)
				if sk.begins_with("tpl_"):
					var clean_k := sk.replace("tpl_", "")
					if elem.id.ends_with("_" + clean_k.split(".")[0]):
						var prop := clean_k.substr(clean_k.find(".") + 1)
						elem.properties[prop] = sub.parameter_overrides[k]
				elif sk.contains("."):
					var parts := sk.split(".")
					if elem.id.ends_with("_" + parts[0]):
						elem.properties[parts[1]] = sub.parameter_overrides[k]

		for ep in sub.exposed_ports:
			var exp_id: String = str(ep.get("id", ep.get("port_id", "")))
			var telem: String = str(ep.get("target_element", ep.get("internal_element_id", "")))
			var tport: String = str(ep.get("target_port", ep.get("internal_port_id", "")))
			if not exp_id.is_empty() and not telem.is_empty() and not tport.is_empty():
				for conn in active_document.connections:
					if conn.source_element == subgraph_id and conn.source_port == exp_id:
						conn.source_element = telem
						conn.source_port = tport
					if conn.target_element == subgraph_id and conn.target_port == exp_id:
						conn.target_element = telem
						conn.target_port = tport

		sub.role = "group"
		sub.template_id = null
		sub.template_version = null
		sub.exposed_ports = []
		sub.parameter_overrides = {}

		select(sub.id, "subgraph")
		validate()
		subgraphs_modified.emit()
		document_modified.emit()
		return true

	# Fallback if sub.elements was empty (legacy fixtures):
	var elem_map := {}
	var created_elem_ids: Array = []
	for proto_id in tmpl.elements:
		var proto_elem := get_element(str(proto_id))
		if proto_elem == null:
			continue
		var clone: SceneTypes.SceneElement = proto_elem.clone()
		var new_eid := "%s_%s" % [subgraph_id, proto_elem.id.replace("tpl_", "")]
		clone.id = new_eid
		clone.name = "%s %s" % [sub.name, proto_elem.name]
		clone.transform.position = sub.transform.position + proto_elem.transform.position
		clone.editor.graph_position = Vector2(clone.transform.position.x * 20.0, clone.transform.position.y * 20.0)

		for key in sub.parameter_overrides.keys():
			var sk := str(key)
			if sk.begins_with(proto_elem.id + "."):
				var prop_name := sk.substr(proto_elem.id.length() + 1)
				clone.properties[prop_name] = sub.parameter_overrides[key]
			elif sk == proto_elem.id and sub.parameter_overrides[key] is Dictionary:
				for p in sub.parameter_overrides[key].keys():
					clone.properties[p] = sub.parameter_overrides[key][p]

		active_document.elements.append(clone)
		created_elem_ids.append(new_eid)
		elem_map[proto_elem.id] = new_eid

	for conn_id in tmpl.connections:
		var target_conn: SceneTypes.SceneConnection = null
		for c in active_document.connections:
			if c.id == str(conn_id):
				target_conn = c
				break
		if target_conn != null and elem_map.has(target_conn.source_element) and elem_map.has(target_conn.target_element):
			var conn_clone: SceneTypes.SceneConnection = target_conn.clone()
			conn_clone.id = "%s_%s" % [subgraph_id, target_conn.id.replace("tpl_", "")]
			conn_clone.source_element = elem_map[target_conn.source_element]
			conn_clone.target_element = elem_map[target_conn.target_element]
			active_document.connections.append(conn_clone)

	for ep in sub.exposed_ports:
		var pid: String = str(ep.get("id", ep.get("port_id", "")))
		var telem: String = str(ep.get("target_element", ep.get("internal_element_id", "")))
		var tport: String = str(ep.get("target_port", ep.get("internal_port_id", "")))
		if elem_map.has(telem):
			var actual_eid: String = elem_map[telem]
			for conn in active_document.connections:
				if conn.source_element == subgraph_id and conn.source_port == pid:
					conn.source_element = actual_eid
					conn.source_port = tport
				if conn.target_element == subgraph_id and conn.target_port == pid:
					conn.target_element = actual_eid
					conn.target_port = tport

	sub.role = "group"
	sub.template_id = null
	sub.template_version = null
	sub.elements = created_elem_ids
	sub.exposed_ports = []
	sub.parameter_overrides = {}

	select(sub.id, "subgraph")
	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return true

func set_subgraph_position(sub_id: String, new_pos: Vector3) -> bool:
	var sub := get_subgraph(sub_id)
	if sub == null:
		return false
	_record_undo()
	var delta_pos: Vector3 = new_pos - sub.transform.position
	sub.transform.position = new_pos
	sub.editor.graph_position = Vector2(new_pos.x * 20.0, new_pos.y * 20.0)

	if delta_pos.length_squared() > 0.0001:
		for eid in sub.elements:
			var elem := get_element(str(eid))
			if elem != null:
				elem.transform.position += delta_pos
				elem.editor.graph_position = Vector2(elem.transform.position.x * 20.0, elem.transform.position.y * 20.0)

	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return true

func set_subgraph_dimensions(sub_id: String, new_dims: Vector3) -> bool:
	var sub := get_subgraph(sub_id)
	if sub == null:
		return false
	_record_undo()
	var dims := Vector3(max(1.0, new_dims.x), max(1.0, new_dims.y), max(0.1, new_dims.z))
	sub.transform.scale = dims
	if sub.editor != null:
		sub.editor.extensions["dimensions"] = [dims.x, dims.y, dims.z]
	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return true

func update_subgraph_geometry_and_position(sub_id: String, new_dims: Vector3, new_pos: Vector3, orig_dims: Vector3 = Vector3.ZERO, orig_pos: Vector3 = Vector3.ZERO) -> bool:
	var sub := get_subgraph(sub_id)
	if sub == null:
		return false
	if orig_dims != Vector3.ZERO and orig_pos != Vector3.ZERO:
		sub.transform.scale = orig_dims
		if sub.editor != null:
			sub.editor.extensions["dimensions"] = [orig_dims.x, orig_dims.y, orig_dims.z]
		sub.transform.position = Vector3(orig_pos.x, orig_pos.y, orig_pos.z)
		sub.editor.graph_position = Vector2(orig_pos.x * 20.0, orig_pos.y * 20.0)
	_record_undo()
	var dims := Vector3(max(1.0, new_dims.x), max(1.0, new_dims.y), max(0.1, new_dims.z))
	sub.transform.scale = dims
	if sub.editor != null:
		sub.editor.extensions["dimensions"] = [dims.x, dims.y, dims.z]
	var delta_pos: Vector3 = Vector3(new_pos.x, new_pos.y, max(0.0, new_pos.z)) - sub.transform.position
	sub.transform.position = Vector3(new_pos.x, new_pos.y, max(0.0, new_pos.z))
	sub.editor.graph_position = Vector2(new_pos.x * 20.0, new_pos.y * 20.0)

	if delta_pos.length_squared() > 0.0001:
		for eid in sub.elements:
			var elem := get_element(str(eid))
			if elem != null:
				elem.transform.position += delta_pos
				elem.editor.graph_position = Vector2(elem.transform.position.x * 20.0, elem.transform.position.y * 20.0)

	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return true

func set_subgraph_override(sub_id: String, target_elem_id: String, prop_key: String = "", value: Variant = null) -> bool:
	var sub := get_subgraph(sub_id)
	if sub == null:
		return false
	_record_undo()
	var full_key := target_elem_id
	if not prop_key.is_empty():
		full_key = "%s.%s" % [target_elem_id, prop_key]
	sub.parameter_overrides[full_key] = value

	if not prop_key.is_empty():
		var clean_target: String = target_elem_id.replace("tpl_", "")
		for eid in sub.elements:
			var sid: String = str(eid)
			if sid.ends_with("_" + clean_target) or sid == target_elem_id or sid.ends_with("_" + target_elem_id):
				var elem := get_element(sid)
				if elem != null:
					elem.properties[prop_key] = value
					break

	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return true

func expose_subgraph_port(sub_id: String, port_def: Dictionary) -> bool:
	var sub := get_subgraph(sub_id)
	if sub == null:
		return false
	_record_undo()
	sub.exposed_ports.append(port_def.duplicate(true))
	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return true

func remove_subgraph_port(sub_id: String, port_id: String) -> bool:
	var sub := get_subgraph(sub_id)
	if sub == null:
		return false
	_record_undo()
	for i in range(sub.exposed_ports.size() - 1, -1, -1):
		var ep: Dictionary = sub.exposed_ports[i]
		if ep.get("id", ep.get("port_id", "")) == port_id:
			sub.exposed_ports.remove_at(i)
			break
	for i in range(active_document.connections.size() - 1, -1, -1):
		var c: SceneTypes.SceneConnection = active_document.connections[i]
		if (c.source_element == sub_id and c.source_port == port_id) or \
		   (c.target_element == sub_id and c.target_port == port_id):
			active_document.connections.remove_at(i)

	validate()
	subgraphs_modified.emit()
	document_modified.emit()
	return true
