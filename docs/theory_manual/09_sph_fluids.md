# Chapter 9: SPH & Particle Methods

Part IV of this manual transitions to **SimFluid**, the engine's dedicated fluid dynamics module. However, as outlined in the "Unified Simulation Framework" thesis ([Chapter 1](file:///home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/01_unified_framework.md)), SimFluid is not a separate codebase. It is built directly on top of the exact same ECS and GPU infrastructure as the crowd simulators.

To model true compressible fluids (like water flowing through a ruptured stadium pipe), SimFluid utilizes **Smoothed Particle Hydrodynamics (SPH)** [1].

## 9.1 The Lagrangian Perspective

Fluid dynamics can be modeled from two perspectives:
1. **Eulerian (Grid-based)**: The observer stands still and watches the fluid flow past specific coordinate grid cells (as used in the LWR macroscopic crowd model).
2. **Lagrangian (Particle-based)**: The observer "rides" along with a specific particle of fluid as it moves through space.

SPH is a Lagrangian, mesh-free method. A fluid is represented by discrete particles, each possessing a mass $m_i$, position $\vec{r}_i$, velocity $\vec{v}_i$, and a local density $\rho_i$. The Navier-Stokes equations governing fluid flow (Conservation of Mass and Momentum) are solved by calculating forces between these moving particles.

## 9.2 The Smoothing Kernel ($W$)

Because the fluid is represented by discrete points, we must "smooth" their properties over space to calculate continuous fields like pressure and density. SPH achieves this using an interpolation function called the **Smoothing Kernel** $W(\vec{r} - \vec{r}', h)$, where $h$ is the smoothing length (the effective radius of the particle).

The density of a particle $i$ is calculated by summing the mass of all neighboring particles $j$ weighted by the kernel:
$$ \rho_i = \sum_{j} m_j W(\vec{r}_i - \vec{r}_j, h) $$

Once the density is known, the pressure $P_i$ is calculated using an Equation of State (Tait's Equation for water). Finally, the pressure gradient force (which pushes particles away from high-density areas) is calculated:
$$ \vec{F}_i^{pressure} = -\frac{m_i}{\rho_i} \sum_{j} m_j \left( \frac{P_i}{\rho_i^2} + \frac{P_j}{\rho_j^2} \right) \nabla W(\vec{r}_i - \vec{r}_j, h) $$

## 9.3 The Architectural Elegance of the Unified Engine

If you examine the SPH pressure force equation above, and compare it to the Social Force Model (SFM) psychological repulsion equation in [Chapter 7](file:///home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/07_micro_locomotion.md), the mathematical isomorphism is striking.

- Both require iterating over all neighbors $j$ within a cutoff radius $h$.
- Both calculate a repulsive force based on proximity.
- Both use a Symplectic Euler integrator to update positions.

**The ECS Implementation:**
Because of this isomorphism, SimFluid does not need its own physics engine. 
1. An SPH fluid particle is simply an ECS Entity with a `FluidParticle` archetype.
2. The $O(N)$ neighbor search required to find all particles within radius $h$ is executed by the exact same GPU Spatial Hashing algorithm (`CellListMap.jl`) used by the pedestrian simulator ([Chapter 2](file:///home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/02_numerical_methods.md)).
3. The contiguous Structure-of-Arrays (SoA) memory layout guarantees that the GPU can compute SPH pressure fields for millions of water particles at 60 frames per second, matching the performance of dedicated C++ physics engines.

---
## References
[1] Monaghan, J. J. (1992). Smoothed particle hydrodynamics. *Annual Review of Astronomy and Astrophysics*, 30(1), 543-574.
