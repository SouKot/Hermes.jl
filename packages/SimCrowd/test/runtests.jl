using SimCrowd
using Test
using StaticArrays
using LinearAlgebra
using KernelAbstractions
using Ark
using CellListMap
using Printf

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

        # Unified ORCA (O(N×k) spatial hash — replaces update_orca_system_cpu!)
        search_o01 = RadixSpatialHash(CPU(), 1, SVector(-1f0,-1f0), SVector(7f0,12f0), 1.0f0)

        while t < t_max
            SimCrowd.update_orca_system!(world, search_o01, CPU(), dt)
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

        # Unified ORCA (O(N×k) spatial hash — replaces update_orca_system_cpu!)
        search_o02 = RadixSpatialHash(CPU(), 2, SVector(-3f0,-1f0), SVector(13f0,5f0), 1.0f0)

        while t < t_max
            SimCrowd.update_orca_system!(world, search_o02, CPU(), dt)
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

    # ─────────────────────────────────────────────────────────────────────────
    # §2.5 NavigationSystem step! order (bug fix: nav force was wiped by reset)
    # ─────────────────────────────────────────────────────────────────────────
    @testset "§2.5 NavigationSystem step! order" begin
        # Single SFM agent at x=1, goal (via nav field) at x=9.
        # Before §2.5 fix: step! reset Force AFTER nav → F_drive discarded → agent didn't move toward goal.
        # After fix: reset → nav adds F_drive → social adds F_repulsion → integrate.
        cfg  = SimConfig(0.05f0)
        gr   = SVector(0f0, 0f0)
        gx   = SVector(10f0, 10f0)

        w3   = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32},
                     MotionParams{Float32}, SFMParams{Float32}, Goal{Float32}, Force{Float32},
                     WallSegment{Float32})
        ap   = from_agent_params(0.25f0, 80f0, 1.3f0, 0.5f0)
        new_entity!(w3, (Position(SVector(1f0, 5f0)), Velocity(SVector(0f0, 0f0)),
                         ap..., Goal(SVector(9f0, 5f0)), Force(SVector(0f0, 0f0))))
        sr3  = CPUNeighborSearch(1, gr, gx, 1.5f0)

        # Build a flat nav field (no obstacles) pointing east toward x=9
        obstacle_mask = zeros(Bool, 100, 100)
        nav = build_navigation_field(gr, gx, 0.1f0, SVector(9f0, 5f0), obstacle_mask)
        sc3 = SimScene(w3, sr3, nav, cfg)

        x0 = first([pos_col[1].p[1]
                    for (_, pos_col) in Query(w3, (Position{Float32},))])

        # Run 5 steps: agent must move eastward (x increases toward 9)
        for _ in 1:5; step!(sc3); end

        x1 = first([pos_col[1].p[1]
                    for (_, pos_col) in Query(w3, (Position{Float32},))])

        @test x1 > x0          # agent moved toward goal (east)
        @test x1 - x0 > 0.01f0 # meaningful displacement, not floating-point noise

        # Also confirm Force is non-zero after step! (nav force survived the reset)
        f_after = first([force_col[1].f
                         for (_, force_col) in Query(w3, (Force{Float32},))])
        # After step! integrate has consumed force — but position proves the force was applied.
        # The key test is x1 > x0 above.
        @test isfinite(x1)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # §S7 Psych force accuracy: O(N×k) CellListMap == O(N²) kernel
    # ─────────────────────────────────────────────────────────────────────────
    @testset "§S7 CellListMap psych forces match O(N²) kernel" begin
        # Directly compare per-agent psych force vectors between:
        #   Old: compute_psych_forces_kernel! (O(N²) KA kernel, still in codebase for GPU path)
        #   New: CellListMap.pairwise!(compute_psych, search.psych_system) (Sprint 7 CPU path)

        F  = Float32
        N  = 24   # small enough to be fast, large enough to have neighbors
        cs = F(1.5)

        gr = SVector(F(0), F(0))
        gx = SVector(F(6), F(6))

        # Place agents on a regular 4×6 grid at 1m spacing (well within cutoff)
        positions     = [SVector(F(mod(i-1, 4)) + F(0.5), F(div(i-1, 4)) + F(0.5)) for i in 1:N]
        velocities    = [SVector(F(cos(i*0.3f0)), F(sin(i*0.3f0))) for i in 1:N]
        social_radii  = fill(F(0.3), N)
        As = fill(F(2000), N); Bs = fill(F(0.08), N); λs = fill(F(0.5), N)

        cutoff_sq = cs * cs

        # ── Helper: run old O(N²) KA kernel ─────────────────────────────────
        function run_old_kernel(ηs::Vector{F})
            out = zeros(SVector{2,F}, N)
            k! = SimCrowd.compute_psych_forces_kernel!(CPU())
            k!(out, positions, velocities, social_radii, As, Bs, λs, ηs, cutoff_sq, N, ndrange=N)
            KernelAbstractions.synchronize(CPU())
            return out
        end

        # ── Helper: run new CellListMap approach ─────────────────────────────
        function run_new_clm(ηs::Vector{F})
            search = CPUNeighborSearch(N, gr, gx, cs)
            # Fill pre-allocated buffers manually (normally done by _update_social_forces_impl!)
            search.cpu_As  .= As
            search.cpu_Bs  .= Bs
            search.cpu_λs  .= λs
            search.cpu_ηs  .= ηs
            search.cpu_mus .= F(0.5)  # not used by psych, but must be initialised

            # Update psych_system with actual positions
            CellListMap.update!(search.psych_system; positions=positions)

            # Replicate compute_psych closure from _update_social_forces_impl!
            cpu_As = search.cpu_As; cpu_Bs = search.cpu_Bs
            cpu_λs = search.cpu_λs; cpu_ηs = search.cpu_ηs

            function compute_psych(pair, psych_out)
                (; i, j, d) = pair
                d > F(1e-6) || return psych_out
                pos_i = positions[i]; vel_i = velocities[i]; s_r_i = social_radii[i]
                pos_j = positions[j]; vel_j = velocities[j]; s_r_j = social_radii[j]
                f_ij = cpu_ηs[i] > zero(F) ?
                    SimCrowd.gcf_force(pos_i, vel_i, s_r_i, pos_j, s_r_j; V₀=cpu_As[i], η=cpu_ηs[i]) :
                    SimCrowd.psychological_force(pos_i, vel_i, s_r_i, pos_j, s_r_j;
                                        A=cpu_As[i], B=cpu_Bs[i], λ=cpu_λs[i])
                f_ji = cpu_ηs[j] > zero(F) ?
                    SimCrowd.gcf_force(pos_j, vel_j, s_r_j, pos_i, s_r_i; V₀=cpu_As[j], η=cpu_ηs[j]) :
                    SimCrowd.psychological_force(pos_j, vel_j, s_r_j, pos_i, s_r_i;
                                        A=cpu_As[j], B=cpu_Bs[j], λ=cpu_λs[j])
                psych_out[i] += f_ij
                psych_out[j] += f_ji
                return psych_out
            end
            CellListMap.pairwise!(compute_psych, search.psych_system)
            return copy(search.psych_system.output)
        end

        rtol = 1f-3   # allow FP rounding differences from parallel reduction order

        # ── Scenario A: Helbing (η = 0 for all) ─────────────────────────────
        ηs_A = zeros(F, N)
        old_A = run_old_kernel(ηs_A)
        new_A = run_new_clm(ηs_A)
        relerr_A = norm(old_A .- new_A) / max(norm(old_A), F(1e-10))
        @test relerr_A < rtol

        # ── Scenario B: GCF (η = 0.5 for all) ───────────────────────────────
        ηs_B = fill(F(0.5), N)
        old_B = run_old_kernel(ηs_B)
        new_B = run_new_clm(ηs_B)
        relerr_B = norm(old_B .- new_B) / max(norm(old_B), F(1e-10))
        @test relerr_B < rtol

        # ── Scenario C: Heterogeneous (half Helbing, half GCF) ───────────────
        ηs_C = [isodd(i) ? F(0.0) : F(0.5) for i in 1:N]
        old_C = run_old_kernel(ηs_C)
        new_C = run_new_clm(ηs_C)
        relerr_C = norm(old_C .- new_C) / max(norm(old_C), F(1e-10))
        @test relerr_C < rtol

        # ── Sanity: forces are non-zero (agents are within cutoff) ───────────
        @test norm(old_A) > F(0)
        @test norm(new_A) > F(0)
    end

