# authoring_mesh_factory.gd
# Procedural Industrial PBR 3D Mesh Factory for conveyors (with legs & variable elevations), queues, and servers.
class_name SimVizAuthoringMeshFactory
extends RefCounted

const SceneTypes := preload("res://scripts/scenespec_types.gd")

# Reusable PBR Materials
static var _mat_steel: StandardMaterial3D
static var _mat_belt: StandardMaterial3D
static var _mat_table: StandardMaterial3D
static var _mat_floor_stripe: StandardMaterial3D
static var _mat_beacon_green: StandardMaterial3D
static var _mat_beacon_yellow: StandardMaterial3D
static var _mat_beacon_red: StandardMaterial3D
static var _mat_source_accent: StandardMaterial3D
static var _mat_sink_accent: StandardMaterial3D
static var _mat_spawner: StandardMaterial3D
static var _mat_exit: StandardMaterial3D
static var _mat_portal_glass: StandardMaterial3D
static var _mat_wall: StandardMaterial3D
static var _mat_room_floor: StandardMaterial3D

static func _ensure_materials() -> void:
	if _mat_steel != null:
		return

	# Powder-coated / structural steel
	_mat_steel = StandardMaterial3D.new()
	_mat_steel.albedo_color = Color("#8fa0b3")
	_mat_steel.metallic = 0.85
	_mat_steel.roughness = 0.25

	# Matte rubber conveyor belt
	_mat_belt = StandardMaterial3D.new()
	_mat_belt.albedo_color = Color("#1e232a")
	_mat_belt.metallic = 0.0
	_mat_belt.roughness = 0.85

	# Stainless steel workstation table
	_mat_table = StandardMaterial3D.new()
	_mat_table.albedo_color = Color("#c4d0dc")
	_mat_table.metallic = 0.95
	_mat_table.roughness = 0.18

	# Hazard yellow/black stripe
	_mat_floor_stripe = StandardMaterial3D.new()
	_mat_floor_stripe.albedo_color = Color("#f1c40f")
	_mat_floor_stripe.metallic = 0.1
	_mat_floor_stripe.roughness = 0.7

	# Emissive Beacon Lights
	_mat_beacon_green = StandardMaterial3D.new()
	_mat_beacon_green.albedo_color = Color("#2ecc71")
	_mat_beacon_green.emission_enabled = true
	_mat_beacon_green.emission = Color("#2ecc71")
	_mat_beacon_green.emission_energy_multiplier = 3.0

	_mat_beacon_yellow = StandardMaterial3D.new()
	_mat_beacon_yellow.albedo_color = Color("#f39c12")
	_mat_beacon_yellow.emission_enabled = true
	_mat_beacon_yellow.emission = Color("#f39c12")
	_mat_beacon_yellow.emission_energy_multiplier = 0.5 # dim when inactive

	_mat_beacon_red = StandardMaterial3D.new()
	_mat_beacon_red.albedo_color = Color("#e74c3c")
	_mat_beacon_red.emission_enabled = true
	_mat_beacon_red.emission = Color("#e74c3c")
	_mat_beacon_red.emission_energy_multiplier = 0.5 # dim when inactive

	# Source Infeed Accent (Powder-coat Green)
	_mat_source_accent = StandardMaterial3D.new()
	_mat_source_accent.albedo_color = Color("#27ae60")
	_mat_source_accent.metallic = 0.4
	_mat_source_accent.roughness = 0.35

	# Sink Collection Bin Accent (Industrial Purple)
	_mat_sink_accent = StandardMaterial3D.new()
	_mat_sink_accent.albedo_color = Color("#8e44ad")
	_mat_sink_accent.metallic = 0.4
	_mat_sink_accent.roughness = 0.35

	# Crowd Spawner (Translucent Lime with gentle glow)
	_mat_spawner = StandardMaterial3D.new()
	_mat_spawner.albedo_color = Color(0.55, 0.77, 0.29, 0.6)
	_mat_spawner.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_spawner.emission_enabled = true
	_mat_spawner.emission = Color("#8bc34a")
	_mat_spawner.emission_energy_multiplier = 0.8

	# Exit Goal (Glowing Emergency Green)
	_mat_exit = StandardMaterial3D.new()
	_mat_exit.albedo_color = Color("#2ecc71")
	_mat_exit.emission_enabled = true
	_mat_exit.emission = Color("#2ecc71")
	_mat_exit.emission_energy_multiplier = 2.5

	# Hybrid Portal Glass (Translucent Cyan)
	_mat_portal_glass = StandardMaterial3D.new()
	_mat_portal_glass.albedo_color = Color(0.3, 0.7, 0.9, 0.45)
	_mat_portal_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_portal_glass.roughness = 0.1
	_mat_portal_glass.metallic = 0.2

	# Architectural Wall / Column (Warm Matte Off-White)
	_mat_wall = StandardMaterial3D.new()
	_mat_wall.albedo_color = Color("#bdc3c7")
	_mat_wall.metallic = 0.1
	_mat_wall.roughness = 0.85

	# Walkable Floor Surface (Subtle Concrete/Tile)
	_mat_room_floor = StandardMaterial3D.new()
	_mat_room_floor.albedo_color = Color("#34495e")
	_mat_room_floor.metallic = 0.05
	_mat_room_floor.roughness = 0.7

