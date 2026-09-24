# packages/GodotBridge/src/compiler/distribution_parser.jl
#
# Statistical Distribution Parser & Sampler Generator for SceneSpec Compiler.
# Translates scalar values, string identifiers, and parameter dictionaries
# into type-stable, zero-allocation callable samplers: (rng::AbstractRNG) -> Float64.

using Distributions: Exponential, Dirac, Erlang, Uniform, Normal, TriangularDist, rand
using Random: AbstractRNG

"""
    normalize_time_unit_scale(unit::AbstractString)::Float64

Returns the conversion multiplier to normalize a time unit into simulated seconds.
"""
function normalize_time_unit_scale(unit::AbstractString)::Float64
    u = lowercase(strip(string(unit)))
    if u in ["s", "sec", "second", "seconds"]
        return 1.0
    elseif u in ["m", "min", "minute", "minutes"]
        return 60.0
    elseif u in ["h", "hr", "hour", "hours"]
        return 3600.0
    elseif u in ["d", "day", "days"]
        return 86400.0
    elseif u in ["ms", "msec", "millisecond", "milliseconds"]
        return 0.001
    else
        return 1.0
    end
end

"""
    parse_arrival_sampler(properties::Dict{String, Any}, base_time_unit::String="seconds") -> Tuple{Any, Vector{String}}

Extracts and builds an arrival time interval sampler: `rng -> Δt` from element properties.
Returns `(sampler, errors)`.
"""
function parse_arrival_sampler(properties::Dict{String, Any}, base_time_unit::String="seconds")
    errors = String[]
    time_scale = normalize_time_unit_scale(base_time_unit)

    # 1. Direct distribution dict
    dist_val = get(properties, "arrival_distribution", get(properties, "distribution", nothing))
    
    # Check for direct arrival rate
    if haskey(properties, "arrival_rate")
        rate = Float64(properties["arrival_rate"])
        if rate <= 0.0
            push!(errors, "arrival_rate must be strictly positive, got $rate")
            return ((rng) -> 1.0, errors)
        end
        # Poisson process interarrival time: Exp(1/λ)
        mean_interarrival = (1.0 / rate) * time_scale
        dist = Exponential(mean_interarrival)
        return ((rng::AbstractRNG) -> rand(rng, dist), errors)
    elseif haskey(properties, "interarrival_time") || haskey(properties, "mean_interarrival_time")
        raw = get(properties, "interarrival_time", get(properties, "mean_interarrival_time", 1.0))
        if raw isa Dict
            return _build_sampler_from_dict(raw, time_scale)
        else
            val = Float64(raw)
            if val <= 0.0
                push!(errors, "interarrival_time must be strictly positive, got $val")
                return ((rng) -> 1.0, errors)
            end
            dist = Exponential(val * time_scale)
            return ((rng::AbstractRNG) -> rand(rng, dist), errors)
        end
    end

    if dist_val isa Dict
        return _build_sampler_from_dict(dist_val, time_scale)
    elseif dist_val isa AbstractString
        dist_type = lowercase(strip(dist_val))
        if dist_type == "exponential"
            rate = Float64(get(properties, "rate", get(properties, "arrival_rate", 1.0)))
            dist = Exponential((1.0 / rate) * time_scale)
            return ((rng::AbstractRNG) -> rand(rng, dist), errors)
        elseif dist_type in ["constant", "deterministic"]
            val = Float64(get(properties, "value", get(properties, "time", 1.0))) * time_scale
            return ((rng::AbstractRNG) -> val, errors)
        elseif dist_type == "uniform"
            min_v = Float64(get(properties, "min", 0.5)) * time_scale
            max_v = Float64(get(properties, "max", 1.5)) * time_scale
            dist = Uniform(min_v, max_v)
            return ((rng::AbstractRNG) -> rand(rng, dist), errors)
        end
    end

    # Default fallback: 1 arrival per simulated second
    default_dist = Exponential(1.0 * time_scale)
    return ((rng::AbstractRNG) -> rand(rng, default_dist), errors)
end

