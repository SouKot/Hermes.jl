using Test
using GodotBridge

mutable struct ThresholdAdapter <: GodotBridge.SimulationAdapter
    current_time::Float64
    elements::Dict{String, GodotBridge.ElementState}
    pending::GodotBridge.DirtyState
end

GodotBridge.abm_capability(::ThresholdAdapter) = GodotBridge.NoABM()
GodotBridge.supports_dirty_tracking(::ThresholdAdapter) = true
GodotBridge.dirty_state(adapter::ThresholdAdapter) = adapter.pending
GodotBridge.get_simulation_time(adapter::ThresholdAdapter) = adapter.current_time
GodotBridge.get_elements_snapshot(adapter::ThresholdAdapter) = collect(values(adapter.elements))
GodotBridge.get_entities_snapshot(::ThresholdAdapter) = GodotBridge.EntitySnapshot[]
GodotBridge.get_element_state(adapter::ThresholdAdapter, id::String) = adapter.elements[id]
GodotBridge.get_entity_state(::ThresholdAdapter, id::String) = error("no entities")
GodotBridge.clear_dirty_state!(::ThresholdAdapter, ::UInt64) = nothing
GodotBridge.dispatch_command(::ThresholdAdapter, command) = command

function make_threshold_adapter(count=10)
    elements = Dict{String, GodotBridge.ElementState}()
    for index in 1:count
        id = "element-$index"
        elements[id] = GodotBridge.ElementState(id, "queue", UInt32(index), Dict{String, Any}())
    end
    return ThresholdAdapter(0.0, elements, GodotBridge.DirtyState(revision=1))
end

function update!(adapter, ids, revision)
    for id in ids
        adapter.elements[id].occupancy += UInt32(1)
    end
    adapter.pending = GodotBridge.DirtyState(elements_updated=ids, revision=revision)
    adapter.current_time += 0.1
end

@testset "Adaptive change-density threshold" begin
    @test GodotBridge.DEFAULT_TYPED_DELTA_THRESHOLD == 0.8

    adapter = make_threshold_adapter()
    builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=1000)
    GodotBridge.build_next_snapshot_bytes(builder)

    sparse_ids = ["element-1", "element-2"]
    update!(adapter, sparse_ids, 2)
    sparse_message = GodotBridge.build_next_snapshot_message(builder)
    @test sparse_message.payload isa GodotBridge.DeltaPayload

    dense_ids = ["element-$index" for index in 1:9]
    update!(adapter, dense_ids, 3)
    dense_message = GodotBridge.build_next_snapshot_message(builder)
    @test dense_message.payload isa GodotBridge.SnapshotPayload
end
