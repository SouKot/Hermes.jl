# packages/SimOptim/src/sciml_bridge.jl
#
# SciML OptimizationProblem Bridge, Common Random Numbers (CRN) DES Evaluator,
# and Metaheuristic / Policy Solvers for Antigravity SimOptim (Phase 7E-2 & 7E-3).

using SciMLBase
using CommonSolve
using Optim
using Random
using Statistics
using GodotBridge
using SimCore
using SimDES

# ─────────────────────────────────────────────────────────────────────────────
# 1. Exact Analytical M/M/c Erlang-C Formula
# ─────────────────────────────────────────────────────────────────────────────

"""
    erlang_c_wq(λ::Float64, μ::Float64, c::Int) -> Float64

Computes the exact steady-state expected waiting time in queue `W_q` for an M/M/c
station with arrival rate `λ`, per-server service rate `μ`, and `c` servers.
Returns `Inf` if `c <= 0` or `ρ = λ / (c*μ) >= 1.0`.
"""
function erlang_c_wq(λ::Float64, μ::Float64, c::Int)::Float64
    c <= 0 && return Inf
    μ <= 0.0 && return Inf
    λ <= 0.0 && return 0.0
    ρ = λ / (c * μ)
    ρ >= 1.0 && return 1e6 * (1.0 + ρ - 1.0)
    a = λ / μ
    sum_terms = 0.0
    for k in 0:(c - 1)
        sum_terms += (a^k) / factorial(k)
    end
    last_term = ((a^c) / factorial(c)) * (1.0 / (1.0 - ρ))
    C_prob = last_term / (sum_terms + last_term)
    return C_prob / (c * μ - λ)
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. Decision Vector Encoding, Decoding & SceneSpec Mutation
# ─────────────────────────────────────────────────────────────────────────────

"""
    encode_initial_vector(spec::SimOptimizationSpec) -> Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}}

Returns `(u0, lb, ub)` as `Float64` vectors suitable for `SciMLBase.OptimizationProblem`.
"""
function encode_initial_vector(spec::SimOptimizationSpec)::Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}}
    n = length(spec.decision_variables)
    u0 = zeros(Float64, n)
    lb = zeros(Float64, n)
    ub = zeros(Float64, n)

    for (i, v) in enumerate(spec.decision_variables)
        if v isa ParamDecisionVar
            if v.var_type == :categorical
                ncat = max(1, length(v.categories))
                lb[i] = 1.0
                ub[i] = Float64(ncat)
                idx = findfirst(==(string(v.initial)), v.categories)
                u0[i] = idx === nothing ? 1.0 : Float64(idx)
            else
                lb[i] = v.lower
                ub[i] = v.upper
                u0[i] = clamp(Float64(v.initial), v.lower, v.upper)
            end
        elseif v isa PolicyDecisionVar
            lb[i] = v.lower
            ub[i] = v.upper
            u0[i] = clamp(v.initial, v.lower, v.upper)
        elseif v isa GraphTopologyDecisionVar
            ncand = max(1, length(v.candidates))
            lb[i] = 1.0
            ub[i] = Float64(ncand)
            idx = findfirst(==(v.initial), v.candidates)
            u0[i] = idx === nothing ? 1.0 : Float64(idx)
        end
    end
    return (u0, lb, ub)
end

"""
    decode_decision_vector(spec::SimOptimizationSpec, u::AbstractVector{<:Real}) -> Tuple{Dict{String, Any}, String}

Decodes continuous vector `u` into a dictionary `var_id => typed_value` and a human-readable
summary string used for Top-\$K\$ deduplication and leaderboard display.
"""
function decode_decision_vector(spec::SimOptimizationSpec, u::AbstractVector{<:Real})::Tuple{Dict{String, Any}, String}
    decoded = Dict{String, Any}()
    parts = String[]
    all_int = !isempty(spec.decision_variables) && all(
        v -> (v isa ParamDecisionVar && v.var_type == :int),
        spec.decision_variables
    )
    int_vals = Int[]

    for (i, v) in enumerate(spec.decision_variables)
        raw_val = Float64(u[i])
        if v isa ParamDecisionVar
            if v.var_type == :int
                ival = clamp(round(Int, raw_val), round(Int, v.lower), round(Int, v.upper))
                decoded[v.id] = ival
                push!(int_vals, ival)
                push!(parts, "$(v.id)=$ival")
            elseif v.var_type == :categorical
                ncat = max(1, length(v.categories))
                idx = clamp(round(Int, raw_val), 1, ncat)
                sval = isempty(v.categories) ? "" : v.categories[idx]
                decoded[v.id] = sval
                push!(parts, "$(v.id)=$sval")
            else
                fval = round(clamp(raw_val, v.lower, v.upper); digits=2)
                decoded[v.id] = fval
                push!(parts, "$(v.id)=$fval")
            end
        elseif v isa PolicyDecisionVar
            fval = round(clamp(raw_val, v.lower, v.upper); digits=2)
            decoded[v.id] = fval
            push!(parts, "$(v.id)=$fval")
        elseif v isa GraphTopologyDecisionVar
            ncand = max(1, length(v.candidates))
            idx = clamp(round(Int, raw_val), 1, ncand)
            sval = isempty(v.candidates) ? "none" : v.candidates[idx]
            decoded[v.id] = sval
            push!(parts, "$(v.id)=$sval")
        end
    end

    summary = if all_int
        "[" * join(int_vals, ", ") * "]"
    else
        join(parts, ", ")
    end
    return (decoded, summary)
