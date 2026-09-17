using Statistics
using GodotBridge

mutable struct CleanBenchmarkAdapter <: GodotBridge.SimulationAdapter
    current_time::Float64
    elements::Dict{String, GodotBridge.ElementState}
    pending::GodotBridge.DirtyState
end

GodotBridge.abm_capability(::CleanBenchmarkAdapter) = GodotBridge.NoABM()
GodotBridge.supports_dirty_tracking(::CleanBenchmarkAdapter) = true
GodotBridge.dirty_state(adapter::CleanBenchmarkAdapter) = adapter.pending
GodotBridge.get_simulation_time(adapter::CleanBenchmarkAdapter) = adapter.current_time
GodotBridge.get_elements_snapshot(adapter::CleanBenchmarkAdapter) = collect(values(adapter.elements))
GodotBridge.get_entities_snapshot(::CleanBenchmarkAdapter) = GodotBridge.EntitySnapshot[]
GodotBridge.get_element_state(adapter::CleanBenchmarkAdapter, id::String) = adapter.elements[id]
GodotBridge.get_entity_state(::CleanBenchmarkAdapter, id::String) = error("no entities")
GodotBridge.clear_dirty_state!(::CleanBenchmarkAdapter, ::UInt64) = nothing
GodotBridge.dispatch_command(::CleanBenchmarkAdapter, command) = command

function make_elements(count)
    elements = Dict{String, GodotBridge.ElementState}()
    for index in 1:count
        id = "element-$index"
        elements[id] = GodotBridge.ElementState(
            id, "queue", UInt32(index % 100),
            Dict{String, Any}("throughput" => Float64(index % 17))
        )
    end
    return elements
end

function run_mode(; direct::Bool, count=500_000, changed_count=50_000, updates=20)
    adapter = CleanBenchmarkAdapter(0.0, make_elements(count),
        GodotBridge.DirtyState(revision=1))
    builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=1000)
    initial = direct ? GodotBridge.build_next_snapshot_bytes(builder) :
        GodotBridge.build_next_snapshot(builder; encoding=:generic)

    ids = ["element-$(index)" for index in 1:changed_count]
    adapter.pending = GodotBridge.DirtyState(elements_updated=ids, revision=2)
    warmup = direct ? GodotBridge.build_next_snapshot_bytes(builder) :
        GodotBridge.build_next_snapshot(builder; encoding=:generic)

    times = Float64[]
    sizes = Int[]
    for update in 1:updates
        shifted_ids = ["element-$(mod1(index + update, count))" for index in 1:changed_count]
        for id in shifted_ids
            adapter.elements[id].occupancy += UInt32(1)
        end
        adapter.pending = GodotBridge.DirtyState(
            elements_updated=shifted_ids, revision=UInt64(update + 2)
        )
        adapter.current_time += 0.1
        start = time_ns()
        result = direct ? GodotBridge.build_next_snapshot_bytes(builder) :
            GodotBridge.build_next_snapshot(builder; encoding=:generic)
        elapsed_ms = (time_ns() - start) / 1.0e6
        push!(times, elapsed_ms)
        push!(sizes, direct ? length(result) : length(GodotBridge.encode_messagepack(result)))
    end
    sorted = sort(times)
    return (
        direct=direct,
        updates=updates,
        changed=changed_count,
        mean_ms=mean(times),
        p50_ms=sorted[clamp(ceil(Int, 0.50 * length(sorted)), 1, length(sorted))],
        p99_ms=sorted[clamp(ceil(Int, 0.99 * length(sorted)), 1, length(sorted))],
        mean_bytes=mean(sizes),
        min_bytes=minimum(sizes),
        max_bytes=maximum(sizes)
    )
end

# Compile and warm both paths before the measured iterations.
generic = run_mode(direct=false)
typed = run_mode(direct=true)
println("generic=", generic)
println("typed=", typed)
println("mean_speedup=", generic.mean_ms / typed.mean_ms)
println("typed_under_30fps=", typed.mean_ms < 33.333333)
