"""Result handle returned by `submit_command`."""
mutable struct CommandFuture
    channel::Channel{Any}
    submitted_at::Float64
    status::Symbol
    result::Any
    elapsed::Float64
    error::Any
end

function CommandFuture()
    return CommandFuture(Channel{Any}(1), time(), :pending, nothing, 0.0, nothing)
end

"""Return true when the command has completed or failed."""
is_command_ready(future::CommandFuture) = isready(future.channel)

"""Wait for a command result, optionally timing out in seconds."""
function wait_result(future::CommandFuture; timeout::Float64=5.0)
    timeout >= 0.0 || throw(ArgumentError("timeout must be non-negative"))
    if !isready(future.channel)
        timedwait(() -> isready(future.channel), timeout) == :timed_out &&
            throw(InterruptException())
    end
    response = take!(future.channel)
    future.elapsed = response.elapsed
    future.error = response.error
    if response.error === nothing
        future.status = :completed
        future.result = response.result
        return response.result
    end
    future.status = :error
    throw(response.error)
end

function command_latency(future::CommandFuture)
    return future.elapsed
end

function get_latency_stats(futures::AbstractVector{<:CommandFuture})
    completed = [future.elapsed for future in futures if future.status == :completed]
    isempty(completed) && return Dict{Symbol, Float64}()
    sorted = sort(completed)
    percentile(values, fraction) = values[clamp(ceil(Int, fraction * length(values)), 1, length(values))]
    return Dict(
        :min => minimum(completed),
        :max => maximum(completed),
        :mean => sum(completed) / length(completed),
        :p95 => percentile(sorted, 0.95),
        :p99 => percentile(sorted, 0.99)
    )
end

export CommandFuture, is_command_ready, wait_result, command_latency, get_latency_stats
