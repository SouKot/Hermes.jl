# packages/GodotBridge/src/validation/analytical_benchmarks.jl
#
# Analytical Queueing Benchmark Solvers and Verification Engine.
# Provides closed-form ground truth solutions (M/M/1, M/M/c, M/G/1, Jackson Networks)
# and statistical comparison routines to verify simulation numerical integrity.

module AnalyticalBenchmarks

export AnalyticalResult, ValidationReport
export solve_mm1, solve_mmc, solve_mg1, solve_jackson_tandem
export validate_benchmark, evaluate_littles_law

"""
    AnalyticalResult

Closed-form analytical solution for a queueing station or network.
"""
struct AnalyticalResult
    name::String
    rho::Float64       # Utilization (server busy fraction)
    L::Float64         # Average WIP (entities in system: waiting + in service)
    Lq::Float64        # Average queue length (waiting entities only)
    W::Float64         # Average sojourn time (total time in system)
    Wq::Float64        # Average queue wait time (excluding service)
end

"""
    ValidationReport

Comparison between empirical simulation metrics and analytical ground truth.
"""
struct ValidationReport
    metric_name::String
    simulated_value::Float64
    analytical_value::Float64
    relative_error::Float64
    passed::Bool
    status::Symbol      # :pass, :warning, :fail
end

"""
    solve_mm1(lambda::Float64, mu::Float64) -> AnalyticalResult

Closed-form solution for an M/M/1 queueing system (Poisson arrivals, Exponential service).
Requires lambda < mu for steady-state stability.
"""
function solve_mm1(lambda::Float64, mu::Float64)::AnalyticalResult
    lambda > 0.0 || throw(ArgumentError("Arrival rate lambda must be positive, got $lambda"))
    mu > 0.0 || throw(ArgumentError("Service rate mu must be positive, got $mu"))
    lambda < mu || throw(ArgumentError("M/M/1 requires lambda < mu for stability: lambda=$lambda, mu=$mu"))

    rho = lambda / mu
    L = rho / (1.0 - rho)
    Lq = (rho^2) / (1.0 - rho)
    W = 1.0 / (mu - lambda)
    Wq = rho / (mu - lambda)

    return AnalyticalResult("M/M/1", rho, L, Lq, W, Wq)
end

"""
    solve_mmc(lambda::Float64, mu::Float64, c::Int) -> AnalyticalResult

Closed-form solution for an M/M/c multi-server queueing system (Erlang-C formula).
Requires lambda < c * mu for steady-state stability.
"""
function solve_mmc(lambda::Float64, mu::Float64, c::Int)::AnalyticalResult
    lambda > 0.0 || throw(ArgumentError("Arrival rate lambda must be positive, got $lambda"))
    mu > 0.0 || throw(ArgumentError("Service rate mu must be positive, got $mu"))
    c >= 1 || throw(ArgumentError("Number of servers c must be >= 1, got $c"))
    lambda < (c * mu) || throw(ArgumentError("M/M/c requires lambda < c * mu: lambda=$lambda, c*mu=$(c*mu)"))

    rho = lambda / (c * mu)
    a = lambda / mu

    # Compute p0 (probability of 0 entities in system)
    # sum_{n=0}^{c-1} (a^n / n!)
    sum_terms = 0.0
    term = 1.0
    for n in 0:(c - 1)
        if n > 0
            term *= a / n
        end
        sum_terms += term
    end

    # Last term: (a^c / (c! * (1 - rho)))
    c_term = 1.0
    for n in 1:c
        c_term *= a / n
    end
    c_term /= (1.0 - rho)

    p0 = 1.0 / (sum_terms + c_term)

    # Erlang-C probability of waiting: P(Wait > 0)
    p_wait = c_term * p0

    # Queue metrics
    Lq = (p_wait * rho) / (1.0 - rho)
    Wq = Lq / lambda
    W = Wq + (1.0 / mu)
    L = lambda * W

    return AnalyticalResult("M/M/$c", rho, L, Lq, W, Wq)
end

