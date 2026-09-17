"""Return all element snapshots, using the adapter's batch method."""
function extract_elements_parallel(
    adapter::SimulationAdapter;
    min_parallel_size::Int=100,
    workers::Int=Threads.nthreads()
)::Vector{ElementState}
    workers > 0 || throw(ArgumentError("workers must be positive"))
    elements = collect(get_elements_snapshot(adapter))
    length(elements) < min_parallel_size && return elements

    # The adapter owns engine access. Parallelize only the pure result copy so
    # adapters that are not thread-safe are never queried concurrently.
    result = Vector{ElementState}(undef, length(elements))
    Threads.@threads :static for index in eachindex(elements)
        result[index] = elements[index]
    end
    return result
end

"""
    extract_elements_cached(adapter, cache; current_time=nothing, fetcher=nothing)

Extract element state through a TTL cache. If `fetcher` is omitted, the
adapter's batch snapshot is used and no per-element engine hook is required.
"""
function extract_elements_cached(
    adapter::SimulationAdapter,
    cache::ElementStateCache;
    current_time::Union{Float64, Nothing}=nothing,
    fetcher::Union{Function, Nothing}=nothing
)::Vector{ElementState}
    timestamp = isnothing(current_time) ? Float64(get_simulation_time(adapter)) : current_time
    source = get_elements_snapshot(adapter)

    if timestamp - cache.last_cleanup >= cache.ttl * 10
        clear_expired!(cache, timestamp)
    end

    if isnothing(fetcher)
        fetcher = element_id -> begin
            for element in source
                element.id == element_id && return element
            end
            throw(KeyError(element_id))
        end
    end

    return [get_cached_element(cache, element.id, timestamp, fetcher) for element in source]
end

export extract_elements_parallel, extract_elements_cached
