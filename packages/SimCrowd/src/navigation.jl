# ── Navigation Field ───────────────────────────────────────────────────────────

using Eikonal

"""
    NavigationField

Represents a static potential field that guides agents to a goal while avoiding obstacles.
Uses the Fast Marching Method to solve the Eikonal equation `|∇T| = 1/f`, where `f` is speed.
"""
struct NavigationField
    grid_min::SVector{2, Float32}
    grid_max::SVector{2, Float32}
    cell_size::Float32
    dims::SVector{2, Int}
    
    potential::Matrix{Float64}
    gradient::Matrix{SVector{2, Float32}}
    goal_pos::SVector{2, Float32}
end

"""
    build_navigation_field(grid_min, grid_max, cell_size, goal_pos, obstacle_mask)

Builds the navigation field using `Eikonal.jl`'s Fast Marching solver.
`obstacle_mask` is a boolean matrix where `true` means impassable.
"""
function build_navigation_field(grid_min::SVector{2, Float32}, grid_max::SVector{2, Float32}, 
                                cell_size::Float32, goal_pos::SVector{2, Float32}, 
                                obstacle_mask::Matrix{Bool})
    dims = ceil.(Int, (grid_max - grid_min) / cell_size)
    
    # The speed array (cost). f = 1.0 for free space, f = 1e5 for obstacles (impassable)
    speeds = ones(Float64, dims[1], dims[2])
    speeds[obstacle_mask] .= 1e5
    
    # Initialize Fast Marching Method
    fmm = FastMarching(dims[1], dims[2])
    fmm.v .= speeds
    
    # Map goal_pos to grid indices
    goal_idx = floor.(Int, (goal_pos - grid_min) / cell_size)
    goal_x = clamp(goal_idx[1] + 1, 1, dims[1])
    goal_y = clamp(goal_idx[2] + 1, 1, dims[2])
    
    # Initialize the goal with 0 potential
    init!(fmm, (goal_x, goal_y))
    
    # Solve the Eikonal equation
    march!(fmm)
    
    # Extract the potential field (times)
    potential = copy(fmm.t)
    
    # Compute the gradient using central finite differences
    gradient = zeros(SVector{2, Float32}, dims[1], dims[2])
    for y in 2:dims[2]-1
        for x in 2:dims[1]-1
            # ∇T points away from the goal (times increase away from goal)
            # We want the gradient to point TOWARDS the goal, so we take -∇T
            dx = -(potential[x+1, y] - potential[x-1, y]) / (2.0 * cell_size)
            dy = -(potential[x, y+1] - potential[x, y-1]) / (2.0 * cell_size)
            
            vec = SVector{2, Float32}(dx, dy)
            # Handle NaN/Inf gradients gracefully
            if isfinite(vec[1]) && isfinite(vec[2]) && norm(vec) > 1f-6
                gradient[x, y] = normalize(vec)
            end
        end
    end
    
    return NavigationField(grid_min, grid_max, cell_size, dims, potential, gradient, goal_pos)
end

"""
    get_desired_direction(nav::NavigationField, pos::SVector{2, Float32})

Returns the unit vector pointing towards the goal from `pos`, navigating around obstacles.
Returns the naive line-of-sight vector if `pos` is out of grid bounds.
"""
@inline function get_desired_direction(nav::NavigationField, pos::SVector{2, Float32})
    # Float indices
    f_idx = (pos - nav.grid_min) / nav.cell_size
    
    # Cell centers are at integer + 0.5
    cx = f_idx[1] - 0.5f0
    cy = f_idx[2] - 0.5f0
    
    x0 = floor(Int, cx)
    y0 = floor(Int, cy)
    tx = cx - x0
    ty = cy - y0
    
    # 1-based indexing
    x0 += 1; y0 += 1
    x1 = x0 + 1; y1 = y0 + 1
    
    if x0 >= 1 && x1 <= nav.dims[1] && y0 >= 1 && y1 <= nav.dims[2]
        g00 = nav.gradient[x0, y0]
        g10 = nav.gradient[x1, y0]
        g01 = nav.gradient[x0, y1]
        g11 = nav.gradient[x1, y1]
        
        dir = (1.0f0 - tx) * (1.0f0 - ty) * g00 + 
              tx * (1.0f0 - ty) * g10 + 
              (1.0f0 - tx) * ty * g01 + 
              tx * ty * g11
              
        if norm(dir) > 1f-6
            return normalize(dir)
        end
    end
    
    # Fallback to direct goal line of sight
    dir = nav.goal_pos - pos
    n = norm(dir)
    return n > 1f-6 ? (dir / n) : zero(SVector{2, Float32})
end
