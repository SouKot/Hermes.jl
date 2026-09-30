# packages/GodotBridge/src/compiler/logic_catalog.jl
#
# Standard Logic Catalog — named routing and discipline rules for the IR layer.
# These are parsed from SceneSpec JSON and compiled into SimDES ZoneConfig policies.

"""
Outflow routing rules — how an entity selects its next zone after service.
"""
abstract type OutflowRule end

"""Route to a single fixed downstream element (default)."""
struct FixedOutflow <: OutflowRule
    target_id::String
end

"""Probabilistic split: route to one of several targets with given weights."""
struct ProbOutflow <: OutflowRule
    targets::Vector{Tuple{String, Float64}}  # (element_id, weight) — weights need not sum to 1
end

"""Route to whichever downstream queue has the shortest current length."""
struct ShortestQueueOutflow <: OutflowRule
    candidates::Vector{String}  # element_ids of candidate queues
end

"""Round-robin across downstream queues."""
mutable struct RoundRobinOutflow <: OutflowRule
    candidates::Vector{String}
    _state::Ref{Int}
    RoundRobinOutflow(candidates) = new(candidates, Ref(0))
end

"""
Queue sorting disciplines.
"""
abstract type QueueDisciplineRule end

struct FIFODiscipline     <: QueueDisciplineRule end
struct LIFODiscipline     <: QueueDisciplineRule end
struct PriorityHOLDiscipline <: QueueDisciplineRule end
struct EarliestDueDateDiscipline <: QueueDisciplineRule end
struct SPTDiscipline      <: QueueDisciplineRule end
struct CustomComparatorDiscipline <: QueueDisciplineRule
    comparator_fn::Function
    expr_str::String
end

"""Parse a discipline string from SceneSpec JSON into a QueueDisciplineRule."""
function parse_discipline(s::Union{String,Symbol})::QueueDisciplineRule
    str = lowercase(strip(string(s)))
    if str in ("fifo", "first_in_first_out", "fcfs") return FIFODiscipline()
    elseif str in ("lifo", "last_in_first_out", "stack") return LIFODiscipline()
    elseif str in ("priority", "hol", "priority_hol") return PriorityHOLDiscipline()
    elseif str in ("edd", "earliest_due_date") return EarliestDueDateDiscipline()
    elseif str in ("spt", "shortest_processing_time") return SPTDiscipline()
    elseif str in ("custom", "comparator", "custom_comparator")
        return CustomComparatorDiscipline((a, b) -> a.arrival_time < b.arrival_time, "")
    else
        @warn "Unknown discipline '$(s)', defaulting to FIFO"
        return FIFODiscipline()
    end
end

"""Convert a QueueDisciplineRule to a SimDES.QueueDiscipline enum value."""
function to_simdes_discipline(d::QueueDisciplineRule)::SimDES.QueueDiscipline
    if d isa FIFODiscipline
        return SimDES.FIFO
    elseif d isa LIFODiscipline
        return SimDES.LIFO
    elseif d isa PriorityHOLDiscipline
        return SimDES.PRIORITY_HOL
    elseif d isa EarliestDueDateDiscipline
        return SimDES.EDD
    elseif d isa SPTDiscipline
        return SimDES.SPT
    else
        return SimDES.FIFO
    end
end

"""
    parse_discipline_expr(src::AbstractString) -> Function

Compile a user-supplied queue discipline comparator expression into a two-argument
closure `(entity_a, entity_b) -> Bool` returning `true` when `entity_a` should be
served before `entity_b`. Both `entity_a`/`entity_b` and short aliases `a`/`b`
are bound inside the expression, and all `SimCore.SimViz` helpers (`attr`, `num_attr`,
`get_attribute`, `slack`, `critical_ratio`, `wait_time`, etc.) are in scope.
"""
function parse_discipline_expr(src::AbstractString)::Function
    s = strip(String(src))
    isempty(s) && return (a, b) -> a.arrival_time < b.arrival_time
    full_src = if occursin("->", s)
        s
    else
        """
        (entity_a, entity_b) -> begin
            local a = entity_a
            local b = entity_b
            Bool($(s))
        end
        """
    end
    expr = Meta.parse(full_src)
    mod = Module()
    Core.eval(mod, :(using SimCore))
    Core.eval(mod, :(using SimCore.SimViz))
    return Core.eval(mod, expr)
end

