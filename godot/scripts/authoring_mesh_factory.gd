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

