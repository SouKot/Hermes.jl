# Hermes.jl — Implementation Phases & Task Tracker
**Date**: 2026-08-07  
**Julia**: 1.12.5 | **Repo**: `/run/media/sourabh/SANDISK-2TB/antigravity/ABM/`  
**References**: [Design Doc](./2026-08-07_simulation_platform_design.md) · [Test Cases](./2026-08-07_validation_test_cases.md) · [Code Practices](./2026-08-07_code_design_practices.md)

---

## How to Use This Document

**Status icons**:
- `[ ]` Not started
- `[/]` In progress
- `[x]` Complete
- `[!]` Blocked — see note

**Task IDs** reference the validation test catalogue (e.g., `DES-S-01`).  
**Design refs** link to sections in the design document (e.g., `§7.8`).  
Update status and add notes as you work. Commit this file with every sprint completion.

---

## Architecture Reference (The Three-Tier Model)

```
TIER 1 — Serial DES (1 thread, 1 global FEL)     ← Build first. Validate here.
TIER 2 — Conservative PDES (N threads, N LPs)    ← Build next. Scale here.
TIER 3 — Multi-facility MPI network               ← Future roadmap.

LEVEL 1 (Macro)  — Zone/Facility LP agents        → Tier 1 & 2
LEVEL 2 (Meso)   — DES entities (packages, people) → SimDES
LEVEL 3 (Micro)  — Physics particles (crowd, fluid) → SimCrowd / SimFluid
```

---

## Phase 0 — Project Infrastructure ✅ COMPLETE

> Completed: 2026-08-07

- [x] **P0-01** · Repository initialized at `/run/media/sourabh/SANDISK-2TB/antigravity/ABM/`
- [x] **P0-02** · Julia workspace `Project.toml` with all 5 packages + experiments
- [x] **P0-03** · PkgTemplates scaffold: `SimCore`, `SimDES`, `SimCrowd`, `SimFluid`, `SimViz`
- [x] **P0-04** · `.JuliaFormatter.toml` (Blue style, indent=4, margin=92)
- [x] **P0-05** · `.gitignore` (Manifests, data/, plots/, IDE files)
- [x] **P0-06** · `DEPENDENCY_AUDIT.md` — all 8 production deps approved (MIT / Apache-2.0)
- [x] **P0-07** · `docs/2026-08-07_simulation_platform_design.md` — unified architecture
- [x] **P0-08** · `docs/2026-08-07_validation_test_cases.md` — 37 test cases
- [x] **P0-09** · `docs/2026-08-07_code_design_practices.md` — coding standards
- [x] **P0-10** · `experiments/` DrWatson environment + `DES_S_01_MM1_low_load.jl` stub
- [x] **P0-11** · Initial git commit (`9fdac72`), `github.user` set for PkgTemplates
- [ ] **P0-12** · Create private GitHub repo `Hermes.jl` and push
  - `git remote add origin git@github.com:sauravkotnala/Hermes.jl.git`
  - `git branch -M main && git push -u origin main`
- [x] **P0-13** · Add `Revise.jl` to `~/.julia/config/startup.jl` ✅ (already present — auto-activates Project.toml too)
- [x] **P0-14** · Install dev tools in global environment ✅ (2026-08-07)
  - Installed: Revise, JET, Aqua, BenchmarkTools, JuliaFormatter, ProfileView, TestItemRunner
  - Note: use `julia --startup-file=no` when managing global env from workspace dir

---

## Phase 1 — SimCore: Shared Foundation

> **Goal**: Build the shared data structures that every other package depends on.  
> **Package**: `packages/SimCore/src/SimCore.jl`  
> **Design refs**: §5.1 (ECS layout), §7.1–7.3 (FEL), §7.8 (SimClock), §7.11–7.12 (events)  
> **Timeline**: Week 1

### Sprint 1A — Core Types

- [x] **1A-01** · Define abstract event hierarchy (`§7.11`)
  ```julia
  # packages/SimCore/src/events.jl
  abstract type SimEvent end
  struct EntityArrival   <: SimEvent; entity_id::UInt64; zone_id::Int; time::Float64 end
  struct ProcessComplete <: SimEvent; entity_id::UInt64; station_id::Int; time::Float64 end
  struct ResourceFailure <: SimEvent; resource_id::Int; severity::Float32; time::Float64 end
  struct ScheduledChange <: SimEvent; zone_id::Int; change_type::Symbol; time::Float64 end
  struct TransferOut     <: SimEvent; entity_id::UInt64; dest_zone::Int; time::Float64 end
  struct NullEvent       <: SimEvent end   # Chandy-Misra null message
  ```

- [x] **1A-02** · Define `CancellableEvent` wrapper + cancel set (`§7.12`)
  ```julia
  struct CancellableEvent
      id    :: UInt64
      inner :: SimEvent
      time  :: Float64
  end
  const cancelled = Set{UInt64}()
  cancel!(id::UInt64) = push!(cancelled, id)
  ```

- [x] **1A-03** · Define `SimClock` with `throttle!`, `pause!`, `unpause!`, `set_speed!` (`§7.8`)
  ```julia
  mutable struct SimClock
      sim_time     :: Float64
      wall_origin  :: Float64
      speed_factor :: Float64
      paused       :: Threads.Atomic{Bool}
  end
  ```
  - Implement `throttle!(clock, next_sim_time)` — sleep to maintain chosen speed
  - Implement `pause!` / `unpause!` via `Atomic{Bool}`
  - Implement `step_once!` — advance exactly one event then pause
  - Test: `DES-S-09` (SimClock speed fidelity at 60×, 1×, 0.5×, paused)

