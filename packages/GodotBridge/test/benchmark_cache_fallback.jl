using Statistics
using GodotBridge

struct CacheBenchmarkAdapter <: GodotBridge.SimulationAdapter
    elements::Vector{GodotBridge.ElementState}
end

GodotBridge.abm_capability(::CacheBenchmarkAdapter) = GodotBridge.NoABM()
GodotBridge.get_simulation_time(::CacheBenchmarkAdapter) = 1.0
GodotBridge.get_elements_snapshot(adapter::CacheBenchmarkAdapter) = adapter.elements
GodotBridge.get_entities_snapshot(::CacheBenchmarkAdapter) = GodotBridge.EntitySnapshot[]

function make_elements(count)
    return [
        GodotBridge.ElementState(
            "element-$index", "queue", UInt32(index % 100),
            Dict{String, Any}()
        ) for index in 1:count
    ]
end

function old_linear_fallback(source)
    result = Vector{GodotBridge.ElementState}(undef, length(source))
    for output_index in eachindex(source)
        wanted_id = source[output_index].id
        for element in source
            if element.id == wanted_id
                result[output_index] = element
                break
            end
        end
    end
    return result
end

function time_call(f; repetitions=3)
    f()
    samples = Float64[]
    for _ in 1:repetitions
        start = time_ns()
        f()
        push!(samples, (time_ns() - start) / 1.0e6)
    end
    return mean(samples)
end

println("Cold/expired ElementStateCache fallback benchmark")
println("elements,old_linear_ms,indexed_cache_ms,speedup")
for count in [1_000, 5_000, 10_000]
    elements = make_elements(count)
    adapter = CacheBenchmarkAdapter(elements)
    old_ms = time_call(() -> old_linear_fallback(elements))
    new_ms = time_call(() -> GodotBridge.extract_elements_cached(
        adapter, GodotBridge.ElementStateCache(0.0); current_time=1.0
    ))
    println(join([
        count,
        round(old_ms; digits=3),
        round(new_ms; digits=3),
        round(old_ms / new_ms; digits=2)
    ], ","))
end
