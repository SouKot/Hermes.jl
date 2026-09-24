# packages/GodotBridge/src/compiler/compiler_ir.jl
#
# Normalized Execution Graph Intermediate Representation (IR) for SceneSpec v1.
# Strips editor and GUI metadata, normalizing elements into strongly-typed execution nodes.

"""
    AbstractIRNode

Base type for all execution graph nodes in the intermediate representation.
"""
abstract type AbstractIRNode end

"""
    IRSourceNode <: AbstractIRNode

Source node responsible for spawning discrete entities according to an arrival process.
"""
struct IRSourceNode <: AbstractIRNode
    id::String
    entity_type::String
    arrival_sampler::Any  # (rng::AbstractRNG) -> Float64
    priority::Int
end

"""
    IRQueueNode <: AbstractIRNode

Waiting line / buffer node with capacity and discipline.
"""
struct IRQueueNode <: AbstractIRNode
    id::String
    capacity::Int
    discipline::Symbol  # :fifo, :lifo, :priority
    initial_occupancy::Int
end

"""
    IRServerNode <: AbstractIRNode

Service processing station with one or more parallel servers.
"""
struct IRServerNode <: AbstractIRNode
    id::String
    num_servers::Int
    service_dist_obj::Any  # UnivariateDistribution
    service_sampler::Any   # (rng::AbstractRNG) -> Float64
    failure_model::Symbol  # :none, :mtbf_mttr
    mtbf::Float64
    mttr::Float64
end

"""
    IRConveyorNode <: AbstractIRNode

Continuous or discrete transport conveyor with length, speed, and transit latency.
"""
struct IRConveyorNode <: AbstractIRNode
    id::String
    length::Float64
    speed::Float64
    transit_delay::Float64
    capacity::Int
end

"""
    IRSinkNode <: AbstractIRNode

Disposal node recording throughput, sojourn time, and destroying departing entities.
"""
struct IRSinkNode <: AbstractIRNode
    id::String
    record_sojourn::Bool
end

"""
    IRCrowdSpawnerNode <: AbstractIRNode

Agent-based crowd spawner injecting pedestrian agents.
"""
struct IRCrowdSpawnerNode <: AbstractIRNode
    id::String
    spawn_rate::Float64
    goal::Tuple{Float64, Float64}
end

"""
    IRHybridGateNode <: AbstractIRNode

Turnstile or physical gate synchronizing discrete tokens with agent passage.
"""
struct IRHybridGateNode <: AbstractIRNode
    id::String
    capacity::Int
    transit_delay::Float64
end

"""
    ExecutionGraphIR

Normalized intermediate representation of an authored simulation model.
Decouples graphical representation from execution structures.
"""
struct ExecutionGraphIR
    nodes::Dict{String, AbstractIRNode}
    element_to_zone::Dict{String, Int}
    zone_to_element::Dict{Int, String}
    downstream_conns::Dict{String, Vector{Tuple{String, String, String, String}}}
    spatial_positions::Dict{String, Tuple{Float64, Float64, Float64}}
    spatial_dimensions::Dict{String, Tuple{Float64, Float64, Float64}}
end

function ExecutionGraphIR()
    return ExecutionGraphIR(
        Dict{String, AbstractIRNode}(),
        Dict{String, Int}(),
        Dict{Int, String}(),
        Dict{String, Vector{Tuple{String, String, String, String}}}(),
        Dict{String, Tuple{Float64, Float64, Float64}}(),
        Dict{String, Tuple{Float64, Float64, Float64}}()
    )
end
