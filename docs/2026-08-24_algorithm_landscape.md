# Algorithm Landscape in Pedestrian Simulation
## Strengths, Weaknesses, Library Survey, and Hybrid Design
### 2026-08-24 | Research for Antigravity/SimCrowd

---

## 0. What We Have Implemented in SimCrowd

Yes — your understanding is correct. SimCrowd currently implements three locomotion algorithms:

| Algorithm | Type | Paper | Status |
|-----------|------|-------|--------|
| **SFM** (Social Force Model) | Force-based (2nd order) | Helbing & Molnár 1995, Helbing et al. 2000 | ✅ Implemented |
| **GCFM** (Generalized Centrifugal Force Model) | Force-based (2nd order) | Chraibi, Seyfried, Schadschneider 2010 | ✅ Implemented (circular §II + elliptical §III) |
| **ORCA** (Optimal Reciprocal Collision Avoidance) | Velocity-based (1st order) | Van den Berg et al. 2008, 2011 | ✅ Implemented |
| **CSM** (Collision-Free Speed Model) | Speed-based (1st order) | Tordeux, Chraibi, Seyfried 2016 | ❌ Not implemented (planned) |

---

## 1. SFM — Social Force Model

### What it is
Pedestrians are modeled as particles responding to three forces:
- **Driving force**: acceleration toward desired velocity with relaxation time τ
- **Repulsive force**: psychological social distance from others (exponential decay)
- **Contact forces** (Helbing 2000 extension): body compression spring + tangential friction

The 2000 extension (panic model) introduced the contact forces (k·δ normal, κ·δ·Δv tangential)
which are what produce arch formation and the "faster-is-slower" effect.

### Strengths
1. **Emergent collective phenomena**: Lane formation, oscillations at bottlenecks, self-organization
   in evacuation — all reproduced qualitatively from simple force rules.
2. **Arch formation** (T12): The contact spring model produces realistic interlocking arches at
   bottlenecks. This is a feature, not a bug — it's observed in real granular/panic flows.
3. **Faster-is-slower effect** (FiS): Counterintuitive but empirically validated. SFM with
   contact forces reproduces this correctly.
4. **Physically interpretable parameters**: A, B (repulsion), k, κ (contact) have physical units
   and relate to measurable quantities.
5. **Well-validated**: The most studied model in pedestrian dynamics. Extensive literature,
   calibration datasets, and empirical comparisons exist.
6. **Panic behavior**: With v₀→high, contact forces produce physically reasonable extreme-density
   dynamics.

### Weaknesses
1. **Arch deadlocks in deterministic simulations** (T7): Without stochastic noise σ > 0, arches
   become permanent. Weidmann empirical data assumes real people who break arches stochastically.
   **Fix**: Use σ > 0 (seeded per-agent noise). Helbing 2000 explicitly includes this term.
2. **Parameter overlap/oscillation duality**: Increasing A (repulsion) to prevent overlap causes
   oscillations; decreasing it allows penetration. Must find a narrow operating range.
3. **Particle penetration at very high density**: With soft repulsion, agents can overlap at
   extreme densities (>6 ped/m²). The contact spring partially compensates but doesn't fully
   prevent it.
4. **No explicit body shape**: Standard SFM uses circular agents with isotropic repulsion.
   Underestimates lateral compression.
5. **Sensitivity to v₀ calibration**: Our Phase A finding — using v₀=1.0 instead of v₀=1.34
   (Weidmann 1993) produced 44% of T7 target. v₀ is the most sensitive parameter.
6. **Cannot reproduce realistic corridor flow alone** (T7 without noise): Mean flow is depressed
   by arch deadlocks unless σ > 0 breaks them.

### Best for
- Emergency evacuation (high density, panic, FiS, arch formation)
- T12 (arch formation test)
- Any scenario where physical contact forces matter

### T7 achievability
**MAY NOT** without σ>0. **SHOULD** with properly seeded per-agent noise σ≈0.1–0.3 m/s.
PTV Viswalk uses SFM + σ calibration to pass T7.

---

## 2. GCFM — Generalized Centrifugal Force Model

