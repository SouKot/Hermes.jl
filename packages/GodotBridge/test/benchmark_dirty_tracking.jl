using Statistics
using GodotBridge

mutable struct DirtyBenchmarkAdapter <: GodotBridge.SimulationAdapter
    current_time::Float64
    elements::Dict{String, GodotBridge.ElementState}
    pending::GodotBridge.DirtyState
end

GodotBridge.abm_capability(::DirtyBenchmarkAdapter) = GodotBridge.NoABM()
GodotBridge.supports_dirty_tracking(::DirtyBenchmarkAdapter) = true
GodotBridge.dirty_state(adapter::DirtyBenchmarkAdapter) = adapter.pending
GodotBridge.get_simulation_time(adapter::DirtyBenchmarkAdapter) = adapter.current_time
GodotBridge.get_elements_snapshot(adapter::DirtyBenchmarkAdapter) = collect(values(adapter.elements))
GodotBridge.get_entities_snapshot(::DirtyBenchmarkAdapter) = GodotBridge.EntitySnapshot[]
GodotBridge.get_element_state(adapter::DirtyBenchmarkAdapter, id::String) = adapter.elements[id]
GodotBridge.get_entity_state(::DirtyBenchmarkAdapter, id::String) = error("no entities")
GodotBridge.clear_dirty_state!(::DirtyBenchmarkAdapter, ::UInt64) = nothing
GodotBridge.dispatch_command(::DirtyBenchmarkAdapter, command) = command

function make_adapter(count)
    elements = Dict{String, GodotBridge.ElementState}()
    for index in 1:count
        id = "element-$index"
        elements[id] = GodotBridge.ElementState(
            id, "queue", UInt32(index % 100),
            Dict{String, Any}("throughput" => Float64(index % 17))
        )
    end
    return DirtyBenchmarkAdapter(0.0, elements, GodotBridge.DirtyState(revision=1))
end

function run_incremental(count; updates=20, fraction=0.01, direct=false)
    adapter = make_adapter(count)
    builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=1000)
    direct ? GodotBridge.build_next_snapshot_bytes(builder) : GodotBridge.build_next_snapshot(builder; encoding=:generic)
    changed = max(1, round(Int, count * fraction))
    times = Float64[]
    sizes = Int[]

    # Warm up dirty extraction, delta construction, and serialization.
    warmup_ids = ["element-$(mod1(index, count))" for index in 1:changed]
    adapter.pending = GodotBridge.DirtyState(elements_updated=warmup_ids, revision=2)
    direct ? GodotBridge.build_next_snapshot_bytes(builder) : GodotBridge.build_next_snapshot(builder; encoding=:generic)

    for update in 1:updates
        ids = ["element-$(mod1(index + update, count))" for index in 1:changed]
        for id in ids
            adapter.elements[id].occupancy += UInt32(1)
        end
        adapter.pending = GodotBridge.DirtyState(elements_updated=ids, revision=update + 2)
        adapter.current_time += 0.1
        start = time_ns()
        message = direct ? GodotBridge.build_next_snapshot_bytes(builder) :
            GodotBridge.build_next_snapshot(builder; encoding=:generic)
        push!(times, (time_ns() - start) / 1.0e6)
        push!(sizes, direct ? length(message) :
            length(GodotBridge.encode_messagepack(message)))
    end
    return (
        count=count,
        changed=changed,
        mean_ms=mean(times),
        p99_ms=sort(times)[clamp(ceil(Int, 0.99 * length(times)), 1, length(times))],
        mean_bytes=mean(sizes)
    )
end

println("Dirty-state incremental benchmark")
println("elements,changed,mean_ms,p99_ms,mean_delta_bytes")
for count in [10_000, 50_000, 100_000, 500_000]
    result = run_incremental(count)
    println(join([
        result.count, result.changed, round(result.mean_ms; digits=3),
        round(result.p99_ms; digits=3), round(result.mean_bytes; digits=0)
    ], ","))
end
