using Statistics
using GodotBridge

mutable struct StressAdapter <: GodotBridge.SimulationAdapter
    current_time::Float64
    elements::Vector{GodotBridge.ElementState}
    entities::Vector{GodotBridge.EntitySnapshot}
end

GodotBridge.abm_capability(::StressAdapter) = GodotBridge.NoABM()
GodotBridge.get_simulation_time(adapter::StressAdapter) = adapter.current_time
GodotBridge.get_elements_snapshot(adapter::StressAdapter) = adapter.elements
GodotBridge.get_entities_snapshot(adapter::StressAdapter) = adapter.entities
GodotBridge.dispatch_command(::StressAdapter, command) = command

function build_stress_adapter(element_count::Int)
    elements = [
        GodotBridge.ElementState(
            "element-$index", "queue", UInt32(index % 100),
            Dict{String, Any}("throughput" => Float64(index % 17))
        ) for index in 1:element_count
    ]
    return StressAdapter(0.0, elements, GodotBridge.EntitySnapshot[])
end

function bytes_per_second(bytes, elapsed)
    return elapsed == 0.0 ? Inf : bytes / elapsed
end

function stress_changed_state(element_count::Int; updates::Int=20, changed_fraction::Float64=0.01)
    adapter = build_stress_adapter(element_count)
    builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=10)
    changed_count = max(1, round(Int, element_count * changed_fraction))
    full_sizes = Int[]
    delta_sizes = Int[]
    elapsed_times = Float64[]

    for update in 1:updates
        start = time_ns()
        message = GodotBridge.build_next_snapshot(builder)
        elapsed = (time_ns() - start) / 1.0e9
        push!(elapsed_times, elapsed)
        encoded = GodotBridge.encode_messagepack(message)
        if message.payload isa GodotBridge.SnapshotPayload
            push!(full_sizes, length(encoded))
        else
            push!(delta_sizes, length(encoded))
        end

        # Change a small, deterministic subset of element state each frame.
        for index in 1:changed_count
            element_index = mod1(index + update, element_count)
            element = adapter.elements[element_index]
            element.occupancy = UInt32(mod(Int(element.occupancy) + 1, 100))
            element.custom_metrics["throughput"] = Float64(update)
        end
        adapter.current_time += 0.1
    end

    stats = GodotBridge.adaptive_statistics(builder)
    return (
        elements=element_count,
        changed=changed_count,
        updates=updates,
        mean_update_ms=1000 * mean(elapsed_times),
        p99_update_ms=1000 * sort(elapsed_times)[clamp(ceil(Int, 0.99 * length(elapsed_times)), 1, length(elapsed_times))],
        full_bytes=isempty(full_sizes) ? 0 : mean(full_sizes),
        delta_bytes=isempty(delta_sizes) ? 0 : mean(delta_sizes),
        savings_percent=stats[:estimated_savings_percent],
        full_count=stats[:full_snapshots],
        delta_count=stats[:deltas]
    )
end

function stress_command_rate(command_count::Int=10_000)
    adapter = build_stress_adapter(0)
    pool = GodotBridge.CommandWorkerPool(adapter; num_workers=4, capacity=command_count)
    GodotBridge.start_pool!(pool)
    start = time_ns()
    futures = [GodotBridge.submit_command(pool, :step) for _ in 1:command_count]
    foreach(GodotBridge.wait_result, futures)
    elapsed = (time_ns() - start) / 1.0e9
    stats = GodotBridge.get_latency_stats(futures)
    GodotBridge.stop_pool!(pool)
    return (
        commands=command_count,
        elapsed_seconds=elapsed,
        commands_per_second=command_count / elapsed,
        mean_latency_ms=1000 * stats[:mean],
        p99_latency_ms=1000 * stats[:p99]
    )
end

function stress_long_run(element_count::Int=10_000; updates::Int=100)
    adapter = build_stress_adapter(element_count)
    builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=10)
    start = time_ns()
    total_bytes = 0
    for update in 1:updates
        message = GodotBridge.build_next_snapshot(builder)
        total_bytes += length(GodotBridge.encode_messagepack(message))
        adapter.current_time += 0.1
        if !isempty(adapter.elements)
            adapter.elements[mod1(update, length(adapter.elements))].occupancy += UInt32(1)
        end
    end
    elapsed = (time_ns() - start) / 1.0e9
    GC.gc()
    return (
        updates=updates,
        elapsed_seconds=elapsed,
        updates_per_second=updates / elapsed,
        total_bytes=total_bytes,
        live_bytes_after_run=Base.gc_live_bytes()
    )
end

println("Changed-state stress benchmark")
println("elements,changed,updates,mean_update_ms,p99_update_ms,full_bytes,delta_bytes,savings_percent,full_count,delta_count")
for count in [10_000, 20_000, 50_000, 100_000]
    # Keep the 100K probe bounded while retaining the longer workload for
    # smaller scales. Use stress_changed_state(count; updates=20) for a full
    # 100K run when the machine can sustain it.
    updates = count == 100_000 ? 3 : 20
    result = stress_changed_state(count; updates=updates)
    println(join([
        result.elements, result.changed, result.updates,
        round(result.mean_update_ms; digits=2), round(result.p99_update_ms; digits=2),
        round(result.full_bytes; digits=0), round(result.delta_bytes; digits=0),
        round(result.savings_percent; digits=2), result.full_count, result.delta_count
    ], ","))
end

println("Command stress benchmark: ", stress_command_rate())
println("Long-run stability benchmark: ", stress_long_run())
