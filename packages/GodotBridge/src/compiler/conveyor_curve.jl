# packages/GodotBridge/src/compiler/conveyor_curve.jl
#
# General 3D/2D Parametric Conveyor Curve & Network Junction Alignment Engine.
#
# Architecture:
#   Layer 1: Extensible Shape Preset Registry (`CONVEYOR_SHAPE_PRESETS`)
#            - :straight       (Point-to-point linear / inclined belt)
#            - :s_curve        (Universal C¹ Cubic Hermite smooth connector)
#            - :l_bend         (Straight run + tangent filleted corner bend of radius R)
#            - :u_turn         (180° return loop with configurable width and radius R)
#            - :circular_arc   (Constant-radius curved roller section with sweep angle)
#            - :serpentine     (Multi-pass switchback accumulation conveyor)
#            - :spiral_helix   (3D helical vertical elevator / lowerator)
#            - :custom_spline  (User/optimizer control points with Catmull-Rom auto-tangents)
#   Layer 2: Canonical Piecewise Cubic Bézier Control Points -> Baked Arc-Length Table (`BakedConveyorCurve`)
#   Layer 3: O(log N) Zero-Allocation Constant-Speed Evaluator (`sample_conveyor_curve`)
#            & Automatic Network Junction Pose Solver (`resolve_conveyor_network_poses!`)

const Vec3 = NTuple{3, Float64}

@inline _v3_add(a::Vec3, b::Vec3)::Vec3 = (a[1] + b[1], a[2] + b[2], a[3] + b[3])
@inline _v3_sub(a::Vec3, b::Vec3)::Vec3 = (a[1] - b[1], a[2] - b[2], a[3] - b[3])
@inline _v3_scale(a::Vec3, s::Float64)::Vec3 = (a[1] * s, a[2] * s, a[3] * s)
@inline _v3_dot(a::Vec3, b::Vec3)::Float64 = a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
@inline _v3_cross(a::Vec3, b::Vec3)::Vec3 = (
    a[2]*b[3] - a[3]*b[2],
    a[3]*b[1] - a[1]*b[3],
    a[1]*b[2] - a[2]*b[1]
)
@inline _v3_len(a::Vec3)::Float64 = sqrt(_v3_dot(a, a))
@inline _v3_dist(a::Vec3, b::Vec3)::Float64 = _v3_len(_v3_sub(b, a))
@inline function _v3_lerp(a::Vec3, b::Vec3, t::Float64)::Vec3
    return (a[1] + t*(b[1] - a[1]), a[2] + t*(b[2] - a[2]), a[3] + t*(b[3] - a[3]))
end
@inline function _v3_normalize(a::Vec3, fallback::Vec3 = (1.0, 0.0, 0.0))::Vec3
    l = _v3_len(a)
    return l > 1e-9 ? (a[1] / l, a[2] / l, a[3] / l) : fallback
end

"""
    Pose3D

World-space 3D attachment pose (position, unit flow tangent, and unit surface up-normal)
for a conveyor inlet, outlet, or transfer junction.
"""
struct Pose3D
    pos::Vec3
    tangent::Vec3
    up::Vec3
    function Pose3D(pos::Vec3, tangent::Vec3 = (1.0, 0.0, 0.0), up::Vec3 = (0.0, 0.0, 1.0))
        return new(pos, _v3_normalize(tangent, (1.0, 0.0, 0.0)), _v3_normalize(up, (0.0, 0.0, 1.0)))
    end
end

"""
    SplineControlPoint3D

Canonical Cubic Bézier control point in 3D space.
`in_handle` and `out_handle` are relative offset vectors from `pos`
(matching Godot's `Curve3D.add_point(pos, in_handle, out_handle)` convention).
"""
struct SplineControlPoint3D
    pos::Vec3
    in_handle::Vec3
    out_handle::Vec3
    up::Vec3
    function SplineControlPoint3D(
        pos::Vec3,
        in_handle::Vec3 = (0.0, 0.0, 0.0),
        out_handle::Vec3 = (0.0, 0.0, 0.0),
        up::Vec3 = (0.0, 0.0, 1.0)
    )
        return new(pos, in_handle, out_handle, _v3_normalize(up, (0.0, 0.0, 1.0)))
    end
end

"""
    BakedConveyorCurve

Compile-time baked arc-length parameterized representation of a 3D conveyor path.
Supports `O(log N)` zero-allocation constant-speed evaluation of position, tangent, and up-normal.
"""
struct BakedConveyorCurve
    preset::Symbol
    inlet_pose::Pose3D
    outlet_pose::Pose3D
    total_length::Float64
    arc_lengths::Vector{Float64}
    positions::Vector{Vec3}
    tangents::Vector{Vec3}
    ups::Vector{Vec3}
    control_points::Vector{SplineControlPoint3D}
end

# ─────────────────────────────────────────────────────────────────────────────
# Cubic Bézier Segment Evaluation & Arc-Length Table Baking
# ─────────────────────────────────────────────────────────────────────────────

"""
    eval_cubic_bezier(p0::Vec3, p1::Vec3, p2::Vec3, p3::Vec3, u::Float64) -> Tuple{Vec3, Vec3}

Evaluates a single Cubic Bézier segment at parameter `u in [0, 1]` and returns `(position, derivative)`.
"""
@inline function eval_cubic_bezier(p0::Vec3, p1::Vec3, p2::Vec3, p3::Vec3, u::Float64)::Tuple{Vec3, Vec3}
    om = 1.0 - u
    om2 = om * om
    u2 = u * u
    b0 = om2 * om
    b1 = 3.0 * om2 * u
    b2 = 3.0 * om * u2
    b3 = u2 * u

    pos = (
        b0*p0[1] + b1*p1[1] + b2*p2[1] + b3*p3[1],
        b0*p0[2] + b1*p1[2] + b2*p2[2] + b3*p3[2],
        b0*p0[3] + b1*p1[3] + b2*p2[3] + b3*p3[3]
    )

    d01 = _v3_sub(p1, p0)
    d12 = _v3_sub(p2, p1)
    d23 = _v3_sub(p3, p2)
    w0 = 3.0 * om2
    w1 = 6.0 * om * u
    w2 = 3.0 * u2
    deriv = (
        w0*d01[1] + w1*d12[1] + w2*d23[1],
        w0*d01[2] + w1*d12[2] + w2*d23[2],
        w0*d01[3] + w1*d12[3] + w2*d23[3]
    )
    return (pos, deriv)
