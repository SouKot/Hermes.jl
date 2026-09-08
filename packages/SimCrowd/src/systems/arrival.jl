# ── Boundary Condition System ──────────────────────────────────────────────────
# Sprint 3Z: Domain-edge boundary conditions for pedestrian simulation.
#
# ## Architecture
#
# `BoundaryCondition{F}` is a purely abstract interface with a single required method:
#
#     apply_boundary!(world::World, bc::MyBC{F}, dt::F) → Int
#
# The interior physics (SFM/ORCA/CSM) is completely decoupled from what happens
# at the domain edge. Adding a new BC requires only:
#   1. Define `struct MyBC{F} <: BoundaryCondition{F}` with whatever fields you need.
#   2. Implement `apply_boundary!(world, bc::MyBC{F}, dt::F)`.
#   3. Export from SimCrowd.jl.
#
# No changes to SimScene, step!, or any physics system are ever needed.
#
# ## Fluid-mechanics analogy
#
#   AbsorbingBoundary    ≈ far-field / open outflow (non-reflecting, no back-pressure)
#   PeriodicBoundary     ≈ periodic BC (steady-state calibration, no population change)
#   ConstantFluxBoundary ≈ prescribed-flux inlet + absorbing outlet (Weidmann T7)
#   OpenBoundary         ≈ no BC (domain large enough — pure no-op)
#
# ## GPU note
#
# `apply_boundary!` is a host-side CPU operation. For GPU worlds, synchronise device
# positions to host (KernelAbstractions.synchronize + copyto!) before calling.
# GPU-side arrival detection (flag array → CPU removal pass) is a future extension.
#
# ## Canonical simulation loop (BC-agnostic)
#
#     bc = AbsorbingBoundary(1.5f0)    # or PeriodicBoundary, ConstantFluxBoundary, …
#     n_exited = 0
#     while n_exited < N && t <= t_max
#         step!(scene)
#         n_exited += apply_boundary!(world, bc, dt)
#         t += dt
#     end
#
# The loop body is IDENTICAL regardless of which BoundaryCondition is active.


# ── Abstract interface ────────────────────────────────────────────────────────

"""
    BoundaryCondition{F<:AbstractFloat}

Abstract supertype for all pedestrian domain boundary conditions.

## Required interface

Every concrete subtype must implement:

```julia
apply_boundary!(world::World, bc::MyBC{F}, dt::F) → Int
```

Return value semantics (net agents affected this call):
- **Positive**: agents removed (absorbing sink)
- **Negative**: agents added (source, e.g. `ConstantFluxBoundary`)
- **Zero**: count-preserving operation (wrapping, no-op)

## Design contract

- Called **once per simulation step**, after `step!(scene)`.
- **Must not** be called during an active `Query` iteration over the same archetype.
- **CPU-only** by default. For GPU worlds, sync device→host before calling.
- Interior physics (SFM/ORCA/CSM, SimScene, step!) are **not modified** when
  changing boundary conditions. The BC is a pure post-step hook.

## Extension pattern

```julia
# 1. Define your BC struct (carry whatever state it needs):
struct MyCustomBC{F} <: BoundaryCondition{F}
    threshold::F
    # … any fields needed by your logic
end

# 2. Implement apply_boundary!:
function apply_boundary!(world::World, bc::MyCustomBC{F}, dt::F) where {F<:AbstractFloat}
    # … your logic here …
    return n_affected
end

# 3. Export from SimCrowd.jl — done.
```
"""
abstract type BoundaryCondition{F<:AbstractFloat} end


# ── AbsorbingBoundary ─────────────────────────────────────────────────────────

"""
    AbsorbingBoundary{F}(arrival_radius)

Open-outflow boundary condition. Agents whose position is within `arrival_radius`
of their `Goal{F}` component are permanently removed from the simulation.

Analogous to a **far-field / non-reflecting outflow** BC in CFD: once an agent
exits, zero back-pressure propagates back from it into the room.

# Fields
- `arrival_radius::F`: Removal threshold (metres). Agent removed when
  `norm(pos - goal) ≤ arrival_radius`.

# Typical values
- Evacuation (room → open street): 1.0–2.0 m past the exit plane.
- Transit hub (platform → train): 0.5 m (tight gate).
- Wide plaza (indoors → outdoors): 3.0–5.0 m.

# Example
```julia
bc = AbsorbingBoundary(1.5f0)   # remove within 1.5 m of goal
n_exited += apply_boundary!(world, bc, dt)
```
"""
struct AbsorbingBoundary{F<:AbstractFloat} <: BoundaryCondition{F}
    arrival_radius::F
end

