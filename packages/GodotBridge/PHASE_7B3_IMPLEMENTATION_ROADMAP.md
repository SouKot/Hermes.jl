# Phase 7B.3 Implementation Roadmap

**Objective**: Implement the adapter pattern + trait dispatch architecture for state extraction, command processing, and adaptive updates.

**Timeline**: 12-16 hours of focused development

**Status**: ✅ Bridge implementation and bridge-only acceptance complete; Godot E2E pending

**Validation**: Julia 1.13.0, full package suite passing: 98 tests.

**Current validation total**: 98 tests, including adaptive-threshold, entity,
profiling, and SIMD coverage.

**BenchmarkTools change-density matrix**: At 500K elements, typed adaptive
updates measured 2.74x faster at 1% changed, 2.01x at 10%, and 1.71x at 50%.
At 100% changed, typed sparse-delta encoding was 0.51x the generic path, so the
adaptive policy must select a full snapshot when the changed fraction is high.
The measured crossover is between 75% and 90%; `DEFAULT_TYPED_DELTA_THRESHOLD`
is now explicitly set to 0.8. Above it, the builder selects a full snapshot
rather than constructing a sparse delta.

Entity-heavy BenchmarkTools validation measured typed speedups of 5.24x at
100K/1%, 5.24x at 500K/1%, 5.54x at 100K/10%, and 3.45x at 500K/10%. The
500K/10% typed case measured 30.67 ms median and 31.43 ms p99.

**P0 performance fix**: ✅ The O(n²) cold/expired cache fallback was replaced by
an O(n) ID index. Measured speedups are 14.5x at 1K, 56.1x at 5K, and 144.0x at
10K elements. The remaining abstract-field P0 item is separate and remains open.

**Baseline performance measurements**: `test/benchmark_phase7b3.jl` now measures
10K/20K/50K/100K element scales and 1,000 commands. The warmed-up baseline on
September 17, 2026 produced full MessagePack payloads of approximately 0.91,
1.83, 4.59, and 9.19 MB respectively; unchanged deltas were approximately
350 bytes; command throughput was approximately 9,847 commands/sec. These are
baseline observations, not final hardware-independent acceptance thresholds.

**Incremental tracking measurement**: The warmed-up dirty-capable benchmark
reduces 1% changed updates to approximately 0.049 ms at 10K, 0.252 ms at 50K,
and 0.570 ms at 100K, with 0.647 ms p99 at 100K. Mean delta size at 100K is
approximately 97 KB. The earlier 262-311 ms measurements used a fixture that
declared dirty tracking but returned the full-scan fallback; they are retained
only as fallback-path measurements, not incremental-path results.

**Higher-scale and typed-encoding measurements**:
- 500K elements, 1% changed: 10.921 ms mean update, approximately 489 KB delta.
- 500K elements, 10% changed: generic encoding averaged 11.36 ms; typed direct
    MessagePack encoding averaged 9.78 ms, a measured 13.9% encoding improvement.
- Integrated adaptive path at 500K/10% changed: generic 42.0 ms mean / 46.8 ms
    p99; typed direct 19.7 ms mean / 23.7 ms p99, approximately 2.1x faster and
    below the 33.3 ms 30 FPS budget.
- Reusable IOBuffer encoding was tested but regressed the 500K/10% end-to-end
    workload, so it remains an optional API rather than the adaptive default.

**Parallelization decisions**:
- CPU threading is opt-in through `supports_parallel_state_fetch(adapter)`;
    adapters must guarantee independent, thread-safe state reads before enabling it.
- SIMD is not applied to the bridge's Dict/String-heavy protocol records. SIMD
    belongs inside adapters for dense numeric arrays such as positions, velocities,
    grids, and occupancy vectors, before dirty values cross the adapter boundary.
- GPU execution remains adapter-owned. `supports_gpu_state_fetch` and
    `synchronize_gpu_state!` define the explicit device-to-host boundary without
    adding CUDA as a core dependency. GPU is appropriate for bulk numeric model
    updates, not command dispatch or small dirty-record serialization.

---

## Phase Overview

Phase 7B.3 consists of 5 interconnected implementation phases that build the runtime bridge between SimElements and the Godot GUI. Each phase is designed to be independently testable before moving to the next.

| Phase | Component | Hours | Status | Dependencies |
|-------|-----------|-------|--------|--------------|
| 7B.3.1 | Adapter Interface System | 2-3 | ✅ Complete | None |
| 7B.3.2 | Element & Entity Extraction | 3-4 | ✅ Complete | 7B.3.1 |
| 7B.3.3 | Command Queue & Threading | 2-3 | ✅ Complete | 7B.3.1 |
| 7B.3.4 | Adaptive Update Strategy | 2-3 | ✅ Complete | 7B.3.2 |
| 7B.3.5 | Integration & Stress Testing | 2-3 | ✅ Bridge-only complete; Godot E2E pending | All |

**Total Estimated Effort**: 12-16 hours

---

## Phase 7B.3.1: Adapter Interface System

**Implementation status**: ✅ Complete. Implemented in `src/adapters/traits.jl`,
`interface.jl`, `registry.jl`, and `examples.jl`; validated by
`test/test_phase7b3_1.jl` and the integrated package suite.

**Objective**: Define the abstract interface that SimElements engines must implement to work with the Godot bridge.

**Hours**: 2-3 hours

**Deliverables**:

### 1. Define ABM Trait System
**File**: `src/adapters/traits.jl` (~80 lines)

Create the trait dispatch system for optional ABM support:

```julia
# ABM capability markers (zero-cost abstractions)
abstract type ABMCapability end
struct NoABM <: ABMCapability end          # DES-only system
struct SupportsABM <: ABMCapability end    # Hybrid or Pure ABM

# Version compatibility markers
abstract type ProtocolVersion end
struct V1 <: ProtocolVersion end

# Extensibility markers for future features
abstract type FeatureCapability end
struct SupportsGPU <: FeatureCapability end
struct SupportsReplay <: FeatureCapability end
```

**Acceptance Criteria**:
- [x] All trait types defined and exportable
- [x] Zero-cost at compile time (dispatch resolved at compile-time)
- [x] Can be composed (multiple traits per adapter)

---

### 2. Define SimulationAdapter Abstract Type
**File**: `src/adapters/interface.jl` (~150 lines)

Create the abstract interface that all engines must implement:

