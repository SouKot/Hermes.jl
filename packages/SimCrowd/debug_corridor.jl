using SimCrowd
using StaticArrays
using LinearAlgebra

function debug_corridor()
    world = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32}, MotionParams{Float32}, SFMParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
    R = 10.0f0
    width = 3.0f0
    dt = 0.001f0
    
    # 1 agent
    N = 1
    pos = SVector(10.0f0, 0.0f0)
    new_entity!(world, (Position(pos), Velocity(SVector(0.0f0,0.0f0)), from_agent_params(0.3f0, 80.0f0, 1.3f0, 0.5f0)..., Goal(SVector(0.0f0,0.0f0)), Force(SVector(0.0f0,0.0f0))))
    
    # Inner and outer walls
    num_segs = 32
    r_in = R - width/2
    r_out = R + width/2
    for i in 1:num_segs
        t1 = Float32((i-1) * 2 * pi / num_segs)
        t2 = Float32(i * 2 * pi / num_segs)
        new_entity!(world, (WallSegment(SVector(r_in*cos(t1), r_in*sin(t1)), SVector(r_in*cos(t2), r_in*sin(t2))),))
        new_entity!(world, (WallSegment(SVector(r_out*cos(t1), r_out*sin(t1)), SVector(r_out*cos(t2), r_out*sin(t2))),))
    end
    
    grid_size = R + width + 5.0f0
    sh = CPUNeighborSearch(N, SVector(-grid_size, -grid_size), SVector(grid_size, grid_size), 4.0f0)
    
    for step in 1:20000
        for (entities, pos_col, vel_col, motion_col, goal_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, MotionParams{Float32}, Goal{Float32}, Force{Float32}))
            for i in eachindex(pos_col)
                pos = pos_col[i].p
                theta = atan(pos[2], pos[1])
                dir = SVector(-sin(theta), cos(theta))
                goal = pos + dir * 5.0f0
                F_drive = goal_seeking_force(pos, vel_col[i].v, goal, motion_col[i].v_pref, motion_col[i].τ)
                force_col[i] = Force(F_drive)
            end
        end
        update_social_forces_system!(world, sh, CPU())
        integrate_physics_system!(world, dt)
        
        if step % 2000 == 0
            for (entities, pos_col, vel_col) in Query(world, (Position{Float32}, Velocity{Float32}))
                pos = pos_col[1].p
                theta = atan(pos[2], pos[1])
                dir = SVector(-sin(theta), cos(theta))
                v_t = dot(vel_col[1].v, dir)
                println("t=", step*dt, " pos=", round.(pos, digits=2), " v_t=", round(v_t, digits=3), " v=", round.(vel_col[1].v, digits=3))
            end
        end
    end
end

debug_corridor()