static func create_3d_node_for_element(elem: SceneTypes.SceneElement) -> Node3D:
	_ensure_materials()
	var root := Node3D.new()
	root.name = "Elem3D_" + elem.id

	match elem.kind:
		"conveyor":
			_build_conveyor(root, elem)
		"server":
			_build_server(root, elem)
		"queue":
			_build_queue(root, elem)
		"source":
			_build_source(root, elem)
		"sink":
			_build_sink(root, elem)
		"crowd_spawner":
			_build_crowd_spawner(root, elem)
		"exit_goal":
			_build_exit_goal(root, elem)
		"hybrid_portal":
			_build_hybrid_portal(root, elem)
		"obstacle_wall":
			_build_obstacle_wall(root, elem)
		"walkable_room":
			_build_walkable_room(root, elem)
		_:
			_build_generic_box(root, elem)

	return root

static func _build_conveyor(root: Node3D, elem: SceneTypes.SceneElement) -> void:
	var dims := _get_dims(elem, Vector3(8.0, 1.2, 0.2))
	var length: float = dims.x
	var width: float = dims.y
	var bed_thickness: float = 0.15

	var z_start: float = float(elem.geometry.get("elevation_start", 0.8))
	var z_end: float = float(elem.geometry.get("elevation_end", z_start))
	var dz := z_end - z_start
	var length_3d := sqrt((length * length) + (dz * dz))
	var pitch_rad := asin(clamp(dz / max(length_3d, 0.001), -1.0, 1.0))

	# Conveyor Bed Assembly (pitched)
	var bed_pivot := Node3D.new()
	bed_pivot.name = "BedPivot"
	# Godot 3D: X East, Y Up, Z South (so ground plan is X/Z, elevation is Y)
	# Canonical Z-up is projected: X -> X, Y -> -Z, Z -> Y
	bed_pivot.position = Vector3(0, z_start, 0)
	bed_pivot.rotation.z = pitch_rad # incline along X axis
	root.add_child(bed_pivot)

	# 1. Rubber Belt
	var belt_mesh := BoxMesh.new()
	belt_mesh.size = Vector3(length_3d, bed_thickness * 0.5, width * 0.9)
	belt_mesh.material = _mat_belt
	var belt_inst := MeshInstance3D.new()
	belt_inst.mesh = belt_mesh
	belt_inst.position = Vector3(length_3d * 0.5, bed_thickness * 0.25, 0)
	bed_pivot.add_child(belt_inst)

	# 2. Side Steel Channel Frames
	var side_mesh := BoxMesh.new()
	side_mesh.size = Vector3(length_3d, bed_thickness * 1.5, 0.06)
	side_mesh.material = _mat_steel

	var side_left := MeshInstance3D.new()
	side_left.mesh = side_mesh
	side_left.position = Vector3(length_3d * 0.5, bed_thickness * 0.5, (width * 0.5) - 0.03)
	bed_pivot.add_child(side_left)

	var side_right := MeshInstance3D.new()
	side_right.mesh = side_mesh
	side_right.position = Vector3(length_3d * 0.5, bed_thickness * 0.5, -(width * 0.5) + 0.03)
	bed_pivot.add_child(side_right)

	# 3. Support Legs with Leveling Feet anchored to Floor
	var leg_spacing := 2.0
	var leg_count: int = max(2, int(ceil(length / leg_spacing)) + 1)
	for i in range(leg_count):
		var t: float = float(i) / float(max(1, leg_count - 1))
		var x_pos: float = t * length
		var z_elev: float = z_start + (t * dz) # height from floor
		var leg_height: float = max(z_elev, 0.1)

		var leg_assembly := Node3D.new()
		leg_assembly.position = Vector3(x_pos, 0, 0) # On floor
		root.add_child(leg_assembly)

		# Left and Right vertical tubes
		for side_sign in [-1.0, 1.0]:
			var tube_mesh := BoxMesh.new()
			tube_mesh.size = Vector3(0.08, leg_height, 0.08)
			tube_mesh.material = _mat_steel

			var tube_inst := MeshInstance3D.new()
			tube_inst.mesh = tube_mesh
			tube_inst.position = Vector3(0, leg_height * 0.5, side_sign * (width * 0.45))
			leg_assembly.add_child(tube_inst)

			# Circular leveling foot on floor
			var foot_mesh := CylinderMesh.new()
			foot_mesh.top_radius = 0.08
			foot_mesh.bottom_radius = 0.10
			foot_mesh.height = 0.03
			foot_mesh.material = _mat_steel

			var foot_inst := MeshInstance3D.new()
			foot_inst.mesh = foot_mesh
			foot_inst.position = Vector3(0, 0.015, side_sign * (width * 0.45))
			leg_assembly.add_child(foot_inst)

		# Cross brace between left and right tube
		var brace_mesh := BoxMesh.new()
		brace_mesh.size = Vector3(0.06, 0.06, width * 0.8)
		brace_mesh.material = _mat_steel
		var brace_inst := MeshInstance3D.new()
		brace_inst.mesh = brace_mesh
		brace_inst.position = Vector3(0, leg_height * 0.4, 0)
		leg_assembly.add_child(brace_inst)

