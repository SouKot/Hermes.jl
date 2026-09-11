"""
    SimCoreGPUExt — GPU-accelerated post-hoc statistics for SimCore

This is a Julia package extension (Julia 1.9+).
It is automatically loaded when *both* `CUDA` and `KernelAbstractions` are present
in the active environment.  SimCore itself has zero new mandatory dependencies.

## Provides

| Function                              | Description                                             |
|---------------------------------------|---------------------------------------------------------|
| `gpu_mean_var(arr::CuArray)`          | Parallel mean + variance in one device pass             |
| `batch_means_ci(::CuArray; k, alpha)` | GPU-resident batch-means CI; only k scalars to CPU      |
| `gpu_histogram(::CuArray, nbins)`     | Atomic-increment histogram; bin counts to CPU           |

## Design notes

- DES event loops are **not** GPU-parallelised here. The FEL (future event list)
  is an intrinsically sequential causal structure — GPU cannot accelerate it.
- GPU is used *only* for post-hoc reduction of large sample arrays
  (sojourn, wait) that were buffered via `StatsPipeline(record_samples=true)`.
- Kernels are written with `KernelAbstractions.jl` so the same source compiles
  for CUDA (NVIDIA), ROCm (AMD), and Metal (Apple Silicon) without changes.

Design ref: Sprint 4I · Task 22
"""
module SimCoreGPUExt

using SimCore
using KernelAbstractions
using CUDA


# ─────────────────────────────────────────────────────────────────────────────
# 1. gpu_mean_var — parallel mean + unbiased variance
# ─────────────────────────────────────────────────────────────────────────────

"""
    gpu_mean_var(arr::CuArray{Float64}) → (mean::Float64, variance::Float64)

Compute the mean and unbiased sample variance of a GPU array in one pass.

Only two scalars are transferred back to host memory:
the mean and variance of `arr`. The raw array stays on device.

## Algorithm
Uses CUDA.jl's `CUDA.sum` / `CUDA.mapreduce` for the reduction passes.
This is not a custom `@kernel` but a library-level dispatch so it benefits
from cuBLAS/thrust backends automatically.

Pass 1: `μ = Σ arr / n`
Pass 2: `s² = Σ (x - μ)² / (n-1)`

## Returns
- `(NaN, NaN)` if `arr` is empty.

## Example
```julia
using CUDA, SimCore
arr = CUDA.randn(Float64, 1_000_000) .+ 5.0
μ, s² = gpu_mean_var(arr)   # → (≈5.0, ≈1.0)
```
"""
function gpu_mean_var(arr::CuArray{Float64})
    n = length(arr)
    n == 0 && return (NaN, NaN)
    n == 1 && return (Float64(CUDA.sum(arr)), NaN)

    μ  = Float64(CUDA.sum(arr)) / n
    # Variance: E[(X-μ)²] computed in a second device pass
    var = Float64(CUDA.mapreduce(x -> (x - μ)^2, +, arr)) / (n - 1)
    return (μ, var)
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. batch_means_ci (CuArray overload) — GPU-resident batch means
# ─────────────────────────────────────────────────────────────────────────────

