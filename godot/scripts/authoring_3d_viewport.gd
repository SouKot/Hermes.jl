# authoring_3d_viewport.gd
# Synchronized 3D Layout Viewport with procedural PBR equipment, concrete floor, lighting, and orbit camera.
class_name SimVizAuthoring3DViewport
extends SubViewportContainer

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const MeshFactory := preload("res://scripts/authoring_mesh_factory.gd")
const ConveyorCurve3D := preload("res://scripts/conveyor_curve_3d.gd")

signal floating_properties_requested(elem_id: String, screen_pos: Vector2)
signal conveyor_geometry_mode_requested(elem_id: String)

var doc_store: DocumentStore
var geometry_mode_elem_id: String = "":
	set(value):
		geometry_mode_elem_id = value
		_geometry_drag.clear()
		_geometry_warning = ""
		if _geometry_overlay != null:
			_geometry_overlay.queue_redraw()
var _geometry_overlay: Control
var _geometry_drag: Dictionary = {}
var _geometry_warning: String = ""

var _sub_viewport: SubViewport
var _world_root: Node3D
var _camera: Camera3D
var _cam_pivot: Node3D
var _entities_root: Node3D
var _floor_mesh: MeshInstance3D
var _agents_root: Node3D
var _agents_multimesh_instance: MultiMeshInstance3D
var _agents_multimesh: MultiMesh
var _active_agents: Array = []
var selected_agent_id: String = ""
var is_follow_camera_active: bool = false

# Orbit Camera parameters
var _cam_distance: float = 30.0
var _cam_pitch: float = 0.65   # Radians elevation above floor (~37 degrees)
var _cam_yaw: float = 0.55     # Radians horizontal azimuth
var _is_orbiting: bool = false
var _is_panning: bool = false
var _last_mouse_pos: Vector2 = Vector2.ZERO
var _selection_indicator: Node3D = null

func _init(p_store: DocumentStore = null) -> void:
	doc_store = p_store
	stretch = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	_ensure_setup()
	if doc_store != null:
		doc_store.document_loaded.connect(_on_document_reloaded)
		doc_store.document_modified.connect(_on_document_modified)
		doc_store.selection_changed.connect(_on_selection_changed)

func _ready() -> void:
	_ensure_setup()
	rebuild_3d_scene()
	frame_scene()

func _ensure_setup() -> void:
	if _world_root != null:
		return
	_setup_3d_world()
	_setup_ui_overlay()

func _setup_3d_world() -> void:
	_sub_viewport = SubViewport.new()
	_sub_viewport.own_world_3d = true
	_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sub_viewport)

	_world_root = Node3D.new()
	_sub_viewport.add_child(_world_root)

	# 1. Lighting & Environment
	var env := WorldEnvironment.new()
	var env_res := Environment.new()
	env_res.background_mode = Environment.BG_COLOR
	env_res.background_color = Color("#0c131d")
	env_res.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env_res.ambient_light_color = Color("#55697d")
	env_res.ambient_light_energy = 1.3
	env.environment = env_res
	_world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.785, 0.61, 0)
	sun.light_color = Color("#ffffff")
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	_world_root.add_child(sun)

	# 2a. Polished Concrete Floor Slab
	var floor_m := PlaneMesh.new()
	floor_m.size = Vector2(160, 160)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color("#1e293b")
	floor_mat.metallic = 0.25
	floor_mat.roughness = 0.35
	floor_m.material = floor_mat

	_floor_mesh = MeshInstance3D.new()
	_floor_mesh.mesh = floor_m
	_floor_mesh.position = Vector3(0, 0, 0)
	_world_root.add_child(_floor_mesh)

	# 2b. CAD Floor Alignment Grid (5m spacing with subtle unshaded lines)
	var grid_mat := StandardMaterial3D.new()
	grid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid_mat.albedo_color = Color(0.24, 0.34, 0.46, 0.7)

	var verts := PackedVector3Array()
	for i in range(-80, 81, 5):
		verts.append(Vector3(float(i), 0.01, -80.0))
		verts.append(Vector3(float(i), 0.01, 80.0))
		verts.append(Vector3(-80.0, 0.01, float(i)))
		verts.append(Vector3(80.0, 0.01, float(i)))

	var arr_mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	arr_mesh.surface_set_material(0, grid_mat)

	var grid_inst := MeshInstance3D.new()
	grid_inst.mesh = arr_mesh
	_world_root.add_child(grid_inst)

	# 3. Orbit Camera Rig
	_cam_pivot = Node3D.new()
	_cam_pivot.position = Vector3(15.0, 0.8, -10.0)
	_world_root.add_child(_cam_pivot)

	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 48.0
	_world_root.add_child(_camera)
	_update_camera_transform()

	# 4. Equipment Container
	_entities_root = Node3D.new()
	_entities_root.name = "EntitiesRoot"
	_world_root.add_child(_entities_root)

	var bridges_root := Node3D.new()
	bridges_root.name = "BridgesRoot"
	_world_root.add_child(bridges_root)

	# 5. Agent MultiMesh Container (Hardware-accelerated crowd rendering)
	_agents_multimesh_instance = MultiMeshInstance3D.new()
	_agents_multimesh_instance.name = "AgentsMultiMesh"
	var agent_mat := StandardMaterial3D.new()
	agent_mat.vertex_color_use_as_albedo = true
	agent_mat.roughness = 0.35
	_agents_multimesh_instance.material_override = agent_mat
	_agents_multimesh = MultiMesh.new()
	_agents_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_agents_multimesh.use_colors = true
	_agents_multimesh.mesh = MeshFactory.create_agent_capsule_mesh()
	_agents_multimesh_instance.multimesh = _agents_multimesh
	_world_root.add_child(_agents_multimesh_instance)

	_agents_root = Node3D.new()
	_agents_root.name = "AgentsRoot"
	_world_root.add_child(_agents_root)

