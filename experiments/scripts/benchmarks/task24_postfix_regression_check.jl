#!/usr/bin/env julia

"""
Task 24 / Task 7 compact post-fix benchmark.

Runs a minimal post-fix validation set:
1. ORCA update benchmark on CPU for tiny + moderate scenes
2. ORCA update benchmark on CUDA for tiny + moderate scenes (if available)
3. SimCore reduction timing on CPU arrays and CuArray (if available)

Run from repo root:
  julia --project=. experiments/scripts/benchmarks/task24_postfix_regression_check.jl
"""

using Dates
using Statistics
using TOML
using Random
using StaticArrays
using Ark
using KernelAbstractions
using SimCrowd
using SimCore
using CUDA

safe_git_commit() = try
    readchomp(`git rev-parse --short HEAD`)
catch
    "unknown"
end

safe_git_branch() = try
    readchomp(`git rev-parse --abbrev-ref HEAD`)
catch
    "unknown"
end

function summarize_scalar(v::Vector{Float64})
    n = length(v)
    μ = mean(v)
    σ = n > 1 ? std(v; corrected=true) : 0.0
    return Dict(
        "n" => n,
        "mean" => μ,
        "std" => σ,
        "min" => minimum(v),
        "max" => maximum(v),
    )
end

function repeat_case(f::Function; reps::Int=3)
    runs = [f() for _ in 1:reps]
    metric_keys = String[]
    for run in runs
        append!(metric_keys, collect(keys(run)))
    end
    unique!(metric_keys)

    summaries = Dict{String, Any}()
    for key in metric_keys
        vals = Float64[]
        for run in runs
            if haskey(run, key)
                value = run[key]
                if value isa Real
                    fv = Float64(value)
                    isfinite(fv) && push!(vals, fv)
                end
            end
        end
        isempty(vals) || (summaries[key] = summarize_scalar(vals))
    end

    return Dict("runs" => runs, "summary" => summaries)
end

function make_orca_world(n_agents::Int; F::Type{Float32}=Float32)
    world = World(Position{F}, Velocity{F}, AgentGeometry{F}, MotionParams{F},
                  SFMParams{F}, ORCAParams{F}, Goal{F}, Force{F}, WallSegment{F})

    width = max(F(8), F(0.3) * F(n_agents))
    height = max(F(8), F(0.08) * F(n_agents))

    new_entity!(world, (WallSegment(SVector(F(4), F(0)), SVector(F(4), height)),))
    new_entity!(world, (WallSegment(SVector(F(0), F(0)), SVector(width, F(0))),))
    new_entity!(world, (WallSegment(SVector(width, F(0)), SVector(width, height)),))

    cols = max(1, ceil(Int, sqrt(n_agents)))
    rows = ceil(Int, n_agents / cols)
    spacing_x = F(0.55)
    spacing_y = F(0.55)
    origin_x = F(0.8)
    origin_y = F(0.8)
    shared = from_agent_params(F(0.2), F(80), F(1.4), F(0.5), F(0.5), F(0.0))

    for idx in 1:n_agents
        row = (idx - 1) ÷ cols
        col = (idx - 1) % cols
        pos = SVector(origin_x + spacing_x * F(col), origin_y + spacing_y * F(row))
        goal = SVector(min(width - F(0.75), pos[1] + F(2.5)), min(height - F(0.75), pos[2] + F(3.0)))
        params = ORCAParams(F(2.0), F(0.5), 10, F(8.0), F(0.2), F(1.4), F(0.5), F(80.0))
        new_entity!(world, (
            Position(pos),
            Velocity(zero(SVector{2,F})),
            shared...,
            params,
            Goal(goal),
            Force(zero(SVector{2,F}))
        ))
    end

    grid_max = SVector(width + F(1), height + F(1))
    return world, grid_max
end

function make_orca_search(backend, n_agents::Int, grid_max)
    return RadixSpatialHash(backend, n_agents, SVector(0.0f0, 0.0f0), grid_max, 1.0f0)
end

