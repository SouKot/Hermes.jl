"""
    SimCore

Shared foundation for the Hermes/Antigravity simulation platform.

Provides:
- Abstract event hierarchy and cancellable event wrapper
- `SimClock` — adjustable-speed simulation clock
- ECS component structs (`CrowdAgent`, `FluidParticle`, `DESAgent`, etc.)
- `SimWorld` — global simulation state container
- `SimStats` — legacy statistics accumulator (retained for backward compat)
- `WelchDetector` — online steady-state detector (Welch 1983)
- `AbstractCollector` + 5 concrete collectors (Sprint 4I)
- `StatsPipeline` — composable, warmup-aware statistics pipeline (Sprint 4I)
- `WarmupPolicy` — pluggable warmup strategies (Sprint 4I)
- Output analysis: `check_littles_law`, `batch_means_ci`, `replicate` (Sprint 4I)
- `SimEntity` ID management
"""
module SimCore

using DataStructures: PriorityQueue, enqueue!, dequeue!, dequeue_pair!, peek, isempty
using StaticArrays: SVector

# ── Source files (order matters: dependencies first) ─────────────────────────
include("events.jl")
include("clock.jl")
include("components.jl")
include("warmup.jl")     # WelchDetector — must precede pipeline.jl
include("collectors.jl") # AbstractCollector + 5 collectors — must precede pipeline.jl
include("pipeline.jl")   # StatsPipeline, WarmupPolicy — uses warmup + collectors
include("analysis.jl")   # check_littles_law, batch_means_ci, replicate — uses pipeline
include("stats.jl")      # SimStats (legacy) — must be defined before SimWorld
include("world.jl")

# ── Public API exports ────────────────────────────────────────────────────────

# Events
export SimEvent
export EntityArrival, ProcessComplete, ResourceFailure, ScheduledChange,
       TransferOut, NullEvent
export CancellableEvent, cancel!, next_event_id!, is_cancelled

# Clock
export SimClock, throttle!, pause!, unpause!, set_speed!, step_once!, reset!,
       is_paused, sim_time

# Components
export DESAgent, CrowdAgent, FluidParticle, CrowdObstacle,
       width, height, center

# World
export SimWorld, ZoneState, new_entity_id!,
       add_des_agent!, remove_des_agent!,
       add_crowd_agent!, remove_crowd_agent!,
       add_fluid_particle!, add_obstacle!, remove_entity!,
       get_des_agent, get_crowd_agent, update_crowd_agent!,
       add_zone!, get_zone, entity_count

# Legacy stats (SimStats — retained for backward compat with SimViz)
export SimStats, record_arrival!, record_departure!, record_queue_length!,
       record_utilization!, record_uptime!, record_blocked!, reset_stats!, sim_summary,
       mean_queue_length, mean_wait_time, mean_sojourn_time,
       utilization, blocking_probability

# ── Sprint 4I: Warmup ─────────────────────────────────────────────────────────
export WelchDetector, update!, warmup_complete
export WarmupMode, WARMUP_AUTO, WARMUP_NONE, WARMUP_FIXED, WARMUP_IMMEDIATE
export WarmupPolicy, tick_warmup!

# ── Sprint 4I: Collectors ─────────────────────────────────────────────────────
export AbstractCollector
export MeanCollector, WeightedMeanCollector, P2QuantileCollector
export ExtremaCollector, CounterCollector
export fit!, value, reset!

# ── Sprint 4I: Pipeline ───────────────────────────────────────────────────────
export StatsPipeline, add_collector!, reset!
export record_idle!   # new — not in legacy SimStats

# ── Sprint 4I: Analysis ───────────────────────────────────────────────────────
export check_littles_law, batch_means_ci, replicate, replicate_parallel
# Accelerated extension (SimCoreGPUExt) — available when AcceleratedKernels +
# KernelAbstractions are loaded.  Works on CPU threads AND all GPU backends.
export gpu_mean_var, gpu_histogram

# ── Accelerated-extension stubs (methods added by SimCoreGPUExt) ───────────────
"""
    gpu_mean_var(arr::AbstractArray{Float64}) → (mean::Float64, variance::Float64)

Compute the mean and unbiased sample variance of an array in a single parallel pass.

This function is a stub in `SimCore`. The implementation is added by `SimCoreGPUExt`
when `AcceleratedKernels` and `KernelAbstractions` are loaded.  It then works on:
- Plain `Array{Float64}` via KA CPU backend (multithreaded)
- `CuArray{Float64}` via AK CUDA backend
- `ROCArray{Float64}` via AK ROCm backend
- `MtlArray{Float64}` via AK Metal backend

Throws `MethodError` if the extension is not loaded (i.e., AcceleratedKernels not
in the active environment).  Check `SimCore._accel_available()` before calling.
"""
function gpu_mean_var end

"""
    gpu_histogram(samples::AbstractArray{Float64}, nbins::Int;
                  lo::Float64=0.0, hi::Union{Nothing,Float64}=nothing)
    → (edges::Vector{Float64}, counts::Vector{Int32})

Compute a histogram of `samples` using one `AK.mapreduce` per bin.

This function is a stub in `SimCore`. The implementation is added by `SimCoreGPUExt`
when `AcceleratedKernels` and `KernelAbstractions` are loaded.
"""
function gpu_histogram end

end