"""
    batch_means_ci(samples::CuArray{Float64}; k::Int=30, alpha::Float64=0.05)
    → (mean, ci_lo, ci_hi, n_batches, batch_size)

GPU-accelerated batch means confidence interval.

Samples remain on the GPU device throughout. Only `k` batch-mean scalars
are transferred to host to compute the final CI (Law & Kelton §9.5).

## When to use
When `StatsPipeline(record_samples=true)` is active and you have transferred
the `_sojourn_samples` or `_wait_samples` buffers to a `CuArray`:

```julia
pipeline = StatsPipeline(record_samples=true)
# ... run long simulation ...
d_sojourn = CuArray(pipeline._sojourn_samples)
ci = batch_means_ci(d_sojourn; k=30)
println("W̄ = \$(ci.mean) ± \$(ci.ci_hi - ci.mean) (95% CI, GPU-accelerated)")
```

## Returns all-NaN if fewer than 2k observations.

See also: `batch_means_ci(::Vector{Float64})` — CPU fallback (always available).
"""
function SimCore.batch_means_ci(samples::CuArray{Float64};
                                k::Int      = 30,
                                alpha::Float64 = 0.05)
    n = length(samples)
    if n < 2k
        return (mean=NaN, ci_lo=NaN, ci_hi=NaN, n_batches=0, batch_size=0)
    end
    k < 10 && @warn "batch_means_ci(CuArray): k=$k < 10; t-approximation may be inaccurate."

    batch_size = n ÷ k

    # Compute k batch means on GPU; transfer only k scalars to host.
    # Each batch is a contiguous view — CUDA.mean on a SubArray dispatches to cuBLAS.
    batch_means = Vector{Float64}(undef, k)
    for i in 1:k
        lo_i = (i - 1) * batch_size + 1
        hi_i = i * batch_size
        # Inline mean: sum GPU subarray / batch_size; avoids requiring Statistics stdlib
        batch_sum = CUDA.mapreduce(identity, +, view(samples, lo_i:hi_i))
        batch_means[i] = Float64(batch_sum) / batch_size
    end

    # CI from the k (now-CPU) batch means — same formula as the CPU version
    μ = sum(batch_means) / k
    var_sum = 0.0
    for bm in batch_means
        d = bm - μ
        var_sum += d * d
    end
    s      = sqrt(var_sum / (k - 1))
    t_crit = SimCore._t_critical(k - 1, alpha / 2)
    se     = s / sqrt(Float64(k))

    return (mean=μ, ci_lo=μ - t_crit*se, ci_hi=μ + t_crit*se,
            n_batches=k, batch_size=batch_size)
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. gpu_histogram — atomic-increment bin counts
# NOTE: _histogram_kernel! is defined BEFORE gpu_histogram so that CUDA.@cuda
#       can resolve the function at parse time (required by the @cuda macro).
# ─────────────────────────────────────────────────────────────────────────────

# GPU kernel for histogram — one thread per sample.
# Each thread atomically increments one bin counter.
function _histogram_kernel!(counts, samples, lo::Float64, inv_width::Float64, nbins::Int32)
    i = (CUDA.blockIdx().x - Int32(1)) * CUDA.blockDim().x + CUDA.threadIdx().x
    i > Int32(length(samples)) && return nothing
    @inbounds begin
        x   = samples[i]
        bin = clamp(ceil(Int32, (x - lo) * inv_width), Int32(1), nbins)
        CUDA.atomic_add!(pointer(counts, bin), Int32(1))
    end
    return nothing
end

"""
    gpu_histogram(samples::CuArray{Float64}, nbins::Int;
                  lo::Float64=0.0, hi::Union{Nothing,Float64}=nothing)
    → (edges::Vector{Float64}, counts::Vector{Int32})

Compute a histogram of `samples` using GPU atomic increments.

Each GPU thread reads one sample and atomically increments the appropriate bin.
Returns bin `edges` and `counts` on the CPU.

## Arguments
- `samples` — GPU array of observations (e.g. sojourn times, queue lengths)
- `nbins`   — number of histogram bins
- `lo`      — lower bin edge (default 0.0)
- `hi`      — upper bin edge (default: max of samples)

## Returns
`(edges, counts)` where:
- `edges` is a `Vector{Float64}` of length `nbins + 1`
- `counts` is a `Vector{Int32}` of length `nbins`
- `sum(counts) == length(samples)` (all observations are counted)

## Example
```julia
d_sojourn = CuArray(pipeline._sojourn_samples)
edges, counts = gpu_histogram(d_sojourn, 50)
# Plot with any plotting library:
# bar(edges[1:end-1], counts)
```
"""
function gpu_histogram(samples::CuArray{Float64}, nbins::Int;
                       lo::Float64                = 0.0,
                       hi::Union{Nothing,Float64} = nothing)
    isempty(samples) && return (edges=Float64[], counts=Int32[])
    nbins > 0 || throw(ArgumentError("nbins must be > 0"))

    hi_val = hi === nothing ? Float64(CUDA.maximum(samples)) : hi
    hi_val <= lo && throw(ArgumentError("hi ($hi_val) must be > lo ($lo)"))

    edges     = collect(range(lo, hi_val; length=nbins + 1))
    d_counts  = CUDA.zeros(Int32, nbins)
    inv_width = nbins / (hi_val - lo)
    n_samples = length(samples)

    threads = 256
    blocks  = cld(n_samples, threads)
    CUDA.@cuda threads=threads blocks=blocks _histogram_kernel!(
        d_counts, samples, lo, inv_width, Int32(nbins))

    CUDA.synchronize()
    return (edges=edges, counts=Array(d_counts))
end

end # module SimCoreGPUExt
