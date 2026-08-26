# Debugging Protocol — Mandatory Rules

> [!IMPORTANT]
> These rules are **user-mandated** and must be followed in every debugging session, without exception. They supersede any urge to make educated guesses or apply fixes based on untested assumptions.

---

## ⚡ RULE ZERO — DIAGNOSTIC FIRST, ALWAYS

> [!CAUTION]
> **This is the single most important rule. It was added after Sprint 3K (2026-08-26) when
> the team spent multiple sessions reasoning about wrong hypotheses (ORCA deadlock, noise,
> arch formation) when the REAL problem (agents flying through walls at 3.88 m/s due to
> contact spring instability) would have been found immediately with a diagnostic.**

**Whenever you encounter ANY of the following:**
- A test fails
- A validation fails
- An agent/entity is stuck or behaving wrongly
- A simulation produces unexpected results

**Your FIRST action — before any hypothesis, before any code change — is:**

### 1. Build a diagnostic script that captures per-entity state at failure time

The diagnostic must capture, for every entity that is failing:
- **Exact position** (x, y, z coordinates)
- **Exact velocity** (vx, vy, speed — is speed physically plausible?)
- **All forces acting on it** (goal force, each wall force with magnitude + direction, neighbor forces)
- **Net force** (especially: is net_x forward or backward?)
- **Mode/state** (e.g., SFM_MODE or ORCA_MODE in Hybrid FSM)
- **Whether entity is inside valid geometry** (y < 0? y > 4? outside room?)

### 2. Also capture aggregate snapshots at multiple time points

At t=5s, 35s, 60s, 120s (or equivalent milestone fractions):
- How many entities have passed/succeeded?
- x-position histogram (where are entities spatially?)
- Mode distribution (SFM vs ORCA, active vs passive, etc.)
- Mean and **maximum** speed (max_speed >> v_pref → contact spring instability)
- Any entities in impossible positions (outside geometry)?

### 3. Run the diagnostic BEFORE forming any hypothesis

Read the output. Let the data tell you what's wrong. Only then form a hypothesis.

> [!WARNING]
> **Sprint 3K case study (the cost of skipping this rule):**
>
> The 3K test had 70/80 agents stuck at t=120s. We spent multiple sessions reasoning about:
> - ❌ "vel_j=0 in ORCA causing deadlock" (wrong)
> - ❌ "σ=0.3 noise insufficient to break arch" (wrong)
> - ❌ "ρ_off=0.5 causing premature ORCA switch" (wrong)
> - ❌ "social_r_wall=0.2m blocking door entry" (partially right, but found last)
>
> Running `diag_3k_stuck.jl` (per-agent position+force at t=120s) immediately revealed:
> - Agents 70, 27, 41 at **y=-1.9, y=-0.36, y=4.9** — **OUTSIDE THE ROOM**
> - Agent 70 speed = **3.88 m/s** (2.8× preferred speed — contact spring explosion)
> - Root cause: k=120,000 N/m at dt=0.05s → ω₀=38.7 rad/s, Euler stability limit = 0.052s
>
> **The diagnostic took 5 minutes. The wrong hypotheses took multiple sessions.**

### Diagnostic script template

See: `brain/78616c9e.../scratch/diag_3k_stuck.jl` for a complete template.

Key pattern:
```julia
# For each stuck/failing entity:
@printf("Entity %d: pos=(%.3f, %.3f)  vel=(%.3f, %.3f)  speed=%.3f  mode=%s\n",
        idx, pos[1], pos[2], vel[1], vel[2], norm(vel), mode)

# Check for impossible positions FIRST:
(pos[2] < 0 || pos[2] > room_height) && println("  ⚠ OUTSIDE GEOMETRY!")

# Print all forces with magnitudes:
@printf("  goal_force=(%.1f, %.1f)  |F|=%.1f N\n", f_g[1], f_g[2], norm(f_g))
for wall in walls
    f_w = wall_force(pos, wall)
    norm(f_w) > 1f0 && @printf("  wall_force: |F|=%.1f N  dir=(%.2f,%.2f)\n",
                                norm(f_w), f_w[1]/norm(f_w), f_w[2]/norm(f_w))
end
@printf("  net_x=%.1f N  → %s\n", net_x, net_x > 0 ? "FORWARD" : "BACKWARD BLOCKED")
```

