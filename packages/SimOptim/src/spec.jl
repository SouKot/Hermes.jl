# packages/SimOptim/src/spec.jl
#
# Declarative Optimization Problem Specification & Top-K Hall-of-Fame Archive
# for Antigravity SimOptim (Phase 7E-2).

"""
    AbstractDecisionVariable

Abstract supertype for all decision variables in a `SimOptimizationSpec`.
"""
abstract type AbstractDecisionVariable end

"""
    ParamDecisionVar <: AbstractDecisionVariable

Discrete integer, continuous float, or categorical parameter decision variable mapped to
a `SceneSpec` element property (supports dotted paths like `"routing_weights.vip_queue_threshold"`).
"""
struct ParamDecisionVar <: AbstractDecisionVariable
    id          :: String
    element_id  :: String
    property    :: String
    var_type    :: Symbol          # :int, :float, :categorical
    lower       :: Float64
    upper       :: Float64
    categories  :: Vector{String}
    initial     :: Any
    label       :: String
end

function ParamDecisionVar(;
    id::String,
    element_id::String,
    property::String,
    var_type::Symbol = :int,
    lower::Real = 1.0,
    upper::Real = 5.0,
    categories::Vector{String} = String[],
    initial::Any = lower,
    label::String = id
)
    if var_type == :categorical && !isempty(categories)
        return ParamDecisionVar(id, element_id, property, var_type, 1.0, Float64(length(categories)), categories, initial, label)
    end
    return ParamDecisionVar(id, element_id, property, var_type, Float64(lower), Float64(upper), categories, initial, label)
end

"""
    PolicyDecisionVar <: AbstractDecisionVariable

State-dependent routing or dispatch policy variable `π_θ(s)` parameterized by
threshold or linear/MLP policy weights.
"""
struct PolicyDecisionVar <: AbstractDecisionVariable
    id             :: String
    element_id     :: String
    property       :: String
    policy_kind    :: Symbol          # :state_threshold, :priority_hol, :linear_policy
    state_features :: Vector{Symbol}
    actions        :: Vector{Symbol}
    lower          :: Float64
    upper          :: Float64
    initial        :: Float64
    label          :: String
end

function PolicyDecisionVar(;
    id::String,
    element_id::String,
    property::String = "routing_weights.vip_queue_threshold",
    policy_kind::Symbol = :state_threshold,
    state_features::Vector{Symbol} = [:vip_queue_len, :pool_utilization],
    actions::Vector{Symbol} = [:dedicated, :pool_hol],
    lower::Real = 0.0,
    upper::Real = 5.0,
    initial::Real = 1.0,
    label::String = id
)
    return PolicyDecisionVar(id, element_id, property, policy_kind, state_features, actions,
                             Float64(lower), Float64(upper), Float64(initial), label)
end

"""
    GraphTopologyDecisionVar <: AbstractDecisionVariable

Combinatorial structural graph decision variable for adding/removing/rewiring edges
or selecting grammar mutations on a `SceneSpec` flow network.
"""
struct GraphTopologyDecisionVar <: AbstractDecisionVariable
    id                :: String
    element_id        :: String
    property          :: String
    allowed_mutations :: Vector{Symbol}
    candidates        :: Vector{String}
    initial           :: String
    label             :: String
end

function GraphTopologyDecisionVar(;
    id::String,
    element_id::String,
    property::String = "recirculation_edge",
    allowed_mutations::Vector{Symbol} = [:add_edge, :remove_edge, :rewire_edge, :spur_mode],
    candidates::Vector{String} = ["none"],
    initial::String = "none",
    label::String = id
)
    return GraphTopologyDecisionVar(id, element_id, property, allowed_mutations, candidates, initial, label)
end

"""
    ObjectiveSpec

Declarative objective specification (`:minimize` or `:maximize` a simulation/analytical metric).
"""
struct ObjectiveSpec
    sense            :: Symbol   # :minimize or :maximize
    metric           :: String   # e.g. "er_wait_mean", "system_sojourn_mean", "std_wait_mean"
    weight           :: Float64
    secondary_metric :: String
    description      :: String
end

function ObjectiveSpec(;
    sense::Symbol = :minimize,
    metric::String = "system_sojourn_mean",
    weight::Real = 1.0,
    secondary_metric::String = "total_servers",
    description::String = ""
)
    return ObjectiveSpec(sense, metric, Float64(weight), secondary_metric, description)
end