end

"""
    bake_conveyor_curve(preset::Symbol, cpts::Vector{SplineControlPoint3D}; num_samples::Int=64) -> BakedConveyorCurve

Compiles a vector of `SplineControlPoint3D` into a uniform arc-length lookup table with `num_samples + 1` entries.
"""
function bake_conveyor_curve(
    preset::Symbol,
    cpts::Vector{SplineControlPoint3D};
    num_samples::Int = 64
)::BakedConveyorCurve
    if isempty(cpts)
        p_def = Pose3D((0.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        return BakedConveyorCurve(preset, p_def, p_def, 1.0, [0.0, 1.0],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)], [(1.0, 0.0, 0.0), (1.0, 0.0, 0.0)],
            [(0.0, 0.0, 1.0), (0.0, 0.0, 1.0)], cpts)
    elseif length(cpts) == 1
        cp = cpts[1]
        p2 = _v3_add(cp.pos, (1.0, 0.0, 0.0))
        cpts = [cp, SplineControlPoint3D(p2)]
    end

    n_segs = length(cpts) - 1
    sub_per_seg = max(16, cld(num_samples * 2, n_segs))
    total_raw = n_segs * sub_per_seg + 1

    raw_s = Vector{Float64}(undef, total_raw)
    raw_p = Vector{Vec3}(undef, total_raw)
    raw_t = Vector{Vec3}(undef, total_raw)
    raw_u = Vector{Vec3}(undef, total_raw)

    idx = 1
    cum_s = 0.0
    prev_p = cpts[1].pos

    for seg in 1:n_segs
        cp0 = cpts[seg]
        cp1 = cpts[seg + 1]
        p0 = cp0.pos
        p1 = _v3_add(cp0.pos, cp0.out_handle)
        p2 = _v3_add(cp1.pos, cp1.in_handle)
        p3 = cp1.pos
        chord_dir = _v3_normalize(_v3_sub(p3, p0), (1.0, 0.0, 0.0))

        j_start = (seg == 1) ? 0 : 1
        for j in j_start:sub_per_seg
            u = Float64(j) / Float64(sub_per_seg)
            pos, deriv = eval_cubic_bezier(p0, p1, p2, p3, u)
            tan = _v3_normalize(deriv, chord_dir)
            up_v = _v3_normalize(_v3_lerp(cp0.up, cp1.up, u), (0.0, 0.0, 1.0))
            if idx > 1
                cum_s += _v3_dist(prev_p, pos)
            end
            raw_s[idx] = cum_s
            raw_p[idx] = pos
            raw_t[idx] = tan
            raw_u[idx] = up_v
            prev_p = pos
            idx += 1
        end
    end

    total_len = max(1e-4, cum_s)

    # Resample at uniform arc-length intervals (0 .. num_samples) for fast O(1)/O(log N) lookup
    N = max(8, num_samples)
    arc_lengths = Vector{Float64}(undef, N + 1)
    positions   = Vector{Vec3}(undef, N + 1)
    tangents    = Vector{Vec3}(undef, N + 1)
    ups         = Vector{Vec3}(undef, N + 1)

    raw_cursor = 1
    for k in 0:N
        target_s = (Float64(k) / Float64(N)) * cum_s
        while raw_cursor < total_raw - 1 && raw_s[raw_cursor + 1] < target_s
            raw_cursor += 1
        end
        s0 = raw_s[raw_cursor]
        s1 = raw_s[min(total_raw, raw_cursor + 1)]
        α = (s1 > s0 + 1e-9) ? clamp((target_s - s0) / (s1 - s0), 0.0, 1.0) : 0.0
        arc_lengths[k + 1] = target_s
        positions[k + 1]   = _v3_lerp(raw_p[raw_cursor], raw_p[min(total_raw, raw_cursor + 1)], α)
        tangents[k + 1]    = _v3_normalize(_v3_lerp(raw_t[raw_cursor], raw_t[min(total_raw, raw_cursor + 1)], α), raw_t[raw_cursor])
        ups[k + 1]         = _v3_normalize(_v3_lerp(raw_u[raw_cursor], raw_u[min(total_raw, raw_cursor + 1)], α), (0.0, 0.0, 1.0))
    end

    in_pose  = Pose3D(positions[1], tangents[1], ups[1])
    out_pose = Pose3D(positions[end], tangents[end], ups[end])
    return BakedConveyorCurve(preset, in_pose, out_pose, total_len, arc_lengths, positions, tangents, ups, cpts)
end

"""
    sample_conveyor_curve(curve::BakedConveyorCurve, t_frac::Float64) -> Tuple{Vec3, Vec3}

Evaluates the baked conveyor curve at normalized arc-length fraction `t_frac in [0, 1]`.
Returns `(position::Vec3, unit_tangent::Vec3)` with zero heap allocations.
"""
@inline function sample_conveyor_curve(curve::BakedConveyorCurve, t_frac::Float64)::Tuple{Vec3, Vec3}
    u = clamp(t_frac, 0.0, 1.0)
    N = length(curve.arc_lengths) - 1
    N <= 0 && return (curve.inlet_pose.pos, curve.inlet_pose.tangent)

    # Because bake_conveyor_curve resamples at uniform arc-length steps, direct index lookup is O(1)!
    f_idx = u * Float64(N)
    idx = clamp( unsafe_trunc(Int, floor(f_idx)) + 1, 1, N )
    α = clamp(f_idx - Float64(idx - 1), 0.0, 1.0)

    p0 = @inbounds curve.positions[idx]
    p1 = @inbounds curve.positions[idx + 1]
    t0 = @inbounds curve.tangents[idx]
    t1 = @inbounds curve.tangents[idx + 1]

    pos = _v3_lerp(p0, p1, α)
    tan = _v3_normalize(_v3_lerp(t0, t1, α), t0)
    return (pos, tan)
