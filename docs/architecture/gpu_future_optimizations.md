# Future GPU Optimizations & Architecture Roadmap
**Status:** Living Document
**Purpose:** A backlog of known architectural bottlenecks in the GPU backend and strategies to alleviate them, derived from benchmarking and profiling. When time permits, these can be pulled into a sprint.

---

### `[ ]` 1. Lazy Grid Rebuilding / Verlet Lists
- **The Bottleneck:** Currently, the `RadixSpatialHash` reconstructs the entire spatial grid and runs a full Radix Sort (`sortperm!`) on every single simulation frame. This is extremely expensive at 100k+ agents.
- **The Solution:** Implement a "skin radius" (Verlet list) approach. Instead of sorting every frame, we track the maximum displacement of any agent since the last sort. If no agent has moved further than the skin radius, we can safely reuse the grid from the previous frame.
- **Flexibility Note:** This dynamic threshold ensures mathematical correctness regardless of agent speed. Fast vehicles will automatically trigger grid rebuilds every 1–2 frames, while slow pedestrians might only trigger a rebuild every 10–20 frames.

### `[ ]` 2. GPU-Native ECS Storage (Zero PCI-e Transfers)
- **The Bottleneck:** `Ark.jl` stores its components as standard CPU `Vector`s. This forces us to push data across the PCI-e bus to the GPU and back on every frame (H2D and D2H transfers).
- **The Solution:** Write a custom storage backend for `Ark.jl` that natively allocates components as `CuArray`s. 
- **The Impact:** If the canonical simulation state lives permanently in VRAM, the physics kernels can run infinitely without ever communicating with the CPU, completely eliminating PCI-e overhead. The CPU would only be used for occasional rendering or logging.

### `[ ]` 3. Newton's Third Law via Spatial Graph Coloring
- **The Bottleneck:** The GPU does exactly 2x the mathematical workload of the CPU because it cannot safely use Newton's Third Law ($F_{ij} = -F_{ji}$) without atomic memory writes (which serialize execution and destroy parallelism).
- **The Solution:** Implement "Spatial Graph Coloring". By partitioning the spatial grid into 8 distinct colors, we can guarantee that no two adjacent cells are processed simultaneously. This removes race conditions and allows the GPU to safely write to neighbor forces without atomics.
- **Trade-off:** This is highly complex to implement and manage on the GPU. It is generally only worth the engineering effort if the actual math inside the force computation becomes astronomically expensive. For simple social forces, doing 2x the math is often still faster than managing graph coloring.