"""
    ConstraintSpec

Declarative constraint specification supporting resource budgets (`:linear_sum`),
simulation SLA bounds (`:metric_bound`), and structural limits (`:topology_budget`).
"""
struct ConstraintSpec
    id             :: String
    kind           :: Symbol          # :linear_sum, :metric_bound, :topology_budget
    variables      :: Vector{String}  # used by :linear_sum
    metric         :: String          # used by :metric_bound / :topology_budget
    relation       :: Symbol          # :<=, :>=, :==
    rhs            :: Float64
    penalty_weight :: Float64
    description    :: String
end

function ConstraintSpec(;
    id::String,
    kind::Symbol = :linear_sum,
    variables::Vector{String} = String[],
    metric::String = "",
    relation::Symbol = :<=,
    rhs::Real = 0.0,
    penalty_weight::Real = 100.0,
    description::String = ""
)
    return ConstraintSpec(id, kind, variables, metric, relation, Float64(rhs), Float64(penalty_weight), description)
end

"""
    SolverConfig

Configuration for the `SimOptim` optimization solver and Common Random Numbers (CRN) evaluator.
"""
struct SolverConfig
    algorithm             :: Symbol   # :bbo, :eca, :mixed_ga, :policy_search, :nsga2, :simulated_annealing, :cobyla, :exhaustive
    max_evaluations       :: Int
    population_size       :: Int
    replications_per_eval :: Int
    sim_horizon           :: Float64
    warmup_time           :: Float64
    use_crn               :: Bool
    base_seed             :: UInt64
    top_k                 :: Int
end

function SolverConfig(;
    algorithm::Symbol = :bbo,
    max_evaluations::Int = 40,
    population_size::Int = 10,
    replications_per_eval::Int = 4,
    sim_horizon::Real = 1200.0,
    warmup_time::Real = 150.0,
    use_crn::Bool = true,
    base_seed::UInt64 = 0x53494d_4f5054_0001,
    top_k::Int = 5
)
    return SolverConfig(
        algorithm,
        max(1, max_evaluations),
        max(2, population_size),
        max(1, replications_per_eval),
        Float64(sim_horizon),
        Float64(warmup_time),
        use_crn,
        base_seed,
        max(1, top_k)
    )
end

"""
    SimOptimizationSpec

Complete model-agnostic optimization specification parsed from or exported to `SceneSpec["optimization"]`.
"""
struct SimOptimizationSpec
    problem_id         :: String
    problem_class      :: Symbol   # :parameter, :policy, :topology
    title              :: String
    decision_variables :: Vector{AbstractDecisionVariable}
    objectives         :: Vector{ObjectiveSpec}
    constraints        :: Vector{ConstraintSpec}
    solver             :: SolverConfig
end

function SimOptimizationSpec(;
    problem_id::String = "custom_optim",
    problem_class::Symbol = :parameter,
    title::String = "Custom Simulation Optimization",
    decision_variables::Vector{<:AbstractDecisionVariable} = AbstractDecisionVariable[],
    objectives::Vector{ObjectiveSpec} = [ObjectiveSpec()],
    constraints::Vector{ConstraintSpec} = ConstraintSpec[],
    solver::SolverConfig = SolverConfig()
)
    return SimOptimizationSpec(
        problem_id,
        problem_class,
        title,
        AbstractDecisionVariable[v for v in decision_variables],
        objectives,
        constraints,
        solver
    )
end

"""
    HallOfFameCandidate

Represents one ranked solution in the Top-\$K\$ Hall-of-Fame archive, storing its
decision values, simulation metrics, constraint margins, and complete self-contained `SceneSpec`
dictionary for 2D snapshot rendering and 1-click loading onto the main canvas.
"""
mutable struct HallOfFameCandidate
    rank                 :: Int
    candidate_id         :: String
    penalized_score      :: Float64
    primary_objective    :: Float64
    secondary_objective  :: Float64
    is_feasible          :: Bool
    constraint_violation :: Float64
    constraint_margins   :: Dict{String, Float64}
    decision_vector      :: Vector{Float64}
    decision_summary     :: String
    decision_dict        :: Dict{String, Any}
    metrics              :: Dict{String, Float64}
    scenespec            :: Dict{String, Any}
end

function Base.getproperty(c::HallOfFameCandidate, sym::Symbol)
    if sym === :scenespec_snapshot
        return getfield(c, :scenespec)
    end
    return getfield(c, sym)
end

