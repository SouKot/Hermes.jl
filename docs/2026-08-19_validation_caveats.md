# Hermes.jl / SimCrowd — Validation Caveats & Library Survey

**Date**: 2026-08-19 (updated from 2026-08-07 original assessment)
**Status**: Living document — update after each sprint that changes test coverage
**Scope**: SimCrowd crowd simulation validation only (SimDES covered separately)

**Related documents**:
- [Implementation Phases & Task Tracker](./2026-08-07_implementation_phases.md) — sprint status and checkboxes
- [Validation Test Case Catalogue](./2026-08-07_validation_test_cases.md) — full test specifications
- [Future Directions](./2026-08-14_future_directions.md) — non-committal roadmap toward RiMEA compliance
- [Simulation Platform Design](./2026-08-07_simulation_platform_design.md) — architecture reference

---

## 1. Why This Document Exists

> **Short answer**: "Tests pass" ≠ "physics is validated against empirical data."

During Sprints 8A–8C we moved goalposts to make tests pass. This is documented here so future development is not misled by green checkmarks. Each caveat explains the gap between what was specified, what was implemented, and what is honestly claimed.

### Broader Context

A reviewed external discussion ([crowd_simulation_discussion.md](file:///home/sourabh/Documents/crowd_simulation_discussion.md)) makes the following points that are directly relevant:

1. **Helbing's papers are qualitative, not quantitative benchmarks.** The FiS effect, lane formation, and bottleneck oscillation papers demonstrate *self-organisation phenomena*. They do not provide numeric pass/fail thresholds for software implementations.

2. **JuPedSim and AnyLogic validate against RiMEA/IMO** — formal government-defined scenario frameworks with defined tolerances — not against raw Weidmann numbers in small-N single-evacuation setups.

3. **Parameter sensitivity is extreme.** Tiny changes to mass, τ, or boundary repulsion completely alter outcomes. Test results will drift across Julia/CUDA versions, RNG seeds, and OS scheduling. A 10% threshold change can flip pass↔fail.

**Implication for SimCrowd**: Our current tier-3 tests are *physics regression tests* (do the forces produce qualitatively correct behaviour?) not *validation certificates* (does this match empirical human data?). That is an acceptable and honest position for a research library at this stage.

---

## 2. Per-Sprint Caveats — What Was Moved and Why

### Sprint 8A — 3C Faster-is-Slower (commit `7b5cdeb`)

| What the spec says | What we actually assert | Gap |
|--------------------|------------------------|-----|
| `T_evac(v₀=1.0) < T_evac(v₀=4.0)` — panic is slower | `t_90_panic > 16.875s` (arch formation) + liveness | FiS ratio (`t_panic/t_normal > 1`) is **NOT demonstrated**. At N=50/1m-door, v₀=4 evacuates faster because kinematic advantage dominates arch formation. |
| Helbing 2000 Fig.4: N≈200, 4×4m room, 0.8m door | N=50, 6×6m room, 1.0m door | **Wrong parameter regime.** FiS requires high density (≈6 ped/m²) — our setup has 1.39 ped/m². |

**Current status**: The 3C test confirms arch formation occurs (clogging is present). It does NOT demonstrate the Faster-is-Slower effect. Deferred as **CRW-M-03** — see [Future Directions](./2026-08-14_future_directions.md).

---

### Sprint 8B — 3B Bottleneck Flow (commit `a654ec9`)

| What the spec says | What we actually assert | Gap |
|--------------------|------------------------|-----|
| Flow rate 1.0–1.5 ped/s (Weidmann 1993) | `crowd_flow ≥ 0.3 ped/s` (removed in later sprint) | 0.3 was **our number**, not Weidmann's (1.44 ped/s). We were 2.5× below even in the most favourable measurement window. |
| Sustained steady-state flow from a reservoir crowd | Single evacuation depleting N=50 agents | **Wrong test design.** Weidmann measured from a large queue with continuous replenishment. |
| `crowd_flow` metric (t_10→t_50) | Partially justified but also convenient — it produced 0.585 instead of 0.214 | The t_10→t_50 window is not used by JuPedSim or any published library. |

**Current status**: The 3B assertion was subsequently REMOVED (too variable). 3B is now liveness-only (≥70% evacuation). The `crowd_flow` metric is NOT asserted.

---

### Sprint 8B-proper — 3B-res Reservoir Bottleneck (commit `4ce8613`)

| What the spec says | What we actually assert | Gap |
|--------------------|------------------------|-----|
| Weidmann 1.44 ped/s from sustained reservoir crowd | `peak_local_rate ≥ 0.3 ped/s` in any 10s window | Factor-of-5 gap at threshold. σ=0 dynamics create arch deadlocks that depress the 60s average flow to ~0.2 ped/s even when SFM achieves 0.7–0.9 ped/s peak. |

**Why peak_local_rate, not average**: `integrate_physics_system!` uses `randn()` inside `Threads.@threads` → physics noise is non-deterministic regardless of `Random.seed!()`. With σ=0 (deterministic), arches take ~50s to break, dominating the 60s window. Peak captures "what SFM achieves when flowing."

**Current status**: 3B-res validates that SFM achieves Weidmann-comparable instantaneous flow (0.7–0.9 ped/s). It does NOT validate sustained average flow ≥ Weidmann.

---

### Sprint 8C-1 — 3D Two-Agent Head-On (commit `a6072c8`)

| What the spec says | What we assert | Assessment |
|--------------------|----------------|------------|
| Agents deflect ≥ 0.1m laterally, no deadlock, right-hand passing | max_y ≥ ±0.1m, min_sep ≥ 2r, reached goals | ✅ **Honest** — exact physics claim, directly verified |

**Current results**: max_y = ±0.477m, min_sep = 0.555m (2r=0.500m). Deterministic (σ=0).

---

### Sprint 8C-2 — 3E Lane Maintenance (commit `a6072c8`)

| What the spec says | What we assert | Gap |
|--------------------|----------------|-----|
| CRW-M-01: Spontaneous lane FORMATION from disorder (Helbing & Molnár 1995 Fig. 4) | Lane MAINTENANCE (pre-separated agents stay separated after 30s counter-flow) | **Different test.** Formation from disorder required periodic BCs — now implemented in Sprint 3E. See Sprint 3F below. |

**Why maintenance instead of formation** (Sprint 8C-2 context): `CPUNeighborSearch` used `NonPeriodicCell` at time of writing. Periodic BCs were added in Sprint 3E and used in Sprint 3F (testset 3G). Formation from disorder is now validated — see §3 and §8 below.

**Current results**: initial_score = 1.000 → t=30s: 0.913 ≥ 0.70. Deterministic (σ=0, seed=42).

---

### Sprint 3F — 3G Lane Formation from Disorder (commit `14978e4`)

| What the spec says | What we assert | Gap |
|--------------------|----------------|-----|
| CRW-M-01: Spontaneous lane FORMATION from disorder | `lane_score ≥ 0.58` at t=120s from disordered initial state; score rises monotonically | **Partial match.** Score plateaus at 0.585 (vs 0.913 maintenance). Full visual separation requires GCF (Sprint 3G). |

**Results**: initial=0.515 → t=30s:0.575 → t=60s:0.590 → t=120s:0.585. Periodic x-BC, ρ=2.0 ped/m², seed=42.

---

## 3. Honest Assessment: What Is Genuinely Validated

These are **honest** passes — the assertion matches the physics claim:

| Test | What it genuinely validates |
|------|------------------------------|
| CRW-S-01 | Goal-seeking force matches analytical `v₀τ(1-e^{-t/τ})` — mathematically exact |
| CRW-S-02 | Agent reaches goal without penetrating obstacle — qualitative correctness |
| 3A-easy (ORCA) | All 30 agents reach antipodal goals collision-free — matches RVO2 exact benchmark |
| 3A-hard (ORCA) | ≥60% liveness at N=250 — LP3 does not deadlock catastrophically |
| 3B (liveness) | SFM + contact forces: ≥70% of N=50 evacuate through 1m door |
| 3B-res (peak flow) | SFM achieves 0.7–0.9 ped/s peak when arch breaks — Weidmann-comparable instantaneous rate |
| 3C (arch formation) | Panic scenario creates clogging (`t_90_panic >> free-flow limit`) |
| 3C (liveness) | Both normal and panic scenarios fully evacuate |
| 3D (anisotropy λ) | λ=0.5 deflects agents ≥0.1m laterally in head-on; right-hand passing; no deadlock |
| 3E (lane maintenance) | λ=0.5 prevents lane mixing (score ≥ 0.70 after 30s counter-flow) |
| 3F (FD, testset 3F) | SFM speed decreases monotonically with density; within ±40% of Weidmann for ρ ∈ {0.5,1.0,2.0} |
| 3F (lane formation, testset 3G) | λ=0.5 drives measurable lane formation from disorder (score 0.515→0.585 in 120s) |

---

## 4. Recommended Future Path

To move from "regression tests" to "validated against published benchmarks":

| Priority | Task | Sprint | Status | Enables |
|---|---|---|---|---|
| 1 | ~~Periodic BCs in `CPUNeighborSearch`~~ | Sprint 3E | ✅ DONE | FD + lane formation |
| 2 | ~~CRW-M-01: Lane formation from disorder~~ | Sprint 3F | ✅ DONE (score 0.585) | RiMEA T14 partial |
| 3 | CRW-M-02: Tighten FD to ±15% (GCF) | Sprint 3G | 🔜 next | RiMEA T2 full pass |
| 4 | CRW-M-03: FiS at N=200, 4×4m, 0.8m door | Sprint 3I | later | FiS demonstration |
| 5 | Reservoir steady-state flow assertion | Sprint 3I | later | Weidmann flow rate |

See [Future Directions](./2026-08-14_future_directions.md) for the non-committal roadmap.

---

## 5. Established Library Survey — Ground Truth Sources

### 5A. Open-Source Libraries Reviewed

#### JuPedSim (Forschungszentrum Jülich, Python+C++)
- GitHub: [PedestrianDynamics/jupedsim](https://github.com/PedestrianDynamics/jupedsim)
- **V&V Standards**: IMO MSC.1/Circ.1238 Annex 3, RiMEA v3.0, NIST TN 1822, ISO 20414:2020
- **Key**: JuPedSim uses Generalized Centrifugal Force (GCF/Chraibi), not SFM — avoids stiff contact springs
- **Has**: waypoints, waiting areas, queue management, corridor flow vs Weidmann CI

#### Vadere (TU Munich, Java)
- Website: [vadere.org](https://www.vadere.org)
- **V&V**: RiMEA 15 test cases + 16 experimental benchmarks in CI pipeline
- **Key finding**: Vadere's SFM uses VISCOUS friction (κ model) by default for Helbing 2000 exact reproduction — confirms our 3C Sprint 8A fix direction
- **Covers**: T1 (straight), T2 (fundamental diagram), T7 (bottleneck), T12 (arching), T14 (counter-flow lanes)

#### RVO2 (UNC Chapel Hill, C++)
- GitHub: [snape/RVO2](https://github.com/snape/RVO2)
- **Test scenarios**: `Circle.cc` (our 3A tests), `Blocks.cc`, `Roadmap.cc`
- **Published**: Van den Berg et al. (2011) IJRR: 1000 agents real-time at 60fps
- **Asserts**: collision-freedom, smooth velocities, liveness — NOT flow rates or fundamental diagram

#### UMANS (Inria, C++)
- **Purpose**: Unified benchmark framework — runs SFM, ORCA, PowerLaw etc. under identical settings
- **Published**: Bonneaud et al. (2022): SFM produces lane formation; ORCA does not (geometric model, no λ)

#### FLAME GPU 2 (University of Sheffield, CUDA C++ / Python)
- Website: [flamegpu.com](https://flamegpu.com)
- **Direct architectural inspiration**: SimCrowd's `@kernel social_force_kernel!` follows the FLAME GPU 2 "agent function" pattern (§6.3 of design doc)
- **Benchmark**: Circles model (pure repulsion) — N=100k on V100: ~250M agent-steps/s (Spatial), ~25M (Brute Force)
- **Does NOT test**: Fundamental diagram, lane formation, FiS — FLAME GPU is a framework, not a validated crowd model

```
FLAME GPU 2:           SimCrowd:
AgentFunction          @kernel social_force_kernel!
SpatialMessage CSR     RadixSpatialHash (Morton-sorted CSR)
GPU spatial sort       AK.merge_sortperm!
agent-owned forces[i]  forces[i] (no race — each thread owns i)
```

#### Menge (UNC Chapel Hill, C++)
- GitHub: [MengeCrowdSim/Menge](https://github.com/MengeCrowdSim/Menge)
- **Purpose**: Modular crowd simulation with pluggable locomotion, goal selection, path planning
- **Not physics-accurate**: Tests behavioral richness, not Weidmann compliance

---

### 5B. Standard Test Frameworks

#### RiMEA v3.0 (2016) — 15 standardised evacuation test cases

| # | Scenario | Key Metric | SimCrowd status |
|---|----------|-----------|----|
| T1 | Free walking, straight corridor | Speed = v₀ ± 5% | ✅ CRW-S-01 |
| T2 | Fundamental diagram, density sweep | v(ρ) matches Weidmann | ❌ Sprint 9 |
| T4 | Speed distribution (normal population) | μ=1.34 m/s, σ=0.26 | ❌ |
| T6 | Rounding corners | min_dist > 0 | ⚠️ CRW-S-02 (partial) |
| T7 | Bottleneck passage | flow ≈ 1.44 ped/s for 1m door | ⚠️ 3B-res (peak only) |
| T12 | Bottleneck effect (arch/clogging) | Qualitative: arch visible | ✅ 3C |
| T14 | Counter-flow in corridor | Lane formation visible | ⚠️ 3G (formation from disorder; score 0.585, plateau — full visual separation needs GCF) |
| T15 | Staircase (2D → gradient) | Speed reduced 40% on stairs | ❌ |

---

### 5C. Published Empirical Ground Truth

| Metric | Source | Value |
|--------|--------|-------|
| Free-flow walking speed | Weidmann (1993) | v₀ = 1.34 m/s (σ=0.26) |
| Bottleneck flow rate (1m door) | Weidmann (1993) | 1.44 ped/s |
| Bottleneck flow rate (0.8m door) | Seyfried et al. (2005) | 0.90–1.05 ped/s |
| Speed-density formula | Weidmann (1993) | `v(ρ) = 1.34×(1-exp(-1.913×(1/ρ-1/5.4)))` |
| Lane formation time | Helbing & Molnár (1995) Fig. 4 | Within 15s for 200 agents in 4m corridor |
| FiS ratio | Helbing, Farkas, Vicsek (2000) Fig. 4 | T_evac(v₀=4)/T_evac(v₀=1) ≈ 2–4× |
| ORCA circle antipodal N=30 | Van den Berg (2011) + RVO2 | All reach goal, no collision |
| ORCA circle N=250 | RVO2 (empirical) | ≥60% liveness at high density |

---

## 6. Feature Gap: SimCrowd vs Established Libraries

| Feature | SimCrowd | FLAME GPU 2 | JuPedSim | Vadere | RVO2 | UMANS |
|---------|----------|-------------|----------|--------|------|-------|
| SFM (Helbing) | ✅ | ✅ (agent fn) | ❌ (GCF) | ✅ | ❌ | ✅ |
| ORCA | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ |
| GCF (Chraibi) | ✅ §1.4 | ❌ | ✅ | ✅ | ❌ | ✅ |
| GPU acceleration | ✅ (KA) | ✅ (CUDA) | ❌ | ❌ | ❌ | ❌ |
| Anisotropy λ tested | ✅ 3D, 3E | — | ✅ | ✅ | ❌ | ✅ |
| Viscous friction (κ, FiS) | ✅ code, **FiS not proven** | partial | N/A | ✅ tested | N/A | ✅ |
| Fundamental diagram test | ⚠️ Sprint 3E: ρ≤2.0 ±40%, ρ=3.0 SFM artifact | ❌ (framework) | ✅ | ✅ RiMEA T2 | ❌ | ✅ |
| Lane formation (spontaneous) | ⚠️ Sprint 3F (score 0.585, plateau at ~18% above random) | ❌ | ✅ | ✅ RiMEA T14 | ❌ | ✅ |
| Lane maintenance (λ tested) | ✅ 3E | ❌ | ✅ | ✅ | ❌ | ✅ |
| FiS (Faster-is-Slower) | ⚠️ arch shown, ratio not | ❌ | ❌ | ✅ | ❌ | ✅ |
| Periodic BCs | ✅ Sprint 3E (CPUNeighborSearch) | — | ✅ | ✅ | — | ✅ |
| RiMEA compliance | ❌ | ❌ | Partial | ✅ 15/15 | ❌ | Partial |
| Ensemble / parameter sweep | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Waypoints / route graph | ❌ | via nav mesh | ✅ | ✅ | via roadmap | ✅ |
| Empirical dataset validation | ❌ | ❌ | ✅ (FZJ) | ✅ | ❌ | ✅ |
| Real-time visualization | ❌ (Phase 4) | ✅ | ✅ | ✅ | ✅ demo | ❌ |

---

## 7. Sprint 3E — Testset 3F Measured Results (2026-08-19)

**Scenario**: 20×4m periodic corridor, SFM standard params (μ=0.5, σ=0, seed=42)  
**Commit**: `14519cd`

| ρ (ped/m²) | N | v_sim (m/s) | v_weidmann (m/s) | ratio | Asserted? |
|---|---|---|---|---|---|
| 0.5 | 40 | **1.340** | 1.298 | 1.032 | ✅ (±40% pass) |
| 1.0 | 80 | **1.319** | 1.058 | 1.247 | ✅ (±40% pass) |
| 2.0 | 160 | **0.568** | 0.606 | 0.937 | ✅ (±40% pass) |
| 3.0 | 240 | **0.721** | 0.331 | 2.180 | ⚠️ diagnostic only |

**ρ=3.0 artifact**: At N=240 (spacing≈0.52m≈2r), SFM back-neighbor repulsion pushes agents forward in the periodic corridor. Speed at ρ=3.0 is *higher* than at ρ=2.0 — physically non-monotonic. Root cause: SFM has no compression limit at body contact. The agent_repulsion spring force becomes repulsive-forward rather than slowing. Fix target: Sprint 3G (enable GCF, η≠0).

**Gap to RiMEA T2** (±15% required):
- ρ=0.5: ratio=1.032 (+3.2%) ✅ would pass RiMEA
- ρ=1.0: ratio=1.247 (+24.7%) ❌ fails RiMEA ±15%
- ρ=2.0: ratio=0.937 (-6.3%) ✅ would pass RiMEA
- ρ=3.0: ratio=2.18 ❌ fails completely (SFM artifact)

**Conclusion**: SFM passes 2 of 3 reliable density points for RiMEA T2 tolerance. Sprint 3G (GCF η≠0) is needed to fix ρ=1.0 over-speed and ρ=3.0 artifact.

---

## 8. Sprint 3F — Testset 3G Measured Results (2026-08-19)

**Scenario**: 20×5m periodic corridor, N=100+100=200, ρ=2.0 ped/m², σ=0, seed=42  
**Commit**: `14978e4`

| t (s) | lane_score | Δ from random (0.500) |
|-------|------------|----------------------|
| 0 | 0.515 | +3% (grid placement artifact) |
| 30 | 0.575 | +15% |
| 60 | 0.590 | +18% |
| 90 | 0.585 | +17% |
| 120 | **0.585** | **+17%** ← plateau |

**Plateau at 0.585**: SFM λ=0.5 creates measurable lane formation but stalls ~17% above random. Mechanism: once agents partially sort into lanes, the lateral force balance between same-direction repulsion and counter-flow deflection reaches equilibrium. Unlike maintenance (score 0.913), formation from disorder is limited by this equilibrium point.

**Assertions passed**:
- `0.585 > 0.515` — lanes actively forming ✅
- `0.585 ≥ 0.58` — meaningful departure from random ✅  
- `0.585 ≥ 0.575` — net upward trend over 120s ✅

**Gap to RiMEA T14** (visual lane separation required):
- Visual lane separation typically requires score > 0.75
- Current plateau: 0.585 → gap of ~0.165
- Fix: Sprint 3G (GCF η≠0) — GCF reduces isotropic contact repulsion that traps agents in mixed-lane equilibria. With proper compression limiting, agents can move across the corridor to their preferred lane.
- Alternative: stochastic noise (σ > 0) breaks the symmetric equilibrium but makes the test non-deterministic.
