# Hermes.jl — Simulation Platform

> *Hermes: Greek god of speed and commerce. Built with Julia.*

A high-performance, general-purpose simulation platform combining:
- **Discrete Event Simulation (DES)** — parallel, multi-scale event scheduling
- **Crowd Dynamics** — Social Force Model (SFM) with GPU acceleration
- **Fluid Simulation** — SPH/LBM (Phase 3)
- **Real-time Visualization** — GLMakie (Phase 1) → Godot 4 (Phase 2)

**Status**: Pre-alpha (active development)  
**License**: Commercial proprietary — see [LICENSE](LICENSE)

## Repository Structure

```
packages/
├── SimCore/    Shared types, ECS world, events
├── SimDES/     DES engine, FEL, Conservative PDES
├── SimCrowd/   Social Force Model, crowd dynamics
├── SimFluid/   Fluid simulation skeleton (Phase 3)
└── SimViz/     GLMakie visualization layer

docs/           Design documents and reference
experiments/    Validation test cases (DrWatson)
```

## Getting Started (Internal)

```julia
# Start Julia from the repo root
julia --threads auto --project=.

# In Julia REPL:
using SimDES, SimCrowd, SimViz
```

## Documentation

- [Architecture Design](docs/2026-08-07_simulation_platform_design.md)
- [Validation Test Cases](docs/2026-08-07_validation_test_cases.md)
- [Code Design & Practices](docs/2026-08-07_code_design_practices.md)
