extends SceneTree

const CatalogClass := preload("res://scripts/authoring_catalog.gd")
const SceneTypes := preload("res://scripts/scenespec_types.gd")
const BlockNode := preload("res://scripts/authoring_block_node.gd")
const Canvas2DClass := preload("res://scripts/authoring_2d_canvas.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const MeshFactory := preload("res://scripts/authoring_mesh_factory.gd")

func _init() -> void:
	print("==================================================================")
	print("Starting Modular Chart Entity Blocks Smoke Test (Phase 7D-12E)...")
	print("==================================================================")

	var catalog = CatalogClass.new()

	print("Step 1: Validating catalog entries for Instrumentation & Scopes...")
	var chart_kinds := ["scope_2d", "digital_meter", "histogram_sink", "state_space_3d", "xy_scatter"]
	for k in chart_kinds:
		var entry = catalog.get_entry(k)
		assert(entry != null, "Catalog must contain entry for: %s" % k)
		assert(entry.category == "Instrumentation & Scopes", "Category for %s must be 'Instrumentation & Scopes'" % k)
		assert(entry.default_input_ports.size() > 0, "%s must have input signal ports" % k)
		assert(entry.default_dimensions.x >= 5.0, "%s width must be >= 5.0m for readable screen" % k)
		print("  ✓ Verified catalog entry: %s (%s)" % [entry.display_name, entry.kind])
	print("Step 1 PASSED: All 5 modular chart blocks present and verified in catalog.")

	print("Step 2: Testing BlockNode instantiation and specialized bay layout...")
	var scope_elem := catalog.create_element_instance("scope_2d", "scope_01", Vector2(10, 10))
	var scope_node := BlockNode.new(scope_elem, null)
	root.add_child(scope_node)
	scope_node.rebuild_ports()

	var layout: Dictionary = scope_node.get_bay_layout()
	assert(layout["has_sig_in"] == true, "Scope must have has_sig_in == true")
	assert(layout["has_flow_in"] == false, "Scope must not have flow_in")
	assert(layout["has_flow_out"] == false, "Scope must not have flow_out")
	assert(layout["left_w"] == 24.0, "Scope left bay width should be 24.0px")
	assert(layout["right_w"] == 0.0, "Scope right bay width should be 0.0px")
	assert(layout["col_sig_x"] == 12.0, "Signal input socket should be at x=12.0px")
	assert(scope_node.size.x >= 120.0, "Scope card width must be >= 120px")
	assert(scope_node.size.y >= 75.0, "Scope card height must be >= 75px")

	var port_info: Dictionary = scope_node.get_port_info("sig_in")
	assert(!port_info.is_empty(), "Scope must register 'sig_in' port socket")
	assert(port_info["kind"] == "signal", "'sig_in' port kind must be signal")
	print("Step 2 PASSED: Bay layout and socket geometry verified.")

	print("Step 3: Testing feeding live signal values into Scope and Digital Meter...")
	var meter_elem := catalog.create_element_instance("digital_meter", "meter_01", Vector2(30, 10))
	var meter_node := BlockNode.new(meter_elem, null)
	root.add_child(meter_node)
	meter_node.rebuild_ports()

	for i in range(10):
		var test_val: float = float(i) * 3.5
		scope_node.feed_signal_value("sig_in", test_val, float(i))
		meter_node.feed_signal_value("sig_in", test_val, float(i))

	assert(scope_node.signal_history.size() == 10, "Scope must record 10 points in history")
	assert(is_equal_approx(scope_node.signal_values.get("sig_in", 0.0), 31.5), "Latest scope signal value must be 31.5")
	assert(is_equal_approx(meter_node.signal_values.get("sig_in", 0.0), 31.5), "Latest meter signal value must be 31.5")
	print("Step 3 PASSED: Signal ingestion and buffer maintenance verified.")

	print("Step 4: Testing 2D Canvas signal telemetry wire routing...")
	var doc_store := DocumentStore.new()
	var doc := SceneTypes.SceneDocument.new()

	var q_elem := catalog.create_element_instance("queue", "queue_01", Vector2(5, 5))
	doc.elements.append(q_elem)
	doc.elements.append(scope_elem)
	doc.elements.append(meter_elem)

	# Wire queue_01:length -> scope_01:sig_in
	var conn_scope := SceneTypes.SceneConnection.new()
	conn_scope.id = "conn_scope_1"
	conn_scope.source_element = "queue_01"
	conn_scope.source_port = "length"
	conn_scope.target_element = "scope_01"
	conn_scope.target_port = "sig_in"
	conn_scope.link_type = "signal"
	doc.connections.append(conn_scope)

	# Wire queue_01:occupancy -> meter_01:sig_in
	var conn_meter := SceneTypes.SceneConnection.new()
	conn_meter.id = "conn_meter_1"
	conn_meter.source_element = "queue_01"
	conn_meter.source_port = "occupancy"
	conn_meter.target_element = "meter_01"
	conn_meter.target_port = "sig_in"
	conn_meter.link_type = "signal"
	doc.connections.append(conn_meter)

	doc_store.active_document = doc

	var canvas := Canvas2DClass.new()
	canvas.doc_store = doc_store
	root.add_child(canvas)
	canvas.rebuild_blocks()

	# Simulate incoming live telemetry from Julia engine
	var sim_telemetry := {
		"queue_01": {
			"type": "queue",
			"metrics": {
				"queue_length": 14.0,
				"occupancy_pct": 70.0,
				"wait_mean_wq": 5.2
			}
		}
	}
	canvas.update_element_telemetry(sim_telemetry)

	var live_scope_node = canvas._block_nodes.get("scope_01")
	var live_meter_node = canvas._block_nodes.get("meter_01")
	assert(live_scope_node != null, "Canvas must have spawned scope block node")
	assert(live_meter_node != null, "Canvas must have spawned meter block node")
	assert(is_equal_approx(live_scope_node.signal_values.get("sig_in", 0.0), 14.0), "Scope must have received queue_length = 14.0")
	assert(is_equal_approx(live_meter_node.signal_values.get("sig_in", 0.0), 70.0), "Meter must have received occupancy_pct = 70.0")
	print("Step 4 PASSED: 2D Canvas live signal routing from station metrics to scopes verified.")

	print("Step 5: Testing 3D Mesh Factory procedural kiosk generation...")
	var kiosk_3d := MeshFactory.create_3d_node_for_element(scope_elem)
	assert(kiosk_3d != null, "MeshFactory must create 3D node for scope_2d")
	assert(kiosk_3d.get_child_count() >= 3, "Scope kiosk must have base plate, pedestal post, and console head")
	var head_node = kiosk_3d.get_child(2)
	assert(head_node.get_child_count() >= 2, "Console head must contain casing and display screen")
	print("Step 5 PASSED: 3D industrial monitoring kiosk node hierarchy verified.")

	print("==================================================================")
	print("ALL MODULAR CHART ENTITY BLOCK SMOKE TESTS PASSED (100%)!")
	print("==================================================================")
	quit(0)
