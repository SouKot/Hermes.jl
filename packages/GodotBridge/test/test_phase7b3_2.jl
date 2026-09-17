using Test

module ExtractionTestHarness
include("../src/protocol/envelope.jl")
include("../src/snapshot/snapshot_builder.jl")
include("../src/adapters/traits.jl")
include("../src/adapters/interface.jl")
include("../src/extraction/element_cache.jl")
include("../src/extraction/parallel_elements.jl")
include("../src/extraction/ring_buffer.jl")
include("../src/extraction/entity_batch.jl")

mutable struct MockAdapter <: SimulationAdapter
    current_time::Float64
    elements::Vector{ElementState}
    entities::Vector{EntitySnapshot}
    fetches::Int
end

abm_capability(::MockAdapter) = NoABM()
get_simulation_time(adapter::MockAdapter) = adapter.current_time
get_elements_snapshot(adapter::MockAdapter) = adapter.elements
get_entities_snapshot(adapter::MockAdapter) = adapter.entities

function get_element(adapter::MockAdapter, id::String)
    adapter.fetches += 1
    return only(filter(element -> element.id == id, adapter.elements))
end
end

using .ExtractionTestHarness
const H = ExtractionTestHarness

@testset "Phase 7B.3.2: Extraction" begin
    element(id, occupancy) = H.ElementState(id, "queue", UInt32(occupancy), Dict{String, Any}())
    entity(id, coordinates) = H.EntitySnapshot(
        id, "customer", "queue-1", 0.0, coordinates, Dict{String, Any}()
    )

    adapter = H.MockAdapter(
        1.0,
        [element("queue-1", 2), element("queue-2", 4)],
        [entity("agent-1", [[0.0, 0.0], [1.0, 1.0]])],
        0
    )

    @testset "TTL cache" begin
        cache = H.ElementStateCache(0.5)
        first_value = H.get_cached_element(cache, "queue-1", 1.0,
            id -> H.get_element(adapter, id))
        second_value = H.get_cached_element(cache, "queue-1", 1.2,
            id -> H.get_element(adapter, id))
        @test first_value === second_value
        @test adapter.fetches == 1
        @test H.cache_stats(cache).hit_rate == 0.5

        H.get_cached_element(cache, "queue-1", 1.6,
            id -> H.get_element(adapter, id))
        @test adapter.fetches == 2
        @test H.clear_expired!(cache, 2.2) == 1
    end

    @testset "Element extraction" begin
        extracted = H.extract_elements_parallel(adapter; min_parallel_size=1)
        @test extracted == adapter.elements

        cache = H.ElementStateCache(10.0)
        cached = H.extract_elements_cached(adapter, cache; current_time=1.0,
            fetcher=id -> H.get_element(adapter, id))
        @test [value.id for value in cached] == ["queue-1", "queue-2"]

        fallback_cache = H.ElementStateCache(0.0)
        fallback = H.extract_elements_cached(adapter, fallback_cache; current_time=1.0)
        @test [value.id for value in fallback] == ["queue-1", "queue-2"]
    end

    @testset "Trajectory ring buffer" begin
        buffer = H.TrajectoryRingBuffer(2)
        H.add_point!(buffer, [0, 0], 0.0)
        H.add_point!(buffer, [1, 1], 1.0)
        H.add_point!(buffer, [2, 2], 2.0)
        @test H.get_trajectory(buffer) == [[1.0, 1.0], [2.0, 2.0]]
        @test H.trajectory(buffer)[1][2] == 1.0
        @test H.memory_usage(buffer) > 0
    end

    @testset "Entity extraction" begin
        buffers = Dict("agent-1" => H.TrajectoryRingBuffer(4))
        extracted = H.extract_entities_vectorized(adapter;
            trajectory_buffers=buffers, current_time=adapter.current_time)
        @test length(extracted) == 1
        @test extracted[1].id == "agent-1"
        @test extracted[1].trajectory_2d == [[0.0, 0.0], [1.0, 1.0]]
    end
end
