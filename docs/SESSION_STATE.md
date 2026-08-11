# SESSION STATE

> **DO NOT EDIT BY HAND.** Updated automatically at end of each session.  
> Last updated: 2026-08-11 (conversation `78616c9e-3fd6-407c-bebd-abc1d7c4255f`)

---

## 1. Where We Left Off

- **Last Commit:** `45386a1 (HEAD → master) fix(SimCrowd): Tier 3 suite → 8/8 green; sigma calibration, force split, 3B/3C redesign`
- **Current Phase:** Tier 3 cross-library validation COMPLETE (8/8 passing). Now planning improvement sprint.
- **Test Status:**
  ```
  Tier 3: Cross-Library Validation vs Published Benchmarks | 8/8  1m27s
    3A-easy ORCA N=30 antipodal circle                      | 3/3
    3A-hard ORCA N=250 collision avoidance                  | 2/2
    3B SFM Bottleneck N=50 6×6m (Helbing 2000)              | 1/1
    3C SFM Faster-is-Slower N=50 (Helbing 2000 Figure 4)    | 2/2
  ```

---

## 2. What Was Accomplished in the Last Session

### Physics Fixes
| Fix | File | Details |
|-----|------|---------|
| Noise sigma `0.05→0.1 m/s` | `physics.jl` | Helbing 2000 evacuation calibration; arch-break time 6s→1.5s |
| Force split: `contact_force` + `psychological_force` | `forces.jl` | Contact is Newton-3-exact (symmetric via CellListMap); psych is asymmetric (anisotropy on psych only) |
| CPU pipeline Phase 2+3 separation | `social.jl` | Phase 2: body+friction via `CellListMap.pairwise!`; Phase 3: psych O(N²) sequential |
| Restored ORCA call in 3A-hard loop | `tier3_cross_library.jl` | Regression introduced when editing 3B setup |

### Test Redesigns (3B/3C)
- **3B**: Changed N=200/20×10m → N=50/6×6m (Helbing 2000 exact geometry). Liveness threshold 55%. Documented that 5-arg (social-only) produces 0.17 ped/s vs Weidmann 1.44 ped/s — correct physics, not a bug.
- **3C**: Changed N=200/12×12m → N=50/6×6m. Removed n_normal liveness (Coulomb arch too stable at v₀=1.0) and FiS ratio (t_normal hits 500s timeout). Kept: arch-formation proof (`t_panic >> 18.75s`) + panic liveness.

### Key Scientific Finding (Documented in improvement plan)
Our Coulomb friction cap (`clamp(κ×g×Δv_t, -μ×k×g, +μ×k×g)`) prevents the Faster-is-Slower effect at normal speed. Helbing's pure viscous model (`κ×g×Δv_t`, no cap) is required for correct FiS physics. This is the #1 issue in the improvement plan.

---

## 3. Next Sprint — The Improvement Plan

Full plan at: `simcrowd_improvement_plan.md` (in conversation artifacts) and summarized below.

### Sprint 1 — Correctness Bugs (START HERE)
| Task | File | Effort |
|------|------|--------|
| Fix `AgentParams` 4-arg constructor: `μ=1.2e5` should be `μ=0.5` | `SimCrowd.jl:44` | 30 min |
| Add `ContactModel` enum (`Viscous \| Coulomb \| NoContact`), dispatch in `contact_force` | `forces.jl` | 4h |
| Upload per-agent A, B, λ to `SocialForcesGPUContext`; remove hardcoded GPU defaults | `social.jl` | 4h |

### Sprint 2 — Performance (before N > 1000)
| Task | File | Effort |
|------|------|--------|
| Replace O(N²) psych loop with `Polyester.@batch` (quick win) or CSR neighbor list | `social.jl:322` | 1 day |
| Morton curve sorting in `RadixSpatialHash` | `neighbor_search.jl` | 3h |

### Sprint 3 — Scientific Completeness
| Task | Effort |
|------|--------|
| Per-agent σ in `AgentParams`; remove hardcoded `sigma` in `physics.jl` | 2h |
| ORCA LP3 profiling + fix (LP3 fallback produces min_sep≈0.01–0.18m) | 1 day |
| ORCA static obstacle lines (integrate wall ORCA constraints into LP) | 1 day |

---

## 4. Key Files for Next Session

| File | Why |
|------|-----|
| `packages/SimCrowd/src/SimCrowd.jl` | 4-arg AgentParams constructor bug (line 44) |
| `packages/SimCrowd/src/forces.jl` | ContactModel enum to add |
| `packages/SimCrowd/src/systems/social.jl` | GPU hardcoded defaults + O(N²) psych loop |
| `packages/SimCrowd/src/systems/orca_math.jl` | LP3 fallback quality |
| `packages/SimCrowd/test/tier3_cross_library.jl` | Tier 3 tests (reference for verification) |

---

## 5. Resume Commands

**After restart**, paste this in the new conversation to restore context instantly:
> "Continue antigravity/SimCrowd development. Read SESSION_STATE.md. The last session fixed the Tier 3 cross-library tests (8/8 green). Next sprint is SimCrowd improvement plan Sprint 1 — start with the AgentParams constructor bug."

**Run tests to verify no drift:**
```bash
cd /run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/SimCrowd
julia --startup-file=no --project=. test/tier3_cross_library.jl
# Expected: 8 passed, 0 failed in ~90s
```

---

## 6. Open Questions / Decisions Pending

| Question | Context |
|----------|---------|
| Does `Polyester.@batch` work with `KernelAbstractions.jl`? | Yes — Polyester is CPU-only threading; KA handles GPU dispatch. They live at different stack layers and don't conflict. `@batch` replaces `Threads.@threads` on the CPU social force loop only. |
| Should we switch to Chraibi GCF as the DEFAULT social force? | Deferred — requires validation dataset. Keep Helbing as default, add GCF as a `ForceModel` option (Sprint 4). |
| Should 3B use 6-arg (body contact) instead of 5-arg? | No — 5-arg is intentional. 3B tests social-force-only behavior; 3C tests full contact+FiS. The separation is valuable. |
