using Test
using GodotBridge

mutable struct PoolTestAdapter <: GodotBridge.SimulationAdapter
    calls::Vector{Symbol}
end

abm_capability(::PoolTestAdapter) = GodotBridge.NoABM()
get_simulation_time(::PoolTestAdapter) = 0.0
get_elements_snapshot(::PoolTestAdapter) = GodotBridge.ElementState[]
get_entities_snapshot(::PoolTestAdapter) = GodotBridge.EntitySnapshot[]

function GodotBridge.dispatch_command(adapter::PoolTestAdapter, command)
    push!(adapter.calls, command)
    command == :fail && error("intentional command failure")
    return command
end

@testset "Phase 7B.3.3: Command worker pool" begin
    adapter = PoolTestAdapter(Symbol[])
    pool = CommandWorkerPool(adapter; num_workers=2, capacity=8)
    start_pool!(pool)

    @testset "Non-blocking submission and completion" begin
        futures = [submit_command(pool, command) for command in [:play, :pause, :step]]
        @test all(future -> future.status == :pending, futures)
        results = [wait_result(future) for future in futures]
        @test results == [:play, :pause, :step]
        @test all(future -> future.status == :completed, futures)
        @test length(get_latency_stats(futures)) == 5
    end

    @testset "Failures are isolated to their future" begin
        future = submit_command(pool, :fail)
        @test_throws ErrorException wait_result(future)
        @test future.status == :error
        successful = submit_command(pool, :reset)
        @test wait_result(successful) == :reset
    end

    @testset "CPU worker pool does not claim GPU execution" begin
        @test !GodotBridge.has_feature(adapter, GodotBridge.SupportsGPU)
        @test pool.num_workers == 2
    end

    stop_pool!(pool)
    @test !pool.running
    @test_throws InvalidStateException submit_command(pool, :after_stop)
end
