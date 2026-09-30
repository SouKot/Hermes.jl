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
- `capacity::Int`: maximum entities in system (queue + in-service)
- `num_servers::Int`: total number of parallel servers
- `last_event_time::Float64`: time of last event (for time-average stats)
- `queue::Vector{UInt64}`: ordered FIFO list of entity IDs waiting.
  `push!` is O(1) amortized; `popfirst!` is O(n) (memmove) — but CPU
  SIMD vectorisation makes this faster than `Deque` at all realistic DES
  queue depths (benchmarked: 11ns flat from n=5 to n=2000). Switch to
  `DataStructures.Deque` only if queue depths regularly exceed ~10,000.
"""
mutable struct ZoneState
    queue_length    :: Int
    busy_servers    :: Int
    capacity        :: Int
    num_servers     :: Int
    last_event_time :: Float64
    queue           :: Vector{UInt64}   # see docstring re: O(n) popfirst! vs memmove
end

"""
    ZoneState(; capacity, num_servers) -> ZoneState

Create a fresh zone state with empty queue and idle servers.
"""
ZoneState(; capacity::Int = typemax(Int), num_servers::Int = 1) =
    ZoneState(0, 0, capacity, num_servers, 0.0, UInt64[])

# ── EntityHandle & Topology / Kinematics Stores (SimViz M-1) ─────────────────

"""
    EntityHandle(id::Int32, kind::UInt8)

Unboxed 64-bit integer handle for O(1) zero-allocation entity addressing in `SimViz`.
- `kind = 1`: scene / station / conveyor / resource entity (server, queue, conveyor, source, sink, vehicle)
- `kind = 2`: flowing item entity (product, customer, pallet)
- `kind = 3`: container / subgraph entity
- `id = 0, kind = 0`: `INVALID_HANDLE`
"""
struct EntityHandle
    id   :: Int32
    kind :: UInt8
end

const INVALID_HANDLE = EntityHandle(Int32(0), UInt8(0))
Base.isvalid(h::EntityHandle) = h.id != Int32(0) && h.kind != UInt8(0)

"""
    EntityKinematics

Piecewise-linear O(1) trajectory state for an entity moving along a conveyor or spatial path.
"""
mutable struct EntityKinematics
    zone_id             :: Int
    path_length         :: Float64
    base_distance       :: Float64   # distance along path [m] at last_update_time
    current_speed       :: Float64   # current instantaneous speed [m/s] (0.0 when accumulated/stopped)
    nominal_speed       :: Float64   # nominal unblocked speed [m/s]
    last_update_time    :: Float64
    exit_event_id       :: UInt64    # FEL event ID of scheduled ProcessComplete (0 if stopped/accumulated)
    custom_pos_override :: Bool
    custom_pos          :: NTuple{3, Float64}
end

EntityKinematics(zone_id::Int, path_length::Float64, speed::Float64, t::Float64; exit_event_id::UInt64=UInt64(0)) =
    EntityKinematics(zone_id, max(0.001, path_length), 0.0, speed, speed, t, exit_event_id, false, (0.0, 0.0, 0.0))

@inline function kinematics_distance(k::EntityKinematics, t::Float64)::Float64
    return clamp(k.base_distance + max(0.0, t - k.last_update_time) * k.current_speed, 0.0, max(0.001, k.path_length))
end

@inline function kinematics_progress(k::EntityKinematics, t::Float64)::Float64
    return clamp(kinematics_distance(k, t) / max(0.001, k.path_length), 0.0, 1.0)
end

"""
    PortDescriptor

Metadata for a strictly directional port (`:in` or `:out`) on a scene entity.
"""
struct PortDescriptor
    name        :: Symbol
    direction   :: Symbol   # strictly :in or :out
    domain      :: Symbol   # :flow, :signal, :event, :metric
    cardinality :: Symbol   # :single or :multi
end

"""
    PortWireLink

Represents one connected wire on a port at 1-based slot index `slot`.
"""
struct PortWireLink
    slot        :: Int
    peer_handle :: EntityHandle
    peer_port   :: Symbol
    wire_id     :: String
    weight      :: Float64
end

"""
    PortDirectory

