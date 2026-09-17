"""
    DeltaBuilder

Module for computing efficient incremental changes between snapshots.

Handles:
- Element state changes (added, removed, updated)
- Entity lifecycle changes (entered, left)
- Entity movement (position changes, trajectory updates)
- ABM density/velocity updates
- Efficient encoding for bandwidth

Strategy:
- Compare snapshots by ID
- Track what changed, not entire state
- Use indices to compress entity movement
- Support partial updates for large crowds
"""
module DeltaBuilder

using UUIDs

include("../protocol/envelope.jl")

export ElementChange, EntityChange, DeltaState, 
       build_delta,
       create_delta_message,
       get_change_summary

"""
    ElementChange

Represents a change to an element (queue/server/location).
"""
mutable struct ElementChange
    element_id::String
    change_type::String  # "added", "removed", "updated"
    occupancy_before::Union{UInt32, Nothing}
    occupancy_after::Union{UInt32, Nothing}
    metrics_changed::Dict{String, Tuple{Any, Any}}  # key => (old_value, new_value)
end

"""
    EntityChange

Represents a change to an entity (customer or agent).
"""
mutable struct EntityChange
    entity_id::String
    change_type::String  # "arrived", "departed", "moved", "updated"
    previous_location::Union{String, Nothing}
    current_location::String
    trajectory_segment::Union{Vector{Vector{Float64}}, Nothing}  # New trajectory points
    properties_changed::Dict{String, Tuple{Any, Any}}  # key => (old_value, new_value)
end

"""
    DeltaState

Summary of all changes between two snapshots.
"""
mutable struct DeltaState
    parent_snapshot_id::String
    elements_changed::Vector{ElementChange}
    entities_added::Vector{EntityChange}
    entities_removed::Vector{EntityChange}
    entities_moved::Vector{EntityChange}
    entities_updated::Vector{EntityChange}
    abm_density_changed::Bool
    abm_velocity_field_changed::Bool
    abm_changes_summary::Dict{String, Any}
end