func _setup_ui_overlay() -> void:
	_geometry_overlay = Control.new()
	_geometry_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_geometry_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_geometry_overlay.draw.connect(_draw_geometry_handles)
	add_child(_geometry_overlay)
	var overlay := MarginContainer.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_theme_constant_override("margin_top", 10)
	overlay.add_theme_constant_override("margin_right", 10)
	add_child(overlay)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_END
	hbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(hbox)

	var ortho_btn := Button.new()
	ortho_btn.text = "Perspective"
	ortho_btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	ortho_btn.add_theme_font_size_override("font_size", 11)
	ortho_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	ortho_btn.pressed.connect(func():
		if _camera != null:
			if _camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
				_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
				_camera.size = _cam_distance * 0.75
				ortho_btn.text = "Orthographic"
			else:
				_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
				ortho_btn.text = "Perspective"
	)
	hbox.add_child(ortho_btn)

	var reset_btn := Button.new()
	reset_btn.text = "⛶ Frame All / Reset View"
	reset_btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	reset_btn.add_theme_font_size_override("font_size", 11)
	reset_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	reset_btn.pressed.connect(func(): frame_scene())
	hbox.add_child(reset_btn)

func _is_pose_or_curved_conveyor(elem: SceneTypes.SceneElement) -> bool:
	if elem == null or elem.kind != "conveyor":
		return false
	if elem.geometry.has("inlet_pose") or elem.geometry.has("outlet_pose"):
		return true
	var preset: String = str(elem.geometry.get("shape_preset", elem.properties.get("shape_preset", "straight"))).to_lower()
	return preset != "straight" and not preset.is_empty()

func _get_elem_flow_endpoint_2d(elem: SceneTypes.SceneElement, is_output: bool) -> Vector2:
	if elem == null:
		return Vector2.ZERO
	if _is_pose_or_curved_conveyor(elem):
		var pts := MeshFactory.ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 16)
		if pts.size() >= 2:
			return pts[pts.size() - 1] if is_output else pts[0]
	var px: float = float(elem.transform.position[0])
	var py: float = float(elem.transform.position[1])
	var dims: Vector3 = MeshFactory.get_dims(elem, Vector3(2.0, 1.5, 1.0))
	return Vector2(px + dims.x if is_output else px, py + dims.y * 0.5)

func rebuild_3d_scene() -> void:
	_ensure_setup()
	if _entities_root == null:
		return

	for child in _entities_root.get_children():
		_entities_root.remove_child(child)
		child.queue_free()

	var bridges_root: Node3D = _world_root.get_node_or_null("BridgesRoot") if _world_root != null else null
	if bridges_root != null:
		for child in bridges_root.get_children():
			bridges_root.remove_child(child)
			child.queue_free()

	if doc_store == null or doc_store.active_document == null:
		return

	for elem in doc_store.active_document.elements:
		var anchor := Node3D.new()
		anchor.name = "ElemAnchor_" + elem.id
		anchor.set_meta("element_id", elem.id)

		var px: float = float(elem.transform.position[0])
		var py: float = float(elem.transform.position[1])
		var pz: float = float(elem.transform.position[2])
		var dims: Vector3 = MeshFactory.get_dims(elem, Vector3(2.0, 1.5, 1.0))
		var anchor_y: float = 0.0 if pz <= 1.05 else (pz - 0.8)
		anchor.position = Vector3(px, anchor_y, -py)
		anchor.rotation_degrees.y = -float(elem.transform.rotation.z)

		var node_3d := MeshFactory.create_3d_node_for_element(elem, doc_store)
		node_3d.name = "Elem3D_" + elem.id
		node_3d.position = Vector3.ZERO if _is_pose_or_curved_conveyor(elem) else Vector3(0, 0, -dims.y * 0.5)
		anchor.add_child(node_3d)

		_entities_root.add_child(anchor)

	# Build 3D Steel Roller Transfer Bridges across flow connections so no gaps appear between stations
	if bridges_root != null:
		for conn in doc_store.active_document.connections:
			if conn.link_type != "flow":
				continue
			var src_elem := doc_store.get_element(conn.source_element)
			var dst_elem := doc_store.get_element(conn.target_element)
			if src_elem == null or dst_elem == null:
				continue
			var p_out := _get_elem_flow_endpoint_2d(src_elem, true)
			var p_in := _get_elem_flow_endpoint_2d(dst_elem, false)
			var gap_m: float = p_out.distance_to(p_in)
			if gap_m > 0.12 and gap_m < 18.0:
				var bridge := MeshFactory.create_transfer_bridge_3d(p_out, p_in, 0.85, 0.80)
				bridge.name = "Bridge3D_" + str(conn.id)
				bridges_root.add_child(bridge)

	_update_selection_indicator()

