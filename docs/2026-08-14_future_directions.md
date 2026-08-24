# Hermes.jl / SimCrowd — Future Directions

**Date**: 2026-08-14 (last updated: 2026-08-23 after Sprint 3I)  
**Status**: Non-committal. These are *informed possibilities*, not scheduled work.  
**Purpose**: Prevent good ideas from being forgotten without creating false commitment in the implementation plan.  
**Informed by**: [`crowd_simulation_discussion.md`](file:///home/sourabh/Documents/crowd_simulation_discussion.md) · architectural discussion 2026-08-14

> Items here graduate to [`2026-08-07_implementation_phases.md`](./2026-08-07_implementation_phases.md) only when a concrete sprint plan is agreed. Until then, adding phase numbers or checkboxes to these items is explicitly discouraged.

---

## 1. Proper Crowd Validation (RiMEA / IMO Framework)

### Why this matters
Our current tier-3 tests are *physics regression tests* — they confirm SFM and ORCA produce qualitatively correct behaviour. They are **not** validation certificates against empirical human data. The honest caveats are documented in [`implementation_plan.md §0`](file:///home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/implementation_plan.md).

Professional-grade crowd simulation libraries (JuPedSim, AnyLogic, SimWalk, Pedestrian Dynamics) validate against formal government and industry frameworks, not against raw Helbing parameter sweeps:

| Framework | Jurisdiction | Scope |
|-----------|-------------|-------|
| **RiMEA** v3.0 | Europe (Germany-led) | 14 scenarios: fundamental diagram, bottleneck, evacuation, merging flows |
| **IMO MSC.1/Circ.1238** | International Maritime | Vessel and cruise ship evacuation |
| **NIST TN 1822** | United States | Building evacuation, stairwell flow |
| **ISO 20414:2020** | International | General pedestrian simulation validation |

### What we would need to implement
- **RiMEA Scenario 4** (fundamental diagram): Reservoir setup — agents continuously enter from one side to maintain constant density. Measure steady-state speed at ρ ∈ {0.5, 1.0, 2.0, 3.5, 5.0} ped/m². Assert within ±15% of Weidmann (1993) empirical curve.
- **RiMEA Scenario 7** (bottleneck): N=200, 4×4m room, 0.8m door. Measure flow rate after steady state. Assert within ±20% of Weidmann.
- **RiMEA Scenario 6** (bidirectional corridor): Proper lane formation metric — not mean speed, but a lane segregation score (fraction of agents moving in opposite directions separated by y-coordinate).

### What would trigger pursuing this
- SimCrowd being used in a real safety-engineering context (stadium, transit station, venue design)
- A potential commercial or research partnership requiring documented compliance

---

## 2. Hybrid FSM (Density-Triggered Locomotion Dispatch) — Sprint 3K

> **Status (2026-08-23)**: TRIGGERED. Pre-implementation research phase required before any code.  
> **Depends on**: Sprint 3J (GCFM-elliptical) completing first — both ORCA and SFM must be individually validated before combining.

### What it is
[Menge](https://github.com/MengeCrowdSim/Menge) (UNC Chapel Hill, Curtis et al. 2016) implements a **Finite State Machine (FSM)** over agent behaviour. Each agent runs a behaviour state (e.g., `WALKING_NORMAL`, `EVACUATING_PANIC`), and the *locomotion model* bound to that state can be swapped independently:

```
Agent FSM:
  State: NORMAL    → locomotion: ORCA   (smooth, no shaking, numerically stable)
  State: DENSE     → locomotion: SFM    (body compression, friction, arch formation)
  State: EVACUATE  → locomotion: SFM + panic v₀
  
  Transitions:
    NORMAL → DENSE:    local density ρ > 3.5 ped/m²  (contact regime begins)
    DENSE  → NORMAL:   local density ρ < 2.5 ped/m²  (hysteresis to prevent chatter)
    *      → EVACUATE: alarm event (DES integration point)
```

### Pre-Implementation Research Requirement (mandatory for Sprint 3K)

Before any implementation, the following must be documented in a `docs/sprint3k_hybrid_fsm_research.md` file:

#### A. Established Libraries That Implement Hybrid FSM

| Library | Approach | Published reference | Shortcomings documented? |
|---------|----------|--------------------|-----------------------------|
| **Menge** (UNC Chapel Hill) | FSM over pluggable locomotion models; density-triggered state transitions; ORCA + SF plug-ins | Curtis, Best, Manocha (2016) *J. Autonomous Robots* | Yes: state chatter at threshold density; no continuous blending |
| **JuPedSim** (FZ Jülich) | Uses model layers: GCFM-elliptical for normal walking, activates body-contact forces only when physical overlap occurs (implicit FSM) | Chraibi et al. 2010; Tordeux 2016 | Yes: contact activation threshold is sensitive to `cr` param |
| **STEPS** (Mott MacDonald) | Commercial; density-adaptive speed-reduction, no published model | Internal | No public paper |
| **MassMotion** (Oasys) | Density-triggered profile switching (normal/emergency/evacuation) | Internally documented | Partial — `flow_model_switching` paper 2019 |
| **UMANS** (Claes et al. 2022) | Pluggable simulation pipeline; ORCA + SFM as separate plugins; no density-triggered FSM | UMANS 2022 | Yes: agents can only use one model per run |

**Key finding from literature**: Menge is the most general published Hybrid FSM design. Its key architectural decisions:
1. **Pluggable behaviour graph** — states and transitions are configured (not hardcoded), similar to a BehaviorTree
2. **Locomotion model is per-state** — any state can bind any locomotion model; the FSM is agnostic to physics
3. **Density estimated from neighbor search** — exact same neighbor list used for force computation, zero extra cost
4. **Hysteresis band required** — without it, agents flip states every step at threshold (chatter instability)

#### B. Known Shortcomings to Address in Sprint 3K

| Shortcoming | Source | Our mitigation |
|-------------|--------|----------------|
| **State chatter** at ρ ≈ threshold | Menge paper §5.2 | Hysteresis band (ρ_off < ρ_on), per-agent mode history |
| **Discontinuous force** at transition | JuPedSim internal tests | Blend window: interpolate forces for 1–2 steps at mode switch |
| **Density estimation noise** | All libraries | Use 3-step rolling average of local ρ per agent |
| **No arch at moderate density** | This codebase (see §12 caveats) | Documented explicitly; T12/FiS remain SFM-only tests |
| **Non-reciprocal transitions** | Menge §5.3 | If agent i switches to SFM but neighbors are ORCA, forces are asymmetric — document and test |

#### C. Target Design for Sprint 3K

The Sprint 3K implementation should be the **most general, modular, configurable** version consistent with the codebase's ECS architecture:

```julia
# Target Sprint 3K struct (based on Menge §3 architecture)
Base.@kwdef struct HybridFSMParams{F<:AbstractFloat}
    # Density thresholds (Menge defaults: 3.5 / 2.5 ped/m²)
    ρ_on            :: F = F(3.5)      # ORCA → SFM threshold (ped/m²)
    ρ_off           :: F = F(2.5)      # SFM → ORCA threshold (ped/m²); must be < ρ_on
    # Density estimation
    density_radius  :: F = F(2.0)      # neighbor search radius for local ρ estimate (m)
    density_avg_n   :: Int = 3         # rolling average window (steps) to reduce chatter
    # Blend window (force continuity at mode switch)
    blend_steps     :: Int = 2         # number of steps to interpolate forces at transition
    # Underlying model params (reuse existing structs — no duplication)
    sfm_params      :: SFMParams{F}    # populated from existing SFMParams constructor
    orca_params     :: ORCAParams{F}   # populated from existing ORCAParams constructor
end
```

This design:
- Is configured at World-setup time (no hardcoded thresholds)
- Reuses existing `SFMParams` + `ORCAParams` — no new force kernels
- Has explicit `blend_steps` for force continuity
- Documents the non-reciprocal transition limitation explicitly

### Why it matters for SimCrowd
SimCrowd already has both engines fully implemented and **canonically tested** (ORCA in 3A/3I-a/b/c tests, SFM in 3B/3C tests). The missing piece is a **unified dispatch layer** that runs the appropriate engine per-agent based on local density. Benefits:
- Eliminates the SFM "shaking artifact" in low-density normal walking
- Allows ORCA's collision-freedom guarantee to apply where it's tractable (ρ < 3.5 ped/m²)
- Makes the FiS effect properly testable: at panic, all agents switch to SFM → arch formation
- Enables DES-triggered evacuation mode (alarm event → all agents switch to SFM+panic v₀)

### What would trigger pursuing Sprint 3K
- Sprint 3J (GCFM-elliptical) is complete
- Pre-implementation research (`docs/sprint3k_hybrid_fsm_research.md`) is written and reviewed
- Pre-implementation research includes: reading Menge §3–5, JuPedSim hybrid tests, UMANS 2022

---

## 3. Collision-Free Speed Model (CSM)

### What it is
The **Collision-Free Speed Model** (Tordeux, Chraibi et al. 2016; used by JuPedSim as primary normal-flow model) replaces spring-force repulsion with a speed-reduction rule based on the gap ahead:

```
v_i = v₀ × f(gap_ahead_i)

where gap_ahead_i = distance to nearest agent in direction of travel
      f(gap) → 1 as gap → ∞ (free flow)
      f(gap) → 0 as gap → 0 (stopped)
```

No spring force. No oscillation. The agent simply walks slower when the person ahead is close.

### Why it matters
SFM produces a known artefact: agents oscillate (shake) at low density or near walls because the repulsion force pushes in both directions simultaneously. This is visible in our 3B time series as erratic evacuation counts (e.g., 0 in one 10s window, 7 in the next). CSM eliminates this while preserving the density-speed relationship that produces the fundamental diagram.

JuPedSim uses CSM for normal walking and only activates SFM body-contact forces (`k`, `κ`) when physical contact actually occurs. This two-layer approach is cleaner than running full SFM everywhere.

### What would trigger pursuing this
- If the shaking artefact produces consistent test failures or physically unrealistic outputs at low density
- When implementing the RiMEA fundamental diagram scenario (which requires clean speed-vs-density curves)

---

## 4. Navigation Decision Layer (MEC / NavMesh)

### What it is
Commercial tools like **Pedestrian Dynamics (INCONTROL)** use a **Macro Element Content (MEC) network** — a sparse graph of pedestrian decision points (turnstiles, stairwells, queue lines, junctions) layered above the physical simulation. Agents make discrete *routing decisions* at nodes, rather than continuously reacting to force fields.

This is closer to how humans actually navigate: we plan a route ("I'll take the left stairwell"), commit to it until a decision point, then re-evaluate. We do not continuously integrate force vectors from every person around us.

Current SimCrowd navigation: Eikonal potential field (gradient descent to exit). This is a force-field approach — correct for emergency egress physics, but limited for normal operational flow (queuing, turnstile selection, service decision points).

### What it would enable
- Heterogeneous agent populations: some agents are familiar with the venue (take optimal route), others are tourists (follow signs, take obvious path)
- Explicit queue modelling: agents join the shorter of two queues based on visible length
- Group cohesion: families bind to the slowest member's path decision

### Reference architecture
```
Tier 1 (Global):   A* over NavMesh   → group routing + exit assignment
Tier 2 (Mid):      ORCA / CSM        → collision-free trajectory
Tier 3 (Contact):  SFM forces        → density > 3.5 ped/m² only
```
This is the architecture recommended in the external discussion document and is consistent with JuPedSim's layered design.

### What would trigger pursuing this
- Real-world deployment context requiring mixed normal/emergency behaviour
- A specific use case (transit station, stadium) where route-choice decisions matter
- Only after Tiers 2 and 3 (ORCA and SFM) are properly validated

---

## 5. Continuum / Macroscopic Models

### What it is
At very large scales (50,000+ agents — a full stadium evacuation), individual-agent simulation becomes computationally intractable. **Hughes' Continuum Theory** (2002) treats the crowd as a fluid governed by coupled PDEs:
- **Continuity equation**: conservation of crowd mass
- **Eikonal equation**: optimal path computation (equivalent to a potential field)

Computational cost scales with grid size, not agent count — making it practical for venue-scale predictions.

### Relevance to Hermes
SimCrowd is architected for GPU-resident agent simulation (KernelAbstractions.jl). At N=100k+ on GPU, individual SFM may still be tractable. But for planning-level questions ("how long to evacuate a 80,000-seat stadium under three exit scenarios?"), a macroscopic model running in seconds would be more useful than a microscopic model running in hours.

A hybrid approach: macroscopic model for venue-level planning, SimCrowd microscopic for specific bottleneck zones at high density.

### What would trigger pursuing this
- A specific large-venue client or use case (N > 50,000 required)
- After microscopic validation is established (it would be difficult to validate a macro model without a validated micro model for cross-checking)

---

## 6. What is Explicitly Out of Scope

| Direction | Why not |
|-----------|---------|
| **ML/CVAE trajectory prediction** | Black-box, non-auditable, incompatible with safety certification (RiMEA/IMO). Trained on trajectory datasets that don't include panic/emergency behaviour. Wrong direction for a physics-based safety library. |
| **Unity/Unreal game engine integration** | ORCA variants used in game engines are not calibrated for physical realism. Hermes is a scientific simulation platform, not a visual effects tool. |
| **Cellular Automata** | Too coarse for our use cases. Useful for quick worst-case estimates but cannot produce the density-dependent dynamics that SFM/ORCA provide. |

---

## Trigger Conditions Summary

| Direction | Trigger | Status (2026-08-23) |
|-----------|---------|---------------------|
| RiMEA T2 fundamental diagram | Physics-correct GCFM + calibration | ✅ DONE (Sprint 3F, commit `557028e`) |
| RiMEA T4 speed distribution | Speed heterogeneity population test | ✅ DONE (Sprint 3H, commit `5e2635f`) |
| ORCA canonical validation | Cross-validate vs RVO2/UMANS benchmarks | ✅ DONE (Sprint 3I, commit `afc8f59`) |
| **Menge FSM dispatch** | **Reservoir bottleneck test exists; T7 gap is the trigger** | ⚠️ **TRIGGERED — Sprint 3J next** |
| GCFM-elliptical (Chraibi 2010 §III) | T7 gap persists after Menge FSM attempt | ⏳ Pending Sprint 3J result |
| CSM normal-flow model | RiMEA T2/T7 gap; SFM shaking in low-density tests | ⏳ Not yet triggered |
| NavMesh decision layer | Mixed normal/emergency deployment; group cohesion required | ⏳ Not yet triggered |
| Continuum macro model | N > 50,000 use case; venue-planning scenario | ⏳ Not yet triggered |
| RiMEA full compliance audit | Real-world safety engineering use case | ⏳ After Sprint 3K |
