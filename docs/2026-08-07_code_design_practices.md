# SimPlatform — Code Design & Development Practices
**Date**: 2026-08-07  
**Status**: Living document — update as decisions evolve  
**Scope**: Engineering standards for all `packages/Sim*/` Julia packages

---

## How to Use This Document

This document defines **how we write code**, not what the code does (that is in the design document). Every contributor — including future-you — should be able to read this and understand:
- Why a code looks the way it does
- What tools to run before committing
- How to add tests, documentation, and benchmarks correctly

---

## Table of Contents

1. [Software Name & Identity](#1-software-name--identity)
2. [Architecture Principles](#2-architecture-principles)
3. [Type System & Type Stability](#3-type-system--type-stability)
4. [Unicode Variables — Policy](#4-unicode-variables--policy)
5. [Static Analysis with JET.jl](#5-static-analysis-with-jetjl)
6. [Parallelization Strategy](#6-parallelization-strategy)
7. [Documentation Standards](#7-documentation-standards)
8. [Testing Strategy & Infrastructure](#8-testing-strategy--infrastructure)
9. [Performance Engineering](#9-performance-engineering)
10. [Code Style Guide](#10-code-style-guide)
11. [Versioning & Release Management](#11-versioning--release-management)
12. [License & Dependency Policy](#12-license--dependency-policy)
13. [Toolchain Reference Card](#13-toolchain-reference-card)

---

## 1. Software Name & Identity

### Name: **Hermes.jl**

> *Hermes is the Greek god of speed, commerce, and boundaries between worlds. Julia's defining virtue is speed. Our platform serves commerce (logistics, supply chain, manufacturing). And we bridge the boundary between discrete event time and continuous physical space.*

**Full name**: Hermes Simulation Platform  
**Package prefix**: `Sim` (SimCore, SimDES, SimCrowd, SimViz, SimFluid)  
**GitHub**: `github.com/[your-handle]/Hermes.jl` (private)  
**Top-level module**: `Hermes`

**Alternative names considered** (for reference):
- `Janus.jl` — Roman god of time and transitions (J for Julia). Also considered.
- `Minerva.jl` — Roman goddess of wisdom and craft. More academic feel.
- `Helios.jl` — Hidden tribute to Helbing (Social Force Model paper author) + speed/light.

---

## 2. Architecture Principles

### 2.1 The Three Immutable Rules

**Rule 1 — No global mutable state.**  
Every simulation state lives inside a `World` struct. No module-level globals that change during simulation. This makes tests deterministic and parallel execution safe.

```julia
# ❌ WRONG
const current_time = Ref(0.0)  # mutable global

# ✅ CORRECT
mutable struct SimWorld
    time     :: Float64
    entities :: EntityStore
    events   :: PriorityQueue{SimEvent, Float64}
end
```

**Rule 2 — Performance-critical code must be type-stable.**  
The DES inner loop, the Social Force Model kernel, and the spatial hash grid must be type-stable. Use `@code_warntype` and JET.jl to verify. No exceptions.

**Rule 3 — Separate concerns across packages.**  
`SimCore` knows nothing about visualization. `SimViz` knows nothing about DES logic. This allows users to install only what they need and allows future replacement of any layer.

### 2.2 Data Flow Direction

```
User defines layout (JSON/Godot scene)
    ↓
SimCore: instantiate World, entities, components
    ↓
SimDES: event loop drives time — schedules Physics steps
    ↓
SimCrowd / SimFluid: physics kernels update agent state
    ↓
SimViz: reads World state → renders to GLMakie / Godot socket
```

Dependencies flow **downward only**. `SimDES` may depend on `SimCore`. `SimCore` never depends on `SimDES`. No circular dependencies — ever.

### 2.3 Entity-Component-System (ECS) Conventions

Following Ark.jl's ECS design:
- **Entity**: a `UInt64` ID — nothing more
- **Component**: a plain struct containing data (no methods)
- **System**: a function that queries entities with specific components and updates them

```julia
# Component — pure data, no behavior
struct CrowdAgent
    position     :: SVector{2, Float32}
    velocity     :: SVector{2, Float32}
    desired_speed:: Float32
    panic_level  :: Float32
end

# System — pure function, operates on components
function social_force_system!(world::SimWorld, dt::Float32)
    for id in entities_with(world, CrowdAgent)
        agent = get_component(world, id, CrowdAgent)
        force = compute_social_force(world, id, agent)
        # update component
        set_component!(world, id, CrowdAgent(
            agent.position + agent.velocity * dt,
            agent.velocity + force * dt,
            agent.desired_speed,
            agent.panic_level
        ))
    end
end
```

---

## 3. Type System & Type Stability

### 3.1 Why Type Stability Matters

Julia compiles specialized methods for each combination of argument types. If a function's return type cannot be inferred at compile time, Julia inserts runtime type checks — this can make code 10–100× slower than necessary.

**Type stability means**: the output type of a function depends only on the *types* of its inputs, not their *values*.

```julia
# ❌ Type UNSTABLE — return type depends on value
function get_speed(agent, panic::Bool)
    panic ? 4.0f0 : 1.4f0   # OK: same type, Float32
end

# ❌ Type UNSTABLE — returns Any
function get_event_time(e)
    if e isa ArrivalEvent
        return e.time          # Float64
    else
        return nothing         # Nothing — two possible return types!
    end
end

# ✅ STABLE — return Union{Float64, Nothing} is fine if declared
function get_event_time(e::SimEvent)::Union{Float64, Nothing}
    e isa ArrivalEvent ? e.time : nothing
end

# ✅ EVEN BETTER — use dispatch
get_event_time(e::ArrivalEvent)    = e.time
get_event_time(e::SimEvent)        = nothing
```

### 3.2 Struct Field Type Rules

```julia
# ❌ WRONG — abstract field type causes heap allocation for every access
struct SimWorld
    agents :: AbstractVector   # Julia can't infer element type
    time   :: Real             # Real is abstract
end

# ✅ CORRECT — concrete types
struct SimWorld{A <: AbstractVector{CrowdAgent}}
    agents :: A                # parametric — concrete at instantiation
    time   :: Float64
end

# ✅ ALSO CORRECT — concrete directly
mutable struct SimWorld
    agents :: Vector{CrowdAgent}   # Vector{CrowdAgent} is concrete
    time   :: Float64
end
```

**Rule**: Every struct field must have a concrete type. Use parametric types when needed for flexibility.

### 3.3 Checking Type Stability — Standard Process

```julia
using JET, InteractiveUtils

# Method 1: @code_warntype (in REPL)
@code_warntype social_force_system!(world, 0.05f0)
# Look for red/yellow "Any" or "Union{...}" return types

# Method 2: @inferred (in tests — fails if type unstable)
@testset "Type stability" begin
    @inferred social_force_system!(world, 0.05f0)
    @inferred dispatch!(world, ArrivalEvent(1, 0, 0.0), 0.0)
end

# Method 3: JET.jl (in CI)
using JET
@report_opt social_force_system!(world, 0.05f0)
```

### 3.4 Parametric Types for Generic APIs

```julia
# Generic DES event — parametric on time type for flexibility
struct ScheduledEvent{T <: Real, P <: SimEvent}
    time    :: T
    payload :: P
    id      :: UInt64
end

# Generic zone state — parametric on entity type
struct ZoneState{E}
    entities  :: Vector{E}
    local_fel :: PriorityQueue{SimEvent, Float64}
    clock     :: Float64
end
```

---

## 4. Unicode Variables — Policy

### 4.1 Decision: **Selective Use**

Julia permits Unicode identifiers. The policy is:
- ✅ **Use unicode** in internal mathematical code (simulation kernels, formulas)
- ❌ **Avoid unicode** in public API function names and keyword arguments
- ✅ **Use unicode** in documentation/docstrings as supplementary notation
- ❌ **Never use** unicode that is not easily typeable in VS Code with Julia extension

### 4.2 Approved Unicode Identifiers

| Symbol | Name | Allowed in | Meaning in our codebase |
|---|---|---|---|
| `λ` | lambda | Internal math | Arrival rate (DES) |
| `μ` | mu | Internal math | Service rate (DES) |
| `ρ` | rho | Internal math | Utilization ρ = λ/μ |
| `τ` | tau | Internal math | Relaxation time (Social Force) |
| `Δt` | Delta-t | Internal math | Simulation timestep |
| `∇` | nabla | Internal math | Gradient operator |
| `α`, `β` | alpha, beta | Internal math | Decay/scale parameters |
| `ε` | epsilon | Internal math | Small tolerance value |
| `σ` | sigma | Internal math | Standard deviation |
| `∞` | infinity | Internal math | `const ∞ = Inf` |

### 4.3 How to Type Unicode in VS Code

With the Julia extension: type `\lambda` then press Tab → `λ`.  
Full list: https://docs.julialang.org/en/v1/manual/unicode-input/

### 4.4 Examples

```julia
# ✅ GOOD — unicode in formula implementations
function mm1_mean_queue_length(λ::Float64, μ::Float64)
    ρ = λ / μ
    @assert 0 < ρ < 1 "System must be stable: ρ=$ρ"
    return ρ / (1 - ρ)      # Little's Law: L = ρ/(1-ρ)
end

# ✅ GOOD — unicode in Social Force kernel
function goal_seeking_force(v::SVector{2,F}, v₀::F, τ::F, ê::SVector{2,F}) where F
    return (v₀ * ê - v) / τ   # f_goal = (v₀·ê - v) / τ
end

# ❌ BAD — unicode in public API
function simulate!(world; λ=1.0, μ=2.0)  # keyword args should be ASCII
# ✅ CORRECT public API
function simulate!(world; arrival_rate=1.0, service_rate=2.0) end
```

---

## 5. Static Analysis with JET.jl

### 5.1 What JET.jl Does

JET.jl performs **abstract interpretation** of Julia code — it runs your code at the type level without executing it, detecting:
- Type inference failures (return type is `Any`)
- Undefined method calls
- Unused variables
- Potential runtime errors

This is the closest Julia gets to a static type checker. It is **not optional** for performance-critical code.

### 5.2 Two JET Modes

**Mode 1: `@report_opt` — Optimization Analysis**  
Reports anything that prevents Julia from generating optimal machine code:
```julia
using JET

# Check the DES event loop
@report_opt sim_loop!(world, fel, clock, 100.0)

# Check the Social Force kernel
@report_opt social_force_system!(world, 0.05f0)
```
Any red output here is a performance bug. Fix it before merging.

**Mode 2: `@report_call` — Call Analysis**  
Reports potential runtime errors (calling methods that don't exist, etc.):
```julia
@report_call dispatch!(world, ArrivalEvent(1, 0, 0.0), 0.0)
```

### 5.3 JET in CI (GitHub Actions)

Add to each package's `test/runtests.jl`:
```julia
using JET

@testset "JET static analysis" begin
    # Report any optimization issues in core functions
    rep = report_package("SimDES")
    @test length(JET.get_reports(rep)) == 0
end
```

And in `.github/workflows/CI.yml`:
```yaml
- name: Run JET analysis
  run: julia --project=. -e 'using JET; report_package("SimDES")'
```

### 5.4 When NOT to Use JET

JET is not useful for:
- Visualization code (GLMakie is complex, JET produces many false positives)
- DrWatson experiment scripts (dynamic by nature)
- One-off analysis scripts

Apply JET to: **SimCore**, **SimDES**, **SimCrowd** hot paths only.

---

## 6. Parallelization Strategy

This is the most important architectural decision. Our platform has **three levels** of parallelism, each using different Julia mechanisms.

### 6.1 Level 1 — GPU Parallelism (Crowd & Fluid Physics)

**What**: Social Force Model, SPH/LBM fluid kernels — thousands to millions of agents updated simultaneously.  
**Tool**: `KernelAbstractions.jl` — write one kernel, run on NVIDIA CUDA, AMD ROCm, or multi-threaded CPU.  
**Why KernelAbstractions over CUDA.jl directly**: Hardware-agnostic — same kernel code works on any GPU backend.

```julia
using KernelAbstractions

@kernel function social_force_kernel!(
    positions, velocities, forces,
    desired_speeds, @Const goals, @Const obstacles
)
    i = @index(Global, Linear)   # GPU thread index

    pos_i = positions[i]
    vel_i = velocities[i]
    v0_i  = desired_speeds[i]

    # Goal-seeking force
    ê_goal  = normalize(goals[i] - pos_i)
    f_goal  = (v0_i * ê_goal - vel_i) / τ

    # Repulsion from other agents (read-only neighbor scan)
    f_agents = zero(eltype(forces))
    for j in 1:length(positions)
        i == j && continue
        r_ij = pos_i - positions[j]
        d    = norm(r_ij)
        d > 3.0f0 && continue   # cutoff radius
        f_agents += A * exp((r_i + r_j - d) / B) * normalize(r_ij)
    end

    forces[i] = f_goal + f_agents
    # Note: spatial hash grid replaces the O(N²) loop above in production
end

# Backend-agnostic launch
backend = get_backend(positions)   # returns CUDABackend, ROCMBackend, or CPU
kernel  = social_force_kernel!(backend, 256)   # 256 threads per block
kernel(positions, velocities, forces, desired_speeds, goals, obstacles,
       ndrange=length(positions))
```

**Rules for GPU kernels**:
- No dynamic dispatch inside kernels (no abstract types)
- No heap allocation (use `StaticArrays.SVector` for small vectors)
- No recursion
- Minimize global memory reads — use shared memory for neighbor data
- Always benchmark with `CUDA.@profile` or equivalent

### 6.2 Level 2 — Multi-threading (DES Logical Processes)

**What**: Conservative Parallel DES — each zone LP runs as a Julia Task on its own thread.  
**Tool**: Julia's native `@spawn` (creates a Task that runs on any available thread).  
**Rule**: No shared mutable state between LPs — only message passing via `Channel`.

```julia
# Each LP is a @spawn Task — Julia schedules it on available threads
function launch_parallel_des!(zones::Vector{ZoneConfig}, t_end::Float64)
    channels = build_channel_graph(zones)

    # Spawn one Task per zone
    tasks = map(zones) do z
        Threads.@spawn run_zone!(
            z.id, z.lookahead,
            channels[z.id].inbox,
            channels[z.id].outboxes,
            z.state,
            t_end
        )
    end

    # Wait for all zones
    foreach(wait, tasks)
end
```

**Threading rules**:
- NEVER share mutable structs between Tasks without locks or atomics
- Use `Channel{T}` for inter-task communication (it handles synchronization)
- Use `Atomic{T}` (from `Base.Threads`) for shared counters (e.g., event count)
- Use `ReentrantLock` only as last resort — prefer channels

```julia
# ✅ Safe inter-task communication
inbox = Channel{ZoneMessage}(1024)   # buffered channel

# ✅ Safe shared counter
event_count = Threads.Atomic{Int}(0)
Threads.atomic_add!(event_count, 1)

# ❌ UNSAFE — shared mutable without synchronization
shared_queue = PriorityQueue{SimEvent, Float64}()   # race condition!
```

**How to run multi-threaded Julia**:
```bash
julia --threads auto              # use all available cores
julia --threads 8                 # use 8 threads
JULIA_NUM_THREADS=8 julia         # environment variable
```

### 6.3 Level 3 — Distributed / MPI (Tier 3, Future)

**What**: Multi-facility supply chain simulation across multiple machines.  
**Tool**: `MPI.jl` for inter-process communication.  
**Status**: Deferred to Tier 3. Design the LP message-passing API so that `Channel` can later be replaced with MPI messages transparently.

**Abstraction layer** (design for future extensibility):
```julia
# Abstract message transport — allows swapping Channel for MPI later
abstract type MessageTransport end

struct ChannelTransport <: MessageTransport
    channel :: Channel{ZoneMessage}
end

struct MPITransport <: MessageTransport
    rank :: Int
    tag  :: Int
end

# LP runner uses the abstract interface
function send_message!(transport::ChannelTransport, msg::ZoneMessage)
    put!(transport.channel, msg)
end

function send_message!(transport::MPITransport, msg::ZoneMessage)
    MPI.send(msg, transport.rank, transport.tag, MPI.COMM_WORLD)
end
```

### 6.4 Thread Safety Checklist

Before any code touches multiple threads, verify:
- [ ] No shared mutable struct fields modified from two tasks
- [ ] All inter-task data flow via `Channel` or `Atomic`
- [ ] GPU kernels have no Julia heap allocation
- [ ] `@spawn` tasks are `wait()`ed for — no fire-and-forget without error handling
- [ ] Random number generators are task-local (`Random.default_rng()` is thread-local in Julia 1.7+)

---

## 7. Documentation Standards

### 7.1 Documenter.jl Setup

Every package has a `docs/` folder structured for Documenter.jl:

```
packages/SimDES/
├── docs/
│   ├── Project.toml     (Documenter.jl as dep)
│   ├── make.jl          (build script)
│   └── src/
│       ├── index.md
│       ├── api.md
│       └── tutorials/
│           └── mm1_queue.md
```

Build docs:
```bash
julia --project=docs docs/make.jl
```

Host options: GitHub Pages (private repo → restricted, but GitHub Pages can be private), or self-hosted.

### 7.2 Docstring Standard

**Every exported function, type, and constant must have a docstring.**

Format: `DocStringExtensions.jl` macros + standard Julia docstring convention:

```julia
using DocStringExtensions

"""
    sim_loop!(world, fel, clock, t_end) -> SimStats

Run the DES simulation loop until simulated time `t_end`.

# Arguments
- `world::SimWorld`: The ECS world containing all entity state.
- `fel::PriorityQueue{SimEvent, Float64}`: The Future Event List.
- `clock::SimClock`: Controls simulation speed (real-time, fast, paused).
- `t_end::Float64`: Stop when simulated time exceeds this value.

# Returns
A `SimStats` struct with final statistics (throughput, utilization, etc.).

# Performance
Type-stable. Zero allocation in the hot path (verified with `@allocated`).
At `speed_factor=Inf`, processes ~10M events/second on a single core.

# Example
```julia
world = SimWorld()
fel   = PriorityQueue{SimEvent, Float64}()
clock = SimClock(Inf)  # fastest mode

schedule!(fel, ArrivalEvent(entity_id=1, zone_id=1, time=0.0))
stats = sim_loop!(world, fel, clock, 3600.0)
println("Throughput: ", stats.throughput, " entities/hour")
```

# See Also
[`schedule!`](@ref), [`SimClock`](@ref), [`dispatch!`](@ref)
"""
function sim_loop!(world::SimWorld, fel::PriorityQueue, clock::SimClock, t_end::Float64)
    # ...
end
```

### 7.3 Docstring Requirements by Symbol Type

| Symbol type | Required sections |
|---|---|
| Exported function | Summary line, `# Arguments`, `# Returns`, `# Example` |
| Exported type/struct | Summary + field descriptions via `$(TYPEDFIELDS)` |
| Exported constant | One-line description + units/type |
| Internal function | Summary line only (no full docstring required) |
| Module | Module-level docstring explaining purpose and what it exports |

```julia
"""
$(TYPEDEF)

Represents a single simulated zone (Logical Process) in the Conservative PDES architecture.

$(TYPEDFIELDS)
"""
mutable struct ZoneState
    "Zone identifier (must be unique across the simulation)"
    id          :: Int
    "Simulated clock for this LP"
    local_time  :: Float64
    "Future Event List — events pending in this zone"
    local_fel   :: PriorityQueue{SimEvent, Float64}
    "Guaranteed minimum delay before a message reaches downstream zones"
    lookahead   :: Float64
end
```

---

## 8. Testing Strategy & Infrastructure

### 8.1 Three-Layer Test Architecture

```
Layer 1: Unit Tests (per package, fast, deterministic)
    packages/SimDES/test/runtests.jl
    packages/SimCrowd/test/runtests.jl
    Run: julia --project=packages/SimDES -e "using Pkg; Pkg.test()"

Layer 2: Validation Tests (DrWatson experiments, compare against ground truth)
    experiments/scripts/des/DES_S_01.jl  (M/M/1 vs analytical)
    experiments/scripts/crowd/CRW_M_01.jl (lane formation)
    Run: julia --project=experiments experiments/scripts/des/DES_S_01.jl

Layer 3: Benchmark Tests (performance regression, BenchmarkTools)
    experiments/scripts/benchmarks/PAR_03_speedup.jl
    Run: julia --project=experiments experiments/scripts/benchmarks/PAR_03_speedup.jl
```

### 8.2 Unit Test Structure

Each package's `test/runtests.jl`:
```julia
using Test, Aqua, JET
using SimDES

@testset "SimDES" begin

    @testset "Aqua quality checks" begin
        Aqua.test_all(SimDES)
    end

    @testset "JET static analysis" begin
        # Only check exported functions
        @test isempty(JET.get_reports(report_package("SimDES")))
    end

    @testset "Type stability" begin
        world = SimWorld()
        fel   = PriorityQueue{SimEvent, Float64}()
        clock = SimClock(Inf)
        @inferred sim_loop!(world, fel, clock, 1.0)
        @inferred dispatch!(world, ArrivalEvent(1, 1, 0.0), 0.0)
    end

    @testset "Event cancellation" begin
        # DES-S-08 test case
        include("test_event_cancellation.jl")
    end

    @testset "M/M/1 queue" begin
        # DES-S-01 test case (quick version, 10k events for unit test)
        include("test_mm1_queue.jl")
    end

end
```

### 8.3 Tools for Testing

| Tool | What it catches | When to use |
|---|---|---|
| `Test.@test` | Logic correctness | All tests |
| `Test.@test_throws` | Expected exceptions | Error handling |
| `Test.@inferred` | Type stability | All hot-path functions |
| `Aqua.jl` | Piracy, ambiguities, unbound type params | Per package, in CI |
| `JET.jl` | Type instabilities, undefined calls | SimCore, SimDES, SimCrowd |
| `BenchmarkTools.@btime` | Timing, allocations | Performance regressions |
| `@allocated` | Zero-allocation verification | DES inner loop, GPU kernels |

### 8.4 Zero-Allocation Tests (Critical for Hot Paths)

```julia
@testset "Zero allocation in hot path" begin
    world = setup_test_world()
    event = ArrivalEvent(1, 1, 0.0)

    # Warm up (Julia compilation)
    dispatch!(world, event, 0.0)

    # Verify zero allocations
    allocs = @allocated dispatch!(world, event, 0.0)
    @test allocs == 0   # if > 0, we have a performance bug
end
```

### 8.5 Deterministic Tests (Seeded RNG)

All stochastic tests must use a fixed seed for reproducibility:

```julia
using Random

@testset "M/M/1 convergence (seeded)" begin
    Random.seed!(42)   # fixed seed — same result every run
    result = run_mm1_simulation(λ=1.0, μ=2.0, n_arrivals=100_000)
    @test isapprox(result.L, 1.0, rtol=0.02)
end
```

### 8.6 TestItemRunner.jl (VSCode Integration)

Install `TestItemRunner.jl` for running individual test items from the VSCode Julia extension:

```julia
using TestItemRunner

@testitem "M/M/1 queue correctness" begin
    # Self-contained test — can run standalone in VSCode
    using SimDES, Test
    result = run_mm1_simulation(λ=1.0, μ=2.0, n_arrivals=50_000)
    @test isapprox(result.L, 1.0, rtol=0.05)
end
```

This shows a green/red indicator next to each `@testitem` in the editor — essential for fast iteration.

---

## 9. Performance Engineering

### 9.1 The Performance Hierarchy

```
1. Algorithm  → Choose O(N log N) over O(N²) — no amount of optimization fixes a bad algorithm
2. Type stability → Ensure Julia generates optimal machine code
3. Memory layout → Prefer SoA over AoS for GPU; minimize heap allocations
4. Parallelism → GPU then multi-thread then distributed
5. Low-level → @inbounds, @simd, SIMD.jl — only after profiling shows it matters
```

**Never optimize prematurely. Profile first.**

### 9.2 Profiling Tools

```julia
# Method 1: Julia built-in profiler
using Profile, ProfileView   # or PProf.jl for flamegraphs

Profile.clear()
@profile sim_loop!(world, fel, clock, 60.0)
ProfileView.view()   # flamegraph — shows where time is spent

# Method 2: BenchmarkTools for micro-benchmarks
using BenchmarkTools

# Compare two implementations
b1 = @benchmark dispatch!($world, $event, $t)
b2 = @benchmark dispatch_v2!($world, $event, $t)
judge(minimum(b1), minimum(b2))   # prints comparison

# Method 3: CUDA profiling (for GPU kernels)
CUDA.@profile sim_loop_gpu!(world, 60.0f0)
```

### 9.3 Memory Allocation Rules

```julia
# ALWAYS check allocations in hot-path functions after writing them
@allocated dispatch!(world, ArrivalEvent(1, 1, 0.0), 0.0)
# → should be 0

# Pre-allocate buffers — never allocate inside simulation loop
struct SimWorld
    # Pre-allocated work buffers — reused every step
    force_buffer  :: Vector{SVector{2, Float32}}
    neighbor_list :: Vector{Int}
    # ...
end

# ❌ Wrong — allocates on every call
function compute_forces(world)
    forces = zeros(SVector{2, Float32}, length(world.agents))  # allocation!
    # ...
end

# ✅ Correct — writes to pre-allocated buffer
function compute_forces!(forces::Vector, world)
    fill!(forces, zero(SVector{2, Float32}))  # no allocation
    # ...
end
```

### 9.4 StaticArrays Rules

Use `StaticArrays.SVector` for all fixed-size small vectors (agent positions, velocities, forces):

```julia
using StaticArrays

# ✅ 2D position — stack allocated, no heap
pos = SVector{2, Float32}(1.0f0, 2.0f0)

# ✅ Force computation — all on stack
f = pos + SVector{2, Float32}(0.1f0, -0.2f0)   # no heap allocation

# ❌ Wrong for small vectors — heap allocated
pos = [1.0f0, 2.0f0]   # Vector is heap allocated
```

SVector is **stack-allocated** for n ≤ 12 elements and eliminates GC pressure entirely.

### 9.5 @inbounds Usage Policy

`@inbounds` disables bounds checking in array indexing — removes safety but improves speed. Rules:

```julia
# ✅ OK — use @inbounds only in inner loops, only after verifying correctness
function social_force_system!(world, dt)
    positions = world.positions
    n = length(positions)
    @inbounds for i in 1:n
        # Safe: we know i ∈ 1:n
        pos_i = positions[i]
        # ...
    end
end

# ❌ NEVER use @inbounds before correctness is proven
# ❌ NEVER use @inbounds on externally-provided indices
```

---

## 10. Code Style Guide

### 10.1 Naming Conventions

| Symbol | Convention | Example |
|---|---|---|
| Types/structs | `UpperCamelCase` | `SimWorld`, `ArrivalEvent`, `ZoneState` |
| Functions | `lower_snake_case` | `dispatch!`, `sim_loop!`, `run_zone!` |
| Mutating functions | `lower_snake_case!` | `update_agents!`, `step_physics!` |
| Constants | `UPPER_SNAKE_CASE` | `MAX_AGENTS`, `DEFAULT_LOOKAHEAD` |
| Modules | `UpperCamelCase` | `SimDES`, `SimCore` |
| Type parameters | Single uppercase | `T`, `F`, `A` |
| Internal/private | prefix `_` | `_compute_force`, `_validate_world` |

### 10.2 Function Size and Focus

```julia
# ❌ WRONG — one function doing too much
function run_simulation!(world, config)
    # setup
    for entity in config.entities
        add_component!(world, entity.id, ...)
    end
    # simulation
    while !isempty(world.fel) && world.time < config.t_end
        event, t = dequeue_pair!(world.fel)
        # handle every event type...
        if event isa ArrivalEvent
            # 20 lines
        elseif event isa ServiceComplete
            # 15 lines
        # ...
        end
    end
    # stats collection
    # ...
end

# ✅ CORRECT — small, focused functions
function setup_world!(world, config)     ... end
function sim_loop!(world, config)        ... end
function collect_stats(world) :: SimStats ... end

# Julia dispatch replaces if/elseif for events
dispatch!(world, e::ArrivalEvent, t)    = handle_arrival!(world, e, t)
dispatch!(world, e::ServiceComplete, t) = handle_service_complete!(world, e, t)
```

### 10.3 Error Handling

```julia
# Use @assert for internal invariants (disabled in optimized builds)
function enqueue_event!(fel, event::SimEvent)
    @assert event.time >= 0.0 "Event time must be non-negative: $(event.time)"
    enqueue!(fel, event => event.time)
end

# Use explicit error for user-facing validation
function set_speed!(clock::SimClock, factor::Float64)
    factor >= 0.0 || throw(ArgumentError(
        "Speed factor must be non-negative, got $factor"
    ))
    clock.speed_factor = factor
end

# Use @warn for recoverable issues
function schedule!(fel, event::SimEvent)
    if length(fel) > 1_000_000
        @warn "FEL has $(length(fel)) events — consider upgrading to calendar queue" maxlog=1
    end
    enqueue!(fel, event => event.time)
end
```

### 10.4 Code Formatting

Use `JuliaFormatter.jl` with this config at root `.JuliaFormatter.toml`:

```toml
style = "blue"                    # Blue style — community standard
indent = 4
margin = 92                       # line length limit
always_use_return = false
whitespace_typedefs = true
whitespace_ops_in_indices = true
remove_extra_newlines = true
pipe_to_function_call = false
long_to_short_function_def = true
always_for_in = true
```

Run before every commit:
```julia
using JuliaFormatter
format("packages/SimDES/src/")
```

Or set up a pre-commit hook.

---

## 11. Versioning & Release Management

### 11.1 Semantic Versioning (SemVer)

Format: `MAJOR.MINOR.PATCH` (e.g., `0.1.0`, `1.2.3`)

| Version bump | When |
|---|---|
| `PATCH` (0.1.x) | Bug fixes, no API change |
| `MINOR` (0.x.0) | New features, backward-compatible API additions |
| `MAJOR` (x.0.0) | Breaking API changes — existing code may need updates |

During initial development (version `0.x.y`): any MINOR bump may break API. Stabilize at `1.0.0` when the API is mature.

### 11.2 CHANGELOG.md

Every package must maintain a `CHANGELOG.md`:

```markdown
# Changelog

All notable changes to SimDES are documented here.

## [Unreleased]
### Added
- Conservative PDES Tier 2 support (multi-LP Julia Tasks)

## [0.2.0] - 2026-09-01
### Added
- SimClock speed control (set_speed!, pause!, step_once!)
### Changed
- dispatch! now returns output events instead of modifying world directly
### Fixed
- Event cancellation set memory leak (cancelled events not cleaned up)

## [0.1.0] - 2026-08-07
### Added
- Initial M/M/1, M/M/c serial DES implementation
- DataStructures.PriorityQueue FEL
```

### 11.3 Git Workflow

```
main          ← stable, tagged releases only
develop       ← integration branch, CI must pass before merge
feature/*     ← feature branches (e.g., feature/pdes-tier2)
fix/*         ← bug fix branches
bench/*       ← benchmark/profiling branches (never merge to main)
```

Commit message format:
```
feat(SimDES): add conservative PDES multi-LP support
fix(SimCrowd): resolve panic force division by zero at high density
perf(SimCore): replace Dict{UInt64} with sorted Vector for ECS
test(SimDES): add DES-S-04 M/M/c Erlang-C validation
docs(SimDES): add docstrings for sim_loop! and dispatch!
```

---

## 12. License & Dependency Policy

### 12.1 Our License: Commercial Proprietary

Hermes.jl uses a **custom commercial license**. Key terms (decide with legal counsel):
- Source code is private (GitHub private repo)
- Customers receive a compiled library or source access under NDA
- Free tier: academic/research use, capped at 10,000 agents and 5 zones
- Commercial tier: full scale, support contract, deployment rights

**Do NOT** publish to the Julia General Registry (that requires open-source compatibility).

### 12.2 Dependency License Audit

Every dependency must be compatible with commercial use. **MIT and BSD licenses are safe. GPL is NOT.**

| Dependency | License | Safe for commercial? |
|---|---|---|
| `DataStructures.jl` | MIT | ✅ Yes |
| `StaticArrays.jl` | MIT | ✅ Yes |
| `GLMakie.jl` | MIT | ✅ Yes |
| `KernelAbstractions.jl` | MIT | ✅ Yes |
| `Revise.jl` | MIT | ✅ Yes (dev only) |
| `DrWatson.jl` | MIT | ✅ Yes (dev only) |
| `BenchmarkTools.jl` | MIT | ✅ Yes (dev only) |
| `JET.jl` | MIT | ✅ Yes (dev only) |
| `Aqua.jl` | MIT | ✅ Yes (dev only) |
| `Documenter.jl` | MIT | ✅ Yes (dev only) |
| `MPI.jl` | MIT | ✅ Yes |
| `CUDA.jl` | MIT | ✅ Yes |
| **Ark.jl** | **Check!** | ⚠️ **Verify before using** |

**Process for adding any new dependency**:
1. Check LICENSE file in the package's GitHub repo
2. If MIT, Apache-2.0, BSD-2/3 → ✅ approved, add to dependency
3. If GPL, AGPL, LGPL → ❌ do NOT add without legal review
4. If unclear → ask before adding
5. Document the license in `DEPENDENCY_AUDIT.md`

### 12.3 Ark.jl Specifically

Ark.jl is a newer package. **Before using it in production code, verify**:
- Its GitHub LICENSE file
- Whether it is actively maintained
- Its API stability (check if it has a 1.0 release)

If Ark.jl's license is incompatible, we implement a minimal ECS ourselves in `SimCore` (a simple `Dict{UInt64, ComponentStorage}` is ~100 lines and sufficient for our use case).

---

## 13. Toolchain Reference Card

This is the canonical list of tools — their purpose, when to use them, and how to install:

```julia
# Add all dev tools to your global Julia environment
using Pkg
Pkg.add([
    # Development workflow
    "Revise",          # Hot-reload code changes (add to startup.jl!)
    "TestItemRunner",  # Run individual @testitem blocks in VSCode
    "JuliaFormatter",  # Code formatting

    # Testing & quality
    "Aqua",            # Package quality checks
    "JET",             # Static analysis & type stability
    "BenchmarkTools",  # Micro-benchmarking

    # Documentation
    "Documenter",      # HTML docs from docstrings
    "DocStringExtensions", # TYPEDEF, TYPEDFIELDS macros

    # Profiling
    "ProfileView",     # Flamegraph profiler (desktop)
    "PProf",           # Chrome-based flamegraph profiler
])
```

**Add to `~/.julia/config/startup.jl`** (one-time setup):
```julia
# Always load Revise for hot-reloading
try; using Revise; catch e; end

# Optional: always load TestItemRunner for VSCode
try; using TestItemRunner; catch e; end
```

### Quick Reference Commands

```bash
# Run all tests for SimDES
julia --threads auto --project=packages/SimDES -e "using Pkg; Pkg.test()"

# Run a specific test item (with TestItemRunner)
julia --project=packages/SimDES -e "using TestItemRunner; @run_package_tests"

# Format all source code
julia -e "using JuliaFormatter; format(\"packages/\")"

# Run JET analysis
julia --project=packages/SimDES -e "using JET; report_package(\"SimDES\")"

# Benchmark
julia --project=experiments -e "include(\"experiments/scripts/benchmarks/PAR_03_speedup.jl\")"

# Build docs
julia --project=packages/SimDES/docs packages/SimDES/docs/make.jl

# Start Julia with all threads for development
julia --threads auto --project=.
```

---

> [REVIEW NEEDED]: This document covers all major coding concerns. Topics to revisit after team grows:
> - Code review checklist (PR template)
> - CI/CD pipeline specifics (GitHub Actions YAML)
> - Secrets management (license keys for commercial distribution)
> - Customer-facing API stability policy
>
> [COMMENT]: <!-- Add your feedback here -->
