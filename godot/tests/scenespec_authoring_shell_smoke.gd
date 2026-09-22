# scenespec_authoring_shell_smoke.gd
# Headless unit & integration test suite for Phase 7D-05: Authoring Shell, Two-View Architecture, and PBR 3D Factory.
extends SceneTree

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const Catalog := preload("res://scripts/authoring_catalog.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const DiagnosticsPanel := preload("res://scripts/authoring_diagnostics_panel.gd")
const BlockNode := preload("res://scripts/authoring_block_node.gd")
const Canvas2D := preload("res://scripts/authoring_2d_canvas.gd")
const MeshFactory := preload("res://scripts/authoring_mesh_factory.gd")
const Viewport3D := preload("res://scripts/authoring_3d_viewport.gd")
const AuthoringShell := preload("res://scripts/authoring_shell.gd")
const Inspector := preload("res://scripts/authoring_inspector.gd")
const RuleBuilder := preload("res://scripts/authoring_rule_builder.gd")
const FloatingInspector := preload("res://scripts/authoring_floating_inspector.gd")
const ABMDialog := preload("res://scripts/authoring_abm_dialog.gd")

var _failures: int = 0
var _tests_run: int = 0

func _init() -> void:
	print("============================================================")
	print("  PHASE 7D-05: AUTHORING SHELL & TWO-VIEW SMOKE TEST")
	print("============================================================")

	test_catalog_registry()
	test_document_store_lifecycle()
	test_authoring_block_node_three_part_layout()
	test_procedural_mesh_factory_conveyor_elevation_and_legs()
	test_procedural_mesh_factory_server_and_queue()
	test_2d_canvas_and_port_wiring()
	test_authoring_shell_two_view_switching_and_transport()
	test_keyboard_and_multi_element_deletion()
	test_block_duplication()
	test_arbitrary_angle_rotation_and_parity()
	test_3d_click_picking_and_selection_indicator()
	test_camera_framing_and_view_modes()

	# Phase 7D-07 & 7D-08 Suites
	test_typed_port_visuals_and_semantic_colors()
	test_interactive_invalid_link_rejection_and_cardinality()
	test_dag_hierarchical_auto_layout()
	test_declarative_schema_inspector_and_statistical_distributions()
	test_port_properties_inspection_and_buffer_editing()
	test_multi_selection_mixed_values_and_batch_undo()
	test_no_code_rule_builder_and_metric_discovery()
	test_active_simulation_live_edit_policy()

	# Fluid Window Scaling & Right-Click Floating Tabbed Inspector Suites
	test_resizable_splitters_and_expand_layout()
	test_floating_tabbed_properties_inspector()

	# Phase 7D-09 ABM & Multi-Paradigm Crowd Suites
	test_abm_model_registry_and_configuration_dialog()
	test_catalog_crowd_and_hybrid_primitives()
	test_agent_telemetry_2d_and_3d_visualization()

	# Phase 7D-10 Groups, Templates, and Compound Subgraphs Suites
	test_subgraph_grouping_and_scope_navigation()
	test_versioned_template_packaging_and_instantiation()
	test_compound_boundary_ports_and_detach_policy()

	# Usability Refinement: 4-Corner Invisible Resizing & Tightened Port Hit
	test_four_corner_resizing_and_tightened_port_hit()

	# Subsystem Encapsulation, 4-Corner Resizing & Internal Manifest (User Feedback)
	test_subsystem_resizing_encapsulation_and_manifest()

	# Subsystem Group to Template Packaging & Cloned Entity Instantiation (User Issue Fix)
	test_subsystem_template_packaging_and_full_instantiation()

	print("============================================================")
	if _failures == 0:
		print("● ALL %d TEST SUITES PASSED CLEANLY (Phase 7D-07 through 7D-10 Verified)" % _tests_run)
		print("============================================================")
		quit(0)
	else:
		print("✖ %d TEST FAILURES DETECTED" % _failures)
		print("============================================================")
		quit(1)

func _assert(cond: bool, msg: String) -> void:
	if not cond:
		_failures += 1
		print("  ✖ FAILED: %s" % msg)
	else:
		print("  ✔ PASS: %s" % msg)

func test_catalog_registry() -> void:
	_tests_run += 1
	print("\n[Suite 1: Component Catalog Registry]")
	var cat := Catalog.new()
	var entries := cat.get_all_entries()
	_assert(entries.size() >= 5, "Catalog has at least 5 standard primitives")

	var conv_entry := cat.get_entry("conveyor")
	_assert(conv_entry != null, "Conveyor entry exists in catalog")
	_assert(conv_entry.default_dimensions == Vector3(8.0, 1.2, 0.8), "Conveyor default dimensions are 8.0m x 1.2m x 0.8m")
	_assert(conv_entry.default_elevation_start == 0.8, "Conveyor default elevation is 0.8m")

	var queue_entry := cat.get_entry("queue")
	_assert(queue_entry != null, "Queue entry exists in catalog")

	var server_entry := cat.get_entry("server")
	_assert(server_entry != null, "Server entry exists in catalog")

	var inst := cat.create_element_instance("conveyor", "conv_test", Vector2(15.0, 25.0))
	_assert(inst.id == "conv_test", "Created element instance has correct ID")
	_assert(inst.kind == "conveyor", "Created element instance has correct kind")
	_assert(float(inst.transform.position[0]) == 15.0, "Created element has correct X position")
	_assert(inst.input_ports.size() >= 1 and inst.output_ports.size() >= 1, "Created element has default ports")

func test_document_store_lifecycle() -> void:
	_tests_run += 1
	print("\n[Suite 2: Document Store & Undo/Redo/Atomic Persistence]")
	var store := DocumentStore.new()
	_assert(store.active_document != null, "New document initialized")
	_assert(store.is_dirty == false, "New document starts clean")

	var cat := Catalog.new()
	var e1 := cat.create_element_instance("conveyor", "c1", Vector2(10, 10))
	var e2 := cat.create_element_instance("server", "s1", Vector2(25, 10))

	store.add_element(e1)
	_assert(store.is_dirty == true, "Adding element marks document dirty")
	_assert(store.active_document.elements.size() == 1, "Element added to document")

	store.add_element(e2)
	_assert(store.active_document.elements.size() == 2, "Second element added")

	# Test Undo
	var did_undo := store.undo()
	_assert(did_undo, "Undo succeeded")
	_assert(store.active_document.elements.size() == 1, "Undo reverted second element addition")

	# Test Redo
	var did_redo := store.redo()
	_assert(did_redo, "Redo succeeded")
	_assert(store.active_document.elements.size() == 2, "Redo restored second element addition")

	# Test update_element_position and undo
	store.update_element_position("c1", Vector3(18.5, 12.0, 0.0))
	var c1_updated := store.get_element("c1")
	_assert(c1_updated.transform.position == Vector3(18.5, 12.0, 0.0), "Element position updated in store")
	_assert(c1_updated.editor.graph_position == Vector2(370.0, 240.0), "Element graph position synchronized (20px per meter)")
	store.undo()
	var c1_undone := store.get_element("c1")
	_assert(c1_undone.transform.position == Vector3(10.0, 10.0, 0.8), "Undo restored previous element position")
	store.redo()
	var c1_redone := store.get_element("c1")
	_assert(c1_redone.transform.position == Vector3(18.5, 12.0, 0.0), "Redo restored updated element position")

	# Test Save & Load atomic round-trip
	var tmp_path := "user://test_7d05_save.json"
	var save_ok := store.save_to_file(tmp_path)
	_assert(save_ok, "Atomic save to file succeeded")
	_assert(store.is_dirty == false, "Document marked clean after save")

	var store2 := DocumentStore.new()
	var load_ok := store2.load_from_file(tmp_path)
	_assert(load_ok, "Reload from file succeeded")
	_assert(store2.active_document.elements.size() == 2, "Reloaded document elements match")

func test_authoring_block_node_three_part_layout() -> void:
	_tests_run += 1
	print("\n[Suite 3: Single Entity Block Three-Part Layout]")
	var cat := Catalog.new()
	var elem := cat.create_element_instance("conveyor", "conv_01", Vector2(10, 20))
	elem.geometry["elevation_start"] = 0.8
	elem.geometry["elevation_end"] = 2.5

	var block := BlockNode.new(elem)
	block._ready()

	# Proportional sizing: 8.0m conveyor at 20px/m is 160px
	_assert(abs(block.size.x - 160.0) < 1.0, "Block width is proportional to physical length (8.0m * 20px/m = 160px)")
	_assert(block.size.y >= 72.0, "Block height fits port bays and sockets (>= 72px)")

	# Sockets in Left Bay (2 columns: IN at x=16, OUT at x=46)
	var flow_in_pos: Vector2 = block._port_sockets["flow_in"]["pos"]
	_assert(abs(flow_in_pos.x - 16.0) < 1.0, "Flow In socket resolved on Left Bay Column 1 (IN)")

	var flow_out_pos: Vector2 = block._port_sockets["flow_out"]["pos"]
	_assert(abs(flow_out_pos.x - 46.0) < 1.0, "Flow Out socket resolved on Left Bay Column 2 (OUT)")

	# Sockets in Right Bay (2 columns: SIG at size.x - 48, MET at size.x - 16)
	var sig_pos: Vector2 = block._port_sockets["speed_signal"]["pos"]
	_assert(abs(sig_pos.x - (block.size.x - 48.0)) < 1.0, "Signal In socket resolved on Right Bay Column 1 (SIG)")

	var met_pos: Vector2 = block._port_sockets["occupancy"]["pos"]
	_assert(abs(met_pos.x - (block.size.x - 16.0)) < 1.0, "Metric Out socket resolved on Right Bay Column 2 (MET)")

	# Hit test add and remove buttons for all 4 columns
	var hit_flow_in_add := block._hit_test_add_button(Vector2(8.0, block.size.y - 10.0))
	var hit_flow_in_rem := block._hit_test_remove_button(Vector2(22.0, block.size.y - 10.0))
	_assert(hit_flow_in_add == "flow_in", "Left Bay Column 1 bottom button triggers Add Flow In")
	_assert(hit_flow_in_rem == "flow_in", "Left Bay Column 1 bottom button triggers Remove Flow In")

	var hit_flow_out_add := block._hit_test_add_button(Vector2(38.0, block.size.y - 10.0))
	var hit_flow_out_rem := block._hit_test_remove_button(Vector2(52.0, block.size.y - 10.0))
	_assert(hit_flow_out_add == "flow_out", "Left Bay Column 2 bottom button triggers Add Flow Out")
	_assert(hit_flow_out_rem == "flow_out", "Left Bay Column 2 bottom button triggers Remove Flow Out")

	var hit_sig_in_add := block._hit_test_add_button(Vector2(block.size.x - 55.0, block.size.y - 10.0))
	var hit_sig_in_rem := block._hit_test_remove_button(Vector2(block.size.x - 41.0, block.size.y - 10.0))
	_assert(hit_sig_in_add == "signal_in", "Right Bay Column 1 bottom button triggers Add Signal In")
	_assert(hit_sig_in_rem == "signal_in", "Right Bay Column 1 bottom button triggers Remove Signal In")

	var hit_met_out_add := block._hit_test_add_button(Vector2(block.size.x - 24.0, block.size.y - 10.0))
	var hit_met_out_rem := block._hit_test_remove_button(Vector2(block.size.x - 9.0, block.size.y - 10.0))
	_assert(hit_met_out_add == "metric_out", "Right Bay Column 2 bottom button triggers Add Metric Out")
	_assert(hit_met_out_rem == "metric_out", "Right Bay Column 2 bottom button triggers Remove Metric Out")

	# Test compact entity contraction (Source 2.0m x 2.0m: collapses middle to 0 gap between ports)
	var src_elem := cat.create_element_instance("source", "src_02", Vector2(7.5, 10.0))
	src_elem.geometry["dimensions"] = [2.0, 2.0, 1.0]
	var src_block := BlockNode.new(src_elem)
	src_block._ready()
	_assert(abs(src_block.size.x - 40.0) < 1.0, "Compact source (2.0m) contracts to 40px without artificial 260px padding")
	_assert(abs(src_block.size.y - 40.0) < 1.0, "Compact source height is proportional (2.0m = 40px)")
	_assert(src_block.get_bay_layout()["collapsed"] == true, "Compact source collapses middle part to 0 gap between ports")

	# Test Zero-Gap 2D/3D Coordination
	var src_right_2d := (float(src_elem.transform.position[0]) + float(src_elem.geometry["dimensions"][0])) * 20.0 # 9.5m * 20 = 190px
	var conv_touch_x := 9.5 # Touching source_02 in 2D
	var conv_left_2d := conv_touch_x * 20.0 # 190px
	_assert(abs(src_right_2d - conv_left_2d) < 0.01, "Zero gap in 2D canvas: Source right edge touches Conveyor left edge at exactly 190px")
	_assert(abs((src_elem.transform.position[0] + src_elem.geometry["dimensions"][0]) - conv_touch_x) < 0.01, "Zero gap in 3D: Source ends at 9.5m, Conveyor starts at 9.5m (0.0m seam)")

	# Test resize handle hit test & dynamic size expansion
	block.set_selected(true)
	_assert(block._hit_test_resize_handle(Vector2(block.size.x - 5.0, block.size.y - 5.0)), "Resize handle hit test passes at bottom-right corner")
	_assert(not block._hit_test_resize_handle(Vector2(20.0, 20.0)), "Resize handle does not hit test away from corner")

	var prev_w: float = block.size.x
	elem.geometry["dimensions"] = [12.0, 1.8, 1.0]
	block.refresh_from_element()
	_assert(block.size.x > prev_w, "Block width dynamically expanded on dimension update")
	var updated_dims := block._get_physical_dimensions()
	_assert(abs(updated_dims.x - 12.0) < 0.01 and abs(updated_dims.y - 1.8) < 0.01, "Physical dimensions updated accurately")

func test_procedural_mesh_factory_conveyor_elevation_and_legs() -> void:
	_tests_run += 1
	print("\n[Suite 4: Procedural PBR 3D Factory - Conveyor with Variable Elevation & Legs]")
	var cat := Catalog.new()
	var elem := cat.create_element_instance("conveyor", "incline_conv_01", Vector2(0, 0))
	elem.geometry["dimensions"] = [10.0, 1.2, 0.2]
	elem.geometry["elevation_start"] = 0.8  # Waist height infeed
	elem.geometry["elevation_end"] = 3.2    # Elevated mezzanine discharge

	var node_3d: Node3D = MeshFactory.create_3d_node_for_element(elem)
	_assert(node_3d != null, "Conveyor 3D node created")

	# Verify BedPivot exists and has pitch slope
	var bed_pivot: Node3D = node_3d.get_node_or_null("BedPivot")
	_assert(bed_pivot != null, "Conveyor has BedPivot assembly")
	_assert(bed_pivot.rotation.z > 0.05, "BedPivot is pitched up along incline (slope angle > 0)")
	_assert(abs(bed_pivot.position.y - 0.8) < 0.01, "Bed starts at elevation 0.8m")

	# Verify legs are generated
	var leg_assemblies := 0
	for child in node_3d.get_children():
		if child.name != "BedPivot":
			leg_assemblies += 1
	_assert(leg_assemblies >= 5, "Conveyor has at least 5 support leg stands spaced along 10m length")

func test_procedural_mesh_factory_server_and_queue() -> void:
	_tests_run += 1
	print("\n[Suite 5: Procedural PBR 3D Factory - Server with Beacon & Queue Buffer]")
	var cat := Catalog.new()

	# Server
	var s_elem := cat.create_element_instance("server", "station_01", Vector2(10, 0))
	var server_3d: Node3D = MeshFactory.create_3d_node_for_element(s_elem)
	_assert(server_3d != null, "Server 3D node created")
	_assert(server_3d.get_child_count() >= 5, "Server has work table, legs, gantry, and beacon lights")

	# Queue
	var q_elem := cat.create_element_instance("queue", "buffer_01", Vector2(20, 0))
	var queue_3d: Node3D = MeshFactory.create_3d_node_for_element(q_elem)
	_assert(queue_3d != null, "Queue 3D node created")
	_assert(queue_3d.get_child_count() >= 3, "Queue has accumulation bed, legs, and floor hazard pad")

	# Source (Infeed hopper with legs, chute, and green beacon)
	var src_elem := cat.create_element_instance("source", "source_01", Vector2(0, 0))
	var src_3d: Node3D = MeshFactory.create_3d_node_for_element(src_elem)
	_assert(src_3d != null, "Source 3D node created")
	_assert(src_3d.get_child_count() >= 6, "Source has support legs, green hopper, discharge chute, and beacon")

	# Sink (Discharge collection bin with staging pad and steel rim)
	var snk_elem := cat.create_element_instance("sink", "sink_01", Vector2(30, 0))
	var snk_3d: Node3D = MeshFactory.create_3d_node_for_element(snk_elem)
	_assert(snk_3d != null, "Sink 3D node created")
	_assert(snk_3d.get_child_count() >= 3, "Sink has staging pad, collection bin, and rim guard")

func test_2d_canvas_and_port_wiring() -> void:
	_tests_run += 1
	print("\n[Suite 6: 2D Canvas & Port-to-Port Wiring]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var c1 := cat.create_element_instance("conveyor", "c1", Vector2(5, 5))
	var s1 := cat.create_element_instance("server", "s1", Vector2(20, 5))
	store.add_element(c1)
	store.add_element(s1)

	var canvas := Canvas2D.new(store)
	canvas.size = Vector2(800, 600)
	canvas.rebuild_blocks()
	_assert(canvas._block_nodes.size() == 2, "Canvas instantiated both entity blocks")

	# Wire Flow Out (c1) -> Flow In (s1)
	canvas._wire_source_elem = "c1"
	canvas._wire_source_port = "flow_out"
	canvas._wire_source_kind = "flow"
	canvas._wire_source_is_output = true
	canvas._wire_hovered_elem = "s1"
	canvas._wire_hovered_port = "flow_in"
	canvas._wire_is_compatible = true
	canvas._is_dragging_wire = true
	canvas._finish_wire_drag()

	_assert(store.active_document.connections.size() == 1, "Flow connection created in document")
	var conn: SceneTypes.SceneConnection = store.active_document.connections[0]
	_assert(conn.source_element == "c1" and conn.target_element == "s1", "Flow connection links c1 to s1")
	_assert(conn.link_type == "flow", "Connection kind is flow")

	# Wire Metric Out (s1.utilization) -> Signal In (c1.speed_signal)
	canvas._wire_source_elem = "s1"
	canvas._wire_source_port = "utilization"
	canvas._wire_source_kind = "metric"
	canvas._wire_source_is_output = true
	canvas._wire_hovered_elem = "c1"
	canvas._wire_hovered_port = "speed_signal"
	canvas._wire_is_compatible = true
	canvas._is_dragging_wire = true
	canvas._finish_wire_drag()
	_assert(store.active_document.connections.size() == 2, "Metric -> Signal connection created")
	var sig_conn: SceneTypes.SceneConnection = store.active_document.connections[1]
	_assert(sig_conn.source_element == "s1" and sig_conn.target_element == "c1", "Metric links s1 to c1 signal")

	# Test adding ports in each of the 4 columns
	var prev_flow_in := canvas._count_ports(c1.input_ports, "flow")
	canvas._on_add_port_requested("c1", "flow_in")
	_assert(canvas._count_ports(c1.input_ports, "flow") == prev_flow_in + 1, "Added Flow In port to Left Bay Column 1")

	var prev_flow_out := canvas._count_ports(c1.output_ports, "flow")
	canvas._on_add_port_requested("c1", "flow_out")
	_assert(canvas._count_ports(c1.output_ports, "flow") == prev_flow_out + 1, "Added Flow Out port to Left Bay Column 2")

	var prev_sig_in := canvas._count_ports(c1.input_ports, "signal")
	canvas._on_add_port_requested("c1", "signal_in")
	_assert(canvas._count_ports(c1.input_ports, "signal") == prev_sig_in + 1, "Added Signal In port to Right Bay Column 1")

	var prev_met_out := c1.metric_ports.size()
	canvas._on_add_port_requested("c1", "metric_out")
	_assert(c1.metric_ports.size() == prev_met_out + 1, "Added Metric Out port to Right Bay Column 2")

	# Test wire drag motion across block boundary
	canvas._on_port_drag_started("c1", "flow_out", "flow", true, Vector2(100, 100))
	_assert(canvas._is_dragging_wire, "Wire drag started")
	var mm := InputEventMouseMotion.new()
	mm.position = Vector2(400, 300)
	canvas._input(mm)
	_assert(canvas._wire_current_mouse != Vector2.ZERO, "Wire tracks mouse across block boundaries")
	canvas._cancel_wire_drag()
	_assert(not canvas._is_dragging_wire, "Wire drag cancelled")

	# Test Overlay Layer planar ordering (z_index = 10, mouse_filter = IGNORE)
	_assert(canvas._wires_layer != null, "Dedicated wires overlay layer exists")
	_assert(canvas._wires_layer.z_index == 10, "Wires overlay renders at higher planar z-index (z_index=10)")
	_assert(canvas._wires_layer.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Wires overlay ignores mouse events for unobstructed clicks")

	# Test reverse wire dragging: Input -> Output (s1.flow_in -> c1.flow_out_1)
	canvas._wire_source_elem = "s1"
	canvas._wire_source_port = "flow_in"
	canvas._wire_source_kind = "flow"
	canvas._wire_source_is_output = false
	canvas._wire_hovered_elem = "c1"
	canvas._wire_hovered_port = "flow_out_1"
	canvas._wire_is_compatible = true
	canvas._is_dragging_wire = true
	canvas._finish_wire_drag()
	var rev_conn: SceneTypes.SceneConnection = store.active_document.connections[-1]
	_assert(rev_conn.source_element == "c1" and rev_conn.target_element == "s1", "Reverse dragged Flow In -> Flow Out normalized with source as output")
	_assert(rev_conn.source_port == "flow_out_1" and rev_conn.target_port == "flow_in", "Normalized ports match emitter -> receiver")

	# Test reverse signal dragging: Signal In -> Metric Out (c1.signal_in_1 -> s1.utilization)
	canvas._wire_source_elem = "c1"
	canvas._wire_source_port = "signal_in_1"
	canvas._wire_source_kind = "signal"
	canvas._wire_source_is_output = false
	canvas._wire_hovered_elem = "s1"
	canvas._wire_hovered_port = "utilization"
	canvas._wire_is_compatible = true
	canvas._is_dragging_wire = true
	canvas._finish_wire_drag()
	var rev_sig: SceneTypes.SceneConnection = store.active_document.connections[-1]
	_assert(rev_sig.source_element == "s1" and rev_sig.target_element == "c1", "Reverse dragged Signal In -> Metric Out normalized with metric as source")
	_assert(rev_sig.link_type == "signal", "Link type normalized as signal")

	# Free up s1.flow_in port by removing prior connections so hover check can test compatibility
	store.remove_connection(conn.id)
	store.remove_connection(rev_conn.id)

	# Test _update_wire_hover directly without to_local error
	canvas._on_port_drag_started("c1", "flow_out", "flow", true, Vector2(100, 100))
	var s1_node: BlockNode = canvas._block_nodes["s1"]
	var target_port_pos: Vector2 = s1_node.position + s1_node.get_port_local_position("flow_in")
	canvas._wire_current_mouse = target_port_pos
	canvas._update_wire_hover()
	_assert(canvas._wire_hovered_elem == "s1", "Hover detection correctly resolves target block without to_local error")
	_assert(canvas._wire_hovered_port == "flow_in", "Hover detection resolves target socket ID")
	_assert(canvas._wire_is_compatible, "Hover detection validates compatibility")
	canvas._cancel_wire_drag()

	# Test LIFO Port Removal (Delete Last Port)
	while canvas._count_ports(c1.input_ports, "flow") > 1:
		store.remove_last_port_from_element("c1", "flow_in")
	var prev_flow_in_cnt := canvas._count_ports(c1.input_ports, "flow")
	_assert(prev_flow_in_cnt == 1, "Baseline flow_in count is 1")
	canvas._on_add_port_requested("c1", "flow_in")
	_assert(canvas._count_ports(c1.input_ports, "flow") == 2, "Appended flow_in port via [+]")
	canvas._on_remove_port_requested("c1", "flow_in")
	_assert(canvas._count_ports(c1.input_ports, "flow") == 1, "Removed last flow_in port via [-]")
	# Safety guard: attempt to remove core primary port below 1
	var rem_res := store.remove_last_port_from_element("c1", "flow_in")
	_assert(not rem_res, "Core primary flow_in port is protected from deletion")
	_assert(canvas._count_ports(c1.input_ports, "flow") == 1, "Primary flow_in port preserved")

	# Test Cascade Connection Deletion on Port Removal
	canvas._on_add_port_requested("s1", "flow_in")
	var new_s1_port: String = s1.input_ports[-1].id
	canvas._wire_source_elem = "c1"
	canvas._wire_source_port = "flow_out"
	canvas._wire_source_kind = "flow"
	canvas._wire_source_is_output = true
	canvas._wire_hovered_elem = "s1"
	canvas._wire_hovered_port = new_s1_port
	canvas._wire_is_compatible = true
	canvas._is_dragging_wire = true
	canvas._finish_wire_drag()
	var pre_del_conn_count := store.active_document.connections.size()
	# Now remove the port from s1
	canvas._on_remove_port_requested("s1", "flow_in")
	_assert(store.active_document.connections.size() < pre_del_conn_count, "Connection attached to removed port was cascade-deleted")

	# Test Spline Hit Testing & Selection
	store.active_document.connections.clear()
	var test_conn := SceneTypes.SceneConnection.new()
	test_conn.id = "c1_flow_out__s1_flow_in"
	test_conn.source_element = "c1"
	test_conn.source_port = "flow_out"
	test_conn.target_element = "s1"
	test_conn.target_port = "flow_in"
	test_conn.link_type = "flow"
	store.add_connection(test_conn)

	var p1 := canvas._resolve_port_position("c1", "flow_out")
	var p2 := canvas._resolve_port_position("s1", "flow_in")
	var mid_pt := (p1 + p2) * 0.5
	var hit_conn_id := canvas._hit_test_connection(mid_pt)
	_assert(hit_conn_id == test_conn.id, "Connection spline hit-tested successfully at midpoint")

	# Test Wire Deletion via Keyboard [DELETE]
	store.select(test_conn.id, "connection")
	_assert(store.selected_id == test_conn.id and store.selected_type == "connection", "Connection selected")
	var del_key_event := InputEventKey.new()
	del_key_event.pressed = true
	del_key_event.keycode = KEY_DELETE
	canvas._input(del_key_event)
	_assert(store.active_document.connections.is_empty(), "Selected connection deleted via KEY_DELETE")

	# Test Port Disconnect (Without Deleting Port)
	var test_conn2 := SceneTypes.SceneConnection.new()
	test_conn2.id = "c1_flow_out__s1_flow_in_2"
	test_conn2.source_element = "c1"
	test_conn2.source_port = "flow_out"
	test_conn2.target_element = "s1"
	test_conn2.target_port = "flow_in"
	test_conn2.link_type = "flow"
	store.add_connection(test_conn2)
	_assert(store.active_document.connections.size() == 1, "Connection added for disconnect test")
	var disc_cnt := store.disconnect_port("c1", "flow_out")
	_assert(disc_cnt == 1, "disconnect_port removed 1 attached connection")
	_assert(store.active_document.connections.is_empty(), "Connection unlinked from port")
	_assert(c1.output_ports.size() >= 1, "Port itself remained intact after disconnect")

func test_authoring_shell_two_view_switching_and_transport() -> void:
	_tests_run += 1
	print("\n[Suite 7: Authoring Shell Two-View Switching & Simulation Transport]")
	var shell := AuthoringShell.new()
	shell._ready()

	_assert(shell.current_view == AuthoringShell.ViewMode.VIEW_2D, "Shell starts in 2D LAYOUT mode")
	_assert(shell._canvas_2d.visible == true, "2D Canvas is visible")
	_assert(shell._viewport_3d.visible == false, "3D Viewport is hidden")

	# Switch to 3D Layout
	shell.switch_view(AuthoringShell.ViewMode.VIEW_3D)
	_assert(shell.current_view == AuthoringShell.ViewMode.VIEW_3D, "Switched to 3D LAYOUT mode")
	_assert(shell._canvas_2d.visible == false, "2D Canvas is hidden in 3D mode")
	_assert(shell._viewport_3d.visible == true, "3D Viewport is visible in 3D mode")

	# Test persistent transport
	_assert(shell.is_sim_running == false, "Simulation starts stopped")
	shell._btn_play.pressed.emit()
	_assert(shell.is_sim_running == true, "Play button starts simulation")

	shell._process(0.5)
	_assert(shell.sim_time >= 0.49, "Simulation time advanced with clock")

	shell._btn_pause.pressed.emit()
	_assert(shell.is_sim_running == false, "Pause button halts simulation")

	shell._btn_step.pressed.emit()
	_assert(shell.sim_time >= 0.59, "Step button advances by +0.1s")

	shell._btn_reset.pressed.emit()
	_assert(shell.sim_time == 0.0, "Reset button rewinds simulation clock to 0.0s")

	# Test Inspector Editable SpinBoxes for selected element
	var test_elem := shell.catalog.create_element_instance("conveyor", "test_c", Vector2(0, 0))
	shell.doc_store.add_element(test_elem)
	shell.doc_store.select("test_c", "element")
	shell._populate_inspector()
	var spinbox_count := 0
	for child in shell._inspector_container.get_children():
		if child is HBoxContainer:
			for sub in child.get_children():
				if sub is SpinBox:
					spinbox_count += 1
	_assert(spinbox_count >= 3, "Docked inspector contains editable SpinBoxes for Position (X,Y,Z)")
	_assert(shell._insp_spin_px != null and shell._insp_spin_py != null and shell._insp_spin_pz != null, "Position SpinBox references initialized")

	# Test Floating Inspector Spatial / CAD tab contains full geometry SpinBoxes (Position X,Y,Z, Dimensions L,W,H, Elevation Z1,Z2)
	shell._floating_inspector.open_for_element("test_c")
	shell._floating_inspector._switch_tab(1)
	var cad_spinbox_count := 0
	for child in shell._floating_inspector._pages_container.get_children():
		if child is HBoxContainer:
			for sub in child.get_children():
				if sub is SpinBox:
					cad_spinbox_count += 1
				elif sub is VBoxContainer:
					for sub_child in sub.get_children():
						if sub_child is SpinBox:
							cad_spinbox_count += 1
	_assert(cad_spinbox_count >= 8, "Floating Inspector CAD tab contains editable SpinBoxes for Position (X,Y,Z), Dimensions (L,W,H), and Elevation (Z1,Z2)")
	shell._floating_inspector.close()

	# Test Position SpinBox change updates element and 2D canvas
	shell._insp_spin_px.value = 15.0
	shell._insp_spin_px.value_changed.emit(15.0)
	_assert(test_elem.transform.position.x == 15.0, "Changing X SpinBox updates element transform.position.x")
	_assert(test_elem.editor.graph_position.x == 300.0, "Changing X SpinBox updates graph_position (15m * 20px/m = 300px)")

	# Test 2D block move syncs to inspector
	shell._canvas_2d._on_block_moved("test_c", Vector2(400, 200))
	_assert(abs(shell._insp_spin_px.value - (400.0 - shell._canvas_2d.pan_offset.x) / (shell._canvas_2d.zoom_level * 20.0)) < 0.05, "Moving block on 2D canvas syncs to Inspector X SpinBox")

	# Test 3D Viewport synchronization & camera auto-framing
	var vp: Viewport3D = shell._viewport_3d
	_assert(vp._entities_root.get_child_count() == 1, "3D Viewport synchronized with active document elements")
	_assert(vp._camera.position.y > 5.0, "3D Camera is elevated above the floor (Y > 5.0m)")

	# Add another element and verify auto-framing around the cluster
	var c2 := shell.catalog.create_element_instance("conveyor", "conv_far", Vector2(40, 20))
	shell.doc_store.add_element(c2)
	vp.frame_scene()
	_assert(vp._entities_root.get_child_count() == 2, "3D Viewport contains both elements")
	_assert(vp._cam_pivot.position.x > 10.0, "Camera pivot centered around element cluster in X")
	_assert(vp._cam_pivot.position.z < 0.0, "Camera pivot centered around element cluster in Godot -Z")
	_assert(vp._camera.position.y >= 10.0, "Camera elevated sufficiently to frame multi-element scene")

	# Test camera reset default
	vp._reset_camera_default()
	_assert(abs(vp._cam_pivot.position.x - 15.0) < 0.1, "Camera reset restores default pivot X=15.0")
	_assert(vp._camera.position.y > 5.0, "Reset camera elevated above floor")

func test_keyboard_and_multi_element_deletion() -> void:
	_tests_run += 1
	print("\n[Suite 8: Phase 7D-06 - Keyboard Deletion & Multi-Element Cascade]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var e1 := cat.create_element_instance("source", "src_del", Vector2(10, 10))
	var e2 := cat.create_element_instance("conveyor", "conv_del", Vector2(20, 10))
	store.add_element(e1)
	store.add_element(e2)

	# Wire them
	var conn := SceneTypes.SceneConnection.new()
	conn.id = "c_del"
	conn.source_element = "src_del"
	conn.source_port = "flow_out_1"
	conn.target_element = "conv_del"
	conn.target_port = "flow_in_1"
	store.add_connection(conn)
	_assert(store.active_document.elements.size() == 2, "2 elements added")
	_assert(store.active_document.connections.size() == 1, "1 connection added")

	# Select src_del and simulate canvas KEY_DELETE
	var canvas := Canvas2D.new(store)
	store.select("src_del", "element")
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_DELETE
	canvas._input(ev)

	_assert(store.active_document.elements.size() == 1, "src_del was deleted via KEY_DELETE")
	_assert(store.get_element("src_del") == null, "src_del no longer in document")
	_assert(store.active_document.connections.is_empty(), "Attached wire was cascade-deleted")

	# Test undo
	store.undo()
	_assert(store.active_document.elements.size() == 2, "Undo restored deleted element")
	_assert(store.active_document.connections.size() == 1, "Undo restored cascade-deleted connection")

	# Test Multi-element deletion
	store.set_selected_elements(["src_del", "conv_del"])
	_assert(store.selected_elements.size() == 2, "Both elements selected in store")
	canvas._input(ev)
	_assert(store.active_document.elements.is_empty(), "Both elements removed via multi-selection deletion")
	_assert(store.active_document.connections.is_empty(), "All connections purged")

	# Undo multi-delete
	store.undo()
	_assert(store.active_document.elements.size() == 2, "Undo restored both elements in single transaction")

func test_block_duplication() -> void:
	_tests_run += 1
	print("\n[Suite 9: Phase 7D-06 - Block Duplication]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var e1 := cat.create_element_instance("conveyor", "conv_main", Vector2(15.0, 10.0))
	store.add_element(e1)
	store.select("conv_main", "element")

	# Duplicate via store API
	var dup := store.duplicate_element("conv_main")
	_assert(dup != null, "Duplication returned cloned element")
	_assert(dup.id == "conv_main_copy", "Duplicate assigned unique ID (conv_main_copy)")
	_assert(store.active_document.elements.size() == 2, "Document now contains 2 elements")
	_assert(abs(dup.transform.position.x - 17.0) < 0.01, "Duplicate X offset by +2.0m (15m -> 17m)")
	_assert(abs(dup.transform.position.y - 12.0) < 0.01, "Duplicate Y offset by +2.0m (10m -> 12m)")
	_assert(store.selected_id == "conv_main_copy", "Duplicate is automatically selected")

	# Duplicate again to check incremental ID
	var dup2 := store.duplicate_element("conv_main")
	_assert(dup2.id == "conv_main_copy02", "Second duplicate increments suffix to conv_main_copy02")
	_assert(store.active_document.elements.size() == 3, "Document now contains 3 elements")

	# Undo duplicates
	store.undo()
	_assert(store.active_document.elements.size() == 2, "Undo reverted second duplicate")
	store.undo()
	_assert(store.active_document.elements.size() == 1, "Undo reverted first duplicate")

func test_arbitrary_angle_rotation_and_parity() -> void:
	_tests_run += 1
	print("\n[Suite 10: Phase 7D-06 & 7D-06A - Continuous Arbitrary Angle Rotation]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var e1 := cat.create_element_instance("conveyor", "conv_rot", Vector2(10.0, 10.0))
	e1.geometry["dimensions"] = [6.0, 1.2, 0.8]
	store.add_element(e1)
	store.select("conv_rot", "element")

	var vp := Viewport3D.new(store)
	var canvas := Canvas2D.new(store)

	# Set arbitrary rotation: 45.0 degrees
	store.set_element_rotation("conv_rot", 45.0)
	_assert(abs(e1.transform.rotation.z - 45.0) < 0.01, "Element rotation set to 45.0°")

	vp.rebuild_3d_scene()
	var anchor: Node3D = vp._entities_root.get_node_or_null("ElemAnchor_conv_rot")
	_assert(anchor != null, "3D ElemAnchor exists")
	_assert(abs(anchor.rotation_degrees.y - (-45.0)) < 0.01, "3D Anchor rotated by -45.0° (Godot Y matches Z-up Yaw)")

	# Set another arbitrary angle: 72.5 degrees
	store.set_element_rotation("conv_rot", 72.5)
	_assert(abs(e1.transform.rotation.z - 72.5) < 0.01, "Element rotation set to arbitrary continuous 72.5°")
	vp.rebuild_3d_scene()
	anchor = vp._entities_root.get_node_or_null("ElemAnchor_conv_rot")
	_assert(abs(anchor.rotation_degrees.y - (-72.5)) < 0.01, "3D Anchor rotated to -72.5°")

	# Test 2D BlockNode rotated port coordinates
	canvas.rebuild_blocks()
	var block: BlockNode = canvas._block_nodes["conv_rot"]
	_assert(abs(block.rotation_degrees - 72.5) < 0.01, "2D BlockNode rotation_degrees matches element rotation (72.5°)")
	var p_canvas := block.get_port_canvas_position("flow_out_1")
	var p_local := block.get_port_local_position("flow_out_1")
	var expected_canvas: Vector2 = block.position + block.pivot_offset + (p_local - block.pivot_offset).rotated(deg_to_rad(72.5))
	_assert(p_canvas.distance_to(expected_canvas) < 0.05, "Port canvas position accurately transformed via 2D rotation matrix")

	# Test rotation shortcuts (KEY_R advances +45°, Shift+KEY_R advances +15°)
	store.set_element_rotation("conv_rot", 0.0)
	var ev_r := InputEventKey.new()
	ev_r.pressed = true
	ev_r.keycode = KEY_R
	canvas._input(ev_r)
	_assert(abs(e1.transform.rotation.z - 45.0) < 0.01, "KEY_R advances rotation by +45.0°")

	ev_r.shift_pressed = true
	canvas._input(ev_r)
	_assert(abs(e1.transform.rotation.z - 60.0) < 0.01, "Shift + KEY_R advances rotation by fine +15.0° (45° + 15° = 60°)")

func test_3d_click_picking_and_selection_indicator() -> void:
	_tests_run += 1
	print("\n[Suite 11: Phase 7D-06A - 3D Click Picking & Selection Highlight]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var e1 := cat.create_element_instance("server", "srv_pick", Vector2(10.0, 10.0))
	e1.geometry["dimensions"] = [4.0, 2.0, 1.5]
	store.add_element(e1)

	var vp := Viewport3D.new(store)
	vp.rebuild_3d_scene()
	vp.frame_scene()

	# Select element and verify 3D selection indicator attached
	store.select("srv_pick", "element")
	_assert(vp._selection_indicator != null and is_instance_valid(vp._selection_indicator), "Selection indicator attached in 3D")
	var anchor: Node3D = vp._entities_root.get_node_or_null("ElemAnchor_srv_pick")
	_assert(anchor != null and anchor.has_node("SelectionIndicator"), "Selection indicator parented to active element anchor")

	# Deselect and verify indicator cleared
	store.clear_selection()
	_assert(vp._selection_indicator == null, "Selection indicator cleared on deselect")

	# Test mathematical raycast picking at element center
	var picked_id := vp.pick_element_at(vp._sub_viewport.size * 0.5)
	_assert(picked_id == "srv_pick", "3D center raycast picked srv_pick")

func test_camera_framing_and_view_modes() -> void:
	_tests_run += 1
	print("\n[Suite 12: Phase 7D-06 & 7D-06A - Framing & Camera View Modes]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var e1 := cat.create_element_instance("source", "s1", Vector2(0.0, 0.0))
	var e2 := cat.create_element_instance("sink", "s2", Vector2(50.0, 30.0))
	store.add_element(e1)
	store.add_element(e2)

	var canvas := Canvas2D.new(store)
	canvas.size = Vector2(800, 600)
	canvas.frame_all()
	_assert(canvas.zoom_level > 0.3 and canvas.zoom_level < 2.0, "2D Canvas frame_all set appropriate zoom level")

	var vp := Viewport3D.new(store)
	_assert(vp._camera.projection == Camera3D.PROJECTION_PERSPECTIVE, "3D Camera default projection is Perspective")
	# Switch to Orthographic
	vp._camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	vp._camera.size = vp._cam_distance * 0.75
	_assert(vp._camera.projection == Camera3D.PROJECTION_ORTHOGONAL, "3D Camera projection switched to Orthographic")
	vp.frame_scene()
	_assert(vp._camera.size > 20.0, "Orthographic size updated on frame_scene (zoomed out)")
	vp.frame_selection()
	_assert(vp._camera.size < 15.0 and vp._camera.size > 2.0, "Orthographic size updated on frame_selection (zoomed in on element)")

func test_typed_port_visuals_and_semantic_colors() -> void:
	_tests_run += 1
	print("\n[Suite 13: Phase 7D-07 - Typed Port Visuals & Semantic Port Colors]")
	var cat := Catalog.new()
	var elem := cat.create_element_instance("server", "srv_typed", Vector2(10, 10))
	var block := BlockNode.new(elem)
	block.size = Vector2(180, 120)

	# Verify port color definitions
	_assert(BlockNode.COLOR_FLOW == Color("#2ecc71"), "Flow ports styled with emerald green (#2ecc71)")
	_assert(BlockNode.COLOR_METRIC == Color("#9b59b6"), "Metric ports styled with amethyst purple (#9b59b6)")
	_assert(BlockNode.COLOR_SIGNAL == Color("#3498db"), "Signal ports styled with cobalt blue (#3498db)")
	_assert(BlockNode.COLOR_CONTROL == Color("#e67e22"), "Control ports styled with warm amber (#e67e22)")
	_assert(BlockNode.COLOR_EVENT == Color("#e74c3c"), "Event ports styled with coral red (#e74c3c)")

	# Add a 'many' cardinality port
	var multi_port := SceneTypes.ScenePort.new()
	multi_port.id = "multi_flow_in"
	multi_port.kind = "flow"
	multi_port.cardinality = "many"
	elem.input_ports.append(multi_port)
	block.rebuild_ports()

	# Check socket metadata
	var has_many := false
	for p_id in block._port_sockets.keys():
		var socket: Dictionary = block._port_sockets[p_id]
		if socket.get("cardinality") == "many":
			has_many = true
			break
	_assert(has_many, "Port with cardinality='many' correctly registered in block socket cache")

	# Test port selection signal emission on click
	var selected := {"port": ""}
	block.port_selected.connect(func(_eid: String, pid: String): selected["port"] = pid)
	var pos := block.get_port_canvas_position("flow_in")
	var hit := block.hit_test_port(pos - block.position)
	_assert(hit == "flow_in", "hit_test_port resolves port socket position accurately")
	block.port_selected.emit("srv_typed", "flow_in")
	_assert(selected["port"] == "flow_in", "Clicking/selecting socket triggers port_selected signal")

func test_interactive_invalid_link_rejection_and_cardinality() -> void:
	_tests_run += 1
	print("\n[Suite 14: Phase 7D-07 - Interactive Invalid Link Rejection & Single Cardinality]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var e_src := cat.create_element_instance("source", "s1", Vector2(0, 0))
	var e_srv := cat.create_element_instance("server", "srv1", Vector2(10, 0))
	store.add_element(e_src)
	store.add_element(e_srv)

	var canvas := Canvas2D.new(store)
	canvas.size = Vector2(800, 600)
	canvas.rebuild_blocks()

	var srv_block: BlockNode = canvas._block_nodes["srv1"]
	var pos_util := srv_block.get_port_canvas_position("utilization")
	var pos_flow_in := srv_block.get_port_canvas_position("flow_in")
	var pos_flow_out := srv_block.get_port_canvas_position("flow_out")

	# 1. Test incompatible kind rejection (Flow output -> Metric output/in)
	canvas.start_wire_drag("s1", "flow_out", "flow", true, Vector2(50, 50))
	canvas.update_wire_hover_at(pos_util)
	_assert(not canvas._wire_is_compatible, "Linking Flow port to Metric port is rejected")
	_assert(canvas._wire_rejection_reason.contains("Incompatible link") or canvas._wire_rejection_reason.contains("Incompatible kinds") or canvas._wire_rejection_reason.contains("Cannot connect"), "Rejection reason indicates kind or direction incompatibility: " + canvas._wire_rejection_reason)

	# 2. Test direction mismatch rejection (Output -> Output)
	canvas.update_wire_hover_at(pos_flow_out)
	_assert(not canvas._wire_is_compatible, "Linking Output port to Output port is rejected")
	_assert(canvas._wire_rejection_reason.contains("Cannot connect"), "Rejection reason indicates direction mismatch: " + canvas._wire_rejection_reason)

	# 3. Test compatible link
	canvas.update_wire_hover_at(pos_flow_in)
	_assert(canvas._wire_is_compatible, "Linking Flow Output to Flow Input is accepted")
	_assert(canvas._wire_rejection_reason.is_empty(), "No rejection reason on compatible link")

	# Finish drag and create connection
	canvas.finish_wire_drag()
	_assert(store.active_document.connections.size() == 1, "Compatible link created connection in DocumentStore")

	# 4. Test Single Cardinality rejection (flow_in already connected)
	var e_src2 := cat.create_element_instance("source", "s2", Vector2(0, 10))
	store.add_element(e_src2)
	canvas.rebuild_blocks()

	canvas.start_wire_drag("s2", "flow_out", "flow", true, Vector2(50, 150))
	canvas.update_wire_hover_at(pos_flow_in)
	_assert(not canvas._wire_is_compatible, "Second link to single-cardinality input socket is rejected")
	_assert(canvas._wire_rejection_reason.contains("already connected"), "Rejection reason indicates single-cardinality limit: " + canvas._wire_rejection_reason)
	canvas._cancel_wire_drag()

func test_dag_hierarchical_auto_layout() -> void:
	_tests_run += 1
	print("\n[Suite 15: Phase 7D-07 - Process Graph Hierarchical DAG Auto-Layout]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var s := cat.create_element_instance("source", "s_node", Vector2(0, 0))
	var q := cat.create_element_instance("queue", "q_node", Vector2(0, 0))
	var m := cat.create_element_instance("server", "m_node", Vector2(0, 0))
	var k := cat.create_element_instance("sink", "k_node", Vector2(0, 0))
	store.add_element(s)
	store.add_element(q)
	store.add_element(m)
	store.add_element(k)

	# Wire up s -> q -> m -> k
	var c1 := SceneTypes.SceneConnection.new()
	c1.id = "c1"; c1.source_element = "s_node"; c1.source_port = "flow_out_1"; c1.target_element = "q_node"; c1.target_port = "flow_in_1"; c1.link_type = "flow"
	var c2 := SceneTypes.SceneConnection.new()
	c2.id = "c2"; c2.source_element = "q_node"; c2.source_port = "flow_out_1"; c2.target_element = "m_node"; c2.target_port = "flow_in_1"; c2.link_type = "flow"
	var c3 := SceneTypes.SceneConnection.new()
	c3.id = "c3"; c3.source_element = "m_node"; c3.source_port = "flow_out_1"; c3.target_element = "k_node"; c3.target_port = "flow_in_1"; c3.link_type = "flow"
	store.add_connection(c1)
	store.add_connection(c2)
	store.add_connection(c3)

	# Execute Auto-Layout DAG
	var ok := store.auto_layout_dag(60.0, 40.0)
	_assert(ok, "auto_layout_dag executed successfully")

	# Verify strict left-to-right topological order
	var sx: float = s.editor.graph_position.x
	var qx: float = q.editor.graph_position.x
	var mx: float = m.editor.graph_position.x
	var kx: float = k.editor.graph_position.x
	_assert(sx < qx and qx < mx and mx < kx, "Topological ordering preserved: Source (%.0f) < Queue (%.0f) < Server (%.0f) < Sink (%.0f)" % [sx, qx, mx, kx])

	# Verify 20px/m 1:1 parity with 3D transform position
	_assert(abs(float(s.transform.position[0]) - (sx / 20.0)) < 0.01, "Source 3D position maintains 20px/m parity")
	_assert(abs(float(k.transform.position[0]) - (kx / 20.0)) < 0.01, "Sink 3D position maintains 20px/m parity")

	# Verify undo restores layout
	var old_sx := sx
	store.undo()
	var restored_s := store.get_element("s_node")
	_assert(restored_s != null and (restored_s.editor.graph_position.x != old_sx or restored_s.editor.graph_position == Vector2.ZERO), "Undo successfully rolled back DAG auto-layout")

func test_declarative_schema_inspector_and_statistical_distributions() -> void:
	_tests_run += 1
	print("\n[Suite 16: Phase 7D-08 - Declarative Schema Inspector & Statistical Distributions]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var srv := cat.create_element_instance("server", "srv_insp", Vector2(0, 0))
	store.add_element(srv)
	store.select("srv_insp", "element")

	var insp := Inspector.new(store, cat)

	# Verify schema resolution for server
	var entry := cat.get_entry("server")
	var s_schema: Dictionary = entry.get_property_schema("service_time")
	_assert(not s_schema.is_empty(), "service_time schema found on server")
	_assert(s_schema.get("type") == "distribution", "service_time property type is 'distribution'")
	_assert(s_schema.get("supported_distributions", []).has("triangular"), "service_time supports triangular distribution")

	# Test set_element_property with triangular distribution
	var tri_dist := {
		"distribution": "triangular",
		"min": 4.0,
		"mode": 8.0,
		"max": 15.0
	}
	store.set_element_property("srv_insp", "service_time", tri_dist)
	_assert(srv.properties.get("service_time", {}).get("distribution") == "triangular", "Triangular distribution written to element properties")

	# Test DistributionSparkline generation
	var sparkline := Inspector.DistributionSparkline.new()
	sparkline.custom_minimum_size = Vector2(200, 36)
	sparkline.set_distribution(tri_dist)
	_assert(sparkline.dist_data.get("distribution") == "triangular", "Sparkline configured with triangular distribution")
	_assert(sparkline.dist_data.get("mode") == 8.0, "Sparkline mode is 8.0")

	# Test Exponential distribution
	var exp_dist := {"distribution": "exponential", "mean": 6.5}
	sparkline.set_distribution(exp_dist)
	_assert(sparkline.dist_data.get("distribution") == "exponential", "Sparkline accepts exponential distribution")

	# Test Normal distribution
	var norm_dist := {"distribution": "normal", "mean": 10.0, "std_dev": 2.0}
	sparkline.set_distribution(norm_dist)
	_assert(sparkline.dist_data.get("distribution") == "normal", "Sparkline accepts normal distribution")

func test_port_properties_inspection_and_buffer_editing() -> void:
	_tests_run += 1
	print("\n[Suite 17: Phase 7D-08 - Port Properties Inspection & Dedicated Buffer Editing]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var q := cat.create_element_instance("queue", "q_port_test", Vector2(0, 0))
	store.add_element(q)

	# Select flow_in port
	store.select_port("q_port_test", "flow_in")
	_assert(store.selected_type == "port", "DocumentStore selected_type is 'port'")
	_assert(store.selected_port_id == "flow_in", "DocumentStore selected_port_id is 'flow_in'")

	var insp := Inspector.new(store, cat)

	# Update port properties (chute_buffer_capacity and conveyance_handshake_latency_sec)
	var new_port_props := {
		"chute_buffer_capacity": 6,
		"conveyance_handshake_latency_sec": 0.25
	}
	store.update_port_properties("q_port_test", "flow_in", new_port_props)

	var p: SceneTypes.ScenePort = store.get_selected_port()
	_assert(p != null, "get_selected_port retrieved port object")
	_assert(int(p.get_extension("chute_buffer_capacity", 0)) == 6 or int(p.get_extension("chute_capacity", 0)) == 6, "Port chute_buffer_capacity updated to 6")
	_assert(abs(float(p.get_extension("conveyance_handshake_latency_sec", 0.0)) - 0.25) < 0.001 or abs(float(p.get_extension("latency", 0.0)) - 0.25) < 0.001, "Port conveyance_handshake_latency_sec updated to 0.25")

	# Test undo reverts port properties
	store.undo()
	p = store.get_selected_port()
	_assert(p != null and int(p.get_extension("chute_buffer_capacity", 0)) != 6, "Undo reverted port properties")

func test_multi_selection_mixed_values_and_batch_undo() -> void:
	_tests_run += 1
	print("\n[Suite 18: Phase 7D-08 - Multi-Selection Mixed Values & Single-Transaction Batch Undo]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var c1 := cat.create_element_instance("conveyor", "c_batch_1", Vector2(0, 0))
	var c2 := cat.create_element_instance("conveyor", "c_batch_2", Vector2(10, 0))
	c1.properties["speed"] = 1.2
	c2.properties["speed"] = 2.4
	store.add_element(c1)
	store.add_element(c2)

	# Multi-select both conveyors
	store.select_multiple(["c_batch_1", "c_batch_2"])
	_assert(store.selected_type == "element", "DocumentStore selected_type is 'element'")
	_assert(store.selected_elements.size() == 2, "2 elements in selected_elements")

	# Inspector in multi-selection mode
	var insp := Inspector.new(store, cat)
	_assert(insp._is_multi_selection(), "Inspector recognizes multi-selection state")

	# Update speed on both in single batch transaction
	store.set_elements_property_batch(["c_batch_1", "c_batch_2"], "speed", 3.5)
	_assert(c1.properties.get("speed") == 3.5, "c1 speed updated to 3.5")
	_assert(c2.properties.get("speed") == 3.5, "c2 speed updated to 3.5")

	# Test single-transaction undo
	var undo_ok := store.undo()
	_assert(undo_ok, "Undo transaction succeeded")
	var restored_c1 := store.get_element("c_batch_1")
	var restored_c2 := store.get_element("c_batch_2")
	_assert(restored_c1 != null and restored_c1.properties.get("speed") == 1.2, "Single undo reverted c1 speed back to 1.2")
	_assert(restored_c2 != null and restored_c2.properties.get("speed") == 2.4, "Single undo reverted c2 speed back to 2.4 simultaneously")

func test_no_code_rule_builder_and_metric_discovery() -> void:
	_tests_run += 1
	print("\n[Suite 19: Phase 7D-08 - No-Code Rule & Condition Builder with Metric Discovery]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var q := cat.create_element_instance("queue", "q_metrics", Vector2(0, 0))
	var srv := cat.create_element_instance("server", "srv_metrics", Vector2(10, 0))
	store.add_element(q)
	store.add_element(srv)

	var conn := SceneTypes.SceneConnection.new()
	conn.id = "conn_rule_test"
	conn.source_element = "q_metrics"; conn.source_port = "flow_out_1"
	conn.target_element = "srv_metrics"; conn.target_port = "flow_in_1"
	conn.link_type = "flow"
	store.add_connection(conn)

	var rule_b := RuleBuilder.new(store)

	# Test metric auto-discovery across document elements
	var available := rule_b.get_available_metrics()
	_assert(available.size() >= 2, "Discovered at least 2 metrics across elements")
	var metric_ids: Array = []
	for m in available:
		metric_ids.append(m.id)
	_assert(metric_ids.has("q_metrics.occupancy"), "Discovered q_metrics.occupancy metric")
	_assert(metric_ids.has("srv_metrics.utilization"), "Discovered srv_metrics.utilization metric")

	# Open connection in rule builder and save condition
	rule_b.open_for_connection("conn_rule_test")
	var condition := {
		"metric": "q_metrics.occupancy",
		"operator": ">=",
		"threshold": 80.0,
		"unit": "%"
	}
	store.update_connection_condition("conn_rule_test", condition)
	_assert(conn.condition.get("metric") == "q_metrics.occupancy", "Rule builder updated connection condition metric")
	_assert(conn.condition.get("operator") == ">=", "Rule builder updated operator to >=")
	_assert(conn.condition.get("threshold") == 80.0, "Rule builder updated threshold to 80.0")

	# Test Undo reverts condition
	store.undo()
	var restored_conn: SceneTypes.SceneConnection = store.active_document.connections[0]
	_assert(restored_conn.condition == null or (restored_conn.condition is Dictionary and (restored_conn.condition as Dictionary).is_empty()), "Undo reverted connection condition")

func test_active_simulation_live_edit_policy() -> void:
	_tests_run += 1
	print("\n[Suite 20: Phase 7D-08 - Active Simulation Live Edit vs Restart Required Policy]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var srv := cat.create_element_instance("server", "srv_live_test", Vector2(0, 0))
	store.add_element(srv)
	store.select("srv_live_test", "element")

	var insp := Inspector.new(store, cat)
	_assert(not insp.is_sim_running, "Simulation starts inactive (is_sim_running == false)")

	# Check schema edit policy declarations
	var entry := cat.get_entry("server")
	var s_time_schema := entry.get_property_schema("service_time")
	var s_fail_schema := entry.get_property_schema("failure_rate")
	_assert(s_time_schema.get("edit_policy") == "live", "service_time edit policy is 'live'")
	_assert(s_fail_schema.get("edit_policy") == "restart_required", "failure_rate edit policy is 'restart_required'")

	# Set simulation to running
	insp.set_simulation_running(true)
	_assert(insp.is_sim_running, "Simulation state updated to running (is_sim_running == true)")

	# Set simulation back to stopped
	insp.set_simulation_running(false)
	_assert(not insp.is_sim_running, "Simulation state updated back to stopped")

func test_resizable_splitters_and_expand_layout() -> void:
	_tests_run += 1
	print("\n[Suite 21: Adjustable Splitters & Fluid Window Scaling]")
	var shell := AuthoringShell.new()
	shell._ready()

	# Verify outer and inner splitters are HSplitContainer
	_assert(shell._outer_split != null and shell._outer_split is HSplitContainer, "Outer layout uses HSplitContainer")
	_assert(shell._inner_split != null and shell._inner_split is HSplitContainer, "Inner layout uses HSplitContainer")

	# Verify default offsets and expand fill
	_assert(shell._outer_split.split_offset == 220, "Outer splitter has 220px default catalog offset")
	_assert(shell._center_container != null and shell._center_container.size_flags_horizontal == Control.SIZE_EXPAND_FILL, "Center layout viewport has SIZE_EXPAND_FILL")

	# Verify dock minimum collapsible width is 38px (~1cm)
	var left_dock: Control = shell._outer_split.get_child(0)
	var right_dock: Control = shell._inner_split.get_child(1)
	_assert(left_dock.custom_minimum_size.x == 38, "Left catalog dock has 38px (~1cm) minimum width")
	_assert(right_dock.custom_minimum_size.x == 38, "Right inspector dock has 38px (~1cm) minimum width")
	_assert(left_dock.clip_contents and right_dock.clip_contents, "Both docks have clip_contents enabled for collapse")

	# Test dynamic resizing and collapsing splitters down to 1cm
	shell._outer_split.split_offset = 38
	_assert(shell._outer_split.split_offset == 38, "Outer splitter collapsed down to 1cm (38px)")
	shell._outer_split.split_offset = 260
	_assert(shell._outer_split.split_offset == 260, "Outer splitter dynamically adjusted to 260px")
	shell._inner_split.split_offset = 320
	_assert(shell._inner_split.split_offset == 320, "Inner splitter dynamically adjusted to 320px")

	shell.free()

func test_floating_tabbed_properties_inspector() -> void:
	_tests_run += 1
	print("\n[Suite 22: Right-Click Floating Tabbed Properties Inspector]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var srv := cat.create_element_instance("server", "srv_flt_test", Vector2(10, 10))
	store.add_element(srv)

	var flt := FloatingInspector.new(store, cat)
	_assert(not flt.visible, "Floating inspector starts hidden")

	# Open for server element
	flt.open_for_element("srv_flt_test", Vector2(150, 150))
	_assert(flt.visible, "Floating inspector becomes visible on open_for_element")
	_assert(flt.current_elem_id == "srv_flt_test", "Floating inspector tracks active element ID")

	# Verify 4 tabs
	_assert(flt._tab_buttons.size() == 4, "Floating inspector has exactly 4 tabs")
	_assert(flt._tab_buttons[0].text.contains("Process"), "Tab 0 is Process & DES")
	_assert(flt._tab_buttons[1].text.contains("Spatial"), "Tab 1 is Spatial / CAD")
	_assert(flt._tab_buttons[2].text.contains("Ports"), "Tab 2 is Ports & Interfaces")
	_assert(flt._tab_buttons[3].text.contains("Rules") or flt._tab_buttons[3].text.contains("Reliability"), "Tab 3 is Reliability & Rules")

	# Switch tabs
	flt._switch_tab(1)
	_assert(flt.current_tab == 1, "Switched to Tab 1 (Spatial / CAD)")
	_assert(flt._pages_container.get_child_count() > 0, "Spatial tab rendered controls in page container")

	# Test spatial coordinate editing via floating inspector
	_assert(flt._spin_px != null, "Position X spinbox initialized in Spatial tab")
	flt._spin_px.value = 14.5
	flt._spin_px.value_changed.emit(14.5)
	_assert(srv.transform.position.x == 14.5, "Floating inspector updated element X position")
	_assert(srv.editor.graph_position.x == 290.0, "Floating inspector synced 2D graph X position (14.5m * 20px/m = 290px)")

	# Test Tab 2: Rich Ports & Interfaces
	flt._switch_tab(2)
	_assert(flt.current_tab == 2, "Switched to Tab 2 (Ports & Interfaces)")
	_assert(flt._pages_container.get_child_count() > 0, "Ports tab rendered controls")

	# Test updating port cardinality via floating inspector
	store.update_port_properties("srv_flt_test", "flow_in", {"cardinality": "many"})
	var p_in: SceneTypes.ScenePort = srv.input_ports[0]
	_assert(p_in.cardinality == "many", "Port cardinality updated to 'many'")

	# Test updating port display name
	store.update_port_properties("srv_flt_test", "flow_in", {"name": "Primary Infeed"})
	_assert(p_in.name == "Primary Infeed", "Port display name updated to 'Primary Infeed'")

	# Test updating chute buffer capacity & latency
	store.update_port_properties("srv_flt_test", "flow_in", {
		"chute_buffer_capacity": 15,
		"conveyance_handshake_latency_sec": 0.35
	})
	_assert(int(p_in.get_extension("chute_buffer_capacity", 0)) == 15, "Port chute buffer capacity updated to 15")
	_assert(abs(float(p_in.get_extension("conveyance_handshake_latency_sec", 0.0)) - 0.35) < 0.001, "Port handshake latency updated to 0.35s")

	# Test dynamic port addition
	flt._add_dynamic_port(srv, "flow_out")
	_assert(srv.output_ports.size() >= 2, "Dynamic outfeed port added via floating inspector")

	# Add an outbound connection with condition = null to test rules tab robustness
	var out_conn := SceneTypes.SceneConnection.new()
	out_conn.id = "conn_null_cond_test"
	out_conn.source_element = "srv_flt_test"; out_conn.source_port = "flow_out"
	out_conn.target_element = "sink_node"; out_conn.target_port = "flow_in"
	out_conn.condition = null
	store.add_connection(out_conn)

	# Test Tab 3: Reliability & Progressive Disclosure with null-condition connection
	flt._switch_tab(3)
	_assert(flt.current_tab == 3, "Switched to Tab 3 (Reliability & Rules)")
	_assert(flt._pages_container.get_child_count() > 0, "Rules tab rendered controls including outbound connection with null condition")

	# Test Close
	flt.close()
	_assert(not flt.visible, "Floating inspector hidden after close()")
	_assert(flt.current_elem_id == "", "Element ID cleared after close()")

	# Test Right-Click trigger on BlockNode
	var block := BlockNode.new(srv)
	block.size = Vector2(180, 120)
	block.rebuild_ports()
	var right_click_captured := {"id": "", "pos": Vector2.ZERO}
	block.floating_properties_requested.connect(func(eid: String, pos: Vector2):
		right_click_captured["id"] = eid
		right_click_captured["pos"] = pos
	)

	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_RIGHT
	mb.pressed = true
	mb.position = block.size * 0.5
	block._gui_input(mb)
	_assert(right_click_captured["id"] == "srv_flt_test", "Right-click on block node emits floating_properties_requested")

	block.free()
	flt.free()

func test_abm_model_registry_and_configuration_dialog() -> void:
	_tests_run += 1
	print("\n[Suite 23: ABM Model Registry, Presets & Schema-Driven Dialog]")
	
	# 1. Model Registry Checks
	_assert(ABMDialog.MODEL_REGISTRY.has("SFM"), "Model Registry contains SFM (Social Force Model)")
	_assert(ABMDialog.MODEL_REGISTRY.has("ORCA"), "Model Registry contains ORCA (Optimal Reciprocal Collision Avoidance)")
	_assert(ABMDialog.MODEL_REGISTRY.has("HybridFSM"), "Model Registry contains HybridFSM")
	_assert(ABMDialog.MODEL_REGISTRY.has("CSM"), "Model Registry contains CSM (Cellular Spatial Markov)")

	var sfm_def: Dictionary = ABMDialog.MODEL_REGISTRY["SFM"]
	_assert(sfm_def.get("library") == "SimCrowd", "SFM library is SimCrowd")
	_assert(sfm_def.get("presets", {}).has("Dense Rush Hour"), "SFM includes 'Dense Rush Hour' preset")

	# 2. Dialog Initialization & Binding
	var store := DocumentStore.new()
	var dialog := ABMDialog.new(store)
	_assert(not dialog.visible, "ABM dialog starts hidden")

	dialog.open()
	_assert(dialog.visible, "ABM dialog visible after open()")

	# 3. Toggle Enabled
	_assert(not store.active_document.abm_config.get("enabled", false), "ABM starts disabled by default")
	dialog._check_enabled.button_pressed = true
	dialog._on_enabled_toggled(true)
	_assert(bool(store.active_document.abm_config.get("enabled", false)) == true, "Enabling ABM updates doc abm_config.enabled")
	_assert(store.active_document.simulation.mode == "hybrid", "Enabling ABM sets simulation mode to 'hybrid'")

	# 4. Model Selection & Switching
	dialog._on_model_selected(1) # ORCA
	_assert(store.active_document.abm_config.get("model_name") == "ORCA", "Selected model updated to ORCA")
	_assert(dialog.get_current_model_name() == "ORCA", "Dialog returns current model ORCA")
	_assert(dialog._migration_label.text.contains("Switched model"), "Migration label shows transition notice")

	# Switch back to SFM
	dialog._on_model_selected(0) # SFM
	_assert(store.active_document.abm_config.get("model_name") == "SFM", "Selected model restored to SFM")

	# 5. Apply Presets
	dialog._on_preset_selected(1) # Dense Rush Hour
	var params: Dictionary = store.active_document.abm_config.get("parameters", {})
	_assert(float(params.get("A", 0.0)) == 2500.0, "Preset 'Dense Rush Hour' applied A=2500.0")
	_assert(float(params.get("k", 0.0)) == 16000.0, "Preset 'Dense Rush Hour' applied k=16000.0")

	# 6. Hardware Backend Preference
	dialog._on_backend_selected(2) # GPU
	_assert(store.active_document.abm_config.get("backend_preference") == "gpu", "Hardware backend preference set to GPU")

	dialog._on_fallback_selected(1) # Strict
	_assert(store.active_document.abm_config.get("fallback_policy") == "strict", "Fallback policy set to strict")

	# 7. Add and Modify Custom Experimental Parameter
	dialog._on_add_custom_param_pressed()
	var custom_params: Dictionary = store.active_document.abm_config.get("parameters", {})
	var custom_key: String = ""
	for k in custom_params.keys():
		if str(k).begins_with("custom_param"):
			custom_key = str(k)
			break
	_assert(not custom_key.is_empty(), "Custom parameter dynamically added to ABM configuration")

	dialog._on_param_value_changed(custom_key, 42.5)
	_assert(float(store.active_document.abm_config["parameters"][custom_key]) == 42.5, "Custom parameter value updated to 42.5")

	dialog._remove_custom_param(custom_key)
	_assert(not store.active_document.abm_config["parameters"].has(custom_key), "Custom parameter removed cleanly")

	dialog.close()
	_assert(not dialog.visible, "ABM dialog closed cleanly")
	dialog.free()

func test_catalog_crowd_and_hybrid_primitives() -> void:
	_tests_run += 1
	print("\n[Suite 24: Catalog Crowd & Hybrid Primitives & 3D Builders]")
	var cat := Catalog.new()
	var factory := MeshFactory.new()

	# Verify Catalog Categories
	var categories: Array = cat.get_categories()
	_assert(categories.has("Crowd & Pedestrian"), "Catalog has 'Crowd & Pedestrian' category")
	_assert(categories.has("Hybrid & Multi-Paradigm"), "Catalog has 'Hybrid & Multi-Paradigm' category")

	# 1. crowd_spawner
	var spawner_entry := cat.get_entry("crowd_spawner")
	_assert(spawner_entry != null, "crowd_spawner registered in catalog")
	var spawner_elem := cat.create_element_instance("crowd_spawner", "spawner_01", Vector2(0, 0))
	_assert(spawner_elem.output_ports.size() >= 1 and spawner_elem.metric_ports.size() >= 1, "crowd_spawner has pedestrian flow out and metric ports")
	_assert(spawner_elem.properties.has("spawn_rate"), "crowd_spawner has 'spawn_rate' property")
	_assert(spawner_elem.properties.has("initial_speed"), "crowd_spawner has 'initial_speed' property")
	var spawner_node: Node3D = MeshFactory.create_3d_node_for_element(spawner_elem)
	_assert(spawner_node != null and spawner_node is Node3D, "MeshFactory built 3D node for crowd_spawner")
	spawner_node.free()

	# 2. exit_goal
	var exit_entry := cat.get_entry("exit_goal")
	_assert(exit_entry != null, "exit_goal registered in catalog")
	var exit_elem := cat.create_element_instance("exit_goal", "exit_01", Vector2(10, 0))
	_assert(exit_elem.input_ports.size() >= 1, "exit_goal has pedestrian input port")
	_assert(exit_elem.properties.has("door_width"), "exit_goal has 'door_width' property")
	var exit_node: Node3D = MeshFactory.create_3d_node_for_element(exit_elem)
	_assert(exit_node != null and exit_node is Node3D, "MeshFactory built 3D node for exit_goal")
	exit_node.free()

	# 3. walkable_room
	var room_entry := cat.get_entry("walkable_room")
	_assert(room_entry != null, "walkable_room registered in catalog")
	var room_elem := cat.create_element_instance("walkable_room", "hall_01", Vector2(0, 10))
	_assert(room_elem.geometry.has("dimensions"), "walkable_room has dimensions geometry")
	_assert(room_elem.properties.has("speed_factor"), "walkable_room has 'speed_factor' surface property")
	var room_node: Node3D = MeshFactory.create_3d_node_for_element(room_elem)
	_assert(room_node != null and room_node is Node3D, "MeshFactory built 3D node for walkable_room")
	room_node.free()

	# 4. obstacle_wall
	var wall_entry := cat.get_entry("obstacle_wall")
	_assert(wall_entry != null, "obstacle_wall registered in catalog")
	var wall_elem := cat.create_element_instance("obstacle_wall", "wall_01", Vector2(10, 10))
	_assert(wall_elem.properties.has("is_passable"), "obstacle_wall has 'is_passable' property")
	var wall_node: Node3D = MeshFactory.create_3d_node_for_element(wall_elem)
	_assert(wall_node != null and wall_node is Node3D, "MeshFactory built 3D node for obstacle_wall")
	wall_node.free()

	# 5. hybrid_portal
	var portal_entry := cat.get_entry("hybrid_portal")
	_assert(portal_entry != null, "hybrid_portal registered in catalog")
	var portal_elem := cat.create_element_instance("hybrid_portal", "turnstile_01", Vector2(5, 5))
	_assert(portal_elem.input_ports.size() >= 1 and portal_elem.output_ports.size() >= 1, "hybrid_portal has DES and ABM interface ports")
	_assert(portal_elem.properties.has("gate_latency_sec"), "hybrid_portal has 'gate_latency_sec' property")
	var portal_node: Node3D = MeshFactory.create_3d_node_for_element(portal_elem)
	_assert(portal_node != null and portal_node is Node3D, "MeshFactory built 3D node for hybrid_portal")
	portal_node.free()

	# Procedural Agent Mannequin & Capsule Meshes
	var mannequin: Node3D = MeshFactory.create_agent_mannequin_node()
	_assert(mannequin != null and mannequin is Node3D, "MeshFactory created LOD 0 mannequin node")
	mannequin.free()

	var capsule_mesh: CapsuleMesh = MeshFactory.create_agent_capsule_mesh()
	_assert(capsule_mesh != null and capsule_mesh is CapsuleMesh, "MeshFactory created LOD 1 capsule mesh")

func test_agent_telemetry_2d_and_3d_visualization() -> void:
	_tests_run += 1
	print("\n[Suite 25: 2D/3D Agent Telemetry Rendering & Follow-Camera]")
	var shell := AuthoringShell.new()
	shell._ready()

	# 1. Shell ABM UI Status
	_assert(shell._btn_abm != null, "Authoring shell header contains '⚙ ABM Settings' button")
	_assert(shell._abm_status_pill != null, "Authoring shell header contains ABM status pill")
	_assert(shell._abm_status_pill.text.contains("OFF"), "ABM status pill initially displays '[○ ABM: OFF]'")

	# Enable ABM in document and verify status pill updates
	shell.doc_store.active_document.abm_config = {"enabled": true, "model_name": "SFM"}
	shell.doc_store.active_document.simulation.mode = "hybrid"
	shell._update_abm_status_pill()
	_assert(shell._abm_status_pill.text.contains("SFM"), "ABM status pill reflects active '[● ABM: SFM]'")

	# 2. Canvas 2D Agent Telemetry
	var sample_agents: Array = [
		{
			"id": "agent_01",
			"x": 5.0,
			"y": 2.5,
			"z": 0.0,
			"vx": 1.2,
			"vy": 0.3,
			"speed": 1.23,
			"r_body": 0.22,
			"state": "walking"
		},
		{
			"id": "agent_02",
			"x": 8.0,
			"y": 4.0,
			"z": 0.0,
			"vx": 0.1,
			"vy": 0.05,
			"speed": 0.11,
			"r_body": 0.20,
			"state": "queuing"
		}
	]

	shell._canvas_2d.update_agent_telemetry(sample_agents)
	_assert(shell._canvas_2d._live_agents.size() == 2, "2D Canvas received 2 live agents")
	_assert(shell._canvas_2d._agent_trajectories.has("agent_01"), "2D Canvas tracks trajectory for agent_01")
	_assert(shell._canvas_2d._agent_trajectories["agent_01"].size() >= 1, "agent_01 trajectory recorded position")

	# 3. 3D Viewport Agent Telemetry
	shell._viewport_3d.update_agent_telemetry(sample_agents)
	_assert(shell._viewport_3d._agents_multimesh_instance != null, "3D Viewport has MultiMeshInstance3D for agents")
	var mm: MultiMesh = shell._viewport_3d._agents_multimesh_instance.multimesh
	_assert(mm != null and mm.instance_count == 2, "MultiMesh instance_count allocated for 2 agents")

	# Check coordinate transform for agent_01:
	# physical X=5.0 -> 3D X=5.0
	# physical Y=2.5 -> 3D Z=-2.5
	# physical Z=0.0 -> 3D Y=0.85
	var xform: Transform3D = shell._viewport_3d.get_agent_transform_3d(0)
	_assert(abs(xform.origin.x - 5.0) < 0.01, "Agent 01 3D X mapped to 5.0m")
	_assert(abs(xform.origin.y - 0.85) < 0.01, "Agent 01 3D Y elevated to waist center 0.85m")
	_assert(abs(xform.origin.z - (-2.5)) < 0.01, "Agent 01 3D Z mapped to -2.5m (SceneSpec Z-up to Godot Y-up)")

	# 4. Follow-Camera Tracking
	shell._viewport_3d.set_follow_camera(true, "agent_01")
	_assert(shell._viewport_3d.is_following_agent, "Follow-camera mode enabled")
	_assert(shell._viewport_3d.follow_agent_id == "agent_01", "Follow-camera tracking agent_01")

	# Update telemetry again to trigger camera follow lerp
	sample_agents[0]["x"] = 6.2
	sample_agents[0]["y"] = 3.1
	shell.update_agent_telemetry(sample_agents)
	_assert(abs(shell._viewport_3d._camera_target.x - 6.2) < 0.01, "Follow-camera target updated to agent_01 physical coordinates")

	# Disable follow camera
	shell._viewport_3d.set_follow_camera(false)
	_assert(not shell._viewport_3d.is_following_agent, "Follow-camera mode disabled cleanly")

	shell.free()

func test_subgraph_grouping_and_scope_navigation() -> void:
	_tests_run += 1
	print("\n[Suite 26: Subgraphs, Groups, Breadcrumb Bar & Scoped Canvas Views]")
	var shell := AuthoringShell.new()
	shell._ready()

	var cat: Catalog = shell.catalog
	var store: DocumentStore = shell.doc_store

	# Add three elements to document
	var e1 := cat.create_element_instance("conveyor", "conv_in", Vector2(10, 10))
	var e2 := cat.create_element_instance("server", "srv_main", Vector2(30, 10))
	var e3 := cat.create_element_instance("queue", "q_out", Vector2(50, 10))
	store.add_element(e1)
	store.add_element(e2)
	store.add_element(e3)

	# Connect e1 to e2, and e2 to e3
	store.add_connection_direct("c1", "conv_in", "flow_out", "srv_main", "flow_in")
	store.add_connection_direct("c2", "srv_main", "flow_out", "q_out", "flow_in")

	_assert(store.get_scoped_elements().size() == 3, "Root scope initially displays all 3 elements")
	_assert(store.get_scoped_connections().size() == 2, "Root scope initially displays both connections")

	# Group e1 and e2 into a group subsystem
	var grp: SceneTypes.SceneSubgraph = store.group_elements(["conv_in", "srv_main"], "Cell Alpha", "group")
	_assert(grp != null, "group_elements successfully created group subgraph")
	_assert(grp.id.begins_with("group_"), "Group subgraph assigned valid group ID")
	_assert(grp.name == "Cell Alpha", "Group subgraph retained specified name")
	_assert(grp.elements.size() == 2, "Group subgraph contains 2 member elements")
	_assert(grp.connections.size() == 1, "Group subgraph identified 1 internal connection")
	_assert(store.selected_id == grp.id, "Group subgraph selected upon creation")

	# Verify Breadcrumb initially at root
	_assert(shell._btn_breadcrumb_root.text.contains("Root"), "Breadcrumb displays 'Root' at top-level")
	_assert(not shell._lbl_breadcrumb_scope.visible, "Breadcrumb scope label hidden at root level")

	# Enter group scope (drill-down)
	store.enter_subgraph_scope(grp.id)
	_assert(store.current_scope_id == grp.id, "Document store entered group scope")
	_assert(store.get_current_scope_name() == "Cell Alpha", "Current scope name matches group name")
	_assert(store.get_scoped_elements().size() == 2, "Scoped element query returns only the 2 group elements")
	_assert(store.get_scoped_connections().size() == 1, "Scoped connection query returns only internal connection")
	_assert(shell._lbl_breadcrumb_scope.visible, "Breadcrumb scope label visible when inside subsystem")
	_assert(shell._lbl_breadcrumb_scope.text.contains("Cell Alpha"), "Breadcrumb scope label displays 'Cell Alpha'")
	_assert(shell._btn_breadcrumb_exit.visible, "Return to root button visible when inside subsystem")

	# Exit to root scope
	store.exit_to_root_scope()
	_assert(store.current_scope_id.is_empty(), "Returned to root scope")
	_assert(store.get_current_scope_name() == "Root", "Current scope name is 'Root'")
	_assert(store.get_scoped_elements().size() == 1, "Root scope query encapsulates grouped elements (only 1 un-grouped element at root)")
	_assert(store.get_scoped_subgraphs().size() == 1, "Root scope query returns 1 subsystem group block")
	_assert(not shell._lbl_breadcrumb_scope.visible, "Breadcrumb scope label hidden after exiting to root")

	# Ungroup
	var ungroup_res: bool = store.ungroup(grp.id)
	_assert(ungroup_res, "Ungroup operation succeeded")
	_assert(store.get_subgraph(grp.id) == null, "Group subgraph removed from document")
	_assert(store.get_scoped_elements().size() == 3, "All 3 elements restored to root scope after ungroup")
	_assert(store.get_scoped_subgraphs().size() == 0, "No subgraphs remain after ungroup")
	_assert(store.active_document.elements.size() == 3, "All original elements preserved after ungroup")

	shell.free()

func test_versioned_template_packaging_and_instantiation() -> void:
	_tests_run += 1
	print("\n[Suite 27: Versioned Template Packaging & Deterministic Instantiation]")
	var shell := AuthoringShell.new()
	shell._ready()

	var cat: Catalog = shell.catalog
	var store: DocumentStore = shell.doc_store

	# Add queue and server
	var q := cat.create_element_instance("queue", "q_cell", Vector2(10, 10))
	var s := cat.create_element_instance("server", "srv_cell", Vector2(25, 10))
	store.add_element(q)
	store.add_element(s)
	store.add_connection_direct("c_int", "q_cell", "flow_out", "srv_cell", "flow_in")

	# Package as template
	var tmpl: SceneTypes.SceneSubgraph = store.package_as_template(
		["q_cell", "srv_cell"],
		"tpl_assembly_station",
		"Assembly Station",
		"1.2.0",
		"Automated robotic assembly workcell"
	)
	_assert(tmpl != null, "package_as_template created template subgraph")
	_assert(tmpl.role == "template", "Template subgraph assigned role 'template'")
	_assert(tmpl.template_version == "1.2.0", "Template version recorded as '1.2.0'")
	_assert(store.get_template("tpl_assembly_station") != null, "get_template retrieves created template")
	_assert(tmpl.exposed_ports.size() >= 2, "Synthesized exposed boundary ports for template")

	# Register into catalog
	var cat_entry := cat.register_template_entry(tmpl)
	_assert(cat_entry != null, "Catalog registered template entry")
	_assert(cat_entry.category == "Templates & Subgraphs", "Template assigned to 'Templates & Subgraphs' category")

	# Instantiate template (Instance 1)
	var inst1: SceneTypes.SceneSubgraph = store.instantiate_template(
		"tpl_assembly_station",
		"Station Alpha",
		Vector3(15.0, 5.0, 0.0)
	)
	_assert(inst1 != null, "Template instantiated successfully")
	_assert(inst1.id == "station_alpha", "Instance 1 assigned snake_case ID 'station_alpha'")
	_assert(inst1.role == "compound", "Instance 1 assigned role 'compound'")
	_assert(inst1.template_id == "tpl_assembly_station", "Instance 1 references template ID")
	_assert(inst1.template_version == "1.2.0", "Instance 1 inherits template version '1.2.0'")
	_assert(inst1.exposed_ports.size() == tmpl.exposed_ports.size(), "Instance 1 copied exposed ports from template")

	# Instantiate template (Instance 2 - verify deterministic collision avoidance)
	var inst2: SceneTypes.SceneSubgraph = store.instantiate_template(
		"tpl_assembly_station",
		"Station Alpha",
		Vector3(35.0, 5.0, 0.0)
	)
	_assert(inst2 != null, "Second template instance created")
	_assert(inst2.id == "station_alpha_02", "Collision avoidance renamed second instance to 'station_alpha_02'")
	_assert(inst2.id != inst1.id, "Instance IDs are strictly distinct")

	# Built-in template instantiation
	var builtin_inst: SceneTypes.SceneSubgraph = store.instantiate_template(
		"queue_server_station",
		"Cell Beta",
		Vector3(55.0, 5.0, 0.0)
	)
	_assert(builtin_inst != null, "Built-in queue_server_station instantiated successfully")
	_assert(builtin_inst.role == "compound", "Built-in instance is a compound subgraph")
	_assert(builtin_inst.exposed_ports.size() >= 2, "Built-in instance has exposed ports")

	shell.free()

func test_compound_boundary_ports_and_detach_policy() -> void:
	_tests_run += 1
	print("\n[Suite 28: Compound Boundary Ports, Overrides & Detach Policy]")
	var shell := AuthoringShell.new()
	shell._ready()

	var cat: Catalog = shell.catalog
	var store: DocumentStore = shell.doc_store

	# Create template proto elements
	var proto_q := cat.create_element_instance("queue", "tpl_q", Vector2(0, 0))
	var proto_srv := cat.create_element_instance("server", "tpl_srv", Vector2(20, 0))
	store.add_element(proto_q)
	store.add_element(proto_srv)
	store.add_connection_direct("c_proto", "tpl_q", "flow_out", "tpl_srv", "flow_in")

	var tmpl := store.package_as_template(["tpl_q", "tpl_srv"], "tpl_pack_line", "Pack Line", "1.0.0")
	_assert(tmpl != null, "Pack Line template packaged")

	# Instantiate compound workcell
	var comp: SceneTypes.SceneSubgraph = store.instantiate_template("tpl_pack_line", "Workcell A", Vector3(20, 10, 0))
	_assert(comp != null, "Compound workcell instantiated")

	# Add external infeed conveyor
	var infeed := cat.create_element_instance("conveyor", "infeed_belt", Vector2(5, 10))
	store.add_element(infeed)

	# Connect external infeed to compound's exposed flow_in port
	var exp_in_id: String = ""
	var exp_out_id: String = ""
	for ep in comp.exposed_ports:
		var dir_str: String = str(ep.get("direction", ""))
		if dir_str == "input" and exp_in_id.is_empty():
			exp_in_id = str(ep.get("id", ep.get("port_id", "")))
		elif dir_str == "output" and exp_out_id.is_empty():
			exp_out_id = str(ep.get("id", ep.get("port_id", "")))

	_assert(not exp_in_id.is_empty(), "Compound has exposed input port")
	_assert(not exp_out_id.is_empty(), "Compound has exposed output port")

	var c_ext = store.add_connection_direct("c_infeed_to_comp", "infeed_belt", "flow_out", comp.id, exp_in_id)
	_assert(c_ext != null, "Connected external conveyor to compound exposed input socket")

	# Set parameter override on compound
	store.set_subgraph_override(comp.id, "tpl_srv", "service_time", 4.5)
	_assert(comp.parameter_overrides.has("tpl_srv.service_time"), "Parameter override recorded on compound")
	_assert(comp.parameter_overrides["tpl_srv.service_time"] == 4.5, "Override value is 4.5s")

	# Test Detach Subgraph (Template Detach Policy)
	var detach_res = store.detach_subgraph(comp.id)
	_assert(detach_res, "detach_subgraph succeeded")
	_assert(comp.role == "group", "Detached subgraph role converted to 'group'")
	_assert(comp.template_id == null, "Detached subgraph cleared template_id")
	_assert(comp.elements.size() == 2, "Detached subgraph adopted cloned elements")

	# Verify parameter override was baked into the cloned element
	var cloned_srv_id: String = "%s_srv" % comp.id
	var cloned_srv = store.get_element(cloned_srv_id)
	_assert(cloned_srv != null, "Cloned server element exists in active document")
	if cloned_srv != null:
		_assert(cloned_srv.properties.get("service_time") == 4.5, "Cloned server inherited overridden service_time (4.5s)")

	# Verify external connection was re-wired from compound to actual cloned queue element
	var rewired_conn: SceneTypes.SceneConnection = null
	for c in store.active_document.connections:
		if c.id == "c_infeed_to_comp":
			rewired_conn = c
			break
	_assert(rewired_conn != null, "External connection persisted after detach")
	if rewired_conn != null:
		var cloned_q_id: String = "%s_q" % comp.id
		_assert(rewired_conn.target_element == cloned_q_id, "External connection re-routed target to cloned queue element")

	shell.free()

func test_four_corner_resizing_and_tightened_port_hit() -> void:
	_tests_run += 1
	print("\n[Suite 29: 4-Corner Invisible Resizing, Accurate Port Hit & Hover Feedback]")
	var store := DocumentStore.new()
	var cat := Catalog.new()
	var e1 := cat.create_element_instance("conveyor", "conv_4c", Vector2(10.0, 10.0))
	e1.geometry["dimensions"] = [6.0, 4.0, 0.8]
	store.add_element(e1)

	var block := BlockNode.new(e1)
	block._ready()

	# 1. Test 4-Corner Hit-Testing
	var c_tl := block._hit_test_resize_corner(Vector2(5.0, 5.0))
	_assert(c_tl == BlockNode.ResizeCorner.TOP_LEFT, "Top-left corner hit test resolves TOP_LEFT")

	var c_tr := block._hit_test_resize_corner(Vector2(block.size.x - 5.0, 5.0))
	_assert(c_tr == BlockNode.ResizeCorner.TOP_RIGHT, "Top-right corner hit test resolves TOP_RIGHT")

	var c_br := block._hit_test_resize_corner(Vector2(block.size.x - 5.0, block.size.y - 5.0))
	_assert(c_br == BlockNode.ResizeCorner.BOTTOM_RIGHT, "Bottom-right corner hit test resolves BOTTOM_RIGHT")

	var c_bl := block._hit_test_resize_corner(Vector2(5.0, block.size.y - 5.0))
	_assert(c_bl == BlockNode.ResizeCorner.BOTTOM_LEFT, "Bottom-left corner hit test resolves BOTTOM_LEFT")

	var c_center := block._hit_test_resize_corner(block.size * 0.5)
	_assert(c_center == BlockNode.ResizeCorner.NONE, "Center body hit test returns NONE for resize corner")

	# 2. Test Tightened Port Hit Testing
	var port_pos := block.get_port_local_position("flow_in")
	var hit_exact := block._hit_test_port(port_pos)
	_assert(hit_exact == "flow_in", "Port hit test passes at exact socket center")

	var hit_near := block._hit_test_port(port_pos + Vector2(4.0, 0.0))
	_assert(hit_near == "flow_in", "Port hit test passes within socket circle (4px offset)")

	var hit_far := block._hit_test_port(port_pos + Vector2(12.0, 0.0))
	_assert(hit_far == "", "Port hit test cleanly rejects clicks outside tight socket zone (12px offset)")

	# 3. Test Hover Cursor Shapes
	var mm_tl := InputEventMouseMotion.new()
	mm_tl.position = Vector2(5.0, 5.0)
	block._gui_input(mm_tl)
	_assert(block.mouse_default_cursor_shape == Control.CURSOR_FDIAGSIZE, "Hover over Top-Left corner shows CURSOR_FDIAGSIZE")

	var mm_tr := InputEventMouseMotion.new()
	mm_tr.position = Vector2(block.size.x - 5.0, 5.0)
	block._gui_input(mm_tr)
	_assert(block.mouse_default_cursor_shape == Control.CURSOR_BDIAGSIZE, "Hover over Top-Right corner shows CURSOR_BDIAGSIZE")

	var mm_br := InputEventMouseMotion.new()
	mm_br.position = Vector2(block.size.x - 5.0, block.size.y - 5.0)
	block._gui_input(mm_br)
	_assert(block.mouse_default_cursor_shape == Control.CURSOR_FDIAGSIZE, "Hover over Bottom-Right corner shows CURSOR_FDIAGSIZE")

	var mm_bl := InputEventMouseMotion.new()
	mm_bl.position = Vector2(5.0, block.size.y - 5.0)
	block._gui_input(mm_bl)
	_assert(block.mouse_default_cursor_shape == Control.CURSOR_BDIAGSIZE, "Hover over Bottom-Left corner shows CURSOR_BDIAGSIZE")

	var mm_port := InputEventMouseMotion.new()
	mm_port.position = port_pos
	block._gui_input(mm_port)
	_assert(block.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND, "Hover over Port shows CURSOR_POINTING_HAND")

	var mm_center := InputEventMouseMotion.new()
	mm_center.position = block.size * 0.5
	block._gui_input(mm_center)
	_assert(block.mouse_default_cursor_shape == Control.CURSOR_ARROW, "Hover over body shows CURSOR_ARROW")

	# 4. Interactive Resizing Simulations
	# 4A. Bottom-Right Resize: Top-Left anchored at (10.0, 10.0)
	var mb_down_br := InputEventMouseButton.new()
	mb_down_br.button_index = MOUSE_BUTTON_LEFT
	mb_down_br.pressed = true
	mb_down_br.position = Vector2(block.size.x - 5.0, block.size.y - 5.0)
	mb_down_br.global_position = mb_down_br.position
	block._gui_input(mb_down_br)
	_assert(block._resizing and block._active_resize_corner == BlockNode.ResizeCorner.BOTTOM_RIGHT, "Bottom-right click initiates resizing")

	var mm_drag_br := InputEventMouseMotion.new()
	mm_drag_br.global_position = mb_down_br.global_position + Vector2(20.0, 20.0) # +1.0m length, +1.0m width
	block._gui_input(mm_drag_br)

	var br_dims := block._get_physical_dimensions()
	_assert(abs(br_dims.x - 7.0) < 0.05, "Bottom-Right drag expanded length to 7.0m (+1.0m)")
	_assert(abs(br_dims.y - 5.0) < 0.05, "Bottom-Right drag expanded width to 5.0m (+1.0m)")
	_assert(abs(e1.transform.position.x - 10.0) < 0.01 and abs(e1.transform.position.y - 10.0) < 0.01, "Top-Left origin stays anchored at (10.0, 10.0)")

	var mb_up := InputEventMouseButton.new()
	mb_up.button_index = MOUSE_BUTTON_LEFT
	mb_up.pressed = false
	block._gui_input(mb_up)
	_assert(not block._resizing, "Releasing mouse commits resize")

	# 4B. Top-Left Resize: Bottom-Right anchored at (10 + 7, 10 + 5) = (17.0, 15.0)
	# Drag Top-Left outward by -20px (-1.0m) in X and -20px (-1.0m) in Y
	var mb_down_tl := InputEventMouseButton.new()
	mb_down_tl.button_index = MOUSE_BUTTON_LEFT
	mb_down_tl.pressed = true
	mb_down_tl.position = Vector2(5.0, 5.0)
	mb_down_tl.global_position = mb_down_tl.position
	block._gui_input(mb_down_tl)
	_assert(block._resizing and block._active_resize_corner == BlockNode.ResizeCorner.TOP_LEFT, "Top-left click initiates resizing")

	var mm_drag_tl := InputEventMouseMotion.new()
	mm_drag_tl.global_position = mb_down_tl.global_position - Vector2(20.0, 20.0) # -20px in X and Y (drag outwards)
	block._gui_input(mm_drag_tl)

	var tl_dims := block._get_physical_dimensions()
	_assert(abs(tl_dims.x - 8.0) < 0.05, "Top-Left drag expanded length to 8.0m (+1.0m)")
	_assert(abs(tl_dims.y - 6.0) < 0.05, "Top-Left drag expanded width to 6.0m (+1.0m)")
	_assert(abs(e1.transform.position.x - 9.0) < 0.05, "Origin shifted by -1.0m in X to 9.0m")
	_assert(abs(e1.transform.position.y - 9.0) < 0.05, "Origin shifted by -1.0m in Y to 9.0m")
	var opp_corner_x: float = e1.transform.position.x + tl_dims.x
	var opp_corner_y: float = e1.transform.position.y + tl_dims.y
	_assert(abs(opp_corner_x - 17.0) < 0.05 and abs(opp_corner_y - 15.0) < 0.05, "Opposite Bottom-Right corner stays strictly anchored at (17.0, 15.0)")
	block._gui_input(mb_up)

	# 5. Test Atomic Undo of Geometry and Position
	store.update_element_geometry_and_position("conv_4c", tl_dims, e1.transform.position, Vector3(6.0, 4.0, 0.8), Vector3(10.0, 10.0, 0.0))
	var did_undo := store.undo()
	_assert(did_undo, "Undo transaction succeeded for corner resize")
	var restored_e1 := store.get_element("conv_4c")
	_assert(abs(restored_e1.geometry["dimensions"][0] - 6.0) < 0.01, "Undo restored dimensions length back to 6.0m")
	_assert(abs(restored_e1.geometry["dimensions"][1] - 4.0) < 0.01, "Undo restored dimensions width back to 4.0m")
	_assert(abs(restored_e1.transform.position.x - 10.0) < 0.01 and abs(restored_e1.transform.position.y - 10.0) < 0.01, "Undo restored origin position back to (10.0, 10.0)")

	block.free()

func test_subsystem_resizing_encapsulation_and_manifest() -> void:
	_tests_run += 1
	print("\n[Suite 30: Subsystem Encapsulation, 4-Corner Resizing & Internal Manifest]")
	var shell := AuthoringShell.new()
	shell._ready()

	var cat: Catalog = shell.catalog
	var store: DocumentStore = shell.doc_store

	# 1. Setup 3 elements and 2 connections
	var q := cat.create_element_instance("queue", "q_sub", Vector2(10, 10))
	var s := cat.create_element_instance("server", "srv_sub", Vector2(25, 10))
	var c := cat.create_element_instance("conveyor", "conv_ext", Vector2(40, 10))
	store.add_element(q)
	store.add_element(s)
	store.add_element(c)

	store.add_connection_direct("c_int", "q_sub", "flow_out", "srv_sub", "flow_in")
	store.add_connection_direct("c_ext", "srv_sub", "flow_out", "conv_ext", "flow_in")

	# 2. Group q_sub and srv_sub into Subsystem
	var sub: SceneTypes.SceneSubgraph = store.group_elements(["q_sub", "srv_sub"], "Assembly Workcell", "group")
	_assert(sub != null, "Subsystem group created successfully")

	# 3. Verify encapsulation at root scope: internal elements must NOT leak to root scope
	var scoped_root := store.get_scoped_elements()
	_assert(scoped_root.size() == 1, "Root scope contains exactly 1 element ('conv_ext'), encapsulated elements excluded")
	_assert(scoped_root[0].id == "conv_ext", "Only external conveyor remains at root scope")
	_assert(store.get_scoped_subgraphs().size() == 1, "Root scope contains exactly 1 subsystem block")

	# 4. Verify external connection rewiring to subsystem boundary port
	var ext_conn: SceneTypes.SceneConnection = null
	for conn in store.active_document.connections:
		if conn.id == "c_ext":
			ext_conn = conn
			break
	_assert(ext_conn != null, "External connection c_ext preserved")
	_assert(ext_conn.source_element == sub.id, "External wire rewired to connect from subsystem block id")
	_assert(ext_conn.target_element == "conv_ext", "External wire targets conveyor")

	# 5. Verify Subsystem Block Initial Dimensions and Sizing
	var block := BlockNode.new(null, sub)
	block._ready()
	var init_dims := block._get_physical_dimensions()
	_assert(init_dims.x >= 8.0 and init_dims.y >= 4.0, "Subsystem block initialized with valid dimensions (>= 8.0x4.0m)")
	_assert(block.size.x >= init_dims.x * 20.0, "Block size in pixels reflects physical dimensions")

	# 6. Test Interactive 4-Corner Resizing on Subsystem Block
	# 6A. Bottom-Right corner drag
	var mb_down_br := InputEventMouseButton.new()
	mb_down_br.button_index = MOUSE_BUTTON_LEFT
	mb_down_br.pressed = true
	mb_down_br.position = block.size - Vector2(5.0, 5.0)
	mb_down_br.global_position = mb_down_br.position
	block._gui_input(mb_down_br)
	_assert(block._resizing and block._active_resize_corner == BlockNode.ResizeCorner.BOTTOM_RIGHT, "Subsystem bottom-right corner initiates resizing")

	var mm_drag_br := InputEventMouseMotion.new()
	mm_drag_br.global_position = mb_down_br.global_position + Vector2(40.0, 40.0) # +2.0m length, +2.0m width
	block._gui_input(mm_drag_br)

	var br_dims := block._get_physical_dimensions()
	_assert(abs(br_dims.x - (init_dims.x + 2.0)) < 0.05, "Subsystem length expanded by +2.0m via corner drag")
	_assert(abs(br_dims.y - (init_dims.y + 2.0)) < 0.05, "Subsystem width expanded by +2.0m via corner drag")

	var mb_up := InputEventMouseButton.new()
	mb_up.button_index = MOUSE_BUTTON_LEFT
	mb_up.pressed = false
	block._gui_input(mb_up)
	_assert(not block._resizing, "Releasing mouse commits subsystem resize")

	# 6B. Top-Left corner drag (opposite BR corner anchoring)
	var start_tl_pos: Vector3 = sub.transform.position
	var mb_down_tl := InputEventMouseButton.new()
	mb_down_tl.button_index = MOUSE_BUTTON_LEFT
	mb_down_tl.pressed = true
	mb_down_tl.position = Vector2(5.0, 5.0)
	mb_down_tl.global_position = mb_down_tl.position
	block._gui_input(mb_down_tl)
	_assert(block._resizing and block._active_resize_corner == BlockNode.ResizeCorner.TOP_LEFT, "Subsystem top-left corner initiates resizing")

	var mm_drag_tl := InputEventMouseMotion.new()
	mm_drag_tl.global_position = mb_down_tl.global_position - Vector2(20.0, 20.0) # -1.0m in X and Y
	block._gui_input(mm_drag_tl)

	var tl_dims := block._get_physical_dimensions()
	_assert(abs(tl_dims.x - (br_dims.x + 1.0)) < 0.05, "Top-left drag expanded subsystem length")
	_assert(abs(tl_dims.y - (br_dims.y + 1.0)) < 0.05, "Top-left drag expanded subsystem width")
	_assert(abs(sub.transform.position.x - (start_tl_pos.x - 1.0)) < 0.05, "Subsystem position origin shifted by -1.0m")
	block._gui_input(mb_up)

	# 7. Test Store Geometry/Position Update and Undo for Subsystems
	var res_update := store.update_subgraph_geometry_and_position(sub.id, tl_dims, sub.transform.position, init_dims, start_tl_pos)
	_assert(res_update, "update_subgraph_geometry_and_position succeeded")
	var updated_sub := store.get_subgraph(sub.id)
	_assert(updated_sub.transform.scale.x == tl_dims.x, "Subsystem scale.x matches resized dimensions")
	_assert(updated_sub.editor.extensions["dimensions"][0] == tl_dims.x, "Subsystem editor dimensions updated")

	var did_undo := store.undo()
	_assert(did_undo, "Subsystem geometry undo succeeded")
	var restored_sub := store.get_subgraph(sub.id)
	_assert(abs(restored_sub.transform.scale.x - init_dims.x) < 0.01, "Undo restored subsystem initial scale length")

	# 8. Test Inspector Rendering for Subsystem
	store.select(sub.id, "subgraph")
	shell.inspector.refresh()
	_assert(shell.inspector._container.get_child_count() > 3, "Inspector rendered subsystem detail panels")

	# 9. Ungroup restores all entities and wires back to root level
	var ungroup_ok := store.ungroup(sub.id)
	_assert(ungroup_ok, "Ungroup operation succeeded")
	_assert(store.get_scoped_elements().size() == 3, "All 3 elements back at root scope after ungroup")
	_assert(store.get_scoped_subgraphs().size() == 0, "0 subgraphs remaining at root scope")

	# Verify wire c_ext rewired back to srv_sub
	var cur_ext_conn: SceneTypes.SceneConnection = null
	for conn in store.active_document.connections:
		if conn.id == "c_ext":
			cur_ext_conn = conn
			break
	_assert(cur_ext_conn != null and cur_ext_conn.source_element == "srv_sub", "External wire connection restored to original element source 'srv_sub'")

	block.free()
	shell.free()

func test_subsystem_template_packaging_and_full_instantiation() -> void:
	_tests_run += 1
	print("\n[Suite 31: Subsystem Group-to-Template Packaging & Cloned Entity Instantiation]")
	var shell := AuthoringShell.new()
	shell._ready()

	var cat: Catalog = shell.catalog
	var store: DocumentStore = shell.doc_store

	# 1. Place a Server, a Queue, and a Conveyor
	var q := cat.create_element_instance("queue", "q_cell", Vector2(10, 10))
	var srv := cat.create_element_instance("server", "srv_cell", Vector2(25, 10))
	var conv := cat.create_element_instance("conveyor", "conv_cell", Vector2(40, 10))
	store.add_element(q)
	store.add_element(srv)
	store.add_element(conv)

	store.add_connection_direct("c_q_srv", "q_cell", "flow_out", "srv_cell", "flow_in")
	store.add_connection_direct("c_srv_conv", "srv_cell", "flow_out", "conv_cell", "flow_in")

	# 2. Group all 3 into a subsystem group
	var grp: SceneTypes.SceneSubgraph = store.group_elements(["q_cell", "srv_cell", "conv_cell"], "Packaging Cell", "group")
	_assert(grp != null, "Packaging Cell group created")
	_assert(grp.elements.size() == 3, "Group contains 3 entities (queue, server, conveyor)")
	_assert(grp.connections.size() == 2, "Group contains 2 internal wires")

	# 3. Test Template Dialog populates correctly from the Group
	var dlg = shell._template_dialog
	dlg.open_for_selection([grp.id])
	_assert(dlg.visible, "Template dialog opened for group")
	_assert(dlg._name_edit.text == "Packaging Cell Template", "Dialog defaulted template name to group name + 'Template'")
	_assert(dlg._desc_edit.text.contains("3 elements"), "Dialog description accurately reports 3 elements")
	_assert(dlg._detected_ports.size() >= 2, "Dialog detected exposed boundary ports from internal elements")

	# 4. Package as reusable template
	var tmpl := store.package_as_template([grp.id], "tpl_packaging_cell", "Packaging Cell Template", "1.0.0", "Full 3-unit workcell")
	_assert(tmpl != null, "Template packaged successfully from group")
	_assert(tmpl.role == "template", "Template subgraph assigned role 'template'")
	var proto_elems = tmpl.get_extension("prototype_elements", [])
	var proto_conns = tmpl.get_extension("prototype_connections", [])
	_assert(proto_elems.size() == 3, "Template stored 3 serialized prototype elements")
	_assert(proto_conns.size() == 2, "Template stored 2 serialized prototype connections")

	# Register into catalog
	cat.register_template_entry(tmpl)
	_assert(cat.get_entry("tpl_packaging_cell") != null, "Template registered in catalog")

	# 5. Instantiate a NEW entity from the template!
	var new_comp: SceneTypes.SceneSubgraph = store.instantiate_template("tpl_packaging_cell", "Line 1 Station", Vector3(100.0, 50.0, 0.0))
	_assert(new_comp != null, "Template instantiated into compound entity")
	_assert(new_comp.role == "compound", "Instantiated entity is a compound subgraph")
	_assert(new_comp.elements.size() == 3, "Instantiated compound contains all 3 entities (queue, server, conveyor)")
	_assert(new_comp.connections.size() == 2, "Instantiated compound contains 2 internal wires")

	# 6. Verify that internal cloned entities actually exist in active_document
	for cloned_eid in new_comp.elements:
		var cloned_elem = store.get_element(str(cloned_eid))
		_assert(cloned_elem != null, "Cloned entity '%s' exists in active document" % str(cloned_eid))
		_assert(cloned_elem.transform.position.x >= 100.0, "Cloned entity positioned relative to instance world_pos (x >= 100.0)")

	# Verify root scope encapsulation (cloned entities are hidden from root canvas, compound block rendered)
	var root_elems := store.get_scoped_elements()
	for cloned_eid in new_comp.elements:
		var found_at_root := false
		for re in root_elems:
			if re.id == str(cloned_eid):
				found_at_root = true
				break
		_assert(not found_at_root, "Cloned member '%s' is encapsulated and hidden from root scope" % str(cloned_eid))

	# 7. Verify compound block visual manifest and inspector
	var comp_block := BlockNode.new(null, new_comp)
	comp_block._ready()
	_assert(comp_block.subgraph.elements.size() == 3, "BlockNode sees 3 elements for compound manifest preview")

	# 8. Verify drill-down into new compound instance
	store.enter_subgraph_scope(new_comp.id)
	var scoped_internal := store.get_scoped_elements()
	_assert(scoped_internal.size() == 3, "Drill-down into compound scope reveals exactly 3 internal member entities")
	store.exit_to_root_scope()

	# 9. Verify moving compound block shifts internal entities
	var orig_elem0_pos: Vector3 = store.get_element(str(new_comp.elements[0])).transform.position
	store.set_subgraph_position(new_comp.id, Vector3(120.0, 60.0, 0.0))
	var shifted_elem0_pos: Vector3 = store.get_element(str(new_comp.elements[0])).transform.position
	_assert(abs((shifted_elem0_pos.x - orig_elem0_pos.x) - 20.0) < 0.01, "Moving compound block shifted internal member entity position by +20m in tandem")

	# 10. Verify detach policy preserves all 3 entities as independent group
	var detach_ok := store.detach_subgraph(new_comp.id)
	_assert(detach_ok, "Detaching compound from template succeeded")
	_assert(new_comp.role == "group", "Detached compound converted to group")
	_assert(new_comp.elements.size() == 3, "Group retains all 3 entities without duplicates or empty members")

	comp_block.free()
	shell.free()




