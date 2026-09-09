"""
    density.jl — Per-cell pedestrian density grid computation

Implements `compute_density_grid!` — a fast O(N) binning pass followed by
a 3×3 Gaussian smoothing pass for visual clarity.

Design notes
─────────────
- Units: **ped/m²**. The raw cell count is normalized by `cell_size²`.
- Grid dimensions are determined by the room geometry:
    `nx = ceil(room_width / cell_size)`, `ny = ceil(room_height / cell_size)`
- Gaussian kernel is a 3×3 approximation with weights
    [1,2,1; 2,4,2; 1,2,1] / 16 (sum = 1 — mass-conserving).
- The grid is allocated once by `SimVizState.density_grid` (Observable) and
  updated in-place each frame by `update_viz!` when `show_density[] == true`.
- Boundary cells: agents outside `[0, room_width] × [0, room_height]` are
  clamped to the nearest interior cell (shouldn't happen in normal operation).
- Verification: `sum(grid) * cell_size^2 ≈ n_agents` (within ±1 from rounding).

Usage
─────
```julia
grid = zeros(Float32, nx, ny)       # allocate once
compute_density_grid!(grid, positions, cell_size, room_width, room_height)
# grid now contains ped/m² in each cell
```
"""

# No extra `using` needed here — all types used are from Base or are
# passed in as function arguments. StaticArrays is not required.

# ── Constants ─────────────────────────────────────────────────────────────────

"""
    GAUSS_KERNEL_3x3

Normalized 3×3 Gaussian blur kernel (weights sum to 1.0).
Applied once per frame to smooth the raw bin counts for visual clarity.
"""
const GAUSS_KERNEL_3x3 = Float32[
    1/16  2/16  1/16;
    2/16  4/16  2/16;
    1/16  2/16  1/16;
]

# ── compute_density_grid! ─────────────────────────────────────────────────────

"""
    compute_density_grid!(grid::Matrix{Float32},
                          positions::Vector{NTuple{2,Float32}},
                          cell_size::Float32,
                          room_width::Float32,
                          room_height::Float32) -> grid

Compute a 2D pedestrian density grid from agent positions.

# Algorithm
1. `fill!(grid, 0f0)` — clear previous frame's counts
2. Bin each agent into cell `(ix, iy)` based on its `(x, y)` position
3. Apply a 3×3 Gaussian smooth pass → copies to `grid` in-place
4. Normalize by `cell_size²` → units: ped/m²

# Arguments
- `grid`:        pre-allocated `Matrix{Float32}` of size `(nx, ny)` where
                 `nx ≈ room_width / cell_size`, `ny ≈ room_height / cell_size`.
                 Size is **not** checked — caller must size correctly.
- `positions`:   agent positions as `Vector{NTuple{2,Float32}}` from `WorldSnapshot`
- `cell_size`:   grid cell side length (m). Typical: 0.5 m for density overlays
- `room_width`:  room x-extent (m) — used for cell index bounds clamping
- `room_height`: room y-extent (m) — used for cell index bounds clamping

# Returns
`grid` (modified in-place).

# Conservation property
After normalization, `sum(grid) * cell_size^2 ≈ length(positions)` to within
±1 ped (boundary clamping may shift one agent's contribution by one cell).

# Example
```julia
nx = ceil(Int, room_width / cell_size)
ny = ceil(Int, room_height / cell_size)
grid = zeros(Float32, nx, ny)
compute_density_grid!(grid, snapshot.positions, 0.5f0, 10f0, 6f0)
@assert sum(grid) * 0.5f0^2 ≈ snapshot.n_agents  atol=1
```
"""
function compute_density_grid!(grid::Matrix{Float32},
                                positions::Vector{NTuple{2,Float32}},
                                cell_size::Float32,
                                room_width::Float32,
                                room_height::Float32) :: Matrix{Float32}
    nx, ny = size(grid)
    fill!(grid, 0f0)

    # ── Pass 1: bin agents ────────────────────────────────────────────────────
    @inbounds for (x, y) in positions
        # Map world coordinate → cell index (1-based, clamped to grid bounds)
        ix = clamp(floor(Int, x / cell_size) + 1, 1, nx)
        iy = clamp(floor(Int, y / cell_size) + 1, 1, ny)
        grid[ix, iy] += 1f0
    end

    # ── Pass 2: 3×3 Gaussian smooth (in-place, using a scratch copy) ─────────
    _gaussian_smooth_3x3!(grid)

    # ── Pass 3: normalize by cell area → ped/m² ──────────────────────────────
    inv_area = 1f0 / (cell_size * cell_size)
    @inbounds for i in eachindex(grid)
        grid[i] *= inv_area
    end

    return grid
end

"""
    _gaussian_smooth_3x3!(grid::Matrix{Float32}) -> grid

Apply one pass of 3×3 Gaussian blur to `grid` using `GAUSS_KERNEL_3x3`.
Operates in-place using a temporary copy of the raw binned counts.

Interior cells: full 3×3 convolution.
Edge/corner cells: reflect boundary (mirror padding) — mass is conserved.

This is the bottleneck for large grids; for N<1000 agents and 100×100 cells
it takes ≈0.1 ms — negligible against the 16 ms frame budget.
"""
function _gaussian_smooth_3x3!(grid::Matrix{Float32})
    nx, ny = size(grid)
    raw    = copy(grid)   # one allocation per frame when density overlay is on

    k = GAUSS_KERNEL_3x3

    @inbounds for iy in 1:ny, ix in 1:nx
        v = 0f0
        for dy in -1:1, dx in -1:1
            # Mirror-pad at boundaries
            jx = clamp(ix + dx, 1, nx)
            jy = clamp(iy + dy, 1, ny)
            v += k[dx+2, dy+2] * raw[jx, jy]
        end
        grid[ix, iy] = v
    end

    return grid
end

# ── density_grid_size ─────────────────────────────────────────────────────────

"""
    density_grid_size(room_width, room_height, cell_size) :: Tuple{Int,Int}

Compute the `(nx, ny)` grid dimensions for a given room and cell size.
Always returns at least `(1, 1)`.

```julia
nx, ny = density_grid_size(10f0, 6f0, 0.5f0)  # → (20, 12)
grid   = zeros(Float32, nx, ny)
```
"""
function density_grid_size(room_width::Float32, room_height::Float32,
                            cell_size::Float32) :: Tuple{Int,Int}
    nx = max(1, ceil(Int, room_width  / cell_size))
    ny = max(1, ceil(Int, room_height / cell_size))
    return (nx, ny)
end
