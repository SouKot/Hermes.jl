"""
    hybrid_sync.jl — Task 24 scaffolding for DES↔ABM synchronisation

This file defines the public data structures and validation helpers required to
start implementing the hybrid sync contract.

Task A/B/C scope:
- public config/types (`HybridSyncConfig`, `ServiceZone`, `HybridSyncBuffers`, `HybridSyncState`)
- config validation (`validate_sync_config`)
- buffer reset utility (`reset_sync_buffers!`)
- state lifecycle utility (`reset_sync_state!`)
- exported function entry-points (`sync_step!`, `mark_departure!`)

Runtime coupling logic is implemented in later tasks.

Task H scope:
- transport seam (`AbstractSyncTransport`, `LocalSyncTransport`)
- transport-aware sync entry-points for future PDES implementations
"""

"""
    AbstractSyncTransport

Transport seam for DES↔ABM sync orchestration. Tier-1 uses local in-process
transport; future Tier-2 PDES transports can specialize the same API.
"""
abstract type AbstractSyncTransport end

"""
    LocalSyncTransport

Tier-1 in-process sync transport (default).
"""
struct LocalSyncTransport <: AbstractSyncTransport end

const LOCAL_SYNC_TRANSPORT = LocalSyncTransport()

"""
    HybridSyncConfig{F<:AbstractFloat}

Configuration for DES↔ABM sync boundary behaviour.

# Fields
- `dt::F`: ABM physics timestep.
- `Δt_sync::F`: DES↔ABM sync cadence in simulated time.
- `max_agents::Int`: capacity for per-agent sync vectors.
- `max_pending_departures::Int`: soft capacity target for host-side pending departures queue.
- `strict_invariants::Bool`: enable strict invariant checks in runtime sync logic.
- `drop_on_overflow::Bool`: if true, overflow policy may drop oldest/newest records (runtime task).
- `profiling::Bool`: enable runtime profiling counters/timers.
"""
struct HybridSyncConfig{F<:AbstractFloat}
    dt                     :: F
    Δt_sync                :: F
    max_agents             :: Int
    max_pending_departures :: Int
    strict_invariants      :: Bool
    drop_on_overflow       :: Bool
    profiling              :: Bool
end

"""
    HybridSyncConfig(; kwargs...) -> HybridSyncConfig{Float64}

Construct a validated hybrid sync config with safe defaults.
"""
function HybridSyncConfig(; dt::Real = 0.05,
                            Δt_sync::Real = 0.5,
                            max_agents::Int = 50_000,
                            max_pending_departures::Int = 50_000,
                            strict_invariants::Bool = true,
                            drop_on_overflow::Bool = false,
                            profiling::Bool = false)
    cfg = HybridSyncConfig(
        Float64(dt),
        Float64(Δt_sync),
        max_agents,
        max_pending_departures,
        strict_invariants,
        drop_on_overflow,
        profiling,
    )
    return validate_sync_config(cfg)
end

"""
    validate_sync_config(cfg::HybridSyncConfig) -> HybridSyncConfig

Validate sync config invariants. Throws `ArgumentError` on invalid inputs.
"""
function validate_sync_config(cfg::HybridSyncConfig{F}) where {F<:AbstractFloat}
    cfg.dt > zero(F) || throw(ArgumentError("dt must be > 0, got $(cfg.dt)"))
    cfg.Δt_sync > zero(F) || throw(ArgumentError("Δt_sync must be > 0, got $(cfg.Δt_sync)"))
    cfg.Δt_sync >= cfg.dt || throw(ArgumentError("Δt_sync must be ≥ dt, got Δt_sync=$(cfg.Δt_sync), dt=$(cfg.dt)"))

    ratio = cfg.Δt_sync / cfg.dt
    nearest = round(ratio)
    eps_tol = sqrt(eps(F))
    abs(ratio - nearest) <= eps_tol ||
        throw(ArgumentError("Δt_sync must be an integer multiple of dt, got ratio=$(ratio)"))

    cfg.max_agents > 0 || throw(ArgumentError("max_agents must be > 0, got $(cfg.max_agents)"))
    cfg.max_pending_departures > 0 ||
        throw(ArgumentError("max_pending_departures must be > 0, got $(cfg.max_pending_departures)"))

    return cfg
end

"""
    ServiceZone{F<:AbstractFloat}

Axis-aligned service zone used for ABM→DES zone-entry detection.
"""
struct ServiceZone{F<:AbstractFloat}
    x_lo    :: F
    x_hi    :: F
    y_lo    :: F
    y_hi    :: F
    zone_id :: Int32
