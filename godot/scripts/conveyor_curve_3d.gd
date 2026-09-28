# conveyor_curve_3d.gd
# General 3D/2D Parametric Conveyor Curve & Network Junction Alignment Engine for Godot 4.
# Mirrors packages/GodotBridge/src/compiler/conveyor_curve.jl:
#   Layer 1: 8 Extensible Shape Presets (straight, s_curve, l_bend, u_turn, circular_arc,
#            serpentine, spiral_helix, custom_spline) + Network Junction C¹ Pose Resolver
#   Layer 2: Piecewise Cubic Bézier Control Points & Uniform Arc-Length Table Baking
#   Layer 3: World-Space 3D & 2D Curve Samplers for 3D Mesh Extrusion, 2D Canvas Track,
#            and Window 2 Topology Schematic.
class_name SimVizConveyorCurve3D
extends RefCounted

const PRESET_IDS := [
	"straight",
	"s_curve",
	"l_bend",
	"u_turn",
	"circular_arc",
	"serpentine",
	"spiral_helix",
	"custom_spline"
]

const PRESET_LABELS := {
	"straight": "Straight Belt",
	"s_curve": "Smooth S-Curve Connector",
	"l_bend": "90° / Angled Elbow (L-Bend)",
	"u_turn": "180° Return Loop (U-Turn)",
	"circular_arc": "Curved Roller Section (Arc)",
	"serpentine": "Serpentine Switchback Buffer",
	"spiral_helix": "3D Spiral Elevator (Helix)",
	"custom_spline": "Custom Control-Point Spline"
}

static func _bezier_arc_kappa(sweep_rad: float) -> float:
	return (4.0 / 3.0) * tan(sweep_rad * 0.25)

static func _norm3(v: Vector3, fallback: Vector3 = Vector3(1.0, 0.0, 0.0)) -> Vector3:
	var l := v.length()
	return (v / l) if l > 1e-6 else fallback

static func eval_cubic_bezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, u: float) -> Dictionary:
	var om: float = 1.0 - u
	var om2: float = om * om
	var u2: float = u * u
	var b0: float = om2 * om
	var b1: float = 3.0 * om2 * u
	var b2: float = 3.0 * om * u2
	var b3: float = u2 * u

	var pos: Vector3 = p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3
	var d01: Vector3 = p1 - p0
	var d12: Vector3 = p2 - p1
	var d23: Vector3 = p3 - p2
	var deriv: Vector3 = d01 * (3.0 * om2) + d12 * (6.0 * om * u) + d23 * (3.0 * u2)
	return {"pos": pos, "deriv": deriv}

