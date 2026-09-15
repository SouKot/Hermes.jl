#!/usr/bin/env julia

"""
Task 24 — Coupled Dual-Gate Concourse Evacuation benchmark (HybridFSM-first).

What this benchmark adds beyond the current baseline:
- HybridFSM crowd model by default (ORCA↔SFM switching under density)
- Two DES-like service gates with explicit queues and service completions
- ABM→DES coupling: agents reaching gate capture zones join gate queues
- DES→ABM coupling: queue load affects gate routing decisions at sync cadence
- Wave-based releases (not all agents active at t=0)
- Constant-density mode (optional): room scales with sqrt(N)
- Matrix runner with progress, checkpointing, and resume (cancel-safe)

Examples:
  julia --threads 16 --project=. experiments/scripts/benchmarks/task24_dual_gate_hybrid_benchmark_matrix.jl --tier tier1
  julia --threads 16 --project=. experiments/scripts/benchmarks/task24_dual_gate_hybrid_benchmark_matrix.jl --tier tier1 --resume true
  julia --threads 16 --project=. experiments/scripts/benchmarks/task24_dual_gate_hybrid_benchmark_matrix.jl \
      --n-agents 500,2000 --utilizations 0.6,0.8 --sync-cadences 1,10,50 --reps 3 --horizon 120
"""

using Dates
using Statistics
using TOML
using Random: MersenneTwister, randexp, shuffle!
using Logging
using LinearAlgebra: norm
using StaticArrays: SVector

using Ark: Query
using SimCore
using SimViz
using SimCrowd: step!, Position, Goal, MotionParams

const TIER1_MATRIX = Dict(
    "n_agents" => [500, 2000, 10000],
    "utilizations" => [0.6, 0.8],
    "sync_cadences" => [1, 10, 50],
    "reps" => 3,
    "horizon_s" => 120.0,
)

const TIER2_MATRIX = Dict(
    "n_agents" => [500, 2000, 10000, 20000],
    "utilizations" => [0.3, 0.6, 0.8, 0.9],
    "sync_cadences" => [1, 10, 50],
    "reps" => 5,
    "horizon_s" => 120.0,
)

const FULL_MATRIX = Dict(
    "n_agents" => [200, 500, 1000, 2000, 5000, 10000, 20000],
    "utilizations" => [0.3, 0.6, 0.8, 0.9],
    "sync_cadences" => [1, 5, 10, 20, 50, 100],
    "reps" => 5,
    "horizon_s" => 120.0,
)

safe_git_commit() = try
    cd(joinpath(@__DIR__, "..", "..", "..")) do
        readchomp(pipeline(`git rev-parse --short HEAD`; stderr=devnull))
    end
catch
    "unknown"
end

safe_git_branch() = try
    cd(joinpath(@__DIR__, "..", "..", "..")) do
        readchomp(pipeline(`git rev-parse --abbrev-ref HEAD`; stderr=devnull))
    end
catch
    "unknown"
end

parse_bool(s::String) = lowercase(strip(s)) in ("1", "true", "yes", "y", "on")

function parse_csv_ints(s::String)
    isempty(s) && return Int[]
    parse.(Int, split(s, ","))
end

function parse_csv_floats(s::String)
    isempty(s) && return Float64[]
    parse.(Float64, split(s, ","))
end

function summarize_scalar(v::Vector{Float64})
    n = length(v)
    μ = mean(v)
    σ = n > 1 ? std(v; corrected=true) : 0.0
    med = median(v)
    q25 = quantile(v, 0.25)
    q75 = quantile(v, 0.75)
    return Dict(
        "n" => n,
        "mean" => μ,
        "std" => σ,
        "median" => med,
        "q25" => q25,
        "q75" => q75,
        "min" => minimum(v),
        "max" => maximum(v),
    )
end

@inline function room_scale_for_density_mode(n_agents::Int, n_ref::Int, density_mode::String)
    if density_mode == "constant"
        return sqrt(Float64(n_agents) / max(1.0, Float64(n_ref)))
    end
    return 1.0
end

