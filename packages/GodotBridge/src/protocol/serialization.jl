"""
    serialization.jl

MessagePack serialization for all Protocol v1 message types.
Primary production serialization format (JSON is debug-only).
"""

using MsgPack
using Dates

mutable struct MessagePackWorkspace
    io::IOBuffer
end

MessagePackWorkspace(sizehint::Int=64 * 1024) =
    MessagePackWorkspace(IOBuffer(UInt8[]; sizehint=sizehint, append=true))

# ============================================================================
# MessagePack Encoding Functions
# ============================================================================

"""
    encode_messagepack(msg::Message) -> Vector{UInt8}

Serialize a Message to MessagePack binary format.
This is the primary serialization used for all wire traffic.

**Returns**: Compact binary representation suitable for WebSocket transmission.
"""
function encode_messagepack(msg::Message)::Vector{UInt8}
    # Convert message to dict for MessagePack encoding
    msg_dict = message_to_dict(msg)
    return pack(msg_dict)
end

"""Encode using a reusable IO buffer for high-frequency updates."""
function encode_messagepack!(workspace::MessagePackWorkspace, msg::Message)::Vector{UInt8}
    seekstart(workspace.io)
    truncate(workspace.io, 0)
    MsgPack.pack(workspace.io, message_to_dict(msg))
    return take!(workspace.io)
end

"""
    decode_messagepack(data::Vector{UInt8}) -> Message

Deserialize a MessagePack binary to a Message struct.

**Arguments**:
- `data`: Raw bytes from WebSocket

**Returns**: Parsed Message with envelope and payload

**Throws**: MessagePackError if data is invalid
"""
function decode_messagepack(data::Vector{UInt8})::Message
    try
        msg_dict = normalize_decoded_value(unpack(data))
        return dict_to_message(msg_dict)
    catch e
        error("Failed to deserialize MessagePack: $(e)")
    end
end

function normalize_decoded_value(value::AbstractDict)
    return Dict{String, Any}(
        string(key) => normalize_decoded_value(item)
        for (key, item) in value
    )
end

function normalize_decoded_value(value::AbstractVector)
    return [normalize_decoded_value(item) for item in value]
end

normalize_decoded_value(value) = value

# ============================================================================
# Helper: Message to Dict (for encoding)
# ============================================================================

function message_to_dict(msg::Message)::Dict{String, Any}
    env = msg.envelope
    
    # Common envelope
    base_dict = Dict(
        "envelope_version" => env.envelope_version,
        "message_id" => env.message_id,
        "timestamp" => env.timestamp,
        "sender" => env.sender,
        "receiver" => env.receiver,
        "kind" => env.kind,
    )
    
    # Add payload based on type
    payload_dict = payload_to_dict(msg.payload)
    merge!(base_dict, payload_dict)
    
    base_dict
end

function payload_to_dict(p::HelloPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "protocol_version" => p.protocol_version,
            "runtime_name" => p.runtime_name,
            "runtime_version" => p.runtime_version,
            "capabilities" => p.capabilities,
            "supported_encodings" => p.supported_encodings,
            "preferred_encoding" => p.preferred_encoding,
            "max_snapshot_rate_hz" => p.max_snapshot_rate_hz,
            "snapshot_batch_size" => p.snapshot_batch_size,
            "extensions_available" => p.extensions_available,
            "supported_abm_models" => p.supported_abm_models,
        )
    )
end

function payload_to_dict(p::SnapshotPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "snapshot_version" => p.snapshot_version,
            "scene_id" => p.scene_id,
            "simulation_time" => p.simulation_time,
            "step_count" => p.step_count,
            "clock_speed" => p.clock_speed,
            "simulation_state" => p.simulation_state,
            "elements_state" => p.elements_state,
            "entities" => p.entities,
            "abm_state" => p.abm_state,
            "overlays" => p.overlays,
            "warnings" => p.warnings,
            "truncated" => p.truncated,
        )
    )
end

function payload_to_dict(p::DeltaPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "snapshot_version" => p.snapshot_version,
            "scene_id" => p.scene_id,
            "simulation_time" => p.simulation_time,
            "step_count" => p.step_count,
            "parent_message_id" => p.parent_message_id,
            "elements_changed" => p.elements_changed,
            "entities_added" => p.entities_added,
            "entities_removed" => p.entities_removed,
            "entities_updated" => p.entities_updated,
            "abm_state_delta" => p.abm_state_delta,
            "overlay_updates" => p.overlay_updates,
        )
    )
end

function payload_to_dict(p::CommandPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "command_version" => p.command_version,
            "command_type" => p.command_type,
            "command" => p.command,
            "scene_id" => p.scene_id,
            "apply_at_time" => p.apply_at_time,
        )
    )
end

function payload_to_dict(p::SceneSpecPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "spec_version" => p.spec_version,
            "scene" => p.scene,
            "simulation" => p.simulation,
            "abm_config" => p.abm_config,
            "elements" => p.elements,
            "connections" => p.connections,
            "subgraphs" => p.subgraphs,
            "overlays" => p.overlays,
            "validation_metadata" => p.validation_metadata,
        )
    )
end

function payload_to_dict(p::AckPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "ack_version" => p.ack_version,
            "acknowledged_message_id" => p.acknowledged_message_id,
            "status" => p.status,
            "details" => p.details,
        )
    )
