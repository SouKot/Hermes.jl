"""Change tracking contract for adapters that can expose engine-owned dirty IDs."""
struct DirtyState
    elements_added::Vector{String}
    elements_updated::Vector{String}
    elements_removed::Vector{String}
    entities_added::Vector{String}
    entities_updated::Vector{String}
    entities_removed::Vector{String}
    abm_fields_changed::Set{Symbol}
    revision::UInt64
    full_scan::Bool
end

function DirtyState(; elements_added=String[], elements_updated=String[],
    elements_removed=String[], entities_added=String[], entities_updated=String[],
    entities_removed=String[], abm_fields_changed=Set{Symbol}(), revision=0,
    full_scan::Bool=false)
    deduplicate(values) = unique(String.(values))
    return DirtyState(
        deduplicate(elements_added), deduplicate(elements_updated), deduplicate(elements_removed),
        deduplicate(entities_added), deduplicate(entities_updated), deduplicate(entities_removed),
        Set{Symbol}(abm_fields_changed), UInt64(revision), full_scan
    )
end

"""Return true when an adapter can provide precise dirty IDs."""
supports_dirty_tracking(::SimulationAdapter) = false

"""Default fallback: the bridge must use a complete state extraction."""
dirty_state(::SimulationAdapter) = DirtyState(full_scan=true)

"""Fetch one changed element. Dirty-tracking adapters must implement this."""
function get_element_state(adapter::SimulationAdapter, id::String)::ElementState
    error("get_element_state not implemented for $(typeof(adapter))")
end

"""Fetch one changed entity. Dirty-tracking adapters must implement this."""
function get_entity_state(adapter::SimulationAdapter, id::String)::EntitySnapshot
    error("get_entity_state not implemented for $(typeof(adapter))")
end

"""Acknowledge a revision after the bridge has consumed it."""
clear_dirty_state!(::SimulationAdapter, ::UInt64) = nothing

"""Whether independent state fetches may run on Julia worker threads."""
supports_parallel_state_fetch(::SimulationAdapter) = false

"""Whether the adapter's dirty values are produced by a GPU backend."""
supports_gpu_state_fetch(adapter::SimulationAdapter) = has_feature(adapter, SupportsGPU)

"""Synchronization boundary for GPU-backed adapters; no-op for CPU adapters."""
synchronize_gpu_state!(::SimulationAdapter) = nothing

function get_element_states(adapter::SimulationAdapter, ids::AbstractVector{<:AbstractString})
    if supports_parallel_state_fetch(adapter) && length(ids) > 1
        result = Vector{ElementState}(undef, length(ids))
        Threads.@threads :static for index in eachindex(ids)
            result[index] = get_element_state(adapter, String(ids[index]))
        end
        return result
    end
    return [get_element_state(adapter, String(id)) for id in ids]
end

function get_entity_states(adapter::SimulationAdapter, ids::AbstractVector{<:AbstractString})
    if supports_parallel_state_fetch(adapter) && length(ids) > 1
        result = Vector{EntitySnapshot}(undef, length(ids))
        Threads.@threads :static for index in eachindex(ids)
            result[index] = get_entity_state(adapter, String(ids[index]))
        end
        return result
    end
    return [get_entity_state(adapter, String(id)) for id in ids]
end

export DirtyState, supports_dirty_tracking, dirty_state
export get_element_state, get_entity_state, clear_dirty_state!
export supports_parallel_state_fetch, get_element_states, get_entity_states
export supports_gpu_state_fetch, synchronize_gpu_state!