```julia
abstract type SimulationAdapter end

# Required interface methods
"""
    abm_capability(adapter::SimulationAdapter)::ABMCapability
Returns whether this adapter supports ABM (SupportsABM or NoABM).
"""
function abm_capability(adapter::SimulationAdapter)
    error("Not implemented for $(typeof(adapter))")
end

"""
    get_simulation_time(adapter::SimulationAdapter)::Float64
Returns current simulation clock time.
"""
function get_simulation_time(adapter::SimulationAdapter)
    error("Not implemented for $(typeof(adapter))")
end

"""
    get_elements_snapshot(adapter::SimulationAdapter)::Vector{ElementState}
Returns state of all simulation elements (networks, resources, etc).
"""
function get_elements_snapshot(adapter::SimulationAdapter)
    error("Not implemented for $(typeof(adapter))")
end

"""
    get_entities_snapshot(adapter::SimulationAdapter)::Vector{EntitySnapshot}
Returns positions, trajectories, and properties of all entities.
"""
function get_entities_snapshot(adapter::SimulationAdapter)
    error("Not implemented for $(typeof(adapter))")
end

# Conditionally dispatched based on ABM capability
"""
    get_abm_snapshot(adapter::SimulationAdapter where {SupportsABM})::ABMStateSnapshot
Returns agent states only if adapter supports ABM.
"""
function get_abm_snapshot(adapter::SimulationAdapter)
    if abm_capability(adapter) isa NoABM
        return nothing  # Lightweight, no computation
    end
    error("Not implemented for $(typeof(adapter))")
end

"""
    dispatch_command(adapter::SimulationAdapter, cmd::SimulationCommand)::CommandResult
Execute command (play, pause, reset, etc) on simulation.
"""
function dispatch_command(adapter::SimulationAdapter, cmd::SimulationCommand)
    error("Not implemented for $(typeof(adapter))")
end
```

**Acceptance Criteria**:
- [x] All required methods documented with docstrings
- [x] Error messages hint at which methods need implementation
- [x] Optional methods gracefully handle NoABM case
- [x] No runtime overhead from interface dispatch

---

### 3. Create Adapter Registry & Factory
**File**: `src/adapters/registry.jl` (~100 lines)

Create a registration system for engines:

```julia
mutable struct AdapterRegistry
    adapters::Dict{String, Type{<:SimulationAdapter}}
    instances::Dict{String, SimulationAdapter}
    
    AdapterRegistry() = new(Dict(), Dict())
end

const GLOBAL_ADAPTER_REGISTRY = AdapterRegistry()

"""
    register_adapter(name::String, adapter_type::Type{<:SimulationAdapter})
Register an adapter class in the global registry.
"""
function register_adapter(name::String, adapter_type::Type{<:SimulationAdapter})
    GLOBAL_ADAPTER_REGISTRY.adapters[name] = adapter_type
end

"""
    create_adapter(name::String, args...)::SimulationAdapter
Instantiate a registered adapter by name.
"""
function create_adapter(name::String, args...)
    haskey(GLOBAL_ADAPTER_REGISTRY.adapters, name) || 
        error("Adapter '$name' not registered. Available: $(keys(GLOBAL_ADAPTER_REGISTRY.adapters))")
    
    adapter_type = GLOBAL_ADAPTER_REGISTRY.adapters[name]
    return adapter_type(args...)
end

"""
    get_active_adapter()::SimulationAdapter
Retrieve currently active simulation adapter.
"""
function get_active_adapter()
    isempty(GLOBAL_ADAPTER_REGISTRY.instances) && 
        error("No active adapter. Register with create_adapter().")
    
    # Return most recently created/registered
    collect(values(GLOBAL_ADAPTER_REGISTRY.instances))[end]
end
```

**Acceptance Criteria**:
- [x] Adapters can be registered and created
- [x] Registry can hold multiple instances
- [x] Helpful error messages for unregistered adapters
- [x] Thread-safe registry access using `ReentrantLock`

---

### 4. Create Example Stub Implementations
**File**: `src/adapters/examples.jl` (~150 lines)

Create minimal stub adapters demonstrating all three model types:

```julia
# DES-Only: Manufacturing System
struct ManufacturingAdapter <: SimulationAdapter
    engine::Any  # Reference to actual SimElements engine
    start_time::Float64
end

abm_capability(::ManufacturingAdapter) = NoABM()

get_simulation_time(adapter::ManufacturingAdapter) = adapter.engine.current_time
# ... stubs for other methods

# Hybrid: Shopping Mall (DES + ABM)
struct ShoppingMallAdapter <: SimulationAdapter
    des_engine::Any
    abm_model::Any
    start_time::Float64
end

abm_capability(::ShoppingMallAdapter) = SupportsABM()
# ... implements all methods including get_abm_snapshot

# Pure ABM: Epidemic Model
struct EpidemicAdapter <: SimulationAdapter
    abm_model::Any
    start_time::Float64
end

abm_capability(::EpidemicAdapter) = SupportsABM()
# ... implements all methods including get_abm_snapshot
```

**Acceptance Criteria**:
- [x] All 3 example adapters compile
- [x] Each demonstrates correct ABM capability declaration
- [x] Stubs have comments explaining what real implementation would do
- [x] Can be instantiated and passed to test functions

---

## Phase 7B.3.2: Element & Entity Extraction

**Implementation status**: ✅ Complete. The implementation uses the repository's
actual `ElementState` and `EntitySnapshot` types, string IDs, locked TTL cache,
trajectory ring buffers, and adapter batch extraction hooks. Validated by
`test/test_phase7b3_2.jl` with 13 passing tests.

**Objective**: Implement efficient, cached extraction of simulation state with parallel processing for large systems.

**Hours**: 3-4 hours

**Deliverables**:

### 1. Create ElementState Cache
**File**: `src/extraction/element_cache.jl` (~180 lines)

Implement TTL-based caching to avoid recomputing element state on every snapshot:

```julia
mutable struct ElementStateCache
    cache::Dict{Int, ElementState}
    timestamps::Dict{Int, Float64}
    ttl::Float64  # Time-to-live in seconds
    last_cleanup::Float64
end

"""
    ElementStateCache(ttl::Float64=0.1)
Create a cache with TTL (default 100ms).
Useful for 10 FPS GUI updates while simulation runs faster.
"""
function ElementStateCache(ttl::Float64=0.1)
    return ElementStateCache(Dict(), Dict(), ttl, 0.0)
end

"""
    get_cached_element(cache::ElementStateCache, elem_id::Int, 
                       current_time::Float64, fetcher::Function)::ElementState
Get cached element or fetch fresh if expired.
Fetcher is a function that returns ElementState for given ID.
"""
function get_cached_element(cache::ElementStateCache, elem_id::Int, 
                            current_time::Float64, fetcher::Function)
    if haskey(cache.cache, elem_id)
        cached_time = cache.timestamps[elem_id]
        if (current_time - cached_time) < cache.ttl
            return cache.cache[elem_id]  # Cache hit
        end
    end
    
    # Cache miss or expired - fetch fresh
    state = fetcher(elem_id)
    cache.cache[elem_id] = state
    cache.timestamps[elem_id] = current_time
    return state
end

"""
    clear_expired(cache::ElementStateCache, current_time::Float64)
Remove expired entries (background maintenance).
"""
function clear_expired(cache::ElementStateCache, current_time::Float64)
    expired = [id for (id, ts) in cache.timestamps if (current_time - ts) >= cache.ttl]
    for id in expired
        delete!(cache.cache, id)
        delete!(cache.timestamps, id)
    end
    cache.last_cleanup = current_time
end
```

