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

## Results: Intermediate GPU (Coalesced Memory) vs 16-Core CPU

*Note: In this test, all per-step GPU allocations were eliminated, and VRAM memory access was strictly coalesced, but the GPU still rebuilt the spatial grid on every frame.*

| N (Agents) | 16-Core CPU (`CellListMap`) | Intermediate GPU (ms/step) |
| :--- | :--- | :--- |
| **1,000** | **0.19 ms/step** | 0.24 ms/step |
| **10,000** | 1.11 ms/step | **0.98 ms/step** |
| **50,000** | 6.68 ms/step | **6.14 ms/step** |
| **100,000** | 20.70 ms/step | **18.60 ms/step** |

### Intermediate Conclusion
The coalesced memory and allocation optimizations were incredibly successful. They eliminated roughly 32% of the GPU computation time at 100k scale (from 27.23 ms down to 18.60 ms). As a result, the GPU formally reclaimed the performance crown at simulation scales ≥ 10,000 agents.

## Results: Final Optimized GPU (Lazy Sorting) vs 16-Core CPU

*Note: In this final test, a Skin Radius (Verlet List) optimization was added to prevent the spatial grid from being sorted every frame, layering on top of the coalesced memory fixes.*

| N (Agents) | 16-Core CPU (ms/step) | 16-Core CPU (Total: 100 steps) | Optimized GPU (ms/step) | Optimized GPU (Total: 100 steps) |
| :--- | :--- | :--- | :--- | :--- |
| **1,000** | 0.20 ms/step | 20.5 ms | **0.18 ms/step** | **18.6 ms** |
| **10,000** | 1.14 ms/step | 114.0 ms | **0.90 ms/step** | **90.8 ms** |
| **50,000** | 7.42 ms/step | 742.9 ms | **6.21 ms/step** | **621.7 ms** |
| **100,000** | 18.52 ms/step | 1852.8 ms | **17.36 ms/step** | **1736.8 ms** |

### PCI-e Data Transfer Overhead (N = 100,000)
To determine if PCI-e bus transfers were bottlenecking the GPU, we explicitly profiled the DMA transfers at `N = 100,000`:
- **Host to Device (H2D)**: 0.452 ms / step
- **Device to Host (D2H)**: 0.332 ms / step
- **Total Transfer Cost**: **0.783 ms / step**

**Conclusion on Transfers**: The total transfer cost is only ~0.78 ms per step, representing less than **5% of the total GPU step time** (17.36 ms). Therefore, PCI-e transfer is *not* a primary bottleneck.

### Architecture Notes
1. **Newton's Third Law ($F_{ij} = -F_{ji}$)**: The `CellListMap` CPU backend takes advantage of Newton's third law. When it computes a force between Agent A and Agent B, it applies it to both agents simultaneously, cutting the math workload exactly in half. On the GPU, doing this requires **atomic memory writes** to avoid thread collisions, which cripples parallel performance. Thus, the GPU computes all forces independently, doing exactly **2x the mathematical workload** of the CPU.
2. **Lazy Sorting (Verlet Lists)**: We implemented a skin radius threshold. A custom GPU kernel checks if `sum(abs2.(current_pos - last_sort_pos)) > skin_radius^2` for *any* agent. If no agent has breached the skin radius, we skip rebuilding the spatial grid entirely. This dynamic threshold guarantees mathematical correctness for high-speed vehicles while eliminating O(N) radix sort overhead for slow pedestrians.
