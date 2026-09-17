# Phase 7B.3.1: SimulationAdapter Abstract Interface
# Contract that all simulation engines must implement

include("traits.jl")

"""
    SimulationAdapter

Abstract base type for simulation engine adapters.

Every simulation engine (DES, ABM, or Hybrid) must implement a concrete adapter
that provides access to its state through this interface. The adapter bridges the
gap between engine-specific internals and the generic Godot GUI protocol.

Required Methods:
- abm_capability(adapter)
- get_simulation_time(adapter)
- get_elements_snapshot(adapter)
- get_entities_snapshot(adapter)
- get_abm_snapshot(adapter) [only if SupportsABM]
- dispatch_command(adapter, cmd)

Optional Customization:
- has_feature(adapter, feature_type)
- protocol_version(adapter)
"""
abstract type SimulationAdapter end

# ============================================================================
# REQUIRED INTERFACE METHODS
# ============================================================================

"""
    abm_capability(adapter::SimulationAdapter)::ABMCapability

Returns whether this adapter supports ABM (SupportsABM) or is DES-only (NoABM).

This is used for compile-time dispatch in the Godot GUI. The trait determines:
- What fields are populated in SnapshotPayload
- Whether get_abm_snapshot() will be called
- How GUI renders agent populations

Returns:
- NoABM(): This is a DES-only system, no ABM data will be provided
- SupportsABM(): This system has agent-based components, ABM data available

Example:
    struct ManufacturingAdapter <: SimulationAdapter
        engine::SimElements
    end
    
    abm_capability(::ManufacturingAdapter) = NoABM()  # DES-only
"""
function abm_capability(adapter::SimulationAdapter)
    error("abm_capability not implemented for $(typeof(adapter)). " *
          "Must return NoABM() or SupportsABM().")
end

"""
    get_simulation_time(adapter::SimulationAdapter)::Float64

Returns current simulation clock time in seconds.

The Godot GUI uses this for:
- Displaying current simulation time
- Tracking trajectory history timestamps
- Correlating with recorded events
- Computing time deltas

Returns:
    Float64: Current time, typically starting from 0.0

Example:
    struct MyAdapter <: SimulationAdapter
        engine::SimElements
    end
    
    get_simulation_time(adapter::MyAdapter) = adapter.engine.clock
"""
function get_simulation_time(adapter::SimulationAdapter)
    error("get_simulation_time not implemented for $(typeof(adapter)). " *
          "Must return Float64 seconds.")
end

"""
    get_elements_snapshot(adapter::SimulationAdapter)::Vector{ElementState}

Extract snapshot of all simulation infrastructure elements.

Elements represent stationary, persistent simulation infrastructure:
- Network nodes, stations, resource pools
- Service centers, storage locations
- Any simulation object with occupancy, queue, or property state

Returns a Vector of ElementState structs. The GUI will:
- Display elements with their properties
- Show occupancy levels via color/size
- Render queues and wait times

Returns:
    Vector{ElementState}: One entry per infrastructure element
    
    Each ElementState contains:
    - id::Int: Unique element identifier
    - type::Symbol: Element type (:station, :queue, :resource, etc)
    - occupancy::Int: Current items/agents in element
    - capacity::Int: Maximum capacity (0 = unlimited)
    - metrics::Dict{String, Float64}: Custom metrics (queue_wait, throughput, etc)

Example:
    struct MyAdapter <: SimulationAdapter
        engine::SimElements
    end
    
    function get_elements_snapshot(adapter::MyAdapter)
        return [
            ElementState(id=1, type=:station, occupancy=5, capacity=10, 
                        metrics=Dict("queue_wait" => 2.3)),
            ElementState(id=2, type=:resource, occupancy=8, capacity=20,
                        metrics=Dict("utilization" => 0.4))
        ]
    end
"""
function get_elements_snapshot(adapter::SimulationAdapter)
    error("get_elements_snapshot not implemented for $(typeof(adapter)). " *
          "Must return Vector{ElementState}.")
end

"""
    get_entities_snapshot(adapter::SimulationAdapter)::Vector{EntitySnapshot}

Extract snapshot of all mobile agents/entities.

Entities represent dynamic simulation objects that move through the system:
- Customers, parts, vehicles, agents
- Objects with position, trajectory, properties
- Mobile in contrast to stationary elements

Returns a Vector of EntitySnapshot structs. The GUI will:
- Display entities as animated icons/markers
- Draw trajectories showing past movement
- Display entity-specific properties and status

Returns:
    Vector{EntitySnapshot}: One entry per mobile entity
    
    Each EntitySnapshot contains:
    - id::Int: Unique entity identifier
    - position::Point: Current (x, y) location
    - trajectory::Vector{Point}: History of recent positions
    - entity_type::Symbol: Entity type (:customer, :vehicle, :part, etc)
    - color::Symbol or String: Display color
    - speed::Float64: Current speed (for animation)
    - properties::Dict{String, Any}: Custom entity properties

Example:
    function get_entities_snapshot(adapter::MyAdapter)
        return [
            EntitySnapshot(id=101, position=Point(10.5, 20.3),
                          trajectory=[Point(10.0, 20.0), Point(9.5, 19.8)],
                          entity_type=:customer, color=:blue, speed=0.5,
                          properties=Dict("wait_time" => 120.0))
        ]
    end
"""
function get_entities_snapshot(adapter::SimulationAdapter)
    error("get_entities_snapshot not implemented for $(typeof(adapter)). " *
          "Must return Vector{EntitySnapshot}.")