- [x] **1A-04** · Define ECS component structs (`§5.1`)
  ```julia
  # DES entities
  struct DESAgent; arrival_time::Float64; current_zone::Int end
  # Crowd agents
  struct CrowdAgent
      position      :: SVector{2, Float32}
      velocity      :: SVector{2, Float32}
      desired_speed :: Float32
      panic_level   :: Float32
  end
  # Fluid particles
  struct FluidParticle
      position :: SVector{2, Float32}
      velocity :: SVector{2, Float32}
      pressure :: Float32
      density  :: Float32
      mass     :: Float32
  end
  # Obstacles
  struct CrowdObstacle; geometry :: NTuple{4, Float32} end  # AABB: x1,y1,x2,y2
  ```

- [x] **1A-05** · Define `SimWorld` struct
  ```julia
  mutable struct SimWorld
      # Entity management
      next_entity_id :: Threads.Atomic{UInt64}
      # Component stores (simple Dicts for Tier 1 — replace with Ark.jl for Tier 2)
      des_agents    :: Dict{UInt64, DESAgent}
      crowd_agents  :: Dict{UInt64, CrowdAgent}
      fluid_ptcls   :: Dict{UInt64, FluidParticle}
      obstacles     :: Dict{UInt64, CrowdObstacle}
      # Simulation time
      time          :: Float64
      # Statistics
      stats         :: SimStats
  end
  ```
  > Note: For Tier 1, use `Dict` for simplicity. Ark.jl replaces this in Tier 2 for cache efficiency.

- [x] **1A-06** · Define `SimStats` struct
  ```julia
  mutable struct SimStats
      total_events      :: Int
      total_arrivals    :: Int
      total_departures  :: Int
      mean_queue_length :: Float64
      mean_wait_time    :: Float64
      utilization       :: Float64
  end
  ```

- [x] **1A-07** · Add `DataStructures.jl` and `StaticArrays.jl` to `SimCore/Project.toml`
  - `cd packages/SimCore && julia --project=. -e 'using Pkg; Pkg.add(["DataStructures","StaticArrays"])'`

### Sprint 1B — SimCore Tests

- [x] **1B-01** · Write `SimCore/test/runtests.jl` with Aqua + JET checks
- [x] **1B-02** · Test: `SimClock` at `speed_factor=Inf` advances without sleep
- [x] **1B-03** · Test: `SimClock` pause blocks and unpause resumes
- [x] **1B-04** · Test: `@inferred SimClock(1.0)` — type stable construction
- [x] **1B-05** · Test: `CancellableEvent` cancel set — cancelled events not dispatched
  - Corresponds to validation: **DES-S-08**
- [x] **1B-06** · Run: `julia --project=packages/SimCore -e "using Pkg; Pkg.test()"`

---

## Phase 2 — SimDES: Serial DES Engine (Tier 1)

> **Goal**: A working, validated serial DES engine passing all DES-S-xx tests.  
> **Package**: `packages/SimDES/src/SimDES.jl`  
> **Design refs**: §7.1–7.5 (FEL, events), §7.8 (SimClock), §7.11–7.12 (dispatch)  
> **Depends on**: Phase 1 complete  
> **Timeline**: Weeks 1–2

### Sprint 2A — Core DES Engine

- [ ] **2A-01** · Create `SimDES/src/SimDES.jl` module skeleton, depend on SimCore
  - `cd packages/SimDES && julia --project=. -e 'using Pkg; Pkg.add(["DataStructures"]); Pkg.develop(path="../SimCore")'`

- [ ] **2A-02** · Implement `FutureEventList` — typed wrapper around `PriorityQueue`
  ```julia
  # packages/SimDES/src/fel.jl
  struct FutureEventList
      queue :: PriorityQueue{CancellableEvent, Float64}
  end
  schedule!(fel, event::SimEvent, t::Float64) = enqueue!(fel.queue, CancellableEvent(next_id!(), event, t) => t)
  safe_dequeue!(fel) = ...   # skip cancelled events
  peek_time(fel)     = isempty(fel.queue) ? Inf : minimum(fel.queue)
  ```

- [ ] **2A-03** · Implement `sim_loop!` — main event loop with SimClock throttle
  ```julia
  function sim_loop!(world::SimWorld, fel::FutureEventList, clock::SimClock, t_end::Float64) :: SimStats
      while !isempty(fel.queue)
          ev, t = safe_dequeue!(fel)
          t > t_end && break
          throttle!(clock, t)       # speed control
          world.time = t
          dispatch!(world, fel, ev.inner, t)
      end
      return world.stats
  end
  ```

- [ ] **2A-04** · Implement M/M/1 primitive elements via Julia multiple dispatch
  - `dispatch!(world, fel, e::EntityArrival, t)` — entity joins queue, schedules service if server idle
  - `dispatch!(world, fel, e::ProcessComplete, t)` — entity departs, next in queue starts service if any
  - `dispatch!(world, fel, e::NullEvent, t)` — no-op (Chandy-Misra placeholder)
  - Use `schedule!(fel, event, t)` inside handlers to chain events