end

"""
    ServiceZone(x_lo, x_hi, y_lo, y_hi, zone_id)

Construct a validated axis-aligned service zone.
"""
function ServiceZone(x_lo::Real, x_hi::Real,
                     y_lo::Real, y_hi::Real,
                     zone_id::Integer)
    x_lo < x_hi || throw(ArgumentError("x_lo must be < x_hi, got x_lo=$x_lo, x_hi=$x_hi"))
    y_lo < y_hi || throw(ArgumentError("y_lo must be < y_hi, got y_lo=$y_lo, y_hi=$y_hi"))
    zone_id >= 0 || throw(ArgumentError("zone_id must be ≥ 0, got $zone_id"))

    F = promote_type(typeof(float(x_lo)), typeof(float(x_hi)), typeof(float(y_lo)), typeof(float(y_hi)))
    return ServiceZone{F}(F(x_lo), F(x_hi), F(y_lo), F(y_hi), Int32(zone_id))
end

"""
    HybridSyncBuffers

Storage for sync boundary data exchange.

Task A provides a host-vector constructor to keep scaffolding dependency-light.
Backend-specialised constructors can be added in follow-up tasks.
"""
mutable struct HybridSyncBuffers{A1<:AbstractVector{Bool},
                                 A2<:AbstractVector{Bool},
                                 A3<:AbstractVector{Bool},
                                 A4<:AbstractVector{Int32},
                                 I<:Integer}
    d_zone_entry_flag  :: A1
    pending_departures :: Vector{I}
    d_agent_in_service :: A2
    d_agent_free       :: A3
    d_agent_zone       :: A4
    agent_slot_cache   :: IdDict{Any,Int}
    cached_agent_count :: Int
end

"""
    HybridSyncBuffers(N::Int; id_type::Type{I}=Int32) -> HybridSyncBuffers

Allocate host-backed sync buffers for `N` agents.
"""
function HybridSyncBuffers(N::Int; id_type::Type{I}=Int32) where {I<:Integer}
    N > 0 || throw(ArgumentError("N must be > 0, got $N"))
    flags = fill(false, N)
    in_service = fill(false, N)
    agent_free = fill(false, N)
    agent_zone = fill(Int32(-1), N)
    bufs = HybridSyncBuffers(flags, I[], in_service, agent_free, agent_zone, IdDict{Any,Int}(), 0)
    return _assert_buffer_invariants!(bufs)
end

"""
    HybridSyncBuffers(cfg::HybridSyncConfig; id_type::Type{I}=Int32) -> HybridSyncBuffers

Allocate host-backed sync buffers using capacities from `cfg`.
"""
function HybridSyncBuffers(cfg::HybridSyncConfig; id_type::Type{I}=Int32) where {I<:Integer}
    bufs = HybridSyncBuffers(cfg.max_agents; id_type=id_type)
    sizehint!(bufs.pending_departures, cfg.max_pending_departures)
    return bufs
end

"""
    _assert_buffer_invariants!(bufs::HybridSyncBuffers) -> bufs

Internal lifecycle invariant guard for sync buffers.
"""
function _assert_buffer_invariants!(bufs::HybridSyncBuffers)
    n = length(bufs.d_zone_entry_flag)
    n > 0 || throw(ArgumentError("sync buffers must have positive length"))
    length(bufs.d_agent_in_service) == n ||
        throw(ArgumentError("d_agent_in_service length must match d_zone_entry_flag length"))
    length(bufs.d_agent_free) == n ||
        throw(ArgumentError("d_agent_free length must match d_zone_entry_flag length"))
    length(bufs.d_agent_zone) == n ||
        throw(ArgumentError("d_agent_zone length must match d_zone_entry_flag length"))
    return bufs
end

"""
    reset_sync_buffers!(bufs::HybridSyncBuffers) -> bufs

Reset sync buffers in-place for a fresh run.
"""
function reset_sync_buffers!(bufs::HybridSyncBuffers)
    _assert_buffer_invariants!(bufs)
    fill!(bufs.d_zone_entry_flag, false)
    empty!(bufs.pending_departures)
    fill!(bufs.d_agent_in_service, false)
    fill!(bufs.d_agent_free, false)
    fill!(bufs.d_agent_zone, Int32(-1))
    empty!(bufs.agent_slot_cache)
    bufs.cached_agent_count = 0
    return bufs
end

