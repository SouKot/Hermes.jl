# SESSION STATE — Hermes.jl / Antigravity

> **DO NOT EDIT BY HAND.** Updated automatically at end of each session.  
> Last updated: 2026-08-19 (conversation `78616c9e-3fd6-407c-bebd-abc1d7c4255f`)

> [!IMPORTANT]
> The **authoritative, always-current** session state is maintained in the IDE agent's
> Knowledge Item (KI) system, which the agent reads automatically at the start of each session.
> This file is a human-readable mirror kept in sync with the KI. If in doubt, the KI takes precedence.

---

## 1. Where We Left Off

- **Last Commit:** `a6072c8` — `Sprint 8C: Add tier-3 SFM anisotropy tests (3D, 3E) + fix 3B/3B-res assertions`
- **Repo git root:** `/run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/SimCrowd`
- **Active Phase:** Sprint 8C COMPLETE. Sprint 8D in progress (doc structure + linking).

---

## 2. Test Status

```
tier1_unit_tests.jl                | 12/12  ✅
runtests.jl (unit+integration)     | 20/20  ✅
tier3_cross_library.jl (published) | 18/18  ✅  3m23s
run_validations.jl (Phase 3C)      | runs but not in CI
```

Verify after restart:
```bash
cd /run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/SimCrowd
julia --startup-file=no --project=. -t auto test/tier3_cross_library.jl
```

---

## 3. Completed Sprints

| Sprint | Commit | Summary |
|--------|--------|---------|
| 8A | `7b5cdeb` | 3C: Viscous friction, goal-past-door, t_90 metric |
| 8B | `a654ec9` | 3B: cr=0.25m contact forces, crowd_flow metric |
| 8B-proper | `4ce8613` | 3B-res: reservoir test, ReservoirConfig infrastructure (13/13) |
| 8C-1 | `a6072c8` | 3D: head-on anisotropy λ test (18/18) |
| 8C-2 | `a6072c8` | 3E: lane maintenance test (18/18) |

---

## 4. Next Tasks

| Sprint | Task | Status |
|--------|------|--------|
| 8D | Update implementation_phases.md checkmarks, link new tests | **← IN PROGRESS** |
| 9 | CRW-M-02: fundamental diagram density sweep | NOT STARTED |
| CRW-M-01 | Periodic BCs in CPUNeighborSearch | NOT STARTED |
| CRW-M-03 | Proper FiS: N=200, 4×4m, 0.8m door | NOT STARTED |

---

## 5. Key Architecture Decisions

- **`from_agent_params` 7-arg**: `(sr, cr, mass, v_pref, τ, μ, σ)` — explicit cr
- **Friction**: `μ=Inf32` Viscous for arch/FiS; `μ=0.5` Coulomb for bottleneck flow
- **σ in tests**: Use σ=0.0 for deterministic results. σ>0 routes through `Threads.@threads randn()` → non-deterministic
- **WallSegment ECS rule**: Always declare WallSegment{F} in World() even in open-space tests
- **Re-injection (reservoir)**: x∈[0.3,2.0] tight zone creates pressure waves that help break arches
- **3B-res peak_local_rate**: Assert on peak (max any 10s window), not average flow

---

## 6. Key Files

| File | Purpose |
|------|---------|
| `test/tier3_cross_library.jl` | All tier-3 benchmark tests (3A–3E, 18/18) |
| `test/crowd_test_helpers.jl` | Reusable reservoir simulation infrastructure |
| `src/systems/physics.jl` | `integrate_physics_system!` — σ+Threads non-determinism source |
| `src/neighbor_search.jl` | `CPUNeighborSearch` — needs periodic BC for CRW-M-01 |

---

## 7. Docs Navigation (All in `/run/media/sourabh/SANDISK-2TB/antigravity/ABM/docs/`)

| Doc | Purpose |
|-----|---------|
| [2026-08-07_implementation_phases.md](./2026-08-07_implementation_phases.md) | Sprint tracker — checkboxes and status |
| [2026-08-19_validation_caveats.md](./2026-08-19_validation_caveats.md) | Honest per-test assessment + library survey |
| [2026-08-14_future_directions.md](./2026-08-14_future_directions.md) | Non-committal roadmap (RiMEA, periodic BCs, FiS) |
| [2026-08-07_validation_test_cases.md](./2026-08-07_validation_test_cases.md) | Full test specifications |
| [2026-08-07_simulation_platform_design.md](./2026-08-07_simulation_platform_design.md) | Architecture reference |
| [2026-08-07_code_design_practices.md](./2026-08-07_code_design_practices.md) | Coding standards |

---

## 8. Resume Phrase

> "Continue antigravity/SimCrowd. Read SESSION_STATE KI. Sprint 8C COMPLETE (18/18 tier3, commit a6072c8).
> Sprint 8D in progress: updating implementation_phases.md checkmarks and doc cross-links.
> Next after 8D: Sprint 9 (CRW-M-02 fundamental diagram) or CRW-M-01 (periodic BCs)."