- [ ] **2A-05** · Implement `run_mm1!` convenience function
  ```julia
  function run_mm1!(λ::Float64, μ::Float64; n_arrivals::Int=100_000, seed::Int=42) :: SimStats
      world = SimWorld()
      fel   = FutureEventList()
      clock = SimClock(Inf)          # fastest mode for validation
      Random.seed!(seed)
      # Schedule first arrival
      schedule!(fel, EntityArrival(next_entity_id!(world), 1, rand(Exponential(1/λ))), 0.0)
      return sim_loop!(world, fel, clock, Inf)
  end
  ```

- [ ] **2A-06** · Implement M/M/c multi-server support
  - `dispatch!(world, fel, e::EntityArrival, t)` — check if any of `c` servers idle
  - Track server states in `SimWorld.station_state :: Dict{Int, Int}` (count of busy servers)

- [ ] **2A-07** · Implement M/M/1/K finite buffer (blocking)
  - Add `capacity::Int` to queue state
  - Lost entities tracked in `stats.blocked_count`

- [ ] **2A-08** · Implement non-exponential service time distributions
  - `M/D/1`: `service_dist = Dirac(d)` — deterministic
  - `M/G/1`: `service_dist = Erlang(k, λ)` — Erlang-k
  - Store `service_dist` as a callable in zone config, not hardcoded

- [ ] **2A-09** · Implement machine failure events
  - `dispatch!(world, fel, e::ResourceFailure, t)` — marks machine as down, reschedules repair
  - Repair: `dispatch!(world, fel, e::ScheduledChange{:Repair}, t)` — machine back up
  - Track `machine_availability` in `SimStats`

- [ ] **2A-10** · Implement `statistics_collector!` — welch warmup removal
  - Detect steady-state using Welch's method (sliding window variance)
  - Record statistics only after warm-up detected
  - Compute: mean `L`, `Lq`, `W`, `Wq`, utilization `ρ`

### Sprint 2B — DES Validation Tests

Wire validation scripts in `experiments/scripts/des/` to use real `SimDES`:

- [ ] **2B-01** · **DES-S-01**: M/M/1 ρ=0.50 — `L ≈ 1.0`, `Wq ≈ 0.5 min` (±2%)
- [ ] **2B-02** · **DES-S-02**: M/M/1 ρ=0.90 — `L ≈ 9.0`, `Wq ≈ 9.0 min` (±5%)
- [ ] **2B-03** · **DES-S-03**: M/M/1 sweep ρ∈{0.1,0.25,0.5,0.7,0.8,0.9,0.95} — full curve
- [ ] **2B-04** · **DES-S-04**: M/M/c (c=4, ρ=0.667) — Erlang-C formula comparison
- [ ] **2B-05** · **DES-S-05**: M/M/1/K (K=5, ρ=1.0) — blocking probability ≈ 1/6
- [ ] **2B-06** · **DES-S-06**: M/D/1 (ρ=0.8) — `Wq ≈ 2.0 min` (P-K formula)
- [ ] **2B-07** · **DES-S-07**: M/G/1 Erlang-2 service — P-K formula validation
- [ ] **2B-08** · **DES-S-08**: Event cancellation — exactly 500/1000 events execute
- [ ] **2B-09** · **DES-S-09**: SimClock fidelity — 60×, 1×, 0.5× speed accuracy

### Sprint 2C — Medium DES Scenarios

