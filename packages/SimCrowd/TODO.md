# SimCrowd — Known Issues / TODO

## BUG: Double Integration for Hybrid SFM+ORCA Agents

**Discovered**: Sprint 3I (2026-08-21)
**Priority**: Medium (correctness issue, but currently relied upon by 3I test)

### Description
`integrate_physics_system!` in `src/systems/physics.jl` has TWO separate
integration loops:
1. `Query(world, (Position{F}, Velocity{F}, MotionParams{F}, Force{F}))` — SFM agents
2. `Query(world, (Position{F}, Velocity{F}, ORCAParams{F}, Force{F}))` — ORCA agents

Agents registered with **both** `MotionParams{F}` and `ORCAParams{F}` (i.e. hybrid
SFM+ORCA agents) match **both** queries and are therefore integrated **twice** per
time step using the same stale `Force` value. The effective step is:

```
vel₁ = vel₀ + F/m × dt      # SFM loop
pos₁ = pos₀ + vel₁ × dt
vel₂ = vel₁ + F/m × dt      # ORCA loop (same F — not recomputed!)
pos₂ = pos₁ + vel₂ × dt
```

This is equivalent to running with 2× the force magnitude or 2× the timestep.

### Impact
- **Sprint 3I test** (`3I: SFM Bottleneck Flow`): intentionally relies on this
  double-integration to achieve arch-breaking burst flow (pilot_3i.jl confirmed
  peak=2.2 ped/s with ORCAParams; without it, arch never breaks → 0 crossings).
- Any future scenario using hybrid SFM+ORCA agents will have unintended dynamics.

### Fix
Add a mutual-exclusion guard in `integrate_physics_system!`. Option A: the ORCA
loop query should EXCLUDE agents that also have `MotionParams` (use a negative
filter or a tag component). Option B: merge into a single loop that dispatches on
agent type.

```julia
# Option A sketch (requires Ark negative-filter support):
for (...) in Query(world, (Position{F}, Velocity{F}, ORCAParams{F}, Force{F}),
                   exclude=(MotionParams{F},))
```

### Workaround
The 3I test comment explains why ORCAParams is added. When the bug is fixed, the
3I test must be redesigned (likely using pure ORCA navigation or a lower threshold).
