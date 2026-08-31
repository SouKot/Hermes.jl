# systems/navigation.jl -- NavigationField (Fast Marching Method)
#
# Sprint 3N-b (2026-08-27): Modular navigation layer shared by CSM and Hybrid FSM.
# Sprint 3O   (2026-08-31): AbstractNavigationField{F} trait + GPU-forward parameterized storage.
#
# Architecture:
#   - AbstractNavigationField{F}: trait — only required method is get_nav_direction(nav, pos).
#   - NavigationField{F, A}: FMM concrete implementation, dirs stored as Array{F,3} (2,nx,ny).
#   - build_navigation_field(...): CPU build from WallSegments + goal → NavigationField{F,Array{F,3}}.
#   - to_device(nav, backend): upload precomputed dirs to GPU → NavigationField{F, DevArray}.
#   - get_nav_direction(nav, pos): bilinear-interpolated direction; @inline for KA kernel inlining.
#   - update_csm_system!(world, dt, nav): CSM dispatch using nav for direction.
#   - update_navigation_system!(world, nav): SFM/Force-based dispatch.
#
# dirs layout: (2, nx, ny) — plain Float array, GPU-uploadable, SIMD-friendly.
#   dirs[1, ix, iy] = x-component of unit direction at grid cell (ix, iy)
#   dirs[2, ix, iy] = y-component of unit direction at grid cell (ix, iy)
#
# GPU path:
#   cpu_nav = build_navigation_field(walls, goal, 0.05f0)   # CPU-only (Eikonal.jl)
#   gpu_nav = to_device(cpu_nav, CUDABackend())              # upload once
#   scene   = SimScene(world, gpu_search, gpu_nav, config)  # works unchanged
#
# Extension:
#   struct MyNavField{F} <: AbstractNavigationField{F}; ...; end
#   get_nav_direction(nav::MyNavField{F}, pos::SVector{2,F}) where F = ...
#   # All update_*_system! calls accept it automatically.
#
# Eikonal.jl semantics (CRITICAL):
#   fmm.v = SLOWNESS (cost per unit length), NOT speed.
#   v=1.0  → free space  (|∇T|=1, T = Euclidean distance)
#   v=1e9  → impassable  (obstacle cells have extremely high travel cost)
#   v=1e-9 → transparent (obstacles WRONG -- FMM routes through walls!)
#
# Reference:
#   Sethian, J.A. (1999). Level Set Methods and Fast Marching Methods.
#   JuPedSim v1.4.2 -- routing engine provides e0 = step.ToNextTarget() for CSM.

using Eikonal
using StaticArrays
using LinearAlgebra
using KernelAbstractions

# ── Abstract interface ────────────────────────────────────────────────────────

"""
    AbstractNavigationField{F<:AbstractFloat}

Abstract supertype for all navigation field implementations.

## Required interface

    get_nav_direction(nav::AbstractNavigationField{F}, pos::SVector{2,F}) → SVector{2,F}

Return a unit vector pointing toward the goal at world position `pos`.
All update systems (`update_csm_system!`, `update_hybrid_fsm_system!`,
`update_navigation_system!`) accept any subtype — zero changes when
switching between FMM, NavMesh, or hierarchical routing.

## Extension pattern

    struct MyNavField{F} <: AbstractNavigationField{F}
        ...
    end
    @inline get_nav_direction(nav::MyNavField{F}, pos::SVector{2,F}) where F = ...

## Concrete implementations

- `NavigationField{F, A}` — FMM (Eikonal) precomputed grid (this file)
"""
abstract type AbstractNavigationField{F<:AbstractFloat} end


# ── Concrete FMM implementation ───────────────────────────────────────────────

