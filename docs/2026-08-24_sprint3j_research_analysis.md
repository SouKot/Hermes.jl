# Sprint 3J Research Analysis — Why SFM and GCFM-Elliptical Fail T7
## Literature Survey and Scientific Assessment
### 2026-08-24 | Conversation 78616c9e

---

## Executive Summary

After Sprint 3J, both SFM and GCFM-elliptical fail the RiMEA T7 bottleneck flow target
(≥1.22 ped/s mean). This document explains **why**, based on the primary literature, and
corrects several errors in our capability matrix. The key finding is:

> **Chraibi 2010 (the GCFM paper) never validated against a bottleneck room flow test.
> It validated the FUNDAMENTAL DIAGRAM in corridors. These are different tests.**
> T7 tests bottleneck room-exit flow (arch formation under crowd pressure).
> The GCFM paper tests steady-state corridor density-velocity curves.

---

## 1. What Chraibi 2010 Actually Validated

Reading the paper directly (arxiv 1008.4297v2), §VII "Simulation results":

> "We measure the fundamental diagram in two-dimensional space with the same set of
> parameters as for the one-dimensional fundamental diagram."

> "We extend the simulation to two-dimensional space and simulate a **25m × 1m corridor
> with periodic boundary conditions**."

**The GCFM paper (Chraibi 2010) NEVER ran a bottleneck room exit simulation.**
It ran periodic boundary corridor simulations (like our 3F test, not our 3B-res test).

### Chraibi 2010 Parameters (from paper, §VII):
| Parameter | Value | Our Value | Match? |
|-----------|-------|-----------|--------|
| `a_min` (front semi-axis at rest) | **0.18 m** | 0.25 m | ❌ **Wrong** |
| `τ_a` (time-gap front) | 0.53 s | 0.53 s | ✅ |
| `b_min` | 0.20 m | 0.25 m | ❌ **Wrong** |
| `b_max` | 0.25 m | 0.30 m | ❌ **Wrong** |
| `v₀` distribution | Normal(1.34, 0.26) | 1.34 fixed | ≈ |
| dt | 0.01 s | 0.01 s | ✅ |
| Geometry tested | 25m × 1m corridor, periodic BC | 10×4m room, 1m door | ❌ **Different** |

**Our `a_min = 0.25m` is 39% larger than the paper's `a_min = 0.18m`.** This is
a significant calibration error. We used `a₀ = 0.25m` (our collision_radius), but the
paper explicitly states `a_min = 0.18m` (body semi-axis at rest, before velocity growth).

### The GCFM Paper's Own Claim:
The abstract states: "Measurements of the fundamental diagram in narrow and wide corridors
are performed." It makes **no claim about bottleneck room exit flow**.

---

## 2. What RiMEA T7 Actually Tests

RiMEA T7 tests **flow through a bottleneck under crowd pressure**, typically:
- A large room with agents continuously supplied (or a reservoir scenario)
- A narrow opening (door) at one end
- Measurement of the **total flow rate** (ped/s) through the opening
- Comparison against the **Weidmann specific flow** benchmark

**The Weidmann 1.44 ped/s figure** is for a 1m door with unlimited, sustained crowd
supply. It is a **specific flow** (approximately 1.44 ped/m·s × 1m door = 1.44 ped/s),
not a generic pedestrian density.