"""
    apply_boundary!(world, bc::AbsorbingBoundary{F}, dt::F) → n_removed::Int

Remove all agents within `bc.arrival_radius` of their `Goal{F}` component.

## Implementation: two-pass deferred deletion

Safe for Ark.jl's archetype swap-remove mechanism:

- **Pass 1 (read)**: iterate via `Query(world, (Position{F}, Goal{F}))` and
  collect `Entity` handles where `‖pos − goal‖² ≤ arrival_radius²`.
  Column indices are **not** invalidated in this pass.

- **Pass 2 (write)**: call `remove_entity!(world, entity)` on each collected
  handle **after** the Query iteration has closed. Swap-remove is safe here.

## Complexity

- Time: O(N) per step; O(k) non-zero work (k = arrivals this step, typically 0–3).
- Space: O(k) per step for the `to_remove` vector.

## GPU note

CPU-only. For GPU worlds, synchronise device→host before calling.
"""
function apply_boundary!(world::World, bc::AbsorbingBoundary{F}, ::F) where {F<:AbstractFloat}
    r_sq      = bc.arrival_radius * bc.arrival_radius
    to_remove = Entity[]

    # Pass 1: collect Entity handles (read-only — no mutation during iteration)
    for (entities, pos_col, goal_col) in Query(world, (Position{F}, Goal{F}))
        for i in eachindex(pos_col)
            dp = pos_col[i].p - goal_col[i].g
            dp[1]^2 + dp[2]^2 ≤ r_sq && push!(to_remove, entities[i])
        end
    end

    # Pass 2: deferred removal (Query iteration already closed — swap-remove is safe)
    # Qualify as Ark.remove_entity! — both Ark and SimCore export this name.
    for entity in to_remove
        Ark.remove_entity!(world, entity)
    end

    return length(to_remove)
end

# Backward-compat: 2-arg form (dt not needed for absorbing sink; accepted but ignored).
apply_boundary!(world::World, bc::AbsorbingBoundary{F}) where {F<:AbstractFloat} =
    apply_boundary!(world, bc, zero(F))


# ── PeriodicBoundary ──────────────────────────────────────────────────────────

"""
    PeriodicBoundary{F}(x_min, x_max, y_min, y_max)

Periodic boundary condition. Agents exiting one domain edge re-enter from the
opposite edge. Agent count is conserved; returns 0.

Analogous to a **periodic BC** in CFD. Useful for steady-state throughput
calibration (CRW-M-02 fundamental diagram) and corridor studies without
finite-population effects.

# Fields
- `x_min`, `x_max`: Domain x extents (metres).
- `y_min`, `y_max`: Domain y extents (metres).

# Example
```julia
bc = PeriodicBoundary(0f0, 20f0, 0f0, 3f0)   # 20m × 3m corridor
while t < T
    step!(scene)
    apply_boundary!(world, bc)   # wrap agents at domain edges
    t += dt
end
```
"""
struct PeriodicBoundary{F<:AbstractFloat} <: BoundaryCondition{F}
    x_min::F
    x_max::F
    y_min::F
    y_max::F
end

"""
    apply_boundary!(world, bc::PeriodicBoundary{F}) → 0
    apply_boundary!(world, bc::PeriodicBoundary{F}, dt) → 0

Wrap agent positions at domain boundaries using modular arithmetic.
Agent count is conserved; returns 0.

Single-pass read-write over `Position{F}` components.
No entity creation or deletion — safe to call inside any archetype iteration.
"""
function apply_boundary!(world::World, bc::PeriodicBoundary{F}, ::F=zero(F)) where {F<:AbstractFloat}
    x_span = bc.x_max - bc.x_min
    y_span = bc.y_max - bc.y_min

    for (_, pos_col) in Query(world, (Position{F},))
        for i in eachindex(pos_col)
            p  = pos_col[i].p
            px = bc.x_min + mod(p[1] - bc.x_min, x_span)
            py = bc.y_min + mod(p[2] - bc.y_min, y_span)
            pos_col[i] = Position(SVector(px, py))
        end
    end

    return 0
end


# ── ConstantFluxBoundary ──────────────────────────────────────────────────────

