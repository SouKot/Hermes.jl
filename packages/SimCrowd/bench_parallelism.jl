using Pkg
Pkg.activate(".")

using SimCrowd
using Ark
using BenchmarkTools
using StaticArrays
using LinearAlgebra
using KernelAbstractions
using Printf

println("="^60)
println("SimCrowd Parallelization Benchmark")
println("Julia version: ", VERSION)
println("Threads: ", Threads.nthreads())
println("="^60)

# ── Setup helpers ─────────────────────────────────────────────────────────

function make_sfm_world(N, scenario_width, scenario_height)
    world = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32}, MotionParams{Float32}, SFMParams{Float32},
                  ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
    for i in 1:N
        pos  = SVector(rand(Float32) * scenario_width, rand(Float32) * scenario_height)
        goal = SVector(rand(Float32) * scenario_width, rand(Float32) * scenario_height)
        new_entity!(world, (
            Position(pos),
            Velocity(SVector(0.0f0, 0.0f0)),
            from_agent_params(0.25f0, 80.0f0, 1.34f0, 0.5f0, 0.5f0)...,
            Goal(goal),
            Force(SVector(0.0f0, 0.0f0))
        ))
    end
    return world
end

function make_orca_world(N, scenario_width, scenario_height)
    world = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32}, MotionParams{Float32}, SFMParams{Float32},
                  ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})
    for i in 1:N
        pos  = SVector(rand(Float32) * scenario_width, rand(Float32) * scenario_height)
        goal = SVector(scenario_width - pos[1], scenario_height - pos[2])  # antipodal
        new_entity!(world, (
            Position(pos),
            Velocity(SVector(0.0f0, 0.0f0)),
            from_agent_params(0.25f0, 80.0f0, 1.34f0, 0.5f0, 0.5f0)...,
            ORCAParams(2.0f0, 0.5f0, 10, 15.0f0, 0.2f0, 1.34f0, 0.5f0, 80.0f0),
            Goal(goal),
            Force(SVector(0.0f0, 0.0f0))
        ))
    end
    return world
end

function sfm_step!(world, sh)
    for (entities, pos_col, vel_col, motion_col, goal_col, force_col) in
            Query(world, (Position{Float32}, Velocity{Float32}, MotionParams{Float32}, Goal{Float32}, Force{Float32}))
        for i in eachindex(pos_col)
            F_drive = goal_seeking_force(pos_col[i].p, vel_col[i].v, goal_col[i].g,
                                         motion_col[i].v_pref, motion_col[i].τ, motion_col[i].mass)
            force_col[i] = Force(F_drive)
        end
    end
    update_social_forces_system!(world, sh, CPU())
    integrate_physics_system!(world, 0.05f0)
end

function orca_step!(world, sh, dt=0.05f0)
    for (entities, pos_col, vel_col, force_col) in
            Query(world, (Position{Float32}, Velocity{Float32}, Force{Float32}))
        for i in eachindex(pos_col)
            force_col[i] = Force(SVector(0.0f0, 0.0f0))
        end
    end
    SimCrowd.update_orca_system_cpu!(world, dt)
    integrate_physics_system!(world, dt)
end

AGENT_COUNTS = [500, 1000, 5000, 10000]
SCENARIO_W   = 100.0f0
SCENARIO_H   = 100.0f0

println("\n" * "─"^60)
println("SECTION 1: SFM — CPU (single-thread baseline vs multi-thread)")
println("─"^60)
println("Note: Julia must be started with -t 1 or -t auto to compare.")
println("Current thread count: ", Threads.nthreads())
println()

sfm_results = Dict{Int, Float64}()
for N in AGENT_COUNTS
    world = make_sfm_world(N, SCENARIO_W, SCENARIO_H)
    sh = CPUNeighborSearch(N, SVector(0.0f0, 0.0f0), SVector(SCENARIO_W, SCENARIO_H), 4.0f0)
    # Warmup
    sfm_step!(world, sh)
    b = @belapsed sfm_step!($world, $sh)
    sfm_results[N] = b * 1000  # ms
    @printf("  N=%6d: %7.2f ms/step  (%6.1f FPS equiv)\n", N, b*1000, 1.0/b)
end

println("\n" * "─"^60)
println("SECTION 2: ORCA CPU — O(N²) all-pairs solver")
println("─"^60)
orca_results = Dict{Int, Float64}()
for N in [100, 250, 500, 1000]   # ORCA CPU is O(N²), keep N smaller
    world = make_orca_world(N, SCENARIO_W, SCENARIO_H)
    sh = CPUNeighborSearch(N, SVector(0.0f0, 0.0f0), SVector(SCENARIO_W, SCENARIO_H), 4.0f0)
    # Warmup
    orca_step!(world, sh)
    b = @belapsed orca_step!($world, $sh)
    orca_results[N] = b * 1000
    @printf("  N=%6d: %7.2f ms/step  (%6.1f FPS equiv)\n", N, b*1000, 1.0/b)
end

println("\n" * "─"^60)
println("SECTION 3: Parallelization model analysis")
println("─"^60)

println("""
SFM Parallelization:
  - Neighbor search (CellListMap): parallel O(N) with spatial hashing
  - Social force compute: parallel O(N*K) where K = avg neighbors per cell
  - Physics integrator (physics.jl): Threads.@threads over agents — O(N/threads)
  - Wall repulsion: sequential O(N * W) where W = number of wall segments

  CONCERN: Threads.@threads on force_col writes may cause RACE CONDITIONS
  if multiple threads write to force_col[i] for the same i. 
  CellListMap handles this correctly (Newton 3rd law pairs), but the
  goal_seeking_force loop in the TEST file is sequential — no race.

ORCA CPU Parallelization:
  - Data collection: sequential O(N)
  - LP solve loop: Threads.@threads for i in 1:N — reads shared positions[]
    but writes to new_velocities[i] — this is SAFE (no write conflicts)
  - Force write-back: sequential O(N)

  CONCERN: orca_cpu.jl allocates Vector{Tuple{F, Int}}[] per thread per step.
  At N=1000 and 250 neighbors, this is 1000 * 250 * ~16 bytes = 4MB of
  allocations per step, causing GC pressure at high frequencies.
""")

println("\n" * "─"^60)
println("SECTION 4: GPU model analysis")
println("─"^60)
println("""
GPU Kernel Architecture (orca.jl + social.jl):
  - RadixSpatialHash: sorts agents by Morton code → cache-coherent cell access
  - KernelAbstractions @kernel: maps one thread per agent (SIMT)
  - K=25 neighbors per GPU thread (MVector{25} in registers)
  - Insertion sort inside kernel: O(K log K) per thread — in-register, fast
  
  CONCERN 1: Allocations per ORCA step in _update_orca_impl! (orca.jl:265-278):
    - dev_v_prefs, dev_taus, dev_masses allocated EVERY step → GPU malloc stalls
    - These should be pre-allocated in ORCAGPUContext and reused

  CONCERN 2: 8 kernel launches per ORCA step (check_rebuild, 6x reorder, orca main)
    - Each KernelAbstractions.synchronize() is a GPU barrier
    - At 5000 agents, synchronization overhead may dominate over compute

  CONCERN 3: Social forces and ORCA are in separate GPU contexts
    - social.jl uses SocialForcesGPUContext, orca.jl uses ORCAGPUContext
    - Both independently copy positions to device → 2x PCIe transfers per step
    - Could be unified into one GPU buffer for positions/velocities
""")

println("="^60)
println("Benchmark complete.")
