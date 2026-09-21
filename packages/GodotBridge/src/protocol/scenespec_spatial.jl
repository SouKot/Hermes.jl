# packages/GodotBridge/src/protocol/scenespec_spatial.jl
#
# Universal Multi-Level & Continuous 3D Spatial Resolution Engine.
# Powered by KernelAbstractions.jl and StaticArrays.jl for SIMD and GPU performance.

using StaticArrays
using LinearAlgebra
using KernelAbstractions

"""
    SpatialBufferSoA

Structure-of-Arrays (SoA) contiguous binary buffer containing resolved absolute
spatial transforms for N elements. Highly optimized for SIMD execution, GPU
staging (`BaseGPUContext`), and direct binary blitting to Godot `PackedByteArray`.
"""
struct SpatialBufferSoA
    count         :: Int
    positions     :: Vector{Float32} # 3N floats: X, Y, Z (meters)
    rotations     :: Vector{Float32} # 3N floats: Euler RX, RY, RZ (radians or degrees)
    scales        :: Vector{Float32} # 3N floats: SX, SY, SZ
    level_indices :: Vector{Int32}   # N ints: index of owning level (or -1 for free 3D)
    ids           :: Vector{String}  # N strings: element identifiers
end

function SpatialBufferSoA(n::Int)
    return SpatialBufferSoA(
        n,
        zeros(Float32, 3 * n),
        zeros(Float32, 3 * n),
        ones(Float32, 3 * n),
        fill(Int32(-1), n),
        String[]
    )
end

# ── Coordinate System Conversions (Z-up <-> Godot 3D) ─────────────────────────

"""
    zup_to_godot_position(p) -> (x, z, -y)

Converts right-handed Z-up coordinates (X East, Y North, Z Elevation)
to Godot's internal 3D coordinates (X Right, Y Up, -Z Forward).
"""
@inline function zup_to_godot_position(p::Union{NTuple{3, Float64}, NTuple{3, Float32}, SVector{3}})
    return (Float64(p[1]), Float64(p[3]), -Float64(p[2]))
end

"""
    godot_to_zup_position(p) -> (x, -z, y)

Converts Godot 3D coordinates to right-handed Z-up coordinates.
"""
@inline function godot_to_zup_position(p::Union{NTuple{3, Float64}, NTuple{3, Float32}, SVector{3}})
    return (Float64(p[1]), -Float64(p[3]), Float64(p[2]))
end

"""
    zup_to_godot_rotation(r) -> (rx, rz, -ry)

Converts Z-up Euler rotations to Godot 3D Euler rotations.
"""
@inline function zup_to_godot_rotation(r::Union{NTuple{3, Float64}, NTuple{3, Float32}, SVector{3}})
    return (Float64(r[1]), Float64(r[3]), -Float64(r[2]))
end

# ── Transform Math & Composition ──────────────────────────────────────────────

"""
    euler_z_rotation_matrix(yaw_rad) -> SMatrix{3,3,Float64}

Builds a 3x3 rotation matrix for ground-plane yaw (rotation around canonical Z axis).
"""
@inline function euler_z_rotation_matrix(yaw_rad::Float64)
    c = cos(yaw_rad)
    s = sin(yaw_rad)
    return @SMatrix [
        c  -s  0.0;
        s   c  0.0;
        0.0 0.0 1.0
    ]
end

"""
    compose_transforms(parent::TransformRecord, child::TransformRecord) -> TransformRecord

Composes a parent rigid transform with a local child transform:
  Pos_world = Pos_parent + R(parent) * (Scale_parent .* Pos_child)
  Rot_world = Rot_parent + Rot_child
  Scale_world = Scale_parent .* Scale_child
"""
function compose_transforms(parent::TransformRecord, child::TransformRecord)::TransformRecord
    p_pos = SVector{3, Float64}(parent.position)
    p_rot = SVector{3, Float64}(parent.rotation)
    p_scale = SVector{3, Float64}(parent.scale)

    c_pos = SVector{3, Float64}(child.position)
    c_rot = SVector{3, Float64}(child.rotation)
    c_scale = SVector{3, Float64}(child.scale)

    # Convert parent yaw (Z-rotation) to rotation matrix. Assumes radians if small, degrees if > 2pi
    yaw = p_rot[3]
    yaw_rad = abs(yaw) > 6.283185307179586 ? deg2rad(yaw) : yaw
    R = euler_z_rotation_matrix(yaw_rad)

    scaled_child = p_scale .* c_pos
    w_pos = p_pos + (R * scaled_child)
    w_rot = p_rot + c_rot
    w_scale = p_scale .* c_scale

    return TransformRecord(
        (w_pos[1], w_pos[2], w_pos[3]),
        (w_rot[1], w_rot[2], w_rot[3]),
        (w_scale[1], w_scale[2], w_scale[3])
    )
