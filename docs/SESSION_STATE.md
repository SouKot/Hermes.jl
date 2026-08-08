# Hermes.jl — Session State
**Last updated**: 2026-08-08 (end of session)  
**Repo**: `/run/media/sourabh/SANDISK-2TB/antigravity/ABM/`  
**Last conversation**: `78616c9e-3fd6-407c-bebd-abc1d7c4255f`

---

## ✅ Where We Left Off

### Last commit: `1e5ee2e`
```
1e5ee2e  docs: integrate code review findings into implementation_phases.md
8a7ce85  Perf + safety: remove_des_agent!, QueueDiscipline enum, zone_stats guard
11e7ecd  Phase 2C: Medium DES scenarios — tandem, Jackson, priority, failures, NHPP, fork-join
```

### Test status: ✅ ALL PASSING
```
SimDES:        69/69  tests
Sprint 2C:     63/63  tests
Total:        132/132  tests in ~15s
```

### Current throughput baseline: **1.73M events/sec** (M/M/1, 50k arrivals)

---

## 📍 Active Phase: Between 2C and 2D

Phase 2A, 2B, 2C are **complete**. The engine is fully functional for Tier 1 serial DES.

**Sprint 2D is next** — SimDES Architecture Hardening (5 tasks, not started):

| Task | Description | Effort |
|------|-------------|--------|
| **2D-01** | FEL-local cancellation set — remove global `ReentrantLock` | 1h |
| **2D-02** | `ArrivalProcess` abstraction (PoissonArrival, NHPPArrival types) | 2h |
| **2D-03** | `FailureModel` abstraction (BernoulliFailure type) | 1h |
| **2D-04** | Automated Welch warm-up detection wired into `sim_loop!` | 4h |
| **2D-05** | Mark `TransferOut` as deprecated for direct Tier 1 use | 30min |

**After 2D, the next major milestone is Phase 3 (SimCrowd).**

---

## 📂 Key Files to Open at Session Start

| File | Purpose |
|------|---------|
| [`docs/2026-08-07_implementation_phases.md`](./2026-08-07_implementation_phases.md) | Phase tracker — THE source of truth |
| [`packages/SimDES/src/zone.jl`](../packages/SimDES/src/zone.jl) | ZoneConfig, ArrivalProcess (2D-02 starts here) |
| [`packages/SimDES/src/dispatch.jl`](../packages/SimDES/src/dispatch.jl) | Event dispatch hot path |
| [`packages/SimDES/src/fel.jl`](../packages/SimDES/src/fel.jl) | FEL + CancellableEvent (2D-01 starts here) |
| [`packages/SimCore/src/events.jl`](../packages/SimCore/src/events.jl) | CancellableEvent, global cancel set |
| [`packages/SimCore/src/world.jl`](../packages/SimCore/src/world.jl) | SimWorld, ZoneState |
| [`packages/SimDES/test/runtests.jl`](../packages/SimDES/test/runtests.jl) | Full test suite |

---

## 🚀 How to Start Next Session

**Paste this into the new conversation:**

> "Continue Hermes.jl development. Read `SESSION_STATE.md` and `implementation_phases.md` to get context. 
> Then start Sprint 2D — begin with task 2D-01 (FEL-local cancellation set)."

**Or if you want to pick a specific task:**
> "Continue Hermes.jl. Read session state. Implement 2D-02: ArrivalProcess abstraction."

**First thing to run in new session:**
```bash
cd /run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/SimDES
julia --startup-file=no --project=. test/runtests.jl
```
Should output: `132/132 tests, ~15s`. If it doesn't, debug before starting new work.

---

## 🏗️ Architecture Summary

```
SimCore  ← shared types (SimWorld, SimEvent, SimClock, SimStats, ZoneState)
SimDES   ← Tier 1 serial DES (FEL, dispatch!, zone configs, runners)
SimCrowd ← Phase 3: Social Force Model (not started)
SimFluid ← Phase 9: deferred
SimViz   ← Phase 4: GLMakie desktop (not started)
```

**Event flow**: `schedule!(fel, event, t)` → `sim_loop!` dequeues → `dispatch!(world, fel, configs, rng, event, t)` → schedules next events + updates stats.

---

## 📋 Completed This Session (2026-08-08)

1. **Implemented Phase 2C** (6 medium DES scenarios): tandem queue, Jackson network, 
   priority queuing (HOL non-preemptive), machine failures, NHPP thinning, fork-join.
2. **Fixed routing-loop bug**: `is_external` flag on `EntityArrival` gates external arrival scheduling.
3. **Fixed machine failure bug**: `zone.num_servers` vs `cfg.num_servers` in EntityArrival dispatch.
4. **Performance hardening** (commit `8a7ce85`):
   - `remove_des_agent!` on hot path (−78ns/departure, +3% throughput)
   - `isempty(world.zone_stats)` guard in `_update_time_averages!`
   - `@enum QueueDiscipline { FIFO=1, PRIORITY_HOL=2 }` replacing `:symbol`
5. **Code review** (`code_review.md`): full performance + modularity analysis with benchmarks.
6. **Updated `implementation_phases.md`**: Sprint 2D added, Phase 5 augmented, 
   Key Technical Decisions updated with benchmark-confirmed results.

---

## 🔬 Deferred Work (Captured in Phase Tracker)

All deferred items are in `implementation_phases.md`. Key ones:
- **2D**: FEL cancellation, ArrivalProcess/FailureModel abstractions, Welch automation
- **5A-06**: `DESContext` struct — move fork-join state out of SimCore
- **5A-07**: `configs::Vector` instead of `Dict` for Tier 2 (>20 zones)
- **8-07**: `_priority_enqueue!` O(log n) if needed in large scenarios