end

# ─────────────────────────────────────────────────────────────────────────────
# Layer 1: Extensible Conveyor Shape Preset Generators
# ─────────────────────────────────────────────────────────────────────────────

# Magic kappa constant for cubic Bézier circular arc approximation: (4/3)*tan(θ/4)
@inline _bezier_arc_kappa(sweep_rad::Float64)::Float64 = (4.0 / 3.0) * tan(sweep_rad * 0.25)

"""
    generate_preset_straight(inlet::Pose3D, outlet::Pose3D, params::AbstractDict) -> Vector{SplineControlPoint3D}
"""
function generate_preset_straight(inlet::Pose3D, outlet::Pose3D, params::AbstractDict)::Vector{SplineControlPoint3D}
    return [
        SplineControlPoint3D(inlet.pos, (0.0, 0.0, 0.0), (0.0, 0.0, 0.0), inlet.up),
        SplineControlPoint3D(outlet.pos, (0.0, 0.0, 0.0), (0.0, 0.0, 0.0), outlet.up)
    ]
end

"""
    generate_preset_s_curve(inlet::Pose3D, outlet::Pose3D, params::AbstractDict) -> Vector{SplineControlPoint3D}

Smooth C¹ Cubic Hermite / Bézier S-curve connecting `inlet` and `outlet` while honoring both tangents.
"""
function generate_preset_s_curve(inlet::Pose3D, outlet::Pose3D, params::AbstractDict)::Vector{SplineControlPoint3D}
    t_in = inlet.tangent
    t_out = outlet.tangent
    lat_off = if haskey(params, "lateral_offset")
        Float64(params["lateral_offset"])
    else
        2.5
    end
    f_span = Float64(get(params, "forward_span", 0.0))
    if f_span < 1.0
        f_span = max(4.0, _v3_dist(inlet.pos, outlet.pos))
    end
    if get(params, "preserve_endpoints", false)
        out_pos = outlet.pos
    else
        n_in = (-t_in[2], t_in[1], 0.0)
        out_pos = _v3_add(_v3_add(inlet.pos, _v3_scale(t_in, f_span)), _v3_scale(n_in, lat_off))
        t_out = t_in
    end
    dist = _v3_dist(inlet.pos, out_pos)
    t_scale = Float64(get(params, "tangent_scale", 0.42))
    hlen = max(0.4, dist * t_scale)
    out_h = _v3_scale(t_in, hlen)
    in_h  = _v3_scale(t_out, -hlen)
    return [
        SplineControlPoint3D(inlet.pos, (0.0, 0.0, 0.0), out_h, inlet.up),
        SplineControlPoint3D(out_pos, in_h, (0.0, 0.0, 0.0), outlet.up)
    ]
end

"""
    generate_preset_l_bend(inlet::Pose3D, outlet::Pose3D, params::AbstractDict) -> Vector{SplineControlPoint3D}

Generates a straight-plus-filleted-corner conveyor (L-Bend / Elbow) between `inlet` and `outlet`.
Supports unequal leg lengths (leg1_length, leg2_length), arbitrary bend angles (bend_angle_deg),
turn directions (turn_direction), or explicit corner_pos.
"""
function generate_preset_l_bend(inlet::Pose3D, outlet::Pose3D, params::AbstractDict)::Vector{SplineControlPoint3D}
    R = max(0.3, Float64(get(params, "bend_radius", 2.5)))
    p_in = inlet.pos
    p_out = outlet.pos
    t_in = inlet.tangent
    t_out = outlet.tangent

    # Determine corner vertex C where incoming tangent line meets outgoing tangent line
    corner = if haskey(params, "corner_pos") && length(params["corner_pos"]) >= 3
        cp = params["corner_pos"]
        (Float64(cp[1]), Float64(cp[2]), Float64(cp[3]))
    elseif haskey(params, "leg1_length") || haskey(params, "leg2_length") || haskey(params, "bend_angle_deg") || haskey(params, "turn_direction")
        l1 = max(0.5, Float64(get(params, "leg1_length", 5.0)))
        l2 = max(0.5, Float64(get(params, "leg2_length", 5.0)))
        ang_deg = Float64(get(params, "bend_angle_deg", 90.0))
        turn_dir_str = lowercase(string(get(params, "turn_direction", "right")))
        sign_ang = if turn_dir_str == "left"
            1.0
        elseif turn_dir_str == "right"
            -1.0
        else
            ang_deg >= 0.0 ? 1.0 : -1.0
        end
        ang_rad = deg2rad(abs(ang_deg)) * sign_ang
        c = _v3_add(p_in, _v3_scale(t_in, l1))
        turned_dir = _v3_normalize((
            t_in[1] * cos(ang_rad) - t_in[2] * sin(ang_rad),
            t_in[1] * sin(ang_rad) + t_in[2] * cos(ang_rad),
            0.0
        ), (1.0, 0.0, 0.0))
        p_out = _v3_add(c, _v3_scale(turned_dir, l2))
        t_out = turned_dir
        c
    else
        # Intersect 2D rays p_in + s * t_in and p_out - u * t_out
        det = t_in[1] * (-t_out[2]) - t_in[2] * (-t_out[1])
        dx = p_out[1] - p_in[1]
        dy = p_out[2] - p_in[2]
        if abs(det) > 1e-3
            s = (dx * (-t_out[2]) - dy * (-t_out[1])) / det
            if s > 0.1
                (p_in[1] + s * t_in[1], p_in[2] + s * t_in[2], 0.5 * (p_in[3] + p_out[3]))
            else
                # Fallback orthogonal corner along inlet tangent
                proj = max(1.0, dx * t_in[1] + dy * t_in[2])
                (p_in[1] + proj * t_in[1], p_in[2] + proj * t_in[2], 0.5 * (p_in[3] + p_out[3]))
            end
        else
            # Parallel tangents -> delegate to S-curve
            return generate_preset_s_curve(inlet, outlet, params)
        end
    end

    v1 = _v3_sub(corner, p_in)
    v2 = _v3_sub(p_out, corner)
    L1 = _v3_len(v1)
    L2 = _v3_len(v2)
    if L1 < 1e-3 || L2 < 1e-3
        return generate_preset_s_curve(inlet, outlet, params)
    end

    u1 = _v3_scale(v1, 1.0 / L1)
    u2 = _v3_scale(v2, 1.0 / L2)
    cos_th = clamp(_v3_dot(u1, u2), -0.995, 0.995)
    theta = acos(cos_th) # turn angle in radians

    if theta < 0.05
        return generate_preset_straight(inlet, outlet, params)
    end

    tan_half = tan(theta * 0.5)
    max_trim = 0.90 * min(L1, L2)
    d_trim = min(R * tan_half, max_trim)
    r_eff = d_trim / max(1e-4, tan_half)

    b_start = _v3_sub(corner, _v3_scale(u1, d_trim))
    b_end   = _v3_add(corner, _v3_scale(u2, d_trim))
    cross_z = u1[1] * u2[2] - u1[2] * u2[1]
    n_arc_segs = max(1, Int(ceil(theta / (0.5 * π))))
    signed_step = theta * (cross_z >= 0.0 ? 1.0 : -1.0) / Float64(n_arc_segs)
    hlen = r_eff * _bezier_arc_kappa(abs(signed_step))
    center = _v3_add(b_start, _v3_scale((-u1[2], u1[1], 0.0), r_eff * (cross_z >= 0.0 ? 1.0 : -1.0)))
    start_radius = _v3_sub(b_start, center)

    cpts = SplineControlPoint3D[]
    if _v3_dist(p_in, b_start) > 0.05
        push!(cpts, SplineControlPoint3D(p_in, (0.0, 0.0, 0.0), (0.0, 0.0, 0.0), inlet.up))
    else
        b_start = p_in
    end
    for index in 0:n_arc_segs
        angle = Float64(index) * signed_step
        ca, sa = cos(angle), sin(angle)
        radial = (start_radius[1] * ca - start_radius[2] * sa, start_radius[1] * sa + start_radius[2] * ca, 0.0)
        tangent = (u1[1] * ca - u1[2] * sa, u1[1] * sa + u1[2] * ca, 0.0)
        pos = index == n_arc_segs ? b_end : _v3_add(center, radial)
        in_h = index > 0 ? _v3_scale(tangent, -hlen) : (0.0, 0.0, 0.0)
        out_h = index < n_arc_segs ? _v3_scale(tangent, hlen) : (0.0, 0.0, 0.0)
        push!(cpts, SplineControlPoint3D(pos, in_h, out_h, inlet.up))
    end
    if _v3_dist(b_end, p_out) > 0.05
        push!(cpts, SplineControlPoint3D(p_out, (0.0, 0.0, 0.0), (0.0, 0.0, 0.0), outlet.up))
    else
        cpts[end] = SplineControlPoint3D(p_out, cpts[end].in_handle, (0.0, 0.0, 0.0), outlet.up)
    end
    return cpts