end

"""
    get_abm_snapshot(adapter::SimulationAdapter)::Union{ABMStateSnapshot, Nothing}

Extract snapshot of agent-based modeling state (if supported).

This is ONLY called if abm_capability(adapter) returns SupportsABM().
If abm_capability returns NoABM(), the GUI automatically sends nothing for ABM field.

For Hybrid DES+ABM systems, use this to provide agent-specific data beyond
what's available in entity snapshots (e.g., internal agent state, infection status,
relationships, spatial density).

Returns:
    Union{ABMStateSnapshot, Nothing}
    
    ABMStateSnapshot contains:
    - agents::Vector{Dict{String, Any}}: Agent-specific state (infection, energy, etc)
    - spatial_density::Dict{Tuple{Int, Int}, Int}: Agents per grid cell
    - properties::Dict{String, Any}: Population-level stats
    
    Returns nothing if no ABM data available this frame.

Example:
    function get_abm_snapshot(adapter::ShoppingMallAdapter)
        return ABMStateSnapshot(
            agents=[
                Dict("id" => 1, "infection_status" => :susceptible, "energy" => 0.8),
                Dict("id" => 2, "infection_status" => :infected, "energy" => 0.5)
            ],
            spatial_density=Dict((5, 5) => 3, (6, 5) => 2),
            properties=Dict("infected_count" => 15, "average_energy" => 0.7)
        )
    end

Note:
    Only implement this if abm_capability returns SupportsABM().
    For NoABM adapters, omit this method entirely.
"""
function get_abm_snapshot(adapter::SimulationAdapter)
    if abm_capability(adapter) isa NoABM
        return nothing  # Lightweight, no computation
    end
    error("get_abm_snapshot not implemented for $(typeof(adapter)). " *
          "Must return ABMStateSnapshot or nothing, or declare NoABM capability.")
end

"""
    dispatch_command(adapter::SimulationAdapter, command)::Any

Execute a command from the Godot GUI on the simulation.

This is the reverse channel: GUI sends commands (play, pause, step, etc) and
adapter translates them to engine-specific actions.

Args:
    adapter: The simulation adapter
    command: Command-like value with type and parameters
    
Returns:
    CommandResult with success status and any error messages

Supported commands:
    :play → Resume simulation
    :pause → Pause simulation
    :step → Execute one step
    :reset → Reset to initial state
    :set_clock_speed → Change simulation speed factor
    :jump_to_time → Jump to specific time
    :query_state → Query simulation state
    :set_trace_entity → Focus on specific entity
    :set_trace_element → Focus on specific element

Example:
    function dispatch_command(adapter::MyAdapter, command)
        try
            if command.command_type == :play
                adapter.engine.running = true
                return CommandResult(success=true)
            elseif command.command_type == :pause
                adapter.engine.running = false
                return CommandResult(success=true)
            else
                return CommandResult(success=false, 
                                   error="Unknown command: \$(command.command_type)")
            end
        catch e
            return CommandResult(success=false, error=string(e))
        end
    end
"""
function dispatch_command(adapter::SimulationAdapter, cmd)
    error("dispatch_command not implemented for $(typeof(adapter)). " *
          "Must handle SimulationCommand and return CommandResult.")
end

# ============================================================================
# OPTIONAL CUSTOMIZATION
# ============================================================================

# has_feature and protocol_version are already defined in traits.jl
# with default implementations

# ============================================================================
# HELPER TYPE STUBS
# ============================================================================

"""
    ElementState

Represents state of one simulation infrastructure element.
Defined elsewhere (in protocol types) but used here as a reference.
"""
# (Actual definition in protocol/envelope.jl)

"""
    EntitySnapshot

Represents state of one mobile entity.
Defined elsewhere (in protocol/envelope.jl) but used here as a reference.
"""
# (Actual definition in protocol/envelope.jl)

"""
    ABMStateSnapshot

Represents agent-based modeling state.
Defined elsewhere (in protocol/envelope.jl) but used here as a reference.
"""
# (Actual definition in protocol/envelope.jl)

"""
    SimulationCommand

Represents a command from the GUI to the simulation.
Defined elsewhere (in commands/handler.jl) but used here as a reference.
"""
# (Actual definition in commands/handler.jl)

"""
    CommandResult

Result of executing a command.
Defined elsewhere (in commands/handler.jl) but used here as a reference.
"""
# (Actual definition in commands/handler.jl)

"""
    Point

2D coordinate for entity position/trajectory.
Defined elsewhere (in protocol/envelope.jl) but used here as a reference.
"""
# (Actual definition in protocol/envelope.jl)

export SimulationAdapter
export abm_capability, get_simulation_time
export get_elements_snapshot, get_entities_snapshot, get_abm_snapshot
export dispatch_command