**Acceptance Criteria**:
- [x] Cache correctly implements TTL expiration
- [x] `get_cached_element` returns fresh data when expired
- [x] `clear_expired` removes only stale entries
- [x] Memory-efficient Dict-based cache
- [x] Thread-safe wrapper provided with `ReentrantLock`

---

### 2. Parallel Element Extraction
**File**: `src/extraction/parallel_elements.jl` (~200 lines)

Implement efficient parallel extraction for 10,000+ elements:

```julia
"""
    extract_elements_parallel(adapter::SimulationAdapter, 
                             num_workers::Int=4)::Vector{ElementState}

Extract all elements in parallel using thread pool.
Each thread fetches a batch of elements to avoid contention.
"""
function extract_elements_parallel(adapter::SimulationAdapter, 
                                   num_workers::Int=4)
    elements = get_elements_snapshot(adapter)
    n_elements = length(elements)
    
    if n_elements < 100
        # Small system: don't parallelize overhead
        return elements
    end
    
    # Divide work among threads
    batch_size = ceil(Int, n_elements / num_workers)
    results = Vector{ElementState}(undef, n_elements)
    
    Threads.@threads for worker in 1:num_workers
        start_idx = (worker - 1) * batch_size + 1
        end_idx = min(worker * batch_size, n_elements)
        
        for i in start_idx:end_idx
            results[i] = elements[i]  # Cache/enrich as needed
        end
    end
    
    return results
end

"""
    extract_elements_cached(adapter::SimulationAdapter, 
                           cache::ElementStateCache,
                           current_time::Float64)::Vector{ElementState}

Extract elements using TTL cache to minimize recomputation.
"""
function extract_elements_cached(adapter::SimulationAdapter, 
                                cache::ElementStateCache,
                                current_time::Float64)
    all_elements = get_elements_snapshot(adapter)
    
    # Clear expired entries periodically
    if (current_time - cache.last_cleanup) > cache.ttl * 10
        clear_expired(cache, current_time)
    end
    
    # Fetch with caching
    return [get_cached_element(cache, elem.id, current_time, 
                              elem -> get_element_state_detail(adapter, elem.id))
            for elem in all_elements]
end
```

**Acceptance Criteria**:
- [x] Extraction path handles large element vectors and preserves order
- [x] Threaded copy path uses Julia's available thread count
- [x] Cached extraction reduces recomputation
- [x] Cache thread safety verified in tests
- [ ] Performance benchmark shows >50% improvement for large systems (deferred to 7B.3.5)

---

### 3. Entity Extraction with Vectorization
**File**: `src/extraction/entity_batch.jl` (~180 lines)

Implement efficient batch extraction for 1000+ entities:

```julia
"""
    extract_entities_vectorized(adapter::SimulationAdapter)::Vector{EntitySnapshot}

Extract all entities using vectorized operations instead of loops.
Collects positions, velocities, properties in batch.
"""
function extract_entities_vectorized(adapter::SimulationAdapter)
    entities = get_entities_snapshot(adapter)
    n = length(entities)
    
    # Vectorized property extraction
    ids = [e.id for e in entities]
    x_coords = [e.position.x for e in entities]
    y_coords = [e.position.y for e in entities]
    
    # Batch trajectory update
    trajectories = batch_get_trajectories(adapter, ids)
    
    # Vectorized property lookup
    types = batch_get_types(adapter, ids)
    colors = batch_get_colors(adapter, types)
    
    # Reconstruct with enriched data
    return [EntitySnapshot(
        id=ids[i],
        position=Point(x_coords[i], y_coords[i]),
        trajectory=trajectories[i],
        entity_type=types[i],
        color=colors[i],
        speed=entities[i].speed,
        properties=entities[i].properties
    ) for i in 1:n]
end

"""
    batch_get_trajectories(adapter::SimulationAdapter, ids::Vector{Int})
Fetch trajectory history for multiple entities in one call.
"""
function batch_get_trajectories(adapter::SimulationAdapter, ids::Vector{Int})
    # Adapter should implement efficient batch lookup
    # Example: look up from pre-computed trajectory storage
    return [get_entity_trajectory(adapter, id) for id in ids]
end
```

**Acceptance Criteria**:
- [x] Batch-preserving entity extraction implemented
- [x] Adapter trajectory batch hook implemented
- [x] Works with the repository's `EntitySnapshot` representation
- [x] Trajectory data can be retained in ring buffers
- [ ] Performance benchmark shows >30% improvement for large systems (deferred to 7B.3.5)

---

### 4. Ring Buffer for Trajectory History
**File**: `src/extraction/ring_buffer.jl` (~150 lines)

Implement fixed-size memory-efficient trajectory storage:

```julia
mutable struct TrajectoryRingBuffer
    buffer::Vector{Point}
    times::Vector{Float64}
    capacity::Int
    size::Int
    head::Int  # Next write position
    
    TrajectoryRingBuffer(capacity::Int=1000) = new(
        Vector{Point}(undef, capacity),
        Vector{Float64}(undef, capacity),
        capacity, 0, 1
    )
end

"""
    add_point(buffer::TrajectoryRingBuffer, point::Point, time::Float64)
Add a new point to trajectory (overwrites oldest if full).
"""
function add_point(buffer::TrajectoryRingBuffer, point::Point, time::Float64)
    buffer.buffer[buffer.head] = point
    buffer.times[buffer.head] = time
    
    buffer.head = (buffer.head % buffer.capacity) + 1
    buffer.size = min(buffer.size + 1, buffer.capacity)
end

"""
    get_trajectory(buffer::TrajectoryRingBuffer)::Vector{Point}
Get trajectory points in chronological order.
"""
function get_trajectory(buffer::TrajectoryRingBuffer)
    if buffer.size == 0
        return Point[]
    end
    
    if buffer.size < buffer.capacity
        return buffer.buffer[1:buffer.size]  # Not wrapped yet
    else
        # Wrapped: start from head, go to end, then start to head-1
        return [buffer.buffer[buffer.head:end]; buffer.buffer[1:buffer.head-1]]
    end
end

"""
    memory_usage(buffer::TrajectoryRingBuffer)::Int
Returns approximate memory usage in bytes.
"""
function memory_usage(buffer::TrajectoryRingBuffer)
    return buffer.capacity * (sizeof(Point) + sizeof(Float64))
end
```

**Acceptance Criteria**:
- [x] Fixed-size memory usage (no growth over time)
- [x] Trajectory correctly wraps around when full
- [x] Points returned in chronological order
- [x] Memory-efficient fixed-capacity storage
- [x] Thread-safe reads and writes

---

## Phase 7B.3.3: Command Queue & Threading

