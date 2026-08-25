# Chapter 5: Queueing Theory & Statistical Models

While Chapter 3 detailed the low-level architecture of the Discrete Event Simulation (SimDES) engine, this chapter focuses on the mathematical models built atop that architecture. To accurately simulate real-world infrastructure, the platform relies on classical **Queueing Theory** and **Stochastic Processes** [1].

In SimDES, a "Queueing System" is defined by three interacting components:
1. **The Arrival Process**: The stochastic generation of incoming agents.
2. **The Service Process**: The stochastic delay experienced by an agent at a facility.
3. **The Queue Discipline**: The logical sorting of agents waiting for service.

> [!NOTE]
> **Running Example: The Subway Station Checkpoint**
> To ground the mathematics in reality, this chapter will use a single unifying example: A security checkpoint at a major subway station. Throughout the chapter, we will model passengers arriving at the station, waiting in line, passing through a metal detector, and dealing with equipment breakdowns.

---

## 5.1 The Arrival Process (Generators)

In macroscopic fluid models, flow is defined continuously as mass passing through a boundary over time. In SimDES, flow is strictly discrete. The engine must spawn individual passengers at specific, timestamped moments. We cannot simply spawn a passenger exactly every 2.0 seconds, because human arrival is inherently random. 

### 5.1.1 The Homogeneous Poisson Process (Off-Peak Hours)
**When to use it:** When modeling arrivals during a stable, off-peak period where the average arrival rate remains constant, and passengers arrive independently of one another.

**Why it works:** If arrivals are independent, the process is "memoryless" (the fact that a passenger just arrived does not increase or decrease the probability of another passenger arriving right behind them). The number of arrivals $N$ in a time interval $T$ follows a **Poisson distribution**:
$$ P(N(T) = k) = \frac{e^{-\lambda T} (\lambda T)^k}{k!} $$
Where $\lambda$ is the average arrival rate (e.g., 5 passengers per minute).

**How it is simulated:** To generate discrete passengers in SimDES, we do not sample the number of arrivals $k$; instead, we sample the **inter-arrival time** ($\Delta t$) between consecutive passengers. The mathematical consequence of a memoryless Poisson process is that the inter-arrival times strictly follow an **Exponential Distribution**:
$$ f(\Delta t) = \lambda e^{-\lambda \Delta t} $$

To generate these timestamps efficiently, the engine uses **Inverse Transform Sampling**. We calculate the Cumulative Distribution Function (CDF), $F(\Delta t) = 1 - e^{-\lambda \Delta t}$, set it equal to a uniform random variable $U \sim \text{Uniform}(0, 1)$, and solve for $\Delta t$:
$$ U = 1 - e^{-\lambda \Delta t} \implies \Delta t = -\frac{\ln(1 - U)}{\lambda} $$
*(Note: Because $U$ and $1-U$ have the same uniform distribution, this is usually simplified in code to $\Delta t = -\ln(U) / \lambda$).*

### 5.1.2 Non-Homogeneous Poisson Process (Rush Hour)
**When to use it:** When the average arrival rate changes dynamically over time (e.g., a massive surge of passengers arriving right as the station opens for rush hour).

**Why it works:** The constant $\lambda$ is replaced with a time-dependent rate function $\lambda(t)$. The exponential distribution math breaks down because the rate is no longer constant between $\Delta t$.

**How it is simulated:** The engine uses a stochastic technique called **Thinning** (or Acceptance-Rejection). 
1. The engine bounds the maximum arrival rate over the entire simulation to find $\lambda_{max}$.
2. It generates potential "dummy" arrivals using the standard Inverse Transform Sampling equation above, relying on $\lambda_{max}$.
3. For each dummy arrival at time $t_i$, it generates a random number $U \sim \text{Uniform}(0, 1)$. 
4. The passenger is "accepted" and actually spawned only if $U \le \frac{\lambda(t_i)}{\lambda_{max}}$. Otherwise, the arrival is rejected.

---

## 5.2 The Service Process and Failure Models

Once the passenger reaches the front of the line, they step into the security metal detector. How long does the scan take?

### 5.2.1 Service Distributions
**When to use them:** To model the time duration a server is occupied by a single agent.

**Why the Exponential Distribution Fails Here:** While inter-arrival times are exponential (meaning a time of $0.001$ seconds is highly probable), service times are bounded by physical reality. A person physically cannot walk through a metal detector in $0.001$ seconds. Therefore, service times rarely use the Exponential distribution.

