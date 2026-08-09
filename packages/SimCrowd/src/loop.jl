# ── Simulation Loop ────────────────────────────────────────────────────────────

using KernelAbstractions

"""
    crowd_step_cpu!(agents, sh, nav, integrator, dt; backend=CPU())

Performs a single timestep of the Social Force Model on the CPU.
1. Rebuilds the spatial hash grid based on current positions.
2. Computes the driving force (via navigation field) and social repulsion (via spatial hash).
3. Integrates the physics using the provided `integrator`.
"""
function crowd_step_cpu!(agents::Vector{CrowdAgent{F}}, 
                         sh::SpatialHash, 
                         nav::NavigationField, 
                         integrator::Integrator, 
                         dt::F; 
                         backend=CPU()) where {F<:AbstractFloat}
    
    # 1. Extract positions and rebuild Spatial Hash
    # (In Phase 3B (GPU) this will be a StructOfArrays, avoiding this allocation)
    positions = [a.position for a in agents]
    build_grid!(sh, positions, backend)
    
    # 2. Compute Forces and Integrate
    Threads.@threads for i in 1:length(agents)
        agent = agents[i]
        
        # Driving Force (from Navigation Field)
        dir = get_desired_direction(nav, agent.position)
        F_drive = (agent.v_pref * dir - agent.velocity) / agent.τ
        
        # Social Repulsion Force
        F_repulse = zero(SVector{2,F})
        for neighbor_idx in get_neighbors(sh, agent.position)
            if neighbor_idx != i
                neighbor = agents[neighbor_idx]
                F_repulse += agent_repulsion(agent.position, neighbor.position, agent.radius, neighbor.radius)
            end
        end
        
        # Sum forces
        F_total = F_drive + F_repulse
        
        # 3. Integrate
        integrate_agent!(agent, F_total, dt, integrator)
    end
end