---

## VALIDATION INTEGRITY RULES (SimCrowd / Antigravity — User Mandate)

> [!CAUTION]
> These three rules were explicitly mandated by the user after discovering that
> validation tests were being "cooked" (parameters tuned to pass, not to be correct).
> **Violating these rules is unacceptable.** They apply to every test change, every
> parameter change, and every assertion change in tier3_cross_library.jl.

### Rule V1 — Do Not Move the Goalposts

**Never change a validation test to make it easier to pass without a robust physical reason.**

- If you remove a density assertion (e.g., ρ=3.0), you must cite a peer-reviewed source
  showing that reference implementations (JuPedSim, Chraibi 2010) also exclude that density.
- If you change a tolerance (e.g., ±15% → ±40%), you must cite the original paper's stated tolerance.
- If you add a `# diagnostic only` comment to skip an @test, that is goalpost-moving.
- Changing test parameters to match simulation output (instead of fixing the simulation) is **forbidden**.

✅ **Acceptable change example**: "JuPedSim also excludes ρ>2.5 from RiMEA T2 per their
   published test suite — verified by reading `/home/sourabh/.local/lib/python3.14/site-packages/jupedsim/`."

❌ **Unacceptable change example**: "ρ=3.0 is hard, so we'll just assert monotone speed instead of ±15%."

---

### Rule V2 — Debug in the Correct Order (3-Step Protocol)

When a validation test fails, investigate in this EXACT order before touching ANY code:

**Step 1 — Check parameter values**
- Are our force model parameters (V₀, η, λ, B, A, k, κ, τ) the same as in the reference paper?
- Are our geometric parameters (r, corridor dimensions, door width) matching?
- Are our simulation parameters (dt, t_warmup, t_measure, seed) matching the paper?

**Step 2 — Check test code and assumptions against JuPedSim**
- Install and read JuPedSim: `pip install jupedsim`; source in `/home/sourabh/.local/lib/python3.14/site-packages/jupedsim/`
- Compare our test setup (geometry, BC, measurement method) with their benchmark tests.
- Compare our force model implementation against their Python/C++ source.
- Check if their model uses the SAME formula (e.g., is the anisotropy λ included?).

**Step 3 — Check for fundamental algorithmic differences**
- Does our model have the SAME mathematical structure as the reference?
  (e.g., circular GCF vs. elliptical GCFM — these are fundamentally different)
- Does our integration method match? (Euler dt=0.01s vs. dt=0.05s changes equilibrium behavior)
- Does our measurement method match? (Voronoi vs. full-corridor average)

> [!WARNING]
> Do NOT skip to Step 3 if Step 1 or Step 2 could explain the failure.
> The λ-bug in gcf_force (2026-08-21) was a Step 1 failure that took weeks
> to find because we jumped to "fundamental model differences."

---

### Rule V3 — Tests Must Not Be Compromised or Cooked

**A "cooked" test is one where the parameters or assertions were chosen to make a
specific simulation output pass, rather than to validate physically correct behavior.**

Signs of a cooked test:
- The calibration sweep was run and then the passing parameters were put in the test.
  (Acceptable ONLY if the parameters match a peer-reviewed source — e.g., Chraibi 2010 uses η=0.5.)
- An assertion was REMOVED because the simulation couldn't pass it.
- An assertion was WEAKENED (higher tolerance, removed density point) without physical justification.
- The test seed was changed to find a "lucky" run that passes.

**Verification**: After any test change, ask: "Would this test still catch a bug in the model?"
If the answer is no, the test has been compromised.

