using BenchmarkTools
using Statistics
using GodotBridge
using MsgPack

mutable struct AcceptanceAdapter <: GodotBridge.SimulationAdapter
    current_time::Float64
    elements::Dict{String, GodotBridge.ElementState}
    pending::GodotBridge.DirtyState
end

GodotBridge.abm_capability(::AcceptanceAdapter) = GodotBridge.NoABM()
GodotBridge.supports_dirty_tracking(::AcceptanceAdapter) = true
GodotBridge.dirty_state(adapter::AcceptanceAdapter) = adapter.pending
GodotBridge.get_simulation_time(adapter::AcceptanceAdapter) = adapter.current_time
GodotBridge.get_elements_snapshot(adapter::AcceptanceAdapter) = collect(values(adapter.elements))
GodotBridge.get_entities_snapshot(::AcceptanceAdapter) = GodotBridge.EntitySnapshot[]
GodotBridge.get_element_state(adapter::AcceptanceAdapter, id::String) = adapter.elements[id]
GodotBridge.get_entity_state(::AcceptanceAdapter, id::String) = error("no entities")
GodotBridge.clear_dirty_state!(::AcceptanceAdapter, ::UInt64) = nothing
GodotBridge.dispatch_command(::AcceptanceAdapter, command) = command

function make_adapter(count)
    elements = Dict{String, GodotBridge.ElementState}()
    for index in 1:count
        id = "element-$index"
        elements[id] = GodotBridge.ElementState(
            id, "queue", UInt32(index % 100),
            Dict{String, Any}("throughput" => Float64(index % 17))
        )
    end
    return AcceptanceAdapter(0.0, elements, GodotBridge.DirtyState(revision=1))
end

function update!(adapter, ids, revision)
    for id in ids
        adapter.elements[id].occupancy += UInt32(1)
    end
    adapter.pending = GodotBridge.DirtyState(elements_updated=ids, revision=revision)
    adapter.current_time += 0.1
end

function run_stability(count=10_000; updates=1_000, changed=100)
    adapter = make_adapter(count)
    builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=1000)
    GodotBridge.build_next_snapshot_bytes(builder)
    ids = ["element-$(index)" for index in 1:changed]
    times = Float64[]
    total_bytes = 0
    for update_index in 1:updates
        update!(adapter, ids, UInt64(update_index + 1))
        start = time_ns()
        bytes = GodotBridge.build_next_snapshot_bytes(builder)
        push!(times, (time_ns() - start) / 1.0e6)
        total_bytes += length(bytes)
    end
    GC.gc()
    sorted = sort(times)
    return (
        updates=updates,
        mean_ms=mean(times),
        p99_ms=sorted[clamp(ceil(Int, 0.99 * length(sorted)), 1, length(sorted))],
        updates_per_second=1000.0 / mean(times),
        total_bytes=total_bytes,
        live_bytes=Base.gc_live_bytes()
    )
end

function run_command_stability(count=10_000)
    adapter = make_adapter(0)
    pool = GodotBridge.CommandWorkerPool(adapter; num_workers=4, capacity=count)
    GodotBridge.start_pool!(pool)
    start = time_ns()
    futures = [GodotBridge.submit_command(pool, :step) for _ in 1:count]
    foreach(GodotBridge.wait_result, futures)
    elapsed = (time_ns() - start) / 1.0e9
    stats = GodotBridge.get_latency_stats(futures)
    GodotBridge.stop_pool!(pool)
    return (
        commands=count,
        commands_per_second=count / elapsed,
        mean_latency_ms=1000 * stats[:mean],
        p99_latency_ms=1000 * stats[:p99]
    )
end

adapter = make_adapter(10_000)
profile = GodotBridge.profile_adapter(adapter; iterations=10)
elements = collect(values(adapter.elements))
entities = GodotBridge.EntitySnapshot[]
snapshot = GodotBridge.build_snapshot(
    "acceptance", 1.0, UInt64(1), 1.0f0, "running",
    elements, entities
)
generic_message = GodotBridge.wrap_snapshot_in_message(snapshot)
generic_trial = @benchmark GodotBridge.encode_messagepack(
    $generic_message
) samples=10 evals=1
typed_trial = @benchmark GodotBridge.encode_direct_snapshot(
    "acceptance", 1.0, UInt64(1), $elements, $entities
) samples=10 evals=1
serialized = GodotBridge.encode_direct_snapshot(
    "acceptance", 1.0, UInt64(1), elements, entities
)
decoded = MsgPack.unpack(serialized)

println("adapter_profile=", GodotBridge.profile_summary(profile))
println("transport_generic_median_ms=", median(generic_trial.times) / 1.0e6)
println("transport_typed_median_ms=", median(typed_trial.times) / 1.0e6)
println("transport_typed_speedup=", median(generic_trial.times) / median(typed_trial.times))
println("transport_payload_bytes=", length(serialized))
println("transport_schema_ok=", decoded["kind"] == "snapshot" &&
    decoded["payload"]["scene_id"] == "acceptance")
println("update_stability=", run_stability())
println("command_stability=", run_command_stability())