"""
    HybridSyncState

Minimal state/counters for sync diagnostics.
"""
mutable struct HybridSyncState
    n_sync_steps             :: Int
    total_arrivals_injected  :: Int
    total_departures_applied :: Int
    total_overflow_drops     :: Int
    last_arrivals_injected   :: Int
    last_departures_applied  :: Int
    last_overflow_drops      :: Int
end

"""
    HybridSyncState() -> HybridSyncState
"""
HybridSyncState() = HybridSyncState(0, 0, 0, 0, 0, 0, 0)

"""
    reset_sync_state!(st::HybridSyncState) -> st

Reset all sync counters/diagnostics in-place.
"""
function reset_sync_state!(st::HybridSyncState)
    st.n_sync_steps = 0
    st.total_arrivals_injected = 0
    st.total_departures_applied = 0
    st.total_overflow_drops = 0
    st.last_arrivals_injected = 0
    st.last_departures_applied = 0
    st.last_overflow_drops = 0
    return st
end

"""
    _record_sync_step!(st::HybridSyncState; arrivals_injected=0, departures_applied=0, overflow_drops=0) -> st

Internal helper to update cumulative and last-step sync counters.
"""
function _record_sync_step!(st::HybridSyncState;
                            arrivals_injected::Integer = 0,
                            departures_applied::Integer = 0,
                            overflow_drops::Integer = 0)
    arrivals_injected >= 0 || throw(ArgumentError("arrivals_injected must be ≥ 0"))
    departures_applied >= 0 || throw(ArgumentError("departures_applied must be ≥ 0"))
    overflow_drops >= 0 || throw(ArgumentError("overflow_drops must be ≥ 0"))

    st.n_sync_steps += 1
    st.last_arrivals_injected = Int(arrivals_injected)
    st.last_departures_applied = Int(departures_applied)
    st.last_overflow_drops = Int(overflow_drops)
    st.total_arrivals_injected += Int(arrivals_injected)
    st.total_departures_applied += Int(departures_applied)
    st.total_overflow_drops += Int(overflow_drops)
    return st
end

"""
    _sync_state_snapshot(st::HybridSyncState) -> NamedTuple

Internal diagnostic snapshot for logging/tests.
"""
function _sync_state_snapshot(st::HybridSyncState)
    return (
        n_sync_steps = st.n_sync_steps,
        total_arrivals_injected = st.total_arrivals_injected,
        total_departures_applied = st.total_departures_applied,
        total_overflow_drops = st.total_overflow_drops,
        last_arrivals_injected = st.last_arrivals_injected,
        last_departures_applied = st.last_departures_applied,
        last_overflow_drops = st.last_overflow_drops,
    )
end

"""
    sync_step!(args...)

    _normalize_agent_index(bufs::HybridSyncBuffers, agent_id, context) -> Int

Validate and normalize an agent identifier to a 1-based buffer index.
"""
function _normalize_agent_index(bufs::HybridSyncBuffers, agent_id::Integer, context::AbstractString)
    agent_index = Int(agent_id)
    1 <= agent_index <= length(bufs.d_zone_entry_flag) ||
        throw(ArgumentError("$context agent_id must be within 1:$(length(bufs.d_zone_entry_flag)), got $agent_id"))
    return agent_index
end

"""
    _scan_zone_entries!(bufs::HybridSyncBuffers) -> Vector{Int}

Collect and clear all zone-entry flags raised by the ABM side since the last sync.
"""
function _scan_zone_entries!(bufs::HybridSyncBuffers)
    _assert_buffer_invariants!(bufs)
    arrival_ids = Int[]
    for agent_index in eachindex(bufs.d_zone_entry_flag)
        if bufs.d_zone_entry_flag[agent_index]
            push!(arrival_ids, agent_index)
            bufs.d_zone_entry_flag[agent_index] = false
        end
    end
    return arrival_ids
end

"""
    _scan_zone_entries!(::LocalSyncTransport, bufs::HybridSyncBuffers) -> Vector{Int}

Transport-specialized zone-entry scan for Tier-1 local transport.
"""
@inline _scan_zone_entries!(::LocalSyncTransport, bufs::HybridSyncBuffers) =
    _scan_zone_entries!(bufs)

