# Chapter 2: Numerical Integration & Spatial Hashing

## 2.1 The Equations of Motion and Behavioral Forces
In continuous-time pedestrian models (such as the Social Force Model) [1] and particle-based fluid models (such as Smoothed Particle Hydrodynamics), entities are treated as discrete point masses moving through continuous space. Their movement is governed by a superposition of forces, formulated identically to Newton's Second Law of Motion. The state of an entity $i$ evolves according to the following system of ordinary differential equations (ODEs):

$$ m_i \frac{d\vec{v}_i}{dt} = \vec{F}_i^{goal} + \sum_{j \neq i} \vec{F}_{ij}^{social} + \sum_{w} \vec{F}_{iw}^{wall} $$
$$ \frac{d\vec{r}_i}{dt} = \vec{v}_i $$

Where:
- $\vec{r}_i$ and $\vec{v}_i$ are the two-dimensional position and velocity vectors of entity $i$.
- $m_i$ is the mass of the entity. In macroscopic fluid dynamics, this is a physical mass. In crowd dynamics, however, it is standard practice to normalize mass ($m_i = 1$) because the "forces" driving human locomotion are largely decoupled from physical inertia; a person can stop walking almost instantly compared to a sliding block of ice [1].

While this equation mirrors classical mechanics, the forces involved in crowd simulation are primarily **psychological and behavioral**, transitioning to physical forces only at extreme densities. Let us break down each component:

### 2.1.1 The Driving Force ($\vec{F}_i^{goal}$)
A pedestrian is not a passive particle blown by the wind; they have a destination. $\vec{F}_i^{goal}$ represents the internal desire of the pedestrian to accelerate toward their specific target at a preferred walking speed (typically around 1.34 m/s). If unimpeded, this "driving force" propels the agent forward. If the agent deviates from their path or speed, this force acts as a corrective spring pulling them back to their desired state.

### 2.1.2 Agent-Agent Interaction ($\vec{F}_{ij}^{social}$)
Pedestrians prefer to maintain a comfortable "territorial" distance from strangers. $\vec{F}_{ij}^{social}$ is the sum of repulsive forces exerted by all other nearby pedestrians ($j$) onto our focus pedestrian ($i$). 
- At low densities, this force is purely psychological (a soft, exponential repulsion) causing people to steer around one another. 
- At high densities (such as a panic evacuation through a narrow doorway), this term changes character drastically. It becomes a hard, physical contact force modeling the compression of ribcages and sliding friction between shoulders [1].

### 2.1.3 Obstacle Interaction ($\vec{F}_{iw}^{wall}$)
Similar to agent-agent interactions, pedestrians will steer clear of walls, columns, and fences. $\vec{F}_{iw}^{wall}$ is the repulsive force from the static geometry of the environment.

By summing these three components (the desire to move forward, the desire to avoid others, and the desire to avoid walls), we yield a net acceleration vector that governs the agent's next step.

## 2.2 Numerical Integration: The Symplectic Euler Method

Because the forces acting on an agent change continuously as they move (especially the highly non-linear repulsive forces), the ODEs described above cannot be solved analytically. We must step the simulation forward in discrete time chunks, denoted as the timestep $\Delta t$.

In computational fluid dynamics, higher-order integrators like Runge-Kutta 4 (RK4) are highly favored for their accuracy. However, RK4 requires evaluating the forces four times per timestep. Because pairwise force evaluation (checking distances between every pair of agents) is the single most expensive operation in our engine, RK4 is computationally prohibitive for simulating crowds of $100,000+$ agents in real-time.

A standard alternative is the **Explicit (Forward) Euler** method, which evaluates forces only once:
1. Calculate forces based on current positions.
2. Update position using current velocity.
3. Update velocity using the calculated forces.

However, Explicit Euler is disastrous for systems involving stiff contact forces (like a dense crowd pressing against a door). It injects artificial energy into the system [3]. If two agents are pushing against each other, the delayed response of Explicit Euler causes them to overshoot their equilibrium distance, resulting in a massive repulsive force on the next step, which causes an even larger overshoot in the opposite direction. The system quickly explodes into numerical instability.

To solve this, the Antigravity platform utilizes **Symplectic Euler** (also known as Semi-Implicit Euler):

$$ \vec{v}_i(t + \Delta t) = \vec{v}_i(t) + \Delta t \cdot \frac{\vec{F}_i(t)}{m_i} $$
$$ \vec{r}_i(t + \Delta t) = \vec{r}_i(t) + \Delta t \cdot \vec{v}_i(t + \Delta t) $$

