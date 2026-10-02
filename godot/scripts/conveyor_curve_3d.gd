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
	if not bool(params.get("preserve_endpoints", false)):
		var lat_off: float = float(params["lateral_offset"]) if params.has("lateral_offset") else 2.5
		var f_span: float = float(params.get("forward_span", 0.0))
		if f_span < 1.0:
			f_span = maxf(4.0, (outlet_pos - inlet_pos).length())
			params["forward_span"] = f_span
		params["lateral_offset"] = lat_off
		var n_in := Vector3(-t_in.y, t_in.x, 0.0)
		outlet_pos = inlet_pos + t_in * f_span + n_in * lat_off
		t_out = t_in

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
		if not bool(params.get("preserve_endpoints", false)):
			var cached_angle: float = deg_to_rad(absf(float(params.get("bend_angle_deg", 90.0))))
			var cached_sign: float = -1.0 if str(params.get("turn_direction", "right")).to_lower() == "right" else 1.0
			var cached_turn := Vector3(t_in.x * cos(cached_angle * cached_sign) - t_in.y * sin(cached_angle * cached_sign), t_in.x * sin(cached_angle * cached_sign) + t_in.y * cos(cached_angle * cached_sign), 0.0).normalized()
			outlet_pos = corner + cached_turn * maxf(0.5, float(params.get("leg2_length", 5.0)))
			t_out = cached_turn
	elif params.has("leg1_length") or params.has("leg2_length") or params.has("bend_angle_deg") or params.has("turn_direction"):
		var l1: float = maxf(0.5, float(params.get("leg1_length", 5.0)))
		var l2: float = maxf(0.5, float(params.get("leg2_length", 5.0)))
		var ang_deg: float = float(params.get("bend_angle_deg", 90.0))
		var turn_dir_str: String = str(params.get("turn_direction", "right")).to_lower()
		var sign_ang: float = 1.0
		if turn_dir_str == "left":
			sign_ang = 1.0
		elif turn_dir_str == "right":
			sign_ang = -1.0
		else:
			sign_ang = 1.0 if ang_deg >= 0.0 else -1.0
		var ang_rad: float = deg_to_rad(absf(ang_deg)) * sign_ang
		corner = inlet_pos + t_in * l1
		var turned_dir := Vector3(
			t_in.x * cos(ang_rad) - t_in.y * sin(ang_rad),
			t_in.x * sin(ang_rad) + t_in.y * cos(ang_rad),
			0.0
		).normalized()
		outlet_pos = corner + turned_dir * l2
		t_out = turned_dir
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
			var ang_deg: float = float(params.get("bend_angle_deg", 90.0))
			var ang_rad: float = deg_to_rad(ang_deg)
			var span: float = maxf(4.0, inlet_pos.distance_to(outlet_pos))
			var half_span: float = span * 0.5
			corner = inlet_pos + t_in * half_span
			var turned_dir := Vector3(
				t_in.x * cos(ang_rad) - t_in.y * sin(ang_rad),
				t_in.x * sin(ang_rad) + t_in.y * cos(ang_rad),
				0.0
			).normalized()
			outlet_pos = corner + turned_dir * half_span
			t_out = turned_dir

	# Save resolved corner into params dictionary
	params["corner_pos"] = [corner.x, corner.y, corner.z]

	var v1: Vector3 = corner - inlet_pos
	var v2: Vector3 = outlet_pos - corner
	var L1: float = v1.length()
	var L2: float = v2.length()
	params["leg1_length"] = L1
	params["leg2_length"] = L2

	if L1 < 1e-3 or L2 < 1e-3:
		return _gen_s_curve(inlet_pos, t_in, outlet_pos, t_out, params)

	var u1: Vector3 = v1 / L1
	var u2: Vector3 = v2 / L2
	var cos_th: float = clampf(u1.dot(u2), -0.995, 0.995)
	var theta: float = acos(cos_th)
	var bend_deg := rad_to_deg(theta)
	params["bend_angle_deg"] = bend_deg
	var cross_z: float = u1.x * u2.y - u1.y * u2.x
	params["turn_direction"] = "left" if cross_z > 0.0 else "right"

	if theta < 0.05:
		return _gen_straight(inlet_pos, outlet_pos)

	var tan_half: float = tan(theta * 0.5)
	var max_trim: float = 0.90 * minf(L1, L2)
	var d_trim: float = minf(R * tan_half, max_trim)
	var r_eff: float = d_trim / maxf(1e-4, tan_half)

	var b_start: Vector3 = corner - u1 * d_trim
	var b_end: Vector3 = corner + u2 * d_trim
	var n_arc_segs: int = maxi(1, int(ceil(theta / (0.5 * PI))))
	var signed_step: float = theta * (1.0 if cross_z >= 0.0 else -1.0) / float(n_arc_segs)
	var hlen: float = r_eff * _bezier_arc_kappa(absf(signed_step))
	var center := b_start + Vector3(-u1.y, u1.x, 0.0) * r_eff * (1.0 if cross_z >= 0.0 else -1.0)
	var start_radius := b_start - center

	var cpts: Array = []
	if inlet_pos.distance_to(b_start) > 0.05:
		cpts.append({"pos": inlet_pos, "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO})
	else:
		b_start = inlet_pos
	for index in range(n_arc_segs + 1):
		var angle: float = float(index) * signed_step
		var ca: float = cos(angle)
		var sa: float = sin(angle)
		var radial := Vector3(start_radius.x * ca - start_radius.y * sa, start_radius.x * sa + start_radius.y * ca, 0.0)
		var tangent := Vector3(u1.x * ca - u1.y * sa, u1.x * sa + u1.y * ca, 0.0)
		var pos := b_end if index == n_arc_segs else center + radial
		cpts.append({"pos": pos, "in_handle": -tangent * hlen if index > 0 else Vector3.ZERO, "out_handle": tangent * hlen if index < n_arc_segs else Vector3.ZERO})
	if b_end.distance_to(outlet_pos) > 0.05:
		cpts.append({"pos": outlet_pos, "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO})
	else:
		cpts[cpts.size() - 1]["pos"] = outlet_pos
	return cpts

static func _gen_u_turn(inlet_pos: Vector3, inlet_tan: Vector3, outlet_pos: Vector3, outlet_tan: Vector3, params: Dictionary) -> Array:
	var R: float = maxf(0.5, float(params.get("bend_radius", 2.0)))
	var leg_len: float = maxf(1.5, float(params.get("leg_length", 6.0)))
	var return_len: float = maxf(1.5, float(params.get("return_leg_length", leg_len)))
	var dir := _norm3(Vector3(inlet_tan.x, inlet_tan.y, 0.0))
	var perp := Vector3(-dir.y, dir.x, 0.0)

	var p0 := inlet_pos
	var p1 := p0 + dir * leg_len
	var apex := p1 + dir * R + perp * R
	var p2 := p1 + perp * (2.0 * R)
	var p3 := outlet_pos if bool(params.get("preserve_endpoints", false)) else p2 - dir * return_len
	var k90: float = R * _bezier_arc_kappa(0.5 * PI)
	var end_handle := clampf(p2.distance_to(p3) * 0.25, 0.4, 2.0) if bool(params.get("preserve_endpoints", false)) else 0.0

	return [
		{"pos": p0, "in_handle": Vector3.ZERO, "out_handle": Vector3.ZERO},
		{"pos": p1, "in_handle": Vector3.ZERO, "out_handle": dir * k90},
		{"pos": apex, "in_handle": -perp * k90, "out_handle": perp * k90},
		{"pos": p2, "in_handle": dir * k90, "out_handle": -dir * end_handle},
		{"pos": p3, "in_handle": -_norm3(outlet_tan) * end_handle, "out_handle": Vector3.ZERO}
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
	var passes: int = clampi(int(round(float(params.get("passes", 3)))), 2, 12)
	var pitch: float = maxf(1.2, float(params.get("pass_spacing", params.get("pitch", 2.0))))
	var R: float = 0.5 * pitch
	var span: float = maxf(3.0, float(params.get("pass_length", inlet_pos.distance_to(outlet_pos))))
	var infeed_length: float = clampf(float(params.get("infeed_length", 0.0)), 0.0, span)
	var outfeed_length: float = clampf(float(params.get("outfeed_length", 0.0)), 0.0, span)
	var dir := _norm3(Vector3(inlet_tan.x, inlet_tan.y, 0.0))
	var perp := Vector3(-dir.y, dir.x, 0.0)
	var k90: float = R * _bezier_arc_kappa(0.5 * PI)
	var core_origin := inlet_pos + dir * infeed_length

	var cpts: Array = []
	if infeed_length > 0.001:
		cpts.append({"pos": inlet_pos, "in_handle": Vector3.ZERO, "out_handle": dir * (infeed_length / 3.0)})
	for p in range(1, passes + 1):
		var fwd: bool = (p % 2) == 1
		var y_off: float = float(p - 1) * pitch
		var base_start := core_origin + perp * y_off
		var base_end := base_start + dir * span
		var s_pt := base_start if fwd else base_end
		var e_pt := base_end if fwd else base_start
		var t_dir := dir if fwd else (-dir)
		var in_h_start := (-dir * (infeed_length / 3.0)) if p == 1 and infeed_length > 0.001 else (Vector3.ZERO if p == 1 else (-t_dir * k90))
		var out_h_end := (t_dir * (outfeed_length / 3.0)) if p == passes and outfeed_length > 0.001 else (Vector3.ZERO if p == passes else (t_dir * k90))
		cpts.append({"pos": s_pt, "in_handle": in_h_start, "out_handle": Vector3.ZERO})
		cpts.append({"pos": e_pt, "in_handle": Vector3.ZERO, "out_handle": out_h_end})
		if p < passes:
			var apex := e_pt + t_dir * R + perp * R
			cpts.append({"pos": apex, "in_handle": -perp * k90, "out_handle": perp * k90})
		elif outfeed_length > 0.001:
			cpts.append({"pos": e_pt + t_dir * outfeed_length, "in_handle": -t_dir * (outfeed_length / 3.0), "out_handle": Vector3.ZERO})
	return cpts

static func _gen_spiral_helix(inlet_pos: Vector3, inlet_tan: Vector3, outlet_pos: Vector3, _outlet_tan: Vector3, params: Dictionary) -> Array:
	var R: float = maxf(1.0, float(params.get("helix_radius", 2.5)))
	var turns: float = clampf(float(params.get("helix_turns", 1.5)), 0.25, 6.0)
	var dz: float = float(params.get("elevation_gain", outlet_pos.z - inlet_pos.z))
	if not params.has("elevation_gain") and absf(dz) < 0.1:
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
		var mid := (inlet_pos + outlet_pos) * 0.5
		var dir := _norm3(outlet_pos - inlet_pos, inlet_tan)
		var perp := Vector3(-dir.y, dir.x, 0.0)
		raw_pts = [
			{"pos": [inlet_pos.x, inlet_pos.y, inlet_pos.z]},
			{"pos": [mid.x + perp.x * 2.5, mid.y + perp.y * 2.5, mid.z]},
			{"pos": [outlet_pos.x, outlet_pos.y, outlet_pos.z]}
		]
		params["control_points"] = raw_pts

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
		var item = raw_pts[i]
		var in_handle := _extract_vec3(item.get("in_handle", []), -t_dir * d_in) if item is Dictionary else -t_dir * d_in
		var out_handle := _extract_vec3(item.get("out_handle", []), t_dir * d_out) if item is Dictionary else t_dir * d_out
		cpts.append({
			"pos": p_curr,
			"in_handle": in_handle,
			"out_handle": out_handle
		})
	return cpts

static func convert_element_to_custom_spline(elem_or_dict, doc_or_spec = null) -> Dictionary:
	var baked := sample_world_curve(elem_or_dict, doc_or_spec, 24)
	var cpts_raw: Array = []
	for cp in baked.get("control_points", []):
		var p: Vector3 = cp["pos"]
		var in_h: Vector3 = cp["in_handle"]
		var out_h: Vector3 = cp["out_handle"]
		cpts_raw.append({"pos": [p.x, p.y, p.z], "in_handle": [in_h.x, in_h.y, in_h.z], "out_handle": [out_h.x, out_h.y, out_h.z]})

	var geom: Dictionary = {}
	if elem_or_dict is Dictionary:
		if not elem_or_dict.has("geometry") or not (elem_or_dict["geometry"] is Dictionary):
			elem_or_dict["geometry"] = {}
		geom = elem_or_dict["geometry"]
	elif elem_or_dict != null and elem_or_dict.geometry is Dictionary:
		geom = elem_or_dict.geometry

	geom["shape_preset"] = "custom_spline"
	if not geom.has("shape_params") or not (geom["shape_params"] is Dictionary):
		geom["shape_params"] = {}
	geom["shape_params"]["control_points"] = cpts_raw
	return geom

static func custom_span_midpoint(elem_or_dict, index: int) -> Vector3:
	var geom: Dictionary = elem_or_dict.get("geometry", {}) if elem_or_dict is Dictionary else elem_or_dict.geometry
	var params: Dictionary = geom.get("shape_params", {})
	var raw: Array = params.get("control_points", [])
	if index < 0 or index >= raw.size() - 1:
		return Vector3.ZERO
	var cpts := _gen_custom_spline(Vector3.ZERO, Vector3.RIGHT, Vector3.RIGHT, Vector3.RIGHT, params)
	var start: Vector3 = cpts[index]["pos"]
	var finish: Vector3 = cpts[index + 1]["pos"]
	return eval_cubic_bezier(start, start + cpts[index]["out_handle"], finish + cpts[index + 1]["in_handle"], finish, 0.5)["pos"]

static func insert_custom_spline_point(elem_or_dict, index: int) -> bool:
	var geom: Dictionary = elem_or_dict.get("geometry", {}) if elem_or_dict is Dictionary else elem_or_dict.geometry
	var params: Dictionary = geom.get("shape_params", {})
	var raw: Array = params.get("control_points", [])
	if index < 0 or index >= raw.size() - 1:
		return false
	var cpts := _gen_custom_spline(Vector3.ZERO, Vector3.RIGHT, Vector3.RIGHT, Vector3.RIGHT, params)
	var p0: Vector3 = cpts[index]["pos"]
	var p1: Vector3 = p0 + cpts[index]["out_handle"]
	var p3: Vector3 = cpts[index + 1]["pos"]
	var p2: Vector3 = p3 + cpts[index + 1]["in_handle"]
	var a := p0.lerp(p1, 0.5)
	var b := p1.lerp(p2, 0.5)
	var c := p2.lerp(p3, 0.5)
	var d := a.lerp(b, 0.5)
	var e := b.lerp(c, 0.5)
	var mid := d.lerp(e, 0.5)
	var stored: Array = []
	for cp in cpts:
		var pos: Vector3 = cp["pos"]
		var in_h: Vector3 = cp["in_handle"]
		var out_h: Vector3 = cp["out_handle"]
		stored.append({"pos": [pos.x, pos.y, pos.z], "in_handle": [in_h.x, in_h.y, in_h.z], "out_handle": [out_h.x, out_h.y, out_h.z]})
	stored[index]["out_handle"] = [a.x - p0.x, a.y - p0.y, a.z - p0.z]
	stored[index + 1]["in_handle"] = [c.x - p3.x, c.y - p3.y, c.z - p3.z]
	stored.insert(index + 1, {"pos": [mid.x, mid.y, mid.z], "in_handle": [d.x - mid.x, d.y - mid.y, d.z - mid.z], "out_handle": [e.x - mid.x, e.y - mid.y, e.z - mid.z]})
	params["control_points"] = stored
	return true

static func connected_endpoint_locks(elem_id: String, doc_store) -> Dictionary:
	var locks := {"inlet": false, "outlet": false}
	if doc_store == null or doc_store.active_document == null:
		return locks
	for conn in doc_store.active_document.connections:
		if conn.enabled and conn.link_type == "flow":
			if conn.source_element == elem_id:
				locks["outlet"] = true
			if conn.target_element == elem_id:
				locks["inlet"] = true
	return locks

static func connected_endpoints_unchanged(before: Dictionary, after: Dictionary, locks: Dictionary) -> bool:
	for end_name in ["inlet", "outlet"]:
		if not bool(locks.get(end_name, false)):
			continue
		var before_pos: Vector3 = before[end_name + "_pos"]
		var after_pos: Vector3 = after[end_name + "_pos"]
		var before_tan: Vector3 = before[end_name + "_tan"]
		var after_tan: Vector3 = after[end_name + "_tan"]
		if before_pos.distance_to(after_pos) > 0.02 or before_tan.dot(after_tan) < 0.995:
			return false
	return true

static func width_at_fraction(elem_or_dict, fraction: float) -> float:
	var geom: Dictionary = elem_or_dict.get("geometry", {}) if elem_or_dict is Dictionary else elem_or_dict.geometry
	var dims = geom.get("dimensions", [8.0, 1.2, 0.8])
	var base_width: float = maxf(0.4, float(dims[1])) if dims is Array and dims.size() > 1 else 1.2
	var profile = geom.get("width_profile", [])
	if not (profile is Array) or profile.is_empty():
		return base_width
	var keys: Array = []
	for item in profile:
		if item is Dictionary:
			keys.append({"fraction": clampf(float(item.get("fraction", 0.5)), 0.0, 1.0), "scale": maxf(0.1, float(item.get("scale", 1.0)))})
	if keys.is_empty():
		return base_width
	keys.sort_custom(func(first: Dictionary, second: Dictionary) -> bool: return first["fraction"] < second["fraction"])
	if float(keys[0]["fraction"]) > 0.0:
		keys.push_front({"fraction": 0.0, "scale": 1.0})
	if float(keys[-1]["fraction"]) < 1.0:
		keys.append({"fraction": 1.0, "scale": 1.0})
	var pos := clampf(fraction, 0.0, 1.0)
	if pos <= float(keys[0]["fraction"]):
		return clampf(base_width * float(keys[0]["scale"]), 0.4, 8.0)
	for index in range(keys.size() - 1):
		var left: Dictionary = keys[index]
		var right: Dictionary = keys[index + 1]
		if pos <= float(right["fraction"]):
			var span: float = float(right["fraction"]) - float(left["fraction"])
			var alpha: float = clampf((pos - float(left["fraction"])) / span, 0.0, 1.0) if span > 0.00001 else 0.0
			return clampf(base_width * lerpf(float(left["scale"]), float(right["scale"]), alpha), 0.4, 8.0)
	return base_width

static func next_width_key_fraction(elem_or_dict) -> float:
	var geom: Dictionary = elem_or_dict.get("geometry", {}) if elem_or_dict is Dictionary else elem_or_dict.geometry
	var fractions: Array[float] = [0.0, 1.0]
	var profile = geom.get("width_profile", [])
	if profile is Array:
		for item in profile:
			if item is Dictionary:
				fractions.append(clampf(float(item.get("fraction", 0.5)), 0.0, 1.0))
	fractions.sort()
	var largest_gap := 0.0
	var result := 0.5
	for index in range(fractions.size() - 1):
		var gap: float = fractions[index + 1] - fractions[index]
		if gap > largest_gap:
			largest_gap = gap
			result = (fractions[index] + fractions[index + 1]) * 0.5
	return result

static func maximum_width(elem_or_dict) -> float:
	var max_width: float = width_at_fraction(elem_or_dict, 0.0)
	var geom: Dictionary = elem_or_dict.get("geometry", {}) if elem_or_dict is Dictionary else elem_or_dict.geometry
	var profile = geom.get("width_profile", [])
	if profile is Array:
		for item in profile:
			if item is Dictionary:
				max_width = maxf(max_width, width_at_fraction(elem_or_dict, float(item.get("fraction", 0.5))))
	return maxf(max_width, width_at_fraction(elem_or_dict, 1.0))

static func geometry_diagnostics(elem_or_dict, doc_or_spec = null) -> Dictionary:
	var geom: Dictionary = elem_or_dict.get("geometry", {}) if elem_or_dict is Dictionary else elem_or_dict.geometry
	var baked := sample_world_curve(elem_or_dict, doc_or_spec, 64)
	var controls: Array = baked["control_points"]
	for index in range(controls.size() - 1):
		if (controls[index]["pos"] as Vector3).distance_to(controls[index + 1]["pos"]) < 0.05:
			return {"error": "Adjacent bend stations must be at least 0.05 m apart", "warning": ""}
	var points: PackedVector3Array = baked["points"]
	var dims = geom.get("dimensions", [8.0, 1.2, 0.8])
	var width := float(dims[1]) if dims is Array and dims.size() > 1 else 1.2
	var widest: float = maximum_width(elem_or_dict)
	var shape_params: Dictionary = geom.get("shape_params", {}) if geom.get("shape_params") is Dictionary else {}
	if str(geom.get("shape_preset", "")) == "serpentine" and float(shape_params.get("pass_spacing", 2.0)) < widest:
		return {"error": "", "warning": "Lane center spacing is narrower than the belt; passes overlap"}
	var steep := false
	var tight := false
	for index in range(points.size() - 1):
		var edge := points[index + 1] - points[index]
		if absf(edge.z) > 0.268 * Vector2(edge.x, edge.y).length() + 0.001:
			steep = true
	for index in range(1, points.size() - 1):
		var first := points[index] - points[index - 1]
		var second := points[index + 1] - points[index]
		var cross_size := first.cross(second).length()
		if cross_size > 0.000001 and first.length() * second.length() * (first + second).length() / (2.0 * cross_size) < width * 0.5:
			tight = true
	var warning := ""
	if steep:
		warning = "Conveyor grade exceeds 15 degrees"
	elif tight:
		warning = "Bend radius is smaller than half the belt width"
	return {"error": "", "warning": warning}

static func update_shape_parameter(elem_or_dict, key: String, value, doc_or_spec = null) -> bool:
	var geom: Dictionary = elem_or_dict.get("geometry", {}) if elem_or_dict is Dictionary else elem_or_dict.geometry
	var elem_id: String = str(elem_or_dict.get("id", "")) if elem_or_dict is Dictionary else str(elem_or_dict.id)
	var locks := connected_endpoint_locks(elem_id, doc_or_spec)
	var before := sample_world_curve(elem_or_dict, doc_or_spec) if locks["inlet"] or locks["outlet"] else {}
	var original: Dictionary = geom.duplicate(true)
	if geom.get("shape_params") is Dictionary and geom["shape_params"].get(key) == value:
		return true
	if doc_or_spec is Object and doc_or_spec.has_method("_record_undo"):
		doc_or_spec._record_undo()
	if not (geom.get("shape_params") is Dictionary):
		geom["shape_params"] = {}
	var params: Dictionary = geom["shape_params"]
	if str(geom.get("shape_preset", "")) == "l_bend" and key in ["bend_angle_deg", "leg1_length", "leg2_length", "turn_direction"]:
		params.erase("corner_pos")
		geom.erase("corner_pos")
	params[key] = value
	var after := sample_world_curve(elem_or_dict, doc_or_spec)
	if (not before.is_empty() and not connected_endpoints_unchanged(before, after, locks)) or not str(geometry_diagnostics(elem_or_dict, doc_or_spec)["error"]).is_empty():
		if elem_or_dict is Dictionary:
			elem_or_dict["geometry"] = original
		else:
			elem_or_dict.geometry = original
		return false
	return true

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
	for k in ["bend_radius", "bend_angle_deg", "sweep_angle_deg", "passes", "pass_spacing", "pass_length", "infeed_length", "outfeed_length", "helix_radius", "helix_turns", "elevation_gain", "corner_pos", "control_points", "tangent_scale", "leg_length", "return_leg_length", "leg1_length", "leg2_length", "turn_direction", "forward_span", "auto_join", "lateral_offset"]:
		if s_params.has(k):
			continue
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
	var anchored_outlet := false

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
		anchored_outlet = not bool(out_d.get("_derived", false))
		if anchored_outlet:
			s_params["preserve_endpoints"] = true
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
						s_params["preserve_endpoints"] = true
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
	if num_samples <= 0:
		num_samples = clampi((cpts.size() - 1) * 24, 48, 768)
	var res := bake_control_points(preset, cpts, num_samples)

	if s_params.has("corner_pos"):
		if not geom.has("shape_params") or not (geom["shape_params"] is Dictionary):
			geom["shape_params"] = {}
		geom["shape_params"]["corner_pos"] = s_params["corner_pos"]
		res["corner_pos"] = s_params["corner_pos"]
		if elem_or_dict != null and not (elem_or_dict is Dictionary) and elem_or_dict.geometry is Dictionary:
			if not elem_or_dict.geometry.has("shape_params") or not (elem_or_dict.geometry["shape_params"] is Dictionary):
				elem_or_dict.geometry["shape_params"] = {}
			elem_or_dict.geometry["shape_params"]["corner_pos"] = s_params["corner_pos"]

	if preset != "straight":
		var end_pt: Vector3 = res["outlet_pos"]
		var end_tan: Vector3 = res["outlet_tan"]
		var out_dict := {
			"position": [end_pt.x, end_pt.y, end_pt.z],
			"tangent": [end_tan.x, end_tan.y, end_tan.z],
			"_derived": not anchored_outlet
		}
		geom["outlet_pose"] = out_dict
		if elem_or_dict != null and not (elem_or_dict is Dictionary) and elem_or_dict.geometry is Dictionary:
			elem_or_dict.geometry["outlet_pose"] = out_dict

	return res

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
