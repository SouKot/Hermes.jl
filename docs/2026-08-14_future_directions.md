# Hermes.jl / SimCrowd — Future Directions

**Date**: 2026-08-14  
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

## 2. Menge-Style Behavioural State Machine (Near-Term Priority)

### What it is
[Menge](https://github.com/MengeCrowdSim/Menge) (UNC Chapel Hill) implements a **Finite State Machine (FSM)** over agent behaviour. Each agent runs a behaviour state (e.g., `WALKING_NORMAL`, `EVACUATING_PANIC`), and the *locomotion model* bound to that state can be swapped independently:

```
Agent FSM:
  State: NORMAL    → locomotion: ORCA   (smooth, no shaking, numerically stable)
  State: DENSE     → locomotion: SFM    (body compression, friction, arch formation)
  State: EVACUATE  → locomotion: SFM + panic v₀
  
  Transitions:
    NORMAL → DENSE:    local density ρ > 3.5 ped/m²  (contact regime begins)
    DENSE  → NORMAL:   local density ρ < 2.5 ped/m²  (hysteresis to prevent chatter)
    *      → EVACUATE: alarm event
```

### Why it matters for SimCrowd
SimCrowd already has both engines fully implemented and tested independently (ORCA in 3A tests, SFM in 3B/3C tests). The missing piece is a **unified dispatch layer** that runs the appropriate engine per-agent based on local density. Benefits:
- Eliminates the SFM "shaking artifact" in low-density normal walking (currently visible in 3B time series: agents trickle inconsistently)
- Allows ORCA's collision-freedom guarantee to apply where it's tractable (ρ < 3.5 ped/m²)
- Makes the FiS effect properly testable: at panic, all agents switch to SFM, which naturally produces arch formation at Helbing densities

### Implementation sketch (not committed)
```julia
struct AgentBehaviourState
    mode::Symbol  # :normal, :dense, :evacuate
end

function select_locomotion!(world, density_field)
    for agent in agents(world)
        ρ = local_density(density_field, agent.position)
        if ρ > 3.5 && agent.mode == :normal
            agent.mode = :dense    # switch to SFM
        elseif ρ < 2.5 && agent.mode == :dense
            agent.mode = :normal   # switch to ORCA
        end
    end
end
```

### What would trigger pursuing this
- Once 3B flow rate validation is properly implemented with a reservoir setup (the current N=50 depletion test is insufficient)
- When we observe the shaking artifact causing test instability or incorrect physics

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

| Direction | Trigger |
|-----------|---------|
| RiMEA validation | Real-world safety engineering use case; partnership requiring documented compliance |
| Menge FSM dispatch | Shaking artefact causing failures; reservoir bottleneck test implemented |
| CSM normal-flow model | RiMEA fundamental diagram scenario; shaking in low-density tests |
| NavMesh decision layer | Mixed normal/emergency deployment; group cohesion required |
| Continuum macro model | N > 50,000 use case; venue-planning scenario |