- [ ] **2C-01** · **DES-M-01**: Tandem queue (2 nodes, Jackson's theorem)
  - Implement entity routing between zones: `TransferOut` event → next zone receives `EntityArrival`
  - Validate: total sojourn time `W = W₁ + W₂ = 1.5 min`

- [ ] **2C-02** · **DES-M-02**: Jackson network (4 nodes, routing matrix)
  - `dispatch!(world, fel, e::TransferOut, t)` routes with probability vector
  - Validate each node independently vs. M/M/1 formula

- [ ] **2C-03** · **DES-M-03**: Priority queue (preemptive, 2 classes)
  - Add `priority::Int` field to `EntityArrival`
  - Preemption: high-priority arrival interrupts low-priority service

- [ ] **2C-04** · **DES-M-04**: Machine with failures (`ResourceFailure` + `ScheduledChange`)
  - Availability target: `A = β/(α+β) ≈ 0.909`

- [ ] **2C-05** · **DES-M-06**: Time-varying arrival rate (NHPP via thinning)
  - `ArrivalRateSchedule` struct with hourly λ values
  - Thinning algorithm: draw from max λ, reject with probability `1 - λ(t)/λ_max`

- [ ] **2C-06** · **DES-M-07**: Fork-join parallel processing
  - `EntityArrival` spawns 3 simultaneous sub-entities
  - `JoinBarrier` event fires when all 3 complete
  - Validate: join time > max(E[S₁], E[S₂], E[S₃])

---

## Phase 3 — SimCrowd: Social Force Model

> **Goal**: CPU-correct Social Force Model, GPU-accelerated, passing all CRW-S and CRW-M tests.  
> **Package**: `packages/SimCrowd/src/SimCrowd.jl`  
> **Design refs**: §3 (Crowd module), §5.1 (ECS layout), §6.3 (FLAME GPU 2 pattern)  
> **Depends on**: Phase 1 (SimCore) complete  
> **Timeline**: Weeks 2–4

### Sprint 3A — Social Force Model (CPU)

- [ ] **3A-01** · Add dependencies to `SimCrowd/Project.toml`
  - `Pkg.add(["StaticArrays","LinearAlgebra"]); Pkg.develop(path="../SimCore")`

- [ ] **3A-02** · Implement goal-seeking force (`§3`, Helbing & Molnár 1995)
  ```julia
  function goal_seeking_force(pos::SVector{2,F}, vel::SVector{2,F},
                              goal::SVector{2,F}, v₀::F, τ::F) where F
      ê = normalize(goal - pos)
      return (v₀ * ê - vel) / τ
  end
  ```

- [ ] **3A-03** · Implement agent-agent repulsion force (Gaussian potential)
  ```julia
  # Parameters: A=2000N, B=0.08m (Helbing & Molnár 1995 default)
  function agent_repulsion(pos_i, pos_j, r_i, r_j; A=2000f0, B=0.08f0)
      r_ij = pos_i - pos_j
      d    = norm(r_ij)
      d < 1e-6f0 && return zero(r_ij)
      return A * exp((r_i + r_j - d) / B) * normalize(r_ij)
  end
  ```

- [ ] **3A-04** · Implement wall/obstacle repulsion force
  ```julia
  function wall_repulsion(pos, wall_segment; A_w=2000f0, B_w=0.08f0)
      d_w, n_w = closest_point_on_segment(pos, wall_segment)
      return A_w * exp(-d_w / B_w) * n_w
  end
  ```

- [ ] **3A-05** · Implement Euler integration step
  ```julia
  function integrate_agent!(agent::CrowdAgent, force::SVector{2,F}, dt::F) where F
      new_vel = agent.velocity + force * dt
      # Clamp to maximum speed (1.3 × desired_speed for panic)
      max_speed = agent.desired_speed * (1f0 + agent.panic_level)
      norm_vel  = norm(new_vel)
      if norm_vel > max_speed
          new_vel = new_vel * (max_speed / norm_vel)
      end
      new_pos = agent.position + new_vel * dt
      return CrowdAgent(new_pos, new_vel, agent.desired_speed, agent.panic_level)
  end
  ```

- [ ] **3A-06** · Implement naive O(N²) crowd step (correct but slow — baseline for tests)
  ```julia
  function crowd_step_cpu!(world::SimWorld, dt::Float32)
      agents = collect(values(world.crowd_agents))
      n = length(agents)
      forces = zeros(SVector{2,Float32}, n)
      for i in 1:n
          a_i = agents[i]
          # Goal force
          forces[i] += goal_seeking_force(a_i.position, a_i.velocity,
                                           a_i.goal, a_i.desired_speed, τ)
          # Agent-agent repulsion
          for j in 1:n
              i == j && continue
              forces[i] += agent_repulsion(a_i.position, agents[j].position, r, r)
          end
          # Wall repulsion
          for obs in values(world.obstacles)
              forces[i] += wall_repulsion(a_i.position, obs)
          end
      end
      # Integrate
      for (i, (id, _)) in enumerate(world.crowd_agents)
          world.crowd_agents[id] = integrate_agent!(agents[i], forces[i], dt)
      end
  end
  ```

- [ ] **3A-07** · Implement Eikonal navigation potential field
  - Build distance-to-goal grid on initialization
  - Fast Marching Method for static obstacles
  - Agent goal direction = gradient of Eikonal field
  - Re-compute when gates open/close (DES event triggers this)

- [ ] **3A-08** · Implement spatial hash grid — O(N·k) neighbor lookup
  ```julia
  struct SpatialHashGrid{F}
      cell_size  :: F
      grid       :: Dict{Tuple{Int,Int}, Vector{Int}}   # cell → agent indices
  end
  function insert_agents!(grid::SpatialHashGrid, positions)
      empty!(grid.grid)
      for (i, pos) in enumerate(positions)
          key = floor_cell(pos, grid.cell_size)
          push!(get!(Vector{Int}, grid.grid, key), i)
      end
  end
  function neighbors(grid, pos, radius)
      # return all agent indices within radius
  end
  ```

### Sprint 3B — GPU Acceleration (KernelAbstractions.jl)

> **Design ref**: §6.3 (FLAME GPU 2 agent function pattern)

- [ ] **3B-01** · Add `KernelAbstractions.jl` to `SimCrowd/Project.toml`
- [ ] **3B-02** · Convert agent state to SoA (Structure of Arrays) for GPU efficiency
  ```julia
  struct CrowdAgentSoA
      positions     :: Vector{SVector{2, Float32}}    # or CuVector for GPU
      velocities    :: Vector{SVector{2, Float32}}
      desired_speeds:: Vector{Float32}
      panic_levels  :: Vector{Float32}
      goals         :: Vector{SVector{2, Float32}}
  end
  ```

- [ ] **3B-03** · Implement `@kernel social_force_kernel!` with KernelAbstractions
  - Thread index → agent index `i`
  - Read neighbors from spatial hash (pre-computed on GPU)
  - Compute goal + repulsion + wall forces
  - Write to force buffer (no race conditions — each thread owns `forces[i]`)
  
- [ ] **3B-04** · Implement GPU-resident spatial hash grid
  - Sort agents by cell → build CSR (compressed sparse row) neighbor list
  - GPU-friendly: no dynamic `Dict`, sorted arrays + binary search

- [ ] **3B-05** · Benchmark GPU vs CPU: at N=1k, 10k, 50k, 100k agents
  - Corresponds to **PAR-05**

### Sprint 3C — Crowd Validation Tests

- [ ] **3C-01** · **CRW-S-01**: Single agent straight-line to goal
  - Verify: reaches goal, steady-state speed = `v₀ ± 0.05`, no overshoot
- [ ] **3C-02** · **CRW-S-02**: Single agent obstacle avoidance
  - Verify: no penetration, reaches goal, smooth path
- [ ] **3C-03** · **CRW-S-03**: Two agents head-on — symmetric avoidance
  - Verify: both reach goals, no penetration, symmetric paths
- [ ] **3C-04** · **CRW-S-04**: 10-agent bottleneck — arching at 1.2m door
  - Verify: all exit, flow rate 1.0–1.5 agents/sec, visual arch
- [ ] **3C-05** · **CRW-S-05**: Faster-is-slower — 20 agents, 3 panic levels
  - Verify: `T_evac(v₀=1.0) < T_evac(v₀=5.0)` (panic slows evacuation)
- [ ] **3C-06** · **CRW-M-01**: Lane formation — 200 agents bidirectional corridor
  - Verify: lanes form within 15s, mean speed > 1.2 m/s
  - Reference: Helbing & Molnár (1995) Fig. 4
- [ ] **3C-07** · **CRW-M-02**: Fundamental diagram — speed vs. density
  - Run at ρ∈{0.1, 0.5, 1.0, 2.0, 3.0, 5.0} p/m²
  - Verify: within ±15% of Weidmann (1993) empirical data
- [ ] **3C-08** · **CRW-M-03**: 500-agent multi-exit evacuation
  - Verify: evacuation time within ±20% of flow-capacity estimate
- [ ] **3C-09** · **CRW-L-01**: 10,000-agent large venue — performance + correctness
  - Verify: > 30 FPS on target GPU
  - Corresponds to **PAR-05** (crowd scaling)

---

## Phase 4 — SimViz: GLMakie Desktop Prototype

> **Goal**: Real-time visualization of simulation state. Phase 1 desktop = no editor, hardcoded layout.  
> **Package**: `packages/SimViz/src/SimViz.jl`  
> **Design refs**: §4.3 (GLMakie Phase 1), §4.4 (desktop window layout)  
> **Depends on**: Phase 2 (SimDES) and Phase 3 (SimCrowd) for something to visualize  
> **Timeline**: Weeks 2–3 (runs in parallel with Phase 2 & 3)

### Sprint 4A — Core Visualization

- [ ] **4A-01** · Add `GLMakie.jl`, `Observables.jl` to `SimViz/Project.toml`

- [ ] **4A-02** · Implement `SimVizState` — Observables wrapping world state
  ```julia
  struct SimVizState
      positions     :: Observable{Vector{Point2f}}
      panic_levels  :: Observable{Vector{Float32}}
      stats_text    :: Observable{String}
      sim_time      :: Observable{Float64}
  end
  ```

- [ ] **4A-03** · Implement `create_window!` — main GLMakie figure
  - Multi-panel layout: simulation canvas + statistics panel + controls
  - `meshscatter!` for agents (one GPU draw call for all agents)
  - `heatmap!` for density overlay (optional)
  - `lines!` for walls/obstacles

- [ ] **4A-04** · Implement `update_viz!` — push world state to Observables
  - Called from simulation loop at 60fps
  - Reads `SimWorld.crowd_agents` → writes `positions[]`, `panic_levels[]`
  - Stats panel: simulated time, event count, agent count, FPS

- [ ] **4A-05** · Implement control bar (GLMakie `Button` + `Slider`)
  - `▶ Run` button — calls `unpause!(clock)`
  - `⏸ Pause` button — calls `pause!(clock)`
  - `⏭ Step` button — calls `step_once!(clock)`
  - Speed slider: 0.1× to ∞ — calls `set_speed!(clock, val)`
  - `⏹ Reset` button — resets world and FEL

- [ ] **4A-06** · Implement `run_visualization!` — async simulation + sync viz
  ```julia
  function run_visualization!(world, fel, clock)
      fig = create_window!()
      viz = SimVizState()
      display(fig)
      @async begin
          while isopen(fig.scene)
              step_simulation!(world, fel, clock)
              update_viz!(viz, world)
              sleep(1/60)
          end
      end
  end
  ```

### Sprint 4B — Test Scenarios for Visualization

- [ ] **4B-01** · Hardcoded M/M/1 queue visualization (single server, queue depth as color)
- [ ] **4B-02** · Hardcoded 100-agent evacuation room visualization
- [ ] **4B-03** · Combined: DES alarm event triggers crowd evacuation (visible in GLMakie)
  - This is the first integration test: `ScheduledChange{:EvacAlarm}` changes crowd goals

---

## Phase 5 — Conservative PDES: Tier 2 Engine

> **Goal**: Refactor serial DES to per-LP parallel DES using Chandy-Misra protocol.  
> **Design refs**: §7.5 (Option B), §7.6 (PDES as ABM), §7.7 (no zone limit), §7.10 (Tier 2)  
> **Depends on**: Phase 2 complete and all DES-S tests passing  
> **Timeline**: Weeks 4–6

### Sprint 5A — LP Architecture

- [ ] **5A-01** · Define `ZoneConfig` and `ZoneState`
  ```julia
  struct ZoneConfig
      id         :: Int
      lookahead  :: Float64        # minimum transit time to downstream neighbors
      neighbors  :: Vector{Int}    # downstream LP IDs
  end
  mutable struct ZoneState
      id         :: Int
      local_time :: Float64
      local_fel  :: FutureEventList
      lookahead  :: Float64
  end
  ```

- [ ] **5A-02** · Implement `ZoneMessage` — timestamped inter-LP message
  ```julia
  struct ZoneMessage
      from_zone :: Int
      event     :: SimEvent
      time      :: Float64
  end
  ```

- [ ] **5A-03** · Build channel graph — one `Channel{ZoneMessage}` per directed edge
  ```julia
  function build_channel_graph(zones::Vector{ZoneConfig})
      channels = Dict{Tuple{Int,Int}, Channel{ZoneMessage}}()
      for z in zones, neighbor in z.neighbors
          channels[(z.id, neighbor)] = Channel{ZoneMessage}(1024)
      end
      return channels
  end
  ```

- [ ] **5A-04** · Implement `run_zone!` — LP main loop (Chandy-Misra)
  ```julia
  function run_zone!(config::ZoneConfig, state::ZoneState,
                     inbox::Channel{ZoneMessage},
                     outboxes::Dict{Int, Channel{ZoneMessage}},
                     t_end::Float64)
      while state.local_time < t_end
          # 1. Send null messages to all neighbors (announce safe window)
          safe_until = state.local_time + config.lookahead
          for (nb_id, ch) in outboxes
              put!(ch, ZoneMessage(config.id, NullEvent(), safe_until))
          end
          # 2. Receive messages — process up to safe horizon
          while (msg = take!(inbox)).time <= safe_until
              if !(msg.event isa NullEvent)
                  schedule!(state.local_fel, msg.event, msg.time)
              end
          end
          # 3. Process local events up to safe horizon
          while !isempty(state.local_fel) && peek_time(state.local_fel) <= safe_until
              ev, t = safe_dequeue!(state.local_fel)
              state.local_time = t
              dispatch!(state, outboxes, ev.inner, t)
          end
      end
  end
  ```

- [ ] **5A-05** · Implement `launch_parallel_des!` — spawn one Task per zone
  ```julia
  function launch_parallel_des!(zones::Vector{ZoneConfig}, t_end::Float64)
      channels = build_channel_graph(zones)
      states   = [ZoneState(z.id, 0.0, FutureEventList(), z.lookahead) for z in zones]
      tasks = [Threads.@spawn run_zone!(
                  zones[i], states[i],
                  inbox_channel(channels, zones[i].id),
                  outbox_channels(channels, zones[i].id),
                  t_end)
               for i in eachindex(zones)]
      foreach(wait, tasks)
      return merge_stats(states)
  end
  ```

### Sprint 5B — PDES Validation Tests

- [ ] **5B-01** · **PAR-01**: Serial vs. parallel correctness — identical event logs with fixed seed
- [ ] **5B-02** · **PAR-02**: Null message deadlock test — circular LP topology (LP1→LP2→LP3→LP1)
- [ ] **5B-03** · **PAR-03**: Speedup vs. LP count — 1,2,4,5,8,10 LPs, measure wall time
  - Plot: actual vs. ideal speedup; compute Amdahl's serial fraction
- [ ] **5B-04** · **PAR-04**: FEL throughput — n=100→1k→10k→100k→1M events, measure events/sec
- [ ] **5B-05** · **PAR-06**: SimClock parallel consistency — all LP clocks within 0.1 sim-sec
- [ ] **5B-06** · **PAR-07**: Lookahead sensitivity — DC model, sweep lookahead 0.1s to 300s

### Sprint 5C — Large DES Scenarios

- [ ] **5C-01** · **DES-L-03**: DC Inbound (10 LPs, Tier 2 PDES)
  - LP1: Truck arrivals | LP2: Inbound dock | LP3: Receiving/QC
  - LP4: Sorter | LP5: Putaway | LPs 6-10: storage zones
  - Validate: throughput pallets/hour, queue depths, dock utilization

- [ ] **5C-02** · **DES-M-01**: Tandem queue via Tier 2 (each node = separate LP)
  - Verify: results identical to serial Tier 1 run

---

## Phase 6 — DES + Crowd Integration

> **Goal**: DES events trigger crowd behavior changes. Full `§5` unified architecture.  
> **Design refs**: §5.2 (sim step loop), §3.5 (crowd DES coupling)  
> **Depends on**: Phase 2 (DES) + Phase 3 (Crowd) + Phase 4 (Viz) complete  
> **Timeline**: Weeks 6–8

### Sprint 6A — Integration Layer

- [ ] **6A-01** · Implement `dispatch!` for crowd-triggering events in SimDES
  ```julia
  # EvacAlarm fires → all crowd agents change goal to nearest exit
  function dispatch!(world::SimWorld, fel::FutureEventList,
                     e::ScheduledChange{:EvacAlarm}, t::Float64)
      for (id, agent) in world.crowd_agents
          nearest_exit = find_nearest_exit(world, agent.position)
          world.crowd_agents[id] = @set agent.goal = nearest_exit.position
          world.crowd_agents[id] = @set agent.panic_level = min(1f0, agent.panic_level + 0.5f0)
      end
      @info "EvacAlarm at t=$t — $(length(world.crowd_agents)) agents rerouted"
  end
  ```

- [ ] **6A-02** · Implement gate open/close DES event → Eikonal recompute
  ```julia
  function dispatch!(world, fel, e::ScheduledChange{:GateOpen}, t)
      world.gates[e.zone_id].open = true
      recompute_eikonal!(world)      # navigation field updated
  end
  ```

- [ ] **6A-03** · Implement `Gate` as shared DES+Crowd element
  - Gate state: open/closed (DES controlled)
  - Physical geometry: obstacle when closed (Crowd respects)
  - Throughput measured by DES statistics

- [ ] **6A-04** · Implement crowd flow rate measurement → DES statistics
  - Count agents crossing Exit boundary → `ProcessComplete` DES event
  - Feeds back into queue depth stats

### Sprint 6B — Integration Validation

- [ ] **6B-01** · **CRW-L-03**: Hospital Ward — DES schedule + crowd dynamics
  - Shift change: `ScheduledChange{:ShiftChange}` → new staff wave spawned
  - Emergency: `EvacAlarm` → all visitors reroute
  - Verify: crowd density follows DES schedule, no race conditions

- [ ] **6B-02** · **CRW-L-01**: 10,000-agent venue + DES alarm
  - DES event at t=60s → panic level increases → faster-is-slower
  - Verify: evacuation time, bottleneck identification

- [ ] **6B-03** · **CRW-L-02**: 5,000-agent panic scenario
  - Verify: post-panic exit flow rate < pre-panic rate

---

## Phase 7 — Godot 4 Desktop Application (Phase 2 Visualization)

> **Goal**: Replace hardcoded GLMakie layout with a full Godot 4 scene editor + real-time rendering.  
> **Design refs**: §4.4 (Godot 4 architecture), §4.5 (Julia ↔ Godot communication), §4.11 (WebSocket protocol)  
> **Depends on**: Phase 6 complete (engine stable, validated)  
> **Timeline**: Weeks 8–14

### Sprint 7A — Julia WebSocket Server

- [ ] **7A-01** · Add `HTTP.jl` or `Oxygen.jl` to workspace deps
- [ ] **7A-02** · Implement `WebSocketServer` in SimViz
  ```julia
  function start_viz_server!(world::SimWorld, clock::SimClock; port=8765)
      server = WebSocket.listen(port) do ws
          # Send sim state at 60fps
          @async while isopen(ws)
              state = serialize_world(world)
              send(ws, MsgPack.pack(state))
              sleep(1/60)
          end
          # Receive layout and control messages
          for msg in ws
              handle_client_message!(world, clock, MsgPack.unpack(msg))
          end
      end
  end
  ```

- [ ] **7A-03** · Implement `serialize_world` — MessagePack binary frame
  - Crowd positions + panic levels (Float32 per agent for bandwidth)
  - DES statistics (queue depths, utilization)
  - Simulated time
  - Delta encoding: only send changed positions

- [ ] **7A-04** · Implement `handle_client_message!` — receive layout + clock commands
  - `clock` commands: `{speed: 1.0, command: "play"}` → `set_speed!(clock, 1.0)`
  - `layout` updates: parse new zone topology → rebuild world

### Sprint 7B — Godot 4 Application

- [ ] **7B-01** · Install Godot 4 (desktop) — https://godotengine.org/download
- [ ] **7B-02** · Create Godot 4 project: `ABM/godot/HermesViz/`
- [ ] **7B-03** · Implement WebSocket client in GDScript
  - Connect to `ws://localhost:8765`
  - Parse MessagePack frames (use `msgpack-gd` plugin or pure GDScript)
  - Update `MultiMeshInstance2D` agent positions each frame

- [ ] **7B-04** · Configure `MultiMeshInstance2D` for 500k+ agent rendering
  - One `MultiMesh` per agent type (crowd, fluid particles)
  - Instance color = panic level (green → red via HSV)
  - Instance transform = agent position

- [ ] **7B-05** · Build physical layout editor using Godot Scene Editor
  - Create custom `SimElement` nodes: `QueueNode`, `ServerNode`, `CrowdSource`, `Exit`, `Gate`
  - Each node: icon + property inspector fields (capacity, service rate, etc.)
  - Export scene to JSON → send to Julia via WebSocket

- [ ] **7B-06** · Implement process logic graph via Godot's `GraphEdit`
  - Built-in `GraphEdit` + `GraphNode` for node connections
  - Custom node types matching SimDES element library

- [ ] **7B-07** · Implement simulation control panel in Godot UI
  - Play / Pause / Step / Reset buttons
  - Speed slider (0.1× to 10×, plus "fastest" mode)
  - Clock display: sim time + wall time
  - FPS counter and agent count

---

## Phase 8 — Large DES Scenarios (Final Validation)

> **Goal**: Complete all medium and large DES test cases that require Tier 2.  
> **Depends on**: Phase 5 (PDES) complete  
> **Timeline**: Weeks 10–16

- [ ] **8-01** · **DES-L-01**: Manufacturing cell — 5 machines, buffers, breakdowns
- [ ] **8-02** · **DES-L-02**: Call center — 20 agents, 3 skill groups, NHPP arrivals
- [ ] **8-03** · **DES-M-05**: Batch arrivals and service
- [ ] **8-04** · **CRW-M-04**: T-junction merge (300 agents)
- [ ] **8-05** · **CRW-M-05**: Stadium aisle evacuation (2,000 agents)
- [ ] **8-06** · Full benchmark report: all PAR-xx tests with plots

---

## Phase 9 — SimFluid (Skeleton → Implementation)

> **Goal**: First working fluid simulation — pipe network solver. SPH/LBM deferred.  
> **Package**: `packages/SimFluid/src/SimFluid.jl`  
> **Design refs**: §5.1 (fluid components), §5.2 (fluid step in sim loop)  
> **Status**: Skeleton only — implementation deferred to Phase 9  
> **Timeline**: Month 3–4 (after Phases 1–6 complete)

- [ ] **9-01** · Define `PipeNode`, `PipeSegment`, `Valve`, `Reservoir` components
- [ ] **9-02** · Implement pipe network graph (`Graphs.jl` + pressure solver)
  - Hazen-Williams or Darcy-Weisbach equation for steady-state flow
  - Sparse linear algebra: `A·p = b` where A = network admittance matrix
- [ ] **9-03** · Integrate with DES: `Valve` open/close events → pressure re-solve
- [ ] **9-04** · SPH (Smoothed Particle Hydrodynamics) kernel — GPU (deferred to later)
- [ ] **9-05** · LBM (Lattice-Boltzmann Method) grid — GPU (deferred to later)

---

## Phase 10 — Multi-Facility Network (Tier 3 / Future)

> **Goal**: Connect multiple Hermes facilities via MPI.  
> **Design refs**: §7.7 (Tier 3 MPI), §7.9 (multi-facility topology)  
> **Status**: Future roadmap — not before Phases 1–8 complete  
> **Timeline**: Month 6+

- [ ] **10-01** · Design `MessageTransport` abstraction (Channel → MPI swappable) — see code practices §6.3
- [ ] **10-02** · Implement `MPI.jl` transport layer for ZoneMessage
- [ ] **10-03** · Test: 3-facility supply chain (Manufacturing → Regional DC → Last-Mile)
- [ ] **10-04** · Benchmark: speedup with MPI vs. single-machine Tier 2

---

## Phase 11 — Web Deployment (Phase 3 Frontend)

> **Goal**: Deploy Hermes as a web application (choose Godot WASM or React stack).  
> **Design refs**: §4.8 (path decision), §4.9 (updated tech stack)  
> **Status**: Decision deferred until Phase 7 complete  
> **Timeline**: Month 6+

- [ ] **11-01** · **Decision point**: Godot WASM vs. React+PixiJS
  - Evaluate: Godot WASM performance in browser, download size
  - Evaluate: React+PixiJS web app feasibility
- [ ] **11-02** · **Option A** (if Godot WASM): Export Godot project to WASM, deploy to static host
- [ ] **11-03** · **Option B** (if React): Build React + Konva.js + PixiJS v8 web frontend
- [ ] **11-04** · Julia backend: unchanged WebSocket protocol works for both

---

## Progress Dashboard

| Phase | Name | Status | Sprint completion |
|---|---|---|---|
| **0** | Infrastructure | ✅ Complete (2026-08-07) | 13/14 tasks done (P0-12 GitHub push pending) |
| **1** | SimCore | ✅ Complete (2026-08-07) | 12/12 |
| **2** | SimDES Tier 1 | `[ ]` Not started | 0/24 |
| **3** | SimCrowd + GPU | `[ ]` Not started | 0/21 |
| **4** | SimViz GLMakie | `[ ]` Not started | 0/8 |
| **5** | Conservative PDES | `[ ]` Not started | 0/15 |
| **6** | DES + Crowd Integration | `[ ]` Not started | 0/7 |
| **7** | Godot 4 Desktop App | `[ ]` Not started | 0/14 |
| **8** | Large DES Validation | `[ ]` Not started | 0/6 |
| **9** | SimFluid | `[ ]` Deferred | — |
| **10** | Multi-facility (MPI) | `[ ]` Future | — |
| **11** | Web Deployment | `[ ]` Future | — |

---

## Validation Coverage by Phase

| Phase completes | Tests now passing |
|---|---|
| Phase 1 | DES-S-08, DES-S-09 |
| Phase 2A+2B | DES-S-01..09 (all small DES) |
| Phase 2C | DES-M-01..07 (medium DES) |
| Phase 3A+3C | CRW-S-01..05, CRW-M-01..03 |
| Phase 3B | PAR-05 (GPU scaling) |
| Phase 4 | Integration demo (not a test case) |
| Phase 5A+5B | PAR-01..07 (all parallel tests) |
| Phase 5C | DES-L-03 (DC inbound) |
| Phase 6 | CRW-L-01..03 |
| Phase 8 | DES-L-01..02, CRW-M-04..05 |

**Total**: 37 test cases | Expected fully green after Phase 8.

---

## Key Technical Decisions Already Made

| Decision | Answer | Reference |
|---|---|---|
| Julia version | 1.12.5 | Phase 0 |
| ECS engine | Ark.jl (Apache-2.0 + MIT) | §5.1, DEPENDENCY_AUDIT |
| FEL data structure | `DataStructures.PriorityQueue` (binary heap) for Tier 1 | §7.2 |
| Parallel DES protocol | Conservative (Chandy-Misra) — no rollbacks | §7.5 Option B |
| GPU backend | `KernelAbstractions.jl` (hardware-agnostic) | §6.3, code_practices §6.1 |
| Phase 1 viz | GLMakie (desktop, already installed) | §4.3 |
| Phase 2 viz | Godot 4 desktop app (MIT, 500k+ agents) | §4.4 |
| Phase 3 viz | Decision deferred (Godot WASM vs React+PixiJS) | §4.8 |
| Crowd model | Social Force Model (Helbing & Molnár 1995) | §3 |
| Navigation | Eikonal potential field per exit | §3 |
| Unicode policy | Selective: λ,μ,ρ,τ,Δt in math; ASCII in public API | code_practices §4 |
| Type stability | JET.jl mandatory for SimCore, SimDES, SimCrowd hot paths | code_practices §5 |
| License | Proprietary commercial (custom LICENSE) | code_practices §12 |
| Software name | **Hermes.jl** | code_practices §1 |