end

function _set_nested_property!(props::AbstractDict, prop_path::String, val::Any)
    if occursin('.', prop_path)
        segs = split(prop_path, '.')
        cur = props
        for s in segs[1:end-1]
            ks = String(s)
            if !haskey(cur, ks) || !(cur[ks] isa AbstractDict)
                cur[ks] = Dict{String, Any}()
            end
            cur = cur[ks]
        end
        cur[String(segs[end])] = val
    else
        props[prop_path] = val
    end
end

"""
    apply_decision_to_scenespec!(scenespec::Dict{String, Any}, spec::SimOptimizationSpec, decoded::Dict{String, Any}) -> Dict{String, Any}

Applies decoded decision variables onto `scenespec` in-place and returns `scenespec`.
"""
function apply_decision_to_scenespec!(
    scenespec::Dict{String, Any},
    spec::SimOptimizationSpec,
    decoded::Dict{String, Any}
)::Dict{String, Any}
    elems = get(scenespec, "elements", Any[])
    conns = get(scenespec, "connections", Any[])

    for v in spec.decision_variables
        haskey(decoded, v.id) || continue
        val = decoded[v.id]

        if v isa GraphTopologyDecisionVar && v.property == "recirculation_edge"
            # Remove any previous grammar recirculation edge from element_id
            filter!(c -> !(c isa AbstractDict && get(c, "id", "") == "conn_grammar_recirc"), conns)
            target_id = string(val)
            if target_id != "none" && !isempty(target_id)
                push!(conns, Dict{String, Any}(
                    "id" => "conn_grammar_recirc",
                    "source_element" => v.element_id,
                    "source_port" => "flow_out",
                    "target_element" => target_id,
                    "target_port" => "flow_in",
                    "link_type" => "flow",
                    "enabled" => true,
                    "ordering" => 99
                ))
            end
            continue
        end

        for el in elems
            el isa AbstractDict || continue
            if string(get(el, "id", "")) == v.element_id
                props = get!(el, "properties", Dict{String, Any}())
                _set_nested_property!(props, v.property, val)
                break
            end
        end
    end

    return scenespec
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. Common Random Numbers (CRN) Multi-Replication DES Evaluator
# ─────────────────────────────────────────────────────────────────────────────

function _reset_warmup_stats!(world::SimCore.SimWorld, t_now::Float64)
    SimCore.reset_stats!(world.stats)
    world.stats.warmup_complete = true
    for (_, zs) in world.zone_stats
        SimCore.reset_stats!(zs)
        zs.warmup_complete = true
    end
    for (_, zstate) in world.zone_states
        zstate.last_event_time = t_now
    end
    return nothing
end

function _compute_tandem_erlang_metrics(scenespec::Dict{String, Any})::Tuple{Float64, Float64}
    elems = get(scenespec, "elements", Any[])
    λ_total = 0.0
    for el in elems
        el isa AbstractDict || continue
        if string(get(el, "kind", "")) == "source"
            props = get(el, "properties", Dict{String, Any}())
            iat = get(props, "interarrival_time", Dict{String, Any}())
            mean_iat = Float64(get(iat, "mean", 0.0))
            if mean_iat > 0.0
                λ_total += 1.0 / mean_iat
            end
        end
    end
    λ_total <= 0.0 && return (0.0, 0.0)

    total_wq = 0.0
    total_w = 0.0
    for el in elems
        el isa AbstractDict || continue
        if string(get(el, "kind", "")) == "server"
            props = get(el, "properties", Dict{String, Any}())
            c = Int(get(props, "servers", 1))
            st = get(props, "service_time", Dict{String, Any}())
            mean_s = Float64(get(st, "mean", get(st, "mode", 1.0)))
            μ = mean_s > 0.0 ? (1.0 / mean_s) : 1.0
            wq = erlang_c_wq(λ_total, μ, c)
            total_wq += wq
            total_w += wq + mean_s
        end
    end
    return (total_wq, total_w)