---

## Rule 1 — Check Documentation First

Before writing a single line of fix code, read the relevant documentation:

- Read the **official docs / API reference** for the library/framework involved in the error.
- Check **changelogs, known issues, and migration guides** for the version in use.
- Search the **GitHub issues** of the relevant package for the exact error message.
- For shader/GPU errors: check the **WebGL spec** or **GLSL ES spec** for the precise meaning of the error (e.g., `VALIDATE_STATUS false`, precision qualifier rules).

**Why**: Many errors have documented root causes and standard fixes. Guessing wastes time and often leads to wrong patches.

### Example of what went wrong (conversation 969fb699):
Instead of checking the GLSL ES 3.00 spec for precision qualifier semantics, we assumed `precision mediump sampler2D` as a *default* would be honored by all WebGL drivers. It wasn't. The spec-correct fix (explicit `mediump` on the uniform declaration itself) was only found after multiple failed assumptions.

---

## Rule 2 — Write Diagnostic Code Before Fixing

Never apply a fix for a bug that has not been directly observed in runtime behavior. The workflow is:

```
OBSERVE → DIAGNOSE → FIX → VERIFY
```

### Step-by-step:

1. **Add targeted logging/tracing** that directly instruments the suspected code path.
   - Log input values, types, and outputs at the exact location of the suspected bug.
   - Use structured log tags (e.g., `[FA-LS]`, `[FA-AR]`) so logs can be filtered.
   - Make logs narrow and specific — don't dump everything.

2. **Run the code** and capture the actual log output.

3. **Read the logs** to confirm or refute the hypothesis before touching any fix code.

4. **Only then** write the fix, targeting the exact observed problem.

5. **Verify** the fix by re-running and checking that the symptom is gone.

### For simulation failures — capture PER-ENTITY state (not just aggregates)

Aggregate metrics (mean speed, n_passed) can hide the real problem. Always also capture:

| What to check | Why |
|---|---|
| Per-entity (x, y) at failure time | Entities outside geometry → numerical instability |
| Per-entity max speed | Speed >> v_pref → contact spring explosion |
| Per-entity net force by component | net_x < 0 → genuinely blocked by wall/crowd |
| Per-entity mode (SFM/ORCA/etc.) | Wrong mode → wrong forces being applied |
| Force magnitude from EACH wall segment | One wall can dominate and block forward motion |

### What "diagnostic code" means in this codebase:

**Julia side (simulation diagnostic):**
```julia
# Print stuck entities with full state:
for idx in stuck_idxs
    pos, vel, mode = positions[idx], velocities[idx], modes[idx]
    @printf("Entity %d: pos=(%.3f,%.3f) speed=%.3f mode=%s\n",
            idx, pos[1], pos[2], norm(vel), mode)
    pos[2] < 0 || pos[2] > room_h && println("  ⚠ OUTSIDE GEOMETRY — numerical instability!")
    # Forces...
end
```

**Julia side (logging):**
```julia
@info "[TAG] description" key1=val1 key2=val2
```

**JavaScript side:**
```javascript
console.log("[TAG] description", { key1: val1, key2: val2 });
```

---

## Workflow Summary

```
Error / Test Failure / Wrong Behavior
    │
    ▼
⚡ RULE ZERO: DIAGNOSTIC FIRST
    Build per-entity diagnostic script
    Capture: positions, velocities, forces, modes
    Check: are any entities outside geometry? max_speed >> v_pref?
    │
    ▼
Read diagnostic output. Form hypothesis from DATA, not intuition.
    │
    ▼
Rule V2, Step 1: CHECK PARAMETERS
    - dt, V₀, η, λ, B, A, k, r, corridor dims — match the reference paper?
    │
    ▼
Rule V2, Step 2: COMPARE WITH JUPEDSIM
    - Read JuPedSim source + test suite
    - Compare model formula, anisotropy, measurement method
    │
    ▼
Rule V2, Step 3: ALGORITHMIC DIFFERENCES
    - Circular vs. elliptical? Isotropic vs. anisotropic? Euler step?
    │
    ▼
Fix the SIMULATION (not the test)
    │
    ▼
Rule V1: Check — did you change ANY assertion?
    If yes: is there a peer-reviewed citation for the change?
    │
    ▼
Rule V3: Check — is the test still capable of catching a model bug?
    │
    ▼
COMMIT (only if all rules satisfied)
```

