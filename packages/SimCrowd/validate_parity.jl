using Pkg
Pkg.activate(".")
Pkg.instantiate()

using SimCrowd
using StaticArrays
using KernelAbstractions
using CUDA
using Ark
using Random
using LinearAlgebra

function clone_world(orig_world)
    w = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32}, MotionParams{Float32}, SFMParams{Float32}, Goal{Float32}, Force{Float32})
    for (entities, pos_col, vel_col, geom_col, motion_col, sfm_col, goal_col, f_col) in Query(orig_world, (Position{Float32}, Velocity{Float32}, AgentGeometry{Float32}, MotionParams{Float32}, SFMParams{Float32}, Goal{Float32}, Force{Float32}))
        for i in 1:length(entities)
            pos = pos_col[i]
            vel = vel_col[i]
            geom = geom_col[i]
            motion = motion_col[i]
            sfm = sfm_col[i]
            goal = goal_col[i]
            f = f_col[i]
            new_entity!(w, (Position(pos.p), Velocity(vel.v), AgentGeometry(geom.social_radius, geom.collision_radius), MotionParams(motion.mass, motion.v_pref, motion.τ, motion.σ), SFMParams(sfm.A, sfm.B, sfm.λ, sfm.μ), Goal(goal.g), Force(f.f)))
        end
    end
    return w
end

function run_parity_check()
    println("--- Starting CPU vs GPU Parity Check ---")
    N = 5000
    steps = 10
    dt = 0.05f0
    
    grid_min = SVector(0.0f0, 0.0f0)
    grid_max = SVector(100.0f0, 100.0f0)
    cell_size = 2.0f0
    
    dims = ceil.(Int, (grid_max - grid_min) / cell_size)
    nav = build_navigation_field(grid_min, grid_max, cell_size, SVector(50.0f0, 50.0f0), zeros(Bool, dims[1], dims[2]))
    
    # 1. Initialize Deterministic World
    Random.seed!(42)
    base_world = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32}, MotionParams{Float32}, SFMParams{Float32}, Goal{Float32}, Force{Float32})
    for i in 1:N
        pos = SVector{2,Float32}(rand()*100.0f0, rand()*100.0f0)
        # Agents want to go to the center (50, 50)
        new_entity!(base_world, (
            Position(pos),
            Velocity(SVector(0.0f0, 0.0f0)),
            from_agent_params(0.3f0, 80.0f0, 1.4f0, 1.5f0)...,
            Goal(SVector(50.0f0, 50.0f0)),
            Force(SVector(0.0f0, 0.0f0))
        ))
    end
    
    # 2. Run CPU Simulation
    println("Running CPU simulation...")
    cpu_world = clone_world(base_world)
    cpu_sh = CPUNeighborSearch(N, grid_min, grid_max, cell_size)
    for _ in 1:steps
        update_navigation_system!(cpu_world, nav)
        update_social_forces_system!(cpu_world, cpu_sh, CPU())
        integrate_physics_system!(cpu_world, dt)
    end
    
    # 3. Run GPU Simulation
    if !CUDA.functional()
        println("CUDA is not functional. Cannot run GPU parity check.")
        return
    end
    
    println("Running GPU simulation...")
    gpu_world = clone_world(base_world)
    gpu_backend = CUDABackend()
    gpu_sh = RadixSpatialHash(gpu_backend, N, grid_min, grid_max, cell_size)
    
    for _ in 1:steps
        update_navigation_system!(gpu_world, nav)
        update_social_forces_system!(gpu_world, gpu_sh, gpu_backend)
        integrate_physics_system!(gpu_world, dt)
    end
    
    # 4. Compare Results
    println("Comparing results...")
    
    # Extract positions (in same order, since insertion order is preserved)
    # Wait, query order might not be strictly preserved if entities are added/removed.
    # Since we only modify components in-place and don't add/remove, the iteration order in StructArrays is identical.
    cpu_positions = SVector{2,Float32}[]
    for (entities, pos_col) in Query(cpu_world, (Position{Float32},))
        for i in 1:length(entities)
            pos = pos_col[i]
            push!(cpu_positions, SVector(pos.p[1], pos.p[2]))
        end
    end
    
    gpu_positions = SVector{2,Float32}[]
    for (entities, pos_col) in Query(gpu_world, (Position{Float32},))
        for i in 1:length(entities)
            pos = pos_col[i]
            push!(gpu_positions, SVector(pos.p[1], pos.p[2]))
        end
    end
    
    max_error = 0.0f0
    max_idx = 0
    for i in 1:N
        err = norm(cpu_positions[i] - gpu_positions[i])
        if err > max_error
            max_error = err
            max_idx = i
        end
    end
    
    println("Max positional error: $max_error at agent $max_idx")
    
    if max_error < 1e-4
        println("✅ SUCCESS: CPU and GPU results are identical within tolerance!")
    else
        println("❌ FAILURE: GPU results diverge from CPU results significantly.")
        println("CPU agent $max_idx: ", cpu_positions[max_idx])
        println("GPU agent $max_idx: ", gpu_positions[max_idx])
    end
end

run_parity_check()
