# systems/navigation.jl -- NavigationField (Fast Marching Method)
#
# Sprint 3N-b (2026-08-27): Modular navigation layer shared by CSM and Hybrid FSM.
#
# Architecture:
#   - NavigationField{F}: immutable struct holding precomputed direction grid.
#   - build_navigation_field(...): constructs field from WallSegments + goal.
#   - get_nav_direction(nav, pos): bilinear-interpolated direction at any position.
#   - update_csm_system!(world, dt, nav): CSM dispatch using nav for direction.
#   - update_navigation_system!(world, nav): SFM/Force-based dispatch (existing).
#
# Algorithm:
#   1. Rasterize WallSegments onto a binary obstacle grid (Bresenham line + radius buffer).
#   2. Run Eikonal.jl FastMarching from the goal cell outward through free cells.
#   3. Compute -∇T at every free cell → unit direction toward goal avoiding obstacles.
#   4. At query time: bilinear interpolation from the grid; fallback to direct goal.
#
# Bug fixed from previous version:
#   - OLD: speeds[obstacle_mask] .= 1e5  (obstacles were FAST -- wrong!)
#   - NEW: speeds[obstacle_mask] .= 0.0  (obstacles are impassable -- correct)
#
# Reference:
#   Sethian, J.A. (1999). Level Set Methods and Fast Marching Methods.
#   JuPedSim v1.4.2 -- routing engine provides e0 = step.ToNextTarget() for CSM.

using Eikonal
using StaticArrays
using LinearAlgebra

# ── Struct ────────────────────────────────────────────────────────────────────

"""
    NavigationField{F<:AbstractFloat}

Precomputed FMM-based direction field for pedestrian routing.

Stores a 2D grid of unit direction vectors `-∇T / |∇T|` where T is the
Eikonal travel-time from every free cell to the goal. Agents query their
desired direction at any position via bilinear interpolation.

## Fields
- `grid_min`:  world-coordinate of grid origin (bottom-left corner of cell [1,1])
- `cell_size`: side length of each grid cell (m)
- `dims`:      (nx, ny) number of cells
- `dirs`:      nx × ny matrix of unit direction vectors (zero at obstacles/walls)
- `goal_pos`:  goal position in world coordinates (used as fallback)

## Notes
- Not `isbits`: holds a `Matrix`. Pass by reference to update functions.
- Precomputed once per scenario. Rebuild if geometry or goal changes.
"""
struct NavigationField{F<:AbstractFloat}
    grid_min  :: SVector{2, F}
    cell_size :: F
    dims      :: Tuple{Int, Int}
    dirs      :: Matrix{SVector{2, F}}   # (nx, ny), unit vectors toward goal
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
    T   = fmm.t   # travel time (potential)
    dirs = fill(zero(SVector{2,F}), nx, ny)

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
                dirs[ix, iy] = SVector{2,F}(gx_f / mag, gy_f / mag)
            end
        end
    end

    return NavigationField{F}(grid_min, cell_size, (nx, ny), dirs, goal_pos)
end


"""
    build_navigation_field(walls, goal_pos, cell_size; kwargs...) → NavigationField{F}

Convenience variant that auto-computes bounds from the wall geometry + 1m padding.
"""
function build_navigation_field(
    walls     :: Vector{NTuple{2, SVector{2,F}}},
    goal_pos  :: SVector{2,F},
    cell_size :: F = F(0.05);
    kwargs...
) :: NavigationField{F} where {F<:AbstractFloat}
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
    build_navigation_field(grid_min, grid_max, cell_size, goal_pos, obstacle_mask) → NavigationField{F}

**Backwards-compatible** overload matching the original 5-argument signature.

Accepts a precomputed Boolean `obstacle_mask` (nx × ny, true = obstacle) and
converts it to a wall-list form, then builds the NavigationField.

Called by existing runtests.jl tests (CRW-S-02, §2.5). Sprint 3N-b preferred
API uses the `build_navigation_field(walls, goal, ...)` variant instead.
"""
function build_navigation_field(
    grid_min      :: SVector{2, F},
    grid_max      :: SVector{2, F},
    cell_size     :: F,
    goal_pos      :: SVector{2, F},
    obstacle_mask :: Matrix{Bool}
) :: NavigationField{F} where {F<:AbstractFloat}
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

    # Compute direction grid
    T    = fmm.t
    dirs = fill(zero(SVector{2,F}), nx, ny)
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
                dirs[ix, iy] = SVector{2,F}(gx_f / mag, gy_f / mag)
            end
        end
    end

    return NavigationField{F}(grid_min, cell_size, dims, dirs, goal_pos)
end


# ── Query ─────────────────────────────────────────────────────────────────────

"""
    get_nav_direction(nav::NavigationField{F}, pos::SVector{2,F}) → SVector{2,F}

Return the unit navigation direction at `pos` using bilinear interpolation
from the precomputed direction grid.

Falls back to direct goal-pointing if `pos` is outside the grid or the
interpolated direction is degenerate (e.g., obstacle cells nearby).
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

    ix1 = ix0 + 1;  iy1 = iy0 + 1

    # Convert to 1-based and clamp
    i0 = ix0 + 1;  i1 = i0 + 1
    j0 = iy0 + 1;  j1 = j0 + 1

    in_bounds = (i0 >= 1 && i1 <= nx && j0 >= 1 && j1 <= ny)

    if in_bounds
        g00 = nav.dirs[i0, j0]
        g10 = nav.dirs[i1, j0]
        g01 = nav.dirs[i0, j1]
        g11 = nav.dirs[i1, j1]

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
function update_navigation_system!(world::World, nav::NavigationField{F}) where {F}
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