end

# ── KernelAbstractions Hardware-Portable Batch Transform Kernel ───────────────

"""
    compose_transforms_ka_kernel!(out_positions, out_rotations, out_scales,
                                  parent_pos, parent_rot, parent_scale,
                                  child_pos, child_rot, child_scale, N)

Hardware-portable KernelAbstractions kernel. Dispatches identically on
Multicore CPU thread pools or any vendor GPU (CUDA, ROCm, Metal, oneAPI).
"""
@kernel function compose_transforms_ka_kernel!(
    out_pos     :: AbstractVector{Float32},
    out_rot     :: AbstractVector{Float32},
    out_scale   :: AbstractVector{Float32},
    @Const(parent_pos   :: AbstractVector{Float32}),
    @Const(parent_rot   :: AbstractVector{Float32}),
    @Const(parent_scale :: AbstractVector{Float32}),
    @Const(child_pos    :: AbstractVector{Float32}),
    @Const(child_rot    :: AbstractVector{Float32}),
    @Const(child_scale  :: AbstractVector{Float32}),
    N
)
    i = @index(Global, Linear)
    if i <= N
        base_idx = Int32(3) * (i - Int32(1)) + Int32(1)

        # Read parent and child components
        pp_x = parent_pos[base_idx];   pp_y = parent_pos[base_idx+1]; pp_z = parent_pos[base_idx+2]
        pr_x = parent_rot[base_idx];   pr_y = parent_rot[base_idx+1]; pr_z = parent_rot[base_idx+2]
        ps_x = parent_scale[base_idx]; ps_y = parent_scale[base_idx+1]; ps_z = parent_scale[base_idx+2]

        cp_x = child_pos[base_idx];   cp_y = child_pos[base_idx+1]; cp_z = child_pos[base_idx+2]
        cr_x = child_rot[base_idx];   cr_y = child_rot[base_idx+1]; cr_z = child_rot[base_idx+2]
        cs_x = child_scale[base_idx]; cs_y = child_scale[base_idx+1]; cs_z = child_scale[base_idx+2]

        # Compose yaw rotation (Z-axis) in radians for local offsets
        yaw_rad = deg2rad(pr_z)
        c = cos(yaw_rad)
        s = sin(yaw_rad)

        scaled_cx = ps_x * cp_x
        scaled_cy = ps_y * cp_y
        scaled_cz = ps_z * cp_z

        rot_cx = c * scaled_cx - s * scaled_cy
        rot_cy = s * scaled_cx + c * scaled_cy
        rot_cz = scaled_cz

        out_pos[base_idx]   = pp_x + rot_cx
        out_pos[base_idx+1] = pp_y + rot_cy
        out_pos[base_idx+2] = pp_z + rot_cz

        out_rot[base_idx]   = pr_x + cr_x
        out_rot[base_idx+1] = pr_y + cr_y
        out_rot[base_idx+2] = pr_z + cr_z

        out_scale[base_idx]   = ps_x * cs_x
        out_scale[base_idx+1] = ps_y * cs_y
        out_scale[base_idx+2] = ps_z * cs_z
    end
end

const compose_transforms_kernel! = compose_transforms_ka_kernel!

# ── Multi-Level & Elevation Queries ───────────────────────────────────────────

"""
    resolve_element_elevation(elem::ElementRecord, spatial::Union{SpatialConfig, Nothing}) -> Float64

Computes the absolute Z coordinate (elevation) of an element. If bound to a level
in `spatial.levels`, computes Z = level.elevation + local_z. If not bound to a level,
returns the element's direct Z coordinate (continuous 3D).
"""
function resolve_element_elevation(elem::ElementRecord, spatial::Union{SpatialConfig, Nothing})::Float64
    local_z = elem.transform.position[3]
    if isempty(elem.level_id) || spatial === nothing
        return local_z
    end

    for level in spatial.levels
        if level.id == elem.level_id
            return level.elevation + local_z
        end
    end
    return local_z
end

"""
    filter_level_elements(spec::TypedSceneSpec, level_id::String) -> Vector{ElementRecord}

Returns all elements located on the specified spatial level.
"""
function filter_level_elements(spec::TypedSceneSpec, level_id::String)::Vector{ElementRecord}
    return filter(e -> e.level_id == level_id, spec.elements)
end

