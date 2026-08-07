"""
    world.jl — SimWorld: global simulation state container

`SimWorld` holds all entity component data for Tier 1 (Dict-based, single-thread).
In Tier 2, Ark.jl replaces the Dict stores with cache-efficient SoA archetype storage,
but the public API (`add_crowd_agent!`, `get_crowd_agent`, etc.) remains identical.

Design ref: §5.1 (Shared ECS World Layout)
"""

# ── ZoneState (must be defined before SimWorld) ───────────────────────────────

"""
    ZoneState

Mutable runtime state for a single zone (DES logical process).

# Fields
- `queue_length::Int`: current number of entities waiting in queue
- `busy_servers::Int`: number of servers currently processing
- `capacity::Int`: maximum queue capacity (`typemax(Int)` = unlimited)
- `num_servers::Int`: total number of parallel servers
- `last_event_time::Float64`: time of last event (for time-average stats)
"""
mutable struct ZoneState
    queue_length    :: Int
    busy_servers    :: Int
    capacity        :: Int
    num_servers     :: Int
    last_event_time :: Float64
end

"""
    ZoneState(; capacity, num_servers) -> ZoneState

Create a fresh zone state with empty queues and idle servers.
"""
ZoneState(; capacity::Int = typemax(Int), num_servers::Int = 1) =
    ZoneState(0, 0, capacity, num_servers, 0.0)

# ── SimWorld ──────────────────────────────────────────────────────────────────

"""
    SimWorld

The simulation world — holds all entity state for a single simulation run.

Tier 1 implementation uses `Dict{UInt64, T}` for simplicity and correctness.
Tier 2 replaces Dict stores with Ark.jl archetypes for cache efficiency while
keeping the same public API.

# Fields
- `_next_entity_id`: thread-safe ID counter
- `des_agents`: DES entities (customers, packages, patients)
- `crowd_agents`: pedestrian crowd agents
- `fluid_particles`: SPH fluid particles
- `obstacles`: walls and barriers
- `zone_states`: per-zone mutable state (queue depth, server busy count, etc.)
- `stats`: global statistics accumulator
- `time`: current simulated time
"""
mutable struct SimWorld
    _next_entity_id :: Threads.Atomic{UInt64}
    des_agents      :: Dict{UInt64, DESAgent}
    crowd_agents    :: Dict{UInt64, CrowdAgent}
    fluid_particles :: Dict{UInt64, FluidParticle}
    obstacles       :: Dict{UInt64, CrowdObstacle}
    zone_states     :: Dict{Int, ZoneState}
    stats           :: SimStats
    time            :: Float64
end

"""
    SimWorld() -> SimWorld

Create an empty simulation world with no entities.
"""
function SimWorld()
    SimWorld(
        Threads.Atomic{UInt64}(0),
        Dict{UInt64, DESAgent}(),
        Dict{UInt64, CrowdAgent}(),
        Dict{UInt64, FluidParticle}(),
        Dict{UInt64, CrowdObstacle}(),
        Dict{Int, ZoneState}(),
        SimStats(),
        0.0,
    )
end

# ── Entity ID management ───────────────────────────────────────────────────────

"""
    new_entity_id!(world) -> UInt64

Generate and return a new unique entity ID.
Thread-safe monotonic counter.
"""
new_entity_id!(world::SimWorld) =
    Threads.atomic_add!(world._next_entity_id, UInt64(1)) + UInt64(1)

# ── Entity add / remove ────────────────────────────────────────────────────────

"""
    add_des_agent!(world, id, agent) -> world

Add a DES agent (customer/package/patient) to the world.
"""
function add_des_agent!(world::SimWorld, id::UInt64, agent::DESAgent)
    world.des_agents[id] = agent
    return world
end

"""
    add_crowd_agent!(world, agent) -> UInt64

Add a crowd agent to the world, auto-assigning a new entity ID.
Returns the assigned ID.
"""
function add_crowd_agent!(world::SimWorld, agent::CrowdAgent)
    id = new_entity_id!(world)
    world.crowd_agents[id] = agent
    return id
end

"""
    add_crowd_agent!(world, id, agent) -> world

Add a crowd agent with an explicit entity ID.
"""
function add_crowd_agent!(world::SimWorld, id::UInt64, agent::CrowdAgent)
    world.crowd_agents[id] = agent
    return world
end

"""
    add_fluid_particle!(world, particle) -> UInt64

Add a fluid particle to the world, auto-assigning a new entity ID.
"""
function add_fluid_particle!(world::SimWorld, particle::FluidParticle)
    id = new_entity_id!(world)
    world.fluid_particles[id] = particle
    return id
end

"""
    add_obstacle!(world, obstacle) -> UInt64

Add a wall/obstacle to the world, auto-assigning a new entity ID.
"""
function add_obstacle!(world::SimWorld, obstacle::CrowdObstacle)
    id = new_entity_id!(world)
    world.obstacles[id] = obstacle
    return id
end

"""
    remove_entity!(world, id)

Remove an entity of any type from the world by ID.
"""
function remove_entity!(world::SimWorld, id::UInt64)
    delete!(world.des_agents, id)
    delete!(world.crowd_agents, id)
    delete!(world.fluid_particles, id)
    delete!(world.obstacles, id)
    return world
end

# ── Component accessors ────────────────────────────────────────────────────────

"""
    get_des_agent(world, id) -> Union{DESAgent, Nothing}
"""
get_des_agent(world::SimWorld, id::UInt64) = get(world.des_agents, id, nothing)

"""
    get_crowd_agent(world, id) -> Union{CrowdAgent, Nothing}
"""
get_crowd_agent(world::SimWorld, id::UInt64) = get(world.crowd_agents, id, nothing)

"""
    update_crowd_agent!(world, id, agent)

Replace the crowd agent component for `id` with a new `agent` struct.
Used by the Social Force integration step.
"""
function update_crowd_agent!(world::SimWorld, id::UInt64, agent::CrowdAgent)
    world.crowd_agents[id] = agent
    return world
end

# ── Zone management ────────────────────────────────────────────────────────────

"""
    add_zone!(world, zone_id; capacity, num_servers) -> world

Register a zone with the given ID and initial state.
Must be called before any events reference this zone.
"""
function add_zone!(world::SimWorld, zone_id::Int;
                   capacity::Int    = typemax(Int),
                   num_servers::Int = 1)
    world.zone_states[zone_id] = ZoneState(; capacity, num_servers)
    return world
end

"""
    get_zone(world, zone_id) -> ZoneState

Retrieve mutable zone state. Throws `KeyError` if zone not registered.
"""
get_zone(world::SimWorld, zone_id::Int) = world.zone_states[zone_id]

# ── World summary ──────────────────────────────────────────────────────────────

"""
    entity_count(world) -> NamedTuple

Return counts of all entity types in the world.
"""
function entity_count(world::SimWorld)
    (
        des_agents      = length(world.des_agents),
        crowd_agents    = length(world.crowd_agents),
        fluid_particles = length(world.fluid_particles),
        obstacles       = length(world.obstacles),
        zones           = length(world.zone_states),
    )
end
