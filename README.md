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
- **GodotBridge + Godot GUI**: Protocol v1 MessagePack bridge and Godot 4
  monitoring client with live DES/ABM/hybrid state, runtime controls, inspector,
  trajectories, density/heatmap layers, reconnect recovery, and performance
  instrumentation.
- **GodotBridge + Godot Authoring Studio & Monitor**: Protocol v1 MessagePack
  bridge and Godot 4 interactive simulation platform:
  - **Synchronized Two-View Architecture**: 2D process-flow graph canvas and
    3D spatial digital twin viewport with instanced multi-mesh rendering.
  - **SceneSpec v1 Contract**: typed flow and metric ports, Y-up / Z-up spatial
    coordinate models, and hierarchical subgraphs with parameter overrides.
  - **Multi-Paradigm Component Catalog**: sources, queues, servers, conveyors,
    sinks, turnstiles, and crowd spawners.
  - **Rule-Based Inspector**: live parameter tuning, custom rule builder, and
    diagnostics panel.
  - **Resilient Multi-Format Persistence**: canonical `.scenespec` (JSON),
    binary MessagePack (`.scenespec.mp`), and composite `.simviz` bundles with
    automated autosave, crash recovery, and semantic diff preview.
  - **Live Runtime Monitoring**: entity trajectories, dynamic density
    heatmaps, transport controls (Play, Pause, Step, Reset), and performance
    instrumentation.

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
- **CPU parallelism (available):** crowd-side compute paths use threaded and
  KernelAbstractions-based backends through the shared `ScenarioConfig`
  `execution_backend` selector.
- **GPU (available for crowd kernels):** SimCrowd routes SFM, ORCA, HybridFSM,
  and CSM through backend-aware `RadixSpatialHash` / KernelAbstractions paths,
  with `:cuda` selectable from `ScenarioConfig`.
- **PDES / MPI (planned):** conservative PDES and multi-node execution are
  design targets, not complete features yet.

`SimViz` now builds all crowd models through the same backend-aware world
construction path, so user-facing backend choice is part of the public
scenario contract rather than a model-specific detail.

---

## Repository Structure

```
packages/
├── SimCore/    Shared types and infrastructure
├── SimDES/     Discrete-event simulation engine
├── SimCrowd/   Crowd/agent dynamics
├── SimFluid/   Fluid simulation scaffold
├── SimViz/     GLMakie visualization and demo scenarios
└── GodotBridge/ Protocol v1 runtime bridge

experiments/    Validation scripts (DrWatson environment)
docs/           Design notes, methodology, and session state
godot/          Godot 4 monitoring and authoring client
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
for the tracked criteria around statistics API convergence.

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

### Godot live monitor
### Godot Studio & Live Monitor

Requires Julia, Godot 4.7+, and local port `9107`.

```bash
bash run_phase7c_demo.sh
```

The live monitor displays DES elements, moving entities, trajectories, an ABM
density heatmap, runtime metrics, selection/inspection, and acknowledged
play/pause/step/reset/speed controls.
The interactive studio provides:
- **Visual Process Graph Authoring**: drag-and-drop 2D layout editor for discrete-event and agent-based components.
- **Synchronized 3D Digital Twin**: procedural 3D meshes, multi-level spatial layouts, and synchronized camera navigation.
- **Live Runtime Monitoring**: entity trajectories, dynamic density heatmap, station metrics, and transport controls (Play, Pause, Step, Reset, Speed).
- **Multi-Format Persistence**: atomic saving and loading for `.scenespec` (JSON), `.scenespec.mp` (MessagePack), and `.simviz` (project bundles) with automatic autosave and diff preview.

Run the clean automated Julia/Godot interoperability acceptance check with:
Run the master Phase 7D cross-boundary round-trip and authoring acceptance suite:

```bash
bash run_phase7c_acceptance.sh
bash run_phase7d_roundtrip_acceptance.sh
```

Phase 7C normal-scene monitoring acceptance is complete. The compact packed
array/`MultiMeshInstance2D` path is synthetically validated through 500K
entities; connected 500K GUI acceptance remains a separate scale gate.

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

Godot smoke tests can be run from `godot/`:

```bash
godot --headless --path . --script res://tests/protocol_smoke.gd
godot --headless --path . --script res://tests/state_store_smoke.gd
godot --headless --path . --script res://tests/viewport_smoke.gd
godot --headless --path . --script res://tests/scenespec_authoring_shell_smoke.gd
godot --headless --path . --script res://tests/scenespec_cross_roundtrip.gd
godot --headless --path . --script res://tests/scenespec_smoke.gd
godot --headless --path . --script res://tests/phase7c_acceptance_smoke.gd
```

Requires Julia 1.12+. GPU-dependent paths require compatible hardware/runtime.

---

## Development Process Notes

This repository is developed with AI-assisted coding, but technical decisions,
acceptance criteria, and merges are human-reviewed.

Project process constraints are documented in:

- `docs/DEBUGGING_PROTOCOL.md`
- `docs/METHODOLOGY.md`
- `docs/2026-08-07_code_design_practices.md`

Current Godot plans and evidence:

- `docs/2026-09-17_phase7c_design_and_implementation_plan.md`
- `docs/2026-09-17_phase7c_06_memory_and_scale_report.md`
- `docs/2026-09-18_phase7d_design_and_implementation_plan.md`

Phase 7D is planned as a SceneSpec-driven authoring environment with typed
Phase 7D delivers a complete SceneSpec-driven authoring studio with typed
ports, registry-based elements/models, synchronized 2D layout and 3D spatial
views, undo/redo, validation, import/export, and deterministic Julia runtime
compilation.
views, undo/redo, validation, and multi-format persistence. Phases 7D-00 through
7D-11 are fully implemented and verified across 41 smoke suites; Phase 7D-12
focuses on dynamic Julia compiler and runtime activation.

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
