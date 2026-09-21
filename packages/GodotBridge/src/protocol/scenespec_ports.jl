# ============================================================================
# SceneSpec Port Protocol Registry & Compatibility Engine (Phase 7D-04)
#
# Provides extensible port protocol definitions, dynamic registration,
# directionality semantics, and connection cardinality verification.
# ============================================================================

"""
    PortProtocolDefinition

Specification of a port communication protocol.
- `kind`: The unique protocol identifier symbol (e.g. `:flow`, `:metric`, `:signal`)
- `allowed_targets`: Set of protocol symbols this protocol is permitted to connect to
- `allow_bidirectional`: Whether links with this protocol can transmit bidirectionally
- `description`: Human-readable protocol documentation
"""
struct PortProtocolDefinition
    kind::Symbol
    allowed_targets::Set{Symbol}
    allow_bidirectional::Bool
    description::String
end

# ─────────────────────────────────────────────────────────────────────────────
# Global Port Protocol Registry
# ─────────────────────────────────────────────────────────────────────────────

const _PORT_REGISTRY_LOCK = ReentrantLock()
const _PORT_REGISTRY = Dict{Symbol, PortProtocolDefinition}()

"""
    _init_default_port_protocols!()

Initializes the default core port protocols for discrete-event and agent-based modeling.
"""
function _init_default_port_protocols!()
    lock(_PORT_REGISTRY_LOCK) do
        empty!(_PORT_REGISTRY)
        _PORT_REGISTRY[:flow] = PortProtocolDefinition(
            :flow,
            Set{Symbol}([:flow]),
            false,
            "Discrete entity/item flow link between process elements"
        )
        _PORT_REGISTRY[:metric] = PortProtocolDefinition(
            :metric,
            Set{Symbol}([:metric, :signal]),
            false,
            "Numerical or scalar telemetry and KPI telemetry reporting stream"
        )
        _PORT_REGISTRY[:signal] = PortProtocolDefinition(
            :signal,
            Set{Symbol}([:signal, :control]),
            false,
            "Discrete or continuous control signal communication"
        )
        _PORT_REGISTRY[:control] = PortProtocolDefinition(
            :control,
            Set{Symbol}([:control, :signal]),
            false,
            "Supervisory control or actuation command link"
        )
        _PORT_REGISTRY[:event] = PortProtocolDefinition(
            :event,
            Set{Symbol}([:event]),
            false,
            "Asynchronous discrete event trigger or notification"
        )
    end
    return nothing
end

# Auto-initialize on file load
_init_default_port_protocols!()

"""
    register_port_protocol!(kind::Symbol, allowed_targets; bidirectional::Bool=false, description::String="")

Registers or overrides a port protocol in the global registry.
Allows domain extensions (e.g. `:fluid`, `:ros_topic`, `:power_bus`).
"""
function register_port_protocol!(
    kind::Symbol,
    allowed_targets::Union{Set{Symbol}, Vector{Symbol}, NTuple{N, Symbol} where N};
    bidirectional::Bool=false,
    description::String=""
)
    targets_set = Set{Symbol}(allowed_targets)
    lock(_PORT_REGISTRY_LOCK) do
        _PORT_REGISTRY[kind] = PortProtocolDefinition(kind, targets_set, bidirectional, description)
    end
    return nothing
end

"""
    get_port_protocol(kind::Symbol)::Union{PortProtocolDefinition, Nothing}

Retrieves the protocol definition for `kind`, or `nothing` if unregistered.
"""
function get_port_protocol(kind::Symbol)::Union{PortProtocolDefinition, Nothing}
    lock(_PORT_REGISTRY_LOCK) do
        return get(_PORT_REGISTRY, kind, nothing)
    end
end

"""
    list_port_protocols()::Vector{Symbol}

Returns a sorted list of all currently registered protocol kind symbols.
"""
function list_port_protocols()::Vector{Symbol}
    lock(_PORT_REGISTRY_LOCK) do
        return sort(collect(keys(_PORT_REGISTRY)))
    end
end

"""
    reset_port_protocols!()

Resets the registry to its default built-in protocols.
Useful for restoring clean test states.
"""
function reset_port_protocols!()
    _init_default_port_protocols!()
end

"""
    is_connection_compatible(src_kind::Symbol, tgt_kind::Symbol)::Bool

Checks if a connection from a source port with protocol `src_kind` is compatible
with a target port with protocol `tgt_kind`.
If `src_kind` is registered, checks `tgt_kind in definition.allowed_targets`.
If target is registered and permits bidirectional, also checks reverse.
If both are unregistered, returns `src_kind == tgt_kind` as fallback.
"""
function is_connection_compatible(src_kind::Symbol, tgt_kind::Symbol)::Bool
    src_proto = get_port_protocol(src_kind)
    tgt_proto = get_port_protocol(tgt_kind)

    if src_proto !== nothing
        if tgt_kind in src_proto.allowed_targets
            return true
        end
    end

    if tgt_proto !== nothing && tgt_proto.allow_bidirectional
        if src_kind in tgt_proto.allowed_targets
            return true
        end
    end

    # Fallback for unregistered custom protocols: equal symbols match
    if src_proto === nothing && tgt_proto === nothing
        return src_kind == tgt_kind
    end

    return false
end

"""
    check_cardinality(connection_count::Int, min_conn::Int, max_conn::Int)::Bool

Validates whether `connection_count` satisfies the range bounds `[min_conn, max_conn]`.
A negative `max_conn` (e.g. -1) signifies unlimited capacity.
"""
function check_cardinality(connection_count::Int, min_conn::Int, max_conn::Int)::Bool
    if connection_count < min_conn
        return false
    end
    if max_conn >= 0 && connection_count > max_conn
        return false
    end
    return true
end

"""
    check_port_cardinality(connection_count::Int, cardinality::Symbol)::Bool

Validates standard cardinality symbols (`:one` or `:many`).
- `:one`: at most 1 connection
- `:many`: 0 or more connections
"""
function check_port_cardinality(connection_count::Int, cardinality::Symbol)::Bool
    if cardinality == :one
        return connection_count <= 1
    elseif cardinality == :many
        return connection_count >= 0
    end
    # Default fallback: allow if non-negative
    return connection_count >= 0
end

