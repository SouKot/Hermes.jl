using Pkg
Pkg.activate(".")

using SimCrowd
using Ark
using BenchmarkTools
using StaticArrays
using KernelAbstractions

# Setup 5000 ORCA agents
world = World(Position{Float32}, Velocity{Float32}, ORCAParams{Float32}, Goal{Float32}, Force{Float32})
N = 5000

for i in 1:N
    pos = SVector(rand(Float32)*100.0f0, rand(Float32)*100.0f0)
    new_entity!(world, (
        Position(pos), Velocity(SVector(0.0f0,0.0f0)), 
        ORCAParams(2.0f0, 0.5f0, 10, 15.0f0, 0.2f0, 1.4f0, 0.5f0, 80.0f0), 
        Goal(SVector(50.0f0, 50.0f0)), Force(SVector(0.0f0,0.0f0))
    ))
end

sh = CPUNeighborSearch(N, SVector(0.0f0, 0.0f0), SVector(100.0f0, 100.0f0), 4.0f0)
update_orca_system!(world, sh, CPU(), 0.01f0)

println("Benchmarking ORCA Step (5000 agents)...")
b = @benchmark update_orca_system!($world, $sh, CPU(), 0.01f0)
display(b)
