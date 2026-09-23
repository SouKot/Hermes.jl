class_name SimVizSceneSpecCodec
extends RefCounted

const PROTOCOL_CODEC = preload("res://scripts/protocol_codec.gd")
const SCENE_TYPES = preload("res://scripts/scenespec_types.gd")
const SCENE_VALIDATOR = preload("res://scripts/scenespec_validator.gd")

var _codec = PROTOCOL_CODEC.new()

func load_from_json_string(text: String) -> Dictionary:
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("SceneSpec JSON parse error: %s at line %d" % [json.get_error_message(), json.get_error_line()])
		return {}
	if not json.data is Dictionary:
		push_error("SceneSpec JSON root is not an object: %s" % typeof(json.data))
		return {}
	return json.data

func save_to_json_string(spec: Dictionary, pretty: bool = true) -> String:
	var indent := "  " if pretty else ""
	return JSON.stringify(spec, indent, false)

func decode_msgpack(bytes: PackedByteArray) -> Dictionary:
	var raw = _codec.decode(bytes)
	if not raw is Dictionary:
		push_error("SceneSpec MessagePack root is not a map")
		return {}
	return raw

func encode_msgpack(spec: Dictionary) -> PackedByteArray:
	return _codec.encode(spec)

func load_document(text: String) -> RefCounted:
	var dict := load_from_json_string(text)
	if dict.is_empty():
		return null
	return SCENE_TYPES.SceneDocument.from_dict(dict)

func save_document(doc: RefCounted, pretty: bool = true) -> String:
	if doc == null or not doc.has_method("to_dict"):
		return ""
	return save_to_json_string(doc.to_dict(), pretty)

const ROOT_CANONICAL_KEYS := [
	"spec_version", "scene", "simulation", "abm_config", "spatial",
	"elements", "connections", "subgraphs", "overlays", "validation_metadata",
	"extensions", "editor"
]

const ELEMENT_CANONICAL_KEYS := [
	"id", "name", "type_name", "category", "level_id", "transform",
	"spatial", "process", "display", "extensions"
]

const CONNECTION_CANONICAL_KEYS := [
	"id", "source_element", "source_port", "target_element", "target_port",
	"link_type", "enabled", "ordering", "condition", "latency", "capacity", "extensions"
]

const SUBGRAPH_CANONICAL_KEYS := [
	"id", "name", "description", "interface_ports", "elements", "connections",
	"internal_elements", "internal_connections", "external_ref", "extensions"
]

const TRANSFORM_CANONICAL_KEYS := [
	"position", "rotation", "rotation_deg", "scale"
]

func canonicalize_float(f: float) -> float:
	if is_nan(f):
		return 0.0
	if is_inf(f):
		return 999999.0 if f > 0.0 else -999999.0
	var snapped_val: float = snappedf(f, 0.000001)
	if abs(snapped_val) < 1e-9:
		return 0.0
	return snapped_val

func canonicalize_value(val: Variant, sort_keyed: bool = true) -> Variant:
	if val is float:
		return canonicalize_float(val)
	elif val is Dictionary:
		return canonicalize_dictionary(val, sort_keyed)
	elif val is Array:
		return canonicalize_array(val, sort_keyed)
	elif val is Vector3:
		return [canonicalize_float(val.x), canonicalize_float(val.y), canonicalize_float(val.z)]
	elif val is Vector2:
		return [canonicalize_float(val.x), canonicalize_float(val.y)]
	return val

func canonicalize_array(arr: Array, sort_keyed: bool = true) -> Array:
	var copy: Array = []
	for item in arr:
		copy.append(canonicalize_value(item, sort_keyed))
	if sort_keyed and _is_keyed_collection(copy):
		copy = _sort_keyed_array(copy)
	return copy