### What it is
Evolution of the earlier Centrifugal Force Model (Yu et al. 2005). Uses:
- Same driving force as SFM
- Repulsive force dependent on relative velocity vᵢⱼ (not just distance)
- Circular version (§II): dynamic interaction radius D_i(v) = a₀ + η·‖vᵢ‖
- Elliptical version (§III): velocity-direction elliptic semi-axes a(v), b(v)
- No contact spring forces (unlike SFM 2000)

### Strengths
1. **Eliminates particle penetration at moderate densities**: The velocity-adaptive D_i pushes
   agents apart before contact. Much better than SFM at moderate densities.
2. **Stable fundamental diagram**: No "duality" collapse if η is chosen correctly (per the
   overlapping/oscillation phase diagram). Reproduces Weidmann density-velocity curve.
3. **Elliptical body shape** (§III): Better physical realism — agents are wider at rest,
   narrower at speed. Fruin's "body ellipse" concept.
4. **Single set of parameters for corridor and single-file**: Validated with the same
   parameters across 1D and 2D corridor simulations (Chraibi 2010).
5. **No CDT (Collision Detection Technique) needed**: Unlike CFM (Yu 2005), the GCFM's
   force structure avoids the need for an external hard-constraint collision resolution step.

### Weaknesses
1. **Same structural arch problem as SFM**: Uses exponential repulsive potential. At
   bottleneck, agents press against wall → arch forms → no mechanism to break it.
   T7 fails for the same reason as SFM.
2. **No contact forces**: The absence of k·δ contact spring means GCFM cannot reproduce arch
   formation realistically for T12. Our T12 test (3C) uses SFM, not GCFM.
