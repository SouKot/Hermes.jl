# Chapter 6: Navigation & Route Planning

Part III of this manual focuses entirely on **SimCrowd**, the continuous-time agent-based pedestrian dynamics engine. Before an agent can physically move and avoid collisions, it must know *where* it is trying to go. 

In traditional video game architectures, navigation is often handled via graph-based algorithms like A* or Dijkstra's algorithm. However, in dense crowd simulations, discrete graph nodes create highly unnatural, jagged movement paths, and hundreds of thousands of agents independently running A* is computationally intractable. 

Instead, Antigravity utilizes **Macroscopic Potential Fields**, solving continuous Partial Differential Equations (PDEs) to create smooth, global navigation fields that all agents query simultaneously in $O(1)$ time [1].

## 6.1 The Eikonal Equation and Potential Fields

The goal of the navigation system is to generate a scalar field $\phi(x, y)$ across the entire walkable environment, where the value at any point represents the shortest travel time to the destination (e.g., an exit gate). 

This is mathematically formulated as the **Eikonal Equation**, a non-linear PDE fundamental to wave propagation and optics:

$$ \|\nabla \phi(\mathbf{x})\| = \frac{1}{f(\mathbf{x})} \quad \text{for } \mathbf{x} \in \Omega $$
$$ \phi(\mathbf{x}) = 0 \quad \text{for } \mathbf{x} \in \Gamma $$

Where:
- $\Omega$ is the walkable domain.
- $\Gamma$ is the destination boundary (the exit).
- $f(\mathbf{x})$ is the local speed field at position $\mathbf{x}$ (how fast an agent can walk through that specific space).

If the space is empty and flat, $f(\mathbf{x})$ is a constant (e.g., $1.34$ m/s, the average human walking speed). The solution to this equation produces a gradient field that smoothly flows around walls and obstacles, completely eliminating the unnatural "corner-hugging" artifacts seen in discrete A* graphs.

### 6.1.1 Solving via the Fast Marching Method (FMM)
Because solving the Eikonal equation analytically is impossible for complex geometry (like a stadium concourse), the engine solves it numerically on a discrete GPU grid using the **Fast Marching Method (FMM)** [2].

The FMM is an Eulerian interface-tracking algorithm conceptually similar to Dijkstra's algorithm, but adapted for continuous PDEs. It starts at the destination boundary $\Gamma$ and expands an active "wavefront" outward, calculating the arrival time $\phi$ for every grid cell based on its neighbors using an upwind finite-difference scheme.

By offloading the FMM to the GPU, the engine can compute the entire potential field for a massive stadium in milliseconds.

## 6.2 Generating the Desired Velocity ($\vec{v}_0$)

Once the potential field $\phi(\mathbf{x})$ is computed, an agent simply looks up the value at their current coordinate. Because $\phi$ represents the "cost" to reach the exit, the optimal path is always the steepest descent of this field. 

The agent calculates its **Desired Velocity** ($\vec{v}_0$) by taking the negative normalized gradient of the field, scaled by its personal desired speed ($v_{max}$):

$$ \vec{v}_0 = -v_{max} \frac{\nabla \phi(\mathbf{x})}{\|\nabla \phi(\mathbf{x})\|} $$

This vector $\vec{v}_0$ is a critical input component for all microscopic locomotion models discussed in [Chapter 7](file:///home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/07_micro_locomotion.md) (such as the Social Force Model and ORCA).

## 6.3 Dynamic Cost Fields and Congestion Routing

In an empty stadium, the speed field $f(\mathbf{x})$ is constant. But what happens during an evacuation when a specific hallway becomes completely jammed with people? If the navigation field remains static, agents will blindly march into the jammed hallway because it is mathematically the "shortest geometric path."

To model intelligent human routing, SimDES employs **Dynamic Cost Fields**. 

The local speed $f(\mathbf{x})$ is continuously updated based on the local macroscopic density $\rho(\mathbf{x})$. Using the spatial hashing grid from [Chapter 2](file:///home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/02_numerical_methods.md), the engine calculates the density at every grid cell. As density increases, the local speed $f(\mathbf{x})$ decreases according to empirical fundamental diagrams (e.g., Weidmann's relationship, where speed drops to nearly zero at $5.4 \text{ ped/m}^2$).

$$ f(\mathbf{x}, t) = V_0 \cdot \left( 1 - e^{-\gamma \cdot (\frac{1}{\rho(\mathbf{x},t)} - \frac{1}{\rho_{max}})} \right) $$

As $f(\mathbf{x})$ approaches zero in crowded areas, the Eikonal equation assigns a massive time-cost $\phi$ to those regions. The GPU recalculates the FMM field periodically (e.g., every 1.0 seconds). Consequently, the gradient $\nabla \phi$ dynamically warps *around* the congestion, naturally causing incoming agents to reroute to longer, but faster, alternate exits. 

This dynamic feedback loop between microscopic physical positioning (density) and macroscopic PDE routing (the Eikonal field) is the cornerstone of realistic crowd behavior in Antigravity.

---
## References
[1] Treuille, A., Cooper, S., & Popović, Z. (2006). Continuum crowds. *ACM Transactions on Graphics (TOG)*, 25(3), 1160-1168.
[2] Sethian, J. A. (1996). A fast marching level set method for monotonically advancing fronts. *Proceedings of the National Academy of Sciences*, 93(4), 1591-1595.