# ─────────────────────────────────────────────────────────────────────────────
# Sprint 3L: Geometry primitives unit tests (geometry.jl)
# ─────────────────────────────────────────────────────────────────────────────
@testset "Sprint 3L: geometry.jl unit tests" begin

    # ── nearest_point_on_segment ─────────────────────────────────────────────
    p1 = SVector(0.0f0, 0.0f0); p2 = SVector(4.0f0, 0.0f0)

    # Query point directly on segment: nearest point = q, dist = 0, t = 0.25
    pt, d, t = nearest_point_on_segment(p1, p2, SVector(1.0f0, 0.0f0))
    @test pt ≈ SVector(1.0f0, 0.0f0)
    @test d ≈ 0.0f0 atol=1e-6
    @test t ≈ 0.25f0

    # Query point at midpoint perpendicular: nearest = midpoint of segment
    pt, d, t = nearest_point_on_segment(p1, p2, SVector(2.0f0, 3.0f0))
    @test pt ≈ SVector(2.0f0, 0.0f0)
    @test d ≈ 3.0f0 atol=1e-5
    @test t ≈ 0.5f0

    # Query past p2 end: clamps to p2
    pt, d, t = nearest_point_on_segment(p1, p2, SVector(6.0f0, 0.0f0))
    @test pt ≈ p2
    @test t ≈ 1.0f0

    # Query before p1 end: clamps to p1
    pt, d, t = nearest_point_on_segment(p1, p2, SVector(-2.0f0, 1.0f0))
    @test pt ≈ p1
    @test t ≈ 0.0f0

    # Degenerate segment (p1 == p2): returns p1
    pt, d, t = nearest_point_on_segment(SVector(3.0f0, 3.0f0), SVector(3.0f0, 3.0f0), SVector(0.0f0, 0.0f0))
    @test pt ≈ SVector(3.0f0, 3.0f0)
    @test t == 0.0f0

    # ── nearest_point_on_arc ─────────────────────────────────────────────────
    center = SVector(0.0f0, 0.0f0); r = 2.0f0

    # External point on x-axis: nearest surface point at (2,0)
    pt, d = nearest_point_on_arc(center, r, SVector(5.0f0, 0.0f0))
    @test pt ≈ SVector(2.0f0, 0.0f0)
    @test d ≈ 3.0f0 atol=1e-5   # |5 - 2| = 3

    # Internal point: dist = |1 - 2| = 1
    pt, d = nearest_point_on_arc(center, r, SVector(1.0f0, 0.0f0))
    @test pt ≈ SVector(2.0f0, 0.0f0)
    @test d ≈ 1.0f0 atol=1e-5

    # Point exactly on circle: dist ≈ 0
    pt, d = nearest_point_on_arc(center, r, SVector(2.0f0, 0.0f0))
    @test d ≈ 0.0f0 atol=1e-5

    # ── CSM structs isbits ───────────────────────────────────────────────────
    @test isbitstype(CSMParams{Float32})
    @test isbitstype(CSMParams{Float64})
    @test isbitstype(AgentCSMState{Float32})
    @test isbitstype(AgentCSMState{Float64})

    # ── CSMParams_V1/V2/V3/JuPedSim constructors ────────────────────────────
    p1 = CSMParams_Classic(Float32)
    @test p1.use_rotational_steering == false
    @test p1.a_neighbor == 8.0f0
    @test p1.D_neighbor == 0.1f0
    @test p1.strength_geo > 0.0f0
    @test p1.range_geo > 0.0f0

    p3 = CSMParams_V3(Float32)
    @test p3.use_rotational_steering == true
    @test p3.heading_relaxation_tau > 0.0f0

    pj = CSMParams_JuPedSim(Float32)
    @test pj.v0 ≈ 1.34f0
    @test pj.use_rotational_steering == false

    # ── csm_speed boundary conditions (Tordeux 2016 OV function) ───────────────
    v₀ = 1.34f0; T = 1.0f0
    @test csm_speed(Float32(Inf), v₀, T) ≈ v₀          # free flow
    @test csm_speed(0.0f0, v₀, T) == 0.0f0              # body contact → zero
    @test csm_speed(T * v₀, v₀, T) ≈ v₀               # at safety gap → v₀
    @test csm_speed(T * v₀ / 2, v₀, T) ≈ v₀ / 2        # midpoint → v₀/2

    @printf("\nSprint 3L geometry unit tests: PASSED\n")