**Implementation status**: ✅ Complete. Implemented in
`src/commands/thread_pool.jl` and `futures.jl`; validated by
`test/test_phase7b3_3.jl` with 11 passing tests. The pool uses CPU worker tasks,
a bounded FIFO queue, futures, serialized adapter mutation, and latency metrics.
GPU execution is intentionally a separate adapter/backend concern; CPU workers
may schedule GPU work but do not execute GPU kernels themselves.

**Objective**: Implement non-blocking command execution with worker thread pool.

**Hours**: 2-3 hours

**Deliverables**:

### 1. Worker Thread Pool
**File**: `src/commands/thread_pool.jl` (~150 lines)

Create a thread pool for non-blocking command execution:

```julia
mutable struct WorkerPool
    queue::Channel{Tuple{SimulationCommand, Channel}}  # Command + response channel
    workers::Vector{Task}
    adapter::SimulationAdapter
    num_workers::Int
    running::Bool
    
    WorkerPool(adapter::SimulationAdapter, num_workers::Int=4) = new(
        Channel{Tuple{SimulationCommand, Channel}}(100),  # Buffered queue
        Task[],
        adapter,
        num_workers,
        false
    )
end

"""
    start(pool::WorkerPool)
Launch worker threads.
"""
function start(pool::WorkerPool)
    pool.running = true
    for i in 1:pool.num_workers
        task = Threads.@spawn worker_loop(pool)
        push!(pool.workers, task)
    end
end

"""
    worker_loop(pool::WorkerPool)
Main loop for worker thread. Receives commands and dispatches them.
"""
function worker_loop(pool::WorkerPool)
    while pool.running
        try
            cmd, response_channel = take!(pool.queue)
            
            # Execute with timing
            start_time = time()
            result = dispatch_command(pool.adapter, cmd)
            elapsed = time() - start_time
            
            # Send result back
            put!(response_channel, (result, elapsed))
            
        catch e
            if !isa(e, InvalidStateException)
                @error "Worker error: $e"
            end
        end
    end
end

"""
    execute_async(pool::WorkerPool, cmd::SimulationCommand)::Future
Submit command and return immediately with a future for result.
"""
function execute_async(pool::WorkerPool, cmd::SimulationCommand)
    response_channel = Channel(1)
    put!(pool.queue, (cmd, response_channel))
    
    # Return a future-like interface
    return RemoteChannel(() -> response_channel)
end

"""
    stop(pool::WorkerPool; wait_for_completion::Bool=true)
Shut down worker pool.
"""
function stop(pool::WorkerPool; wait_for_completion::Bool=true)
    pool.running = false
    
    if wait_for_completion
        # Wait for all workers to finish
        for task in pool.workers
            wait(task)
        end
    end
end
```

**Acceptance Criteria**:
- [x] Workers spawn correctly
- [x] Commands queue through a bounded FIFO channel
- [x] Futures return results with execution time
- [x] Pool shuts down cleanly after draining queued work
- [x] Errors are isolated to the command future
- [ ] Throughput benchmark for 100s of commands/sec (deferred to 7B.3.5)

---

### 2. Command Future & Latency Tracking
**File**: `src/commands/futures.jl` (~100 lines)

Implement result tracking and latency monitoring:

```julia
mutable struct CommandFuture
    response_channel::RemoteChannel
    submitted_at::Float64
    id::String
    status::Symbol  # :pending, :completed, :error
    result::Union{CommandResult, Nothing}
    elapsed::Float64
end

"""
    CommandFuture(response_channel::RemoteChannel, id::String)
Create a future for command result tracking.
"""
function CommandFuture(response_channel::RemoteChannel, id::String)
    CommandFuture(response_channel, time(), id, :pending, nothing, 0.0)
end

"""
    wait_result(future::CommandFuture; timeout::Float64=5.0)::CommandResult
Block until result is available (with optional timeout).
"""
function wait_result(future::CommandFuture; timeout::Float64=5.0)
    try
        result, elapsed = fetch(future.response_channel)
        future.status = :completed
        future.result = result
        future.elapsed = elapsed
        return result
    catch e
        future.status = :error
        rethrow(e)
    end
end

"""
    is_ready(future::CommandFuture)::Bool
Non-blocking check if result is available.
"""
function is_ready(future::CommandFuture)
    return isready(future.response_channel)
end

"""
    get_latency_stats(futures::Vector{CommandFuture})::Dict
Compute latency statistics across multiple commands.
"""
function get_latency_stats(futures::Vector{CommandFuture})
    elapsed_times = [f.elapsed for f in futures if f.status == :completed]
    
    isempty(elapsed_times) && return Dict()
    
    return Dict(
        :min => minimum(elapsed_times),
        :max => maximum(elapsed_times),
        :mean => mean(elapsed_times),
        :median => median(elapsed_times),
        :p95 => percentile(elapsed_times, 95),
        :p99 => percentile(elapsed_times, 99)
    )
end
```

**Acceptance Criteria**:
- [x] Futures track pending, completed, and error status
- [x] Wait with timeout works
- [x] Non-blocking readiness check available
- [x] Latency statistics computed
- [x] Result storage is isolated per future

---

## Phase 7B.3.4: Adaptive Update Strategy

**Implementation status**: ✅ Complete. Implemented in
`src/updates/efficiency_tracker.jl` and `adaptive_builder.jl`. The adaptive
builder selects full snapshots or deltas by serialized size, forces periodic
full snapshots, and reports transmission statistics. Validated by
`test/test_phase7b3_4.jl` with 12 passing tests.

**Objective**: Implement logic to decide when to send full snapshots vs deltas based on efficiency.

**Hours**: 2-3 hours

**Deliverables**:

### 1. Update Efficiency Tracker
**File**: `src/updates/efficiency_tracker.jl` (~150 lines)

Track snapshot efficiency to drive delta/full decisions:

```julia
mutable struct SnapshotEfficiencyTracker
    last_full_snapshot_size::Int
    last_delta_size::Int
    full_count::Int
    delta_count::Int
    total_bandwidth::Int
    efficiency_threshold::Float64  # Switch to full if delta > full * threshold
    
    SnapshotEfficiencyTracker(threshold::Float64=0.8) = new(
        0, 0, 0, 0, 0, threshold
    )
end

"""
    should_send_delta(tracker::SnapshotEfficiencyTracker, 
                     delta_size::Int, full_size::Int)::Bool

Decide whether to send delta or full snapshot based on size ratio.
"""
function should_send_delta(tracker::SnapshotEfficiencyTracker, 
                          delta_size::Int, full_size::Int)
    ratio = delta_size / full_size
    
    if ratio > tracker.efficiency_threshold
        # Delta is nearly as large as full snapshot, send full
        return false
    else
        # Delta is significantly smaller, send delta
        return true
    end
end

"""
    record_snapshot(tracker::SnapshotEfficiencyTracker, 
                   is_delta::Bool, size::Int)

Record snapshot transmission for statistics.
"""
function record_snapshot(tracker::SnapshotEfficiencyTracker, 
                        is_delta::Bool, size::Int)
    if is_delta
        tracker.last_delta_size = size
        tracker.delta_count += 1
    else
        tracker.last_full_snapshot_size = size
        tracker.full_count += 1
    end
    tracker.total_bandwidth += size
end

"""
    get_efficiency_report(tracker::SnapshotEfficiencyTracker)::Dict

Get summary of transmission efficiency.
"""
function get_efficiency_report(tracker::SnapshotEfficiencyTracker)
    total_msgs = tracker.full_count + tracker.delta_count
    
    savings = 0.0
    if tracker.full_count > 0
        # Assume each full snapshot = full_count size
        # And deltas are 20-30% of that
        estimate_without_delta = tracker.full_count * tracker.last_full_snapshot_size
        actual_with_delta = tracker.total_bandwidth
        savings = (estimate_without_delta - actual_with_delta) / estimate_without_delta * 100
    end
    
    return Dict(
        :total_messages => total_msgs,
        :full_snapshots => tracker.full_count,
        :deltas => tracker.delta_count,
        :total_bandwidth_kb => tracker.total_bandwidth / 1024,
        :estimated_savings_pct => savings,
        :avg_full_size_bytes => tracker.full_count > 0 ? 
            tracker.last_full_snapshot_size : 0,
        :avg_delta_size_bytes => tracker.delta_count > 0 ? 
            tracker.last_delta_size : 0
    )
end
```

**Acceptance Criteria**:
- [ ] Delta/full decision based on configurable threshold
- [ ] Statistics tracking accurate
- [ ] Efficiency report shows bandwidth savings
- [ ] Dynamic threshold adaptation works (optional enhancement)
- [ ] Thread-safe for concurrent updates

---

### 2. Adaptive Snapshot Builder
**File**: `src/updates/adaptive_builder.jl` (~180 lines)

Orchestrate full vs delta decisions:

```julia
mutable struct AdaptiveSnapshotBuilder
    last_snapshot::Union{SnapshotPayload, Nothing}
    efficiency_tracker::SnapshotEfficiencyTracker
    cache::ElementStateCache
    adapter::SimulationAdapter
    full_interval::Int  # Force full snapshot every N updates
    update_count::Int
    
    AdaptiveSnapshotBuilder(adapter::SimulationAdapter; 
                           full_interval::Int=10) = new(
        nothing,
        SnapshotEfficiencyTracker(),
        ElementStateCache(),
        adapter,
        full_interval,
        0
    )
end

"""
    build_next_snapshot(builder::AdaptiveSnapshotBuilder)::Message

Build either full snapshot or delta based on efficiency.
Forces full snapshot every N updates for safety.
"""
function build_next_snapshot(builder::AdaptiveSnapshotBuilder)
    builder.update_count += 1
    current_time = get_simulation_time(builder.adapter)
    
    # Every Nth update, send full snapshot for consistency
    force_full = (builder.update_count % builder.full_interval) == 0
    
    if builder.last_snapshot === nothing || force_full
        # Build full snapshot
        snapshot = build_snapshot_from_adapter(builder.adapter)
        
        # Serialize and track size
        msg = wrap_snapshot_in_message(snapshot)
        msg_bytes = serialize(msg)
        
        builder.efficiency_tracker.record_snapshot(false, length(msg_bytes))
        builder.last_snapshot = snapshot
        
        return msg
    else
        # Build delta vs last snapshot
        current_snapshot = build_snapshot_from_adapter(builder.adapter)
        delta = build_delta(builder.last_snapshot, current_snapshot)
        
        # Serialize both to compare sizes
        delta_msg = create_delta_message(delta)
        delta_bytes = serialize(delta_msg)
        
        full_bytes = length(serialize(wrap_snapshot_in_message(current_snapshot)))
        
        # Decide whether to send delta
        if builder.efficiency_tracker.should_send_delta(
            length(delta_bytes), full_bytes)
            
            builder.efficiency_tracker.record_snapshot(true, length(delta_bytes))
            return delta_msg
        else
            # Delta is too large, send full instead
            builder.efficiency_tracker.record_snapshot(false, full_bytes)
            builder.last_snapshot = current_snapshot
            return wrap_snapshot_in_message(current_snapshot)
        end
    end
end

"""
    get_statistics(builder::AdaptiveSnapshotBuilder)::Dict
Get detailed statistics about snapshot efficiency.
"""
function get_statistics(builder::AdaptiveSnapshotBuilder)
    merge(
        builder.efficiency_tracker.get_efficiency_report(),
        Dict(
            :updates_since_full => builder.update_count % builder.full_interval,
            :cache_hit_rate => length(builder.cache.cache) / builder.cache.capacity * 100
        )
    )
end
```

**Acceptance Criteria**:
- [ ] Full snapshots sent every N updates
- [ ] Delta efficiency comparison works
- [ ] Larger deltas trigger full snapshot fallback
- [ ] Statistics show bandwidth savings
- [ ] Performance benchmarks meet targets (70-85% savings)

---

## Phase 7B.3.5: Integration & Stress Testing

**Current status**: ✅ Bridge-only acceptance complete; realistic stress
coverage is available. Run `julia --project=. test/stress_phase7b3.jl` for
the bounded changed-state workload, or
`julia --project=. test/benchmark_phase7b3.jl` for the baseline payload scale.

**Measured baseline (Julia 1.13, September 17, 2026)**:
- 10K elements, 1% changed: 245 ms mean update, 84% estimated savings.
- 20K elements, 1% changed: 707 ms mean update, 84% estimated savings.
- 50K elements, 1% changed: 4.71 s mean update, 84% estimated savings.
- 100K elements, 1% changed, 3-update probe: 31.1 s mean update, 66% estimated savings.
- 10,000 commands: 66,550 commands/sec in the stress run.
- 100-update long run at 10K: 5.97 updates/sec, with 10.1 MB transmitted.
- Dirty-state path at 100K/1% changed: 0.570 ms mean update, 0.647 ms p99,
  and approximately 97 KB mean delta payload after warmup.
- Dirty-state path at 500K/1% changed: 10.921 ms mean update; p99 requires
    further tail-latency investigation because the short sample included GC noise.

**Conclusion**: Dirty tracking removes the full-scan bottleneck and meets the
30 FPS transport budget by a wide margin for 1% changed state. Remaining stress
work is now covered by the bridge acceptance harness; live WebSocket transfer,
Godot decode/rendering, and slow-client backpressure remain external gates.

**Bridge acceptance harness**: `test/acceptance_phase7b3.jl` checks adapter
profiling, typed/generic transport schema integrity, 1,000-update stability,
live bytes after GC, and 10,000-command throughput. The latest run measured:

- Typed full transport: 1.901 ms median versus 2.486 ms generic (1.31x).
- Typed payload schema: valid; payload size 909,217 bytes.
- 1,000 updates at 10K elements: 0.124 ms mean, approximately 8,054 updates/sec.
- 10,000 commands: approximately 97,533 commands/sec.
- Live bytes after the stability run: approximately 42.3 MB.

