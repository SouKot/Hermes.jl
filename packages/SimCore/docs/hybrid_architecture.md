# DES + ABM Hybrid Synchronisation Architecture

> **Design document for Sprint 4K implementation.**  
> Written: Sprint 4I · Task 24  
> Status: CONTRACT (Sprint 4K must honour every interface defined here)  
> Author: Antigravity simulation platform

---

## 1. Problem Statement

The platform runs two fundamentally different computational models concurrently:

| Engine | Clock model | Parallelism | Hardware target |
|--------|------------|-------------|-----------------|
| **DES** — Discrete-Event Simulation | Event-driven (variable Δt) | Sequential per LP | CPU threads |
| **ABM** — Agent-Based Model (crowd) | Fixed physics timestep `dt` | All agents in parallel | GPU kernels |

These engines must **interoperate**: an ABM agent who walks into a service zone (e.g. a door
bottleneck, triage station, transport node) becomes a DES entity that queues, is served, then
returns to the ABM crowd.  The challenge is that:

- The DES event loop is causally ordered — events cannot be processed out of order.
- The GPU ABM kernel runs all N agents in one parallel launch — it cannot block waiting for
  individual DES decisions.
- The two engines run at different time granularities (DES events: seconds apart; ABM steps: `dt ≈ 0.05 s`).

The solution is a **thin, lock-free producer–consumer interface** via GPU-visible ring buffers
that are read/written only at well-defined sync boundaries.

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  CPU Thread (Julia DES engine)          GPU (KernelAbstractions kernel)      │
│                                                                               │
│  sim_loop!(des_state)                   update_agents!(world, dt)            │
│    │                                      │                                   │
│    │  process EntityArrival               │  compute SFM/ORCA crowd forces   │
│    │  entity enters DES queue             │  integrate positions + velocities │
│    │  ProcessComplete event fires         │  for each agent i:                │
│    │  entity departs, notifies ABM        │    if zone_check(pos_i, zones[]):  │
│    │                                      │      d_zone_entry_flag[i] = true  │
│    │◄── SYNC BOUNDARY ──────────────────►│    if d_agent_in_service[i]:       │
│    │                                      │      skip force integration        │
│    │  1. GPU kernel finishes step         │                                   │
│    │  2. CPU reads d_zone_entry_flag      │◄── d_agent_free[i] written by CPU │
│    │  3. CPU creates EntityArrival events │    agent resumes on next step      │
│    │  4. CPU reads pending_departures     │                                   │
│    │  5. CPU writes d_agent_free[freed]   │                                   │
│    │  6. GPU reads d_agent_free on next   │                                   │
│    │     kernel launch                    │                                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key insight:** The DES and ABM do NOT run at the same time scale.  The GPU can take many
fine-grained physics steps between DES sync points.  The sync boundary is simply a
producer–consumer handoff via device-visible buffers — the standard pattern in GPU-accelerated
simulation (Richmond et al. 2023, *FLAME GPU 2*; Perumalla 2014, §8.3).

---

## 3. Sync Protocol — Step-by-Step

The protocol executes at every sync boundary, which occurs every `Δt_sync` simulated seconds.
`Δt_sync` is a tunable parameter (see Section 7).

```
Step 1 — ABM kernel finishes
    KernelAbstractions.synchronize(backend)
    # All agents have completed their physics step.
    # d_zone_entry_flag[] is fully written.

Step 2 — CPU reads zone-entry flags (GPU→CPU, O(N) scan but N small in practice)
    h_flags = Array(buffers.d_zone_entry_flag)        # full copy to host
    arr_ids  = findall(h_flags)                       # indices where flag==true
    fill!(buffers.d_zone_entry_flag, false)           # reset for next step

Step 3 — CPU injects DES events for each arriving agent
    for i in arr_ids
        zone_id  = Int(Array(buffers.d_agent_zone)[i])
        t_arrive = current_sim_time
        enqueue!(fel, EntityArrival(UInt64(i), zone_id, t_arrive))
        buffers.d_agent_in_service[i] = true          # freeze in ABM
    end

Step 4 — CPU reads pending departures (host-side vector)
    dep_ids = copy(buffers.pending_departures)
    empty!(buffers.pending_departures)

Step 5 — CPU frees each departed agent
    for i in dep_ids
        buffers.d_agent_in_service[i] = false         # unfreeze in ABM
        buffers.d_agent_free[i]       = true          # signal GPU to restore goal
    end

Step 6 — GPU reads d_agent_free on next kernel launch
    # Inside update_agents! kernel (see Note A for KA early-exit pattern):
    if d_agent_free[i]
        d_agent_free[i] = false   # consume flag
        # restore goal: steer toward original destination or nearest exit
    end
    if d_agent_in_service[i]
        # frozen — skip all physics (branch not taken)
    else
        # normal SFM/ORCA force integration
    end
```