"""
    HallOfFameArchive

Maintains the deduplicated Top-\$K\$ best candidates discovered during an optimization run.
Feasible solutions are always ranked ahead of infeasible ones; ties are broken by `penalized_score`
and `primary_objective`.
"""
mutable struct HallOfFameArchive
    max_k      :: Int
    candidates :: Vector{HallOfFameCandidate}
    seen_keys  :: Dict{String, Int}
end

HallOfFameArchive(max_k::Int = 5) = HallOfFameArchive(max(1, max_k), HallOfFameCandidate[], Dict{String, Int}())

function _candidate_is_better(a::HallOfFameCandidate, b::HallOfFameCandidate)::Bool
    if a.is_feasible != b.is_feasible
        return a.is_feasible
    end
    if !isapprox(a.penalized_score, b.penalized_score; atol=1e-6)
        return a.penalized_score < b.penalized_score
    end
    return a.primary_objective < b.primary_objective
end

"""
    update_hall_of_fame!(archive::HallOfFameArchive, cand::HallOfFameCandidate) -> Bool

Inserts or updates `cand` in `archive` (deduplicating by `cand.decision_summary`),
re-sorts the Top-\$K\$ list, updates `.rank` fields `1..K`, and returns `true` if `cand`
entered or improved the Top-\$K\$.
"""
function update_hall_of_fame!(archive::HallOfFameArchive, cand::HallOfFameCandidate)::Bool
    key = cand.decision_summary
    existing_idx = findfirst(c -> c.decision_summary == key, archive.candidates)
    if existing_idx !== nothing
        if _candidate_is_better(cand, archive.candidates[existing_idx])
            archive.candidates[existing_idx] = cand
        else
            return false
        end
    else
        push!(archive.candidates, cand)
    end

    sort!(archive.candidates, lt = _candidate_is_better)
    if length(archive.candidates) > archive.max_k
        resize!(archive.candidates, archive.max_k)
    end
    for (idx, c) in enumerate(archive.candidates)
        c.rank = idx
    end
    return any(c -> c.decision_summary == key, archive.candidates)
end

"""
    hall_of_fame_to_dicts(archive::HallOfFameArchive) -> Vector{Dict{String, Any}}

Serializes the Top-\$K\$ Hall-of-Fame candidates into JSON/WebSocket-ready dictionaries.
"""
function hall_of_fame_to_dicts(archive::HallOfFameArchive; include_scenespec::Bool = true)::Vector{Dict{String, Any}}
    out = Dict{String, Any}[]
    for c in archive.candidates
        d = Dict{String, Any}(
            "rank" => c.rank,
            "candidate_id" => c.candidate_id,
            "penalized_score" => c.penalized_score,
            "primary_objective" => c.primary_objective,
            "secondary_objective" => c.secondary_objective,
            "is_feasible" => c.is_feasible,
            "constraint_violation" => c.constraint_violation,
            "constraint_margins" => copy(c.constraint_margins),
            "decision_vector" => copy(c.decision_vector),
            "decision_summary" => c.decision_summary,
            "decision_dict" => deepcopy(c.decision_dict),
            "metrics" => copy(c.metrics)
        )
        if include_scenespec
            d["scenespec"] = deepcopy(c.scenespec)
        end
        push!(out, d)
    end
    return out
end

# ─────────────────────────────────────────────────────────────────────────────
# Dictionary / JSON Parsing & Serialization
# ─────────────────────────────────────────────────────────────────────────────

function _dict_get(d::AbstractDict, key::String, default)
    if haskey(d, key)
        return d[key]
    elseif haskey(d, Symbol(key))
        return d[Symbol(key)]
    end
    return default
end

