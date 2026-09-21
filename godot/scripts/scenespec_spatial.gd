# ============================================================================
# SimVizSpatialResolver (Phase 7D-04)
#
# Spatial layout resolution, continuous 3D coordinate frame transformations,
# multi-level floor slicing, and binary Structure-of-Arrays (SoA) decoding.
# ============================================================================
class_name SimVizSpatialResolver extends RefCounted

const SceneTypes = preload("res://scripts/scenespec_types.gd")

# ─────────────────────────────────────────────────────────────────────────────
# 1. Transform Composition
# ─────────────────────────────────────────────────────────────────────────────

"""
Composes a parent world/compound transform with a child local transform:
T_world = T_parent ∘ T_child
Applies parent scale and Z-yaw rotation to child relative translation.
"""
static func compose_transforms(
	parent: SceneTypes.SceneTransform,
	child: SceneTypes.SceneTransform
) -> SceneTypes.SceneTransform:
	if parent == null and child == null:
		return SceneTypes.SceneTransform.new()
	if parent == null:
		return child.clone()
	if child == null:
		return parent.clone()

	var yaw_rad: float = deg_to_rad(parent.rotation.z)
	var c: float = cos(yaw_rad)
	var s: float = sin(yaw_rad)

	var scaled_cx: float = parent.scale.x * child.position.x
	var scaled_cy: float = parent.scale.y * child.position.y
	var scaled_cz: float = parent.scale.z * child.position.z

	var rot_cx: float = c * scaled_cx - s * scaled_cy
	var rot_cy: float = s * scaled_cx + c * scaled_cy
	var rot_cz: float = scaled_cz

	var out_pos := Vector3(
		parent.position.x + rot_cx,
		parent.position.y + rot_cy,
		parent.position.z + rot_cz
	)
	var out_rot := Vector3(
		parent.rotation.x + child.rotation.x,
		parent.rotation.y + child.rotation.y,
		parent.rotation.z + child.rotation.z
	)
	var out_scale := Vector3(
		parent.scale.x * child.scale.x,
		parent.scale.y * child.scale.y,
		parent.scale.z * child.scale.z
	)

	return SceneTypes.SceneTransform.new(out_pos, out_rot, out_scale)

# ─────────────────────────────────────────────────────────────────────────────
# 2. Coordinate System Mapping (Canonical Z-Up <-> Godot 3D)
# ─────────────────────────────────────────────────────────────────────────────

"""
Converts canonical right-handed Z-up coordinates (X=East, Y=North, Z=Up)
into Godot 3D coordinates (X=Right, Y=Up, Z=Back/-North).
"""
static func zup_to_godot_position(pos: Vector3) -> Vector3:
	return Vector3(pos.x, pos.z, -pos.y)

"""
Converts Godot 3D coordinates (X=Right, Y=Up, Z=Back)
back into canonical right-handed Z-up coordinates (X=East, Y=North, Z=Up).
"""
static func godot_to_zup_position(pos: Vector3) -> Vector3:
	return Vector3(pos.x, -pos.z, pos.y)

"""
Constructs a full Godot Transform3D from canonical Z-up position, Euler rotation, and scale.
"""
static func zup_to_godot_transform(pos: Vector3, rot: Vector3, scl: Vector3) -> Transform3D:
	var g_pos: Vector3 = zup_to_godot_position(pos)
	# Euler angles in degrees: rot.z in Z-up corresponds to Y-rotation in Godot
	var t := Transform3D.IDENTITY
	t = t.scaled(Vector3(scl.x, scl.z, scl.y))
	t = t.rotated(Vector3.UP, -deg_to_rad(rot.z))
	t = t.rotated(Vector3.RIGHT, deg_to_rad(rot.x))
	t = t.rotated(Vector3.FORWARD, deg_to_rad(rot.y))
	t.origin = g_pos
	return t

# ─────────────────────────────────────────────────────────────────────────────
# 3. Multi-Level Elevation & Vertical Connectors
# ─────────────────────────────────────────────────────────────────────────────