> **Note A — KA kernel early-exit:** KernelAbstractions kernels cannot use bare `return` at
> the top level of a `@kernel` body on all backends.  Use a guard branch pattern instead:
> ```julia
> @kernel function update_agents!(positions, velocities, in_service, agent_free, ...)
>     i = @index(Global)
>     if agent_free[i]
>         agent_free[i] = false
>         # restore goal direction
>     end
>     if !in_service[i]
>         # compute forces, integrate positions/velocities
>     end
>     # frozen agents: neither branch executes — implicit no-op
> end
> ```

---

## 4. Data Structures

All device arrays are allocated via `similar(ref_array, T, N)` — backend-agnostic,
works on CUDA, ROCm, Metal, and multithreaded CPU unchanged.

### 4.1 `d_zone_entry_flag :: AbstractArray{Bool, 1}`

Per-agent flag set by GPU when agent enters a DES service zone.  Reset by CPU at sync.

**Atomix-free design:** This flag approach was chosen over an atomic ring buffer because the
`SimCoreGPUExt` GPU extension (Task 22) demonstrated that Atomix v1.2.1 + CUDA ≥ 6 has an
`AtomixCUDAExt`/`CUDACore` type mismatch.  The flag scan is O(N) but avoids any Atomix
dependency and is sufficient for typical N ≤ 50,000 crowd simulations.

### 4.2 `pending_departures :: Vector{Int32}` (host-side)

Agent IDs freed by DES (`ProcessComplete` events).  Written by CPU DES handler; read and
cleared by CPU sync (Step 4).  Host-only — no GPU transfer needed.

### 4.3 `d_agent_in_service :: AbstractArray{Bool, 1}`

Per-agent freeze flag.  `true` → agent position frozen, physics skipped.  
Written by CPU (Steps 3, 5); read by GPU kernel (guard branch, Step 6).  
Hazard-free: `synchronize(backend)` separates CPU write from next GPU launch.

### 4.4 `d_agent_free :: AbstractArray{Bool, 1}`

One-shot resume signal.  CPU sets `true` (Step 5); GPU reads and clears (Step 6).  
Lets the kernel restore goal direction without additional CPU→GPU data transfer.

### 4.5 `d_agent_zone :: AbstractArray{Int32, 1}`

Which DES service zone each agent last entered.  Written by GPU (zone detection, Step 2);
read by CPU (Step 3).  Value is `-1` when agent is not in any zone.

### 4.6 Canonical Struct

```julia
"""
    HybridSyncBuffers{Backend}

GPU-visible buffers for the DES↔ABM synchronisation protocol.
Allocated once at simulation start via `HybridSyncBuffers(backend, N)`.

Sprint 4K must allocate one of these per simulated world and pass it to both
`update_agents!` (GPU kernel) and `sync_step!` (CPU).
"""
struct HybridSyncBuffers{Backend}
    d_zone_entry_flag   :: AbstractArray{Bool, 1}   # GPU writes, CPU reads+clears
    pending_departures  :: Vector{Int32}             # CPU writes+reads (host only)
    d_agent_in_service  :: AbstractArray{Bool, 1}   # CPU writes, GPU reads
    d_agent_free        :: AbstractArray{Bool, 1}   # CPU writes, GPU reads+clears
    d_agent_zone        :: AbstractArray{Int32, 1}  # GPU writes, CPU reads
end

function HybridSyncBuffers(backend, N::Int)
    z = KernelAbstractions.zeros(backend, Bool, N)
    HybridSyncBuffers{typeof(backend)}(
        KernelAbstractions.zeros(backend, Bool,  N),   # d_zone_entry_flag
        Int32[],                                        # pending_departures
        KernelAbstractions.zeros(backend, Bool,  N),   # d_agent_in_service
        KernelAbstractions.zeros(backend, Bool,  N),   # d_agent_free
        fill!(similar(z, Int32, N), Int32(-1)),         # d_agent_zone
    )
end
```

