"""
bench_social_forces.jl — §3.2 SIMD benchmark for CPU social force kernel.

Run with:
    julia --startup-file=no --project=.. -t auto bench/bench_social_forces.jl

Records wall-clock time for update_social_forces_system!(world, search, CPU())
at N = 100, 500, 2000, 4000 agents. Used to measure any gain from @simd or @turbo
on the inner j-loop in _update_social_forces_impl!.
"""

using BenchmarkTools
using Printf
using StaticArrays
using Dates
using KernelAbstractions: CPU
using Ark: World, new_entity!

# Activate the SimCrowd project
import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using SimCrowd

# ── Helpers ─────────────────────────────────────────────────────────────────

function make_world_and_search(N::Int; F=Float32)
    # Grid covers [0,0]...[sqrt(N)+2, sqrt(N)+2] to keep density realistic (1 agent/m²)
    side = ceil(F, sqrt(F(N))) + F(2)
    grid_min = SVector(F(0), F(0))
    grid_max = SVector(side, side)
    cell_size = F(1.5)

    world = World(
        Position{F}, Velocity{F}, AgentGeometry{F}, MotionParams{F},
        SFMParams{F}, Goal{F}, Force{F}, WallSegment{F}
    )
    ap = from_agent_params(F(0.25), F(80), F(1.3), F(0.5))

    rng_x = range(F(0.5), step=F(1.0), length=N)
    for i in 1:N
        px = rng_x[mod1(i, length(rng_x))]
        py = F(floor((i-1) / length(rng_x))) + F(0.5)
        new_entity!(world, (
            Position(SVector(px, py)),
            Velocity(SVector(F(0), F(0))),
            ap...,
            Goal(SVector(side - F(1), py)),
            Force(SVector(F(0), F(0)))
        ))
    end

    search = CPUNeighborSearch(N, grid_min, grid_max, cell_size)
    return world, search
end

# ── Benchmark ────────────────────────────────────────────────────────────────

println("="^60)
println("§3.2 Social Force Kernel — CPU Benchmark")
println("="^60)
println("Julia version: ", VERSION)
println("Threads: ", Threads.nthreads())
println()

Ns = [100, 500, 2000, 4000]

results = Dict{Int, BenchmarkTools.Trial}()

for N in Ns
    world, search = make_world_and_search(N)

    # Warmup
    update_social_forces_system!(world, search, CPU())

    t = @benchmark update_social_forces_system!($world, $search, CPU()) samples=10 evals=1
    results[N] = t

    med_ms = median(t).time / 1e6
    @printf "  N = %5d | median = %7.2f ms | min = %7.2f ms | allocs = %d\n" N med_ms minimum(t).time/1e6 t.allocs
end

println()
println("─"^60)
println("Throughput (agent-steps/second at median):")
for N in Ns
    med_s = median(results[N]).time / 1e9
    throughput = N / med_s
    @printf "  N = %5d | %.3e agent-steps/s\n" N throughput
end

println()
println("─"^60)
println("SIMD investigation notes:")
println("  - KA CPU() already generates auto-vectorised code via LLVM.")
println("  - Inner j-loop has branches (η>0, overlap>0) that may block @turbo.")
println("  - Try @simd on j-loop only if baseline shows scalar throughput.")
println("  - Accept change only if ≥10% improvement at N=2000 (typical sim size).")
println()
println("Result recorded: $(now())")