static func bake_control_points(preset: String, cpts: Array, num_samples: int = 48) -> Dictionary:
	if cpts.is_empty():
		cpts = [
			{"pos": Vector3.ZERO, "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO},
			{"pos": Vector3(6.0, 0.0, 0.0), "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO}
		]
	elif cpts.size() == 1:
		var p0: Vector3 = cpts[0]["pos"]
		cpts = [
			cpts[0],
			{"pos": p0 + Vector3(6.0, 0.0, 0.0), "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO}
		]

	var n_segs: int = cpts.size() - 1
	var sub_per_seg: int = maxi(16, int(ceil(float(num_samples * 2) / float(n_segs))))

	var raw_s: PackedFloat64Array = []
	var raw_p: PackedVector3Array = []
	var raw_t: PackedVector3Array = []

	var cum_s: float = 0.0
	var prev_p: Vector3 = cpts[0]["pos"]

	for seg in range(n_segs):
		var cp0: Dictionary = cpts[seg]
		var cp1: Dictionary = cpts[seg + 1]
		var p0: Vector3 = cp0["pos"]
		var p1: Vector3 = p0 + (cp0.get("out_handle", Vector3.ZERO) as Vector3)
		var p3: Vector3 = cp1["pos"]
		var p2: Vector3 = p3 + (cp1.get("in_handle", Vector3.ZERO) as Vector3)
		var chord_dir := _norm3(p3 - p0, Vector3(1.0, 0.0, 0.0))

		var j_start: int = 0 if seg == 0 else 1
		for j in range(j_start, sub_per_seg + 1):
			var u: float = float(j) / float(sub_per_seg)
			var ev := eval_cubic_bezier(p0, p1, p2, p3, u)
			var pos: Vector3 = ev["pos"]
			var tan_v: Vector3 = _norm3(ev["deriv"], chord_dir)
			if raw_p.size() > 0:
				cum_s += prev_p.distance_to(pos)
			raw_s.append(cum_s)
			raw_p.append(pos)
			raw_t.append(tan_v)
			prev_p = pos

	var total_len: float = maxf(0.001, cum_s)
	var N: int = maxi(8, num_samples)
	var total_raw: int = raw_p.size()

	var points: PackedVector3Array = []
	var tangents: PackedVector3Array = []
	var arc_lengths: PackedFloat64Array = []

	var cursor: int = 0
	for k in range(N + 1):
		var target_s: float = (float(k) / float(N)) * cum_s
		while cursor < total_raw - 2 and raw_s[cursor + 1] < target_s:
			cursor += 1
		var s0: float = raw_s[cursor]
		var s1: float = raw_s[mini(total_raw - 1, cursor + 1)]
		var alpha: float = clampf((target_s - s0) / (s1 - s0), 0.0, 1.0) if (s1 > s0 + 1e-6) else 0.0
		var p_interp := raw_p[cursor].lerp(raw_p[mini(total_raw - 1, cursor + 1)], alpha)
		var t_interp := _norm3(raw_t[cursor].lerp(raw_t[mini(total_raw - 1, cursor + 1)], alpha), raw_t[cursor])
		points.append(p_interp)
		tangents.append(t_interp)
		arc_lengths.append(target_s)

	var mid_idx: int = N / 2
	return {
		"preset": preset,
		"points": points,
		"tangents": tangents,
		"arc_lengths": arc_lengths,
		"total_length": total_len,
		"inlet_pos": points[0],
		"outlet_pos": points[points.size() - 1],
		"inlet_tan": tangents[0],
		"outlet_tan": tangents[tangents.size() - 1],
		"midpoint": points[mid_idx],
		"mid_tangent": tangents[mid_idx],
		"control_points": cpts
	}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 1: Preset Generators
# ─────────────────────────────────────────────────────────────────────────────

static func generate_control_points(preset: String, inlet_pos: Vector3, inlet_tan: Vector3, outlet_pos: Vector3, outlet_tan: Vector3, params: Dictionary) -> Array:
	var p := preset.strip_edges().to_lower()
	match p:
		"s_curve":
			return _gen_s_curve(inlet_pos, inlet_tan, outlet_pos, outlet_tan, params)
		"l_bend":
			return _gen_l_bend(inlet_pos, inlet_tan, outlet_pos, outlet_tan, params)
		"u_turn":
			return _gen_u_turn(inlet_pos, inlet_tan, outlet_pos, outlet_tan, params)
		"circular_arc":
			return _gen_circular_arc(inlet_pos, inlet_tan, outlet_pos, outlet_tan, params)
		"serpentine":
			return _gen_serpentine(inlet_pos, inlet_tan, outlet_pos, outlet_tan, params)
		"spiral_helix":
			return _gen_spiral_helix(inlet_pos, inlet_tan, outlet_pos, outlet_tan, params)
		"custom_spline":
			return _gen_custom_spline(inlet_pos, inlet_tan, outlet_pos, outlet_tan, params)
		_:
			return _gen_straight(inlet_pos, outlet_pos)

static func _gen_straight(inlet_pos: Vector3, outlet_pos: Vector3) -> Array:
	return [
		{"pos": inlet_pos, "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO},
		{"pos": outlet_pos, "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO}
	]

static func _gen_s_curve(inlet_pos: Vector3, inlet_tan: Vector3, outlet_pos: Vector3, outlet_tan: Vector3, params: Dictionary) -> Array:
	var t_in := _norm3(inlet_tan)
	var t_out := _norm3(outlet_tan)
	var chord := outlet_pos - inlet_pos
	var cross_z: float = absf(chord.x * t_in.y - chord.y * t_in.x)
	if not bool(params.get("auto_join", false)) and cross_z < 0.05 and t_in.dot(t_out) > 0.99:
		var lat_off: float = float(params.get("lateral_offset", 2.4))
		var n_in := Vector3(-t_in.y, t_in.x, 0.0)
		outlet_pos = outlet_pos + n_in * lat_off
	var dist: float = inlet_pos.distance_to(outlet_pos)
	var t_scale: float = float(params.get("tangent_scale", 0.42))
	var hlen: float = maxf(0.4, dist * t_scale)
	return [
		{"pos": inlet_pos, "in_handle": Vector3.ZERO, "out_handle": t_in * hlen},
		{"pos": outlet_pos, "in_handle": -t_out * hlen, "out_handle": Vector3.ZERO}
	]

static func _gen_l_bend(inlet_pos: Vector3, inlet_tan: Vector3, outlet_pos: Vector3, outlet_tan: Vector3, params: Dictionary) -> Array:
	var R: float = maxf(0.3, float(params.get("bend_radius", 2.5)))
	var t_in := _norm3(inlet_tan)
	var t_out := _norm3(outlet_tan)

	var corner := Vector3.ZERO
	var has_corner := false
	if params.has("corner_pos") and params["corner_pos"] is Array and (params["corner_pos"] as Array).size() >= 3:
		var cp: Array = params["corner_pos"]
		corner = Vector3(float(cp[0]), float(cp[1]), float(cp[2]))
		has_corner = true
	else:
		var det: float = t_in.x * (-t_out.y) - t_in.y * (-t_out.x)
		var dx: float = outlet_pos.x - inlet_pos.x
		var dy: float = outlet_pos.y - inlet_pos.y
		if absf(det) > 1e-3:
			var s: float = (dx * (-t_out.y) - dy * (-t_out.x)) / det
			if s > 0.1:
				corner = Vector3(inlet_pos.x + s * t_in.x, inlet_pos.y + s * t_in.y, 0.5 * (inlet_pos.z + outlet_pos.z))
				has_corner = true
		if not has_corner:
			# Default 90-degree elbow using bend_angle_deg if outlet_pos was along straight line
			var ang_deg: float = float(params.get("bend_angle_deg", 90.0))
			var ang_rad: float = deg_to_rad(ang_deg)
			var span: float = maxf(4.0, inlet_pos.distance_to(outlet_pos))
			var half_span: float = span * 0.5
			corner = inlet_pos + t_in * half_span
			var turned_dir := Vector3(
				t_in.x * cos(ang_rad) - t_in.y * sin(ang_rad),
				t_in.x * sin(ang_rad) + t_in.y * cos(ang_rad),
				0.0
			)
			outlet_pos = corner + turned_dir * half_span
			t_out = turned_dir

	var v1: Vector3 = corner - inlet_pos
	var v2: Vector3 = outlet_pos - corner
	var L1: float = v1.length()
	var L2: float = v2.length()
	if L1 < 1e-3 or L2 < 1e-3:
		return _gen_s_curve(inlet_pos, t_in, outlet_pos, t_out, params)

	var u1: Vector3 = v1 / L1
	var u2: Vector3 = v2 / L2
	var cos_th: float = clampf(u1.dot(u2), -0.995, 0.995)
	var theta: float = acos(cos_th)
	if theta < 0.05:
		return _gen_straight(inlet_pos, outlet_pos)

	var tan_half: float = tan(theta * 0.5)
	var max_trim: float = 0.999 * minf(L1, L2)
	var d_trim: float = minf(R * tan_half, max_trim)
	var r_eff: float = d_trim / maxf(1e-4, tan_half)

	var b_start: Vector3 = corner - u1 * d_trim
	var b_end: Vector3 = corner + u2 * d_trim
	var hlen: float = r_eff * _bezier_arc_kappa(theta)

	var cpts: Array = []
	if inlet_pos.distance_to(b_start) > 0.05:
		cpts.append({"pos": inlet_pos, "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO})
	else:
		b_start = inlet_pos
	cpts.append({"pos": b_start, "in_handle": Vector3.ZERO, "out_handle": u1 * hlen})
	if b_end.distance_to(outlet_pos) > 0.05:
		cpts.append({"pos": b_end, "in_handle": -u2 * hlen, "out_handle": Vector3.ZERO})
		cpts.append({"pos": outlet_pos, "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO})
	else:
		cpts.append({"pos": outlet_pos, "in_handle": -u2 * hlen, "out_handle": Vector3.ZERO})
	return cpts

static func _gen_u_turn(inlet_pos: Vector3, inlet_tan: Vector3, outlet_pos: Vector3, _outlet_tan: Vector3, params: Dictionary) -> Array:
	var R: float = maxf(0.5, float(params.get("bend_radius", 2.0)))
	var leg_len: float = maxf(1.5, float(params.get("leg_length", maxf(3.0, inlet_pos.distance_to(outlet_pos) * 0.5))))
	var dir := _norm3(Vector3(inlet_tan.x, inlet_tan.y, 0.0))
	var perp := Vector3(-dir.y, dir.x, 0.0)

	var p0 := inlet_pos
	var p1 := p0 + dir * leg_len
	var apex := p1 + dir * R + perp * R
	var p2 := p1 + perp * (2.0 * R)
	var p3 := p0 + perp * (2.0 * R)
	var k90: float = R * _bezier_arc_kappa(0.5 * PI)

	return [
		{"pos": p0, "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO},
		{"pos": p1, "in_handle": Vector3.ZERO, "out_handle": dir * k90},
		{"pos": apex, "in_handle": -perp * k90, "out_handle": perp * k90},
		{"pos": p2, "in_handle": dir * k90, "out_handle": Vector3.ZERO},
		{"pos": p3, "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO}
	]

static func _gen_circular_arc(inlet_pos: Vector3, inlet_tan: Vector3, outlet_pos: Vector3, _outlet_tan: Vector3, params: Dictionary) -> Array:
	var R: float = maxf(0.5, float(params.get("bend_radius", 4.0)))
	var sweep_deg: float = float(params.get("sweep_angle_deg", 90.0))
	var sweep_rad: float = deg_to_rad(clampf(sweep_deg, -350.0, 350.0))
	if absf(sweep_rad) < 0.02:
		return _gen_straight(inlet_pos, outlet_pos)

	var sign_s: float = 1.0 if sweep_rad >= 0.0 else -1.0
	var dir := _norm3(Vector3(inlet_tan.x, inlet_tan.y, 0.0))
	var normal_to_center := Vector3(-sign_s * dir.y, sign_s * dir.x, 0.0)
	var center := inlet_pos + normal_to_center * R

	var n_arc_segs: int = maxi(1, int(ceil(absf(sweep_rad) / (0.5 * PI))))
	var d_theta: float = sweep_rad / float(n_arc_segs)
	var hlen: float = R * _bezier_arc_kappa(absf(d_theta))
	var r0: Vector3 = inlet_pos - center
	var dz: float = outlet_pos.z - inlet_pos.z

	var cpts: Array = []
	for i in range(n_arc_segs + 1):
		var ang: float = float(i) * d_theta
		var ca: float = cos(ang)
		var sa: float = sin(ang)
		var rx: float = r0.x * ca - r0.y * sa
		var ry: float = r0.x * sa + r0.y * ca
		var pz: float = inlet_pos.z + (float(i) / float(n_arc_segs)) * dz
		var pt := Vector3(center.x + rx, center.y + ry, pz)
		var tx: float = -sign_s * (ry / R)
		var ty: float =  sign_s * (rx / R)
		var t_vec := _norm3(Vector3(tx, ty, 0.0), dir)
		var in_h := Vector3.ZERO if i == 0 else (-t_vec * hlen)
		var out_h := Vector3.ZERO if i == n_arc_segs else (t_vec * hlen)
		cpts.append({"pos": pt, "in_handle": in_h, "out_handle": out_h})
	return cpts

static func _gen_serpentine(inlet_pos: Vector3, inlet_tan: Vector3, outlet_pos: Vector3, _outlet_tan: Vector3, params: Dictionary) -> Array:
	var passes: int = clampi(int(round(float(params.get("passes", 3)))), 2, 8)
	var pitch: float = maxf(1.2, float(params.get("pass_spacing", 2.0)))
	var R: float = 0.5 * pitch
	var span: float = maxf(3.0, inlet_pos.distance_to(outlet_pos))
	var dir := _norm3(Vector3(inlet_tan.x, inlet_tan.y, 0.0))
	var perp := Vector3(-dir.y, dir.x, 0.0)
	var k180: float = R * 1.333333

	var cpts: Array = []
	for p in range(1, passes + 1):
		var fwd: bool = (p % 2) == 1
		var y_off: float = float(p - 1) * pitch
		var base_start := inlet_pos + perp * y_off
		var base_end := base_start + dir * span
		var s_pt := base_start if fwd else base_end
		var e_pt := base_end if fwd else base_start
		var t_dir := dir if fwd else (-dir)
		var in_h_start := Vector3.ZERO if p == 1 else (-t_dir * k180)
		var out_h_end := Vector3.ZERO if p == passes else (t_dir * k180)
		cpts.append({"pos": s_pt, "in_handle": in_h_start, "out_handle": Vector3.ZERO})
		cpts.append({"pos": e_pt, "in_handle": Vector3.ZERO, "out_handle": out_h_end})
	return cpts

static func _gen_spiral_helix(inlet_pos: Vector3, inlet_tan: Vector3, outlet_pos: Vector3, _outlet_tan: Vector3, params: Dictionary) -> Array:
	var R: float = maxf(1.0, float(params.get("helix_radius", 2.5)))
	var turns: float = clampf(float(params.get("helix_turns", 1.5)), 0.25, 6.0)
	var dz: float = float(params.get("elevation_gain", outlet_pos.z - inlet_pos.z))
	if absf(dz) < 0.1:
		dz = 2.4

	var total_rad: float = turns * TAU
	var n_segs: int = maxi(4, int(ceil(turns * 4.0)))
	var d_theta: float = total_rad / float(n_segs)
	var hlen: float = R * _bezier_arc_kappa(d_theta)

	var dir := _norm3(Vector3(inlet_tan.x, inlet_tan.y, 0.0))
	var normal_to_center := Vector3(-dir.y, dir.x, 0.0)
	var center := inlet_pos + normal_to_center * R
	var r0: Vector3 = inlet_pos - center

	var cpts: Array = []
	for i in range(n_segs + 1):
		var ang: float = float(i) * d_theta
		var ca: float = cos(ang)
		var sa: float = sin(ang)
		var rx: float = r0.x * ca - r0.y * sa
		var ry: float = r0.x * sa + r0.y * ca
		var pz: float = inlet_pos.z + (float(i) / float(n_segs)) * dz
		var pt := Vector3(center.x + rx, center.y + ry, pz)
		var tx: float = -(ry / R)
		var ty: float =  (rx / R)
		var tz: float = dz / (total_rad * R)
		var t_vec := _norm3(Vector3(tx, ty, tz), dir)
		var in_h := Vector3.ZERO if i == 0 else (-t_vec * hlen)
		var out_h := Vector3.ZERO if i == n_segs else (t_vec * hlen)
		cpts.append({"pos": pt, "in_handle": in_h, "out_handle": out_h})
	return cpts

static func _gen_custom_spline(inlet_pos: Vector3, inlet_tan: Vector3, outlet_pos: Vector3, outlet_tan: Vector3, params: Dictionary) -> Array:
	var raw_pts = params.get("control_points", [])
	if not (raw_pts is Array) or (raw_pts as Array).size() < 2:
		return _gen_s_curve(inlet_pos, inlet_tan, outlet_pos, outlet_tan, params)

	var pts: Array[Vector3] = []
	for item in raw_pts:
		if item is Dictionary and item.has("pos") and item["pos"] is Array and (item["pos"] as Array).size() >= 3:
			var p: Array = item["pos"]
			pts.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
		elif item is Array and (item as Array).size() >= 3:
			pts.append(Vector3(float(item[0]), float(item[1]), float(item[2])))
		elif item is Vector3:
			pts.append(item)

	if pts.size() < 2:
		return _gen_s_curve(inlet_pos, inlet_tan, outlet_pos, outlet_tan, params)

	var M: int = pts.size()
	var cpts: Array = []
	for i in range(M):
		var p_prev: Vector3 = pts[maxi(0, i - 1)]
		var p_curr: Vector3 = pts[i]
		var p_next: Vector3 = pts[mini(M - 1, i + 1)]
		var t_dir: Vector3
		if i == 0:
			t_dir = _norm3(p_next - p_curr, inlet_tan)
		elif i == M - 1:
			t_dir = _norm3(p_curr - p_prev, outlet_tan)
		else:
			t_dir = _norm3(p_next - p_prev)
		var d_in: float = 0.33 * p_prev.distance_to(p_curr) if i > 0 else 0.0
		var d_out: float = 0.33 * p_curr.distance_to(p_next) if i < M - 1 else 0.0
		cpts.append({
			"pos": p_curr,
			"in_handle": -t_dir * d_in,
			"out_handle": t_dir * d_out
		})
	return cpts

# ─────────────────────────────────────────────────────────────────────────────
# Layer 3: Element / Document Curve Resolver
# ─────────────────────────────────────────────────────────────────────────────

static func _extract_vec3(v, fallback: Vector3) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	if v is Array and (v as Array).size() == 2:
		return Vector3(float(v[0]), float(v[1]), fallback.z)
	return fallback

static func sample_world_curve(elem_or_dict, doc_or_spec = null, num_samples: int = 48) -> Dictionary:
	var elem_id: String = ""
	var pos := Vector3.ZERO
	var rot_z_deg: float = 0.0
	var dims := Vector3(8.0, 1.2, 0.8)
	var geom: Dictionary = {}
	var props: Dictionary = {}

	if elem_or_dict is Dictionary:
		var d: Dictionary = elem_or_dict
		elem_id = str(d.get("id", ""))
		var tr = d.get("transform", {})
		if tr is Dictionary:
			pos = _extract_vec3(tr.get("position", [0, 0, 0]), Vector3.ZERO)
			var rot_v := _extract_vec3(tr.get("rotation", [0, 0, 0]), Vector3.ZERO)
			rot_z_deg = rot_v.z
		if d.get("geometry") is Dictionary:
			geom = d["geometry"]
			dims = _extract_vec3(geom.get("dimensions", [8.0, 1.2, 0.8]), dims)
		if d.get("properties") is Dictionary:
			props = d["properties"]
	elif elem_or_dict != null:
		elem_id = str(elem_or_dict.id)
		if elem_or_dict.transform != null:
			pos = elem_or_dict.transform.position
			rot_z_deg = elem_or_dict.transform.rotation.z
		if elem_or_dict.geometry is Dictionary:
			geom = elem_or_dict.geometry
			dims = _extract_vec3(geom.get("dimensions", [8.0, 1.2, 0.8]), dims)
		if elem_or_dict.properties is Dictionary:
			props = elem_or_dict.properties

	var preset: String = str(geom.get("shape_preset", props.get("shape_preset", "straight"))).strip_edges().to_lower()
	if not (preset in PRESET_IDS):
		preset = "straight"

	var s_params: Dictionary = {}
	if geom.get("shape_params") is Dictionary:
		s_params = (geom["shape_params"] as Dictionary).duplicate(true)
	for k in ["bend_radius", "bend_angle_deg", "sweep_angle_deg", "passes", "pass_spacing", "helix_radius", "helix_turns", "elevation_gain", "corner_pos", "control_points", "tangent_scale", "leg_length", "auto_join", "lateral_offset"]:
		if geom.has(k):
			s_params[k] = geom[k]
		elif props.has(k):
			s_params[k] = props[k]

	var rot_rad: float = deg_to_rad(rot_z_deg)
	var default_tan := Vector3(cos(rot_rad), sin(rot_rad), 0.0)
	var span: float = maxf(2.0, dims.x)

	var inlet_pos := pos
	var inlet_tan := default_tan
	var outlet_pos := pos + default_tan * span
	var outlet_tan := default_tan

	var z_start: float = float(geom.get("elevation_start", 0.8))
	var z_end: float = float(geom.get("elevation_end", z_start))
	var dz_incline: float = z_end - z_start

	if geom.has("inlet_pose") and geom["inlet_pose"] is Dictionary and geom.has("outlet_pose") and geom["outlet_pose"] is Dictionary:
		var in_d: Dictionary = geom["inlet_pose"]
		var out_d: Dictionary = geom["outlet_pose"]
		inlet_pos = _extract_vec3(in_d.get("pos", in_d.get("position", pos)), pos)
		inlet_tan = _norm3(_extract_vec3(in_d.get("tangent", default_tan), default_tan), default_tan)
		outlet_pos = _extract_vec3(out_d.get("pos", out_d.get("position", outlet_pos)), outlet_pos)
		outlet_tan = _norm3(_extract_vec3(out_d.get("tangent", default_tan), default_tan), default_tan)
		if not s_params.has("auto_join"):
			s_params["auto_join"] = true
	else:
		# Auto-join to downstream conveyor if doc_or_spec provided
		var resolved_from_conn := false
		if doc_or_spec != null and not elem_id.is_empty():
			var conns_arr: Array = []
			var elems_arr: Array = []
			if doc_or_spec is Dictionary:
				if doc_or_spec.get("connections") is Array: conns_arr = doc_or_spec["connections"]
				if doc_or_spec.get("elements") is Array: elems_arr = doc_or_spec["elements"]
			elif doc_or_spec.get("active_document") != null:
				conns_arr = doc_or_spec.active_document.connections
				elems_arr = doc_or_spec.active_document.elements
			elif doc_or_spec.get("connections") is Array:
				conns_arr = doc_or_spec.connections
				elems_arr = doc_or_spec.elements

			var conv_pos_by_id: Dictionary = {}
			for e in elems_arr:
				var ekind: String = str(e.get("kind", "") if e is Dictionary else e.kind).to_lower()
				if ekind == "conveyor" or ekind.ends_with("/conveyor"):
					var eid: String = str(e.get("id", "") if e is Dictionary else e.id)
					var epos := Vector3.ZERO
					if e is Dictionary:
						var etr = e.get("transform", {})
						if etr is Dictionary: epos = _extract_vec3(etr.get("position", [0,0,0]), Vector3.ZERO)
					elif e.transform != null:
						epos = e.transform.position
					conv_pos_by_id[eid] = epos

			for c in conns_arr:
				var src_e: String = str(c.get("source_element", "") if c is Dictionary else c.source_element)
				var dst_e: String = str(c.get("target_element", "") if c is Dictionary else c.target_element)
				var ltype: String = str(c.get("link_type", "flow") if c is Dictionary else c.link_type)
				if ltype == "flow" and src_e == elem_id and conv_pos_by_id.has(dst_e):
					var dst_p: Vector3 = conv_pos_by_id[dst_e]
					var diff: Vector3 = dst_p - pos
					if diff.length() > 0.5:
						inlet_pos = pos
						outlet_pos = dst_p
						inlet_tan = _norm3(diff, default_tan)
						outlet_tan = inlet_tan
						resolved_from_conn = true
						if not s_params.has("auto_join"):
							s_params["auto_join"] = true
						break

			if not resolved_from_conn:
				for c in conns_arr:
					var src_e: String = str(c.get("source_element", "") if c is Dictionary else c.source_element)
					var dst_e: String = str(c.get("target_element", "") if c is Dictionary else c.target_element)
					var ltype: String = str(c.get("link_type", "flow") if c is Dictionary else c.link_type)
					if ltype == "flow" and dst_e == elem_id and conv_pos_by_id.has(src_e):
						var src_p: Vector3 = conv_pos_by_id[src_e]
						var diff_in: Vector3 = pos - src_p
						if diff_in.length() > 0.5:
							inlet_tan = _norm3(diff_in, default_tan)
							outlet_tan = inlet_tan
							inlet_pos = pos
							outlet_pos = pos + inlet_tan * maxf(6.0, span)
							break

	if absf(dz_incline) > 1e-3 and absf(outlet_pos.z - inlet_pos.z) < 1e-3:
		outlet_pos.z = inlet_pos.z + dz_incline

	var cpts := generate_control_points(preset, inlet_pos, inlet_tan, outlet_pos, outlet_tan, s_params)
	return bake_control_points(preset, cpts, num_samples)

static func build_curve3d_for_element(elem_or_dict, doc_or_spec = null) -> Curve3D:
	var baked := sample_world_curve(elem_or_dict, doc_or_spec, 32)
	var cpts: Array = baked.get("control_points", [])
	var c3d := Curve3D.new()
	c3d.up_vector_enabled = true
	for cp in cpts:
		if cp is Dictionary:
			var p: Vector3 = cp.get("pos", Vector3.ZERO)
			var in_h: Vector3 = cp.get("in_handle", Vector3.ZERO)
			var out_h: Vector3 = cp.get("out_handle", Vector3.ZERO)
			# Convert from SimViz Z-up (x, y, z) to Godot Y-up (x, z, -y)
			c3d.add_point(
				Vector3(p.x, p.z, -p.y),
				Vector3(in_h.x, in_h.z, -in_h.y),
				Vector3(out_h.x, out_h.z, -out_h.y)
			)
	return c3d

static func sample_2d_polyline(elem_or_dict, doc_or_spec = null, num_samples: int = 36) -> PackedVector2Array:
	var baked := sample_world_curve(elem_or_dict, doc_or_spec, num_samples)
	var pts3: PackedVector3Array = baked["points"]
	var poly: PackedVector2Array = []
	for p in pts3:
		poly.append(Vector2(p.x, p.y))
	return poly