---

## 5. Zone Detection — Entering a DES Service Zone

A *DES service zone* is an axis-aligned bounding box (AABB) in world coordinates.
The GPU kernel checks each unfrozen agent's position against all zones each physics step.

```julia
# Compact zone representation — store all zones in a device array
struct ServiceZone
    x_lo :: Float32
    x_hi :: Float32
    y_lo :: Float32
    y_hi :: Float32
    zone_id :: Int32
end

# Inside update_agents! @kernel:
# (called per-agent after guard branch passes)
function _check_zone_entry!(pos_i, zones, n_zones, in_service_i,
                             zone_entry_flag, agent_zone, i)
    in_service_i && return   # already frozen, skip zone check
    for z in 1:n_zones
        zn = zones[z]
        if zn.x_lo ≤ pos_i[1] ≤ zn.x_hi && zn.y_lo ≤ pos_i[2] ≤ zn.y_hi
            zone_entry_flag[i] = true
            agent_zone[i]      = zn.zone_id
            return             # enter at most one zone per step
        end
    end
end
```

---

## 6. DES Dispatch Handler — `ProcessComplete`

When the DES engine fires a `ProcessComplete` event, the dispatcher must notify the ABM:

```julia
function handle_process_complete!(event::ProcessComplete,
                                  des_state,
                                  sync_bufs::HybridSyncBuffers,
                                  pipeline::StatsPipeline)
    agent_id = Int32(event.entity_id)
    # Signal ABM to unfreeze agent at next sync boundary
    push!(sync_bufs.pending_departures, agent_id)
    # Record DES stats (warmup-gated via StatsPipeline — Task 9)
    record_departure!(pipeline, event.wait_time, event.sojourn_time)
end
```

---

## 7. Sync Interval — Performance Tradeoff

`Δt_sync` controls how often the CPU and GPU exchange data:

| `Δt_sync` | Sync overhead | Agent limbo duration | Recommended for |
|-----------|--------------|---------------------|-----------------|
| `dt` (0.05 s) — every ABM step | High (GPU→CPU each step) | ≤ 1 frame | Debug / correctness |
| 0.5 s sim-time (default) | Low (~10 ABM steps per sync) | ≤ 0.5 s | Production |
| 5.0 s sim-time | Minimal | ≤ 5 s | Throughput benchmarks |

**Default:** `Δt_sync = 0.5` simulated seconds.  The GPU runs ~10 physics steps (`dt = 0.05 s`)
between sync points.  Agent freeze lag is at most 0.5 s — imperceptible for crowd scenarios.

**Constraint:** `Δt_sync` must be a multiple of `dt`.

---

## 8. Thread Safety

| Resource | Owner | Safety guarantee |
|----------|-------|-----------------|
| `d_zone_entry_flag` | GPU writes → CPU reads | `synchronize(backend)` before CPU scan |
| `pending_departures` | CPU DES handler writes → CPU sync reads | Single CPU thread — no lock |
| `d_agent_in_service` | CPU writes → GPU reads | `synchronize(backend)` before next kernel launch |
| `d_agent_free` | CPU writes → GPU reads+clears | Same `synchronize` guarantee |
| `StatsPipeline` | CPU only (per-LP) | `merge!` at replication boundary (Task 13) |

**No GPU→GPU sync is needed.** All hazards cross the CPU/GPU boundary and are resolved by a
single `KernelAbstractions.synchronize(backend)` call at each sync boundary.

---

## 9. Correctness Invariants

These invariants must hold at every sync boundary.  Sprint 4K tests must verify each.

1. **No agent lost:** Every agent with `d_zone_entry_flag[i] = true` in step k results in
   exactly one `EntityArrival` event on the FEL.

2. **No double-freeze:** An agent with `d_agent_in_service[i] = true` never sets
   `d_zone_entry_flag[i] = true` (early-exit guard prevents zone re-check).

3. **No double-free:** Each `ProcessComplete` fires exactly once per `EntityArrival`.
   FEL causal ordering guarantees this — no two events at the same time for the same entity.

4. **Mass conservation (closed world):** Over any interval [t₀, t₁]:
   ```
   Σ arrivals_injected_to_DES = Σ departures_returned_to_ABM
   ```

