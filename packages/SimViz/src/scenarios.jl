"""
    scenarios.jl — Three built-in demo scenarios for SimViz (Phase 4B)

Exports three `ScenarioConfig` constructors and matching `run_*_demo!`
entry points:

| Scenario              | Key feature demonstrated                          |
|:----------------------|:-------------------------------------------------- |
| `evacuation_scenario` | Hybrid-FSM ORCA↔SFM switching at a bottleneck     |
| `mm1_scenario`        | DES M/M/1 queue visualized as a corridor of dots  |
| `integration_scenario`| DES event (alarm at t=60s) triggers crowd panic   |

# Usage

```julia
using SimViz
run_evacuation_demo!()                       # default 80 agents
run_evacuation_demo!(n_agents=200, door_width=0.8)
run_mm1_demo!(lambda=0.8, mu=1.0)
run_integration_demo!(n_agents=100)
```

Each `run_*_demo!` calls `run_visualization!(config)`, which opens a GLMakie
window. See `window.jl` for the full rendering pipeline.

# Design notes

- All scenario constructors return a plain `ScenarioConfig` — the canonical
  Phase 7 user-facing surface. No GLMakie types here.
- DES parameters (`lambda`, `mu`, `evac_alarm_time`) are stored in
  `ScheduledEvent` entries inside `ScenarioConfig.events`. The event handler
  in `scenario_config.jl` fires them during `build_world!`.
- `ScheduledEvent` currently has `time::Float64`, `type::Symbol`, and
  `params::NamedTuple`. We add demo-specific DES events here.
"""

# ── 4B-01: Evacuation Scenario ────────────────────────────────────────────────

"""
    evacuation_scenario(; n_agents=80, door_width=1.0, crowd_model=MODEL_HYBRID_FSM,
                          flux_boundary=true, rng_seed=0, kwargs...) :: ScenarioConfig

Classic bottleneck evacuation: `n_agents` agents in a 10×4m room rush a
single exit (east wall, center, `door_width` m wide).

# Key parameters
- `n_agents`: number of crowd agents (default 80; T7 benchmark uses 80)
- `door_width`: exit width in metres (default 1.0m; T7 target: 1.22 ped/s)
- `crowd_model`: `MODEL_HYBRID_FSM` (default) — agents switch ORCA↔SFM
  near the congested exit, visually observable as blue↔red color change
- `flux_boundary`: when `true`, agents that exit are removed (open boundary)

# Visual
- Default overlay: `OVERLAY_FSM` (ORCA=blue, SFM=red)
- Near the exit, density rises above `rho_on` → agents switch to SFM (red)
- T7 benchmark flow rate target: ≥1.22 ped/s through a 1m door

# References
- Helbing et al. 2000 (panic model)
- T7 evacuation benchmark (SimCrowd benchmark suite)
"""
function evacuation_scenario(;
        n_agents    :: Int       = 80,
        door_width  :: Float64  = 1.0,
        crowd_model :: CrowdModel = MODEL_HYBRID_FSM,
        flux_boundary :: Bool   = true,
        rng_seed    :: Int      = 0,
        kwargs...,
    ) :: ScenarioConfig

    room = RoomGeometry(
        width  = 10.0,
        height = 4.0,
        doors  = [DoorSpec(wall=:east, center=2.0, width=door_width)],
    )

    return ScenarioConfig(;
        room          = room,
        n_agents      = n_agents,
        crowd_model   = crowd_model,
        # Panic-speed params: v_pref slightly elevated vs default
        v_pref        = 1.5,         # m/s; elevated urgency
        tau_relax     = 0.4,         # s; faster response
        # SFM contact friction (important in dense doorway)
        sfm_A         = 2000.0,
        sfm_B         = 0.08,
        sfm_lambda    = 0.75,
        sfm_mu        = 0.5,
        # HybridFSM thresholds
        rho_on        = 3.5,
        rho_off       = 2.5,
        # Solver
        dt            = 0.05,
        dt_sfm        = 0.01,
        correction_iters = 8,
        flux_boundary = flux_boundary,
        rng_seed      = rng_seed,
        label         = "Evacuation Demo",
        description   = "$(n_agents) agents evacuating through a $(door_width)m door (T7 benchmark)",
        kwargs...,
    )
end

"""
    run_evacuation_demo!(; kwargs...) -> nothing

Open a GLMakie window showing the evacuation scenario.

All keyword arguments are forwarded to `evacuation_scenario(; kwargs...)`.

# What to observe
- Start paused; press ▶ Run
- Near the exit, agents turn red (SFM mode) as density exceeds `rho_on`
- Flow rate (ped/s) appears in the stats panel as `Arrivals / sim_time`
- T7 target: ≥1.22 ped/s through a 1m door with 80 agents
"""
function run_evacuation_demo!(; kwargs...)
    config = evacuation_scenario(; kwargs...)
    run_visualization!(config)
end

# ── 4B-02: M/M/1 Queue Scenario ──────────────────────────────────────────────