function benchmark_orca_case(backend, n_agents::Int; dt::Float32=0.01f0, steps::Int=20)
    world, grid_max = make_orca_world(n_agents)
    search = make_orca_search(backend, n_agents, grid_max)

    SimCrowd.update_orca_system!(world, search, backend, dt)
    is_gpu_backend(backend) && CUDA.synchronize()

    timed = @timed begin
        lp3_total = 0
        for _ in 1:steps
            lp3_total += SimCrowd.update_orca_system!(world, search, backend, dt)
        end
        is_gpu_backend(backend) && CUDA.synchronize()
        lp3_total
    end

    return Dict(
        "elapsed_s" => timed.time,
        "alloc_bytes" => Float64(timed.bytes),
        "gc_time_s" => timed.gctime,
        "n_agents" => Float64(n_agents),
        "steps" => Float64(steps),
        "steps_per_s" => steps / timed.time,
        "us_per_step" => 1.0e6 * timed.time / steps,
        "lp3_total" => Float64(timed.value),
    )
end

function benchmark_reduction_cpu(; n_samples::Int=200_000, nbins::Int=32)
    rng = MersenneTwister(20260915)
    data = randn(rng, Float64, n_samples) .+ 3.0

    gpu_mean_var(data)
    gpu_histogram(data, nbins; lo=-2.0, hi=8.0)

    timed = @timed begin
        μ, var = gpu_mean_var(data)
        edges, counts = gpu_histogram(data, nbins; lo=-2.0, hi=8.0)
        (μ=μ, var=var, counts_sum=sum(counts), edge_hi=last(edges))
    end

    return Dict(
        "elapsed_s" => timed.time,
        "alloc_bytes" => Float64(timed.bytes),
        "gc_time_s" => timed.gctime,
        "n_samples" => Float64(n_samples),
        "nbins" => Float64(nbins),
        "mean" => timed.value.μ,
        "variance" => timed.value.var,
        "counts_sum" => Float64(timed.value.counts_sum),
        "edge_hi" => Float64(timed.value.edge_hi),
    )
end

function benchmark_reduction_cuda(; n_samples::Int=200_000, nbins::Int=32)
    data = CUDA.CuArray(randn(MersenneTwister(20260915), Float64, n_samples) .+ 3.0)

    gpu_mean_var(data)
    gpu_histogram(data, nbins; lo=-2.0, hi=8.0)
    CUDA.synchronize()

    timed = @timed begin
        μ, var = gpu_mean_var(data)
        edges, counts = gpu_histogram(data, nbins; lo=-2.0, hi=8.0)
        CUDA.synchronize()
        (μ=μ, var=var, counts_sum=sum(counts), edge_hi=last(edges))
    end

    return Dict(
        "elapsed_s" => timed.time,
        "alloc_bytes" => Float64(timed.bytes),
        "gc_time_s" => timed.gctime,
        "n_samples" => Float64(n_samples),
        "nbins" => Float64(nbins),
        "mean" => timed.value.μ,
        "variance" => timed.value.var,
        "counts_sum" => Float64(timed.value.counts_sum),
        "edge_hi" => Float64(timed.value.edge_hi),
    )
end

function assess_results(cases::Dict{String,Any}, cuda_ok::Bool)
    cpu_tiny = cases["orca_cpu_n10"]["summary"]["us_per_step"]["mean"]
    cpu_mid = cases["orca_cpu_n500"]["summary"]["us_per_step"]["mean"]
    reductions_cpu = cases["reductions_cpu"]["summary"]["elapsed_s"]["mean"]

    assessment = Dict{String,Any}(
        "cpu_path_viable" => (cpu_tiny > 0.0 && cpu_mid > cpu_tiny),
        "cpu_reductions_viable" => reductions_cpu > 0.0,
    )

    if cuda_ok && haskey(cases, "orca_cuda_n10") && haskey(cases, "orca_cuda_n500") && haskey(cases, "reductions_cuda")
        cuda_tiny = cases["orca_cuda_n10"]["summary"]["us_per_step"]["mean"]
        cuda_mid = cases["orca_cuda_n500"]["summary"]["us_per_step"]["mean"]
        reductions_cuda = cases["reductions_cuda"]["summary"]["elapsed_s"]["mean"]
        assessment["cuda_path_viable"] = (cuda_tiny > 0.0 && cuda_mid > 0.0)
        assessment["cuda_reductions_viable"] = reductions_cuda > 0.0
        assessment["cuda_tiny_vs_cpu_ratio"] = cuda_tiny / cpu_tiny
        assessment["cuda_moderate_vs_cpu_ratio"] = cuda_mid / cpu_mid
        assessment["reduction_cuda_vs_cpu_ratio"] = reductions_cuda / reductions_cpu
    else
        assessment["cuda_path_viable"] = false
        assessment["cuda_reductions_viable"] = false
    end

    return assessment
