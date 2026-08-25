# Chapter 8: Fluid-Analogue Macroscopic Models

Chapters 6 and 7 detailed **microscopic** models, where every single pedestrian is simulated as an independent agent with personal mass, velocity, and psychological intentions. However, when simulating millions of agents (e.g., a city-wide evacuation), computing microscopic interactions becomes computationally infeasible, even with GPU acceleration.

To solve this, Antigravity implements **Macroscopic Models**. At extreme scales, the individual intentions of humans become statistically irrelevant, and the crowd behaves mathematically like a continuous, compressible fluid.

## 8.1 The Lighthill-Whitham-Richards (LWR) Model

The most famous macroscopic model is the **LWR Model**, originally developed in the 1950s for vehicular traffic but perfectly adaptable to pedestrian dynamics [1]. 

The model relies on the fundamental continuum equation of fluid dynamics: the **Conservation of Mass**. It states that the change in density ($\rho$) over time must equal the spatial gradient of the flow (the flux). If no passengers are magically created or destroyed inside a hallway, the flow in must equal the flow out.

This is governed by the 1D Continuity Equation PDE:
$$ \frac{\partial \rho}{\partial t} + \frac{\partial q}{\partial x} = 0 $$

Where:
- $\rho(x,t)$ is the pedestrian density (ped/m$^2$).
- $q(x,t)$ is the macroscopic flow or throughput (ped/m/s).

Because flow $q$ is strictly defined as density multiplied by velocity ($q = \rho \cdot v$), we can rewrite the equation as:
$$ \frac{\partial \rho}{\partial t} + \frac{\partial (\rho \cdot v(\rho))}{\partial x} = 0 $$

## 8.2 The Fundamental Diagram

To solve the LWR equation, we must define $v(\rho)$, which is the velocity of the crowd as a function of its density. This empirical relationship is known as the **Fundamental Diagram**.

As density increases, velocity drops. Antigravity defaults to the widely validated **Weidmann Model** (1993) [2], which uses an exponential decay function:
$$ v(\rho) = v_{max} \cdot \left( 1 - \exp\left[-\gamma \cdot \left(\frac{1}{\rho} - \frac{1}{\rho_{max}}\right)\right] \right) $$

Where:
- $v_{max} \approx 1.34$ m/s (free-flow walking speed).
- $\rho_{max} \approx 5.4$ ped/m$^2$ (crush density where flow completely stops).
- $\gamma \approx 1.913$ (shape parameter).

When we plot $q = \rho \cdot v(\rho)$, we see a parabolic curve. Flow increases as more people enter a hallway, reaches a maximum capacity ($q_{max}$), and then rapidly collapses to zero as the density approaches the crush limit $\rho_{max}$.

## 8.3 Shockwaves and Stop-and-Go Waves

The profound power of treating crowds as a compressible fluid via the LWR model is its ability to mathematically predict and simulate **Shockwaves**.

In highly congested corridors, a minor disruption (a person tripping for 2 seconds) causes the people behind them to slow down, creating a local spike in density $\rho$. Because $v(\rho)$ drops non-linearly, this dense cluster propagates backward through the crowd. This is known as a "Stop-and-Go Wave" or a "Phantom Jam."

Mathematically, this is identical to a compressible fluid shockwave. The speed at which this backward shockwave propagates ($c$) is defined by the derivative of the Fundamental Diagram:
$$ c = \frac{dq}{d\rho} $$

Because the Antigravity engine solves the LWR PDE numerically using finite-volume Godunov schemes, it naturally reproduces these backward-propagating shockwaves across city-wide evacuation grids without needing to simulate a single individual agent.

---
## References
[1] Lighthill, M. J., & Whitham, G. B. (1955). On kinematic waves. II. A theory of traffic flow on long crowded roads. *Proceedings of the Royal Society of London. Series A*, 229(1178), 317-345.
[2] Weidmann, U. (1993). Transporttechnik der Fussgänger (Transport Technology of Pedestrians). *Schriftenreihe des IVT, ETH Zürich*, 90.
