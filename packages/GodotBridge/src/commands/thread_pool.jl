"""
    CommandWorkerPool

Bounded, non-blocking command queue backed by Julia CPU tasks scheduled on the
thread pool. Commands are dequeued FIFO; adapter execution is serialized by
default because most simulation engines are not safe for concurrent mutation.
"""
mutable struct CommandWorkerPool
    queue::Channel{Any}
    workers::Vector{Task}
    adapter::SimulationAdapter
    num_workers::Int
    running::Bool
    execution_lock::ReentrantLock
end

function CommandWorkerPool(
    adapter::SimulationAdapter;
    num_workers::Int=Threads.nthreads(),
    capacity::Int=256
)
    num_workers > 0 || throw(ArgumentError("num_workers must be positive"))
    capacity > 0 || throw(ArgumentError("capacity must be positive"))
    return CommandWorkerPool(
        Channel{Any}(capacity), Task[], adapter, num_workers, false, ReentrantLock()
    )
end

function _command_worker_loop(pool::CommandWorkerPool)
    while pool.running || isready(pool.queue)
        item = try
            take!(pool.queue)
        catch exception
            exception isa InvalidStateException && break
            rethrow()
        end

        future = item.future
        started_at = time_ns()
        try
            # Serialize engine mutation unless an adapter explicitly provides
            # its own concurrency-safe dispatch implementation.
            result = lock(pool.execution_lock) do
                dispatch_command(pool.adapter, item.command)
            end
            elapsed = (time_ns() - started_at) / 1.0e9
            put!(future.channel, (result=result, elapsed=elapsed, error=nothing))
        catch exception
            elapsed = (time_ns() - started_at) / 1.0e9
            put!(future.channel, (result=nothing, elapsed=elapsed, error=exception))
        end
    end
end

"""Start the pool and launch its CPU worker tasks."""
function start_pool!(pool::CommandWorkerPool)
    pool.running && return pool
    pool.running = true
    empty!(pool.workers)
    for _ in 1:pool.num_workers
        push!(pool.workers, Threads.@spawn _command_worker_loop(pool))
    end
    return pool
end

"""Stop accepting work and wait for queued work to finish."""
function stop_pool!(pool::CommandWorkerPool; drain::Bool=true)
    pool.running = false
    if !drain
        while isready(pool.queue)
            take!(pool.queue)
        end
    end
    close(pool.queue)
    foreach(wait, pool.workers)
    empty!(pool.workers)
    return pool
end

"""Submit a command without waiting for its result."""
function submit_command(pool::CommandWorkerPool, command)
    pool.running || throw(InvalidStateException("command pool is not running", :submit))
    future = CommandFuture()
    put!(pool.queue, (command=command, future=future))
    return future
end

export CommandWorkerPool, start_pool!, stop_pool!, submit_command