end

"""
    generate_preset_u_turn(inlet::Pose3D, outlet::Pose3D, params::AbstractDict) -> Vector{SplineControlPoint3D}

Generates a 180° U-turn conveyor loop with straight legs and a semicircular turnaround of radius `R`.
"""
function generate_preset_u_turn(inlet::Pose3D, outlet::Pose3D, params::AbstractDict)::Vector{SplineControlPoint3D}
    R = max(0.5, Float64(get(params, "bend_radius", 2.0)))
    leg_len = max(1.5, Float64(get(params, "leg_length", 6.0)))
    return_len = max(1.5, Float64(get(params, "return_leg_length", leg_len)))
    dir = _v3_normalize((inlet.tangent[1], inlet.tangent[2], 0.0), (1.0, 0.0, 0.0))
    perp = (-dir[2], dir[1], 0.0) # 90° lateral offset

    p0 = inlet.pos
    p1 = _v3_add(p0, _v3_scale(dir, leg_len))
    apex = _v3_add(_v3_add(p1, _v3_scale(dir, R)), _v3_scale(perp, R))
    p2 = _v3_add(p1, _v3_scale(perp, 2.0 * R))
    p3 = get(params, "preserve_endpoints", false) ? outlet.pos : _v3_sub(p2, _v3_scale(dir, return_len))

    k90 = R * _bezier_arc_kappa(0.5 * π)
    end_handle = get(params, "preserve_endpoints", false) ? clamp(_v3_dist(p2, p3) * 0.25, 0.4, 2.0) : 0.0
    return [
        SplineControlPoint3D(p0, (0.0, 0.0, 0.0), (0.0, 0.0, 0.0), inlet.up),
        SplineControlPoint3D(p1, (0.0, 0.0, 0.0), _v3_scale(dir, k90), inlet.up),
        SplineControlPoint3D(apex, _v3_scale(perp, -k90), _v3_scale(perp, k90), inlet.up),
        SplineControlPoint3D(p2, _v3_scale(dir, k90), _v3_scale(dir, -end_handle), outlet.up),
        SplineControlPoint3D(p3, _v3_scale(outlet.tangent, -end_handle), (0.0, 0.0, 0.0), outlet.up)
    ]
end