"""
    parse_optimization_spec(raw::AbstractDict) -> SimOptimizationSpec

Parses a declarative `SceneSpec["optimization"]` dictionary into a typed `SimOptimizationSpec`.
"""
function parse_optimization_spec(raw::AbstractDict)::SimOptimizationSpec
    prob_id    = string(_dict_get(raw, "problem_id", "custom_optim"))
    prob_class = Symbol(lowercase(string(_dict_get(raw, "problem_class", "parameter"))))
    title      = string(_dict_get(raw, "title", "Simulation Optimization"))

    # 1. Decision variables
    dvars = AbstractDecisionVariable[]
    raw_vars = _dict_get(raw, "decision_variables", Any[])
    for rv in raw_vars
        rv isa AbstractDict || continue
        vid   = string(_dict_get(rv, "id", "v_$(length(dvars)+1)"))
        el_id = string(_dict_get(rv, "element_id", ""))
        prop  = string(_dict_get(rv, "property", ""))
        vtype = Symbol(lowercase(string(_dict_get(rv, "type", "int"))))
        lbl   = string(_dict_get(rv, "label", vid))

        if vtype in (:grammar_edge, :topology, :graph)
            cands = String[string(x) for x in _dict_get(rv, "candidates", Any["none"])]
            init_val = string(_dict_get(rv, "initial", isempty(cands) ? "none" : cands[1]))
            push!(dvars, GraphTopologyDecisionVar(
                id = vid, element_id = el_id, property = prop,
                candidates = cands, initial = init_val, label = lbl
            ))
        elseif vtype == :policy
            lo = Float64(_dict_get(rv, "lower", 0.0))
            hi = Float64(_dict_get(rv, "upper", 5.0))
            init_val = Float64(_dict_get(rv, "initial", (lo + hi) / 2))
            push!(dvars, PolicyDecisionVar(
                id = vid, element_id = el_id, property = prop,
                lower = lo, upper = hi, initial = init_val, label = lbl
            ))
        elseif vtype == :categorical
            cats = String[string(x) for x in _dict_get(rv, "categories", Any[])]
            init_val = string(_dict_get(rv, "initial", isempty(cats) ? "" : cats[1]))
            push!(dvars, ParamDecisionVar(
                id = vid, element_id = el_id, property = prop,
                var_type = :categorical, categories = cats, initial = init_val, label = lbl
            ))
        elseif vtype == :float
            lo = Float64(_dict_get(rv, "lower", 0.0))
            hi = Float64(_dict_get(rv, "upper", 1.0))
            init_val = Float64(_dict_get(rv, "initial", lo))
            push!(dvars, ParamDecisionVar(
                id = vid, element_id = el_id, property = prop,
                var_type = :float, lower = lo, upper = hi, initial = init_val, label = lbl
            ))
        else
            lo = Float64(_dict_get(rv, "lower", 1))
            hi = Float64(_dict_get(rv, "upper", 5))
            init_val = round(Int, Float64(_dict_get(rv, "initial", lo)))
            push!(dvars, ParamDecisionVar(
                id = vid, element_id = el_id, property = prop,
                var_type = :int, lower = lo, upper = hi, initial = init_val, label = lbl
            ))
        end
    end

    # 2. Objectives (supports single "objective" dict or "objectives" array)
    objs = ObjectiveSpec[]
    if haskey(raw, "objectives") || haskey(raw, :objectives)
        for ro in _dict_get(raw, "objectives", Any[])
            ro isa AbstractDict || continue
            push!(objs, ObjectiveSpec(
                sense = Symbol(lowercase(string(_dict_get(ro, "sense", "minimize")))),
                metric = string(_dict_get(ro, "metric", "system_sojourn_mean")),
                weight = Float64(_dict_get(ro, "weight", 1.0)),
                secondary_metric = string(_dict_get(ro, "secondary_metric", "total_servers")),
                description = string(_dict_get(ro, "description", ""))
            ))
        end
    elseif haskey(raw, "objective") || haskey(raw, :objective)
        ro = _dict_get(raw, "objective", Dict{String, Any}())
        if ro isa AbstractDict
            push!(objs, ObjectiveSpec(
                sense = Symbol(lowercase(string(_dict_get(ro, "sense", "minimize")))),
                metric = string(_dict_get(ro, "metric", "system_sojourn_mean")),
                weight = Float64(_dict_get(ro, "weight", 1.0)),
                secondary_metric = string(_dict_get(ro, "secondary_metric", "total_servers")),
                description = string(_dict_get(ro, "description", ""))
            ))
        end
    end
    isempty(objs) && push!(objs, ObjectiveSpec())

    # 3. Constraints
    constrs = ConstraintSpec[]
    for rc in _dict_get(raw, "constraints", Any[])
        rc isa AbstractDict || continue
        cid  = string(_dict_get(rc, "id", "c_$(length(constrs)+1)"))
        kind = Symbol(lowercase(string(_dict_get(rc, "kind", "linear_sum"))))
        vars = String[string(v) for v in _dict_get(rc, "variables", Any[])]
        met  = string(_dict_get(rc, "metric", ""))
        rel_str = string(_dict_get(rc, "relation", "<="))
        rel  = rel_str == ">=" ? :(>=) : (rel_str == "==" ? :(==) : :(<=))
        rhs  = Float64(_dict_get(rc, "rhs", 0.0))
        pen  = Float64(_dict_get(rc, "penalty_weight", 100.0))
        desc = string(_dict_get(rc, "description", ""))
        push!(constrs, ConstraintSpec(cid, kind, vars, met, rel, rhs, pen, desc))
    end

    # 4. Solver config
    rs = _dict_get(raw, "solver", Dict{String, Any}())
    solver = if rs isa AbstractDict
        SolverConfig(
            algorithm = Symbol(lowercase(string(_dict_get(rs, "algorithm", "bbo")))),
            max_evaluations = Int(_dict_get(rs, "max_evaluations", 40)),
            population_size = Int(_dict_get(rs, "population_size", 10)),
            replications_per_eval = Int(_dict_get(rs, "replications_per_eval", 4)),
            sim_horizon = Float64(_dict_get(rs, "sim_horizon", 1200.0)),
            warmup_time = Float64(_dict_get(rs, "warmup_time", 150.0)),
            use_crn = Bool(_dict_get(rs, "use_crn", true)),
            top_k = Int(_dict_get(rs, "top_k", 5))
        )
    else
        SolverConfig()
    end

    return SimOptimizationSpec(prob_id, prob_class, title, dvars, objs, constrs, solver)
