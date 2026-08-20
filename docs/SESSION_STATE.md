# SESSION STATE — Hermes.jl / Antigravity

> **DO NOT EDIT BY HAND.** Updated automatically at end of each session.  
> Last updated: 2026-08-20 (conversation `78616c9e-3fd6-407c-bebd-abc1d7c4255f`)

> [!IMPORTANT]
> The **authoritative, always-current** session state is maintained in the IDE agent's
> Knowledge Item (KI) system, which the agent reads automatically at the start of each session.
> This file is a human-readable mirror kept in sync with the KI. If in doubt, the KI takes precedence.

---

## 1. Where We Left Off

- **Last Commit:** `0bb7fab` — `docs: add METHODOLOGY.md with post-sprint close-out checklist`
- **Previous code commit:** `5e2635f` — `Sprint 3H PASS: RiMEA T4 speed distribution — r=1.0, KS p=0.21`
- **Repo git root:** `/run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/SimCrowd`
- **Active Phase:** Sprint 3H **COMPLETE** ✅. Next: Sprint 3I (RiMEA T7: Bottleneck Flow ±15%)

---

## 2. Test Status

```
tier1_unit_tests.jl                | 12/12  ✅
runtests.jl (unit+integration)     | 20/20  ✅
tier3_cross_library.jl (published) | 30/30  ✅  3m37s   ← Tier 3 (3A–3G)
tier3_cross_library.jl 3H testset  |  3/3   ✅  1.6s    ← KS p=0.21, r=1.0000
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
| 3A | earlier | ORCA LP3 navigation (30/30 easy, 197/250 hard) |
| 3B | `4ce8613` | SFM Bottleneck + reservoir (crowd_flow ≥ 0.3 ped/s) |
| 3C | `7b5cdeb` | Arch formation + FiS context (viscous friction) |
| 3D | `a6072c8` | Head-on anisotropy λ=0.5 (Helbing & Molnár 1995) |
| 3E | `a6072c8` | Lane maintenance (score=0.913 vs 0.5 random) |
| 3F | `—` | Fundamental diagram GCF η=0.5 ±15% (ρ≤2.0 passing) |
| 3G | `—` | Lane formation from disorder (score=0.585 ≥ 0.58) |
| 3H | `5e2635f` | **Speed distribution Normal(1.34,0.26): KS p=0.21, r=1.0000** |

---

## 4. Next Tasks

| Sprint | Task | Status |
|--------|------|--------|
| **3I** | **RiMEA T7: Bottleneck Flow ±15% of Weidmann 1.44 ped/s** | **← NEXT** |
| 3J | RiMEA T15: Staircase speed reduction (-40%) | NOT STARTED |
| Post-3J | Full RiMEA T1–T15 compliance audit | NOT STARTED |

---

## 5. Key Architecture Decisions

- **`from_agent_params` 6-arg**: `(sr, mass, v_pref, τ, μ, σ)` — also 7-arg with explicit cr
- **Friction**: `μ=Inf32` Viscous for arch/FiS; `μ=0.5` Coulomb for bottleneck flow
- **σ in tests**: Use σ=0.0 for deterministic results. σ>0 routes through `Threads.@threads randn()` → non-deterministic
- **WallSegment ECS rule**: Always declare WallSegment{F} in World() even in open-space tests
- **Re-injection (reservoir)**: x∈[0.3,2.0] tight zone creates pressure waves that help break arches
- **CellListMap boundary clipping (CRITICAL)**: Any `CPUNeighborSearch` with finite box `[xmin,xmax]` clips out-of-box positions to boundary → spurious 0-distance pairs → body contact forces. For free-flow drift tests, skip `update_social_forces_system!` or extend box by `v_max × t_total`. See §10 of validation_caveats.md.

---

## 6. Key Files

| File | Purpose |
|------|---------|
| `test/tier3_cross_library.jl` | All tier-3 benchmark tests (3A–3H, 33 passing) |
| `test/crowd_test_helpers.jl` | `run_speed_distribution!`, `run_reservoir_bottleneck!`, etc. |
| `src/systems/physics.jl` | `integrate_physics_system!` — σ+Threads non-determinism source |
| `src/neighbor_search.jl` | `CPUNeighborSearch` — FINITE BOX: see CellListMap boundary note above |
| `src/systems/social.jl` | `update_social_forces_system!` + `_update_social_forces_impl!` |

---

## 7. Docs Navigation (All in `/run/media/sourabh/SANDISK-2TB/antigravity/ABM/docs/`)

| Doc | Purpose |
|-----|---------|
| [2026-08-07_implementation_phases.md](./2026-08-07_implementation_phases.md) | Sprint tracker — 3H `[x]`, 3I `[ ]`, 3J `[ ]` |
| [2026-08-19_validation_caveats.md](./2026-08-19_validation_caveats.md) | Honest per-test assessment + §10 Sprint 3H root cause |
| [2026-08-14_future_directions.md](./2026-08-14_future_directions.md) | Non-committal roadmap (RiMEA, periodic BCs, FiS) |
| [2026-08-07_validation_test_cases.md](./2026-08-07_validation_test_cases.md) | Full test specifications |
| [2026-08-07_simulation_platform_design.md](./2026-08-07_simulation_platform_design.md) | Architecture reference |
| [2026-08-07_code_design_practices.md](./2026-08-07_code_design_practices.md) | Coding standards |

---

## 8. Resume Phrase

> "Continue antigravity/SimCrowd. Read SESSION_STATE KI. Sprint 3H COMPLETE (33 passing, commit 5e2635f).
> Next: Sprint 3I — RiMEA T7 Bottleneck Flow ±15% of Weidmann 1.44 ped/s.
> The 3B-res test currently has peak_local_rate=0.9 ped/s vs target ≥1.22 ped/s.
> CellListMap boundary clipping bug documented in §10 of validation_caveats.md."
