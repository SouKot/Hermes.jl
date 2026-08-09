# ── Navigation Field & System ───────────────────────────────────────────────────

using Ark
using Eikonal
using StaticArrays
using LinearAlgebra

"""
    NavigationField{F<:AbstractFloat}

Represents a static potential field that guides agents to a goal while avoiding obstacles.
Uses the Fast Marching Method to solve the Eikonal equation `|∇T| = 1/f`, where `f` is speed.
"""
struct NavigationField{F<:AbstractFloat}
    grid_min::SVector{2, F}
    grid_max::SVector{2, F}
    cell_size::F
    dims::SVector{2, Int}
    
    potential::Matrix{Float64}
    gradient::Matrix{SVector{2, F}}
    goal_pos::SVector{2, F}
end

"""
    build_navigation_field(grid_min, grid_max, cell_size, goal_pos, obstacle_mask)

Builds the navigation field using `Eikonal.jl`'s Fast Marching solver.
"""
function build_navigation_field(grid_min::SVector{2, F}, grid_max::SVector{2, F}, 
                                cell_size::F, goal_pos::SVector{2, F}, 
                                obstacle_mask::Matrix{Bool}) where {F<:AbstractFloat}
    dims = ceil.(Int, (grid_max - grid_min) / cell_size)
    
    speeds = ones(Float64, dims[1], dims[2])
    speeds[obstacle_mask] .= 1e5
    
    fmm = FastMarching(dims[1], dims[2])
    fmm.v .= speeds
    
    goal_idx = floor.(Int, (goal_pos - grid_min) / cell_size)
    goal_x = clamp(goal_idx[1] + 1, 1, dims[1])
    goal_y = clamp(goal_idx[2] + 1, 1, dims[2])
    
    init!(fmm, (goal_x, goal_y))
    march!(fmm)
    
    potential = copy(fmm.t)
    gradient = zeros(SVector{2, F}, dims[1], dims[2])
    
    for y in 2:dims[2]-1
        for x in 2:dims[1]-1
            dx = -(potential[x+1, y] - potential[x-1, y]) / (2.0 * cell_size)
            dy = -(potential[x, y+1] - potential[x, y-1]) / (2.0 * cell_size)
            
            vec = SVector{2, F}(dx, dy)
            if isfinite(vec[1]) && isfinite(vec[2]) && norm(vec) > F(1e-6)
                gradient[x, y] = normalize(vec)
            end
        end
    end
    
    return NavigationField{F}(grid_min, grid_max, cell_size, dims, potential, gradient, goal_pos)
end

@inline function get_desired_direction(nav::NavigationField{F}, pos::SVector{2, F}) where {F}
    f_idx = (pos - nav.grid_min) / nav.cell_size
    
    cx = f_idx[1] - F(0.5)
    cy = f_idx[2] - F(0.5)
    
    x0 = floor(Int, cx)
    y0 = floor(Int, cy)
    tx = cx - x0
    ty = cy - y0
    
    x0 += 1; y0 += 1
    x1 = x0 + 1; y1 = y0 + 1
    
    if x0 >= 1 && x1 <= nav.dims[1] && y0 >= 1 && y1 <= nav.dims[2]
        g00 = nav.gradient[x0, y0]
        g10 = nav.gradient[x1, y0]
        g01 = nav.gradient[x0, y1]
        g11 = nav.gradient[x1, y1]
        
        dir = (F(1.0) - tx) * (F(1.0) - ty) * g00 + 
              tx * (F(1.0) - ty) * g10 + 
              (F(1.0) - tx) * ty * g01 + 
              tx * ty * g11
              
        if norm(dir) > F(1e-6)
            return normalize(dir)
        end
    end
    
    dir = nav.goal_pos - pos
    n = norm(dir)
    return n > F(1e-6) ? (dir / n) : zero(SVector{2, F})
end

"""
    update_navigation_system!(world, nav)

Updates the driving forces for all agents based on the navigation field.
"""
function update_navigation_system!(world::World, nav::NavigationField{F}) where {F}
    for (entities, pos_col, vel_col, params_col, force_col) in Query(world, (Position{F}, Velocity{F}, AgentParams{F}, Force{F}))
        Threads.@threads for i in eachindex(pos_col)
            pos = pos_col[i].p
            vel = vel_col[i].v
            params = params_col[i]
            
            dir = get_desired_direction(nav, pos)
            
            # F_drive = (v0 * e_i - v_i) / τ
            F_drive = (params.v_pref * dir - vel) / params.τ
            force_col[i] = Force(F_drive)
        end
    end
end
