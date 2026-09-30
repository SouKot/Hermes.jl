# test_phase7g_ports_cardinality_and_telemetry.gd
# Headless integration test suite for Phase 7G:
# 1. Perimeter Edge Ports (Left=flow_in, Right=flow_out, Top=signal_in, Bottom=metric_out) & zero side bays
# 2. Multi-Wire Bus Cardinality ("many"), 5-in/4-out delete & auto-renumbering, reorder_port_channel
# 3. High-Density Scale Guardrails (>32 warning PORT_006, >64 error PORT_004) & Popup filtering
# 4. Unified Conveyor Rendering:
#    - Straight conveyor renders directly inside its BlockNode with perimeter ports on the belt ends/rails (no duplicate canvas track)
#    - Curved conveyor renders track on canvas with flow_in/flow_out at Γ(0)/Γ(1) and Midpoint Spine Pill directly on Γ(0.5) (zero lateral offset)
# 5. Wire Visibility Tri-State Toggle (All / Focus / Off) & Contextual Socket Visibility
# 6. Adaptive Nameplates: wide/medium blocks render inline; only narrow blocks (size.x < 68) use unboxed floating caption
extends SceneTree

const Canvas2D := preload("res://scripts/authoring_2d_canvas.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const Catalog := preload("res://scripts/authoring_catalog.gd")
const BlockNode := preload("res://scripts/authoring_block_node.gd")
const SceneTypes := preload("res://scripts/scenespec_types.gd")
const ConveyorCurve3D := preload("res://scripts/conveyor_curve_3d.gd")
const FloatingInspector := preload("res://scripts/authoring_floating_inspector.gd")
const RulePanel := preload("res://scripts/authoring_rule_panel.gd")
const Outliner := preload("res://scripts/authoring_outliner.gd")

func _init() -> void:
	print("==================================================")
	print("Running Phase 7G Headless Verification Suite...")
	print("==================================================")

	var store := DocumentStore.new()
	var catalog := Catalog.new()
	var canvas := Canvas2D.new()
	canvas.doc_store = store
	canvas._ready()
	var assertions: int = 0

	# -------------------------------------------------------------------------
	# 1. Catalog Default Cardinality & Perimeter Edge Socket Coordinates
	# -------------------------------------------------------------------------
	store.create_new_document()
	var srv: SceneTypes.SceneElement = catalog.create_element_instance("server", "srv_hub", Vector2(10, 10))
	store.add_element(srv)
	canvas.rebuild_blocks()

	var b_srv: BlockNode = canvas._block_nodes["srv_hub"]
	var layout_srv := b_srv.get_bay_layout()
	if not (is_zero_approx(float(layout_srv["left_w"])) and is_zero_approx(float(layout_srv["right_w"]))):
		_fail("Expected zero side-bay widths (left_w=0, right_w=0), got: %s" % str(layout_srv))
		return
	assertions += 1

	var p_in := b_srv.get_port_local_position("flow_in")
	var p_out := b_srv.get_port_local_position("flow_out")
	var p_sig := b_srv.get_port_local_position("pause_signal")
	var p_met := b_srv.get_port_local_position("utilization")

	if not (is_zero_approx(p_in.x) and is_equal_approx(p_out.x, b_srv.size.x) and is_zero_approx(p_sig.y) and is_equal_approx(p_met.y, b_srv.size.y)):
		_fail("Expected perimeter port coordinates (Left x=0, Right x=W, Top y=0, Bottom y=H), got in=%s out=%s sig=%s met=%s" % [str(p_in), str(p_out), str(p_sig), str(p_met)])
		return
	assertions += 1

	if not (b_srv._has_point(Vector2(-5.0, p_in.y)) and b_srv._has_point(Vector2(b_srv.size.x + 5.0, p_out.y))):
		_fail("Expected _has_point() margin to cover perimeter sockets at x=0 and x=size.x")
		return
	assertions += 1
	print("[PASS] 1. Perimeter Edge Ports & Zero Side Bays verified.")

	# -------------------------------------------------------------------------
	# 2. 5-Inlet / 4-Outlet Multi-Wire Bus, Delete #3, Auto-Renumber & Undo/Redo
	# -------------------------------------------------------------------------
	for i in range(1, 6):
		var src_i: SceneTypes.SceneElement = catalog.create_element_instance("source", "src_%d" % i, Vector2(2, 3 * i))
		store.add_element(src_i)
		var c_in := SceneTypes.SceneConnection.new()
		c_in.id = "conn_in_%d" % i
		c_in.source_element = src_i.id
		c_in.source_port = "flow_out"
		c_in.target_element = "srv_hub"
		c_in.target_port = "flow_in"
		c_in.link_type = "flow"
		store.add_connection(c_in)

	for j in range(1, 5):
		var q_j: SceneTypes.SceneElement = catalog.create_element_instance("queue", "q_out_%d" % j, Vector2(20, 3 * j))
		store.add_element(q_j)
		var c_out := SceneTypes.SceneConnection.new()
		c_out.id = "conn_out_%d" % j
		c_out.source_element = "srv_hub"
		c_out.source_port = "flow_out"
		c_out.target_element = q_j.id
		c_out.target_port = "flow_in"
		c_out.link_type = "flow"
		store.add_connection(c_out)

	var in_conns_before := store.get_port_connections("srv_hub", "flow_in", false)
	var out_conns_before := store.get_port_connections("srv_hub", "flow_out", true)
	if in_conns_before.size() != 5 or out_conns_before.size() != 4:
		_fail("Expected 5 inbound and 4 outbound connections on srv_hub")
		return
	assertions += 1

	# Delete 3rd input (src_3) and 3rd output (q_out_3)
	var del_in_ok := store.delete_port_channel_by_index("srv_hub", "flow_in", false, 3)
	var del_out_ok := store.delete_port_channel_by_index("srv_hub", "flow_out", true, 3)
	if not (del_in_ok and del_out_ok):
		_fail("Failed to delete 3rd input or 3rd output channel")
		return
	assertions += 1

	var in_after := store.get_port_connections("srv_hub", "flow_in", false)
	var out_after := store.get_port_connections("srv_hub", "flow_out", true)
	if in_after.size() != 4 or out_after.size() != 3:
		_fail("Expected 4 inbound and 3 outbound channels after deleting #3, got %d and %d" % [in_after.size(), out_after.size()])
		return
	if not (in_after[0].source_element == "src_1" and in_after[1].source_element == "src_2" and in_after[2].source_element == "src_4" and in_after[3].source_element == "src_5"):
		_fail("Inbound channels did not compact/renumber cleanly after deleting #3")
		return
	if not (in_after[0].ordering == 1 and in_after[1].ordering == 2 and in_after[2].ordering == 3 and in_after[3].ordering == 4):
		_fail("Inbound channel orderings are not contiguous 1..4: [%d, %d, %d, %d]" % [in_after[0].ordering, in_after[1].ordering, in_after[2].ordering, in_after[3].ordering])
		return
	if not (out_after[0].target_element == "q_out_1" and out_after[1].target_element == "q_out_2" and out_after[2].target_element == "q_out_4"):
		_fail("Outbound channels did not compact/renumber cleanly after deleting #3")
		return
	if not (out_after[0].ordering == 1 and out_after[1].ordering == 2 and out_after[2].ordering == 3):
		_fail("Outbound channel orderings are not contiguous 1..3")
		return
	assertions += 2

	# Test Undo / Redo of channel deletion
	store.undo() # Restores 3rd output
	store.undo() # Restores 3rd input
	if store.get_port_connections("srv_hub", "flow_in", false).size() != 5 or store.get_port_connections("srv_hub", "flow_out", true).size() != 4:
		_fail("Undo did not restore deleted #3 channels and their ordering")
		return
	store.redo()
	store.redo()
	if store.get_port_connections("srv_hub", "flow_in", false).size() != 4 or store.get_port_connections("srv_hub", "flow_out", true).size() != 3:
		_fail("Redo did not re-apply channel deletions")
		return
	assertions += 1

	# Test reorder_port_channel (move channel #3 to #1 on outbound)
	store.reorder_port_channel("srv_hub", "flow_out", true, 3, 1)
	var out_reordered := store.get_port_connections("srv_hub", "flow_out", true)
	if out_reordered[0].target_element != "q_out_4" or out_reordered[0].ordering != 1:
		_fail("reorder_port_channel failed to move q_out_4 to channel #1")
		return
	assertions += 1

	# Verify no static ×N rectangle badge exists on multi-wire ports and right-clicking any connected port (>=1) opens ChannelPopup
	canvas.rebuild_blocks()
	var b_hub: BlockNode = canvas._block_nodes["srv_hub"]
	if b_hub._get_port_badge_rect("flow_out") != Rect2() or not b_hub._hit_test_port_badge(b_hub.get_port_local_position("flow_out") + Vector2(10, 0)).is_empty():
		_fail("Expected static ×N port badge rectangle to be completely removed")
		return
	var b_src1: BlockNode = canvas._block_nodes["src_1"]
	var rclick_ev := InputEventMouseButton.new()
	rclick_ev.button_index = MOUSE_BUTTON_RIGHT
	rclick_ev.pressed = true
	rclick_ev.position = b_src1.get_port_local_position("flow_out")
	rclick_ev.global_position = Vector2(120, 120)
	b_src1._gui_input(rclick_ev)
	if store.get_port_connections("src_1", "flow_out", true).size() != 1:
		_fail("Right-clicking a port with 1 connection must NOT auto-disconnect the port")
		return
	if not canvas.get_channel_popup().visible or canvas.get_channel_popup().current_element_id != "src_1":
		_fail("Right-clicking a port with 1 connection must open the Channel Manager popup")
		return
	canvas.get_channel_popup().close_popup()
	assertions += 1
	print("[PASS] 2. 5-In / 4-Out Multi-Wire Bus Delete #3, Auto-Renumber, Reorder, Undo/Redo & Right-Click Popup verified.")

	# -------------------------------------------------------------------------
	# 3. High-Density Scale (30+ Connections), Filterable Popup & Guardrails
	# -------------------------------------------------------------------------
	store.create_new_document()
	var hub: SceneTypes.SceneElement = catalog.create_element_instance("queue", "q_mega_hub", Vector2(5, 10))
	store.add_element(hub)

	for k in range(1, 36):
		var s_k: SceneTypes.SceneElement = catalog.create_element_instance("server", "srv_target_%02d" % k, Vector2(20, 2 * k))
		store.add_element(s_k)
		var ck := SceneTypes.SceneConnection.new()
		ck.id = "c_mega_%02d" % k
		ck.source_element = "q_mega_hub"
		ck.source_port = "flow_out"
		ck.target_element = s_k.id
		ck.target_port = "flow_in"
		ck.link_type = "flow"
		ck.ordering = k
		store.active_document.connections.append(ck)

	store.validate()
	var has_warn_32 := false
	for issue in store.last_diagnostics:
		if issue["code"] == "PORT_006_HIGH_FANOUT" and issue["severity"] == "warning":
			has_warn_32 = true
			break
	if not has_warn_32:
		_fail("Expected PORT_006_HIGH_FANOUT warning when port has 35 connections (>32)")
		return
	assertions += 1

	# Test ChannelPopup search filter with 35 connections
	canvas.rebuild_blocks()
	canvas.open_channel_popup("q_mega_hub", "flow_out", true, Vector2(150, 150))
	var popup = canvas.get_channel_popup()
	if popup.get_visible_channel_rows().size() != 35:
		_fail("Expected 35 rows in ChannelPopup before filtering, got %d" % popup.get_visible_channel_rows().size())
		return
	popup._search_input.text = "srv_target_27"
	popup._search_input.text_changed.emit("srv_target_27")
	var filtered_rows: Array = popup.get_visible_channel_rows()
	if filtered_rows.size() != 1 or filtered_rows[0]["peer_element"] != "srv_target_27":
		_fail("Expected ChannelPopup filter 'srv_target_27' to return 1 matching row, got %s" % str(filtered_rows))
		return
	popup.close_popup()
	assertions += 1

	# Add up to 65 connections to trigger PORT_004_CARDINALITY_EXCEEDED (>64)
	for k in range(36, 66):
		var s_k: SceneTypes.SceneElement = catalog.create_element_instance("server", "srv_target_%02d" % k, Vector2(30, 2 * (k - 35)))
		store.add_element(s_k)
		var ck := SceneTypes.SceneConnection.new()
		ck.id = "c_mega_%02d" % k
		ck.source_element = "q_mega_hub"
		ck.source_port = "flow_out"
		ck.target_element = s_k.id
		ck.target_port = "flow_in"
		ck.link_type = "flow"
		ck.ordering = k
		store.active_document.connections.append(ck)

	store.validate()
	var has_err_64 := false
	for issue in store.last_diagnostics:
		if issue["code"] == "PORT_004_CARDINALITY_EXCEEDED" and issue["severity"] == "error":
			has_err_64 = true
			break
	if not has_err_64:
		_fail("Expected PORT_004_CARDINALITY_EXCEEDED error when port has 65 connections (>64)")
		return
	assertions += 1
	print("[PASS] 3. High-Density Scale (35 & 65 connections), Popup Filtering, and Validator Guardrails verified.")

	# -------------------------------------------------------------------------
	# 4. Unified Conveyor Rendering (Straight vs. Curved — Zero Separate Blocks!)
	# -------------------------------------------------------------------------
	store.create_new_document()
	var conv_straight: SceneTypes.SceneElement = catalog.create_element_instance("conveyor", "conv_straight", Vector2(8, 8))
	store.add_element(conv_straight)

	var conv_curved: SceneTypes.SceneElement = catalog.create_element_instance("conveyor", "conv_curved", Vector2(10, 14))
	conv_curved.geometry["shape_preset"] = "l_turn_right"
	conv_curved.geometry["inlet_pose"] = {"position": [10.0, 14.0, 0.8], "tangent": [1.0, 0.0, 0.0]}
	conv_curved.geometry["outlet_pose"] = {"position": [18.0, 20.0, 0.8], "tangent": [0.0, 1.0, 0.0]}
	store.add_element(conv_curved)
	canvas.rebuild_blocks()

	var b_straight: BlockNode = canvas._block_nodes["conv_straight"]
	if b_straight._is_curved_or_joined_conveyor():
		_fail("Expected conv_straight to NOT be marked as curved/joined")
		return
	if not b_straight.uses_floating_nameplate():
		_fail("Expected conv_straight to use floating nameplate above the top rail so belt centerline stays unobstructed")
		return
	canvas.update_agent_telemetry([
		{"id": "ent_conv_test", "kind": "product", "zone": "conv_straight", "position": [11.0, 8.0]}
	])
	var target_conv_pt: Vector2 = canvas._agent_target_positions.get("ent_conv_test", Vector2.ZERO)
	if not is_equal_approx(target_conv_pt.y, 8.6):
		_fail("Expected product on conv_straight to travel along centerline y=8.6m, got y=%f" % target_conv_pt.y)
		return
	# Straight conveyor must have flow_in at (0, size.y*0.5) and flow_out at (size.x, size.y*0.5) on its own perimeter!
	var st_in_local := b_straight.get_port_local_position("flow_in")
	var st_out_local := b_straight.get_port_local_position("flow_out")
	if not (is_zero_approx(st_in_local.x) and is_equal_approx(st_out_local.x, b_straight.size.x)):
		_fail("Expected straight conveyor flow_in/flow_out on belt left/right perimeter, got %s and %s" % [str(st_in_local), str(st_out_local)])
		return
	assertions += 1

	var b_curved: BlockNode = canvas._block_nodes["conv_curved"]
	# Curved conveyor Spine Pill must sit directly on the curve midpoint (no 38px lateral offset)
	var pts_curved: PackedVector2Array = ConveyorCurve3D.sample_2d_polyline(conv_curved, store, 20)
	var mid_m: Vector2 = pts_curved[pts_curved.size() / 2]
	var expected_pill_pos: Vector2 = canvas.pan_offset + ((mid_m * 20.0) - (b_curved.size * 0.5)) * canvas.zoom_level
	if b_curved.position.distance_to(expected_pill_pos) > 1.0:
		_fail("Expected curved conveyor Midpoint Spine Pill directly on curve midpoint %s, got %s" % [str(expected_pill_pos), str(b_curved.position)])
		return
	if b_curved._port_sockets.has("flow_in") or b_curved._port_sockets.has("flow_out"):
		_fail("Curved conveyor Midpoint Spine Pill must NOT hold flow_in/flow_out sockets; they belong at Γ(0)/Γ(1)")
		return
	if not (b_curved._port_sockets.has("speed_signal") and b_curved._port_sockets.has("occupancy")):
		_fail("Curved conveyor Midpoint Spine Pill must hold speed_signal (Top) and occupancy (Bottom) ports")
		return
	assertions += 1
	print("[PASS] 4. Unified Straight & Curved Conveyor Rendering (Zero Separate Blocks) verified.")

	# -------------------------------------------------------------------------
	# 5. Wire Visibility Tri-State Toggle & Contextual Socket Visibility
	# -------------------------------------------------------------------------
	store.clear_selection()
	canvas.set_wire_visibility_mode(canvas.WireVisibilityMode.ALL)
	# Unconnected port on unselected/unhovered block should hide its socket ring
	if b_straight.should_show_port_socket("speed_signal"):
		_fail("Expected unconnected port socket 'speed_signal' to be hidden when block is idle/unselected")
		return
	# Selecting the block reveals all its port sockets
	store.select("conv_straight", "element")
	if not b_straight.should_show_port_socket("speed_signal"):
		_fail("Expected selected block to reveal all port sockets")
		return
	store.clear_selection()

	# Cycle wire visibility mode: ALL (0) -> FOCUS (1) -> OFF (2) -> ALL (0)
	if canvas.cycle_wire_visibility_mode() != 1 or canvas.get_wire_visibility_label() != "Focus":
		_fail("Expected cycle_wire_visibility_mode() to switch to Focus (1)")
		return
	if canvas.cycle_wire_visibility_mode() != 2 or canvas.get_wire_visibility_label() != "Off":
		_fail("Expected cycle_wire_visibility_mode() to switch to Off (2)")
		return
	if canvas.cycle_wire_visibility_mode() != 0 or canvas.get_wire_visibility_label() != "All":
		_fail("Expected cycle_wire_visibility_mode() to wrap back to All (0)")
		return
	assertions += 1
	print("[PASS] 5. Wire Visibility Tri-State Toggle & Contextual Socket Visibility verified.")

	# -------------------------------------------------------------------------
	# 6. Adaptive Nameplates (Compact 40×40 Source vs. 80×40 Queue)
	# -------------------------------------------------------------------------
	var src_compact: SceneTypes.SceneElement = catalog.create_element_instance("source", "src_compact", Vector2(2, 2)) # 2m x 2m -> 40x40px
	var q_medium: SceneTypes.SceneElement = catalog.create_element_instance("queue", "q_medium", Vector2(7, 2)) # 4m x 2m -> 80x40px
	store.add_element(src_compact)
	store.add_element(q_medium)
	canvas.rebuild_blocks()

	var b_src_c: BlockNode = canvas._block_nodes["src_compact"]
	var b_q_m: BlockNode = canvas._block_nodes["q_medium"]
	if not b_src_c.uses_floating_nameplate():
		_fail("Expected 40x40px Source block (size.x=40 < 68) to use floating caption")
		return
	if b_q_m.uses_floating_nameplate():
		_fail("Expected 80x40px Queue block (size.x=80 >= 68) to render its title inside the block")
		return
	if not b_q_m._port_sockets.has("release_signal") or not is_zero_approx(b_q_m.get_port_local_position("release_signal").y):
		_fail("Expected Queue block to have 'release_signal' port on Top perimeter edge (y=0)")
		return
	assertions += 1
	print("[PASS] 6. Adaptive Nameplates verified.")

	# -------------------------------------------------------------------------
	# 7. Port-Normal Wire Shapes, Interactive Waypoints (All 4 Modes) & WirePopup (Option 1B)
	# -------------------------------------------------------------------------
	var conn_wq := store.add_connection_direct("conn_wire_test", "src_compact", "flow_out", "q_medium", "flow_in", "flow")
	var srv_ctrl: SceneTypes.SceneElement = catalog.create_element_instance("server", "srv_ctrl", Vector2(7, 8))
	store.add_element(srv_ctrl)
	var conn_sig := store.add_connection_direct("conn_sig_test", "srv_ctrl", "utilization", "q_medium", "release_signal", "signal")
	canvas.rebuild_blocks()

	# 7a. Verify Port Normals: Left=(-1,0), Right=(+1,0), Top=(0,-1), Bottom=(0,+1)
	var geom_flow := canvas.compute_connection_geometry(conn_wq)
	var geom_sig := canvas.compute_connection_geometry(conn_sig)
	if not (geom_flow["start_normal"].distance_to(Vector2(1, 0)) < 0.01 and geom_flow["end_normal"].distance_to(Vector2(-1, 0)) < 0.01):
		_fail("Expected Left/Right flow ports to have horizontal normals (+X, -X), got %s and %s" % [str(geom_flow["start_normal"]), str(geom_flow["end_normal"])])
		return
	if not (geom_sig["start_normal"].distance_to(Vector2(0, 1)) < 0.01 and geom_sig["end_normal"].distance_to(Vector2(0, -1)) < 0.01):
		_fail("Expected Bottom metric / Top signal ports to have vertical normals (+Y, -Y), got %s and %s" % [str(geom_sig["start_normal"]), str(geom_sig["end_normal"])])
		return
	assertions += 1

	# 7b. Scene-Wide Default Wire Shape vs Per-Wire Override
	if store.get_effective_wire_shape("conn_wire_test") != "bezier":
		_fail("Expected default wire shape to be 'bezier'")
		return
	store.set_default_wire_shape("orthogonal")
	if store.get_effective_wire_shape("conn_wire_test") != "orthogonal":
		_fail("Expected 'auto' wire to follow scene-wide default 'orthogonal'")
		return

	# 7c. Plain Right-Click on wire -> selects wire and opens Expanded Floating Wire Pop-up (Option 1B)
	var flow_pts: PackedVector2Array = canvas.compute_connection_geometry(conn_wq)["points"]
	var click_on_wire_pt: Vector2 = flow_pts[flow_pts.size() / 2]
	var rclick_wire := InputEventMouseButton.new()
	rclick_wire.button_index = MOUSE_BUTTON_RIGHT
	rclick_wire.pressed = true
	rclick_wire.position = click_on_wire_pt
	rclick_wire.global_position = click_on_wire_pt
	canvas._gui_input(rclick_wire)

	var wpop = canvas.get_wire_popup()
	if not wpop.visible or wpop.current_conn_id != "conn_wire_test":
		_fail("Expected plain Right-Click on wire to open Expanded Floating Wire Pop-up (Option 1B) for 'conn_wire_test'")
		return
	wpop.set_shape_mode("chamfer")
	wpop.set_radius_or_tension(12.0)
	wpop.set_stroke_style("dotted")
	wpop.set_wire_width(3.0)
	wpop.set_color_override("#00d2ff")
	var vis_after := store.get_connection_visual("conn_wire_test")
	if vis_after["routing_mode"] != "chamfer" or not is_equal_approx(float(vis_after["width"]), 3.0) or vis_after["stroke_style"] != "dotted" or vis_after["color"] != "#00d2ff":
		_fail("WirePopup Option 1B controls did not persist visual settings: %s" % str(vis_after))
		return
	wpop.close_popup()
	assertions += 1

	# 7d. Interactive On-Canvas Waypoint (●) & Midpoint (⊕) Handles across ALL 4 Wire Types
	store.select("conn_wire_test", "connection")
	var geom_before_wp := canvas.compute_connection_geometry(conn_wq)
	var mid_handles_0: Array = geom_before_wp["midpoint_handles"]
	if mid_handles_0.size() != 1:
		_fail("Expected 1 midpoint (⊕) handle on 0-waypoint wire, got %d" % mid_handles_0.size())
		return

	# Left-click press on midpoint (⊕) handle to insert a new waypoint (●) and drag it
	var lpress_mid := InputEventMouseButton.new()
	lpress_mid.button_index = MOUSE_BUTTON_LEFT
	lpress_mid.pressed = true
	lpress_mid.position = mid_handles_0[0]
	canvas._gui_input(lpress_mid)

	var drag_motion := InputEventMouseMotion.new()
	drag_motion.position = mid_handles_0[0] + Vector2(0, -40)
	canvas._gui_input(drag_motion)

	var lrelease := InputEventMouseButton.new()
	lrelease.button_index = MOUSE_BUTTON_LEFT
	lrelease.pressed = false
	lrelease.position = drag_motion.position
	canvas._gui_input(lrelease)

	for mode_test in ["bezier", "orthogonal", "chamfer", "straight"]:
		store.update_connection_visual("conn_wire_test", {"routing_mode": mode_test})
		var g_mode := canvas.compute_connection_geometry(conn_wq)
		if g_mode["effective_mode"] != mode_test:
			_fail("Expected effective_mode '%s', got '%s'" % [mode_test, str(g_mode["effective_mode"])])
			return
		if g_mode["waypoint_handles"].size() != 1 or g_mode["midpoint_handles"].size() != 2 or g_mode["points"].size() < 3:
			_fail("Expected 1 waypoint (●) handle and 2 midpoint (⊕) handles in mode '%s', got wp=%d mid=%d" % [mode_test, g_mode["waypoint_handles"].size(), g_mode["midpoint_handles"].size()])
			return
	assertions += 1

	# Right-click directly on the waypoint (●) handle to delete that single bend
	var wp_pos_canvas: Vector2 = canvas.compute_connection_geometry(conn_wq)["waypoint_handles"][0]
	var rclick_wp := InputEventMouseButton.new()
	rclick_wp.button_index = MOUSE_BUTTON_RIGHT
	rclick_wp.pressed = true
	rclick_wp.position = wp_pos_canvas
	canvas._gui_input(rclick_wp)
	if store.get_connection_visual("conn_wire_test")["waypoints"].size() != 0:
		_fail("Expected Right-Click on waypoint (●) handle to remove that single waypoint")
		return

	# Shift + Right-Click on wire -> immediately deletes the connection
	var pts_for_del: PackedVector2Array = canvas.compute_connection_geometry(conn_sig)["points"]
	var shift_rclick := InputEventMouseButton.new()
	shift_rclick.button_index = MOUSE_BUTTON_RIGHT
	shift_rclick.pressed = true
	shift_rclick.shift_pressed = true
	shift_rclick.position = pts_for_del[pts_for_del.size() / 2]
	canvas._gui_input(shift_rclick)
	if store.get_connection("conn_sig_test") != null:
		_fail("Expected Shift + Right-Click on wire to immediately delete 'conn_sig_test'")
		return
	assertions += 1
	print("[PASS] 7. Port-Normal Wire Shapes (4 Modes), Interactive Waypoint Handles & WirePopup (Option 1B) verified.")

	# -------------------------------------------------------------------------
	# 8. Immediate Roadmap Actions I-1 to I-4 GUI Verification
	# -------------------------------------------------------------------------
	var src_entry = catalog.get_entry("source")
	if src_entry == null or src_entry.get_property_schema("priority").is_empty():
		_fail("Expected 'source' property schema in AuthoringCatalog to include 'priority'")
		return

	var q_entry = catalog.get_entry("queue")
	var disc_schema: Dictionary = q_entry.get_property_schema("discipline") if q_entry != null else {}
	var disc_opts: Array = []
	for opt_item in disc_schema.get("enum_options", []):
		if opt_item is Dictionary:
			disc_opts.append(str(opt_item.get("value", "")))
	for req_opt in ["FIFO", "LIFO", "Priority", "EDD", "SPT", "Custom"]:
		if not disc_opts.has(req_opt):
			_fail("Expected 'queue' discipline options to include '%s', got %s" % [req_opt, str(disc_opts)])
			return

	# Verify FloatingInspector builds cleanly for Source (default_attributes) & Queue (Custom discipline + Hooks)
	var finsp := FloatingInspector.new(store, catalog)
	finsp._ready()
	finsp.open_for_element("src_compact", Vector2(100, 100))
	store.set_element_property("src_compact", "default_attributes", {
		"batch_id": "auto_increment",
		"due_date_offset": 60.0
	})
	finsp.open_for_element("q_medium", Vector2(120, 120))
	store.set_element_property("q_medium", "discipline", "Custom")
	store.set_element_property("q_medium", "custom_discipline", "get_attribute(a, \"due_date\", Inf) < get_attribute(b, \"due_date\", Inf)")
	finsp.open_for_element("q_medium", Vector2(120, 120))
	finsp._switch_tab(4) # Switch to Hooks tab (HookContext reference + Quick Hook Presets)
	if store.get_element("q_medium").properties.get("discipline", "") != "Custom":
		_fail("Expected q_medium discipline to be 'Custom'")
		return

	# Verify AuthoringRulePanel supports Custom (Comparator)
	var rpanel := RulePanel.new()
	rpanel._ready()
	rpanel.configure("q_medium", "queue", store.get_element("q_medium").properties)
	if rpanel._discipline_option.item_count < 6 or not rpanel._custom_disc_box.visible:
		_fail("Expected AuthoringRulePanel discipline dropdown to have 6 options and show custom comparator editor when 'Custom' is active")
		return

	# Verify AuthoringOutliner renders live entity color overrides, priority, attribute summary, and expandable attributes
	var outliner := Outliner.new()
	outliner._ready()
	outliner.setup(store)
	outliner.rebuild([
		{
			"id": "ent_101",
			"element_id": "q_medium",
			"properties": {
				"color_r": 0.95,
				"color_g": 0.22,
				"color_b": 0.22,
				"mesh_type": "sphere",
				"priority": 10,
				"attributes": {
					"batch_id": 2,
					"due_date": 51.0,
					"inspected": true
				}
			}
		}
	])
	var root_item: TreeItem = outliner._tree.get_root()
	var q_elem_item: TreeItem = null
	var child := root_item.get_first_child()
	while child != null:
		var meta = child.get_metadata(0)
		if meta is Dictionary and meta.get("id", "") == "q_medium":
			q_elem_item = child
			break
		child = child.get_next()
	if q_elem_item == null or q_elem_item.get_child_count() != 1:
		_fail("Expected 1 live entity sub-item under q_medium in AuthoringOutliner")
		return
	var ent_row: TreeItem = q_elem_item.get_first_child()
	var ent_text: String = ent_row.get_text(0)
	if ent_text.find("P10") == -1 or ent_text.find("batch_id=2") == -1:
		_fail("Expected entity row in AuthoringOutliner to show priority ('P10') and attribute summary ('batch_id=2'), got '%s'" % ent_text)
		return
	if ent_row.get_child_count() != 3:
		_fail("Expected entity row in AuthoringOutliner to have 3 expandable attribute key-value child rows, got %d" % ent_row.get_child_count())
		return
	assertions += 1
	print("[PASS] 8. Immediate Roadmap Actions I-1 to I-4 GUI (Catalog, FloatingInspector, RulePanel, Outliner) verified.")

	print("==================================================")
	print("ALL PHASE 7G TESTS PASSED (%d assertion groups)" % assertions)
	print("==================================================")
	quit(0)

func _fail(msg: String) -> void:
	printerr("[FAIL] Phase 7G Test Error: " + msg)
	quit(1)

