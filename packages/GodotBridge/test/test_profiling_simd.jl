using Test
using GodotBridge

mutable struct DenseProfileAdapter <: GodotBridge.SimulationAdapter
    current_time::Float64
    state::GodotBridge.DenseNumericState{Float32}
end

GodotBridge.abm_capability(::DenseProfileAdapter) = GodotBridge.NoABM()
GodotBridge.get_simulation_time(adapter::DenseProfileAdapter) = adapter.current_time
GodotBridge.get_elements_snapshot(::DenseProfileAdapter) = GodotBridge.ElementState[]
GodotBridge.get_entities_snapshot(::DenseProfileAdapter) = GodotBridge.EntitySnapshot[]
GodotBridge.dispatch_command(::DenseProfileAdapter, command) = command
GodotBridge.dense_numeric_state(adapter::DenseProfileAdapter) = adapter.state
GodotBridge.supports_simd(::DenseProfileAdapter) = true

@testset "Adapter profiling and SIMD hooks" begin
    adapter = DenseProfileAdapter(0.0, GodotBridge.DenseNumericState{Float32}(128))
    fill!(adapter.state.velocities_x, 1.0f0)
    fill!(adapter.state.velocities_y, 2.0f0)

    profile = GodotBridge.profile_adapter(adapter; iterations=2)
    @test profile.iterations == 2
    @test profile.extraction_ms >= 0.0
    @test profile.full_snapshot_ms >= 0.0
    @test profile.encoded_bytes > 0
    @test !profile.dirty_tracking

    GodotBridge.advance_dense_numeric!(adapter, 0.5f0; simd=true)
    @test adapter.state.positions_x[1] == 0.5f0
    @test adapter.state.positions_y[1] == 1.0f0

    GodotBridge.advance_positions_scalar!(adapter.state, 0.5f0)
    @test adapter.state.positions_x[1] == 1.0f0
    @test GodotBridge.supports_simd(adapter)
end
