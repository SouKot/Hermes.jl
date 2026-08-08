# Hermes.jl — Session State
**Last updated**: 2026-08-08 (Sprint 2D completed)  
**Repo**: `/run/media/sourabh/SANDISK-2TB/antigravity/ABM/`  
**Last conversation**: `78616c9e-3fd6-407c-bebd-abc1d7c4255f`

---

## ✅ Where We Left Off

### Last commit: `5ff94f2`
```
5ff94f2  sprint(2D): architecture hardening — ArrivalProcess, FailureModel, FEL-local cancel, auto-warmup
9648d0a  docs: add SESSION_STATE.md — live session continuity document
1e5ee2e  docs: integrate code review findings into implementation_phases.md
```

### Test status: ✅ ALL PASSING
```
SimDES:        69/69  tests
Sprint 2C:     70/70  tests  (+7 new typed-kwarg assertions from 2D)
Total:        139/139  tests in ~14.3s
```

---

## 📍 Active Phase: After 2D — Ready for Phase 3

Phases 2A, 2B, 2C, **2D** are complete. The Tier 1 serial DES engine is production-ready.

**Next milestone: Phase 3 — SimCrowd (Social Force Model)**

Or if more DES hardening is needed, minor deferred items from Sprint 2D:
| Task | Description |
|------|-------------|
| (minor) | Add `warmup_n` tests to SimDES test suite for explicit coverage |
| (Phase 5) | `DESContext` struct — move fork-join state out of SimCore |

---

## 🏗️ What Changed in Sprint 2D

### 2D-01 — FEL-local cancellation
- `FutureEventList` gains `cancelled::Set{UInt64}` — no `ReentrantLock` in Tier 1
- `cancel!(fel::FutureEventList, id)` is the new preferred API (O(1), no lock)
- `safe_dequeue!` checks `cev.id in fel.cancelled` directly
- `import SimCore: cancel!` in `SimDES.jl` prevents dual-binding ambiguity

### 2D-02 — ArrivalProcess hierarchy
```julia
abstract type ArrivalProcess end
struct NoArrival <: ArrivalProcess end          # default: no external arrivals
struct PoissonArrival <: ArrivalProcess          # homogeneous Poisson
    rate :: Float64
end
struct NHPPArrival <: ArrivalProcess             # non-homogeneous Poisson
    schedule :: ArrivalRateSchedule
end
```
- `ZoneConfig.arrival::ArrivalProcess` replaces flat `arrival_rate` + `arrival_schedule`
- **Legacy kwargs still work**: `arrival_rate=λ` auto-converts to `PoissonArrival(λ)`
- `_schedule_next_arrival!` dispatches on ArrivalProcess subtype (zero-overhead)

### 2D-03 — FailureModel hierarchy
```julia
abstract type FailureModel end
struct NoFailure <: FailureModel end             # default: no failures
struct BernoulliFailure <: FailureModel          # exponential TTF + repair
    α :: Float64   # failure rate
    β :: Float64   # repair rate
end
```
- `ZoneConfig.failures::FailureModel` replaces flat `failure_rate` + `repair_rate`
- **Legacy kwargs still work**: `failure_rate=α, repair_rate=β` auto-converts
- `ResourceFailure` and `Repair` handlers dispatch on FailureModel subtype

### 2D-04 — Automated warmup in sim_loop!
```julia
stats = sim_loop!(world, fel, configs, clock, rng;
                  t_end=100_000.0,
                  warmup_n=5_000)   # ← NEW: auto-flip warmup after 5k departures
```

### 2D-05 — TransferOut marked Tier 2 only
- Docstring updated with explicit note that `TransferOut` is reserved for Chandy-Misra PDES messages
- Tier 1 code should use `FixedRoute`/`ProbRoute` in `ZoneConfig`

---

## 📂 Key Files to Open at Session Start

| File | Purpose |
|------|---------|
| [`docs/2026-08-07_implementation_phases.md`](./2026-08-07_implementation_phases.md) | Phase tracker — source of truth |
| [`packages/SimDES/src/zone.jl`](../packages/SimDES/src/zone.jl) | ZoneConfig, ArrivalProcess, FailureModel |
| [`packages/SimDES/src/dispatch.jl`](../packages/SimDES/src/dispatch.jl) | Event dispatch hot path |
| [`packages/SimDES/src/fel.jl`](../packages/SimDES/src/fel.jl) | FEL + FEL-local cancel |
| [`packages/SimDES/src/loop.jl`](../packages/SimDES/src/loop.jl) | sim_loop! + warmup_n |
| [`packages/SimDES/test/runtests.jl`](../packages/SimDES/test/runtests.jl) | Full test suite (139 tests) |

---

## 🚀 How to Start Next Session

**Paste this into the new conversation:**

> "Continue Hermes.jl development. Read SESSION_STATE.md. Sprint 2D is complete.
> Start Phase 3 — SimCrowd Social Force Model."

**First thing to run:**
```bash
cd /run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/SimDES
julia --startup-file=no --project=. test/runtests.jl
```
Should output: `139/139 tests, ~14s`.

---

## 🔬 Deferred Work (Captured in Phase Tracker)

- **Phase 3**: SimCrowd — Social Force Model pedestrian simulation
- **Phase 4**: SimViz — GLMakie desktop visualization  
- **Phase 5**: Tier 2 PDES — Chandy-Misra Conservative PDES (per-LP FEL)
  - 5A-06: `DESContext` struct — move fork-join state out of SimCore
  - 5A-07: `configs::Vector` instead of `Dict` for >20 zones
- **Sprint 8-07**: `_priority_enqueue!` O(log n) if needed for large scenarios

---

## 🏗️ Architecture Summary

```
SimCore  ← shared types: SimWorld, SimEvent, SimClock, SimStats, ZoneState
SimDES   ← Tier 1 serial DES: FEL, dispatch!, ZoneConfig, ArrivalProcess, FailureModel
SimCrowd ← Phase 3: Social Force Model (not started)
SimFluid ← Phase 9: deferred
SimViz   ← Phase 4: GLMakie desktop (not started)
```

**ZoneConfig shape (Sprint 2D):**
```julia
ZoneConfig(
  id, num_servers, capacity, service_dist,
  arrival  :: ArrivalProcess,   # NoArrival | PoissonArrival(λ) | NHPPArrival(sched)
  failures :: FailureModel,     # NoFailure | BernoulliFailure(α, β)
  routing  :: RoutingPolicy,    # ExitSystem | FixedRoute(to) | ProbRoute(choices)
  queue_discipline :: QueueDiscipline,  # FIFO | PRIORITY_HOL
  fork_join :: Union{Nothing, ForkJoinConfig},
  ...
)
```
