# Hermes — Simulation Platform

A Julia-based simulation platform being built to handle three interconnected
domains under a single agent-based engine:

- **Discrete Event Simulation (DES)** — queues, servers, event scheduling, multi-scale process modelling
- **Crowd Dynamics** — pedestrian agent simulation using physics-based force models and collision-avoidance algorithms
- **Fluid Simulation** — particle-based methods (planned, not yet started)

The unifying idea is that a customer in a queue, a pedestrian in a crowd, and a
fluid particle are all *agents with state and behavioural rules* — the same
computational substrate should handle all three.

---

## Status: Pre-Alpha

This is early-stage research and development code. It is not ready for production
use. What exists and works:

- **SimDES** — serial DES engine (M/M/1, M/M/c, M/G/1, tandem queues, Jackson
  networks, fork-join, NHPP arrivals, machine failures). 55+ tests passing.
- **SimCrowd** — crowd simulation with:
  - Social Force Model (SFM, Helbing & Molnár 1995)
  - GCF-Elliptical model (Chraibi 2010) — RiMEA T2 compliant at all 4 densities
  - ORCA collision avoidance (van den Berg et al.)
  - Hybrid FSM (density-triggered ORCA+SFM dispatch) — passes RiMEA T7 at 2.3× threshold
  - GPU acceleration via KernelAbstractions.jl

What is not yet built: fluid simulation, real-time visualization, multi-level
geometry, staircase models.

The API is unstable and will change without notice.

---

## Intended Use

The long-term goal is a general-purpose simulation tool comparable in scope to
AnyLogic or FlexSim, but built in Julia for performance and open extensibility.
Intended application areas include evacuation planning, venue capacity analysis,
manufacturing process simulation, and airport terminal flow.

This is a solo research project. There is no roadmap commitment or release
schedule.

### Parallelization

Parallelism is a first-class concern, not an afterthought. The plan has three
levels:

- **CPU thread-level** (in progress) — crowd force computation runs across all
  available CPU cores via `Threads.@threads`. SimDES is serial today; a
  Conservative Parallel DES engine (Chandy-Misra null-message protocol, one
  logical process per facility) is the planned Tier 2.
- **GPU** (partial) — crowd simulation uses KernelAbstractions.jl kernels that
  compile to CUDA or Metal. The same kernel code runs on CPU for correctness
  testing and on GPU for large-N performance.
- **Multi-node / MPI** (not started) — Tier 3 target for very large-scale
  multi-facility networks. Depends on Tier 2 being stable first.

The three-tier architecture (serial → threaded PDES → MPI) is described in the
internal design document.

---

## Development Approach

This project is developed with significant AI assistance (primarily large language
models used as a coding and research pair). Every design decision, algorithm
choice, parameter value, and test assertion goes through human review before being
committed. The AI is used to accelerate implementation and surface options; the
human decides what is correct and why. All validation results are independently
checked against published reference implementations (JuPedSim, RVO2, Menge) and
peer-reviewed papers.

---

## Repository Structure

```
packages/
├── SimCore/    Shared types, ECS world, event definitions
├── SimDES/     DES engine — FEL, routing, statistics
├── SimCrowd/   Crowd dynamics — SFM, GCF, ORCA, Hybrid FSM
├── SimFluid/   Fluid simulation (skeleton only)
└── SimViz/     Visualization (not yet started)

experiments/    Validation scripts (DrWatson environment)
```

---

## Running the Tests

```bash
# From packages/SimCrowd:
julia --threads auto --project=. -e 'using Pkg; Pkg.test()'

# Run cross-library tier-3 benchmarks:
julia --threads auto --project=. test/tier3_cross_library.jl
```

Requires Julia 1.12+. GPU tests require a CUDA-capable device.

---

## Acknowledgements

### Algorithms and research

The crowd simulation models are implementations of published peer-reviewed work.
The parameters used in the code and tests are taken directly from the original
papers, not calibrated to fit our output.

- **Helbing & Molnár (1995)** — *Social force model for pedestrian dynamics.*
  Physical Review E 51(5). Foundation of the SFM implementation; parameters
  A=2000 N, B=0.08 m, λ=0.5, τ=0.5 s.

- **Helbing, Farkas & Vicsek (2000)** — *Simulating dynamical features of escape
  panic.* Nature 407. Contact force model (spring constant k, friction κ),
  stochastic noise amplitude σ=0.3 N/kg, faster-is-slower effect.

- **Chraibi, Seyfried & Schadschneider (2010)** — *Generalized centrifugal-force
  model for pedestrian dynamics.* Physical Review E 82(4). GCFM-elliptical
  personal space model; parameters η, b_min, b_max, a₀ from Table I of that paper.

- **van den Berg, Guy, Lin & Manocha (2008–2011)** — *Reciprocal velocity
  obstacles / Reciprocal n-body collision avoidance.* The ORCA algorithm.
  The linear-programming routines in `orca_math.jl` are a Julia port of the
  reference RVO2 C++ implementation.

- **Weidmann (1993)** — *Transporttechnik der Fußgänger.* ETH Zurich. The
  fundamental diagram (speed vs. density) and bottleneck flow rate used as
  primary validation targets throughout the test suite.

### Cross-validation references

Test results are cross-checked against these open-source implementations:

- **JuPedSim** (Forschungszentrum Jülich) — primary comparison library for
  bottleneck flow, fundamental diagram, and speed distribution tests.
- **RVO2** (University of North Carolina) — reference C++ ORCA implementation;
  our tier-3 ORCA tests reproduce the `Blocks.cc` and `Circle.cc` scenarios.
- **Menge** (University of North Carolina / GAMMA group) — architectural
  reference for the density-triggered Hybrid FSM design (Sprint 3K).
- **UMANS** (Van Toll et al., 2022) — used for ORCA bidirectional corridor
  speed-efficiency comparison (Table 3).

### Julia ecosystem

This project relies on the following Julia packages:
[Ark.jl](https://github.com/Gesee-y/Ark.jl) (ECS),
[KernelAbstractions.jl](https://github.com/JuliaGPU/KernelAbstractions.jl) (GPU kernels),
[StaticArrays.jl](https://github.com/JuliaArrays/StaticArrays.jl),
[CellListMap.jl](https://github.com/m3g/CellListMap.jl) (neighbor search),
[DataStructures.jl](https://github.com/JuliaCollections/DataStructures.jl) (priority queue),
[HypothesisTests.jl](https://github.com/JuliaStats/HypothesisTests.jl),
[Distributions.jl](https://github.com/JuliaStats/Distributions.jl),
[DrWatson.jl](https://github.com/JuliaDynamics/DrWatson.jl) (experiment management).

---

## License

Source-available. Free for academic research and educational use.
**Commercial use requires written authorization from the author.**
See [LICENSE](LICENSE) for full terms.

Copyright (c) 2026 Sourabh Kotnala — sauravkotnala@gmail.com
