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
var _cam_distance: float = 24.0
var _cam_pitch: float = -0.55 # Radians (~31 degrees down)
var _cam_yaw: float = 0.65   # Radians
var _is_orbiting: bool = false
var _is_panning: bool = false
var _last_mouse_pos: Vector2 = Vector2.ZERO

func _init(p_store: DocumentStore = null) -> void:
	doc_store = p_store
	stretch = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP

func _ready() -> void:
	_setup_3d_world()
	if doc_store != null:
		doc_store.document_loaded.connect(_on_document_reloaded)
		doc_store.document_modified.connect(_on_document_modified)
		doc_store.selection_changed.connect(_on_selection_changed)
		rebuild_3d_scene()

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
	env_res.ambient_light_color = Color("#4b5a6c")
	env_res.ambient_light_energy = 1.2
	env.environment = env_res
	_world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.785, 0.61, 0)
	sun.light_color = Color("#ffffff")
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	_world_root.add_child(sun)

	# 2. Polished Concrete Floor Slab
	var floor_m := PlaneMesh.new()
	floor_m.size = Vector2(160, 160)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color("#18212c")
	floor_mat.metallic = 0.2
	floor_mat.roughness = 0.4
	floor_m.material = floor_mat

	_floor_mesh = MeshInstance3D.new()
	_floor_mesh.mesh = floor_m
	_floor_mesh.position = Vector3(0, 0, 0)
	_world_root.add_child(_floor_mesh)

	# 3. Orbit Camera Rig
	_cam_pivot = Node3D.new()
	_cam_pivot.position = Vector3(10, 0, 10)
	_world_root.add_child(_cam_pivot)

	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 50.0
	_cam_pivot.add_child(_camera)
	_update_camera_transform()

	# 4. Equipment Container
	_entities_root = Node3D.new()
	_entities_root.name = "EntitiesRoot"
	_world_root.add_child(_entities_root)

func rebuild_3d_scene() -> void:
	if _entities_root == null:
		return

	for child in _entities_root.get_children():
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

func _on_document_reloaded(_doc: SceneTypes.SceneDocument) -> void:
	rebuild_3d_scene()

func _on_document_modified() -> void:
	rebuild_3d_scene()

func _on_selection_changed(_sel_id: String, _sel_type: String) -> void:
	# Future: outline shader or bounding box highlight
	pass

func _update_camera_transform() -> void:
	_cam_pivot.rotation.y = _cam_yaw
	_camera.rotation.x = _cam_pitch
	_camera.position = Vector3(0, 0, _cam_distance)

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
			_cam_distance = clamp(_cam_distance * 0.9, 2.0, 150.0)
			_update_camera_transform()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_distance = clamp(_cam_distance * 1.1, 2.0, 150.0)
			_update_camera_transform()
			accept_event()

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var delta := mm.position - _last_mouse_pos
		_last_mouse_pos = mm.position

		if _is_orbiting:
			_cam_yaw -= delta.x * 0.006
			_cam_pitch = clamp(_cam_pitch - delta.y * 0.006, -1.4, -0.05)
			_update_camera_transform()
			accept_event()
		elif _is_panning:
			var forward := -_camera.global_transform.basis.z
			var right := _camera.global_transform.basis.x
			forward.y = 0.0
			forward = forward.normalized()
			right.y = 0.0
			right = right.normalized()
			var move := (-right * delta.x + forward * delta.y) * (_cam_distance * 0.002)
			_cam_pivot.position += move
			accept_event()