func frame_scene() -> void:
	_ensure_setup()
	if _cam_pivot == null or _camera == null:
		return
	if doc_store == null or doc_store.active_document == null:
		_reset_camera_default()
		return

	var elems = doc_store.active_document.elements
	if elems.is_empty():
		_reset_camera_default()
		return

	var min_x := 1e9
	var max_x := -1e9
	var min_z := 1e9
	var max_z := -1e9

	for elem in elems:
		var px: float = float(elem.transform.position[0])
		var py: float = float(elem.transform.position[1])
		var dims: Vector3 = MeshFactory.get_dims(elem, Vector3(2.0, 1.5, 1.0))
		var gz_top: float = -py
		var gz_bot: float = -py - dims.y

		min_x = min(min_x, px)
		max_x = max(max_x, px + dims.x)
		min_z = min(min_z, gz_bot)
		max_z = max(max_z, gz_top)

	if min_x > max_x or min_z > max_z:
		_reset_camera_default()
		return

	var center_x := (min_x + max_x) * 0.5
	var center_z := (min_z + max_z) * 0.5
	var span_x: float = max_x - min_x
	var span_z: float = max_z - min_z
	var max_span: float = max(span_x, span_z)

	_cam_pivot.position = Vector3(center_x, 0.8, center_z)
	_cam_distance = clamp(max_span * 1.8 + 12.0, 12.0, 160.0)
	_cam_pitch = 0.65 # ~37 degrees elevation angle
	_cam_yaw = 0.55   # angled isometric perspective
	if _camera != null and _camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		_camera.size = _cam_distance * 0.75
	_update_camera_transform()

func frame_selection() -> void:
	_ensure_setup()
	if doc_store != null and doc_store.selected_type == "element" and not doc_store.selected_id.is_empty():
		var elem := doc_store.get_element(doc_store.selected_id)
		if elem != null:
			var px: float = float(elem.transform.position[0])
			var py: float = float(elem.transform.position[1])
			var dims: Vector3 = MeshFactory.get_dims(elem, Vector3(2.0, 1.5, 1.0))
			_cam_pivot.position = Vector3(px + dims.x * 0.5, 0.8, -py - dims.y * 0.5)
			_cam_distance = clamp(max(dims.x, dims.y) * 2.2 + 6.0, 6.0, 80.0)
			if _camera != null and _camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
				_camera.size = _cam_distance * 0.75
			_update_camera_transform()
			return
	frame_scene()

func _reset_camera_default() -> void:
	_ensure_setup()
	if _cam_pivot == null or _camera == null:
		return
	_cam_pivot.position = Vector3(15.0, 0.8, -10.0)
	_cam_distance = 30.0
	_cam_pitch = 0.65
	_cam_yaw = 0.55
	if _camera != null and _camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		_camera.size = _cam_distance * 0.75
	_update_camera_transform()

func _on_document_reloaded(_doc: SceneTypes.SceneDocument) -> void:
	rebuild_3d_scene()
	frame_scene()

func _on_document_modified() -> void:
	rebuild_3d_scene()
	if _geometry_overlay != null:
		_geometry_overlay.queue_redraw()

func _on_selection_changed(_sel_id: String, _sel_type: String) -> void:
	_update_selection_indicator()
	if _geometry_overlay != null:
		_geometry_overlay.queue_redraw()