static func _build_server(root: Node3D, elem: SceneTypes.SceneElement) -> void:
	var dims := _get_dims(elem, Vector3(3.0, 2.0, 1.8))
	var length: float = dims.x
	var width: float = dims.y
	var table_height: float = 0.85

	# 1. Stainless Steel Work Table
	var table_top := BoxMesh.new()
	table_top.size = Vector3(length, 0.08, width)
	table_top.material = _mat_table
	var table_inst := MeshInstance3D.new()
	table_inst.mesh = table_top
	table_inst.position = Vector3(length * 0.5, table_height, 0)
	root.add_child(table_inst)

	# 2. Table Support Legs
	var leg_tube := BoxMesh.new()
	leg_tube.size = Vector3(0.08, table_height, 0.08)
	leg_tube.material = _mat_steel
	for dx in [0.1, length - 0.1]:
		for dz in [-(width * 0.5) + 0.1, (width * 0.5) - 0.1]:
			var leg := MeshInstance3D.new()
			leg.mesh = leg_tube
			leg.position = Vector3(dx, table_height * 0.5, dz)
			root.add_child(leg)

	# 3. Overhead Gantry
	var gantry_h: float = max(dims.z, 2.2)
	for dx in [0.1, length - 0.1]:
		var g_post := MeshInstance3D.new()
		var p_mesh := BoxMesh.new()
		p_mesh.size = Vector3(0.06, gantry_h, 0.06)
		p_mesh.material = _mat_steel
		g_post.mesh = p_mesh
		g_post.position = Vector3(dx, gantry_h * 0.5, -(width * 0.5) + 0.05)
		root.add_child(g_post)

	# Top gantry beam
	var top_beam := MeshInstance3D.new()
	var tb_mesh := BoxMesh.new()
	tb_mesh.size = Vector3(length, 0.06, 0.06)
	tb_mesh.material = _mat_steel
	top_beam.mesh = tb_mesh
	top_beam.position = Vector3(length * 0.5, gantry_h, -(width * 0.5) + 0.05)
	root.add_child(top_beam)

	# 4. 3-Color Andon Status Beacon Tower
	var beacon_base := MeshInstance3D.new()
	var b_base_mesh := CylinderMesh.new()
	b_base_mesh.top_radius = 0.04
	b_base_mesh.bottom_radius = 0.05
	b_base_mesh.height = 0.2
	b_base_mesh.material = _mat_steel
	beacon_base.mesh = b_base_mesh
	beacon_base.position = Vector3(0.2, gantry_h + 0.1, -(width * 0.5) + 0.05)
	root.add_child(beacon_base)

	# Red Light (Top)
	var light_red := MeshInstance3D.new()
	var cyl_red := CylinderMesh.new()
	cyl_red.top_radius = 0.04
	cyl_red.bottom_radius = 0.04
	cyl_red.height = 0.08
	cyl_red.material = _mat_beacon_red
	light_red.mesh = cyl_red
	light_red.position = Vector3(0.2, gantry_h + 0.36, -(width * 0.5) + 0.05)
	root.add_child(light_red)

	# Yellow Light (Middle)
	var light_yel := MeshInstance3D.new()
	var cyl_yel := CylinderMesh.new()
	cyl_yel.top_radius = 0.04
	cyl_yel.bottom_radius = 0.04
	cyl_yel.height = 0.08
	cyl_yel.material = _mat_beacon_yellow
	light_yel.mesh = cyl_yel
	light_yel.position = Vector3(0.2, gantry_h + 0.28, -(width * 0.5) + 0.05)
	root.add_child(light_yel)

	# Green Light (Bottom, Active by default)
	var light_grn := MeshInstance3D.new()
	var cyl_grn := CylinderMesh.new()
	cyl_grn.top_radius = 0.04
	cyl_grn.bottom_radius = 0.04
	cyl_grn.height = 0.08
	cyl_grn.material = _mat_beacon_green
	light_grn.mesh = cyl_grn
	light_grn.position = Vector3(0.2, gantry_h + 0.20, -(width * 0.5) + 0.05)
	root.add_child(light_grn)