"""
    mm1_scenario(; lambda=0.9, mu=1.0, rng_seed=0) :: ScenarioConfig

A pure-DES M/M/1 queue visualized as colored dots in a narrow corridor.

# How it works
- No crowd (ABM) agents — `n_agents=0`
- A `ScheduledEvent(:start_mm1_queue, t=0, params=(lambda, mu))` is stored
  in `config.events`. The `build_world!` event handler fires it at t=0,
  starting a Poisson arrival process with rate `lambda` and exponential
  service with rate `mu`.
- Each DES customer is represented as a colored dot in the corridor:
  - **Green**: in queue (waiting)
  - **Blue**: in service
  - **Gray**: departed (briefly visible before removal)
- Queue length `Lq` is shown in the stats panel alongside the theoretical
  `L = λ/(μ-λ)` reference value.

# Parameters
- `lambda`: arrival rate (ped/s); must satisfy `lambda < mu` for stability
- `mu`: service rate (ped/s)
- At `lambda=0.9, mu=1.0`: ρ=0.9, theoretical L≈9.0

# Stability warning
If `lambda >= mu`, the queue is unstable (grows without bound).
"""
function mm1_scenario(;
        lambda   :: Float64 = 0.9,
        mu       :: Float64 = 1.0,
        rng_seed :: Int     = 0,
        kwargs...,
    ) :: ScenarioConfig

    lambda >= mu && @warn "M/M/1 queue is UNSTABLE (λ=$lambda ≥ μ=$mu). Queue will grow unboundedly."

    room = RoomGeometry(
        width  = 15.0,
        height = 2.0,
        doors  = [DoorSpec(wall=:east, center=1.0, width=2.0)],
    )

    mm1_event = ScheduledEvent(
        time   = 0.0,
        type   = :start_mm1_queue,
        params = (lambda=lambda, mu=mu),
    )

    return ScenarioConfig(;
        room        = room,
        n_agents    = 0,           # pure DES — no ABM crowd agents
        crowd_model = MODEL_SFM,   # irrelevant (0 agents) but required
        events      = [mm1_event],
        dt          = 0.05,
        rng_seed    = rng_seed,
        label       = "M/M/1 Queue Demo",
        description = "DES M/M/1 queue: λ=$lambda ped/s, μ=$mu ped/s, ρ=$(round(lambda/mu, digits=2))",
        kwargs...,
    )
end

"""
    run_mm1_demo!(; kwargs...) -> nothing

Open a GLMakie window showing the M/M/1 queue visualization.

# What to observe
- Colored dots appear in the corridor at rate `lambda`
- One dot at a time enters service (rightmost position, blue)
- Queue depth fluctuates; after warm-up it converges to L ≈ λ/(μ-λ)
- Stats panel shows: `Arrivals`, `Departures`, `ρ server = busy_time/t`
"""
function run_mm1_demo!(; kwargs...)
    config = mm1_scenario(; kwargs...)
    run_visualization!(config)
end

# ── 4B-03: DES + Crowd Integration Scenario ──────────────────────────────────

"""
    integration_scenario(; n_agents=100, evac_alarm_time=60.0, rng_seed=0) :: ScenarioConfig

A crowd-DES integration demo: agents walk freely in ORCA mode until a DES
`evac_alarm` event fires at `evac_alarm_time` seconds, triggering a panic
response in all agents simultaneously.

# How it works
- 100 ORCA agents wander in a 20×10m lobby with 2 exits (east + west walls)
- At `t = evac_alarm_time`, the `evac_alarm` DES event fires:
  - `v_pref` is boosted to 1.8 m/s (panic speed)
  - All agents' goals are redirected to the nearest exit
  - `panic_level` is raised to 0.8 (affects color in `OVERLAY_PANIC` mode)
  - Stats panel shows a 🚨 ALARM indicator
- Default overlay: `OVERLAY_PANIC` — agents shift from green → orange/red

# Parameters
- `n_agents`: number of crowd agents (default 100)
- `evac_alarm_time`: DES event trigger time in seconds (default 60.0s)

# What to observe
- Before t=60s: agents in green (calm, ORCA)
- At t=60s: 🚨 ALARM fires, agents turn orange/red, rush to exits
- This is the **Phase 4 DES+Crowd integration milestone**
"""
function integration_scenario(;
        n_agents         :: Int    = 100,
        evac_alarm_time  :: Float64 = 60.0,
        rng_seed         :: Int    = 0,
        kwargs...,
    ) :: ScenarioConfig

    # Lobby with 2 exits: east + west
    room = RoomGeometry(
        width  = 20.0,
        height = 10.0,
        doors  = [
            DoorSpec(wall=:east,  center=5.0, width=2.0),
            DoorSpec(wall=:west,  center=5.0, width=2.0),
        ],
    )

    alarm_event = ScheduledEvent(
        time   = evac_alarm_time,
        type   = :evac_alarm,
        params = (v_panic=1.8, panic_level=0.8),
    )

    return ScenarioConfig(;
        room        = room,
        n_agents    = n_agents,
        crowd_model = MODEL_ORCA,   # ORCA for normal walking; panic response is DES-triggered
        v_pref      = 1.34,         # normal walking speed pre-alarm
        orca_tau    = 2.0,
        orca_max_neighbors = 15,
        events      = [alarm_event],
        dt          = 0.05,
        rng_seed    = rng_seed,
        label       = "DES + Crowd Integration Demo",
        description = "$(n_agents) ORCA agents; 🚨 evac alarm fires at t=$(evac_alarm_time)s",
        kwargs...,
    )
end

"""
    run_integration_demo!(; kwargs...) -> nothing

Open a GLMakie window showing the DES + crowd integration scenario.

# What to observe
- Before the alarm: agents in green (OVERLAY_PANIC mode, calm)
- At `evac_alarm_time` seconds: 🚨 indicator in stats panel
- Agents turn orange/red and rush to exits
- This is the **Phase 4 integration milestone**
"""
function run_integration_demo!(; kwargs...)
    config = integration_scenario(; kwargs...)
    run_visualization!(config)
end
