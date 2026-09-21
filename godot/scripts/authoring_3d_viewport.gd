# authoring_3d_viewport.gd
# Synchronized 3D Layout Viewport with procedural PBR equipment, concrete floor, lighting, and orbit camera.
class_name SimVizAuthoring3DViewport
extends SubViewportContainer

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const MeshFactory := preload("res://scripts/authoring_mesh_factory.gd")

var doc_store: DocumentStore

var _sub_viewport: SubViewport
var _world_root: Node3D
var _camera: Camera3D
var _cam_pivot: Node3D
var _entities_root: Node3D
var _floor_mesh: MeshInstance3D

# Orbit Camera parameters
var _cam_distance: float = 30.0
var _cam_pitch: float = 0.65   # Radians elevation above floor (~37 degrees)
var _cam_yaw: float = 0.55     # Radians horizontal azimuth
var _is_orbiting: bool = false
var _is_panning: bool = false
var _last_mouse_pos: Vector2 = Vector2.ZERO

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

func _setup_ui_overlay() -> void:
	var overlay := MarginContainer.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_theme_constant_override("margin_top", 10)
	overlay.add_theme_constant_override("margin_right", 10)
	add_child(overlay)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_END
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(hbox)

	var reset_btn := Button.new()
	reset_btn.text = "⛶ Frame All / Reset View"
	reset_btn.add_theme_font_size_override("font_size", 11)
	reset_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	reset_btn.pressed.connect(func(): frame_scene())
	hbox.add_child(reset_btn)

func rebuild_3d_scene() -> void:
	_ensure_setup()
	if _entities_root == null:
		return

	for child in _entities_root.get_children():
		_entities_root.remove_child(child)
		child.queue_free()

	if doc_store == null or doc_store.active_document == null:
		return

	for elem in doc_store.active_document.elements:
		var node_3d := MeshFactory.create_3d_node_for_element(elem)
		_entities_root.add_child(node_3d)

		# Position in 3D: SceneSpec X, Y, Z maps to Godot 3D (X, Z, -Y)
		var px: float = float(elem.transform.position[0])
		var py: float = float(elem.transform.position[1])
		var pz: float = float(elem.transform.position[2])
		# Godot 3D coordinate system: X East, Y Up, Z South
		node_3d.position = Vector3(px, pz, -py)

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
		var gz: float = -py

		min_x = min(min_x, px)
		max_x = max(max_x, px + dims.x)
		min_z = min(min_z, gz - dims.y * 0.5)
		max_z = max(max_z, gz + dims.y * 0.5)

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
	_update_camera_transform()

func _reset_camera_default() -> void:
	_ensure_setup()
	if _cam_pivot == null or _camera == null:
		return
	_cam_pivot.position = Vector3(15.0, 0.8, -10.0)
	_cam_distance = 30.0
	_cam_pitch = 0.65
	_cam_yaw = 0.55
	_update_camera_transform()

func _on_document_reloaded(_doc: SceneTypes.SceneDocument) -> void:
	rebuild_3d_scene()
	frame_scene()

func _on_document_modified() -> void:
	rebuild_3d_scene()

func _on_selection_changed(_sel_id: String, _sel_type: String) -> void:
	pass

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

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_is_orbiting = mb.pressed
			_last_mouse_pos = mb.position
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_is_panning = mb.pressed
			_last_mouse_pos = mb.position
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_distance = clamp(_cam_distance * 0.88, 2.0, 200.0)
			_update_camera_transform()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_distance = clamp(_cam_distance * 1.14, 2.0, 200.0)
			_update_camera_transform()
			accept_event()

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
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
