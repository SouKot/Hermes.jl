using Statistics
using GodotBridge

mutable struct BenchmarkAdapter <: GodotBridge.SimulationAdapter
    current_time::Float64
    elements::Vector{GodotBridge.ElementState}
    entities::Vector{GodotBridge.EntitySnapshot}
end

GodotBridge.abm_capability(::BenchmarkAdapter) = GodotBridge.NoABM()
GodotBridge.get_simulation_time(adapter::BenchmarkAdapter) = adapter.current_time
GodotBridge.get_elements_snapshot(adapter::BenchmarkAdapter) = adapter.elements
GodotBridge.get_entities_snapshot(adapter::BenchmarkAdapter) = adapter.entities
GodotBridge.dispatch_command(::BenchmarkAdapter, command) = command

function build_adapter(element_count::Int)
    elements = [
        GodotBridge.ElementState(
            "element-$index", "queue", UInt32(index % 100),
            Dict{String, Any}("throughput" => Float64(index % 17))
        ) for index in 1:element_count
    ]
    return BenchmarkAdapter(0.0, elements, GodotBridge.EntitySnapshot[])
end

function milliseconds(start_ns, stop_ns)
    return (stop_ns - start_ns) / 1.0e6
end

function measure_element_scale(counts=[10_000, 20_000, 50_000, 100_000]; iterations=5)
    println("Element scaling benchmark")
    println("count,extract_ms,full_pack_ms,full_bytes,delta_pack_ms,delta_bytes")
    for count in counts
        adapter = build_adapter(count)
        extracted_times = Float64[]
        full_pack_times = Float64[]
        full_sizes = Int[]
        delta_pack_times = Float64[]
        delta_sizes = Int[]
        builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=1000)

        # Warm up compilation before recording measurements.
        warmup = GodotBridge.build_snapshot(
            "benchmark", adapter.current_time, UInt64(1), 1.0f0,
            "running", adapter.elements, adapter.entities
        )
        GodotBridge.encode_messagepack(GodotBridge.wrap_snapshot_in_message(warmup))

        for _ in 1:iterations
            start = time_ns()
            snapshot = GodotBridge.build_snapshot(
                "benchmark", adapter.current_time, UInt64(1), 1.0f0,
                "running", adapter.elements, adapter.entities
            )
            push!(extracted_times, milliseconds(start, time_ns()))

            full_message = GodotBridge.wrap_snapshot_in_message(snapshot)
            start = time_ns()
            full_bytes = GodotBridge.encode_messagepack(full_message)
            push!(full_pack_times, milliseconds(start, time_ns()))
            push!(full_sizes, length(full_bytes))

            adapter.current_time += 1.0
            builder.update_count = 1
            builder.last_snapshot = snapshot
            current = GodotBridge.build_snapshot_from_adapter(builder)
            delta = GodotBridge.DeltaBuilder.build_delta(snapshot, current)
            delta_message = GodotBridge.DeltaBuilder.create_delta_message(
                delta; snapshot_version=current.snapshot_version,
                scene_id=current.scene_id, simulation_time=current.simulation_time,
                step_count=current.step_count
            )
            start = time_ns()
            delta_bytes = GodotBridge.encode_messagepack(delta_message)
            push!(delta_pack_times, milliseconds(start, time_ns()))
            push!(delta_sizes, length(delta_bytes))
        end

        println(join([
            count,
            round(mean(extracted_times); digits=2),
            round(mean(full_pack_times); digits=2),
            round(mean(full_sizes); digits=0),
            round(mean(delta_pack_times); digits=2),
            round(mean(delta_sizes); digits=0)
        ], ","))
    end
end

function measure_command_throughput(command_count=1000)
    adapter = BenchmarkAdapter(0.0, GodotBridge.ElementState[], GodotBridge.EntitySnapshot[])
    pool = GodotBridge.CommandWorkerPool(adapter; num_workers=4, capacity=command_count)
    GodotBridge.start_pool!(pool)
    warmup_future = GodotBridge.submit_command(pool, :warmup)
    GodotBridge.wait_result(warmup_future)
    start = time_ns()
    futures = [GodotBridge.submit_command(pool, :step) for _ in 1:command_count]
    for future in futures
        GodotBridge.wait_result(future)
    end
    elapsed = (time_ns() - start) / 1.0e9
    stats = GodotBridge.get_latency_stats(futures)
    GodotBridge.stop_pool!(pool)
    println("Command throughput benchmark")
    println("commands=$(command_count),elapsed_s=$(round(elapsed; digits=3)),throughput_per_s=$(round(command_count / elapsed; digits=1)),mean_latency_ms=$(round(1000 * stats[:mean]; digits=3)),p99_ms=$(round(1000 * stats[:p99]; digits=3))")
end

measure_element_scale()
measure_command_throughput()
