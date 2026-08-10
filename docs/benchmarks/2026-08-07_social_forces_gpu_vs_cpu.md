# Benchmark: Social Forces (CPU vs GPU)
**Date:** 2026-08-07
**Component:** `SimCrowd.jl` (Social Force Model)

## Hardware Topology
- **CPU**: 24-core (tested at 16 threads for baseline)
- **CPU Backend**: `CellListMap.jl` (v0.10+ ParticleSystem API, multi-threaded)
- **GPU**: NVIDIA (via `CUDA.jl` and `KernelAbstractions.jl`)
- **GPU Backend**: Custom `RadixSpatialHash`

## Test Methodology
- 100 simulation steps per configuration.
- Agent scales: 1k, 10k, 50k, 100k.
- Measurement: Average time per step (ms/step).

## Results: Unoptimized GPU vs 16-Core CPU

*Note: In this test, the GPU implementation suffered from heavy per-step memory allocations and PCI-e transfer bottlenecks.*

| N (Agents) | 16-Core CPU (`CellListMap`) | GPU Backend (`RadixSpatialHash`) |
| :--- | :--- | :--- |
| **1,000** | **0.18 ms/step** | 0.26 ms/step |
| **10,000** | **0.72 ms/step** | 1.37 ms/step |
| **50,000** | **5.65 ms/step** | 6.94 ms/step |
| **100,000** | **15.15 ms/step** | 27.23 ms/step |

### Analysis
The 16-core CPU vastly outperforms the unoptimized GPU implementation at all scales. The GPU bottleneck is primarily driven by:
1. **Per-step `KernelAbstractions.zeros` allocations** in the ECS loop.
2. **PCI-e DMA Transfers**: Copying `positions` and `radii` to the device on every step.
3. **Uncoalesced Memory Access**: The `RadixSpatialHash` uses `sortperm!` to yield a permutation array. The subsequent physics kernel looks up memory via `positions[agent_indices[i]]`, resulting in random VRAM reads.

## Next Steps (Optimization Phase)
We will implement a `SocialForcesGPUContext` to pre-allocate device buffers, and a generic `reorder_array_kernel!` to physically shuffle the VRAM arrays based on the spatial hash. This will guarantee fully coalesced memory access on the GPU. We expect this to significantly change the performance profile.
