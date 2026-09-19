extends SceneTree

const SCENESPEC_CODEC = preload("res://scripts/scenespec_codec.gd")

func _init() -> void:
	print("Running Godot SceneSpec v1 Golden Fixture Smoke Tests...")
	var codec = SCENESPEC_CODEC.new()
	var fixture_names := [
		"minimal_des.json",
		"minimal_abm.json",
		"minimal_hybrid.json",
		"two_level_spatial.json",
		"invalid_connections.json",
		"missing_library.json",
		"future_fields.json"
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

		# 1. Parse JSON
		var spec: Dictionary = codec.load_from_json_string(text)
		if spec.is_empty():
			push_error("Failed to parse JSON fixture: %s" % fname)
			quit(1)
			return

		# 2. JSON Round-Trip
		var json_out: String = codec.save_to_json_string(spec, true)
		var spec_reloaded: Dictionary = codec.load_from_json_string(json_out)
		var json_eq: Dictionary = codec.semantic_equal(spec, spec_reloaded)
		if not json_eq["ok"]:
			push_error("JSON round-trip mismatch in %s: %s" % [fname, json_eq["error"]])
			quit(1)
			return

		# 3. MessagePack Round-Trip
		var mp_bytes: PackedByteArray = codec.encode_msgpack(spec)
		if mp_bytes.is_empty():
			push_error("MessagePack encode returned empty bytes for: %s" % fname)
			quit(1)
			return

		var mp_spec: Dictionary = codec.decode_msgpack(mp_bytes)
		var mp_eq: Dictionary = codec.semantic_equal(spec, mp_spec)
		if not mp_eq["ok"]:
			push_error("MessagePack round-trip mismatch in %s: %s" % [fname, mp_eq["error"]])
			quit(1)
			return

		print("  [PASS] Fixture %s verified (JSON + MessagePack round-trip)" % fname)
		passed_count += 1

	# Detailed checks for future_fields
	var future_path := "res://fixtures/scenespec/future_fields.json"
	var future_file := FileAccess.open(future_path, FileAccess.READ)
	var future_spec: Dictionary = codec.load_from_json_string(future_file.get_as_text())
	future_file.close()

	if not future_spec.get("future_distributed_engine", false):
		push_error("future_distributed_engine was not preserved!")
		quit(1)
		return
	if future_spec.get("cluster_target_nodes", []).size() != 2:
		push_error("cluster_target_nodes was not preserved!")
		quit(1)
		return
	var first_elem: Dictionary = future_spec.get("elements", [])[0]
	if float(first_elem.get("thermal_dissipation_watts", 0.0)) != 450.0:
		push_error("thermal_dissipation_watts was not preserved in element!")
		quit(1)
		return
	print("  [PASS] Unknown field preservation verified for future_fields.json")

	# Detailed check for two_level_spatial
	var spatial_path := "res://fixtures/scenespec/two_level_spatial.json"
	var spatial_file := FileAccess.open(spatial_path, FileAccess.READ)
	var spatial_spec: Dictionary = codec.load_from_json_string(spatial_file.get_as_text())
	spatial_file.close()

	var spatial_meta: Dictionary = spatial_spec.get("spatial", {})
	if str(spatial_meta.get("coordinate_system", "")) != "right_handed_z_up":
		push_error("Expected right_handed_z_up coordinate system!")
		quit(1)
		return
	var levels: Array = spatial_meta.get("levels", [])
	if levels.size() != 2:
		push_error("Expected 2 spatial levels in two_level_spatial.json!")
		quit(1)
		return
	print("  [PASS] Z-up coordinate system and levels verified for two_level_spatial.json")

	print("\nAll %d SceneSpec golden fixtures passed Godot headless validation!" % passed_count)
	quit(0)

