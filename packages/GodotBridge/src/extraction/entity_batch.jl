"""Extract entity snapshots through the adapter's batch interface."""
function extract_entities_vectorized(
    adapter::SimulationAdapter;
    trajectory_buffers::Union{Dict{String, TrajectoryRingBuffer}, Nothing}=nothing,
    current_time::Union{Float64, Nothing}=nothing
)::Vector{EntitySnapshot}
    entities = collect(get_entities_snapshot(adapter))
    isnothing(trajectory_buffers) && return entities

    timestamp = isnothing(current_time) ? Float64(get_simulation_time(adapter)) : current_time
    result = Vector{EntitySnapshot}(undef, length(entities))
    for index in eachindex(entities)
        entity = entities[index]
        buffer = get(trajectory_buffers, entity.id, nothing)
        if isnothing(buffer)
            result[index] = entity
            continue
        end
        for coordinate in entity.trajectory_2d
            add_point!(buffer, coordinate, timestamp)
        end
        result[index] = EntitySnapshot(
            entity.id,
            entity.entity_type,
            entity.current_location,
            entity.arrival_time,
            get_trajectory(buffer),
            entity.properties
        )
    end
    return result
end

"""Batch hook for adapters that provide a more efficient trajectory lookup."""
function batch_get_trajectories(
    adapter::SimulationAdapter,
    ids::AbstractVector{<:AbstractString}
)
    entities = get_entities_snapshot(adapter)
    by_id = Dict(entity.id => entity.trajectory_2d for entity in entities)
    return [get(by_id, String(id), Vector{Vector{Float64}}()) for id in ids]
end

export extract_entities_vectorized, batch_get_trajectories
