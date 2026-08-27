# geometry.jl — Shared geometric primitives for SimCrowd
#
# Single source of truth for geometric query functions used by:
#   - CSM  (Sprint 3L): wall repulsion via nearest_point_on_segment
#   - ORCA (Sprint 3N): local linearization via nearest_point_on_arc (stub → full in 3N)
#
# Design principles:
#   - No SimCrowd-internal dependencies: pure geometry functions only.
#   - GPU-safe: no heap allocation, only SVector arithmetic. All functions @inline.
#   - Zero-allocation: all intermediate values are stack-allocated SVectors / scalars.

using StaticArrays
using LinearAlgebra

"""
    nearest_point_on_segment(p1, p2, q) → (point, dist, t)

Nearest point on closed line segment [p1, p2] to query point q.

Returns:
- `point`: nearest point on the segment (`SVector{2,F}`)
- `dist`:  Euclidean distance from q to point (`F`)
- `t`:     parametric coordinate ∈ [0, 1] along the segment (0 → p1, 1 → p2)

Degenerate case (p1 ≈ p2): returns (p1, ‖q − p1‖, 0).

GPU-safe: no heap allocation. Used by CSM wall repulsion (V2) and future ORCA arc stub.
"""
@inline function nearest_point_on_segment(
    p1 :: SVector{2,F},
    p2 :: SVector{2,F},
    q  :: SVector{2,F}
) :: Tuple{SVector{2,F}, F, F} where {F<:AbstractFloat}
    d    = p2 - p1
    len2 = dot(d, d)
    if len2 < eps(F)
        # Degenerate: p1 == p2 (zero-length segment)
        dist = norm(q - p1)
        return p1, dist, zero(F)
    end
    t  = clamp(dot(q - p1, d) / len2, zero(F), one(F))
    pt = p1 + t * d
    return pt, norm(q - pt), t
end

"""
    nearest_point_on_arc(center, radius, q) → (point, dist)

Nearest point on the circumference of a circle (center `center`, radius `radius`)
to query point q.

Returns:
- `point`: nearest surface point (`SVector{2,F}`)
- `dist`:  absolute distance from q to the circle surface (`F`)

Works for both exterior (q outside the circle) and interior (q inside the circle)
queries.

**Sprint 3N STUB** — this function is complete for simple circular obstacles.
Sprint 3N will extend this with `nearest_tangent_lines_for_orca` to generate
local half-plane constraints for the ORCA LP solver on curved walls.

GPU-safe: no heap allocation.
"""
@inline function nearest_point_on_arc(
    center :: SVector{2,F},
    radius :: F,
    q      :: SVector{2,F}
) :: Tuple{SVector{2,F}, F} where {F<:AbstractFloat}
    dir = q - center
    d   = norm(dir)
    if d < eps(F)
        # q is at center — return arbitrary point on circle
        return center + SVector(radius, zero(F)), radius
    end
    pt   = center + (radius / d) * dir   # nearest surface point
    dist = abs(d - radius)               # distance from q to surface
    return pt, dist
end