**How we model it:**
1. **Deterministic (Constant)**: $\Delta t = C$. Used for highly automated, unvarying processes. If the turnstile gates take exactly 1.2 seconds to open and close, we use a constant.
2. **Normal (Gaussian) Distribution**: $\Delta t \sim \mathcal{N}(\mu, \sigma^2)$. Used for human-driven processes that cluster around a mean (e.g., a security guard checking a bag takes 15 seconds on average, with a standard deviation of 3 seconds). 
3. **Log-Normal Distribution**: Because a standard Normal distribution extends to negative infinity, a wide variance might mathematically generate a negative service time. The Log-Normal distribution restricts all values to the positive domain, making it the safest and most accurate statistical model for human service times.

### 5.2.2 Stochastic Failure Models
Infrastructure inevitably breaks down, blocking the queue. SimDES models this using two distinct probabilistic approaches.

**1. Bernoulli Failure (The "Read Error")**
- **When/Why:** Used for per-transaction failures. Every time a passenger scans their ticket, there is an independent probability $p$ that the barcode reader fails to scan. 
- **How:** At the start of the service event, a random number $U$ is drawn. If $U < p$, the standard `ServiceComplete` event is replaced with a `RecoveryDelay` event (representing the passenger fumbling and trying again).

**2. Weibull Failure (The "Mechanical Breakdown")**
- **When/Why:** Used to model the long-term mechanical degradation of the turnstile motor. An old motor is more likely to break down than a brand new one.
- **How:** The engine models the time between mechanical failures using a **Weibull Distribution**. The Weibull hazard function (failure rate) is defined as:
  $$ h(t) = \frac{k}{\lambda} \left(\frac{t}{\lambda}\right)^{k-1} $$
  Where $k$ is the shape parameter. This is mathematically powerful because it models three distinct realities of engineering:
  - If $k < 1$, the failure rate *decreases* over time (Infant mortality / defective parts failing immediately).
  - If $k = 1$, the failure rate is constant (Reduces to the Exponential distribution / random unpredictable failures).
  - If $k > 1$, the failure rate *increases* over time (Wear-and-tear degradation).

---

## 5.3 Queue Disciplines

If passengers are arriving at the security checkpoint faster than the metal detectors can scan them ($\lambda > \mu$), a physical queue forms. The **Queue Discipline** dictates how the engine pulls passengers from this waiting list.

1. **FIFO (First-In, First-Out)**: The standard queue. Computationally implemented as a standard contiguous Array acting as a double-ended queue, where passengers are pushed to the back and popped from the front.
2. **Priority HOL (Head-of-Line)**: Used for the "VIP/First-Class" security lane. Passengers possess an integer `PriorityLevel` component. The queue is mathematically implemented as a **Max-Heap**, prioritizing passengers with higher priority integers. *Non-Preemptive* Priority HOL means a VIP passenger skips the line, but will not physically interrupt a normal passenger who is already mid-scan inside the metal detector.

---

## 5.4 Theoretical Validation: Little's Law

To ensure that the SimDES engine is mathematically sound and free of "leaking" agents (bugs where passengers are accidentally deleted from memory or stuck infinitely in a broken queue), the platform's macroscopic output is constantly validated against **Little's Law** [2].

Little's Law is a fundamental, overarching theorem of queueing theory. It states that the long-term average number of passengers in the stationary subway station ($L$) is strictly equal to the long-term average effective arrival rate ($\lambda$) multiplied by the average time a passenger spends in the station ($W$).

$$ L = \lambda W $$

**Why this matters:** This law is mathematically proven to hold regardless of the arrival distribution (Poisson or NHPP), regardless of the service distribution (Normal or Log-Normal), and regardless of the queue discipline (FIFO or Priority) [2]. 

**How it is used:** During continuous integration unit testing, the Antigravity platform runs massive Monte Carlo simulations. The engine independently tracks the empirical $L_{sim}$, $\lambda_{sim}$, and $W_{sim}$. If, at the end of the simulation, $L_{sim}$ diverges from $\lambda_{sim} \times W_{sim}$ by more than a tiny floating-point tolerance, it constitutes mathematical proof that a logical routing bug exists in the engine's source code.

---
## References
[1] Gross, D., Shortle, J. F., Thompson, J. M., & Harris, C. M. (2008). *Fundamentals of Queueing Theory* (4th ed.). Wiley.
[2] Little, J. D. C. (1961). A Proof for the Queuing Formula: L = λW. *Operations Research*, 9(3), 383–387.
