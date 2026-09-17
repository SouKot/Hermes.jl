"""
    debug.jl

JSON debug output for development and diagnostics.
This is strictly for logging and inspection, never for production wire protocol.
"""

using JSON
# ============================================================================
# JSON Debug Output (Development/Diagnostic Only)
# ============================================================================

"""
    to_debug_json(msg::Message; pretty=true) -> String

Convert a Message to human-readable JSON format.

WARNING: This is for debugging and logging only.
Never use JSON for production wire protocol - use MessagePack instead.

Arguments:
- `msg`: Message to convert
- `pretty`: If true, format with indentation for readability

Returns: JSON string representation
"""
function to_debug_json(msg::Message; pretty=true)::String
    dict = message_to_debug_dict(msg)
    if pretty
        return JSON.json(dict, 2)
    else
        return JSON.json(dict)
    end
end

"""
    log_message_debug(msg::Message; label="") -> Nothing

Print a debug log of the message for development.

Arguments:
- `msg`: Message to log
- `label`: Optional prefix for the log line
"""
function log_message_debug(msg::Message; label="")::Nothing
    env = msg.envelope
    prefix = isempty(label) ? "" : "$label: "
    println("$prefix[$(env.kind)] $(env.message_id) from=$(env.sender) to=$(env.receiver)")
    nothing
end

# ============================================================================
# Helper: Convert Message to Debug Dict
# ============================================================================

function message_to_debug_dict(msg::Message)::Dict{String, Any}
    env = msg.envelope
    
    # Full envelope structure
    base_dict = Dict(
        "envelope_version" => env.envelope_version,
        "message_id" => env.message_id,
        "timestamp" => env.timestamp,
        "timestamp_readable" => Dates.unix2datetime(env.timestamp / 1000),
        "sender" => env.sender,
        "receiver" => env.receiver,
        "kind" => env.kind,
    )
    
    # Add payload
    payload_dict = payload_to_debug_dict(msg.payload)
    merge!(base_dict, payload_dict)
    
    base_dict
end

function payload_to_debug_dict(p::HelloPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "type" => "HelloPayload",
            "protocol_version" => p.protocol_version,
            "runtime_name" => p.runtime_name,
            "runtime_version" => p.runtime_version,
            "capabilities" => p.capabilities,
            "supported_encodings" => p.supported_encodings,
            "preferred_encoding" => p.preferred_encoding,
            "max_snapshot_rate_hz" => p.max_snapshot_rate_hz,
            "snapshot_batch_size" => p.snapshot_batch_size,
            "num_extensions" => length(p.extensions_available),
            "num_abm_models" => length(p.supported_abm_models),
        )
    )
end

function payload_to_debug_dict(p::SnapshotPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "type" => "SnapshotPayload",
            "snapshot_version" => p.snapshot_version,
            "scene_id" => p.scene_id,
            "simulation_time" => p.simulation_time,
            "step_count" => p.step_count,
            "clock_speed" => p.clock_speed,
            "simulation_state" => p.simulation_state,
            "num_elements" => length(p.elements_state),
            "num_entities" => length(p.entities),
            "has_abm_state" => !isnothing(p.abm_state),
            "num_overlays" => length(p.overlays),
            "num_warnings" => length(p.warnings),
            "truncated" => p.truncated,
        )
    )
end

function payload_to_debug_dict(p::DeltaPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "type" => "DeltaPayload",
            "snapshot_version" => p.snapshot_version,
            "scene_id" => p.scene_id,
            "simulation_time" => p.simulation_time,
            "step_count" => p.step_count,
            "parent_message_id" => p.parent_message_id,
            "elements_changed_count" => length(p.elements_changed),
            "entities_added_count" => length(p.entities_added),
            "entities_removed_count" => length(p.entities_removed),
            "entities_updated_count" => length(p.entities_updated),
            "has_abm_delta" => !isnothing(p.abm_state_delta),
            "overlay_updates_count" => length(p.overlay_updates),
        )
    )
end

function payload_to_debug_dict(p::CommandPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "type" => "CommandPayload",
            "command_version" => p.command_version,
            "command_type" => p.command_type,
            "command_action" => get(p.command, "action", ""),
            "scene_id" => p.scene_id,
            "apply_at_time" => p.apply_at_time,
        )
    )
end

function payload_to_debug_dict(p::SceneSpecPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "type" => "SceneSpecPayload",
            "spec_version" => p.spec_version,
            "scene_name" => get(p.scene, "name", ""),
            "num_elements" => length(p.elements),
            "num_connections" => length(p.connections),
            "num_subgraphs" => length(p.subgraphs),
            "num_overlays" => length(p.overlays),
            "has_abm_config" => !isnothing(p.abm_config),
        )
    )
end

function payload_to_debug_dict(p::AckPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "type" => "AckPayload",
            "ack_version" => p.ack_version,
            "acknowledged_message_id" => p.acknowledged_message_id,
            "status" => p.status,
            "details" => p.details,
        )
    )
end

function payload_to_debug_dict(p::ErrorPayload)::Dict{String, Any}
    Dict(
        "payload" => Dict(
            "type" => "ErrorPayload",
            "error_version" => p.error_version,
            "causing_message_id" => p.causing_message_id,
            "error_code" => p.error_code,
            "error_message" => p.error_message,
            "has_error_details" => !isnothing(p.error_details),
            "recoverable" => p.recoverable,
            "recovery_suggestion" => p.recovery_suggestion,
        )
    )
end

# Add Dates to imports
using Dates

# ============================================================================
# Exports
# ============================================================================

export to_debug_json, log_message_debug
