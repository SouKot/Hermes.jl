class_name SimVizSceneSpecCodec
extends RefCounted

const PROTOCOL_CODEC = preload("res://scripts/protocol_codec.gd")
const SCENE_TYPES = preload("res://scripts/scenespec_types.gd")

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

func decode_document_msgpack(bytes: PackedByteArray) -> RefCounted:
	var dict := decode_msgpack(bytes)
	if dict.is_empty():
		return null
	return SCENE_TYPES.SceneDocument.from_dict(dict)

func encode_document_msgpack(doc: RefCounted) -> PackedByteArray:
	if doc == null or not doc.has_method("to_dict"):
		return PackedByteArray()
	return encode_msgpack(doc.to_dict())

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
