"""
    components.jl — ECS component structs

Plain Julia structs representing the data attached to entities in the
simulation world. Each struct is a component in the Entity-Component-System
pattern backed by Ark.jl (Tier 2) or Dict (Tier 1 prototype).

Rules (from code_design_practices.md §2.3 & §3.2):
- Every field has a concrete type (no abstract fields)
- Immutable by default — use @set (Accessors.jl) to "update"
- SVector{2,Float32} for 2D positions/velocities (stack-allocated, no GC)

Design ref: §5.1 (Shared ECS World Layout)
"""

using StaticArrays: SVector

# ── DES / Queueing components ─────────────────────────────────────────────────

"""
    DESAgent

Represents an entity moving through a discrete-event system
(customer, package, patient, vehicle, work-order).

# Fields
- `arrival_time::Float64`: simulated time this entity first entered the system
- `current_zone::Int`: LP (Logical Process) ID where the entity currently is
- `priority::Int`: service priority; higher = served first (default 0)
"""
struct DESAgent
    arrival_time  :: Float64
    current_zone  :: Int
    priority      :: Int
end

DESAgent(arrival_time::Float64, current_zone::Int) =
    DESAgent(arrival_time, current_zone, 0)

# ── Crowd agent component ──────────────────────────────────────────────────────

"""
    CrowdAgent

A pedestrian agent in the Social Force Model (Helbing & Molnár 1995).
All fields use `Float32` for GPU kernel compatibility.

# Fields
- `position::SVector{2,Float32}`: 2D position [m]
- `velocity::SVector{2,Float32}`: current velocity [m/s]
- `desired_speed::Float32`: preferred walking speed [m/s]; typical 1.34 m/s
- `panic_level::Float32`: 0.0 = calm, 1.0 = full panic
- `goal::SVector{2,Float32}`: current navigation target position [m]
- `radius::Float32`: agent body radius [m]; typical 0.25 m
- `mass::Float32`: agent mass [kg]; typical 80 kg
"""
struct CrowdAgent
    position      :: SVector{2, Float32}
    velocity      :: SVector{2, Float32}
    desired_speed :: Float32
    panic_level   :: Float32
    goal          :: SVector{2, Float32}
    radius        :: Float32
    mass          :: Float32
end

"""
    CrowdAgent(position, goal; kwargs...) -> CrowdAgent

Convenience constructor with sensible defaults for a calm pedestrian.
"""
function CrowdAgent(position::SVector{2,Float32}, goal::SVector{2,Float32};
                    desired_speed::Float32 = 1.34f0,
                    panic_level::Float32   = 0.0f0,
                    radius::Float32        = 0.25f0,
                    mass::Float32          = 80.0f0)
    CrowdAgent(position, zero(SVector{2,Float32}), desired_speed, panic_level,
               goal, radius, mass)
end

# ── Fluid particle component ───────────────────────────────────────────────────

"""
    FluidParticle

An SPH (Smoothed Particle Hydrodynamics) or LBM lattice-cell particle.
All fields use `Float32` for GPU kernel compatibility.

# Fields
- `position::SVector{2,Float32}`: particle position [m]
- `velocity::SVector{2,Float32}`: particle velocity [m/s]
- `pressure::Float32`: local pressure [Pa]
- `density::Float32`: local fluid density [kg/m³]
- `mass::Float32`: particle mass [kg]
"""
struct FluidParticle
    position :: SVector{2, Float32}
    velocity :: SVector{2, Float32}
    pressure :: Float32
    density  :: Float32
    mass     :: Float32
end

FluidParticle(position::SVector{2,Float32}; density::Float32=1000.0f0, mass::Float32=1.0f0) =
    FluidParticle(position, zero(SVector{2,Float32}), 0.0f0, density, mass)

# ── Obstacle component ────────────────────────────────────────────────────────

"""
    CrowdObstacle

An axis-aligned bounding box (AABB) wall or obstacle that crowd agents
and fluid particles cannot pass through.

# Fields
- `x1, y1`: lower-left corner [m]
- `x2, y2`: upper-right corner [m]

# Example
```julia
# A wall from (0,0) to (10,0)
obs = CrowdObstacle(0f0, -0.1f0, 10f0, 0.1f0)
```
"""
struct CrowdObstacle
    x1 :: Float32
    y1 :: Float32
    x2 :: Float32
    y2 :: Float32
end

"""
    width(obs), height(obs), center(obs)

Geometric helpers for `CrowdObstacle`.
"""
width(obs::CrowdObstacle)  = obs.x2 - obs.x1
height(obs::CrowdObstacle) = obs.y2 - obs.y1
center(obs::CrowdObstacle) = SVector{2,Float32}((obs.x1 + obs.x2)/2, (obs.y1 + obs.y2)/2)