Pre-indexed topology and port-connection lookup tables for O(1) `SimViz` queries.
"""
mutable struct PortDirectory
    name_to_handle      :: Dict{String, EntityHandle}
    handle_to_name      :: Dict{EntityHandle, String}
    handle_to_zone      :: Dict{EntityHandle, Int}
    zone_to_handle      :: Dict{Int, EntityHandle}
    handle_to_kind      :: Dict{EntityHandle, Symbol}
    by_kind             :: Dict{Symbol, Vector{EntityHandle}}
    by_group            :: Dict{Symbol, Vector{EntityHandle}}
    ports               :: Dict{EntityHandle, Vector{PortDescriptor}}
    wires               :: Dict{Tuple{EntityHandle, Symbol}, Vector{PortWireLink}}
    round_robin_cursors :: Dict{Tuple{EntityHandle, Symbol}, Int}
end

PortDirectory() = PortDirectory(
    Dict{String, EntityHandle}(),
    Dict{EntityHandle, String}(),
    Dict{EntityHandle, Int}(),
    Dict{Int, EntityHandle}(),
    Dict{EntityHandle, Symbol}(),
    Dict{Symbol, Vector{EntityHandle}}(),
    Dict{Symbol, Vector{EntityHandle}}(),
    Dict{EntityHandle, Vector{PortDescriptor}}(),
    Dict{Tuple{EntityHandle, Symbol}, Vector{PortWireLink}}(),
    Dict{Tuple{EntityHandle, Symbol}, Int}(),
)

"""
    UserTelemetryStore

Stores user-emitted counters, gauges, time-series, histograms, tallies, and trace logs.
"""
mutable struct UserTelemetryStore
    counters   :: Dict{Symbol, Int64}
    gauges     :: Dict{Symbol, Float64}
    timeseries :: Dict{Symbol, Vector{Tuple{Float64, Float64}}}
    histograms :: Dict{Symbol, Vector{Float64}}
    tally_sums :: Dict{Symbol, Tuple{Float64, Int64}}
    logs       :: Vector{Tuple{Float64, String, String}}
end

UserTelemetryStore() = UserTelemetryStore(
    Dict{Symbol, Int64}(),
    Dict{Symbol, Float64}(),
    Dict{Symbol, Vector{Tuple{Float64, Float64}}}(),
    Dict{Symbol, Vector{Float64}}(),
    Dict{Symbol, Tuple{Float64, Int64}}(),
    Tuple{Float64, String, String}[],
)

# ── SimWorld ──────────────────────────────────────────────────────────────────

"""
    SimWorld

The simulation world — holds all entity state for a single simulation run.

Tier 1 implementation uses `Dict{UInt64, T}` for simplicity and correctness.
Tier 2 replaces Dict stores with Ark.jl archetypes for cache efficiency while
keeping the same public API.
"""
mutable struct SimWorld
    _next_entity_id        :: Threads.Atomic{UInt64}
    des_agents             :: Dict{UInt64, DESAgent}
    crowd_agents           :: Dict{UInt64, CrowdAgent}
    fluid_particles        :: Dict{UInt64, FluidParticle}
    obstacles              :: Dict{UInt64, CrowdObstacle}
    zone_states            :: Dict{Int, ZoneState}
    stats                  :: SimStats
    zone_stats             :: Dict{Int, SimStats}                      # per-zone stats
    entry_times            :: Dict{UInt64, Float64}                    # system entry time per entity
    join_barriers          :: Dict{UInt64, Tuple{Int,Int,Float64}}     # parent → (total,done,t_entry)
    sub_entity_map         :: Dict{UInt64, UInt64}                     # sub_id → parent_id
    time                   :: Float64
    entity_attributes      :: Dict{UInt64, Dict{String, Any}}
    entity_visuals         :: Dict{UInt64, Dict{String, Any}}
    entity_route_overrides :: Dict{UInt64, Int}
    zone_attributes        :: Dict{Int, Dict{String, Any}}
    entity_kinematics      :: Dict{UInt64, EntityKinematics}
    port_directory         :: PortDirectory
    user_telemetry         :: UserTelemetryStore
    containment_parent     :: Dict{EntityHandle, EntityHandle}
    containment_children   :: Dict{EntityHandle, Vector{EntityHandle}}
    zone_signals           :: Dict{Tuple{Int, Symbol}, Any}
    last_processed_attrs   :: Dict{Int, Dict{String, Any}}
    zone_paused            :: Dict{Int, Tuple{Bool, Int}}
    zone_service_override  :: Dict{Tuple{Int, UInt64}, Float64}
    zone_setup_time        :: Dict{Tuple{Int, UInt64}, Float64}
    active_user_events     :: Dict{Int, Set{UInt64}}
    entity_type_templates  :: Dict{Symbol, Dict{String, Any}}
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
        Dict{Int, SimStats}(),
        Dict{UInt64, Float64}(),
        Dict{UInt64, Tuple{Int,Int,Float64}}(),
        Dict{UInt64, UInt64}(),
        0.0,
        Dict{UInt64, Dict{String, Any}}(),
        Dict{UInt64, Dict{String, Any}}(),
        Dict{UInt64, Int}(),
        Dict{Int, Dict{String, Any}}(),
        Dict{UInt64, EntityKinematics}(),
        PortDirectory(),
        UserTelemetryStore(),
        Dict{EntityHandle, EntityHandle}(),
        Dict{EntityHandle, Vector{EntityHandle}}(),
        Dict{Tuple{Int, Symbol}, Any}(),
        Dict{Int, Dict{String, Any}}(),
        Dict{Int, Tuple{Bool, Int}}(),
        Dict{Tuple{Int, UInt64}, Float64}(),
        Dict{Tuple{Int, UInt64}, Float64}(),
        Dict{Int, Set{UInt64}}(),
        Dict{Symbol, Dict{String, Any}}(),
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
    remove_des_agent!(world, id)

Remove a DES agent (customer/package/patient) from the world.
Use this on the simulation hot path — it touches only the `des_agents` dict
(25.8ns), unlike `remove_entity!` which deletes from all four entity dicts
(103.8ns, 78ns wasted on empty crowd/fluid/obstacle dicts).
"""
function remove_des_agent!(world::SimWorld, id::UInt64)
    delete!(world.des_agents, id)
    !isempty(world.entity_attributes)      && delete!(world.entity_attributes, id)
    !isempty(world.entity_visuals)         && delete!(world.entity_visuals, id)
    !isempty(world.entity_route_overrides) && delete!(world.entity_route_overrides, id)
    !isempty(world.entity_kinematics)      && delete!(world.entity_kinematics, id)
    return world
