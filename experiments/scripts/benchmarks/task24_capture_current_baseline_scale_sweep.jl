#!/usr/bin/env julia

"""
Task 24 scale-sweep baseline capture for the current setup.

Runs a small multi-scale benchmark for the current headless DES+ABM stack and
its ABM-only / MM1-only baselines to quantify how runtime and queue metrics vary
with workload size.

Run from repo root:
  julia --project=. experiments/scripts/benchmarks/task24_capture_current_baseline_scale_sweep.jl
"""

using Dates
using Statistics
using TOML

using SimCore
using SimViz
using SimCrowd: step!

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

function build_orca_ctx(; n_agents::Int, dt::Float64, seed::Int,
                        with_mm1::Bool, with_alarm::Bool,
                        λ::Float64=0.6, μ::Float64=1.0,
                        alarm_t::Float64=20.0)
    events = SimViz.ScheduledEvent[]

    if with_mm1
        push!(events, SimViz.ScheduledEvent(
            time=0.0,
            type=:start_mm1_queue,
            params=(lambda=λ, mu=μ, warmup_mode=:none, warmup_n=0),
        ))
    end

    if with_alarm
        push!(events, SimViz.ScheduledEvent(
            time=alarm_t,
            type=:evac_alarm,
            params=(v_panic=1.8, panic_level=0.8),
        ))
    end

    cfg = SimViz.ScenarioConfig(
        n_agents=n_agents,
        crowd_model=SimViz.MODEL_ORCA,
        events=events,
        flux_boundary=false,
        dt=dt,
        rng_seed=seed,
    )

    return SimViz.build_world!(cfg)
end

function run_headless_case(; n_agents::Int=80,
                           sim_horizon_s::Float64=120.0,
                           dt::Float64=0.05,
                           seed::Int=2026,
                           with_mm1::Bool,
                           with_alarm::Bool)
    ctx = build_orca_ctx(; n_agents=n_agents, dt=dt, seed=seed,
                         with_mm1=with_mm1, with_alarm=with_alarm)

    n_steps = Int(round(sim_horizon_s / dt))

    timed = @timed begin
        for _ in 1:n_steps
            step!(ctx.scene)
            ctx.sim_time += ctx.config.dt
            SimViz._dispatch_events!(ctx, ctx.sim_time)
        end
        SimViz.serialize_world_ctx(ctx)
    end

    snap = timed.value
    s = snap.stats
    elapsed = timed.time

    steps_per_s = n_steps / elapsed
    sim_seconds_per_wall_second = sim_horizon_s / elapsed

    total_events = Float64(s.total_events)
    des_event_throughput = total_events / elapsed

    littles_law_err = begin
        L_pred = s.throughput * s.W
        if isnan(L_pred) || isnan(s.L) || abs(s.L) < 1e-12
            NaN
        else
            abs(L_pred - s.L) / abs(s.L)
        end
    end

    max_panic = isempty(snap.panic_levels) ? 0.0f0 : maximum(snap.panic_levels)

    return Dict(
        "elapsed_s" => elapsed,
        "alloc_bytes" => Float64(timed.bytes),
        "gc_time_s" => timed.gctime,
        "n_steps" => Float64(n_steps),
        "sim_horizon_s" => sim_horizon_s,
        "steps_per_s" => steps_per_s,
        "sim_seconds_per_wall_second" => sim_seconds_per_wall_second,
        "n_agents" => Float64(n_agents),
        "des_total_events" => total_events,
        "des_total_arrivals" => Float64(s.total_arrivals),
        "des_total_departures" => Float64(s.total_departures),
        "des_event_throughput_events_per_s" => des_event_throughput,
        "W" => Float64(s.W),
        "Wq" => Float64(s.Wq),
        "L" => Float64(s.L),
        "Lq" => Float64(s.Lq),
        "rho" => Float64(s.rho),
        "lambda_eff" => Float64(s.throughput),
        "littles_law_rel_err" => littles_law_err,
        "max_panic" => Float64(max_panic),
    )
end

function repeat_case(f::Function; reps::Int=3)
    runs = [f() for _ in 1:reps]

    metric_keys = [
        "elapsed_s", "alloc_bytes", "gc_time_s", "des_event_throughput_events_per_s",
        "steps_per_s", "sim_seconds_per_wall_second", "littles_law_rel_err",
        "des_total_events", "des_total_arrivals", "des_total_departures",
        "W", "Wq", "L", "Lq", "rho", "lambda_eff", "max_panic",
    ]

    summaries = Dict{String, Any}()
    for k in metric_keys
        vals = Float64[]
        for r in runs
            if haskey(r, k)
                v = Float64(r[k])
                if isfinite(v)
                    push!(vals, v)
                end
            end
        end
        if !isempty(vals)
            summaries[k] = summarize_scalar(vals)
        end
    end

    return Dict(
        "runs" => runs,
        "summary" => summaries,
    )
