# Simulation Platform Design Document
### DES · Fluid Dynamics · Crowd Simulation — Unified Architecture
**Date**: 2026-08-07  
**Status**: In Review  
**Goal**: Build an AnyLogic / FlexSim-class simulation platform in Julia

---

## 📝 How to Review This Document

This document is designed for collaborative review. Please use the following comment convention **anywhere in the file** to leave feedback:

```
> [COMMENT]: Your comment or question here.
```

Example:
```
> [COMMENT]: I prefer Agents.jl for prototyping — should we start there?
```

After adding your comments, save the file and share it back. Comments can go:
- Immediately **after** any section header, table, or code block
- Inside the dedicated **`> [REVIEW NEEDED]`** boxes that appear at the end of each section
- Anywhere inline in the text

---

## Table of Contents

1. [Project Vision](#1-project-vision)
2. [Framework Comparison: Agents.jl vs Ark.jl vs Vahana.jl](#2-framework-comparison)
3. [Crowd Dynamics — New Module](#3-crowd-dynamics--new-module)
4. [Visualization & GUI Architecture](#4-visualization--gui-architecture)
5. [Unified System Architecture](#5-unified-system-architecture)
6. [Open-Source Reference Implementations](#6-open-source-reference-implementations)
7. [Event Scheduling: Data Structures & Design](#7-event-scheduling-data-structures--design)
8. [Open Questions & Next Steps](#8-open-questions--next-steps)

---

## 1. Project Vision

Build a **Julia-based simulation platform** targeting three interconnected domains:

| Domain | What it models | Real-world use cases |
|---|---|---|
| **Discrete Event Simulation (DES)** | Queues, servers, resources, processes | Manufacturing, supply chain, hospital flow |
| **Fluid / Hydraulic Dynamics** | Pipe networks, particle-based SPH/LBM | Water distribution, industrial process simulation |
| **Crowd Dynamics** | Pedestrian agents with local behavioral rules | Evacuation, venue capacity, airport terminal flow |

These three domains are **not independent** — they share a common agent-based substrate and benefit from a unified engine. This is the insight that makes this platform novel.

> **Design Principle**: Use Agent-Based Methods (ABM) as the unifying computational paradigm. A person in a crowd, a fluid particle, and a customer in a queue are all *agents* with state and behavioral rules — the engine is the same.

> [REVIEW NEEDED] §1: Does this vision statement accurately capture your goal? Should we add any fourth domain (e.g., traffic, supply chain)? Should we scope this down to one domain for Phase 1?
>
> [COMMENT]: <!-- Add your comment here -->

---

## 2. Framework Comparison

> *Sources: Official documentation for each framework, read directly during the August 5–6 session.*

### 2.1 What Each Framework Actually Is

| | **Agents.jl** | **Ark.jl** | **Vahana.jl** |
|---|---|---|---|
| **Type** | ABM simulation framework | Archetype-based ECS data library | Distributed graph-dynamical ABM framework |
| **Level** | High-level, opinionated | Low-level, data-oriented | Medium-level, graph-centric |
| **Paradigm** | `agent_step!` + `model_step!` loop | Entities + Components + Query systems | Synchronous Graph Dynamical Systems (SyGDS) |
| **Formal model** | Informal ABM | No formal model — ECS pattern | Rigorous SyGDS (generalizes Cellular Automata) |
| **Docs quality** | ✅ Excellent | ✅ Good | ✅ Good |
| **Maturity** | ✅ Very mature | ⚠️ Younger (active dev) | ⚠️ Younger (arXiv 2024) |
| **Community** | ✅ Large | ⚠️ Small | ⚠️ Small |

### 2.2 Core Architecture

#### Agents.jl
- Agents live in a **space** (grid, continuous 2D/3D, graph, or OSM)
- Each step: `agent_step!(agent, model)` called for every agent; then `model_step!(model)`
- Built-in **event queue** for continuous-time DES (Gillespie-style)
- **Ensemble runs** with `ensemblerun!` + `paramscan`

#### Ark.jl
- **World** = container for all entities
- **Entities** = opaque IDs
- **Components** = plain Julia structs attached to entities (`Position`, `Velocity`, `Mass`)
- **Archetypes** = auto-grouped entities with the same component mix → cache-efficient SoA layout
- **Queries** = iterate over all entities matching a component pattern
- **Events** = reactive observer system (fires on component add/remove/change), NOT a DES event queue
- **Batch operations** = SIMD-friendly bulk updates via `StructArray` views
- **GPU storage** = swap `Vector` for `GPUVector{:CUDA}` — same API

#### Vahana.jl
- **Simulation** = a typed graph: agents = vertices, interactions = directed edges
- **Transition function**: `f(agent, id, sim) → new_agent_state` (pure, functional)
- **Synchronous BSP updates**: all agents read from t, write to t+1 simultaneously
- **`add_graph!(sim, g, ...)`** = import any `Graphs.jl` graph directly
- **MPI**: just `mpirun -n N julia script.jl` — framework handles distribution transparently

### 2.3 Capability Matrix

#### Discrete Event Simulation (DES)

| Feature | **Agents.jl** | **Ark.jl** | **Vahana.jl** |
|---|---|---|---|
| **Built-in event queue** | ✅ Yes (Gillespie) | ❌ No | ❌ No |
| **Scheduled events** | ✅ Yes | ❌ DIY `PriorityQueue` | ❌ No (BSP only) |
| **Reactive events** | ⚠️ Limited | ✅ `EventRegistry`, Observers | ❌ No |
| **Time model** | Discrete tick OR continuous | DIY clock | Discrete synchronous ticks |
| **Process-oriented DES** | ❌ (use ConcurrentSim.jl) | ❌ | ❌ |
| **DES suitability** | ✅ **Best out-of-box** | ❌ Needs wrapper | ⚠️ Only if DES maps to BSP |

> **Key insight on Vahana.jl and DES**: BSP synchronous model is fundamentally at odds with DES where events have variable timestamps and must be processed in causal order.

#### Fluid / Hydraulic Dynamics

| Feature | **Agents.jl** | **Ark.jl** | **Vahana.jl** |
|---|---|---|---|
| **Particle agents (SPH/LBM)** | ✅ Possible | ✅ **Ideal** | ⚠️ Possible |
| **Scale to 1M+ particles** | ⚠️ Degrades | ✅ <1ns/entity at any scale | ⚠️ MPI helps |
| **Cache-efficient layout** | ❌ Array-of-structs | ✅ Archetype SoA | ⚠️ Unknown |
| **SIMD vectorization** | ❌ | ✅ Native via StructArray | ❌ |
| **GPU support** | ❌ | ✅ **Native** (`GPUVector{:CUDA}`) | ❌ |
| **Network hydraulics** (pipe graphs) | ✅ Graph space | ⚠️ DIY graph | ✅ **Natural fit** |

#### Parallelism

| Feature | **Agents.jl** | **Ark.jl** | **Vahana.jl** |
|---|---|---|---|
| **Ensemble (multi-run)** | ✅ Native `parallel=true` | N/A | N/A |
| **Single-model threading** | ⚠️ Manual, unsafe for add/remove | ⚠️ Manual `Threads.@threads` | ✅ Automatic |
| **GPU** | ❌ | ✅ **Native** | ❌ |
| **MPI / multi-node** | ❌ | ❌ | ✅ **Native** |
| **SIMD** | ❌ | ✅ StructArray → auto-vectorization | ❌ |

**Ark.jl Benchmark** (official docs): 10⁹ total position+velocity updates (1M entities × 1000 iterations):

| Backend | Time | Speedup |
|---|---|---|
| CPU, 1 core (Ryzen 5 5600H) | 7.37s | 1× |
| CPU, 6 cores (`Threads.@threads`) | 1.57s | 4.7× |
| **GPU (GTX 1650)** | **0.32s** | **23×** |

GPU requires only: `world = World(Position => Storage{GPUVector{:CUDA}}, ...)` — same query API.

### 2.4 API Style

```julia
# Ark.jl — ECS style
@component struct Position x::Float32; y::Float32 end
@component struct Velocity vx::Float32; vy::Float32 end

world = World()
for _ in 1:1_000_000
    create_entity!(world, Position(rand(), rand()), Velocity(0f0, 0f0))
end

q = query(world, Position, Velocity)
@threads for (pos, vel) in q
    pos.x += vel.vx * dt
    pos.y += vel.vy * dt
end
```

```julia
# Vahana.jl — graph style (good for pipe networks)
function flow_step(node, id, sim)
    neighbors = neighborstates(sim, id, Pipe, Fluid)
    pipes = edgestates(sim, id, Pipe)
    new_pressure = sum(n.pressure * p.conductance for (n,p) in zip(neighbors, pipes))
    Fluid(new_pressure / length(pipes), node.velocity)
end
apply!(sim, flow_step, [Fluid], [Fluid, Pipe], [Fluid])
```

### 2.5 Verdict

| Requirement | **Agents.jl** | **Ark.jl** | **Vahana.jl** |
|---|---|---|---|
| **DES event queue** | ✅ Built-in | ❌ DIY | ❌ Incompatible |
| **Fluid particles (SPH/LBM)** | ⚠️ Workable | ✅ **Optimal** | ⚠️ Possible |
| **Hydraulic pipe network** | ✅ Graph space | ⚠️ DIY | ✅ Natural fit |
| **Crowd dynamics (10k+ agents)** | ⚠️ Works, not GPU | ✅ **GPU-accelerated** | ❌ BSP mismatch |
| **GPU acceleration** | ❌ | ✅ Native | ❌ |
| **Rapid prototyping** | ✅ Fastest | ❌ Slowest | ⚠️ Medium |

> **✅ Recommended engine**: **Ark.jl** as the core ECS engine + a thin custom DES queue (20 lines, `DataStructures.PriorityQueue`). Use `Agents.jl` for fast prototyping, migrate hot paths to Ark.jl.

> [REVIEW NEEDED] §2: Do you agree with this framework verdict? Key decisions:
> - Use **Ark.jl** as the production engine (not Agents.jl)?
> - Build DES queue ourselves on top of Ark.jl?
> - Vahana.jl ruled out — agree?
>
> [COMMENT]: <!-- Add your comment here -->

---

## 3. Crowd Dynamics — New Module

### 3.1 Why Crowd Dynamics Belongs in This Platform

This addition is not just a feature bolt-on — it **deepens the coherence** of the whole platform:

1. **ABM is the natural computational model for crowds.** Each person = an agent with local behavioral rules. The existing ABM infrastructure (Ark.jl ECS) requires zero architectural change to support crowd agents.

2. **Crowd dynamics and fluid dynamics share deep mathematics.** This is not coincidental:
   - The **LWR model** (Lighthill-Whitham-Richards) treats crowds as a compressible fluid — same PDEs as gas dynamics.
   - **Hughes' model** uses the Eikonal equation to compute navigation potential fields, identical in structure to pressure field solvers.
   - **Consequence**: the GPU kernels and SoA data layouts built for fluid particles can be partially reused for macroscopic crowd flow models.

3. **Crowds + DES = the commercially valuable combination.** In AnyLogic and FlexSim, the highest-value use cases are:
   - Pedestrian flow in airports, train stations, shopping malls
   - Emergency evacuation modeling
   - Hospital patient routing
   - Venue capacity and safety planning
   
   These are DES scenarios where crowd agents are the "customers" moving through a system — events like *"evacuation alarm at t=120s"* or *"gate opens at t=30min"* control crowd behavior.

4. **No Julia crowd simulation library currently exists.** This is a genuine gap in the ecosystem and an opportunity for this platform to be novel.

### 3.2 Crowd Simulation Models to Support

#### Tier 1 — Microscopic (Agent-Based) Models

These are the core offering — each person is an individual agent:

| Model | Description | Complexity | Best For |
|---|---|---|---|
| **Social Force Model** (Helbing, 1995) | Agents follow attractive goal forces + repulsive social forces from other agents and walls | Medium | Dense crowds, panic evacuation, bottleneck studies |
| **ORCA / Velocity Obstacles** | Collision-free velocity planning — each agent independently avoids collisions | Medium | Sparse to medium density, robot crowd analogy |
| **Floor Field / Cellular Automata** | Grid-based; agents follow static/dynamic floor field with probability | Low | Large-scale evacuation, simple geometry |
| **Cognitive / BDI Models** | Agents with beliefs, desires, intentions — can pause, decide, change goal | High | Realistic behavioral modeling, complex decision points |

#### Tier 2 — Macroscopic (Fluid-Based) Models

Treat crowd density as a continuous field — useful for large-scale scenarios:

| Model | Description | Julia fit |
|---|---|---|
| **LWR Kinematic Wave** | 1D crowd flow as conservation law (traffic-like) | Excellent — standard PDE |
| **Hughes' Model** | 2D continuum crowd: density + Eikonal navigation potential | Medium — needs PDE solver |
| **Advection-Diffusion** | Simplified density spread model | Excellent — trivial to implement |

> **Key insight**: Macroscopic models can reuse your fluid simulation infrastructure directly. The LWR model shares numerics with hydraulic pipe flow.

#### Tier 3 — Hybrid Models (Long-term)

Combine microscopic agents in areas of interest (bottlenecks, evacuation doors) with macroscopic fields in open spaces. This is what commercial tools like Legion and Pathfinder do.

### 3.3 Ark.jl ECS Components for Crowd Agents

```julia
# Core kinematic state
@component struct Position      x::Float32; y::Float32         end
@component struct Velocity      vx::Float32; vy::Float32       end
@component struct Acceleration  ax::Float32; ay::Float32       end

# Behavioral state
@component struct Goal          target_x::Float32; target_y::Float32  end
@component struct DesiredSpeed  v0::Float32                           end  # preferred walking speed

# Social Force Model components
@component struct SocialForce   fx::Float32; fy::Float32       end  # repulsion from neighbors
@component struct WallForce     fx::Float32; fy::Float32       end  # repulsion from walls
@component struct PanicLevel    level::Float32                 end  # 0 = calm, 1 = full panic

# Classification
@component struct AgentType     type::UInt8                    end  # pedestrian, staff, VIP...
@component struct Group         group_id::UInt32               end  # group cohesion forces
```

This maps directly to Ark.jl's ECS — each component is a tight struct, stored in SoA layout for SIMD and GPU.

### 3.4 Social Force Model — GPU Implementation Sketch

The **Social Force Model** is the industry standard for microscopic crowd simulation. The force on agent `i` is:

```
F_i = F_goal + Σⱼ F_social(i,j) + Σ_w F_wall(i,w)
```

Where:
- `F_goal` — drives the agent toward their destination at desired speed
- `F_social(i,j)` — repulsive exponential from nearby agents (decays with distance)
- `F_wall` — repulsive from walls (same form as social force)

```julia
# GPU kernel — runs on all crowd agents simultaneously
function social_force_step!(world::World, dt::Float32)
    q = query(world, Position, Velocity, Goal, DesiredSpeed, SocialForce)
    
    @cuda threads=256 @kernel for (pos, vel, goal, ds, sf) in q
        # Goal force: drive toward destination
        dx_goal = goal.target_x - pos.x
        dy_goal = goal.target_y - pos.y
        dist_goal = sqrt(dx_goal^2 + dy_goal^2)
        e_x, e_y = dx_goal/dist_goal, dy_goal/dist_goal  # unit vector to goal
        
        # F_goal = (desired_velocity - current_velocity) / τ
        f_goal_x = (ds.v0 * e_x - vel.vx) / 0.5f0
        f_goal_y = (ds.v0 * e_y - vel.vy) / 0.5f0
        
        # Social forces from neighbors (inner loop — O(N²), use spatial hash)
        # ... (neighbor queries via spatial grid)
        
        # Euler integration
        vel.vx += (f_goal_x + sf.fx) * dt
        vel.vy += (f_goal_y + sf.fy) * dt
        pos.x  += vel.vx * dt
        pos.y  += vel.vy * dt
    end
end
```

> **Performance note**: The O(N²) neighbor loop is the bottleneck. A spatial hash grid (cell list) reduces this to O(N·k) where k = average neighbors in radius. This maps well to GPU shared memory.

### 3.5 DES Integration with Crowd Events

Crowds in real scenarios are triggered by discrete events — this is exactly where DES + crowd dynamics merge:

```julia
# Crowd events handled by the DES engine
abstract type CrowdEvent end

struct EvacuationAlarm  <: CrowdEvent; zone::Int; severity::Float32 end
struct GateOpen         <: CrowdEvent; gate_id::Int; capacity::Int  end
struct CrowdSourceSpawn <: CrowdEvent; rate::Float32; location::NTuple{2,Float32} end
struct BottleneckClosed <: CrowdEvent; node_id::Int                end

# Schedule from DES queue
schedule_event!(sim, EvacuationAlarm(zone=3, severity=0.9), at_time=120.0)
schedule_event!(sim, GateOpen(gate_id=5, capacity=200),     at_time=30.0)
```

When a `EvacuationAlarm` fires, the DES engine updates crowd agent `Goal` components (new exit targets) and `PanicLevel` components — the social force computation automatically responds next GPU step.

### 3.6 Navigation: Floor Fields and Potential Maps

For large environments, agents need to navigate around obstacles without global path knowledge. The standard approach:

1. **Offline**: Precompute a **navigation potential field** (Eikonal equation) per exit — gives every grid cell a distance-to-exit value
2. **Online**: Each agent follows the gradient of the field (descend toward exit)

```julia
# Precompute navigation potential using Fast Marching Method
using EikonalSolvers  # or custom GPU implementation
potential_field = solve_eikonal(environment_grid, exit_nodes)

# Each agent queries gradient at their position
@component struct NavigationPotential
    field_ref::Int  # which potential field (which exit) this agent is targeting
end
```

This scales to hundreds of thousands of agents with no per-agent pathfinding cost.

### 3.7 Crowd ↔ Fluid Analogy: Shared Infrastructure

| Crowd Model Component | Fluid Equivalent | Shared Code? |
|---|---|---|
| Agent position/velocity | Particle position/velocity | ✅ Same ECS components |
| Social force repulsion | Particle pressure | ✅ Same kernel structure |
| Navigation potential field | Pressure field / velocity potential | ✅ Same PDE solver |
| LWR density flow | Pipe network hydraulics | ✅ Same conservation law numerics |
| Exit capacity constraint | Valve/orifice flow restriction | ✅ Same DES event type |
| Panic level (density > threshold) | Cavitation / overflow | ✅ Same threshold trigger |

This shared infrastructure is a key architectural advantage — the crowd module is not a separate subsystem but a **semantic specialization** of the existing fluid + DES engine.

### 3.8 Crowd Simulation Libraries Survey

| Library | Language | Model | Notes |
|---|---|---|---|
| **Legion** | C++ (commercial) | Microscopic + macroscopic hybrid | Used in airport/rail planning |
| **Pathfinder** | C++ (commercial) | SFPE-based evacuation | Fire safety engineering standard |
| **SUMO** (crowd mode) | C++ (open) | Microscopic (pedestrians + vehicles) | Used for urban simulation |
| **MassMotion** | C++ (commercial) | Microscopic ABM | Architecture/venue planning |
| **Agents.jl** | Julia (open) | ABM, continuous space | No GPU, but good prototyping |
| **CrowdSim (ours)** | Julia (new) | Social Force + ORCA + LWR | GPU via Ark.jl — **this is the gap to fill** |

> **Opportunity**: There is no GPU-accelerated, open-source crowd simulator in Julia. Building this as a module of our platform addresses a real ecosystem need.

### 3.9 Crowd Module Roadmap

| Phase | Features | Effort |
|---|---|---|
| **Phase 1** | Social Force Model, CPU, WGLMakie visualization, <1000 agents | ~1 week |
| **Phase 2** | GPU via Ark.jl CUDA backend, spatial hash grid, 10k–100k agents | ~2 weeks |
| **Phase 3** | Navigation potential fields (Eikonal), multi-exit routing | ~1 week |
| **Phase 4** | DES event integration (alarms, gates, spawners) | ~1 week |
| **Phase 5** | Macroscopic LWR model, crowd ↔ fluid shared solver | ~2 weeks |
| Phase 6 — GUI elements | React Flow GUI elements (Spawn Source, Exit, Obstacle, Gate) | ~1 week |

> [REVIEW NEEDED] §3 Crowd Dynamics: Several key decisions need your input:
> - Which crowd model to start with? Social Force Model (recommended) or simpler Cellular Automata?
> - 2D only, or do we need 3D (multi-floor buildings)?
> - Is this for evacuation safety, venue planning, or general-purpose?
> - Should the crowd module be a physics simulation or just animated icons following routes?
>
> [COMMENT]: <!-- Add your comment here -->

---

## 4. Visualization & GUI Architecture

> *Revised decision: **Desktop-first**. Build a native desktop application first, ship to web later. This is the correct order — every major simulation tool (AnyLogic, FlexSim, Arena, Simul8) did exactly this.*

---

### 4.1 Why Desktop-First is the Right Decision

| Reason | Detail |
|---|---|
| **Industry precedent** | AnyLogic, FlexSim, Arena, Simul8, Witness — all desktop-first. Web came years later, if ever. |
| **Simpler architecture** | No WebSocket serialization bottleneck, no CORS, no browser security sandbox. Julia talks directly to the UI layer. |
| **GLMakie works today** | Already in the stack. 50–200k agents at 60fps, OpenGL-native. Start this week. |
| **Native performance** | No 72MB/sec WebSocket ceiling. Local IPC or shared memory is effectively unlimited. |
| **File system access** | Import CAD floor plans, save model files, export results — natural on desktop, painful in browser. |
| **Target users expect it** | Industrial simulation users (logistics, manufacturing, healthcare) work in desktop tools. |
| **Web comes free from desktop** | Godot 4 → WASM export is a checkbox. The reverse path is a rewrite. |

---

### 4.2 The Two Distinct UI Problems (Still Applies)

Desktop or web, we still need to solve two different editor problems:

```
PROBLEM 1: Process Logic Editor          PROBLEM 2: Physical Space Editor
────────────────────────────────         ────────────────────────────────
Shows HOW entities flow                  Shows WHERE things are
Node graph: Queue → Server → Exit        Floor plan: rooms, corridors, walls
Abstract topology / connectivity         Physical geometry / spatial layout

AnyLogic: the flowchart panel            AnyLogic: the space markup panel
```

And layered over both:

```
PROBLEM 3: Real-Time Simulation Canvas
───────────────────────────────────────────────────────────
100k+ agents moving in real-time at 60fps
Color-coded by state (panic, speed, queue depth)
Rendered on top of the physical layout
```

---

### 4.3 Desktop-First Phase Plan

```
Phase 1 (Now — weeks 1–2)
────────────────────────────────────────────────────────────────
GLMakie desktop window
  • Hardcoded simulation layout (no editor yet)
  • Real-time scatter/meshscatter animation
  • DES event overlay, statistics panel
  • 50–100k agents at 60fps
  • Julia controls simulation directly (no IPC)
  • Goal: validate the simulation engine with visual output

Phase 2 (Weeks 3–8)
────────────────────────────────────────────────────────────────
Godot 4 desktop application (Julia backend via local WebSocket)
  • Godot scene editor = physical layout editor (drag-and-drop, FREE)
  • MultiMeshInstance2D/3D = 500k+ agents at 60fps
  • Julia streams sim state over localhost WebSocket at 60Hz
  • Process logic editor: custom Godot plugin (node graph)
  • Export: Windows, Mac, Linux from same codebase
  • Goal: functional simulation editor + visualization desktop app

Phase 3 (Months 3–6)
────────────────────────────────────────────────────────────────
Web deployment from the same codebase
  Option A: Godot 4 → WASM export (browser, same project)
  Option B: React + Konva + PixiJS (purpose-built web stack)
  Both remain viable — decision at Phase 3 based on requirements
```

---

### 4.4 Phase 1: GLMakie Desktop (Start This Week)

GLMakie is the fastest path to a working visual simulation. You already have it.

**What GLMakie gives you for free on desktop**:
- `scatter!` / `meshscatter!` with `Observable` → surgical GPU updates, no full redraw
- Native OpenGL window, no browser, no WebSocket, no overhead
- Makie's `Axis` + `Figure` layout system for multi-panel dashboards
- `on(mouse_event)` for basic click interaction
- `GLMakie.Screen` with resizable window

**Performance reality on desktop (GLMakie)**:
- 50k agents with `meshscatter!` + Observable: **smooth 60fps**
- 100k agents: **30–60fps** depending on GPU
- 200k agents: **15–30fps** — needs optimization (instanced rendering via `meshscatter!` with matrix buffer)
- 500k+: Use Godot 4 instead

```julia
using GLMakie, Observables

# Phase 1 visualization — entire sim loop in Julia, no IPC
positions  = Observable(rand(Point2f, 10_000))
colors     = Observable(fill(:cyan, 10_000))   # encode agent state
panic_vals = Observable(zeros(Float32, 10_000))

fig = Figure(size=(1400, 900), backgroundcolor=:black)
ax  = Axis(fig[1,1], aspect=DataAspect(),
           backgroundcolor=RGBf(0.05, 0.05, 0.1),
           title="Simulation Platform — Phase 1")

# meshscatter = one draw call for all agents (instanced rendering)
meshscatter!(ax, positions,
    color=panic_vals,
    colormap=:RdYlGn_r,    # green=calm, red=panic
    colorrange=(0f0, 1f0),
    markersize=0.5)

# Stats panel
stats_text = Observable("t = 0.0s | agents = 10,000 | events/s = 0")
Label(fig[2,1], stats_text, color=:white, fontsize=14)

display(fig)

# Simulation loop — runs in Julia, updates Observables
@async begin
    t = 0.0
    while isopen(fig.scene)
        # Step simulation (Ark.jl ECS + DES engine)
        step_simulation!(world, des_queue, t, dt=0.05)
        t += 0.05

        # Update observables → triggers GLMakie GPU buffer update
        positions[]  = get_positions(world)
        panic_vals[] = get_panic_levels(world)
        stats_text[] = "t = $(round(t, digits=1))s | agents = $(nagents(world))"

        sleep(1/60)   # throttle to 60fps
    end
end
```

**Phase 1 desktop window layout** (no external dependencies):
```
┌──────────────────────────────────────────────────────────────────┐
│  GLMakie Window                                                  │
│ ┌────────────────────────────────────┐ ┌──────────────────────┐ │
│ │  Simulation Canvas                 │ │  Statistics Panel    │ │
│ │  GLMakie Axis (OpenGL)             │ │  Queue depths        │ │
│ │  meshscatter! for agents           │ │  Throughput          │ │
│ │  heatmap! for density overlay      │ │  Event log           │ │
│ │  lines! for flow paths             │ │  DES event timeline  │ │
│ └────────────────────────────────────┘ └──────────────────────┘ │
│ ┌────────────────────────────────────────────────────────────────┤
│ │  Controls: [▶ Run] [⏸ Pause] [⏭ Step] [Speed: 1.0x] [Reset]  │
│ └────────────────────────────────────────────────────────────────┘
└──────────────────────────────────────────────────────────────────┘
```

Even this simple layout gives you a working simulation sandbox to validate the engine.

---

### 4.5 Phase 2: Godot 4 Desktop Application

Godot 4 is the right tool for the production desktop app. Here is why it solves all three UI problems:

#### Problem 1 solved: Physical Layout Editor
Godot's **scene editor** IS the physical layout editor. You define custom `Node2D` types for each simulation element (Queue, Server, CrowdSource, Exit, Pipe, Valve). The user drags them onto the canvas from a panel, positions them, and sets properties in Godot's inspector. **This functionality exists in Godot out of the box — you are not building a drag-and-drop editor, you are configuring Godot's existing one.**

```
Godot Scene Editor:
┌──────────────────────────────────────────────────────────────────┐
│  [Element Library]  [Main Canvas]                  [Inspector]   │
│  ─────────────────  ────────────────────────────  ───────────── │
│  📦 Queue           ┌──────────────────────────┐  Queue Node    │
│  🔧 Server          │  [Receiving]              │  Capacity: 50  │
│  👤 CrowdSource     │     ↓                     │  Discipline:   │
│  🚪 Exit            │  [Conveyor A]─[Sort]      │    FIFO        │
│  🔵 Pipe            │     ↓           ↓         │  Service rate: │
│  🔴 Valve           │  [Pack]      [Pack B]     │    Exp(2.5)    │
│  💧 Reservoir       │     ↓           ↓         │                │
│  🚨 Evac Zone       │  [Staging]────────────▶  │                │
│                     └──────────────────────────┘                │
└──────────────────────────────────────────────────────────────────┘
```

#### Problem 2 solved: Real-Time Simulation Canvas
Godot's `MultiMeshInstance2D` renders 500k+ agents in one GPU draw call. The Julia backend streams positions over a local WebSocket at 60Hz. Godot updates the `MultiMesh` buffer directly.

```gdscript
# Godot 4 GDScript — receives Julia sim state and renders agents
extends Node

var socket := WebSocketPeer.new()
var agent_mesh : MultiMeshInstance2D

func _ready():
    socket.connect_to_url("ws://localhost:8765")
    agent_mesh = $AgentMultiMesh

func _process(_delta):
    socket.poll()
    while socket.get_available_packet_count() > 0:
        var data = socket.get_packet()
        var state = JSON.parse_string(data.get_string_from_utf8())
        _update_agents(state["crowd"])

func _update_agents(agents: Array):
    agent_mesh.multimesh.instance_count = agents.size()
    for i in agents.size():
        var a = agents[i]
        var xform = Transform2D(0.0, Vector2(a["x"], a["y"]))
        agent_mesh.multimesh.set_instance_transform_2d(i, xform)
        # Color by panic level
        var c = Color.from_hsv(0.33 - a["panic"] * 0.33, 1.0, 1.0)
        agent_mesh.multimesh.set_instance_color(i, c)
```

#### Problem 3 solved: Process Logic Editor
Godot has a **visual scripting / node graph** system. We can build a custom `GraphEdit` node (built into Godot 4) for the process logic editor — a native node graph editor with typed ports, connections, and custom node types.

```
Godot GraphEdit (built-in, customizable):
  [Source] ──▶ [Queue (cap=50)] ──▶ [Server (rate=2.5)] ──▶ [Sink]
      ↑                                                         ↑
  CrowdSource                                               Statistics
```

This is Godot's `GraphEdit` + `GraphNode` — no external library needed.

#### Julia ↔ Godot 4 Communication

```
Julia Process (simulation engine)          Godot 4 Process (desktop app)
──────────────────────────────────         ──────────────────────────────
Ark.jl ECS world                           Scene editor (layout)
DES event queue                            MultiMesh (agent rendering)
SimClock (speed control)                   GraphEdit (process logic)
Oxygen.jl WebSocket server                 WebSocketPeer client
        │                                          │
        └──────── localhost:8765 ─────────────────┘
                  (MessagePack binary)
                  ~1–5 MB/sec for 100k agents
```

**Why localhost WebSocket and not something faster?**

For desktop, we could use shared memory (Julia's `SharedArrays`) or a named pipe for even lower latency. However, localhost WebSocket:
- Works on all platforms (Windows, Mac, Linux) without OS-specific code
- Decouples Julia and Godot processes (either can restart independently)
- Same protocol reused for web deployment (no code change in Julia)
- Handles the bandwidth easily — 100k agents at 60fps ≈ 3–5 MB/sec, well within localhost limits

---

### 4.6 Godot 4 vs GLMakie: When to Switch

| Scenario | Use GLMakie | Use Godot 4 |
|---|---|---|
| **Validating sim logic** | ✅ Fastest | — |
| **Agents < 100k, 2D only** | ✅ Works well | Optional |
| **Agents > 100k** | ⚠️ Slow | ✅ Required |
| **Drag-and-drop layout editor** | ❌ | ✅ Built-in |
| **3D facility models** | ❌ | ✅ Vulkan 3D |
| **Production desktop app** | ❌ | ✅ |
| **Export to web** | ❌ | ✅ WASM export |
| **Custom UI panels** | ⚠️ Limited | ✅ Full GUI system |

**Transition trigger**: move from GLMakie → Godot 4 when you need the layout editor, or when agent count exceeds 100k.

---

### 4.7 Makie's Correct Role: Results Analysis

Makie (both GLMakie and WGLMakie) remains excellent for what it was designed for — **scientific output analysis**, not real-time animation:

```julia
# Post-simulation analysis — Makie shines here
fig = Figure(size=(1600, 1000))

# Queue occupancy over time
ax1 = Axis(fig[1,1], title="Queue Depths Over Time")
for (name, ts, qs) in queue_history
    lines!(ax1, ts, qs, label=name)
end
axislegend(ax1)

# Agent density heatmap
ax2 = Axis(fig[1,2], title="Crowd Density Map", aspect=DataAspect())
heatmap!(ax2, density_grid, colormap=:hot)

# Throughput histogram
ax3 = Axis(fig[2,1], title="Service Time Distribution")
hist!(ax3, service_times, bins=50, color=:steelblue)

# Event timeline
ax4 = Axis(fig[2,2], title="DES Event Timeline")
scatter!(ax4, event_times, event_types_coded, markersize=4)
```

This is Makie's sweet spot — keep it for the analysis dashboard, not the live simulation.

---

### 4.8 Web Path (Phase 3 — Later)

When web deployment is needed, two paths remain open:

**Option A — Godot 4 WASM** (same codebase):
- Export button in Godot editor → WASM bundle
- Deploy to any static hosting (GitHub Pages, Netlify, S3)
- Julia runs as a separate server; WASM Godot connects via WebSocket
- Same GDScript code runs — no rewrite
- Limitation: WASM Godot is slightly slower than native; initial download ~30MB

**Option B — Purpose-built Web Stack** (React + Konva + PixiJS):
- React Flow (process logic editor) + Konva.js (physical layout) + PixiJS v8 (simulation canvas)
- Better for SaaS web product (lighter, browser-native)
- Julia backend unchanged — same WebSocket protocol
- Requires separate web frontend development effort

**Decision at Phase 3** — both paths are valid. The simulation engine (Julia) is identical for both. The protocol (WebSocket + MessagePack) is identical. Only the frontend changes.

---

### 4.9 Full Technology Stack Summary (Desktop-First)

```
┌──────────────────────────────────────────────────────────────────────┐
│  PHASE 1 — DESKTOP (GLMakie)                                         │
│  Julia simulation engine + GLMakie window                            │
│  No IPC, no editor — pure sim validation                             │
│  Start: this week                                                    │
├──────────────────────────────────────────────────────────────────────┤
│  PHASE 2 — DESKTOP APP (Godot 4)                                     │
│                                                                      │
│  Godot 4 (MIT)                Julia backend                          │
│  ├── Scene Editor             ├── Ark.jl ECS (crowd + fluid)         │
│  │   Physical layout          ├── DES engine (per-LP PDES)           │
│  ├── GraphEdit                ├── SimClock (speed control)           │
│  │   Process logic            └── Oxygen.jl WebSocket server         │
│  ├── MultiMeshInstance2D/3D       ↕ localhost:8765 (MessagePack)     │
│  │   500k+ agents 60fps                                              │
│  └── Export: Win/Mac/Linux/WASM                                      │
│  Start: Week 3                                                       │
├──────────────────────────────────────────────────────────────────────┤
│  PHASE 3 — WEB DEPLOYMENT (when needed)                              │
│  Option A: Godot 4 WASM export (same codebase, browser)             │
│  Option B: React + Konva.js + PixiJS v8 (purpose-built web)         │
│  Julia backend: unchanged in both cases                              │
│  Start: Month 3–6                                                    │
├──────────────────────────────────────────────────────────────────────┤
│  THROUGHOUT — ANALYSIS (GLMakie / WGLMakie)                          │
│  Post-simulation output plots, heatmaps, histograms                  │
│  Parameter sweep visualization, results comparison                   │
└──────────────────────────────────────────────────────────────────────┘
```

---

### 4.10 Element Library (Platform-Agnostic)

The element vocabulary is the same whether rendered in Godot, PixiJS, or GLMakie:

| Category | Element | Physical placement | Process logic |
|---|---|---|---|
| **DES** | Source | ✅ (where entities enter) | ✅ (arrival rate, schedule) |
| **DES** | Queue | ✅ | ✅ (capacity, discipline) |
| **DES** | Server/Resource | ✅ | ✅ (service time, count) |
| **DES** | Router | ❌ abstract | ✅ (condition, probability) |
| **DES** | Sink | ✅ | ✅ (stats collection) |
| **Fluid** | Pipe segment | ✅ | ✅ (diameter, roughness) |
| **Fluid** | Valve | ✅ | ✅ (Kv, open/close) |
| **Fluid** | Reservoir | ✅ | ✅ (head, volume) |
| **Crowd** | Pedestrian Source | ✅ (physical door) | ✅ (spawn rate, profile) |
| **Crowd** | Exit | ✅ (physical door) | ✅ (width, capacity) |
| **Crowd** | Obstacle/Wall | ✅ (geometry) | — |
| **Crowd** | Gate | ✅ | ✅ (DES-triggered open/close) |
| **Crowd** | Evac Trigger | ✅ (zone) | ✅ (alarm, severity) |

---

### 4.11 WebSocket Protocol (Unchanged for Desktop and Web)

**Julia → Frontend (60fps)**:
```
MessagePack binary frame:
{
  t: Float64,          // simulated time
  frame: UInt64,       // frame counter
  crowd: [{id, x, y, state, panic}...],   // crowd agents
  fluid: [{id, x, y, pressure, v}...],   // fluid particles
  des:  {queues: {id: {len, util}}...}   // DES statistics
}
```
*MessagePack binary: ~5× smaller than JSON. At 100k agents: ~2MB/frame → 120MB/sec at 60fps. Compress with delta encoding (send only changed positions) → ~5–10MB/sec realistic throughput.*

**Frontend → Julia (on layout change or control event)**:
```json
{
  "layout": {
    "nodes": [{"id": "n1", "type": "Queue", "x": 10, "y": 5, "params": {}}],
    "walls": [{"x1": 0, "y1": 0, "x2": 100, "y2": 0}],
    "edges": [{"from": "n1", "to": "n2"}]
  },
  "clock": {"speed": 1.0, "command": "play"},
  "view":  {"zoom": 1.5, "pan_x": 50, "pan_y": 25}
}
```

> [REVIEW NEEDED] §4 — Desktop-first confirmed:
> - **Phase 1**: GLMakie desktop, hardcoded layout, validate simulation engine. Can start immediately.
> - **Phase 2**: Godot 4 desktop app. Julia backend via localhost WebSocket.
> - **Phase 3**: Web deployment — Godot WASM or React+PixiJS (decision later).
>
> Questions for you:
> 1. Do you have any Godot experience, or is it new? (affects how we scope Phase 2)
> 2. For Phase 1, should we build the GLMakie prototype around a specific scenario (e.g., simple queueing network, basic crowd evacuation room)?
> 3. 2D only for now, or do we want 3D facility geometry from Phase 2?
>
> [COMMENT]: <!-- Add your answers here -->

---
## 5. Unified System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        SIMULATION PLATFORM                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│  FRONTEND (TypeScript / React)                                              │
│  ├── React Flow        — drag-and-drop layout editor (DES + Fluid + Crowd) │
│  ├── PixiJS v8         — real-time WebGPU simulation animation              │
│  ├── shadcn/ui         — property inspector panels, element library         │
│  └── WebSocket client  — receives sim state from Julia at 60fps             │
├─────────────────────────────────────────────────────────────────────────────┤
│  BACKEND (Julia)                                                            │
│  ├── Oxygen.jl / HTTP.jl  — REST API + WebSocket server                    │
│  │                                                                          │
│  ├── ── DES ENGINE ─────────────────────────────────────────────────────── │
│  │   PriorityQueue{(EntityId, EventType), Float64}                         │
│  │   Event types: Arrival, ServiceComplete, GateOpen, EvacuationAlarm      │
│  │                                                                          │
│  ├── ── FLUID MODULE ───────────────────────────────────────────────────── │
│  │   Ark.jl ECS: Position, Velocity, Pressure, Density (GPU storage)       │
│  │   SPH / LBM kernels → CUDA.jl + KernelAbstractions.jl                  │
│  │   Pipe network solver → Graphs.jl + sparse linear algebra               │
│  │                                                                          │
│  ├── ── CROWD MODULE ───────────────────────────────────────────────────── │
│  │   Ark.jl ECS: Position, Velocity, Goal, SocialForce, PanicLevel        │
│  │   Social Force Model → GPU kernel (spatial hash neighbor lookup)        │
│  │   Navigation: Eikonal potential fields per exit                         │
│  │   Macroscopic fallback: LWR model (shared numerics with fluid)          │
│  │   DES coupling: EvacuationAlarm → update Goal + PanicLevel components   │
│  │                                                                          │
│  └── ── SHARED INFRASTRUCTURE ─────────────────────────────────────────── │
│      Ark.jl World — single ECS world holding all entity types              │
│      CUDA.jl / KernelAbstractions.jl — GPU compute                        │
│      DataStructures.jl — PriorityQueue for DES                             │
│      WGLMakie.jl / Bonito.jl — Phase 1 real-time visualization            │
│      DataFrames.jl / Statistics.jl — output analysis                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.1 Shared ECS World Layout

All three simulation domains live in the **same Ark.jl World**, differentiated by components:

| Entity Tag Component | Domain | Additional Components |
|---|---|---|
| `DESAgent` | Queue/server customer | `ArrivalTime`, `ServiceTime`, `CurrentQueue` |
| `FluidParticle` | SPH/LBM particle | `Position`, `Velocity`, `Pressure`, `Density`, `Mass` |
| `CrowdAgent` | Pedestrian | `Position`, `Velocity`, `Goal`, `SocialForce`, `PanicLevel`, `Group` |
| `PipeNode` | Hydraulic network node | `Pressure`, `FlowRate`, `NodeType` |
| `CrowdObstacle` | Wall / barrier | `Geometry`, `WallForce` |

Queries isolate domains:
```julia
# Only crowd agents
q_crowd = query(world, CrowdAgent, Position, Velocity, SocialForce)

# Only fluid particles
q_fluid = query(world, FluidParticle, Position, Velocity, Pressure, Density)

# Mixed: crowd agents near pipe nodes (e.g., people near leaking pipe)
q_mixed = query(world, CrowdAgent, Position) & near(query(world, PipeNode), radius=5.0)
```

### 5.2 Simulation Step Loop

```julia
function sim_step!(world::World, des_queue, t::Float64, dt::Float64)
    # 1. Process all DES events due at time t
    while !isempty(des_queue) && peek(des_queue).time <= t
        event = dequeue!(des_queue)
        dispatch_des_event!(world, event, t)
    end
    
    # 2. Fluid physics step (GPU)
    fluid_step!(world, dt)          # SPH/LBM kernel
    hydraulic_network_step!(world)  # pipe solver
    
    # 3. Crowd physics step (GPU)
    compute_social_forces!(world)   # Social Force Model kernel
    crowd_integrate!(world, dt)     # Euler integration
    
    # 4. Collect statistics
    record_statistics!(world, t)
    
    # 5. Notify frontend (WebSocket)
    push_state_to_frontend!(world, t)
end
```

---


## 6. Open-Source Reference Implementations

> *This section surveys major parallel, scalable, open-source DES and ABM frameworks. The goal is to learn from their design decisions — especially event scheduling — and borrow ideas for our Julia implementation.*

### 6.1 Overview Table

| Library | Language | Parallelism | Scale | Domain | License | Key Insight for Us |
|---|---|---|---|---|---|---|
| **ROSS** | C | MPI (optimistic Time Warp) | ~2M cores, 500B events/sec | General PDES | MIT | Reverse computation instead of state-saving |
| **FLAME GPU 2** | CUDA C++ / Python | GPU (CUDA) | 100M+ agents | General ABM | AGPL / Commercial | GPU agent function dispatch pattern |
| **Repast HPC** | C++ | MPI (conservative) | Cluster-scale | General ABM | BSD | Context+Projection model, clean agent API |
| **OMNeT++** | C++ | Thread + MPI | Large networks | Network / DES | Academic free | Message-passing event model, hierarchical modules |
| **SimGrid** | C++ / Python | MPI + Threads | Cluster | Distributed systems | LGPL | Platform model abstraction, SimDAG for DAG tasks |
| **Warped2** | C++ | MPI + Pthreads | Cluster | General PDES | MIT | Time Warp with lazy cancellation; configurable optimizations |
| **ADEVS** | C++ | POSIX Threads | Shared memory | DEVS formalism | MIT | Rigorous DEVS math; hierarchical model composition |

---

### 6.2 ROSS — Rensselaer's Optimistic Simulation System

**GitHub**: `ROSS-org/ROSS` | **Language**: C (C11) | **License**: MIT

**What it is**: The gold standard for extreme-scale parallel DES. Used by US national labs (Sandia, ANL) for simulating systems at supercomputer scale.

**Performance numbers**:
- Scales to **~2,000,000 processor cores** (MPI)
- Processes **>500 billion events/second** (PHOLD benchmark)
- Powers **CODES** framework (billion-node network topologies) and **NeMo** (8M+ neuromorphic cores)

**Key design decisions to learn from**:

1. **Reverse Computation instead of state saving**  
   Most Time Warp systems checkpoint agent state before each event, then restore from checkpoint on rollback. ROSS instead requires the modeler to write a *reverse event handler* that "undoes" an event mathematically. This eliminates memory overhead from state saving at the cost of modeler discipline.
   
   ```c
   // ROSS pattern: forward event + reverse event as a pair
   void server_event(server_state *s, tw_bf *bf, event_msg *msg, tw_lp *lp) {
       // forward: process arrival
       bf->c0 = (s->queue_length == 0);  // save branch decision in bitfield
       s->queue_length++;
       if (bf->c0) schedule_service(lp, msg);
   }
   
   void server_event_reverse(server_state *s, tw_bf *bf, event_msg *msg, tw_lp *lp) {
       // reverse: undo the above
       s->queue_length--;
       if (bf->c0) cancel_service(lp);  // reverse the conditional branch
   }
   ```
   
   **Julia translation**: In our DES engine, if we go optimistic (Time Warp), we should define `forward_event!` / `reverse_event!` function pairs for each event type rather than saving whole-world snapshots.

2. **Logical Processes (LPs) as the unit of parallelism**  
   Each ROSS LP = one simulation entity (a queue, a server, a router). LPs run independently; events are messages between LPs. This maps directly to our ECS entities — each `EntityId` can be an LP.

3. **GVT (Global Virtual Time) for memory reclamation**  
   ROSS computes GVT periodically to determine what checkpoint data can be safely freed ("fossil collection"). This is the parallel equivalent of advancing the simulation clock.

**Relevance to our project**: If we ever need distributed-scale DES (thousands of servers, city-scale crowd evacuation across MPI nodes), ROSS's Time Warp + reverse computation pattern is the architecture to follow. For single-machine, single-GPU simulation, ROSS is overkill.

---

### 6.3 FLAME GPU 2

**GitHub**: `FLAMEGPU/FLAMEGPU2` | **Language**: CUDA C++ + Python 3 | **License**: AGPL-3.0 / Commercial

**What it is**: The most directly relevant framework to our use case. GPU-accelerated ABM using CUDA, capable of 100M+ agents. Developed at University of Sheffield; used in tumor biology, epidemiology, traffic.

**Key design decisions to learn from**:

1. **Agent function dispatch on GPU**  
   FLAME GPU compiles user-defined agent functions into CUDA kernels at model definition time. Each agent type has named functions that fire in a defined order per simulation step:
   
   ```python
   # FLAME GPU 2 Python API — defines agent behavior
   pedestrian = model.newAgent("Pedestrian")
   pedestrian.newVariable("x", float)
   pedestrian.newVariable("y", float)
   pedestrian.newVariable("panic", float, 0.0)
   
   # Agent function — compiled to CUDA kernel
   move_fn = pedestrian.newRTCFunction("move", move_agent_source)
   move_fn.setInitialState("default")
   move_fn.setEndState("default")
   
   # Execution order
   layer1 = model.newLayer()
   layer1.addAgentFunction(move_fn)
   ```
   
   **Julia translation**: In Ark.jl, our ECS queries play the same role — each `query(world, CrowdAgent, Position, ...)` maps to a CUDA kernel dispatch. The key insight is that **agent functions are layered** — execution order matters and is explicit.

2. **Message passing between agents (not shared memory)**  
   FLAME GPU uses a message list abstraction: agents output messages (e.g., position), other agents read nearby messages (spatial filtering). This avoids race conditions without locking.
   
   ```python
   # Agent outputs position message
   location_msg = model.newMessageSpatial2D("location")
   location_msg.newVariable("id", int)
   location_msg.setRadius(interaction_radius)
   ```
   
   **Julia translation**: This is equivalent to our spatial hash grid for Social Force Model neighbor lookup. Instead of direct memory access, we can implement a GPU-friendly message buffer per agent.

3. **Ensemble / parameter sweep natively supported**  
   FLAME GPU supports running multiple model instances simultaneously on one GPU — critical for parameter optimization and Monte Carlo analysis.

**Relevance**: FLAME GPU 2's Python API and agent function → CUDA kernel compilation pipeline is the best reference for how to structure Ark.jl GPU kernels for crowd and fluid agents. Study its `examples/pedestrian_navigation/` on GitHub directly.

---

### 6.4 Repast HPC

**GitHub**: `Repast/repast.hpc` | **Language**: C++ + Boost | **License**: BSD

**What it is**: The HPC (High Performance Computing) variant of the Repast ABM suite from Argonne National Laboratory. Uses MPI for distributed-memory parallelism across clusters.

**Key design decisions to learn from**:

1. **Context + Projection abstraction**  
   Repast organizes agents in a *Context* (a set of agents) and places them in *Projections* (Grid, ContinuousSpace, Network). This cleanly separates "what agents exist" from "where they are" — exactly the separation ECS provides.

2. **Ghost agents for boundary communication**  
   When an agent near a process boundary interacts with agents on another process, Repast creates read-only *ghost copies* of those agents locally. The real agent is updated by its owning process, then ghosts are synchronized.
   
   **Julia translation**: If we ever parallelize crowd simulation across multiple CPU threads or processes, the ghost agent pattern is the right approach for spatial boundary agents.

3. **`Repast4Py`** — newer Python successor, uses `mpi4py`  
   The Python API is cleaner and worth reading for API design inspiration even if we use Julia.

**Relevance**: Repast HPC is a good reference for **spatial decomposition** parallelism (§1 of our parallel DES section). The ghost agent synchronization pattern is directly applicable when we partition a large environment into regions.

---

### 6.5 OMNeT++

**Website**: omnetpp.org | **Language**: C++ | **License**: Academic free / Commercial

**What it is**: Extremely mature (1992–present), modular, component-based DES framework. Primarily used for network simulation (INET framework), but the engine is domain-agnostic. Widely used in academia and industry.

**Key design decisions to learn from**:

1. **Hierarchical module composition**  
   OMNeT++ models are hierarchical: a `Network` contains `Hosts`, each `Host` contains `Queue` and `Server` modules. Modules communicate only via *gates* and *messages* — no direct field access.
   
   **Julia translation**: This maps to our React Flow node graph. Each dragged element (Queue, Server, Pipe) is a module. Connections between nodes are gates/channels. The OMNeT++ NED language (Network Description) is the inspiration for our JSON layout schema.

2. **Future Event Set (FES) = calendar queue**  
   OMNeT++'s internal event queue uses a **calendar queue** (bucket-based, ~O(1) amortized). This is one of the fastest known structures for simulation event queues with uniformly-distributed event times — much faster than binary heap at large scale.

3. **Event granularity**: OMNeT++ schedules `cMessage` objects. Each message has a timestamp (`simtime_t`), sender, receiver, and payload. The scheduler dequeues the minimum-timestamp message.

**Relevance**: OMNeT++'s hierarchical module + gate/message architecture is the clearest existing design for our **GUI element model** (how React Flow nodes connect and communicate). Study the INET OMNeT++ source for the Queue/Server/Source/Sink implementation pattern.

---

### 6.6 SimGrid

**GitHub**: `simgrid/simgrid` | **Language**: C++ / Python / Java | **License**: LGPL

**What it is**: Simulation framework for distributed computing systems (clouds, grids, HPC). Notable for highly accurate performance modeling at scale. Developed at INRIA/France.

**Key design decisions to learn from**:

1. **Activity lifecycle model**  
   SimGrid models computation as *Activities* (Exec, Comm, IO) that consume resources. Activities can be suspended, cancelled, and chained. This is a process-oriented DES approach — more expressive than raw event queues for modeling workflows.

2. **SimDAG**: a DAG (directed acyclic graph) task scheduler for workflow simulation — directly relevant if we model industrial processes as task DAGs.

3. **Validated against real systems**: SimGrid's network models are calibrated against real hardware measurements, giving high-accuracy predictions. This "calibration-first" philosophy is worth adopting for fluid pipe network models.

---

### 6.7 Warped2 & ADEVS

**Warped2** (`wilseypa/warped2`): C++, MPI + Pthreads, Time Warp optimistic PDES. Good reference for Time Warp with **lazy cancellation** (don't immediately cancel all rollback messages — wait to see if they're still needed) and configurable pending event set optimizations.

**ADEVS** (`smiz/adevs`): C++, POSIX threads, shared memory. Implements the **DEVS (Discrete Event System Specification)** formalism rigorously. Key insight: DEVS provides a formal mathematical foundation for DES — each model has `δ_int` (internal transition), `δ_ext` (external transition), `λ` (output function), and `ta` (time advance function). This guarantees compositional correctness.

**DEVS relevance**: If we want our DES engine to be formally correct and composable, adopting DEVS semantics (even informally) gives us:
- Clear separation of event handling (`δ_int`) vs. message receipt (`δ_ext`)
- Formal definition of when an entity produces output (`λ`)
- Time advance function (`ta`) = when is the entity's next self-event?

```julia
# DEVS-inspired Julia structure for a Queue entity
struct QueueModel
    capacity::Int
    service_rate::Float64
 end

# Internal transition: service completion
function δ_int!(q::QueueModel, world::World, entity::EntityId, t::Float64)
    dequeue_customer!(world, entity)
    if queue_length(world, entity) > 0
        schedule_event!(entity, :ServiceComplete, t + rand(Exponential(1/q.service_rate)))
    end
end

# External transition: arrival
function δ_ext!(q::QueueModel, world::World, entity::EntityId, t::Float64, msg)
    enqueue_customer!(world, entity, msg.customer_id)
    if queue_length(world, entity) == 1  # was empty
        schedule_event!(entity, :ServiceComplete, t + rand(Exponential(1/q.service_rate)))
    end
end

# Time advance: when is the next self-event?
ta(q::QueueModel, world::World, entity::EntityId)::Float64 =
    queue_length(world, entity) > 0 ? service_time_remaining(world, entity) : Inf
```

> [REVIEW NEEDED] §6: Any of these libraries you'd like to study more deeply before we start coding? FLAME GPU 2 is the most directly relevant for GPU crowd/fluid sim. ROSS is relevant if we plan supercomputer scale. OMNeT++ is the best reference for the GUI element model.
>
> [COMMENT]: <!-- Add your comment here -->

---

## 7. Event Scheduling: Data Structures & Parallel DES Design

> *This section covers: FEL data structures, why single-threaded DES fails at scale, parallel DES strategies, how Option B is a form of ABM (a key architectural insight), configurable simulation clock speed, and a scalable general architecture for any facility type.*

### 7.1 The Future Event List (FEL)

Every DES engine has a **Future Event List** — the central data structure that holds all pending events sorted by simulated time. The scheduler always dequeues the minimum-timestamp event. This is the single most performance-critical structure in any DES engine.

**Operations required**:
1. `insert(event, time)` — schedule a new event
2. `dequeue_min()` — get and remove the next event
3. `cancel(event)` — cancel a previously scheduled event (needed for Time Warp rollback)

### 7.2 Data Structure Options

| Structure | Insert | Dequeue-min | Cancel | Best for | Used in |
|---|---|---|---|---|---|
| **Binary Heap** | O(log n) | O(log n) | O(n) | General purpose, n < 100k | Most simple simulators |
| **Fibonacci Heap** | O(1) amort. | O(log n) | O(1) | Theoretically optimal | Rarely used (high constant) |
| **Calendar Queue** | O(1) avg | O(1) avg | O(1) | Large n, uniform time distribution | OMNeT++, many DES engines |
| **Ladder Queue** | O(1) amort | O(1) amort | O(1) | Large n, arbitrary distribution | Research DES engines |
| **Splay Tree** | O(log n) amort | O(log n) | O(log n) | Skewed access patterns | Some PDES engines |
| **4-ary Heap** | O(log4 n) | O(log4 n) | O(log4 n) | Cache-friendly variant of heap | ROSS (internal) |

### 7.3 What Production Systems Actually Use

- **OMNeT++**: Calendar queue (bucket-based, ~O(1) amortized) — own highly-tuned implementation
- **ROSS**: **Per-LP 4-ary heap** — each logical process has its own local FEL, NOT a global one
- **FLAME GPU 2**: No global event queue — BSP synchronous; events are implicit in agent state
- **SimGrid**: Custom heap with lazy deletion
- **Repast HPC**: Per-process priority queues, events are MPI messages
- **Julia `DataStructures.PriorityQueue`**: Binary heap — O(log n) for all operations

> **Critical pattern**: ROSS and Repast use **per-LP local queues** — this is fundamental to why they scale. A single global FEL cannot scale beyond a single core.

---

### 7.4 Why Single-Threaded DES Fails at Scale

Consider a **large distribution center** at peak — a representative but not unique example:

| Component | Count | Events/sim-hour |
|---|---|---|
| Dock doors (inbound) | 80–150 | ~600 events |
| Conveyor segments | 500–2,000 | ~50,000 events |
| Sorting lanes | 50–200 | ~20,000 events |
| Pick stations | 200–1,000 | ~30,000 events |
| **Total peak** | — | **200,000–500,000 events/sim-hour** |

At this scale, **all event handlers execute serially on one core**:
- A slow event (conveyor jam rerouting) **blocks all other zones**
- Inbound and outbound simulate sequentially even though they are almost causally independent
- Faster-than-real-time simulation becomes impossible at full scale

The same problem applies to an **automotive plant** (stamping → welding → painting → assembly → shipping), a **mining operation** (extraction → crushing → conveying → processing → logistics), or a **hospital** (admission → triage → diagnosis → treatment → discharge). These are all parallel workflows simulated on a single core.

**Single-threaded DES is acceptable for**: prototyping, validation, models < 50k events/sim-hour, debugging.  
**Parallel DES is required for**: realistic-scale facility simulation, multi-facility networks, faster-than-real-time planning tools.

---

### 7.5 Parallel DES: Three Approaches

**Option A — Single Global FEL** (serial)
```
One global PriorityQueue. Simulation loop dequeues minimum-time event, executes serially.
```
- Correct by construction, fully deterministic, easy to debug
- **Cannot use more than 1 CPU core**
- **Use for**: Prototyping, validation, models < 50k events/sim-hour

---

**Option B — Conservative Parallel DES (Chandy-Misra)** — Recommended
```
Each zone/subsystem = Logical Process (LP) with its own local FEL and its own thread.
LPs communicate via timestamped messages. An LP processes events only up to the
minimum timestamp of its incoming messages. Lookahead = minimum transit time.
```
- Each LP runs on its own core — true multi-core parallelism
- No rollback needed — correctness by construction
- **Scales to any number of zones** — the only limit is available CPU cores
- Julia's `Channel` and `@spawn` map naturally to this pattern
- **Use for**: Any facility simulation, supply chains, multi-facility networks

---

**Option C — Optimistic Parallel DES (Time Warp / ROSS-style)**
```
Each LP runs ahead speculatively without waiting. On receiving a straggler message,
rollback and re-execute. GVT computed periodically for memory reclamation.
```
- Maximum parallelism — no waiting between LPs
- Requires reverse event handlers or state checkpointing — significantly more complex
- **Use for**: Very large loosely-coupled systems when conservative stalls too often

---

### 7.6 Key Insight: Conservative Parallel DES IS Agent-Based Modeling

> *You asked: "Can Option B be emulated using ABM?" — the answer is yes, and more than that: Option B IS ABM at the process/zone level. This unifies the entire platform.*

In traditional ABM (Agents.jl, Mesa), all agents step **synchronously** (BSP): every agent advances by one tick, then all synchronize. This works for homogeneous populations but breaks down for facilities where different stations operate at different rates.

In Conservative Parallel DES, each **Logical Process (LP) is an agent**:

| ABM concept | Conservative PDES equivalent |
|---|---|
| **Agent** | Logical Process (LP) = one zone, station, or facility |
| **Agent state** | Zone state: queues, servers, inventories, schedules |
| **Agent behavior** | Process events from local FEL; produce output events |
| **Agent interaction** | Timestamped messages via channels (not shared memory) |
| **Time advance** | Asynchronous per-LP (not synchronized BSP ticks) |
| **Coordination** | Null message protocol (automatic deadlock prevention) |

This is **asynchronous ABM** — more general and more powerful than synchronous ABM for facility simulation. Our platform can be viewed as a **three-level ABM hierarchy**:

```
  LEVEL 1 — Macro (Facility/Zone agents)
  ────────────────────────────────────────────────────────────────
  Each zone = an LP agent running on its own thread
  Behavior: process DES events, send timestamped messages to neighbors
  Coordination: Conservative PDES (Chandy-Misra null messages)

  LEVEL 2 — Meso (Entity agents within zones)
  ────────────────────────────────────────────────────────────────
  Packages, vehicles, customers, orders = DES entities
  Behavior: trigger events (arrival, service start, departure)
  State: tracked in Ark.jl ECS components

  LEVEL 3 — Micro (Particle/Crowd agents)
  ────────────────────────────────────────────────────────────────
  Fluid particles, pedestrians, forklifts = GPU-accelerated agents
  Behavior: physics rules (Social Force, SPH/LBM)
  Coordination: BSP GPU kernel launches (FLAME GPU 2 style)
```

This three-level hierarchy is the core architectural innovation of this platform. No existing tool unifies all three levels.

---

### 7.7 Scalability: No Zone Count Limit

> *You asked: "Should we not put a restriction on number of zones? Should the algorithm be scalable?"*

**No restriction on zone count — the algorithm scales naturally.**

The Chandy-Misra algorithm requires only:
1. Each LP has a `Channel` to each of its downstream neighbors
2. Each LP sends null messages to its neighbors after each safe window
3. Each LP blocks on `take!(inbox)` when it has no safe events to process

This is a **topology graph** problem, not a count problem. The performance scales as:

| Zones (LPs) | Threads available | Speedup (ideal) | Bottleneck |
|---|---|---|---|
| 10 | 12-core machine | ~10× | None |
| 50 | 64-core server | ~50× | None |
| 500 | 512-core HPC node | ~500× | Thread management overhead |
| 10,000+ | MPI cluster | Unlimited | → Tier 3 (Time Warp / MPI) |

For **Tier 2 (single machine)**, the practical limit is the number of CPU cores. On a modern workstation (12–16 cores), 10–15 LPs run truly in parallel. On a server (64–128 cores), 50–100 LPs.

For **multi-facility networks** (single-DC to nationwide network), we promote to **Tier 3**: each facility becomes an MPI process, each internal zone becomes a thread-local LP. This is exactly how ROSS and Repast HPC scale to supercomputers — the pattern is the same, just the transport layer changes from Julia `Channel` to MPI messages.

```
  Single facility (Tier 2):      Multi-facility (Tier 3):
  ─────────────────────────      ─────────────────────────────────────
  12 zones × 1 thread each       3 facilities × MPI process each
  Julia @spawn + Channel          Each facility runs Tier 2 internally
  12-core workstation             MPI connects facilities
                                  Lookahead = inter-facility transit time
                                  (hours to days → excellent parallelism)
```

---

### 7.8 Configurable Simulation Clock Speed

> *You asked: "I think we should have a sim clock whose speed the user can adjust — fastest possible, match wall clock, or even slower than wall clock. Is it possible?"*

**Yes — this is straightforward to implement and critically important for different use cases:**

| Speed mode | `speed_factor` | Use case |
|---|---|---|
| **Fastest possible** | `Inf` | Batch planning runs, parameter sweeps |
| **10× real-time** | `10.0` | Quick scenario previews |
| **Real-time (1:1)** | `1.0` | Live monitoring dashboards, operator training |
| **Slow motion** | `0.1` | Educational demos, debugging event sequences |
| **Paused / step-by-step** | `0.0` | Debugging, event inspection |

```julia
# Simulation clock with adjustable speed
mutable struct SimClock
    sim_time    ::Float64    # current simulated time (seconds)
    wall_origin ::Float64    # wall clock at sim start (time())
    speed_factor::Float64    # Inf=fastest, 1.0=real-time, 0.5=half-speed
    paused      ::Atomic{Bool}
end

SimClock(speed::Float64 = Inf) = SimClock(0.0, time(), speed, Atomic{Bool}(false))

# Called by the sim runner before processing each event
function throttle!(clock::SimClock, next_sim_time::Float64)
    # Paused: block until unpaused
    while clock.paused[]
        sleep(0.01)
    end
    
    # Fastest mode: no throttle at all
    isinf(clock.speed_factor) && (clock.sim_time = next_sim_time; return)
    
    # Calculate how much wall time should have elapsed for this sim advance
    expected_wall = clock.wall_origin + next_sim_time / clock.speed_factor
    remaining     = expected_wall - time()
    
    # Sleep only if we are ahead of schedule (never sleep if behind)
    remaining > 0.001 && sleep(remaining)
    
    clock.sim_time = next_sim_time
end

# User-facing controls (can be called from GUI at any time)
set_speed!(clock::SimClock, factor::Float64) = (clock.speed_factor = factor)
pause!(clock::SimClock)   = atomic_cas!(clock.paused, false, true)
unpause!(clock::SimClock) = atomic_cas!(clock.paused, true, false)
step_once!(clock::SimClock) = ... # advance exactly one event then pause again
```

**Integration with the sim loop**:
```julia
function sim_loop!(world::World, fel::PriorityQueue, clock::SimClock, t_end::Float64)
    while !isempty(fel)
        event, t = dequeue_pair!(fel)
        t > t_end && break
        
        throttle!(clock, t)          # ← speed control happens here
        dispatch!(world, event, t)
    end
end
```

**For the parallel PDES (Tier 2)**, the clock is shared across all LPs — each LP calls `throttle!` before processing its safe event window. Since all LPs advance at the same simulated rate (just different events), the throttle naturally keeps the whole simulation synchronized to the chosen speed.

**Real-time mode use cases**:
- **Operator training simulator**: run at 1:1, operators see realistic event pacing
- **Live DC dashboard**: simulation runs alongside real operations, verifying against actual sensor data
- **Slow-motion replay**: post-incident analysis at 0.1× speed, every event visible

---

### 7.9 General Facility Topology — Examples Beyond Distribution Centers

> *You emphasized: "DC is just an example. Think about automotive plant, mining operation, hospital. The platform should be general."*

The LP topology is defined by the user in React Flow — our platform just runs whatever graph they draw. The **lookahead** for each connection is the minimum transit time between those two zones, which the user configures per edge.

**Automotive Plant**:
```
[LP: Stamping] ─(2min)─▶ [LP: Welding] ─(5min)─▶ [LP: Painting] ─(15min)─▶
[LP: Assembly Line A] ─▶ [LP: Assembly Line B] ─▶ [LP: Final Inspection] ─▶
[LP: Shipping/Logistics]
```
Lookahead = physical conveyor belt / AGV transit time between stations.

**Mining Operation**:
```
[LP: Extraction (Pit/Face)] ─(10min)─▶ [LP: Primary Crushing] ─(3min)─▶
[LP: Conveying System]      ─(8min)─▶  [LP: Secondary Crushing/Screening] ─▶
[LP: Processing Plant]      ─(20min)─▶ [LP: Tailings/Smelting] ─▶
[LP: Port/Rail Logistics]
```
Lookahead = haul truck cycle time, belt speed, processing batch time.

**Hospital Operation**:
```
[LP: ED Triage]       ─(5min)─▶  [LP: ED Treatment Bays] ─▶
[LP: Radiology/Lab]              [LP: ICU] ─▶ [LP: General Ward] ─▶
[LP: Surgical Suite]  ─(30min)─▶ [LP: Recovery/PACU]     ─▶
[LP: Discharge Planning]
```
Lookahead = patient transport time, bed assignment delay, lab turnaround time.

**Multi-facility supply chain** (Tier 3 / MPI):
```
[Facility A: Manufacturing] ─(2 days)─▶ [Facility B: Regional DC] ─(4hr)─▶
[Facility C: Last-Mile DC]  ─(1hr)────▶ [Customer Delivery Zone]
```
Lookahead = inter-facility transit time — hours to days, giving enormous parallelism.

---

### 7.10 Three-Tier Architecture (Updated)

```
┌──────────────────────┬──────────────────────────────┬─────────────────────┐
│  TIER 1 (Prototype)  │  TIER 2 (Production — any    │  TIER 3 (Multi-     │
│                      │  single facility)             │  facility network)  │
│  Single global FEL   │  Conservative PDES            │  Time Warp / MPI    │
│  Serial, 1 thread    │  Per-zone LPs + Channels      │  + Tier 2 internal  │
│                      │  No zone count limit          │                     │
│  DataStructures.jl   │  Julia @spawn + Channel       │  MPI.jl             │
│  PriorityQueue       │  Per-LP PriorityQueue         │  ROSS pattern       │
│                      │                              │                     │
│  SimClock supported  │  SimClock supported           │  SimClock supported │
│  (all speed modes)   │  (all speed modes)            │  (all speed modes)  │
│                      │                              │                     │
│  Start here always   │  Build toward this            │  Future: when Tier 2│
│                      │  DC, plant, mine, hospital    │  is insufficient    │
└──────────────────────┴──────────────────────────────┴─────────────────────┘
```

**Build order**:
1. **Tier 1**: Serial DES + SimClock. Validate model correctness. Days.
2. **Tier 2**: Refactor to per-zone LPs. Event handlers unchanged. 1–2 weeks.
3. **Tier 3**: MPI transport layer. Only if multi-facility at national scale. Future.

---

### 7.11 Event Handler Pattern (Industry-Agnostic, Works Across All Tiers)

```julia
abstract type SimEvent end

# Generic events that work for any industry
struct EntityArrival    <: SimEvent; entity_id::UInt64; zone_id::Int; time::Float64 end
struct ProcessComplete  <: SimEvent; entity_id::UInt64; station_id::Int; time::Float64 end
struct ResourceFailure  <: SimEvent; resource_id::Int; severity::Float32; time::Float64 end
struct ScheduledChange  <: SimEvent; zone_id::Int; change_type::Symbol; time::Float64 end
struct TransferOut      <: SimEvent; entity_id::UInt64; dest_zone::Int; time::Float64 end
struct NullEvent        <: SimEvent end   # Chandy-Misra null message

# Industry-specific events are subtypes of the generic ones
# Automotive: struct WeldComplete <: ProcessComplete ... end
# Hospital:   struct PatientAdmit <: EntityArrival ... end
# Mining:     struct BlastEvent   <: ScheduledChange ... end

# Julia multiple dispatch routes to the correct handler
dispatch!(state, e::EntityArrival,   t) = handle_arrival!(state, e, t)
dispatch!(state, e::ProcessComplete, t) = handle_process_complete!(state, e, t)
dispatch!(state, e::ResourceFailure, t) = handle_failure!(state, e, t)
dispatch!(state, e::ScheduledChange, t) = handle_change!(state, e, t)
dispatch!(state, e::NullEvent,       t) = nothing
```

### 7.12 Cancel Support

```julia
const cancelled = Set{UInt64}()

struct CancellableEvent
    id    ::UInt64
    inner ::SimEvent
    time  ::Float64
end

cancel!(id::UInt64) = push!(cancelled, id)

function safe_dequeue!(fel::PriorityQueue)
    while !isempty(fel)
        ev, t = dequeue_pair!(fel)
        ev.id in cancelled && (delete!(cancelled, ev.id); continue)
        return ev, t
    end
    return nothing, Inf
end
```

> [REVIEW NEEDED] §7 — Your comments addressed:
> 1. ✅ **Option B as ABM**: Conservative PDES LPs ARE agents — see §7.6 for the unified three-level ABM hierarchy
> 2. ✅ **No zone limit**: Scales naturally with CPU cores; see §7.7
> 3. ✅ **General platform**: Automotive, mining, hospital examples in §7.9 — all just different LP topologies
> 4. ✅ **Configurable sim clock**: SimClock with speed_factor — Inf, real-time, slow-motion, pause, step; see §7.8
> 5. ✅ **Single DC + multi-facility**: Tier 2 for single facility, Tier 3 (MPI) for multi-facility networks
>
> Remaining open questions for you:
> - Which industry vertical should we use as the **primary test case** for prototyping? (DC, hospital, automotive?)
> - For the simulation clock real-time mode — should the GUI show wall clock AND sim clock simultaneously?
> - For multi-facility Tier 3: is this a near-term requirement or future roadmap?
>
> [COMMENT]: <!-- Add your answers here -->

---
## 8. Open Questions & Next Steps

*(Formerly §6 — renumbered)*

### Open Questions

| # | Question | Impact | Status |
|---|---|---|---|
| 1 | Primary target use case? (evacuation, venue planning, industrial DES?) | Determines which features to build first | ⏳ Needs answer |
| 2 | GPU availability — NVIDIA CUDA or AMD ROCm? | Affects Ark.jl backend choice | ⏳ Needs answer |
| 3 | Multi-node (cluster) scale, or single GPU machine? | Determines if MPI/ROSS pattern needed | ⏳ Needs answer |
| 4 | 2D only or 3D environments? | 3D crowd sim is significantly harder | ⏳ Needs answer |
| 5 | Is crowd = full physics sim (Social Force) or animated routing? | Scope of crowd module | ⏳ Needs answer |
| 6 | DES event count at peak: < 10k or > 100k? | Determines FEL data structure choice | ⏳ Needs answer |
| 7 | Start conservative-serial DES or optimistic-parallel from day 1? | Architecture complexity | ⏳ Needs answer |
| 8 | Which reference library to study first? (FLAME GPU 2 recommended) | Coding speed | ⏳ Needs answer |

### Recommended Next Steps

**Immediate (Phase 1 — this week)**
- [ ] Build a minimal Ark.jl ECS world with crowd agent components
- [ ] Implement Social Force Model on CPU first (validate behavior)
- [ ] Visualize with WGLMakie + Bonito.jl: scatter plot of agents with panic color
- [ ] Hook up a simple DES event: "evacuation alarm at t=60s" → change goals
- [ ] Study FLAME GPU 2 `pedestrian_navigation` example as coding reference

**Short-term (Phase 2 — next 2–4 weeks)**
- [ ] Port Social Force Model to GPU via Ark.jl `GPUVector{:CUDA}`
- [ ] Implement spatial hash grid for O(N·k) neighbor lookup
- [ ] Add Eikonal navigation potential field
- [ ] Bootstrap React + React Flow frontend
- [ ] Implement typed DES event queue with Julia multiple dispatch

**Medium-term (Phase 3 — 1–3 months)**
- [ ] Build element library: Crowd Source, Exit, Gate, Obstacle
- [ ] Integrate PixiJS for simulation animation
- [ ] Full DES + crowd event coupling
- [ ] Begin fluid ↔ crowd shared numerics (LWR macroscopic model)

> [REVIEW NEEDED] §8: Review the open questions list — any you can answer now will significantly clarify the implementation plan. Please add your answers as comments below each question.
>
> [COMMENT]: <!-- Add your answers to each open question here -->

---

*Document created: 2026-08-07*  
*Updated: 2026-08-07 — Added §6 (Reference Implementations), §7 (Event Scheduling), review markers throughout*  
*Source sessions: ee2ae0d9 (Aug 5–6 2026), 78616c9e (Aug 7 2026)*  
*Review status: ⏳ Pending user review — please add `[COMMENT]:` blocks and return*