end

"""
    remove_crowd_agent!(world, id)

Remove a crowd agent from the world. Use this instead of `remove_entity!`
when only crowd agents are being removed.
"""
remove_crowd_agent!(world::SimWorld, id::UInt64) =
    (delete!(world.crowd_agents, id); world)

"""
    remove_entity!(world, id)

Remove an entity of any type from the world by ID.
Searches all four entity stores. Use only for world teardown or when the
entity type is unknown. On the simulation hot path, prefer `remove_des_agent!`
or `remove_crowd_agent!` to avoid 78ns of wasted hash lookups per call.
"""
function remove_entity!(world::SimWorld, id::UInt64)
    delete!(world.des_agents, id)
    delete!(world.crowd_agents, id)
    delete!(world.fluid_particles, id)
    delete!(world.obstacles, id)
    !isempty(world.entity_attributes)      && delete!(world.entity_attributes, id)
    !isempty(world.entity_visuals)         && delete!(world.entity_visuals, id)
    !isempty(world.entity_route_overrides) && delete!(world.entity_route_overrides, id)
    !isempty(world.entity_kinematics)      && delete!(world.entity_kinematics, id)
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

# ── Entity Attributes, Visual Overrides, and EntityStateView (I-1..I-4, M-1) ──

const _EMPTY_ATTR_DICT = Dict{String, Any}()

"""
    get_entity_attributes(world::SimWorld, id::Integer; create::Bool=false) -> Dict{String, Any}

Return the dynamic attribute dictionary for entity `id`.
"""
function get_entity_attributes(world::SimWorld, id::Integer; create::Bool=false)::Dict{String, Any}
    uid = UInt64(id)
    if create
        return get!(world.entity_attributes, uid) do
            Dict{String, Any}()
        end
    else
        return get(world.entity_attributes, uid, _EMPTY_ATTR_DICT)
    end
end

"""
    get_entity_attribute(world::SimWorld, id::Integer, key::Union{String, Symbol}, default=nothing)

Read a single attribute `key` from entity `id`.
"""
function get_entity_attribute(world::SimWorld, id::Integer, key::Union{String, Symbol}, default=nothing)
    uid = UInt64(id)
    bag = get(world.entity_attributes, uid, nothing)
    bag === nothing && return default
    return get(bag, string(key), default)
end

"""
    set_entity_attribute!(world::SimWorld, id::Integer, key::Union{String, Symbol}, value)

Write a single attribute `key => value` onto entity `id`.
"""
function set_entity_attribute!(world::SimWorld, id::Integer, key::Union{String, Symbol}, value)
    bag = get_entity_attributes(world, id; create=true)
    bag[string(key)] = value
    return value
end