"""
    resolve_vertical_connector(elem::ElementRecord, spatial::Union{SpatialConfig, Nothing})
        -> (base_elevation::Float64, target_elevation::Float64, height::Float64)

Resolves vertical extents for vertical connectors (stairs, elevators, ramps, conveyors).
"""
function resolve_vertical_connector(elem::ElementRecord, spatial::Union{SpatialConfig, Nothing})
    ve = elem.vertical_extent
    if ve === nothing
        z = resolve_element_elevation(elem, spatial)
        h = elem.geometry.height !== nothing ? elem.geometry.height : 3.0
        return (z, z + h, h)
    end

    base_z = Float64(get(ve, "base_elevation", resolve_element_elevation(elem, spatial)))
    h = Float64(get(ve, "height", 3.0))
    return (base_z, base_z + h, h)
end

"""
    resolve_all_transforms(spec::TypedSceneSpec; backend=AutoBackend())::SpatialBufferSoA

Extracts all resolved absolute 3D transforms for elements in `spec`, assembling
a contiguous `SpatialBufferSoA` memory layout ready for SIMD, GPU, and Godot binary transfer.
"""
function resolve_all_transforms(spec::TypedSceneSpec; backend::AbstractExecutionBackend=AutoBackend())::SpatialBufferSoA
    N = length(spec.elements)
    soa = SpatialBufferSoA(N)

    # Build level index map: level_id -> Int32 index (0-based)
    level_map = Dict{String, Int32}()
    if spec.spatial !== nothing
        for (idx, lvl) in enumerate(spec.spatial.levels)
            level_map[lvl.id] = Int32(idx - 1)
        end
    end

    for i in 1:N
        elem = spec.elements[i]
        push!(soa.ids, elem.id)

        base_idx = 3 * (i - 1) + 1
        pos = elem.transform.position
        rot = elem.transform.rotation
        scale = elem.transform.scale

        # Compute absolute Z
        abs_z = resolve_element_elevation(elem, spec.spatial)

        soa.positions[base_idx]   = Float32(pos[1])
        soa.positions[base_idx+1] = Float32(pos[2])
        soa.positions[base_idx+2] = Float32(abs_z)

        soa.rotations[base_idx]   = Float32(rot[1])
        soa.rotations[base_idx+1] = Float32(rot[2])
        soa.rotations[base_idx+2] = Float32(rot[3])

        soa.scales[base_idx]   = Float32(scale[1])
        soa.scales[base_idx+1] = Float32(scale[2])
        soa.scales[base_idx+2] = Float32(scale[3])

        soa.level_indices[i] = get(level_map, elem.level_id, Int32(-1))
    end

    return soa
end

# ── Direct Binary Serialization for Godot PackedByteArray ─────────────────────

"""
    to_godot_byte_array(soa::SpatialBufferSoA) -> Vector{UInt8}

Serializes `SpatialBufferSoA` into a contiguous byte vector. Godot's C++ / GDScript
`PackedByteArray` directly decodes this buffer with zero deserialization overhead.

Binary Format:
- Header: UInt32 count (N)
- positions: 3N * Float32 (12N bytes)
- rotations: 3N * Float32 (12N bytes)
- scales:    3N * Float32 (12N bytes)
- level_indices: N * Int32 (4N bytes)
Total Payload Size: 4 + 40N bytes.
"""
function to_godot_byte_array(soa::SpatialBufferSoA)::Vector{UInt8}
    N = soa.count
    total_bytes = 4 + 40 * N
    buf = Vector{UInt8}(undef, total_bytes)

    # 1. Write UInt32 count
    u32_view = reinterpret(UInt32, view(buf, 1:4))
    u32_view[1] = UInt32(N)

    # 2. Copy positions (12N bytes)
    offset = 5
    pos_bytes = 12 * N
    if N > 0
        unsafe_copyto!(reinterpret(Ptr{Float32}, pointer(buf, offset)), pointer(soa.positions), 3 * N)
        offset += pos_bytes

        # 3. Copy rotations (12N bytes)
        unsafe_copyto!(reinterpret(Ptr{Float32}, pointer(buf, offset)), pointer(soa.rotations), 3 * N)
        offset += pos_bytes

        # 4. Copy scales (12N bytes)
        unsafe_copyto!(reinterpret(Ptr{Float32}, pointer(buf, offset)), pointer(soa.scales), 3 * N)
        offset += pos_bytes

        # 5. Copy level indices (4N bytes)
        unsafe_copyto!(reinterpret(Ptr{Int32}, pointer(buf, offset)), pointer(soa.level_indices), N)
    end

    return buf
end
