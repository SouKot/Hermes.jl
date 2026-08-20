# Antigravity — Working Methodology & Process Conventions

> **Read this at the start of every Antigravity session.**  
> Last updated: 2026-08-20

---

## 1. How to Resume After a Restart

When starting a **new conversation** after switching the computer off:

1. **Read `SESSION_STATE.md`** — the canonical resume document:
   - In-repo: `/run/media/sourabh/SANDISK-2TB/antigravity/ABM/docs/SESSION_STATE.md`
   - KI backup: `/home/sourabh/.gemini/antigravity-ide/knowledge/antigravity_session_state/artifacts/state.md`
   It contains: last commit hash, test status, next tasks, and a **ready-to-paste resume phrase**.

2. **Check the phase tracker** — `docs/2026-08-07_implementation_phases.md` is the
   single source of truth for what is done and what is next.

3. **Reference the active conversation** (for deep context if needed):
   - Conversation ID: `78616c9e-3fd6-407c-bebd-abc1d7c4255f`
   - Transcript: `/home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/.system_generated/logs/transcript.jsonl`
   - Artifacts (improvement plan, walkthrough): `/home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/`

4. **Run the verification test before starting new work:**
   ```bash
   cd /run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/SimCrowd
   julia --startup-file=no --project=. -t auto test/tier3_cross_library.jl
   # Expected: 33 passed, 0 failed (3A–3H)
   ```
   All Tier 3 tests must pass before new work begins.

---

## 2. The Core Workflow (Every Session)

```
REQUEST → PLAN → APPROVE → EXECUTE → VERIFY → COMMIT → CLOSE OUT
```

### Step A — Plan Before Acting
- For any non-trivial change: write an `implementation_plan.md` artifact first.
- State: what will change, why, and how to verify.
- Wait for **explicit user approval** ("yes", "go ahead", "looks good") before touching code.
- Exception: trivial fixes (typos, docstring corrections, one-liner changes) go directly.

### Step B — Research Before Writing
- Before any code change: **read the relevant files** (view_file, grep_search).
- Check the Knowledge Items for established patterns. Do not assume from memory.
- Follow **Debugging Protocol KI**: check docs first, then write diagnostic code, never guess.

### Step C — Measure Before Optimizing
- **"Measure, don't guess"** is the project's performance rule.
- Always run benchmarks (e.g. `bench_new.jl`) **before** declaring a performance
  issue and **after** implementing a fix.
- Do not claim O(n) is a problem without showing it in nanoseconds on the actual workload.

### Step D — Execute
- Make code changes with `multi_replace_file_content` (multiple non-adjacent edits)
  or `replace_file_content` (single contiguous edit).
- Preserve all existing comments and docstrings unrelated to the change.
- Update docstrings immediately when changing function semantics.

### Step E — Test Before Committing
- **All tests must pass before any commit.** No exceptions.
- Run: `julia --startup-file=no --project=. -t auto test/tier3_cross_library.jl`

### Step F — Commit with a Descriptive Message
- Commit format (multi-line):
  ```
  <type>: <short summary>

  <what changed and why — one paragraph>
  <benchmark numbers if performance change>
  <tests: N/N pass in Xs>
  ```
- Types: `feat`, `fix`, `perf`, `docs`, `refactor`, `test`
- Always include test counts and timings in commit messages for perf changes.

---

## 3. Post-Sprint Close-Out Checklist

> **MANDATORY after every successful sprint.** Do not start the next sprint until all boxes are checked.
> The purpose: ensure the project state is fully recoverable after a computer restart.

### 3A. Code Commits
- [ ] All test files committed (tier3_cross_library.jl, crowd_test_helpers.jl)
- [ ] Helper/infrastructure code committed (new structs, config types, etc.)
- [ ] Project.toml / Manifest.toml committed if new dependencies added
- [ ] Commit message includes: what was implemented, test results (N/N passing), and any important lessons

### 3B. Documentation — In-Repo (`docs/`)
- [ ] **`implementation_phases.md`**: mark the sprint `[x]` DONE with actual results, commit hash, and date
- [ ] **`validation_caveats.md`**: add a new `§N` section documenting:
  - What passed / failed and why
  - Any root causes discovered (bugs, model limitations, test design issues)
  - Key lessons for future tests (e.g. "skip update_social_forces_system! for drift tests")
  - Update the RiMEA compliance table (T1–T15 status column)
- [ ] **`SESSION_STATE.md`**: update to reflect:
  - Last commit hash and message
  - Updated test counts (all suites)
  - Sprint status (completed → archived, next sprint → NEXT)
  - Any new architectural decisions
  - Updated Resume Phrase
- [ ] Commit documentation changes: `git commit -m "docs: mark Sprint 3X DONE, update SESSION_STATE"`

### 3C. Knowledge Items (KI) — IDE Agent's Memory
- [ ] **`antigravity_session_state/artifacts/state.md`**: fully rewrite to mirror SESSION_STATE.md
  - File path: `/home/sourabh/.gemini/antigravity-ide/knowledge/antigravity_session_state/artifacts/state.md`
  - Must include: last commit, test counts, next sprint, key lessons from this sprint
  - Update "Last updated" timestamp at top
  - The KI is what the agent reads first at the start of any new conversation — **this is the most important file**

### 3D. Validation Tests (if assertions changed)
- [ ] If the test thresholds or assertions changed: document WHY in `validation_caveats.md`
- [ ] If new dependencies added to `Project.toml`: verify `Manifest.toml` is regenerated
- [ ] If a new test helper function added: verify it's exported / accessible

