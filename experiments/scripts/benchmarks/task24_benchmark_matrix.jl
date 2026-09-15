#!/usr/bin/env julia

"""
Task 24 benchmark matrix runner.

This benchmark measures the real Task 24 hybrid runtime path, not the older
SimViz scheduled-event demo path.

Cases captured per parameter setting:
  - `abm_only_headless`   : pure ABM stepping baseline
  - `hybrid_hook_only`    : SimCrowd hybrid hooks enabled, but no service-zone traffic
  - `hybrid_active`       : real ABM→DES→ABM sync with `sync_step!` and `SimDES`

Features:
  - Tiered matrices: tier1, tier2, full
  - Custom parameter subsets from CLI
  - Clear progress output with ETA
  - Incremental checkpoint write after EACH parameter setting
  - Resume from latest checkpoint
  - Optional threaded repetitions (start Julia with `--threads 16`)
"""

using Dates
using Statistics
using TOML
using Logging
using Random: AbstractRNG, MersenneTwister

const _TASK24_PACKAGES_DIR = normpath(joinpath(@__DIR__, "..", "..", "..", "packages"))
_TASK24_PACKAGES_DIR in LOAD_PATH || pushfirst!(LOAD_PATH, _TASK24_PACKAGES_DIR)

using Ark: Query
using SimCore
import SimDES
using SimViz
using SimCrowd: step!, Position, Velocity, Goal, MotionParams

const TIER1_MATRIX = Dict(
    "n_agents" => [200, 2000, 20000],
    "utilizations" => [0.6, 0.8],
    "sync_cadences" => [1, 10, 50],
    "reps" => 3,
    "horizon_s" => 120.0,
)