function build_dual_gate_ctx(; n_agents::Int,
                             dt::Float64,
                             seed::Int,
                             density_mode::String,
                             n_ref::Int,
                             base_room_w::Float64,
                             base_room_h::Float64,
                             base_v_pref::Float64)
    sc = room_scale_for_density_mode(n_agents, n_ref, density_mode)
    room_w = base_room_w * sc
    room_h = base_room_h * sc

    room = SimViz.RoomGeometry(
        width=room_w,
        height=room_h,
        doors=[
            SimViz.DoorSpec(wall=:east, center=0.35, width=2.0),
            SimViz.DoorSpec(wall=:east, center=0.65, width=2.0),
        ],
    )

    cfg = SimViz.ScenarioConfig(
        room=room,
        n_agents=n_agents,
        crowd_model=SimViz.MODEL_HYBRID_FSM,
        v_pref=base_v_pref,
        dt=dt,
        flux_boundary=false,
        rng_seed=seed,
        events=SimViz.ScheduledEvent[],
        label="Task24 Dual-Gate HybridFSM",
        description="Dual-gate concourse benchmark with explicit gate queues and wave release",
    )

    return SimViz.build_world!(cfg)
end

function set_agent_motion_goal!(ctx, entity_updates::Dict)
    F = Float32
    for (entities, pos_col, goal_col, motion_col) in Query(ctx.ark_world, (Position{F}, Goal{F}, MotionParams{F}))
        for i in eachindex(entities)
            eid = entities[i]
            haskey(entity_updates, eid) || continue
            upd = entity_updates[eid]
            goal_col[i] = Goal{F}(upd[:goal])
            old = motion_col[i]
            motion_col[i] = MotionParams{F}(old.mass, upd[:v_pref], old.τ, old.σ)
        end
    end
end

