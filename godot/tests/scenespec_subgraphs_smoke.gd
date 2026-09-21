extends SceneTree

# ============================================================================
# scenespec_subgraphs_smoke.gd - Phase 7D-04 Subgraph & Spatial Layout Smoke
#
# Validates hierarchical subgraph expansion, parameter overrides, spatial
# transform composition, SoA buffer decoding, and diagnostics in Godot.
# ============================================================================

const CODEC_SCRIPT = preload("res://scripts/scenespec_codec.gd")
const SCENE_TYPES = preload("res://scripts/scenespec_types.gd")
const VALIDATOR_SCRIPT = preload("res://scripts/scenespec_validator.gd")
const SUBGRAPHS_SCRIPT = preload("res://scripts/scenespec_subgraphs.gd")
const SPATIAL_SCRIPT = preload("res://scripts/scenespec_spatial.gd")

func _init() -> void:
	print("================================================================================")
	print("Running Godot SceneSpec Subgraph Expansion & Spatial Layout Smoke (Phase 7D-04)")
	print("================================================================================")

	var codec = CODEC_SCRIPT.new()
	var validator = VALIDATOR_SCRIPT.new()

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 1: Load and Validate Golden Fixture (hierarchical_subgraph.json)
	# ─────────────────────────────────────────────────────────────────────────────
	var fixture_path := "res://fixtures/scenespec/hierarchical_subgraph.json"
	var file := FileAccess.open(fixture_path, FileAccess.READ)
	if file == null:
		push_error("Failed to open fixture: %s" % fixture_path)
		quit(1)
		return

	var text := file.get_as_text()
	file.close()

	var doc: SCENE_TYPES.SceneDocument = codec.load_document(text)
	if doc == null:
		push_error("Failed to parse hierarchical_subgraph.json into SceneDocument")
		quit(1)
		return

	if doc.subgraphs.size() != 3:
		push_error("Expected 3 subgraphs in fixture, got %d" % doc.subgraphs.size())
		quit(1)
		return

	var report: Dictionary = validator.validate_document(doc)
	if not report.get("is_valid", false):
		push_error("Fixture hierarchical_subgraph.json failed validation: %s" % str(report.get("diagnostics", [])))
		quit(1)
		return

	print("  [PASS] Fixture hierarchical_subgraph.json loaded and validated cleanly (0 errors)")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 2: Subgraph Compilation & Expansion
	# ─────────────────────────────────────────────────────────────────────────────
	var compiled: Dictionary = SUBGRAPHS_SCRIPT.compile_scene_graph(doc)
	var flat_doc: SCENE_TYPES.SceneDocument = compiled.get("flat_doc")
	if flat_doc == null:
		push_error("compile_scene_graph did not return flat_doc")
		quit(1)
		return

	# Expected flat elements:
	# 2 top-level non-template (src_ground_entry, snk_mezzanine_exit)
	# + 2 from station_alpha (station_alpha::tpl_q, station_alpha::tpl_srv)
	# + 2 from station_beta (station_beta::tpl_q, station_beta::tpl_srv)
	# = 6 elements total. (tpl_q and tpl_srv must be excluded as template prototypes).
	if flat_doc.elements.size() != 6:
		push_error("Expected 6 flat elements, got %d" % flat_doc.elements.size())
		quit(1)
		return

	var flat_elem_map := {}
	for e in flat_doc.elements:
		flat_elem_map[e.id] = e

	if flat_elem_map.has("tpl_q") or flat_elem_map.has("tpl_srv"):
		push_error("Template prototype elements leaked into flat compilation!")
		quit(1)
		return

	if not flat_elem_map.has("station_alpha::tpl_q") or not flat_elem_map.has("station_alpha::tpl_srv"):
		push_error("station_alpha child elements missing from compilation")
		quit(1)
		return

	if not flat_elem_map.has("station_beta::tpl_q") or not flat_elem_map.has("station_beta::tpl_srv"):
		push_error("station_beta child elements missing from compilation")
		quit(1)
		return

	print("  [PASS] Two-phase compilation expanded 6 flat elements with uninstantiated template filtering")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 3: Parameter Overrides
	# ─────────────────────────────────────────────────────────────────────────────
	var alpha_q: SCENE_TYPES.SceneElement = flat_elem_map["station_alpha::tpl_q"]
	var alpha_srv: SCENE_TYPES.SceneElement = flat_elem_map["station_alpha::tpl_srv"]
	var beta_srv: SCENE_TYPES.SceneElement = flat_elem_map["station_beta::tpl_srv"]

	if int(alpha_q.properties.get("capacity", 0)) != 75:
		push_error("station_alpha::tpl_q capacity override failed: %s" % str(alpha_q.properties))
		quit(1)
		return

	if not is_equal_approx(float(alpha_srv.properties.get("service_time", 0.0)), 8.0):
		push_error("station_alpha::tpl_srv service_time override failed: %s" % str(alpha_srv.properties))
		quit(1)
		return

	if not is_equal_approx(float(beta_srv.properties.get("service_time", 0.0)), 4.0):
		push_error("station_beta::tpl_srv service_time override failed: %s" % str(beta_srv.properties))
		quit(1)
		return

	if int(beta_srv.properties.get("servers", 0)) != 4:
		push_error("station_beta::tpl_srv servers override failed: %s" % str(beta_srv.properties))
		quit(1)
		return

	print("  [PASS] Scoped parameter overrides correctly applied to compiled instances")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 4: Spatial Transform Composition & Level Inheritance
	# ─────────────────────────────────────────────────────────────────────────────
	# station_alpha is at (10, 0, 0), tpl_q is at (-2, 0, 0) -> composed is (8, 0, 0)
	if not is_equal_approx(alpha_q.transform.position.x, 8.0) or not is_equal_approx(alpha_q.transform.position.z, 0.0):
		push_error("station_alpha::tpl_q position composition mismatch: %s" % str(alpha_q.transform.position))
		quit(1)
		return

	# station_alpha is at (10, 0, 0), tpl_srv is at (2, 0, 0) -> composed is (12, 0, 0)
	if not is_equal_approx(alpha_srv.transform.position.x, 12.0):
		push_error("station_alpha::tpl_srv position composition mismatch: %s" % str(alpha_srv.transform.position))
		quit(1)
		return

	# station_beta is at (30, 0, 4.5), tpl_srv is at (2, 0, 0) -> composed is (32, 0, 4.5)
	if not is_equal_approx(beta_srv.transform.position.x, 32.0) or not is_equal_approx(beta_srv.transform.position.z, 4.5):
		push_error("station_beta::tpl_srv position composition mismatch: %s" % str(beta_srv.transform.position))
		quit(1)
		return

	if beta_srv.level_id != "level_mezzanine":
		push_error("station_beta::tpl_srv expected level_id 'level_mezzanine', got '%s'" % beta_srv.level_id)
		quit(1)
		return

	# Direct unit test of compose_transforms with rotation
	var p_trans = SCENE_TYPES.SceneTransform.new()
	p_trans.position = Vector3(10.0, 20.0, 5.0)
	p_trans.rotation = Vector3(0.0, 0.0, 90.0) # 90 deg yaw
	var c_trans = SCENE_TYPES.SceneTransform.new()
	c_trans.position = Vector3(1.0, 0.0, 0.0)
	var comp_rot = SPATIAL_SCRIPT.compose_transforms(p_trans, c_trans)
	# 90 deg rotation turns (1, 0, 0) into (0, 1, 0) -> composed pos is (10, 21, 5)
	if not is_equal_approx(comp_rot.position.x, 10.0) or not is_equal_approx(comp_rot.position.y, 21.0):
		push_error("Rotated transform composition mismatch: %s" % str(comp_rot.position))
		quit(1)
		return

	print("  [PASS] Hierarchical spatial transforms and level assignments verified")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 5: Connection Rewiring & Boundary Port Mapping
	# ─────────────────────────────────────────────────────────────────────────────
	var flat_conn_map := {}
	for c in flat_doc.connections:
		flat_conn_map[c.id] = c

	# conn_entry_to_alpha: src_ground_entry:flow_out -> station_alpha:flow_in
	# Must be rewired to: src_ground_entry:flow_out -> station_alpha::tpl_q:flow_in
	var rewired_entry: SCENE_TYPES.SceneConnection = flat_conn_map.get("conn_entry_to_alpha")
	if rewired_entry == null:
		push_error("conn_entry_to_alpha missing from flat connections")
		quit(1)
		return

	if rewired_entry.target_element != "station_alpha::tpl_q" or rewired_entry.target_port != "flow_in":
		push_error("conn_entry_to_alpha boundary rewiring failed: target=%s:%s" % [rewired_entry.target_element, rewired_entry.target_port])
		quit(1)
		return

	# conn_alpha_to_beta: station_alpha:flow_out -> station_beta:flow_in
	# Must be rewired to: station_alpha::tpl_srv:flow_out -> station_beta::tpl_q:flow_in
	var rewired_mid: SCENE_TYPES.SceneConnection = flat_conn_map.get("conn_alpha_to_beta")
	if rewired_mid == null or rewired_mid.source_element != "station_alpha::tpl_srv" or rewired_mid.target_element != "station_beta::tpl_q":
		push_error("conn_alpha_to_beta boundary rewiring failed: %s" % str(rewired_mid))
		quit(1)
		return

	print("  [PASS] Boundary connection rewiring across compound exposed ports verified")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 6: Bidirectional Source Mapping & Metric Queries
	# ─────────────────────────────────────────────────────────────────────────────
	var sm: Dictionary = compiled.get("source_map", {})
	var src_res: Dictionary = SUBGRAPHS_SCRIPT.resolve_runtime_source(sm, "station_alpha::tpl_srv")
	if src_res.get("subgraph_id") != "station_alpha" or src_res.get("local_id") != "tpl_srv" or src_res.get("template_id") != "tpl_station":
		push_error("resolve_runtime_source failed: %s" % str(src_res))
		quit(1)
		return

	# Hierarchical metric query
	var live_metrics := {
		"station_alpha::tpl_q": 10.0,
		"station_alpha::tpl_srv": 20.0,
		"station_beta::tpl_srv": 42.0
	}
	var q_res: float = SUBGRAPHS_SCRIPT.query_hierarchical_metric(sm, "station_alpha", live_metrics)
	if not is_equal_approx(q_res, 30.0):
		push_error("query_hierarchical_metric returned %f, expected 30.0" % q_res)
		quit(1)
		return

	print("  [PASS] Bidirectional SubgraphSourceMap and hierarchical metric queries verified")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 7: Binary SoA Decoding
	# ─────────────────────────────────────────────────────────────────────────────
	# Construct a binary SoA payload matching Julia's to_godot_byte_array
	var spb := StreamPeerBuffer.new()
	spb.put_32(2) # count = 2
	# pos: (1.0, 2.0, 3.0), (4.0, 5.0, 6.0)
	spb.put_float(1.0); spb.put_float(2.0); spb.put_float(3.0)
	spb.put_float(4.0); spb.put_float(5.0); spb.put_float(6.0)
	# rot: (0, 0, 0), (0, 0, 90)
	spb.put_float(0.0); spb.put_float(0.0); spb.put_float(0.0)
	spb.put_float(0.0); spb.put_float(0.0); spb.put_float(90.0)
	# scl: (1, 1, 1), (1, 1, 1)
	spb.put_float(1.0); spb.put_float(1.0); spb.put_float(1.0)
	spb.put_float(1.0); spb.put_float(1.0); spb.put_float(1.0)
	# level_indices: 0, 1
	spb.put_32(0); spb.put_32(1)

	var decoded: Dictionary = SPATIAL_SCRIPT.decode_spatial_soa_bytes(spb.data_array)
	if decoded.get("count") != 2:
		push_error("decode_spatial_soa_bytes count mismatch: %s" % str(decoded.get("count")))
		quit(1)
		return

	var d_pos: PackedFloat32Array = decoded.get("positions", PackedFloat32Array())
	if d_pos.size() != 6 or not is_equal_approx(d_pos[5], 6.0):
		push_error("decode_spatial_soa_bytes position unpacking failed: %s" % str(d_pos))
		quit(1)
		return

	var d_levels: PackedInt32Array = decoded.get("level_indices", PackedInt32Array())
	if d_levels.size() != 2 or d_levels[0] != 0 or d_levels[1] != 1:
		push_error("decode_spatial_soa_bytes level indices failed: %s" % str(d_levels))
		quit(1)
		return

	print("  [PASS] SpatialBufferSoA direct binary byte array decoding verified")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 8: Subgraph Semantic Validation Rules
	# ─────────────────────────────────────────────────────────────────────────────
	# SUBGRAPH_001: Recursive Cycle Detection
	var cycle_doc := SCENE_TYPES.SceneDocument.new()
	var sub1 := SCENE_TYPES.SceneSubgraph.new()
	sub1.id = "sub_cycle_1"; sub1.role = "compound"; sub1.template_id = "sub_cycle_2"
	var sub2 := SCENE_TYPES.SceneSubgraph.new()
	sub2.id = "sub_cycle_2"; sub2.role = "compound"; sub2.template_id = "sub_cycle_1"
	cycle_doc.subgraphs.append(sub1)
	cycle_doc.subgraphs.append(sub2)
	var rep_cycle: Dictionary = validator.validate_document(cycle_doc)
	var cycle_rules := []
	for d in rep_cycle.get("diagnostics", []):
		cycle_rules.append(d.get("rule_id"))
	if not "SUBGRAPH_001_RECURSIVE_CYCLE" in cycle_rules:
		push_error("Expected SUBGRAPH_001_RECURSIVE_CYCLE diagnostic, got: %s" % str(cycle_rules))
		quit(1)
		return

	# SUBGRAPH_003: Missing Template Detection
	var bad_tmpl_doc := SCENE_TYPES.SceneDocument.new()
	var sub_bad_tmpl := SCENE_TYPES.SceneSubgraph.new()
	sub_bad_tmpl.id = "sub_missing"; sub_bad_tmpl.role = "compound"; sub_bad_tmpl.template_id = "nonexistent_tpl"
	bad_tmpl_doc.subgraphs.append(sub_bad_tmpl)
	var rep_bad_tmpl: Dictionary = validator.validate_document(bad_tmpl_doc)
	var tmpl_rules := []
	for d in rep_bad_tmpl.get("diagnostics", []):
		tmpl_rules.append(d.get("rule_id"))
	if not "SUBGRAPH_003_TEMPLATE_NOT_FOUND" in tmpl_rules:
		push_error("Expected SUBGRAPH_003_TEMPLATE_NOT_FOUND diagnostic, got: %s" % str(tmpl_rules))
		quit(1)
		return

	# SPATIAL_003: Connector Inaccessible
	var bad_conn_doc := SCENE_TYPES.SceneDocument.new()
	bad_conn_doc.spatial = {
		"levels": [
			{ "id": "lvl_1", "elevation": 0.0, "height": 3.0 },
			{ "id": "lvl_2", "elevation": 10.0, "height": 3.0 }
		]
	}

	var bad_lift := SCENE_TYPES.SceneElement.new()
	bad_lift.id = "bad_lift"; bad_lift.kind = "spatial_connector"; bad_lift.level_id = "lvl_1"
	bad_lift.vertical_extent = {
		"source_level_id": "lvl_1",
		"target_level_id": "lvl_2",
		"height": 4.0
	}
	bad_conn_doc.elements.append(bad_lift)

	var rep_lift: Dictionary = validator.validate_document(bad_conn_doc)
	var lift_rules := []
	for d in rep_lift.get("diagnostics", []):
		lift_rules.append(d.get("rule_id"))
	if not "SPATIAL_003_CONNECTOR_INACCESSIBLE" in lift_rules:
		push_error("Expected SPATIAL_003_CONNECTOR_INACCESSIBLE diagnostic, got: %s" % str(lift_rules))
		quit(1)
		return

	print("  [PASS] Subgraph validation diagnostics verified (SUBGRAPH_001, SUBGRAPH_003, SPATIAL_003)")

	print("================================================================================")
	print("All Phase 7D-04 Subgraph & Spatial Layout smoke tests PASSED successfully!")
	print("================================================================================")
	quit(0)