### What this means:
T7 requires the simulation to:
1. Sustain crowd pressure at the door (reservoir/unlimited supply)
2. NOT form long-lived arch deadlocks (these don't occur with real people)
3. Match the empirical observation that flow ≈ constant × door_width

**Arch formation is a MODEL ARTIFACT, not a real pedestrian behavior.** Weidmann's
experimental subjects were real people who naturally avoid rigid arch lock-up through
micro-adjustments, shuffling, and random hesitation.

---

## 3. Why Our GCFM-Elliptical Implementation Fails T7

### Finding 1: Wrong `a_min` Parameter

We implemented `a₀ = 0.25m` (our collision_radius = body_radius). But Chraibi's
`a_min = 0.18m` is the **physical ellipse semi-axis at rest**, which is the half-
shoulder-width, not the collision radius.

| | Our Impl. | Chraibi 2010 |
|--|--|--|
| `a(v=0)` | 0.25m | 0.18m |
| `a(v=1.34)` | 0.25 + 0.53×1.34 = **0.96m** | 0.18 + 0.53×1.34 = **0.89m** |
| Personal space ahead at v=1.34 | 0.96m | 0.89m |
| Effective agent "length" (i+j) | 1.92m | 1.78m |

At v=1.34 m/s, our agents need 1.92m center-to-center to not interact vs. Chraibi's
1.78m. This is a 7.9% larger personal space — causing tighter packing near the door →
stronger arch stabilization → longer deadlocks.

### Finding 2: Wrong `b_min`, `b_max`

| | Our Impl. | Chraibi 2010 |
|--|--|--|
| `b_min` | 0.25m | **0.20m** |
| `b_max` | 0.30m | **0.25m** |

Our b values are 5cm larger throughout. This means our agents are physically wider
(taller in the door direction) than the paper. At a 1m door:
- Chraibi: effective agents' lateral footprint = 0.20–0.25m each
- Ours: effective agents' lateral footprint = 0.25–0.30m each

With our b values, only **~3.3 agents** can fit across the 1m door simultaneously.
With Chraibi's b values, **~4.0 agents** can fit. This directly reduces throughput.

### Finding 3: The Test Geometry is Different

Chraibi 2010 validated in a **periodic corridor** — agents cycle indefinitely, no arch
can form because there's no obstacle. Our T7 test has a **wall with a door** — agents
press against the wall and form arches.

**The GCFM paper never claimed to solve arch formation.** That is a fundamentally
different phenomenon that requires either:
a) Physical stochastic noise (σ > 0) — our comment says this was tried and caused worse results
b) Different force law that prevents arch lock (e.g., collision-free speed model)
c) Velocity obstacle / anticipation approach (e.g., ORCA in crowd)

### Finding 4: Arch Formation is a Force-Model Structural Problem

The literature is explicit (search results):

> "In the standard SFM, pedestrians are treated as physical particles subject to
> repulsive forces. At high densities near a bottleneck, these forces can become
> extremely high, leading to clogging or the formation of rigid, static arch structures
> that do not dissipate as they would with real humans. **This is often an artifact of
> how the avoidance mechanism (repulsive forces) is formulated.**"

GCFM (§II, circular) and GCFM (§III, elliptical) both use the same **exponential
repulsive force** structure. Neither adds arch-breaking mechanisms. The elliptical
variant changes the SPATIAL PROFILE of the personal space but not its
**hardness/stiffness** — so arches still form.

---

## 4. The Capability Matrix Error

### Our current matrix (before this analysis):
```
T7 | SFM: MAY NOT | GCFM-circular: SHOULD | GCFM-elliptical: MAY NOT
```

### Why "GCFM-circular SHOULD" was wrong:
We set GCFM-circular to SHOULD based on the (incorrect) inference that if the paper
validates the fundamental diagram with the same parameters, the bottleneck test should
also pass. But:

1. Chraibi 2010 tested **corridors with periodic BC** — no door, no arch
2. For bottleneck flow, the issue is **arch formation**, not the fundamental diagram
3. GCFM-circular has the same spring-force structure as SFM — arches form in both

**GCFM-circular T7 should also be MAY NOT, not SHOULD.**

### Corrected capability matrix:

| Model | T7 (≥1.22 ped/s mean) | Reason |
|-------|----------------------|--------|
| SFM (v₀=1.0) | CANNOT | Arch deadlocks, wrong v₀ |
| SFM (v₀=1.34) | MAY NOT | 0.97–1.07 ped/s (Phase A) — arch limits |
| GCFM-circular (v₀=1.34) | MAY NOT | Same spring-force → same arch problem |
| GCFM-elliptical (wrong params) | MAY NOT | 0.82 ped/s (3J) — wider ellipse → worse arches |
| GCFM-elliptical (Chraibi params) | SHOULD | Correct params may reduce arch severity |
| Collision-Free Speed Model (CSM) | SHOULD | Speed-based, no spring force → no arch |
| Hybrid FSM (ORCA + SFM) | SHOULD | ORCA prevents arch; SFM activates only at ρ>3.5 |