"""
    NavigationField{F<:AbstractFloat, A<:AbstractArray{F}} <: AbstractNavigationField{F}

Precomputed FMM-based direction field for pedestrian routing. Stores the
unit direction grid `-∇T / |∇T|` as a plain numeric array — GPU-uploadable
and SIMD-friendly.

## Fields
- `grid_min`:  world-coordinate of grid origin (bottom-left corner of cell [1,1])
- `cell_size`: side length of each grid cell (m)
- `dims`:      `(nx, ny)` number of grid cells
- `dirs`:      `Array{F,3}` of shape `(2, nx, ny)` — plain floats, no SVector boxing.
               `dirs[1, ix, iy]` = x-component, `dirs[2, ix, iy]` = y-component.
- `goal_pos`:  goal position in world coordinates (fallback when pos is out of grid)

## Storage layout: `(2, nx, ny)`

In Julia (column-major), dim 1 varies fastest:
- `dirs[1, ix, iy]` and `dirs[2, ix, iy]` are adjacent in memory → one cache line
  fetches both components for a cell (AoS within a cell).
- No `SVector` boxing → directly `copyto!`-able to `CuArray` / `ROCArray`.
- `@inline get_nav_direction` compiles into KA GPU kernels without overhead.

## Type aliases

    NavigationField{F, Array{F,3}}     — CPU  (from build_navigation_field)
    NavigationField{F, CuArray{F,3}}   — GPU  (from to_device(nav, CUDABackend()))

## Notes
- Not `isbits`: holds a heap array. Pass by reference to update functions.
- Precomputed once per scenario. Rebuild via `build_navigation_field` if geometry changes.
- FMM solve is always CPU-only (Eikonal.jl). Use `to_device` for GPU upload.
"""
struct NavigationField{F<:AbstractFloat, A<:AbstractArray{F}} <: AbstractNavigationField{F}
    grid_min  :: SVector{2, F}
    cell_size :: F
    dims      :: Tuple{Int, Int}
    dirs      :: A              # shape (2, nx, ny) — dirs[1,ix,iy]=dx, dirs[2,ix,iy]=dy
    goal_pos  :: SVector{2, F}
end


# ── Wall rasterization ────────────────────────────────────────────────────────

"""
    _rasterize_segment!(mask, p1, p2, grid_min, cell_size, nx, ny, buf_cells)

Mark all grid cells within `buf_cells` cells of segment (p1, p2) as obstacles.
Uses DDA line traversal + circular buffer erosion.
"""
function _rasterize_segment!(
    mask      :: Matrix{Bool},
    p1        :: SVector{2,F},
    p2        :: SVector{2,F},
    grid_min  :: SVector{2,F},
    cell_size :: F,
    nx        :: Int,
    ny        :: Int,
    buf_cells :: Int = 1
) where {F<:AbstractFloat}
    # World → grid index (float)
    to_grid(p) = (p - grid_min) / cell_size .+ F(0.5)  # cell centers at 0.5, 1.5, ...

    g1 = to_grid(p1); g2 = to_grid(p2)
    dx = g2[1] - g1[1]; dy = g2[2] - g1[2]
    steps = max(ceil(Int, abs(dx)), ceil(Int, abs(dy)), 1) * 2  # 2× oversample

    for k in 0:steps
        t  = F(k) / F(steps)
        gx = g1[1] + t * dx
        gy = g1[2] + t * dy
        cx = round(Int, gx)
        cy = round(Int, gy)
        # Mark cell + buffer
        for bx in -buf_cells:buf_cells, by in -buf_cells:buf_cells
            ix = cx + bx; iy = cy + by
            if 1 <= ix <= nx && 1 <= iy <= ny
                mask[ix, iy] = true
            end
        end
    end
end


# ── Builder ───────────────────────────────────────────────────────────────────

