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

	print("============================================================")
	if _failures == 0:
		print("● ALL %d TEST SUITES PASSED CLEANLY (Phase 7D-05 Verified)" % _tests_run)
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

	_assert(block.size.x >= 260.0, "Block width is at least 260px to fit 2-column bays and center")
	_assert(block.size.y >= 96.0, "Block height fits port bays and dimensions")

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

	# Hit test add buttons for all 4 columns
	var hit_flow_in := block._hit_test_add_button(Vector2(10.0, block.size.y - 10.0))
	_assert(hit_flow_in == "flow_in", "Left Bay Column 1 bottom button triggers Add Flow In")

	var hit_flow_out := block._hit_test_add_button(Vector2(40.0, block.size.y - 10.0))
	_assert(hit_flow_out == "flow_out", "Left Bay Column 2 bottom button triggers Add Flow Out")

	var hit_sig_in := block._hit_test_add_button(Vector2(block.size.x - 45.0, block.size.y - 10.0))
	_assert(hit_sig_in == "signal_in", "Right Bay Column 1 bottom button triggers Add Signal In")

	var hit_met_out := block._hit_test_add_button(Vector2(block.size.x - 15.0, block.size.y - 10.0))
	_assert(hit_met_out == "metric_out", "Right Bay Column 2 bottom button triggers Add Metric Out")

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