"""
    build_delta(previous::SnapshotPayload, current::SnapshotPayload) -> DeltaState

Compute all changes between two snapshots.

**Arguments**:
- `previous`: Earlier snapshot to compare from
- `current`: Newer snapshot to compute changes toward

**Returns**: DeltaState with all categorized changes

**Strategy**:
1. Index both snapshots by ID
2. Identify element additions/removals/updates
3. Identify entity arrivals/departures/moves
4. Compute ABM changes
5. Return categorized changes for efficient transmission

**Example**:
```julia
delta = build_delta(old_snapshot, new_snapshot)
println("Elements changed: ", length(delta.elements_changed))
println("Entities arrived: ", length(delta.entities_added))
```
"""
function build_delta(previous::SnapshotPayload, current::SnapshotPayload)::DeltaState
    # Validate snapshots
    if isnothing(previous.snapshot_id) || isnothing(current.snapshot_id)
        error("Both snapshots must have valid snapshot_id")
    end
    
    # Index previous snapshot
    prev_elements = Dict{String, Any}()
    if !isnothing(previous.elements_state)
        for elem in previous.elements_state
            prev_elements[elem["id"]] = elem
        end
    end
    
    prev_entities = Dict{String, Any}()
    if !isnothing(previous.entities)
        for ent in previous.entities
            prev_entities[ent["id"]] = ent
        end
    end
    
    # Index current snapshot
    curr_elements = Dict{String, Any}()
    if !isnothing(current.elements_state)
        for elem in current.elements_state
            curr_elements[elem["id"]] = elem
        end
    end
    
    curr_entities = Dict{String, Any}()
    if !isnothing(current.entities)
        for ent in current.entities
            curr_entities[ent["id"]] = ent
        end
    end
    
    # Compute element changes
    elements_changed = ElementChange[]
    
    # Removed elements
    for (elem_id, prev_elem) in prev_elements
        if !haskey(curr_elements, elem_id)
            push!(elements_changed, ElementChange(
                elem_id, "removed",
                UInt32(prev_elem["occupancy"]), nothing,
                Dict()
            ))
        end
    end
    
    # Added or updated elements
    for (elem_id, curr_elem) in curr_elements
        if !haskey(prev_elements, elem_id)
            # Added
            push!(elements_changed, ElementChange(
                elem_id, "added",
                nothing, UInt32(curr_elem["occupancy"]),
                Dict()
            ))
        else
            # Possibly updated
            prev_elem = prev_elements[elem_id]
            metrics_changed = Dict{String, Tuple{Any, Any}}()
            
            # Check occupancy
            prev_occ = UInt32(prev_elem["occupancy"])
            curr_occ = UInt32(curr_elem["occupancy"])
            
            if prev_occ != curr_occ
                metrics_changed["occupancy"] = (prev_occ, curr_occ)
            end
            
            # Check custom metrics
            prev_metrics = get(prev_elem, "custom_metrics", Dict())
            curr_metrics = get(curr_elem, "custom_metrics", Dict())
            
            for key in union(keys(prev_metrics), keys(curr_metrics))
                prev_val = get(prev_metrics, key, nothing)
                curr_val = get(curr_metrics, key, nothing)
                if prev_val != curr_val
                    metrics_changed[key] = (prev_val, curr_val)
                end
            end
            
            # Only record if something changed
            if !isempty(metrics_changed)
                push!(elements_changed, ElementChange(
                    elem_id, "updated",
                    prev_occ, curr_occ,
                    metrics_changed
                ))
            end
        end
    end
    
    # Compute entity changes
    entities_added = EntityChange[]
    entities_removed = EntityChange[]
    entities_moved = EntityChange[]
    entities_updated = EntityChange[]
    
    # Removed entities (departed)
    for (ent_id, prev_ent) in prev_entities
        if !haskey(curr_entities, ent_id)
            push!(entities_removed, EntityChange(
                ent_id, "departed",
                get(prev_ent, "current_location", "unknown"),
                "departed",
                nothing,
                Dict()
            ))
        end
    end
    
    # Added or updated entities
    for (ent_id, curr_ent) in curr_entities
        if !haskey(prev_entities, ent_id)
            # Arrived
            push!(entities_added, EntityChange(
                ent_id, "arrived",
                nothing,
                get(curr_ent, "current_location", "unknown"),
                get(curr_ent, "trajectory_2d", []),
                Dict()
            ))
        else
            # Possibly moved or updated
            prev_ent = prev_entities[ent_id]
            prev_loc = get(prev_ent, "current_location", "unknown")
            curr_loc = get(curr_ent, "current_location", "unknown")
            
            properties_changed = Dict{String, Tuple{Any, Any}}()
            
            # Check properties
            prev_props = get(prev_ent, "properties", Dict())
            curr_props = get(curr_ent, "properties", Dict())
            
            for key in union(keys(prev_props), keys(curr_props))
                prev_val = get(prev_props, key, nothing)
                curr_val = get(curr_props, key, nothing)
                if prev_val != curr_val
                    properties_changed[key] = (prev_val, curr_val)
                end
            end
            
            if prev_loc != curr_loc
                # Moved to new location
                push!(entities_moved, EntityChange(
                    ent_id, "moved",
                    prev_loc, curr_loc,
                    get(curr_ent, "trajectory_2d", []),
                    properties_changed
                ))
            elseif !isempty(properties_changed)
                # Updated but same location
                push!(entities_updated, EntityChange(
                    ent_id, "updated",
                    prev_loc, curr_loc,
                    nothing,
                    properties_changed
                ))
            end
        end
    end
    
    # Compute ABM changes
    abm_density_changed = false
    abm_velocity_changed = false
    abm_summary = Dict{String, Any}()
    
    if !isnothing(previous.abm_state) && !isnothing(current.abm_state)
        prev_abm = previous.abm_state
        curr_abm = current.abm_state
        
        # Check density
        if get(prev_abm, "density_field", nothing) != get(curr_abm, "density_field", nothing)
            abm_density_changed = true
            abm_summary["density_changed"] = true
        end
        
        # Check velocity field
        if get(prev_abm, "velocity_field", nothing) != get(curr_abm, "velocity_field", nothing)
            abm_velocity_changed = true
            abm_summary["velocity_changed"] = true
        end
        
        # Agent count
        prev_agents = length(get(prev_abm, "agents", []))
        curr_agents = length(get(curr_abm, "agents", []))
        if prev_agents != curr_agents
            abm_summary["agent_count_before"] = prev_agents
            abm_summary["agent_count_after"] = curr_agents
        end
    end
    
    DeltaState(
        previous.snapshot_id,
        elements_changed,
        entities_added,
        entities_removed,
        entities_moved,
        entities_updated,
        abm_density_changed,
        abm_velocity_changed,
        abm_summary
    )
end