end

function main()
    timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    out_dir = joinpath(@__DIR__, "..", "..", "data", "benchmarks")
    mkpath(out_dir)

    cuda_ok = CUDA.functional()

    meta = Dict(
        "captured_at" => string(now()),
        "julia_version" => string(VERSION),
        "threads" => Threads.nthreads(),
        "git_commit" => safe_git_commit(),
        "git_branch" => safe_git_branch(),
        "script" => "experiments/scripts/benchmarks/task24_postfix_regression_check.jl",
        "intent" => "Task7 compact post-fix performance and regression posture validation",
        "cuda_functional" => cuda_ok,
    )

    benchmark_orca_case(CPU(), 10; steps=2)
    benchmark_orca_case(CPU(), 500; steps=2)
    benchmark_reduction_cpu(; n_samples=20_000, nbins=16)
    if cuda_ok
        CUDA.allowscalar(false)
        benchmark_orca_case(CUDA.CUDABackend(), 10; steps=2)
        benchmark_orca_case(CUDA.CUDABackend(), 500; steps=2)
        benchmark_reduction_cuda(; n_samples=20_000, nbins=16)
    end

    cases = Dict{String,Any}()
    cases["orca_cpu_n10"] = repeat_case(() -> benchmark_orca_case(CPU(), 10; steps=20); reps=3)
    cases["orca_cpu_n500"] = repeat_case(() -> benchmark_orca_case(CPU(), 500; steps=10); reps=3)
    cases["reductions_cpu"] = repeat_case(() -> benchmark_reduction_cpu(); reps=3)

    if cuda_ok
        cases["orca_cuda_n10"] = repeat_case(() -> benchmark_orca_case(CUDA.CUDABackend(), 10; steps=20); reps=3)
        cases["orca_cuda_n500"] = repeat_case(() -> benchmark_orca_case(CUDA.CUDABackend(), 500; steps=10); reps=3)
        cases["reductions_cuda"] = repeat_case(() -> benchmark_reduction_cuda(); reps=3)
    end

    payload = Dict(
        "metadata" => meta,
        "cases" => cases,
        "assessment" => assess_results(cases, cuda_ok),
    )

    run_path = joinpath(out_dir, "task24_postfix_regression_check_$(timestamp).toml")
    latest_path = joinpath(out_dir, "task24_postfix_regression_check_latest.toml")

    open(run_path, "w") do io
        TOML.print(io, payload)
    end
    cp(run_path, latest_path; force=true)

    println("\nTask 7 compact post-fix benchmark captured.")
    println("  -> ", run_path)
    println("  -> ", latest_path)
    println("\nKey means:")
    println("  orca_cpu_n10 us/step = ", round(cases["orca_cpu_n10"]["summary"]["us_per_step"]["mean"], digits=2))
    println("  orca_cpu_n500 us/step = ", round(cases["orca_cpu_n500"]["summary"]["us_per_step"]["mean"], digits=2))
    println("  reductions_cpu elapsed_s = ", round(cases["reductions_cpu"]["summary"]["elapsed_s"]["mean"], digits=6))
    if cuda_ok
        println("  orca_cuda_n10 us/step = ", round(cases["orca_cuda_n10"]["summary"]["us_per_step"]["mean"], digits=2))
        println("  orca_cuda_n500 us/step = ", round(cases["orca_cuda_n500"]["summary"]["us_per_step"]["mean"], digits=2))
        println("  reductions_cuda elapsed_s = ", round(cases["reductions_cuda"]["summary"]["elapsed_s"]["mean"], digits=6))
    else
        println("  CUDA cases skipped: no functional CUDA device.")
    end
end

main()
