# ── Types ──────────────────────────────────────────────────────────────────────

"""
    CrowdAgent{F<:AbstractFloat}

Represents a single pedestrian in the simulation.
"""
mutable struct CrowdAgent{F<:AbstractFloat}
    id::UInt64
    position::SVector{2,F}
    velocity::SVector{2,F}
    radius::F
    v_pref::F  # desired speed
    τ::F       # relaxation time
    goal::SVector{2,F} # Current target coordinate (often updated via Navigation field)
end

# ── Integrators ──────────────────────────────────────────────────────────────

"""
    Integrator

Abstract type for physics integrators.
"""
abstract type Integrator end

"""
    ForwardEuler <: Integrator

Standard Forward Euler integrator. 
x_{t+1} = x_t + v_t * dt
v_{t+1} = v_t + F * dt
"""
struct ForwardEuler <: Integrator end

"""
    SymplecticEuler <: Integrator

Symplectic Euler integrator. Better energy conservation for oscillatory systems.
v_{t+1} = v_t + F * dt
x_{t+1} = x_t + v_{t+1} * dt
"""
struct SymplecticEuler <: Integrator end

"""
    integrate_agent!(agent, F_total, dt, integrator)

Updates the agent's position and velocity in-place using the specified `integrator`.
"""
@inline function integrate_agent!(agent::CrowdAgent{F}, F_total::SVector{2,F}, dt::F, ::SymplecticEuler) where {F}
    agent.velocity += F_total * dt
    agent.position += agent.velocity * dt
    return nothing
end

@inline function integrate_agent!(agent::CrowdAgent{F}, F_total::SVector{2,F}, dt::F, ::ForwardEuler) where {F}
    agent.position += agent.velocity * dt
    agent.velocity += F_total * dt
    return nothing
end