"""
    get_zone_attributes(world::SimWorld, zone_id::Int; create::Bool=false) -> Dict{String, Any}
"""
function get_zone_attributes(world::SimWorld, zone_id::Int; create::Bool=false)::Dict{String, Any}
    if create
        return get!(world.zone_attributes, zone_id) do
            Dict{String, Any}()
        end
    else
        return get(world.zone_attributes, zone_id, _EMPTY_ATTR_DICT)
    end
end

function get_zone_attribute(world::SimWorld, zone_id::Int, key::Union{String, Symbol}, default=nothing)
    bag = get(world.zone_attributes, zone_id, nothing)
    bag === nothing && return default
    return get(bag, string(key), default)
end

function set_zone_attribute!(world::SimWorld, zone_id::Int, key::Union{String, Symbol}, value)
    bag = get_zone_attributes(world, zone_id; create=true)
    bag[string(key)] = value
    return value
end

"""
    get_entity_visuals(world::SimWorld, id::Integer; create::Bool=false) -> Dict{String, Any}
"""
function get_entity_visuals(world::SimWorld, id::Integer; create::Bool=false)::Dict{String, Any}
    uid = UInt64(id)
    if create
        return get!(world.entity_visuals, uid) do
            Dict{String, Any}()
        end
    else
        return get(world.entity_visuals, uid, _EMPTY_ATTR_DICT)
    end
end

"""
    set_entity_visual!(world::SimWorld, id::Integer, key::Union{String, Symbol}, value)
"""
function set_entity_visual!(world::SimWorld, id::Integer, key::Union{String, Symbol}, value)
    vis = get_entity_visuals(world, id; create=true)
    vis[string(key)] = value
    return value
end

"""
    EntityStateView

Lightweight read-only view of an entity passed to custom queue discipline comparators
`(a, b) -> ...` and predicate selectors (`pull_from_port_where!`, `dequeue_where!`).
Supports dot-property lookup (`a.due_date`, `a.priority`, `a.arrival_time`, `a.wait_time`,
`a.slack`, `a.critical_ratio`, `a.handle`) as well as `get_attribute(a, key, default)`.
"""
struct EntityStateView
    id           :: Int
    priority     :: Int
    arrival_time :: Float64
    current_zone :: Int
    sim_time     :: Float64
    attributes   :: Dict{String, Any}
end

function Base.getproperty(v::EntityStateView, sym::Symbol)
    if sym === :id
        return getfield(v, :id)
    elseif sym === :priority
        return getfield(v, :priority)
    elseif sym === :arrival_time
        return getfield(v, :arrival_time)
    elseif sym === :current_zone
        return getfield(v, :current_zone)
    elseif sym === :sim_time
        return getfield(v, :sim_time)
    elseif sym === :attributes
        return getfield(v, :attributes)
    elseif sym === :handle
        return EntityHandle(Int32(getfield(v, :id)), UInt8(2))
    elseif sym === :wait_time
        return max(0.0, getfield(v, :sim_time) - getfield(v, :arrival_time))
    elseif sym === :due_date
        attrs = getfield(v, :attributes)
        val = get(attrs, "due_date", Inf)
        return val isa Real ? Float64(val) : Inf
    elseif sym === :service_time || sym === :estimated_service
        attrs = getfield(v, :attributes)
        val = get(attrs, "estimated_service", get(attrs, "service_time", 1.0))
        return val isa Real ? Float64(val) : 1.0
    elseif sym === :slack
        dd = v.due_date
        st = v.service_time
        return dd - getfield(v, :sim_time) - st
    elseif sym === :critical_ratio
        dd = v.due_date
        st = max(1e-6, v.service_time)
        return (dd - getfield(v, :sim_time)) / st
    else
        attrs = getfield(v, :attributes)
        return get(attrs, string(sym), nothing)
    end
end

get_entity_attribute(v::EntityStateView, key::Union{String, Symbol}, default=nothing) =
    get(getfield(v, :attributes), string(key), default)

"""
    get_entity_state(world::SimWorld, id::Integer) -> EntityStateView
"""
function get_entity_state(world::SimWorld, id::Integer)::EntityStateView
    uid = UInt64(id)
    ag = get_des_agent(world, uid)
    prio = ag !== nothing ? ag.priority : 0
    arr_t = ag !== nothing ? ag.arrival_time : get(world.entry_times, uid, world.time)
    cz = ag !== nothing ? ag.current_zone : 0
    attrs = get_entity_attributes(world, uid; create=false)
    return EntityStateView(Int(uid), prio, arr_t, cz, world.time, attrs)
end

