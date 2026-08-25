# Chapter 10: Shallow Water & Grid Methods

While Smoothed Particle Hydrodynamics (SPH, [Chapter 9](file:///home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/09_sph_fluids.md)) is excellent for tracking complex, splashing fluid interfaces, it can be computationally expensive due to the massive number of interacting particles required to model a large body of water. 

For large-scale, continuous flows—such as modeling a river flooding into a subway station, or the dispersion of a toxic gas through a stadium concourse—SimFluid relies on **Eulerian (Grid-based)** methods.

## 10.1 The Lattice-Boltzmann Method (LBM)

Rather than solving the macroscopic Navier-Stokes equations directly, the **Lattice-Boltzmann Method (LBM)** models the fluid microscopically. It simulates fictional fluid particles colliding and streaming across a rigid spatial grid [1].

In a 2D simulation, the grid typically uses a **D2Q9 lattice** (2 Dimensions, 9 Quanta/Directions). Each grid cell contains a distribution function $f_i(\mathbf{x}, t)$ that tracks the probability of particles moving in one of the 9 discrete directions (Center, North, South, East, West, and the four diagonals).

The simulation advances in two distinct, highly parallelizable steps:
1. **Streaming**: Particles move to the neighboring grid cell in their respective direction.
   $$ f_i(\mathbf{x} + \vec{c}_i \Delta t, t + \Delta t) = f_i^*(\mathbf{x}, t) $$
2. **Collision**: Particles arriving at the same cell collide and "relax" toward a local equilibrium distribution (using the BGK collision operator).
   $$ f_i^*(\mathbf{x}, t) = f_i(\mathbf{x}, t) - \frac{1}{\tau} \left( f_i(\mathbf{x}, t) - f_i^{eq}(\mathbf{x}, t) \right) $$

**Architectural Synergy:** 
Because LBM is fundamentally a cellular automaton operating on a discrete grid, it integrates flawlessly with the Eikonal FMM grid described in [Chapter 6](file:///home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/06_navigation_field.md). The GPU can compute the LBM fluid dispersion on the exact same memory buffers used to calculate the pedestrian navigation potential field.

## 10.2 The Shallow Water Equations (SWE)

When modeling floods, calculating the full 3D vertical pressure profile of the water is usually unnecessary. If the horizontal scale of the flow (a 100-meter concourse) is vastly larger than the vertical depth of the water (0.5 meters), we can mathematically integrate the Navier-Stokes equations over the depth to create the **Shallow Water Equations (SWE)** [2].

The SWE reduce the 3D problem to a 2D problem, drastically cutting computational costs.
- **Mass Conservation**:
  $$ \frac{\partial h}{\partial t} + \frac{\partial (hu)}{\partial x} + \frac{\partial (hv)}{\partial y} = 0 $$
- **Momentum Conservation (X-direction)**:
  $$ \frac{\partial (hu)}{\partial t} + \frac{\partial}{\partial x} \left( hu^2 + \frac{1}{2}gh^2 \right) + \frac{\partial (huv)}{\partial y} = -gh \frac{\partial H}{\partial x} - C_f u \sqrt{u^2 + v^2} $$

Where:
- $h$ is the fluid depth.
- $u, v$ are the horizontal velocity components.
- $g$ is gravity.
- $H$ is the underlying terrain elevation (e.g., stairs or ramps).
- $C_f$ is the bottom friction coefficient (e.g., smooth tile vs. rough concrete).

## 10.3 Cross-Domain Interaction

The most powerful capability of the Antigravity platform is the coupling of these fluid models with the crowd dynamics models. 
For example, if the LBM or SWE solver detects that water depth $h(\mathbf{x})$ in a specific grid cell exceeds $0.1$ meters, it dynamically increases the pedestrian cost field $f(\mathbf{x})$ in that exact same cell (as described in [Section 6.3](file:///home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/06_navigation_field.md#63-dynamic-cost-fields-and-congestion-routing)). 

This causes the pedestrian navigation field (the Eikonal PDE) to instantly warp, forcing the simulated crowd to intelligently evacuate *away* from the advancing floodwaters.

---
## References
[1] Chen, S., & Doolen, G. D. (1998). Lattice Boltzmann method for fluid flows. *Annual Review of Fluid Mechanics*, 30(1), 329-364.
[2] Vreugdenhil, C. B. (1994). *Numerical Methods for Shallow-Water Flow*. Springer.