end

function payload_to_dict(p::ErrorPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "error_version" => p.error_version,
            "causing_message_id" => p.causing_message_id,
            "error_code" => p.error_code,
            "error_message" => p.error_message,
            "error_details" => p.error_details,
            "recoverable" => p.recoverable,
            "recovery_suggestion" => p.recovery_suggestion,
        )
    )
end

# ============================================================================
# Helper: Dict to Message (for decoding)
# ============================================================================

function dict_to_message(d::Dict{String, Any})::Message
    # Extract envelope
    env = MessageEnvelope(
        get(d, "envelope_version", "1.0"),
        get(d, "message_id", ""),
        get(d, "timestamp", UInt64(0)),
        get(d, "sender", ""),
        get(d, "receiver", ""),
        get(d, "kind", ""),
    )
    
    # Extract and parse payload
    payload_data = get(d, "payload", Dict())
    kind = env.kind
    
    payload = if kind == "hello"
        HelloPayload(
            get(payload_data, "protocol_version", ""),
            get(payload_data, "runtime_name", ""),
            get(payload_data, "runtime_version", ""),
            get(payload_data, "capabilities", String[]),
            get(payload_data, "supported_encodings", String[]),
            get(payload_data, "preferred_encoding", ""),
            UInt32(get(payload_data, "max_snapshot_rate_hz", 30)),
            UInt32(get(payload_data, "snapshot_batch_size", 100)),
            get(payload_data, "extensions_available", Dict{String, Any}[]),
            get(payload_data, "supported_abm_models", Dict{String, Any}[]),
        )
    elseif kind == "snapshot"
        SnapshotPayload(
            get(payload_data, "snapshot_version", ""),
            get(payload_data, "scene_id", ""),
            Float64(get(payload_data, "simulation_time", 0.0)),
            UInt64(get(payload_data, "step_count", 0)),
            Float32(get(payload_data, "clock_speed", 1.0)),
            get(payload_data, "simulation_state", "stopped"),
            get(payload_data, "elements_state", Dict{String, Any}[]),
            get(payload_data, "entities", Dict{String, Any}[]),
            get(payload_data, "abm_state", nothing),
            get(payload_data, "overlays", Dict{String, Any}[]),
            get(payload_data, "warnings", String[]),
            get(payload_data, "truncated", false),
        )
    elseif kind == "delta"
        DeltaPayload(
            get(payload_data, "snapshot_version", ""),
            get(payload_data, "scene_id", ""),
            Float64(get(payload_data, "simulation_time", 0.0)),
            UInt64(get(payload_data, "step_count", 0)),
            get(payload_data, "parent_message_id", ""),
            get(payload_data, "elements_changed", Dict{String, Any}[]),
            get(payload_data, "entities_added", Dict{String, Any}[]),
            get(payload_data, "entities_removed", String[]),
            get(payload_data, "entities_updated", Dict{String, Any}[]),
            get(payload_data, "abm_state_delta", nothing),
            get(payload_data, "overlay_updates", Dict{String, Any}[]),
        )
    elseif kind == "command"
        CommandPayload(
            get(payload_data, "command_version", ""),
            get(payload_data, "command_type", ""),
            get(payload_data, "command", Dict{String, Any}()),
            get(payload_data, "scene_id", ""),
            get(payload_data, "apply_at_time", nothing),
        )
    elseif kind == "scene_spec"
        SceneSpecPayload(
            get(payload_data, "spec_version", ""),
            get(payload_data, "scene", Dict{String, Any}()),
            get(payload_data, "simulation", Dict{String, Any}()),
            get(payload_data, "abm_config", nothing),
            get(payload_data, "elements", Dict{String, Any}[]),
            get(payload_data, "connections", Dict{String, Any}[]),
            get(payload_data, "subgraphs", Dict{String, Any}[]),
            get(payload_data, "overlays", Dict{String, Any}[]),
            get(payload_data, "validation_metadata", Dict{String, Any}()),
        )
    elseif kind == "ack"
        AckPayload(
            get(payload_data, "ack_version", ""),
            get(payload_data, "acknowledged_message_id", ""),
            get(payload_data, "status", ""),
            get(payload_data, "details", ""),
        )
    elseif kind == "error"
        ErrorPayload(
            get(payload_data, "error_version", ""),
            get(payload_data, "causing_message_id", ""),
            get(payload_data, "error_code", ""),
            get(payload_data, "error_message", ""),
            get(payload_data, "error_details", nothing),
            get(payload_data, "recoverable", false),
            get(payload_data, "recovery_suggestion", ""),
        )
    else
        error("Unknown message kind: $kind")
    end
    
    Message(env, payload)
end

# ============================================================================
# Version Compatibility
# ============================================================================

"""
    check_protocol_version(version::String) -> Bool

Validate that the protocol version is supported.
Currently supports 1.0 and 1.x.
"""
function check_protocol_version(version::String)::Bool
    # Support semantic versioning
    parts = split(version, ".")
    major = try
        parse(Int, parts[1])
    catch
        0
    end
    major == 1  # Only accept version 1.x
end

# ============================================================================
# Exports
# ============================================================================

export encode_messagepack, decode_messagepack, check_protocol_version