static func _build_queue(root: Node3D, elem: SceneTypes.SceneElement) -> void:
	var dims := _get_dims(elem, Vector3(4.0, 2.0, 0.8))
	var length: float = dims.x
	var width: float = dims.y
	var height: float = dims.z

	# 1. Elevated Accumulation Roller Bed
	var roller_bed := BoxMesh.new()
	roller_bed.size = Vector3(length, 0.12, width)
	roller_bed.material = _mat_table
	var bed_inst := MeshInstance3D.new()
	bed_inst.mesh = roller_bed
	bed_inst.position = Vector3(length * 0.5, height, 0)
	root.add_child(bed_inst)

	# 2. Support Legs
	for dx in [0.2, length - 0.2]:
		for dz in [-(width * 0.5) + 0.1, (width * 0.5) - 0.1]:
			var leg := MeshInstance3D.new()
			var lm := BoxMesh.new()
			lm.size = Vector3(0.08, height, 0.08)
			lm.material = _mat_steel
			leg.mesh = lm
			leg.position = Vector3(dx, height * 0.5, dz)
			root.add_child(leg)

	# 3. Floor Hazard Staging Pad
	var pad := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(length + 0.6, 0.01, width + 0.6)
	pm.material = _mat_floor_stripe
	pad.mesh = pm
	pad.position = Vector3(length * 0.5, 0.005, 0)
	root.add_child(pad)

