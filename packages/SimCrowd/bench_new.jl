using Pkg
Pkg.activate(".")
Pkg.instantiate()

using SimCrowd
using StaticArrays
using KernelAbstractions
using CUDA
using Ark

# Benchmark script for new Ark ECS SoA code
function run_bench(N, steps)
    grid_min = SVector(0.0f0, 0.0f0)
    grid_max = SVector(100.0f0, 100.0f0)
    cell_size = 2.0f0
    
    backend = CPU()
    
    # We use CPUNeighborSearch for CPU execution
    sh = CPUNeighborSearch(N, grid_min, grid_max, cell_size)
    dims = ceil.(Int, (grid_max - grid_min) / cell_size)
    nav = build_navigation_field(grid_min, grid_max, cell_size, SVector(50.0f0, 50.0f0), zeros(Bool, dims[1], dims[2]))
    
    world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Goal{Float32}, Force{Float32})
    
    for i in 1:N
        pos = SVector{2,Float32}(rand()*100.0f0, rand()*100.0f0)
        new_entity!(world, (
            Position(pos),
            Velocity(SVector(0.0f0, 0.0f0)),
            AgentParams(0.3f0, 1.4f0, 0.5f0),
            Goal(SVector(50.0f0, 50.0f0)),
            Force(SVector(0.0f0, 0.0f0))
        ))
    end
    
    dt = 0.05f0
    
    # Warmup
    update_navigation_system!(world, nav)
    update_social_forces_system!(world, sh, backend)
    integrate_physics_system!(world, dt)
    
    start = time()
    for _ in 1:steps
        update_navigation_system!(world, nav)
        update_social_forces_system!(world, sh, backend)
        integrate_physics_system!(world, dt)
    end
    total = time() - start
    
    println("New Ark.jl SoA CPU (N=$N, steps=$steps): $total seconds. ($(total/steps*1000) ms/step)")
end

function run_bench_gpu(N, steps)
    grid_min = SVector(0.0f0, 0.0f0)
    grid_max = SVector(100.0f0, 100.0f0)
    cell_size = 2.0f0
    
    backend = CUDABackend()
    
    sh = RadixSpatialHash(backend, N, grid_min, grid_max, cell_size)
    dims = ceil.(Int, (grid_max - grid_min) / cell_size)
    nav = build_navigation_field(grid_min, grid_max, cell_size, SVector(50.0f0, 50.0f0), zeros(Bool, dims[1], dims[2]))
    
    world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Goal{Float32}, Force{Float32})
    
    for i in 1:N
        pos = SVector{2,Float32}(rand()*100.0f0, rand()*100.0f0)
        new_entity!(world, (
            Position(pos),
            Velocity(SVector(0.0f0, 0.0f0)),
            AgentParams(0.3f0, 1.4f0, 0.5f0),
            Goal(SVector(50.0f0, 50.0f0)),
            Force(SVector(0.0f0, 0.0f0))
        ))
    end
    
    dt = 0.05f0
    
    # Warmup
    update_navigation_system!(world, nav)
    update_social_forces_system!(world, sh, backend)
    integrate_physics_system!(world, dt)
    
    start = time()
    for _ in 1:steps
        update_navigation_system!(world, nav)
        update_social_forces_system!(world, sh, backend)
        integrate_physics_system!(world, dt)
    end
    total = time() - start
    
    println("New Ark.jl SoA GPU (N=$N, steps=$steps): $total seconds. ($(total/steps*1000) ms/step)")
end

# Run
run_bench(1000, 100)
run_bench(10000, 100)
run_bench(50000, 100)
run_bench(100000, 100)

if CUDA.functional()
    run_bench_gpu(1000, 100)
    run_bench_gpu(10000, 100)
    run_bench_gpu(50000, 100)
    run_bench_gpu(100000, 100)
end