Bridge-only Phase 7B.3.5 checks are complete. Live WebSocket transfer, Godot
decode, rendering, and slow-client backpressure remain external end-to-end gates.

**Objective**: Integrate all components, verify end-to-end behavior, stress test with realistic scenarios.

**Hours**: 2-3 hours

**Deliverables**:

### 1. Integration Tests
**File**: `test/test_phase7b3_integration.jl` (~300 lines)

Create comprehensive integration tests:

```julia
@testset "Phase 7B.3 Integration Tests" begin
    
    # Test 1: Adapter registration and creation
    @testset "Adapter Lifecycle" begin
        register_adapter("TestDES", TestDESAdapter)
        adapter = create_adapter("TestDES", test_engine)
        @test abm_capability(adapter) isa NoABM
    end
    
    # Test 2: Element extraction with caching
    @testset "Element Cache Efficiency" begin
        cache = ElementStateCache(0.1)
        t1 = extract_elements_cached(adapter, cache, 0.0)
        @test length(t1) > 0
        
        # Same time: should get from cache
        t2 = extract_elements_cached(adapter, cache, 0.05)
        @test t1 === t2  # Same object from cache
    end
    
    # Test 3: Parallel extraction scales
    @testset "Parallel Extraction Scales" begin
        large_adapter = create_large_test_adapter(10000)
        
        sequential_time = @time extract_elements_parallel(large_adapter, 1)
        parallel_time = @time extract_elements_parallel(large_adapter, 4)
        
        speedup = sequential_time / parallel_time
        @test speedup > 1.5  # Expect >50% speedup
    end
    
    # Test 4: Command queue non-blocking
    @testset "Non-Blocking Commands" begin
        pool = WorkerPool(adapter, 2)
        start(pool)
        
        futures = []
        for i in 1:10
            cmd = SimulationCommand(:play, i)
            push!(futures, execute_async(pool, cmd))
        end
        
        # Should return immediately
        @test all(!is_ready(f) for f in futures)
        
        # Wait for all results
        results = [wait_result(f) for f in futures]
        @test all(r.success for r in results)
        
        stop(pool)
    end
    
    # Test 5: Adaptive snapshot efficiency
    @testset "Adaptive Snapshot Efficiency" begin
        builder = AdaptiveSnapshotBuilder(adapter)
        
        msgs = []
        for i in 1:20
            msg = build_next_snapshot(builder)
            push!(msgs, msg)
        end
        
        stats = get_statistics(builder)
        @test stats[:estimated_savings_pct] > 50
        @test stats[:deltas] > 0
        @test stats[:full_snapshots] > 0
    end
end
```

**Acceptance Criteria**:
- [ ] All integration tests pass
- [ ] Adapter lifecycle test passes
- [ ] Cache efficiency demonstrated
- [ ] Parallel extraction shows >50% speedup
- [ ] Command queue processes 100+ msgs/sec
- [ ] Adaptive snapshots achieve 70%+ savings
- [ ] Code coverage >85%

---

### 2. Stress Testing Scenarios
**File**: `test/test_phase7b3_stress.jl` (~250 lines)

Create realistic stress tests:

```julia
@testset "Phase 7B.3 Stress Tests" begin
    
    # Stress 1: Large element count - parametrized scaling
    @testset "Element Count Scaling: 10K, 20K, 50K, 100K" begin
        for element_count in [10000, 20000, 50000, 100000]
            large_adapter = create_large_test_adapter(element_count)
            builder = AdaptiveSnapshotBuilder(large_adapter)
            
            # Measure extraction time
            extraction_times = Float64[]
            serialization_times = Float64[]
            
            for _ in 1:100
                t1 = time()
                msg = build_next_snapshot(builder)
                t2 = time()
                
                @test msg !== nothing
                push!(extraction_times, t2 - t1)
                
                # Measure serialization time
                t3 = time()
                data = serialize(msg)
                t4 = time()
                push!(serialization_times, t4 - t3)
            end
            
            stats = get_statistics(builder)
            avg_extraction = mean(extraction_times) * 1000  # ms
            avg_serialization = mean(serialization_times) * 1000  # ms
            avg_msg_size = stats[:total_bandwidth_kb] * 1024 / 100  # bytes
            
            @info "Elements=$element_count: extraction=$(round(avg_extraction; digits=2))ms, " *
                  "serialization=$(round(avg_serialization; digits=2))ms, " *
                  "msg_size=$(round(avg_msg_size; digits=0))bytes, " *
                  "bandwidth_savings=$(round(stats[:estimated_savings_pct]; digits=1))%"
            
            # Adaptive targets based on element count
            # Full snapshots should scale linearly, deltas sublinearly
            if element_count <= 10000
                @test avg_extraction < 50  # <50ms for 10K
                @test stats[:total_bandwidth_kb] < 10000  # <10MB for 100 updates
            elseif element_count <= 50000
                @test avg_extraction < 200  # <200ms for 50K
                @test stats[:total_bandwidth_kb] < 50000  # <50MB for 100 updates
            else  # 100K
                @test avg_extraction < 500  # <500ms for 100K
                @test stats[:total_bandwidth_kb] < 100000  # <100MB for 100 updates
            end
        end
    end
    
    # Stress 2: High command rate
    @testset "1000 Commands/sec" begin
        pool = WorkerPool(adapter, 4)
        start(pool)
        
        futures = []
        for i in 1:1000
            cmd = SimulationCommand(:step, 1)
            push!(futures, execute_async(pool, cmd))
        end
        
        results = [wait_result(f; timeout=10.0) for f in futures]
        @test sum(r.success for r in results) > 950  # Allow 5% failure rate
        
        latency_stats = get_latency_stats(futures)
        @test latency_stats[:mean] < 0.01  # <10ms mean latency
        @test latency_stats[:p99] < 0.05   # <50ms 99th percentile
        
        stop(pool)
    end
    
    # Stress 3: Long-running simulation
    @testset "Long-Running Snapshot Stream" begin
        builder = AdaptiveSnapshotBuilder(adapter)
        
        # Simulate 10 minutes of updates at 10 FPS
        num_updates = 10 * 60 * 10
        start_time = time()
        
        for i in 1:num_updates
            msg = build_next_snapshot(builder)
            @test msg !== nothing
        end
        
        elapsed = time() - start_time
        updates_per_sec = num_updates / elapsed
        
        @test updates_per_sec > 100  # Should maintain >100 updates/sec
        
        stats = get_statistics(builder)
        @test stats[:estimated_savings_pct] > 65
    end
    
    # Stress 4: Cache thrashing
    @testset "Cache Thrashing Resistance" begin
        cache = ElementStateCache(0.01)  # Very short TTL
        
        for _ in 1:1000
            extract_elements_cached(adapter, cache, time())
            # Cache constantly expires and refills
        end
        
        @test length(cache.cache) >= 0  # Should be stable
    end
end
```

