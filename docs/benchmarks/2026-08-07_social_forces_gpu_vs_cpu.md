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
We implemented a `SocialForcesGPUContext` to pre-allocate device buffers, and a generic `reorder_array_kernel!` to physically shuffle the VRAM arrays based on the spatial hash. This guarantees fully coalesced memory access on the GPU. 

## Results: Optimized GPU vs 16-Core CPU

*Note: In this test, all per-step GPU allocations have been eliminated, and VRAM memory access is strictly coalesced.*

| N (Agents) | 16-Core CPU (ms/step) | 16-Core CPU (Total: 100 steps) | Optimized GPU (ms/step) | Optimized GPU (Total: 100 steps) |
| :--- | :--- | :--- | :--- | :--- |
| **1,000** | **0.19 ms/step** | **19.2 ms** | 0.24 ms/step | 24.7 ms |
| **10,000** | 1.11 ms/step | 111.0 ms | **0.98 ms/step** | **98.5 ms** |
| **50,000** | 6.68 ms/step | 668.8 ms | **6.14 ms/step** | **614.0 ms** |
| **100,000** | 20.70 ms/step | 2070.2 ms | **18.60 ms/step** | **1860.1 ms** |

### PCI-e Data Transfer Overhead (N = 100,000)
To determine if PCI-e bus transfers were bottlenecking the GPU, we explicitly profiled the DMA transfers at `N = 100,000`:
- **Host to Device (H2D)**: 0.452 ms / step
- **Device to Host (D2H)**: 0.332 ms / step
- **Total Transfer Cost**: **0.783 ms / step**

**Conclusion on Transfers**: The total transfer cost is only ~0.78 ms per step, representing less than **5% of the total GPU step time** (18.60 ms). Therefore, PCI-e transfer is *not* the primary reason the GPU isn't 5x faster than the CPU. 

### Why isn't the GPU 5x faster?
1. **Newton's Third Law (F_ij = -F_ji)**: The `CellListMap` CPU backend takes advantage of Newton's third law. When it computes a force between Agent A and Agent B, it applies it to both agents simultaneously, cutting the math workload exactly in half. On the GPU, doing this requires **atomic memory writes** to avoid thread collisions, which cripples parallel performance. Thus, the GPU computes all forces independently, doing exactly **2x the mathematical workload** of the CPU.
2. **Per-Frame Sorting**: The GPU backend rebuilds the grid and Radix-Sorts 100,000 agents from scratch on every single frame to maintain coalesced memory.
3. **CPU Strength**: A 16-core modern CPU is an absolute powerhouse. It's not a slow baseline to beat.
