# Hermes — Simulation Platform

Hermes is a Julia simulation platform for three linked domains:

- **Discrete Event Simulation (DES)**
- **Crowd Dynamics (ABM)**
- **Fluid Simulation** (planned)

The core idea is shared state and interoperable simulation layers rather than
separate standalone tools.

---

## Status: Pre-Alpha

This is research-stage software and not production-ready.

### Implemented

- **SimCore**: shared simulation types, world/state abstractions, statistics
  interfaces (`SimStats`, `StatsPipeline`), and common primitives.
- **SimDES**: serial DES engine with queue/network modelling and event-driven
  processing.
- **SimCrowd**: crowd modelling with SFM, ORCA, and hybrid variants, plus a GPU
  execution path through KernelAbstractions.jl.
- **SimViz**: desktop visualization (GLMakie) with demo scenarios including:
  evacuation, M/M/1 queue, DES+crowd integration, and a composite DES+ORCA demo.

### Not implemented / incomplete

- **SimFluid** numerical implementation (currently scaffold stage).
- Production-grade API stability and release process.
- Distributed PDES runtime (Chandy–Misra is planned, not finished).

APIs are expected to change.

---

## Intended Use

Target use cases include evacuation studies, venue/terminal flow analysis,
service-system experiments, and hybrid DES+crowd research workflows.

Current priority is correctness and validation discipline, especially around
DES↔ABM synchronization semantics.

---

## Parallelization Roadmap (Current Reality)

- **Serial baseline (available):** DES runs serially; crowd and viz integration
  operate in the current package pipeline.
- **CPU parallelism (partial):** crowd-side compute paths include threaded and
  kernel-based acceleration where applicable.
- **GPU (partial):** crowd kernels support GPU backends via
  KernelAbstractions.jl.
- **PDES / MPI (planned):** conservative PDES and multi-node execution are
  design targets, not complete features yet.

---

## Repository Structure

```
packages/
├── SimCore/    Shared types and infrastructure
├── SimDES/     Discrete-event simulation engine
├── SimCrowd/   Crowd/agent dynamics
├── SimFluid/   Fluid simulation scaffold
└── SimViz/     Visualization and demo scenarios

experiments/    Validation scripts (DrWatson environment)
docs/           Design notes, methodology, and session state
```

---

## Statistics Interfaces (Current + Migration Direction)

Hermes currently exposes two statistics interfaces:

- **`StatsPipeline` (primary direction)**: composable, warmup-aware metrics
  pipeline used for queueing and summary outputs.
- **`SimStats` (legacy compatibility)**: retained for backward compatibility and
  low-level counter visibility during migration.

### Migration intent

- New runtime/statistics feature work should target **`StatsPipeline`**.
- `SimStats` is being kept as a compatibility layer during convergence and is
  not intended as the long-term primary API.
- Planned retirement trigger for `SimStats`: after the deprecation window,
  once internal runtime usage is zero and migration guidance is complete.

See [docs/2026-08-07_implementation_phases.md](docs/2026-08-07_implementation_phases.md)
Phase 5.5 (“Statistics API Convergence”) for the tracked criteria.

---

## Primary Julia Dependencies

The platform relies on Julia packages including:

- `Ark.jl` (ECS)
- `AcceleratedKernels.jl` (portable CPU/GPU kernel patterns in crowd and stats paths)
- `KernelAbstractions.jl` (CPU/GPU kernels)
- `GLMakie.jl` + `Observables.jl` (visualization)
- `StaticArrays.jl` (small fixed-size vectors)
- `CellListMap.jl` (neighbor-search support)
- `DataStructures.jl` (priority queues and related structures)
- `DrWatson.jl` (experiment workflow)

`OnlineStats.jl` is **not** a runtime dependency at present; SimCore uses
internal collector implementations with an OnlineStats-like API style.

---

## Running Visualization Demos

From workspace root (`ABM/`):

```bash
julia --project=. -e 'using SimViz; run_evacuation_demo!()'
julia --project=. -e 'using SimViz; run_mm1_demo!()'
julia --project=. -e 'using SimViz; run_integration_demo!()'
julia --project=. -e 'using SimViz; run_des_orca_demo!()'
```

If you want a faster alarm transition in integration demos, set
`evac_alarm_time` to a smaller value (for example, `20.0`).

---

## Running Tests

From workspace root (`ABM/`):

```bash
julia --project=. -e 'import Pkg; Pkg.test("SimCore")'
julia --project=. -e 'import Pkg; Pkg.test("SimDES")'
julia --project=. -e 'import Pkg; Pkg.test("SimCrowd")'
julia --project=. -e 'import Pkg; Pkg.test("SimViz")'
```

Focused validation suites can also be run from individual package test
directories.

Requires Julia 1.12+. GPU-dependent paths require compatible hardware/runtime.

---

## Development Process Notes

This repository is developed with AI-assisted coding, but technical decisions,
acceptance criteria, and merges are human-reviewed.

Project process constraints are documented in:

- `docs/DEBUGGING_PROTOCOL.md`
- `docs/METHODOLOGY.md`
- `docs/2026-08-07_code_design_practices.md`

---

## References and Acknowledgements

Core modelling and validation references include:

- Helbing & Molnár (1995) — Social Force Model
- Helbing, Farkas & Vicsek (2000) — escape panic dynamics
- Chraibi et al. (2010) — generalized centrifugal-force model
- van den Berg et al. — ORCA / RVO2 family
- Weidmann (1993) — pedestrian fundamental diagram

Cross-checking and comparative workflows in this project have used open
implementations and literature, including JuPedSim and RVO2.

---

## License

Source-available. Free for academic research and educational use.
**Commercial use requires written authorization from the author.**
See [LICENSE](LICENSE) for full terms.

Copyright (c) 2026 Sourabh Kotnala — sauravkotnala@gmail.com
