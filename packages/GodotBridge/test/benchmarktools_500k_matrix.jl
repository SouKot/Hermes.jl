using BenchmarkTools
using Statistics
using GodotBridge

mutable struct MatrixAdapter <: GodotBridge.SimulationAdapter
    current_time::Float64
    elements::Dict{String, GodotBridge.ElementState}
    pending::GodotBridge.DirtyState
end

GodotBridge.abm_capability(::MatrixAdapter) = GodotBridge.NoABM()
GodotBridge.supports_dirty_tracking(::MatrixAdapter) = true
GodotBridge.dirty_state(adapter::MatrixAdapter) = adapter.pending
GodotBridge.get_simulation_time(adapter::MatrixAdapter) = adapter.current_time
GodotBridge.get_elements_snapshot(adapter::MatrixAdapter) = collect(values(adapter.elements))
GodotBridge.get_entities_snapshot(::MatrixAdapter) = GodotBridge.EntitySnapshot[]
GodotBridge.get_element_state(adapter::MatrixAdapter, id::String) = adapter.elements[id]
GodotBridge.get_entity_state(::MatrixAdapter, id::String) = error("no entities")
GodotBridge.clear_dirty_state!(::MatrixAdapter, ::UInt64) = nothing
GodotBridge.dispatch_command(::MatrixAdapter, command) = command

mutable struct MatrixCase
    adapter::MatrixAdapter
    builder::GodotBridge.AdaptiveSnapshotBuilder
    ids::Vector{String}
    revision::UInt64
end

function make_case(count, fraction)
    elements = Dict{String, GodotBridge.ElementState}()
    for index in 1:count
        id = "element-$index"
        elements[id] = GodotBridge.ElementState(
            id, "queue", UInt32(index % 100),
            Dict{String, Any}("throughput" => Float64(index % 17))
        )
    end
    adapter = MatrixAdapter(0.0, elements, GodotBridge.DirtyState(revision=1))
    builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=1000)
    GodotBridge.build_next_snapshot_bytes(builder)
    changed = round(Int, count * fraction)
    ids = ["element-$index" for index in 1:changed]
    return MatrixCase(adapter, builder, ids, UInt64(1))
end

function step_case!(case::MatrixCase, direct::Bool)
    case.revision += UInt64(1)
    for id in case.ids
        case.adapter.elements[id].occupancy += UInt32(1)
    end
    case.adapter.pending = GodotBridge.DirtyState(
        elements_updated=case.ids, revision=case.revision
    )
    case.builder.update_count = 1
    return direct ? GodotBridge.build_next_snapshot_bytes(case.builder) :
        GodotBridge.build_next_snapshot(case.builder; encoding=:generic)
end

function summarize(trial)
    samples = trial.times
    return (
        median_ms=median(samples) / 1.0e6,
        p99_ms=quantile(samples, 0.99) / 1.0e6,
        allocations=allocs(trial),
        bytes_allocated=memory(trial),
        gc_percent=100.0 * sum(trial.gctimes) / sum(samples)
    )
end

function run_case(fraction; samples=8)
    generic_case = make_case(500_000, fraction)
    typed_case = make_case(500_000, fraction)
    # Warm both paths and ensure the measured trials are post-compilation.
    step_case!(generic_case, false)
    step_case!(typed_case, true)
    generic_trial = @benchmark step_case!($generic_case, false) samples=samples evals=1
    typed_trial = @benchmark step_case!($typed_case, true) samples=samples evals=1
    generic_result = summarize(generic_trial)
    typed_result = summarize(typed_trial)
    return (
        fraction=fraction,
        generic=generic_result,
        typed=typed_result,
        median_speedup=generic_result.median_ms / typed_result.median_ms
    )
end

println("BenchmarkTools 500K adaptive update matrix")
for fraction in (0.01, 0.10, 0.25, 0.50, 0.75, 0.90, 1.00)
    println(run_case(fraction))
end