"""
    build_navigation_field(walls, goal_pos, bounds, cell_size; agent_radius, goal_radius)

Build a `NavigationField{F}` for a scenario defined by `walls` (WallSegment endpoints)
and a `goal_pos` in world coordinates.

## Arguments
- `walls`:       `Vector{NTuple{2, SVector{2,F}}}` — each entry is (p1, p2) of a wall segment
- `goal_pos`:    target position agents navigate toward (world coordinates)
- `bounds`:      `(x_min, x_max, y_min, y_max)` — world bounding box to cover
- `cell_size`:   grid resolution (m). Default 0.05m (5cm). Smaller = more accurate, slower.
- `agent_radius`: wall buffer radius (m). Cells within this distance of a wall become obstacles.
                  Should match agent radius (default 0.2m) to prevent overlap.
- `goal_radius`:  radius around goal_pos to seed as destination (m). Default cell_size*2.

## Returns
A `NavigationField{F}` with precomputed direction vectors.

## Notes
FMM is run in Float64 internally (Eikonal.jl requirement), then gradient is
cast to F for the direction grid.
"""
function build_navigation_field(
    walls       :: Vector{NTuple{2, SVector{2,F}}},
    goal_pos    :: SVector{2,F},
    bounds      :: NTuple{4,F},                # (x_min, x_max, y_min, y_max)
    cell_size   :: F = F(0.05);
    agent_radius :: F = F(0.2),
    goal_radius  :: F = cell_size * F(2)
) :: NavigationField{F} where {F<:AbstractFloat}

    x_min, x_max, y_min, y_max = bounds
    grid_min = SVector{2,F}(x_min, y_min)

    nx = max(2, ceil(Int, (x_max - x_min) / cell_size))
    ny = max(2, ceil(Int, (y_max - y_min) / cell_size))

    # ── 1. Build obstacle mask from wall segments ─────────────────────────────
    buf_cells = max(1, round(Int, agent_radius / cell_size))
    obstacle  = fill(false, nx, ny)
    for (p1, p2) in walls
        _rasterize_segment!(obstacle, p1, p2, grid_min, cell_size, nx, ny, buf_cells)
    end

    # ── 2. Slowness grid: 1.0 in free space, 1e9 in obstacles ───────────────
    # CRITICAL: Eikonal.jl fmm.v is SLOWNESS (cost per unit length),
    # NOT speed. |∇T| = v. High v → high travel cost → agents avoid obstacles.
    #   v = 1.0  → normal free-space traversal (|∇T|=1, T = distance) ✓
    #   v = 1e9  → effectively impassable (T grows by 1e9 per cell) ✓
    #   v = 1e-9 → nearly free (transparent obstacles!) ← WRONG
    slowness = fill(1.0, nx, ny)
    for iy in 1:ny, ix in 1:nx
        if obstacle[ix, iy]
            slowness[ix, iy] = 1e9   # very high cost = impassable
        end
    end

    # ── 3. Find goal cell(s) ─────────────────────────────────────────────────
    fmm = FastMarching(nx, ny)
    fmm.v .= slowness

    # Seed all cells within goal_radius of goal_pos
    goal_seeded = false
    goal_r_cells = max(0, ceil(Int, goal_radius / cell_size))
    gx0 = round(Int, (goal_pos[1] - x_min) / cell_size + 0.5)
    gy0 = round(Int, (goal_pos[2] - y_min) / cell_size + 0.5)

    for dx in -goal_r_cells:goal_r_cells, dy in -goal_r_cells:goal_r_cells
        gx = clamp(gx0 + dx, 1, nx)
        gy = clamp(gy0 + dy, 1, ny)
        if !obstacle[gx, gy]
            init!(fmm, (gx, gy))
            goal_seeded = true
        end
    end

    # Fallback: if goal is in obstacle, seed nearest free cell
    if !goal_seeded
        best_dist = Inf
        bx = bx = clamp(gx0, 1, nx); by = clamp(gy0, 1, ny)
        for iy in 1:ny, ix in 1:nx
            if !obstacle[ix, iy]
                d = (ix - gx0)^2 + (iy - gy0)^2
                if d < best_dist
                    best_dist = d; bx = ix; by = iy
                end
            end
        end
        init!(fmm, (bx, by))
    end

    # ── 4. Run FMM ───────────────────────────────────────────────────────────
    march!(fmm)

    # ── 5. Compute gradient and direction field ───────────────────────────────
    # fmm.t has size (nx+1, ny+1) — valid indices are 1:nx, 1:ny
    # dirs layout: (2, nx, ny) plain Float array — GPU-uploadable, no SVector boxing.
    #   dirs[1, ix, iy] = x-component,  dirs[2, ix, iy] = y-component
    T    = fmm.t   # travel time (potential)
    dirs = zeros(F, 2, nx, ny)

    h = Float64(cell_size)
    for iy in 1:ny
        for ix in 1:nx
            obstacle[ix, iy] && continue   # no direction inside wall cells

            # Finite difference gradient: use one-sided at boundaries
            ix_m = max(ix - 1, 1);  ix_p = min(ix + 1, nx)
            iy_m = max(iy - 1, 1);  iy_p = min(iy + 1, ny)

            dTdx = (T[ix_p, iy] - T[ix_m, iy]) / ((ix_p - ix_m) * h)
            dTdy = (T[ix, iy_p] - T[ix, iy_m]) / ((iy_p - iy_m) * h)

            # Direction = -∇T (toward decreasing potential = toward goal)
            gx_f = F(-dTdx)
            gy_f = F(-dTdy)
            mag  = sqrt(gx_f^2 + gy_f^2)

            if isfinite(mag) && mag > F(1e-9)
                dirs[1, ix, iy] = gx_f / mag
                dirs[2, ix, iy] = gy_f / mag
            end
        end
    end

    return NavigationField{F, Array{F,3}}(grid_min, cell_size, (nx, ny), dirs, goal_pos)
end


