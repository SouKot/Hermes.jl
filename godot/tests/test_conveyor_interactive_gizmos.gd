# tests/test_conveyor_interactive_gizmos.gd
# Dedicated test suite verifying:
# 1. Whole conveyor track dragging (predictable translational dragging anywhere along track)
# 2. S-Curve initialization & lateral offset (no collinear degeneration into straight line)
# 3. Asymmetric L-Bends (unequal leg lengths L1 != L2 and arbitrary bend angles)
# 4. Custom spline authoring (vertex dragging, midpoint [+] insertion, and conversion)
extends SceneTree

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const Catalog := preload("res://scripts/authoring_catalog.gd")
const ConveyorCurve3D := preload("res://scripts/conveyor_curve_3d.gd")
const Canvas2D := preload("res://scripts/authoring_2d_canvas.gd")
const Inspector := preload("res://scripts/authoring_inspector.gd")
const FloatingInspector := preload("res://scripts/authoring_floating_inspector.gd")
const BlockNode := preload("res://scripts/authoring_block_node.gd")

var _passed := 0
var _failed := 0

func _assert(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("  ✓ PASS: ", msg)
	else:
		_failed += 1
		printerr("  ✗ FAIL: ", msg)

func _find_labeled_spin(root_node: Node, label: String) -> SpinBox:
	for spin in root_node.find_children("*", "SpinBox", true, false):
		for sibling in spin.get_parent().get_children():
			if sibling is Label and sibling.text == label:
				return spin
	return null

func _latest_spline_conversion_dialog(root_node: Node) -> ConfirmationDialog:
	var dialogs := root_node.find_children("*", "ConfirmationDialog", true, false)
	for index in range(dialogs.size() - 1, -1, -1):
		if dialogs[index].title == "Convert to Editable Spline?":
			return dialogs[index]
	return null

func _init() -> void:
	print("============================================================")
	print("  SimViz General Conveyor & Interactive Gizmo Test Suite")
	print("============================================================")

	var store := DocumentStore.new()
	var cat := Catalog.new()
	var doc := SceneTypes.SceneDocument.new()
	store.active_document = doc

	var canvas := Canvas2D.new(store)
	var insp := Inspector.new(store, cat)

	# ─────────────────────────────────────────────────────────────────────────
	# Test 1: S-Curve Non-Zero Initialization (Issue 2)
	# ─────────────────────────────────────────────────────────────────────────
	print("\n[1] Testing S-Curve Initialization & Direct Lateral Offset...")
	var conv_s := cat.create_element_instance("conveyor", "conv_s", Vector2(10.0, 10.0))
	conv_s.geometry["dimensions"] = [10.0, 1.2, 0.8]
	store.add_element(conv_s)

	# Switch from straight to s_curve
	insp.set_conveyor_shape_preset("conv_s", "s_curve")
	_assert(str(conv_s.geometry.get("shape_preset", "")) == "s_curve", "Preset switched to s_curve")

	var baked_s := ConveyorCurve3D.sample_world_curve(conv_s, store, 36)
	var poly_s := ConveyorCurve3D.sample_2d_polyline(conv_s, store, 36)
	_assert(poly_s.size() >= 25, "S-Curve 2D polyline generated with >=25 vertices")

	# Verify max lateral displacement is >= 2.0m (not straight!)
	var max_y: float = -1e9
	var min_y: float = 1e9
	for pt in poly_s:
		max_y = maxf(max_y, pt.y)
		min_y = minf(min_y, pt.y)
	var lateral_span := max_y - min_y
	_assert(lateral_span >= 2.0, "S-Curve exhibits visible lateral displacement (span=%.2fm, not straight!)" % lateral_span)
	_assert(baked_s["total_length"] > 10.2, "S-Curve total length (%.2fm) exceeds straight chord (10.0m)" % baked_s["total_length"])
	var conv_anchored := cat.create_element_instance("conveyor", "conv_anchored", Vector2(60.0, 0.0))
	conv_anchored.geometry["shape_preset"] = "s_curve"
	conv_anchored.geometry["inlet_pose"] = {"position": [60.0, 0.0, 0.8], "tangent": [1.0, 0.0, 0.0]}
	conv_anchored.geometry["outlet_pose"] = {"position": [70.0, 0.0, 0.8], "tangent": [1.0, 0.0, 0.0]}
	store.add_element(conv_anchored)
	var anchored_curve := ConveyorCurve3D.sample_world_curve(conv_anchored, store)
	_assert((anchored_curve["outlet_pos"] as Vector3).distance_to(Vector3(70.0, 0.0, 0.8)) < 0.01, "Explicit S-curve outlet remains anchored")
	var conv_default_elbow := cat.create_element_instance("conveyor", "conv_default_elbow", Vector2(30.0, 20.0))
	store.add_element(conv_default_elbow)
	insp.set_conveyor_shape_preset("conv_default_elbow", "l_bend")
	var elbow_initial := ConveyorCurve3D.sample_world_curve(conv_default_elbow, store, 64)
	var elbow_after_cached_pose := ConveyorCurve3D.sample_world_curve(conv_default_elbow, store, 64)
	var elbow_points: PackedVector3Array = elbow_after_cached_pose["points"]
	var elbow_min_y := elbow_points[0].y
	var elbow_max_y := elbow_points[0].y
	for point in elbow_points:
		elbow_min_y = minf(elbow_min_y, point.y)
		elbow_max_y = maxf(elbow_max_y, point.y)
	_assert(elbow_max_y - elbow_min_y > 4.0 and elbow_after_cached_pose["total_length"] > elbow_initial["total_length"] - 0.1, "Fresh 90-degree L-bend stays bent after its derived corner is cached")
	_assert(not Canvas2D._is_valid_belt_triangle(Vector2.ZERO, Vector2.ZERO, Vector2.RIGHT), "Zero-area belt triangles are skipped before rendering")
	_assert(Canvas2D._is_valid_belt_triangle(Vector2.ZERO, Vector2.RIGHT, Vector2.UP), "Finite belt triangles remain drawable")
	var elbow_before_conversion := ConveyorCurve3D.sample_world_curve(conv_default_elbow, store, 64)
	insp._request_custom_spline_conversion(conv_default_elbow, func(): pass)
	var cancel_conversion := _latest_spline_conversion_dialog(insp)
	_assert(cancel_conversion != null, "Preset-to-spline change asks whether to keep the conversion")
	if cancel_conversion != null:
		cancel_conversion.canceled.emit()
	_assert(str(conv_default_elbow.geometry["shape_preset"]) == "l_bend", "Cancel restores the previous preset")
	insp._request_custom_spline_conversion(conv_default_elbow)
	var accept_conversion := _latest_spline_conversion_dialog(insp)
	if accept_conversion != null:
		accept_conversion.confirmed.emit()
	_assert(str(conv_default_elbow.geometry["shape_preset"]) == "custom_spline", "Confirm keeps the control-point spline conversion")
	var elbow_after_conversion := ConveyorCurve3D.sample_world_curve(conv_default_elbow, store, 64)
	var conversion_deviation := 0.0
	for index in range((elbow_before_conversion["points"] as PackedVector3Array).size()):
		conversion_deviation = maxf(conversion_deviation, elbow_before_conversion["points"][index].distance_to(elbow_after_conversion["points"][index]))
	_assert(conversion_deviation < 0.01, "Keeping conversion preserves the user's edited conveyor shape")
	insp.refresh()
	var custom_labels := insp.find_children("*", "Label", true, false)
	var shows_spline_controls := false
	for label in custom_labels:
		shows_spline_controls = shows_spline_controls or str(label.text).begins_with("Spline Vertices:")
	_assert(shows_spline_controls, "Confirmed conversion immediately refreshes the inspector to spline controls")

	# ─────────────────────────────────────────────────────────────────────────
	# Test 2: Asymmetric L-Bend with Unequal Legs & Arbitrary Angles (Issue 3)
	# ─────────────────────────────────────────────────────────────────────────
	print("\n[2] Testing Asymmetric L-Bend (L1 != L2, e.g. 12m infeed vs 3m outfeed, 60° angle)...")
	var conv_l := cat.create_element_instance("conveyor", "conv_l", Vector2(0.0, 0.0))
	conv_l.geometry["shape_preset"] = "l_bend"
	conv_l.geometry["shape_params"] = {
		"leg1_length": 12.0,
		"leg2_length": 3.0,
		"bend_angle_deg": 60.0,
		"bend_radius": 2.0,
		"turn_direction": "right"
	}
	conv_l.geometry["inlet_pose"] = {"position": [0.0, 0.0, 0.8], "tangent": [1.0, 0.0, 0.0]}
	store.add_element(conv_l)

	var baked_l := ConveyorCurve3D.sample_world_curve(conv_l, store, 48)
	var poly_l := ConveyorCurve3D.sample_2d_polyline(conv_l, store, 48)
	_assert(poly_l.size() >= 30, "Asymmetric L-Bend polyline generated")

	var cp_resolved: Array = conv_l.geometry["shape_params"].get("corner_pos", [])
	_assert(cp_resolved.size() >= 2, "Corner position resolved in shape_params")
	var corner_pt := Vector2(float(cp_resolved[0]), float(cp_resolved[1])) if cp_resolved.size() >= 2 else Vector2.ZERO
	var in_pt := Vector2(0.0, 0.0)
	var out_pt := poly_l[poly_l.size() - 1]

	var l1_meas := in_pt.distance_to(corner_pt)
	var l2_meas := corner_pt.distance_to(out_pt)
	_assert(absf(l1_meas - 12.0) < 0.1, "Infeed Leg 1 measured length (%.2fm) matches 12.0m" % l1_meas)
	_assert(absf(l2_meas - 3.0) < 0.1, "Outfeed Leg 2 measured length (%.2fm) matches 3.0m" % l2_meas)
	ConveyorCurve3D.update_shape_parameter(conv_l, "bend_angle_deg", 120.0, store)
	_assert(absf(float(conv_l.geometry["shape_params"]["bend_angle_deg"]) - 120.0) < 0.1, "Editing a resolved L-bend updates its angle")
	ConveyorCurve3D.update_shape_parameter(conv_l, "bend_angle_deg", 60.0, store)
	var conv_locked := cat.create_element_instance("conveyor", "conv_locked", Vector2(200.0, 40.0))
	conv_locked.geometry["shape_preset"] = "l_bend"
	conv_locked.geometry["shape_params"] = {"leg1_length": 8.0, "leg2_length": 4.0, "bend_angle_deg": 90.0, "turn_direction": "left"}
	store.add_element(conv_locked)
	ConveyorCurve3D.sample_world_curve(conv_locked, store)
	var conn_locked := SceneTypes.SceneConnection.new()
	conn_locked.id = "locked_outlet"
	conn_locked.source_element = "conv_locked"
	conn_locked.target_element = "conv_l"
	conn_locked.link_type = "flow"
	store.add_connection(conn_locked)
	store.select("conv_locked", "element")
	insp.refresh()
	var locked_presets := insp.find_children("ConveyorPresetDropdown", "OptionButton", true, false)
	var locked_preset: OptionButton = locked_presets.back() if not locked_presets.is_empty() else null
	_assert(locked_preset != null and locked_preset.disabled, "Docked inspector disables preset changes on connected conveyors")
	var locked_before := ConveyorCurve3D.sample_world_curve(conv_locked, store)
	var accepted := ConveyorCurve3D.update_shape_parameter(conv_locked, "bend_angle_deg", 45.0, store)
	var locked_after := ConveyorCurve3D.sample_world_curve(conv_locked, store)
	_assert(not accepted and (locked_after["outlet_pos"] as Vector3).distance_to(locked_before["outlet_pos"]) < 0.01, "Inspector refuses an edit that displaces a connected outlet")
	var locked_position := conv_locked.transform.position
	canvas._translate_conveyor_element("conv_locked", 3.0, 0.0)
	_assert(conv_locked.transform.position.distance_to(locked_position) < 0.01, "Whole-belt drag cannot detach a connected conveyor")
	canvas._rotate_conveyor_element("conv_locked", 45.0, Vector2(200.0, 40.0))
	_assert(conv_locked.transform.position.distance_to(locked_position) < 0.01 and absf(conv_locked.transform.rotation.z) < 0.01, "Whole-belt rotation cannot detach a connected conveyor")
	canvas.rebuild_blocks()
	canvas.enter_conveyor_geometry_mode("conv_locked")
	var locked_end: Vector3 = locked_before["outlet_pos"]
	var locked_click := InputEventMouseButton.new()
	locked_click.button_index = MOUSE_BUTTON_LEFT
	locked_click.pressed = true
	locked_click.position = canvas.pan_offset + Vector2(locked_end.x, locked_end.y) * 20.0
	canvas._gui_input(locked_click)
	_assert(canvas._conveyor_active_gizmo_type.is_empty() and not canvas._conveyor_geometry_warning.is_empty(), "Connected outlet handle is not draggable")
	canvas.exit_conveyor_geometry_mode()
	store.remove_connection(conn_locked.id)

	var conv_serp := cat.create_element_instance("conveyor", "conv_serp", Vector2(0.0, 0.0))
	conv_serp.geometry["shape_preset"] = "serpentine"
	conv_serp.geometry["shape_params"] = {"passes": 3, "pass_spacing": 2.0, "pass_length": 8.0}
	store.add_element(conv_serp)
	var serp_short := ConveyorCurve3D.sample_world_curve(conv_serp, store, 64)
	ConveyorCurve3D.update_shape_parameter(conv_serp, "pass_length", 12.0, store)
	var serp_long := ConveyorCurve3D.sample_world_curve(conv_serp, store, 64)
	_assert(float(serp_long["total_length"]) > float(serp_short["total_length"]) + 10.0, "Serpentine pass length changes the generated path")
	ConveyorCurve3D.update_shape_parameter(conv_serp, "infeed_length", 2.0, store)
	ConveyorCurve3D.update_shape_parameter(conv_serp, "outfeed_length", 3.0, store)
	var serp_with_leads := ConveyorCurve3D.sample_world_curve(conv_serp, store, 48)
	_assert(serp_with_leads["control_points"].size() == 10, "Terminal lead spans preserve the serpentine bend count")
	var serp_endpoint: Vector3 = serp_with_leads["outlet_pos"]
	_assert(Vector2(serp_endpoint.x, serp_endpoint.y).distance_to(Vector2(17, 4)) < 0.01, "Infeed and outfeed lead lengths independently extend the conveyor ends")
	conv_serp.geometry["shape_params"]["infeed_length"] = 0.0
	conv_serp.geometry["shape_params"]["outfeed_length"] = 0.0
	canvas.rebuild_blocks()
	canvas.enter_conveyor_geometry_mode("conv_serp")
	var serp_handles := canvas._serpentine_end_geometry(conv_serp)
	var guard_drag := InputEventMouseButton.new()
	guard_drag.button_index = MOUSE_BUTTON_LEFT
	guard_drag.pressed = true
	guard_drag.position = canvas.pan_offset + (serp_handles["in_join"] as Vector2) * 20.0
	canvas._gui_input(guard_drag)
	var beyond_guard := InputEventMouseMotion.new()
	beyond_guard.position = canvas.pan_offset + ((serp_handles["inlet"] as Vector2) + (serp_handles["in_direction"] as Vector2) * (float(serp_handles["max_length"]) + 2.0)) * 20.0
	canvas._gui_input(beyond_guard)
	_assert(absf(float(conv_serp.geometry["shape_params"]["infeed_length"]) - float(serp_handles["max_length"])) < 0.1, "Dragging beyond the infeed guard clamps the end-run length")
	_assert(canvas._conveyor_geometry_warning.contains("guard rail"), "Dragging beyond an end-run guard shows a warning")
	var release_guard := InputEventMouseButton.new()
	release_guard.button_index = MOUSE_BUTTON_LEFT
	canvas._gui_input(release_guard)
	canvas.exit_conveyor_geometry_mode()
	conv_serp.geometry["shape_params"]["infeed_length"] = 0.0
	conv_serp.geometry["shape_params"]["outfeed_length"] = 0.0
	ConveyorCurve3D.sample_world_curve(conv_serp, store)
	store.select("conv_serp", "element")
	insp.refresh()
	var dock_bends := _find_labeled_spin(insp, "Bends")
	_assert(dock_bends != null, "Docked inspector exposes the serpentine bend count")
	if dock_bends != null:
		dock_bends.value = 4.0
		dock_bends.value_changed.emit(4.0)
		_assert(int(conv_serp.geometry["shape_params"]["passes"]) == 5, "Docked bend control stores five runs (got %s)" % str(conv_serp.geometry["shape_params"]["passes"]))
		_assert(ConveyorCurve3D.sample_world_curve(conv_serp, store)["control_points"].size() == 14, "Docked bend count regenerates five rounded runs")
	var floating := FloatingInspector.new(store, cat)
	floating.open_for_element("conv_serp")
	floating._switch_tab(1)
	var floating_bends := _find_labeled_spin(floating, "Bends")
	_assert(floating_bends != null, "Floating inspector exposes the same bend count")
	if floating_bends != null:
		floating_bends.value = 3.0
		floating_bends.value_changed.emit(3.0)
		_assert(int(conv_serp.geometry["shape_params"]["passes"]) == 4 and ConveyorCurve3D.sample_world_curve(conv_serp, store)["control_points"].size() == 11, "Floating bend count regenerates four rounded runs")
	var add_key_button: Button = null
	for button in insp.find_children("*", "Button", true, false):
		if button.text == "+ Width Key":
			add_key_button = button
	_assert(add_key_button != null, "Docked geometry panel offers local width keys")
	if add_key_button != null:
		add_key_button.pressed.emit()
		_assert((conv_serp.geometry.get("width_profile", []) as Array).size() == 1, "Adding a local width key keeps the serpentine preset")
		_assert(absf(ConveyorCurve3D.next_width_key_fraction(conv_serp) - 0.25) < 0.01, "Next width key fills the largest open path span")
		floating._switch_tab(1)
		var local_width_spin := _find_labeled_spin(floating, "Local Width (m)")
		_assert(local_width_spin != null, "Floating inspector exposes local cross-section width")
		if local_width_spin != null:
			local_width_spin.value_changed.emit(3.0)
			_assert(absf(ConveyorCurve3D.width_at_fraction(conv_serp, 0.5) - 3.0) < 0.05, "Floating local width changes rendered belt cross-section")
			_assert(str(ConveyorCurve3D.geometry_diagnostics(conv_serp, store)["warning"]).contains("overlap"), "Width exceeding serpentine lane spacing warns of overlap")
		var remove_key_button: Button = null
		for button in floating.find_children("*", "Button", true, false):
			if button.tooltip_text == "Remove width key":
				remove_key_button = button
		_assert(remove_key_button != null, "Floating geometry panel offers width key removal")
		if remove_key_button != null:
			remove_key_button.pressed.emit()
			_assert(conv_serp.geometry["width_profile"].is_empty(), "Removing local key restores uniform width")
	var floating_elbow := cat.create_element_instance("conveyor", "floating_elbow", Vector2(75, 30))
	floating_elbow.geometry["shape_preset"] = "l_bend"
	store.add_element(floating_elbow)
	var floating_elbow_before := ConveyorCurve3D.sample_world_curve(floating_elbow, store, 64)
	floating.open_for_element("floating_elbow")
	floating._switch_tab(1)
	var floating_dropdowns := floating.find_children("FloatingConveyorPresetDropdown", "OptionButton", true, false)
	var floating_dropdown: OptionButton = floating_dropdowns.back() if not floating_dropdowns.is_empty() else null
	_assert(floating_dropdown != null, "Floating preset selector is available for conversion")
	if floating_dropdown != null:
		var custom_idx: int = ConveyorCurve3D.PRESET_IDS.find("custom_spline")
		floating_dropdown.select(custom_idx)
		floating_dropdown.item_selected.emit(custom_idx)
		var cancel_dialog := _latest_spline_conversion_dialog(floating)
		_assert(cancel_dialog != null, "Floating preset conversion asks whether to keep the spline")
		if cancel_dialog != null:
			cancel_dialog.canceled.emit()
		_assert(str(floating_elbow.geometry["shape_preset"]) == "l_bend", "Floating cancel restores the previous preset")
		floating_dropdown.select(custom_idx)
		floating_dropdown.item_selected.emit(custom_idx)
		var keep_dialog := _latest_spline_conversion_dialog(floating)
		if keep_dialog != null:
			keep_dialog.confirmed.emit()
		floating.refresh()
		_assert(str(floating_elbow.geometry["shape_preset"]) == "custom_spline", "Floating confirmation keeps spline conversion")
		var floating_elbow_after := ConveyorCurve3D.sample_world_curve(floating_elbow, store, 64)
		var floating_conversion_error := 0.0
		for index in range((floating_elbow_before["points"] as PackedVector3Array).size()):
			floating_conversion_error = maxf(floating_conversion_error, floating_elbow_before["points"][index].distance_to(floating_elbow_after["points"][index]))
		_assert(floating_conversion_error < 0.01, "Floating confirmation preserves the conveyor shape")
	floating.free()

	var conv_helix := cat.create_element_instance("conveyor", "conv_helix", Vector2(0.0, 0.0))
	conv_helix.geometry["shape_preset"] = "spiral_helix"
	conv_helix.geometry["shape_params"] = {"helix_radius": 2.0, "helix_turns": 1.5, "elevation_gain": 3.0}
	store.add_element(conv_helix)
	insp.refresh()
	var pitch_spin := _find_labeled_spin(insp, "Pitch (m/turn)")
	_assert(pitch_spin != null, "Helix preset offers pitch alongside rise and turns")
	if pitch_spin != null:
		pitch_spin.value_changed.emit(3.0)
		_assert(absf(float(conv_helix.geometry["shape_params"]["elevation_gain"]) - 4.5) < 0.01, "Pitch changes helix rise without converting its preset")
	var helix_small := ConveyorCurve3D.sample_world_curve(conv_helix, store, 64)
	ConveyorCurve3D.update_shape_parameter(conv_helix, "helix_radius", 4.0, store)
	var helix_large := ConveyorCurve3D.sample_world_curve(conv_helix, store, 64)
	_assert(float(helix_large["total_length"]) > float(helix_small["total_length"]) + 10.0, "Helix radius changes the generated path")
	ConveyorCurve3D.convert_element_to_custom_spline(conv_helix, store)
	var helix_custom := ConveyorCurve3D.sample_world_curve(conv_helix, store, 64)
	var helix_conversion_error := 0.0
	for idx in range((helix_large["points"] as PackedVector3Array).size()):
		helix_conversion_error = maxf(helix_conversion_error, helix_large["points"][idx].distance_to(helix_custom["points"][idx]))
	_assert(helix_conversion_error < 0.01, "Helix conversion preserves the full 3D path (error=%.4fm)" % helix_conversion_error)
	var helix_points: Array = conv_helix.geometry["shape_params"]["control_points"]
	var helix_station: Dictionary = helix_points[2]
	var old_helix_z: float = float(helix_station["pos"][2])
	canvas._conveyor_active_gizmo_type = "spline_vertex"
	canvas._conveyor_active_gizmo_elem_id = "conv_helix"
	canvas._conveyor_active_gizmo_idx = 2
	var station_px := canvas.pan_offset + Vector2(float(helix_station["pos"][0]), float(helix_station["pos"][1])) * 20.0
	canvas._conveyor_drag_prev_canvas_mouse = station_px
	var height_drag := InputEventMouseMotion.new()
	height_drag.shift_pressed = true
	height_drag.position = station_px + Vector2(0, -20)
	canvas._gui_input(height_drag)
	_assert(absf(float(helix_station["pos"][2]) - old_helix_z - 1.0) < 0.01, "Shift-drag raises a freeform station without flattening its 3D path")
	canvas._conveyor_active_gizmo_type = ""
	canvas._conveyor_active_gizmo_elem_id = ""

	# ─────────────────────────────────────────────────────────────────────────
	# Test 3: Whole-Conveyor Translational Dragging (Issue 1)
	# ─────────────────────────────────────────────────────────────────────────
	print("\n[3] Testing Whole-Conveyor Translational Dragging across Canvas...")
	canvas.pan_offset = Vector2(0, 0)
	canvas.zoom_level = 1.0
	canvas.rebuild_blocks()

	var prev_l_corner: Vector2 = corner_pt
	var prev_l_in := Vector2(float(conv_l.geometry["inlet_pose"]["position"][0]), float(conv_l.geometry["inlet_pose"]["position"][1]))
	var prev_l_out := Vector2(float(conv_l.geometry["outlet_pose"]["position"][0]), float(conv_l.geometry["outlet_pose"]["position"][1]))

	# Simulate dragging the conveyor by (+15.0m, -8.0m)
	canvas._translate_conveyor_element("conv_l", 15.0, -8.0)

	var new_l_in := Vector2(float(conv_l.geometry["inlet_pose"]["position"][0]), float(conv_l.geometry["inlet_pose"]["position"][1]))
	var new_l_out := Vector2(float(conv_l.geometry["outlet_pose"]["position"][0]), float(conv_l.geometry["outlet_pose"]["position"][1]))
	var new_l_corner := Vector2(float(conv_l.geometry["shape_params"]["corner_pos"][0]), float(conv_l.geometry["shape_params"]["corner_pos"][1]))

	_assert(absf((new_l_in - prev_l_in).x - 15.0) < 0.1, "Inlet pose translated by +15.0m in X")
	_assert(absf((new_l_in - prev_l_in).y - (-8.0)) < 0.1, "Inlet pose translated by -8.0m in Y")
	_assert(absf((new_l_out - prev_l_out).x - 15.0) < 0.1, "Outlet pose translated by +15.0m in X")
	_assert(absf((new_l_corner - prev_l_corner).x - 15.0) < 0.1, "Elbow corner translated by +15.0m in X without distortion")
	_assert(absf((new_l_corner - prev_l_corner).y - (-8.0)) < 0.1, "Elbow corner translated by -8.0m in Y without distortion")

	# ─────────────────────────────────────────────────────────────────────────
	# Test 4: Custom Controlled Spline & On-Canvas Gizmos (Issue 4)
	# ─────────────────────────────────────────────────────────────────────────
	print("\n[4] Testing Custom Controlled Spline System & Conversion...")
	var conv_spl := cat.create_element_instance("conveyor", "conv_spl", Vector2(30.0, 30.0))
	conv_spl.geometry["dimensions"] = [12.0, 1.2, 0.8]
	conv_spl.geometry["shape_preset"] = "s_curve"
	store.add_element(conv_spl)

	# Convert to custom spline
	var before_conversion := ConveyorCurve3D.sample_world_curve(conv_spl, store, 64)
	ConveyorCurve3D.convert_element_to_custom_spline(conv_spl, store)
	_assert(str(conv_spl.geometry.get("shape_preset", "")) == "custom_spline", "Converted to custom_spline")
	var cpts_arr: Array = conv_spl.geometry["shape_params"].get("control_points", [])
	_assert(cpts_arr.size() >= 2, "Converted spline has >= 2 control points (count=%d)" % cpts_arr.size())
	var after_conversion := ConveyorCurve3D.sample_world_curve(conv_spl, store, 64)
	var conversion_error := 0.0
	for idx in range((before_conversion["points"] as PackedVector3Array).size()):
		conversion_error = maxf(conversion_error, before_conversion["points"][idx].distance_to(after_conversion["points"][idx]))
	_assert(conversion_error < 0.01, "Spline conversion preserves the evaluated curve (error=%.4fm)" % conversion_error)

	# Test gizmo hit testing
	store.select("conv_spl", "element")
	var first_point_pos: Array = cpts_arr[0]["pos"]
	var normal_view_point := canvas.pan_offset + Vector2(float(first_point_pos[0]), float(first_point_pos[1])) * 20.0
	_assert(canvas._hit_test_conveyor_gizmo(normal_view_point).is_empty(), "Spline edit handles are hidden in normal view")
	canvas.enter_conveyor_geometry_mode("conv_spl")
	var first_cp: Array = cpts_arr[0]["pos"]
	var v0_canvas: Vector2 = canvas.pan_offset + Vector2(float(first_cp[0]), float(first_cp[1])) * (20.0 * canvas.zoom_level)
	var hit_g := canvas._hit_test_conveyor_gizmo(v0_canvas)
	_assert(not hit_g.is_empty(), "Hit test detected spline vertex gizmo at canvas position")
	_assert(str(hit_g.get("type", "")) in ["spline_vertex", "inlet"], "Gizmo type is spline_vertex or inlet")

	# Test adding a point via midpoint [+] insertion
	var pre_count: int = cpts_arr.size()
	# Simulate midpoint click between vertex 0 and 1
	var curve_before_insert := ConveyorCurve3D.sample_world_curve(conv_spl, store, 64)
	var mid3: Vector3 = ConveyorCurve3D.custom_span_midpoint(conv_spl, 0)
	var mid_canvas := canvas.pan_offset + Vector2(mid3.x, mid3.y) * (20.0 * canvas.zoom_level)
	var mid_hit := canvas._hit_test_conveyor_gizmo(mid_canvas)
	_assert(not mid_hit.is_empty() and str(mid_hit.get("type", "")) == "midpoint_add", "Midpoint [+] insertion handle detected at span center")

	# Simulate left-click on midpoint handle to insert vertex
	var mb_add := InputEventMouseButton.new()
	mb_add.button_index = MOUSE_BUTTON_LEFT
	mb_add.pressed = true
	mb_add.position = mid_canvas
	canvas._gui_input(mb_add)
	var inserted_points: Array = conv_spl.geometry["shape_params"]["control_points"]
	_assert(inserted_points.size() == pre_count + 1, "Vertex inserted successfully into spline (new count=%d)" % inserted_points.size())
	var curve_after_insert := ConveyorCurve3D.sample_world_curve(conv_spl, store, 64)
	var insert_error := 0.0
	for idx in range((curve_before_insert["points"] as PackedVector3Array).size()):
		insert_error = maxf(insert_error, curve_before_insert["points"][idx].distance_to(curve_after_insert["points"][idx]))
	_assert(insert_error < 0.01, "Inserting a bend leaves the curve unchanged (error=%.4fm)" % insert_error)
	var selected_point: Dictionary = inserted_points[1]
	var old_out: Array = selected_point["out_handle"].duplicate()
	var handle_xy := Vector2(float(selected_point["pos"][0]) + float(old_out[0]), float(selected_point["pos"][1]) + float(old_out[1]))
	var handle_px := canvas.pan_offset + handle_xy * 20.0
	var handle_hit := canvas._hit_test_conveyor_gizmo(handle_px)
	_assert(str(handle_hit.get("type", "")) == "out_handle", "Spline tangent arm is hit-testable")
	canvas._conveyor_active_gizmo_type = "out_handle"
	canvas._conveyor_active_gizmo_elem_id = "conv_spl"
	canvas._conveyor_active_gizmo_idx = 1
	var tangent_drag := InputEventMouseMotion.new()
	tangent_drag.position = handle_px + Vector2(0, 30)
	canvas._gui_input(tangent_drag)
	_assert(absf(float(selected_point["out_handle"][1]) - float(old_out[1])) > 1.0, "Dragging tangent arm edits stored spline handle")
	canvas._conveyor_active_gizmo_type = ""
	canvas._conveyor_active_gizmo_elem_id = ""

	var conv_turn := cat.create_element_instance("conveyor", "conv_turn", Vector2(120.0, 50.0))
	conv_turn.geometry["shape_preset"] = "u_turn"
	store.add_element(conv_turn)
	var default_turn := ConveyorCurve3D.sample_world_curve(conv_turn, store, 36)
	ConveyorCurve3D.update_shape_parameter(conv_turn, "return_leg_length", 3.0, store)
	var shorter_return := ConveyorCurve3D.sample_world_curve(conv_turn, store, 36)
	_assert(absf((shorter_return["outlet_pos"] as Vector3).x - (default_turn["outlet_pos"] as Vector3).x - 3.0) < 0.1, "U-turn return reach changes independently of its hairpin")
	canvas.rebuild_blocks()
	canvas.enter_conveyor_geometry_mode("conv_turn")
	var turn_before := ConveyorCurve3D.sample_world_curve(conv_turn, store, 36)
	var turn_end: Vector3 = turn_before["outlet_pos"]
	var turn_mouse := InputEventMouseButton.new()
	turn_mouse.button_index = MOUSE_BUTTON_LEFT
	turn_mouse.pressed = true
	turn_mouse.position = canvas.pan_offset + Vector2(turn_end.x, turn_end.y) * 20.0
	canvas._gui_input(turn_mouse)
	var endpoint_conversion := _latest_spline_conversion_dialog(canvas)
	_assert(endpoint_conversion != null and str(conv_turn.geometry.get("shape_preset", "")) == "u_turn", "Unsupported U-turn endpoint edit warns before changing the preset")
	if endpoint_conversion != null:
		endpoint_conversion.canceled.emit()
	_assert(str(conv_turn.geometry.get("shape_preset", "")) == "u_turn", "Cancel keeps the U-turn preset unchanged")
	canvas._gui_input(turn_mouse)
	endpoint_conversion = _latest_spline_conversion_dialog(canvas)
	var endpoint_before_conversion := ConveyorCurve3D.sample_world_curve(conv_turn, store, 36)
	if endpoint_conversion != null:
		endpoint_conversion.confirmed.emit()
	_assert(str(conv_turn.geometry.get("shape_preset", "")) == "custom_spline", "Confirm converts the U-turn to editable control points")
	var endpoint_after_conversion := ConveyorCurve3D.sample_world_curve(conv_turn, store, 36)
	_assert((endpoint_before_conversion["outlet_pos"] as Vector3).distance_to(endpoint_after_conversion["outlet_pos"]) < 0.01, "Endpoint conversion preserves the current outlet before dragging")
	canvas.rebuild_blocks()
	canvas.enter_conveyor_geometry_mode("conv_turn")
	canvas._gui_input(turn_mouse)
	var turn_drag := InputEventMouseMotion.new()
	turn_drag.position = turn_mouse.position + Vector2(40, 0)
	canvas._gui_input(turn_drag)
	var turn_after := ConveyorCurve3D.sample_world_curve(conv_turn, store, 36)
	var moved_end: Vector3 = turn_after["outlet_pos"]
	_assert(absf(moved_end.x - turn_end.x - 2.0) < 0.1, "Promoted U-turn outlet moves from the dragged side")
	canvas._conveyor_active_gizmo_type = ""
	canvas._conveyor_active_gizmo_elem_id = ""
	canvas.exit_conveyor_geometry_mode()
	var old_end_x: float = float(inserted_points[-1]["pos"][0])
	canvas._conveyor_active_gizmo_type = "outlet"
	canvas._conveyor_active_gizmo_elem_id = "conv_spl"
	var end_drag := InputEventMouseMotion.new()
	end_drag.position = canvas.pan_offset + Vector2(old_end_x + 2.0, float(inserted_points[-1]["pos"][1])) * 20.0
	canvas._gui_input(end_drag)
	_assert(absf(float(inserted_points[-1]["pos"][0]) - old_end_x - 2.0) < 0.1, "Dragging custom outlet changes the spline endpoint")
	canvas._conveyor_active_gizmo_type = ""
	canvas._conveyor_active_gizmo_elem_id = ""

	# ─────────────────────────────────────────────────────────────────────────
	# Test 5: Belt Width Rail Handles & Dragging
	# ─────────────────────────────────────────────────────────────────────────
	print("\n[5] Testing Conveyor Width Rail Handles & Live Dragging...")
	store.select("conv_s", "element")
	var normal_view_mid := canvas.pan_offset + canvas._conveyor_pivot(conv_s) * 20.0
	_assert(canvas._hit_test_conveyor_gizmo(normal_view_mid).is_empty(), "Curved geometry handles are hidden in normal view")
	canvas.enter_conveyor_geometry_mode("conv_s")
	var s_poly := ConveyorCurve3D.sample_2d_polyline(conv_s, store, 36)
	var mid_pt := s_poly[s_poly.size() / 2]
	var w_init: float = float(conv_s.geometry["dimensions"][1])
	_assert(absf(w_init - 1.2) < 0.05, "Initial belt width is 1.2m")

	# Hit test the lateral rail handle
	var mid_canvas_s := canvas.pan_offset + mid_pt * (20.0 * canvas.zoom_level)
	# Normal displacement for width rail handle (half width = 0.6m = 12px at zoom 1.0)
	var rail_mouse := mid_canvas_s + Vector2(0.0, 12.0)
	var rail_hit := canvas._hit_test_conveyor_gizmo(rail_mouse)
	_assert(not rail_hit.is_empty(), "Hit test detected conveyor gizmo near lateral edge")
	_assert(str(rail_hit.get("type", "")) in ["width_rail", "inflection"], "Gizmo detected width_rail or inflection")

	# Simulate dragging width_rail to increase width to 2.4m
	canvas._conveyor_active_gizmo_type = "width_rail"
	canvas._conveyor_active_gizmo_elem_id = "conv_s"
	var mm_drag := InputEventMouseMotion.new()
	# Mouse at 1.2m offset from center in world units
	var target_world := mid_pt + Vector2(0.0, 1.2)
	mm_drag.position = canvas.pan_offset + target_world * (20.0 * canvas.zoom_level)
	canvas._gui_input(mm_drag)

	var w_new: float = float(conv_s.geometry["dimensions"][1])
	_assert(w_new >= 2.0, "Belt width successfully increased via width_rail drag (w=%.2fm)" % w_new)
	conv_s.geometry["width_profile"] = [{"fraction": 0.5, "scale": 1.5}]
	var saved_conveyor := SceneTypes.SceneElement.from_dict(conv_s.to_dict())
	_assert(absf(ConveyorCurve3D.width_at_fraction(saved_conveyor, 0.5) - ConveyorCurve3D.width_at_fraction(conv_s, 0.5)) < 0.01, "Width keys survive SceneSpec element round-trip")
	var path_before_width := ConveyorCurve3D.sample_world_curve(conv_s, store, 64)
	_assert(absf(ConveyorCurve3D.width_at_fraction(conv_s, 0.5) - w_new * 1.5) < 0.01, "A width key widens only the local cross-section")
	_assert(absf(ConveyorCurve3D.width_at_fraction(conv_s, 0.0) - w_new) < 0.01, "A midpoint width key preserves inlet width")
	canvas.enter_conveyor_geometry_mode("conv_s")
	var key_frame := canvas._conveyor_width_key_frame(conv_s, 0.5)
	var key_center: Vector2 = key_frame["center"]
	var key_normal: Vector2 = key_frame["normal"]
	var key_pos := canvas.pan_offset + (key_center + key_normal * ConveyorCurve3D.width_at_fraction(conv_s, 0.5) * 0.5) * 20.0
	_assert(str(canvas._hit_test_conveyor_gizmo(key_pos).get("type", "")) == "width_key", "Local width key is hit-testable on the rail")
	var key_press := InputEventMouseButton.new()
	key_press.button_index = MOUSE_BUTTON_LEFT
	key_press.pressed = true
	key_press.position = key_pos
	canvas._gui_input(key_press)
	var key_motion := InputEventMouseMotion.new()
	key_motion.position = canvas.pan_offset + (key_center + key_normal * 2.4) * 20.0
	canvas._gui_input(key_motion)
	_assert(absf(ConveyorCurve3D.width_at_fraction(conv_s, 0.5) - 4.8) < 0.1, "Dragging a local key changes width at its own path position")
	var width_after_key := ConveyorCurve3D.sample_world_curve(conv_s, store, 64)
	_assert((width_after_key["midpoint"] as Vector3).distance_to(path_before_width["midpoint"]) < 0.01, "Changing cross-section does not deform the centerline")
	var key_release := InputEventMouseButton.new()
	key_release.button_index = MOUSE_BUTTON_LEFT
	canvas._gui_input(key_release)
	canvas.exit_conveyor_geometry_mode()

	# ─────────────────────────────────────────────────────────────────────────
	# Test 6: Dedicated Conveyor Geometry Mode
	# ─────────────────────────────────────────────────────────────────────────
	print("\n[6] Testing Dedicated Conveyor Geometry Editing Mode...")
	_assert(not canvas.is_in_conveyor_geometry_mode(), "Initially not in geometry mode")
	canvas.enter_conveyor_geometry_mode("conv_s")
	_assert(canvas.is_in_conveyor_geometry_mode(), "Successfully entered Conveyor Geometry Mode")
	_assert(canvas._conveyor_geom_mode_elem_id == "conv_s", "Active geometry mode element is conv_s")

	var b_conv_s: BlockNode = canvas._block_nodes["conv_s"]
	_assert(b_conv_s.is_geometry_mode_active, "BlockNode is_geometry_mode_active is true")
	_assert(b_conv_s.mouse_filter == Control.MOUSE_FILTER_IGNORE, "BlockNode mouse_filter is IGNORE so ports don't block clicks")
	_assert(not b_conv_s.should_show_port_socket("flow_in"), "Port sockets are hidden in geometry mode")
	var b_other: BlockNode = canvas._block_nodes["conv_l"]
	_assert(not b_other.should_show_port_socket("flow_in") and b_other.hit_test_port(Vector2.ZERO).is_empty(), "Other element ports are hidden and not hit-testable")
	canvas.rebuild_blocks()
	b_conv_s = canvas._block_nodes["conv_s"]
	b_other = canvas._block_nodes["conv_l"]
	_assert(not b_other.should_show_port_socket("flow_in"), "Canvas rebuild retains port suppression")
	_assert(not canvas._hit_test_conveyor_gizmo(canvas.pan_offset + canvas._conveyor_pivot(conv_s) * 20.0 + Vector2(0, -48)).is_empty(), "Rotation handle is hit-testable in geometry mode")
	var rotation_before := ConveyorCurve3D.sample_world_curve(conv_s, store, 64)
	var pivot := canvas._conveyor_pivot(conv_s)
	canvas._rotate_conveyor_element("conv_s", 90.0, pivot)
	var rotation_after := ConveyorCurve3D.sample_world_curve(conv_s, store, 64)
	var old_start: Vector3 = rotation_before["inlet_pos"]
	var new_start: Vector3 = rotation_after["inlet_pos"]
	var expected_start := pivot + (Vector2(old_start.x, old_start.y) - pivot).rotated(PI * 0.5)
	_assert(Vector2(new_start.x, new_start.y).distance_to(expected_start) < 0.01, "Whole rotation moves curve inlet about pivot")
	_assert(absf(float(rotation_before["total_length"]) - float(rotation_after["total_length"])) < 0.01, "Whole rotation preserves arc length")

	# Exit geometry mode
	canvas.exit_conveyor_geometry_mode()
	_assert(not canvas.is_in_conveyor_geometry_mode(), "Successfully exited Conveyor Geometry Mode")
	_assert(not b_conv_s.is_geometry_mode_active, "BlockNode is_geometry_mode_active restored to false")
	_assert(b_conv_s.mouse_filter == Control.MOUSE_FILTER_STOP, "BlockNode mouse_filter restored to STOP")

	# ─────────────────────────────────────────────────────────────────────────
	# Test 7: Switching Straight -> Curved -> Straight Roundtrip
	# ─────────────────────────────────────────────────────────────────────────
	print("\n[7] Testing Straight -> Curved -> Straight Roundtrip...")
	var conv_rt := cat.create_element_instance("conveyor", "conv_rt", Vector2(50.0, 50.0))
	conv_rt.geometry["dimensions"] = [10.0, 1.2, 0.8]
	store.add_element(conv_rt)
	canvas.rebuild_blocks()

	var b_rt: BlockNode = canvas._block_nodes["conv_rt"]
	_assert(not b_rt._is_curved_or_joined_conveyor(), "Initial conveyor is straight")

	# Switch to s_curve
	insp.set_conveyor_shape_preset("conv_rt", "s_curve")
	_assert(b_rt._is_curved_or_joined_conveyor(), "Switched to s_curve: curved mode active")

	# Switch back to straight
	insp.set_conveyor_shape_preset("conv_rt", "straight")
	_assert(not b_rt._is_curved_or_joined_conveyor(), "Switched back to straight: straight mode cleanly restored")
	_assert(not conv_rt.geometry.has("corner_pos"), "corner_pos erased on straight conveyor")
	_assert(not conv_rt.geometry.has("inlet_pose"), "inlet_pose erased on straight conveyor")
	_assert(not conv_rt.geometry.has("outlet_pose"), "outlet_pose erased on straight conveyor")
	# ─────────────────────────────────────────────────────────────────────────
	# Test 8: Straight Conveyor Geometry Mode & Dragging (Width, Length, Infeed)
	# ─────────────────────────────────────────────────────────────────────────
	print("\n[8] Testing Straight Conveyor Geometry Mode Dragging...")
	var conv_st := cat.create_element_instance("conveyor", "conv_st", Vector2(100.0, 100.0))
	conv_st.geometry["dimensions"] = [8.0, 1.2, 0.8]
	conv_st.transform.position = Vector3(5.0, 5.0, 0.8)
	conv_st.editor.graph_position = Vector2(100.0, 100.0)
	store.add_element(conv_st)
	canvas.rebuild_blocks()
	store.select("conv_st", "element")

	# Enter geometry mode on straight conveyor
	canvas.enter_conveyor_geometry_mode("conv_st")
	_assert(canvas.is_in_conveyor_geometry_mode(), "Entered geometry mode on straight conveyor")
	var b_st: BlockNode = canvas._block_nodes["conv_st"]
	_assert(b_st.is_geometry_mode_active, "Straight BlockNode is_geometry_mode_active is true")

	# Test straight conveyor width rail hit test
	var sm := canvas._get_straight_conveyor_metrics(conv_st)
	var rail_top_px := canvas.pan_offset + (sm["rail_top_m"] as Vector2) * (20.0 * canvas.zoom_level)
	var hit_w := canvas._hit_test_conveyor_gizmo(rail_top_px)
	_assert(not hit_w.is_empty() and str(hit_w.get("type", "")) == "width_rail", "Straight conveyor width rail handle hit-tested")
	_assert(hit_w.has("index"), "Straight conveyor width rail handle has safe 'index' key")

	# Simulate dragging width rail handle on straight conveyor
	var mb_w := InputEventMouseButton.new()
	mb_w.button_index = MOUSE_BUTTON_LEFT
	mb_w.pressed = true
	mb_w.position = rail_top_px
	canvas._gui_input(mb_w)
	_assert(canvas._conveyor_active_gizmo_type == "width_rail", "Active gizmo type set to width_rail without crash")

	# Drag to increase width to 2.4m
	var mm_w := InputEventMouseMotion.new()
	var new_w_world := (sm["p_mid_m"] as Vector2) + (sm["norm"] as Vector2) * 1.2
	mm_w.position = canvas.pan_offset + new_w_world * (20.0 * canvas.zoom_level)
	canvas._gui_input(mm_w)
	var st_w: float = float(conv_st.geometry["dimensions"][1])
	_assert(absf(st_w - 2.4) < 0.1, "Straight conveyor width successfully dragged to 2.4m (w=%.2fm)" % st_w)
	_assert(absf(b_st.size.y - (st_w * 20.0)) < 0.1, "Straight conveyor BlockNode size.y updated in sync")

	# Release width drag
	var mb_w_up := InputEventMouseButton.new()
	mb_w_up.button_index = MOUSE_BUTTON_LEFT
	mb_w_up.pressed = false
	canvas._gui_input(mb_w_up)

	# Test dragging outlet handle to change length
	var p_out_px := canvas.pan_offset + (sm["p_out_m"] as Vector2) * (20.0 * canvas.zoom_level)
	var hit_out := canvas._hit_test_conveyor_gizmo(p_out_px)
	_assert(not hit_out.is_empty() and str(hit_out.get("type", "")) == "outlet", "Straight conveyor outlet handle hit-tested")

	var mb_out := InputEventMouseButton.new()
	mb_out.button_index = MOUSE_BUTTON_LEFT
	mb_out.pressed = true
	mb_out.position = p_out_px
	canvas._gui_input(mb_out)

	# Drag outlet to extend length from 8m to 14m
	var mm_out := InputEventMouseMotion.new()
	var new_out_world := (sm["p_in_m"] as Vector2) + (sm["dir"] as Vector2) * 14.0
	mm_out.position = canvas.pan_offset + new_out_world * (20.0 * canvas.zoom_level)
	canvas._gui_input(mm_out)
	var st_len: float = float(conv_st.geometry["dimensions"][0])
	_assert(absf(st_len - 14.0) < 0.1, "Straight conveyor length successfully dragged to 14.0m (L=%.2fm)" % st_len)
	_assert(absf(b_st.size.x - (st_len * 20.0)) < 0.1, "Straight conveyor BlockNode size.x updated in sync")
	var cancel_key := InputEventKey.new()
	cancel_key.keycode = KEY_ESCAPE
	cancel_key.pressed = true
	canvas._handle_key_input(cancel_key)
	_assert(canvas.is_in_conveyor_geometry_mode(), "Escape cancels an active drag before leaving geometry mode")
	_assert(absf(float(store.get_element("conv_st").geometry["dimensions"][0]) - 8.0) < 0.1, "Escape restores conveyor length before the drag")
	b_st = canvas._block_nodes["conv_st"]
	var restored_straight := store.get_element("conv_st")
	for pivot_mode in ["inlet", "outlet"]:
		canvas.conveyor_rotation_pivot_mode = pivot_mode
		var fixed_before := canvas._conveyor_pivot(restored_straight)
		canvas._rotate_conveyor_element("conv_st", 90.0, fixed_before)
		var fixed_after := canvas._conveyor_pivot(restored_straight)
		_assert(fixed_before.distance_to(fixed_after) < 0.01, "Rotation about %s preserves its endpoint" % pivot_mode)
		canvas._rotate_conveyor_element("conv_st", -90.0, fixed_before)
	canvas.conveyor_rotation_pivot_mode = "center"

	# Exit geometry mode before testing block node middle-click
	canvas.exit_conveyor_geometry_mode()
	var middle_clicked := []
	b_st.conveyor_geometry_mode_toggled.connect(func(eid: String): middle_clicked.append(eid))
	var mb_mid := InputEventMouseButton.new()
	mb_mid.button_index = MOUSE_BUTTON_MIDDLE
	mb_mid.pressed = true
	b_st._gui_input(mb_mid)
	_assert(middle_clicked.size() > 0 and middle_clicked[0] == "conv_st", "BlockNode emits conveyor_geometry_mode_toggled on middle-click")

	# Test Inspector button signal propagation
	var insp_geom := []
	insp.conveyor_geometry_mode_requested.connect(func(eid: String): insp_geom.append(eid))
	insp.conveyor_geometry_mode_requested.emit("conv_st")
	_assert(insp_geom.size() > 0 and insp_geom[0] == "conv_st", "Inspector conveyor_geometry_mode_requested signal fires properly")
	var history_elem := cat.create_element_instance("conveyor", "conv_history", Vector2(140, 140))
	history_elem.geometry["shape_preset"] = "spiral_helix"
	history_elem.geometry["shape_params"] = {"helix_radius": 2.5, "helix_turns": 1.5, "elevation_gain": 3.0}
	store.add_element(history_elem)
	ConveyorCurve3D.update_shape_parameter(history_elem, "helix_radius", 4.0, store)
	_assert(absf(float(history_elem.geometry["shape_params"]["helix_radius"]) - 4.0) < 0.01, "Inspector shape edit stores its new value")
	store.undo()
	_assert(absf(float(store.get_element("conv_history").geometry["shape_params"]["helix_radius"]) - 2.5) < 0.01, "Undo restores the previous inspector shape value")
	var before_invalid := store.get_element("conv_history")
	store._record_undo()
	before_invalid.geometry["shape_preset"] = "custom_spline"
	before_invalid.geometry["shape_params"]["control_points"] = [{"pos": [2.0, 2.0, 0.0]}, {"pos": [2.0, 2.0, 0.0]}]
	_assert(not canvas._finish_conveyor_geometry_edit("conv_history"), "Invalid zero-length geometry is rejected on commit")
	_assert(str(store.get_element("conv_history").geometry["shape_preset"]) == "spiral_helix", "Invalid geometry rollback restores the previous preset")

	canvas.free()
	insp.free()

	print("\n============================================================")
	print("  Summary: %d passed, %d failed" % [_passed, _failed])
	print("============================================================")
	quit(1 if _failed > 0 else 0)
