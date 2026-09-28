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

	vp3d.free()
	canvas2d.free()
	insp.free()

	print("\n============================================================")
	print("  Summary: %d passed, %d failed" % [_passed, _failed])
	print("============================================================")
	quit(1 if _failed > 0 else 0)

