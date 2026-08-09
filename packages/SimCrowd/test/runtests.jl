using SimCrowd
using Test
using StaticArrays
using LinearAlgebra
using KernelAbstractions

@testset "SimCrowd.jl" begin
    
    @testset "Forces Validation" begin
        # Goal seeking force
        pos = SVector(0.0f0, 0.0f0)
        vel = SVector(1.0f0, 0.0f0)
        goal = SVector(10.0f0, 0.0f0)
        v0 = 2.0f0
        τ = 0.5f0
        
        # ê = (1, 0). (2.0*(1,0) - (1,0)) / 0.5 = (2, 0)
        F_drive = goal_seeking_force(pos, vel, goal, v0, τ)
        @test F_drive ≈ SVector(2.0f0, 0.0f0)
        
        # Agent repulsion
        # A = 2000, B = 0.08
        pos_i = SVector(0.0f0, 0.0f0)
        pos_j = SVector(0.5f0, 0.0f0)
        r_i = 0.3f0
        r_j = 0.3f0
        # d = 0.5. (r_i + r_j - d) = 0.1
        # exp(0.1 / 0.08) = exp(1.25) ≈ 3.49034
        # A * exp(1.25) * (-1, 0) = 2000 * 3.49034 * (-1, 0)
        F_rep = agent_repulsion(pos_i, pos_j, r_i, r_j)
        @test F_rep[1] < 0.0f0
        @test F_rep[2] == 0.0f0
    end
    
    @testset "Spatial Hash Correctness" begin
        # Generate 100 random agents in a 10x10 grid
        N = 100
        grid_min = SVector(0.0f0, 0.0f0)
        grid_max = SVector(10.0f0, 10.0f0)
        cell_size = 1.0f0
        
        # We need a fallback Backend since CPU() is from KernelAbstractions
        backend = CPU()
        sh = SpatialHash(backend, N, grid_min, grid_max, cell_size)
        
        # Generate random positions
        positions = [SVector{2, Float32}(rand()*10, rand()*10) for _ in 1:N]
        
        # Build grid
        build_grid!(sh, positions, backend)
        
        # Naive O(N^2) comparison
        function naive_neighbors(positions, target_pos, cell_size)
            neighbors = Int[]
            
            dims_x, dims_y = 10, 10
            
            idx2 = floor.(Int, (target_pos - grid_min) / cell_size)
            t_x = clamp(idx2[1], 0, dims_x - 1)
            t_y = clamp(idx2[2], 0, dims_y - 1)
            
            for (i, p) in enumerate(positions)
                idx1 = floor.(Int, (p - grid_min) / cell_size)
                p_x = clamp(idx1[1], 0, dims_x - 1)
                p_y = clamp(idx1[2], 0, dims_y - 1)
                
                if abs(p_x - t_x) <= 1 && abs(p_y - t_y) <= 1
                    push!(neighbors, i)
                end
            end
            return sort(neighbors)
        end
        
        # Check a few agents
        for i in 1:10
            target_pos = positions[i]
            naive = naive_neighbors(positions, target_pos, cell_size)
            
            # Get neighbors from spatial hash
            sh_neighbors = Int[]
            for n_idx in get_neighbors(sh, target_pos)
                push!(sh_neighbors, n_idx)
            end
            sort!(sh_neighbors)
            
            @test naive == sh_neighbors
        end
    end
    
    @testset "Validation: CRW-S-01 (Straight-Line Goal Seeking)" begin
        # Setup: One agent at (0,0), goal (10,0)
        # v0 = 1.4, τ = 0.5
        v0 = 1.4f0
        τ = 0.5f0
        dt = 0.05f0
        
        agent = CrowdAgent(
            UInt64(1), SVector(0.0f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.3f0, v0, τ, SVector(10.0f0, 0.0f0)
        )
        
        integrator = SymplecticEuler()
        
        t = 0.0f0
        reached_goal = false
        time_to_reach = 0.0f0
        
        max_steps = 1000
        for step in 1:max_steps
            # Only goal seeking force
            F_drive = goal_seeking_force(agent.position, agent.velocity, agent.goal, v0, τ)
            integrate_agent!(agent, F_drive, dt, integrator)
            t += dt
            
            # Check steady state speed around t=3.0
            if abs(t - 3.0f0) < dt/2
                @test isapprox(norm(agent.velocity), v0, atol=0.05)
            end
            
            if norm(agent.position - agent.goal) < 0.1f0
                reached_goal = true
                time_to_reach = t
                break
            end
        end
        
        @test reached_goal
        # Analytical time ≈ 7.6 sec
        @test isapprox(time_to_reach, 7.6f0, rtol=0.05)
    end
    
    @testset "Validation: CRW-S-02 (Obstacle Avoidance)" begin
        # Setup: Agent at (0, 0.01) to break perfect symmetry saddle point
        # goal (10,0). Obstacle at (5,0) radius 0.5m
        v0 = 1.4f0
        τ = 0.5f0
        dt = 0.05f0
        
        agent = CrowdAgent(
            UInt64(1), SVector(0.0f0, 0.01f0), SVector(0.0f0, 0.0f0), 0.3f0, v0, τ, SVector(10.0f0, 0.0f0)
        )
        
        # We will use navigation field for obstacle avoidance
        grid_min = SVector(-2.0f0, -5.0f0)
        grid_max = SVector(12.0f0, 5.0f0)
        cell_size = 0.2f0
        
        dims = ceil.(Int, (grid_max - grid_min) / cell_size)
        obstacle_mask = zeros(Bool, dims[1], dims[2])
        
        # Fill obstacle mask for circle at (5,0), radius 0.5m + agent radius 0.3m = 0.8m
        for x in 1:dims[1], y in 1:dims[2]
            cx = grid_min[1] + (x - 0.5f0) * cell_size
            cy = grid_min[2] + (y - 0.5f0) * cell_size
            if (cx - 5.0f0)^2 + (cy - 0.0f0)^2 <= 0.8f0^2
                obstacle_mask[x, y] = true
            end
        end
        
        nav = build_navigation_field(grid_min, grid_max, cell_size, agent.goal, obstacle_mask)
        
        integrator = SymplecticEuler()
        
        t = 0.0f0
        reached_goal = false
        min_dist_to_obs = 100.0f0
        
        max_steps = 2000
        for step in 1:max_steps
            dir = get_desired_direction(nav, agent.position)
            F_drive = (v0 * dir - agent.velocity) / τ
            integrate_agent!(agent, F_drive, dt, integrator)
            t += dt
            
            # Check distance to obstacle
            dist_to_obs = norm(agent.position - SVector(5.0f0, 0.0f0))
            min_dist_to_obs = min(min_dist_to_obs, dist_to_obs)
            
            if norm(agent.position - agent.goal) < 0.2f0
                reached_goal = true
                break
            end
        end
        
        @test reached_goal
        # Agent radius is 0.3, obstacle radius is 0.5
        @test min_dist_to_obs > 0.5f0
    end
end