"""
    build_navigation_field(walls, goal_pos, cell_size; kwargs...) → NavigationField{F, Array{F,3}}

Convenience variant that auto-computes bounds from the wall geometry + 1m padding.
Always returns a CPU navigation field. Use `to_device(nav, backend)` to upload to GPU.
"""
function build_navigation_field(
    walls     :: Vector{NTuple{2, SVector{2,F}}},
    goal_pos  :: SVector{2,F},
    cell_size :: F = F(0.05);
    kwargs...
) :: NavigationField{F, Array{F,3}} where {F<:AbstractFloat}
    if isempty(walls)
        # Fallback: small box around goal
        pad = F(2.0)
        bounds = (goal_pos[1] - pad, goal_pos[1] + pad, goal_pos[2] - pad, goal_pos[2] + pad)
        return build_navigation_field(walls, goal_pos, bounds, cell_size; kwargs...)
    end
    # Auto-bounds: union of all wall endpoints + goal + 1m padding
    all_pts = [p for (p1, p2) in walls for p in (p1, p2)]
    push!(all_pts, goal_pos)
    xs = [p[1] for p in all_pts]; ys = [p[2] for p in all_pts]
    pad = F(1.0)
    bounds = (minimum(xs) - pad, maximum(xs) + pad, minimum(ys) - pad, maximum(ys) + pad)
    return build_navigation_field(walls, goal_pos, bounds, cell_size; kwargs...)
end


# ── Legacy backwards-compatible overload ─────────────────────────────────────

"""
    build_navigation_field(grid_min, grid_max, cell_size, goal_pos, obstacle_mask) → NavigationField{F, Array{F,3}}

**Backwards-compatible** overload matching the original 5-argument signature.

Accepts a precomputed Boolean `obstacle_mask` (nx × ny, true = obstacle) and
builds the NavigationField via FMM directly from the mask.

Called by existing runtests.jl tests (CRW-S-02, §2.5). Sprint 3N-b preferred
API uses the `build_navigation_field(walls, goal, ...)` variant instead.
"""
function build_navigation_field(
    grid_min      :: SVector{2, F},
    grid_max      :: SVector{2, F},
    cell_size     :: F,
    goal_pos      :: SVector{2, F},
    obstacle_mask :: Matrix{Bool}
) :: NavigationField{F, Array{F,3}} where {F<:AbstractFloat}
    nx = size(obstacle_mask, 1)
    ny = size(obstacle_mask, 2)
    dims = (nx, ny)

    # Build slowness grid directly from the mask
    # (Eikonal.jl: fmm.v = slowness, v=1.0 free, v=1e9 obstacle)
    fmm = FastMarching(nx, ny)
    fmm.v .= 1.0
    for iy in 1:ny, ix in 1:nx
        if obstacle_mask[ix, iy]
            fmm.v[ix, iy] = 1e9
        end
    end

    # Seed goal
    gx0 = clamp(round(Int, (goal_pos[1] - grid_min[1]) / cell_size + 0.5), 1, nx)
    gy0 = clamp(round(Int, (goal_pos[2] - grid_min[2]) / cell_size + 0.5), 1, ny)
    init!(fmm, (gx0, gy0))
    march!(fmm)

    # Compute direction grid — (2, nx, ny) layout, plain floats (GPU-uploadable)
    T    = fmm.t
    dirs = zeros(F, 2, nx, ny)
    h    = Float64(cell_size)
    for iy in 1:ny
        for ix in 1:nx
            obstacle_mask[ix, iy] && continue
            ix_m = max(ix-1, 1);  ix_p = min(ix+1, nx)
            iy_m = max(iy-1, 1);  iy_p = min(iy+1, ny)
            dTdx = (T[ix_p, iy] - T[ix_m, iy]) / ((ix_p - ix_m) * h)
            dTdy = (T[ix, iy_p] - T[ix, iy_m]) / ((iy_p - iy_m) * h)
            gx_f = F(-dTdx); gy_f = F(-dTdy)
            mag  = sqrt(gx_f^2 + gy_f^2)
            if isfinite(mag) && mag > F(1e-9)
                dirs[1, ix, iy] = gx_f / mag
                dirs[2, ix, iy] = gy_f / mag
            end
        end
    end

    return NavigationField{F, Array{F,3}}(grid_min, cell_size, dims, dirs, goal_pos)
end


# ── GPU upload ────────────────────────────────────────────────────────────────