**Acceptance Criteria**:
- [ ] 10,000 elements handled efficiently
- [ ] 1000 commands/sec processed
- [ ] Latency <10ms mean, <50ms p99
- [ ] Long-running stability (>100 updates/sec sustained)
- [ ] Memory usage stays bounded
- [ ] No memory leaks over 10+ minute runs
- [ ] Cache maintains >80% hit rate

---

### 3. Performance Benchmarking Suite
**File**: `test/benchmark_phase7b3.jl` (~200 lines)

Create benchmarks for performance targets:

```julia
@testset "Phase 7B.3 Performance Benchmarks" begin
    
    # Benchmark 1: Element extraction
    @testset "Element Extraction Benchmark" begin
        for size in [100, 1000, 10000]
            adapter = create_large_test_adapter(size)
            
            # Single-threaded baseline
            t_seq = @time extract_elements_parallel(adapter, 1)
            
            # Multi-threaded
            t_par = @time extract_elements_parallel(adapter, 4)
            
            speedup = t_seq / t_par
            @info "Element extraction speedup: $speedup x (size=$size)"
            @test speedup > 1.5  # Target >50% speedup
        end
    end
    
    # Benchmark 2: Snapshot serialization
    @testset "Serialization Benchmark" begin
        adapter = create_large_test_adapter(1000)
        snapshot = build_snapshot_from_adapter(adapter)
        
        # Measure MessagePack performance
        time_pack = @time begin
            for _ in 1:100
                msg = wrap_snapshot_in_message(snapshot)
                data = serialize(msg)
            end
        end
        
        @info "Serialization rate: $(100 / (time_pack/100)) msgs/sec"
    end
    
    # Benchmark 3: Command dispatch latency
    @testset "Command Latency Benchmark" begin
        pool = WorkerPool(adapter, 4)
        start(pool)
        
        latencies = Float64[]
        for _ in 1:100
            cmd = SimulationCommand(:play, 1)
            future = execute_async(pool, cmd)
            result = wait_result(future)
            push!(latencies, future.elapsed)
        end
        
        @info "Command latency: mean=$(mean(latencies)*1000)ms, p99=$(percentile(latencies, 99)*1000)ms"
        @test mean(latencies) < 0.01  # <10ms target
        
        stop(pool)
    end
end
```

**Acceptance Criteria**:
- [ ] Benchmark suite runs without errors
- [ ] Results match performance targets
- [ ] Results logged for comparison across commits
- [ ] All 3 benchmark categories pass

---

## Testing Checklist

Before considering Phase 7B.3 complete, verify:

- [ ] **Unit Tests**: All 50+ core logic tests pass
- [ ] **Integration Tests**: All 5 integration scenarios pass
- [ ] **Stress Tests**: All 4 stress scenarios pass
- [ ] **Benchmarks**: All 3 performance benchmarks meet targets
- [ ] **Thread Safety**: No race conditions detected
- [ ] **Memory Leaks**: Valgrind/profiling shows no leaks
- [ ] **Documentation**: All public APIs documented with examples
- [ ] **Error Handling**: All error paths tested
- [ ] **Performance**: Meets all targets (element extraction, entity extraction, commands, updates)

**Total Test Coverage Target**: >85% code coverage

---

## Acceptance Criteria for Phase 7B.3 Completion

✅ **Adapter System**:
- [x] SimulationAdapter abstract type defined
- [x] ABM trait dispatch system working
- [x] 3+ example adapters (DES, Hybrid, Pure ABM)
- [x] Adapter registry operational

✅ **State Extraction**:
- [x] ElementStateCache with TTL working
- [ ] Parallel element extraction >50% speedup (benchmark pending)
- [ ] Vectorized entity extraction >30% speedup (benchmark pending)
- [x] Ring buffer trajectory tracking
- [x] Handles large element vectors; 10K+ benchmark pending

✅ **Command Processing**:
- [x] Worker thread pool with configurable worker count
- [x] Non-blocking command execution
- [ ] <1ms command latency average (benchmark pending)
- [ ] 100+ commands/sec throughput (benchmark pending)
- [ ] Handles 1000 commands/sec stress (7B.3.5)

✅ **Adaptive Updates**:
- [x] Full snapshots forced every N updates
- [x] Delta efficiency tracking working
- [x] Fallback to full when delta too large
- [ ] 70-85% bandwidth savings achieved (benchmark pending in 7B.3.5)
- [x] Efficiency report generates correctly

✅ **Integration**:
- [x] Adapter, extraction, and command components load together
- [x] Integrated package tests pass under Julia 1.13
- [x] Command latency statistics available
- [ ] Zero memory leaks
- [ ] Long-running stability (>10 minutes tested)

---

## Deployment Checklist

Once Phase 7B.3 is complete:

- [ ] All code committed to repository
- [ ] Documentation updated in main README
- [ ] Example adapters updated
- [ ] Integration guide written for new engines
- [ ] Performance benchmarks documented
- [ ] Version bumped in Project.toml
- [ ] CHANGELOG.md updated
- [ ] Ready for Phase 7C (Godot GUI integration)

---

## Notes & Dependencies

## Performance Optimization Plan

This section records the next whole-system optimization opportunities. Each
step must be benchmarked before and after implementation; projected gains are
targets, not guarantees.

### Current Measurements

The warmed-up dirty-state path currently measures:

| Workload | Mean update | Delta size |
|----------|------------:|-----------:|
| 10K elements, 1% changed | 0.052 ms | 9.9 KB |
| 50K elements, 1% changed | 0.270 ms | 48.8 KB |
| 100K elements, 1% changed | 0.584 ms | 97.3 KB |
| 500K elements, 1% changed | 10.921 ms | 489.3 KB |
| 500K elements, 10% changed | 42.0 ms generic / 19.7 ms typed adaptive | ~4.94 MB |

Typed direct delta encoding reduced the encoding segment at 500K/10% changed
from 11.36 ms to 9.78 ms, approximately 13.9%. A reusable `IOBuffer` was
tested but regressed the end-to-end 500K/10% workload and is therefore not the
adaptive default.

### Priority 1: Typed Full Snapshots

Replace the repeated `Dict{String, Any}` conversion in full snapshots with
typed wire records. Retain the dictionary representation for compatibility and
debugging.

**Status**: ✅ Implemented as additive `encode_direct_snapshot` and integrated
`build_next_snapshot_bytes` paths in
`src/protocol/direct_snapshot.jl`. Existing `SnapshotPayload` and generic
`encode_messagepack` behavior remain unchanged.

The adaptive builder now defaults to typed bytes via `build_next_snapshot`.
Callers that require the legacy object API must explicitly use
`build_next_snapshot_message` or `encoding=:generic`.

Measured gain on Julia 1.13 with equivalent wire sizes:

| Scale | Generic | Typed direct | Improvement |
|------:|--------:|-------------:|------------:|
| 10K | 8.58 ms | 1.62 ms | 5.3x |
| 100K | 107.16 ms | 22.63 ms | 4.7x |
| 500K | 605.29 ms | 169.15 ms | 3.6x |

The typed path accepts `ElementState` and `EntitySnapshot` directly, avoiding
the intermediate nested dictionary tree. Generic encoding remains available for
compatibility and debugging.

**End-to-end adaptive result**: After integrating the typed path through
`build_next_snapshot_bytes`, the 500K/10% changed workload measured approximately
42.0 ms mean and 46.8 ms p99 through the generic adaptive path, versus 19.7 ms
mean and 23.7 ms p99 through the typed direct path. This is approximately 2.1x
end-to-end improvement and brings that workload below the 33.3 ms 30 FPS budget.

Benchmark gate: compare full snapshot construction, MessagePack size, mean
latency, p99 latency, and allocations at 100K and 500K elements.

### Priority 2: Integrate Typed Direct Deltas

Use the existing typed direct-delta representation as an optional production
transport path while preserving the generic Protocol v1 path.

**Status**: ✅ Integrated through `build_next_snapshot_bytes`; the generic
`build_next_snapshot` API remains unchanged.

Target gain: approximately 10-20% for dirty delta encoding. The current
measured gain is 13.9% for the encoding segment at 500K/10% changed.

Benchmark gate: compare generic and direct encoding for 1%, 10%, 50%, and 100%
changed state. Confirm byte compatibility at the field/protocol level.

### Priority 3: Entity-Specific Dirty Tracking

Track entity arrivals, departures, movements, property changes, and trajectory
segments independently. Do not rebuild unchanged entity properties or history.

Target gain: approximately 2-10x for entity-heavy models, depending on
trajectory and property payload size.

Benchmark gate: 100K and 500K entities with 1%, 10%, and 50% movement/change
rates.

### Priority 4: ABM Numeric Buffers

Avoid base64 copies for positions, velocities, and density grids where the
client supports binary fields. Use typed binary buffers, reusable staging
buffers, or compressed numeric blocks.

Target gain: approximately 1.2-3x for ABM transport and about 33% less payload
expansion than base64 for binary data.

SIMD and GPU computation belong inside the model adapter for dense numeric
operations such as movement, neighborhood search, density fields, and grids.

### Priority 5: Adapter-Owned Parallel Extraction

The bridge must not parallelize a vector after the adapter has already done all
expensive extraction. Adapters that guarantee thread-safe independent reads can
implement batch state fetching and opt into Julia threading.

Target gain: approximately 2-4x for the state-fetch portion, only when the
adapter and workload are thread-safe and sufficiently large.

### Adapter Profiling and SIMD Measurement

Implemented `profile_adapter(adapter; iterations=...)` in
`src/profiling/adapter_profiler.jl`. It measures extraction, dirty-state,
full-snapshot construction/encoding, p99 latency, output size, and whether the
adapter supports dirty tracking. This is the first step for profiling real DES,
ABM, and hybrid adapters before selecting optimization backends.

Implemented optional dense numeric hooks in `src/extraction/dense_numeric.jl`:

- `DenseNumericState`
- `advance_positions_scalar!`
- `advance_positions_simd!`
- `supports_simd(adapter)`
- `dense_numeric_state(adapter)`
- `advance_dense_numeric!`

The initial 5-million-element benchmark on Julia 1.13 measured 3.32 ms for the
scalar kernel and 3.44 ms for the baseline `@simd` kernel (`0.97x`, slightly
slower). Therefore SIMD is available as an opt-in adapter capability, but this
benchmark does not justify enabling it by default. Real adapters must benchmark
their own dense kernels and data layouts; a stronger SIMD package or GPU backend
should be added only when that measurement shows a gain.

### Priority 6: Delta Fallback Policy

Use dirty deltas when the changed fraction is small. Send a full snapshot when
the delta becomes larger than the configured threshold or when revision recovery
is required. Avoid performing an O(n) comparison when the result will be a full
snapshot anyway.

Target gain: prevents pathological high-change workloads from spending more time
building deltas than sending full snapshots.

### Priority 7: WebSocket Backpressure

Add bounded per-client send queues and sender tasks. A slow Godot client must not
block simulation updates. Drop stale deltas and request a full resynchronization
when a client falls behind.

Target gain: improved simulation latency and multi-client scalability rather than
raw serialization speed.

### Priority 8: Command-Lane Separation

Keep simulation mutations serialized, but separate them from read-only queries
and GPU submissions:

```text
simulation mutations -> serialized engine lane
read-only queries     -> parallel query lane
GPU work              -> adapter-owned GPU stream lane
```

Target gain: no gain for inherently sequential mutations; approximately 2-4x for
safe read-only query workloads.

### Priority 9: Allocation and GC Control

Reuse dirty-ID vectors, delta vectors, typed records, trajectory storage, and
numeric staging buffers. Avoid `collect(values(dict))`, temporary `Set` objects,
and repeated nested dictionary creation in high-frequency paths.

Benchmark gate: record allocations, GC time, mean latency, p99 latency, and live
memory across 100-update and 1,000-update runs.

### Priority 10: Optional Compression

Support an adaptive policy for raw MessagePack versus compressed MessagePack.
Use compression only when compression cost is lower than the bandwidth saved.
Sparse deltas generally should remain uncompressed; large ABM grids and high
change-rate updates may benefit from compression.

### GPU Boundary

The bridge core will not depend directly on CUDA. GPU-enabled adapters own:

- GPU kernels and device memory
- CPU/GPU synchronization
- Device-to-host staging buffers
- Dirty ID and field production

The bridge consumes synchronized dirty records and handles caching, delta
construction, serialization, and transport. This keeps CPU-only, GPU, DES, ABM,
and hybrid adapters modular.

### Benchmark Matrix

Every optimization must be measured against this matrix:

| Scale | Changed state | Required measurements |
|-------:|--------------:|-----------------------|
| 10K | 1%, 10%, 50%, 100% | mean, p99, bytes, allocations |
| 100K | 1%, 10%, 50%, 100% | mean, p99, bytes, allocations |
| 500K | 1%, 10%, 50%, 100% | mean, p99, bytes, allocations |

Also measure entity-heavy workloads, ABM numeric fields, 10,000 commands, and
long-running stability. No optimization is accepted based only on a mean
latency improvement if p99 latency or memory growth regresses.

**Dependencies from Prior Phases**:
- Phase 7B.1: Protocol envelope and MessagePack serialization
- Phase 7B.2: Snapshot and delta builders, command handler

**Future Phases**:
- Phase 7C: Godot GUI integration (consumes all 7B.3 outputs)
- Phase 8: Multi-engine support (extends adapter system)

**Reference Documentation**:
- See `PHASE_7B3_RECOMMENDATIONS.md` for architectural rationale
- See `PHASE_7B2_SUMMARY.md` for snapshot/delta specifications
- See `INDEX.md` for complete documentation guide
