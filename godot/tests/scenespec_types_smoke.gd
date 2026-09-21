extends SceneTree

const SCENESPEC_CODEC = preload("res://scripts/scenespec_codec.gd")
const SCENE_TYPES = preload("res://scripts/scenespec_types.gd")

func _init() -> void:
	print("Running Godot SceneSpec v1 Strongly-Typed Classes Smoke Tests (Phase 7D-01)...")
	var codec = SCENESPEC_CODEC.new()
	var fixture_names := [
		"minimal_des.json",
		"minimal_abm.json",
		"minimal_hybrid.json",
		"two_level_spatial.json",
		"invalid_connections.json",
		"missing_library.json",
		"future_fields.json",
		"hierarchical_subgraph.json"
	]

	var passed_count := 0
	for fname in fixture_names:
		var path := "res://fixtures/scenespec/%s" % fname
		if not FileAccess.file_exists(path):
			push_error("Fixture not found: %s" % path)
			quit(1)
			return

		var file := FileAccess.open(path, FileAccess.READ)
		var text := file.get_as_text()
		file.close()

		# 1. Parse JSON original
		var orig_dict: Dictionary = codec.load_from_json_string(text)
		if orig_dict.is_empty():
			push_error("Failed to parse JSON fixture: %s" % fname)
			quit(1)
			return

		# 2. Parse into typed SceneDocument
		var doc = codec.load_document(text)
		if doc == null:
			push_error("load_document returned null for fixture: %s" % fname)
			quit(1)
			return

		if str(doc.spec_version) != "1.0.0":
			push_error("Invalid spec_version in %s: %s" % [fname, doc.spec_version])
			quit(1)
			return

		# 3. Round-trip typed document -> dict
		var doc_dict: Dictionary = doc.to_dict()
		var res: Dictionary = codec.semantic_equal(orig_dict, doc_dict)
		if not res["ok"]:
			push_error("Typed SceneDocument round-trip mismatch in %s: %s" % [fname, res["error"]])
			quit(1)
			return

		# 4. MessagePack round-trip via typed document
		var mp_bytes: PackedByteArray = codec.encode_document_msgpack(doc)
		if mp_bytes.is_empty():
			push_error("encode_document_msgpack returned empty for %s" % fname)
			quit(1)
			return

		var doc_from_mp = codec.decode_document_msgpack(mp_bytes)
		if doc_from_mp == null:
			push_error("decode_document_msgpack returned null for %s" % fname)
			quit(1)
			return

		var mp_res: Dictionary = codec.semantic_equal(orig_dict, doc_from_mp.to_dict())
		if not mp_res["ok"]:
			push_error("MessagePack typed document mismatch in %s: %s" % [fname, mp_res["error"]])
			quit(1)
			return

		print("  [PASS] Typed SceneDocument round-trip verified for: %s" % fname)
		passed_count += 1

	# Test 5: Deep cloning verification
	var min_path := "res://fixtures/scenespec/minimal_des.json"
	var min_file := FileAccess.open(min_path, FileAccess.READ)
	var min_doc = codec.load_document(min_file.get_as_text())
	min_file.close()

	var cloned = min_doc.clone()
	var first_orig_elem = min_doc.elements[0]
	var first_clone_elem = cloned.elements[0]

	first_clone_elem.name = "Mutated In Clone Only"
	first_clone_elem.transform.position.x = 999.0

	if first_orig_elem.name == "Mutated In Clone Only":
		push_error("Cloning failed: mutating clone affected original element name!")
		quit(1)
		return
	if first_orig_elem.transform.position.x == 999.0:
		push_error("Cloning failed: mutating clone affected original transform position!")
		quit(1)
		return
	print("  [PASS] Deep cloning immutability verified")

	# Test 6: Unknown field preservation on future_fields.json
	var future_path := "res://fixtures/scenespec/future_fields.json"
	var future_file := FileAccess.open(future_path, FileAccess.READ)
	var future_doc = codec.load_document(future_file.get_as_text())
	future_file.close()

	if not future_doc.extensions.get("future_distributed_engine", false):
		push_error("future_distributed_engine was not retained in document extensions!")
		quit(1)
		return

	var felem = future_doc.elements[0]
	if float(felem.extensions.get("thermal_dissipation_watts", 0.0)) != 450.0:
		push_error("thermal_dissipation_watts was not retained in element extensions!")
		quit(1)
		return

	var fport = felem.output_ports[0]
	if int(fport.extensions.get("bus_channel_id", 0)) != 4:
		push_error("bus_channel_id was not retained in port extensions!")
		quit(1)
		return
	print("  [PASS] Unknown-field and extension retention verified in Godot typed classes")

	# Test 7: Normalization of draft document
	var empty_doc = SCENE_TYPES.SceneDocument.new()
	var elem_unnorm = SCENE_TYPES.SceneElement.new()
	elem_unnorm.id = "elem_raw"
	elem_unnorm.transform.scale = Vector3.ZERO
	empty_doc.elements.append(elem_unnorm)

	codec.normalize_document(empty_doc)
	if empty_doc.spatial.is_empty():
		push_error("normalize_document failed to backfill spatial config!")
		quit(1)
		return
	if elem_unnorm.level_id != "level_ground":
		push_error("normalize_document failed to backfill element level_id!")
		quit(1)
		return
	if elem_unnorm.transform.scale != Vector3.ONE:
		push_error("normalize_document failed to backfill unit scale!")
		quit(1)
		return
	print("  [PASS] Document normalization hook verified")

	print("\nAll %d SceneSpec fixtures and typed class tests passed Godot validation!" % passed_count)
	quit(0)