Notice the critical difference: the position update uses the *newly computed* velocity $\vec{v}_i(t + \Delta t)$, not the old velocity. This subtle change makes the integrator *symplectic*. Symplectic integrators perfectly conserve the phase-space volume of the system [3]. While the energy of the system might oscillate slightly around the true value, it is guaranteed not to drift or explode over time. For resolving the highly oscillatory "spring-like" contact forces in a dense crowd, Symplectic Euler provides robust, unconditionally stable behavior for a much wider range of timesteps.

### 2.2.1 The Timestep Constraint (Stiffness)
Despite the stability of Symplectic Euler, the choice of the timestep $\Delta t$ is still heavily dictated by the mathematical stiffness of the underlying behavioral models.
- **The Social Force Model (SFM)**: When simulating panic, the SFM models human bodies as stiff springs with a stiffness constant $k \approx 120,000$ N/m [1]. Resolving this intense granular repulsion without numerical explosion requires an extremely fine timestep: $\Delta t \approx 0.001$ seconds (1000 updates per simulated second).
- **The Generalized Centrifugal Force Model (GCFM)**: This model relies on softer, exponential potential fields and avoids rigid body collisions entirely [2]. Because the force gradients are smoother, it permits a much larger, more performant timestep: $\Delta t \approx 0.01$ seconds (100 updates per simulated second).

## 2.3 Resolving O(N²) Interactions: Spatial Hashing

The summation term $\sum_{j \neq i} \vec{F}_{ij}^{social}$ implies that to calculate the force on agent $i$, we must compute the distance to every other agent $j$ in the simulation. For a crowd of $N = 100,000$, this requires $10^{10}$ distance checks per timestep. Running this at 1000 timesteps per second is computationally impossible, even on modern GPU hardware.

Fortunately, both social repulsion and fluid pressure decay rapidly with distance. Beyond a certain "cutoff radius" $R_c$ (typically 2 to 3 meters for a pedestrian), the repulsive force from a neighbor is mathematically negligible and can be safely truncated to absolute zero. 

The Antigravity platform leverages this physical reality by employing **Spatial Hashing** (implemented via the highly optimized `CellListMap.jl` library), a technique widely used in Molecular Dynamics [4]. The algorithm fundamentally transforms the performance scaling of the engine:

1. **Grid Partitioning**: The entire simulation space is divided into a grid of square cells, where the side length of each cell $L$ is exactly equal to or slightly larger than the cutoff radius $R_c$.
2. **Binning ($O(N)$)**: At the start of every timestep, each agent's $(x,y)$ coordinate is hashed to determine which grid cell they belong to. The agent's ID is appended to that cell's list.
3. **Neighbor Search**: When it is time to calculate the forces acting on agent $i$, the engine does not loop over all $N$ agents. Instead, it only checks the agents residing in agent $i$'s current cell, plus the agents in the 8 directly adjacent neighboring cells.

Because $L \ge R_c$, it is mathematically guaranteed that any agent within the cutoff radius *must* reside in one of these 9 cells. This reduces the time complexity of the force calculation from $O(N^2)$ to $O(N \cdot k)$, where $k$ is the local density (the average number of neighbors within the cutoff radius). As a result, the simulation scales linearly with the number of agents.

## 2.4 Stochastic Calculus and Symmetry Breaking

Human behavior is inherently noisy and unpredictable. In physical crowd simulations, this noise serves a critical mathematical function: it introduces perturbations that break geometric symmetry. 

To understand why this is necessary, consider two common simulation failure modes:
1. **The Head-to-Head Deadlock**: If two agents are walking directly toward each other in a perfectly straight, narrow corridor, their repulsive forces point exactly backward. The deterministic forces perfectly cancel out their forward driving forces, leaving them frozen in place indefinitely.
2. **The "Arching" Effect**: When a dense crowd tries to push through a narrow doorway simultaneously, the pedestrians form a semi-circular formation around the exit. The repulsive physical forces pushing inward perfectly balance each other, creating a stable, unmoving physical structure identical to a masonry arch in architecture. The flow completely halts [1].

In reality, these perfect equilibria are highly unstable. A person might slightly shift their weight or bump their shoulder, perturbing the system. Once the geometric perfection is broken, the forces become instantly unbalanced, and the arch collapses (or the agents step around each other).

To model this, we inject random noise into the system. Mathematically, the deterministic ODEs are upgraded to **Stochastic Differential Equations (SDEs)** (specifically, the Langevin equation):

$$ m_i d\vec{v}_i = \vec{F}_i(t) dt + \sigma d\vec{W}_t $$

Where $\vec{W}_t$ is a continuous Wiener process (Brownian motion), and $\sigma$ represents the amplitude of the behavioral fluctuations. 

