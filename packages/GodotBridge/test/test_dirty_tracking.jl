using Test
using GodotBridge

mutable struct DirtyTestAdapter <: GodotBridge.SimulationAdapter
    current_time::Float64
    elements::Dict{String, GodotBridge.ElementState}
    entities::Dict{String, GodotBridge.EntitySnapshot}
    pending::GodotBridge.DirtyState
    acknowledged::UInt64
end

GodotBridge.abm_capability(::DirtyTestAdapter) = GodotBridge.NoABM()
GodotBridge.get_simulation_time(adapter::DirtyTestAdapter) = adapter.current_time
GodotBridge.supports_dirty_tracking(::DirtyTestAdapter) = true
GodotBridge.dirty_state(adapter::DirtyTestAdapter) = adapter.pending
GodotBridge.get_elements_snapshot(adapter::DirtyTestAdapter) = collect(values(adapter.elements))
GodotBridge.get_entities_snapshot(adapter::DirtyTestAdapter) = collect(values(adapter.entities))
GodotBridge.get_element_state(adapter::DirtyTestAdapter, id::String) = adapter.elements[id]
GodotBridge.get_entity_state(adapter::DirtyTestAdapter, id::String) = adapter.entities[id]
GodotBridge.clear_dirty_state!(adapter::DirtyTestAdapter, revision::UInt64) = (adapter.acknowledged = revision)
GodotBridge.dispatch_command(::DirtyTestAdapter, command) = command

function make_dirty_adapter()
    element = GodotBridge.ElementState("queue-1", "queue", UInt32(1), Dict{String, Any}())
    entity = GodotBridge.EntitySnapshot("agent-1", "agent", "queue-1", 0.0,
        [[0.0, 0.0]], Dict{String, Any}())
    return DirtyTestAdapter(0.0, Dict("queue-1" => element), Dict("agent-1" => entity),
        GodotBridge.DirtyState(revision=1), 0)
end

@testset "Dirty tracking incremental path" begin
    adapter = make_dirty_adapter()
    builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=10)
    first = GodotBridge.build_next_snapshot(builder; encoding=:generic)
    @test first.payload isa GodotBridge.SnapshotPayload

    adapter.elements["queue-1"].occupancy = UInt32(7)
    adapter.current_time = 0.1
    adapter.pending = GodotBridge.DirtyState(
        elements_updated=["queue-1"], revision=2
    )
    second = GodotBridge.build_next_snapshot(builder; encoding=:generic)
    @test second.payload isa GodotBridge.DeltaPayload
    @test adapter.acknowledged == 2
    @test second.payload.elements_changed[1]["element_id"] == "queue-1"

    typed_default = GodotBridge.build_next_snapshot(builder)
    @test typed_default isa Vector{UInt8}

    direct_bytes = GodotBridge.encode_direct_dirty_delta(
        builder.incremental_cache,
        GodotBridge.DirtyState(elements_updated=["queue-1"], revision=3),
        GodotBridge.build_snapshot("dirty", 0.2, UInt64(3))
    )
    @test !isempty(direct_bytes)
end