"""
    ConstantFluxBoundary{F, Fn}(arrival_radius, spawn_rate, spawn_pos, agent_factory)

Constant-flux boundary condition: a combined **source + sink**.

- **Sink**: agents within `arrival_radius` of their `Goal{F}` are removed
  (identical to `AbsorbingBoundary`).
- **Source**: new agents are spawned at `spawn_pos` at `spawn_rate` ped/s,
  maintaining a continuous pedestrian supply for steady-state flow measurement.

This is the correct BC for **Weidmann T7 bottleneck flow validation** (see
`2026-09-08_t7_acceptance_criteria.md`): it eliminates finite-population
transients so the measured flow rate reflects steady-state throughput.

## Spawn accumulator

Spawning is fractional-then-threshold: each call accumulates `spawn_rate × dt`
into an internal `_deficit` counter. When deficit ≥ 1.0, one agent is spawned
via `agent_factory(world)` and deficit is decremented by 1.0.  This produces
exactly the correct average rate without rounding drift.

## dt-dependent interface — IMPORTANT

Always call the **3-argument form** to pass the actual dt this step:

```julia
apply_boundary!(world, bc, actual_dt)
```

When `dt_sfm < dt` is active, the caller must pass `dt_sfm`. Using `config.dt`
would over-accumulate the deficit and spawn too many agents per second.
Calling the 2-argument form will throw an informative error.

## Return value

`n_removed - n_spawned` (positive = net sink; negative = net source).

# Fields
- `arrival_radius::F`: Sink threshold (metres).
- `spawn_rate::F`: Target spawn rate (ped/s). Weidmann 1m door: 1.44 ped/s.
- `spawn_pos::SVector{2,F}`: Spawn location for documentation / debugging.
  The actual placement is determined by `agent_factory`.
- `agent_factory::Fn`: `(world::World) → nothing`; creates one new agent.
  All parameters (physics model, goal, initial position) are in the closure.
- `_deficit::Ref{F}`: Internal accumulator. Do not set manually; use the
  4-argument constructor.

# Example
```julia
factory = world -> new_entity!(world, (
    Position(SVector(0.5f0, 2.0f0)),
    Velocity(zero(SVector{2,Float32})),
    Goal(SVector(12.0f0, 2.0f0)),
    CSMParams{Float32}(),
    AgentCSMState{Float32}(),
    AgentGeometry(0.2f0, 0.13f0),
))

bc = ConstantFluxBoundary(1.5f0, 1.44f0, SVector(0.5f0, 2.0f0), factory)

t = 0f0
while t < t_max
    step!(scene)
    actual_dt = scene.config.dt   # or dt_sfm if adaptive switching active
    apply_boundary!(scene.world, bc, actual_dt)
    t += actual_dt
end
```
"""
struct ConstantFluxBoundary{F<:AbstractFloat, Fn} <: BoundaryCondition{F}
    arrival_radius :: F
    spawn_rate     :: F
    spawn_pos      :: SVector{2,F}
    agent_factory  :: Fn
    _deficit       :: Ref{F}   # fractional-spawn accumulator (ped owed)
end

# 4-argument convenience constructor — initialises deficit to zero
function ConstantFluxBoundary(
    arrival_radius :: F,
    spawn_rate     :: F,
    spawn_pos      :: SVector{2,F},
    agent_factory  :: Fn,
) where {F<:AbstractFloat, Fn}
    ConstantFluxBoundary{F,Fn}(arrival_radius, spawn_rate, spawn_pos, agent_factory, Ref(zero(F)))
end

"""
    apply_boundary!(world, bc::ConstantFluxBoundary{F}, dt::F) → net_delta::Int

Apply one step of the constant-flux BC:

1. **Sink pass**: remove agents within `bc.arrival_radius` of their `Goal{F}`
   (two-pass deferred deletion, safe for Ark swap-remove).
2. **Source pass**: accumulate `bc.spawn_rate × dt` into `bc._deficit`, then
   call `bc.agent_factory(world)` for each whole-agent unit of deficit.

Returns `n_removed - n_spawned` (positive = net sink; negative = net source).
"""
function apply_boundary!(world::World, bc::ConstantFluxBoundary{F}, dt::F) where {F<:AbstractFloat}
    # ── Sink: remove arrived agents (two-pass, deferred) ──────────────────────
    r_sq      = bc.arrival_radius * bc.arrival_radius
    to_remove = Entity[]

    for (entities, pos_col, goal_col) in Query(world, (Position{F}, Goal{F}))
        for i in eachindex(pos_col)
            dp = pos_col[i].p - goal_col[i].g
            dp[1]^2 + dp[2]^2 ≤ r_sq && push!(to_remove, entities[i])
        end
    end
    for entity in to_remove
        Ark.remove_entity!(world, entity)
    end
    n_removed = length(to_remove)

    # ── Source: fractional-threshold spawn accumulator ─────────────────────────
    bc._deficit[] += bc.spawn_rate * dt
    n_spawned = 0
    while bc._deficit[] ≥ one(F)
        bc.agent_factory(world)
        bc._deficit[] -= one(F)
        n_spawned += 1
    end

    return n_removed - n_spawned
end

"""
    apply_boundary!(world, bc::ConstantFluxBoundary{F}) → error

2-argument form is intentionally disabled. The spawn accumulator requires the
actual dt used this step. Always use:

```julia
apply_boundary!(world, bc, actual_dt)
```
"""
function apply_boundary!(world::World, bc::ConstantFluxBoundary{F}) where {F<:AbstractFloat}
    error(
        "ConstantFluxBoundary requires the actual timestep dt.\n" *
        "Use the 3-argument form: apply_boundary!(world, bc, dt)\n" *
        "When dt_sfm adaptive switching is active, pass dt_sfm, not config.dt."
    )
end


# ── OpenBoundary ──────────────────────────────────────────────────────────────

"""
    OpenBoundary{F}()

No-op boundary condition. Domain is large enough that no agent reaches an edge.
`apply_boundary!` returns 0 immediately with zero allocation.

Analogous to a **free-space / large-domain** simulation where boundary effects
are absent by construction (e.g., open plaza, pedestrian crossing study).
"""
struct OpenBoundary{F<:AbstractFloat} <: BoundaryCondition{F} end

# No-op — zero allocation, returns 0 immediately.
apply_boundary!(::World, ::OpenBoundary) = 0