end

"""
    optimization_spec_to_dict(spec::SimOptimizationSpec) -> Dict{String, Any}

Converts a `SimOptimizationSpec` back into a canonical `SceneSpec["optimization"]` dictionary.
"""
function optimization_spec_to_dict(spec::SimOptimizationSpec)::Dict{String, Any}
    vars_out = Any[]
    for v in spec.decision_variables
        if v isa ParamDecisionVar
            d = Dict{String, Any}(
                "id" => v.id,
                "element_id" => v.element_id,
                "property" => v.property,
                "type" => string(v.var_type),
                "initial" => v.initial,
                "label" => v.label
            )
            if v.var_type == :categorical
                d["categories"] = Any[c for c in v.categories]
            elseif v.var_type == :int
                d["lower"] = round(Int, v.lower)
                d["upper"] = round(Int, v.upper)
            else
                d["lower"] = v.lower
                d["upper"] = v.upper
            end
            push!(vars_out, d)
        elseif v isa PolicyDecisionVar
            push!(vars_out, Dict{String, Any}(
                "id" => v.id,
                "element_id" => v.element_id,
                "property" => v.property,
                "type" => "policy",
                "policy_kind" => string(v.policy_kind),
                "lower" => v.lower,
                "upper" => v.upper,
                "initial" => v.initial,
                "label" => v.label
            ))
        elseif v isa GraphTopologyDecisionVar
            push!(vars_out, Dict{String, Any}(
                "id" => v.id,
                "element_id" => v.element_id,
                "property" => v.property,
                "type" => "grammar_edge",
                "candidates" => Any[c for c in v.candidates],
                "initial" => v.initial,
                "label" => v.label
            ))
        end
    end

    constrs_out = Any[]
    for c in spec.constraints
        push!(constrs_out, Dict{String, Any}(
            "id" => c.id,
            "kind" => string(c.kind),
            "variables" => Any[v for v in c.variables],
            "metric" => c.metric,
            "relation" => string(c.relation),
            "rhs" => c.rhs,
            "penalty_weight" => c.penalty_weight,
            "description" => c.description
        ))
    end

    obj1 = isempty(spec.objectives) ? ObjectiveSpec() : spec.objectives[1]
    return Dict{String, Any}(
        "problem_id" => spec.problem_id,
        "problem_class" => string(spec.problem_class),
        "title" => spec.title,
        "decision_variables" => vars_out,
        "constraints" => constrs_out,
        "objective" => Dict{String, Any}(
            "sense" => string(obj1.sense),
            "metric" => obj1.metric,
            "weight" => obj1.weight,
            "secondary_metric" => obj1.secondary_metric,
            "description" => obj1.description
        ),
        "solver" => Dict{String, Any}(
            "algorithm" => string(spec.solver.algorithm),
            "max_evaluations" => spec.solver.max_evaluations,
            "population_size" => spec.solver.population_size,
            "replications_per_eval" => spec.solver.replications_per_eval,
            "sim_horizon" => spec.solver.sim_horizon,
            "warmup_time" => spec.solver.warmup_time,
            "use_crn" => spec.solver.use_crn,
            "top_k" => spec.solver.top_k
        )
    )
end