static func _build_source(root: Node3D, elem: SceneTypes.SceneElement) -> void:
	var dims := get_dims(elem, Vector3(2.5, 2.0, 2.0))
	var length: float = dims.x
	var width: float = dims.y
	var total_h: float = max(dims.z, 1.8)
	var stand_h: float = 0.9

	# 1. Base Support Stand (4 legs with leveling feet)
	for dx in [0.15, length - 0.15]:
		for dz in [-(width * 0.5) + 0.15, (width * 0.5) - 0.15]:
			var leg := MeshInstance3D.new()
			var lm := BoxMesh.new()
			lm.size = Vector3(0.08, stand_h, 0.08)
			lm.material = _mat_steel
			leg.mesh = lm
			leg.position = Vector3(dx, stand_h * 0.5, dz)
			root.add_child(leg)

	# 2. Infeed Bulk Hopper Funnel / Upper Bin (Powder-coat Green)
	var hopper_mesh := BoxMesh.new()
	var hopper_h: float = total_h - stand_h
	hopper_mesh.size = Vector3(length * 0.9, hopper_h, width * 0.9)
	hopper_mesh.material = _mat_source_accent
	var hopper_inst := MeshInstance3D.new()
	hopper_inst.mesh = hopper_mesh
	hopper_inst.position = Vector3(length * 0.5, stand_h + hopper_h * 0.5, 0)
	root.add_child(hopper_inst)

	# 3. Sloped Discharge Chute at infeed outlet (feeding forward into line)
	var chute_mesh := BoxMesh.new()
	chute_mesh.size = Vector3(length * 0.4, 0.06, width * 0.6)
	chute_mesh.material = _mat_table
	var chute_inst := MeshInstance3D.new()
	chute_inst.mesh = chute_mesh
	chute_inst.position = Vector3(length * 0.85, stand_h + 0.1, 0)
	chute_inst.rotation.z = -0.3 # tilted down towards conveyor
	root.add_child(chute_inst)

	# 4. Status Beacon Light on Hopper Top
	var beacon_base := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.04
	bm.bottom_radius = 0.04
	bm.height = 0.12
	bm.material = _mat_steel
	beacon_base.mesh = bm
	beacon_base.position = Vector3(0.25, total_h + 0.06, -(width * 0.5) + 0.25)
	root.add_child(beacon_base)

	var beacon_lamp := MeshInstance3D.new()
	var lm := CylinderMesh.new()
	lm.top_radius = 0.04
	lm.bottom_radius = 0.04
	lm.height = 0.1
	lm.material = _mat_beacon_green
	beacon_lamp.mesh = lm
	beacon_lamp.position = Vector3(0.25, total_h + 0.17, -(width * 0.5) + 0.25)
	root.add_child(beacon_lamp)

static func _build_sink(root: Node3D, elem: SceneTypes.SceneElement) -> void:
	var dims := get_dims(elem, Vector3(2.5, 2.0, 1.2))
	var length: float = dims.x
	var width: float = dims.y
	var bin_h: float = max(dims.z, 1.0)

	# 1. Floor Hazard Staging Pad
	var pad := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(length + 0.4, 0.01, width + 0.4)
	pm.material = _mat_floor_stripe
	pad.mesh = pm
	pad.position = Vector3(length * 0.5, 0.005, 0)
	root.add_child(pad)

	# 2. Deep Industrial Collection Bin (Purple Body)
	var bin_mesh := BoxMesh.new()
	bin_mesh.size = Vector3(length * 0.9, bin_h * 0.85, width * 0.9)
	bin_mesh.material = _mat_sink_accent
	var bin_inst := MeshInstance3D.new()
	bin_inst.mesh = bin_mesh
	bin_inst.position = Vector3(length * 0.5, bin_h * 0.85 * 0.5, 0)
	root.add_child(bin_inst)

	# 3. Steel Rim & Bumper Guard Rails
	var rim_mesh := BoxMesh.new()
	rim_mesh.size = Vector3(length * 0.95, 0.06, width * 0.95)
	rim_mesh.material = _mat_steel
	var rim_inst := MeshInstance3D.new()
	rim_inst.mesh = rim_mesh
	rim_inst.position = Vector3(length * 0.5, bin_h * 0.85, 0)
	root.add_child(rim_inst)

static func _build_generic_box(root: Node3D, elem: SceneTypes.SceneElement) -> void:
	var dims := get_dims(elem, Vector3(2.0, 1.5, 1.0))
	var mesh := BoxMesh.new()
	mesh.size = Vector3(dims.x, dims.z, dims.y)
	mesh.material = _mat_steel
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.position = Vector3(dims.x * 0.5, dims.z * 0.5, 0)
	root.add_child(inst)

static func get_dims(elem: SceneTypes.SceneElement, default_v: Vector3) -> Vector3:
	if elem != null and elem.geometry.has("dimensions"):
		var d = elem.geometry["dimensions"]
		if d is Array and d.size() >= 3:
			return Vector3(float(d[0]), float(d[1]), float(d[2]))
	return default_v

static func _get_dims(elem: SceneTypes.SceneElement, default_v: Vector3) -> Vector3:
	return get_dims(elem, default_v)

# ============================================================================
# Crowd & Hybrid 3D Procedural Primitives
# ============================================================================