function run_coupled_dual_gate_case(; n_agents::Int,
                                    utilization::Float64,
                                    sync_cadence_ratio::Int,
                                    sim_horizon_s::Float64,
                                    dt::Float64,
                                    seed::Int,
                                    wave_count::Int,
                                    wave_interval_s::Float64,
                                    density_mode::String,
                                    n_ref::Int,
                                    base_room_w::Float64,
                                    base_room_h::Float64,
                                    base_v_pref::Float64,
                                    service_mu_base::Float64,
                                    capture_radius::Float64,
                                    reroute_hysteresis::Int,
                                    quiet::Bool=true)

    F = Float32

    runner = () -> begin
        ctx = build_dual_gate_ctx(
            n_agents=n_agents,
            dt=dt,
            seed=seed,
            density_mode=density_mode,
            n_ref=n_ref,
            base_room_w=base_room_w,
            base_room_h=base_room_h,
            base_v_pref=base_v_pref,
        )

        W = Float32(ctx.config.room.width)
        H = Float32(ctx.config.room.height)

        gate_points = (
            SVector{2,F}(0.45f0 * W, 0.35f0 * H),
            SVector{2,F}(0.45f0 * W, 0.65f0 * H),
        )
        exit_points = (
            SVector{2,F}(W + 0.5f0, 0.35f0 * H),
            SVector{2,F}(W + 0.5f0, 0.65f0 * H),
        )

        # utilization knob => service speed proxy
        # higher utilization => lower mu => more queueing pressure
        util_safe = max(0.05, utilization)
        mu_gate = Float64(service_mu_base) * (0.60 / util_safe)
        mu_gate = max(mu_gate, 0.05)

        # gather entities once and assign waves
        entities_all = Any[]
        for (entities, _, _, _) in Query(ctx.ark_world, (Position{F}, Goal{F}, MotionParams{F}))
            append!(entities_all, entities)
        end

        rng = MersenneTwister(seed + 404)
        shuffle!(rng, entities_all)

        waves = max(1, wave_count)
        wave_of = Dict{Any,Int}()
        for (idx, e) in enumerate(entities_all)
            w = min(waves, 1 + Int(floor((idx - 1) * waves / max(1, n_agents))))
            wave_of[e] = w
        end

        wave_released = falses(waves)
        wave_release_time = [(w - 1) * wave_interval_s for w in 1:waves]

        status = Dict{Any,Symbol}()               # :waiting_release | :walking | :queued | :serving | :post_service | :exited
        gate_pref = Dict{Any,Int}()               # preferred gate index
        gate_service = Dict{Any,Int}()            # gate used for service
        arrival_t = Dict{Any,Float64}()           # when entered queue system
        queue_enter_t = Dict{Any,Float64}()       # queue entry time
        wait_samples = Float64[]
        sojourn_samples = Float64[]

        for e in entities_all
            w = wave_of[e]
            status[e] = (w == 1) ? :walking : :waiting_release
            gate_pref[e] = (rand(rng) < 0.5) ? 1 : 2
        end

        # freeze unreleased waves at t=0
        updates = Dict{Any,Dict{Symbol,Any}}()
        for (entities, pos_col, _, _) in Query(ctx.ark_world, (Position{F}, Goal{F}, MotionParams{F}))
            for i in eachindex(entities)
                e = entities[i]
                if status[e] == :waiting_release
                    p = pos_col[i].p
                    updates[e] = Dict(:goal => p, :v_pref => 0.0f0)
                end
            end
        end
        set_agent_motion_goal!(ctx, updates)

        gate_queues = (Any[], Any[])
        gate_serving = Any[nothing, nothing]
        gate_busy_until = [-1.0, -1.0]
        gate_busy = [false, false]
        gate_departures = [0, 0]
        gate_arrivals = [0, 0]

        reroutes = 0
        entered_queue = 0
        exited_count = 0

        area_L = 0.0
        area_Lq = 0.0
        busy_time_total = 0.0

        n_steps = Int(round(sim_horizon_s / dt))
        sync_every = max(1, sync_cadence_ratio)
        capture_r = Float32(capture_radius)
        exit_r = 0.75f0

        t_prev = 0.0

        timed = @timed begin
            for step_idx in 1:n_steps
                t_now = step_idx * dt

                # release wave(s)
                for w in 1:waves
                    if !wave_released[w] && t_now >= wave_release_time[w]
                        wave_released[w] = true
                        rel_updates = Dict{Any,Dict{Symbol,Any}}()
                        for (entities, pos_col, _, _) in Query(ctx.ark_world, (Position{F}, Goal{F}, MotionParams{F}))
                            for i in eachindex(entities)
                                e = entities[i]
                                if wave_of[e] == w && status[e] == :waiting_release
                                    status[e] = :walking
                                    g = gate_pref[e]
                                    rel_updates[e] = Dict(:goal => gate_points[g], :v_pref => Float32(base_v_pref))
                                end
                            end
                        end
                        set_agent_motion_goal!(ctx, rel_updates)
                    end
                end

                # sync-cadence routing decision (DES→ABM)
                if step_idx % sync_every == 0
                    load1 = length(gate_queues[1]) + (gate_busy[1] ? 1 : 0)
                    load2 = length(gate_queues[2]) + (gate_busy[2] ? 1 : 0)
                    route_updates = Dict{Any,Dict{Symbol,Any}}()

                    for (entities, pos_col, goal_col, motion_col) in Query(ctx.ark_world, (Position{F}, Goal{F}, MotionParams{F}))
                        for i in eachindex(entities)
                            e = entities[i]
                            st = get(status, e, :walking)
                            st == :walking || continue

                            old_g = gate_pref[e]
                            new_g = old_g
                            if load1 + reroute_hysteresis < load2
                                new_g = 1
                            elseif load2 + reroute_hysteresis < load1
                                new_g = 2
                            end

                            if new_g != old_g
                                gate_pref[e] = new_g
                                reroutes += 1
                            end

                            route_updates[e] = Dict(:goal => gate_points[gate_pref[e]], :v_pref => motion_col[i].v_pref)
                        end
                    end

                    set_agent_motion_goal!(ctx, route_updates)
                end

                # ABM step
                step!(ctx.scene)
                ctx.sim_time += ctx.config.dt

                # ABM→DES queue entry + freeze queued/serving agents
                motion_updates = Dict{Any,Dict{Symbol,Any}}()
                for (entities, pos_col, goal_col, motion_col) in Query(ctx.ark_world, (Position{F}, Goal{F}, MotionParams{F}))
                    for i in eachindex(entities)
                        e = entities[i]
                        st = get(status, e, :walking)
                        pos = pos_col[i].p

                        if st == :walking
                            g = gate_pref[e]
                            if norm(pos - gate_points[g]) <= capture_r
                                status[e] = :queued
                                gate_arrivals[g] += 1
                                entered_queue += 1
                                arrival_t[e] = t_now
                                queue_enter_t[e] = t_now
                                push!(gate_queues[g], e)
                                motion_updates[e] = Dict(:goal => pos, :v_pref => 0.0f0)
                            end
                        elseif st == :queued || st == :serving
                            motion_updates[e] = Dict(:goal => pos, :v_pref => 0.0f0)
                        elseif st == :post_service
                            g = get(gate_service, e, gate_pref[e])
                            motion_updates[e] = Dict(:goal => exit_points[g], :v_pref => Float32(base_v_pref))
                            if norm(pos - exit_points[g]) <= exit_r
                                status[e] = :exited
                                exited_count += 1
                            end
                        end
                    end
                end
                isempty(motion_updates) || set_agent_motion_goal!(ctx, motion_updates)

                # Process gate service completions
                for g in 1:2
                    if gate_busy[g] && t_now >= gate_busy_until[g]
                        e = gate_serving[g]
                        gate_busy[g] = false
                        gate_serving[g] = nothing
                        gate_departures[g] += 1
                        status[e] = :post_service
                        gate_service[e] = g

                        wq = t_now - get(queue_enter_t, e, t_now)
                        ws = t_now - get(arrival_t, e, t_now)
                        push!(wait_samples, wq)
                        push!(sojourn_samples, ws)
                    end
                end

                # Start service if idle and queue non-empty
                for g in 1:2
                    if !gate_busy[g] && !isempty(gate_queues[g])
                        e = popfirst!(gate_queues[g])
                        status[e] = :serving
                        gate_serving[g] = e
                        gate_busy[g] = true
                        svc = randexp(rng) / mu_gate
                        gate_busy_until[g] = t_now + svc
                    end
                end

                # Time-weighted queue/system statistics
                q1 = length(gate_queues[1])
                q2 = length(gate_queues[2])
                b1 = gate_busy[1] ? 1 : 0
                b2 = gate_busy[2] ? 1 : 0
                dt_seg = t_now - t_prev
                area_L += (q1 + q2 + b1 + b2) * dt_seg
                area_Lq += (q1 + q2) * dt_seg
                busy_time_total += (b1 + b2) * dt_seg
                t_prev = t_now
            end

            SimViz.serialize_world_ctx(ctx)
        end

        elapsed = timed.time

        dep_total = gate_departures[1] + gate_departures[2]
        λ_eff = dep_total / max(sim_horizon_s, eps())
        Wq = isempty(wait_samples) ? NaN : mean(wait_samples)
        Ws = isempty(sojourn_samples) ? NaN : mean(sojourn_samples)
        L = area_L / max(sim_horizon_s, eps())
        Lq = area_Lq / max(sim_horizon_s, eps())
        rho = busy_time_total / max(2.0 * sim_horizon_s, eps())

        little_err = begin
            pred = λ_eff * Ws
            if isnan(pred) || isnan(L) || abs(L) < 1e-12
                NaN
            else
                abs(pred - L) / abs(L)
            end
        end

        imbalance = abs(gate_departures[1] - gate_departures[2]) / max(1.0, dep_total)

        return Dict(
            "elapsed_s" => elapsed,
            "alloc_bytes" => Float64(timed.bytes),
            "gc_time_s" => timed.gctime,
            "n_steps" => Float64(n_steps),
            "sim_horizon_s" => sim_horizon_s,
            "steps_per_s" => n_steps / elapsed,
            "sim_seconds_per_wall_second" => sim_horizon_s / elapsed,
            "n_agents" => Float64(n_agents),
            "density_mode" => density_mode,
            "room_width_m" => Float64(ctx.config.room.width),
            "room_height_m" => Float64(ctx.config.room.height),
            "room_area_m2" => Float64(ctx.config.room.width * ctx.config.room.height),
            "utilization_knob" => utilization,
            "sync_cadence_ratio" => Float64(sync_cadence_ratio),
            "wave_count" => Float64(wave_count),
            "wave_interval_s" => wave_interval_s,
            "service_mu_per_gate" => mu_gate,
            "gate_arrivals_total" => Float64(gate_arrivals[1] + gate_arrivals[2]),
            "gate_departures_total" => Float64(dep_total),
            "gate1_departures" => Float64(gate_departures[1]),
            "gate2_departures" => Float64(gate_departures[2]),
            "gate_load_imbalance" => imbalance,
            "reroute_count" => Float64(reroutes),
            "entered_queue_count" => Float64(entered_queue),
            "exited_count" => Float64(exited_count),
            "W" => Ws,
            "Wq" => Wq,
            "L" => L,
            "Lq" => Lq,
            "rho" => rho,
            "lambda_eff" => λ_eff,
            "littles_law_rel_err" => little_err,
        )
    end

    if quiet
        return with_logger(NullLogger()) do
            runner()
        end
    else
        return runner()
    end