"""
    generate_preset_circular_arc(inlet::Pose3D, outlet::Pose3D, params::AbstractDict) -> Vector{SplineControlPoint3D}

Generates a pure circular arc roller bed starting at `inlet.pos` along `inlet.tangent`
with radius `bend_radius` and sweep angle `sweep_angle_deg` (or connecting to `outlet.pos`).
"""
function generate_preset_circular_arc(inlet::Pose3D, outlet::Pose3D, params::AbstractDict)::Vector{SplineControlPoint3D}
    R = max(0.5, Float64(get(params, "bend_radius", 4.0)))
    sweep_deg = Float64(get(params, "sweep_angle_deg", 90.0))
    sweep_rad = deg2rad(clamp(sweep_deg, -350.0, 350.0))
    abs(sweep_rad) < 0.02 && return generate_preset_straight(inlet, outlet, params)

    sign_s = sweep_rad >= 0.0 ? 1.0 : -1.0
    dir = _v3_normalize((inlet.tangent[1], inlet.tangent[2], 0.0), (1.0, 0.0, 0.0))
    normal_to_center = (-sign_s * dir[2], sign_s * dir[1], 0.0)
    center = _v3_add(inlet.pos, _v3_scale(normal_to_center, R))

    # Split into at most 90° segments for <0.03% circular accuracy
    n_arc_segs = max(1, Int(ceil(abs(sweep_rad) / (0.5 * π))))
    d_theta = sweep_rad / Float64(n_arc_segs)
    hlen = R * _bezier_arc_kappa(abs(d_theta))
    r0 = _v3_sub(inlet.pos, center)
    dz = outlet.pos[3] - inlet.pos[3]

    cpts = SplineControlPoint3D[]
    for i in 0:n_arc_segs
        ang = Float64(i) * d_theta
        ca, sa = cos(ang), sin(ang)
        rx = r0[1] * ca - r0[2] * sa
        ry = r0[1] * sa + r0[2] * ca
        pz = inlet.pos[3] + (Float64(i) / Float64(n_arc_segs)) * dz
        pt = (center[1] + rx, center[2] + ry, pz)
        # Unit tangent along arc
        tx = -sign_s * (ry / R)
        ty =  sign_s * (rx / R)
        t_vec = _v3_normalize((tx, ty, 0.0), dir)
        in_h  = (i == 0) ? (0.0, 0.0, 0.0) : _v3_scale(t_vec, -hlen)
        out_h = (i == n_arc_segs) ? (0.0, 0.0, 0.0) : _v3_scale(t_vec, hlen)
        push!(cpts, SplineControlPoint3D(pt, in_h, out_h, inlet.up))
    end
    return cpts
end

"""
    generate_preset_serpentine(inlet::Pose3D, outlet::Pose3D, params::AbstractDict) -> Vector{SplineControlPoint3D}

Generates a multi-pass switchback accumulation conveyor between `inlet` and `outlet`.
"""
function generate_preset_serpentine(inlet::Pose3D, outlet::Pose3D, params::AbstractDict)::Vector{SplineControlPoint3D}
    passes = clamp(Int(round(Float64(get(params, "passes", 3)))), 2, 12)
    pitch  = max(1.2, Float64(get(params, "pass_spacing", get(params, "pitch", 2.0))))
    R      = 0.5 * pitch
    span   = max(3.0, Float64(get(params, "pass_length", _v3_dist(inlet.pos, outlet.pos))))
    infeed_length = clamp(Float64(get(params, "infeed_length", 0.0)), 0.0, span)
    outfeed_length = clamp(Float64(get(params, "outfeed_length", 0.0)), 0.0, span)
    dir    = _v3_normalize((inlet.tangent[1], inlet.tangent[2], 0.0), (1.0, 0.0, 0.0))
    perp   = (-dir[2], dir[1], 0.0)
    k90    = R * _bezier_arc_kappa(0.5 * π)
    core_origin = _v3_add(inlet.pos, _v3_scale(dir, infeed_length))

    cpts = SplineControlPoint3D[]
    if infeed_length > 0.001
        push!(cpts, SplineControlPoint3D(inlet.pos, (0.0, 0.0, 0.0), _v3_scale(dir, infeed_length / 3.0), inlet.up))
    end
    for p in 1:passes
        fwd = isodd(p)
        y_off = Float64(p - 1) * pitch
        base_start = _v3_add(core_origin, _v3_scale(perp, y_off))
        base_end   = _v3_add(base_start, _v3_scale(dir, span))
        s_pt = fwd ? base_start : base_end
        e_pt = fwd ? base_end   : base_start
        t_dir = fwd ? dir : _v3_scale(dir, -1.0)

        in_h_start = p == 1 && infeed_length > 0.001 ? _v3_scale(dir, -infeed_length / 3.0) : (p == 1 ? (0.0, 0.0, 0.0) : _v3_scale(t_dir, -k90))
        out_h_end = p == passes && outfeed_length > 0.001 ? _v3_scale(t_dir, outfeed_length / 3.0) : (p == passes ? (0.0, 0.0, 0.0) : _v3_scale(t_dir, k90))
        push!(cpts, SplineControlPoint3D(s_pt, in_h_start, (0.0, 0.0, 0.0), inlet.up))
        push!(cpts, SplineControlPoint3D(e_pt, (0.0, 0.0, 0.0), out_h_end, inlet.up))
        if p < passes
            apex = _v3_add(_v3_add(e_pt, _v3_scale(t_dir, R)), _v3_scale(perp, R))
            push!(cpts, SplineControlPoint3D(apex, _v3_scale(perp, -k90), _v3_scale(perp, k90), inlet.up))
        elseif outfeed_length > 0.001
            tail = _v3_add(e_pt, _v3_scale(t_dir, outfeed_length))
            push!(cpts, SplineControlPoint3D(tail, _v3_scale(t_dir, -outfeed_length / 3.0), (0.0, 0.0, 0.0), outlet.up))
        end
    end
    return cpts
end