5. **Physics isolation:** A frozen agent (`d_agent_in_service[i] = true`) does not:
   - accumulate SFM/ORCA forces
   - move (position unchanged)
   - interact with other agents (excluded from neighbor search)
   - trigger zone re-entry (guarded by early exit)

---

## 10. Verification Plan (Sprint 4K)

```julia
# Test 1 — Zone entry detection (unit, CPU backend — no GPU required)
@testset "Zone entry detection" begin
    bufs = HybridSyncBuffers(CPU(), 10)
    zones = [ServiceZone(8f0, 12f0, 0f0, 4f0, Int32(1))]   # zone at x∈[8,12]
    # Place agent 3 inside zone, others outside
    positions = [(Float32(i), 2f0) for i in 1:10]
    # Run one kernel step
    arr_ids = sync_step_cpu!(des_state, bufs, positions, zones, 0.0)
    @test arr_ids == [3]
    @test all(.!Array(bufs.d_zone_entry_flag))   # flags cleared
    @test Array(bufs.d_agent_in_service)[3]      # agent 3 frozen
end

# Test 2 — No agent lost over 100 sync cycles (closed world)
@testset "Mass conservation" begin
    total_in = 0; total_out = 0
    for _ in 1:100
        arr = sync_step!(...)
        total_in += length(arr)
        total_out += length(bufs.pending_departures)
    end
    @test total_in == total_out
end

# Test 3 — Sync overhead < 5% vs pure CPU DES baseline
@testset "DES throughput overhead" begin
    t_pure  = @elapsed run_mm1!(0.9, 1.0; n_arrivals=50_000)
    t_hybrid = @elapsed run_mm1_hybrid!(0.9, 1.0; n_arrivals=50_000, Δt_sync=0.5)
    @test (t_hybrid - t_pure) / t_pure < 0.05
end

# Test 4 — ABM physics unchanged when no agents in service (GPU, requires CUDA/ROCm)
@testset "ABM physics unaffected" begin
    # All d_agent_in_service = false
    # Run 1000 GPU steps — final positions must match pure-ABM baseline (no sync)
    @test maximum(abs.(pos_hybrid .- pos_baseline)) < 1e-5f0
end
```

---

## 11. References

- Richmond, P., Chesterman, D., & Heywood, P. (2023). *FLAMEGPU2: A framework for high
  performance agent-based simulation on GPUs.* Software: Practice and Experience.
  — Producer–consumer GPU↔CPU messaging pattern, §4.2.

- Perumalla, K. (2014). *Introduction to Reversible Computing.* CRC Press. §8.3
  — Synchronous vs. asynchronous PDES boundary protocols.

- Chandy, K.M. & Misra, J. (1979). *Distributed simulation: A case study in design and
  verification of distributed programs.* IEEE Transactions on Software Engineering, 5(5).
  — Null-message protocol for conservative PDES (applicable to Sprint 4K Tier 2 multi-LP mode).

---

## 12. Sprint 4K Implementation Checklist

> Entry condition for Sprint 4K.  All boxes must be checked before the GPU ABM engine
> is considered complete and integrated with the DES backend.

- `[ ]` `HybridSyncBuffers` struct defined in `SimCore/src/hybrid_sync.jl` (new file)
- `[ ]` `HybridSyncBuffers(backend, N)` constructor allocates all device arrays
- `[ ]` `sync_step!(des_state, abm_world, sync_bufs, current_t)` implemented (CPU)
- `[ ]` `update_agents!` kernel: guard branch for `d_agent_in_service` (no force/move)
- `[ ]` `update_agents!` kernel: zone-entry flag set via `_check_zone_entry!`
- `[ ]` `update_agents!` kernel: `d_agent_free` consumed and goal direction restored
- `[ ]` DES dispatch: `handle_process_complete!` pushes to `pending_departures`
- `[ ]` `StatsPipeline` wired to hybrid sim: `record_departure!` in DES handler
- `[ ]` Invariant 1 (no agent lost): unit test passing (Test 1 above)
- `[ ]` Invariant 4 (mass conservation): integration test passing (Test 2 above)
- `[ ]` Throughput overhead < 5%: benchmark passing (Test 3 above)
- `[ ]` ABM physics regression test passing (Test 4 above)
- `[ ]` `gpu_mean_var` / `gpu_histogram` (`SimCoreGPUExt`) used for post-hoc analysis
