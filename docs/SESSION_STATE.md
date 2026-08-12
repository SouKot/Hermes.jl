# SESSION STATE

> **DO NOT EDIT BY HAND.** Updated automatically at end of each session.  
> Last updated: 2026-08-12 (conversation `78616c9e-3fd6-407c-bebd-abc1d7c4255f`)

---

## 1. Where We Left Off

- **Last Commit:** `763ab36 (HEAD → master) feat(SimCrowd): Sprint 1B — ContactModel enum + GPU μ parity`
- **Previous:** `64ce516 fix(SimCrowd): Sprint 1A — AgentParams μ default + navigation mass + test API sync`
- **Current Phase:** Sprint 1 COMPLETE. Ready for Sprint 2 (Performance).
- **Test Status:**
  ```
  runtests.jl:                18/18   2.8s
  Tier 3: Cross-Library Validation vs Published Benchmarks |  8/8   1m20s
    3A-easy ORCA N=30 antipodal circle                      | 3/3
    3A-hard ORCA N=250 collision avoidance                  | 2/2
    3B SFM Bottleneck N=50 6×6m (Helbing 2000)              | 1/1
    3C SFM Faster-is-Slower N=50 (Helbing 2000 Figure 4)    | 2/2
  ```

---

## 2. What Was Accomplished in Sprint 1

### Sprint 1A (commit 64ce516) — Correctness Bugs
| Fix | File | Details |
|-----|------|---------|
| `AgentParams` 4-arg constructor: `μ = F(1.2e5) → F(0.5)` | `SimCrowd.jl:45` | `1.2e5` was body stiffness `k`, not friction coefficient |
| `update_navigation_system!` mass bug | `navigation.jl:116` | `F_drive = (v_pref×dir−vel)/τ` stored as Force; physics divided by mass again → 80× too weak. Fixed → `mass × ...` |
| `agent_repulsion` old 4-arg API | `runtests.jl:31` | Forces refactor expanded to 8-arg; test not updated |
| CRW-S-01 query included `ORCAParams` | `runtests.jl:113` | Entity has AgentParams only; query returned empty → no force → agent drifted on noise |
| `goal_seeking_force` test assertion | `runtests.jl:20` | Expected 2.0 (old accel) → 160.0 N (mass × accel) |
| 3-arg `AgentParams(r, v_pref, τ)` | bench/validate scripts | Old form predating `mass` field; fixed to 4-arg with mass=80.0f0 |
| `ap.radius` → `ap.social_radius` | `validate_parity.jl` | Field rename not propagated |

### Sprint 1B (commit 763ab36) — ContactModel + GPU Parity
| Fix | File | Details |
|-----|------|---------|
| `ContactModel` enum | `SimCrowd.jl` | `@enum ContactModel::Int32 { NoContact, Coulomb, Viscous }` encoded in `AgentParams.μ` sentinel |
| New `AgentParams` constructor | `SimCrowd.jl` | `AgentParams(r, m, vp, τ, model::ContactModel [, μ])` — sets both collision_radius and μ from model |
| `contact_force` ContactModel dispatch | `forces.jl` | `isinf(μ)` → Viscous (pure κ×g×Δv_t, FiS-capable); `iszero(μ)` → NoContact; else Coulomb |
| GPU μ parity | `social.jl` | `cpu_mus/dev_mus/sorted_dev_mus` buffers in `SocialForcesGPUContext`; per-agent μ uploaded and sorted each step; kernel reads `μ_i` from `sorted_mus[i]` — last hardcoded GPU default removed |

---

## 3. Next Sprint — Sprint 2 (Performance)

Full plan at: `simcrowd_improvement_plan.md` (in conversation artifacts).

### Sprint 2 — Performance (START HERE)
| Task | File | Effort | Notes |
|------|------|--------|-------|
| Replace O(N²) psych loop with KA `@kernel(CPU())` | `social.jl:322` | 1 day | Architecture: one kernel, `CPU()` + `CUDABackend()` dispatch. No Polyester. |
| Morton curve sorting in `RadixSpatialHash` | `neighbor_search.jl` | 3h | Memory locality improvement for cache performance |

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
| `packages/SimCrowd/src/systems/social.jl` | Phase 3 O(N²) psych loop → KA `@kernel` |
| `packages/SimCrowd/src/neighbor_search.jl` | `RadixSpatialHash` Morton curve sorting |
| `packages/SimCrowd/src/SimCrowd.jl` | ContactModel enum (just added) |
| `packages/SimCrowd/src/forces.jl` | contact_force ContactModel dispatch (just added) |

---

## 5. API Reference — What Changed in Sprint 1

### New types
```julia
@enum ContactModel::Int32 NoContact Coulomb Viscous  # exported
```

### New constructors
```julia
# ContactModel constructor — sets collision_radius and μ automatically
AgentParams(r, m, vp, τ, model::ContactModel)           # μ defaults to 0.5 for Coulomb
AgentParams(r, m, vp, τ, model::ContactModel, μ::F)     # explicit μ for Coulomb

# Examples
AgentParams(0.25f0, 80f0, 1.4f0, 0.5f0, NoContact)     # social force only
AgentParams(0.25f0, 80f0, 4.0f0, 0.5f0, Viscous)       # FiS-capable evacuation
AgentParams(0.25f0, 80f0, 1.4f0, 0.5f0, Coulomb, 0.3f0) # custom μ
```

### contact_force dispatch via μ
| μ value | ContactModel | Behavior |
|---------|--------------|----------|
| `iszero(μ)` | NoContact | Returns zero — no body contact |
| `isinf(μ)` | Viscous | Pure `κ×g×Δv_t` — Helbing 2000 exact, FiS-capable |
| `0 < μ < Inf` | Coulomb | `clamp(κ×g×Δv_t, ±μ×k×g)` — default |

---

## 6. Resume Commands

**After restart**, paste this in the new conversation to restore context instantly:
> "Continue antigravity/SimCrowd development. Read SESSION_STATE.md. Sprint 1 is complete (runtests 18/18, Tier 3 8/8). Start Sprint 2: replace the O(N²) psych loop in social.jl with a KA @kernel."

**Run tests to verify no drift:**
```bash
cd /run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/SimCrowd
julia --startup-file=no --project=. test/runtests.jl       # Expected: 18/18
julia --startup-file=no --project=. test/tier3_cross_library.jl  # Expected: 8/8
```

---

## 7. Open Questions / Decisions Pending

| Question | Context | Decision |
|----------|---------|---------|
| Polyester.@batch for psych loop? | Sprint 2 | **No** — use KA @kernel with CPU()/GPU() backends. One implementation, zero new deps. See §3.1 of improvement plan. |
| Should we switch to Chraibi GCF as default SFM? | Sprint 4 | Deferred — keep Helbing as default, add GCF as `ForceModel` option |
| Should 3B use 6-arg (body contact)? | Tier 3 | No — 5-arg is intentional. 3B = social-only, 3C = full contact+FiS |
| Per-agent A, B, k, κ, λ? | Sprint 3/4 | Deferred — requires AgentParams struct expansion. Currently module-level defaults |
