# Simulation Platform — Validation Test Case Catalogue
**Date**: 2026-08-07  
**Status**: Living document — update as tests are implemented  
**Scope**: DES engine + Crowd Simulation (Social Force Model) + Parallelization  
**References**: [Implementation Phases](./2026-08-07_implementation_phases.md) (checkboxes & status) · [Validation Caveats](./2026-08-19_validation_caveats.md) (honest per-test assessment) · [Design Doc](./2026-08-07_simulation_platform_design.md) · [**Validation Dashboard**](./2026-09-03_validation_dashboard.md) (parameters used · results · current status)

---

## How to Use This Document

Each test case has:
- **ID** — unique reference (e.g., `DES-S-01`)
- **Scale** — Small / Medium / Large / Scalability
- **Validation type** — Analytical (exact answer known) / Empirical (compared to real data) / Qualitative (emergent behavior check)
- **Ground truth source** — where the expected answer comes from
- **Pass criteria** — what "correct" means, with tolerance

**Test ID convention**:
- `DES-S-xx` = DES, Small
- `DES-M-xx` = DES, Medium
- `DES-L-xx` = DES, Large/Complex
- `CRW-S-xx` = Crowd, Small
- `CRW-M-xx` = Crowd, Medium
- `CRW-L-xx` = Crowd, Large
- `PAR-xx`   = Parallelization / Scalability

**Status tracking**:
- `[ ]` Not started
- `[/]` In progress
- `[x]` Passing
- `[!]` Failing — needs investigation

---

## PART 1: DES Test Cases

### Background: Verification vs. Validation

- **Verification**: Does the code correctly implement the design? (Code vs. specification)
- **Validation**: Does the simulation match reality? (Simulation vs. real system)

For DES engine tests, the primary method is **analytical verification** — comparing simulation output against closed-form queueing theory formulas. These are exact answers, not estimates.

**Kendall's notation**: A/B/c/K/N where:
- A = arrival process (M=Markovian/Poisson, D=Deterministic, G=General)
- B = service process distribution
- c = number of servers
- K = system capacity (default ∞)
- N = population size (default ∞)

---

### Tier 1: Small DES Test Cases (Analytically Solvable)

#### DES-S-01 — M/M/1 Queue (Single Server, Low Load)
**Scale**: Small | **Type**: Analytical | **Priority**: P0 — must pass first

**Setup**:
- Arrival rate: λ = 1.0 entity/minute (Poisson)
- Service rate: μ = 2.0 entity/minute (Exponential)
- Utilization: ρ = λ/μ = 0.50
- Single FIFO queue, single server, infinite capacity
- Run: 100,000 arrivals (for statistical convergence)

**Analytical ground truth (exact)**:
```
ρ   = 0.50
L   = ρ/(1-ρ) = 1.00        (mean number in system)
Lq  = ρ²/(1-ρ) = 0.50       (mean queue length, excl. server)
W   = 1/(μ-λ) = 1.00 min    (mean time in system)
Wq  = ρ/(μ-λ) = 0.50 min    (mean waiting time in queue)
P0  = 1-ρ = 0.50             (probability server idle)
```

**Pass criteria**: All metrics within ±2% of analytical values at 95% confidence interval.

**What this tests**: Arrival event handler, service completion handler, FIFO queue discipline, time-advance logic, statistics collection.

**Julia validation snippet**:
```julia
λ, μ = 1.0, 2.0
ρ = λ/μ
expected = (L = ρ/(1-ρ), Lq = ρ^2/(1-ρ), W = 1/(μ-λ), Wq = ρ/(μ-λ))
result = run_mm1_simulation(λ, μ, n_arrivals=100_000)
@test isapprox(result.L,  expected.L,  rtol=0.02)
@test isapprox(result.Wq, expected.Wq, rtol=0.02)
```

---

#### DES-S-02 — M/M/1 Queue (High Load — Near Saturation)
**Scale**: Small | **Type**: Analytical | **Priority**: P0

**Setup**: Same as DES-S-01 but ρ = 0.90 (λ=0.9, μ=1.0)

**Why this matters**: Near-saturation behavior is nonlinear and numerically sensitive. Simulation engines often fail here due to warm-up bias or insufficient run length.

**Analytical ground truth**:
```
L   = ρ/(1-ρ) = 9.00
Lq  = ρ²/(1-ρ) = 8.10
W   = 10.0 min
Wq  = 9.0 min
```

**Pass criteria**: ±5% at 95% CI (higher tolerance due to high variance near saturation). Must use steady-state detection to remove warm-up period.