"""
    generate_preset_spiral_helix(inlet::Pose3D, outlet::Pose3D, params::AbstractDict) -> Vector{SplineControlPoint3D}

Generates a 3D helical vertical spiral elevator/lowerator conveyor with `helix_radius` and `helix_turns`.
"""
function generate_preset_spiral_helix(inlet::Pose3D, outlet::Pose3D, params::AbstractDict)::Vector{SplineControlPoint3D}
    R = max(1.0, Float64(get(params, "helix_radius", 2.5)))
    turns = clamp(Float64(get(params, "helix_turns", 1.5)), 0.25, 6.0)
    dz = Float64(get(params, "elevation_gain", outlet.pos[3] - inlet.pos[3]))
    !haskey(params, "elevation_gain") && abs(dz) < 0.1 && (dz = 2.4)

    total_rad = turns * 2.0 * π
    n_segs = max(4, Int(ceil(turns * 4.0)))
    d_theta = total_rad / Float64(n_segs)
    hlen = R * _bezier_arc_kappa(d_theta)

    dir = _v3_normalize((inlet.tangent[1], inlet.tangent[2], 0.0), (1.0, 0.0, 0.0))
    normal_to_center = (-dir[2], dir[1], 0.0)
    center = _v3_add(inlet.pos, _v3_scale(normal_to_center, R))
    r0 = _v3_sub(inlet.pos, center)

    cpts = SplineControlPoint3D[]
    for i in 0:n_segs
        ang = Float64(i) * d_theta
        ca, sa = cos(ang), sin(ang)
        rx = r0[1] * ca - r0[2] * sa
        ry = r0[1] * sa + r0[2] * ca
        pz = inlet.pos[3] + (Float64(i) / Float64(n_segs)) * dz
        pt = (center[1] + rx, center[2] + ry, pz)
        tx = -(ry / R)
        ty =  (rx / R)
        tz = dz / (total_rad * R)
        t_vec = _v3_normalize((tx, ty, tz), dir)
        in_h  = (i == 0) ? (0.0, 0.0, 0.0) : _v3_scale(t_vec, -hlen)
        out_h = (i == n_segs) ? (0.0, 0.0, 0.0) : _v3_scale(t_vec, hlen)
        push!(cpts, SplineControlPoint3D(pt, in_h, out_h, (0.0, 0.0, 1.0)))
    end
    return cpts
end

"""
    generate_preset_custom_spline(inlet::Pose3D, outlet::Pose3D, params::AbstractDict) -> Vector{SplineControlPoint3D}

Builds a smooth Catmull-Rom / Cubic Bézier spline through arbitrary control points in `params["control_points"]`.
"""
function generate_preset_custom_spline(inlet::Pose3D, outlet::Pose3D, params::AbstractDict)::Vector{SplineControlPoint3D}
    raw_pts = get(params, "control_points", nothing)
    pts = Vec3[]
    if (raw_pts isa AbstractVector) && length(raw_pts) >= 2
        for item in raw_pts
            if item isa AbstractDict && haskey(item, "pos")
                p = item["pos"]
                length(p) >= 3 && push!(pts, (Float64(p[1]), Float64(p[2]), Float64(p[3])))
            elseif (item isa AbstractVector || item isa Tuple) && length(item) >= 3
                push!(pts, (Float64(item[1]), Float64(item[2]), Float64(item[3])))
            end
        end
    end

    if length(pts) < 2
        mid = _v3_scale(_v3_add(inlet.pos, outlet.pos), 0.5)
        dir = _v3_normalize(_v3_sub(outlet.pos, inlet.pos), inlet.tangent)
        perp = (-dir[2], dir[1], 0.0)
        p1 = _v3_add(mid, _v3_scale(perp, 2.5))
        pts = [inlet.pos, p1, outlet.pos]
    end

    M = length(pts)
    cpts = Vector{SplineControlPoint3D}(undef, M)
    for i in 1:M
        p_prev = pts[max(1, i - 1)]
        p_curr = pts[i]
        p_next = pts[min(M, i + 1)]
        secant = _v3_sub(p_next, p_prev)
        t_dir = if i == 1
            _v3_normalize(_v3_sub(p_next, p_curr), inlet.tangent)
        elseif i == M
            _v3_normalize(_v3_sub(p_curr, p_prev), outlet.tangent)
        else
            _v3_normalize(secant, (1.0, 0.0, 0.0))
        end
        d_in  = i > 1 ? 0.33 * _v3_dist(p_prev, p_curr) : 0.0
        d_out = i < M ? 0.33 * _v3_dist(p_curr, p_next) : 0.0
        item = (raw_pts isa AbstractVector && i <= length(raw_pts)) ? raw_pts[i] : nothing
        in_handle = item isa AbstractDict && haskey(item, "in_handle") && length(item["in_handle"]) >= 3 ?
            (Float64(item["in_handle"][1]), Float64(item["in_handle"][2]), Float64(item["in_handle"][3])) : _v3_scale(t_dir, -d_in)
        out_handle = item isa AbstractDict && haskey(item, "out_handle") && length(item["out_handle"]) >= 3 ?
            (Float64(item["out_handle"][1]), Float64(item["out_handle"][2]), Float64(item["out_handle"][3])) : _v3_scale(t_dir, d_out)
        cpts[i] = SplineControlPoint3D(
            p_curr,
            in_handle,
            out_handle,
            (0.0, 0.0, 1.0)
        )
    end
    return cpts
end

const CONVEYOR_SHAPE_PRESETS = Dict{Symbol, Function}(
    :straight      => generate_preset_straight,
    :s_curve       => generate_preset_s_curve,
    :l_bend        => generate_preset_l_bend,
    :u_turn        => generate_preset_u_turn,
    :circular_arc  => generate_preset_circular_arc,
    :serpentine    => generate_preset_serpentine,
    :spiral_helix  => generate_preset_spiral_helix,
    :custom_spline => generate_preset_custom_spline
)

"""
    register_conveyor_shape_preset!(name::Symbol, generator_fn::Function)

Registers a new parametric conveyor shape generator `(inlet::Pose3D, outlet::Pose3D, params::AbstractDict) -> Vector{SplineControlPoint3D}`.
"""
function register_conveyor_shape_preset!(name::Symbol, generator_fn::Function)
    CONVEYOR_SHAPE_PRESETS[name] = generator_fn
    return CONVEYOR_SHAPE_PRESETS
end

# ─────────────────────────────────────────────────────────────────────────────
# Layer 3: Automatic Conveyor Network Junction Pose Solver & IR Baker
# ─────────────────────────────────────────────────────────────────────────────

