"""Typed MessagePack representation for allocation-light dirty deltas.

This is an optional transport path. It preserves Protocol v1 field names while
avoiding the intermediate nested Dict tree used by the generic encoder.
"""
struct DirectElementDelta
    element_id::String
    change_type::String
    occupancy_after::Union{UInt32, Nothing}
    custom_metrics::Union{Dict{String, Any}, Nothing}
end

struct DirectAddedEntity
    entity_id::String
    change_type::String
    current_location::String
    trajectory_segment::Union{Vector{Vector{Float64}}, Nothing}
end

struct DirectUpdatedEntity
    entity_id::String
    change_type::String
    properties_changed::Dict{String, Any}
end

struct DirectDeltaPayload
    snapshot_version::String
    scene_id::String
    simulation_time::Float64
    step_count::UInt64
    parent_message_id::String
    elements_changed::Vector{DirectElementDelta}
    entities_added::Vector{DirectAddedEntity}
    entities_removed::Vector{String}
    entities_updated::Vector{DirectUpdatedEntity}
    abm_state_delta::Union{Dict{String, Any}, Nothing}
    overlay_updates::Vector{Dict{String, Any}}
end

struct DirectDeltaMessage
    envelope_version::String
    message_id::String
    timestamp::UInt64
    sender::String
    receiver::String
    kind::String
    payload::DirectDeltaPayload
end

MsgPack.msgpack_type(::Type{DirectElementDelta}) = MsgPack.StructType()
MsgPack.msgpack_type(::Type{DirectAddedEntity}) = MsgPack.StructType()
MsgPack.msgpack_type(::Type{DirectUpdatedEntity}) = MsgPack.StructType()
MsgPack.msgpack_type(::Type{DirectDeltaPayload}) = MsgPack.StructType()
MsgPack.msgpack_type(::Type{DirectDeltaMessage}) = MsgPack.StructType()

function encode_direct_delta(
    payload::DirectDeltaPayload;
    message_id::String="direct-delta",
    timestamp::UInt64=UInt64(floor(time() * 1000)),
    sender::String="julia_runtime",
    receiver::String="godot_gui"
)::Vector{UInt8}
    return pack(DirectDeltaMessage(
        "1.0", message_id, timestamp, sender, receiver, "delta", payload
    ))
end

export DirectElementDelta, DirectAddedEntity, DirectUpdatedEntity
export DirectDeltaPayload, DirectDeltaMessage, encode_direct_delta