func _update_selection_indicator() -> void:
	if _selection_indicator != null:
		if is_instance_valid(_selection_indicator):
			_selection_indicator.queue_free()
		_selection_indicator = null

	if doc_store == null or doc_store.selected_type != "element" or doc_store.selected_id.is_empty():
		return

	var elem := doc_store.get_element(doc_store.selected_id)
	if elem == null:
		return

	var anchor: Node3D = _entities_root.get_node_or_null("ElemAnchor_" + elem.id)
	if anchor == null:
		return

	var dims: Vector3 = MeshFactory.get_dims(elem, Vector3(2.0, 1.5, 1.0))
	var max_h: float = max(dims.z, 2.0)
	if elem.kind == "conveyor":
		var z_s: float = float(elem.geometry.get("elevation_start", 0.8))
		var z_e: float = float(elem.geometry.get("elevation_end", z_s))
		max_h = max(max_h, max(z_s, z_e) + 0.5)

	_selection_indicator = Node3D.new()
	_selection_indicator.name = "SelectionIndicator"

	var sel_mat := StandardMaterial3D.new()
	sel_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sel_mat.albedo_color = Color("#52c7a5")

	var arr_mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var min_x := -0.05
	var max_x := dims.x + 0.05
	var min_y := 0.0
	var max_y := max_h + 0.1
	var min_z := -dims.y - 0.05
	var max_z := 0.05

	var edges := [
		Vector3(min_x, min_y, min_z), Vector3(max_x, min_y, min_z),
		Vector3(max_x, min_y, min_z), Vector3(max_x, min_y, max_z),
		Vector3(max_x, min_y, max_z), Vector3(min_x, min_y, max_z),
		Vector3(min_x, min_y, max_z), Vector3(min_x, min_y, min_z),

		Vector3(min_x, max_y, min_z), Vector3(max_x, max_y, min_z),
		Vector3(max_x, max_y, min_z), Vector3(max_x, max_y, max_z),
		Vector3(max_x, max_y, max_z), Vector3(min_x, max_y, max_z),
		Vector3(min_x, max_y, max_z), Vector3(min_x, max_y, min_z),

		Vector3(min_x, min_y, min_z), Vector3(min_x, max_y, min_z),
		Vector3(max_x, min_y, min_z), Vector3(max_x, max_y, min_z),
		Vector3(max_x, min_y, max_z), Vector3(max_x, max_y, max_z),
		Vector3(min_x, min_y, max_z), Vector3(min_x, max_y, max_z)
	]
	for v in edges:
		verts.append(v)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	arr_mesh.surface_set_material(0, sel_mat)

	var mi := MeshInstance3D.new()
	mi.mesh = arr_mesh
	_selection_indicator.add_child(mi)

	anchor.add_child(_selection_indicator)

func pick_element_at(screen_pos: Vector2) -> String:
	if _camera == null or doc_store == null or doc_store.active_document == null:
		return ""

	var ray_origin := _camera.project_ray_origin(screen_pos)
	var ray_dir := _camera.project_ray_normal(screen_pos)

	var best_dist := 1e9
	var hit_elem_id := ""

	for elem in doc_store.active_document.elements:
		var anchor: Node3D = _entities_root.get_node_or_null("ElemAnchor_" + elem.id)
		if anchor == null:
			continue
		var dims: Vector3 = MeshFactory.get_dims(elem, Vector3(2.0, 1.5, 1.0))
		var max_h: float = max(dims.z, 2.0)
		if elem.kind == "conveyor":
			var z_s: float = float(elem.geometry.get("elevation_start", 0.8))
			var z_e: float = float(elem.geometry.get("elevation_end", z_s))
			max_h = max(max_h, max(z_s, z_e) + 0.5)

		# Transform ray into anchor's local coordinate space
		var inv_t: Transform3D = anchor.global_transform.affine_inverse()
		var local_orig: Vector3 = inv_t * ray_origin
		var local_dir: Vector3 = inv_t.basis * ray_dir

		# Local box bounds: X in [0, dims.x], Y in [0, max_h], Z in [-dims.y, 0]
		var aabb := AABB(Vector3(0, 0, -dims.y), Vector3(dims.x, max_h, dims.y))
		var hit_t = aabb.intersects_ray(local_orig, local_dir)
		if hit_t != null:
			var dist: float = local_orig.distance_to(local_orig + local_dir * hit_t)
			if dist < best_dist:
				best_dist = dist
				hit_elem_id = elem.id

	return hit_elem_id

func _update_camera_transform() -> void:
	if _camera == null or _cam_pivot == null:
		return
	var elev: float = clamp(_cam_pitch, 0.10, 1.45) # Elevation above horizontal floor plane (radians)
	var horiz_dist: float = _cam_distance * cos(elev)
	var off_y: float = _cam_distance * sin(elev)
	var off_x: float = horiz_dist * sin(_cam_yaw)
	var off_z: float = horiz_dist * cos(_cam_yaw)

	var target_pos := _cam_pivot.position
	var eye_pos := target_pos + Vector3(off_x, off_y, off_z)
	_camera.look_at_from_position(eye_pos, target_pos, Vector3.UP)
	if _camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		_camera.size = _cam_distance * 0.75
	if _geometry_overlay != null:
		_geometry_overlay.queue_redraw()