func canonicalize_dictionary(dict: Dictionary, sort_keyed: bool = true) -> Dictionary:
	var preferred_order: Array = []
	if dict.has("spec_version"):
		preferred_order = ROOT_CANONICAL_KEYS
	elif dict.has("type_name") and dict.has("id"):
		preferred_order = ELEMENT_CANONICAL_KEYS
	elif dict.has("source_element") and dict.has("target_element"):
		preferred_order = CONNECTION_CANONICAL_KEYS
	elif dict.has("interface_ports") and dict.has("id"):
		preferred_order = SUBGRAPH_CANONICAL_KEYS
	elif dict.has("position") and (dict.has("rotation") or dict.has("rotation_deg")):
		preferred_order = TRANSFORM_CANONICAL_KEYS

	var remaining_keys: Array = []
	for k in dict.keys():
		if not preferred_order.has(str(k)):
			remaining_keys.append(str(k))
	remaining_keys.sort()

	var ordered_keys: Array = []
	for k in preferred_order:
		if dict.has(k):
			ordered_keys.append(k)
	for k in remaining_keys:
		ordered_keys.append(k)

	var canonical := {}
	for k in ordered_keys:
		canonical[k] = canonicalize_value(dict[k], sort_keyed)
	return canonical

func save_to_canonical_json_string(spec: Dictionary, pretty: bool = true) -> String:
	var canonical := canonicalize_dictionary(spec, true)
	var indent := "  " if pretty else ""
	return JSON.stringify(canonical, indent, false)

func save_canonical_document(doc: RefCounted, pretty: bool = true) -> String:
	if doc == null or not doc.has_method("to_dict"):
		return ""
	return save_to_canonical_json_string(doc.to_dict(), pretty)

func save_to_msgpack_file(doc: RefCounted, path: String) -> bool:
	if doc == null:
		return false
	var bytes := encode_document_msgpack(doc)
	if bytes.is_empty():
		return false
	var tmp_path := path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.flush()
	f.close()

	var bak_path := path + ".bak"
	if FileAccess.file_exists(path):
		var err_bak := DirAccess.rename_absolute(path, bak_path)
		if err_bak != OK:
			DirAccess.remove_absolute(tmp_path)
			return false
	var err_rename := DirAccess.rename_absolute(tmp_path, path)
	if err_rename == OK:
		if FileAccess.file_exists(bak_path):
			DirAccess.remove_absolute(bak_path)
		return true
	else:
		if FileAccess.file_exists(bak_path):
			DirAccess.rename_absolute(bak_path, path)
		DirAccess.remove_absolute(tmp_path)
		return false

func load_from_msgpack_file(path: String) -> RefCounted:
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	return decode_document_msgpack(bytes)

func encode_transport_envelope(doc: Variant, message_id: String = "") -> PackedByteArray:
	var payload_dict: Dictionary = {}
	if doc != null and doc.has_method("to_dict"):
		payload_dict = doc.to_dict()
	elif doc is Dictionary:
		payload_dict = doc
	var msg_id := message_id if not message_id.is_empty() else ("msg_scenespec_" + str(Time.get_ticks_msec()))
	var envelope := {
		"envelope_version": "1.0",
		"message_id": msg_id,
		"timestamp": Time.get_unix_time_from_system() * 1000.0,
		"sender": "godot_gui",
		"target": "julia_runtime",
		"kind": "scene_spec",
		"payload": payload_dict
	}
	return encode_msgpack(envelope)

func decode_transport_envelope(bytes: PackedByteArray) -> Dictionary:
	var raw: Dictionary = decode_msgpack(bytes)
	if raw.is_empty():
		return {}
	return raw

func resolve_data_uri(uri: String, project_root: String) -> String:
	if uri.begins_with("data://"):
		var rel := uri.substr(7)
		return project_root.path_join("data").path_join(rel)
	elif uri.begins_with("asset://"):
		var rel := uri.substr(8)
		return project_root.path_join("assets").path_join(rel)
	elif uri.begins_with("subgraph://"):
		var rel := uri.substr(11)
		return project_root.path_join("graph").path_join("subgraphs").path_join(rel)
	return uri

