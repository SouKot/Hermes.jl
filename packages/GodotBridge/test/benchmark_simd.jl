using Statistics
using GodotBridge

function benchmark_kernel(count=5_000_000; iterations=5)
    scalar = GodotBridge.DenseNumericState{Float32}(count)
    simd = GodotBridge.DenseNumericState{Float32}(count)
    fill!(scalar.velocities_x, 1.0f0)
    fill!(scalar.velocities_y, 2.0f0)
    copyto!(simd.velocities_x, scalar.velocities_x)
    copyto!(simd.velocities_y, scalar.velocities_y)

    GodotBridge.advance_positions_scalar!(scalar, 0.001f0)
    GodotBridge.advance_positions_simd!(simd, 0.001f0)

    scalar_times = Float64[]
    simd_times = Float64[]
    for _ in 1:iterations
        start = time_ns()
        GodotBridge.advance_positions_scalar!(scalar, 0.001f0)
        push!(scalar_times, (time_ns() - start) / 1.0e6)

        start = time_ns()
        GodotBridge.advance_positions_simd!(simd, 0.001f0)
        push!(simd_times, (time_ns() - start) / 1.0e6)
    end

    return (
        count=count,
        scalar_ms=mean(scalar_times),
        simd_ms=mean(simd_times),
        speedup=mean(scalar_times) / mean(simd_times)
    )
end

println(benchmark_kernel())