"""
    to_device(nav::NavigationField{F, Array{F,3}}, backend::Backend) → NavigationField{F, DevArray}

Upload a CPU-built NavigationField to the specified KernelAbstractions backend
(CUDABackend, ROCmBackend, MetalBackend). The FMM solve always runs on CPU
(Eikonal.jl is CPU-only); this function copies the precomputed `dirs` grid.

Call once after `build_navigation_field`. Store the returned GPU nav field
in `SimScene` for use with GPU kernels.

# Example

    cpu_nav = build_navigation_field(walls, goal, 0.05f0)
    gpu_nav = to_device(cpu_nav, CUDABackend())
    scene   = SimScene(world, gpu_search, gpu_nav, config)
"""
function to_device(nav::NavigationField{F, Array{F,3}}, backend::Backend) where {F}
    dev_dirs = KernelAbstractions.zeros(backend, F, 2, nav.dims[1], nav.dims[2])
    KernelAbstractions.copyto!(backend, dev_dirs, nav.dirs)
    KernelAbstractions.synchronize(backend)
    return NavigationField{F, typeof(dev_dirs)}(
        nav.grid_min, nav.cell_size, nav.dims, dev_dirs, nav.goal_pos)
end

# CPU() is a no-op — field is already on CPU
to_device(nav::NavigationField{F, Array{F,3}}, ::CPU) where {F} = nav


# ── Query ─────────────────────────────────────────────────────────────────────

"""
    get_nav_direction(nav::NavigationField{F}, pos::SVector{2,F}) → SVector{2,F}

Return the unit navigation direction at `pos` using bilinear interpolation
from the precomputed direction grid.

Falls back to direct goal-pointing if `pos` is outside the grid or the
interpolated direction is degenerate (e.g., obstacle cells nearby).

`@inline` ensures this compiles directly into KA GPU kernels when `nav.dirs`
is a device array — no runtime dispatch overhead.
"""
@inline function get_nav_direction(
    nav :: NavigationField{F},
    pos :: SVector{2,F}
) :: SVector{2,F} where {F<:AbstractFloat}
    nx, ny = nav.dims
    cs = nav.cell_size

    # Floating-point grid index (0-based cell centers at 0.5, 1.5, ...)
    fx = (pos[1] - nav.grid_min[1]) / cs - F(0.5)
    fy = (pos[2] - nav.grid_min[2]) / cs - F(0.5)

    ix0 = floor(Int, fx);  iy0 = floor(Int, fy)
    tx  = fx - ix0;         ty  = fy - iy0

    # Convert to 1-based indices
    i0 = ix0 + 1;  i1 = i0 + 1
    j0 = iy0 + 1;  j1 = j0 + 1

    in_bounds = (i0 >= 1 && i1 <= nx && j0 >= 1 && j1 <= ny)

    if in_bounds
        # Read plain floats from (2, nx, ny) array — no SVector boxing
        g00 = SVector(nav.dirs[1, i0, j0], nav.dirs[2, i0, j0])
        g10 = SVector(nav.dirs[1, i1, j0], nav.dirs[2, i1, j0])
        g01 = SVector(nav.dirs[1, i0, j1], nav.dirs[2, i0, j1])
        g11 = SVector(nav.dirs[1, i1, j1], nav.dirs[2, i1, j1])

        w00 = (F(1) - tx) * (F(1) - ty)
        w10 = tx           * (F(1) - ty)
        w01 = (F(1) - tx) * ty
        w11 = tx           * ty

        raw = w00 * g00 + w10 * g10 + w01 * g01 + w11 * g11
        mag = norm(raw)
        if mag > F(1e-9)
            return raw / mag
        end
    end

    # Fallback: direct goal direction
    d = nav.goal_pos - pos
    n = norm(d)
    return n > F(1e-9) ? d / n : SVector{2,F}(one(F), zero(F))
end

# Backwards-compatible alias for the SFM system (was get_desired_direction)
const get_desired_direction = get_nav_direction


# ── SFM/Force dispatch (existing, unchanged) ──────────────────────────────────

"""
    update_navigation_system!(world, nav)

Set the driving force for all SFM agents (those with `MotionParams{F}` and `Force{F}`)
based on the FMM navigation field.

For CSM agents, use `update_csm_system!(world, dt, nav)` instead.
"""
function update_navigation_system!(world::World, nav::AbstractNavigationField{F}) where {F}
    for (_, pos_col, vel_col, params_col, force_col) in
            Query(world, (Position{F}, Velocity{F}, MotionParams{F}, Force{F}))
        Threads.@threads for i in eachindex(pos_col)
            pos    = pos_col[i].p
            vel    = vel_col[i].v
            params = params_col[i]

            dir = get_nav_direction(nav, pos)

            # F_drive = mass × (v_pref × e_i − v_i) / τ   [Newtons]
            F_drive = params.mass * (params.v_pref * dir - vel) / params.τ
            force_col[i] = Force(F_drive)
        end
    end
end
