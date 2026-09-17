"""Typed Protocol v1 full-snapshot transport.

This additive path keeps the existing SnapshotPayload and dictionary/debug APIs
unchanged while allowing production callers to encode typed simulation state
without first constructing nested Dict{String,Any} trees.
"""
struct DirectSnapshotElement
    element_id::String
    element_kind::String
    occupancy::UInt32
    custom_metrics::Dict{String, Any}
end

struct DirectSnapshotEntity
    id::String
    kind::String
    current_location::String
    arrival_time::Float64
    trajectory_2d::Vector{Vector{Float64}}
    properties::Dict{String, Any}
end

struct DirectSnapshotPayload
    snapshot_version::String
    scene_id::String
    simulation_time::Float64
    step_count::UInt64
    clock_speed::Float32
    simulation_state::String
    elements_state::Vector{DirectSnapshotElement}
    entities::Vector{DirectSnapshotEntity}
    abm_state::Any
    overlays::Vector{Dict{String, Any}}
    warnings::Vector{String}
    truncated::Bool
end

struct DirectSnapshotMessage
    envelope_version::String
    message_id::String
    timestamp::UInt64
    sender::String
    receiver::String
    kind::String
    payload::DirectSnapshotPayload
end

MsgPack.msgpack_type(::Type{DirectSnapshotElement}) = MsgPack.StructType()
MsgPack.msgpack_type(::Type{DirectSnapshotEntity}) = MsgPack.StructType()
MsgPack.msgpack_type(::Type{DirectSnapshotPayload}) = MsgPack.StructType()
MsgPack.msgpack_type(::Type{DirectSnapshotMessage}) = MsgPack.StructType()

function direct_snapshot_element(element::ElementState)
    return DirectSnapshotElement(
        element.id, element.element_type, element.occupancy, element.custom_metrics
    )
end

function direct_snapshot_entity(entity::EntitySnapshot)
    return DirectSnapshotEntity(
        entity.id, entity.entity_type, entity.current_location,
        entity.arrival_time, entity.trajectory_2d, entity.properties
    )
end

function direct_snapshot_payload(
    scene_id::String,
    simulation_time::Float64,
    step_count::UInt64,
    elements::AbstractVector{<:ElementState},
    entities::AbstractVector{<:EntitySnapshot};
    snapshot_version::String="1.0.0",
    clock_speed::Float32=1.0f0,
    simulation_state::String="running",
    abm_state=nothing,
    overlays::Vector{Dict{String, Any}}=Dict{String, Any}[],
    warnings::Vector{String}=String[],
    truncated::Bool=false
)
    return DirectSnapshotPayload(
        snapshot_version, scene_id, simulation_time, step_count, clock_speed,
        simulation_state, DirectSnapshotElement[direct_snapshot_element(element)
            for element in elements],
        DirectSnapshotEntity[direct_snapshot_entity(entity) for entity in entities],
        abm_state, overlays, warnings, truncated
    )
end

function direct_snapshot_payload(snapshot::SnapshotPayload)
    elements = DirectSnapshotElement[
        DirectSnapshotElement(
            String(get(element, "element_id", get(element, "id", ""))),
            String(get(element, "element_kind", get(element, "kind", ""))),
            UInt32(get(element, "occupancy", 0)),
            Dict{String, Any}(get(element, "custom_metrics", Dict{String, Any}()))
        ) for element in snapshot.elements_state
    ]
    entities = DirectSnapshotEntity[
        DirectSnapshotEntity(
            String(get(entity, "id", "")), String(get(entity, "kind", "")),
            String(get(entity, "current_location", "")),
            Float64(get(entity, "arrival_time", 0.0)),
            Vector{Vector{Float64}}(get(entity, "trajectory_2d", Vector{Vector{Float64}}())),
            Dict{String, Any}(get(entity, "properties", Dict{String, Any}()))
        ) for entity in snapshot.entities
    ]
    return DirectSnapshotPayload(
        snapshot.snapshot_version, snapshot.scene_id, snapshot.simulation_time,
        snapshot.step_count, snapshot.clock_speed, snapshot.simulation_state,
        elements, entities, snapshot.abm_state, snapshot.overlays,
        snapshot.warnings, snapshot.truncated
    )
end

function encode_direct_snapshot(
    payload::DirectSnapshotPayload;
    message_id::String="direct-snapshot",
    timestamp::UInt64=UInt64(floor(time() * 1000)),
    sender::String="julia_runtime",
    receiver::String="godot_gui"
)::Vector{UInt8}
    return pack(DirectSnapshotMessage(
        "1.0", message_id, timestamp, sender, receiver, "snapshot", payload
    ))
end

function encode_direct_snapshot(
    scene_id::String,
    simulation_time::Float64,
    step_count::UInt64,
    elements::AbstractVector{<:ElementState},
    entities::AbstractVector{<:EntitySnapshot};
    kwargs...
)::Vector{UInt8}
    return encode_direct_snapshot(direct_snapshot_payload(
        scene_id, simulation_time, step_count, elements, entities; kwargs...
    ))
end

function encode_direct_snapshot(snapshot::SnapshotPayload; kwargs...)
    return encode_direct_snapshot(direct_snapshot_payload(snapshot); kwargs...)
end

export DirectSnapshotElement, DirectSnapshotEntity, DirectSnapshotPayload
export DirectSnapshotMessage, direct_snapshot_element, direct_snapshot_entity
export direct_snapshot_payload, encode_direct_snapshot