"""
    create_delta_message(delta::DeltaState; sender="bridge", receiver="godot") -> Message

Convert a DeltaState into a DeltaPayload message ready for transmission.

**Arguments**:
- `delta`: Computed changes
- `sender`: Message sender (default "bridge")
- `receiver`: Message receiver (default "godot")

**Returns**: Message struct ready for serialization

**Design**:
- Encodes all changes from DeltaState into Protocol v1 format
- Sends only changed fields, not entire state
- Bandwidth-efficient for large simulations
- Uses parent_snapshot_id for causality tracking

**Example**:
```julia
delta = build_delta(old, new)
msg = create_delta_message(delta)
# Send via broadcast_snapshot(server, msg.payload)
```
"""
function create_delta_message(
    delta::DeltaState;
    sender::String="bridge",
    receiver::String="godot"
)::Message
    
    # Convert changes to dict format for payload
    elements_changed_dict = []
    for elem_change in delta.elements_changed
        push!(elements_changed_dict, Dict(
            "element_id" => elem_change.element_id,
            "change_type" => elem_change.change_type,
            "occupancy_before" => elem_change.occupancy_before,
            "occupancy_after" => elem_change.occupancy_after,
            "metrics_changed" => elem_change.metrics_changed
        ))
    end
    
    entities_added_dict = []
    for ent_change in delta.entities_added
        push!(entities_added_dict, Dict(
            "entity_id" => ent_change.entity_id,
            "change_type" => "arrived",
            "current_location" => ent_change.current_location,
            "trajectory_segment" => ent_change.trajectory_segment
        ))
    end
    
    entities_removed_dict = []
    for ent_change in delta.entities_removed
        push!(entities_removed_dict, Dict(
            "entity_id" => ent_change.entity_id,
            "change_type" => "departed",
            "previous_location" => ent_change.previous_location
        ))
    end
    
    entities_moved_dict = []
    for ent_change in delta.entities_moved
        push!(entities_moved_dict, Dict(
            "entity_id" => ent_change.entity_id,
            "change_type" => "moved",
            "previous_location" => ent_change.previous_location,
            "current_location" => ent_change.current_location,
            "trajectory_segment" => ent_change.trajectory_segment
        ))
    end
    
    entities_updated_dict = []
    for ent_change in delta.entities_updated
        push!(entities_updated_dict, Dict(
            "entity_id" => ent_change.entity_id,
            "change_type" => "updated",
            "properties_changed" => ent_change.properties_changed
        ))
    end
    
    # Create payload
    payload = DeltaPayload(
        parent_snapshot_id = delta.parent_snapshot_id,
        elements_changed = elements_changed_dict,
        entities_added = entities_added_dict,
        entities_removed = entities_removed_dict,
        entities_moved = entities_moved_dict,
        entities_updated = entities_updated_dict,
        abm_changes = delta.abm_changes_summary
    )
    
    # Wrap in message
    Message(
        protocol_version = "1.0",
        message_id = string(uuid4()),
        timestamp = Dates.now(),
        sender = sender,
        receiver = receiver,
        kind = "delta",
        payload = payload
    )
end

"""
    get_change_summary(delta::DeltaState) -> Dict{String, Any}

Get a summary of all changes for logging/debugging.

**Returns**: Dict with counts and high-level summary

**Example**:
```julia
delta = build_delta(old, new)
summary = get_change_summary(delta)
println("Elements changed: ", summary["elements_changed_count"])
println("Entities moved: ", summary["entities_moved_count"])
```
"""
function get_change_summary(delta::DeltaState)::Dict{String, Any}
    Dict(
        "parent_snapshot_id" => delta.parent_snapshot_id,
        "elements_changed_count" => length(delta.elements_changed),
        "elements_added_count" => sum(1 for e in delta.elements_changed if e.change_type == "added"),
        "elements_removed_count" => sum(1 for e in delta.elements_changed if e.change_type == "removed"),
        "elements_updated_count" => sum(1 for e in delta.elements_changed if e.change_type == "updated"),
        "entities_added_count" => length(delta.entities_added),
        "entities_removed_count" => length(delta.entities_removed),
        "entities_moved_count" => length(delta.entities_moved),
        "entities_updated_count" => length(delta.entities_updated),
        "entities_total_changes" => length(delta.entities_added) + length(delta.entities_removed) + 
                                   length(delta.entities_moved) + length(delta.entities_updated),
        "abm_density_changed" => delta.abm_density_changed,
        "abm_velocity_field_changed" => delta.abm_velocity_field_changed,
        "abm_summary" => delta.abm_changes_summary
    )
end

end  # module DeltaBuilder