"""
    _assert_invariants!(bufs::HybridSyncBuffers, arrival_ids, departure_ids; strict_invariants=true) -> nothing

Validate sync boundary invariants before mutating state.
"""
function _assert_invariants!(bufs::HybridSyncBuffers,
                             arrival_ids::AbstractVector{<:Integer},
                             departure_ids::AbstractVector{<:Integer};
                             strict_invariants::Bool = true)
    _assert_buffer_invariants!(bufs)
    strict_invariants || return nothing

    n_departures = length(departure_ids)
    for i in 1:n_departures
        raw_agent_id = departure_ids[i]
        agent_index = _normalize_agent_index(bufs, raw_agent_id, "departure")
        for j in (i + 1):n_departures
            other_index = _normalize_agent_index(bufs, departure_ids[j], "departure")
            other_index == agent_index &&
                throw(ArgumentError("duplicate pending departure for agent_id=$agent_index"))
        end
        bufs.d_agent_in_service[agent_index] ||
            throw(ArgumentError("departure for agent_id=$agent_index requires d_agent_in_service=true"))
    end

    for raw_agent_id in arrival_ids
        agent_index = _normalize_agent_index(bufs, raw_agent_id, "arrival")
        zone_id = bufs.d_agent_zone[agent_index]
        zone_id >= 0 || throw(ArgumentError("arrival for agent_id=$agent_index requires non-negative zone_id"))
        !bufs.d_agent_in_service[agent_index] ||
            throw(ArgumentError("arrival for agent_id=$agent_index violates no-double-freeze invariant"))
        !bufs.d_agent_free[agent_index] ||
            throw(ArgumentError("arrival for agent_id=$agent_index cannot occur while d_agent_free=true"))
        for raw_departure_id in departure_ids
            departure_index = _normalize_agent_index(bufs, raw_departure_id, "departure")
            departure_index == agent_index &&
                throw(ArgumentError("agent_id=$agent_index cannot arrive and depart in the same sync step"))
        end
    end

    return nothing
end

"""
    _inject_arrivals!(bufs::HybridSyncBuffers, arrival_ids, sim_time; on_arrival! = event -> nothing) -> Vector{EntityArrival}

Convert pending zone entries into DES arrival events and freeze the corresponding agents.
"""
function _inject_arrivals!(bufs::HybridSyncBuffers,
                           arrival_ids::AbstractVector{<:Integer},
                           sim_time::Real;
                           on_arrival! = (_event) -> nothing)
    arrivals = EntityArrival[]
    event_time = Float64(sim_time)
    for raw_agent_id in arrival_ids
        agent_index = _normalize_agent_index(bufs, raw_agent_id, "arrival")
        zone_id = Int(bufs.d_agent_zone[agent_index])
        arrival_event = EntityArrival(UInt64(agent_index), zone_id, event_time)
        bufs.d_agent_in_service[agent_index] = true
        bufs.d_agent_free[agent_index] = false
        push!(arrivals, arrival_event)
        on_arrival!(arrival_event)
    end
    return arrivals
end

"""
    _inject_arrivals!(::LocalSyncTransport, bufs, arrival_ids, sim_time; on_arrival!=...) -> Vector{EntityArrival}

Transport-specialized arrival injection for Tier-1 local transport.
"""
@inline function _inject_arrivals!(::LocalSyncTransport,
                                   bufs::HybridSyncBuffers,
                                   arrival_ids::AbstractVector{<:Integer},
                                   sim_time::Real;
                                   on_arrival! = (_event) -> nothing)
    return _inject_arrivals!(bufs, arrival_ids, sim_time; on_arrival! = on_arrival!)
end

"""
    _apply_departures!(bufs::HybridSyncBuffers, departure_ids) -> Vector{Int}

Unfreeze departed agents and raise one-shot resume flags for the ABM side.
"""
function _apply_departures!(bufs::HybridSyncBuffers,
                            departure_ids::AbstractVector{<:Integer})
    applied_departures = Int[]
    for raw_agent_id in departure_ids
        agent_index = _normalize_agent_index(bufs, raw_agent_id, "departure")
        bufs.d_agent_in_service[agent_index] = false
        bufs.d_agent_free[agent_index] = true
        push!(applied_departures, agent_index)
    end
    empty!(bufs.pending_departures)
    return applied_departures
end

"""
    _apply_departures!(::LocalSyncTransport, bufs, departure_ids) -> Vector{Int}

Transport-specialized departure application for Tier-1 local transport.
"""
@inline _apply_departures!(::LocalSyncTransport,
                           bufs::HybridSyncBuffers,
                           departure_ids::AbstractVector{<:Integer}) =
    _apply_departures!(bufs, departure_ids)

