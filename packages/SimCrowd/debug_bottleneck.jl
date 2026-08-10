using SimCrowd
using StaticArrays
using LinearAlgebra

function debug_bottleneck()
    world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
    N = 10
    dt = 0.001f0
    v0 = 1.4f0
    
    new_entity!(world, (WallSegment(SVector(5.0f0, 0.0f0), SVector(5.0f0, 1.9f0)),))
    new_entity!(world, (WallSegment(SVector(5.0f0, 3.1f0), SVector(5.0f0, 5.0f0)),))
    
    goal_final = SVector(10.0f0, 2.5f0)
    
    for i in 1:N
        pos = SVector(1.0f0 + rand(Float32)*3.0f0, 1.0f0 + rand(Float32)*3.0f0)
        goal_door = SVector(5.0f0, clamp(pos[2], 2.1f0, 2.9f0))
        new_entity!(world, (Position(pos), Velocity(SVector(0.0f0,0.0f0)), AgentParams(0.3f0, 80.0f0, v0, 0.5f0), Goal(goal_door), Force(SVector(0.0f0,0.0f0))))
    end
    
    sh = CPUNeighborSearch(N, SVector(0.0f0, 0.0f0), SVector(12.0f0, 5.0f0), 4.0f0)
    
    t = 0.0f0
    while t < 2.0f0
        for (entities, pos_col, vel_col, params_col, goal_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Goal{Float32}, Force{Float32}))
            for i in eachindex(pos_col)
                if pos_col[i].p[1] > 5.0f0
                    goal_col[i] = Goal(goal_final)
                else
                    goal_col[i] = Goal(SVector(5.0f0, clamp(pos_col[i].p[2], 2.1f0, 2.9f0)))
                end
                F_drive = goal_seeking_force(pos_col[i].p, vel_col[i].v, goal_col[i].g, params_col[i].v_pref, params_col[i].τ)
                force_col[i] = Force(F_drive)
            end
        end
        
        update_social_forces_system!(world, sh, CPU())
        integrate_physics_system!(world, dt)
        t += dt
        
        if mod(round(Int, t/dt), 200) == 0
            println("t = ", round(t, digits=2))
            for (entities, pos_col, vel_col) in Query(world, (Position{Float32}, Velocity{Float32}))
                for i in 1:min(3, length(pos_col))
                    println("  Agent $i: pos=", round.(pos_col[i].p, digits=2), " vel=", round.(vel_col[i].v, digits=2))
                end
            end
        end
    end
end

debug_bottleneck()