func _geometry_handles() -> Array:
	if geometry_mode_elem_id.is_empty() or doc_store == null or _camera == null or not _camera.is_inside_tree():
		return []
	var elem := doc_store.get_element(geometry_mode_elem_id)
	if elem == null or elem.kind != "conveyor":
		return []
	var baked := ConveyorCurve3D.sample_world_curve(elem, doc_store, 40)
	var pts: PackedVector3Array = baked.get("points", PackedVector3Array())
	if pts.size() < 2:
		return []
	var handles: Array = []
	var anchor: Node3D = _entities_root.get_node_or_null("ElemAnchor_" + elem.id) if _entities_root != null else null
	if anchor == null or not anchor.is_inside_tree():
		return []
	var preset := str(elem.geometry.get("shape_preset", "straight"))
	if preset == "spiral_helix":
		var quarter: Vector3 = pts[pts.size() / 4]
		var end: Vector3 = pts[pts.size() - 1]
		handles.append({"type": "radius", "world": Vector3(quarter.x, quarter.z, -quarter.y), "label": "Radius"})
		handles.append({"type": "rise", "world": Vector3(end.x, end.z, -end.y), "label": "Rise"})
		handles.append({"type": "turns", "world": Vector3(end.x, end.z, -end.y), "offset": Vector2(0, -36), "label": "Turns"})
	elif preset == "custom_spline":
		var params: Dictionary = elem.geometry.get("shape_params", {})
		var stations: Array = params.get("control_points", [])
		for index in range(stations.size()):
			var station = stations[index]
			if station is Dictionary and station.get("pos") is Array and station["pos"].size() >= 3:
				var pos: Array = station["pos"]
				handles.append({"type": "station", "index": index, "world": Vector3(float(pos[0]), float(pos[2]), -float(pos[1])), "label": "Z%d" % (index + 1)})
	for handle in handles:
		var point: Vector3 = handle["world"]
		handle["screen"] = _project_conveyor_point(elem, Vector3(point.x, -point.z, point.y), anchor) + handle.get("offset", Vector2.ZERO)
	return handles

func _project_conveyor_point(elem: SceneTypes.SceneElement, path_pos: Vector3, anchor: Node3D) -> Vector2:
	var element_pos: Vector3 = elem.transform.position
	var bed_height: float = float(elem.geometry.get("elevation_start", 0.8))
	var local_pos := Vector3(path_pos.x - element_pos.x, path_pos.z - element_pos.z + bed_height, element_pos.y - path_pos.y)
	var rendered_pos: Vector3 = anchor.global_transform * local_pos
	return Vector2(-1000, -1000) if _camera.is_position_behind(rendered_pos) else _camera.unproject_position(rendered_pos)

func _pick_conveyor_curve(screen_pos: Vector2) -> String:
	if doc_store == null or doc_store.active_document == null or _camera == null or not _camera.is_inside_tree():
		return ""
	var closest := 14.0
	var picked := ""
	for elem in doc_store.active_document.elements:
		if elem.kind != "conveyor":
			continue
		var anchor: Node3D = _entities_root.get_node_or_null("ElemAnchor_" + elem.id)
		if anchor == null or not anchor.is_inside_tree():
			continue
		var baked := ConveyorCurve3D.sample_world_curve(elem, doc_store, 32)
		var points: PackedVector3Array = baked.get("points", PackedVector3Array())
		for index in range(points.size() - 1):
			var start := _project_conveyor_point(elem, points[index], anchor)
			var finish := _project_conveyor_point(elem, points[index + 1], anchor)
			if start.x < 0 or finish.x < 0:
				continue
			var segment := finish - start
			var ratio: float = clampf((screen_pos - start).dot(segment) / maxf(segment.length_squared(), 0.001), 0.0, 1.0)
			var distance := screen_pos.distance_to(start + segment * ratio)
			if distance < closest:
				closest = distance
				picked = elem.id
	return picked

