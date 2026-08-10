using Pkg
Pkg.activate(".")

using SimCrowd
using StaticArrays
using LinearAlgebra
using KernelAbstractions
using Ark
using Test

# Helper for counting agents that have reached their goal
# Helper for counting agents that have reached their goal
function count_reached(world::World, tolerance::Float32=0.5f0)
    count = 0
    for (entities, pos_col, goal_col) in Query(world, (Position{Float32}, Goal{Float32}))
        for i in eachindex(pos_col)
            if norm(pos_col[i].p - goal_col[i].g) < tolerance
                count += 1
            end
        end
    end
    return count
end

@testset "Phase 3C Empirical Validations" begin
    
    @testset "CRW-S-03: Two Agents Head-On Avoidance" begin
        world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
        v0 = 1.4f0
        τ = 0.5f0
        dt = 0.01f0
        
        # Agent A: left to right
        eA = new_entity!(world, (
            Position(SVector(0.0f0, -0.0f0)), Velocity(SVector(v0, 0.0f0)), AgentParams(0.2f0, 80.0f0, v0, τ, 0.0f0), Goal(SVector(10.0f0, -0.0f0)), Force(SVector(0.0f0, 0.0f0))
        ))
        # Agent B: right to left
        eB = new_entity!(world, (
            Position(SVector(10.0f0, 0.0f0)), Velocity(SVector(-v0, 0.0f0)), AgentParams(0.2f0, 80.0f0, v0, τ, 0.0f0), Goal(SVector(0.0f0, 0.0f0)), Force(SVector(0.0f0, 0.0f0))
        ))
        
        # Corridor walls (width = 2m, y from -1 to 1)
        new_entity!(world, (WallSegment(SVector(-2.0f0, 1.0f0), SVector(12.0f0, 1.0f0)),))
        new_entity!(world, (WallSegment(SVector(-2.0f0, -1.0f0), SVector(12.0f0, -1.0f0)),))
        
        sh = CPUNeighborSearch(2, SVector(-2.0f0, -2.0f0), SVector(12.0f0, 2.0f0), 4.0f0)
        
        dt = 0.001f0
        max_steps = 20000
        min_dist = 100.0f0
        for _ in 1:max_steps
            # Navigation field is simple straight lines to goal
            for (entities, pos_col, vel_col, params_col, goal_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Goal{Float32}, Force{Float32}))
                for i in eachindex(pos_col)
                    F_drive = goal_seeking_force(pos_col[i].p, vel_col[i].v, goal_col[i].g, params_col[i].v_pref, params_col[i].τ, params_col[i].mass)
                    force_col[i] = Force(F_drive)
                end
            end
            
            update_social_forces_system!(world, sh, CPU())
            integrate_physics_system!(world, dt)
            
            posA = get_components(world, eA, (Position{Float32},))[1].p
            posB = get_components(world, eB, (Position{Float32},))[1].p
            min_dist = min(min_dist, norm(posA - posB))
            
            if count_reached(world) == 2
                break
            end
        end
        
        @test count_reached(world) == 2
        @test min_dist > 0.5f0 # No interpenetration (radii 0.3+0.3 = 0.6)
    end
    
    @testset "CRW-S-04: 10-Agent Bottleneck (1.2m door)" begin
        world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
        N = 10
        dt = 0.001f0
        v0 = 1.4f0
        
        # Room: x in [0, 5], y in [0, 5]. Door at x=5, y in [1.9, 3.1]
        new_entity!(world, (WallSegment(SVector(5.0f0, 0.0f0), SVector(5.0f0, 1.9f0)),))
        new_entity!(world, (WallSegment(SVector(5.0f0, 3.1f0), SVector(5.0f0, 5.0f0)),))
        
        goal_final = SVector(10.0f0, 2.5f0)
        
        for i in 1:N
            pos = SVector(1.0f0 + rand(Float32)*3.0f0, 1.0f0 + rand(Float32)*3.0f0)
            goal_door = SVector(5.0f0, clamp(pos[2], 2.1f0, 2.9f0))
            new_entity!(world, (Position(pos), Velocity(SVector(0.0f0,0.0f0)), AgentParams(0.2f0, 80.0f0, v0, 0.5f0, 0.0f0), Goal(goal_door), Force(SVector(0.0f0,0.0f0))))
        end
        
        sh = CPUNeighborSearch(N, SVector(0.0f0, 0.0f0), SVector(12.0f0, 5.0f0), 4.0f0)
        
        function count_passed_x(world, x_val)
            count = 0
            for (entities, pos_col) in Query(world, (Position{Float32},))
                for i in eachindex(pos_col)
                    if pos_col[i].p[1] > x_val
                        count += 1
                    end
                end
            end
            return count
        end
        
        t = 0.0f0
        while count_passed_x(world, 9.0f0) < N && t < 30.0f0
            for (entities, pos_col, vel_col, params_col, goal_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Goal{Float32}, Force{Float32}))
                for i in eachindex(pos_col)
                    if pos_col[i].p[1] > 5.0f0
                        goal_col[i] = Goal(goal_final)
                    else
                        goal_col[i] = Goal(SVector(5.0f0, clamp(pos_col[i].p[2], 2.1f0, 2.9f0)))
                    end
                    F_drive = goal_seeking_force(pos_col[i].p, vel_col[i].v, goal_col[i].g, params_col[i].v_pref, params_col[i].τ, params_col[i].mass)
                    force_col[i] = Force(F_drive)
                end
            end
            
            update_social_forces_system!(world, sh, CPU())
            integrate_physics_system!(world, dt)
            t += dt
        end
        
        @test count_passed_x(world, 9.0f0) == N
        flow_rate = N / t
        @test 1.0 <= flow_rate <= 1.5 # Expected ~1.44
    end
    
    @testset "ORCA: 10-Agent Bottleneck (1.2m door)" begin
        world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
        N = 10
        dt = 0.01f0 # ORCA can use larger dt safely
        v0 = 1.4f0
        
        new_entity!(world, (WallSegment(SVector(5.0f0, 0.0f0), SVector(5.0f0, 1.9f0)),))
        new_entity!(world, (WallSegment(SVector(5.0f0, 3.1f0), SVector(5.0f0, 5.0f0)),))
        
        goal_final = SVector(10.0f0, 2.5f0)
        
        for i in 1:N
            pos = SVector(1.0f0 + rand(Float32)*3.0f0, 1.0f0 + rand(Float32)*3.0f0)
            goal_door = SVector(5.0f0, clamp(pos[2], 2.1f0, 2.9f0))
            # 2.0s time_horizon, 0.5s obst, 10 max neighbors, 15m radius
            # Include AgentParams with tiny radius (0.1m) for wall repulsion without strong agent-agent SFM repulsions
            new_entity!(world, (
                Position(pos), Velocity(SVector(0.0f0,0.0f0)), 
                AgentParams(0.1f0, 80.0f0, v0, 0.5f0, 0.5f0),
                ORCAParams(2.0f0, 0.5f0, 10, 15.0f0, 0.2f0, v0, 0.5f0, 80.0f0), 
                Goal(goal_door), Force(SVector(0.0f0,0.0f0))
            ))
        end
        
        sh = CPUNeighborSearch(N, SVector(0.0f0, 0.0f0), SVector(12.0f0, 5.0f0), 4.0f0)
        
        function count_passed_x(world, x_val)
            count = 0
            for (entities, pos_col) in Query(world, (Position{Float32},))
                for i in eachindex(pos_col)
                    if pos_col[i].p[1] > x_val
                        count += 1
                    end
                end
            end
            return count
        end
        
        t = 0.0f0
        while count_passed_x(world, 9.0f0) < N && t < 30.0f0
            for (entities, pos_col, vel_col, goal_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, Goal{Float32}, Force{Float32}))
                for i in eachindex(pos_col)
                    if pos_col[i].p[1] > 5.0f0
                        goal_col[i] = Goal(goal_final)
                    else
                        goal_col[i] = Goal(SVector(5.0f0, clamp(pos_col[i].p[2], 2.1f0, 2.9f0)))
                    end
                    # ORCA provides its own driving force, we do NOT manually add goal_seeking_force here!
                    force_col[i] = Force(SVector(0.0f0, 0.0f0))
                end
            end
            
            update_social_forces_system!(world, sh, CPU())
            update_orca_system!(world, sh, CPU(), dt)
            integrate_physics_system!(world, dt)
            t += dt
        end
        
        @test count_passed_x(world, 9.0f0) == N
        flow_rate = N / t
        println("ORCA Bottleneck flow rate: ", flow_rate, " (expected 1.0-1.5)")
        @test 1.0 <= flow_rate <= 1.5
    end
    
    @testset "CRW-S-05: Faster-is-slower (20 agents, multiple v0)" begin
        function run_panic_scenario(v_pref)
            world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
            N = 20
            dt = 0.001f0
            
            # Room: 5x5. Door at x=5, y in [2.05, 2.95] (0.9m door)
            new_entity!(world, (WallSegment(SVector(5.0f0, 0.0f0), SVector(5.0f0, 2.05f0)),))
            new_entity!(world, (WallSegment(SVector(5.0f0, 2.95f0), SVector(5.0f0, 5.0f0)),))
            
            goal_final = SVector(10.0f0, 2.5f0)
            
            for i in 1:N
                pos = SVector(1.0f0 + rand(Float32)*3.0f0, 1.0f0 + rand(Float32)*3.0f0)
                goal_door = SVector(5.0f0, clamp(pos[2], 2.1f0, 2.9f0))
                new_entity!(world, (Position(pos), Velocity(SVector(0.0f0,0.0f0)), AgentParams(0.2f0, 80.0f0, v_pref, 0.5f0, 0.0f0), Goal(goal_door), Force(SVector(0.0f0,0.0f0))))
            end
            
            sh = CPUNeighborSearch(N, SVector(0.0f0, 0.0f0), SVector(12.0f0, 5.0f0), 4.0f0)
            
            function count_passed_x(world, x_val)
                count = 0
                for (entities, pos_col) in Query(world, (Position{Float32},))
                    for i in eachindex(pos_col)
                        if pos_col[i].p[1] > x_val
                            count += 1
                        end
                    end
                end
                return count
            end
            
            t = 0.0f0
            while count_passed_x(world, 9.0f0) < N && t < 100.0f0
                for (entities, pos_col, vel_col, params_col, goal_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Goal{Float32}, Force{Float32}))
                    for i in eachindex(pos_col)
                        if pos_col[i].p[1] > 5.0f0
                            goal_col[i] = Goal(goal_final)
                        else
                            goal_col[i] = Goal(SVector(5.0f0, clamp(pos_col[i].p[2], 2.1f0, 2.9f0)))
                        end
                        F_drive = goal_seeking_force(pos_col[i].p, vel_col[i].v, goal_col[i].g, params_col[i].v_pref, params_col[i].τ, params_col[i].mass)
                        force_col[i] = Force(F_drive)
                    end
                end
                
                update_social_forces_system!(world, sh, CPU())
                integrate_physics_system!(world, dt)
                t += dt
            end
            return t
        end
        
        t_normal = run_panic_scenario(1.0f0)
        t_panic = run_panic_scenario(5.0f0)
        @test t_normal < t_panic
    end
    
    @testset "ORCA: Faster-is-slower Elimination" begin
        function run_orca_panic_scenario(v_pref)
            world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
            N = 20
            dt = 0.01f0
            
            new_entity!(world, (WallSegment(SVector(5.0f0, 0.0f0), SVector(5.0f0, 2.05f0)),))
            new_entity!(world, (WallSegment(SVector(5.0f0, 2.95f0), SVector(5.0f0, 5.0f0)),))
            
            goal_final = SVector(10.0f0, 2.5f0)
            
            for i in 1:N
                pos = SVector(1.0f0 + rand(Float32)*3.0f0, 1.0f0 + rand(Float32)*3.0f0)
                goal_door = SVector(5.0f0, clamp(pos[2], 2.1f0, 2.9f0))
                new_entity!(world, (
                    Position(pos), Velocity(SVector(0.0f0,0.0f0)), 
                    AgentParams(0.1f0, 80.0f0, v_pref, 0.5f0, 0.5f0),
                    ORCAParams(2.0f0, 0.5f0, 10, 15.0f0, 0.2f0, v_pref, 0.5f0, 80.0f0), 
                    Goal(goal_door), Force(SVector(0.0f0,0.0f0))
                ))
            end
            
            sh = CPUNeighborSearch(N, SVector(0.0f0, 0.0f0), SVector(12.0f0, 5.0f0), 4.0f0)
            
            function count_passed_x(world, x_val)
                count = 0
                for (entities, pos_col) in Query(world, (Position{Float32},))
                    for i in eachindex(pos_col)
                        if pos_col[i].p[1] > x_val
                            count += 1
                        end
                    end
                end
                return count
            end
            
            t = 0.0f0
            while count_passed_x(world, 9.0f0) < N && t < 100.0f0
                for (entities, pos_col, vel_col, goal_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, Goal{Float32}, Force{Float32}))
                    for i in eachindex(pos_col)
                        if pos_col[i].p[1] > 5.0f0
                            goal_col[i] = Goal(goal_final)
                        else
                            goal_col[i] = Goal(SVector(5.0f0, clamp(pos_col[i].p[2], 2.1f0, 2.9f0)))
                        end
                        force_col[i] = Force(SVector(0.0f0,0.0f0))
                    end
                end
                
                update_social_forces_system!(world, sh, CPU())
                update_orca_system!(world, sh, CPU(), dt)
                integrate_physics_system!(world, dt)
                t += dt
            end
            return t
        end
        
        t_normal = run_orca_panic_scenario(1.0f0)
        t_panic = run_orca_panic_scenario(5.0f0)
        println("ORCA Faster-is-slower evac times: Normal=", t_normal, "s vs Panic=", t_panic, "s")
        # In ORCA, panic should logically resolve faster because there is no friction locking arch
        @test t_panic <= t_normal
    end
    
    @testset "CRW-M-01: Bidirectional Lane Formation" begin
        world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
        N_half = 100
        N = 200
        dt = 0.001f0
        v0 = 1.4f0
        
        # Corridor: 30x4
        new_entity!(world, (WallSegment(SVector(0.0f0, 0.0f0), SVector(30.0f0, 0.0f0)),))
        new_entity!(world, (WallSegment(SVector(0.0f0, 4.0f0), SVector(30.0f0, 4.0f0)),))
        
        # Left -> Right
        for i in 1:N_half
            pos = SVector(rand(Float32)*5.0f0, rand(Float32)*4.0f0)
            new_entity!(world, (Position(pos), Velocity(SVector(v0,0.0f0)), AgentParams(0.2f0, 80.0f0, v0, 0.5f0, 0.0f0), Goal(SVector(30.0f0, pos[2])), Force(SVector(0.0f0,0.0f0))))
        end
        
        # Right -> Left
        for i in 1:N_half
            pos = SVector(25.0f0 + rand(Float32)*5.0f0, rand(Float32)*4.0f0)
            new_entity!(world, (Position(pos), Velocity(SVector(-v0,0.0f0)), AgentParams(0.2f0, 80.0f0, v0, 0.5f0, 0.0f0), Goal(SVector(0.0f0, pos[2])), Force(SVector(0.0f0,0.0f0))))
        end
        
        sh = CPUNeighborSearch(N, SVector(0.0f0, 0.0f0), SVector(30.0f0, 4.0f0), 4.0f0)
        
        # Run for 15 seconds to allow lanes to form
        for _ in 1:15000
            # Straight-line navigation for simplicity
            for (entities, pos_col, vel_col, params_col, goal_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Goal{Float32}, Force{Float32}))
                for i in eachindex(pos_col)
                    F_drive = goal_seeking_force(pos_col[i].p, vel_col[i].v, goal_col[i].g, params_col[i].v_pref, params_col[i].τ, params_col[i].mass)
                    force_col[i] = Force(F_drive)
                end
            end
            
            update_social_forces_system!(world, sh, CPU())
            integrate_physics_system!(world, dt)
        end
        
        # After 15s, they should be in steady state flow, measure mean speed
        sum_v = 0.0f0
        for (entities, vel_col) in Query(world, (Velocity{Float32},))
            for i in eachindex(vel_col)
                sum_v += norm(vel_col[i].v)
            end
        end
        mean_speed = sum_v / N
        @test mean_speed > 1.2f0 # Near v0 = 1.4
    end
    
    @testset "CRW-M-02: Fundamental Diagram (Speed vs Density)" begin
        function run_density(target_density)
            world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
            
            # We want a fixed track size to prevent tight curve issues
            R = 10.0f0
            width = 3.0f0
            dt = 0.001f0
            Area = 2.0f0 * Float32(pi) * R * width
            N = round(Int, Area * target_density)
            
            # Place agents randomly in circle
            for i in 1:N
                theta = rand(Float32) * 2.0f0 * Float32(pi)
                r = R + (rand(Float32) - 0.5f0) * width
                pos = SVector(r * cos(theta), r * sin(theta))
                
                # Goal is a bit ahead on the circle
                new_entity!(world, (Position(pos), Velocity(SVector(0.0f0,0.0f0)), AgentParams(0.2f0, 80.0f0, 1.3f0, 0.5f0, 0.0f0), Goal(SVector(0.0f0,0.0f0)), Force(SVector(0.0f0,0.0f0))))
            end
            
            # Inner wall (polygon approx)
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
            
            # Run for 20s
            for step in 1:20000
                for (entities, pos_col, vel_col, params_col, goal_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Goal{Float32}, Force{Float32}))
                    for i in eachindex(pos_col)
                        pos = pos_col[i].p
                        # Tangent vector
                        theta = atan(pos[2], pos[1])
                        dir = SVector(-sin(theta), cos(theta))
                        # Fake a goal ahead
                        goal = pos + dir * 5.0f0
                        
                        F_drive = goal_seeking_force(pos, vel_col[i].v, goal, params_col[i].v_pref, params_col[i].τ, params_col[i].mass)
                        force_col[i] = Force(F_drive)
                    end
                end
                
                update_social_forces_system!(world, sh, CPU())
                integrate_physics_system!(world, dt)
            end
            
            sum_v = 0.0f0
            for (entities, pos_col, vel_col) in Query(world, (Position{Float32}, Velocity{Float32}))
                for i in eachindex(vel_col)
                    pos = pos_col[i].p
                    theta = atan(pos[2], pos[1])
                    dir = SVector(-sin(theta), cos(theta))
                    sum_v += dot(vel_col[i].v, dir)
                end
            end
            return sum_v / N
        end
        
        v_low = run_density(0.5f0)
        v_med = run_density(2.0f0)
        v_high = run_density(5.0f0)
        
        @test v_low > 1.1f0 # free flow
        @test 0.6f0 < v_med < 1.0f0
        @test v_high < 0.5f0 # congested
    end
    
    @testset "CRW-M-03: Room Evacuation with Multiple Exits (500 agents)" begin
        world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
        N = 500
        dt = 0.01f0
        
        # Room: 30x20. Exit 1: Left wall, y in [9.0, 11.0] (2m wide). Exit 2: Right wall, y in [9.25, 10.75] (1.5m wide).
        new_entity!(world, (WallSegment(SVector(0.0f0, 0.0f0), SVector(0.0f0, 9.0f0)),))
        new_entity!(world, (WallSegment(SVector(0.0f0, 11.0f0), SVector(0.0f0, 20.0f0)),))
        
        new_entity!(world, (WallSegment(SVector(30.0f0, 0.0f0), SVector(30.0f0, 9.25f0)),))
        new_entity!(world, (WallSegment(SVector(30.0f0, 10.75f0), SVector(30.0f0, 20.0f0)),))
        
        new_entity!(world, (WallSegment(SVector(0.0f0, 0.0f0), SVector(30.0f0, 0.0f0)),))
        new_entity!(world, (WallSegment(SVector(0.0f0, 20.0f0), SVector(30.0f0, 20.0f0)),))
        
        for i in 1:N
            pos = SVector(2.0f0 + rand(Float32)*26.0f0, 2.0f0 + rand(Float32)*16.0f0)
            
            # Agents choose closest exit
            dist1 = norm(pos - SVector(0.0f0, 10.0f0))
            dist2 = norm(pos - SVector(30.0f0, 10.0f0))
            goal = dist1 < dist2 ? SVector(-5.0f0, 10.0f0) : SVector(35.0f0, 10.0f0)
            
            new_entity!(world, (Position(pos), Velocity(SVector(0.0f0,0.0f0)), AgentParams(0.2f0, 80.0f0, 1.4f0, 0.5f0, 0.0f0), Goal(goal), Force(SVector(0.0f0,0.0f0))))
        end
        
        sh = CPUNeighborSearch(N, SVector(-10.0f0, -5.0f0), SVector(40.0f0, 25.0f0), 4.0f0)
        
        # Navigation field approximation: just straight line to chosen exit
        function count_evacuated(world)
            count = 0
            for (entities, pos_col) in Query(world, (Position{Float32},))
                for i in eachindex(pos_col)
                    if pos_col[i].p[1] < 0.0f0 || pos_col[i].p[1] > 30.0f0
                        count += 1
                    end
                end
            end
            return count
        end
        
        t = 0.0f0
        while count_evacuated(world) < N && t < 150.0f0
            for (entities, pos_col, vel_col, params_col, goal_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Goal{Float32}, Force{Float32}))
                for i in eachindex(pos_col)
                    F_drive = goal_seeking_force(pos_col[i].p, vel_col[i].v, goal_col[i].g, params_col[i].v_pref, params_col[i].τ, params_col[i].mass)
                    force_col[i] = Force(F_drive)
                end
            end
            
            update_social_forces_system!(world, sh, CPU())
            integrate_physics_system!(world, dt)
            t += dt
        end
        
        @test count_evacuated(world) == N
        # Expected T ≈ 95 seconds. Allow ±20% -> 76 to 114s
        @test 76.0f0 <= t <= 114.0f0
    end
end
