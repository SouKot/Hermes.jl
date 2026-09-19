"""
    envelope.jl

Defines the message envelope structure and all 7 payload types for the Godot-Julia protocol.
"""

"""
    MessageEnvelope

The envelope that wraps every message sent between Julia and Godot.

**Fields**:
- `envelope_version::String` - SemVer for the envelope format (e.g., "1.0")
- `message_id::String` - Unique identifier for this message
- `timestamp::UInt64` - Unix milliseconds for clock synchronization
- `sender::String` - "julia_runtime" or "godot_gui"
- `receiver::String` - "godot_gui", "godot_editor", or "julia_runtime"
- `kind::String` - Message type: "hello", "snapshot", "delta", "command", "scene_spec", "ack", "error"
"""
mutable struct MessageEnvelope
    envelope_version::String
    message_id::String
    timestamp::UInt64
    sender::String
    receiver::String
    kind::String
end

"""Abstract base type for all message payloads."""
abstract type MessagePayload end

"""
    Message{P<:MessagePayload}

A complete message consisting of an envelope and a typed payload. The type
parameter preserves extensibility for future payload types while allowing the
compiler to specialize protocol operations for known payloads.
"""
mutable struct Message{P<:MessagePayload}
    envelope::MessageEnvelope
    payload::P
end

# ============================================================================
# Payload Type Definitions
# ============================================================================

# ============================================================================
# 1. HelloPayload - Handshake on connect
# ============================================================================

"""
    HelloPayload <: MessagePayload

Sent by Julia runtime to Godot on connection.
Establishes protocol version and capabilities.
"""
struct HelloPayload <: MessagePayload
    protocol_version::String
    runtime_name::String
    runtime_version::String
    capabilities::Vector{String}
    supported_encodings::Vector{String}
    preferred_encoding::String
    max_snapshot_rate_hz::UInt32
    snapshot_batch_size::UInt32
    extensions_available::Vector{Dict{String, Any}}
    supported_abm_models::Vector{Dict{String, Any}}
end

# ============================================================================
# 2. SnapshotPayload - Full state update
# ============================================================================

"""
    SnapshotPayload

Sent by Julia runtime to Godot periodically (default 30 Hz).
Contains complete current state of the simulation.
"""
struct SnapshotPayload <: MessagePayload
    snapshot_version::String
    scene_id::String
    simulation_time::Float64
    step_count::UInt64
    clock_speed::Float32
    simulation_state::String  # "running", "paused", "stopped", "error"
    elements_state::Vector{Dict{String, Any}}
    entities::Vector{Dict{String, Any}}
    abm_state::Union{Dict{String, Any}, Nothing}
    overlays::Vector{Dict{String, Any}}
    warnings::Vector{String}
    truncated::Bool
end

function _string_dict(value::AbstractDict)
    return Dict{String, Any}(string(key) => item for (key, item) in value)
end

function _dict_vector(value::AbstractVector)
    return [_string_dict(item) for item in value]
end

function _dict_vector(value::AbstractDict)
    return [Dict{String, Any}("id" => string(key), "value" => item)
            for (key, item) in value]
end

function SnapshotPayload(;
    snapshot_version,
    scene_id,
    simulation_time,
    step_count,
    clock_speed,
    simulation_state,
    elements_state,
    entities,
    abm_state,
    overlays,
    warnings,
    truncated
)
    return SnapshotPayload(
        String(snapshot_version), String(scene_id), Float64(simulation_time),
        UInt64(step_count), Float32(clock_speed), String(simulation_state),
        _dict_vector(elements_state), _dict_vector(entities),
        isnothing(abm_state) ? nothing : _string_dict(abm_state),
        _dict_vector(overlays), String.(warnings), Bool(truncated)
    )
end

# ============================================================================
# 3. DeltaPayload - Incremental update
# ============================================================================