end

function case_summary(case_name::String, result::Dict)
    summary = result["summary"]
    if !haskey(summary, "elapsed_s")
        return Dict("case" => case_name, "mean_elapsed_s" => NaN)
    end

    return Dict(
        "case" => case_name,
        "mean_elapsed_s" => summary["elapsed_s"]["mean"],
        "mean_alloc_bytes" => get(summary, "alloc_bytes", Dict("mean" => NaN))["mean"],
        "mean_lambda_eff" => get(summary, "lambda_eff", Dict("mean" => NaN))["mean"],
        "mean_max_panic" => get(summary, "max_panic", Dict("mean" => NaN))["mean"],
    )
end

function main()
    timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    out_dir = joinpath(@__DIR__, "..", "..", "data", "benchmarks")
    mkpath(out_dir)

    meta = Dict(
        "captured_at" => string(now()),
        "julia_version" => string(VERSION),
        "threads" => Threads.nthreads(),
        "git_commit" => safe_git_commit(),
        "git_branch" => safe_git_branch(),
        "script" => "experiments/scripts/benchmarks/task24_capture_current_baseline_scale_sweep.jl",
        "intent" => "Task24 current baseline scale sweep for current DES+ABM versus ABM-only and MM1-only",
        "repetitions_per_scale" => 3,
    )

    scale_points = [0, 20, 40, 80, 120, 200]

    # Warmup compilation runs for the path touched by the sweep.
    run_headless_case(with_mm1=true, with_alarm=true, n_agents=80)
    run_headless_case(with_mm1=false, with_alarm=false, n_agents=80)
    run_headless_case(with_mm1=true, with_alarm=false, n_agents=0)

    mm1_only = repeat_case(() -> run_headless_case(
        n_agents=0,
        sim_horizon_s=120.0,
        dt=0.05,
        seed=2026,
        with_mm1=true,
        with_alarm=false,
    ); reps=3)

    current_des_abm = Dict{String, Any}()
    for n in scale_points
        if n == 0
            continue
        end
        current_des_abm[string(n)] = repeat_case(() -> run_headless_case(
            n_agents=n,
            sim_horizon_s=120.0,
            dt=0.05,
            seed=2026,
            with_mm1=true,
            with_alarm=true,
        ); reps=3)
    end

    abm_only = Dict{String, Any}()
    for n in scale_points
        if n == 0
            continue
        end
        abm_only[string(n)] = repeat_case(() -> run_headless_case(
            n_agents=n,
            sim_horizon_s=120.0,
            dt=0.05,
            seed=2026,
            with_mm1=false,
            with_alarm=false,
        ); reps=3)
    end

    payload = Dict(
        "metadata" => meta,
        "scale_points" => scale_points,
        "cases" => Dict(
            "mm1_only_headless" => Dict(
                "n_agents" => 0,
                "result" => mm1_only,
                "summary" => case_summary("mm1_only_headless", mm1_only),
            ),
            "current_des_abm_headless" => Dict(
                "n_agents" => scale_points[2:end],
                "by_scale" => current_des_abm,
                "summary_by_scale" => Dict(k => case_summary("current_des_abm_headless", v) for (k,v) in current_des_abm),
            ),
            "abm_only_headless" => Dict(
                "n_agents" => scale_points[2:end],
                "by_scale" => abm_only,
                "summary_by_scale" => Dict(k => case_summary("abm_only_headless", v) for (k,v) in abm_only),
            ),
        ),
    )

    toml_path = joinpath(out_dir, "task24_current_baseline_scale_sweep_$(timestamp).toml")
    open(toml_path, "w") do io
        TOML.print(io, payload)
    end

    latest_path = joinpath(out_dir, "task24_current_baseline_scale_sweep_latest.toml")
    cp(toml_path, latest_path; force=true)

    println("\nTask 24 scale-sweep baseline captured.")
    println("  -> ", toml_path)
    println("  -> ", latest_path)
    println("\nScale summary: ")
    for n in scale_points[2:end]
        key = string(n)
        des_mean = current_des_abm[key]["summary"]["elapsed_s"]["mean"]
        abm_mean = abm_only[key]["summary"]["elapsed_s"]["mean"]
        ratio = des_mean / abm_mean
        println("  n_agents=$(n): DES+ABM=", round(des_mean, digits=4), "s, ABM-only=", round(abm_mean, digits=4), "s, ratio=", round(ratio, digits=4))
    end
end

main()
