# Chapter 7: Microscopic Locomotion Models

Once an agent has determined its desired velocity vector $\vec{v}_0$ via the Eikonal potential field ([Chapter 6](file:///home/sourabh/.gemini/antigravity-ide/brain/78616c9e-3fd6-407c-bebd-abc1d7c4255f/06_navigation_field.md)), it must physically move through space. Because multiple agents are competing for the same physical space, collisions are inevitable. 

**Microscopic Locomotion Models** define the mathematical rules governing how individual agents alter their velocity to avoid each other, avoid walls, and navigate through bottlenecks. Antigravity supports several interchangeable locomotion models, allowing the user to select the appropriate mathematical framework for their specific density regime.

## 7.1 The Social Force Model (SFM)

The most famous agent-based locomotion model in pedestrian dynamics is the **Social Force Model (SFM)**, originally proposed by Dirk Helbing in 1995 [1]. SFM relies on Newtonian mechanics. An agent's acceleration is driven by the sum of theoretical "forces":

$$ m_i \frac{d\vec{v}_i}{dt} = \vec{F}_i^{goal} + \sum_{j \neq i} \vec{F}_{ij}^{soc} + \sum_{W} \vec{F}_{iW}^{soc} + \sum_{j \neq i} \vec{F}_{ij}^{phys} $$

### 7.1.1 Motivation Force ($\vec{F}^{goal}$)
Also known as the relaxation or driving force, this term represents the agent's internal desire to adapt its current velocity $\vec{v}_i$ to its desired velocity $\vec{v}_0$ over a relaxation time $\tau$:
$$ \vec{F}_i^{goal} = m_i \frac{\vec{v}_0 - \vec{v}_i}{\tau} $$

### 7.1.2 Psychological Repulsion ($\vec{F}^{soc}$)
Pedestrians try to maintain a comfortable distance from others. This is modeled as a repulsive exponential force that increases as the distance $d_{ij}$ between agents shrinks:
$$ \vec{F}_{ij}^{soc} = A \cdot \exp\left(\frac{r_{ij} - d_{ij}}{B}\right) \vec{n}_{ij} $$
Where $A$ is the interaction strength, $B$ is the effective range, $r_{ij}$ is the sum of their radii, and $\vec{n}_{ij}$ is the normalized vector pointing from agent $j$ to agent $i$. 

### 7.1.3 Physical Forces ($\vec{F}^{phys}$)
At extremely high densities, psychological boundaries break down and physical contact occurs ($d_{ij} < r_{ij}$). SFM models this using granular physics:
1. **Body Force (Elastic)**: Pushes overlapping agents apart. $k g(r_{ij} - d_{ij}) \vec{n}_{ij}$
2. **Sliding Friction**: Impedes tangential motion when bodies press together. $\kappa g(r_{ij} - d_{ij}) \Delta v_t \vec{t}_{ij}$
(Where $g(x)$ is zero if $x < 0$, and equals $x$ otherwise).

### 7.1.4 The "Faster-is-Slower" (FiS) Effect
A defining success of SFM is its ability to spontaneously reproduce the **Faster-is-Slower** phenomenon during panic evacuations. If agents' desired speeds ($v_0$) increase, they aggressively push into bottlenecks (doors). The resulting granular friction forces ($\vec{F}^{phys}$) create physical arching and deadlocks, dropping the macroscopic flow rate (throughput) dramatically [2].

## 7.2 Generalized Centrifugal Force Model (GCFM)

A critical flaw in classical SFM is its assumption that pedestrians are perfectly circular. In reality, human shoulders are wider than human chests. At high densities, classical SFM agents overlap unnaturally because the repulsive forces are completely isotropic (equal in all directions).

Antigravity implements the **Generalized Centrifugal Force Model (GCFM)** [3], which replaces the circular repulsion with **elliptical equipotential lines**. The semi-axes of the ellipse dynamically stretch in the direction of the agent's velocity. This accurately reproduces the "zipper effect" where pedestrians naturally turn their shoulders sideways to squeeze through tight crowds, drastically improving the accuracy of fundamental diagrams at densities $>4 \text{ ped/m}^2$.

## 7.3 Optimal Reciprocal Collision Avoidance (ORCA)

SFM and GCFM are "force-based" models. At low densities, force-based models can cause unnatural oscillating behavior (agents vibrating as forces push them back and forth). 

To solve this, Antigravity implements **ORCA**, a geometric, non-force-based algorithm widely used in robotics [4]. 
Instead of calculating forces, ORCA calculates **Velocity Obstacles (VO)**. An agent mathematically defines the cone of future trajectories that will result in a collision with a neighbor. The agent then formulates a **Linear Programming (LP)** problem to find the optimal velocity vector that lies exactly on the edge of the VO cone, ensuring a strictly collision-free path.

**When it fails:** ORCA is perfect for sparse, highly structured flow. However, in extreme density panics, it is geometrically impossible to find a collision-free velocity. The Linear Programming solver becomes "infeasible," and the algorithm breaks down.

## 7.4 Advanced Architecture: Hybrid FSM

Because ORCA excels in sparse free-flow and SFM excels in dense granular contact, Antigravity introduces a **Hybrid Finite State Machine (FSM)** architecture. 

The ECS engine constantly monitors the local macroscopic density $\rho(\mathbf{x})$ via the spatial hashing grid. 
- If $\rho < 2.0 \text{ ped/m}^2$, the engine utilizes ORCA, generating perfectly smooth, anticipatory collision avoidance.
- If $\rho \ge 2.0 \text{ ped/m}^2$, the engine detects the LP infeasibility and instantaneously switches the agent's ECS Archetype to utilize the SFM/GCFM force integrators, properly simulating the physical pushing and friction required to model crushing behavior. 

This hybrid approach allows the platform to bridge the gap between intelligent robotic routing and irrational fluid-like panic dynamics.

---
## References
[1] Helbing, D., & Molnar, P. (1995). Social force model for pedestrian dynamics. *Physical Review E*, 51(5), 4282.
[2] Helbing, D., Farkas, I., & Vicsek, T. (2000). Simulating dynamical features of escape panic. *Nature*, 407(6803), 487-490.
[3] Chraibi, M., Seyfried, A., & Schadschneider, A. (2010). Generalized centrifugal-force model for pedestrian dynamics. *Physical Review E*, 82(4), 046111.
[4] Van Den Berg, J., Guy, S. J., Lin, M., & Manocha, D. (2011). Reciprocal n-body collision avoidance. In *Robotics research* (pp. 3-19). Springer.
