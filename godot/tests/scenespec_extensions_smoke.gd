extends SceneTree

const SCENESPEC_CODEC = preload("res://scripts/scenespec_codec.gd")
const SCENE_TYPES = preload("res://scripts/scenespec_types.gd")
const SCENE_VALIDATOR = preload("res://scripts/scenespec_validator.gd")

func _init() -> void:
	print("================================================================================")
	print("Running Godot Dynamic Extension Preservation & Metadata Smoke Tests (Phase 7D-03)...")
	print("================================================================================")
	var codec = SCENESPEC_CODEC.new()
	var validator = SCENE_VALIDATOR.new()

	var fixture_path := "res://fixtures/scenespec/future_fields.json"
	var file := FileAccess.open(fixture_path, FileAccess.READ)
	if file == null:
		push_error("Cannot open fixture: %s" % fixture_path)
		quit(1)
		return
	var text := file.get_as_text()
	file.close()

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 1: Grounding Against future_fields.json
	# ─────────────────────────────────────────────────────────────────────────────
	var doc = codec.load_document(text)
	if doc == null:
		push_error("load_document returned null for future_fields.json")
		quit(1)
		return

	# Document-level unknown properties
	if not doc.has_extension("future_distributed_engine"):
		push_error("doc.has_extension('future_distributed_engine') failed!")
		quit(1)
		return
	if doc.get_extension("future_distributed_engine") != true:
		push_error("doc.get_extension('future_distributed_engine') mismatch!")
		quit(1)
		return
	var cluster_nodes = doc.get_extension("cluster_target_nodes")
	if not (cluster_nodes is Array) or cluster_nodes.size() != 2:
		push_error("doc.get_extension('cluster_target_nodes') mismatch!")
		quit(1)
		return
	if doc.get_extension("root_level_extension_key") != "val_12345":
		push_error("doc.get_extension('root_level_extension_key') mismatch!")
		quit(1)
		return
	if doc.get_extension_path("experimental_flags.enable_neural_surrogate") != true:
		push_error("doc.get_extension_path('experimental_flags.enable_neural_surrogate') mismatch!")
		quit(1)
		return
	if doc.get_extension_path("cluster_target_nodes/0") != "compute_worker_01":
		push_error("doc.get_extension_path('cluster_target_nodes/0') mismatch!")
		quit(1)
		return
	if doc.get_extension_path("cluster_target_nodes/1") != "compute_worker_02":
		push_error("doc.get_extension_path('cluster_target_nodes/1') mismatch!")
		quit(1)
		return

	# Element-level unknown properties
	if doc.elements.is_empty():
		push_error("doc.elements is empty!")
		quit(1)
		return
	var elem = doc.elements[0]
	if float(elem.get_extension("thermal_dissipation_watts", 0.0)) != 450.0:
		push_error("elem.get_extension('thermal_dissipation_watts') mismatch!")
		quit(1)
		return
	if elem.editor.get_extension("custom_badge") != "SMART-V2":
		push_error("elem.editor.get_extension('custom_badge') mismatch!")
		quit(1)
		return
	if int(elem.get_extension_path("custom_vendor_blob.can_bus_speed_kbps", 0)) != 500:
		push_error("elem.get_extension_path('custom_vendor_blob.can_bus_speed_kbps') mismatch!")
		quit(1)
		return
	if int(elem.get_extension_path("custom_vendor_blob.retry_limit", 0)) != 3:
		push_error("elem.get_extension_path('custom_vendor_blob.retry_limit') mismatch!")
		quit(1)
		return

	# Port-level unknown properties
	if elem.output_ports.is_empty():
		push_error("elem.output_ports is empty!")
		quit(1)
		return
	var port = elem.output_ports[0]
	if int(port.get_extension("bus_channel_id", 0)) != 4:
		push_error("port.get_extension('bus_channel_id') mismatch!")
		quit(1)
		return
	if port.get_extension("security_token_required") != false:
		push_error("port.get_extension('security_token_required') mismatch!")
		quit(1)
		return

	# List extensions
	var elem_keys: Array = elem.list_extensions()
	if not ("thermal_dissipation_watts" in elem_keys) or not ("custom_vendor_blob" in elem_keys):
		push_error("elem.list_extensions() incomplete: %s" % str(elem_keys))
		quit(1)
		return

	print("  [PASS] future_fields.json metadata extraction & path navigation verified")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 2: Mutation and Deep Path Setters
	# ─────────────────────────────────────────────────────────────────────────────
	elem.set_extension("cooling_system_type", "liquid_nitrogen")
	if elem.get_extension("cooling_system_type") != "liquid_nitrogen":
		push_error("elem.set_extension failed!")
		quit(1)
		return

	elem.set_extension_path("custom_vendor_blob.can_bus_speed_kbps", 1000)
	if int(elem.get_extension_path("custom_vendor_blob.can_bus_speed_kbps")) != 1000:
		push_error("elem.set_extension_path update failed!")
		quit(1)
		return

	elem.set_extension_path("diagnostics.firmware.version", "4.2.1-rc1")
	if elem.get_extension_path("diagnostics.firmware.version") != "4.2.1-rc1":
		push_error("elem.set_extension_path intermediate auto-create failed!")
		quit(1)
		return

	var del_val = elem.delete_extension("maintenance_schedule_url")
	if del_val != "https://telemetry.local/device/elem_future_source" or elem.has_extension("maintenance_schedule_url"):
		push_error("elem.delete_extension failed!")
		quit(1)
		return

	print("  [PASS] Mutation and deep path navigation verified")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 3: Namespaced Extension Operations
	# ─────────────────────────────────────────────────────────────────────────────
	var sensor_data := {"channel": "ANALOG_01", "sample_rate_hz": 250.0}
	elem.set_namespace("vendor:sensors", sensor_data)
	if not elem.has_namespace("vendor:sensors"):
		push_error("elem.has_namespace('vendor:sensors') failed!")
		quit(1)
		return
	var ns: Dictionary = elem.get_namespace("vendor:sensors")
	if ns.get("channel") != "ANALOG_01" or float(ns.get("sample_rate_hz", 0.0)) != 250.0:
		push_error("elem.get_namespace mismatch: %s" % str(ns))
		quit(1)
		return
	if elem.get_extension_path("vendor:sensors.channel") != "ANALOG_01":
		push_error("Path traversal into namespace failed!")
		quit(1)
		return
	elem.delete_namespace("vendor:sensors")
	if elem.has_namespace("vendor:sensors"):
		push_error("elem.delete_namespace failed!")
		quit(1)
		return

	print("  [PASS] Namespaced extension operations verified")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 4: Deep Merge and Clone Isolation
	# ─────────────────────────────────────────────────────────────────────────────
	elem.merge_extensions({
		"custom_vendor_blob": {"new_param": 999},
		"telemetry_priority": "HIGH"
	})
	if int(elem.get_extension_path("custom_vendor_blob.new_param", 0)) != 999:
		push_error("merge_extensions new_param failed!")
		quit(1)
		return
	if int(elem.get_extension_path("custom_vendor_blob.retry_limit", 0)) != 3:
		push_error("merge_extensions erased existing sibling retry_limit!")
		quit(1)
		return
	if elem.get_extension("telemetry_priority") != "HIGH":
		push_error("merge_extensions telemetry_priority failed!")
		quit(1)
		return

	var cloned = doc.clone()
	var cloned_elem = cloned.elements[0]
	cloned_elem.set_extension("telemetry_priority", "LOW")
	if elem.get_extension("telemetry_priority") != "HIGH":
		push_error("Mutating clone affected original element extension!")
		quit(1)
		return

	print("  [PASS] Deep merge and clone isolation verified")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 5: MessagePack Round-Trip with Mutated Extensions
	# ─────────────────────────────────────────────────────────────────────────────
	doc.set_extension("test_run_uuid", "123e4567-e89b-12d3-a456-426614174000")
	var mp_bytes: PackedByteArray = codec.encode_document_msgpack(doc)
	if mp_bytes.is_empty():
		push_error("codec.encode_document_msgpack returned empty!")
		quit(1)
		return

	var doc_restored = codec.decode_document_msgpack(mp_bytes)
	if doc_restored == null:
		push_error("codec.decode_document_msgpack returned null!")
		quit(1)
		return

	if doc_restored.get_extension("test_run_uuid") != "123e4567-e89b-12d3-a456-426614174000":
		push_error("Restored doc missing test_run_uuid extension!")
		quit(1)
		return
	if int(doc_restored.elements[0].get_extension_path("custom_vendor_blob.new_param", 0)) != 999:
		push_error("Restored elem missing custom_vendor_blob.new_param!")
		quit(1)
		return
	if float(doc_restored.elements[0].get_extension("thermal_dissipation_watts", 0.0)) != 450.0:
		push_error("Restored elem missing original thermal_dissipation_watts!")
		quit(1)
		return

	print("  [PASS] Lossless MessagePack round-trip with mutated extensions verified")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 6: Extension Governance Validation Rules (EXT_001, EXT_002)
	# ─────────────────────────────────────────────────────────────────────────────
	# 6a. EXT_001_INVALID_KEY: key with invalid whitespace
	var bad_elem = doc.elements[0]
	bad_elem.set_extension("invalid key with spaces", "bad_val")
	var rep1 = validator.validate_document(doc)
	if rep1.get("is_valid", true):
		push_error("Expected invalid status for EXT_001_INVALID_KEY!")
		quit(1)
		return
	var has_ext001 := false
	for d in rep1.get("diagnostics", []):
		if d.get("rule_id") == "EXT_001_INVALID_KEY" and d.get("severity") == "error":
			has_ext001 = true
			break
	if not has_ext001:
		push_error("EXT_001_INVALID_KEY diagnostic not found!")
		quit(1)
		return
	bad_elem.delete_extension("invalid key with spaces")

	# 6b. EXT_002_RESERVED_KEY_CONFLICT: shadowing core field 'transform' on element
	bad_elem.set_extension("transform", {"fake": 1})
	var rep2 = validator.validate_document(doc)
	if rep2.get("is_valid", true):
		push_error("Expected invalid status for EXT_002_RESERVED_KEY_CONFLICT!")
		quit(1)
		return
	var has_ext002 := false
	for d in rep2.get("diagnostics", []):
		if d.get("rule_id") == "EXT_002_RESERVED_KEY_CONFLICT" and d.get("severity") == "error":
			has_ext002 = true
			break
	if not has_ext002:
		push_error("EXT_002_RESERVED_KEY_CONFLICT diagnostic not found!")
		quit(1)
		return
	bad_elem.delete_extension("transform")

	# Verify cleaned doc returns to valid
	var rep_clean = validator.validate_document(doc)
	if not rep_clean.get("is_valid", false):
		push_error("Cleaned doc failed validation unexpectedly: %s" % str(rep_clean.get("diagnostics", [])))
		quit(1)
		return

	print("  [PASS] Extension governance rules (EXT_001, EXT_002) verified")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 7: Static SimVizSceneTypes Extension Helpers
	# ─────────────────────────────────────────────────────────────────────────────
	var raw_dict := {
		"custom_field": "val_abc",
		"extensions": {
			"vendor_data": {"speed": 42}
		}
	}
	if SCENE_TYPES.get_extension(raw_dict, "custom_field") != "val_abc":
		push_error("SCENE_TYPES.get_extension on raw dictionary failed!")
		quit(1)
		return
	if int(SCENE_TYPES.get_extension_path(raw_dict, "vendor_data.speed", 0)) != 42:
		push_error("SCENE_TYPES.get_extension_path on raw dictionary failed!")
		quit(1)
		return
	SCENE_TYPES.set_extension(raw_dict, "new_tag", "tag_123")
	if raw_dict.get("new_tag") != "tag_123":
		push_error("SCENE_TYPES.set_extension on raw dictionary failed!")
		quit(1)
		return

	print("  [PASS] Static SimVizSceneTypes extension helpers verified")

	print("================================================================================")
	print("All Phase 7D-03 Godot Dynamic Extension Preservation smoke tests PASSED!")
	print("================================================================================")
	quit(0)
