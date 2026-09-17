"""
    snapshot_builder.jl

Build Snapshot messages from simulation engine state.
Converts DES elements, entities, and ABM state into SnapshotPayload.
"""

using Dates

# ============================================================================
# Snapshot Builder Interface
# ============================================================================

"""
    SimulationState

Abstract interface for simulation state that can be converted to a Snapshot.
Provides access to simulation time, step count, clock speed, element state,
entity state, and optional ABM state.
"""
abstract type SimulationState end

"""
    ElementState

Represents the state of a single simulation element.
"""
mutable struct ElementState
    id::String
    element_type::String  # "queue", "server", "source", "sink", etc.
    occupancy::UInt32
    custom_metrics::Dict{String, Any}
end

"""
    EntitySnapshot

Represents a single entity in the simulation.
"""
mutable struct EntitySnapshot
    id::String
    entity_type::String
    current_location::String  # Element ID
    arrival_time::Float64
    trajectory_2d::Vector{Vector{Float64}}  # [[x1, y1], [x2, y2], ...]
    properties::Dict{String, Any}
end

"""
    ABMStateSnapshot

Represents the state of the ABM (agent-based model) subsystem.
"""
mutable struct ABMStateSnapshot
    crowd_model_active::String
    num_agents::UInt32
    agent_positions::Union{Vector{Float32}, String}  # Vector or base64 string
    agent_velocities::Union{Vector{Float32}, String}  # Vector or base64 string
    crowd_density_grid::Union{Vector{UInt8}, String, Nothing}  # Vector or base64 string
    crowd_heatmap::Union{Nothing, Dict{String, Any}}
end

# ============================================================================
# Snapshot Builder Functions
# ============================================================================

"""
    build_snapshot(args...) -> SnapshotPayload

Build a complete SnapshotPayload from simulation state components.

Arguments: scene_id, simulation_time, step_count, clock_speed, simulation_state,
elements_state, entities, abm_state, overlays, warnings, truncated

Returns: SnapshotPayload ready for transmission
"""
function build_snapshot(
    scene_id::String,
    simulation_time::Float64,
    step_count::UInt64,
    clock_speed::Float32=1.0f0,
    simulation_state::String="running",
    elements_state::Vector{ElementState}=ElementState[],
    entities::Vector{EntitySnapshot}=EntitySnapshot[],
    abm_state::Union{ABMStateSnapshot, Nothing}=nothing,
    overlays::Vector{Dict{String, Any}}=Dict{String, Any}[],
    warnings::Vector{String}=String[],
    truncated::Bool=false
)::SnapshotPayload

    # Convert ElementState objects to Dicts
    elements_dicts = [element_to_dict(e) for e in elements_state]
    
    # Convert EntitySnapshot objects to Dicts
    entities_dicts = [entity_to_dict(e) for e in entities]
    
    # Convert ABMStateSnapshot if present
    abm_dict = isnothing(abm_state) ? nothing : abm_to_dict(abm_state)
    
    SnapshotPayload(
        "1.0.0",  # snapshot_version
        scene_id,
        simulation_time,
        step_count,
        clock_speed,
        simulation_state,
        elements_dicts,
        entities_dicts,
        abm_dict,
        overlays,
        warnings,
        truncated
    )
end

"""
    create_hello_message_from_simulation(
        runtime_version::String="0.1.0",
        capabilities::Vector{String}=[...],
        extensions_available::Vector{Dict}=[],
        supported_abm_models::Vector{Dict}=[]
    ) -> Message

Create a Hello message for the WebSocket protocol handshake.
"""
function create_hello_message_from_simulation(;
    runtime_version::String="0.1.0",
    capabilities::Vector{String}=[
        "snapshot_streaming",
        "delta_updates",
        "model_selection",
        "scene_editing",
        "binary_encoding"
    ],
    extensions_available::Vector{Dict{String, Any}}=[],
    supported_abm_models::Vector{Dict{String, Any}}=[],
)::Message
    
    env = MessageEnvelope(
        "1.0",
        "msg_hello_$(string(time()))",
        UInt64(floor(time() * 1000)),
        "julia_runtime",
        "godot_gui",
        "hello"
    )
    
    payload = HelloPayload(
        "1.0.0",
        "SimViz",
        runtime_version,
        capabilities,
        ["json", "messagepack"],
        "messagepack",
        UInt32(30),  # max_snapshot_rate_hz
        UInt32(100),  # snapshot_batch_size
        extensions_available,
        supported_abm_models
    )
    
    Message(env, payload)
end

"""
    wrap_snapshot_in_message(snapshot::SnapshotPayload) -> Message

Wrap a SnapshotPayload in a Message envelope with proper headers.
"""
function wrap_snapshot_in_message(snapshot::SnapshotPayload)::Message
    env = MessageEnvelope(
        "1.0",
        "msg_snapshot_$(string(time()))",
        UInt64(floor(time() * 1000)),
        "julia_runtime",
        "godot_gui",
        "snapshot"
    )
    
    Message(env, snapshot)