When we discretize this SDE in time, we cannot simply multiply the noise by $\Delta t$. According to Itô calculus and the **Euler-Maruyama method** for integrating SDEs, the variance of a Wiener process scales linearly with time, which means the standard deviation (the actual noise term we add) must scale with the square root of time [6]:

$$ \vec{v}_i(t + \Delta t) = \vec{v}_i(t) + \frac{\vec{F}_i(t)}{m_i} \Delta t + \sigma \sqrt{\Delta t} \cdot \vec{\xi} $$

Where $\vec{\xi} \sim \mathcal{N}(0, I)$ is a standard normal random vector. By correctly scaling by $\sqrt{\Delta t}$, we ensure that the statistical variance of the agent's random walk remains physically consistent regardless of whether we run the simulation at 100 Hz or 1000 Hz.

### 2.4.1 The Parallel Reproducibility Problem

Implementing this noise securely in a heavily multi-threaded ECS environment (where thousands of agents are processed simultaneously across dozens of CPU cores) presents a massive challenge for scientific reproducibility. 

For a simulation platform to be valid, it must be **perfectly reproducible**: running the identical scenario twice must yield the identical result.

A naive approach in Julia might use `Threads.TaskLocalRNG()` to avoid data races. However, this fails the reproducibility test. In a parallel `Threads.@threads` loop, the operating system's thread scheduler decides how agents are batched. In Run 1, Thread A might process Agent 5 then Agent 6. In Run 2, Thread A might process Agent 6 then Agent 5. Because standard random number generators are sequential streams, Agent 5 will get a different random number in Run 2, and the simulations will diverge (the "Butterfly Effect").

The Antigravity platform solves this by abandoning sequential RNG streams entirely. Instead, it utilizes **per-agent seeded noise** using Julia's fast, built-in `Xoshiro` generator:

```julia
# A global atomic counter tracks the current simulation step
# This increments exactly once per timestep, outside the threaded loop
actual_step = atomic_add!(physics_call_counter, 1)

# Inside the multi-threaded physics loop (running in parallel):
# We create a unique, deterministic seed state for this specific agent
# at this specific timestep, using a hash of the Entity ID and Timestep.
seed = hash(entities[i]) ⊻ (UInt64(actual_step) ⊻ (UInt64(actual_step) << 32)) ⊻ 0xdeadbeef_cafecafe

# We instantiate a lightweight, local RNG that only this thread sees
rng  = Xoshiro(seed)

# Generate the noise
noise_x = randn(rng)
noise_y = randn(rng)
```

By hashing the unique entity ID with the global timestep counter, we mathematically guarantee that the noise applied to Agent $i$ at Timestep $t$ is exactly the same on every single run, regardless of the thread scheduling order. This provides thread-safe, lock-free, and perfectly reproducible stochasticity.

### 2.4.2 Implementation Caveat: Hash-Seeded Xoshiro vs. True CBRNGs
> [!NOTE]
> **Theory vs. Implementation**
> In mathematical theory, the optimal solution to parallel reproducible noise is a **Counter-Based Random Number Generator (CBRNG)**, such as the `Philox` or `Threefry` algorithms provided by the `Random123.jl` package [7]. A true CBRNG is a stateless, bijective function: $f(\text{seed}, \text{counter}) \rightarrow \text{random\_number}$.
> 
> **Current Implementation**: The SimCrowd engine currently uses a pseudo-CBRNG approach: it heavily hashes the `(EntityID, Timestep)` pair into a 64-bit integer, uses that to seed a brand new `Xoshiro` state, draws two random numbers, and throws the state away. 
> 
> **Which is better?**
> A true CBRNG (like `Philox`) is mathematically superior. Seeding a standard PRNG like `Xoshiro` millions of times per second (once per agent, per step) can expose poor initialization biases (the "Zero State" problem). However, `Xoshiro` is shipped in the Julia standard library (`Base.Random`), requiring zero external dependencies, and executes fast enough for our current target of 100,000 agents. 
> 
> **Future Improvement**: If the platform scales beyond 1,000,000 agents, or if statistical rigorousness dictates, migrating the implementation from the current `hash() ⊻ Xoshiro` pattern to `Random123.jl/Philox4x` would be a recommended upgrade.

### 2.4.3 Stochastic Calculus: Itô vs. Stratonovich and Noise Characteristics

When upgrading deterministic ODEs to Stochastic Differential Equations (SDEs), a fundamental choice must be made regarding the rules of stochastic calculus. The two primary frameworks are **Itô calculus** and **Stratonovich calculus**. The difference lies in how the stochastic integral is evaluated:
- **Itô Calculus** evaluates the noise at the *beginning* of the timestep (a non-anticipating process). It is mathematically convenient (preserving martingale properties) but breaks the standard chain rule of ordinary calculus [6].
- **Stratonovich Calculus** evaluates the noise at the *midpoint* of the timestep. It obeys the standard chain rule and is generally preferred when the noise represents a macroscopic approximation of microscopic continuous physical processes (via the Wong-Zakai theorem) [8].