func migrate_document(doc_dict: Dictionary) -> Dictionary:
	var changes: Array[String] = []
	var migrated := doc_dict.duplicate(true)
	var orig_version: String = str(migrated.get("spec_version", ""))
	if orig_version.is_empty():
		orig_version = "0.0.0"
		changes.append("Missing spec_version; set to 1.0.0")
		migrated["spec_version"] = "1.0.0"
	elif orig_version != "1.0.0":
		changes.append("Migrated spec_version from '%s' to '1.0.0'" % orig_version)
		migrated["spec_version"] = "1.0.0"

	if not migrated.has("spatial") or not (migrated["spatial"] is Dictionary) or migrated["spatial"].is_empty():
		migrated["spatial"] = {
			"coordinate_system": "right_handed_z_up",
			"length_unit": "meters",
			"origin": [0.0, 0.0, 0.0],
			"levels": [
				{
					"id": "level_ground",
					"name": "Ground Floor",
					"elevation": 0.0,
					"default_height": 3.0,
					"visible": true
				}
			]
		}
		changes.append("Synthesized default spatial coordinates and ground level")
	else:
		var sp: Dictionary = migrated["spatial"]
		if not sp.has("coordinate_system"):
			sp["coordinate_system"] = "right_handed_z_up"
			changes.append("Set spatial coordinate_system to right_handed_z_up")
		if not sp.has("length_unit"):
			sp["length_unit"] = "meters"
			changes.append("Set spatial length_unit to meters")
		if not sp.has("levels") or not (sp["levels"] is Array) or sp["levels"].is_empty():
			sp["levels"] = [
				{
					"id": "level_ground",
					"name": "Ground Floor",
					"elevation": 0.0,
					"default_height": 3.0,
					"visible": true
				}
			]
			changes.append("Created default level_ground in spatial")

	var elems = migrated.get("elements", [])
	if elems is Array:
		for i in range(elems.size()):
			var elem = elems[i]
			if elem is Dictionary:
				if not elem.has("level_id") or str(elem["level_id"]).is_empty():
					elem["level_id"] = "level_ground"
					changes.append("Element '%s' assigned to level_ground" % str(elem.get("id", i)))
				if not elem.has("transform") or not (elem["transform"] is Dictionary):
					elem["transform"] = {
						"position": [0.0, 0.0, 0.0],
						"rotation": [0.0, 0.0, 0.0],
						"scale": [1.0, 1.0, 1.0]
					}
					changes.append("Element '%s' initialized with default transform" % str(elem.get("id", i)))

	if not migrated.has("subgraphs") or not (migrated["subgraphs"] is Array):
		migrated["subgraphs"] = []

	return {
		"document": migrated,
		"changes": changes,
		"from_version": orig_version,
		"to_version": "1.0.0"
	}

func decode_document_msgpack(bytes: PackedByteArray) -> RefCounted:
	var dict: Dictionary = decode_msgpack(bytes)
	if dict.is_empty():
		return null
	return SCENE_TYPES.SceneDocument.from_dict(dict)

func encode_document_msgpack(doc: RefCounted) -> PackedByteArray:
	if doc == null or not doc.has_method("to_dict"):
		return PackedByteArray()
	return encode_msgpack(doc.to_dict())

func validate_document(doc: RefCounted, strict: bool = false, check_required: Variant = null) -> Dictionary:
	var validator := SCENE_VALIDATOR.new()
	return validator.validate_document(doc, strict, check_required)

func is_document_valid(doc: RefCounted) -> bool:
	var validator := SCENE_VALIDATOR.new()
	return validator.is_scene_valid(doc)

func normalize_document(doc: RefCounted) -> void:
	if doc == null:
		return
	var ver_val = doc.get("spec_version")
	if ver_val == null or str(ver_val).is_empty():
		doc.set("spec_version", "1.0.0")
	var sp_val = doc.get("spatial")
	var sp: Dictionary = sp_val if sp_val is Dictionary else {}
	if sp.is_empty():
		doc.set("spatial", {
			"coordinate_system": "right_handed_z_up",
			"length_unit": "meters",
			"origin": [0.0, 0.0, 0.0],
			"levels": [
				{
					"id": "level_ground",
					"name": "Ground Floor",
					"elevation": 0.0,
					"default_height": 3.0,
					"visible": true
				}
			]
		})
	var elems_val = doc.get("elements")
	if elems_val is Array:
		for elem in elems_val:
			if elem is SCENE_TYPES.SceneElement:
				if elem.level_id.is_empty():
					elem.level_id = "level_ground"
				if elem.transform == null:
					elem.transform = SCENE_TYPES.SceneTransform.new()
				if elem.transform.scale == Vector3.ZERO:
					elem.transform.scale = Vector3.ONE