"""
Resolves the absolute world elevation (Z in meters) for an element.
If bound to a recognized spatial level, level elevation is factored in.
"""
static func resolve_absolute_elevation(elem: SceneTypes.SceneElement, doc: SceneTypes.SceneDocument) -> float:
	var base_z: float = elem.transform.position.z if elem.transform != null else 0.0
	if doc.spatial.has("levels") and doc.spatial["levels"] is Array:
		for lvl in doc.spatial["levels"]:
			if lvl is Dictionary and str(lvl.get("id", "")) == elem.level_id:
				return float(lvl.get("elevation", 0.0)) + base_z
	return base_z

"""
Filters and returns elements belonging to a specific floor/level ID.
"""
static func get_elements_for_level(doc: SceneTypes.SceneDocument, level_id: String) -> Array:
	var res: Array = []
	for e in doc.elements:
		if e is SceneTypes.SceneElement and e.level_id == level_id:
			res.append(e)
	return res

"""
Resolves vertical extent metadata for ramps, staircases, and elevators.
"""
static func resolve_vertical_connector(elem: SceneTypes.SceneElement, doc: SceneTypes.SceneDocument) -> Dictionary:
	if elem.vertical_extent == null or not (elem.vertical_extent is Dictionary):
		return { "is_connector": false }

	var ve: Dictionary = elem.vertical_extent
	var src_id: String = str(ve.get("source_level_id", ""))
	var tgt_id: String = str(ve.get("target_level_id", ""))
	var height: float = float(ve.get("height", 0.0))

	var levels_map: Dictionary = {}
	if doc.spatial.has("levels") and doc.spatial["levels"] is Array:
		for lvl in doc.spatial["levels"]:
			if lvl is Dictionary and lvl.has("id"):
				levels_map[str(lvl["id"])] = float(lvl.get("elevation", 0.0))

	var has_levels: bool = levels_map.has(src_id) and levels_map.has(tgt_id)
	var spans: bool = false
	if has_levels:
		var src_elev: float = levels_map[src_id]
		var tgt_elev: float = levels_map[tgt_id]
		var min_elev: float = min(src_elev, tgt_elev)
		var max_elev: float = max(src_elev, tgt_elev)
		var elem_z: float = elem.transform.position.z if elem.transform != null else 0.0
		spans = (elem_z <= min_elev + 0.001) and (elem_z + height >= max_elev - 0.001)

	return {
		"is_connector": true,
		"source_level_id": src_id,
		"target_level_id": tgt_id,
		"height": height,
		"valid_levels": has_levels,
		"spans_levels": spans
	}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Direct Binary SoA Decoding (PackedByteArray)
# ─────────────────────────────────────────────────────────────────────────────

"""
Direct memory blitting decoder for Julia's `SpatialBufferSoA`.
Bypasses JSON/MessagePack decoding entirely.
Format:
- Int32 count (4 bytes)
- 3*N Float32 positions (12*N bytes)
- 3*N Float32 rotations (12*N bytes)
- 3*N Float32 scales (12*N bytes)
- N Int32 level_indices (4*N bytes)
"""
static func decode_spatial_soa_bytes(raw_bytes: PackedByteArray) -> Dictionary:
	if raw_bytes.size() < 4:
		return { "count": 0, "positions": PackedFloat32Array(), "rotations": PackedFloat32Array(), "scales": PackedFloat32Array(), "level_indices": PackedInt32Array() }

	var sp := StreamPeerBuffer.new()
	sp.data_array = raw_bytes

	var count: int = sp.get_32()
	var expected_size: int = 4 + (3 * count * 4) + (3 * count * 4) + (3 * count * 4) + (count * 4)
	if raw_bytes.size() < expected_size:
		return { "count": 0, "error": "Buffer underflow: expected %d bytes, got %d" % [expected_size, raw_bytes.size()] }

	var positions := PackedFloat32Array()
	positions.resize(3 * count)
	for i in range(3 * count):
		positions[i] = sp.get_float()

	var rotations := PackedFloat32Array()
	rotations.resize(3 * count)
	for i in range(3 * count):
		rotations[i] = sp.get_float()

	var scales := PackedFloat32Array()
	scales.resize(3 * count)
	for i in range(3 * count):
		scales[i] = sp.get_float()

	var level_indices := PackedInt32Array()
	level_indices.resize(count)
	for i in range(count):
		level_indices[i] = sp.get_32()

	return {
		"count": count,
		"positions": positions,
		"rotations": rotations,
		"scales": scales,
		"level_indices": level_indices
	}