To understand which calculus is appropriate for the SimCrowd engine, we must analyze the characteristics of the noise we are currently injecting. The engine employs **Additive White Noise**:
1. **Additive Noise**: The amplitude of the noise ($\sigma$) is a constant parameter. It does not depend on the current state (position or velocity) of the agent.
2. **White Noise**: The noise is completely uncorrelated in time; the random perturbation at timestep $t$ has no relation to the perturbation at $t + \Delta t$.

**Why Itô is mathematically sound for the current setup:**
Because the noise in our current implementation is additive (state-independent), the mathematical difference between Itô and Stratonovich vanishes. The "drift correction term" (often called spurious drift) that separates the two frameworks is proportional to the spatial derivative of the noise amplitude $\frac{\partial \sigma}{\partial x}$. Since $\sigma$ is constant, $\frac{\partial \sigma}{\partial x} = 0$. Therefore, both Itô and Stratonovich calculus yield the exact same physical trajectory for additive noise [6]. The use of the Itô-based Euler-Maruyama scheme is thus perfectly rigorous for the current SimCrowd architecture.

**Future Improvements from Scientific Literature: Multiplicative and Colored Noise**
While Additive White Noise successfully breaks geometric symmetry (arch-breaking), modern pedestrian dynamics literature suggests that it does not fully capture human behavioral variance.
- **Multiplicative Noise**: In reality, human movement variance is state-dependent. A pedestrian walking at 2.0 m/s exhibits a wider variance in lateral sway than a pedestrian standing still. If the engine were upgraded to use state-dependent noise ($\sigma(v)$), Itô and Stratonovich would diverge. In physical systems, Stratonovich is often the preferred choice for multiplicative noise because physical noise (like ground unevenness or wind) has a finite correlation time before taking the white noise limit [8].
- **Colored Noise**: True human decision-making is not temporally uncorrelated (White). If a pedestrian makes a minor behavioral error and veers left, human reaction time and inertia dictate that they will likely continue veering left for a few hundred milliseconds. **Colored Noise** (temporally correlated noise) is typically modeled using an Ornstein-Uhlenbeck process. Recent scientific literature has demonstrated that replacing White Noise with Colored Noise in Social Force Models is critical for accurately reproducing emergent phenomena like stop-and-go waves, phantom traffic jams, and realistic inertial reorientation during evacuations [9][10]. 

If the Antigravity platform requires deeper behavioral realism in the future, transitioning the noise generation from Additive White Noise to an Ornstein-Uhlenbeck Colored Noise process is the strongest mathematically-backed path forward.

---
## References
[1] Helbing, D., Farkas, I., & Vicsek, T. (2000). Simulating dynamical features of escape panic. *Nature*, 407(6803), 487-490.
[2] Chraibi, M., Seyfried, A., & Schadschneider, A. (2010). Generalized centrifugal-force model for pedestrian dynamics. *Physical Review E*, 82(4), 046111.
[3] Hairer, E., Lubich, C., & Wanner, G. (2006). *Geometric Numerical Integration: Structure-Preserving Algorithms for Ordinary Differential Equations*. Springer.
[4] Allen, M. P., & Tildesley, D. J. (2017). *Computer Simulation of Liquids*. Oxford University Press.
[5] Blackman, D., & Vigna, S. (2021). Scrambled Linear Pseudorandom Number Generators. *ACM Transactions on Mathematical Software*, 47(4), 1-32.
[6] Higham, D. J. (2001). An Algorithmic Introduction to Numerical Simulation of Stochastic Differential Equations. *SIAM Review*, 43(3), 525-546.
[7] Salmon, J. K., Moraes, M. A., Dror, R. O., & Shaw, D. E. (2011). Parallel random numbers: as easy as 1, 2, 3. *Proceedings of the International Conference for High Performance Computing, Networking, Storage and Analysis*.
[8] Kloeden, P. E., & Platen, E. (1992). *Numerical Solution of Stochastic Differential Equations*. Springer.
[9] Martinez-Gil, F., Lozano, M., & Fernández, F. (2017). Emergent behaviors and scalability for colored noise driven pedestrian dynamics. *Physica A: Statistical Mechanics and its Applications*, 468, 244-259.
[10] Frank, T. D. (2005). *Nonlinear Fokker-Planck Equations: Fundamentals and Applications*. Springer.