end

function repeat_case(f::Function; reps::Int=3, threaded_reps::Bool=false)
    runs = Vector{Any}(undef, reps)

    if threaded_reps && Threads.nthreads() > 1 && reps > 1
        Threads.@threads for i in 1:reps
            runs[i] = f(i)
        end
    else
        for i in 1:reps
            runs[i] = f(i)
        end
    end

    metric_keys = [
        "elapsed_s", "alloc_bytes", "gc_time_s", "steps_per_s", "sim_seconds_per_wall_second",
        "room_area_m2", "service_mu_per_gate", "gate_arrivals_total", "gate_departures_total",
        "gate_load_imbalance", "reroute_count", "entered_queue_count", "exited_count",
        "W", "Wq", "L", "Lq", "rho", "lambda_eff", "littles_law_rel_err",
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

    Dict("runs" => runs, "summary" => summaries)
end

function case_summary(result::Dict)
    summary = result["summary"]
    if !haskey(summary, "elapsed_s")
        return Dict("mean_elapsed_s" => NaN)
    end

    Dict(
        "mean_elapsed_s" => summary["elapsed_s"]["mean"],
        "median_elapsed_s" => summary["elapsed_s"]["median"],
        "mean_alloc_bytes" => get(summary, "alloc_bytes", Dict("mean" => NaN))["mean"],
        "mean_reroute_count" => get(summary, "reroute_count", Dict("mean" => NaN))["mean"],
        "mean_gate_departures" => get(summary, "gate_departures_total", Dict("mean" => NaN))["mean"],
        "mean_little_err" => get(summary, "littles_law_rel_err", Dict("mean" => NaN))["mean"],
    )
end

function matrix_signature(cfg)
    join([
        "n=" * join(cfg["n_agents"], ","),
        "u=" * join(string.(cfg["utilizations"]), ","),
        "s=" * join(cfg["sync_cadences"], ","),
        "r=" * string(cfg["reps"]),
        "h=" * string(cfg["horizon_s"]),
        "dt=" * string(cfg["dt"]),
        "wm=" * string(cfg["wave_count"]),
        "wi=" * string(cfg["wave_interval_s"]),
        "dm=" * string(cfg["density_mode"]),
    ], "|")
end

function parse_cli_args(argv)
    tier = "custom"
    n_agents = Int[]
    utilizations = Float64[]
    sync_cadences = Int[]
    reps = 3
    horizon_s = 120.0
    dt = 0.05
    seed = 2026
    resume = true
    threaded_reps = true

    wave_count = 4
    wave_interval_s = 20.0
    density_mode = "constant"   # constant | fixed
    n_ref = 500
    base_room_w = 20.0
    base_room_h = 10.0
    base_v_pref = 1.34
    service_mu_base = 1.2
    capture_radius = 0.85
    reroute_hysteresis = 1

    custom_matrix = false

    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--tier"
            tier = lowercase(argv[i + 1]); i += 2
        elseif a == "--n-agents"
            n_agents = parse_csv_ints(argv[i + 1]); custom_matrix = true; i += 2
        elseif a == "--utilizations"
            utilizations = parse_csv_floats(argv[i + 1]); custom_matrix = true; i += 2
        elseif a == "--sync-cadences"
            sync_cadences = parse_csv_ints(argv[i + 1]); custom_matrix = true; i += 2
        elseif a == "--reps"
            reps = parse(Int, argv[i + 1]); i += 2
        elseif a == "--horizon"
            horizon_s = parse(Float64, argv[i + 1]); i += 2
        elseif a == "--dt"
            dt = parse(Float64, argv[i + 1]); i += 2
        elseif a == "--seed"
            seed = parse(Int, argv[i + 1]); i += 2
        elseif a == "--resume"
            resume = parse_bool(argv[i + 1]); i += 2
        elseif a == "--threaded-reps"
            threaded_reps = parse_bool(argv[i + 1]); i += 2
        elseif a == "--wave-count"
            wave_count = parse(Int, argv[i + 1]); i += 2
        elseif a == "--wave-interval"
            wave_interval_s = parse(Float64, argv[i + 1]); i += 2
        elseif a == "--density-mode"
            density_mode = lowercase(argv[i + 1]); i += 2
        elseif a == "--n-ref"
            n_ref = parse(Int, argv[i + 1]); i += 2
        elseif a == "--base-room-w"
            base_room_w = parse(Float64, argv[i + 1]); i += 2
        elseif a == "--base-room-h"
            base_room_h = parse(Float64, argv[i + 1]); i += 2
        elseif a == "--base-vpref"
            base_v_pref = parse(Float64, argv[i + 1]); i += 2
        elseif a == "--service-mu-base"
            service_mu_base = parse(Float64, argv[i + 1]); i += 2
        elseif a == "--capture-radius"
            capture_radius = parse(Float64, argv[i + 1]); i += 2
        elseif a == "--reroute-hysteresis"
            reroute_hysteresis = parse(Int, argv[i + 1]); i += 2
        else
            i += 1
        end
    end

    if tier == "tier1"
        n_agents = TIER1_MATRIX["n_agents"]
        utilizations = TIER1_MATRIX["utilizations"]
        sync_cadences = TIER1_MATRIX["sync_cadences"]
        reps = TIER1_MATRIX["reps"]
        horizon_s = TIER1_MATRIX["horizon_s"]
    elseif tier == "tier2"
        n_agents = TIER2_MATRIX["n_agents"]
        utilizations = TIER2_MATRIX["utilizations"]
        sync_cadences = TIER2_MATRIX["sync_cadences"]
        reps = TIER2_MATRIX["reps"]
        horizon_s = TIER2_MATRIX["horizon_s"]
    elseif tier == "full"
        n_agents = FULL_MATRIX["n_agents"]
        utilizations = FULL_MATRIX["utilizations"]
        sync_cadences = FULL_MATRIX["sync_cadences"]
        reps = FULL_MATRIX["reps"]
        horizon_s = FULL_MATRIX["horizon_s"]
    elseif custom_matrix
        isempty(n_agents) && (n_agents = [500])
        isempty(utilizations) && (utilizations = [0.6])
        isempty(sync_cadences) && (sync_cadences = [10])
    else
        tier = "tier1"
        n_agents = TIER1_MATRIX["n_agents"]
        utilizations = TIER1_MATRIX["utilizations"]
        sync_cadences = TIER1_MATRIX["sync_cadences"]
        reps = TIER1_MATRIX["reps"]
        horizon_s = TIER1_MATRIX["horizon_s"]
    end

    return Dict(
        "tier" => tier,
        "n_agents" => n_agents,
        "utilizations" => utilizations,
        "sync_cadences" => sync_cadences,
        "reps" => reps,
        "horizon_s" => horizon_s,
        "dt" => dt,
        "seed" => seed,
        "resume" => resume,
        "threaded_reps" => threaded_reps,
        "wave_count" => wave_count,
        "wave_interval_s" => wave_interval_s,
        "density_mode" => density_mode,
        "n_ref" => n_ref,
        "base_room_w" => base_room_w,
        "base_room_h" => base_room_h,
        "base_v_pref" => base_v_pref,
        "service_mu_base" => service_mu_base,
        "capture_radius" => capture_radius,
        "reroute_hysteresis" => reroute_hysteresis,
    )
end

function build_setting_list(cfg)
    settings = NamedTuple[]
    for n in cfg["n_agents"]
        for u in cfg["utilizations"]
            for s in cfg["sync_cadences"]
                key = "n$(n)_u$(u)_sync$(s)"
                push!(settings, (key=key, n_agents=n, utilization=u, sync=s))
            end
        end
    end
    settings
end

function persist_payload(payload::AbstractDict, run_path::String, latest_path::String)
    open(run_path, "w") do io
        TOML.print(io, payload)
    end
    cp(run_path, latest_path; force=true)
end

function load_resume_payload(latest_path::String, cfg)
    isfile(latest_path) || return nothing
    prior = TOML.parsefile(latest_path)
    if !haskey(prior, "metadata") || !haskey(prior["metadata"], "matrix_signature")
        return nothing
    end
    String(prior["metadata"]["matrix_signature"]) == matrix_signature(cfg) || return nothing
    return Dict{String, Any}(prior)
end

function run_parameter_set(cfg, st)
    res = repeat_case(i -> run_coupled_dual_gate_case(
        n_agents=st.n_agents,
        utilization=st.utilization,
        sync_cadence_ratio=st.sync,
        sim_horizon_s=cfg["horizon_s"],
        dt=cfg["dt"],
        seed=cfg["seed"] + i - 1,
        wave_count=cfg["wave_count"],
        wave_interval_s=cfg["wave_interval_s"],
        density_mode=cfg["density_mode"],
        n_ref=cfg["n_ref"],
        base_room_w=cfg["base_room_w"],
        base_room_h=cfg["base_room_h"],
        base_v_pref=cfg["base_v_pref"],
        service_mu_base=cfg["service_mu_base"],
        capture_radius=cfg["capture_radius"],
        reroute_hysteresis=cfg["reroute_hysteresis"],
    ); reps=cfg["reps"], threaded_reps=cfg["threaded_reps"])

    return Dict(
        "n_agents" => st.n_agents,
        "utilization" => st.utilization,
        "sync_cadence_ratio" => st.sync,
        "result" => res,
        "summary" => case_summary(res),
    )
end

function run_benchmark_matrix(cfg)
    timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    out_dir = joinpath(@__DIR__, "..", "..", "data", "benchmarks")
    mkpath(out_dir)

    run_path = joinpath(out_dir, "task24_dual_gate_hybrid_benchmark_matrix_$(cfg["tier"])_$(timestamp).toml")
    latest_path = joinpath(out_dir, "task24_dual_gate_hybrid_benchmark_matrix_$(cfg["tier"])_latest.toml")

    payload = Dict{String, Any}()
    resumed = false

    if cfg["resume"]
        prior = load_resume_payload(latest_path, cfg)
        if prior !== nothing
            payload = prior
            resumed = true
            println("Resuming from latest checkpoint: ", latest_path)
        end
    end

    if isempty(payload)
        payload = Dict(
            "metadata" => Dict(
                "captured_at" => string(now()),
                "julia_version" => string(VERSION),
                "threads" => Threads.nthreads(),
                "git_commit" => safe_git_commit(),
                "git_branch" => safe_git_branch(),
                "script" => "experiments/scripts/benchmarks/task24_dual_gate_hybrid_benchmark_matrix.jl",
                "tier" => cfg["tier"],
                "intent" => "Task24 Coupled Dual-Gate Concourse Evacuation benchmark (HybridFSM-first)",
                "n_agents" => cfg["n_agents"],
                "utilizations" => cfg["utilizations"],
                "sync_cadences" => cfg["sync_cadences"],
                "reps" => cfg["reps"],
                "horizon_s" => cfg["horizon_s"],
                "dt" => cfg["dt"],
                "wave_count" => cfg["wave_count"],
                "wave_interval_s" => cfg["wave_interval_s"],
                "density_mode" => cfg["density_mode"],
                "matrix_signature" => matrix_signature(cfg),
                "resume_enabled" => cfg["resume"],
                "threaded_reps" => cfg["threaded_reps"],
                "run_started_at" => string(now()),
            ),
            "matrix" => Dict{String, Any}(),
        )
    end

    settings = build_setting_list(cfg)
    total = length(settings)
    matrix = payload["matrix"]
    completed = count(s -> haskey(matrix, s.key), settings)

    println("\nDual-Gate HybridFSM benchmark matrix start")
    println("  tier: ", cfg["tier"])
    println("  threads: ", Threads.nthreads(), " (target: 16)")
    println("  threaded_reps: ", cfg["threaded_reps"])
    println("  total settings: ", total)
    println("  already completed: ", completed)
    println("  checkpoint latest: ", latest_path)
    println("  run file: ", run_path)

    if Threads.nthreads() < 16
        println("  WARNING: Julia is not running with 16 threads. Start with --threads 16")
    end

    if !resumed
        println("\nWarmup compile pass...")
        _ = run_coupled_dual_gate_case(
            n_agents=200,
            utilization=0.6,
            sync_cadence_ratio=10,
            sim_horizon_s=min(cfg["horizon_s"], 8.0),
            dt=cfg["dt"],
            seed=cfg["seed"],
            wave_count=2,
            wave_interval_s=2.0,
            density_mode=cfg["density_mode"],
            n_ref=cfg["n_ref"],
            base_room_w=cfg["base_room_w"],
            base_room_h=cfg["base_room_h"],
            base_v_pref=cfg["base_v_pref"],
            service_mu_base=cfg["service_mu_base"],
            capture_radius=cfg["capture_radius"],
            reroute_hysteresis=cfg["reroute_hysteresis"],
        )
        persist_payload(payload, run_path, latest_path)
    end

    t_global = time()
    done_new = 0

    for st in settings
        haskey(matrix, st.key) && continue

        now_done = completed + done_new
        println("\n[$(now_done + 1)/$total] Running $(st.key) ...")
        t0 = time()

        setting_result = run_parameter_set(cfg, st)
        matrix[st.key] = setting_result
        done_new += 1

        payload["metadata"]["last_completed_key"] = st.key
        payload["metadata"]["last_completed_at"] = string(now())
        payload["metadata"]["completed_settings"] = completed + done_new
        payload["metadata"]["total_settings"] = total

        persist_payload(payload, run_path, latest_path)

        elapsed_setting = time() - t0
        elapsed_global = time() - t_global
        avg = elapsed_global / done_new
        remaining = total - (completed + done_new)
        eta_s = remaining * avg

        s = setting_result["summary"]
        println("  done in ", round(elapsed_setting, digits=2), " s")
        println("  mean elapsed: ", round(s["mean_elapsed_s"], digits=4), " s")
        println("  mean reroutes: ", round(s["mean_reroute_count"], digits=2),
                " | mean departures: ", round(s["mean_gate_departures"], digits=2))
        println("  progress: ", completed + done_new, "/", total,
                " | ETA ~ ", round(eta_s / 60, digits=2), " min")
    end

    payload["metadata"]["run_finished_at"] = string(now())
    persist_payload(payload, run_path, latest_path)

    println("\nDual-Gate HybridFSM benchmark matrix completed.")
    println("  completed settings: ", payload["metadata"]["completed_settings"], "/", total)
    println("  latest: ", latest_path)
    println("  run file: ", run_path)

    return payload
end

function main()
    cfg = parse_cli_args(ARGS)
    run_benchmark_matrix(cfg)
end

main()