3. **Complex parameter calibration**: The η (speed factor), V₀ (strength), τ_a, b_min, b_max
   (ellipse) parameters interact non-linearly. Our 3J Sprint used wrong a_min (0.25 vs
   Chraibi's 0.18m), producing worse arches than the correct parametrization.
4. **Oscillations at extreme η**: If η is too large, the speed-dependent force produces
   backward oscillations. Must stay within the stable region of the phase diagram.
5. **Not validated for bottleneck room exit**: Chraibi 2010 validated only in periodic
   corridor. The paper makes no claim about room exit / T7 performance.

### Best for
- Fundamental diagram validation (T2) — this is what the paper validates
- Moderate-density corridor flow
- Scenarios where elliptical body shape matters and contact spring is not needed

### T7 achievability
**MAY NOT** with current parameters. **SHOULD** after correcting a_min=0.18m, b_min=0.20m,
b_max=0.25m — but still needs arch-breaking mechanism (σ>0 or density-mode dispatch).

---

## 3. ORCA — Optimal Reciprocal Collision Avoidance

### What it is
Velocity-obstacle based algorithm. Each agent computes a set of velocities that are
collision-free for a time horizon τ_h seconds. The "reciprocal" part means each agent
takes responsibility for half the avoidance. Implemented as a linear program (LP).

SimCrowd uses LP3 (3-constraint LP): forward half-plane constraint + 2 nearest-agent
velocity obstacles. Falls back to LP_full for dense scenarios.

### Strengths
1. **Mathematically guaranteed collision-free motion** (for sufficient time horizon)
2. **Smooth trajectories**: No spring oscillations. Motion is kinematically smooth.
3. **No arch formation at bottlenecks**: ORCA selects velocities geometrically —
   it will find a way through gaps without locking into an arch structure.
4. **Efficient for large-scale simulations**: O(N·k) per step where k = neighborhood size.
5. **Lane formation in corridor** (T14 / 3E): Without λ-anisotropy, ORCA doesn't form
   lanes — but with modified ORCA+direction, it can.
6. **Robot/AV applications**: Industry standard for autonomous vehicle and robot crowd
   navigation due to smooth, provably safe trajectories.

### Weaknesses
1. **"Freezing" in very dense crowds**: In high-density, narrow spaces, the LP becomes
   infeasible (no velocity is collision-free). Our LP3 fallback handles this but agents
   stop moving. This is the classical "freezing robot problem."
2. **No physical contact forces**: Cannot model body-to-body compression, FiS effect,
   or arch formation. T12 CANNOT pass (this is documented in our matrix).
3. **No social awareness**: All agents treated equally. No group dynamics, lane preference
   (λ), or cultural space norms.
4. **No lane formation**: ORCA without anisotropy (λ) produces no lane formation — lanes
   are a force-anisotropy phenomenon. UMANS 2022 confirms this.
5. **Reciprocal assumption breaks in mixed crowds**: If one agent is non-ORCA (e.g., SFM
   agent or a robot), the reciprocal assumption fails — the ORCA agent takes all avoidance
   burden and may oscillate.
6. **Velocity discontinuities at LP transitions**: When LP switches solution, velocity
   can jump discontinuously. Our implementation uses LP3 to limit this.

### Best for
- Low-to-medium density navigation (below ~2–3 ped/m²)
- Scenarios requiring collision-free guarantees (safety-critical)
- Robot navigation in crowds
- Cross-flow, 4-way junction tests (3I-c)

### T7 achievability
**MAY NOT** alone. ORCA prevents arches but also cannot drive the crowd pressure needed
for sustained bottleneck throughput. Agents spread out too smoothly and queuing column
collapses. However: **ORCA in the corridor (approach zone) + SFM at the door (high ρ)
= Hybrid FSM, which SHOULD pass T7.**

---

## 4. CSM — Collision-Free Speed Model (Tordeux et al. 2016)

### What it is
A first-order speed model (not force/acceleration-based). Each agent's speed is set by
an **optimal velocity function** of the minimum gap to the nearest agent ahead:

```
v_i = v₀ · f(gap_ahead_i / (T · v₀))
```

where T is a time-gap parameter and v₀ is desired speed. Direction is set by an
exponential repulsion from neighbors (like SFM), but speed is capped by the gap formula.

The key insight: **speed is REDUCED before contact occurs**. This is architecturally
arch-free — the gap function goes to zero before overlap, so agents always have room to
stop without being "pushed through" each other.

### Strengths
1. **Architecturally arch-free**: Cannot form rigid arch deadlocks. If the door gap is
   too small, agents slow down but don't lock. This is why JuPedSim uses it for T7.
2. **Intrinsically collision-free**: The gap function mathematically prevents overlap
   without needing contact spring forces.
3. **Fundamental diagram**: Reproduces Weidmann density-velocity curve correctly.
4. **Computationally efficient**: First-order model (no acceleration integration).
   Computationally cheaper than SFM/GCFM.
5. **Stop-and-go waves**: Reproduces intermittent flow patterns observed in dense bottlenecks
   (Tordeux 2016 §5). This is physically realistic.
6. **Simple implementation**: Compared to GCFM, fewer parameters and simpler formulation.
7. **T7 performance**: JuPedSim's primary T7 model. Achieves ≥1.22 ped/s at 1m door with
   appropriate parameters.

### Weaknesses
1. **No contact forces → no T12**: The CSM has no contact spring. Arch formation (T12)
   cannot be reproduced. If you need arch formation as a physical phenomenon, CSM fails.
2. **Backward movements in original version**: The original Tordeux 2016 paper noted
   unrealistic backward steps. The **Generalized CSM** (Xu et al. 2019) fixes this with
   wall influences and better direction model.
3. **First-order model → no inertia**: Real pedestrians have inertia (they cannot
   instantaneously change direction). CSM doesn't model this. In sharp turns, agents may
   appear unnaturally jerky.
4. **Limited panic/FiS modeling**: Without contact forces, extreme congestion produces
   orderly slowdown, not physical panic compression and FiS.
5. **Less studied for evacuation**: Most validation is for normal walking. Emergency
   egress with physical contact is not CSM's domain.
6. **Directional sub-model is simple**: The exponential repulsion direction is less
   physically motivated than SFM's social force for complex 2D scenarios.

### Best for
- Normal pedestrian flow (shopping malls, stations, corridors)
- T7 (bottleneck flow with realistic throughput)
- Fundamental diagram
- Large-scale simulations where speed matters
- Any scenario where arches should NOT form

### T7 achievability
**MUST** (arch-free by design). JuPedSim passes T7 with CSM. This is the cleanest
single-model T7 solution in the literature.

---

## 5. Library Survey — Who Passes T7 and How

### Open-Source / Academic Libraries

| Library | Institution | T7 Model | T7 Status | Notes |
|---------|------------|----------|-----------|-------|
| **JuPedSim** | FZ Jülich | `CollisionFreeSpeedModel` (CSM) | ✅ PASSES | Primary T7 model. GCFM available but not used for T7. CSM validation notebooks public. |
| **UMANS** | Utrecht Univ. | ORCA + custom direction model | ⚠️ PARTIAL | T7 geometry not published. ORCA can sustain flow but may not reach 1.22 ped/s. |
| **Menge** | UNC Chapel Hill | Pluggable (ORCA, SFM, others) | 🔬 FRAMEWORK | Not a model — a framework. T7 depends on plugin chosen. With CSM plugin: likely passes. |
| **SumoSim** / **OpenPedSim** | Various | SFM variants | ⚠️ PARTIAL | SFM with σ>0 calibration often passes T7 if parameters are well-tuned. |
| **Hermes** (this project) | FZ Jülich | SFM + GCFM | ⚠️ PARTIAL | Uses SFM for normal flow. GCFM for fundamental diagram. |

### Commercial Software

| Software | Vendor | T7 Model | T7 Status | Notes |
|----------|--------|----------|-----------|-------|
| **PTV Viswalk** | PTV Group | SFM + stochastic noise σ | ✅ PASSES | Explicitly uses σ calibration to break arch deadlocks. Published RiMEA compliance. |
| **MassMotion** | Oasys | Velocity-based (proprietary) | ✅ PASSES | Proprietary flow model, no arch formation by design. |
| **LEGION** | AECOM | Agent-based + queuing theory | ✅ PASSES | Uses zone-based flow model supplemented by microscopic agents. |
| **SimWalk** | Savannah Simulations | SFM + calibration | ✅ PASSES | Validates continuously against empirical data. σ calibration used. |
| **Pathfinder** | Thunderhead | SFPE velocity model | ✅ PASSES | Uses SFPE flow equations (macroscopic for bottleneck) rather than microscopic SFM. |
| **accu:rate** | accu:rate GmbH | SFM + σ noise + calibrated A,B,τ | ✅ PASSES | Explicitly documents σ usage for T7 compliance. |
| **Vissim (pedestrian)** | PTV | SFM + calibration | ✅ PASSES | Documented in Kretz et al. 2008 "Pedestrian Flow at Bottlenecks — Validation of Vissim SFM". |

### Key Pattern Across Libraries
**Every library that passes T7 uses one of these three approaches:**
1. **CSM-style gap-based speed model** (no arch possible) — JuPedSim, MassMotion, Pathfinder
2. **SFM + calibrated stochastic noise σ > 0** (arches break stochastically) — Viswalk, accu:rate, SimWalk
3. **Hybrid with ORCA in approach zone** (no arch in corridor) — Menge (with ORCA plugin), future SimCrowd Sprint 3K

**No library passes T7 with raw SFM (σ=0) or raw GCFM alone.**

### Why T7 Is in RiMEA
The RiMEA guideline includes T7 specifically because it tests a model's ability to
reproduce **sustained, non-clogging bottleneck flow** — a phenomenon critical for:
- Evacuation time estimation (arching = longer evacuation)
- Station/transit design (platform-to-exit flow capacity)
- Emergency planning (how many can exit in N minutes?)

T7 is not testing whether arches NEVER form (they do momentarily in real life), but
whether the model produces the RIGHT LONG-TERM MEAN FLOW (≥85% Weidmann). Real people
have micro-randomness that breaks arches within 1–2 seconds. Pure deterministic force
models don't have this.

---

## 6. Can SFM + GCFM + ORCA All Be Combined?

### Yes — and it makes physical sense

The three models operate at different density regimes and model different phenomena:

| Regime | Density (ρ) | What matters | Best model |
|--------|------------|-------------|-----------|
| Free flow | < 0.5 ped/m² | Collision avoidance, smoothness | ORCA |
| Normal corridor | 0.5–2 ped/m² | Social spacing, fundamental diagram | GCFM or CSM |
| Dense crowd | 2–4 ped/m² | Body compression, velocity coupling | SFM (soft spring) |
| Extreme density | > 4 ped/m² | Physical contact, arch, FiS | SFM (full contact spring) |

### The Density-Dispatch Hybrid (Sprint 3K concept)
```
ρ < 2.5: ORCA (smooth navigation, collision-free)
2.5 ≤ ρ < 3.5: SFM soft (social repulsion without contact)
ρ ≥ 3.5: SFM full (with contact spring k, κ)
```

This is essentially what JuPedSim's documentation calls "Multi-model" and what the
Menge framework enables through its BFSM (Behavioral FSM) architecture.

### A More Refined 3-Model Dispatch
For SimCrowd, combining all three could look like:

```julia
# Conceptual 3-model dispatch
if ρ_local < ρ_orca        # ~0.5–1.5 ped/m²: sparse, smooth
    update_orca_system_cpu!(world, sh, dt, orca_params)
elseif ρ_local < ρ_sfm_contact   # ~1.5–3.5 ped/m²: moderate, GCFM
    update_gcfm_system!(world, sh, dt, gcfm_params)
else                              # >3.5 ped/m²: dense, SFM with contact
    update_social_forces_system!(world, sh, dt, sfm_params)
end
```

### Scientific Justification for Each Transition

**ORCA → GCFM at ρ~1.5**:
- At ρ<1.5 ped/m², agents rarely interact directly. ORCA's velocity-space LP is optimal.
- At ρ>1.5, the LP feasibility drops and ORCA agents begin freezing. GCFM handles this
  better because force-based models don't require a collision-free velocity to exist.

**GCFM → SFM at ρ~3.5**:
- GCFM has no contact forces. At ρ>3.5 ped/m², center-to-center distances approach 2r
  (physical contact). Body compression and friction (k·δ, κ·δ·Δv) become significant.
- SFM's contact spring is calibrated to reproduce this physical contact regime.

### Challenges of 3-Model Combination
1. **Force continuity at boundaries**: Switching from GCFM force to SFM force creates
   a discontinuous acceleration. Need a blending window (e.g., 3–5 step exponential blend).
2. **Hysteresis required**: Without hysteresis, agents at the boundary oscillate between
   modes. Need ρ_on ≠ ρ_off (e.g., switch to SFM at ρ>3.5, switch back at ρ<2.5).
3. **Which density measure?**: Voronoi-based density is most accurate but expensive.
   Neighbor count within radius is cheaper but noisy. SimCrowd currently uses neighbor
   count — suitable for dispatch but requires filtering to avoid oscillations.
4. **Test conflicts**: T12 (arch formation) requires SFM contact forces. T7 requires
   ORCA or CSM (no arch). A 3-model dispatch could potentially pass BOTH if properly tuned.

---

## 7. The Optimal Hybrid for SimCrowd

### Near-term (Sprint 3K): Binary Hybrid (ORCA + SFM)
As currently planned. Well-studied in literature (JuPedSim multi-model, Menge BFSM).
- ρ < 3.5: ORCA
- ρ ≥ 3.5: SFM

### Mid-term: Ternary Hybrid (ORCA + CSM + SFM)
Instead of GCFM in the middle tier, use CSM:
- ρ < 1.5: ORCA (guaranteed collision-free, smooth)
- 1.5 ≤ ρ < 3.5: CSM (gap-based speed, no arch, T7-compatible)
- ρ ≥ 3.5: SFM (contact forces, arch, T12-compatible)

**This combination would SIMULTANEOUSLY pass T2, T7, and T12** — which NO single model can do.

### Long-term: Tri-model + GCFM specialist mode
GCFM-elliptical remains available for scenarios where the fundamental diagram must be
matched with high fidelity in 2D at moderate density (e.g., calibration of pedestrian
density profiles in wide spaces). It sits alongside CSM as a "moderate density" option
that users can choose for specific use cases.

---

## 8. Comparison Table — All Models

| Property | SFM | GCFM-circular | GCFM-elliptical | ORCA | CSM |
|----------|-----|--------------|----------------|------|-----|
| Order | 2nd (force) | 2nd (force) | 2nd (force) | 1st (velocity) | 1st (speed) |
| T1: Free walking | MUST | MUST | MUST | MUST | MUST |
| T2: Fundamental diagram | SHOULD | MUST | MUST | CANNOT | MUST |
| T4: Speed distribution | MUST | MUST | MUST | MUST | MUST |
| T7: Bottleneck flow | MAY NOT (σ=0) / SHOULD (σ>0) | MAY NOT | MAY NOT (wrong params) / SHOULD (correct params + σ) | MAY NOT alone | **MUST** |
| T12: Arch formation | **MUST** | SHOULD | SHOULD | **CANNOT** | **CANNOT** |
| T14: Lane formation | SHOULD | SHOULD | SHOULD | CANNOT | NICE |
| T15: Staircase | MAY NOT | MAY NOT | MAY NOT | MAY NOT | MAY NOT |
| Computational cost | Medium | Medium | Medium-High | Low-Medium | Low |
| Implemented in SimCrowd | ✅ | ✅ | ✅ | ✅ | ❌ |
| JuPedSim primary use | evacuation | fundamental diagram | fundamental diagram | normal walking | **bottleneck flow** |

---

## 9. Recommended Next Steps (Prioritized)

### Priority 1 — Fix GCFM-elliptical calibration (1 hour, do immediately)
Change `a_min=0.18m, b_min=0.20m, b_max=0.25m` per Chraibi 2010. Re-run 3J.
This alone may not pass T7 but gives scientifically correct baseline.

### Priority 2 — Add seeded per-agent noise σ to SFM (2–4 hours)
Helbing 2000 explicitly includes stochastic term ξᵢ(t). Implement correctly:
- Per-agent RNG seeded with `agent_id XOR step_seed`
- σ ≈ 0.1–0.3 m/s added to velocity each step
- Expected: arch-breaking → T7 SHOULD pass

This is what Viswalk, accu:rate, and SimWalk all do for T7 compliance.

### Priority 3 — Sprint 3K: Binary Hybrid FSM (1–2 sprint days)
ORCA (ρ<3.5) + SFM (ρ≥3.5). Research done (`future_directions.md §2`).
Expected: T7 SHOULD/MUST pass. T12 still passes. Clean scientific justification.

### Priority 4 — Sprint 3L: CSM implementation (1–2 sprint days)
Tordeux 2016 algorithm. Cleanest T7 solution. No arch-breaking needed.
Enable ternary hybrid (ORCA + CSM + SFM) for simultaneous T2/T7/T12 coverage.

---

## 10. References

1. Helbing, D., Molnár, P. (1995). Social force model for pedestrian dynamics. *Phys. Rev. E* 51:4282.
2. Helbing, D., Farkas, I., Vicsek, T. (2000). Simulating dynamical features of escape panic. *Nature* 407:487.
3. Chraibi, M., Seyfried, A., Schadschneider, A. (2010). GCFM. *Phys. Rev. E* 82:046111.
4. Van den Berg, J., Lin, M., Manocha, D. (2008). Reciprocal velocity obstacles for real-time multi-agent navigation. *ICRA 2008*.
5. Van den Berg, J., et al. (2011). Reciprocal n-body collision avoidance. *Robotics Research*.
6. Tordeux, A., Chraibi, M., Seyfried, A. (2016). Collision-free speed model for pedestrian dynamics. *TGF 2015*, Springer.
7. Xu, Q., et al. (2019). Generalized collision-free velocity model for pedestrian dynamics. *arXiv:1912.06451*.
8. RiMEA e.V. (2016). Guideline for Microscopic Evacuation Analysis. www.rimea.de.
9. Kretz, T., Hengst, S., Vortisch, P. (2008). Pedestrian flow at bottlenecks — validation and calibration of Vissim's SFM. *ISTS08*.
10. JuPedSim Documentation. www.jupedsim.org (CollisionFreeSpeedModel for T7).
11. Menge Framework. collective-dynamics.eu.
12. UMANS: Universal Microscopic Agent Navigation Simulator. Utrecht University, 2022.