end

"""
    evaluate_scenespec(scenespec::Dict{String, Any}, spec::SimOptimizationSpec; decoded=nothing) -> Dict{String, Float64}

Compiles `scenespec` and runs `R = spec.solver.replications_per_eval` Common Random Numbers (CRN)
replications through `SimDES`, returning aggregated performance metrics.
"""
function evaluate_scenespec(
    scenespec::Dict{String, Any},
    spec::SimOptimizationSpec;
    decoded::Union{Nothing, Dict{String, Any}} = nothing
)::Dict{String, Float64}
    R = max(1, spec.solver.replications_per_eval)
    horizon = max(10.0, spec.solver.sim_horizon)
    warmup = clamp(spec.solver.warmup_time, 0.0, horizon * 0.5)
    base_seed = spec.solver.base_seed

    # Structural quantities from SceneSpec
    total_servers = 0.0
    total_conveyor_length = 0.0
    for el in get(scenespec, "elements", Any[])
        el isa AbstractDict || continue
        kind = string(get(el, "kind", ""))
        props = get(el, "properties", Dict{String, Any}())
        if kind == "server"
            # Exclude fast virtual routers (mean service <= 0.1) from physical staff count
            st = get(props, "service_time", Dict{String, Any}())
            mean_s = Float64(get(st, "mean", 1.0))
            if mean_s > 0.1
                total_servers += Float64(get(props, "servers", 1))
            end
        elseif kind == "conveyor"
            total_conveyor_length += Float64(get(props, "length", 5.0))
        end
    end

    sojourn_samples = Float64[]
    wait_samples    = Float64[]
    vip_waits       = Float64[]
    std_waits       = Float64[]
    departures_list = Float64[]
    blocked_list    = Float64[]

    for r in 1:R
        comp = GodotBridge.compile_scenespec(scenespec)
        if !comp.success || comp.world === nothing || comp.fel === nothing
            return Dict{String, Float64}(
                "system_sojourn_mean" => 1e6,
                "system_wait_mean" => 1e6,
                "er_wait_mean" => 1e6,
                "vip_wait_mean" => 1e6,
                "std_wait_mean" => 1e6,
                "system_departures" => 0.0,
                "total_servers" => total_servers,
                "total_conveyor_length" => total_conveyor_length,
                "weighted_vip_std_cost" => 1e6,
                "conveyor_jam_and_sojourn" => 1e6
            )
        end

        seed_r = spec.solver.use_crn ?
            Int(mod(base_seed + UInt64(r) * 0x9e3779b97f4a7c15, UInt64(1_000_000_000))) :
            rand(1:1_000_000_000)

        inst = GodotBridge.SimulationInstance(
            "optim_rep_$r",
            comp.world,
            comp.fel,
            comp.zone_configs,
            comp.source_map,
            comp.execution_ir;
            seed = seed_r,
            clock_speed = Inf
        )

        if warmup > 0.0
            GodotBridge.step_until!(inst, warmup; fast_forward = true)
            _reset_warmup_stats!(inst.world, warmup)
        end
        GodotBridge.step_until!(inst, horizon; fast_forward = true)

        sys_zs = get(inst.world.zone_stats, 0, inst.world.stats)
        w_soj = SimCore.mean_sojourn_time(sys_zs)
        w_wait = SimCore.mean_wait_time(sys_zs)
        push!(sojourn_samples, isfinite(w_soj) ? w_soj : horizon)
        push!(wait_samples, isfinite(w_wait) ? w_wait : horizon)
        push!(departures_list, Float64(sys_zs.total_departures))
        push!(blocked_list, Float64(inst.world.stats.blocked_count))

        # Priority class 1 (VIP -> key -101) and class 0 (Standard -> key -100)
        if haskey(inst.world.zone_stats, -101)
            vw = SimCore.mean_wait_time(inst.world.zone_stats[-101])
            isfinite(vw) && push!(vip_waits, vw)
        end
        if haskey(inst.world.zone_stats, -100)
            sw = SimCore.mean_wait_time(inst.world.zone_stats[-100])
            isfinite(sw) && push!(std_waits, sw)
        end
    end

    sim_sojourn = isempty(sojourn_samples) ? 1e6 : mean(sojourn_samples)
    sim_wait    = isempty(wait_samples)    ? 1e6 : mean(wait_samples)
    vip_wait    = isempty(vip_waits)       ? sim_wait : mean(vip_waits)
    std_wait    = isempty(std_waits)       ? sim_wait : mean(std_waits)
    mean_deps   = isempty(departures_list) ? 0.0 : mean(departures_list)
    mean_blk    = isempty(blocked_list)    ? 0.0 : mean(blocked_list)

    er_wq, er_w = _compute_tandem_erlang_metrics(scenespec)
    # If problem is the 3-stage ER or uses er_wait_mean, provide exact steady-state Erlang-C Wq
    effective_er_wq = isfinite(er_wq) && er_wq > 0.0 ? er_wq : sim_wait
    effective_er_w  = isfinite(er_w)  && er_w > 0.0  ? er_w  : sim_sojourn

    weighted_vip_std = 5.0 * vip_wait + 1.0 * std_wait + 0.5 * total_servers
    jam_penalty = mean_blk * 5.0 + max(0.0, 100.0 - mean_deps) * 0.5
    conv_obj = sim_sojourn + jam_penalty

    return Dict{String, Float64}(
        "system_sojourn_mean" => sim_sojourn,
        "system_wait_mean" => sim_wait,
        "er_wait_mean" => effective_er_wq,
        "er_sojourn_mean" => effective_er_w,
        "vip_wait_mean" => vip_wait,
        "std_wait_mean" => std_wait,
        "system_departures" => mean_deps,
        "blocked_count" => mean_blk,
        "total_servers" => total_servers,
        "total_conveyor_length" => total_conveyor_length,
        "weighted_vip_std_cost" => weighted_vip_std,
        "conveyor_jam_and_sojourn" => conv_obj
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# 4. Constraint & Objective Evaluation
# ─────────────────────────────────────────────────────────────────────────────

"""
    evaluate_constraints_and_objective(spec, decoded, metrics)

Computes constraint satisfaction, margins (`rhs - value` for `<=`), penalty score,
and primary/secondary objectives (supporting multi-objective weighted sums).
"""
function evaluate_constraints_and_objective(
    spec::SimOptimizationSpec,
    decoded::Dict{String, Any},
    metrics::Dict{String, Float64}
)
    is_feasible = true
    total_violation = 0.0
    total_penalty = 0.0
    margins = Dict{String, Float64}()

    for c in spec.constraints
        lhs = 0.0
        if c.kind == :linear_sum
            for vid in c.variables
                v = get(decoded, vid, 0.0)
                lhs += v isa Real ? Float64(v) : 0.0
            end
        else
            lhs = Float64(get(metrics, c.metric, 0.0))
        end

        viol = 0.0
        margin = 0.0
        if c.relation == :(<=)
            margin = c.rhs - lhs
            viol = max(0.0, lhs - c.rhs)
        elseif c.relation == :(>=)
            margin = lhs - c.rhs
            viol = max(0.0, c.rhs - lhs)
        else
            margin = -abs(lhs - c.rhs)
            viol = abs(lhs - c.rhs)
        end

        margins[c.id] = margin
        if viol > 1e-6
            is_feasible = false
            total_violation += viol
            total_penalty += c.penalty_weight * (1.0 + viol)
        end
    end

    obj1 = isempty(spec.objectives) ? ObjectiveSpec() : spec.objectives[1]
    primary_val = Float64(get(metrics, obj1.metric, get(metrics, "system_sojourn_mean", 1e6)))
    secondary_key = if !isempty(obj1.secondary_metric)
        obj1.secondary_metric
    elseif length(spec.objectives) >= 2
        spec.objectives[2].metric
    else
        "total_servers"
    end
    secondary_val = Float64(get(metrics, secondary_key, 0.0))

    # Support single or multi-objective weighted sum over all ObjectiveSpec entries
    weighted_obj_sum = 0.0
    if isempty(spec.objectives)
        weighted_obj_sum = primary_val
    else
        for obj in spec.objectives
            val = Float64(get(metrics, obj.metric, primary_val))
            signed_val = obj.sense == :maximize ? -val : val
            weighted_obj_sum += signed_val * obj.weight
        end
    end
    penalized_score = weighted_obj_sum + total_penalty

    return (
        is_feasible = is_feasible,
        total_violation = total_violation,
        total_penalty = total_penalty,
        margins = margins,
        primary_objective = primary_val,
        secondary_objective = secondary_val,
        penalized_score = penalized_score
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# 5. SciML OptimizationProblem Bridge & Solvers
# ─────────────────────────────────────────────────────────────────────────────

"""
    OptimizationContext

Mutable evaluation context passed as parameters `p` to `SciMLBase.OptimizationProblem`.
Tracks every evaluation, updates the Top-\$K\$ `HallOfFameArchive`, records convergence
and scatter telemetry, and invokes optional `on_progress` streaming callbacks.
"""
mutable struct OptimizationContext
    base_scenespec      :: Dict{String, Any}
    spec                :: SimOptimizationSpec
    archive             :: HallOfFameArchive
    convergence_history :: Vector{Dict{String, Any}}
    scatter_points      :: Vector{Dict{String, Any}}
    eval_count          :: Int
    feasible_count      :: Int
    best_score          :: Float64
    best_primary        :: Float64
    best_summary        :: String
    start_time          :: Float64
    stop_requested      :: Base.RefValue{Bool}
    on_progress         :: Union{Nothing, Function}
end

function OptimizationContext(
    base_scenespec::Dict{String, Any},
    spec::SimOptimizationSpec;
    on_progress::Union{Nothing, Function} = nothing,
    stop_requested::Base.RefValue{Bool} = Ref(false)
)
    return OptimizationContext(
        deepcopy(base_scenespec),
        spec,
        HallOfFameArchive(spec.solver.top_k),
        Dict{String, Any}[],
        Dict{String, Any}[],
        0,
        0,
        Inf,
        Inf,
        "",
        time(),
        stop_requested,
        on_progress
    )
end

"""
    record_evaluation!(ctx, u_vec, decoded, summary, metrics, cand_scenespec; extra_violation=0.0, extra_penalty=0.0) -> Float64

Shared evaluation recorder used across all SimOptim solvers (parameter, policy, and 3D graph/spatial).
Evaluates constraints and objectives, updates the Top-\$K\$ `HallOfFameArchive`, appends convergence
and Pareto scatter telemetry, and triggers `ctx.on_progress(ctx)`.
"""
function record_evaluation!(
    ctx::OptimizationContext,
    u_vec::Vector{Float64},
    decoded::Dict{String, Any},
    summary::String,
    metrics::Dict{String, Float64},
    cand_scenespec::Dict{String, Any};
    extra_violation::Float64 = 0.0,
    extra_penalty::Float64 = 0.0
)::Float64
    ctx.eval_count += 1
    iter = ctx.eval_count

    eval_res = evaluate_constraints_and_objective(ctx.spec, decoded, metrics)
    is_feas = eval_res.is_feasible && (extra_violation <= 1e-6)
    tot_viol = eval_res.total_violation + extra_violation
    pen_score = eval_res.penalized_score + extra_penalty

    if is_feas
        ctx.feasible_count += 1
    end

    cand = HallOfFameCandidate(
        0,
        "cand_$(iter)",
        pen_score,
        eval_res.primary_objective,
        eval_res.secondary_objective,
        is_feas,
        tot_viol,
        eval_res.margins,
        u_vec,
        summary,
        decoded,
        metrics,
        cand_scenespec
    )
    update_hall_of_fame!(ctx.archive, cand)

    if !isempty(ctx.archive.candidates)
        top1 = ctx.archive.candidates[1]
        ctx.best_score = top1.penalized_score
        ctx.best_primary = top1.primary_objective
        ctx.best_summary = top1.decision_summary
    elseif pen_score < ctx.best_score
        ctx.best_score = pen_score
        ctx.best_primary = eval_res.primary_objective
        ctx.best_summary = summary
    end

    push!(ctx.convergence_history, Dict{String, Any}(
        "iteration" => iter,
        "current_objective" => eval_res.primary_objective,
        "current_penalized" => pen_score,
        "best_objective" => ctx.best_primary,
        "best_penalized" => ctx.best_score,
        "is_feasible" => is_feas,
        "summary" => summary
    ))

    push!(ctx.scatter_points, Dict{String, Any}(
        "iteration" => iter,
        "primary_objective" => eval_res.primary_objective,
        "secondary_objective" => eval_res.secondary_objective,
        "is_feasible" => is_feas,
        "summary" => summary
    ))

    if ctx.on_progress !== nothing
        try
            ctx.on_progress(ctx)
        catch e
            @warn "SimOptim on_progress callback error" exception=(e, catch_backtrace())
        end
    end

    return pen_score
end

"""
    evaluate_candidate_vector!(ctx::OptimizationContext, u::AbstractVector{<:Real}) -> Float64

Evaluates decision vector `u`, updates `ctx.archive` (Top-\$K\$ Hall of Fame) and telemetry
histories, fires `ctx.on_progress(ctx)` if attached, and returns `penalized_score`.
"""
function evaluate_candidate_vector!(ctx::OptimizationContext, u::AbstractVector{<:Real})::Float64
    decoded, summary = decode_decision_vector(ctx.spec, u)
    cand_scenespec = deepcopy(ctx.base_scenespec)
    apply_decision_to_scenespec!(cand_scenespec, ctx.spec, decoded)
    metrics = evaluate_scenespec(cand_scenespec, ctx.spec; decoded = decoded)
    return record_evaluation!(
        ctx,
        Float64[Float64(x) for x in u],
        decoded,
        summary,
        metrics,
        cand_scenespec
    )
end

"""
    build_sciml_problem(base_scenespec::Dict{String, Any}, spec::SimOptimizationSpec; kwargs...)
        -> Tuple{SciMLBase.OptimizationProblem, OptimizationContext}

Constructs a standard `SciMLBase.OptimizationProblem` from any declarative `SimOptimizationSpec`.
"""
function build_sciml_problem(
    base_scenespec::Dict{String, Any},
    spec::SimOptimizationSpec;
    on_progress::Union{Nothing, Function} = nothing,
    stop_requested::Base.RefValue{Bool} = Ref(false)
)::Tuple{SciMLBase.OptimizationProblem, OptimizationContext}
    u0, lb, ub = encode_initial_vector(spec)
    ctx = OptimizationContext(base_scenespec, spec; on_progress = on_progress, stop_requested = stop_requested)

    sciml_loss = function (u, p::OptimizationContext)
        return evaluate_candidate_vector!(p, u)
    end

    opt_fn = SciMLBase.OptimizationFunction{false}(sciml_loss)
    prob = SciMLBase.OptimizationProblem(opt_fn, u0, ctx; lb = lb, ub = ub)
    return (prob, ctx)
end

# ─────────────────────────────────────────────────────────────────────────────
# 6. SciML Solver Algorithms & CommonSolve.solve Extensions
# ─────────────────────────────────────────────────────────────────────────────

abstract type AbstractSimOptimAlg end

"""Adaptive Differential Evolution / Black-Box Global Optimizer (`:bbo` / `:eca`)."""
struct SimOptimBBO <: AbstractSimOptimAlg
    population_size :: Int
    F               :: Float64
    CR              :: Float64
end
SimOptimBBO(; population_size::Int = 10, F::Float64 = 0.7, CR::Float64 = 0.8) =
    SimOptimBBO(max(4, population_size), F, CR)

"""Mixed-Integer / Categorical Genetic Algorithm (`:mixed_ga`)."""
struct SimOptimMixedGA <: AbstractSimOptimAlg
    population_size :: Int
    mutation_rate   :: Float64
end
SimOptimMixedGA(; population_size::Int = 10, mutation_rate::Float64 = 0.25) =
    SimOptimMixedGA(max(4, population_size), mutation_rate)

"""State-Dependent Policy Search Optimizer (`:policy_search`)."""
struct SimOptimPolicySearch <: AbstractSimOptimAlg
    population_size :: Int
end
SimOptimPolicySearch(; population_size::Int = 10) = SimOptimPolicySearch(max(4, population_size))

"""Exhaustive / Smart Grid Enumeration for low-dimensional discrete spaces (`:exhaustive`)."""
struct SimOptimExhaustive <: AbstractSimOptimAlg end

"""SciML wrapper around `Optim.SAMIN` / `Optim.NelderMead` (`:nelder_mead`)."""
struct SimOptimNelderMead <: AbstractSimOptimAlg end

"""Template-Free Bilevel Graph Mutation + Inner 3D/2D Spatial Coordinate Optimizer (`:bilevel_graph_sa`)."""
struct SimOptimBilevelGraph <: AbstractSimOptimAlg end

function _select_algorithm(spec::SimOptimizationSpec)::AbstractSimOptimAlg
    alg = spec.solver.algorithm
    pop = spec.solver.population_size
    if spec.problem_class == :topology || alg in (:bilevel_graph_sa, :grammar_ga, :graph_sa, :bilevel)
        return SimOptimBilevelGraph()
    elseif alg in (:exhaustive, :grid)
        return SimOptimExhaustive()
    elseif alg in (:policy_search, :rl_policy, :ppo)
        return SimOptimPolicySearch(population_size = pop)
    elseif alg in (:mixed_ga, :ga, :nsga2)
        return SimOptimMixedGA(population_size = pop)
    elseif alg in (:nelder_mead, :optim)
        return SimOptimNelderMead()
    else
        return SimOptimBBO(population_size = pop)
    end
end

"""
    _enumerate_bounded_compositions!(results, current, idx, remaining, lb_int, ub_int, max_results)

General recursive generator for integer vectors `x` of arbitrary dimension `N` satisfying
`sum(x) == budget` and `lb_int[i] <= x[i] <= ub_int[i]`.
"""
function _enumerate_bounded_compositions!(
    results::Vector{Vector{Int}},
    current::Vector{Int},
    idx::Int,
    remaining::Int,
    lb_int::Vector{Int},
    ub_int::Vector{Int},
    max_results::Int = 64
)
    length(results) >= max_results && return
    N = length(lb_int)
    if idx == N
        if lb_int[N] <= remaining <= ub_int[N]
            current[N] = remaining
            push!(results, copy(current))
        end
        return
    end
    min_rest = sum(@view lb_int[(idx + 1):N])
    max_rest = sum(@view ub_int[(idx + 1):N])
    lo = max(lb_int[idx], remaining - max_rest)
    hi = min(ub_int[idx], remaining - min_rest)
    for val in lo:hi
        current[idx] = val
        _enumerate_bounded_compositions!(results, current, idx + 1, remaining - val, lb_int, ub_int, max_results)
        length(results) >= max_results && return
    end
end

function _generate_structured_seeds(spec::SimOptimizationSpec, lb::Vector{Float64}, ub::Vector{Float64}, rng::AbstractRNG)::Vector{Vector{Float64}}
    n = length(lb)
    seeds = Vector{Float64}[]

    # 1. Include initial baseline vector first so baseline is always evaluated as Iteration 1
    u0, _, _ = encode_initial_vector(spec)
    push!(seeds, copy(u0))

    var_idx_map = Dict{String, Int}(v.id => i for (i, v) in enumerate(spec.decision_variables))

    # 2. General linear_sum budget constraint seeder over ANY number of integer variables
    for c in spec.constraints
        if c.kind == :linear_sum
            idxs = [get(var_idx_map, vid, 0) for vid in c.variables]
            filter!(>(0), idxs)
            if !isempty(idxs) && all(i -> spec.decision_variables[i] isa ParamDecisionVar && spec.decision_variables[i].var_type == :int, idxs)
                budget = round(Int, c.rhs)
                lb_sub = [round(Int, lb[i]) for i in idxs]
                ub_sub = [round(Int, ub[i]) for i in idxs]
                comps = Vector{Int}[]
                _enumerate_bounded_compositions!(comps, zeros(Int, length(idxs)), 1, budget, lb_sub, ub_sub, 64)

                if length(idxs) == n
                    for comp in comps
                        push!(seeds, Float64.(comp))
                    end
                else
                    # Partial integer budget inside a mixed categorical/policy/integer problem:
                    # Pair integer budget allocations with combinations of categorical variables and policy thresholds
                    cat_idxs = [i for i in 1:n if spec.decision_variables[i] isa ParamDecisionVar && spec.decision_variables[i].var_type == :categorical]
                    pol_idxs = [i for i in 1:n if spec.decision_variables[i] isa PolicyDecisionVar]

                    for comp in comps
                        cat_ranges = [round(Int, lb[i]):round(Int, ub[i]) for i in cat_idxs]
                        for cat_tuple in Iterators.product(cat_ranges...)
                            for q_frac in (0.0, 0.5)
                                cand = copy(u0)
                                for (k, idx_var) in enumerate(idxs)
                                    cand[idx_var] = Float64(comp[k])
                                end
                                for (k, idx_cat) in enumerate(cat_idxs)
                                    cand[idx_cat] = Float64(cat_tuple[k])
                                end
                                for (k, idx_pol) in enumerate(pol_idxs)
                                    frac = isodd(k) ? q_frac : 0.73
                                    cand[idx_pol] = round(lb[idx_pol] + frac * (ub[idx_pol] - lb[idx_pol]); digits=2)
                                end
                                push!(seeds, cand)
                            end
                        end
                    end
                end
            end
        end
    end

    return seeds
end

function CommonSolve.solve(
    prob::SciMLBase.OptimizationProblem,
    alg::AbstractSimOptimAlg;
    maxiters::Int = 0
)
    ctx = prob.p::OptimizationContext
    spec = ctx.spec
    lb = Float64.(prob.lb)
    ub = Float64.(prob.ub)
    n = length(lb)
    max_evals = maxiters > 0 ? maxiters : spec.solver.max_evaluations
    rng = MersenneTwister(Int(mod(spec.solver.base_seed, UInt64(1_000_000))))

    if alg isa SimOptimBilevelGraph
        solve_bilevel_graph_search!(ctx, max_evals, rng)
    elseif alg isa SimOptimNelderMead
        obj_wrapped = x -> begin
            ctx.eval_count >= max_evals && return ctx.best_score
            xc = clamp.(x, lb, ub)
            prob.f(xc, ctx)
        end
        Optim.optimize(obj_wrapped, copy(prob.u0), Optim.NelderMead(), Optim.Options(f_calls_limit = max_evals))
    else
        seeds = _generate_structured_seeds(spec, lb, ub, rng)
        pop_size = alg isa SimOptimExhaustive ? length(seeds) : max(6, spec.solver.population_size)
        pop = Vector{Float64}[]
        scores = Float64[]

        for s in seeds
            (ctx.eval_count >= max_evals || ctx.stop_requested[]) && break
            sc = prob.f(clamp.(s, lb, ub), ctx)
            push!(pop, copy(s))
            push!(scores, sc)
        end

        while length(pop) < pop_size && ctx.eval_count < max_evals && !ctx.stop_requested[]
            cand = [lb[i] + rand(rng) * (ub[i] - lb[i]) for i in 1:n]
            sc = prob.f(cand, ctx)
            push!(pop, cand)
            push!(scores, sc)
        end

        while ctx.eval_count < max_evals && !ctx.stop_requested[] && length(pop) >= 3
            for idx in eachindex(pop)
                (ctx.eval_count >= max_evals || ctx.stop_requested[]) && break
                best_idx = argmin(scores)
                r1 = rand(rng, eachindex(pop))
                r2 = rand(rng, eachindex(pop))
                trial = copy(pop[idx])
                j_rand = rand(rng, 1:n)
                for j in 1:n
                    if rand(rng) < 0.75 || j == j_rand
                        trial[j] = pop[best_idx][j] + 0.65 * (pop[r1][j] - pop[r2][j]) + 0.1 * randn(rng) * (ub[j] - lb[j])
                    end
                    trial[j] = clamp(trial[j], lb[j], ub[j])
                end
                sc_trial = prob.f(trial, ctx)
                if sc_trial <= scores[idx]
                    pop[idx] = trial
                    scores[idx] = sc_trial
                end
            end
        end
    end

    best_u = !isempty(ctx.archive.candidates) ?
        copy(ctx.archive.candidates[1].decision_vector) :
        copy(prob.u0)
    best_obj = !isempty(ctx.archive.candidates) ?
        ctx.archive.candidates[1].penalized_score :
        ctx.best_score

    cache = SciMLBase.DefaultOptimizationCache(prob.f, prob.p)
    stats = SciMLBase.OptimizationStats(
        iterations = ctx.eval_count,
        time = time() - ctx.start_time,
        fevals = ctx.eval_count
    )

    return SciMLBase.build_solution(
        cache,
        alg,
        best_u,
        best_obj;
        retcode = SciMLBase.ReturnCode.Success,
        stats = stats
    )
end

"""
    optim_state_to_dict(ctx::OptimizationContext; status::String="running") -> Dict{String, Any}

Serializes the current `OptimizationContext` into the canonical `optim_state` dictionary
streamed to Godot Window 1 (Compact Progress HUD) and Window 2 (Live Feedback & Report).
"""
function optim_state_to_dict(ctx::OptimizationContext; status::String = "running")::Dict{String, Any}
    max_evals = max(1, ctx.spec.solver.max_evaluations)
    pct = clamp((Float64(ctx.eval_count) / Float64(max_evals)) * 100.0, 0.0, 100.0)
    return Dict{String, Any}(
        "status" => status,
        "problem_id" => ctx.spec.problem_id,
        "problem_class" => string(ctx.spec.problem_class),
        "title" => ctx.spec.title,
        "iteration" => ctx.eval_count,
        "max_iterations" => max_evals,
        "progress_pct" => round(pct; digits=1),
        "elapsed_sec" => round(time() - ctx.start_time; digits=2),
        "feasible_count" => ctx.feasible_count,
        "best_score" => isfinite(ctx.best_score) ? round(ctx.best_score; digits=3) : 0.0,
        "best_primary" => isfinite(ctx.best_primary) ? round(ctx.best_primary; digits=3) : 0.0,
        "best_label" => ctx.best_summary,
        "convergence_history" => ctx.convergence_history,
        "scatter_points" => ctx.scatter_points,
        "top_k_solutions" => hall_of_fame_to_dicts(ctx.archive)
    )
end

"""
    run_optimization!(base_scenespec::Dict{String, Any}; spec=nothing, on_progress=nothing, stop_requested=Ref(false))

High-level entry point that parses `spec` (from `base_scenespec["optimization"]` if not supplied),
builds the `SciMLBase.OptimizationProblem`, solves it via `CommonSolve.solve`, and returns
`(sciml_sol, ctx)`.
"""
function run_optimization!(
    base_scenespec::Dict{String, Any};
    spec::Union{Nothing, SimOptimizationSpec} = nothing,
    on_progress::Union{Nothing, Function} = nothing,
    stop_requested::Base.RefValue{Bool} = Ref(false)
)
    opt_spec = if spec !== nothing
        spec
    elseif haskey(base_scenespec, "optimization") && base_scenespec["optimization"] isa AbstractDict
        parse_optimization_spec(base_scenespec["optimization"])
    else
        throw(ArgumentError("SceneSpec does not contain an 'optimization' dictionary and no SimOptimizationSpec was provided."))
    end

    prob, ctx = build_sciml_problem(
        base_scenespec,
        opt_spec;
        on_progress = on_progress,
        stop_requested = stop_requested
    )
    alg = _select_algorithm(opt_spec)
    sol = CommonSolve.solve(prob, alg; maxiters = opt_spec.solver.max_evaluations)
    return (sol, ctx)
end
