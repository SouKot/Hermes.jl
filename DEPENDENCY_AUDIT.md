# Hermes.jl — Dependency License Audit
**Last updated**: 2026-08-07  
**Policy**: All production dependencies must have MIT, Apache-2.0, or BSD-2/3 license.  
**GPL/AGPL/LGPL**: BLOCKED — do not add without explicit legal review.

---

## Production Dependencies

| Package | Version | License | Source | Status | Notes |
|---|---|---|---|---|---|
| `DataStructures.jl` | ≥0.18 | MIT | [GitHub](https://github.com/JuliaCollections/DataStructures.jl) | ✅ Approved | PriorityQueue for FEL |
| `StaticArrays.jl` | ≥1.5 | MIT | [GitHub](https://github.com/JuliaArrays/StaticArrays.jl) | ✅ Approved | SVector for agent positions |
| `GLMakie.jl` | ≥0.9 | MIT | [GitHub](https://github.com/MakieOrg/Makie.jl) | ✅ Approved | Desktop visualization |
| `KernelAbstractions.jl` | ≥0.9 | MIT | [GitHub](https://github.com/JuliaGPU/KernelAbstractions.jl) | ✅ Approved | GPU kernels (hardware-agnostic) |
| `CUDA.jl` | ≥5.0 | MIT | [GitHub](https://github.com/JuliaGPU/CUDA.jl) | ✅ Approved | NVIDIA GPU backend |
| `LinearAlgebra` | stdlib | MIT | Julia stdlib | ✅ Approved | norm, dot, etc. |
| `Logging` | stdlib | MIT | Julia stdlib | ✅ Approved | Event logging |
| **`Ark.jl`** | TBD | **⚠️ CHECK** | TBD | ❓ **PENDING AUDIT** | ECS engine — check license before use |

## Development-Only Dependencies (not shipped to customers)

| Package | License | Status | Notes |
|---|---|---|---|
| `Revise.jl` | MIT | ✅ Dev only | Hot-reload during development |
| `DrWatson.jl` | MIT | ✅ Dev only | Experiment management |
| `BenchmarkTools.jl` | MIT | ✅ Dev only | Benchmarking |
| `JET.jl` | MIT | ✅ Dev only | Static analysis / type stability |
| `Aqua.jl` | MIT | ✅ Dev only | Package quality checks |
| `Documenter.jl` | MIT | ✅ Dev only | HTML documentation generation |
| `DocStringExtensions.jl` | MIT | ✅ Dev only | Docstring macros |
| `PkgTemplates.jl` | MIT | ✅ Dev only | Package scaffolding |
| `JuliaFormatter.jl` | MIT | ✅ Dev only | Code formatting |
| `ProfileView.jl` | MIT | ✅ Dev only | Flamegraph profiler |
| `PProf.jl` | MIT | ✅ Dev only | Chrome-based flamegraph |
| `TestItemRunner.jl` | MIT | ✅ Dev only | VSCode test integration |

---

## Audit Process

When adding a new dependency:
1. Navigate to the package's GitHub repository
2. Find the `LICENSE` file in the root
3. Record the license type and URL below
4. If MIT/Apache-2.0/BSD → add to the table above and mark ✅
5. If GPL/AGPL/LGPL → open a discussion before using
6. Update this file with the PR that adds the dependency

## Pending Audits

| Package | Reason for audit | Assigned to | Due date |
|---|---|---|---|
| `Ark.jl` | Not widely known; license may not be standard | TBD | Before first use |
