# Phase 7B.3 - Engine Integration Design

**Status**: Planning Phase  
**Objective**: Connect Phase 7B.2 middleware to SimElements runtime

## Problem Statement

Phase 7B.2 provides:
- ✅ Snapshot extraction interface (via snapshot_builder.jl)
- ✅ Delta computation (via delta_builder.jl)
- ✅ Command dispatch (via command_handler.jl)
- ✅ WebSocket server scaffold (Phase 7B.1)

**Missing**: How do we plug the SimElements simulation engine into this pipeline?

## Key Questions to Answer

### 1. State Extraction Interface

**Question**: How does `snapshot_builder` access simulation state?

**Current Design** (snapshot_builder.jl):
```julia
function build_snapshot(
    scene_id::String,
    simulation_time::Float64,
    step_count::UInt64,
    # ...
    elements_state::Vector{ElementState}=[],
    entities::Vector{EntitySnapshot}=[],
    abm_state::Union{ABMStateSnapshot, Nothing}=nothing
)
```

**Needed**:
- Abstract interface for extracting elements from SimElements
- Mapping: SimElements element → ElementState (id, type, occupancy, metrics)
- Mapping: Entity position/trajectory → EntitySnapshot
- Mapping: ABM agent state → ABMStateSnapshot

**Design Options**:

**Option A: Query Function**
```julia
# User provides callback functions
elements = get_elements_state(simulation_engine)
entities = get_entities_snapshot(simulation_engine)
abm = get_abm_snapshot(simulation_engine)

snapshot = build_snapshot(..., elements_state=elements, entities=entities, abm_state=abm)
```

**Option B: SimElements Integration Module**
```julia
# Create integration layer
include("integration/simElements_adapter.jl")

adapter = SimElementsAdapter(simulation_engine)
snapshot = build_snapshot_from_engine(adapter, scene_id, sim_time, step_count)
```

**Option C: Message Interface**
```julia
# Engine publishes state via event system
@event engine.state_changed -> (elements, entities, abm)
listener = setup_state_listener(engine)
snapshot = extract_snapshot_from_listener(listener, scene_id, sim_time)
```

### 2. Element State Extraction

**Requirement**: Convert SimElements element (queue/server/location) → ElementState

**What we know from Phase 2-3 (SimElements design)**:
- Elements have: id, type (queue/server/location), state
- Elements can have: occupancy, wait times, custom metrics
- We need: ElementState(id, element_type, occupancy, custom_metrics)

**Implementation Plan**:

```julia
"""Extract state from single SimElements element"""
function extract_element_state(element)::ElementState
    # Get standard properties
    id = element.id
    element_type = element_type_name(element)  # "queue", "server", "location"
    occupancy = get_occupancy(element)  # How many entities in element?
    
    # Get custom metrics
    metrics = Dict{String, Any}()
    if has_queue_properties(element)
        metrics["avg_wait_time"] = average_wait_time(element)
        metrics["max_queue_length"] = max_queue_length(element)
    end
    if has_server_properties(element)
        metrics["busy_time"] = busy_time_fraction(element)
        metrics["server_count"] = server_count(element)
    end
    
    ElementState(id, element_type, occupancy, metrics)
end

function get_elements_state(engine)::Vector{ElementState}
    return [extract_element_state(e) for e in get_all_elements(engine)]
end
```

**Open Questions**:
- How are elements stored/indexed in SimElements?
- What properties do SimElements elements expose?
- How to get occupancy (entity count in element)?
- How to compute metrics (avg_wait, busy_time, etc.)?
- Should we cache element state or compute on demand?

### 3. Entity State Extraction

**Requirement**: Convert SimElements entity → EntitySnapshot

**What we know**:
- Entities have: id, type (customer/agent), current_location
- Entities can have: arrival_time, custom properties
- We need: EntitySnapshot(id, type, location, arrival_time, trajectory, properties)

**Implementation Plan**:

