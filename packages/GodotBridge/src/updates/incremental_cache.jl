"""Cached state updated from adapter-owned dirty IDs."""
mutable struct IncrementalStateCache
    elements::Dict{String, ElementState}
    entities::Dict{String, EntitySnapshot}
    revision::UInt64
    lock::ReentrantLock
end

IncrementalStateCache() = IncrementalStateCache(
    Dict{String, ElementState}(), Dict{String, EntitySnapshot}(), 0, ReentrantLock()
)

function seed_cache!(cache::IncrementalStateCache, elements, entities, revision::UInt64)
    lock(cache.lock) do
        empty!(cache.elements)
        empty!(cache.entities)
        for element in elements
            cache.elements[element.id] = element
        end
        for entity in entities
            cache.entities[entity.id] = entity
        end
        cache.revision = revision
    end
    return cache
end

function apply_dirty_state!(cache::IncrementalStateCache, adapter::SimulationAdapter, dirty::DirtyState)
    dirty.full_scan && throw(ArgumentError("full-scan dirty state cannot update incrementally"))
    supports_gpu_state_fetch(adapter) && synchronize_gpu_state!(adapter)
    element_ids = [dirty.elements_added; dirty.elements_updated]
    entity_ids = [dirty.entities_added; dirty.entities_updated]
    element_values = get_element_states(adapter, element_ids)
    entity_values = get_entity_states(adapter, entity_ids)
    lock(cache.lock) do
        for (id, element) in zip(element_ids, element_values)
            cache.elements[id] = element
        end
        for id in dirty.elements_removed
            delete!(cache.elements, id)
        end
        for (id, entity) in zip(entity_ids, entity_values)
            cache.entities[id] = entity
        end
        for id in dirty.entities_removed
            delete!(cache.entities, id)
        end
        cache.revision = dirty.revision
    end
    clear_dirty_state!(adapter, dirty.revision)
    return cache
end

function cached_elements(cache::IncrementalStateCache)
    lock(cache.lock) do
        return collect(values(cache.elements))
    end
end

function cached_entities(cache::IncrementalStateCache)
    lock(cache.lock) do
        return collect(values(cache.entities))
    end
end

function dirty_delta_payload(
    cache::IncrementalStateCache,
    adapter::SimulationAdapter,
    dirty::DirtyState,
    current::SnapshotPayload
)::DeltaPayload
    changed_elements = Dict{String, Any}[]
    added_elements = Set(dirty.elements_added)
    for id in [dirty.elements_added; dirty.elements_updated]
        element = cache.elements[id]
        push!(changed_elements, Dict(
            "element_id" => element.id,
            "change_type" => id in added_elements ? "added" : "updated",
            "occupancy_after" => element.occupancy,
            "custom_metrics" => element.custom_metrics
        ))
    end
    for id in dirty.elements_removed
        push!(changed_elements, Dict("element_id" => id, "change_type" => "removed"))
    end

    added = Dict{String, Any}[]
    updated = Dict{String, Any}[]
    added_entities = Set(dirty.entities_added)
    for id in [dirty.entities_added; dirty.entities_updated]
        entity = cache.entities[id]
        value = entity_to_dict(entity)
        if id in added_entities
            value["change_type"] = "arrived"
            push!(added, value)
        else
            value["change_type"] = "updated"
            push!(updated, value)
        end
    end

    return DeltaPayload(
        current.snapshot_version, current.scene_id, current.simulation_time,
        current.step_count, "revision-$(dirty.revision)", changed_elements, added,
        dirty.entities_removed, updated, nothing, Dict{String, Any}[]
    )
end

function direct_dirty_delta_payload(
    cache::IncrementalStateCache,
    dirty::DirtyState,
    current::SnapshotPayload
)::DirectDeltaPayload
    added_elements = Set(dirty.elements_added)
    changed_elements = DirectElementDelta[]
    for id in [dirty.elements_added; dirty.elements_updated]
        element = cache.elements[id]
        push!(changed_elements, DirectElementDelta(
            element.id, id in added_elements ? "added" : "updated",
            element.occupancy, element.custom_metrics
        ))
    end
    for id in dirty.elements_removed
        push!(changed_elements, DirectElementDelta(id, "removed", nothing, nothing))
    end

    added_entities = DirectAddedEntity[]
    updated_entities = DirectUpdatedEntity[]
    added_ids = Set(dirty.entities_added)
    for id in [dirty.entities_added; dirty.entities_updated]
        entity = cache.entities[id]
        if id in added_ids
            push!(added_entities, DirectAddedEntity(
                entity.id, "arrived", entity.current_location, entity.trajectory_2d
            ))
        else
            push!(updated_entities, DirectUpdatedEntity(
                entity.id, "updated", entity.properties
            ))
        end
    end

    return DirectDeltaPayload(
        current.snapshot_version, current.scene_id, current.simulation_time,
        current.step_count, "revision-$(dirty.revision)", changed_elements,
        added_entities, dirty.entities_removed, updated_entities, nothing,
        Dict{String, Any}[]
    )
end

function encode_direct_dirty_delta(
    cache::IncrementalStateCache,
    dirty::DirtyState,
    current::SnapshotPayload;
    kwargs...
)::Vector{UInt8}
    return encode_direct_delta(direct_dirty_delta_payload(cache, dirty, current); kwargs...)
end

export IncrementalStateCache, seed_cache!, apply_dirty_state!
export cached_elements, cached_entities, dirty_delta_payload
export direct_dirty_delta_payload
export encode_direct_dirty_delta