"""
    DeltaPayload

Sent by Julia runtime to Godot between full snapshots.
Contains only changes since last snapshot (bandwidth optimization).
"""
struct DeltaPayload <: MessagePayload
    snapshot_version::String
    scene_id::String
    simulation_time::Float64
    step_count::UInt64
    parent_message_id::String
    elements_changed::Vector{Dict{String, Any}}
    entities_added::Vector{Dict{String, Any}}
    entities_removed::Vector{String}
    entities_updated::Vector{Dict{String, Any}}
    abm_state_delta::Union{Dict{String, Any}, Nothing}
    overlay_updates::Vector{Dict{String, Any}}
end

# ============================================================================
# 4. CommandPayload - Control and parameter updates
# ============================================================================

"""
    CommandPayload

Sent by Godot to Julia to control simulation.
Handles play/pause/step/reset/speed and scene edits.
"""
struct CommandPayload <: MessagePayload
    command_version::String
    command_type::String  # "control", "model_selection", "parameter_update", "scene_edit"
    command::Dict{String, Any}
    scene_id::String
    apply_at_time::Union{Float64, Nothing}
end

function CommandPayload(; command_version, command_type, command, scene_id, apply_at_time)
    return CommandPayload(
        String(command_version), String(command_type), _string_dict(command),
        String(scene_id), isnothing(apply_at_time) ? nothing : Float64(apply_at_time)
    )
end

# ============================================================================
# 5. SceneSpecPayload - Scene specification
# ============================================================================

"""
    SceneSpecPayload

Sent in either direction for scene editing or archival.
Contains full SceneSpec v1 content.
"""
struct SceneSpecPayload <: MessagePayload
    spec_version::String
    scene::Dict{String, Any}
    simulation::Dict{String, Any}
    abm_config::Union{Dict{String, Any}, Nothing}
    spatial::Union{Dict{String, Any}, Nothing}
    elements::Vector{Dict{String, Any}}
    connections::Vector{Dict{String, Any}}
    subgraphs::Vector{Dict{String, Any}}
    overlays::Vector{Dict{String, Any}}
    validation_metadata::Dict{String, Any}
    extensions::Dict{String, Any}

    function SceneSpecPayload(
        spec_version::String,
        scene::AbstractDict,
        simulation::AbstractDict,
        abm_config::Union{AbstractDict, Nothing},
        spatial::Union{AbstractDict, Nothing},
        elements::AbstractVector,
        connections::AbstractVector,
        subgraphs::AbstractVector,
        overlays::AbstractVector,
        validation_metadata::AbstractDict,
        extensions::AbstractDict = Dict{String, Any}()
    )
        _scene = Dict{String, Any}(string(k) => v for (k, v) in scene)
        _sim = Dict{String, Any}(string(k) => v for (k, v) in simulation)
        _abm = abm_config === nothing ? nothing : Dict{String, Any}(string(k) => v for (k, v) in abm_config)
        _spatial = spatial === nothing ? nothing : Dict{String, Any}(string(k) => v for (k, v) in spatial)
        _elem = [Dict{String, Any}(string(k) => v for (k, v) in e) for e in elements]
        _conn = [Dict{String, Any}(string(k) => v for (k, v) in c) for c in connections]
        _sub = [Dict{String, Any}(string(k) => v for (k, v) in s) for s in subgraphs]
        _over = [Dict{String, Any}(string(k) => v for (k, v) in o) for o in overlays]
        _val = Dict{String, Any}(string(k) => v for (k, v) in validation_metadata)
        _ext = Dict{String, Any}(string(k) => v for (k, v) in extensions)
        return new(spec_version, _scene, _sim, _abm, _spatial, _elem, _conn, _sub, _over, _val, _ext)
    end

    # Backward-compatible 9-argument constructor
    function SceneSpecPayload(
        spec_version::String,
        scene::AbstractDict,
        simulation::AbstractDict,
        abm_config::Union{AbstractDict, Nothing},
        elements::AbstractVector,
        connections::AbstractVector,
        subgraphs::AbstractVector,
        overlays::AbstractVector,
        validation_metadata::AbstractDict
    )
        return SceneSpecPayload(
            spec_version, scene, simulation, abm_config, nothing,
            elements, connections, subgraphs, overlays, validation_metadata,
            Dict{String, Any}()
        )
    end
