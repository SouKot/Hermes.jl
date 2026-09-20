extends SceneTree

const SCENESPEC_CODEC = preload("res://scripts/scenespec_codec.gd")
const SCENE_TYPES = preload("res://scripts/scenespec_types.gd")
const SCENE_VALIDATOR = preload("res://scripts/scenespec_validator.gd")

func _init() -> void:
	print("================================================================================")
	print("Running Godot SimVizSceneValidator Smoke Tests (Phase 7D-02)...")
	print("================================================================================")
	var codec = SCENESPEC_CODEC.new()
	var validator = SCENE_VALIDATOR.new()

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 1: Grounding Against Golden Fixtures (All 6 Valid Fixtures Have 0 Errors)
	# ─────────────────────────────────────────────────────────────────────────────
	var valid_fixtures := [
		"minimal_des.json",
		"minimal_abm.json",
		"minimal_hybrid.json",
		"two_level_spatial.json",
		"missing_library.json",
		"future_fields.json"
	]

	for fname in valid_fixtures:
		var path := "res://fixtures/scenespec/%s" % fname
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			push_error("Cannot open fixture: %s" % path)
			quit(1)
			return
		var text := file.get_as_text()
		file.close()

		var doc = codec.load_document(text)
		if doc == null:
			push_error("Failed to load typed document for: %s" % fname)
			quit(1)
			return

		var report: Dictionary = validator.validate_document(doc)
		if not report.get("is_valid", false):
			push_error("Fixture %s failed validation unexpectedly! Errors: %s" % [fname, str(report.get("diagnostics", []))])
			quit(1)
			return

		# Check that doc.validation_metadata was set
		var meta = doc.get("validation_metadata")
		if not (meta is Dictionary) or not meta.get("is_valid", false):
			push_error("validation_metadata not properly populated on document for %s" % fname)
			quit(1)
			return

		print("  [PASS] Valid fixture verified: %s (is_valid=true, diagnostics=%d)" % [fname, report.get("diagnostic_count", 0)])

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 2: Grounding Against Canonical invalid_connections.json
	# ─────────────────────────────────────────────────────────────────────────────
	var inv_path := "res://fixtures/scenespec/invalid_connections.json"
	var inv_file := FileAccess.open(inv_path, FileAccess.READ)
	var inv_doc = codec.load_document(inv_file.get_as_text())
	inv_file.close()

	var inv_report = validator.validate_document(inv_doc)
	if inv_report.get("is_valid", true):
		push_error("invalid_connections.json unexpectedly marked valid!")
		quit(1)
		return

	var diags: Array = inv_report.get("diagnostics", [])
	if diags.size() != 2:
		push_error("invalid_connections.json expected exactly 2 diagnostics, got %d: %s" % [diags.size(), str(diags)])
		quit(1)
		return

	# Diagnostic 1: PORT_001_NOT_FOUND on conn_bad_target_port
	var d1 = diags[0]
	if d1.get("rule_id") != "PORT_001_NOT_FOUND" or d1.get("severity") != "error" or d1.get("object_id") != "conn_bad_target_port":
		push_error("First diagnostic mismatch: %s" % str(d1))
		quit(1)
		return
	if d1.get("suggested_fix") != "Connect to 'flow_in'":
		push_error("First diagnostic suggested_fix mismatch: got '%s', expected 'Connect to \\'flow_in\\''" % d1.get("suggested_fix"))
		quit(1)
		return

	# Diagnostic 2: PORT_002_KIND_MISMATCH on conn_incompatible_kinds
	var d2 = diags[1]
	if d2.get("rule_id") != "PORT_002_KIND_MISMATCH" or d2.get("severity") != "error" or d2.get("object_id") != "conn_incompatible_kinds":
		push_error("Second diagnostic mismatch: %s" % str(d2))
		quit(1)
		return
	if not "compatible flow" in str(d2.get("suggested_fix")):
		push_error("Second diagnostic suggested_fix mismatch: %s" % str(d2.get("suggested_fix")))
		quit(1)
		return

	print("  [PASS] Canonical invalid_connections.json grounding passed (PORT_001_NOT_FOUND, PORT_002_KIND_MISMATCH with exact fixes)")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 3: Synthetic Validation - ID Uniqueness (ID_001_DUPLICATE)
	# ─────────────────────────────────────────────────────────────────────────────
	var dup_doc = SCENE_TYPES.SceneDocument.new()
	var e1 = SCENE_TYPES.SceneElement.new()
	e1.id = "elem_duplicate"
	var e2 = SCENE_TYPES.SceneElement.new()
	e2.id = "elem_duplicate"
	dup_doc.elements.append(e1)
	dup_doc.elements.append(e2)

	var dup_report = validator.validate_document(dup_doc)
	var has_dup := false
	for d in dup_report.get("diagnostics", []):
		if d.get("rule_id") == "ID_001_DUPLICATE" and d.get("severity") == "error":
			has_dup = true
			break
	if not has_dup:
		push_error("Failed to detect duplicate element ID: %s" % str(dup_report))
		quit(1)
		return
	print("  [PASS] Duplicate element ID detection verified (ID_001_DUPLICATE)")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 4: Synthetic Validation - Spatial Level Missing & Elevation Out of Bounds
	# ─────────────────────────────────────────────────────────────────────────────
	var sp_doc = SCENE_TYPES.SceneDocument.new()
	sp_doc.spatial = {
		"coordinate_system": "right_handed_z_up",
		"length_unit": "meters",
		"origin": [0.0, 0.0, 0.0],
		"levels": [
			{"id": "level_01", "name": "L1", "elevation": 0.0, "default_height": 3.0}
		]
	}
	var e_miss = SCENE_TYPES.SceneElement.new()
	e_miss.id = "elem_missing_level"
	e_miss.level_id = "non_existent_level"
	sp_doc.elements.append(e_miss)

	var e_oob = SCENE_TYPES.SceneElement.new()
	e_oob.id = "elem_oob"
	e_oob.level_id = "level_01"
	e_oob.transform = SCENE_TYPES.SceneTransform.new()
	e_oob.transform.position = Vector3(0.0, 0.0, 10.0) # Level is [0.0, 3.0]
	sp_doc.elements.append(e_oob)

	var sp_report = validator.validate_document(sp_doc)
	var has_level_missing := false
	var has_oob := false
	for d in sp_report.get("diagnostics", []):
		if d.get("rule_id") == "ELEM_001_LEVEL_NOT_FOUND":
			has_level_missing = true
		if d.get("rule_id") == "SPATIAL_001_ELEVATION_OUT_OF_BOUNDS":
			has_oob = true
	if not has_level_missing:
		push_error("Failed to detect ELEM_001_LEVEL_NOT_FOUND: %s" % str(sp_report))
		quit(1)
		return
	if not has_oob:
		push_error("Failed to detect SPATIAL_001_ELEVATION_OUT_OF_BOUNDS: %s" % str(sp_report))
		quit(1)
		return
	print("  [PASS] Spatial level existence and elevation bounds verified (ELEM_001, SPATIAL_001)")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 5: Synthetic Validation - Direction Mismatch & Cardinality Exceeded
	# ─────────────────────────────────────────────────────────────────────────────
	var port_doc = SCENE_TYPES.SceneDocument.new()
	var ea = SCENE_TYPES.SceneElement.new()
	ea.id = "ea"
	var p_in1 = SCENE_TYPES.ScenePort.new()
	p_in1.id = "p_in1"
	p_in1.kind = "flow"
	p_in1.direction = "input"
	p_in1.cardinality = "one"
	ea.input_ports.append(p_in1)

	var p_out1 = SCENE_TYPES.ScenePort.new()
	p_out1.id = "p_out1"
	p_out1.kind = "flow"
	p_out1.direction = "output"
	ea.output_ports.append(p_out1)

	var eb = SCENE_TYPES.SceneElement.new()
	eb.id = "eb"
	var p_out2 = SCENE_TYPES.ScenePort.new()
	p_out2.id = "p_out2"
	p_out2.kind = "flow"
	p_out2.direction = "output"
	eb.output_ports.append(p_out2)

	port_doc.elements.append(ea)
	port_doc.elements.append(eb)

	# Connection 1: Connect input port to input port (direction mismatch)
	var c_bad_dir = SCENE_TYPES.SceneConnection.new()
	c_bad_dir.id = "c_dir"
	c_bad_dir.source_element = "ea"
	c_bad_dir.source_port = "p_in1"
	c_bad_dir.target_element = "ea"
	c_bad_dir.target_port = "p_in1"
	port_doc.connections.append(c_bad_dir)

	# Connections 2 & 3: Exceed cardinality 'one' on p_in1
	var c_card1 = SCENE_TYPES.SceneConnection.new()
	c_card1.id = "c_card1"
	c_card1.source_element = "ea"
	c_card1.source_port = "p_out1"
	c_card1.target_element = "ea"
	c_card1.target_port = "p_in1"
	port_doc.connections.append(c_card1)

	var c_card2 = SCENE_TYPES.SceneConnection.new()
	c_card2.id = "c_card2"
	c_card2.source_element = "eb"
	c_card2.source_port = "p_out2"
	c_card2.target_element = "ea"
	c_card2.target_port = "p_in1"
	port_doc.connections.append(c_card2)

	var port_report = validator.validate_document(port_doc)
	var has_dir_mismatch := false
	var has_card_exceeded := false
	for d in port_report.get("diagnostics", []):
		if d.get("rule_id") == "PORT_003_DIRECTION_MISMATCH":
			has_dir_mismatch = true
		if d.get("rule_id") == "PORT_004_CARDINALITY_EXCEEDED":
			has_card_exceeded = true
	if not has_dir_mismatch:
		push_error("Failed to detect PORT_003_DIRECTION_MISMATCH: %s" % str(port_report))
		quit(1)
		return
	if not has_card_exceeded:
		push_error("Failed to detect PORT_004_CARDINALITY_EXCEEDED: %s" % str(port_report))
		quit(1)
		return
	print("  [PASS] Port direction and cardinality validation verified (PORT_003, PORT_004)")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 6: Synthetic Validation - Zero-Delay Cycle Detection (GRAPH_002_ZERO_DELAY_CYCLE)
	# ─────────────────────────────────────────────────────────────────────────────
	var cycle_doc = SCENE_TYPES.SceneDocument.new()
	var j1 = SCENE_TYPES.SceneElement.new()
	j1.id = "j1"
	j1.kind = "junction" # non-stateful
	var j1_in = SCENE_TYPES.ScenePort.new()
	j1_in.id = "in"
	j1_in.kind = "flow"
	j1_in.direction = "input"
	var j1_out = SCENE_TYPES.ScenePort.new()
	j1_out.id = "out"
	j1_out.kind = "flow"
	j1_out.direction = "output"
	j1.input_ports.append(j1_in)
	j1.output_ports.append(j1_out)

	var j2 = SCENE_TYPES.SceneElement.new()
	j2.id = "j2"
	j2.kind = "junction" # non-stateful
	var j2_in = SCENE_TYPES.ScenePort.new()
	j2_in.id = "in"
	j2_in.kind = "flow"
	j2_in.direction = "input"
	var j2_out = SCENE_TYPES.ScenePort.new()
	j2_out.id = "out"
	j2_out.kind = "flow"
	j2_out.direction = "output"
	j2.input_ports.append(j2_in)
	j2.output_ports.append(j2_out)

	cycle_doc.elements.append(j1)
	cycle_doc.elements.append(j2)

	var c_1to2 = SCENE_TYPES.SceneConnection.new()
	c_1to2.id = "c_1to2"
	c_1to2.source_element = "j1"
	c_1to2.source_port = "out"
	c_1to2.target_element = "j2"
	c_1to2.target_port = "in"
	c_1to2.link_type = "flow"
	c_1to2.latency = 0.0 # Zero delay!
	cycle_doc.connections.append(c_1to2)

	var c_2to1 = SCENE_TYPES.SceneConnection.new()
	c_2to1.id = "c_2to1"
	c_2to1.source_element = "j2"
	c_2to1.source_port = "out"
	c_2to1.target_element = "j1"
	c_2to1.target_port = "in"
	c_2to1.link_type = "flow"
	c_2to1.latency = 0.0 # Zero delay!
	cycle_doc.connections.append(c_2to1)

	var cycle_report = validator.validate_document(cycle_doc)
	var has_cycle := false
	for d in cycle_report.get("diagnostics", []):
		if d.get("rule_id") == "GRAPH_002_ZERO_DELAY_CYCLE" and d.get("severity") == "error":
			has_cycle = true
			break
	if not has_cycle:
		push_error("Failed to detect zero-delay cycle GRAPH_002_ZERO_DELAY_CYCLE: %s" % str(cycle_report))
		quit(1)
		return
	print("  [PASS] Zero-delay cycle / livelock detection verified (GRAPH_002_ZERO_DELAY_CYCLE)")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 7: Strict Mode Required Ports (PORT_005_REQUIRED_UNCONNECTED)
	# ─────────────────────────────────────────────────────────────────────────────
	var req_doc = SCENE_TYPES.SceneDocument.new()
	var er = SCENE_TYPES.SceneElement.new()
	er.id = "er"
	var pr = SCENE_TYPES.ScenePort.new()
	pr.id = "req_in"
	pr.kind = "flow"
	pr.direction = "input"
	pr.required = true
	er.input_ports.append(pr)
	req_doc.elements.append(er)

	# Draft mode (strict=false) -> no warning
	var draft_report = validator.validate_document(req_doc, false)
	var has_req_draft := false
	for d in draft_report.get("diagnostics", []):
		if d.get("rule_id") == "PORT_005_REQUIRED_UNCONNECTED":
			has_req_draft = true
	if has_req_draft:
		push_error("Draft mode unexpectedly flagged PORT_005_REQUIRED_UNCONNECTED!")
		quit(1)
		return

	# Strict mode (strict=true) -> warning
	var strict_report = validator.validate_document(req_doc, true)
	var has_req_strict := false
	for d in strict_report.get("diagnostics", []):
		if d.get("rule_id") == "PORT_005_REQUIRED_UNCONNECTED":
			has_req_strict = true
	if not has_req_strict:
		push_error("Strict mode failed to flag PORT_005_REQUIRED_UNCONNECTED!")
		quit(1)
		return
	print("  [PASS] Strict mode required unconnected port verified (PORT_005_REQUIRED_UNCONNECTED)")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 8: ABM Model Configuration Rules (ABM_001_INVALID_MODEL)
	# ─────────────────────────────────────────────────────────────────────────────
	var abm_path := "res://fixtures/scenespec/minimal_abm.json"
	var abm_file := FileAccess.open(abm_path, FileAccess.READ)
	var abm_doc = codec.load_document(abm_file.get_as_text())
	abm_file.close()

	# 8a. Unregistered model name generates warning, remains is_valid == true
	abm_doc.abm_config["model_name"] = "CustomFlocking"
	var abm_warn_report = validator.validate_document(abm_doc)
	if not abm_warn_report.get("is_valid", false):
		push_error("Unregistered ABM model name unexpectedly marked scene invalid!")
		quit(1)
		return
	var has_abm_warn := false
	for d in abm_warn_report.get("diagnostics", []):
		if d.get("rule_id") == "ABM_001_INVALID_MODEL" and d.get("severity") == "warning":
			has_abm_warn = true
			break
	if not has_abm_warn:
		push_error("Expected ABM_001_INVALID_MODEL warning for CustomFlocking, none found!")
		quit(1)
		return

	# 8b. Empty model name generates error
	abm_doc.abm_config["model_name"] = ""
	var abm_err_report = validator.validate_document(abm_doc)
	if abm_err_report.get("is_valid", false):
		push_error("Empty ABM model name unexpectedly marked scene valid!")
		quit(1)
		return
	var has_abm_err := false
	for d in abm_err_report.get("diagnostics", []):
		if d.get("rule_id") == "ABM_001_INVALID_MODEL" and d.get("severity") == "error":
			has_abm_err = true
			break
	if not has_abm_err:
		push_error("Expected ABM_001_INVALID_MODEL error for empty model_name, none found!")
		quit(1)
		return
	print("  [PASS] ABM model configuration rules verified (ABM_001 warning and error modes)")

	# ─────────────────────────────────────────────────────────────────────────────
	# Test 9: Codec validator delegation method tests
	# ─────────────────────────────────────────────────────────────────────────────
	var is_valid_via_codec: bool = codec.is_document_valid(req_doc)
	if not is_valid_via_codec:
		push_error("codec.is_document_valid failed for valid req_doc")
		quit(1)
		return
	var diags_via_codec: Dictionary = codec.validate_document(inv_doc)
	if diags_via_codec.get("is_valid", true):
		push_error("codec.validate_document unexpectedly passed inv_doc")
		quit(1)
		return
	print("  [PASS] Codec delegation methods (is_document_valid, validate_document) verified")

	print("================================================================================")
	print("All SimVizSceneValidator Godot smoke tests PASSED successfully!")
	print("================================================================================")
	quit(0)

