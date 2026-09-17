using Test
using GodotBridge

mutable struct AdaptiveTestAdapter <: GodotBridge.SimulationAdapter
    current_time::Float64
    elements::Vector{GodotBridge.ElementState}
    entities::Vector{GodotBridge.EntitySnapshot}
end

GodotBridge.abm_capability(::AdaptiveTestAdapter) = GodotBridge.NoABM()
GodotBridge.get_simulation_time(adapter::AdaptiveTestAdapter) = adapter.current_time
GodotBridge.get_elements_snapshot(adapter::AdaptiveTestAdapter) = adapter.elements
GodotBridge.get_entities_snapshot(adapter::AdaptiveTestAdapter) = adapter.entities

function adaptive_element(id, occupancy; metric=0.0)
    GodotBridge.ElementState(
        id, "queue", UInt32(occupancy), Dict{String, Any}("metric" => metric)
    )
end

function adaptive_entity(id, location; property="stable")
    GodotBridge.EntitySnapshot(
        id, "customer", location, 0.0, [[0.0, 0.0]],
        Dict{String, Any}("property" => property)
    )
end

@testset "Phase 7B.3.4: Adaptive updates" begin
    adapter = AdaptiveTestAdapter(
        0.0,
        [adaptive_element("queue-1", 2)],
        [adaptive_entity("agent-1", "queue-1")]
    )
    builder = AdaptiveSnapshotBuilder(adapter; scene_id="adaptive", full_interval=3)

    @testset "Tracker decisions" begin
        tracker = SnapshotEfficiencyTracker(threshold=0.8)
        @test should_send_delta(tracker, 80, 100)
        @test !should_send_delta(tracker, 81, 100)
        @test !should_send_delta(tracker, 1, 0)
    end

    @testset "Full then delta" begin
        first = build_next_snapshot(builder; encoding=:generic)
        @test first.payload isa SnapshotPayload
        @test adaptive_statistics(builder)[:full_snapshots] == 1

        adapter.current_time = 1.0
        second = build_next_snapshot(builder; encoding=:generic)
        @test second.payload isa DeltaPayload
        @test adaptive_statistics(builder)[:deltas] == 1
    end

    @testset "Periodic full snapshot" begin
        adapter.current_time = 2.0
        periodic = build_next_snapshot(builder; encoding=:generic)
        @test periodic.payload isa SnapshotPayload
        @test adaptive_statistics(builder)[:full_snapshots] == 2
    end

    @testset "Adaptive statistics" begin
        stats = adaptive_statistics(builder)
        @test stats[:updates] == 3
        @test stats[:total_bytes] > 0
        @test haskey(stats, :estimated_savings_percent)
    end
end