end

# ============================================================================
# 6. AckPayload - Acknowledgment
# ============================================================================

"""
    AckPayload

Sent by either side to acknowledge successful receipt and processing.
"""
struct AckPayload <: MessagePayload
    ack_version::String
    acknowledged_message_id::String
    status::String  # "accepted", "pending", "queued"
    details::String
end

# ============================================================================
# 7. ErrorPayload - Error response
# ============================================================================

"""
    ErrorPayload

Sent by either side to report failure or invalid request.
"""
struct ErrorPayload <: MessagePayload
    error_version::String
    causing_message_id::String
    error_code::String  # "VALIDATION_FAILED", "UNSUPPORTED_MODEL", etc.
    error_message::String
    error_details::Union{Dict{String, Any}, Nothing}
    recoverable::Bool
    recovery_suggestion::String
end

# ============================================================================
# Helper constructors
# ============================================================================

"""
    create_hello(; kwargs...) -> Message

Helper to create a Hello message from Julia runtime.
"""
function create_hello(;
    protocol_version="1.0.0",
    runtime_name="SimViz",
    runtime_version="0.1.0",
    capabilities=["snapshot_streaming", "delta_updates", "model_selection", "scene_editing", "binary_encoding"],
    supported_encodings=["json", "messagepack"],
    preferred_encoding="messagepack",
    max_snapshot_rate_hz=UInt32(30),
    snapshot_batch_size=UInt32(100),
    extensions_available=[],
    supported_abm_models=[],
    message_id="msg_hello_$(UUID4())",
)
    env = MessageEnvelope(
        "1.0",
        message_id,
        UInt64(floor(time() * 1000)),
        "julia_runtime",
        "godot_gui",
        "hello"
    )
    payload = HelloPayload(
        protocol_version,
        runtime_name,
        runtime_version,
        capabilities,
        supported_encodings,
        preferred_encoding,
        max_snapshot_rate_hz,
        snapshot_batch_size,
        extensions_available,
        supported_abm_models
    )
    Message(env, payload)
end

"""
    create_ack(acknowledged_message_id::String; status="accepted", details="") -> Message

Helper to create an Ack message.
"""
function create_ack(acknowledged_message_id::String; status="accepted", details="", message_id="msg_ack_$(UUID4())")
    env = MessageEnvelope(
        "1.0",
        message_id,
        UInt64(floor(time() * 1000)),
        "julia_runtime",
        "godot_gui",
        "ack"
    )
    payload = AckPayload(
        "1.0.0",
        acknowledged_message_id,
        status,
        details
    )
    Message(env, payload)
end

"""
    create_error(causing_message_id::String, error_code::String, error_message::String; 
                 error_details=nothing, recoverable=true, recovery_suggestion="") -> Message

Helper to create an Error message.
"""
function create_error(
    causing_message_id::String,
    error_code::String,
    error_message::String;
    error_details=nothing,
    recoverable=true,
    recovery_suggestion="",
    message_id="msg_error_$(UUID4())"
)
    env = MessageEnvelope(
        "1.0",
        message_id,
        UInt64(floor(time() * 1000)),
        "julia_runtime",
        "godot_gui",
        "error"
    )
    payload = ErrorPayload(
        "1.0.0",
        causing_message_id,
        error_code,
        error_message,
        error_details,
        recoverable,
        recovery_suggestion
    )
    Message(env, payload)
end

# Re-export UUID4 for convenience
using UUIDs
const UUID4 = UUIDs.uuid4