static func _build_crowd_spawner(root: Node3D, elem: SceneTypes.SceneElement) -> void:
	var dims := get_dims(elem, Vector3(2.0, 4.0, 2.0))
	var length: float = dims.x
	var width: float = dims.y
	var height: float = dims.z

	# 1. Floor Ingress Zone Decal
	var floor_pad := MeshInstance3D.new()
	var f_mesh := BoxMesh.new()
	f_mesh.size = Vector3(length, 0.02, width)
	f_mesh.material = _mat_spawner
	floor_pad.mesh = f_mesh
	floor_pad.position = Vector3(length * 0.5, 0.01, 0)
	root.add_child(floor_pad)

	# 2. Translucent Volumetric Emitter Frame
	var vol := MeshInstance3D.new()
	var v_mesh := BoxMesh.new()
	v_mesh.size = Vector3(length * 0.95, height * 0.8, width * 0.95)
	v_mesh.material = _mat_spawner
	vol.mesh = v_mesh
	vol.position = Vector3(length * 0.5, height * 0.4, 0)
	root.add_child(vol)

	# 3. Corner Emitter Posts
	for cx in [0.05, length - 0.05]:
		for cz in [-width * 0.5 + 0.05, width * 0.5 - 0.05]:
			var post := MeshInstance3D.new()
			var p_mesh := CylinderMesh.new()
			p_mesh.top_radius = 0.04
			p_mesh.bottom_radius = 0.04
			p_mesh.height = height
			p_mesh.material = _mat_steel
			post.mesh = p_mesh
			post.position = Vector3(cx, height * 0.5, cz)
			root.add_child(post)

static func _build_exit_goal(root: Node3D, elem: SceneTypes.SceneElement) -> void:
	var dims := get_dims(elem, Vector3(1.0, 2.0, 2.4))
	var length: float = dims.x
	var width: float = dims.y
	var height: float = dims.z

	# 1. Doorway Frame (Steel Columns & Top Header)
	var col_l := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(length, height, 0.15)
	cm.material = _mat_steel
	col_l.mesh = cm
	col_l.position = Vector3(length * 0.5, height * 0.5, -width * 0.5)
	root.add_child(col_l)

	var col_r := MeshInstance3D.new()
	col_r.mesh = cm
	col_r.position = Vector3(length * 0.5, height * 0.5, width * 0.5)
	root.add_child(col_r)

	var header := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(length, 0.2, width + 0.15)
	hm.material = _mat_steel
	header.mesh = hm
	header.position = Vector3(length * 0.5, height - 0.1, 0)
	root.add_child(header)

	# 2. Glowing Exit Sign
	var sign_mesh := BoxMesh.new()
	sign_mesh.size = Vector3(0.08, 0.25, 0.8)
	sign_mesh.material = _mat_exit
	var sign_inst := MeshInstance3D.new()
	sign_inst.mesh = sign_mesh
	sign_inst.position = Vector3(length * 0.5, height + 0.15, 0)
	root.add_child(sign_inst)

	# 3. Floor Egress Threshold Pad
	var thresh := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(length, 0.02, width)
	tm.material = _mat_floor_stripe
	thresh.mesh = tm
	thresh.position = Vector3(length * 0.5, 0.01, 0)
	root.add_child(thresh)

static func _build_hybrid_portal(root: Node3D, elem: SceneTypes.SceneElement) -> void:
	var dims := get_dims(elem, Vector3(1.0, 2.5, 2.2))
	var length: float = dims.x
	var width: float = dims.y
	var height: float = dims.z

	# 1. Base Mounting Plate
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(length, 0.04, width)
	bm.material = _mat_steel
	base.mesh = bm
	base.position = Vector3(length * 0.5, 0.02, 0)
	root.add_child(base)

	# 2. Turnstile Pedestals (Left & Right Stainless Cabinets)
	var cab_mesh := BoxMesh.new()
	cab_mesh.size = Vector3(length * 0.8, 1.0, 0.25)
	cab_mesh.material = _mat_table

	var cab_l := MeshInstance3D.new()
	cab_l.mesh = cab_mesh
	cab_l.position = Vector3(length * 0.5, 0.5, -width * 0.35)
	root.add_child(cab_l)

	var cab_r := MeshInstance3D.new()
	cab_r.mesh = cab_mesh
	cab_r.position = Vector3(length * 0.5, 0.5, width * 0.35)
	root.add_child(cab_r)

	# 3. Optical Glass Swinging Barrier
	var glass_mesh := BoxMesh.new()
	glass_mesh.size = Vector3(0.04, 0.8, width * 0.45)
	glass_mesh.material = _mat_portal_glass
	var glass := MeshInstance3D.new()
	glass.mesh = glass_mesh
	glass.position = Vector3(length * 0.5, 0.5, 0)
	root.add_child(glass)

	# 4. Overhead Scanner & Beacon Arch
	var gantry_post := MeshInstance3D.new()
	var gm := CylinderMesh.new()
	gm.top_radius = 0.03
	gm.bottom_radius = 0.03
	gm.height = height
	gm.material = _mat_steel
	gantry_post.mesh = gm
	gantry_post.position = Vector3(length * 0.5, height * 0.5, -width * 0.45)
	root.add_child(gantry_post)

	var beacon := MeshInstance3D.new()
	var b_mesh := SphereMesh.new()
	b_mesh.radius = 0.08
	b_mesh.height = 0.16
	b_mesh.material = _mat_beacon_green
	beacon.mesh = b_mesh
	beacon.position = Vector3(length * 0.5, height, -width * 0.45)
	root.add_child(beacon)