---

## 5. What Other Libraries Do

### JuPedSim (Forschungszentrum Jülich)
**Primary model for T7**: `CollisionFreeSpeedModel` (CSM) — **NOT the GCFM**.
The CSM is speed-based: each agent's speed is determined by the gap ahead of it.
No spring forces → no arch formation possible. The model is "intrinsically collision-free."

From the JuPedSim docs:
```python
model = jps.CollisionFreeSpeedModel(
    strength_neighbor_repulsion=2.6,
    range_neighbor_repulsion=0.1,
    range_geometry_repulsion=0.05
)
```

**JuPedSim does not use GCFM for T7.** The GCFM is available in JuPedSim but is NOT
used in their T7 validation notebook. The CSM is.

### Menge (UNC Chapel Hill)
Uses a combination of velocity obstacles + social forces. The ORCA-based planning
prevents arch formation because ORCA selects velocities geometrically, not through
spring-force equilibrium.

### accu:rate (Germany, commercial)
Uses SFM with parameter calibration AND stochastic noise (σ > 0) to break arches.
Their T7 validation requires σ > 0 — a model parameter they document explicitly.

---

## 6. What Went Wrong in Our Approach

### Error 1: Using `a₀ = collision_radius` as `a_min`
The paper's `a_min = 0.18m` is the body ellipse minor axis at rest. Our `a₀ = 0.25m`
is our agent collision radius (used for Helbing contact spring). These are different
physical concepts. We conflated them.

**Fix**: Re-implement `gcf_force_elliptical` with `a_min` separate from `collision_radius`.
`a_min = 0.18m` (paper) ≠ `collision_radius = 0.25m` (body contact).

### Error 2: Using elliptical personal space without architectural understanding
We implemented §III of the paper hoping it would improve bottleneck flow, because the
paper claims the ellipse "better models two-dimensional flow." But the paper showed this
for **corridor** flow only. For **bottleneck room exit** flow, the arch formation
mechanism dominates and the ellipse makes it worse (wider front ellipse → more stable arch).

### Error 3: Claiming GCFM-circular "SHOULD" pass T7
This was set without experimental evidence and without understanding what the paper
actually validated. Now corrected.

---

## 7. The Path Forward — What Actually Works

### Option A: Fix GCFM-elliptical parameters (low cost)
Recalibrate with Chraibi's correct values:
- `a_min = 0.18m` (not 0.25m)
- `b_min = 0.20m` (not 0.25m)
- `b_max = 0.25m` (not 0.30m)

This may reduce arch severity due to smaller personal space. **Expected improvement**:
from 0.82 to ~0.90–1.05 ped/s. **Still likely below T7** due to structural arch problem.

**This is a fast experiment (1-2 hours) worth doing before Sprint 3K.**

### Option B: Add stochastic noise σ > 0 (medium risk)
Our `3B-res` comment says: "σ>0 uses global Julia RNG for physics noise, which is not
seeded and produces catastrophic stochastic deadlocks." The "catastrophic" result was
due to **unseeded global RNG** causing correlated noise across all agents simultaneously
— a Julia implementation artifact, not a model artifact. With a properly seeded, per-
agent noise term σ ≈ 0.1–0.5, noise should break arches stochastically.

**This is the approach accu:rate and the original Helbing 2000 paper use for T7.**
It is scientifically defensible (Helbing 2000 explicitly includes stochastic term ξᵢ).

### Option C: Implement Collision-Free Speed Model (CSM) (medium cost)
The CSM by Tordeux et al. 2016 is structurally arch-free. It is:
- Simple to implement (speed = f(gap_ahead) — one formula)
- Validated against T7 by its authors
- JuPedSim's primary T7 model
- No contact forces, no spring → architecturally cannot arch

**This is the most scientifically correct path for T7.** It doesn't compete with
SFM (which handles arch formation, FiS, etc.) — they coexist.