end

# ============================================================================
# Helper: Convert ElementState to Dict
# ============================================================================

function element_to_dict(elem::ElementState)::Dict{String, Any}
    Dict(
        "element_id" => elem.id,
        "element_kind" => elem.element_type,
        "occupancy" => elem.occupancy,
        "custom_metrics" => elem.custom_metrics,
    )
end

# ============================================================================
# Helper: Convert EntitySnapshot to Dict
# ============================================================================

function entity_to_dict(ent::EntitySnapshot)::Dict{String, Any}
    Dict(
        "id" => ent.id,
        "kind" => ent.entity_type,
        "current_location" => ent.current_location,
        "arrival_time" => ent.arrival_time,
        "trajectory_2d" => ent.trajectory_2d,
        "properties" => ent.properties,
    )
end

# ============================================================================
# Helper: Convert ABMStateSnapshot to Dict
# ============================================================================

function abm_to_dict(abm::ABMStateSnapshot)::Dict{String, Any}
    # Handle positions and velocities - may be vectors or base64 strings
    positions_encoded = if isa(abm.agent_positions, Vector)
        base64encode(abm.agent_positions)
    else
        abm.agent_positions
    end
    
    velocities_encoded = if isa(abm.agent_velocities, Vector)
        base64encode(abm.agent_velocities)
    else
        abm.agent_velocities
    end
    
    grid_encoded = if isa(abm.crowd_density_grid, Vector)
        base64encode(abm.crowd_density_grid)
    else
        abm.crowd_density_grid
    end
    
    Dict(
        "crowd_model_active" => abm.crowd_model_active,
        "num_agents" => abm.num_agents,
        "agent_positions" => positions_encoded,
        "agent_velocities" => velocities_encoded,
        "crowd_density_grid" => grid_encoded,
        "crowd_heatmap" => abm.crowd_heatmap,
    )
end

# ============================================================================
# Convenience Builders
# ============================================================================

"""
    build_simple_snapshot(
        scene_id::String,
        sim_time::Float64,
        step_count::UInt64;
        clock_speed=1.0f0,
        state="running"
    ) -> SnapshotPayload

Build a minimal snapshot with just timing information.
Useful for testing and simple simulations.
"""
function build_simple_snapshot(
    scene_id::String,
    sim_time::Float64,
    step_count::UInt64;
    clock_speed::Float32=1.0f0,
    state::String="running",
)::SnapshotPayload
    
    build_snapshot(
        scene_id,
        sim_time,
        step_count,
        clock_speed,
        state,
        ElementState[],
        EntitySnapshot[],
        nothing,
        Dict{String, Any}[],
        String[],
        false
    )
end

"""
    build_snapshot_with_elements(
        scene_id::String,
        sim_time::Float64,
        step_count::UInt64,
        elements::Vector{ElementState};
        clock_speed=1.0f0
    ) -> SnapshotPayload

Build a snapshot with element state but no entities.
"""
function build_snapshot_with_elements(
    scene_id::String,
    sim_time::Float64,
    step_count::UInt64,
    elements::Vector{ElementState};
    clock_speed::Float32=1.0f0,
)::SnapshotPayload
    
    build_snapshot(
        scene_id,
        sim_time,
        step_count,
        clock_speed,
        "running",
        elements,
        EntitySnapshot[],
        nothing,
        Dict{String, Any}[],
        String[],
        false
    )
end

"""
    build_snapshot_with_entities(
        scene_id::String,
        sim_time::Float64,
        step_count::UInt64,
        elements::Vector{ElementState},
        entities::Vector{EntitySnapshot};
        clock_speed=1.0f0
    ) -> SnapshotPayload

Build a complete DES snapshot with elements and entities.
"""
function build_snapshot_with_entities(
    scene_id::String,
    sim_time::Float64,
    step_count::UInt64,
    elements::Vector{ElementState},
    entities::Vector{EntitySnapshot};
    clock_speed::Float32=1.0f0,
)::SnapshotPayload
    
    build_snapshot(
        scene_id,
        sim_time,
        step_count,
        clock_speed,
        "running",
        elements,
        entities,
        nothing,
        Dict{String, Any}[],
        String[],
        false
    )
end

# ============================================================================
# Exports
# ============================================================================

export SimulationState, ElementState, EntitySnapshot, ABMStateSnapshot
export build_snapshot
export build_simple_snapshot, build_snapshot_with_elements, build_snapshot_with_entities
export create_hello_message_from_simulation, wrap_snapshot_in_message
export element_to_dict, entity_to_dict, abm_to_dict