```julia
"""Extract state from single SimElements entity"""
function extract_entity_snapshot(entity, trajectory_history=Dict())::EntitySnapshot
    id = entity.id
    entity_type = entity.entity_type  # "customer", "agent", etc.
    location = entity.current_location  # Which element is it in?
    arrival_time = entity.arrival_time  # When did it enter system?
    
    # Get trajectory history
    trajectory = get(trajectory_history, id, [[entity.position_x, entity.position_y]])
    
    # Get custom properties
    properties = Dict{String, Any}()
    if hasfield(entity, :priority)
        properties["priority"] = entity.priority
    end
    if hasfield(entity, :source)
        properties["source"] = entity.source
    end
    
    EntitySnapshot(id, entity_type, location, arrival_time, trajectory, properties)
end

function get_entities_snapshot(engine, trajectory_history)::Vector{EntitySnapshot}
    return [extract_entity_snapshot(e, trajectory_history) for e in get_all_entities(engine)]
end
```

**Open Questions**:
- How are entities stored in SimElements?
- How to get entity current location?
- How to track trajectory history (2D positions over time)?
- Do entities have position coordinates or just element ID?
- Should trajectory be stored separately (performance)?

### 4. ABM State Extraction (if applicable)

**Requirement**: Convert ABM agent state → ABMStateSnapshot

**Only needed if**: Using crowd/agent-based model in addition to DES

**Implementation Plan**:

```julia
"""Extract ABM crowd state"""
function extract_abm_snapshot(abm_model)::ABMStateSnapshot
    agents = abm_model.agents
    positions = abm_model.positions
    velocities = abm_model.velocities
    
    return ABMStateSnapshot(
        model="crowd_simulation",
        agents=agents,
        positions=positions,
        velocities=velocities,
        density_field=compute_density_field(positions),
        velocity_field=compute_velocity_field(velocities)
    )
end
```

**Open Questions**:
- Do we use ABM for this project or strictly DES?
- If ABM, what agent properties to extract?
- Should we compute density/velocity fields or store raw?

### 5. Command Execution

**Requirement**: Route command_handler dispatch → engine execution

**Currently Supported Commands**:
- play: Resume simulation
- pause: Pause simulation  
- step: Execute single DES step
- reset: Reset to initial state
- set_clock_speed: Adjust simulation speed
- jump_to_time: Jump simulation to specific time
- query_state: Get current state
- set_trace_entity: Enable entity tracing
- set_trace_element: Enable element tracing

**Implementation Plan**:

```julia
"""Bridge between command_handler and simulation engine"""
mutable struct SimulationCommandBridge
    engine::Any  # Reference to simulation engine
    paused::Bool
    clock_speed::Float64
    trace_entities::Set{String}
    trace_elements::Set{String}
end

function execute_command(bridge::SimulationCommandBridge, result::CommandResult)
    cmd_type = result.command_type
    params = result.result_data  # Or get from original result
    
    if cmd_type == "play"
        bridge.engine.paused = false
        bridge.engine.state = "running"
    
    elseif cmd_type == "pause"
        bridge.engine.paused = true
        bridge.engine.state = "paused"
    
    elseif cmd_type == "step"
        if !bridge.engine.paused
            error("Cannot step while running")
        end
        advance_single_step(bridge.engine)
    
    elseif cmd_type == "reset"
        reset_simulation(bridge.engine)
    
    elseif cmd_type == "set_clock_speed"
        speed = params["new_speed"]
        bridge.clock_speed = speed
        bridge.engine.clock_speed = speed
    
    elseif cmd_type == "jump_to_time"
        target_time = params["target_time"]
        jump_simulation_to_time(bridge.engine, target_time)
    
    elseif cmd_type == "query_state"
        return get_current_simulation_state(bridge.engine)
    
    end
end
```

**Open Questions**:
- Does SimElements already have play/pause/step/reset?
- How does clock speed adjustment work?
- How do we implement jump_to_time?
- What does "reset" entail (clear all entities? reset clock?)?

### 6. Periodic Update Loop

**Requirement**: Trigger snapshots and deltas at appropriate frequency

**Design Options**:

**Option A: Fixed Schedule**
```julia
# Send snapshot every 10 steps, delta every step
for step in 1:num_steps
    # ... run simulation step ...
    
    if step % 10 == 0
        # Send full snapshot
        snapshot = build_snapshot_from_engine(bridge, scene_id, engine.time, step)
        broadcast_snapshot(server, snapshot)
    else
        # Send delta from previous step
        delta = build_delta(prev_snapshot, current_snapshot)
        broadcast_delta(server, delta)
    end
end
```