### 3E. Final Verification
- [ ] Run full test suite one more time after all doc updates:
  ```bash
  julia --startup-file=no --project=. -t auto test/tier3_cross_library.jl
  ```
- [ ] Confirm total test count matches SESSION_STATE.md and KI state.md

---

## 4. What Each File Is For (Quick Reference)

| File | When to update | What to update |
|------|----------------|----------------|
| `implementation_phases.md` | After each sprint | `[ ]` → `[x]` with results + commit hash |
| `validation_caveats.md` | After each test sprint | New `§N` section + update compliance table |
| `SESSION_STATE.md` | After each session | Last commit, test counts, next sprint, resume phrase |
| KI `state.md` | After each session | Full rewrite to mirror SESSION_STATE.md |
| `tier3_cross_library.jl` | When adding/fixing tests | New `@testset` blocks |
| `crowd_test_helpers.jl` | When adding infrastructure | New `run_X!` functions |
| `Project.toml` | When adding dependencies | `[deps]` section |

---

## 5. Project Structure

```
/run/media/sourabh/SANDISK-2TB/antigravity/ABM/
├── packages/
│   ├── SimCore/          ← shared kernel (events, world, clock, stats)
│   ├── SimDES/           ← serial DES engine, Tier 1
│   ├── SimCrowd/         ← social force crowd (Phase 3)
│   ├── SimFluid/         ← fluid simulation (Phase 9)
│   └── SimViz/           ← visualization (Phase 4)
├── experiments/
└── docs/
    ├── 2026-08-07_implementation_phases.md   ← THE PHASE TRACKER (sprint checkboxes)
    ├── 2026-08-19_validation_caveats.md      ← per-test honest assessment + lessons
    ├── 2026-08-07_simulation_platform_design.md
    ├── 2026-08-07_validation_test_cases.md
    ├── 2026-08-07_code_design_practices.md
    └── SESSION_STATE.md                      ← live session state (human-readable)

IDE Agent Memory (KI system):
/home/sourabh/.gemini/antigravity-ide/knowledge/
├── antigravity_session_state/artifacts/state.md    ← AGENT'S FIRST READ on restart
└── antigravity_working_methodology/artifacts/methodology.md  ← THIS FILE
```

---

## 6. Code Standards (Non-Negotiable)

| Rule | Applies to |
|------|-----------|
| **Unicode in math** — use λ, μ, ρ, τ, Δt, α, β freely in internal code | All packages |
| **ASCII in public APIs** — function names, exported symbols | All exports |
| **JET.jl** static analysis must pass on hot paths | SimCore, SimDES, SimCrowd |
| **Aqua.jl** package quality checks | All packages |
| **Float Parameterization** — `F <: AbstractFloat` | SimCrowd |
| **Dispatch on Backends** — `CPU` vs `GPU` multiple dispatch | SimCrowd Systems |
| **`CellListMap` on CPU** — Always use `ParticleSystem` for symmetric pair forces | SimCrowd CPU |
| **`KernelAbstractions.jl` is backend-agnostic** — supports `CPU()`, `CUDABackend()`, `ROCmBackend()`, `MetalBackend()`. All `@kernel` functions run on all backends. Do NOT add Polyester — KA subsumes it. | SimCrowd systems |
| **No Polyester** — KA `CPU()` backend already uses Julia threads with negligible overhead difference for compute-heavy loops. Fewer deps, no thread model conflicts, one GPU-portable abstraction. | SimCrowd |
| **GPU kernel parameters from ECS** — never hardcode A, B, λ, k, κ, μ in kernels | SimCrowd GPU |

---

## 7. Known Gotchas (Learned the Hard Way)

| Gotcha | When it bites | Fix |
|--------|---------------|-----|
| **CellListMap boundary clipping** | Any test where agents drift past the CPUNeighborSearch bounding box `[xmin,xmax]`. Agents are clipped to boundary → spurious 0-distance pairs → huge body contact forces. | Skip `update_social_forces_system!` for free-flow drift tests, OR extend box by `v_max × t_total`. See validation_caveats §10. |
| **Periodic BC → platoon formation** | Speed distribution tests with periodic corridors. Fast agents catch slow agents → speed compression → KS test fails. | Use finite corridor (no periodic BC) for speed distribution. |
| **Wall friction corrupts x-speeds** | Agents placed at y = agent_radius (0.25m) are at wall contact threshold. SFM wall friction `F_fric = -κ×vx` reduces fast agents more → distribution compression. | y_margin ≥ 1.0m for speed tests. |
| **σ>0 + Threads.@threads → non-deterministic** | Tests with σ>0 noise in `integrate_physics_system!`. The global Julia RNG is shared across threads → order-dependent results. | Use σ=0.0 for deterministic/repeatable assertions. |
| **Goal ON wall → equilibrium trap** | Agent goal placed exactly at exit wall coordinate. Goal-seeking force = 0 at wall → agent freezes. | Place goal ≥ 0.5m past the exit wall. |
| **WallSegment not in World() constructor** | `update_social_forces_system!` queries `WallSegment{F}` internally. If it's not declared in `World(...)`, Ark throws `ArgumentError`. | Always declare `WallSegment{F}` in `World()` even in open-space tests. |
| **Query ordering ≠ creation order (suspected)** | Speed measurement using `v_prefs[idx]` (creation array) vs `vel_col[i]` (query order). | Use combined `Query(world, (Velocity{F}, MotionParams{F}))` to read speed and v_pref from the same entity in the same loop. |