func semantic_equal(a: Variant, b: Variant, atol: float = 1e-6, path: String = "root") -> Dictionary:
	if a == null and b == null:
		return {"ok": true, "error": ""}
	if a == null or b == null:
		return {"ok": false, "error": "%s: null mismatch (%s vs %s)" % [path, str(a), str(b)]}

	if a is bool and b is bool:
		if a == b:
			return {"ok": true, "error": ""}
		return {"ok": false, "error": "%s: bool mismatch (%s vs %s)" % [path, str(a), str(b)]}

	if (a is int or a is float) and (b is int or b is float):
		var fa: float = float(a)
		var fb: float = float(b)
		var diff: float = abs(fa - fb)
		var tol: float = atol * (1.0 + max(abs(fa), abs(fb)))
		if diff <= tol:
			return {"ok": true, "error": ""}
		return {"ok": false, "error": "%s: numeric mismatch (%s vs %s, diff=%f)" % [path, str(a), str(b), diff]}

	if a is String and b is String:
		if a == b:
			return {"ok": true, "error": ""}
		return {"ok": false, "error": "%s: string mismatch ('%s' != '%s')" % [path, a, b]}

	if a is Dictionary and b is Dictionary:
		var keys_a: Array = a.keys()
		var keys_b: Array = b.keys()
		var all_keys := {}
		for k in keys_a:
			all_keys[k] = true
		for k in keys_b:
			all_keys[k] = true

		for k in all_keys.keys():
			var has_a: bool = a.has(k)
			var has_b: bool = b.has(k)
			if not has_a:
				var val_b = b[k]
				if val_b == null or (val_b is Dictionary and val_b.is_empty()) or (val_b is Array and val_b.is_empty()):
					continue
				return {"ok": false, "error": "%s: key '%s' missing in first operand" % [path, str(k)]}
			if not has_b:
				var val_a = a[k]
				if val_a == null or (val_a is Dictionary and val_a.is_empty()) or (val_a is Array and val_a.is_empty()):
					continue
				return {"ok": false, "error": "%s: key '%s' missing in second operand" % [path, str(k)]}

			var subpath := str(k) if path == "root" else "%s.%s" % [path, str(k)]
			var res := semantic_equal(a[k], b[k], atol, subpath)
			if not res["ok"]:
				return res
		return {"ok": true, "error": ""}

	if a is Array and b is Array:
		if _is_keyed_collection(a) and _is_keyed_collection(b):
			var sorted_a := _sort_keyed_array(a)
			var sorted_b := _sort_keyed_array(b)
			if sorted_a.size() != sorted_b.size():
				return {"ok": false, "error": "%s: collection size mismatch (%d vs %d)" % [path, sorted_a.size(), sorted_b.size()]}
			for i in range(sorted_a.size()):
				var item_id: String = str(sorted_a[i].get("id", i))
				var res := semantic_equal(sorted_a[i], sorted_b[i], atol, "%s[id=%s]" % [path, item_id])
				if not res["ok"]:
					return res
			return {"ok": true, "error": ""}
		else:
			if a.size() != b.size():
				return {"ok": false, "error": "%s: array size mismatch (%d vs %d)" % [path, a.size(), b.size()]}
			for i in range(a.size()):
				var res := semantic_equal(a[i], b[i], atol, "%s[%d]" % [path, i])
				if not res["ok"]:
					return res
			return {"ok": true, "error": ""}

	return {"ok": false, "error": "%s: type mismatch (%s vs %s)" % [path, typeof(a), typeof(b)]}

func _is_keyed_collection(arr: Array) -> bool:
	if arr.is_empty():
		return false
	for item in arr:
		if not item is Dictionary or not item.has("id"):
			return false
	return true

func _sort_keyed_array(arr: Array) -> Array:
	var copy: Array = arr.duplicate(true)
	copy.sort_custom(func(x, y): return str(x.get("id", "")) < str(y.get("id", "")))
	return copy