const TIER2_MATRIX = Dict(
    "n_agents" => [200, 2000, 20000],
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

function parse_csv_ints(s::String)
    isempty(s) && return Int[]
    return parse.(Int, split(s, ","))
end

function parse_csv_floats(s::String)
    isempty(s) && return Float64[]
    return parse.(Float64, split(s, ","))
end

parse_bool(s::String) = lowercase(strip(s)) in ("1", "true", "yes", "y", "on")

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

function _entity_sort_key(entity)
    T = typeof(entity)
    if hasfield(T, :_id)
        eid = Int(getfield(entity, :_id))
        egen = hasfield(T, :_gen) ? Int(getfield(entity, :_gen)) : 0
        return (eid, egen)
    end
    return (Int(hash(entity)), 0)
end

function _sorted_scene_entities(scene::SimViz.SimScene{F}) where {F}
    entities = Any[]
    for (ents, _) in Query(scene.world, (Position{F},))
        append!(entities, ents)
    end
    sort!(entities; by=_entity_sort_key)
    return entities
end

function _room_dims(n_agents::Int)
    scale = sqrt(max(1.0, n_agents / 200.0))
    return (width = 10.0 * scale, height = 6.0 * scale)
end

function _make_orca_ctx(; n_agents::Int, dt::Float64, seed::Int, staged_agents::Int)
    dims = _room_dims(n_agents)
    room = SimViz.RoomGeometry(
        width=dims.width,
        height=dims.height,
        doors=[SimViz.DoorSpec(wall=:east, center=0.5 * dims.height, width=min(2.0, 0.4 * dims.height))],
    )
    cfg = SimViz.ScenarioConfig(
        n_agents=n_agents,
        crowd_model=SimViz.MODEL_ORCA,
        flux_boundary=false,
        room=room,
        dt=dt,
        rng_seed=seed,
    )
    ctx = SimViz.build_world!(cfg)

    staged = min(staged_agents, n_agents)
    staged == 0 && return ctx, staged

    F = Float32
    entities = _sorted_scene_entities(ctx.scene)
    center_y = F(dims.height / 2)
    cols = max(1, ceil(Int, sqrt(staged)))
    rows = ceil(Int, staged / cols)
    x0 = F(0.9)
    x_spacing = F(0.08)
    y_spacing = F(0.08)
    row_center = F((rows - 1) / 2)
    targets = Dict{Any,Tuple{SimViz.SVector{2,F},SimViz.SVector{2,F}}}()

    for idx in 1:staged
        row = (idx - 1) ÷ cols
        col = (idx - 1) % cols
        pos = SimViz.SVector(x0 + x_spacing * F(col), center_y + y_spacing * (F(row) - row_center))
        targets[entities[idx]] = (pos, pos)
    end

    for (ents, pos_col, vel_col, goal_col, motion_col) in Query(
        ctx.ark_world,
        (Position{F}, Velocity{F}, Goal{F}, MotionParams{F}),
    )
        for i in eachindex(ents)
            target = get(targets, ents[i], nothing)
            isnothing(target) && continue
            pos, goal = target
            pos_col[i] = Position(pos)
            vel_col[i] = Velocity(zero(SimViz.SVector{2,F}))
            goal_col[i] = Goal(goal)
            motion = motion_col[i]
            motion_col[i] = MotionParams(motion.mass, zero(F), motion.τ, zero(F))
        end
    end

    return ctx, staged
end

function _run_des_until!(world::SimWorld,
                         fel::SimDES.FutureEventList,
                         configs::Dict{Int,SimDES.ZoneConfig},
                         clock::SimClock,
                         rng::AbstractRNG,
                         t_end::Float64;
                         pipeline::Union{Nothing,StatsPipeline}=nothing,
                         sync_bufs::Union{Nothing,HybridSyncBuffers}=nothing)
    while SimDES.peek_time(fel) <= t_end
        result = SimDES.safe_dequeue!(fel)
        result === nothing && break
        cev, t = result
        throttle!(clock, t)
        world.time = t
        SimDES.dispatch!(world, fel, configs, rng, cev.inner, t; pipeline=pipeline, sync_bufs=sync_bufs)
    end
    return world.stats
end

function _measure_sync_step_alloc(n_agents::Int, sync_ratio::Int)
    cfg = HybridSyncConfig(dt=0.05, Δt_sync=0.05 * sync_ratio, max_agents=n_agents,
                           max_pending_departures=max(16, n_agents), strict_invariants=true)
    bufs = HybridSyncBuffers(cfg)
    st = HybridSyncState()
    n_marked = min(max(1, n_agents ÷ 20), 16)
    for i in 1:n_marked
        bufs.d_zone_entry_flag[i] = true
        bufs.d_agent_zone[i] = Int32(1)
    end
    for i in 1:min(n_marked, 4)
        bufs.d_agent_in_service[n_marked + i] = true
        mark_departure!(bufs, n_marked + i; cfg=cfg)
    end
    sync_step!(bufs, st, 0.5; cfg=cfg)

    reset_sync_buffers!(bufs)
    reset_sync_state!(st)
    for i in 1:n_marked
        bufs.d_zone_entry_flag[i] = true
        bufs.d_agent_zone[i] = Int32(1)
    end
    for i in 1:min(n_marked, 4)
        bufs.d_agent_in_service[n_marked + i] = true
        mark_departure!(bufs, n_marked + i; cfg=cfg)
    end

    return @allocated sync_step!(bufs, st, 0.5; cfg=cfg)
end

function run_abm_only_case(; n_agents::Int=80,
                           sim_horizon_s::Float64=120.0,
                           dt::Float64=0.05,
                           seed::Int=2026,
                           staged_agents::Int=0,
                           quiet::Bool=true)
    runner = () -> begin
        ctx, staged = _make_orca_ctx(; n_agents=n_agents, dt=dt, seed=seed, staged_agents=staged_agents)
        n_steps = Int(round(sim_horizon_s / dt))
        timed = @timed begin
            for _ in 1:n_steps
                step!(ctx.scene)
                ctx.sim_time += ctx.config.dt
            end
            SimViz.serialize_world_ctx(ctx)
        end
        return Dict(
            "elapsed_s" => timed.time,
            "alloc_bytes" => Float64(timed.bytes),
            "gc_time_s" => timed.gctime,
            "n_steps" => Float64(n_steps),
            "sim_horizon_s" => sim_horizon_s,
            "steps_per_s" => n_steps / timed.time,
            "sim_seconds_per_wall_second" => sim_horizon_s / timed.time,
            "n_agents" => Float64(n_agents),
            "staged_agents" => Float64(staged),
        )
    end
    return quiet ? with_logger(NullLogger()) do; runner(); end : runner()
end

function run_hybrid_hook_only_case(; n_agents::Int=80,
                                   sim_horizon_s::Float64=120.0,
                                   dt::Float64=0.05,
                                   seed::Int=2026,
                                   sync_cadence_ratio::Int=10,
                                   quiet::Bool=true)
    runner = () -> begin
        sync_cfg = HybridSyncConfig(dt=dt, Δt_sync=dt * sync_cadence_ratio, max_agents=n_agents,
                                    max_pending_departures=max(64, n_agents), strict_invariants=true)
        ctx, _ = _make_orca_ctx(; n_agents=n_agents, dt=dt, seed=seed, staged_agents=0)
        bufs = HybridSyncBuffers(sync_cfg)
        st = HybridSyncState()
        n_steps = Int(round(sim_horizon_s / dt))
        sync_every = max(1, sync_cadence_ratio)

        timed = @timed begin
            for step_idx in 1:n_steps
                step!(ctx.scene; sync_bufs=bufs, service_zones=ServiceZone[])
                ctx.sim_time += ctx.config.dt
                if step_idx % sync_every == 0
                    sync_step!(bufs, st, ctx.sim_time; cfg=sync_cfg)
                end
            end
            SimViz.serialize_world_ctx(ctx)
        end

        return Dict(
            "elapsed_s" => timed.time,
            "alloc_bytes" => Float64(timed.bytes),
            "gc_time_s" => timed.gctime,
            "n_steps" => Float64(n_steps),
            "sim_horizon_s" => sim_horizon_s,
            "steps_per_s" => n_steps / timed.time,
            "sim_seconds_per_wall_second" => sim_horizon_s / timed.time,
            "n_agents" => Float64(n_agents),
            "sync_cadence_ratio" => Float64(sync_cadence_ratio),
            "sync_steps" => Float64(st.n_sync_steps),
            "total_arrivals_injected" => Float64(st.total_arrivals_injected),
            "total_departures_applied" => Float64(st.total_departures_applied),
        )
    end
    return quiet ? with_logger(NullLogger()) do; runner(); end : runner()
end

function run_hybrid_active_case(; n_agents::Int=80,
                                sim_horizon_s::Float64=120.0,
                                dt::Float64=0.05,
                                seed::Int=2026,
                                utilization::Float64=0.6,
                                sync_cadence_ratio::Int=10,
                                quiet::Bool=true)
    runner = () -> begin
        staged_agents = min(max(2, n_agents ÷ 20), 64)
        sync_cfg = HybridSyncConfig(dt=dt, Δt_sync=dt * sync_cadence_ratio, max_agents=n_agents,
                                    max_pending_departures=max(128, n_agents), strict_invariants=true)
        ctx, staged = _make_orca_ctx(; n_agents=n_agents, dt=dt, seed=seed, staged_agents=staged_agents)
        dims = _room_dims(n_agents)
        center_y = dims.height / 2
        service_zones = [ServiceZone(0.6, 2.2, center_y - 1.5, center_y + 1.5, 1)]

        world = SimWorld()
        fel = SimDES.FutureEventList()
        service_time = max(0.05, 0.25 * utilization)
        zone_cfg = SimDES.ZoneConfig(id=1, num_servers=1,
                                     service_dist=SimDES.deterministic_service(service_time),
                                     arrival_rate=0.0,
                                     routing=SimDES.ExitSystem())
        configs = Dict(1 => zone_cfg)
        SimDES.build_world!(world, zone_cfg)

        bufs = HybridSyncBuffers(sync_cfg)
        st = HybridSyncState()
        pipe = StatsPipeline(warmup=WARMUP_NONE)
        clock = SimClock(Inf)
        rng = MersenneTwister(seed + 17)
        n_steps = Int(round(sim_horizon_s / dt))
        sync_every = max(1, sync_cadence_ratio)

        timed = @timed begin
            for step_idx in 1:n_steps
                step!(ctx.scene; sync_bufs=bufs, service_zones=service_zones)
                ctx.sim_time += ctx.config.dt
                if step_idx % sync_every == 0
                    sync_step!(bufs, st, ctx.sim_time;
                               cfg=sync_cfg,
                               on_arrival! = arrival_event -> SimDES.schedule!(fel, arrival_event, arrival_event.time))
                    _run_des_until!(world, fel, configs, clock, rng, ctx.sim_time; pipeline=pipe, sync_bufs=bufs)
                end
            end

            _run_des_until!(world, fel, configs, clock, rng, ctx.sim_time + 10.0; pipeline=pipe, sync_bufs=bufs)
            sync_step!(bufs, st, ctx.sim_time + 10.0;
                       cfg=sync_cfg,
                       on_arrival! = arrival_event -> SimDES.schedule!(fel, arrival_event, arrival_event.time))

            SimViz.serialize_world_ctx(ctx)
        end

        sm = sim_summary(pipe)
        little_ok, little_err = check_littles_law(sm; tol=0.20)
        free_abm = count(!, bufs.d_agent_in_service)
        mass_residual = free_abm + length(world.des_agents) + length(bufs.pending_departures) - n_agents

        return Dict(
            "elapsed_s" => timed.time,
            "alloc_bytes" => Float64(timed.bytes),
            "gc_time_s" => timed.gctime,
            "n_steps" => Float64(n_steps),
            "sim_horizon_s" => sim_horizon_s,
            "steps_per_s" => n_steps / timed.time,
            "sim_seconds_per_wall_second" => sim_horizon_s / timed.time,
            "n_agents" => Float64(n_agents),
            "staged_agents" => Float64(staged),
            "utilization" => utilization,
            "service_time_s" => service_time,
            "sync_cadence_ratio" => Float64(sync_cadence_ratio),
            "sync_steps" => Float64(st.n_sync_steps),
            "total_arrivals_injected" => Float64(st.total_arrivals_injected),
            "total_departures_applied" => Float64(st.total_departures_applied),
            "des_total_arrivals" => Float64(world.stats.total_arrivals),
            "des_total_departures" => Float64(world.stats.total_departures),
            "W" => Float64(sm.W),
            "Wq" => Float64(sm.Wq),
            "L" => Float64(sm.L),
            "Lq" => Float64(sm.Lq),
            "rho" => Float64(sm.utilization),
            "lambda_eff" => Float64(sm.throughput),
            "littles_law_rel_err" => little_err,
            "little_ok" => little_ok ? 1.0 : 0.0,
            "mass_residual" => Float64(mass_residual),
        )
    end
    return quiet ? with_logger(NullLogger()) do; runner(); end : runner()
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

    metric_keys = String[]
    for r in runs
        append!(metric_keys, keys(r))
    end
    unique!(metric_keys)

    summaries = Dict{String, Any}()
    for k in metric_keys
        vals = Float64[]
        for r in runs
            if haskey(r, k)
                v = Float64(r[k])
                isfinite(v) && push!(vals, v)
            end
        end
        !isempty(vals) && (summaries[k] = summarize_scalar(vals))
    end

    return Dict("runs" => runs, "summary" => summaries)
end

function case_summary(case_name::String, result::Dict)
    summary = result["summary"]
    if !haskey(summary, "elapsed_s")
        return Dict("case" => case_name, "mean_elapsed_s" => NaN)
    end
    return Dict(
        "case" => case_name,
        "mean_elapsed_s" => summary["elapsed_s"]["mean"],
        "median_elapsed_s" => summary["elapsed_s"]["median"],
        "mean_alloc_bytes" => get(summary, "alloc_bytes", Dict("mean" => NaN))["mean"],
        "mean_steps_per_s" => get(summary, "steps_per_s", Dict("mean" => NaN))["mean"],
        "mean_little_err" => get(summary, "littles_law_rel_err", Dict("mean" => NaN))["mean"],
        "mean_mass_residual" => get(summary, "mass_residual", Dict("mean" => NaN))["mean"],
    )
end

function matrix_signature(cfg)
    return join([
        "n=" * join(cfg["n_agents"], ","),
        "u=" * join(string.(cfg["utilizations"]), ","),
        "s=" * join(cfg["sync_cadences"], ","),
        "r=" * string(cfg["reps"]),
        "h=" * string(cfg["horizon_s"]),
        "dt=" * string(cfg["dt"]),
    ], "|")
end

function run_parameter_set(; n_agents::Int, utilization::Float64, sync_cadence_ratio::Int,
                           reps::Int, horizon_s::Float64, dt::Float64, seed::Int,
                           threaded_reps::Bool)
    sync_step_alloc_bytes = _measure_sync_step_alloc(n_agents, sync_cadence_ratio)

    abm_res = repeat_case(i -> run_abm_only_case(
        n_agents=n_agents,
        sim_horizon_s=horizon_s,
        dt=dt,
        seed=seed + i - 1,
        staged_agents=0,
    ); reps=reps, threaded_reps=threaded_reps)

    hook_res = repeat_case(i -> run_hybrid_hook_only_case(
        n_agents=n_agents,
        sim_horizon_s=horizon_s,
        dt=dt,
        seed=seed + 10_000 + i - 1,
        sync_cadence_ratio=sync_cadence_ratio,
    ); reps=reps, threaded_reps=threaded_reps)

    active_res = repeat_case(i -> run_hybrid_active_case(
        n_agents=n_agents,
        sim_horizon_s=horizon_s,
        dt=dt,
        seed=seed + 20_000 + i - 1,
        utilization=utilization,
        sync_cadence_ratio=sync_cadence_ratio,
    ); reps=reps, threaded_reps=threaded_reps)

    abm_elapsed = abm_res["summary"]["elapsed_s"]["mean"]
    hook_elapsed = hook_res["summary"]["elapsed_s"]["mean"]
    active_elapsed = active_res["summary"]["elapsed_s"]["mean"]
    abm_alloc = abm_res["summary"]["alloc_bytes"]["mean"]
    hook_alloc = hook_res["summary"]["alloc_bytes"]["mean"]
    active_alloc = active_res["summary"]["alloc_bytes"]["mean"]

    return Dict(
        "n_agents" => n_agents,
        "utilization" => utilization,
        "sync_cadence_ratio" => sync_cadence_ratio,
        "sync_step_alloc_bytes" => Float64(sync_step_alloc_bytes),
        "abm_only_headless" => abm_res,
        "hybrid_hook_only" => hook_res,
        "hybrid_active" => active_res,
        "summary" => Dict(
            "abm_only_headless" => case_summary("abm_only_headless", abm_res),
            "hybrid_hook_only" => case_summary("hybrid_hook_only", hook_res),
            "hybrid_active" => case_summary("hybrid_active", active_res),
            "ratio_elapsed_hook_vs_abm" => hook_elapsed / abm_elapsed,
            "ratio_elapsed_active_vs_abm" => active_elapsed / abm_elapsed,
            "ratio_alloc_hook_vs_abm" => hook_alloc / abm_alloc,
            "ratio_alloc_active_vs_abm" => active_alloc / abm_alloc,
        ),
    )
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
    custom_matrix = false

    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--tier"
            tier = lowercase(argv[i + 1])
            i += 2
        elseif a == "--n-agents"
            n_agents = parse_csv_ints(argv[i + 1])
            custom_matrix = true
            i += 2
        elseif a == "--utilizations"
            utilizations = parse_csv_floats(argv[i + 1])
            custom_matrix = true
            i += 2
        elseif a == "--sync-cadences"
            sync_cadences = parse_csv_ints(argv[i + 1])
            custom_matrix = true
            i += 2
        elseif a == "--reps"
            reps = parse(Int, argv[i + 1])
            i += 2
        elseif a == "--horizon"
            horizon_s = parse(Float64, argv[i + 1])
            i += 2
        elseif a == "--dt"
            dt = parse(Float64, argv[i + 1])
            i += 2
        elseif a == "--seed"
            seed = parse(Int, argv[i + 1])
            i += 2
        elseif a == "--resume"
            resume = parse_bool(argv[i + 1])
            i += 2
        elseif a == "--threaded-reps"
            threaded_reps = parse_bool(argv[i + 1])
            i += 2
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
        isempty(n_agents) && (n_agents = [200])
        isempty(utilizations) && (utilizations = [0.6])
        isempty(sync_cadences) && (sync_cadences = [1])
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
    return settings
end

function persist_payload(payload::AbstractDict, run_path::String, latest_path::String)
    open(run_path, "w") do io
        TOML.print(io, payload)
    end
    cp(run_path, latest_path; force=true)
end

function load_resume_payload(latest_path::String, cfg)
    if !isfile(latest_path)
        return nothing
    end
    prior = TOML.parsefile(latest_path)
    if !haskey(prior, "metadata") || !haskey(prior["metadata"], "matrix_signature")
        return nothing
    end
    if String(prior["metadata"]["matrix_signature"]) != matrix_signature(cfg)
        return nothing
    end
    return Dict{String, Any}(prior)
end

function run_benchmark_matrix(cfg)
    timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    out_dir = joinpath(@__DIR__, "..", "..", "data", "benchmarks")
    mkpath(out_dir)

    run_path = joinpath(out_dir, "task24_benchmark_matrix_$(cfg["tier"])_$(timestamp).toml")
    latest_path = joinpath(out_dir, "task24_benchmark_matrix_$(cfg["tier"])_latest.toml")

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
                "script" => "experiments/scripts/benchmarks/task24_benchmark_matrix.jl",
                "tier" => cfg["tier"],
                "intent" => "Task24 hybrid-overhead benchmark matrix for ABM-only, hook-only, and active hybrid runtime",
                "n_agents" => cfg["n_agents"],
                "utilizations" => cfg["utilizations"],
                "sync_cadences" => cfg["sync_cadences"],
                "reps" => cfg["reps"],
                "horizon_s" => cfg["horizon_s"],
                "dt" => cfg["dt"],
                "resume_enabled" => cfg["resume"],
                "threaded_reps" => cfg["threaded_reps"],
                "matrix_signature" => matrix_signature(cfg),
                "run_started_at" => string(now()),
            ),
            "matrix" => Dict{String, Any}(),
        )
    end

    settings = build_setting_list(cfg)
    total = length(settings)
    matrix = payload["matrix"]
    completed = count(s -> haskey(matrix, s.key), settings)

    println("\nTask 24 hybrid benchmark matrix start")
    println("  tier: ", cfg["tier"])
    println("  threads: ", Threads.nthreads(), " (target: 16)")
    println("  threaded_reps: ", cfg["threaded_reps"])
    println("  total settings: ", total)
    println("  already completed: ", completed)
    println("  checkpoint latest: ", latest_path)
    println("  run file: ", run_path)
    Threads.nthreads() < 16 && println("  WARNING: Julia is not running with 16 threads. Start with --threads 16")

    if !resumed
        println("\nWarmup compile pass...")
        run_abm_only_case(n_agents=200, sim_horizon_s=min(cfg["horizon_s"], 5.0), dt=cfg["dt"], seed=cfg["seed"], quiet=true)
        run_hybrid_hook_only_case(n_agents=200, sim_horizon_s=min(cfg["horizon_s"], 5.0), dt=cfg["dt"], seed=cfg["seed"], sync_cadence_ratio=10, quiet=true)
        run_hybrid_active_case(n_agents=200, sim_horizon_s=min(cfg["horizon_s"], 5.0), dt=cfg["dt"], seed=cfg["seed"], utilization=0.6, sync_cadence_ratio=10, quiet=true)
        persist_payload(payload, run_path, latest_path)
    end

    t_global = time()
    done_new = 0

    for st in settings
        haskey(matrix, st.key) && continue

        now_done = completed + done_new
        println("\n[$(now_done + 1)/$total] Running $(st.key) ...")
        t0 = time()

        result = run_parameter_set(
            n_agents=st.n_agents,
            utilization=st.utilization,
            sync_cadence_ratio=st.sync,
            reps=cfg["reps"],
            horizon_s=cfg["horizon_s"],
            dt=cfg["dt"],
            seed=cfg["seed"],
            threaded_reps=cfg["threaded_reps"],
        )

        matrix[st.key] = result
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
        summary = result["summary"]

        println("  done in ", round(elapsed_setting, digits=2), " s")
        println("  hook/abm elapsed ratio: ", round(summary["ratio_elapsed_hook_vs_abm"], digits=4))
        println("  active/abm elapsed ratio: ", round(summary["ratio_elapsed_active_vs_abm"], digits=4))
        println("  sync_step @allocated: ", Int(round(result["sync_step_alloc_bytes"])), " bytes")
        println("  progress: ", completed + done_new, "/", total, " | ETA ~ ", round(eta_s / 60, digits=2), " min")
    end

    payload["metadata"]["run_finished_at"] = string(now())
    persist_payload(payload, run_path, latest_path)

    println("\nTask 24 hybrid benchmark matrix completed.")
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
