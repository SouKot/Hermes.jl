using Pkg
Pkg.activate(".")

using SimCrowd
using Ark
using BenchmarkTools
using StaticArrays
using KernelAbstractions
using CUDA

CUDA.allowscalar(false) # Ensure we don't accidentally fallback to scalar indexing

# Setup 50000 ORCA agents (10x more for GPU to hide latency)
world = World(Position{Float32}, Velocity{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32})
N = 50000

for i in 1:N
    pos = SVector(rand(Float32)*300.0f0, rand(Float32)*300.0f0)
    new_entity!(world, (
        Position(pos), Velocity(SVector(0.0f0,0.0f0)), 
        ORCAParams(2.0f0, 0.5f0, 10, 15.0f0, 0.2f0, 1.4f0, 0.5f0, 80.0f0), 
        Goal(SVector(150.0f0, 150.0f0)), Force(SVector(0.0f0,0.0f0))
    ))
end

sh = RadixSpatialHash(CUDABackend(), N, SVector(0.0f0, 0.0f0), SVector(300.0f0, 300.0f0), 4.0f0)

# Warmup
update_orca_system!(world, sh, CUDABackend(), 0.01f0)
CUDA.synchronize()

println("Benchmarking ORCA Step on GPU (50000 agents)...")
b = @benchmark begin
    update_orca_system!($world, $sh, CUDABackend(), 0.01f0)
    CUDA.synchronize()
end
display(b)