func _draw_geometry_handles() -> void:
	if _geometry_overlay == null:
		return
	if not _geometry_warning.is_empty():
		_geometry_overlay.draw_string(ThemeDB.fallback_font, Vector2(16, 66), _geometry_warning, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 32), 13, Color("#f39c12"))
	for handle in _geometry_handles():
		var pos: Vector2 = handle["screen"]
		if pos.x < 0 or pos.y < 0 or pos.x > size.x or pos.y > size.y:
			continue
		_geometry_overlay.draw_circle(pos, 9.0, Color("#00d2ff"))
		_geometry_overlay.draw_arc(pos, 11.0, 0, TAU, 20, Color.WHITE, 1.5)
		_geometry_overlay.draw_string(ThemeDB.fallback_font, pos + Vector2(13, 4), str(handle["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)

func _hit_geometry_handle(screen_pos: Vector2) -> Dictionary:
	var nearest: Dictionary = {}
	var nearest_distance := 15.0
	for handle in _geometry_handles():
		var distance: float = (handle["screen"] as Vector2).distance_to(screen_pos)
		if distance < nearest_distance:
			nearest = handle
			nearest_distance = distance
	return nearest

func _drag_geometry_handle(screen_pos: Vector2) -> void:
	if _geometry_drag.is_empty() or doc_store == null:
		return
	var elem := doc_store.get_element(geometry_mode_elem_id)
	if elem == null:
		return
	var locks := ConveyorCurve3D.connected_endpoint_locks(elem.id, doc_store)
	var before := ConveyorCurve3D.sample_world_curve(elem, doc_store) if locks["inlet"] or locks["outlet"] else {}
	var original_geometry: Dictionary = elem.geometry.duplicate(true)
	var delta := screen_pos - (_geometry_drag["start_screen"] as Vector2)
	var kind: String = _geometry_drag["type"]
	if kind == "station":
		var points: Array = elem.geometry["shape_params"]["control_points"]
		var index: int = _geometry_drag["index"]
		if index < 0 or index >= points.size():
			return
		points[index]["pos"][2] = snapped(float(_geometry_drag["start_value"]) - delta.y * _cam_distance / maxf(size.y, 1.0), 0.05)
	else:
		var params: Dictionary = elem.geometry["shape_params"]
		match kind:
			"rise":
				params["elevation_gain"] = snapped(clampf(float(_geometry_drag["start_value"]) - delta.y * _cam_distance / maxf(size.y, 1.0), -20.0, 20.0), 0.05)
			"turns":
				params["helix_turns"] = snapped(clampf(float(_geometry_drag["start_value"]) + delta.x / 80.0, 0.25, 6.0), 0.05)
			"radius":
				params["helix_radius"] = snapped(clampf(float(_geometry_drag["start_value"]) + delta.x * _cam_distance / maxf(size.x, 1.0), 1.0, 25.0), 0.05)
	if not before.is_empty() and not ConveyorCurve3D.connected_endpoints_unchanged(before, ConveyorCurve3D.sample_world_curve(elem, doc_store), locks):
		elem.geometry = original_geometry
		_geometry_warning = "Connected endpoint is locked; edit reverted"
		_geometry_drag.clear()
		_geometry_overlay.queue_redraw()
		return
	_geometry_warning = ""
	doc_store.is_dirty = true
	doc_store.document_modified.emit()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ik := event as InputEventKey
		if ik.pressed and ik.keycode == KEY_ESCAPE and not _geometry_drag.is_empty():
			_geometry_drag.clear()
			doc_store.undo()
			_geometry_warning = "Edit cancelled"
			_geometry_overlay.queue_redraw()
			accept_event()
			return
		if ik.pressed and ik.keycode == KEY_F:
			frame_selection()
			accept_event()
			return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var handle := _hit_geometry_handle(mb.position)
				if not handle.is_empty():
					var elem := doc_store.get_element(geometry_mode_elem_id)
					var params: Dictionary = elem.geometry.get("shape_params", {})
					var kind: String = handle["type"]
					var initial: float = 0.0
					match kind:
						"radius": initial = float(params.get("helix_radius", 2.5))
						"rise": initial = float(params.get("elevation_gain", 2.4))
						"turns": initial = float(params.get("helix_turns", 1.5))
						"station": initial = float(params["control_points"][handle["index"]]["pos"][2])
					doc_store._record_undo()
					_geometry_drag = {"type": kind, "index": handle.get("index", -1), "start_value": initial, "start_screen": mb.position}
					accept_event()
					return
				_last_mouse_pos = mb.position
				accept_event()
			else:
				if not _geometry_drag.is_empty():
					_geometry_drag.clear()
					var elem := doc_store.get_element(geometry_mode_elem_id)
					if elem != null:
						var diagnostics := ConveyorCurve3D.geometry_diagnostics(elem, doc_store)
						if not str(diagnostics["error"]).is_empty():
							doc_store.undo()
							_geometry_warning = diagnostics["error"]
						else:
							_geometry_warning = str(diagnostics["warning"])
							doc_store.validate()
						_geometry_overlay.queue_redraw()
					accept_event()
					return
				# Click without drag (threshold 6px) -> Pick element
				if mb.position.distance_to(_last_mouse_pos) < 6.0:
					var hit_elem := pick_element_at(mb.position)
					if doc_store != null:
						if not hit_elem.is_empty():
							doc_store.select(hit_elem, "element")
						else:
							doc_store.clear_selection()
					accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_is_orbiting = mb.pressed
			if not mb.pressed and mb.position.distance_to(_last_mouse_pos) < 6.0:
				var hit_elem := pick_element_at(mb.position)
				if not hit_elem.is_empty():
					if doc_store != null:
						doc_store.select(hit_elem, "element")
					floating_properties_requested.emit(hit_elem, mb.global_position)
			_last_mouse_pos = mb.position
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				var conveyor_id := _pick_conveyor_curve(mb.position)
				if not conveyor_id.is_empty():
					conveyor_geometry_mode_requested.emit(conveyor_id)
					accept_event()
					return
			_is_panning = mb.pressed
			_last_mouse_pos = mb.position
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_distance = clamp(_cam_distance * 0.88, 2.0, 200.0)
			if _camera != null and _camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
				_camera.size = _cam_distance * 0.75
			_update_camera_transform()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_distance = clamp(_cam_distance * 1.14, 2.0, 200.0)
			if _camera != null and _camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
				_camera.size = _cam_distance * 0.75
			_update_camera_transform()
			accept_event()

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if not _geometry_drag.is_empty():
			_drag_geometry_handle(mm.position)
			accept_event()
			return
		var delta := mm.position - _last_mouse_pos
		_last_mouse_pos = mm.position

		if _is_orbiting:
			_cam_yaw -= delta.x * 0.006
			_cam_pitch = clamp(_cam_pitch - delta.y * 0.006, 0.10, 1.45)
			_update_camera_transform()
			accept_event()
		elif _is_panning:
			var forward := -_camera.global_transform.basis.z
			var right := _camera.global_transform.basis.x
			forward.y = 0.0
			if forward.length_squared() > 0.0001:
				forward = forward.normalized()
			right.y = 0.0
			if right.length_squared() > 0.0001:
				right = right.normalized()
			var move := (-right * delta.x + forward * delta.y) * (_cam_distance * 0.0015)
			_cam_pivot.position += move
			_update_camera_transform()
			accept_event()

# ============================================================================
# Agent Telemetry & Follow Camera
# ============================================================================

var _agent_transforms: Array = []
var _agent_target_transforms: Dictionary = {}
var _agent_smoothed_transforms: Dictionary = {}
var _agent_colors: Dictionary = {}

func get_agent_transform_3d(index: int) -> Transform3D:
	if index >= 0 and index < _agent_transforms.size():
		return _agent_transforms[index]
	return Transform3D.IDENTITY

func _process(delta: float) -> void:
	if _agents_multimesh == null:
		return
	if _active_agents.is_empty():
		_agents_multimesh.instance_count = 0
		_agent_transforms.clear()
		return

	var count: int = _active_agents.size()
	if _agents_multimesh.instance_count != count:
		_agents_multimesh.instance_count = count
	_agent_transforms.resize(count)

	var lerp_weight: float = clamp(delta * 25.0, 0.0, 1.0)

	for i in range(count):
		var agent = _active_agents[i]
		if not (agent is Dictionary):
			continue
		var aid: String = str(agent.get("id", str(i)))
		var target_t: Transform3D = _agent_target_transforms.get(aid, Transform3D.IDENTITY)
		var cur_t: Transform3D = _agent_smoothed_transforms.get(aid, target_t)

		var smooth_pos: Vector3 = cur_t.origin.lerp(target_t.origin, lerp_weight)
		var smooth_basis: Basis = cur_t.basis.slerp(target_t.basis, lerp_weight).orthonormalized()
		var smoothed_t := Transform3D(smooth_basis, smooth_pos)

		_agent_smoothed_transforms[aid] = smoothed_t
		_agent_transforms[i] = smoothed_t
		_agents_multimesh.set_instance_transform(i, smoothed_t)
		_agents_multimesh.set_instance_color(i, _agent_colors.get(aid, Color("#f39c12")))

		if is_follow_camera_active and aid == selected_agent_id and not aid.is_empty():
			if _cam_pivot != null:
				_cam_pivot.position = smooth_pos
				_update_camera_transform()

func update_agent_telemetry(agents: Array) -> void:
	_active_agents = agents
	var active_ids: Dictionary = {}

	for i in range(agents.size()):
		var agent = agents[i]
		if not (agent is Dictionary):
			continue

		var aid: String = str(agent.get("id", str(i)))
		if aid.is_empty():
			aid = str(i)
		active_ids[aid] = true

		var raw_pos = agent.get("position", [0.0, 0.0, 0.0])
		var px: float = 0.0
		var py: float = 0.0
		var pz: float = 0.0
		if agent.has("x") and agent.has("y"):
			px = float(agent["x"])
			py = float(agent["y"])
			pz = float(agent.get("z", 0.0))
		elif agent.has("properties") and agent.properties is Dictionary:
			var p: Dictionary = agent.properties
			if p.has("x"): px = float(p.x)
			if p.has("y"): py = float(p.y)
			if p.has("z"): pz = float(p.get("z", 0.0))
		elif raw_pos is Array:
			if raw_pos.size() >= 1: px = float(raw_pos[0])
			if raw_pos.size() >= 2: py = float(raw_pos[1])
			if raw_pos.size() >= 3: pz = float(raw_pos[2])
		elif raw_pos is Vector3:
			px = raw_pos.x
			py = raw_pos.y
			pz = raw_pos.z
		elif raw_pos is Vector2:
			px = raw_pos.x
			py = raw_pos.y

		var elem_id_ag: String = str(agent.get("zone", ""))
		if elem_id_ag.is_empty() and agent.has("properties") and agent.properties is Dictionary:
			elem_id_ag = str(agent.properties.get("element_id", ""))
		if not elem_id_ag.is_empty() and doc_store != null:
			var target_elem := doc_store.get_element(elem_id_ag)
			if target_elem != null:
				if target_elem.kind == "conveyor" and not _is_pose_or_curved_conveyor(target_elem):
					if is_zero_approx(float(target_elem.transform.rotation.z)):
						var base_y_m: float = float(target_elem.transform.position[1])
						var dims_c: Vector3 = MeshFactory.get_dims(target_elem, Vector3(8.0, 1.2, 0.8))
						var half_h_m: float = dims_c.y * 0.5
						if absf(py - base_y_m) < 0.05 or absf(py - (base_y_m + half_h_m)) < half_h_m + 0.1:
							py = base_y_m + half_h_m
				elif target_elem.kind == "queue":
					var base_x_m: float = float(target_elem.transform.position[0])
					var base_y_m: float = float(target_elem.transform.position[1])
					var dims_q: Vector3 = MeshFactory.get_dims(target_elem, Vector3(4.0, 2.0, 0.8))
					if dims_q.x >= dims_q.y:
						py = base_y_m + dims_q.y * 0.5
						px = clampf(px, base_x_m + 0.35, base_x_m + dims_q.x - 0.35)
					else:
						px = base_x_m + dims_q.x * 0.5
						py = clampf(py, base_y_m + 0.35, base_y_m + dims_q.y - 0.35)

		# Coordinates: SceneSpec Z-up (X East, Y North, Z Up) -> Godot (X, Y_up, -Y)
		var elev_y: float = (pz + 0.20) if pz > 0.4 else (pz + 0.85)
		var g_pos := Vector3(px, elev_y, -py)

		var vel = agent.get("velocity", [0.0, 0.0])
		var vx: float = 0.0
		var vy: float = 0.0
		if agent.has("vx") and agent.has("vy"):
			vx = float(agent["vx"])
			vy = float(agent["vy"])
		elif agent.has("properties") and agent.properties is Dictionary:
			var p: Dictionary = agent.properties
			if p.has("vx"): vx = float(p.vx)
			if p.has("vy"): vy = float(p.vy)
		elif vel is Array and vel.size() >= 2:
			vx = float(vel[0])
			vy = float(vel[1])
		elif vel is Vector2 or vel is Vector3:
			vx = vel.x
			vy = vel.y

		var speed := sqrt(vx * vx + vy * vy)
		var yaw := 0.0
		if speed > 0.01:
			yaw = atan2(-vy, vx)

		var basis := Basis.from_euler(Vector3(0, yaw, 0))
		var target_t := Transform3D(basis, g_pos)
		_agent_target_transforms[aid] = target_t
		if not _agent_smoothed_transforms.has(aid):
			_agent_smoothed_transforms[aid] = target_t

		# Color: Product vs Pedestrian
		var kind: String = str(agent.get("kind", "product"))
		var is_product: bool = (kind == "product" or kind == "carton" or kind == "item")
		var in_service: bool = false
		var has_custom_col: bool = false
		var custom_col := Color("#f39c12")
		if agent.has("properties") and agent.properties is Dictionary:
			in_service = bool(agent.properties.get("in_service", false))
			if agent.properties.has("color_r") and agent.properties.has("color_g") and agent.properties.has("color_b"):
				has_custom_col = true
				custom_col = Color(float(agent.properties.color_r), float(agent.properties.color_g), float(agent.properties.color_b), 1.0)
		var state: String = str(agent.get("state", "walking"))

		var col := Color("#2ecc71") # green
		if is_product:
			if has_custom_col:
				col = custom_col
			elif in_service:
				col = Color("#2ecc71") # being serviced emerald green
			elif state == "queuing" or (agent.has("current_location") and "q" in str(agent.current_location)):
				col = Color("#00d2ff") # waiting in queue bright cyan
			else:
				col = Color("#f39c12") # on conveyor / transit amber
		else:
			if state == "queuing":
				col = Color("#3498db") # blue
			elif speed < 0.35:
				col = Color("#e74c3c") # red
			elif speed < 1.0:
				col = Color("#f1c40f") # amber
		_agent_colors[aid] = col

	# Prune departed entities
	for old_id in _agent_smoothed_transforms.keys():
		if not active_ids.has(old_id):
			_agent_smoothed_transforms.erase(old_id)
			_agent_target_transforms.erase(old_id)
			_agent_colors.erase(old_id)

	if not is_inside_tree():
		_process(1.0)

func set_follow_camera(active: bool, agent_id: String = "") -> void:
	is_follow_camera_active = active
	if not agent_id.is_empty():
		selected_agent_id = agent_id

var is_following_agent: bool:
	get:
		return is_follow_camera_active

var follow_agent_id: String:
	get:
		return selected_agent_id

var _camera_target: Vector3:
	get:
		return _cam_pivot.position if _cam_pivot != null else Vector3.ZERO