**Option B: Adaptive Schedule**
```julia
# Send snapshot if delta would be >80% of snapshot size
for step in 1:num_steps
    # ... run simulation step ...
    
    delta = build_delta(prev_snapshot, current_snapshot)
    delta_size = estimate_encoded_size(delta)
    snapshot_size = estimate_encoded_size(current_snapshot)
    
    if delta_size > 0.8 * snapshot_size
        # Delta inefficient, send full snapshot
        broadcast_snapshot(server, current_snapshot)
    else
        # Delta efficient, send delta
        broadcast_delta(server, delta)
    end
end
```

**Option C: Event-Driven**
```julia
# Send update only when significant change occurs
on_element_added(bridge) -> broadcast_snapshot(server, ...)
on_entity_departed(bridge) -> broadcast_delta(server, ...)
on_simulation_state_changed(bridge) -> broadcast_error(server, ...)
```

### 7. Integration Point Architecture

**Proposed Architecture**:

```
┌─────────────────────────────────────────────────────┐
│ SimElements Runtime                                 │
│  - DES Engine (elements, entities, time)            │
│  - State Management                                 │
│  - Event System                                     │
└──────────────────┬──────────────────────────────────┘
                   │
                   ↓
┌─────────────────────────────────────────────────────┐
│ SimElements Adapter (simElements_bridge.jl)         │
│  - extract_element_state()                          │
│  - extract_entity_snapshot()                        │
│  - execute_command()                                │
│  - track_trajectory_history()                       │
└──────────────────┬──────────────────────────────────┘
                   │
                   ↓
┌─────────────────────────────────────────────────────┐
│ Phase 7B.2 Middleware                               │
│  - snapshot_builder (uses adapter to get state)     │
│  - delta_builder (compares snapshots)               │
│  - command_handler (dispatches via adapter)         │
│  - websocket_server (broadcasts to Godot)           │
└──────────────────┬──────────────────────────────────┘
                   │
                   ↓
┌─────────────────────────────────────────────────────┐
│ Godot Engine (3.2+ - Not implemented yet)           │
│  - GUI Visualization                                │
│  - User Interaction                                 │
│  - Real-time Updates                                │
└─────────────────────────────────────────────────────┘
```

## Implementation Roadmap

### Phase 7B.3.1: SimElements Adapter Interface
1. Define abstract interface for state extraction
2. Implement adapters for common SimElements patterns
3. Test with mock SimElements engine

### Phase 7B.3.2: State Extraction
1. Implement element state extraction
2. Implement entity state extraction
3. Add trajectory history tracking
4. Test with real SimElements

### Phase 7B.3.3: Command Execution
1. Implement command bridge
2. Connect commands to engine operations
3. Test all command types

### Phase 7B.3.4: Integration Loop
1. Implement periodic snapshot generation
2. Implement delta computation trigger
3. Integrate with WebSocket server
4. Test end-to-end flow

### Phase 7B.3.5: Performance & Polish
1. Profile message generation
2. Optimize delta encoding
3. Add error recovery
4. Add monitoring/logging

## Decision Matrix

| Decision | Option A | Option B | Option C | Recommendation |
|----------|----------|----------|----------|-----------------|
| State Extraction | Query Functions | Adapter Module | Message Interface | **B**: Cleaner encapsulation |
| Update Schedule | Fixed | Adaptive | Event-Driven | **B**: Responsive but bounded |
| ABM Support | Full state | Summaries only | No ABM | **B**: Summaries sufficient |
| Trajectory Tracking | Full history | Recent only | On-demand | **B**: Recent only (bandwidth) |

## Questions for User

1. **What SimElements is being used?**
   - Pure DES (queues/servers/locations)?
   - With ABM (crowd agents)?
   - Custom element types?

2. **What state needs to be visible?**
   - Just occupancy?
   - Wait times / busy times?
   - Entity trajectories?
   - Custom metrics?

3. **Update frequency?**
   - How often should snapshots be sent (steps, time)?
   - What's acceptable latency (immediate, 100ms, 1s)?

4. **Performance constraints?**
   - Max entities that need to track?
   - Max bandwidth available?
   - Max latency acceptable?

5. **Engine capabilities?**
   - Can engine pause/resume mid-step?
   - Can engine jump to arbitrary times?
   - Does engine support step-by-step execution?
   - Event/callback system available?

---

**Next Action**: Get answers to these questions, then implement Phase 7B.3.1 (Adapter Interface)