function _parse_pose3d(raw, default_pos::Vec3, default_tan::Vec3)::Pose3D
    if raw isa AbstractDict
        p_raw = get(raw, "pos", get(raw, :pos, get(raw, "position", get(raw, :position, default_pos))))
        t_raw = get(raw, "tangent", get(raw, :tangent, default_tan))
        p = (length(p_raw) >= 3) ? (Float64(p_raw[1]), Float64(p_raw[2]), Float64(p_raw[3])) : default_pos
        t = (length(t_raw) >= 3) ? (Float64(t_raw[1]), Float64(t_raw[2]), Float64(t_raw[3])) : default_tan
        return Pose3D(p, t)
    end
    return Pose3D(default_pos, default_tan)
end

"""
    compute_loop_conveyor_poses(hub_coords::Vector{Vec3}; bend_radius::Float64=2.5) -> Vector{NamedTuple}

Given an ordered sequence of `K` station hub vertices `H_1, ..., H_K` forming a closed loop
(`1 -> 2 -> ... -> K -> 1`), computes tangent-aligned `inlet_pose`, `outlet_pose`, and `corner_pos`
for each conveyor `k` so that:
1. Conveyor `k` runs straight along side `k` and rounds corner `H_{k+1}` with radius `bend_radius`.
2. `outlet_pose(k) == inlet_pose(k+1)` (both position and unit tangent) for every `k = 1..K`!
"""
function compute_loop_conveyor_poses(hub_coords::Vector{Vec3}; bend_radius::Float64 = 2.5)
    K = length(hub_coords)
    K == 0 && return NamedTuple[]
    if K == 1
        p = hub_coords[1]
        in_p = Pose3D(p, (1.0, 0.0, 0.0))
        out_p = Pose3D(_v3_add(p, (6.0, 0.0, 0.0)), (1.0, 0.0, 0.0))
        return [(inlet = in_p, outlet = out_p, corner = out_p.pos, preset = :straight)]
    end

    # Unit direction of each polygon side k: H_k -> H_{next(k)}
    side_dirs = Vector{Vec3}(undef, K)
    side_lens = Vector{Float64}(undef, K)
    for k in 1:K
        nxt = mod1(k + 1, K)
        diff = _v3_sub(hub_coords[nxt], hub_coords[k])
        l = max(1.0, _v3_len(diff))
        side_lens[k] = l
        side_dirs[k] = _v3_scale(diff, 1.0 / l)
    end

    # Trim distance at each vertex H_k where side prev(k) turns into side k
    trims = Vector{Float64}(undef, K)
    for k in 1:K
        prv = mod1(k - 1, K)
        u_in  = side_dirs[prv]
        u_out = side_dirs[k]
        cos_th = clamp(_v3_dot(u_in, u_out), -0.995, 0.995)
        theta = acos(cos_th)
        tan_half = tan(theta * 0.5)
        max_trim = 0.35 * min(side_lens[prv], side_lens[k])
        trims[k] = min(bend_radius * tan_half, max_trim)
    end

    results = Vector{NamedTuple}(undef, K)
    for k in 1:K
        nxt = mod1(k + 1, K)
        u_k   = side_dirs[k]
        u_nxt = side_dirs[nxt]
        # Inlet of conveyor k is right after vertex H_k's corner fillet
        p_in  = _v3_add(hub_coords[k], _v3_scale(u_k, trims[k]))
        # Outlet of conveyor k is right after vertex H_{nxt}'s corner fillet (== Inlet of conveyor nxt!)
        p_out = _v3_add(hub_coords[nxt], _v3_scale(u_nxt, trims[nxt]))
        results[k] = (
            inlet  = Pose3D(p_in, u_k),
            outlet = Pose3D(p_out, u_nxt),
            corner = hub_coords[nxt],
            preset = :l_bend
        )
    end
    return results
end

