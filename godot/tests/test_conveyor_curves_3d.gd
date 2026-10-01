# tests/test_conveyor_curves_3d.gd
# Phase 7F: Headless verification of SimVizConveyorCurve3D, curved 3D mesh extrusion,
# 2D joined conveyor track rendering, and Inspector Shape Preset dropdown.
extends SceneTree

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const Catalog := preload("res://scripts/authoring_catalog.gd")
const ConveyorCurve3D := preload("res://scripts/conveyor_curve_3d.gd")
const MeshFactory := preload("res://scripts/authoring_mesh_factory.gd")
const Inspector := preload("res://scripts/authoring_inspector.gd")
const Canvas2D := preload("res://scripts/authoring_2d_canvas.gd")
const Viewport3D := preload("res://scripts/authoring_3d_viewport.gd")

var _passed := 0
var _failed := 0

func _assert(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("  ✓ PASS: ", msg)
	else:
		_failed += 1
		printerr("  ✗ FAIL: ", msg)

func _init() -> void:
	print("============================================================")
	print("  Phase 7F: Conveyor Curve 3D/2D & Inspector Preset Tests")
	print("============================================================")

	var cat := Catalog.new()
	var store := DocumentStore.new()

	# 1. Verify all 8 presets in SimVizConveyorCurve3D & MeshFactory
	print("\n[1] Testing all 8 Conveyor Shape Presets in 3D & 2D...")
	var conv := cat.create_element_instance("conveyor", "conv_test", Vector2(10.0, 10.0))
	conv.geometry["dimensions"] = [10.0, 1.4, 0.8]
	conv.geometry["elevation_start"] = 0.8
	conv.geometry["elevation_end"] = 2.4
	store.add_element(conv)

	for preset_id in ConveyorCurve3D.PRESET_IDS:
		conv.geometry["shape_preset"] = preset_id
		if preset_id == "custom_spline":
			conv.geometry["control_points"] = [
				{"pos": [10.0, 10.0, 0.0], "in_handle": [0.0, 0.0, 0.0], "out_handle": [3.0, 2.0, 0.0]},
				{"pos": [16.0, 14.0, 0.5], "in_handle": [-2.0, 0.0, 0.0], "out_handle": [2.0, 0.0, 0.0]},
				{"pos": [22.0, 10.0, 1.0], "in_handle": [-3.0, -2.0, 0.0], "out_handle": [0.0, 0.0, 0.0]}
			]
		var c3d: Curve3D = ConveyorCurve3D.build_curve3d_for_element(conv, store)
		_assert(c3d != null and c3d.point_count >= 2, "Preset '%s' produces valid Curve3D (points=%d)" % [preset_id, c3d.point_count if c3d != null else 0])

		var w_data: Dictionary = ConveyorCurve3D.sample_world_curve(conv, store, 32)
		var pts3: PackedVector3Array = w_data["points"]
		var tans3: PackedVector3Array = w_data["tangents"]
		var total_len: float = float(w_data["total_length"])
		_assert(pts3.size() == 33 and tans3.size() == 33 and total_len > 1.0, "Preset '%s' world curve sampled (L=%.2fm)" % [preset_id, total_len])

		var poly2d: PackedVector2Array = ConveyorCurve3D.sample_2d_polyline(conv, store, 24)
		_assert(poly2d.size() == 25, "Preset '%s' 2D polyline has 25 vertices" % preset_id)

		var node3d: Node3D = MeshFactory.create_3d_node_for_element(conv, store)
		var bed_pivot: Node3D = node3d.get_node_or_null("BedPivot")
		var belt_assembly: Node3D = bed_pivot.get_node_or_null("BeltAssembly") if bed_pivot != null else null
		var belt_mesh: MeshInstance3D = belt_assembly.get_node_or_null("BeltMesh") if belt_assembly != null else null
		_assert(belt_mesh != null and belt_mesh.mesh != null and belt_mesh.mesh.get_surface_count() == 1, "Preset '%s' extrudes non-empty 3D ArrayMesh belt" % preset_id)
		node3d.free()
	var profile_conv := cat.create_element_instance("conveyor", "profile_conv", Vector2(60, 60))
	profile_conv.geometry["shape_preset"] = "s_curve"
	profile_conv.geometry["dimensions"] = [10.0, 1.2, 0.8]
	profile_conv.geometry["width_profile"] = [{"fraction": 0.0, "scale": 1.0}, {"fraction": 0.5, "scale": 2.0}, {"fraction": 1.0, "scale": 1.0}]
	store.add_element(profile_conv)
	var profile_root := MeshFactory.create_3d_node_for_element(profile_conv, store)
	var profile_mesh: MeshInstance3D = profile_root.get_node("BedPivot/BeltAssembly/BeltMesh")
	var profile_vertices: PackedVector3Array = profile_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var profile_samples: int = (ConveyorCurve3D.sample_world_curve(profile_conv, store, 0)["points"] as PackedVector3Array).size()
	var mid_top: int = (profile_samples / 2) * 24 + 6
	_assert(absf(profile_vertices[0].distance_to(profile_vertices[1]) - 1.2 * 0.88) < 0.02, "3D belt inlet uses base cross-section width")
	_assert(absf(profile_vertices[mid_top].distance_to(profile_vertices[mid_top + 1]) - 2.4 * 0.88) < 0.04, "3D belt midpoint uses local width key")
	profile_root.free()

	var serp_params := {"passes": 3, "pass_spacing": 2.0, "pass_length": 8.0}
	var serp_controls := ConveyorCurve3D.generate_control_points("serpentine", Vector3.ZERO, Vector3.RIGHT, Vector3(8, 4, 0), Vector3.RIGHT, serp_params)
	var first_arc_middle: Vector3 = ConveyorCurve3D.eval_cubic_bezier(serp_controls[1]["pos"], serp_controls[1]["pos"] + serp_controls[1]["out_handle"], serp_controls[2]["pos"] + serp_controls[2]["in_handle"], serp_controls[2]["pos"], 0.5)["pos"]
	_assert(first_arc_middle.distance_to(Vector3(8.707107, 0.292893, 0.0)) < 0.01, "Serpentine turnaround follows a circular quarter arc")
	_assert(serp_controls.size() == 8, "Three serpentine runs produce two smooth hairpin bends")
	var smooth_serp := cat.create_element_instance("conveyor", "smooth_serp", Vector2.ZERO)
	smooth_serp.geometry["shape_preset"] = "serpentine"
	smooth_serp.geometry["shape_params"] = serp_params
	var rendered_points: PackedVector3Array = ConveyorCurve3D.sample_world_curve(smooth_serp, null, 0)["points"]
	var runtime_points: PackedVector3Array = ConveyorCurve3D.sample_world_curve(smooth_serp, null, 36)["points"]
	_assert(rendered_points.size() >= 160 and runtime_points.size() == 37, "Render sampling resolves each bend without enlarging runtime curve tables")
	var wider_serp := ConveyorCurve3D.generate_control_points("serpentine", Vector3.ZERO, Vector3.RIGHT, Vector3(8, 4, 0), Vector3.RIGHT, {"passes": 3, "pass_spacing": 3.0, "pass_length": 8.0})
	_assert(wider_serp.size() == serp_controls.size() and (wider_serp[-1]["pos"] as Vector3).distance_to(Vector3(8, 6, 0)) < 0.01, "Lane spacing changes footprint without adding bends")
	var legacy_serp := ConveyorCurve3D.generate_control_points("serpentine", Vector3.ZERO, Vector3.RIGHT, Vector3(8, 4, 0), Vector3.RIGHT, {"passes": 3, "pitch": 2.4, "pass_length": 8.0})
	_assert((legacy_serp[-1]["pos"] as Vector3).distance_to(Vector3(8, 4.8, 0)) < 0.01, "Legacy serpentine pitch is preserved as lane spacing")
	var long_serp := ConveyorCurve3D.generate_control_points("serpentine", Vector3.ZERO, Vector3.RIGHT, Vector3(8, 4, 0), Vector3.RIGHT, {"passes": 3, "pass_spacing": 2.0, "pass_length": 12.0})
	_assert((long_serp[-1]["pos"] as Vector3).distance_to(Vector3(12, 4, 0)) < 0.01, "Run length extends the serpentine without changing bend count")
	var many_serp := ConveyorCurve3D.generate_control_points("serpentine", Vector3.ZERO, Vector3.RIGHT, Vector3(8, 4, 0), Vector3.RIGHT, {"passes": 12, "pass_spacing": 2.0, "pass_length": 8.0})
	_assert(many_serp.size() == 35, "Eleven serpentine bends preserve the same hairpin shape")
	var elbow_controls := ConveyorCurve3D.generate_control_points("l_bend", Vector3.ZERO, Vector3.RIGHT, Vector3(8, 4, 0), Vector3.RIGHT, {"leg1_length": 8.0, "leg2_length": 4.0, "bend_angle_deg": 135.0, "bend_radius": 2.0, "turn_direction": "left"})
	var trim: float = minf(2.0 * tan(deg_to_rad(67.5)), 3.6)
	var effective_radius: float = trim / tan(deg_to_rad(67.5))
	var arc_center := Vector3(8.0 - trim, effective_radius, 0.0)
	var elbow_round := elbow_controls.size() == 5
	for section in [1, 2]:
		for fraction in [0.25, 0.5, 0.75]:
			var start: Dictionary = elbow_controls[section]
			var finish: Dictionary = elbow_controls[section + 1]
			var on_arc: Vector3 = ConveyorCurve3D.eval_cubic_bezier(start["pos"], start["pos"] + start["out_handle"], finish["pos"] + finish["in_handle"], finish["pos"], fraction)["pos"]
			elbow_round = elbow_round and absf(on_arc.distance_to(arc_center) - effective_radius) < 0.01
	_assert(elbow_round, "135-degree L-bend fillet is composed of near-circular quarter arcs")

	var parity_cases: Array = JSON.parse_string(FileAccess.get_file_as_string("res://tests/conveyor_geometry_parity.json"))
	for case in parity_cases:
		var inlet: Array = case["inlet"]
		var outlet: Array = case["outlet"]
		var in_tan: Array = case["inlet_tangent"]
		var out_tan: Array = case["outlet_tangent"]
		var controls := ConveyorCurve3D.generate_control_points(case["preset"], Vector3(inlet[0], inlet[1], inlet[2]), Vector3(in_tan[0], in_tan[1], in_tan[2]), Vector3(outlet[0], outlet[1], outlet[2]), Vector3(out_tan[0], out_tan[1], out_tan[2]), case["params"])
		var baked := ConveyorCurve3D.bake_control_points(case["preset"], controls, 64)
		var mid: Array = case["midpoint"]
		var end: Array = case["end"]
		_assert((baked["points"][32] as Vector3).distance_to(Vector3(mid[0], mid[1], mid[2])) < 0.1, "Godot %s matches shared 3D midpoint" % case["preset"])
		_assert((baked["outlet_pos"] as Vector3).distance_to(Vector3(end[0], end[1], end[2])) < 0.01, "Godot %s matches shared 3D outlet" % case["preset"])
		if case.has("end_tangent"):
			var tangent: Array = case["end_tangent"]
			_assert((baked["outlet_tan"] as Vector3).dot(Vector3(tangent[0], tangent[1], tangent[2])) > 0.995, "Godot %s matches anchored outlet heading" % case["preset"])
	var previous_right := Vector3.ZERO
	var sweep_stable := true
	for heading in [Vector3.RIGHT, Vector3(0.1, 0.995, 0).normalized(), Vector3.UP, Vector3(-0.1, 0.995, 0).normalized(), Vector3.LEFT]:
		var right := MeshFactory._transport_sweep_right(previous_right, heading)
		sweep_stable = sweep_stable and absf(right.dot(heading)) < 0.001 and (previous_right == Vector3.ZERO or right.dot(previous_right) > 0.9)
		previous_right = right
	_assert(sweep_stable, "3D sweep rails remain perpendicular and do not flip through a vertical bend")
	var invalid_geom := {"geometry": {"shape_preset": "custom_spline", "shape_params": {"control_points": [{"pos": [0.0, 0.0, 0.0]}, {"pos": [0.0, 0.0, 0.0]}]}}}
	_assert(not str(ConveyorCurve3D.geometry_diagnostics(invalid_geom)["error"]).is_empty(), "Coincident bend stations produce a geometry error")
	var steep_geom := {"geometry": {"shape_preset": "custom_spline", "shape_params": {"control_points": [{"pos": [0.0, 0.0, 0.0]}, {"pos": [5.0, 0.0, 5.0]}]}}}
	_assert(str(ConveyorCurve3D.geometry_diagnostics(steep_geom)["warning"]).contains("grade"), "Steep conveyor routes expose a grade warning")

	# 2. Verify C0 and C1 continuity across a 4-conveyor closed loop
	print("\n[2] Testing 4-Conveyor Closed-Loop C0/C1 Junction Continuity...")
	var loop_store := DocumentStore.new()
	var hubs := [
		{"id": "Conveyor_North", "in_p": [20.5, 24.0, 0.0], "in_t": [1.0, 0.0, 0.0],  "out_p": [34.0, 21.5, 0.0], "out_t": [0.0, -1.0, 0.0], "corner": [34.0, 24.0, 0.0]},
		{"id": "Conveyor_East",  "in_p": [34.0, 21.5, 0.0], "in_t": [0.0, -1.0, 0.0], "out_p": [31.5, 8.0, 0.0],  "out_t": [-1.0, 0.0, 0.0], "corner": [34.0, 8.0, 0.0]},
		{"id": "Conveyor_South", "in_p": [31.5, 8.0, 0.0],  "in_t": [-1.0, 0.0, 0.0], "out_p": [18.0, 10.5, 0.0], "out_t": [0.0, 1.0, 0.0],  "corner": [18.0, 8.0, 0.0]},
		{"id": "Conveyor_West",  "in_p": [18.0, 10.5, 0.0], "in_t": [0.0, 1.0, 0.0],  "out_p": [20.5, 24.0, 0.0], "out_t": [1.0, 0.0, 0.0],  "corner": [18.0, 24.0, 0.0]}
	]
	var loop_elems: Array = []
	for h in hubs:
		var ce := cat.create_element_instance("conveyor", h["id"], Vector2(h["in_p"][0], h["in_p"][1]))
		ce.geometry["shape_preset"] = "l_bend"
		ce.geometry["inlet_pose"] = {"pos": h["in_p"], "tangent": h["in_t"], "up": [0.0, 0.0, 1.0]}
		ce.geometry["outlet_pose"] = {"pos": h["out_p"], "tangent": h["out_t"], "up": [0.0, 0.0, 1.0]}
		ce.geometry["shape_params"] = {"bend_radius": 2.5, "corner_pos": h["corner"]}
		loop_store.add_element(ce)
		loop_elems.append(ce)

	for i in range(4):
		var u_elem = loop_elems[i]
		var v_elem = loop_elems[(i + 1) % 4]
		var u_curve := ConveyorCurve3D.sample_world_curve(u_elem, loop_store, 40)
		var v_curve := ConveyorCurve3D.sample_world_curve(v_elem, loop_store, 40)
		var u_pts: PackedVector3Array = u_curve["points"]
		var v_pts: PackedVector3Array = v_curve["points"]
		var u_tans: PackedVector3Array = u_curve["tangents"]
		var v_tans: PackedVector3Array = v_curve["tangents"]

		var pos_err: float = u_pts[u_pts.size() - 1].distance_to(v_pts[0])
		var tan_dot: float = u_tans[u_tans.size() - 1].dot(v_tans[0])
		_assert(pos_err < 1e-3, "Junction %s -> %s C0 position continuity (err=%.6fm)" % [u_elem.id, v_elem.id, pos_err])
		_assert(tan_dot > 0.995, "Junction %s -> %s C1 tangent alignment (dot=%.5f)" % [u_elem.id, v_elem.id, tan_dot])

	# 3. Verify Inspector preset switching & 2D/3D synchronization
	print("\n[3] Testing Inspector Preset Switching & 2D/3D Synchronization...")
	var insp := Inspector.new(store, cat)
	var canvas2d := Canvas2D.new(store)
	var vp3d := Viewport3D.new(store)
	canvas2d._ready()
	vp3d._ready()

	store.select("conv_test", "element")
	insp.refresh()

	for target_preset in ["l_bend", "u_turn", "serpentine", "spiral_helix", "s_curve", "straight"]:
		insp.set_conveyor_shape_preset("conv_test", target_preset)
		_assert(str(conv.geometry.get("shape_preset", "")) == target_preset, "Inspector updated shape_preset to '%s'" % target_preset)
		var b_node = canvas2d._block_nodes.get("conv_test", null)
		_assert(b_node != null, "2D Canvas block node exists for '%s'" % target_preset)

	conv.geometry["shape_preset"] = "spiral_helix"
	conv.geometry["shape_params"] = {"helix_radius": 2.5, "helix_turns": 1.5, "elevation_gain": 2.4}
	vp3d.geometry_mode_elem_id = "conv_test"
	vp3d.size = Vector2(800, 600)
	for param in [{"type": "radius", "key": "helix_radius", "motion": Vector2(80, 0)}, {"type": "rise", "key": "elevation_gain", "motion": Vector2(0, -80)}, {"type": "turns", "key": "helix_turns", "motion": Vector2(80, 0)}]:
		var old_value: float = float(conv.geometry["shape_params"][param["key"]])
		vp3d._geometry_drag = {"type": param["type"], "index": -1, "start_screen": Vector2.ZERO, "start_value": old_value}
		vp3d._drag_geometry_handle(param["motion"])
		_assert(float(conv.geometry["shape_params"][param["key"]]) > old_value, "3D %s drag updates %s" % [param["type"], param["key"]])
	vp3d._geometry_drag.clear()
	ConveyorCurve3D.convert_element_to_custom_spline(conv, store)
	var station: Dictionary = conv.geometry["shape_params"]["control_points"][1]
	var old_z: float = float(station["pos"][2])
	vp3d._geometry_drag = {"type": "station", "index": 1, "start_screen": Vector2.ZERO, "start_value": old_z}
	vp3d._drag_geometry_handle(Vector2(0, -80))
	_assert(float(station["pos"][2]) > old_z, "3D station drag raises its elevation")
	vp3d._geometry_drag.clear()
	var connected := SceneTypes.SceneConnection.new()
	connected.id = "locked_3d_outlet"
	connected.source_element = "conv_test"
	connected.target_element = "downstream"
	connected.link_type = "flow"
	store.add_connection(connected)
	_assert(bool(ConveyorCurve3D.connected_endpoint_locks("conv_test", store)["outlet"]), "3D test outlet is connected")
	var last_index: int = (conv.geometry["shape_params"]["control_points"] as Array).size() - 1
	var last_z: float = float(conv.geometry["shape_params"]["control_points"][last_index]["pos"][2])
	vp3d._geometry_drag = {"type": "station", "index": last_index, "start_screen": Vector2.ZERO, "start_value": last_z}
	vp3d._drag_geometry_handle(Vector2(0, -80))
	_assert(absf(float(conv.geometry["shape_params"]["control_points"][last_index]["pos"][2]) - last_z) < 0.01, "3D handle restores a connected outlet height")
	_assert(not vp3d._geometry_warning.is_empty(), "3D handle explains connected outlet rejection")
	store.remove_connection(connected.id)
	conv = store.get_element("conv_test")
	var saved_radius: float = float(conv.geometry["shape_params"].get("helix_radius", 2.5))
	store._record_undo()
	vp3d._geometry_drag = {"type": "station", "index": 1, "start_screen": Vector2.ZERO, "start_value": float(conv.geometry["shape_params"]["control_points"][1]["pos"][2])}
	var saved_station_z: float = float(conv.geometry["shape_params"]["control_points"][1]["pos"][2])
	vp3d._drag_geometry_handle(Vector2(0, -80))
	var cancel_event := InputEventKey.new()
	cancel_event.keycode = KEY_ESCAPE
	cancel_event.pressed = true
	vp3d._gui_input(cancel_event)
	_assert(vp3d._geometry_drag.is_empty() and vp3d.geometry_mode_elem_id == "conv_test", "3D Escape cancels the active drag without leaving Geometry view")
	_assert(absf(float(store.get_element("conv_test").geometry["shape_params"]["control_points"][1]["pos"][2]) - saved_station_z) < 0.01, "3D Escape restores the station height")
	_assert(absf(float(store.get_element("conv_test").geometry["shape_params"].get("helix_radius", 2.5)) - saved_radius) < 0.01, "3D Escape preserves other shape parameters")
	root.add_child(vp3d)
	vp3d.size = Vector2(800, 600)
	call_deferred("_finish_projection_test", vp3d, canvas2d, insp)

func _finish_projection_test(vp3d: Viewport3D, canvas2d: Canvas2D, insp: Inspector) -> void:
	vp3d.rebuild_3d_scene()
	var projected_handles: Array = vp3d._geometry_handles()
	_assert(projected_handles.size() > 0, "3D Geometry view projects freeform handles in the scene tree")
	if not projected_handles.is_empty():
		var picked: Dictionary = vp3d._hit_geometry_handle(projected_handles[1]["screen"])
		_assert(not picked.is_empty() and picked["type"] == "station", "3D station handle is hit-testable at its drawn location")
		_assert(vp3d._pick_conveyor_curve(projected_handles[1]["screen"]) == "conv_test", "3D belt picking follows the projected curve")
		var mode_requests: Array = []
		vp3d.conveyor_geometry_mode_requested.connect(func(elem_id: String): mode_requests.append(elem_id))
		var middle_press := InputEventMouseButton.new()
		middle_press.button_index = MOUSE_BUTTON_MIDDLE
		middle_press.pressed = true
		middle_press.position = projected_handles[1]["screen"]
		vp3d._gui_input(middle_press)
		_assert(mode_requests == ["conv_test"] and not vp3d._is_panning, "3D middle-click requests Geometry view rather than panning on a belt")

	vp3d.free()
	canvas2d.free()
	insp.free()

	print("\n============================================================")
	print("  Summary: %d passed, %d failed" % [_passed, _failed])
	print("============================================================")
	quit(1 if _failed > 0 else 0)

