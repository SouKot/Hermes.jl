"""Optional SIMD-friendly dense numeric kernels for adapter-owned state."""
struct DenseNumericState{T<:AbstractFloat}
    positions_x::Vector{T}
    positions_y::Vector{T}
    velocities_x::Vector{T}
    velocities_y::Vector{T}
end

function DenseNumericState{T}(count::Int) where {T<:AbstractFloat}
    count >= 0 || throw(ArgumentError("count must be non-negative"))
    return DenseNumericState{T}(
        zeros(T, count), zeros(T, count), zeros(T, count), zeros(T, count)
    )
end

DenseNumericState(count::Int) = DenseNumericState{Float32}(count)

"""Scalar baseline for deterministic dense numeric benchmarking."""
function advance_positions_scalar!(state::DenseNumericState, dt)
    length(state.positions_x) == length(state.velocities_x) ||
        throw(DimensionMismatch("dense state arrays must have equal length"))
    for index in eachindex(state.positions_x, state.positions_y,
        state.velocities_x, state.velocities_y)
        state.positions_x[index] += state.velocities_x[index] * dt
        state.positions_y[index] += state.velocities_y[index] * dt
    end
    return state
end

"""SIMD-enabled CPU kernel; adapters can replace this with a backend kernel."""
function advance_positions_simd!(state::DenseNumericState, dt)
    length(state.positions_x) == length(state.velocities_x) ||
        throw(DimensionMismatch("dense state arrays must have equal length"))
    @simd for index in eachindex(state.positions_x)
        state.positions_x[index] += state.velocities_x[index] * dt
        state.positions_y[index] += state.velocities_y[index] * dt
    end
    return state
end

"""Default adapter capability: dense SIMD is opt-in."""
supports_simd(::SimulationAdapter) = false

dense_numeric_state(::SimulationAdapter) = nothing

function advance_dense_numeric!(adapter::SimulationAdapter, dt; simd::Bool=false)
    state = dense_numeric_state(adapter)
    state === nothing && throw(ArgumentError("adapter does not expose dense numeric state"))
    simd ? advance_positions_simd!(state, dt) : advance_positions_scalar!(state, dt)
    return state
end

export DenseNumericState, advance_positions_scalar!, advance_positions_simd!
export supports_simd, dense_numeric_state, advance_dense_numeric!
