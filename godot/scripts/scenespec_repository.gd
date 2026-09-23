# scenespec_repository.gd
# Manages Recent Projects, Template Repository, and SimViz Project Bundle indexing.
class_name SimVizSceneRepository
extends RefCounted

const RECENT_PROJECTS_PATH := "user://recent_projects.json"
const USER_TEMPLATES_DIR := "user://templates"
const MAX_RECENT_ITEMS := 20

const SCENE_TYPES := preload("res://scripts/scenespec_types.gd")
const SCENE_CODEC := preload("res://scripts/scenespec_codec.gd")

var _codec := SCENE_CODEC.new()

# ============================================================================
# Recent Projects Management
# ============================================================================

func add_recent_scene(path: String, name: String, format_type: String = "canonical_json", elem_count: int = 0, sub_count: int = 0) -> void:
	if path.is_empty():
		return
	var recents: Array = get_recent_scenes()
	var filtered: Array = []
	for item in recents:
		if item is Dictionary and str(item.get("path", "")) != path:
			filtered.append(item)

	var entry := {
		"path": path,
		"name": name if not name.is_empty() else path.get_file().get_basename(),
		"format_type": format_type,
		"elem_count": elem_count,
		"sub_count": sub_count,
		"timestamp": Time.get_unix_time_from_system()
	}
	filtered.push_front(entry)

	while filtered.size() > MAX_RECENT_ITEMS:
		filtered.pop_back()

	_save_recent_projects(filtered)

func get_recent_scenes() -> Array:
	if not FileAccess.file_exists(RECENT_PROJECTS_PATH):
		return []
	var f := FileAccess.open(RECENT_PROJECTS_PATH, FileAccess.READ)
	if f == null:
		return []
	var text := f.get_as_text()
	f.close()

	var json := JSON.new()
	if json.parse(text) == OK and json.data is Array:
		return json.data
	return []

func clear_recent_scenes() -> void:
	if FileAccess.file_exists(RECENT_PROJECTS_PATH):
		DirAccess.remove_absolute(RECENT_PROJECTS_PATH)

func _save_recent_projects(items: Array) -> void:
	var tmp_path := RECENT_PROJECTS_PATH + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(items, "  "))
	f.flush()
	f.close()

	if FileAccess.file_exists(RECENT_PROJECTS_PATH):
		DirAccess.remove_absolute(RECENT_PROJECTS_PATH)
	DirAccess.rename_absolute(tmp_path, RECENT_PROJECTS_PATH)

# ============================================================================
# Template Repository Management
# ============================================================================