"""
    solve_mg1(lambda::Float64, mu::Float64, var_service::Float64) -> AnalyticalResult

Pollaczek-Khinchine formula for an M/G/1 queue (General service distribution).
`var_service` is the variance of the service time distribution (sigma^2).
"""
function solve_mg1(lambda::Float64, mu::Float64, var_service::Float64)::AnalyticalResult
    lambda > 0.0 || throw(ArgumentError("Arrival rate lambda must be positive, got $lambda"))
    mu > 0.0 || throw(ArgumentError("Service rate mu must be positive, got $mu"))
    var_service >= 0.0 || throw(ArgumentError("Service variance must be non-negative, got $var_service"))
    lambda < mu || throw(ArgumentError("M/G/1 requires lambda < mu: lambda=$lambda, mu=$mu"))

    rho = lambda / mu
    es = 1.0 / mu
    es2 = var_service + es^2

    # Pollaczek-Khinchine mean waiting time
    Wq = (lambda * es2) / (2.0 * (1.0 - rho))
    W = Wq + es
    Lq = lambda * Wq
    L = lambda * W

    return AnalyticalResult("M/G/1", rho, L, Lq, W, Wq)
end

"""
    solve_jackson_tandem(lambda::Float64, mu_vec::Vector{Float64}) -> Vector{AnalyticalResult}

Solves an open Jackson tandem network of M stations in series.
By Burke's Theorem, the departure process of each stable M/M/1 station is an identical Poisson process.
"""
function solve_jackson_tandem(lambda::Float64, mu_vec::Vector{Float64})::Vector{AnalyticalResult}
    results = AnalyticalResult[]
    for (i, mu) in enumerate(mu_vec)
        res = solve_mm1(lambda, mu)
        push!(results, AnalyticalResult("Jackson Station $i (mu=$mu)", res.rho, res.L, res.Lq, res.W, res.Wq))
    end
    return results
end

"""
    validate_benchmark(sim_metrics::Dict{String, Float64}, benchmark::AnalyticalResult; tolerance::Float64=0.05) -> Vector{ValidationReport}

Compares simulated metrics against analytical expectations. Returns a report per metric.
"""
function validate_benchmark(
    sim_metrics::Dict{String, Float64},
    benchmark::AnalyticalResult;
    tolerance::Float64 = 0.05
)::Vector{ValidationReport}
    reports = ValidationReport[]

    metric_pairs = [
        ("utilization", get(sim_metrics, "utilization", 0.0), benchmark.rho),
        ("sojourn_time_W", get(sim_metrics, "sojourn_mean", 0.0), benchmark.W),
        ("wait_time_Wq", get(sim_metrics, "wait_mean", 0.0), benchmark.Wq),
        ("wip_L", get(sim_metrics, "wip_mean", 0.0), benchmark.L),
        ("queue_Lq", get(sim_metrics, "queue_mean", 0.0), benchmark.Lq),
    ]

    for (name, sim_val, ana_val) in metric_pairs
        if ana_val > 0.0
            rel_err = abs(sim_val - ana_val) / ana_val
        else
            rel_err = abs(sim_val - ana_val)
        end

        passed = rel_err <= tolerance
        status = if rel_err <= tolerance
            :pass
        elseif rel_err <= (tolerance * 2.0)
            :warning
        else
            :fail
        end

        push!(reports, ValidationReport(name, sim_val, ana_val, rel_err, passed, status))
    end

    return reports
end

"""
    evaluate_littles_law(L::Float64, lambda::Float64, W::Float64; tolerance::Float64=0.03) -> Tuple{Float64, Symbol}

Evaluates Little's Law invariant: |L - lambda * W| / max(1.0, L).
Returns (relative_error, status) where status is :valid, :converging, or :divergent.
"""
function evaluate_littles_law(L::Float64, lambda::Float64, W::Float64; tolerance::Float64=0.03)::Tuple{Float64, Symbol}
    expected_L = lambda * W
    err = abs(L - expected_L) / max(1.0, L)

    status = if err <= tolerance
        :valid
    elseif err <= (tolerance * 2.5)
        :converging
    else
        :divergent
    end

    return (err, status)
end

end # module AnalyticalBenchmarks