"""
    bake_all_conveyor_curves!(ir::ExecutionGraphIR, flat_spec::TypedSceneSpec) -> Dict{String, BakedConveyorCurve}

Resolves `inlet_pose`, `outlet_pose`, and `shape_preset` for all conveyor elements in `flat_spec`,
enforcing C¹ junction continuity across connected conveyors, and populates `ir.conveyor_curves`.
"""
function bake_all_conveyor_curves!(ir::ExecutionGraphIR, flat_spec::TypedSceneSpec)::Dict{String, BakedConveyorCurve}
    elem_by_id = Dict{String, ElementRecord}(e.id => e for e in flat_spec.elements)
    conv_ids = [e.id for e in flat_spec.elements if lowercase(strip(e.kind)) == "conveyor" || endswith(lowercase(strip(e.kind)), "/conveyor")]

    # Build conveyor-to-conveyor adjacency from ir.downstream_conns
    conv_set = Set{String}(conv_ids)
    conv_out = Dict{String, Vector{String}}(cid => String[] for cid in conv_ids)
    conv_in  = Dict{String, Vector{String}}(cid => String[] for cid in conv_ids)
    for cid in conv_ids
        for (dst, _, _, _) in get(ir.downstream_conns, cid, Tuple{String, String, String, String}[])
            if dst in conv_set
                push!(conv_out[cid], dst)
                push!(conv_in[dst], cid)
            end
        end
    end

    # First pass: determine natural anchor / direction of each conveyor
    inlet_poses  = Dict{String, Pose3D}()
    outlet_poses = Dict{String, Pose3D}()
    presets      = Dict{String, Symbol}()
    params_map   = Dict{String, Dict{String, Any}}()

    for cid in conv_ids
        el = elem_by_id[cid]
        ext = el.geometry.extensions
        props = el.properties

        raw_preset = get(ext, "shape_preset", get(props, "shape_preset", "straight"))
        preset_sym = Symbol(lowercase(strip(string(raw_preset))))
        if !haskey(CONVEYOR_SHAPE_PRESETS, preset_sym)
            preset_sym = :straight
        end

        sp = Dict{String, Any}()
        if haskey(ext, "shape_params") && ext["shape_params"] isa AbstractDict
            for (k, v) in ext["shape_params"]
                sp[string(k)] = v
            end
        end
        for k in ("bend_radius", "sweep_angle_deg", "passes", "pass_spacing", "pass_length", "infeed_length", "outfeed_length", "helix_radius", "helix_turns", "elevation_gain", "corner_pos", "control_points", "tangent_scale", "leg_length", "return_leg_length", "auto_join", "lateral_offset")
            if haskey(sp, k)
                continue
            elseif haskey(ext, k)
                sp[k] = ext[k]
            elseif haskey(props, k)
                sp[k] = props[k]
            end
        end

        pos = el.transform.position
        rot_z_rad = deg2rad(el.transform.rotation[3])
        default_dir = (cos(rot_z_rad), sin(rot_z_rad), 0.0)
        dims = get(ir.spatial_dimensions, cid, (6.0, 1.2, 0.8))
        len_prop = Float64(get(props, "length", dims[1]))
        visual_span = max(2.0, dims[1])

        if haskey(ext, "inlet_pose") && haskey(ext, "outlet_pose")
            in_p  = _parse_pose3d(ext["inlet_pose"], pos, default_dir)
            out_p = _parse_pose3d(ext["outlet_pose"], _v3_add(pos, _v3_scale(default_dir, visual_span)), default_dir)
            if !haskey(sp, "auto_join")
                sp["auto_join"] = true
            end
            if !(ext["outlet_pose"] isa AbstractDict) || !get(ext["outlet_pose"], "_derived", false)
                sp["preserve_endpoints"] = true
            end
            inlet_poses[cid]  = in_p
            outlet_poses[cid] = out_p
            presets[cid]      = preset_sym
            params_map[cid]   = sp
            continue
        end

        # Auto-align with downstream conveyor or downstream element if connected
        outs = conv_out[cid]
        if !isempty(outs)
            dst_cid = first(outs)
            dst_pos = elem_by_id[dst_cid].transform.position
            diff = _v3_sub(dst_pos, pos)
            dist = _v3_len(diff)
            if dist > 0.5
                dir_to_dst = _v3_scale(diff, 1.0 / dist)
                if !haskey(sp, "auto_join")
                    sp["auto_join"] = true
                end
                sp["preserve_endpoints"] = true
                inlet_poses[cid]  = Pose3D(pos, dir_to_dst)
                outlet_poses[cid] = Pose3D(dst_pos, dir_to_dst)
                presets[cid]      = preset_sym
                params_map[cid]   = sp
                continue
            end
        end

        # Standalone conveyor or terminal conveyor in a chain
        if !isempty(conv_in[cid])
            up_cid = first(conv_in[cid])
            up_pos = elem_by_id[up_cid].transform.position
            diff_in = _v3_sub(pos, up_pos)
            d_in = _v3_len(diff_in)
            dir_in = d_in > 0.5 ? _v3_scale(diff_in, 1.0 / d_in) : default_dir
            inlet_poses[cid]  = Pose3D(pos, dir_in)
            outlet_poses[cid] = Pose3D(_v3_add(pos, _v3_scale(dir_in, max(6.0, min(15.0, len_prop)))), dir_in)
        else
            # Check non-conveyor downstream to orient direction
            all_downs = get(ir.downstream_conns, cid, Tuple{String, String, String, String}[])
            dir_flow = default_dir
            if !isempty(all_downs)
                dst_id = first(all_downs)[1]
                if haskey(ir.spatial_positions, dst_id)
                    dst_p = ir.spatial_positions[dst_id]
                    if dst_p[1] < pos[1] - 0.5 && abs(rot_z_rad) < 1e-3
                        dir_flow = (-1.0, 0.0, 0.0)
                    end
                end
            end
            p_start = dir_flow[1] < -0.5 ? _v3_add(pos, (visual_span, 0.0, 0.0)) : pos
            p_end   = _v3_add(p_start, _v3_scale(dir_flow, visual_span))
            inlet_poses[cid]  = Pose3D(p_start, dir_flow)
            outlet_poses[cid] = Pose3D(p_end, dir_flow)
        end
        presets[cid]    = preset_sym
        params_map[cid] = sp
    end

    # Second pass: if conveyors form a closed loop without explicit poses, upgrade to filleted loop poses
    if length(conv_ids) >= 3 && all(cid -> !haskey(elem_by_id[cid].geometry.extensions, "inlet_pose"), conv_ids)
        # Check if conv_out forms a single cycle visiting all conv_ids
        visited = String[]
        curr = conv_ids[1]
        for _ in 1:length(conv_ids)
            push!(visited, curr)
            outs = conv_out[curr]
            isempty(outs) && break
            nxt = first(outs)
            if nxt == conv_ids[1] && length(visited) == length(conv_ids)
                # Found full closed loop!
                hub_coords = [elem_by_id[c].transform.position for c in visited]
                loop_poses = compute_loop_conveyor_poses(hub_coords; bend_radius=2.5)
                for (idx, c) in enumerate(visited)
                    inlet_poses[c]  = loop_poses[idx].inlet
                    outlet_poses[c] = loop_poses[idx].outlet
                    presets[c]      = loop_poses[idx].preset
                    params_map[c]["corner_pos"]  = [loop_poses[idx].corner[1], loop_poses[idx].corner[2], loop_poses[idx].corner[3]]
                    params_map[c]["bend_radius"] = 2.5
                end
                break
            end
            curr in visited && break
            curr = nxt
        end
    end

    # Third pass: enforce C¹ tangent continuity at shared conveyor junctions
    for cid in conv_ids
        outs = conv_out[cid]
        if length(outs) == 1
            dst_cid = outs[1]
            if _v3_dist(outlet_poses[cid].pos, inlet_poses[dst_cid].pos) < 1e-3
                shared_tan = inlet_poses[dst_cid].tangent
                outlet_poses[cid] = Pose3D(inlet_poses[dst_cid].pos, shared_tan, outlet_poses[cid].up)
            end
        end
    end

    # Fourth pass: generate control points and bake each conveyor curve
    for cid in conv_ids
        preset_sym = presets[cid]
        gen_fn = get(CONVEYOR_SHAPE_PRESETS, preset_sym, generate_preset_straight)
        cpts = gen_fn(inlet_poses[cid], outlet_poses[cid], params_map[cid])
        ir.conveyor_curves[cid] = bake_conveyor_curve(preset_sym, cpts; num_samples=64)
    end

    return ir.conveyor_curves
end