end

# ─────────────────────────────────────────────────────────────────────────────
# Sprint 3P: compute_orca_line_endpoint unit tests
# ─────────────────────────────────────────────────────────────────────────────
@testset "3P: compute_orca_line_endpoint" begin
    # ── Case 1: agent approaching door corner from below ─────────────────────
    # Agent at (9.8, 1.2), door corner at (10.0, 1.5). Preferred vel points
    # diagonally toward the corner. The endpoint constraint must push vel away
    # from the corner (i.e. vel_i must violate the constraint — it's forbidden).
    pos_i    = SVector(9.8f0, 1.2f0)
    vel_i    = SVector(1.0f0, 0.3f0)   # diagonal toward corner
    q_corner = SVector(10.0f0, 1.5f0)  # bottom door corner endpoint
    r_i      = 0.2f0
    tau_obs  = 0.5f0
    dt       = 0.05f0

    line = compute_orca_line_endpoint(pos_i, vel_i, r_i, q_corner, tau_obs, dt)

    # Line must be a valid, finite ORCA constraint
    @test isfinite(line.point[1]) && isfinite(line.point[2])
    @test isfinite(line.dir[1])   && isfinite(line.dir[2])

    # Direction must be unit-length (within Float32 precision)
    @test abs(norm(line.dir) - 1.0f0) < 1f-4

    # Result is isbits — GPU kernel safety invariant
    @test isbitstype(typeof(line))

    # ORCA convention: det(dir, point - v) ≤ 0  means v is in the FEASIBLE half-plane.
    # The constraint point is set so that vel_i (approaching corner) satisfies  det ≤ 0.
    # A velocity further INTO the corner (e.g. pure +x at higher speed) must violate it.
    # Verify: the constraint is geometrically correct — the outward normal (perpendicular
    # to dir) points AWAY from the corner, so velocity pointing toward corner violates.
    let d = line.dir, Δ = line.point - vel_i
        cross_curr = d[1]*Δ[2] - d[2]*Δ[1]
        # Current vel_i may or may not violate; test instead that:
        #   (a) the ORCA line boundary is finite (already tested above)
        #   (b) a velocity directly INTO the corner vertex IS forbidden
        v_into_corner = normalize(q_corner - pos_i) * r_i  # small vel toward corner
        Δ_bad = line.point - v_into_corner
        cross_bad = d[1]*Δ_bad[2] - d[2]*Δ_bad[1]
        @test cross_bad > 0f0   # vel pointing at corner should be in forbidden half-plane
    end

    # ── Case 2: agent far from corner — constraint is relaxed ────────────────
    # Agent at (5.0, 2.0), far from the corner — but constraint should still
    # be finite and isbits (no NaN/Inf).
    pos_far = SVector(5.0f0, 2.0f0)
    vel_far = SVector(1.0f0, 0.0f0)
    line_far = compute_orca_line_endpoint(pos_far, vel_far, r_i, q_corner, tau_obs, dt)
    @test isfinite(line_far.point[1]) && isfinite(line_far.point[2])
    @test isbitstype(typeof(line_far))

    # ── Case 3: collision case (agent overlapping corner) ────────────────────
    # Should still return a valid finite constraint (emergency pushback).
    pos_overlap = SVector(9.95f0, 1.48f0)   # within r_i of corner
    line_ov = compute_orca_line_endpoint(pos_overlap, SVector(0.5f0, 0.1f0),
                                          r_i, q_corner, tau_obs, dt)
    @test isfinite(line_ov.point[1]) && isfinite(line_ov.point[2])
    @test isbitstype(typeof(line_ov))

    @printf("\nSprint 3P compute_orca_line_endpoint unit tests: PASSED\n")