---

## Anti-patterns to Avoid

| Anti-pattern | Why it fails |
|---|---|
| Hypothesizing without a diagnostic | Sprint 3K: spent sessions on wrong causes |
| Checking only aggregate metrics | Hides individual entities outside geometry |
| "It's probably a caching issue" | Maybe, but verify first with a diagnostic |
| "The patch looks right" | Runtime behavior often differs from static analysis |
| "Let's try this and see" | Multiple untested patches compound each other |
| "ρ=3.0 is too hard, let's just check monotone" | Goalpost-moving — Rule V1 violation |
| "JuPedSim also can't do this" | Must actually verify, not assume |
| Changing seed to get a lucky pass | Cooking the test — Rule V3 violation |
| Calibrating params then putting them in the test | Allowed ONLY if they match a reference source |
| Increasing σ to fix a problem without diagnosing | Sprint 3K: σ was a symptom, not the cause |

---

## Applied to This Codebase (SimCrowd / Antigravity)

### Numerical stability checks (ALWAYS verify when SFM/contact forces are involved)

```
Contact spring stability: dt < 2/ω₀ = 2/√(k/m)
With k=120,000, m=80kg: ω₀=38.7 rad/s, limit dt < 0.052s  ← UNSTABLE at dt=0.05s
With k=12,000,  m=80kg: ω₀=12.25 rad/s, limit dt < 0.163s ← safe at dt=0.05s

Rule: For dt=0.05s (SimCrowd default), use k ≤ 12,000 N/m.
      For dt=0.01s, k=120,000 is marginally stable.
```

Symptom of contact spring instability: **any entity with speed > 2×v_pref**.

### Parameter reference values

| Parameter | Value | Source |
|---|---|---|
| k (contact spring, dt=0.05s) | **12,000 N/m** | Stability analysis, 2026-08-26 |
| κ (sliding friction) | **24,000 N·s/m** | κ/k = 2.0 (Helbing ratio) |
| social_r_wall | **0.1m** (not r_body=0.2m) | Diagnostic 2026-08-26: 0.2m blocks door corners |
| σ (SFM noise) | **0.3 N/kg** | Helbing 2000 canonical |
| ρ_off (FSM hysteresis) | **0.2 ped/m²** | Below 0.5: premature ORCA switch at low occupancy |
| A (agent repulsion) | 2000 N | Helbing 1995 |
| B (decay length) | 0.08 m | Helbing 1995 |

- **GCF model**: Use Chraibi 2010 §II as the reference. Key parameters: η≈0.5s, λ=0.5, dt=0.01s.
  The λ anisotropy IS part of the GCFM formula (kij coefficient). Do not omit it.
- **Fundamental diagram**: Weidmann (1993) tolerance ±15% (RiMEA T2). Chraibi 2010 validates
  up to ρ=4.0 ped/m². Do not exclude ρ=3.0 without JuPedSim citation.
- **Bottleneck flow (3K, 3J)**: Weidmann 1.44 ped/s for 1m door. Target ≥85% = 1.22 ped/s.
  Do not use numerical bugs (double-integration, contact spring explosion) to pass this.
- **JuPedSim source location**: `/home/sourabh/.local/lib/python3.14/site-packages/jupedsim/`
- **JuPedSim GCFM**: Uses elliptical semi-axes (a_v, a_min, b_min, b_max), NOT circular D_i.
  This is a fundamental model difference — note it, don't paper over it.