"""
    parse_service_sampler(properties::Dict{String, Any}, base_time_unit::String="seconds") -> Tuple{Any, Any, Vector{String}}

Extracts and builds a service time distribution object and callable sampler.
Returns `(dist_obj, sampler, errors)`.
"""
function parse_service_sampler(properties::Dict{String, Any}, base_time_unit::String="seconds")
    errors = String[]
    time_scale = normalize_time_unit_scale(base_time_unit)

    # 1. Direct rate
    if haskey(properties, "service_rate")
        rate = Float64(properties["service_rate"])
        if rate <= 0.0
            push!(errors, "service_rate must be strictly positive, got $rate")
            return (Dirac(1.0), (rng) -> 1.0, errors)
        end
        mean_service = (1.0 / rate) * time_scale
        dist = Exponential(mean_service)
        return (dist, (rng::AbstractRNG) -> rand(rng, dist), errors)
    elseif haskey(properties, "service_time")
        st = properties["service_time"]
        if st isa Dict
            return parse_distribution_object(st, time_scale)
        else
            val = Float64(st) * time_scale
            if val <= 0.0
                push!(errors, "service_time must be strictly positive, got $val")
                return (Dirac(1.0), (rng) -> 1.0, errors)
            end
            dist_kind = lowercase(string(get(properties, "service_distribution", "constant")))
            if dist_kind == "exponential"
                dist = Exponential(val)
                return (dist, (rng::AbstractRNG) -> rand(rng, dist), errors)
            else
                dist = Dirac(val)
                return (dist, (rng::AbstractRNG) -> val, errors)
            end
        end
    end

    dist_val = get(properties, "service_distribution", get(properties, "distribution", nothing))
    if dist_val isa Dict
        return parse_distribution_object(dist_val, time_scale)
    elseif dist_val isa AbstractString
        dist_type = lowercase(strip(dist_val))
        if dist_type == "exponential"
            mean_time = Float64(get(properties, "mean", 1.0)) * time_scale
            dist = Exponential(mean_time)
            return (dist, (rng::AbstractRNG) -> rand(rng, dist), errors)
        elseif dist_type in ["constant", "deterministic"]
            val = Float64(get(properties, "value", 1.0)) * time_scale
            dist = Dirac(val)
            return (dist, (rng::AbstractRNG) -> val, errors)
        elseif dist_type == "uniform"
            min_v = Float64(get(properties, "min", 0.5)) * time_scale
            max_v = Float64(get(properties, "max", 1.5)) * time_scale
            dist = Uniform(min_v, max_v)
            return (dist, (rng::AbstractRNG) -> rand(rng, dist), errors)
        elseif dist_type == "normal"
            mean_v = Float64(get(properties, "mean", 5.0)) * time_scale
            std_v = Float64(get(properties, "std", 1.0)) * time_scale
            dist = Normal(mean_v, std_v)
            return (dist, (rng::AbstractRNG) -> max(0.001, rand(rng, dist)), errors)
        end
    end

    # Default fallback: 1 second exponential service
    default_dist = Exponential(1.0 * time_scale)
    return (default_dist, (rng::AbstractRNG) -> rand(rng, default_dist), errors)
end

"""
    parse_distribution_object(d::Dict, time_scale::Float64) -> Tuple{UnivariateDistribution, Any, Vector{String}}

Parses a distribution dictionary and returns `(dist_obj, sampler, errors)`.
"""
function parse_distribution_object(d::Dict, time_scale::Float64)
    errors = String[]
    kind = lowercase(string(get(d, "type", get(d, "kind", get(d, "distribution", "exponential")))))

    if kind in ["exponential", "exp"]
        if haskey(d, "mean")
            m = max(0.0001, Float64(d["mean"]) * time_scale)
            dist = Exponential(m)
            return (dist, (rng::AbstractRNG) -> rand(rng, dist), errors)
        elseif haskey(d, "rate")
            r = max(0.0001, Float64(d["rate"]))
            dist = Exponential((1.0 / r) * time_scale)
            return (dist, (rng::AbstractRNG) -> rand(rng, dist), errors)
        else
            m = max(0.0001, Float64(get(d, "value", 1.0)) * time_scale)
            dist = Exponential(m)
            return (dist, (rng::AbstractRNG) -> rand(rng, dist), errors)
        end
    elseif kind in ["constant", "deterministic", "dirac"]
        val = max(0.0001, Float64(get(d, "value", get(d, "val", get(d, "time", 1.0)))) * time_scale)
        dist = Dirac(val)
        return (dist, (rng::AbstractRNG) -> val, errors)
    elseif kind in ["uniform", "unif"]
        min_v = max(0.0001, Float64(get(d, "min", 0.5)) * time_scale)
        max_v = max(min_v + 0.0001, Float64(get(d, "max", 1.5)) * time_scale)
        dist = Uniform(min_v, max_v)
        return (dist, (rng::AbstractRNG) -> rand(rng, dist), errors)
    elseif kind in ["normal", "gaussian"]
        mean_v = max(0.0001, Float64(get(d, "mean", 5.0)) * time_scale)
        std_v = max(0.0001, Float64(get(d, "std", get(d, "std_dev", 1.0))) * time_scale)
        dist = Normal(mean_v, std_v)
        return (dist, (rng::AbstractRNG) -> max(0.001, rand(rng, dist)), errors)
    elseif kind in ["erlang"]
        k = max(1, Int(get(d, "k", 2)))
        mean_v = max(0.0001, Float64(get(d, "mean", 2.0)) * time_scale)
        dist = Erlang(k, mean_v / k)
        return (dist, (rng::AbstractRNG) -> rand(rng, dist), errors)
    elseif kind in ["triangular", "pert"]
        a = max(0.0001, Float64(get(d, "min", 1.0)) * time_scale)
        c = max(a, Float64(get(d, "mode", 2.0)) * time_scale)
        b = max(c + 0.0001, Float64(get(d, "max", 3.0)) * time_scale)
        dist = TriangularDist(a, b, c)
        return (dist, (rng::AbstractRNG) -> rand(rng, dist), errors)
    end

    push!(errors, "Unrecognized distribution specification: $d")
    fallback = Dirac(1.0)
    return (fallback, (rng::AbstractRNG) -> 1.0, errors)
end

function _build_sampler_from_dict(d::Dict, time_scale::Float64)
    dist_obj, sampler, errors = parse_distribution_object(d, time_scale)
    return (sampler, errors)
end