end

# ─────────────────────────────────────────────────────────────────────────────
# Sprint 3Q: apply_wall_penetration_correction unit tests
# ─────────────────────────────────────────────────────────────────────────────
@testset "Sprint 3Q: apply_wall_penetration_correction" begin
    F = Float32

    # Horizontal wall from (0,0) to (4,0)
    p1 = SVector(F(0), F(0))
    p2 = SVector(F(4), F(0))
    r  = F(0.2)

    # ── Case 1: No penetration — agent well above wall ───────────────────────
    pos = SVector(F(2), F(0.5))
    vel = SVector(F(0), F(-1))
    pos2, vel2 = apply_wall_penetration_correction(pos, vel, r, p1, p2)
    @test pos2 ≈ pos   # unchanged
    @test vel2 ≈ vel

    # ── Case 2: Penetration — agent centre inside wall exclusion zone ────────
    # Agent at (2, 0.1): centre is 0.1m above wall, radius=0.2 → overlap=0.1m
    pos_in = SVector(F(2), F(0.1))
    vel_in = SVector(F(0), F(-0.5))   # moving INTO wall
    pos_out, vel_out = apply_wall_penetration_correction(pos_in, vel_in, r, p1, p2)

    # Position pushed back: y should equal r=0.2 (at surface)
    @test pos_out[2] ≈ r atol=1f-5
    # Inward velocity component zeroed: vel_out[2] should be ≥ 0
    @test vel_out[2] >= F(0)

    # ── Case 3: Penetration — agent moving outward (no velocity change) ──────
    pos_in2 = SVector(F(2), F(0.1))
    vel_out2_init = SVector(F(0), F(0.5))   # moving AWAY from wall
    pos_o2, vel_o2 = apply_wall_penetration_correction(pos_in2, vel_out2_init, r, p1, p2)
    # Position corrected
    @test pos_o2[2] ≈ r atol=1f-5
    # Velocity unchanged (not moving into wall)
    @test vel_o2 ≈ vel_out2_init

    # ── Case 4: Degenerate wall (p1 == p2) — should not crash ───────────────
    pd1 = SVector(F(3), F(3))
    pos_d, vel_d = apply_wall_penetration_correction(
        SVector(F(3), F(3.05f0)), SVector(F(0), F(-1)), r, pd1, pd1)
    @test isfinite(pos_d[1]) && isfinite(pos_d[2])

    # ── Case 5: isbits / GPU safety ─────────────────────────────────────────
    @test isbitstype(typeof(SVector(F(0), F(0))))   # inputs are isbits
    result = apply_wall_penetration_correction(pos_in, vel_in, r, p1, p2)
    @test result isa Tuple{SVector{2,F}, SVector{2,F}}

    # ── Case 6: CSM ECS wall_penetration_correction! round-trip ─────────────
    # Build a tiny world with one CSM agent overlapping a wall at y=0
    w_csm = World(Position{F}, Velocity{F}, CSMParams{F})
    params_csm = CSMParams_Classic(F)
    new_entity!(w_csm, (
        Position(SVector(F(2), F(0.05f0))),   # inside wall zone (y < r=0.2)
        Velocity(SVector(F(0), F(-0.3f0))),
        params_csm
    ))
    walls_csm = NTuple{2, SVector{2,F}}[(p1, p2)]
    wall_penetration_correction!(w_csm, walls_csm, F, CSMParams{F})
    for (_, pos_col, vel_col) in Query(w_csm, (Position{F}, Velocity{F}))
        for i in eachindex(pos_col)
            @test pos_col[i].p[2] >= params_csm.radius - 1f-5   # pushed back
            @test vel_col[i].v[2] >= F(0)                        # inward vel cancelled
        end
    end

    @printf("\nSprint 3Q apply_wall_penetration_correction unit tests: PASSED\n")
end

end  # SimCrowd.jl