static func _build_obstacle_wall(root: Node3D, elem: SceneTypes.SceneElement) -> void:
	var dims := get_dims(elem, Vector3(0.4, 6.0, 2.8))
	var length: float = dims.x
	var width: float = dims.y
	var height: float = dims.z

	# Main Wall
	var wall := MeshInstance3D.new()
	var wm := BoxMesh.new()
	wm.size = Vector3(length, height, width)
	wm.material = _mat_wall
	wall.mesh = wm
	wall.position = Vector3(length * 0.5, height * 0.5, 0)
	root.add_child(wall)

	# Base Kickplate
	var trim := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(length + 0.04, 0.12, width + 0.04)
	tm.material = _mat_steel
	trim.mesh = tm
	trim.position = Vector3(length * 0.5, 0.06, 0)
	root.add_child(trim)

static func _build_walkable_room(root: Node3D, elem: SceneTypes.SceneElement) -> void:
	var dims := get_dims(elem, Vector3(10.0, 10.0, 2.8))
	var length: float = dims.x
	var width: float = dims.y

	# Floor Slab Tile
	var floor_tile := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(length, 0.02, width)
	fm.material = _mat_room_floor
	floor_tile.mesh = fm
	floor_tile.position = Vector3(length * 0.5, 0.01, 0)
	root.add_child(floor_tile)

# ============================================================================
# Procedural Agent Meshes (LOD 0 Mannequin & LOD 1 Capsule)
# ============================================================================

static func create_agent_mannequin_node(color: Color = Color("#3498db")) -> Node3D:
	var agent_root := Node3D.new()
	agent_root.name = "AgentMannequin"

	var skin_mat := StandardMaterial3D.new()
	skin_mat.albedo_color = color
	skin_mat.roughness = 0.4
	skin_mat.metallic = 0.1

	# Torso (Capsule)
	var torso := MeshInstance3D.new()
	var tm := CapsuleMesh.new()
	tm.radius = 0.18
	tm.height = 0.95
	tm.material = skin_mat
	torso.mesh = tm
	torso.position = Vector3(0, 0.95, 0)
	agent_root.add_child(torso)

	# Head (Sphere)
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.13
	hm.height = 0.26
	head.mesh = hm
	head.position = Vector3(0, 1.55, 0)
	agent_root.add_child(head)

	# Directional Visor (Forward heading indicator)
	var visor := MeshInstance3D.new()
	var vm := BoxMesh.new()
	vm.size = Vector3(0.08, 0.06, 0.16)
	var v_mat := StandardMaterial3D.new()
	v_mat.albedo_color = Color("#111827")
	visor.mesh = vm
	visor.material_override = v_mat
	visor.position = Vector3(0.12, 1.55, 0) # X forward
	agent_root.add_child(visor)

	# Floor Contact Shadow Disc
	var shadow := MeshInstance3D.new()
	var sm := CylinderMesh.new()
	sm.top_radius = 0.25
	sm.bottom_radius = 0.25
	sm.height = 0.005
	var sh_mat := StandardMaterial3D.new()
	sh_mat.albedo_color = Color(0.05, 0.08, 0.12, 0.5)
	sh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow.mesh = sm
	shadow.material_override = sh_mat
	shadow.position = Vector3(0, 0.003, 0)
	agent_root.add_child(shadow)

	return agent_root

static func create_agent_capsule_mesh() -> CapsuleMesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.20
	mesh.height = 1.70
	return mesh


