using BenchmarkTools
using Statistics
using GodotBridge

mutable struct EntityBenchmarkAdapter <: GodotBridge.SimulationAdapter
    current_time::Float64
    entities::Dict{String, GodotBridge.EntitySnapshot}
    pending::GodotBridge.DirtyState
end

GodotBridge.abm_capability(::EntityBenchmarkAdapter) = GodotBridge.NoABM()
GodotBridge.supports_dirty_tracking(::EntityBenchmarkAdapter) = true
GodotBridge.dirty_state(adapter::EntityBenchmarkAdapter) = adapter.pending
GodotBridge.get_simulation_time(adapter::EntityBenchmarkAdapter) = adapter.current_time
GodotBridge.get_elements_snapshot(::EntityBenchmarkAdapter) = GodotBridge.ElementState[]
GodotBridge.get_entities_snapshot(adapter::EntityBenchmarkAdapter) = collect(values(adapter.entities))
GodotBridge.get_element_state(::EntityBenchmarkAdapter, id::String) = error("no elements")
GodotBridge.get_entity_state(adapter::EntityBenchmarkAdapter, id::String) = adapter.entities[id]
GodotBridge.clear_dirty_state!(::EntityBenchmarkAdapter, ::UInt64) = nothing
GodotBridge.dispatch_command(::EntityBenchmarkAdapter, command) = command

mutable struct EntityCase
    adapter::EntityBenchmarkAdapter
    builder::GodotBridge.AdaptiveSnapshotBuilder
    ids::Vector{String}
    revision::UInt64
end

function make_case(count, fraction)
    entities = Dict{String, GodotBridge.EntitySnapshot}()
    for index in 1:count
        id = "entity-$index"
        entities[id] = GodotBridge.EntitySnapshot(
            id, "agent", "location-$(mod1(index, 100))", 0.0,
            [[Float64(index % 100), Float64(index % 80)]],
            Dict{String, Any}("state" => "stable", "priority" => index % 4)
        )
    end
    adapter = EntityBenchmarkAdapter(0.0, entities, GodotBridge.DirtyState(revision=1))
    builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=1000)
    GodotBridge.build_next_snapshot_bytes(builder)
    changed = max(1, round(Int, count * fraction))
    ids = ["entity-$index" for index in 1:changed]
    return EntityCase(adapter, builder, ids, UInt64(1))
end

function step_case!(case::EntityCase, direct::Bool)
    case.revision += UInt64(1)
    for id in case.ids
        entity = case.adapter.entities[id]
        entity.properties["state"] = "updated"
    end
    case.adapter.pending = GodotBridge.DirtyState(
        entities_updated=case.ids, revision=case.revision
    )
    case.adapter.current_time += 0.1
    return direct ? GodotBridge.build_next_snapshot_bytes(case.builder) :
        GodotBridge.build_next_snapshot(case.builder; encoding=:generic)
end

function summary(trial)
    return (
        median_ms=median(trial.times) / 1.0e6,
        p99_ms=quantile(trial.times, 0.99) / 1.0e6,
        allocations=allocs(trial),
        bytes_allocated=memory(trial)
    )
end

for fraction in (0.01, 0.10)
    for count in (100_000, 500_000)
        generic_case = make_case(count, fraction)
        typed_case = make_case(count, fraction)
        step_case!(generic_case, false)
        step_case!(typed_case, true)
        generic_trial = @benchmark step_case!($generic_case, false) samples=6 evals=1
        typed_trial = @benchmark step_case!($typed_case, true) samples=6 evals=1
        println((entities=count, fraction=fraction,
            generic=summary(generic_trial), typed=summary(typed_trial),
            median_speedup=median(generic_trial.times) / median(typed_trial.times)))
    end
end
