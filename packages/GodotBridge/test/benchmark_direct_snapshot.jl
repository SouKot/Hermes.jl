using Statistics
using GodotBridge

function snapshot_state(count)
    elements = [
        ElementState(
            "element-$index", "queue", UInt32(index % 100),
            Dict{String, Any}("throughput" => Float64(index % 17))
        ) for index in 1:count
    ]
    return elements, EntitySnapshot[]
end

function compare_full_snapshot(count; iterations=5)
    elements, entities = snapshot_state(count)
    generic_times = Float64[]
    direct_times = Float64[]
    generic_sizes = Int[]
    direct_sizes = Int[]

    # Warm up both paths.
    generic = build_snapshot("benchmark", 1.0, UInt64(1), 1.0f0, "running", elements, entities)
    encode_messagepack(wrap_snapshot_in_message(generic))
    encode_direct_snapshot("benchmark", 1.0, UInt64(1), elements, entities)

    for iteration in 1:iterations
        start = time_ns()
        generic = build_snapshot("benchmark", Float64(iteration), UInt64(iteration),
            1.0f0, "running", elements, entities)
        generic_bytes = encode_messagepack(wrap_snapshot_in_message(generic))
        push!(generic_times, (time_ns() - start) / 1.0e6)
        push!(generic_sizes, length(generic_bytes))

        start = time_ns()
        direct_bytes = encode_direct_snapshot(
            "benchmark", Float64(iteration), UInt64(iteration), elements, entities
        )
        push!(direct_times, (time_ns() - start) / 1.0e6)
        push!(direct_sizes, length(direct_bytes))
    end

    return (
        elements=count,
        generic_ms=mean(generic_times),
        direct_ms=mean(direct_times),
        generic_p99_ms=sort(generic_times)[clamp(ceil(Int, 0.99 * iterations), 1, iterations)],
        direct_p99_ms=sort(direct_times)[clamp(ceil(Int, 0.99 * iterations), 1, iterations)],
        generic_bytes=mean(generic_sizes),
        direct_bytes=mean(direct_sizes)
    )
end

println("Typed full snapshot benchmark")
for count in [10_000, 100_000, 500_000]
    println(compare_full_snapshot(count))
end