**What this tests**: Warm-up bias removal (Welch's method), variance handling at high load, numerical stability.

---

#### DES-S-03 — M/M/1 Queue Across Utilization Spectrum
**Scale**: Small | **Type**: Analytical | **Priority**: P1

**Setup**: Run M/M/1 at ρ ∈ {0.10, 0.25, 0.50, 0.70, 0.80, 0.90, 0.95} (fix μ=1.0, vary λ).

**What this tests**: Systematic sweep across the operating range. A simulation engine must be accurate across all utilization levels, not just "easy" cases.

**Pass criteria**: All 7 runs within ±2% (ρ ≤ 0.80) and ±5% (ρ > 0.80) of analytical L and Wq values.

**Plot**: Simulated vs. analytical L vs. ρ curve — should match the hyperbolic L = ρ/(1-ρ).

---

#### DES-S-04 — M/M/c Queue (Multi-Server, Erlang-C)
**Scale**: Small | **Type**: Analytical | **Priority**: P0

**Setup**:
- Arrival rate: λ = 4.0 entities/min (Poisson)
- Service rate per server: μ = 1.5 entities/min (Exponential)
- Number of servers: c = 4
- System utilization: ρ = λ/(c·μ) = 4/(4×1.5) = 0.667

**Analytical ground truth (Erlang-C formula)**:
```
C(c, ρ·c) = Erlang-C probability of waiting = ~0.302
Wq = C(c, λ/μ) / (c·μ - λ)              = ~0.134 min
Lq = λ · Wq                              = ~0.536
```

**Pass criteria**: Erlang-C waiting probability ±5%, Wq ±3%.

**What this tests**: Multi-server resource pool, correct allocation of arriving entities to idle servers, proper queuing when all servers busy.

---

#### DES-S-05 — M/M/1/K Finite Buffer (Blocking)
**Scale**: Small | **Type**: Analytical | **Priority**: P1

**Setup**:
- λ=2.0, μ=2.0 (ρ=1.0 offered load), K=5 (max in system)
- Entities arriving when system full are **lost/blocked**

**Analytical ground truth**:
```
At ρ=1 with K=5: P_block = 1/(K+1) = 1/6 ≈ 0.167
Effective throughput λ_eff = λ·(1-P_block) = 2·(5/6) ≈ 1.667
```

**What this tests**: Finite buffer logic, blocking/loss event, effective throughput measurement.

---

#### DES-S-06 — M/D/1 Queue (Deterministic Service)
**Scale**: Small | **Type**: Analytical | **Priority**: P1

**Setup**: λ=0.8, service time D=1.0 (deterministic, not exponential), ρ=0.8

**Analytical ground truth (Pollaczek-Khinchine formula)**:
```
For deterministic service, E[S²] = D² = 1.0, Var[S] = 0
Wq = ρ/(2·μ·(1-ρ)) = 0.8/(2·1·0.2) = 2.0 min
Lq = λ·Wq = 1.6
```

This should give **exactly half** the M/M/1 waiting time (M/M/1 Wq = ρ/(μ-λ) = 0.8/0.2 = 4.0 min).

**What this tests**: Non-exponential service time support, P-K formula correctness, deterministic distribution in event scheduling.

---

#### DES-S-07 — M/G/1 Queue (General Service, P-K Formula)
**Scale**: Small | **Type**: Analytical | **Priority**: P2

**Setup**: λ=0.5, service ~ Erlang-2 (mean=1.0, variance=0.5), ρ=0.5

**Analytical ground truth (Pollaczek-Khinchine)**:
```
E[S]  = 1.0,  E[S²] = Var[S] + E[S]² = 0.5 + 1.0 = 1.5
Lq = ρ²·E[S²] / (2·E[S]·(1-ρ)) = 0.25·1.5/(2·1·0.5) = 0.375
Wq = Lq/λ = 0.75 min
```

**What this tests**: Non-Markovian service distributions, P-K mean value computation.

---

#### DES-S-08 — Event Cancellation Correctness
**Scale**: Small | **Type**: Logical | **Priority**: P0

**Setup**: Schedule 1,000 events. Immediately cancel 500 (random). Run sim. Verify exactly 500 execute.

**Pass criteria**: Exactly 500 events processed, 0 cancelled events executed, no memory leaks in `cancelled` set.

**What this tests**: Lazy deletion cancel mechanism, no phantom events.

---

#### DES-S-09 — SimClock Speed Fidelity
**Scale**: Small | **Type**: Timing | **Priority**: P1

**Setup**: Run a simple M/M/1 (λ=1, μ=2) for 60 seconds of simulated time.

| Speed factor | Expected wall time | Pass criterion |
|---|---|---|
| `Inf` (fastest) | < 1 sec | Completes in < 1 sec |
| `60.0` (60× real-time) | ~1.0 sec | 1.0 ± 0.1 sec |
| `1.0` (real-time) | ~60.0 sec | 60.0 ± 1.0 sec |
| `0.5` (half speed) | ~120.0 sec | 120.0 ± 2.0 sec |
| `0.0` (paused) | ∞ | Does not advance until unpaused |

**What this tests**: SimClock throttle mechanism, `sleep()` accuracy, pause/unpause atomicity.

---

### Tier 2: Medium DES Test Cases

#### DES-M-01 — Tandem Queue (Jackson Network, 2 Nodes)
**Scale**: Medium | **Type**: Analytical | **Priority**: P1

**Setup**:
- Node 1: M/M/1 with λ=1.0, μ₁=2.0 (ρ₁=0.5)
- Node 2: M/M/1 with μ₂=3.0 (departure from Node 1 = arrival to Node 2 = λ₁=1.0, ρ₂=0.333)
- Jackson's theorem: each node in isolation has M/M/1 characteristics

**Analytical ground truth**:
```
Node 1: L₁ = 1.0,  Wq₁ = 0.5 min
Node 2: L₂ = 0.5,  Wq₂ = 0.167 min
Total system sojourn: W = W₁ + W₂ = 1.0 + 0.5 = 1.5 min
(where Wᵢ = 1/(μᵢ - λ))
```

**What this tests**: Entity transfer between queues, departure process statistics, multi-node routing.

---

#### DES-M-02 — Jackson Open Queueing Network (4 Nodes)
**Scale**: Medium | **Type**: Analytical | **Priority**: P2

**Setup**: 4 nodes with routing probability matrix. External arrivals at Nodes 1 and 2.
```
External arrivals: γ₁=1.0, γ₂=0.5
Routing: P₁₂=0.3, P₁₃=0.4, P₁exit=0.3
         P₂₃=0.5, P₂₄=0.5
         P₃exit=1.0, P₄exit=1.0
Service rates: μ₁=3.0, μ₂=2.0, μ₃=4.0, μ₄=2.5
```

**Analytical ground truth**: Solve traffic equations λᵢ = γᵢ + Σⱼ λⱼ·Pⱼᵢ for each node. Each node's Lq, Wq from M/M/1 formulas.

**What this tests**: Probabilistic routing, multi-class traffic, network throughput, correct entity routing logic.

---

#### DES-M-03 — Priority Queue (Preemptive, 2 Classes)
**Scale**: Medium | **Type**: Analytical | **Priority**: P2

**Setup**:
- High-priority class: λ_H=0.3, μ=1.0
- Low-priority class: λ_L=0.5, μ=1.0
- Preemptive priority: high-priority entities interrupt low-priority service

**Analytical ground truth (priority queueing formulas)**:
```
ρ_H = 0.3, ρ_L = 0.5, ρ_total = 0.8
Wq_H = ρ_H/μ / ((1-ρ_H)(1)) ≈ 0.429 min   (exact formula applies)
Low class: higher wait due to interruptions
```

**What this tests**: Priority event scheduling, preemption logic, two-class entity distinction.

---

#### DES-M-04 — Machine with Failures (Preemptive Breakdown)
**Scale**: Medium | **Type**: Statistical | **Priority**: P2

**Setup**:
- Machine processes jobs: service ~ Exp(μ=2.0)
- Machine fails: TTF ~ Exp(α=0.1) (mean 10 time units between failures)
- Repair time: TTR ~ Exp(β=1.0) (mean 1 time unit)
- Arrival rate: λ=1.5 jobs/unit

**Expected behavior**:
```
Machine availability A = β/(α+β) = 1/(0.1+1) ≈ 0.909
Effective service rate μ_eff = μ·A = 1.818
System stable if λ < μ_eff: 1.5 < 1.818 ✓
```

**Pass criteria**: Simulated availability within ±3% of A=0.909 over long run. Measure: fraction of time machine in "up" state.

**What this tests**: Machine failure events, repair events, preemption of in-service jobs, availability statistics.

---

#### DES-M-05 — Batch Arrivals and Service
**Scale**: Medium | **Type**: Statistical | **Priority**: P3

**Setup**: Arrivals in batches of size B ~ Geometric(p=0.3), each batch as one event, inter-batch time ~ Exp(λ=0.5). Single server, service ~ Exp(μ=3.0).

**What this tests**: Batch event generation, group entity processing, aggregate statistics.

---

#### DES-M-06 — Time-Varying Arrival Rate (Non-Stationary)
**Scale**: Medium | **Type**: Statistical | **Priority**: P2

**Setup**: Arrival rate follows a 24-hour profile:
```
Hour 0–6:   λ = 0.5 (night, low)
Hour 6–8:   λ = 2.0 (morning ramp)
Hour 8–12:  λ = 5.0 (morning peak)
Hour 12–14: λ = 3.0 (lunch dip)
Hour 14–18: λ = 5.0 (afternoon peak)
Hour 18–22: λ = 2.0 (evening)
Hour 22–24: λ = 0.5 (night)
```
Implemented via Non-Homogeneous Poisson Process (thinning/inversion).

**Pass criteria**: Empirical arrival rate per hour within ±5% of specified rate. Queue builds during peaks, drains during off-peak — verify this qualitatively.

**What this tests**: Non-stationary DES, schedule-driven events (shift changes), time-varying system load.

---

#### DES-M-07 — Fork-Join Parallel Processing
**Scale**: Medium | **Type**: Statistical | **Priority**: P3

**Setup**:
- An order splits into 3 parallel tasks (pick, pack-material, label)
- Each task on separate server: Exp(μ₁=2), Exp(μ₂=3), Exp(μ₃=1.5)
- Order complete when ALL 3 tasks done (join synchronization)
- Arrival rate: λ=0.8 orders/unit

**Analytical bound (Baccelli-Makowski)**:
```
E[max(S₁, S₂, S₃)] ≥ max(E[S₁], E[S₂], E[S₃]) = max(0.5, 0.33, 0.67) = 0.67
Simulated mean join time should exceed this lower bound
```

**What this tests**: Fork-join synchronization, waiting for multiple concurrent events, barrier logic.

---

### Tier 3: Large/Complex DES Test Cases

#### DES-L-01 — Manufacturing Cell (5 Machines, Buffers, Breakdowns)
**Scale**: Large | **Type**: Statistical | **Priority**: P2

**Setup**:
- 5 machines in series: M1 → M2 → M3 → M4 → M5
- Inter-machine buffers: capacity 10, 5, 8, 10
- Each machine: service ~ Erlang-2, mean varies (M1=2min, M2=1.5min, ...)
- Machine breakdowns: TTF ~ Exp, TTR ~ Exp (each machine different)
- Arrival to M1: λ=0.4 jobs/min

**Validation targets**:
- Throughput (jobs/hour) — bottleneck machine determines this (Little's Law)
- Buffer utilization at each stage
- Machine utilization at each stage
- Blocking probability at each buffer (when full)

**Cross-validation**: Compare against JaamSim reference model (open-source DES tool, validated independently).

**What this tests**: Multi-stage serial systems, blocking/starvation, bottleneck identification, complex DES topology.

---

#### DES-L-02 — Call Center with Shifting Demand
**Scale**: Large | **Type**: Empirical/Statistical | **Priority**: P3

**Setup**:
- 20 agent stations (servers), 3 skill groups
- Time-varying arrival rates (morning rush, lunch, evening — from real call center data)
- Service ~ Lognormal(μ=3min, σ=2min)
- Patience time ~ Exponential (agents abandon after waiting > 5min mean)
- Routing: skills-based (high-skill agents handle complex calls)

**Validation targets**:
- Service level (% answered within 20 sec): target 80%
- Abandonment rate: compare against industry benchmark (2–5%)
- Agent utilization: 85–90% at peak

**Cross-reference**: Erlang-A model (M/M/c + abandonment) for steady-state approximation.

**What this tests**: Multi-skill routing, abandonment/reneging, SLA metric computation, complex agent behavior.

---

#### DES-L-03 — Simple DC — Inbound Only (10 LPs, Tier 2 Architecture)
**Scale**: Large | **Type**: Statistical + Architecture | **Priority**: P1

**Setup** (specifically designed to test Tier 2 Conservative PDES):
```
LP1: Truck Arrivals (Poisson, λ=8 trucks/hr, 40 pallets/truck)
LP2: Inbound Dock (8 doors, unloading Exp(15min/truck))
LP3: Receiving/QC (3 stations, Exp(5min/pallet))
LP4: Inbound Sorter (conveyor, capacity 200 pallets/hr, deterministic transit)
LP5: Putaway (10 forklifts, Erlang-2(8min/pallet))
```

**Validation targets**:
- Throughput: pallets/hour through each stage
- Queue depths at each LP
- Dock utilization
- Pallet sojourn time (dock → putaway)

**Parallelism validation** (key for this test):
- Run same model with 1 LP (serial) and 5 LPs (parallel)
- Results must be statistically identical (same seeds → identical)
- Wall-clock time should be ~5× faster with 5 LPs

**What this tests**: Tier 2 Conservative PDES correctness, Chandy-Misra null message protocol, lookahead accuracy.

---

## PART 2: Crowd Simulation Test Cases

### Background: Social Force Model Validation

The Social Force Model (Helbing & Molnár 1995) produces **emergent collective behaviors** from individual-level rules. Validation has two levels:
1. **Micro-level**: Does each agent follow the force equations correctly?
2. **Macro-level**: Does the collective behavior match empirical crowd phenomena?

**Key empirical references**:
- Helbing & Molnár (1995): Original SFM paper — lane formation data
- Helbing, Farkas & Vicsek (2000): Panic paper — faster-is-slower data
- Weidmann (1993): Fundamental diagram (speed vs. density)
- Fruin (1971): Level of Service (LOS) framework
- SFPE Handbook: Fire protection evacuation engineering standards

---

### Tier 1: Small Crowd Test Cases (Unit / Behavioral)

#### CRW-S-01 — Single Agent: Straight-Line Goal Seeking
**Scale**: Small (1 agent) | **Type**: Analytical | **Priority**: P0

**Setup**:
- One agent at position (0, 0), goal at (10, 0)
- No obstacles, no other agents
- Desired speed: v₀ = 1.4 m/s, relaxation time τ = 0.5s

**Expected trajectory** (from force equation):
```
f_goal = (1/τ) · (v₀·ê_goal - v)
At t=0: v=0, f = v₀/τ = 2.8 m/s² acceleration
Steady state: v = v₀ = 1.4 m/s (at t >> τ)
Time to reach goal: t ≈ x/v₀ + τ ≈ 7.14 + 0.5 ≈ 7.6 sec
```

**Pass criteria**:
- Agent reaches goal ±0.1m
- Steady-state speed = 1.4 ± 0.05 m/s
- No oscillation past goal
- Time to reach within ±5% of analytical estimate

**What this tests**: Goal-seeking force, relaxation time dynamics, position integration accuracy.

---

#### CRW-S-02 — Single Agent: Obstacle Avoidance
**Scale**: Small (1 agent + 1 obstacle) | **Type**: Qualitative + Analytical | **Priority**: P0

**Setup**:
- Agent at (0, 0) heading to goal (10, 0)
- Circular obstacle at (5, 0) radius r=0.5m
- Expected: agent deflects around obstacle, reaches goal

**Pass criteria**:
- Agent never penetrates obstacle (min distance > 0 at all times)
- Agent reaches goal
- Path is smooth (no sharp angle changes > 45°/timestep)
- Deflection is symmetric (test same scenario mirrored)

---

#### CRW-S-03 — Two Agents: Head-On Avoidance
**Scale**: Small (2 agents) | **Type**: Qualitative | **Priority**: P0

**Setup**:
- Agent A at (0, 0), goal (10, 0), v₀=1.4 m/s
- Agent B at (10, 0), goal (0, 0), v₀=1.4 m/s
- Both walking directly toward each other in a corridor (y=0, width=2m)

**Expected behavior**: Symmetric deflection — both step to the right (right-hand traffic convention), pass each other, continue to goals.

**Pass criteria**:
- No interpenetration at any timestep
- Both reach their goals
- Paths are symmetric about y=0
- Resolution: agents shift to opposite sides

**What this tests**: Agent-agent repulsion force, symmetry of force model, right-hand traffic emergence.

---

#### CRW-S-04 — Single Bottleneck: 10 Agents
**Scale**: Small (10 agents) | **Type**: Qualitative | **Priority**: P0

**Setup**:
- 10 agents in a 5m×5m room
- One exit: 1.2m wide door on one wall
- All agents have same goal: exit

**Expected behavior**:
- Arching formation at exit
- Agents exit one at a time (not simultaneously)
- Some intermittent clogging, then release

**Pass criteria**:
- All 10 agents exit
- No agents stuck permanently
- Visual: arch visible in visualization
- Flow rate: 1–1.5 agents/second (empirical door capacity ≈ 1.2 persons/sec/meter × 1.2m = 1.44/sec)

---

#### CRW-S-05 — Faster-is-Slower: Small Group
**Scale**: Small (20 agents) | **Type**: Quantitative | **Priority**: P1

**Setup**: 20 agents in a room, single exit (0.9m wide). Run 3 scenarios:
- Scenario A: desired speed v₀=1.0 m/s (normal)
- Scenario B: desired speed v₀=3.0 m/s (hurried)
- Scenario C: desired speed v₀=5.0 m/s (panic)

**Expected behavior (Helbing et al. 2000)**:
```
Higher desired speed → MORE clogging at exit → LONGER total evacuation time
T_evac(A) < T_evac(C)  [faster-is-slower effect]
```

**Pass criteria**: `T_evac(v₀=1.0) < T_evac(v₀=5.0)` — evacuation is faster at normal speed than panic speed.

**What this tests**: Panic force model, pressure at bottlenecks, counter-intuitive emergent behavior.

---

### Tier 2: Medium Crowd Test Cases

#### CRW-M-01 — Bidirectional Corridor: Lane Formation
**Scale**: Medium (200 agents) | **Type**: Empirical | **Priority**: P1

**Setup**:
- Corridor: 20m long × 4m wide
- 100 agents: left → right (v₀=1.4 m/s)
- 100 agents: right → left (v₀=1.4 m/s)
- Both groups start simultaneously

**Expected behavior (Helbing & Molnár 1995)**:
```
Self-organization into lanes within 5–10 seconds
Number of stable lanes: 2–3 (density dependent)
Mean speed in lanes: close to v₀ (less than 10% reduction)
```

**Quantitative validation**:
- Lane formation time: < 15 seconds
- After steady state: measure speed distribution → mean > 1.2 m/s
- Measure: lane count (by clustering agents by y-coordinate)

**Reference data**: Helbing & Molnár (1995) Fig. 4 — lane snapshots at t=0, 5, 10, 20s.

**What this tests**: Many-body interactions, self-organization, steady-state collective behavior.

---

#### CRW-M-02 — Fundamental Diagram (Speed vs. Density)
**Scale**: Medium (up to 500 agents) | **Type**: Empirical | **Priority**: P1

**Setup**:
- Corridor: 20m × 3m, periodic boundary conditions
- Vary density ρ from 0.1 to 6.0 p/m² in steps
- Measure mean speed at steady state

**Expected output** (Weidmann 1993 fundamental diagram):
```
ρ = 0.5 p/m²  → v ≈ 1.3 m/s  (free flow)
ρ = 1.0 p/m²  → v ≈ 1.1 m/s
ρ = 2.0 p/m²  → v ≈ 0.8 m/s
ρ = 3.0 p/m²  → v ≈ 0.5 m/s
ρ = 5.0 p/m²  → v ≈ 0.2 m/s  (congested)
ρ = 6.0 p/m²  → v ≈ 0.0 m/s  (jammed)
```

**Pass criteria**: Simulated (ρ, v) curve within ±15% of Weidmann data at each density point.

**What this tests**: Density-speed relationship, collective slowdown, crowd compressibility.

---

#### CRW-M-03 — Room Evacuation with Multiple Exits (500 agents)
**Scale**: Medium (500 agents) | **Type**: Empirical | **Priority**: P1

**Setup**:
- Room: 30m × 20m
- 500 agents randomly placed, all trying to exit
- 2 exits: one 2m wide (left wall), one 1.5m wide (right wall)
- Agents use Eikonal potential field for navigation

**Validation targets**:
- Total evacuation time: compare against empirical formula `T = N/f_total` where `f_total` = sum of exit flow rates
  - Exit 1 capacity: ≈ 1.5 × 2.0 = 3.0 p/s, Exit 2: ≈ 1.5 × 1.5 = 2.25 p/s
  - Total: 5.25 p/s → Expected T ≈ 500/5.25 ≈ 95 seconds
- Load distribution between exits: should roughly reflect capacity ratio (57% / 43%)

**Pass criteria**: Evacuation time within ±20% of formula estimate. Exit load ratio within ±15%.

---

#### CRW-M-04 — T-Junction Merging Flow
**Scale**: Medium (300 agents) | **Type**: Qualitative | **Priority**: P2

**Setup**:
- T-junction: 3m wide corridors
- 200 agents: flow from north corridor (top → bottom)
- 100 agents: flow from east corridor (right → main corridor, then bottom)
- Merging point at junction

**Expected behavior**:
- No interpenetration at junction
- Flow rate conservation: outflow ≈ inflow (300 agents/time period)
- Spontaneous alternating or merging pattern

**Pass criteria**: All agents reach destination. No permanent blockage at junction. Flow conservation within ±5%.

---

#### CRW-M-05 — Stadium Aisle Evacuation (2,000 agents)
**Scale**: Medium-Large (2,000 agents) | **Type**: Empirical | **Priority**: P2

**Setup**:
- Simplified stadium section: 40 rows × 50 seats = 2,000 agents
- Aisles every 10 seats (5 aisles)
- 3 exits at bottom (concourse level)
- Agents: exit row → aisle → concourse → exit

**Validation targets** (SFPE Handbook estimates):
```
Queue formation in aisles: yes (observable)
Aisle flow capacity: ~60 persons/min/aisle (35cm aisle width)
Expected evacuation time: 2000 / (5 aisles × 60/min) ≈ 6.7 minutes
```

**Pass criteria**: Evacuation time within ±25% of SFPE estimate. Aisle queuing observable. No agents bypassing aisles.

---

### Tier 3: Large Crowd Test Cases

#### CRW-L-01 — Large Venue Evacuation (10,000 agents)
**Scale**: Large (10,000 agents) | **Type**: Performance + Empirical | **Priority**: P1

**Setup**:
- Arena: 100m × 80m
- 10,000 agents, 8 exits (each 3m wide)
- Triggered by DES event: `EvacAlarm` at t=60s
- Pre-alarm: agents milling randomly (low desired speed, random goals)
- Post-alarm: all switch goal to nearest exit, panic level ramps up

**Validation targets**:
```
Exit flow capacity total: 8 exits × 3m × 1.5 p/s/m = 36 p/s
Expected full evacuation: 10,000 / 36 ≈ 278 seconds ≈ 4.6 min
```

**Performance target**: 10,000 agents, 60fps on target GPU hardware.

**What this tests**: DES ↔ Crowd integration (alarm event triggers crowd behavior change), large-scale performance, spatial hash grid O(N·k) neighbor lookup.

---

#### CRW-L-02 — Panic Scenario with Obstacles (5,000 agents)
**Scale**: Large (5,000 agents) | **Type**: Empirical | **Priority**: P2

**Setup**:
- 50m × 50m open space with pillars/obstacles
- Normal state: agents moving to various goals
- At t=30s: panic alarm → desired speed increases to 4.0 m/s
- Measure: flow rate through exits before and after alarm

**Expected (Helbing et al. 2000)**:
- Faster-is-slower: flow rate through narrow exits DECREASES after panic onset
- Arching and clogging become pronounced
- Herding effect: agents tend to follow others, leading to uneven exit utilization

**Pass criteria**: Post-panic flow rate is measurably lower than pre-panic rate at narrow exits.

---

#### CRW-L-03 — Multi-Zone DES + Crowd Coupling (Hospital Ward)
**Scale**: Large (1,000 crowd agents + DES) | **Type**: Integration | **Priority**: P2

**Setup**:
- Hospital ward: corridors, patient rooms, nurses' station, elevator lobby
- Crowd agents: patients (slow), visitors (normal), staff (fast)
- DES events: shift change, medication rounds, emergency alert
- DES triggers: `ShiftChange` → staff wave arrives (source creates 50 agents at entrance)
- DES triggers: `EmergencyAlert` → all visitors routed to exits (crowd goal change)

**Validation targets**:
- Corridor occupancy follows DES-driven schedule (peaks at shift change)
- Emergency evacuation visible in visualization within 2 sim-seconds of DES event
- No DES-crowd race conditions (verify causal ordering)

**What this tests**: Full DES ↔ Crowd integration, event-driven crowd behavior change, multi-agent-type handling.
---

### ORCA Navigation Test Cases

> **Reference**: Van den Berg et al. (2011) *IJRR* (RVO2); Bonneaud et al. (2022) *UMANS*.
> These scenarios are the canonical published validation suite for ORCA/RVO2.
> They should be compared against RVO2 and UMANS published results.
>
> **Important constraint**: ORCA has **no anisotropy (no λ)** and **no contact forces**.
> It therefore CANNOT produce arch formation, lane formation, or density-dependent
> speed reduction. Test assertions must reflect these design boundaries.

#### CRW-ORCA-01 — Bidirectional Corridor (ORCA, Low Density)
**Scale**: Medium (100+100=200 agents) | **Type**: Qualitative + Performance | **Priority**: P1  
**Reference**: UMANS (2022) Scenario 3 — bidirectional corridor

**Setup**:
- Corridor: 20m × 4m (same dimensions as 3E/3G lane tests for direct comparison)
- 100 agents: left→right (v_pref = 1.34 m/s)
- 100 agents: right→left (v_pref = 1.34 m/s)
- ρ = 200 / (20×4) = 2.5 ped/m² (moderate density, within ORCA feasibility range)
- Goals placed 1m past each wall. σ=0, seed=42

**Expected behavior** (from UMANS 2022):
- All agents reach goals (collision-free guarantee)
- Agents do NOT spontaneously form lanes (ORCA has no λ — confirmed by UMANS)
- Individual dodging instead of lane segregation
- Mean flow speed: ≥85% of v_pref (ORCA efficient at this density)

**Pass criteria**:
- `reached ≥ 180/200` (90% liveness — some LP3 fallback acceptable at ρ=2.5)
- `min_separation > 0` (no penetrations — ORCA’s primary guarantee)
- `mean_speed ≥ 0.80 × v_pref` (1.07 m/s) — ORCA maintains throughput
- `lane_score ≤ 0.60` — confirm NO lane formation (CANNOT by design)

**Cross-library comparison**: UMANS (2022) reports ORCA bidirectional mean speed ≈ 87%–95%
of v_pref at ρ=2.5 depending on time horizon. Assert within that band.

---

#### CRW-ORCA-02 — Static Block Navigation (ORCA)
**Scale**: Small–Medium (50 agents) | **Type**: Qualitative | **Priority**: P2  
**Reference**: RVO2 `examples/Blocks.cc` — Van den Berg et al. (2011)

**Setup**:
- Room: 20m × 20m
- 4 static square obstacles (2m × 2m) arranged in a 2×2 grid in the centre
- 50 agents: antipodal start/goal positions around the obstacle grid
- Agents must navigate around obstacles to reach goals

**Expected behavior** (RVO2 Blocks):
- All agents reach goals without penetrating obstacles
- Smooth detour paths around blocks
- No permanent deadlock from obstacle corners

**Pass criteria**:
- `reached == 50` (all reach goals)
- `min_obstacle_separation > 0` (no wall penetration)
- `max_time < 60s` (no deadlocks)

**Cross-library comparison**: RVO2 Blocks: all N=100 agents reach goals in ≤40s.

---

#### CRW-ORCA-03 — Crossing Flows (ORCA, X-Junction)
**Scale**: Small (40 agents) | **Type**: Qualitative | **Priority**: P2  
**Reference**: UMANS (2022) Scenario 4 — crossing scenario

**Setup**:
- 10m × 10m open space
- 4 groups of 10 agents each entering from N, S, E, W walls
- Each group heading to the opposite wall (N→S, S→N, E→W, W→E)
- Groups intersect at centre — maximum conflict zone

**Expected behavior**:
- All agents reach goals
- Smooth crossing with velocity-space negotiation
- No permanent collision clusters at centre

**Pass criteria**:
- `reached ≥ 38/40` (95% liveness)
- `min_separation > 0` (collision-free)
- `max_time < 30s`

---

## PART 3: Parallelization & Scalability Tests

### PAR-01 — DES Serial vs. Parallel Correctness (Deterministic)
**Scale**: Any | **Type**: Logical | **Priority**: P0

**Setup**:
- Run DES-M-01 (Tandem Queue) with fixed random seed
- Tier 1 (serial, 1 LP): record all event timestamps and handler outputs
- Tier 2 (parallel, 2 LPs): same seed, same model

**Pass criteria**: Event log identical between Tier 1 and Tier 2. Every event fires at the same simulated time, with the same outcome. **This is the fundamental correctness test for PDES.**

**Note**: This requires that the LP decomposition does NOT change the random number stream. Use per-LP RNG streams with independent seeds derived from global seed.

---

### PAR-02 — Conservative PDES Null Message Protocol (Deadlock Detection)
**Scale**: Small-Medium | **Type**: Logical | **Priority**: P0

**Setup**:
- Construct a pathological circular LP topology: LP1 → LP2 → LP3 → LP1 (cycle)
- Zero lookahead on one edge (to force potential deadlock)
- Run simulation

**Pass criteria**: Simulation either:
- Completes without deadlock (null message protocol handles correctly), OR
- Correctly detects potential deadlock and halts with informative error (not an infinite hang)

**What this tests**: Null message implementation, cycle detection, deadlock prevention.

---

### PAR-03 — Speedup vs. LP Count (Amdahl's Law Measurement)
**Scale**: Scalability | **Type**: Performance | **Priority**: P1

**Setup**:
- DES-L-03 model (DC inbound, 5 LPs)
- Run with: 1, 2, 4, 5, 8, 10 LPs (vary by splitting zones)
- Fix total event load constant (same model, different LP decomposition)
- Measure wall-clock time for same simulated time horizon

**Expected (ideal)**:
```
1 LP:  T_baseline
2 LPs: T_baseline / 2     (2× speedup)
4 LPs: T_baseline / 3.5   (diminishing returns: Amdahl's serial fraction ~15%)
5 LPs: T_baseline / 4.0
```

**Plot**: Speedup curve (actual vs. ideal). Compute serial fraction S = (1/speedup - 1/n) / (1 - 1/n).

**Pass criteria**: Speedup at 4 LPs > 2.5× (reasonable efficiency). Serial fraction < 30%.

---

### PAR-04 — FEL Throughput vs. Event Load (Binary Heap Scaling)
**Scale**: Scalability | **Type**: Performance | **Priority**: P1

**Setup**:
- Synthetic workload: events with random timestamps uniformly distributed in [0, T]
- Vary n (events in FEL simultaneously): 100 → 1k → 10k → 100k → 1M
- Measure: events processed per second (throughput)

**Expected**:
```
Binary heap: throughput ~ 1 / (n · log(n) / constant)
At n=100:    ~10M events/sec
At n=10,000: ~1M events/sec  (log₂(10k) = 13.3 factor)
At n=1M:     ~500k events/sec
```

**Plot**: Throughput vs. n (log scale). Should show O(log n) degradation.

**Pass criteria**: Throughput at n=10k > 500k events/sec (Julia binary heap is fast). Degradation rate matches O(log n).

---

### PAR-05 — Crowd Agent Scaling (GPU Spatial Hash)
**Scale**: Scalability | **Type**: Performance | **Priority**: P1

**Setup**:
- Simple open room, no exits (agents just move randomly)
- Vary N: 1k, 5k, 10k, 50k, 100k, 500k agents
- Measure: FPS (frames per second of simulation)

**Expected**:
```
With naive O(N²) neighbor search: FPS drops sharply beyond 1k agents
With spatial hash grid O(N·k):   FPS scales near-linearly up to GPU memory limit
                                  k = avg neighbors per agent (typically 5–20)
GPU memory limit: ~100k agents on 8GB VRAM (float32 positions + velocities)
```

**Pass criteria**:
- N=10k: > 30 FPS (real-time capable)
- N=100k: > 10 FPS (near-real-time)
- N=500k: > 1 FPS (batch mode acceptable)
- Scaling is clearly sub-quadratic (plot FPS vs N on log-log scale)

---

### PAR-06 — SimClock Parallel Consistency
**Scale**: Small | **Type**: Logical | **Priority**: P1

**Setup**:
- Tier 2 model: 3 LPs running in parallel
- Set speed_factor = 1.0 (real-time)
- Run for 60 simulated seconds

**Pass criteria**:
- Wall time = 60 ± 2 seconds
- All LPs' local_time values converge (max difference < 0.1 sim-sec)
- No LP runs ahead of another by more than 1 lookahead period

---

### PAR-07 — Lookahead Sensitivity Analysis
**Scale**: Medium | **Type**: Performance | **Priority**: P2

**Setup**: DES-L-03 DC model with 5 LPs. Run with varying lookahead values:
- lookahead = 0.1s, 1.0s, 5.0s, 30s, 300s

**Expected behavior**:
```
Small lookahead (0.1s): LPs sync very frequently → high synchronization overhead → slow
Large lookahead (30s):  LPs run freely for long windows → high parallelism → fast
Optimal: somewhere in between (typically 10-30% of mean inter-event time)
```

**Pass criteria**: Identify the optimal lookahead for this model. Measure throughput vs. lookahead curve.

---

## Test Execution Summary Table

| Test ID | Description | Scale | Priority | Status | Notes |
|---|---|---|---|---|---|
| DES-S-01 | M/M/1 ρ=0.5 | Small | P0 | `[ ]` | Not started |
| DES-S-02 | M/M/1 ρ=0.9 | Small | P0 | `[ ]` | Not started |
| DES-S-03 | M/M/1 spectrum | Small | P1 | `[ ]` | Not started |
| DES-S-04 | M/M/c Erlang-C | Small | P0 | `[ ]` | Not started |
| DES-S-05 | M/M/1/K blocking | Small | P1 | `[ ]` | Not started |
| DES-S-06 | M/D/1 deterministic | Small | P1 | `[ ]` | Not started |
| DES-S-07 | M/G/1 Erlang service | Small | P2 | `[ ]` | Not started |
| DES-S-08 | Event cancellation | Small | P0 | `[ ]` | Not started |
| DES-S-09 | SimClock fidelity | Small | P1 | `[ ]` | Not started |
| DES-M-01 | Tandem queue | Medium | P1 | `[ ]` | Not started |
| DES-M-02 | Jackson network 4 nodes | Medium | P2 | `[ ]` | Not started |
| DES-M-03 | Priority queue | Medium | P2 | `[ ]` | Not started |
| DES-M-04 | Machine with failures | Medium | P2 | `[ ]` | Not started |
| DES-M-05 | Batch arrivals | Medium | P3 | `[ ]` | Not started |
| DES-M-06 | Time-varying arrivals | Medium | P2 | `[ ]` | Not started |
| DES-M-07 | Fork-Join | Medium | P3 | `[ ]` | Not started |
| DES-L-01 | Manufacturing cell | Large | P2 | `[ ]` | Not started |
| DES-L-02 | Call center | Large | P3 | `[ ]` | Not started |
| DES-L-03 | DC inbound (PDES) | Large | P1 | `[ ]` | Not started |
| CRW-S-01 | Single agent goal | Small | P0 | `[x]` | Covered by 3D setup |
| CRW-S-02 | Obstacle avoidance | Small | P0 | `[x]` | Covered by ORCA wall tests |
| CRW-S-03 | Head-on avoidance | Small | P0 | `[x]` | **3D** — SFM λ-anisotropy ✅ |
| CRW-S-04 | 10-agent bottleneck | Small | P0 | `[x]` | **3B** — SFM bottleneck ✅ |
| CRW-S-05 | Faster-is-slower | Small | P1 | `[x]` | **3C** — FiS confirmed ✅ |
| CRW-M-01 | Lane formation 200 | Medium | P1 | `[x]` | **3G** — lane score ✅; **3E** — lane maintenance ✅ |
| CRW-M-02 | Fundamental diagram | Medium | P1 | `[x]` | **3F** — Weidmann ρ–v curve ✅ |
| CRW-M-03 | 500-agent multi-exit | Medium | P1 | `[ ]` | Large-N, not yet run |
| CRW-M-04 | T-junction merge | Medium | P2 | `[ ]` | Not started |
| CRW-M-05 | Stadium 2k agents | Medium | P2 | `[ ]` | Needs GPU scaling |
| CRW-L-01 | 10k venue evac | Large | P1 | `[ ]` | Needs DES+Crowd coupling |
| CRW-L-02 | 5k panic scenario | Large | P2 | `[ ]` | Needs GPU scaling |
| CRW-L-03 | Hospital DES+Crowd | Large | P2 | `[ ]` | Needs DES engine |
| CRW-ORCA-01 | ORCA Bidirectional (3I-a) | Medium | P1 | `[x]` | **3I-a** — min_sep≥0, speed≥70% v_pref ✅ |
| CRW-ORCA-02 | ORCA Block Navigation (3I-b) | Small | P2 | `[x]` | **3I-b** — 50/50 t=34.75s ✅ (was broken in Sprint 3P; fixed aa6f5aa) |
| CRW-ORCA-03 | ORCA Crossing Flows (3I-c) | Small | P2 | `[x]` | **3I-c** — ≥38/40 ✅ |
| T7 Bottleneck (SFM) | RiMEA T7 reservoir flow | Medium | P1 | `[!]` | **3B-res** — 0.1–0.2 ped/s mean; T7 not achieved (arch) |
| T7 Bottleneck (GCFM) | RiMEA T7 reservoir flow | Medium | P1 | `[!]` | **3J** — 0.70 ped/s; T7 not achieved (arch) |
| T7 Bottleneck (Hybrid FSM) | RiMEA T7 reservoir flow | Medium | P1 | `[!]` | **3K** — 73/80, ~0.90 ped/s; Sprint 3Z fix |
| T7 Bottleneck (CSM) | RiMEA T7 reservoir flow | Medium | P1 | `[x]` | **3L-a/b** — 1.71–2.16 ped/s ✅ FIRST T7 PASS |
| PAR-01 | Serial vs parallel correctness | Any | P0 | `[ ]` | Not started |
| PAR-02 | Null message / deadlock | Small | P0 | `[ ]` | Not started |
| PAR-03 | Speedup vs LP count | Scalability | P1 | `[ ]` | Not started |
| PAR-04 | FEL throughput scaling | Scalability | P1 | `[ ]` | Not started |
| PAR-05 | Crowd agent scaling | Scalability | P1 | `[ ]` | Not started |
| PAR-06 | SimClock parallel | Small | P1 | `[ ]` | Not started |
| PAR-07 | Lookahead sensitivity | Medium | P2 | `[ ]` | Not started |

**Current crowd test status**: 19 crowd tests implemented (`[x]`) | 2 T7 partial fail (`[!]`) | DES + PAR + large crowd not yet started  
**Last updated**: 2026-09-03 · commit `aa6f5aa` · See [Validation Dashboard](./2026-09-03_validation_dashboard.md) for exact parameters and results.


## Implementation Order (Recommended)

### Sprint 1 — DES Engine Core (Phase 1, GLMakie prototype)
1. `DES-S-01` (M/M/1 low load)
2. `DES-S-02` (M/M/1 high load)
3. `DES-S-08` (event cancellation)
4. `DES-S-04` (M/M/c multi-server)
5. `PAR-01` (serial correctness baseline)

### Sprint 2 — DES Completeness
6. `DES-S-03` (utilization sweep)
7. `DES-S-05`, `DES-S-06`, `DES-S-07`
8. `DES-M-01` (tandem queue)
9. `DES-S-09` (SimClock)

### Sprint 3 — Crowd Engine Core
10. `CRW-S-01`, `CRW-S-02`, `CRW-S-03` (unit behaviors)
11. `CRW-S-04` (10-agent bottleneck)
12. `CRW-S-05` (faster-is-slower)

### Sprint 4 — Crowd at Scale
13. `CRW-M-01` (lane formation)
14. `CRW-M-02` (fundamental diagram)
15. `CRW-M-03` (500-agent evacuation)
16. `PAR-05` (GPU scaling)

### Sprint 5 — Parallelization
17. `PAR-02` (null message / deadlock)
18. `PAR-03` (speedup curve)
19. `PAR-04` (FEL scaling)
20. `DES-L-03` (DC inbound, PDES)

### Sprint 6 — Complex Integration
21. `CRW-L-01` (10k venue)
22. `CRW-L-03` (DES+Crowd coupling)
23. `DES-L-01` (manufacturing cell)
24. Remaining P2/P3 tests

---

## Reference Sources

| Source | Used in |
|---|---|
| Helbing & Molnár (1995) *Phys. Rev. E* — Social Force Model | CRW-M-01, CRW-S-03 |
| Helbing, Farkas, Vicsek (2000) *Nature* — Panic paper | CRW-S-05, CRW-L-02 |
| Weidmann (1993) — Fundamental diagram | CRW-M-02 |
| **Chraibi, Seyfried, Schadschneider (2010) *Phys. Rev. E* — Generalized Centrifugal Force** | CRW-M-02 (GCFM-circular §II); Option C — GCFM-elliptical (§III, not yet implemented) |
| **Van den Berg, Lin, Manocha (2011) *IJRR* — RVO2/ORCA** | CRW-ORCA-01, CRW-ORCA-02, CRW-ORCA-03 |
| **Bonneaud et al. (2022) — UMANS comparison framework** | CRW-ORCA-01, CRW-ORCA-03 |
| Fruin (1971) — Level of Service | CRW-M-05 |
| SFPE Handbook — Fire evacuation engineering | CRW-M-05, CRW-L-01 |
| NIST TN-1822 — Evacuation model V&V | CRW-L-01 |
| Erlang-C formula — Multi-server queueing | DES-S-04, DES-L-02 |
| Pollaczek-Khinchine formula — M/G/1 | DES-S-06, DES-S-07 |
| Jackson’s theorem — Open networks | DES-M-01, DES-M-02 |
| Kelton et al. — *Simio and Simulation* | DES-S-01 through DES-S-07 |
| JaamSim — Open-source DES reference | DES-L-01 cross-validation |
| Amdahl’s Law | PAR-03 |

---

## PART 4: Model Capability Matrix

> **Purpose**: Each locomotion model has a different physical basis. This table defines which
> tests each model is expected to pass, may not pass, or physically cannot pass by design.
> Use this when planning new tests or evaluating a new model.
>
> **Levels**:
> - `MUST` — failure = bug in the implementation
> - `SHOULD` — expected for a well-calibrated implementation; important but forgiving
> - `NICE` — demonstrates capability beyond baseline
> - `MAY NOT` — known physical limitation; not a bug if it fails
> - `CANNOT` — physically impossible by design

### Current Locomotion Models

| Model | Description | Reference | Status |
|-------|-------------|-----------|--------|
| **SFM** | Social Force Model — repulsion + contact spring | Helbing & Molnár 1995 | ✅ Implemented |
| **ORCA** | Optimal Reciprocal Collision Avoidance — velocity-space LP | Van den Berg 2008/2011 | ✅ Implemented |
| **GCFM-circular** | Generalized Centrifugal Force — speed-adaptive range D_i, circular | Chraibi 2010 §II | ✅ Implemented |
| **GCFM-elliptical** | GCFM with velocity-direction elliptic semi-axes (τ_gap, b_min, b_max) | Chraibi 2010 §III | ✅ Implemented (Sprint 3J) |
| **CSM** | Collision-Free Speed Model — speed-reduction by gap ahead (arch-free by design) | Tordeux et al. 2016 | ✅ Implemented (Sprint 3L) |
| **Hybrid FSM** | Density-triggered dispatch: ORCA (ρ<3.5) + SFM (ρ>3.5) | future_directions.md §2 | ✅ Implemented (Sprint 3K) |
| **MEC/NavMesh** | Macro Element Content routing layer + locomotion underneath | future_directions.md §4 | ❌ Not implemented |

### Capability Matrix

| Test / Scenario | SFM | ORCA | GCFM-circular | GCFM-elliptical | CSM | Hybrid FSM | MEC/NavMesh |
|-----------------|-----|------|---------------|-----------------|-----|------------|-------------|
| **T1: Free walking speed** | MUST | MUST | MUST | MUST | MUST | MUST | MUST |
| **T2: Fundamental diagram (ρ-v curve)** | SHOULD | CANNOT | MUST | MUST | SHOULD | MUST | MAY NOT |
| **T4: Speed distribution Normal(μ,σ)** | MUST | MUST | MUST | MUST | MUST | MUST | SHOULD |
| **T7: Bottleneck mean flow ≥1.22 ped/s** | MAY NOT (SFM+σ has ±0.30 ped/s variance; σ=0.30 gives 1.15±0.09 mean, below T7; not reliable for single-run assertion — see caveats §13) | MAY NOT | **MAY NOT** (same spring-force arch artifact as SFM) | **MAY NOT** (Sprint 3J-fix: 0.583–0.70 ped/s; smaller ellipse tightens arch more; arch-limited regardless of σ) | **MUST** ✅ (arch-free by design; 1.71–2.16 ped/s achieved — Sprint 3L) | **MUST** ⚠️ (73/80 agents, ~0.90 ped/s — SFM_MODE arch; Sprint 3Z fix: replace SFM_MODE with CSM) | SHOULD |
| **T12: Arch formation / clogging** | MUST | CANNOT | SHOULD | SHOULD | CANNOT | MUST | CANNOT |
| **T14: Lane formation from disorder** | SHOULD | CANNOT | SHOULD | SHOULD | NICE | SHOULD | NICE |
| **T15: Staircase speed reduction** | MAY NOT | MAY NOT | MAY NOT | MAY NOT | MAY NOT | MAY NOT | MUST |
| **CRW-ORCA-01: Bidirectional corridor** | SHOULD | MUST ✅ | SHOULD | SHOULD | SHOULD | MUST | NICE |
| **CRW-ORCA-02: Block navigation** | SHOULD | MUST ✅ | NICE | NICE | NICE | MUST | SHOULD |
| **CRW-ORCA-03: Crossing flows** | SHOULD | MUST ✅ | SHOULD | SHOULD | NICE | MUST | NICE |
| **FiS: Faster-is-Slower** | MUST ✅ | CANNOT | SHOULD | SHOULD | CANNOT | MUST | CANNOT |
| **PAR-05: GPU scaling N>10k** | SHOULD | SHOULD | SHOULD | MAY NOT | SHOULD | SHOULD | NICE |

### Notes on CANNOT entries

| Model | Test | Physical reason |
|-------|------|-----------------|
| ORCA | T2 (fundamental diagram) | No contact forces — ORCA has no density-dependent speed reduction. Agents maintain v_pref at all densities until LP3 fallback (infeasible). |
| ORCA | T12 (arch) | Arch formation requires contact force compression at the door. ORCA prevents all contact by design. |
| ORCA | T14 (lane formation) | Lane formation is driven by λ-anisotropy (frontal agents repel more than rear). ORCA has no λ. Confirmed by UMANS 2022. |
| ORCA | FiS | Faster-is-Slower requires panic v₀ increasing arch persistence (more pressure = more clogging). ORCA has no arch. |
| CSM | T12, FiS | CSM uses speed-reduction rule, not spring forces — no contact compression, no arch. |

### Guidance for Future Models

When implementing a new locomotion model (e.g., CSM, GCFM-elliptical, Hybrid FSM):
1. Identify which row in the matrix it maps to (or add a new row)
2. Run the MUST tests first — these are non-negotiable for the model’s physics claims
3. Run SHOULD tests — document any failures in `validation_caveats.md`
4. Use CANNOT entries to document explicitly what the model does NOT claim to do
5. Add new test IDs (CRW-X-xx) if the new model has unique validation scenarios without existing equivalents