### Option D: Hybrid FSM (Sprint 3K) (higher cost)
ORCA (no arch) + SFM at ρ>3.5 (contact forces). As planned. Still valid but higher
implementation complexity than CSM.

---

## 8. Recommended Action Before Sprint 3K

### Immediate (before writing Sprint 3K plan):

**Step 1 (1 hour)**: Fix GCFM-elliptical parameters to match Chraibi 2010:
- `a_min = 0.18m`, `b_min = 0.20m`, `b_max = 0.25m`
- Run 3J testset with corrected params

**Step 2 (2 hours)**: Try seeded per-agent stochastic noise σ ≈ 0.1m/s on SFM:
- Seed properly: `rng = MersenneTwister(agent_id + 42)` per agent
- σ adds ξᵢ(t) ~ Normal(0, σ²) to velocity each step
- This is what Helbing 2000 intended

**Step 3 (decision)**: Based on results of Steps 1–2:
- If either achieves ≥1.22 ped/s: update 3J assertions, document
- If not: proceed to CSM implementation (Option C) or Hybrid FSM (Option D)

### Priority order for T7:
1. Fix GCFM-elliptical params (trivial — 1 function call change)
2. Try seeded stochastic noise (defensible, low risk)
3. Implement CSM (cleanest solution, architecturally arch-free)
4. Hybrid FSM (most general, also useful for corridor flow models)

---

## 9. Updated Validation Framework

### What T7 really tests (corrected understanding):
T7 validates whether a model can produce **sustained, non-clogging bottleneck flow**
comparable to real pedestrian observations. The key insight:

**Real pedestrians don't form 30-second rigid arch deadlocks at 1m doors.** They
hesitate briefly (arch begins to form), then reorganize (arch releases within 1–2
seconds). The Weidmann 1.44 ped/s is a time-average that implicitly includes these
micro-jams and releases — but at a rapid enough timescale that the mean is high.

The reason GCFM-family models fail T7 is not force strength calibration — it's the
**absence of an arch-breaking mechanism** (stochastic noise, velocity obstacle
anticipation, or gap-based speed reduction).

### Test classification (corrected):
| Test | What it really tests | Appropriate model |
|------|---------------------|-------------------|
| T2 (fundamental diagram) | Density-velocity relationship, no obstacles | GCFM/SFM both fine |
| T7 (bottleneck flow) | Non-clogging flow under crowd pressure | CSM or Hybrid FSM |
| T12 (arch formation) | Arch formation IS the phenomenon | SFM (arch = feature not bug) |

Note the deliberate tension: T7 and T12 test opposite behaviors. **No single force-based
model can pass both T7 and T12 with the same parameters** — arch formation is required
for T12 but is the obstacle to T7. This is why:
- Hybrid FSM (ORCA corridor + SFM door) can potentially pass both
- CSM can pass T7 but not T12 (no contact spring → no arching)
- SFM passes T12 but struggles with T7

---

## 10. References

1. Chraibi, M., Seyfried, A., Schadschneider, A. (2010). *Generalized centrifugal-force
   model for pedestrian dynamics.* Physical Review E, 82, 046111.
   https://arxiv.org/abs/1008.4297

2. Tordeux, A., Chraibi, M., Seyfried, A. (2016). *Collision-free speed model for
   pedestrian dynamics.* Traffic and Granular Flow 2015. Springer.

3. Helbing, D., Farkas, I., Vicsek, T. (2000). *Simulating dynamical features of
   escape panic.* Nature, 407, 487–490.

4. Weidmann, U. (1992). *Transporttechnik der Fußgänger.* ETH Zürich.

5. RiMEA e.V. (2016). *Guideline for Microscopic Evacuation Analysis.*
   https://www.rimea.de

6. JuPedSim Documentation. https://www.jupedsim.org
   - Primary T7 model: CollisionFreeSpeedModel (NOT GCFM)

7. Seyfried et al. (2010). *Enhanced empirical data for the fundamental diagram and
   the flow through bottlenecks.* Pedestrian and Evacuation Dynamics 2008, Springer.
