"""
    ElementStateCache

Thread-safe TTL cache for element snapshots. The cache stores the existing
`ElementState` values without copying them and tracks hit/miss statistics.
"""
mutable struct ElementStateCache
    values::Dict{String, ElementState}
    timestamps::Dict{String, Float64}
    ttl::Float64
    last_cleanup::Float64
    hits::UInt64
    misses::UInt64
    lock::ReentrantLock
end

function ElementStateCache(ttl::Float64=0.1)
    ttl >= 0.0 || throw(ArgumentError("cache TTL must be non-negative"))
    return ElementStateCache(
        Dict{String, ElementState}(), Dict{String, Float64}(),
        ttl, 0.0, 0, 0, ReentrantLock()
    )
end

function get_cached_element(
    cache::ElementStateCache,
    element_id::String,
    current_time::Float64,
    fetcher::Function
)::ElementState
    cached_value = nothing
    lock(cache.lock) do
        if haskey(cache.values, element_id)
            age = current_time - cache.timestamps[element_id]
            if age >= 0.0 && age < cache.ttl
                cache.hits += 1
                cached_value = cache.values[element_id]
            end
        end
    end

    cached_value !== nothing && return cached_value

    value = fetcher(element_id)
    value isa ElementState || throw(ArgumentError("fetcher must return ElementState"))

    lock(cache.lock) do
        cache.values[element_id] = value
        cache.timestamps[element_id] = current_time
        cache.misses += 1
    end
    return value
end

function clear_expired!(cache::ElementStateCache, current_time::Float64)
    lock(cache.lock) do
        expired = String[]
        for (element_id, timestamp) in cache.timestamps
            if current_time - timestamp >= cache.ttl
                push!(expired, element_id)
            end
        end
        for element_id in expired
            delete!(cache.values, element_id)
            delete!(cache.timestamps, element_id)
        end
        cache.last_cleanup = current_time
        return length(expired)
    end
end

# Compatibility alias used by the roadmap examples.
clear_expired(cache::ElementStateCache, current_time::Float64) =
    clear_expired!(cache, current_time)

function clear!(cache::ElementStateCache)
    lock(cache.lock) do
        empty!(cache.values)
        empty!(cache.timestamps)
        cache.last_cleanup = 0.0
        cache.hits = 0
        cache.misses = 0
    end
    return cache
end

function cache_stats(cache::ElementStateCache)
    lock(cache.lock) do
        total = cache.hits + cache.misses
        return (
            hits=cache.hits,
            misses=cache.misses,
            size=length(cache.values),
            hit_rate=total == 0 ? 0.0 : Float64(cache.hits) / total
        )
    end
end

export ElementStateCache, get_cached_element, clear_expired, clear_expired!, clear!, cache_stats
