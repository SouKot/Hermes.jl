# Chapter 11: Validation Test Cases

Part V concludes the Theory Manual by addressing the most critical requirement of any simulation engine used for life-safety engineering: **Validation**. 

It is not enough for a crowd simulation to look visually realistic. If the platform is used to design stadium exits or certify the evacuation time of a skyscraper, it must mathematically guarantee that its macroscopic outputs (throughput, density bottlenecks, and evacuation times) perfectly match empirical reality.

## 11.1 The RiMEA Benchmark Suite

To ensure absolute scientific validity, the Antigravity platform's SimCrowd module is rigorously tested against the **RiMEA** (Richtlinie für Mikroskopische Entfluchtungsanalysen) guidelines [1]. RiMEA is the industry-standard German directive that defines a strict set of 15 fundamental test cases that any microscopic evacuation model must pass to be considered valid for engineering use.

### 11.1.1 Core Test Cases

**Test 1: Forward Free-Flow Speed**
- *Setup*: A single agent walks down a 40m corridor.
- *Validation*: The agent must achieve and maintain their assigned theoretical desired speed ($v_0$) exactly, without numerical damping from the Symplectic Euler integrator.

**Test 4: Fundamental Diagram Bottleneck**
- *Setup*: A massive crowd of 1,000 agents is forced through a narrow 1.0m bottleneck door.
- *Validation*: The macroscopic throughput (agents passing through the door per second) must match empirical capacity limits (e.g., $\approx 1.8$ ped/s). If the SFM friction coefficients are too high, physical arching will cause artificial deadlocks, failing the test.

**Test 11: Staircase Speed Reduction**
- *Setup*: Agents walk along a flat corridor, transition to a downward staircase, and then return to a flat corridor.
- *Validation*: The engine must dynamically alter the agents' $v_{max}$ component according to the slope. Velocity must empirically drop by $\approx 50\%$ on the stairs (depending on the tread/riser ratio) and immediately recover upon reaching the landing.

**Test 15: Obstacle Evasion and Cornering**
- *Setup*: A crowd navigates a hallway featuring a 90-degree corner and a series of pillar obstacles.
- *Validation*: Agents must smoothly follow the Eikonal potential field gradient around the corners without penetrating the rigid body colliders (testing the exactitude of the spatial hashing grid and the SFM elastic boundary forces).

## 11.2 Fluid Validation

For the SimFluid module, validation relies on classical CFD benchmarks:
- **The Dam Break Problem**: A column of water collapses under gravity. The advancing wavefront speed and height over time are compared against exact analytical shallow water solutions and experimental tank data.
- **Poiseuille Flow**: Fluid is pushed through a pipe. The resulting velocity profile must form a perfect mathematical parabola, validating the LBM collision operator's viscosity parameter.

## 11.3 Automated CI/CD Regression Testing

A major vulnerability in simulation development is that modifying a microscopic force equation (e.g., tweaking the GCFM elliptical shoulder width) might accidentally break macroscopic flow rates elsewhere.

To prevent this, the Antigravity platform integrates the RiMEA test suite directly into its Continuous Integration (CI/CD) pipeline. Every time a developer commits code to the repository, the engine boots up and autonomously runs all 15 Monte Carlo simulations head-less. 
It aggregates the throughput and density data, compares it against the strict RiMEA empirical bounds, and mathematically proves the validity of the build. If an equation tweak causes a bottleneck to jam unnaturally, the test suite fails the build, ensuring the platform remains perpetually scientifically sound.

---
## References
[1] RiMEA (2016). *Richtlinie für Mikroskopische Entfluchtungsanalysen* (Guideline for Microscopic Evacuation Analysis). RiMEA e.V.
