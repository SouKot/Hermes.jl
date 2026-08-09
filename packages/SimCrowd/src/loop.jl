# ── ECS Systems ──────────────────────────────────────────────────────────────

using KernelAbstractions
using Ark

"""
    update_navigation_system!(world::World, nav::NavigationField)

Computes the driving force towards the goal using the navigation field.
"""
function update_navigation_system!(world::World, nav::NavigationField)
    for (entities, pos_col, vel_col, params_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Force{Float32}))
        Threads.@threads for i in eachindex(pos_col)
            pos = pos_col[i].p
            vel = vel_col[i].v
            params = params_col[i]
            
            dir = get_desired_direction(nav, pos)
            F_drive = (params.v_pref * dir - vel) / params.τ
            
            force_col[i] = Force(F_drive)
        end
    end
end

"""
    update_social_forces_system!(world::World, sh::SpatialHash, backend::Backend=CPU())

Computes social repulsion forces using the spatial hash.
"""
function update_social_forces_system!(world::World, sh::SpatialHash, backend=CPU())
    # 1. Gather positions and radii to rebuild spatial hash and allow fast lookup
    num_agents = count_entities(world)
    positions = Vector{SVector{2,Float32}}(undef, num_agents)
    radii = Vector{Float32}(undef, num_agents)
    
    idx = 1
    for (entities, pos_col, params_col) in Query(world, (Position{Float32}, AgentParams{Float32}))
        for i in eachindex(pos_col)
            positions[idx] = pos_col[i].p
            radii[idx] = params_col[i].radius
            idx += 1
        end
    end
    
    build_grid!(sh, positions, backend)
    
    # 2. Compute social forces
    for (entities, pos_col, params_col, force_col) in Query(world, (Position{Float32}, AgentParams{Float32}, Force{Float32}))
        Threads.@threads for i in eachindex(pos_col)
            pos_i = pos_col[i].p
            rad_i = params_col[i].radius
            F_repulse = zero(SVector{2,Float32})
            
            for neighbor_idx in get_neighbors(sh, pos_i)
                pos_j = positions[neighbor_idx]
                rad_j = radii[neighbor_idx]
                
                # Check it's not identical (d < 1e-6 catches self-interaction anyway, but to be safe)
                # We add the force
                F_repulse += agent_repulsion(pos_i, pos_j, rad_i, rad_j)
            end
            
            # Add to the existing driving force
            force_col[i] = Force(force_col[i].f + F_repulse)
        end
    end
end

"""
    integrate_physics_system!(world::World, dt::Float32)

Integrates velocity and position using Symplectic Euler.
"""
function integrate_physics_system!(world::World, dt::Float32)
    for (entities, pos_col, vel_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, Force{Float32}))
        Threads.@threads for i in eachindex(pos_col)
            # v_{t+1} = v_t + F * dt
            new_vel = vel_col[i].v + force_col[i].f * dt
            
            # x_{t+1} = x_t + v_{t+1} * dt
            new_pos = pos_col[i].p + new_vel * dt
            
            vel_col[i] = Velocity(new_vel)
            pos_col[i] = Position(new_pos)
        end
    end
end