"""
    _consume_agent_free!(bufs::HybridSyncBuffers, agent_id::Integer) -> Bool

Consume a one-shot free flag for a single agent, returning whether a flag was present.
"""
function _consume_agent_free!(bufs::HybridSyncBuffers, agent_id::Integer)
    agent_index = _normalize_agent_index(bufs, agent_id, "consume_agent_free")
    was_free = bufs.d_agent_free[agent_index]
    bufs.d_agent_free[agent_index] = false
    return was_free
end

"""
    sync_step!(bufs::HybridSyncBuffers, st::HybridSyncState, sim_time; cfg=nothing, on_arrival!=event->nothing)
        -> NamedTuple

Execute one CPU-side DES↔ABM sync boundary step:
- scan and clear zone-entry flags,
- inject arrival events,
- apply pending departures,
- update sync diagnostics.
"""
function sync_step!(bufs::HybridSyncBuffers,
                    st::HybridSyncState,
                    sim_time::Real;
                    cfg::Union{Nothing,HybridSyncConfig} = nothing,
                    on_arrival! = (_event) -> nothing)
    return sync_step!(LOCAL_SYNC_TRANSPORT, bufs, st, sim_time; cfg=cfg, on_arrival! = on_arrival!)
end

"""
    sync_step!(transport::AbstractSyncTransport, bufs::HybridSyncBuffers, st::HybridSyncState, sim_time;
               cfg=nothing, on_arrival!=event->nothing) -> NamedTuple

Transport-aware sync boundary step. `LocalSyncTransport` preserves current
Tier-1 behavior; future transports can specialize scan/inject/apply phases.
"""
function sync_step!(transport::AbstractSyncTransport,
                    bufs::HybridSyncBuffers,
                    st::HybridSyncState,
                    sim_time::Real;
                    cfg::Union{Nothing,HybridSyncConfig} = nothing,
                    on_arrival! = (_event) -> nothing)
    transport isa LocalSyncTransport ||
        throw(ArgumentError("sync_step! transport $(typeof(transport)) is not implemented yet"))

    strict_invariants = isnothing(cfg) ? true : cfg.strict_invariants
    arrival_ids = _scan_zone_entries!(transport, bufs)
    departure_ids = bufs.pending_departures

    _assert_invariants!(bufs, arrival_ids, departure_ids; strict_invariants=strict_invariants)

    arrivals = _inject_arrivals!(transport, bufs, arrival_ids, sim_time; on_arrival! = on_arrival!)
    applied_departures = _apply_departures!(transport, bufs, departure_ids)
    _record_sync_step!(st;
        arrivals_injected=length(arrivals),
        departures_applied=length(applied_departures),
        overflow_drops=0,
    )

    return (
        sim_time = Float64(sim_time),
        arrival_ids = arrival_ids,
        departure_ids = applied_departures,
        arrivals = arrivals,
    )
end

"""
    mark_departure!(bufs::HybridSyncBuffers, agent_id; cfg=nothing) -> Bool

Queue a DES completion for application at the next sync boundary.
Returns `true` if the agent was queued, or `false` if the request was dropped by policy.
"""
function mark_departure!(bufs::HybridSyncBuffers,
                         agent_id::Integer;
                         cfg::Union{Nothing,HybridSyncConfig} = nothing)
    return mark_departure!(LOCAL_SYNC_TRANSPORT, bufs, agent_id; cfg=cfg)
end

"""
    mark_departure!(transport::AbstractSyncTransport, bufs::HybridSyncBuffers, agent_id; cfg=nothing) -> Bool

Transport-aware departure queueing. `LocalSyncTransport` preserves current
Tier-1 behavior.
"""
function mark_departure!(transport::AbstractSyncTransport,
                         bufs::HybridSyncBuffers,
                         agent_id::Integer;
                         cfg::Union{Nothing,HybridSyncConfig} = nothing)
    transport isa LocalSyncTransport ||
        throw(ArgumentError("mark_departure! transport $(typeof(transport)) is not implemented yet"))

    agent_index = _normalize_agent_index(bufs, agent_id, "mark_departure")
    if agent_index in bufs.pending_departures
        throw(ArgumentError("duplicate pending departure for agent_id=$agent_index"))
    end

    if !isnothing(cfg) && length(bufs.pending_departures) >= cfg.max_pending_departures
        if cfg.drop_on_overflow
            return false
        end
        throw(ArgumentError("pending departure queue exceeded configured capacity $(cfg.max_pending_departures)"))
    end

    push!(bufs.pending_departures, convert(eltype(bufs.pending_departures), agent_index))
    return true
end
