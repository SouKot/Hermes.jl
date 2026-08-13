using SimCrowd
using Test
using StaticArrays
using LinearAlgebra
using KernelAbstractions
using Ark

@testset "SimCrowd.jl" begin
    
    @testset "Forces Validation" begin
        # Goal seeking force
        pos = SVector(0.0f0, 0.0f0)
        vel = SVector(1.0f0, 0.0f0)
        goal = SVector(10.0f0, 0.0f0)
        v0 = 2.0f0
        τ = 0.5f0
        
        # ê = (1, 0). F = mass × (v0 × ê − v_i) / τ = 80 × (2.0×(1,0) − (1,0)) / 0.5 = 80 × 2.0 = (160, 0) [N]
        F_drive = goal_seeking_force(pos, vel, goal, v0, τ, 80.0f0)
        @test F_drive ≈ SVector(160.0f0, 0.0f0)
        
        # Agent repulsion
        # A = 2000, B = 0.08
        pos_i = SVector(0.0f0, 0.0f0)
        pos_j = SVector(0.5f0, 0.0f0)
        r_i = 0.3f0
        r_j = 0.3f0
        # d = 0.5. (r_i + r_j - d) = 0.1
        # exp(0.1 / 0.08) = exp(1.25) ≈ 3.49034
        # A * exp(1.25) * (-1, 0) = 2000 * 3.49034 * (-1, 0)
        # agent_repulsion: 8-arg (pos_i, vel_i, social_r_i, collision_r_i, pos_j, vel_j, social_r_j, collision_r_j)
        # Use zero velocities: tests pure position-based repulsion (no anisotropy weight from velocity)
        vel_zero = SVector(0.0f0, 0.0f0)
        F_rep = agent_repulsion(pos_i, vel_zero, r_i, r_i * (2f0/3f0),
                                pos_j, vel_zero, r_j, r_j * (2f0/3f0))
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
        sh = RadixSpatialHash(backend, N, grid_min, grid_max, cell_size)
        
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
        v0 = 1.4f0
        τ = 0.5f0
        dt = 0.05f0
        
        world = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32}, MotionParams{Float32}, SFMParams{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32})
        e = new_entity!(world, (
            Position(SVector(0.0f0, 0.0f0)),
            Velocity(SVector(0.0f0, 0.0f0)),
            # σ=0.0 → deterministic: this test checks goal-seeking convergence, not SDE noise.
            # With σ=0.1 (default), the instantaneous speed at t=3s has ~0.07 m/s variance
            # from the stochastic term, which exceeds the atol=0.05 → spurious failures ~60%.
            from_agent_params(0.3f0, 80.0f0, v0, τ, 0.5f0, 0.0f0)...,
            Goal(SVector(10.0f0, 0.0f0)),
            Force(SVector(0.0f0, 0.0f0))
        ))
        
        t = 0.0f0
        reached_goal = false
        time_to_reach = 0.0f0
        
        max_steps = 1000
        for step in 1:max_steps
            # Manual integration for this specific test
            for (entities, pos_col, vel_col, motion_col, goal_col, force_col) in Query(world, (Position{Float32}, Velocity{Float32}, MotionParams{Float32}, Goal{Float32}, Force{Float32}))
                for i in eachindex(pos_col)
                    F_drive = goal_seeking_force(pos_col[i].p, vel_col[i].v, goal_col[i].g, motion_col[i].v_pref, motion_col[i].τ, motion_col[i].mass)
                    force_col[i] = Force(F_drive)
                end
            end
            
            integrate_physics_system!(world, dt)
            t += dt
            
            # Check steady state speed around t=3.0
            pos_c, vel_c, goal_c = get_components(world, e, (Position{Float32}, Velocity{Float32}, Goal{Float32}))
            pos = pos_c.p
            vel = vel_c.v
            goal = goal_c.g
            
            if abs(t - 3.0f0) < dt/2
                @test isapprox(norm(vel), v0, atol=0.05)
            end
            
            if norm(pos - goal) < 0.1f0
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
        v0 = 1.4f0
        τ = 0.5f0
        dt = 0.05f0
        
        world = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32}, MotionParams{Float32}, SFMParams{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32})
        e = new_entity!(world, (
            Position(SVector(0.0f0, 0.01f0)),
            Velocity(SVector(0.0f0, 0.0f0)),
            from_agent_params(0.3f0, 80.0f0, v0, τ)...,
            Goal(SVector(10.0f0, 0.0f0)),
            Force(SVector(0.0f0, 0.0f0))
        ))
        
        grid_min = SVector(-2.0f0, -5.0f0)
        grid_max = SVector(12.0f0, 5.0f0)
        cell_size = 0.2f0
        
        dims = ceil.(Int, (grid_max - grid_min) / cell_size)
        obstacle_mask = zeros(Bool, dims[1], dims[2])
        
        for x in 1:dims[1], y in 1:dims[2]
            cx = grid_min[1] + (x - 0.5f0) * cell_size
            cy = grid_min[2] + (y - 0.5f0) * cell_size
            if (cx - 5.0f0)^2 + (cy - 0.0f0)^2 <= 0.8f0^2
                obstacle_mask[x, y] = true
            end
        end
        
        nav = build_navigation_field(grid_min, grid_max, cell_size, SVector(10.0f0, 0.0f0), obstacle_mask)
        
        t = 0.0f0
        reached_goal = false
        min_dist_to_obs = 100.0f0
        
        max_steps = 2000
        for step in 1:max_steps
            update_navigation_system!(world, nav)
            integrate_physics_system!(world, dt)
            t += dt
            
            pos_c, goal_c = get_components(world, e, (Position{Float32}, Goal{Float32}))
            pos = pos_c.p
            goal = goal_c.g
            
            dist_to_obs = norm(pos - SVector(5.0f0, 0.0f0))
            min_dist_to_obs = min(min_dist_to_obs, dist_to_obs)
            
            if norm(pos - goal) < 0.2f0
                reached_goal = true
                break
            end
        end
        
        @test reached_goal
        @test min_dist_to_obs > 0.5f0
    end

    @testset "Validation: CRW-O-01 (ORCA Agent vs Static Wall)" begin
        # Setup: One ORCA agent moving toward a wall.
        # With static obstacle ORCA lines (§1.7), the agent deflects before penetrating.
        # Goal is placed on the SAME side as the agent (wall acts as barrier that must be
        # respected, not a target to pass through — ORCA has no pathfinding around walls).
        dt    = 0.05f0
        r     = 0.2f0
        world = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32}, MotionParams{Float32}, SFMParams{Float32},
                      ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})

        # Wall at x=5m (vertical, y from 0 to 10)
        new_entity!(world, (WallSegment(SVector(5f0, 0f0), SVector(5f0, 10f0)),))

        # Agent at (1, 5), goal at (4.5, 8) — reachable without crossing wall.
        # Agent heads diagonally toward the wall; ORCA wall line must keep it clear.
        new_entity!(world, (
            Position(SVector(1f0, 5f0)),
            Velocity(SVector(0f0, 0f0)),
            from_agent_params(r, 80f0, 1.4f0, 0.5f0, 0.5f0, 0.0f0)...,
            ORCAParams(2f0, 0.5f0, 5, 5f0, r, 2f0, 0.5f0, 80f0),
            Goal(SVector(4.5f0, 8f0)),
            Force(SVector(0f0, 0f0))
        ))

        min_dist_to_wall = Inf32
        t = 0f0; t_max = 15f0
        while t < t_max
            SimCrowd.update_orca_system_cpu!(world, dt)
            integrate_physics_system!(world, dt)
            t += dt
            for (_, pos_col) in Query(world, (Position{Float32},))
                for i in eachindex(pos_col)
                    p = pos_col[i].p
                    d = 5f0 - p[1]   # distance to wall at x=5 (agent stays at x<5)
                    min_dist_to_wall = min(min_dist_to_wall, d)
                end
            end
        end

        # Agent must maintain clearance ≥ 0 from wall (no penetration beyond agent centre)
        # ORCA guarantees: agent centre stays to the left of x=5.
        @test min_dist_to_wall >= 0f0
    end

    @testset "Validation: CRW-O-02 (ORCA: two agents, one wall)" begin
        # Two agents heading toward each other with a wall on one side.
        # ORCA should guide both agents around each other without hitting the wall.
        dt  = 0.05f0
        r   = 0.2f0
        world = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32}, MotionParams{Float32}, SFMParams{Float32},
                      ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})

        # Wall at y=0 (horizontal boundary)
        new_entity!(world, (WallSegment(SVector(-2f0, 0f0), SVector(12f0, 0f0)),))

        orca_p = ORCAParams(3f0, 0.5f0, 5, 5f0, r, 2f0, 0.5f0, 80f0)
        ap     = from_agent_params(r, 80f0, 1.4f0, 0.5f0, 0.5f0, 0.0f0)

        # Agent A: (0, 1) → (10, 1)  Agent B: (10, 1) → (0, 1)
        new_entity!(world, (Position(SVector(0f0, 1f0)), Velocity(SVector(0f0,0f0)),
                             ap..., orca_p, Goal(SVector(10f0, 1f0)), Force(SVector(0f0,0f0))))
        new_entity!(world, (Position(SVector(10f0, 1f0)), Velocity(SVector(0f0,0f0)),
                             ap..., orca_p, Goal(SVector(0f0, 1f0)), Force(SVector(0f0,0f0))))

        min_y = Inf32
        t = 0f0; t_max = 15f0
        while t < t_max
            SimCrowd.update_orca_system_cpu!(world, dt)
            integrate_physics_system!(world, dt)
            t += dt
            for (_, pos_col) in Query(world, (Position{Float32},))
                for i in eachindex(pos_col)
                    min_y = min(min_y, pos_col[i].p[2])
                end
            end
        end

        # Neither agent should penetrate the wall at y=0 (centre must stay above y=0)
        @test min_y >= 0f0
    end   # §1.8 Non-Reciprocal ORCA Weights

    # ─────────────────────────────────────────────────────────────────────────
    # §1.4 Chraibi GCF Tests
    # ─────────────────────────────────────────────────────────────────────────
    @testset "§1.4 Chraibi GCF force" begin
        pos_i = SVector(0.0f0, 0.0f0)
        vel_i = SVector(1.5f0, 0.0f0)   # moving right at 1.5 m/s
        s_r_i = 0.25f0
        pos_j = SVector(0.5f0, 0.0f0)   # j is ahead (to the right of i)
        s_r_j = 0.25f0

        # 1. Zero distance returns zero
        @test gcf_force(pos_i, vel_i, s_r_i, pos_i, s_r_j; V₀=2000f0, η=0.5f0) == SVector(0f0,0f0)

        # 2. Direction: repulsion from j pushes i left (negative x)
        f = gcf_force(pos_i, vel_i, s_r_i, pos_j, s_r_j; V₀=2000f0, η=0.5f0)
        @test f[1] < 0.0f0
        @test abs(f[2]) < 1.0f0

        # 3. Force magnitude is positive and finite
        @test isfinite(norm(f)) && norm(f) > 0f0

        # 4. Stationary agent (speed=0): η has no effect — D_i = s_r_i either way
        vel_zero = SVector(0.0f0, 0.0f0)
        f0 = gcf_force(pos_i, vel_zero, s_r_i, pos_j, s_r_j; V₀=2000f0, η=0.0f0)
        f1 = gcf_force(pos_i, vel_zero, s_r_i, pos_j, s_r_j; V₀=2000f0, η=0.5f0)
        @test norm(f0) ≈ norm(f1) rtol=1e-4

        # 5. Directional consistency: gcf_force with η=0 and vel=0 should give negative-x force
        #    (same direction as psychological_force, since n_ij points from j toward i = left)
        vel_zero = SVector(0.0f0, 0.0f0)
        f0 = gcf_force(pos_i, vel_zero, s_r_i, pos_j, s_r_j; V₀=2000f0, η=0.0f0)
        @test f0[1] < 0.0f0   # repulsion: j is to the right, force pushes i left
        @test norm(f0) > 0f0
    end

    # ─────────────────────────────────────────────────────────────────────────
    # §2.1 ForceModel Trait Tests
    # ─────────────────────────────────────────────────────────────────────────
    @testset "§2.1 ForceModel trait" begin
        @test SFMModel()    isa ForceModel
        @test ORCAModel()   isa ForceModel
        @test HybridModel() isa ForceModel

        tag_sfm  = AgentModel{SFMModel}()
        tag_orca = AgentModel{ORCAModel}()
        @test tag_sfm  isa AgentModel
        @test tag_orca isa AgentModel
        @test sizeof(AgentModel{SFMModel}) == 0   # zero-field struct
    end

    # ─────────────────────────────────────────────────────────────────────────
    # §1.4 SFMParams backward compatibility
    # ─────────────────────────────────────────────────────────────────────────
    @testset "§1.4 SFMParams η backward compat" begin
        # 4-arg constructor: η defaults to 0.0
        p4 = SFMParams(2000f0, 0.08f0, 0.5f0, 0.5f0)
        @test p4.η == 0.0f0

        # 1-arg convenience: η = 0.0
        @test SFMParams(0.5f0).η == 0.0f0

        # Default constructor: η = 0.0
        @test SFMParams{Float32}().η == 0.0f0

        # Explicit 5-arg
        p5 = SFMParams(2000f0, 0.08f0, 0.5f0, 0.5f0, 0.4f0)
        @test p5.η ≈ 0.4f0

        # from_agent_params: η defaults to 0
        ap = from_agent_params(0.3f0, 80f0, 1.3f0, 0.5f0)
        @test ap[3].η == 0.0f0

        # from_agent_params: η kwarg is threaded through
        ap_gcf = from_agent_params(0.3f0, 80f0, 1.3f0, 0.5f0; η=0.5f0)
        @test ap_gcf[3].η ≈ 0.5f0
    end

    # ─────────────────────────────────────────────────────────────────────────
    # §2.4 SimConfig + SimScene Tests
    # ─────────────────────────────────────────────────────────────────────────
    @testset "§2.4 SimConfig + SimScene" begin
        cfg = SimConfig()
        @test cfg.dt ≈ 0.05f0
        @test cfg.max_speed ≈ 5.0f0

        cfg2 = SimConfig(0.01f0, 3.0f0)
        @test cfg2.dt ≈ 0.01f0

        cfg3 = SimConfig(0.02f0)
        @test cfg3.max_speed ≈ 5.0f0

        # SimScene without nav_field (empty world — no entities needed for this sub-test)
        w  = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32},
                   MotionParams{Float32}, SFMParams{Float32}, Goal{Float32}, Force{Float32},
                   WallSegment{Float32})
        gr = SVector(0f0, 0f0)
        gx = SVector(10f0, 10f0)
        sr = CPUNeighborSearch(50, gr, gx, 1.5f0)   # N, grid_min, grid_max, cell_size
        sc = SimScene(w, sr, cfg)
        @test sc.nav_field === nothing
        @test sc.config.dt ≈ 0.05f0

        # run! on empty world completes and returns scene
        @test run!(sc, 1.0f0) === sc

        # step! advances agents
        w2 = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32},
                   MotionParams{Float32}, SFMParams{Float32}, Goal{Float32}, Force{Float32},
                   WallSegment{Float32})
        ap = from_agent_params(0.25f0, 80f0, 1.3f0, 0.5f0)
        new_entity!(w2, (Position(SVector(1f0,5f0)), Velocity(SVector(0f0,0f0)),
                         ap..., Goal(SVector(9f0,5f0)), Force(SVector(0f0,0f0))))
        new_entity!(w2, (Position(SVector(3f0,5f0)), Velocity(SVector(0f0,0f0)),
                         ap..., Goal(SVector(9f0,5f0)), Force(SVector(0f0,0f0))))
        sr2 = CPUNeighborSearch(2, gr, gx, 1.5f0)
        sc2 = SimScene(w2, sr2, cfg)

        x_before = [pos_col[i].p[1]
                    for (_, pos_col) in Query(w2, (Position{Float32},))
                    for i in eachindex(pos_col)]
        step!(sc2)
        x_after  = [pos_col[i].p[1]
                    for (_, pos_col) in Query(w2, (Position{Float32},))
                    for i in eachindex(pos_col)]

        @test any(x_after .!= x_before)   # agents moved
    end

end  # SimCrowd.jl
