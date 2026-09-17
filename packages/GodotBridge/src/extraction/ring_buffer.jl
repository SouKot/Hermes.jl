"""
    TrajectoryRingBuffer

Fixed-capacity trajectory history using the protocol's `Vector{Float64}`
coordinate representation. The oldest sample is overwritten when full.
"""
mutable struct TrajectoryRingBuffer
    coordinates::Vector{Vector{Float64}}
    times::Vector{Float64}
    capacity::Int
    size::Int
    head::Int
    lock::ReentrantLock
end

function TrajectoryRingBuffer(capacity::Int=1000)
    capacity > 0 || throw(ArgumentError("trajectory capacity must be positive"))
    return TrajectoryRingBuffer(
        Vector{Vector{Float64}}(undef, capacity),
        Vector{Float64}(undef, capacity),
        capacity, 0, 1, ReentrantLock()
    )
end

function add_point!(
    buffer::TrajectoryRingBuffer,
    coordinate::AbstractVector{<:Real},
    time::Real
)
    length(coordinate) == 2 || throw(ArgumentError("trajectory coordinates must be [x, y]"))
    lock(buffer.lock) do
        buffer.coordinates[buffer.head] = Float64[coordinate[1], coordinate[2]]
        buffer.times[buffer.head] = Float64(time)
        buffer.head = buffer.head == buffer.capacity ? 1 : buffer.head + 1
        buffer.size = min(buffer.size + 1, buffer.capacity)
    end
    return buffer
end

# Compatibility alias used by the roadmap examples.
add_point(buffer::TrajectoryRingBuffer, coordinate::AbstractVector{<:Real}, time::Real) =
    add_point!(buffer, coordinate, time)

function trajectory(buffer::TrajectoryRingBuffer)
    lock(buffer.lock) do
        buffer.size == 0 && return Tuple{Vector{Float64}, Float64}[]
        first_index = buffer.size < buffer.capacity ? 1 : buffer.head
        result = Tuple{Vector{Float64}, Float64}[]
        for offset in 0:(buffer.size - 1)
            index = mod1(first_index + offset, buffer.capacity)
            push!(result, (copy(buffer.coordinates[index]), buffer.times[index]))
        end
        return result
    end
end

function get_trajectory(buffer::TrajectoryRingBuffer)
    return [sample[1] for sample in trajectory(buffer)]
end

function memory_usage(buffer::TrajectoryRingBuffer)
    return buffer.capacity * (2 * sizeof(Float64) + sizeof(Float64))
end

export TrajectoryRingBuffer, add_point!, add_point, trajectory, get_trajectory, memory_usage