func save_template_to_repository(subgraph: Variant, category: String = "Custom") -> String:
	if subgraph == null:
		return ""
	var sub_dict: Dictionary = {}
	var sub_id: String = ""
	if subgraph.has_method("to_dict"):
		sub_dict = subgraph.to_dict()
		sub_id = str(subgraph.get("id"))
	elif subgraph is Dictionary:
		sub_dict = subgraph
		sub_id = str(subgraph.get("id", "template"))

	if sub_id.is_empty():
		sub_id = "template_" + str(Time.get_ticks_msec())

	var dir_path := USER_TEMPLATES_DIR.path_join(category)
	DirAccess.make_dir_recursive_absolute(dir_path)

	var target_file := dir_path.path_join(sub_id + ".scenespec")
	var json_str := _codec.save_to_canonical_json_string(sub_dict, true)

	var f := FileAccess.open(target_file, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(json_str)
	f.flush()
	f.close()
	return target_file

func list_repository_templates() -> Array:
	var results: Array = []
	if not DirAccess.dir_exists_absolute(USER_TEMPLATES_DIR):
		return results

	var dir := DirAccess.open(USER_TEMPLATES_DIR)
	if dir == null:
		return results

	dir.list_dir_begin()
	var category_name := dir.get_next()
	while not category_name.is_empty():
		if not category_name.begins_with("."):
			var cat_dir_path := USER_TEMPLATES_DIR.path_join(category_name)
			if DirAccess.dir_exists_absolute(cat_dir_path):
				var cat_dir := DirAccess.open(cat_dir_path)
				if cat_dir != null:
					cat_dir.list_dir_begin()
					var file_name := cat_dir.get_next()
					while not file_name.is_empty():
						if not file_name.begins_with(".") and file_name.ends_with(".scenespec"):
							var full_path := cat_dir_path.path_join(file_name)
							if FileAccess.file_exists(full_path):
								var t_meta := _read_template_meta(full_path, category_name)
								if not t_meta.is_empty():
									results.append(t_meta)
						file_name = cat_dir.get_next()
					cat_dir.list_dir_end()
		category_name = dir.get_next()
	dir.list_dir_end()
	return results

func load_repository_template(template_id: String) -> SCENE_TYPES.SceneSubgraph:
	var all_templates := list_repository_templates()
	for t in all_templates:
		if str(t.get("id", "")) == template_id:
			var path: String = str(t.get("path", ""))
			if FileAccess.file_exists(path):
				var f := FileAccess.open(path, FileAccess.READ)
				if f != null:
					var text := f.get_as_text()
					f.close()
					var dict := _codec.load_from_json_string(text)
					if not dict.is_empty():
						return SCENE_TYPES.SceneSubgraph.from_dict(dict)
	return null

func _read_template_meta(path: String, category: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var dict := _codec.load_from_json_string(text)
	if dict.is_empty():
		return {}

	var elems = dict.get("elements", dict.get("internal_elements", []))
	return {
		"id": str(dict.get("id", path.get_file().get_basename())),
		"name": str(dict.get("name", path.get_file().get_basename())),
		"category": category,
		"path": path,
		"elements_count": elems.size() if elems is Array else 0,
		"interface_ports": dict.get("interface_ports", [])
	}

# ============================================================================
# SimViz Project Bundle Directory Operations
# ============================================================================

func create_bundle_skeleton(bundle_dir: String, project_name: String) -> bool:
	DirAccess.make_dir_recursive_absolute(bundle_dir)
	DirAccess.make_dir_recursive_absolute(bundle_dir.path_join("graph"))
	DirAccess.make_dir_recursive_absolute(bundle_dir.path_join("graph/subgraphs"))
	DirAccess.make_dir_recursive_absolute(bundle_dir.path_join("data"))
	DirAccess.make_dir_recursive_absolute(bundle_dir.path_join("assets"))
	DirAccess.make_dir_recursive_absolute(bundle_dir.path_join("runs"))

	var proj_meta := {
		"format_version": "1.0.0",
		"project_id": project_name.to_lower().replace(" ", "_"),
		"name": project_name,
		"created_at": Time.get_unix_time_from_system(),
		"root_graph": "graph/root.scenespec",
		"data_directory": "data",
		"assets_directory": "assets",
		"runs_directory": "runs"
	}
	var meta_file := bundle_dir.path_join("project.json")
	var f := FileAccess.open(meta_file, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(proj_meta, "  "))
	f.close()
	return true

func list_bundle_datasets(bundle_dir: String) -> Array:
	var datasets: Array = []
	var data_dir_path := bundle_dir.path_join("data")
	if not DirAccess.dir_exists_absolute(data_dir_path):
		return datasets

	var dir := DirAccess.open(data_dir_path)
	if dir == null:
		return datasets

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and not file_name.begins_with("."):
			var full_path := data_dir_path.path_join(file_name)
			var ext := file_name.get_extension().to_lower()
			var format_desc := ext.to_upper()
			if ext == "arrow" or ext == "feather":
				format_desc = "Apache Arrow (Columnar)"
			elif ext == "parquet":
				format_desc = "Apache Parquet (Compressed)"
			elif ext == "h5" or ext == "hdf5":
				format_desc = "HDF5 (Tensor/Matrix)"
			elif ext == "csv":
				format_desc = "CSV (Tabular)"

			datasets.append({
				"file_name": file_name,
				"uri": "data://" + file_name,
				"format": format_desc,
				"path": full_path,
				"size_bytes": FileAccess.get_file_as_bytes(full_path).size() if FileAccess.file_exists(full_path) else 0
			})
		file_name = dir.get_next()
	dir.list_dir_end()
	return datasets
