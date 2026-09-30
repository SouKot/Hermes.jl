"""
    simviz_helpers.jl — SimViz Helper Library & User Scripting Vocabulary (M-1)

Provides a unified, zero-allocation, Entity-centric scripting DSL (`SimCore.SimViz`)
for authoring simulation hooks, queue disciplines, multi-queue intake selectors,
conveyor kinematics, custom DEVS event state machines, and telemetry.
"""

# ── Hook Command Opcodes & Struct ────────────────────────────────────────────

@enum HookOpCode::UInt8 begin
    OP_NONE               = 0
    OP_ROUTE_TO_ZONE      = 1
    OP_ROUTE_TO_PORT      = 2
    OP_EXIT_SYSTEM        = 3
    OP_HOLD_ENTITY        = 4
    OP_RELEASE_ENTITY     = 5
    OP_PREEMPT_SERVER     = 6
    OP_CLONE_ENTITY       = 7
    OP_SET_SERVICE_TIME   = 8
    OP_ADD_SETUP_TIME     = 9
    OP_START_SERVICE      = 10
    OP_COMPLETE_SERVICE   = 11
    OP_SEIZE_CAPACITY     = 12
    OP_RELEASE_CAPACITY   = 13
    OP_SET_PROCESS_MODE   = 14
    OP_SCHEDULE_EVENT     = 15
    OP_CANCEL_EVENT       = 16
    OP_CANCEL_ALL_EVENTS  = 17
    OP_FORWARD_ENTITY     = 18
    OP_SET_CONVEYOR_MODE  = 19
    OP_SET_SPEED          = 20
    OP_SET_DISTANCE       = 21
    OP_STEP_DISTANCE      = 22
    OP_SPAWN_TO_PORT      = 23
    OP_DESTROY_ENTITY     = 24
    OP_TRIGGER_FAILURE    = 25
    OP_TRIGGER_REPAIR     = 26
    OP_FLUSH_QUEUE        = 27
end

struct HookCommand
    op        :: HookOpCode
    target_id :: Int64
    int_arg   :: Int64
    float_arg :: Float64
    float_arg2:: Float64
    sym_arg   :: Symbol
    str_arg   :: String
    any_arg   :: Any
end

HookCommand(op::HookOpCode;
            target_id::Integer = 0,
            int_arg::Integer = 0,
            float_arg::Real = 0.0,
            float_arg2::Real = 0.0,
            sym_arg::Symbol = :none,
            str_arg::String = "",
            any_arg::Any = nothing) =
    HookCommand(op, Int64(target_id), Int64(int_arg), Float64(float_arg), Float64(float_arg2), sym_arg, str_arg, any_arg)

# ── PortCandidate (Multi-Queue Pull Inspection) ──────────────────────────────

"""
    PortCandidate

Lightweight candidate record returned by `port_head_items` / `port_all_items`
and passed to `pull_from_port_where!`, `pull_from_port_argmin!`, and `pull_from_port_argmax!`.
"""
struct PortCandidate
    item        :: EntityHandle
    source      :: EntityHandle
    slot        :: Int
    queue_pos   :: Int
    entity_view :: EntityStateView
end

function Base.getproperty(c::PortCandidate, sym::Symbol)
    if sym in (:item, :source, :slot, :queue_pos, :entity_view)
        return getfield(c, sym)
    else
        return getproperty(getfield(c, :entity_view), sym)
    end
end

# ── HookContext ──────────────────────────────────────────────────────────────

"""
    HookContext

Execution context passed to lifecycle hooks (`on_entry`, `on_service_start`,
`on_service_complete`, `on_exit`, `on_event`, `on_pull`).

Provides both `self(ctx)` (the station/conveyor/resource that owns the hook)
and `item(ctx)` (the flowing entity that triggered the hook), plus direct access
to `world`, `fel`, `rng`, and buffered structural commands.
"""
mutable struct HookContext
    world            :: SimWorld
    entity_id        :: UInt64          # flowing item ID (0 if station-only event)
    zone_id          :: Int             # integer zone ID of hook owner
    element_id       :: String          # string element ID of hook owner
    t                :: Float64         # current simulated time
    rng              :: Any
    element_to_zone  :: Dict{String, Int}
    zone_to_element  :: Dict{Int, String}
    fel              :: Any             # FutureEventList or nothing
    configs          :: Any             # Dict{Int, ZoneConfig} or nothing
    event_tag        :: Symbol          # tag when fired from on_event (:none otherwise)
    event_payload    :: Any             # payload when fired from on_event
    route_override   :: Union{Nothing, Int, Symbol}
    priority_override:: Union{Nothing, Int}
    commands         :: Vector{HookCommand}
end

function HookContext(
    world::SimWorld,
    entity_id::Integer,
    zone_id::Integer,
    element_id::AbstractString,
    t::Real;
    rng::Any = nothing,
    element_to_zone::Dict{String, Int} = Dict{String, Int}(),
    zone_to_element::Dict{Int, String} = Dict{Int, String}(),
    fel::Any = nothing,
    configs::Any = nothing,
    event_tag::Symbol = :none,
    event_payload::Any = nothing
)
    return HookContext(
        world,
        UInt64(max(0, entity_id)),
        Int(zone_id),
        String(element_id),
        Float64(t),
        rng,
        element_to_zone,
        zone_to_element,
        fel,
        configs,
        event_tag,
        event_payload,
        nothing,
        nothing,
        HookCommand[]
    )
end

# Active HookContext pointer for zero-argument convenience calls inside hooks
const _ACTIVE_HOOK_CTX = Ref{Union{Nothing, HookContext}}(nothing)

@inline function current_ctx()::HookContext
    c = _ACTIVE_HOOK_CTX[]
    c === nothing && error("SimViz zero-argument helper called outside an active hook context; pass `ctx` explicitly.")
    return c
end

@inline function with_hook_context(f::Function, ctx::HookContext)
    prev = _ACTIVE_HOOK_CTX[]
    _ACTIVE_HOOK_CTX[] = ctx
    try
        return f(ctx)
    finally
        _ACTIVE_HOOK_CTX[] = prev
    end
end

# ── Extensible Helper Registry ───────────────────────────────────────────────

struct HelperFunctionMeta
    name      :: Symbol
    category  :: Symbol
    signature :: String
    summary   :: String
    example   :: String
end

Base.getproperty(m::HelperFunctionMeta, s::Symbol) =
    s === :description ? getfield(m, :summary) : getfield(m, s)
Base.propertynames(::HelperFunctionMeta, private::Bool=false) =
    (:name, :category, :signature, :summary, :description, :example)

const _SIMVIZ_HELPER_REGISTRY = Dict{Symbol, HelperFunctionMeta}()
const HELPER_CATALOG = HelperFunctionMeta[]

function register_simviz_helper!(name::Symbol, category::Symbol, signature::String, summary::String, example::String="")
    meta = HelperFunctionMeta(name, category, signature, summary, example)
    _SIMVIZ_HELPER_REGISTRY[name] = meta
    idx = findfirst(m -> m.name == name, HELPER_CATALOG)
    if idx === nothing
        push!(HELPER_CATALOG, meta)
    else
        HELPER_CATALOG[idx] = meta
    end
    return meta
end

function list_simviz_helpers(; category::Union{Nothing, Symbol}=nothing)::Vector{HelperFunctionMeta}
    vals = copy(HELPER_CATALOG)
    if category !== nothing
        filter!(m -> m.category == category, vals)
    end
    sort!(vals, by = m -> (string(m.category), string(m.name)))
    return vals
end

# ── PortDirectory Registration Helpers ───────────────────────────────────────

"""
    register_entity_handle!(world, name, kind_sym; zone_id=0, is_container=false, groups=Symbol[]) -> EntityHandle

Register a named scene entity (Server, Queue, Conveyor, Source, Sink, Resource, or Container)
in `world.port_directory` and return its `EntityHandle`.
"""
function register_entity_handle!(
    world::SimWorld,
    name::Union{AbstractString, Symbol},
    kind_sym::Symbol;
    zone_id::Int = 0,
    is_container::Bool = false,
    groups::Vector{Symbol} = Symbol[]
)::EntityHandle
    pd = world.port_directory
    sname = string(name)
    if haskey(pd.name_to_handle, sname)
        h = pd.name_to_handle[sname]
        if zone_id > 0
            pd.handle_to_zone[h] = zone_id
            pd.zone_to_handle[zone_id] = h
        end
        return h
    end
    hk = is_container ? UInt8(3) : UInt8(1)
    hid = Int32(length(pd.name_to_handle) + 1)
    h = EntityHandle(hid, hk)
    pd.name_to_handle[sname] = h
    pd.handle_to_name[h] = sname
    pd.handle_to_kind[h] = kind_sym
    if zone_id > 0
        pd.handle_to_zone[h] = zone_id
        if !haskey(pd.zone_to_handle, zone_id) || kind_sym in (:server, :conveyor, :queue)
            pd.zone_to_handle[zone_id] = h
        end
    end
    kvec = get!(pd.by_kind, kind_sym, EntityHandle[])
    h in kvec || push!(kvec, h)
    for g in groups
        gvec = get!(pd.by_group, g, EntityHandle[])
        h in gvec || push!(gvec, h)
    end
    return h
end

"""
    register_port!(world, owner_handle, port_name, direction; domain=:flow, cardinality=:multi)
"""
function register_port!(
    world::SimWorld,
    owner::EntityHandle,
    port_name::Union{String, Symbol},
    direction::Symbol;
    domain::Symbol = :flow,
    cardinality::Symbol = :multi
)
    dir = direction in (:in, :input) ? :in : :out
    pvec = get!(world.port_directory.ports, owner, PortDescriptor[])
    psym = Symbol(port_name)
    if !any(p -> p.name == psym, pvec)
        push!(pvec, PortDescriptor(psym, dir, domain, cardinality))
    end
    return nothing
end

"""
    register_port_wire!(world, src_handle, src_port, dst_handle, dst_port; wire_id="", weight=1.0)
"""
function register_port_wire!(
    world::SimWorld,
    src_handle::EntityHandle,
    src_port::Union{String, Symbol},
    dst_handle::EntityHandle,
    dst_port::Union{String, Symbol};
    wire_id::String = "",
    weight::Float64 = 1.0
)
    pd = world.port_directory
    sp = Symbol(src_port)
    dp = Symbol(dst_port)
    register_port!(world, src_handle, sp, :out)
    register_port!(world, dst_handle, dp, :in)

    out_vec = get!(pd.wires, (src_handle, sp), PortWireLink[])
    slot_out = length(out_vec) + 1
    push!(out_vec, PortWireLink(slot_out, dst_handle, dp, wire_id, weight))

    in_vec = get!(pd.wires, (dst_handle, dp), PortWireLink[])
    slot_in = length(in_vec) + 1
    push!(in_vec, PortWireLink(slot_in, src_handle, sp, wire_id, weight))
    return nothing
end

# ── Internal Handle & Zone Resolution ────────────────────────────────────────

@inline function _resolve_handle(ctx::HookContext, h::EntityHandle)::EntityHandle
    return h
end

@inline function _resolve_handle(ctx::HookContext, v::EntityStateView)::EntityHandle
    return EntityHandle(Int32(v.id), UInt8(2))
end

@inline function _resolve_handle(ctx::HookContext, c::PortCandidate)::EntityHandle
    return c.item
end

function _resolve_handle(ctx::HookContext, id::Integer)::EntityHandle
    i = Int(id)
    i <= 0 && return INVALID_HANDLE
    if haskey(ctx.world.des_agents, UInt64(i)) || haskey(ctx.world.entity_attributes, UInt64(i))
        return EntityHandle(Int32(i), UInt8(2))
    end
    pd = ctx.world.port_directory
    if haskey(pd.zone_to_handle, i)
        return pd.zone_to_handle[i]
    end
    return EntityHandle(Int32(i), UInt8(1))
end

function _resolve_handle(ctx::HookContext, name::Union{String, Symbol})::EntityHandle
    s = string(name)
    pd = ctx.world.port_directory
    if haskey(pd.name_to_handle, s)
        return pd.name_to_handle[s]
    end
    if haskey(ctx.element_to_zone, s)
        zid = ctx.element_to_zone[s]
        return register_entity_handle!(ctx.world, s, :station; zone_id=zid)
    end
    # Check if formatted like "ent_12"
    if startswith(s, "ent_")
        ni = tryparse(Int32, s[5:end])
        ni !== nothing && return EntityHandle(ni, UInt8(2))
    end
    return INVALID_HANDLE
end

function _resolve_zone_id(ctx::HookContext, h::EntityHandle)::Int
    !isvalid(h) && return 0
    if h.kind == UInt8(2)
        ag = get_des_agent(ctx.world, UInt64(h.id))
        return ag !== nothing ? ag.current_zone : 0
    end
    pd = ctx.world.port_directory
    if haskey(pd.handle_to_zone, h)
        return pd.handle_to_zone[h]
    end
    if haskey(pd.handle_to_name, h)
        nm = pd.handle_to_name[h]
        if haskey(ctx.element_to_zone, nm)
            return ctx.element_to_zone[nm]
        end
    end
    if haskey(ctx.world.zone_states, Int(h.id))
        return Int(h.id)
    end
    return 0
end

function _resolve_zone_id(ctx::HookContext, target::Union{String, Symbol})::Int
    s = string(target)
    if haskey(ctx.element_to_zone, s)
        return ctx.element_to_zone[s]
    end
    h = _resolve_handle(ctx, s)
    if isvalid(h)
        return _resolve_zone_id(ctx, h)
    end
    ni = tryparse(Int, s)
    return ni !== nothing ? ni : 0
end

_resolve_zone_id(ctx::HookContext, zid::Integer)::Int = Int(zid)

# ═════════════════════════════════════════════════════════════════════════════
# Category 1: Entity Handles, Identity, Group & Topology Selectors
# ═════════════════════════════════════════════════════════════════════════════

"""
    self([ctx]) -> EntityHandle

Return the `EntityHandle` of the entity that owns the currently executing hook
(e.g., `Server_1`, `Conveyor_1`, `Queue_1`).
"""
function self(ctx::HookContext)::EntityHandle
    pd = ctx.world.port_directory
    if !isempty(ctx.element_id) && haskey(pd.name_to_handle, ctx.element_id)
        return pd.name_to_handle[ctx.element_id]
    elseif ctx.zone_id > 0 && haskey(pd.zone_to_handle, ctx.zone_id)
        return pd.zone_to_handle[ctx.zone_id]
    elseif !isempty(ctx.element_id)
        return register_entity_handle!(ctx.world, ctx.element_id, :station; zone_id=ctx.zone_id)
    elseif ctx.zone_id > 0
        return EntityHandle(Int32(ctx.zone_id), UInt8(1))
    end
    return INVALID_HANDLE
end
self() = self(current_ctx())

const self_handle = self
self_id(ctx::HookContext)::String = !isempty(ctx.element_id) ? ctx.element_id : string("zone_", ctx.zone_id)
self_id() = self_id(current_ctx())

"""
    item([ctx]) -> EntityHandle

Return the `EntityHandle` of the flowing entity (product, customer, pallet)
that triggered the hook, or `INVALID_HANDLE` if none.
"""
@inline function item(ctx::HookContext)::EntityHandle
    ctx.entity_id == 0 && return INVALID_HANDLE
    return EntityHandle(Int32(ctx.entity_id), UInt8(2))
end
item() = item(current_ctx())

const item_handle = item
item_id(ctx::HookContext)::Int = Int(ctx.entity_id)
item_id() = item_id(current_ctx())

"""
    entity_handle([ctx,] name_or_id) -> EntityHandle

Resolve a string/symbol name or integer ID into a 64-bit `EntityHandle`.
"""
entity_handle(ctx::HookContext, target) = _resolve_handle(ctx, target)
entity_handle(target) = entity_handle(current_ctx(), target)
const entity = entity_handle

"""
    entity_name([ctx,] [h = self()]) -> String
"""
function entity_name(ctx::HookContext, target=self(ctx))::String
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return ""
    if h.kind == UInt8(2)
        return string(get_entity_attribute(ctx.world, Int(h.id), "name", string("item_", h.id)))
    end
    return get(ctx.world.port_directory.handle_to_name, h, string("entity_", h.id))
end
entity_name(target) = entity_name(current_ctx(), target)
entity_name() = entity_name(current_ctx(), self(current_ctx()))

"""
    entity_kind([ctx,] [h = self()]) -> Symbol
"""
function entity_kind(ctx::HookContext, target=self(ctx))::Symbol
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return :unknown
    if h.kind == UInt8(2)
        et = get_entity_attribute(ctx.world, Int(h.id), "entity_type", "item")
        return Symbol(lowercase(string(et)))
    elseif h.kind == UInt8(3)
        return get(ctx.world.port_directory.handle_to_kind, h, :container)
    end
    return get(ctx.world.port_directory.handle_to_kind, h, :station)
end
entity_kind(target) = entity_kind(current_ctx(), target)
entity_kind() = entity_kind(current_ctx(), self(current_ctx()))

const _EMPTY_HANDLE_VEC = EntityHandle[]

"""
    entities_of_kind([ctx,] kind::Symbol) -> Vector{EntityHandle}

Return the pre-indexed list of all entities of the given `kind`
(e.g., `:conveyor`, `:server`, `:queue`, `:source`, `:sink`, `:item`).
"""
function entities_of_kind(ctx::HookContext, kind::Union{Symbol, String})::Vector{EntityHandle}
    ksym = Symbol(lowercase(string(kind)))
    if ksym in (:item, :product, :flowing, :agent)
        res = EntityHandle[]
        sizehint!(res, length(ctx.world.des_agents))
        for uid in keys(ctx.world.des_agents)
            push!(res, EntityHandle(Int32(uid), UInt8(2)))
        end
        sort!(res, by = h -> h.id)
        return res
    end
    return get(ctx.world.port_directory.by_kind, ksym, _EMPTY_HANDLE_VEC)
end
entities_of_kind(kind::Union{Symbol, String}) = entities_of_kind(current_ctx(), kind)

"""
    entities_where([ctx,] kind::Symbol, pred::Function) -> Vector{EntityHandle}
"""
function entities_where(ctx::HookContext, kind::Union{Symbol, String}, pred::Function)::Vector{EntityHandle}
    cands = entities_of_kind(ctx, kind)
    out = EntityHandle[]
    for h in cands
        if Bool(Base.invokelatest(pred, h))
            push!(out, h)
        end
    end
    return out
end
entities_where(kind::Union{Symbol, String}, pred::Function) = entities_where(current_ctx(), kind, pred)
entities_where(pred::Function, ctx::HookContext, kind::Union{Symbol, String}) = entities_where(ctx, kind, pred)
entities_where(pred::Function, kind::Union{Symbol, String}) = entities_where(current_ctx(), kind, pred)

"""
    entities_in_group([ctx,] group::Union{Symbol, String}) -> Vector{EntityHandle}
"""
function entities_in_group(ctx::HookContext, group::Union{Symbol, String})::Vector{EntityHandle}
    return get(ctx.world.port_directory.by_group, Symbol(group), _EMPTY_HANDLE_VEC)
end
entities_in_group(group::Union{Symbol, String}) = entities_in_group(current_ctx(), group)

"""
    all_entities([ctx]) -> Vector{EntityHandle}
"""
function all_entities(ctx::HookContext)::Vector{EntityHandle}
    res = collect(values(ctx.world.port_directory.name_to_handle))
    sort!(res, by = h -> h.id)
    return res
end
all_entities() = all_entities(current_ctx())

# ═════════════════════════════════════════════════════════════════════════════
# Category 2: Strictly Directional Port Topology & Connected-Entity Selectors
# ═════════════════════════════════════════════════════════════════════════════

"""
    ports([ctx,] [owner = self()]) -> Vector{Symbol}
"""
function ports(ctx::HookContext, owner=self(ctx))::Vector{Symbol}
    h = _resolve_handle(ctx, owner)
    pdesc = get(ctx.world.port_directory.ports, h, PortDescriptor[])
    return Symbol[p.name for p in pdesc]
end
ports(owner) = ports(current_ctx(), owner)
ports() = ports(current_ctx(), self(current_ctx()))

"""
    input_ports([ctx,] [owner = self()]) -> Vector{Symbol}
"""
function input_ports(ctx::HookContext, owner=self(ctx))::Vector{Symbol}
    h = _resolve_handle(ctx, owner)
    pdesc = get(ctx.world.port_directory.ports, h, PortDescriptor[])
    return Symbol[p.name for p in pdesc if p.direction == :in]
end
input_ports(owner) = input_ports(current_ctx(), owner)
input_ports() = input_ports(current_ctx(), self(current_ctx()))

"""
    output_ports([ctx,] [owner = self()]) -> Vector{Symbol}
"""
function output_ports(ctx::HookContext, owner=self(ctx))::Vector{Symbol}
    h = _resolve_handle(ctx, owner)
    pdesc = get(ctx.world.port_directory.ports, h, PortDescriptor[])
    return Symbol[p.name for p in pdesc if p.direction == :out]
end
output_ports(owner) = output_ports(current_ctx(), owner)
output_ports() = output_ports(current_ctx(), self(current_ctx()))

"""
    has_port([ctx,] [owner = self(),] port_name) -> Bool
"""
function has_port(ctx::HookContext, owner, port_name::Union{Symbol, String})::Bool
    h = _resolve_handle(ctx, owner)
    psym = Symbol(port_name)
    pdesc = get(ctx.world.port_directory.ports, h, PortDescriptor[])
    return any(p -> p.name == psym, pdesc) || haskey(ctx.world.port_directory.wires, (h, psym))
end
has_port(ctx::HookContext, port_name::Union{Symbol, String}) = has_port(ctx, self(ctx), port_name)
has_port(owner, port_name::Union{Symbol, String}) = has_port(current_ctx(), owner, port_name)
has_port(port_name::Union{Symbol, String}) = has_port(current_ctx(), self(current_ctx()), port_name)

"""
    port_direction([ctx,] [owner = self(),] port_name) -> Symbol (:in or :out)
"""
function port_direction(ctx::HookContext, owner, port_name::Union{Symbol, String})::Symbol
    h = _resolve_handle(ctx, owner)
    psym = Symbol(port_name)
    for p in get(ctx.world.port_directory.ports, h, PortDescriptor[])
        p.name == psym && return p.direction
    end
    s = string(psym)
    return (startswith(s, "in") || endswith(s, "_in")) ? :in : :out
end
port_direction(ctx::HookContext, port_name::Union{Symbol, String}) = port_direction(ctx, self(ctx), port_name)
port_direction(owner, port_name::Union{Symbol, String}) = port_direction(current_ctx(), owner, port_name)
port_direction(port_name::Union{Symbol, String}) = port_direction(current_ctx(), self(current_ctx()), port_name)

"""
    port_domain([ctx,] [owner = self(),] port_name) -> Symbol
"""
function port_domain(ctx::HookContext, owner, port_name::Union{Symbol, String})::Symbol
    h = _resolve_handle(ctx, owner)
    psym = Symbol(port_name)
    for p in get(ctx.world.port_directory.ports, h, PortDescriptor[])
        p.name == psym && return p.domain
    end
    return :flow
end
port_domain(ctx::HookContext, port_name::Union{Symbol, String}) = port_domain(ctx, self(ctx), port_name)
port_domain(owner, port_name::Union{Symbol, String}) = port_domain(current_ctx(), owner, port_name)
port_domain(port_name::Union{Symbol, String}) = port_domain(current_ctx(), self(current_ctx()), port_name)

"""
    port_cardinality([ctx,] [owner = self(),] port_name) -> Symbol (:single or :multi)
"""
function port_cardinality(ctx::HookContext, owner, port_name::Union{Symbol, String})::Symbol
    h = _resolve_handle(ctx, owner)
    psym = Symbol(port_name)
    for p in get(ctx.world.port_directory.ports, h, PortDescriptor[])
        p.name == psym && return p.cardinality
    end
    return :multi
end
port_cardinality(ctx::HookContext, port_name::Union{Symbol, String}) = port_cardinality(ctx, self(ctx), port_name)
port_cardinality(owner, port_name::Union{Symbol, String}) = port_cardinality(current_ctx(), owner, port_name)
port_cardinality(port_name::Union{Symbol, String}) = port_cardinality(current_ctx(), self(current_ctx()), port_name)

const _EMPTY_WIRE_VEC = PortWireLink[]

@inline function _port_wires(ctx::HookContext, owner, port_name::Union{Symbol, String})::Vector{PortWireLink}
    h = _resolve_handle(ctx, owner)
    psym = Symbol(port_name)
    wires = get(ctx.world.port_directory.wires, (h, psym), nothing)
    if wires !== nothing
        return wires
    end
    # Alias fallback: :in_flow <-> :flow_in <-> :in, :out_flow <-> :flow_out <-> :out
    if psym in (:in_flow, :flow_in, :in)
        for alt in (:in_flow, :flow_in, :in)
            w = get(ctx.world.port_directory.wires, (h, alt), nothing)
            w !== nothing && return w
        end
    elseif psym in (:out_flow, :flow_out, :out)
        for alt in (:out_flow, :flow_out, :out)
            w = get(ctx.world.port_directory.wires, (h, alt), nothing)
            w !== nothing && return w
        end
    end
    return _EMPTY_WIRE_VEC
end

"""
    connection_count([ctx,] [owner = self(),] port_name) -> Int
"""
connection_count(ctx::HookContext, owner, port_name::Union{Symbol, String})::Int =
    length(_port_wires(ctx, owner, port_name))
connection_count(ctx::HookContext, port_name::Union{Symbol, String}) = connection_count(ctx, self(ctx), port_name)
connection_count(owner, port_name::Union{Symbol, String}) = connection_count(current_ctx(), owner, port_name)
connection_count(port_name::Union{Symbol, String}) = connection_count(current_ctx(), self(current_ctx()), port_name)

"""
    is_connected([ctx,] [owner = self(),] port_name) -> Bool
"""
is_connected(ctx::HookContext, owner, port_name::Union{Symbol, String})::Bool =
    connection_count(ctx, owner, port_name) > 0
is_connected(ctx::HookContext, port_name::Union{Symbol, String}) = is_connected(ctx, self(ctx), port_name)
is_connected(owner, port_name::Union{Symbol, String}) = is_connected(current_ctx(), owner, port_name)
is_connected(port_name::Union{Symbol, String}) = is_connected(current_ctx(), self(current_ctx()), port_name)

"""
    connected_ports([ctx,] [owner = self(),] port_name) -> Vector{Tuple{EntityHandle, Symbol}}
"""
function connected_ports(ctx::HookContext, owner, port_name::Union{Symbol, String})::Vector{Tuple{EntityHandle, Symbol}}
    links = _port_wires(ctx, owner, port_name)
    return Tuple{EntityHandle, Symbol}[(w.peer_handle, w.peer_port) for w in links]
end
connected_ports(ctx::HookContext, port_name::Union{Symbol, String}) = connected_ports(ctx, self(ctx), port_name)
connected_ports(owner, port_name::Union{Symbol, String}) = connected_ports(current_ctx(), owner, port_name)
connected_ports(port_name::Union{Symbol, String}) = connected_ports(current_ctx(), self(current_ctx()), port_name)

"""
    connected_entities([ctx,] [owner = self(),] port_name) -> Vector{EntityHandle}

Return all peer `EntityHandle`s wired to `port_name` on `owner` in slot order `[1..N]`.
"""
function connected_entities(ctx::HookContext, owner, port_name::Union{Symbol, String})::Vector{EntityHandle}
    links = _port_wires(ctx, owner, port_name)
    return EntityHandle[w.peer_handle for w in links]
end
connected_entities(ctx::HookContext, port_name::Union{Symbol, String}) = connected_entities(ctx, self(ctx), port_name)
connected_entities(owner, port_name::Union{Symbol, String}) = connected_entities(current_ctx(), owner, port_name)
connected_entities(port_name::Union{Symbol, String}) = connected_entities(current_ctx(), self(current_ctx()), port_name)

"""
    connected_entity([ctx,] [owner = self(),] port_name, slot::Int = 1) -> EntityHandle

Return the peer `EntityHandle` at 1-based wire slot `slot` on `port_name`, or `INVALID_HANDLE`.
"""
function connected_entity(ctx::HookContext, owner, port_name::Union{Symbol, String}, slot::Int=1)::EntityHandle
    links = _port_wires(ctx, owner, port_name)
    (slot < 1 || slot > length(links)) && return INVALID_HANDLE
    return links[slot].peer_handle
end
connected_entity(ctx::HookContext, port_name::Union{Symbol, String}, slot::Int=1) =
    connected_entity(ctx, self(ctx), port_name, slot)
connected_entity(owner, port_name::Union{Symbol, String}, slot::Int=1) =
    connected_entity(current_ctx(), owner, port_name, slot)
connected_entity(port_name::Union{Symbol, String}, slot::Int=1) =
    connected_entity(current_ctx(), self(current_ctx()), port_name, slot)

"""
    connected_entity_where([ctx,] [owner = self(),] port_name, pred::Function) -> EntityHandle
"""
function connected_entity_where(ctx::HookContext, owner, port_name::Union{Symbol, String}, pred::Function)::EntityHandle
    for w in _port_wires(ctx, owner, port_name)
        if Bool(Base.invokelatest(pred, w.peer_handle))
            return w.peer_handle
        end
    end
    return INVALID_HANDLE
end
connected_entity_where(ctx::HookContext, port_name::Union{Symbol, String}, pred::Function) =
    connected_entity_where(ctx, self(ctx), port_name, pred)
connected_entity_where(owner, port_name::Union{Symbol, String}, pred::Function) =
    connected_entity_where(current_ctx(), owner, port_name, pred)
connected_entity_where(port_name::Union{Symbol, String}, pred::Function) =
    connected_entity_where(current_ctx(), self(current_ctx()), port_name, pred)
# Julia do-block overloads (pred first)
connected_entity_where(pred::Function, ctx::HookContext, owner, port_name::Union{Symbol, String}) =
    connected_entity_where(ctx, owner, port_name, pred)
connected_entity_where(pred::Function, ctx::HookContext, port_name::Union{Symbol, String}) =
    connected_entity_where(ctx, self(ctx), port_name, pred)
connected_entity_where(pred::Function, port_name::Union{Symbol, String}) =
    connected_entity_where(current_ctx(), self(current_ctx()), port_name, pred)

"""
    connected_entities_where([ctx,] [owner = self(),] port_name, pred::Function) -> Vector{EntityHandle}
"""
function connected_entities_where(ctx::HookContext, owner, port_name::Union{Symbol, String}, pred::Function)::Vector{EntityHandle}
    res = EntityHandle[]
    for w in _port_wires(ctx, owner, port_name)
        if Bool(Base.invokelatest(pred, w.peer_handle))
            push!(res, w.peer_handle)
        end
    end
    return res
end
connected_entities_where(ctx::HookContext, port_name::Union{Symbol, String}, pred::Function) =
    connected_entities_where(ctx, self(ctx), port_name, pred)
connected_entities_where(owner, port_name::Union{Symbol, String}, pred::Function) =
    connected_entities_where(current_ctx(), owner, port_name, pred)
connected_entities_where(port_name::Union{Symbol, String}, pred::Function) =
    connected_entities_where(current_ctx(), self(current_ctx()), port_name, pred)

"""
    connected_entity_argmin([ctx,] [owner = self(),] port_name, score_fn::Function) -> EntityHandle
"""
function connected_entity_argmin(ctx::HookContext, owner, port_name::Union{Symbol, String}, score_fn::Function)::EntityHandle
    best_h = INVALID_HANDLE
    best_s = Inf
    for w in _port_wires(ctx, owner, port_name)
        s = Float64(Base.invokelatest(score_fn, w.peer_handle))
        if s < best_s
            best_s = s
            best_h = w.peer_handle
        end
    end
    return best_h
end
connected_entity_argmin(ctx::HookContext, port_name::Union{Symbol, String}, score_fn::Function) =
    connected_entity_argmin(ctx, self(ctx), port_name, score_fn)
connected_entity_argmin(owner, port_name::Union{Symbol, String}, score_fn::Function) =
    connected_entity_argmin(current_ctx(), owner, port_name, score_fn)
connected_entity_argmin(port_name::Union{Symbol, String}, score_fn::Function) =
    connected_entity_argmin(current_ctx(), self(current_ctx()), port_name, score_fn)

"""
    connected_entity_argmax([ctx,] [owner = self(),] port_name, score_fn::Function) -> EntityHandle
"""
function connected_entity_argmax(ctx::HookContext, owner, port_name::Union{Symbol, String}, score_fn::Function)::EntityHandle
    best_h = INVALID_HANDLE
    best_s = -Inf
    for w in _port_wires(ctx, owner, port_name)
        s = Float64(Base.invokelatest(score_fn, w.peer_handle))
        if s > best_s
            best_s = s
            best_h = w.peer_handle
        end
    end
    return best_h
end
connected_entity_argmax(ctx::HookContext, port_name::Union{Symbol, String}, score_fn::Function) =
    connected_entity_argmax(ctx, self(ctx), port_name, score_fn)
connected_entity_argmax(owner, port_name::Union{Symbol, String}, score_fn::Function) =
    connected_entity_argmax(current_ctx(), owner, port_name, score_fn)
connected_entity_argmax(port_name::Union{Symbol, String}, score_fn::Function) =
    connected_entity_argmax(current_ctx(), self(current_ctx()), port_name, score_fn)

"""
    upstream_entities([ctx,] [owner = self()]) -> Vector{EntityHandle}
"""
upstream_entities(ctx::HookContext, owner=self(ctx)) = connected_entities(ctx, owner, :in_flow)
upstream_entities(owner) = upstream_entities(current_ctx(), owner)
upstream_entities() = upstream_entities(current_ctx(), self(current_ctx()))

"""
    downstream_entities([ctx,] [owner = self()]) -> Vector{EntityHandle}
"""
downstream_entities(ctx::HookContext, owner=self(ctx)) = connected_entities(ctx, owner, :out_flow)
downstream_entities(owner) = downstream_entities(current_ctx(), owner)
downstream_entities() = downstream_entities(current_ctx(), self(current_ctx()))

"""
    send_signal!([ctx,] [owner = self(),] out_port, value)
"""
function send_signal!(ctx::HookContext, owner, out_port::Union{Symbol, String}, value)
    h = _resolve_handle(ctx, owner)
    zid = _resolve_zone_id(ctx, h)
    psym = Symbol(out_port)
    ctx.world.zone_signals[(zid, psym)] = value
    for w in _port_wires(ctx, h, psym)
        peer_z = _resolve_zone_id(ctx, w.peer_handle)
        ctx.world.zone_signals[(peer_z, w.peer_port)] = value
    end
    return value
end
send_signal!(ctx::HookContext, out_port::Union{Symbol, String}, value) =
    send_signal!(ctx, self(ctx), out_port, value)
send_signal!(owner::EntityHandle, out_port::Union{Symbol, String}, value) =
    send_signal!(current_ctx(), owner, out_port, value)
send_signal!(out_port::Union{Symbol, String}, value) =
    send_signal!(current_ctx(), self(current_ctx()), out_port, value)

"""
    read_signal([ctx,] [owner = self(),] in_port, default = 0.0)
"""
function read_signal(ctx::HookContext, owner, in_port::Union{Symbol, String}, default=0.0)
    h = _resolve_handle(ctx, owner)
    zid = _resolve_zone_id(ctx, h)
    psym = Symbol(in_port)
    if haskey(ctx.world.zone_signals, (zid, psym))
        return ctx.world.zone_signals[(zid, psym)]
    end
    for w in _port_wires(ctx, h, psym)
        peer_z = _resolve_zone_id(ctx, w.peer_handle)
        if haskey(ctx.world.zone_signals, (peer_z, w.peer_port))
            return ctx.world.zone_signals[(peer_z, w.peer_port)]
        end
    end
    return default
end
read_signal(ctx::HookContext, in_port::Union{Symbol, String}, default=0.0) =
    read_signal(ctx, self(ctx), in_port, default)
read_signal(owner::EntityHandle, in_port::Union{Symbol, String}, default=0.0) =
    read_signal(current_ctx(), owner, in_port, default)
read_signal(in_port::Union{Symbol, String}, default=0.0) =
    read_signal(current_ctx(), self(current_ctx()), in_port, default)

"""
    emit_port_event!([ctx,] [owner = self(),] out_event_port, payload = nothing)
"""
function emit_port_event!(ctx::HookContext, owner, out_event_port::Union{Symbol, String}, payload=nothing)
    h = _resolve_handle(ctx, owner)
    psym = Symbol(out_event_port)
    for w in _port_wires(ctx, h, psym)
        schedule_event!(ctx, w.peer_handle, w.peer_port, 0.0; payload=payload)
    end
    return nothing
end
emit_port_event!(ctx::HookContext, out_event_port::Union{Symbol, String}, payload=nothing) =
    emit_port_event!(ctx, self(ctx), out_event_port, payload)
emit_port_event!(owner::EntityHandle, out_event_port::Union{Symbol, String}, payload=nothing) =
    emit_port_event!(current_ctx(), owner, out_event_port, payload)
emit_port_event!(out_event_port::Union{Symbol, String}, payload=nothing) =
    emit_port_event!(current_ctx(), self(current_ctx()), out_event_port, payload)

# ═════════════════════════════════════════════════════════════════════════════
# Category 3: Entity Containment Hierarchy (container_entity & contained_*)
# ═════════════════════════════════════════════════════════════════════════════

"""
    container_entity([ctx,] [target = self()]) -> EntityHandle

Return the immediate container `EntityHandle` holding `target`, or `INVALID_HANDLE`
if `target` is at the top level of the scene.
- Zero-arg `container_entity()` queries the hook owner `self()`.
- `container_entity(item())` queries which station/conveyor/pallet currently holds `item()`.
"""
function container_entity(ctx::HookContext, target=self(ctx))::EntityHandle
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return INVALID_HANDLE
    # 1. Explicit containment map (pallets, carriers, subgraphs, put_inside!)
    if haskey(ctx.world.containment_parent, h)
        return ctx.world.containment_parent[h]
    end
    # 2. If flowing item, check its current station/conveyor zone
    if h.kind == UInt8(2)
        ag = get_des_agent(ctx.world, UInt64(h.id))
        if ag !== nothing && ag.current_zone > 0
            return get(ctx.world.port_directory.zone_to_handle, ag.current_zone, EntityHandle(Int32(ag.current_zone), UInt8(1)))
        end
    end
    return INVALID_HANDLE
end
container_entity(target) = container_entity(current_ctx(), target)
container_entity() = container_entity(current_ctx(), self(current_ctx()))

"""
    has_container([ctx,] [target = self()]) -> Bool
"""
has_container(ctx::HookContext, target=self(ctx))::Bool = isvalid(container_entity(ctx, target))
has_container(target) = has_container(current_ctx(), target)
has_container() = has_container(current_ctx(), self(current_ctx()))

"""
    ancestors([ctx,] [target = self()]) -> Vector{EntityHandle}

Return the chain of enclosing containers `[parent, grandparent, ...]` from innermost to outermost.
"""
function ancestors(ctx::HookContext, target=self(ctx))::Vector{EntityHandle}
    res = EntityHandle[]
    curr = container_entity(ctx, target)
    visited = Set{EntityHandle}()
    while isvalid(curr) && !(curr in visited)
        push!(res, curr)
        push!(visited, curr)
        curr = container_entity(ctx, curr)
    end
    return res
end
ancestors(target) = ancestors(current_ctx(), target)
ancestors() = ancestors(current_ctx(), self(current_ctx()))

"""
    root_container([ctx,] [target = self()]) -> EntityHandle

Walk upward through `container_entity` and return the outermost container `EntityHandle`
(or `INVALID_HANDLE` if `target` has no container).
"""
function root_container(ctx::HookContext, target=self(ctx))::EntityHandle
    chain = ancestors(ctx, target)
    return isempty(chain) ? INVALID_HANDLE : last(chain)
end
root_container(target) = root_container(current_ctx(), target)
root_container() = root_container(current_ctx(), self(current_ctx()))

"""
    contained_entities([ctx,] [holder = self()]; filter::Symbol = :all) -> Vector{EntityHandle}

Return all `EntityHandle`s currently inside `holder`.
Supported `filter` values:
- `:all` (default): all entities inside `holder` (both in-service and queued, plus explicitly `put_inside!` children)
- `:in_service`: only items currently being processed/transported on `holder`
- `:queued`: only items waiting in `holder`'s queue buffer
"""
function contained_entities(ctx::HookContext, holder=self(ctx); filter::Symbol=:all)::Vector{EntityHandle}
    h = _resolve_handle(ctx, holder)
    !isvalid(h) && return EntityHandle[]
    res = EntityHandle[]

    # 1. Explicit children from containment_children (e.g., subgraph children or pallet contents)
    if filter == :all && haskey(ctx.world.containment_children, h)
        append!(res, ctx.world.containment_children[h])
    end

    # 2. If holder corresponds to a simulation zone, gather items in that zone
    zid = _resolve_zone_id(ctx, h)
    if zid > 0 && haskey(ctx.world.zone_states, zid)
        zs = ctx.world.zone_states[zid]
        if filter in (:all, :in_service)
            in_srv = EntityHandle[]
            for (uid, ag) in ctx.world.des_agents
                if ag.current_zone == zid && ag.service_start_time < Inf
                    eh = EntityHandle(Int32(uid), UInt8(2))
                    eh in res || push!(in_srv, eh)
                end
            end
            sort!(in_srv, by = x -> x.id)
            append!(res, in_srv)
        end
        if filter in (:all, :queued)
            for uid in zs.queue
                eh = EntityHandle(Int32(uid), UInt8(2))
                eh in res || push!(res, eh)
            end
        end
    end
    return res
end
contained_entities(holder; filter::Symbol=:all) = contained_entities(current_ctx(), holder; filter=filter)
contained_entities(; filter::Symbol=:all) = contained_entities(current_ctx(), self(current_ctx()); filter=filter)

"""
    contained_count([ctx,] [holder = self()]; filter::Symbol = :all) -> Int
"""
contained_count(ctx::HookContext, holder=self(ctx); filter::Symbol=:all)::Int =
    length(contained_entities(ctx, holder; filter=filter))
contained_count(holder; filter::Symbol=:all) = contained_count(current_ctx(), holder; filter=filter)
contained_count(; filter::Symbol=:all) = contained_count(current_ctx(), self(current_ctx()); filter=filter)

"""
    contains_entity([ctx,] [holder = self(),] child) -> Bool
"""
function contains_entity(ctx::HookContext, holder, child)::Bool
    ch = _resolve_handle(ctx, child)
    !isvalid(ch) && return false
    return ch in contained_entities(ctx, holder; filter=:all)
end
contains_entity(ctx::HookContext, child) = contains_entity(ctx, self(ctx), child)
contains_entity(holder, child) = contains_entity(current_ctx(), holder, child)
contains_entity(child) = contains_entity(current_ctx(), self(current_ctx()), child)

"""
    contained_entity([ctx,] [holder = self(),] index::Int = 1; filter::Symbol = :all) -> EntityHandle
"""
function contained_entity(ctx::HookContext, holder, index::Int=1; filter::Symbol=:all)::EntityHandle
    list = contained_entities(ctx, holder; filter=filter)
    (index < 1 || index > length(list)) && return INVALID_HANDLE
    return list[index]
end
contained_entity(ctx::HookContext, index::Int=1; filter::Symbol=:all) =
    contained_entity(ctx, self(ctx), index; filter=filter)
contained_entity(holder, index::Int; filter::Symbol=:all) =
    contained_entity(current_ctx(), holder, index; filter=filter)
contained_entity(index::Int; filter::Symbol=:all) =
    contained_entity(current_ctx(), self(current_ctx()), index; filter=filter)
contained_entity(; filter::Symbol=:all) =
    contained_entity(current_ctx(), self(current_ctx()), 1; filter=filter)

"""
    first_contained([ctx,] [holder = self()]; filter::Symbol = :all) -> EntityHandle
"""
first_contained(ctx::HookContext, holder=self(ctx); filter::Symbol=:all) =
    contained_entity(ctx, holder, 1; filter=filter)
first_contained(holder; filter::Symbol=:all) = first_contained(current_ctx(), holder; filter=filter)
first_contained(; filter::Symbol=:all) = first_contained(current_ctx(), self(current_ctx()); filter=filter)

"""
    last_contained([ctx,] [holder = self()]; filter::Symbol = :all) -> EntityHandle
"""
function last_contained(ctx::HookContext, holder=self(ctx); filter::Symbol=:all)::EntityHandle
    list = contained_entities(ctx, holder; filter=filter)
    return isempty(list) ? INVALID_HANDLE : last(list)
end
last_contained(holder; filter::Symbol=:all) = last_contained(current_ctx(), holder; filter=filter)
last_contained(; filter::Symbol=:all) = last_contained(current_ctx(), self(current_ctx()); filter=filter)

"""
    contained_entity_where([ctx,] [holder = self(),] pred::Function; filter::Symbol = :all) -> EntityHandle
"""
function contained_entity_where(ctx::HookContext, holder, pred::Function; filter::Symbol=:all)::EntityHandle
    for h in contained_entities(ctx, holder; filter=filter)
        if Bool(Base.invokelatest(pred, h))
            return h
        end
    end
    return INVALID_HANDLE
end
contained_entity_where(ctx::HookContext, pred::Function; filter::Symbol=:all) =
    contained_entity_where(ctx, self(ctx), pred; filter=filter)
contained_entity_where(holder, pred::Function; filter::Symbol=:all) =
    contained_entity_where(current_ctx(), holder, pred; filter=filter)
contained_entity_where(pred::Function; filter::Symbol=:all) =
    contained_entity_where(current_ctx(), self(current_ctx()), pred; filter=filter)

"""
    contained_entities_where([ctx,] [holder = self(),] pred::Function; filter::Symbol = :all) -> Vector{EntityHandle}
"""
function contained_entities_where(ctx::HookContext, holder, pred::Function; filter::Symbol=:all)::Vector{EntityHandle}
    res = EntityHandle[]
    for h in contained_entities(ctx, holder; filter=filter)
        if Bool(Base.invokelatest(pred, h))
            push!(res, h)
        end
    end
    return res
end
contained_entities_where(ctx::HookContext, pred::Function; filter::Symbol=:all) =
    contained_entities_where(ctx, self(ctx), pred; filter=filter)
contained_entities_where(holder, pred::Function; filter::Symbol=:all) =
    contained_entities_where(current_ctx(), holder, pred; filter=filter)
contained_entities_where(pred::Function; filter::Symbol=:all) =
    contained_entities_where(current_ctx(), self(current_ctx()), pred; filter=filter)

"""
    contained_entity_argmin([ctx,] [holder = self(),] score_fn::Function; filter::Symbol = :all) -> EntityHandle
"""
function contained_entity_argmin(ctx::HookContext, holder, score_fn::Function; filter::Symbol=:all)::EntityHandle
    best_h = INVALID_HANDLE
    best_s = Inf
    for h in contained_entities(ctx, holder; filter=filter)
        s = Float64(Base.invokelatest(score_fn, h))
        if s < best_s
            best_s = s
            best_h = h
        end
    end
    return best_h
end
contained_entity_argmin(ctx::HookContext, score_fn::Function; filter::Symbol=:all) =
    contained_entity_argmin(ctx, self(ctx), score_fn; filter=filter)
contained_entity_argmin(holder, score_fn::Function; filter::Symbol=:all) =
    contained_entity_argmin(current_ctx(), holder, score_fn; filter=filter)
contained_entity_argmin(score_fn::Function; filter::Symbol=:all) =
    contained_entity_argmin(current_ctx(), self(current_ctx()), score_fn; filter=filter)

"""
    contained_entity_argmax([ctx,] [holder = self(),] score_fn::Function; filter::Symbol = :all) -> EntityHandle
"""
function contained_entity_argmax(ctx::HookContext, holder, score_fn::Function; filter::Symbol=:all)::EntityHandle
    best_h = INVALID_HANDLE
    best_s = -Inf
    for h in contained_entities(ctx, holder; filter=filter)
        s = Float64(Base.invokelatest(score_fn, h))
        if s > best_s
            best_s = s
            best_h = h
        end
    end
    return best_h
end
contained_entity_argmax(ctx::HookContext, score_fn::Function; filter::Symbol=:all) =
    contained_entity_argmax(ctx, self(ctx), score_fn; filter=filter)
contained_entity_argmax(holder, score_fn::Function; filter::Symbol=:all) =
    contained_entity_argmax(current_ctx(), holder, score_fn; filter=filter)
contained_entity_argmax(score_fn::Function; filter::Symbol=:all) =
    contained_entity_argmax(current_ctx(), self(current_ctx()), score_fn; filter=filter)

"""
    put_inside!([ctx,] container, child) -> EntityHandle

Attach `child` inside `container` (e.g., loading a part onto a pallet or vehicle).
"""
function put_inside!(ctx::HookContext, container, child)::EntityHandle
    ch_cont = _resolve_handle(ctx, container)
    ch_item = _resolve_handle(ctx, child)
    (!isvalid(ch_cont) || !isvalid(ch_item)) && return INVALID_HANDLE
    # Remove from old parent if any
    if haskey(ctx.world.containment_parent, ch_item)
        old_p = ctx.world.containment_parent[ch_item]
        if haskey(ctx.world.containment_children, old_p)
            filter!(!=(ch_item), ctx.world.containment_children[old_p])
        end
    end
    ctx.world.containment_parent[ch_item] = ch_cont
    cvec = get!(ctx.world.containment_children, ch_cont, EntityHandle[])
    ch_item in cvec || push!(cvec, ch_item)
    return ch_item
end
put_inside!(container, child) = put_inside!(current_ctx(), container, child)

"""
    take_out!([ctx,] container, [child]) -> EntityHandle

Remove `child` (or the first contained entity if omitted) from `container`.
"""
function take_out!(ctx::HookContext, container, child=nothing)::EntityHandle
    ch_cont = _resolve_handle(ctx, container)
    !isvalid(ch_cont) && return INVALID_HANDLE
    cvec = get(ctx.world.containment_children, ch_cont, nothing)
    if child === nothing
        (cvec === nothing || isempty(cvec)) && return INVALID_HANDLE
        ch_item = popfirst!(cvec)
        delete!(ctx.world.containment_parent, ch_item)
        return ch_item
    else
        ch_item = _resolve_handle(ctx, child)
        if cvec !== nothing
            filter!(!=(ch_item), cvec)
        end
        delete!(ctx.world.containment_parent, ch_item)
        return ch_item
    end
end
take_out!(container, child) = take_out!(current_ctx(), container, child)
take_out!(container) = take_out!(current_ctx(), container, nothing)

# ═════════════════════════════════════════════════════════════════════════════
# Category 4: Multi-Queue Intake / Pull Selection (:in_flow Bus [1..N])
# ═════════════════════════════════════════════════════════════════════════════

"""
    port_head_items([ctx,] [owner = self(),] in_port::Symbol = :in_flow) -> Vector{PortCandidate}

Return the head waiting item from every non-empty upstream queue connected to `in_port`.
"""
function port_head_items(ctx::HookContext, owner=self(ctx), in_port::Union{Symbol, String}=:in_flow)::Vector{PortCandidate}
    res = PortCandidate[]
    for w in _port_wires(ctx, owner, in_port)
        qzid = _resolve_zone_id(ctx, w.peer_handle)
        if qzid > 0 && haskey(ctx.world.zone_states, qzid)
            zs = ctx.world.zone_states[qzid]
            if !isempty(zs.queue)
                head_uid = first(zs.queue)
                ev = get_entity_state(ctx.world, head_uid)
                push!(res, PortCandidate(EntityHandle(Int32(head_uid), UInt8(2)), w.peer_handle, w.slot, 1, ev))
            end
        end
    end
    return res
end
port_head_items(ctx::HookContext, in_port::Union{Symbol, String}) = port_head_items(ctx, self(ctx), in_port)
port_head_items(in_port::Union{Symbol, String}=:in_flow) = port_head_items(current_ctx(), self(current_ctx()), in_port)

"""
    port_all_items([ctx,] [owner = self(),] in_port::Symbol = :in_flow) -> Vector{PortCandidate}

Return all waiting items across all upstream queues connected to `in_port`.
"""
function port_all_items(ctx::HookContext, owner=self(ctx), in_port::Union{Symbol, String}=:in_flow)::Vector{PortCandidate}
    res = PortCandidate[]
    for w in _port_wires(ctx, owner, in_port)
        qzid = _resolve_zone_id(ctx, w.peer_handle)
        if qzid > 0 && haskey(ctx.world.zone_states, qzid)
            zs = ctx.world.zone_states[qzid]
            for (qpos, uid) in enumerate(zs.queue)
                ev = get_entity_state(ctx.world, uid)
                push!(res, PortCandidate(EntityHandle(Int32(uid), UInt8(2)), w.peer_handle, w.slot, qpos, ev))
            end
        end
    end
    return res
end
port_all_items(ctx::HookContext, in_port::Union{Symbol, String}) = port_all_items(ctx, self(ctx), in_port)
port_all_items(in_port::Union{Symbol, String}=:in_flow) = port_all_items(current_ctx(), self(current_ctx()), in_port)

function _dequeue_candidate!(ctx::HookContext, cand::PortCandidate)::EntityHandle
    qzid = _resolve_zone_id(ctx, cand.source)
    qzid <= 0 && return INVALID_HANDLE
    zs = get(ctx.world.zone_states, qzid, nothing)
    zs === nothing && return INVALID_HANDLE
    uid = UInt64(cand.item.id)
    idx = findfirst(==(uid), zs.queue)
    idx === nothing && return INVALID_HANDLE
    deleteat!(zs.queue, idx)
    zs.queue_length = length(zs.queue)
    return cand.item
end

"""
    pull_from_port!([ctx,] in_port::Symbol, slot::Int) -> EntityHandle
"""
function pull_from_port!(ctx::HookContext, in_port::Union{Symbol, String}, slot::Int)::EntityHandle
    for c in port_head_items(ctx, self(ctx), in_port)
        if c.slot == slot
            return _dequeue_candidate!(ctx, c)
        end
    end
    return INVALID_HANDLE
end
pull_from_port!(in_port::Union{Symbol, String}, slot::Int) = pull_from_port!(current_ctx(), in_port, slot)

"""
    pull_from_port_slot_order!([ctx,] in_port::Symbol = :in_flow) -> EntityHandle
"""
function pull_from_port_slot_order!(ctx::HookContext, in_port::Union{Symbol, String}=:in_flow)::EntityHandle
    cands = port_head_items(ctx, self(ctx), in_port)
    isempty(cands) && return INVALID_HANDLE
    return _dequeue_candidate!(ctx, first(cands))
end
pull_from_port_slot_order!(in_port::Union{Symbol, String}=:in_flow) =
    pull_from_port_slot_order!(current_ctx(), in_port)

"""
    pull_from_port_round_robin!([ctx,] in_port::Symbol = :in_flow) -> EntityHandle
"""
function pull_from_port_round_robin!(ctx::HookContext, in_port::Union{Symbol, String}=:in_flow)::EntityHandle
    h = self(ctx)
    psym = Symbol(in_port)
    links = _port_wires(ctx, h, psym)
    n = length(links)
    n == 0 && return INVALID_HANDLE
    cursor = get(ctx.world.port_directory.round_robin_cursors, (h, psym), 0)
    for offset in 1:n
        slot_idx = mod1(cursor + offset, n)
        pulled = pull_from_port!(ctx, psym, slot_idx)
        if isvalid(pulled)
            ctx.world.port_directory.round_robin_cursors[(h, psym)] = slot_idx
            return pulled
        end
    end
    return INVALID_HANDLE
end
pull_from_port_round_robin!(in_port::Union{Symbol, String}=:in_flow) =
    pull_from_port_round_robin!(current_ctx(), in_port)

"""
    pull_from_port_longest!([ctx,] in_port::Symbol = :in_flow) -> EntityHandle
"""
function pull_from_port_longest!(ctx::HookContext, in_port::Union{Symbol, String}=:in_flow)::EntityHandle
    cands = port_head_items(ctx, self(ctx), in_port)
    isempty(cands) && return INVALID_HANDLE
    best_c = first(cands)
    best_len = -1
    for c in cands
        qlen = queue_length(ctx, c.source)
        if qlen > best_len
            best_len = qlen
            best_c = c
        end
    end
    return _dequeue_candidate!(ctx, best_c)
end
pull_from_port_longest!(in_port::Union{Symbol, String}=:in_flow) =
    pull_from_port_longest!(current_ctx(), in_port)

"""
    pull_from_port_highest_fill!([ctx,] in_port::Symbol = :in_flow) -> EntityHandle
"""
function pull_from_port_highest_fill!(ctx::HookContext, in_port::Union{Symbol, String}=:in_flow)::EntityHandle
    cands = port_head_items(ctx, self(ctx), in_port)
    isempty(cands) && return INVALID_HANDLE
    best_c = first(cands)
    best_fill = -1.0
    for c in cands
        fr = fill_ratio(ctx, c.source)
        if fr > best_fill
            best_fill = fr
            best_c = c
        end
    end
    return _dequeue_candidate!(ctx, best_c)
end
pull_from_port_highest_fill!(in_port::Union{Symbol, String}=:in_flow) =
    pull_from_port_highest_fill!(current_ctx(), in_port)

"""
    pull_from_port_where!([ctx,] in_port::Symbol, pred::Function; scope::Symbol = :heads) -> EntityHandle
"""
function pull_from_port_where!(ctx::HookContext, in_port::Union{Symbol, String}, pred::Function; scope::Symbol=:heads)::EntityHandle
    cands = scope == :all ? port_all_items(ctx, self(ctx), in_port) : port_head_items(ctx, self(ctx), in_port)
    for c in cands
        if Bool(Base.invokelatest(pred, c))
            return _dequeue_candidate!(ctx, c)
        end
    end
    return INVALID_HANDLE
end
pull_from_port_where!(in_port::Union{Symbol, String}, pred::Function; scope::Symbol=:heads) =
    pull_from_port_where!(current_ctx(), in_port, pred; scope=scope)
pull_from_port_where!(pred::Function, ctx::HookContext, in_port::Union{Symbol, String}=:in_flow; scope::Symbol=:heads) =
    pull_from_port_where!(ctx, in_port, pred; scope=scope)
pull_from_port_where!(pred::Function, in_port::Union{Symbol, String}=:in_flow; scope::Symbol=:heads) =
    pull_from_port_where!(current_ctx(), in_port, pred; scope=scope)

"""
    pull_from_port_argmin!([ctx,] in_port::Symbol, score_fn::Function; scope::Symbol = :heads) -> EntityHandle
"""
function pull_from_port_argmin!(ctx::HookContext, in_port::Union{Symbol, String}, score_fn::Function; scope::Symbol=:heads)::EntityHandle
    cands = scope == :all ? port_all_items(ctx, self(ctx), in_port) : port_head_items(ctx, self(ctx), in_port)
    isempty(cands) && return INVALID_HANDLE
    best_c = first(cands)
    best_s = Inf
    for c in cands
        s = Float64(Base.invokelatest(score_fn, c))
        if s < best_s
            best_s = s
            best_c = c
        end
    end
    return _dequeue_candidate!(ctx, best_c)
end
pull_from_port_argmin!(in_port::Union{Symbol, String}, score_fn::Function; scope::Symbol=:heads) =
    pull_from_port_argmin!(current_ctx(), in_port, score_fn; scope=scope)
pull_from_port_argmin!(score_fn::Function, ctx::HookContext, in_port::Union{Symbol, String}=:in_flow; scope::Symbol=:heads) =
    pull_from_port_argmin!(ctx, in_port, score_fn; scope=scope)
pull_from_port_argmin!(score_fn::Function, in_port::Union{Symbol, String}=:in_flow; scope::Symbol=:heads) =
    pull_from_port_argmin!(current_ctx(), in_port, score_fn; scope=scope)

"""
    pull_from_port_argmax!([ctx,] in_port::Symbol, score_fn::Function; scope::Symbol = :heads) -> EntityHandle
"""
function pull_from_port_argmax!(ctx::HookContext, in_port::Union{Symbol, String}, score_fn::Function; scope::Symbol=:heads)::EntityHandle
    cands = scope == :all ? port_all_items(ctx, self(ctx), in_port) : port_head_items(ctx, self(ctx), in_port)
    isempty(cands) && return INVALID_HANDLE
    best_c = first(cands)
    best_s = -Inf
    for c in cands
        s = Float64(Base.invokelatest(score_fn, c))
        if s > best_s
            best_s = s
            best_c = c
        end
    end
    return _dequeue_candidate!(ctx, best_c)
end
pull_from_port_argmax!(in_port::Union{Symbol, String}, score_fn::Function; scope::Symbol=:heads) =
    pull_from_port_argmax!(current_ctx(), in_port, score_fn; scope=scope)
pull_from_port_argmax!(score_fn::Function, ctx::HookContext, in_port::Union{Symbol, String}=:in_flow; scope::Symbol=:heads) =
    pull_from_port_argmax!(ctx, in_port, score_fn; scope=scope)
pull_from_port_argmax!(score_fn::Function, in_port::Union{Symbol, String}=:in_flow; scope::Symbol=:heads) =
    pull_from_port_argmax!(current_ctx(), in_port, score_fn; scope=scope)

"""
    set_intake_mode!([ctx,] [target = self(),] mode::Symbol)
"""
function set_intake_mode!(ctx::HookContext, target, mode::Symbol)
    zid = _resolve_zone_id(ctx, target)
    zid > 0 && set_zone_attribute!(ctx.world, zid, "_intake_mode", mode)
    return mode
end
set_intake_mode!(ctx::HookContext, mode::Symbol) = set_intake_mode!(ctx, self(ctx), mode)
set_intake_mode!(mode::Symbol) = set_intake_mode!(current_ctx(), self(current_ctx()), mode)

# ═════════════════════════════════════════════════════════════════════════════
# Category 5: Entity Attributes & Typed Metadata
# ═════════════════════════════════════════════════════════════════════════════

function _get_any_attr(world::SimWorld, h::EntityHandle, key::Union{Symbol, String}, default=nothing)
    !isvalid(h) && return default
    if h.kind == UInt8(2)
        return get_entity_attribute(world, Int(h.id), key, default)
    else
        # Station / conveyor / container attribute bag (keyed by negative handle id if zone_id == 0)
        zid = get(world.port_directory.handle_to_zone, h, -Int(h.id))
        return get_zone_attribute(world, zid, key, default)
    end
end

function _set_any_attr!(world::SimWorld, h::EntityHandle, key::Union{Symbol, String}, value)
    !isvalid(h) && return value
    if h.kind == UInt8(2)
        return set_entity_attribute!(world, Int(h.id), key, value)
    else
        zid = get(world.port_directory.handle_to_zone, h, -Int(h.id))
        return set_zone_attribute!(world, zid, key, value)
    end
end

"""
    attr([ctx,] [target,] key, default = nothing)

Read dynamic attribute `key` from `target`.
If `target` is omitted inside a hook, reads from `item(ctx)` if `item(ctx)` is valid and has the attribute,
falling back to `self(ctx)` (or `item(ctx)` by default for backward compatibility with entity attribute hooks).
"""
function attr(ctx::HookContext, target::Union{EntityHandle, EntityStateView, PortCandidate}, key::Union{Symbol, String}, default=nothing)
    h = _resolve_handle(ctx, target)
    return _get_any_attr(ctx.world, h, key, default)
end

function attr(ctx::HookContext, key::Union{Symbol, String}, default=nothing)
    it = item(ctx)
    if isvalid(it)
        val = _get_any_attr(ctx.world, it, key, nothing)
        val !== nothing && return val
    end
    sf = self(ctx)
    if isvalid(sf)
        val = _get_any_attr(ctx.world, sf, key, nothing)
        val !== nothing && return val
    end
    return default
end

attr(target::Union{EntityHandle, EntityStateView, PortCandidate}, key::Union{Symbol, String}, default=nothing) =
    attr(current_ctx(), target, key, default)
attr(key::Union{Symbol, String}, default=nothing) = attr(current_ctx(), key, default)

"""
    num_attr([ctx,] [target,] key, default::Real = 0.0) -> Float64
"""
function num_attr(ctx::HookContext, target::Union{EntityHandle, EntityStateView, PortCandidate}, key::Union{Symbol, String}, default::Real=0.0)::Float64
    v = attr(ctx, target, key, default)
    return v isa Real ? Float64(v) : Float64(default)
end
function num_attr(ctx::HookContext, key::Union{Symbol, String}, default::Real=0.0)::Float64
    v = attr(ctx, key, default)
    return v isa Real ? Float64(v) : Float64(default)
end
num_attr(target::Union{EntityHandle, EntityStateView, PortCandidate}, key::Union{Symbol, String}, default::Real=0.0)::Float64 =
    num_attr(current_ctx(), target, key, default)
num_attr(key::Union{Symbol, String}, default::Real=0.0)::Float64 =
    num_attr(current_ctx(), key, default)

"""
    str_attr([ctx,] [target,] key, default::AbstractString = "") -> String
"""
str_attr(ctx::HookContext, target::Union{EntityHandle, EntityStateView, PortCandidate}, key::Union{Symbol, String}, default::AbstractString="")::String =
    string(attr(ctx, target, key, default))
str_attr(ctx::HookContext, key::Union{Symbol, String}, default::AbstractString="")::String =
    string(attr(ctx, key, default))
str_attr(target::Union{EntityHandle, EntityStateView, PortCandidate}, key::Union{Symbol, String}, default::AbstractString="")::String =
    str_attr(current_ctx(), target, key, default)
str_attr(key::Union{Symbol, String}, default::AbstractString="")::String =
    str_attr(current_ctx(), key, default)

"""
    bool_attr([ctx,] [target,] key, default::Bool = false) -> Bool
"""
function bool_attr(ctx::HookContext, target::Union{EntityHandle, EntityStateView, PortCandidate}, key::Union{Symbol, String}, default::Bool=false)::Bool
    v = attr(ctx, target, key, default)
    return v isa Bool ? v : Bool(default)
end
function bool_attr(ctx::HookContext, key::Union{Symbol, String}, default::Bool=false)::Bool
    v = attr(ctx, key, default)
    return v isa Bool ? v : Bool(default)
end
bool_attr(target::Union{EntityHandle, EntityStateView, PortCandidate}, key::Union{Symbol, String}, default::Bool=false)::Bool =
    bool_attr(current_ctx(), target, key, default)
bool_attr(key::Union{Symbol, String}, default::Bool=false)::Bool =
    bool_attr(current_ctx(), key, default)

"""
    has_attr([ctx,] [target,] key) -> Bool
"""
has_attr(ctx::HookContext, target::Union{EntityHandle, EntityStateView, PortCandidate}, key::Union{Symbol, String})::Bool =
    attr(ctx, target, key, nothing) !== nothing
has_attr(ctx::HookContext, key::Union{Symbol, String})::Bool =
    attr(ctx, key, nothing) !== nothing
has_attr(target::Union{EntityHandle, EntityStateView, PortCandidate}, key::Union{Symbol, String})::Bool =
    has_attr(current_ctx(), target, key)
has_attr(key::Union{Symbol, String})::Bool =
    has_attr(current_ctx(), key)

"""
    set_attr!([ctx,] [target,] key, value)

Set attribute `key => value` on `target` (a single `EntityHandle`, a `Vector{EntityHandle}` batch,
or defaulting to `item(ctx)` / `self(ctx)` if omitted).
"""
function set_attr!(ctx::HookContext, target::EntityHandle, key::Union{Symbol, String}, value)
    return _set_any_attr!(ctx.world, target, key, value)
end
function set_attr!(ctx::HookContext, targets::AbstractVector{EntityHandle}, key::Union{Symbol, String}, value)
    for h in targets
        _set_any_attr!(ctx.world, h, key, value)
    end
    return value
end
function set_attr!(ctx::HookContext, key::Union{Symbol, String}, value)
    it = item(ctx)
    if isvalid(it)
        return _set_any_attr!(ctx.world, it, key, value)
    else
        return _set_any_attr!(ctx.world, self(ctx), key, value)
    end
end
set_attr!(target::EntityHandle, key::Union{Symbol, String}, value) = set_attr!(current_ctx(), target, key, value)
set_attr!(targets::AbstractVector{EntityHandle}, key::Union{Symbol, String}, value) = set_attr!(current_ctx(), targets, key, value)
set_attr!(key::Union{Symbol, String}, value) = set_attr!(current_ctx(), key, value)

"""
    inc_attr!([ctx,] [target,] key, delta::Real = 1)
"""
function inc_attr!(ctx::HookContext, target::EntityHandle, key::Union{Symbol, String}, delta::Real=1)
    curr = num_attr(ctx, target, key, 0.0)
     nv = (curr == round(curr) && delta isa Integer) ? Int(curr) + delta : curr + delta
    return set_attr!(ctx, target, key, nv)
end
function inc_attr!(ctx::HookContext, key::Union{Symbol, String}, delta::Real=1)
    it = item(ctx)
    target = isvalid(it) ? it : self(ctx)
    return inc_attr!(ctx, target, key, delta)
end
inc_attr!(target::EntityHandle, key::Union{Symbol, String}, delta::Real=1) = inc_attr!(current_ctx(), target, key, delta)
inc_attr!(key::Union{Symbol, String}, delta::Real=1) = inc_attr!(current_ctx(), key, delta)

"""
    delete_attr!([ctx,] [target,] key)
"""
function delete_attr!(ctx::HookContext, target::EntityHandle, key::Union{Symbol, String})
    !isvalid(target) && return nothing
    if target.kind == UInt8(2)
        bag = get(ctx.world.entity_attributes, UInt64(target.id), nothing)
        bag !== nothing && delete!(bag, string(key))
    else
        zid = get(ctx.world.port_directory.handle_to_zone, target, -Int(target.id))
        bag = get(ctx.world.zone_attributes, zid, nothing)
        bag !== nothing && delete!(bag, string(key))
    end
    return nothing
end
function delete_attr!(ctx::HookContext, key::Union{Symbol, String})
    it = item(ctx)
    return delete_attr!(ctx, isvalid(it) ? it : self(ctx), key)
end
delete_attr!(target::EntityHandle, key::Union{Symbol, String}) = delete_attr!(current_ctx(), target, key)
delete_attr!(key::Union{Symbol, String}) = delete_attr!(current_ctx(), key)

"""
    clear_attrs!([ctx,] [target])
"""
function clear_attrs!(ctx::HookContext, target::EntityHandle=item(ctx))
    !isvalid(target) && return nothing
    if target.kind == UInt8(2)
        delete!(ctx.world.entity_attributes, UInt64(target.id))
    else
        zid = get(ctx.world.port_directory.handle_to_zone, target, -Int(target.id))
        delete!(ctx.world.zone_attributes, zid)
    end
    return nothing
end
clear_attrs!(target::EntityHandle) = clear_attrs!(current_ctx(), target)
clear_attrs!() = clear_attrs!(current_ctx(), item(current_ctx()))

# Legacy I-1..I-4 & shorthand attribute aliases
const get_attr = attr
get_attribute(ctx::HookContext, key::Union{Symbol, String}, default=nothing) = attr(ctx, key, default)
get_attribute(v::EntityStateView, key::Union{Symbol, String}, default=nothing) = get_entity_attribute(v, key, default)
get_attribute(c::PortCandidate, key::Union{Symbol, String}, default=nothing) = get_entity_attribute(c.entity_view, key, default)
get_attribute(h::EntityHandle, key::Union{Symbol, String}, default=nothing) = attr(current_ctx(), h, key, default)
get_attribute(key::Union{Symbol, String}, default=nothing) = attr(current_ctx(), key, default)

set_attribute!(ctx::HookContext, key::Union{Symbol, String}, value) = set_attr!(ctx, key, value)
set_attribute!(ctx::HookContext, target::EntityHandle, key::Union{Symbol, String}, value) = set_attr!(ctx, target, key, value)
set_attribute!(key::Union{Symbol, String}, value) = set_attr!(current_ctx(), key, value)

increment_attribute!(ctx::HookContext, key::Union{Symbol, String}, delta::Real=1) = inc_attr!(ctx, key, delta)
increment_attribute!(key::Union{Symbol, String}, delta::Real=1) = inc_attr!(current_ctx(), key, delta)
has_attribute(ctx::HookContext, key::Union{Symbol, String}) = has_attr(ctx, key)
has_attribute(v::EntityStateView, key::Union{Symbol, String}) = haskey(v.attributes, string(key))
delete_attribute!(ctx::HookContext, key::Union{Symbol, String}) = delete_attr!(ctx, key)

"""
    priority([ctx,] [target = item()]) -> Int
"""
function priority(ctx::HookContext, target=item(ctx))::Int
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return 0
    ag = get_des_agent(ctx.world, UInt64(h.id))
    ag !== nothing && return ag.priority
    return Int(round(num_attr(ctx, h, "priority", 0.0)))
end
priority(target) = priority(current_ctx(), target)
priority() = priority(current_ctx(), item(current_ctx()))

"""
    set_priority!([ctx,] [target = item(),] new_priority::Int)
"""
function set_priority!(ctx::HookContext, target::EntityHandle, new_priority::Integer)
    !isvalid(target) && return Int(new_priority)
    p = Int(new_priority)
    uid = UInt64(target.id)
    set_entity_attribute!(ctx.world, uid, "priority", p)
    ag = get_des_agent(ctx.world, uid)
    if ag !== nothing
        ctx.world.des_agents[uid] = DESAgent(ag.arrival_time, ag.current_zone, p, ag.service_start_time)
    end
    if uid == ctx.entity_id
        ctx.priority_override = p
    end
    return p
end
function set_priority!(ctx::HookContext, targets::AbstractVector{EntityHandle}, new_priority::Integer)
    for h in targets
        set_priority!(ctx, h, new_priority)
    end
    return Int(new_priority)
end
set_priority!(ctx::HookContext, new_priority::Integer) = set_priority!(ctx, item(ctx), new_priority)
set_priority!(target::EntityHandle, new_priority::Integer) = set_priority!(current_ctx(), target, new_priority)
set_priority!(targets::AbstractVector{EntityHandle}, new_priority::Integer) = set_priority!(current_ctx(), targets, new_priority)
set_priority!(new_priority::Integer) = set_priority!(current_ctx(), item(current_ctx()), new_priority)

"""
    arrival_time([ctx,] [target = item()]) -> Float64
"""
function arrival_time(ctx::HookContext, target=item(ctx))::Float64
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return ctx.t
    uid = UInt64(h.id)
    ag = get_des_agent(ctx.world, uid)
    return ag !== nothing ? ag.arrival_time : get(ctx.world.entry_times, uid, ctx.t)
end
arrival_time(target) = arrival_time(current_ctx(), target)
arrival_time() = arrival_time(current_ctx(), item(current_ctx()))

"""
    wait_time([ctx,] [target = item()]) -> Float64
"""
function wait_time(ctx::HookContext, target=item(ctx))::Float64
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return 0.0
    uid = UInt64(h.id)
    ag = get_des_agent(ctx.world, uid)
    ag === nothing && return 0.0
    t_end = isfinite(ag.service_start_time) ? ag.service_start_time : ctx.t
    return max(0.0, t_end - ag.arrival_time)
end
wait_time(target) = wait_time(current_ctx(), target)
wait_time() = wait_time(current_ctx(), item(current_ctx()))

"""
    due_date([ctx,] [target = item()]) -> Float64
"""
due_date(ctx::HookContext, target=item(ctx))::Float64 = num_attr(ctx, _resolve_handle(ctx, target), "due_date", Inf)
due_date(target) = due_date(current_ctx(), target)
due_date() = due_date(current_ctx(), item(current_ctx()))

"""
    slack([ctx,] [target = item()]) -> Float64
"""
function slack(ctx::HookContext, target=item(ctx))::Float64
    h = _resolve_handle(ctx, target)
    dd = due_date(ctx, h)
    st = num_attr(ctx, h, "estimated_service", num_attr(ctx, h, "service_time", 1.0))
    return dd - ctx.t - st
end
slack(target) = slack(current_ctx(), target)
slack() = slack(current_ctx(), item(current_ctx()))

"""
    critical_ratio([ctx,] [target = item()]) -> Float64
"""
function critical_ratio(ctx::HookContext, target=item(ctx))::Float64
    h = _resolve_handle(ctx, target)
    dd = due_date(ctx, h)
    st = max(1e-6, num_attr(ctx, h, "estimated_service", num_attr(ctx, h, "service_time", 1.0)))
    return (dd - ctx.t) / st
end
critical_ratio(target) = critical_ratio(current_ctx(), target)
critical_ratio() = critical_ratio(current_ctx(), item(current_ctx()))

# ═════════════════════════════════════════════════════════════════════════════
# Category 6: Entity State & Capacity Queries
# ═════════════════════════════════════════════════════════════════════════════

"""
    queue_length([ctx,] [target = self()]) -> Int
"""
function queue_length(ctx::HookContext, target=self(ctx))::Int
    zid = _resolve_zone_id(ctx, target)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return 0
    return ctx.world.zone_states[zid].queue_length
end
queue_length(target) = queue_length(current_ctx(), target)
queue_length() = queue_length(current_ctx(), self(current_ctx()))

"""
    in_service([ctx,] [target = self()]) -> Int
"""
function in_service(ctx::HookContext, target=self(ctx))::Int
    zid = _resolve_zone_id(ctx, target)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return 0
    return ctx.world.zone_states[zid].busy_servers
end
in_service(target) = in_service(current_ctx(), target)
in_service() = in_service(current_ctx(), self(current_ctx()))

"""
    num_servers([ctx,] [target = self()]) -> Int
"""
function num_servers(ctx::HookContext, target=self(ctx))::Int
    zid = _resolve_zone_id(ctx, target)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return 0
    return ctx.world.zone_states[zid].num_servers
end
num_servers(target) = num_servers(current_ctx(), target)
num_servers() = num_servers(current_ctx(), self(current_ctx()))

"""
    capacity([ctx,] [target = self()]) -> Int
"""
function capacity(ctx::HookContext, target=self(ctx))::Int
    zid = _resolve_zone_id(ctx, target)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return 0
    return ctx.world.zone_states[zid].capacity
end
capacity(target) = capacity(current_ctx(), target)
capacity() = capacity(current_ctx(), self(current_ctx()))

"""
    free_capacity([ctx,] [target = self()]) -> Int
"""
function free_capacity(ctx::HookContext, target=self(ctx))::Int
    zid = _resolve_zone_id(ctx, target)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return 0
    zs = ctx.world.zone_states[zid]
    return max(0, zs.capacity - (zs.queue_length + zs.busy_servers))
end
free_capacity(target) = free_capacity(current_ctx(), target)
free_capacity() = free_capacity(current_ctx(), self(current_ctx()))

"""
    utilization([ctx,] [target = self()]) -> Float64
"""
function utilization(ctx::HookContext, target::Union{EntityHandle, String, Symbol, Integer}=self(ctx))::Float64
    zid = _resolve_zone_id(ctx, target)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return 0.0
    zs = ctx.world.zone_states[zid]
    zs.num_servers <= 0 && return 1.0
    return clamp(Float64(zs.busy_servers) / Float64(zs.num_servers), 0.0, 1.0)
end
utilization(target::Union{EntityHandle, String, Symbol}) = utilization(current_ctx(), target)
utilization() = utilization(current_ctx(), self(current_ctx()))

"""
    fill_ratio([ctx,] [target = self()]) -> Float64
"""
function fill_ratio(ctx::HookContext, target=self(ctx))::Float64
    zid = _resolve_zone_id(ctx, target)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return 0.0
    zs = ctx.world.zone_states[zid]
    zs.capacity <= 0 && return 1.0
    return clamp(Float64(zs.queue_length + zs.busy_servers) / Float64(zs.capacity), 0.0, 1.0)
end
fill_ratio(target) = fill_ratio(current_ctx(), target)
fill_ratio() = fill_ratio(current_ctx(), self(current_ctx()))

"""
    is_full([ctx,] [target = self()]) -> Bool
"""
is_full(ctx::HookContext, target=self(ctx))::Bool = free_capacity(ctx, target) <= 0
is_full(target) = is_full(current_ctx(), target)
is_full() = is_full(current_ctx(), self(current_ctx()))

"""
    is_empty([ctx,] [target = self()]) -> Bool
"""
function is_empty(ctx::HookContext, target=self(ctx))::Bool
    zid = _resolve_zone_id(ctx, target)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return true
    zs = ctx.world.zone_states[zid]
    return (zs.queue_length + zs.busy_servers) == 0
end
is_empty(target) = is_empty(current_ctx(), target)
is_empty() = is_empty(current_ctx(), self(current_ctx()))

"""
    is_busy([ctx,] [target = self()]) -> Bool
"""
function is_busy(ctx::HookContext, target=self(ctx))::Bool
    zid = _resolve_zone_id(ctx, target)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return false
    zs = ctx.world.zone_states[zid]
    return zs.num_servers > 0 && zs.busy_servers >= zs.num_servers
end
is_busy(target) = is_busy(current_ctx(), target)
is_busy() = is_busy(current_ctx(), self(current_ctx()))

"""
    is_down([ctx,] [target = self()]) -> Bool
"""
function is_down(ctx::HookContext, target=self(ctx))::Bool
    zid = _resolve_zone_id(ctx, target)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return false
    if haskey(ctx.world.zone_paused, zid) && ctx.world.zone_paused[zid][1]
        return true
    end
    return ctx.world.zone_states[zid].num_servers == 0
end
is_down(target) = is_down(current_ctx(), target)
is_down() = is_down(current_ctx(), self(current_ctx()))

"""
    queued_entities([ctx,] [target = self()]) -> Vector{EntityHandle}
"""
queued_entities(ctx::HookContext, target=self(ctx)) = contained_entities(ctx, target; filter=:queued)
queued_entities(target) = queued_entities(current_ctx(), target)
queued_entities() = queued_entities(current_ctx(), self(current_ctx()))

"""
    head_entity([ctx,] [target = self()]) -> EntityHandle
"""
head_entity(ctx::HookContext, target=self(ctx)) = first_contained(ctx, target; filter=:queued)
head_entity(target) = head_entity(current_ctx(), target)
head_entity() = head_entity(current_ctx(), self(current_ctx()))

"""
    tail_entity([ctx,] [target = self()]) -> EntityHandle
"""
tail_entity(ctx::HookContext, target=self(ctx)) = last_contained(ctx, target; filter=:queued)
tail_entity(target) = tail_entity(current_ctx(), target)
tail_entity() = tail_entity(current_ctx(), self(current_ctx()))

"""
    shortest_entity([ctx,] candidates) -> EntityHandle
"""
function shortest_entity(ctx::HookContext, candidates::AbstractVector)::EntityHandle
    best_h = INVALID_HANDLE
    best_q = typemax(Int)
    for c in candidates
        h = _resolve_handle(ctx, c)
        is_down(ctx, h) && continue
        q = queue_length(ctx, h) + in_service(ctx, h)
        if q < best_q
            best_q = q
            best_h = h
        end
    end
    return best_h
end
shortest_entity(candidates::AbstractVector) = shortest_entity(current_ctx(), candidates)

"""
    least_utilized_entity([ctx,] candidates) -> EntityHandle
"""
function least_utilized_entity(ctx::HookContext, candidates::AbstractVector)::EntityHandle
    best_h = INVALID_HANDLE
    best_u = Inf
    for c in candidates
        h = _resolve_handle(ctx, c)
        is_down(ctx, h) && continue
        u = utilization(ctx, h)
        if u < best_u
            best_u = u
            best_h = h
        end
    end
    return best_h
end
least_utilized_entity(candidates::AbstractVector) = least_utilized_entity(current_ctx(), candidates)

"""
    find_entity([ctx,] pred::Function, candidates) -> EntityHandle
"""
function find_entity(ctx::HookContext, pred::Function, candidates::AbstractVector)::EntityHandle
    for c in candidates
        h = _resolve_handle(ctx, c)
        if Bool(Base.invokelatest(pred, h))
            return h
        end
    end
    return INVALID_HANDLE
end
find_entity(pred::Function, candidates::AbstractVector) = find_entity(current_ctx(), pred, candidates)

"""
    filter_entities([ctx,] pred::Function, candidates) -> Vector{EntityHandle}
"""
function filter_entities(ctx::HookContext, pred::Function, candidates::AbstractVector)::Vector{EntityHandle}
    res = EntityHandle[]
    for c in candidates
        h = _resolve_handle(ctx, c)
        if Bool(Base.invokelatest(pred, h))
            push!(res, h)
        end
    end
    return res
end
filter_entities(pred::Function, candidates::AbstractVector) = filter_entities(current_ctx(), pred, candidates)

# Legacy zone_* aliases
const zone_queue_length   = queue_length
const zone_in_service     = in_service
const zone_num_servers    = num_servers
const zone_capacity       = capacity
const zone_free_capacity  = free_capacity
const zone_utilization    = utilization
const is_zone_full        = is_full
const is_zone_busy        = is_busy
const is_zone_down        = is_down
const shortest_zone       = shortest_entity
const least_utilized_zone = least_utilized_entity

# ═════════════════════════════════════════════════════════════════════════════
# Category 7: Entity Control & Dynamic Parameter Actuation
# ═════════════════════════════════════════════════════════════════════════════

"""
    set_capacity!([ctx,] [target = self(),] new_cap::Int)

Dynamically update the capacity of an entity or a batch `Vector{EntityHandle}`.
"""
function set_capacity!(ctx::HookContext, target, new_cap::Integer)
    zid = _resolve_zone_id(ctx, target)
    if zid > 0 && haskey(ctx.world.zone_states, zid)
        ctx.world.zone_states[zid].capacity = max(1, Int(new_cap))
    end
    return Int(new_cap)
end
function set_capacity!(ctx::HookContext, targets::AbstractVector{EntityHandle}, new_cap::Integer)
    for h in targets
        set_capacity!(ctx, h, new_cap)
    end
    return Int(new_cap)
end
set_capacity!(ctx::HookContext, new_cap::Integer) = set_capacity!(ctx, self(ctx), new_cap)
set_capacity!(target, new_cap::Integer) = set_capacity!(current_ctx(), target, new_cap)
set_capacity!(new_cap::Integer) = set_capacity!(current_ctx(), self(current_ctx()), new_cap)

"""
    set_servers!([ctx,] [target = self(),] new_count::Int)
"""
function set_servers!(ctx::HookContext, target, new_count::Integer)
    zid = _resolve_zone_id(ctx, target)
    if zid > 0 && haskey(ctx.world.zone_states, zid)
        ctx.world.zone_states[zid].num_servers = max(0, Int(new_count))
    end
    return Int(new_count)
end
function set_servers!(ctx::HookContext, targets::AbstractVector{EntityHandle}, new_count::Integer)
    for h in targets
        set_servers!(ctx, h, new_count)
    end
    return Int(new_count)
end
set_servers!(ctx::HookContext, new_count::Integer) = set_servers!(ctx, self(ctx), new_count)
set_servers!(target, new_count::Integer) = set_servers!(current_ctx(), target, new_count)
set_servers!(new_count::Integer) = set_servers!(current_ctx(), self(current_ctx()), new_count)

"""
    pause!([ctx,] [target = self()])

Pause an entity (or a `Vector{EntityHandle}` of entities), suspending new service starts
and stopping conveyor movement until `resume!` is called.
"""
function pause!(ctx::HookContext, target=self(ctx))
    zid = _resolve_zone_id(ctx, target)
    if zid > 0 && haskey(ctx.world.zone_states, zid)
        zs = ctx.world.zone_states[zid]
        if !haskey(ctx.world.zone_paused, zid) || !ctx.world.zone_paused[zid][1]
            ctx.world.zone_paused[zid] = (true, max(1, zs.num_servers))
            zs.num_servers = 0
        end
    end
    return nothing
end
function pause!(ctx::HookContext, targets::AbstractVector{EntityHandle})
    for h in targets
        pause!(ctx, h)
    end
    return nothing
end
pause!(target::Union{EntityHandle, String, Symbol, AbstractVector{EntityHandle}}) = pause!(current_ctx(), target)
pause!() = pause!(current_ctx(), self(current_ctx()))

"""
    resume!([ctx,] [target = self()])
"""
function resume!(ctx::HookContext, target=self(ctx))
    zid = _resolve_zone_id(ctx, target)
    if zid > 0 && haskey(ctx.world.zone_states, zid)
        zs = ctx.world.zone_states[zid]
        if haskey(ctx.world.zone_paused, zid) && ctx.world.zone_paused[zid][1]
            saved = ctx.world.zone_paused[zid][2]
            ctx.world.zone_paused[zid] = (false, saved)
            zs.num_servers = saved
        elseif zs.num_servers == 0
            zs.num_servers = 1
        end
    end
    return nothing
end
function resume!(ctx::HookContext, targets::AbstractVector{EntityHandle})
    for h in targets
        resume!(ctx, h)
    end
    return nothing
end
resume!(target::Union{EntityHandle, String, Symbol, AbstractVector{EntityHandle}}) = resume!(current_ctx(), target)
resume!() = resume!(current_ctx(), self(current_ctx()))

"""
    trigger_failure!([ctx,] [target = self(),] repair_duration::Real = 60.0)
"""
function trigger_failure!(ctx::HookContext, target, repair_duration::Real=60.0)
    zid = _resolve_zone_id(ctx, target)
    if zid > 0
        push!(ctx.commands, HookCommand(OP_TRIGGER_FAILURE; target_id=zid, float_arg=Float64(repair_duration)))
    end
    return nothing
end
trigger_failure!(ctx::HookContext, repair_duration::Real=60.0) = trigger_failure!(ctx, self(ctx), repair_duration)
trigger_failure!(target, repair_duration::Real) = trigger_failure!(current_ctx(), target, repair_duration)
trigger_failure!(repair_duration::Real=60.0) = trigger_failure!(current_ctx(), self(current_ctx()), repair_duration)

"""
    trigger_repair!([ctx,] [target = self()])
"""
function trigger_repair!(ctx::HookContext, target=self(ctx))
    zid = _resolve_zone_id(ctx, target)
    if zid > 0
        push!(ctx.commands, HookCommand(OP_TRIGGER_REPAIR; target_id=zid))
    end
    return nothing
end
trigger_repair!(target) = trigger_repair!(current_ctx(), target)
trigger_repair!() = trigger_repair!(current_ctx(), self(current_ctx()))

"""
    flush_queue!([ctx,] [target = self()]; destination = :exit) -> Int
"""
function flush_queue!(ctx::HookContext, target=self(ctx); destination=:exit)::Int
    zid = _resolve_zone_id(ctx, target)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return 0
    zs = ctx.world.zone_states[zid]
    n = length(zs.queue)
    dest_zid = destination === :exit ? -1 : _resolve_zone_id(ctx, destination)
    push!(ctx.commands, HookCommand(OP_FLUSH_QUEUE; target_id=zid, int_arg=dest_zid))
    return n
end
flush_queue!(target; destination=:exit) = flush_queue!(current_ctx(), target; destination=destination)
flush_queue!(; destination=:exit) = flush_queue!(current_ctx(), self(current_ctx()); destination=destination)

# Legacy zone_* control aliases
const set_zone_capacity! = set_capacity!
const set_zone_servers!  = set_servers!
const pause_zone!        = pause!
const resume_zone!       = resume!

# ═════════════════════════════════════════════════════════════════════════════
# Category 8: Routing & Flow Control
# ═════════════════════════════════════════════════════════════════════════════

"""
    route_to!([ctx,] target)

Override the next destination of the current flowing entity (`item(ctx)`) upon departure.
`target` may be an `EntityHandle`, element ID string/symbol, `:exit`, or integer zone ID.
"""
function route_to!(ctx::HookContext, target)
    if target === :exit || target === "exit"
        ctx.route_override = :exit
        ctx.entity_id > 0 && (ctx.world.entity_route_overrides[ctx.entity_id] = -1)
        return :exit
    end
    zid = _resolve_zone_id(ctx, target)
    if zid > 0
        ctx.route_override = zid
        ctx.entity_id > 0 && (ctx.world.entity_route_overrides[ctx.entity_id] = zid)
    end
    return zid
end
route_to!(target) = route_to!(current_ctx(), target)

"""
    route_to_port!([ctx,] out_port::Symbol = :out_flow; slot::Int = 1)
"""
function route_to_port!(ctx::HookContext, out_port::Union{Symbol, String}=:out_flow; slot::Int=1)
    peer = connected_entity(ctx, self(ctx), out_port, slot)
    if isvalid(peer)
        return route_to!(ctx, peer)
    end
    return 0
end
route_to_port!(out_port::Union{Symbol, String}=:out_flow; slot::Int=1) =
    route_to_port!(current_ctx(), out_port; slot=slot)

"""
    route_to_shortest!([ctx,] candidates = connected_entities(ctx, :out_flow))
"""
function route_to_shortest!(ctx::HookContext, candidates=connected_entities(ctx, :out_flow))
    best = shortest_entity(ctx, candidates)
    isvalid(best) && return route_to!(ctx, best)
    return 0
end
route_to_shortest!(candidates) = route_to_shortest!(current_ctx(), candidates)
route_to_shortest!() = route_to_shortest!(current_ctx(), connected_entities(current_ctx(), :out_flow))

"""
    route_to_fastest!([ctx,] candidates = connected_entities(ctx, :out_flow))
"""
function route_to_fastest!(ctx::HookContext, candidates=connected_entities(ctx, :out_flow))
    best = least_utilized_entity(ctx, candidates)
    isvalid(best) && return route_to!(ctx, best)
    return 0
end
route_to_fastest!(candidates) = route_to_fastest!(current_ctx(), candidates)
route_to_fastest!() = route_to_fastest!(current_ctx(), connected_entities(current_ctx(), :out_flow))

"""
    exit_system!([ctx])
"""
exit_system!(ctx::HookContext) = route_to!(ctx, :exit)
exit_system!() = exit_system!(current_ctx())

"""
    hold_entity!([ctx,] [target = item()])
"""
function hold_entity!(ctx::HookContext, target=item(ctx))
    h = _resolve_handle(ctx, target)
    isvalid(h) && push!(ctx.commands, HookCommand(OP_HOLD_ENTITY; target_id=Int64(h.id), int_arg=ctx.zone_id))
    return h
end
hold_entity!(target) = hold_entity!(current_ctx(), target)
hold_entity!() = hold_entity!(current_ctx(), item(current_ctx()))

"""
    release_entity!([ctx,] target, [destination])
"""
function release_entity!(ctx::HookContext, target, destination=nothing)
    h = _resolve_handle(ctx, target)
    dest_z = destination === nothing ? 0 : _resolve_zone_id(ctx, destination)
    isvalid(h) && push!(ctx.commands, HookCommand(OP_RELEASE_ENTITY; target_id=Int64(h.id), int_arg=dest_z))
    return h
end
release_entity!(target, destination=nothing) = release_entity!(current_ctx(), target, destination)

"""
    preempt_server!([ctx,] [station = self()])
"""
function preempt_server!(ctx::HookContext, station=self(ctx))
    zid = _resolve_zone_id(ctx, station)
    zid > 0 && push!(ctx.commands, HookCommand(OP_PREEMPT_SERVER; target_id=zid, int_arg=Int64(ctx.entity_id)))
    return nothing
end
preempt_server!(station) = preempt_server!(current_ctx(), station)
preempt_server!() = preempt_server!(current_ctx(), self(current_ctx()))

"""
    clone_entity!([ctx,] destination; copy_attrs::Bool = true) -> EntityHandle
"""
function clone_entity!(ctx::HookContext, destination; copy_attrs::Bool=true)::EntityHandle
    new_uid = new_entity_id!(ctx.world)
    if copy_attrs && ctx.entity_id > 0
        src_attrs = get_entity_attributes(ctx.world, ctx.entity_id; create=false)
        if !isempty(src_attrs)
            dst_attrs = get_entity_attributes(ctx.world, new_uid; create=true)
            merge!(dst_attrs, src_attrs)
        end
        src_vis = get_entity_visuals(ctx.world, ctx.entity_id; create=false)
        if !isempty(src_vis)
            dst_vis = get_entity_visuals(ctx.world, new_uid; create=true)
            merge!(dst_vis, src_vis)
        end
    end
    ctx.world.entry_times[new_uid] = ctx.t
    dest_z = _resolve_zone_id(ctx, destination)
    if dest_z > 0
        push!(ctx.commands, HookCommand(OP_CLONE_ENTITY; target_id=Int64(new_uid), int_arg=dest_z))
    end
    return EntityHandle(Int32(new_uid), UInt8(2))
end
clone_entity!(destination; copy_attrs::Bool=true) = clone_entity!(current_ctx(), destination; copy_attrs=copy_attrs)

"""
    batch_entities!([ctx,] count::Int; batch_type::Symbol = :pallet) -> EntityHandle
"""
function batch_entities!(ctx::HookContext, count::Int; batch_type::Symbol=:pallet)::EntityHandle
    zid = ctx.zone_id
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return INVALID_HANDLE
    zs = ctx.world.zone_states[zid]
    length(zs.queue) < count && return INVALID_HANDLE
    members = EntityHandle[]
    for _ in 1:count
        uid = popfirst!(zs.queue)
        push!(members, EntityHandle(Int32(uid), UInt8(2)))
    end
    zs.queue_length = length(zs.queue)
    return combine_entities!(ctx, members; new_type=batch_type)
end
batch_entities!(count::Int; batch_type::Symbol=:pallet) = batch_entities!(current_ctx(), count; batch_type=batch_type)

"""
    unbatch_entity!([ctx,] [batch = item()]) -> Vector{EntityHandle}
"""
function unbatch_entity!(ctx::HookContext, batch=item(ctx))::Vector{EntityHandle}
    bh = _resolve_handle(ctx, batch)
    children = copy(get(ctx.world.containment_children, bh, EntityHandle[]))
    for ch in children
        take_out!(ctx, bh, ch)
    end
    return children
end
unbatch_entity!(batch) = unbatch_entity!(current_ctx(), batch)
unbatch_entity!() = unbatch_entity!(current_ctx(), item(current_ctx()))

# ═════════════════════════════════════════════════════════════════════════════
# Category 9: Custom Server Construction
# ═════════════════════════════════════════════════════════════════════════════

"""
    set_service_time!([ctx,] duration::Real)
"""
function set_service_time!(ctx::HookContext, duration::Real)
    d = max(0.0001, Float64(duration))
    ctx.world.zone_service_override[(ctx.zone_id, ctx.entity_id)] = d
    push!(ctx.commands, HookCommand(OP_SET_SERVICE_TIME; target_id=Int64(ctx.entity_id), int_arg=ctx.zone_id, float_arg=d))
    return d
end
set_service_time!(duration::Real) = set_service_time!(current_ctx(), duration)

"""
    add_setup_time!([ctx,] extra_delay::Real)
"""
function add_setup_time!(ctx::HookContext, extra_delay::Real)
    d = max(0.0, Float64(extra_delay))
    prev = get(ctx.world.zone_setup_time, (ctx.zone_id, ctx.entity_id), 0.0)
    ctx.world.zone_setup_time[(ctx.zone_id, ctx.entity_id)] = prev + d
    push!(ctx.commands, HookCommand(OP_ADD_SETUP_TIME; target_id=Int64(ctx.entity_id), int_arg=ctx.zone_id, float_arg=d))
    return prev + d
end
add_setup_time!(extra_delay::Real) = add_setup_time!(current_ctx(), extra_delay)

"""
    start_service!([ctx,] item_h::EntityHandle, duration::Real)
"""
function start_service!(ctx::HookContext, item_h::EntityHandle, duration::Real)
    !isvalid(item_h) && return INVALID_HANDLE
    d = max(0.0001, Float64(duration))
    push!(ctx.commands, HookCommand(OP_START_SERVICE; target_id=Int64(item_h.id), int_arg=ctx.zone_id, float_arg=d))
    return item_h
end
start_service!(item_h::EntityHandle, duration::Real) = start_service!(current_ctx(), item_h, duration)

"""
    complete_service!([ctx,] [item_h = item()])
"""
function complete_service!(ctx::HookContext, item_h::EntityHandle=item(ctx))
    !isvalid(item_h) && return INVALID_HANDLE
    push!(ctx.commands, HookCommand(OP_COMPLETE_SERVICE; target_id=Int64(item_h.id), int_arg=ctx.zone_id))
    return item_h
end
complete_service!(item_h::EntityHandle) = complete_service!(current_ctx(), item_h)
complete_service!() = complete_service!(current_ctx(), item(current_ctx()))

"""
    seize_capacity!([ctx,] [station = self(),] units::Int = 1) -> Bool
"""
function seize_capacity!(ctx::HookContext, station=self(ctx), units::Int=1)::Bool
    zid = _resolve_zone_id(ctx, station)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return false
    zs = ctx.world.zone_states[zid]
    if zs.busy_servers + units <= zs.num_servers
        zs.busy_servers += units
        return true
    end
    return false
end
seize_capacity!(ctx::HookContext, units::Int) = seize_capacity!(ctx, self(ctx), units)
seize_capacity!(units::Int=1) = seize_capacity!(current_ctx(), self(current_ctx()), units)

"""
    release_capacity!([ctx,] [station = self(),] units::Int = 1)
"""
function release_capacity!(ctx::HookContext, station=self(ctx), units::Int=1)
    zid = _resolve_zone_id(ctx, station)
    if zid > 0 && haskey(ctx.world.zone_states, zid)
        zs = ctx.world.zone_states[zid]
        zs.busy_servers = max(0, zs.busy_servers - units)
    end
    return nothing
end
release_capacity!(ctx::HookContext, units::Int) = release_capacity!(ctx, self(ctx), units)
release_capacity!(units::Int=1) = release_capacity!(current_ctx(), self(current_ctx()), units)

"""
    dequeue_where!([ctx,] [queue = self(),] pred::Function) -> EntityHandle
"""
function dequeue_where!(ctx::HookContext, queue, pred::Function)::EntityHandle
    zid = _resolve_zone_id(ctx, queue)
    (zid <= 0 || !haskey(ctx.world.zone_states, zid)) && return INVALID_HANDLE
    zs = ctx.world.zone_states[zid]
    for (idx, uid) in enumerate(zs.queue)
        ev = get_entity_state(ctx.world, uid)
        if Bool(Base.invokelatest(pred, ev))
            deleteat!(zs.queue, idx)
            zs.queue_length = length(zs.queue)
            return EntityHandle(Int32(uid), UInt8(2))
        end
    end
    return INVALID_HANDLE
end
dequeue_where!(ctx::HookContext, pred::Function) = dequeue_where!(ctx, self(ctx), pred)
dequeue_where!(queue, pred::Function) = dequeue_where!(current_ctx(), queue, pred)
dequeue_where!(pred::Function) = dequeue_where!(current_ctx(), self(current_ctx()), pred)

"""
    last_processed_attr([ctx,] [station = self(),] key, default = nothing)
"""
function last_processed_attr(ctx::HookContext, station, key::Union{Symbol, String}, default=nothing)
    zid = _resolve_zone_id(ctx, station)
    bag = get(ctx.world.last_processed_attrs, zid, nothing)
    bag === nothing && return default
    return get(bag, string(key), default)
end
last_processed_attr(ctx::HookContext, key::Union{Symbol, String}, default=nothing) =
    last_processed_attr(ctx, self(ctx), key, default)
last_processed_attr(key::Union{Symbol, String}, default=nothing) =
    last_processed_attr(current_ctx(), self(current_ctx()), key, default)

# ═════════════════════════════════════════════════════════════════════════════
# Category 10: Low-Level DEVS Event Scheduling & Custom Block Engine
# ═════════════════════════════════════════════════════════════════════════════

"""
    set_process_mode!([ctx,] [target = self(),] mode::Symbol)

Set `:standard` (default DES server/queue/conveyor physics) or `:custom`
(suppresses automatic service/exit scheduling so user hooks control the FEL directly).
"""
function set_process_mode!(ctx::HookContext, target, mode::Symbol)
    zid = _resolve_zone_id(ctx, target)
    zid > 0 && set_zone_attribute!(ctx.world, zid, "_process_mode", mode)
    return mode
end
set_process_mode!(ctx::HookContext, mode::Symbol) = set_process_mode!(ctx, self(ctx), mode)
set_process_mode!(mode::Symbol) = set_process_mode!(current_ctx(), self(current_ctx()), mode)

"""
    schedule_event!([ctx,] [owner = self(),] tag::Symbol, delay::Real; payload = nothing, interval::Real = 0.0, callback = nothing) -> UInt64
"""
function schedule_event!(
    ctx::HookContext,
    owner,
    tag::Symbol,
    delay::Real;
    payload::Any = nothing,
    interval::Real = 0.0,
    callback::Union{Nothing, Function} = nothing
)::UInt64
    h = _resolve_handle(ctx, owner)
    zid = _resolve_zone_id(ctx, h)
    ename = entity_name(ctx, h)
    t_fire = ctx.t + max(0.0, Float64(delay))
    ev = CustomUserEvent(zid, ename, tag, t_fire, payload, Float64(interval), callback)
    if ctx.fel !== nothing
        cev = CancellableEvent(ev, t_fire)
        enqueue!(ctx.fel.queue, cev => t_fire)
        evs = get!(ctx.world.active_user_events, zid, Set{UInt64}())
        push!(evs, cev.id)
        return cev.id
    else
        push!(ctx.commands, HookCommand(OP_SCHEDULE_EVENT; target_id=zid, float_arg=Float64(delay), float_arg2=Float64(interval), sym_arg=tag, str_arg=ename, any_arg=(payload, callback)))
        return UInt64(0)
    end
end
schedule_event!(ctx::HookContext, tag::Symbol, delay::Real; payload::Any=nothing, interval::Real=0.0, callback::Union{Nothing, Function}=nothing) =
    schedule_event!(ctx, self(ctx), tag, delay; payload=payload, interval=interval, callback=callback)
schedule_event!(owner, tag::Symbol, delay::Real; payload::Any=nothing, interval::Real=0.0, callback::Union{Nothing, Function}=nothing) =
    schedule_event!(current_ctx(), owner, tag, delay; payload=payload, interval=interval, callback=callback)
schedule_event!(tag::Symbol, delay::Real; payload::Any=nothing, interval::Real=0.0, callback::Union{Nothing, Function}=nothing) =
    schedule_event!(current_ctx(), self(current_ctx()), tag, delay; payload=payload, interval=interval, callback=callback)
schedule_event!(ctx::HookContext, owner, delay::Real, tag::Symbol; payload::Any=nothing, interval::Real=0.0, callback::Union{Nothing, Function}=nothing) =
    schedule_event!(ctx, owner, tag, delay; payload=payload, interval=interval, callback=callback)
schedule_event!(ctx::HookContext, delay::Real, tag::Symbol; payload::Any=nothing, interval::Real=0.0, callback::Union{Nothing, Function}=nothing) =
    schedule_event!(ctx, self(ctx), tag, delay; payload=payload, interval=interval, callback=callback)
schedule_event!(owner, delay::Real, tag::Symbol; payload::Any=nothing, interval::Real=0.0, callback::Union{Nothing, Function}=nothing) =
    schedule_event!(current_ctx(), owner, tag, delay; payload=payload, interval=interval, callback=callback)
schedule_event!(delay::Real, tag::Symbol; payload::Any=nothing, interval::Real=0.0, callback::Union{Nothing, Function}=nothing) =
    schedule_event!(current_ctx(), self(current_ctx()), tag, delay; payload=payload, interval=interval, callback=callback)

"""
    schedule_at!([ctx,] [owner = self(),] tag::Symbol, abs_time::Real; payload = nothing) -> UInt64
"""
schedule_at!(ctx::HookContext, owner, tag::Symbol, abs_time::Real; payload::Any=nothing) =
    schedule_event!(ctx, owner, tag, max(0.0, Float64(abs_time) - ctx.t); payload=payload)
schedule_at!(ctx::HookContext, tag::Symbol, abs_time::Real; payload::Any=nothing) =
    schedule_at!(ctx, self(ctx), tag, abs_time; payload=payload)
schedule_at!(tag::Symbol, abs_time::Real; payload::Any=nothing) =
    schedule_at!(current_ctx(), self(current_ctx()), tag, abs_time; payload=payload)

"""
    schedule_every!([ctx,] [owner = self(),] tag::Symbol, interval::Real; first_delay::Real = interval, payload = nothing) -> UInt64
"""
schedule_every!(ctx::HookContext, owner, tag::Symbol, interval::Real; first_delay::Real=interval, payload::Any=nothing) =
    schedule_event!(ctx, owner, tag, first_delay; payload=payload, interval=interval)
schedule_every!(ctx::HookContext, tag::Symbol, interval::Real; first_delay::Real=interval, payload::Any=nothing) =
    schedule_every!(ctx, self(ctx), tag, interval; first_delay=first_delay, payload=payload)
schedule_every!(tag::Symbol, interval::Real; first_delay::Real=interval, payload::Any=nothing) =
    schedule_every!(current_ctx(), self(current_ctx()), tag, interval; first_delay=first_delay, payload=payload)

"""
    after!(fn::Function, [ctx,] delay::Real) -> UInt64
"""
after!(fn::Function, ctx::HookContext, delay::Real) =
    schedule_event!(ctx, self(ctx), :after_callback, delay; callback=fn)
after!(fn::Function, delay::Real) =
    after!(fn, current_ctx(), delay)

"""
    cancel_event!([ctx,] event_id::Integer)
"""
function cancel_event!(ctx::HookContext, event_id::Integer)
    eid = UInt64(event_id)
    eid == 0 && return nothing
    if ctx.fel !== nothing
        push!(ctx.fel.cancelled, eid)
    else
        push!(ctx.commands, HookCommand(OP_CANCEL_EVENT; target_id=Int64(eid)))
    end
    return nothing
end
cancel_event!(event_id::Integer) = cancel_event!(current_ctx(), event_id)

"""
    cancel_all_events!([ctx,] [owner = self()])
"""
function cancel_all_events!(ctx::HookContext, owner=self(ctx))
    zid = _resolve_zone_id(ctx, owner)
    evs = get(ctx.world.active_user_events, zid, nothing)
    if evs !== nothing
        for eid in evs
            cancel_event!(ctx, eid)
        end
        empty!(evs)
    end
    return nothing
end
cancel_all_events!(owner) = cancel_all_events!(current_ctx(), owner)
cancel_all_events!() = cancel_all_events!(current_ctx(), self(current_ctx()))

"""
    event_tag([ctx]) -> Symbol
"""
event_tag(ctx::HookContext)::Symbol = ctx.event_tag
event_tag() = event_tag(current_ctx())

"""
    event_payload([ctx]) -> Any
"""
event_payload(ctx::HookContext) = ctx.event_payload
event_payload() = event_payload(current_ctx())

"""
    forward_entity!([ctx,] item_h::EntityHandle, out_port::Symbol = :out_flow; slot::Int = 1, delay::Real = 0.0)
"""
function forward_entity!(ctx::HookContext, item_h::EntityHandle, out_port::Union{Symbol, String}=:out_flow; slot::Int=1, delay::Real=0.0)
    !isvalid(item_h) && return INVALID_HANDLE
    peer = connected_entity(ctx, self(ctx), out_port, slot)
    dest_z = isvalid(peer) ? _resolve_zone_id(ctx, peer) : -1
    push!(ctx.commands, HookCommand(OP_FORWARD_ENTITY; target_id=Int64(item_h.id), int_arg=dest_z, float_arg=Float64(delay)))
    return item_h
end
forward_entity!(item_h::EntityHandle, out_port::Union{Symbol, String}=:out_flow; slot::Int=1, delay::Real=0.0) =
    forward_entity!(current_ctx(), item_h, out_port; slot=slot, delay=delay)

# ═════════════════════════════════════════════════════════════════════════════
# Category 11: Spatial, Conveyor & Vehicle Kinematics
# ═════════════════════════════════════════════════════════════════════════════

"""
    set_conveyor_mode!([ctx,] [conv = self(),] mode::Symbol; pitch::Real = 0.5, index_interval::Real = 1.0)

Configure conveyor kinematics mode (`:free_flow`, `:accumulating`, or `:indexing`) on a single
conveyor or a `Vector{EntityHandle}` of conveyors.
"""
function set_conveyor_mode!(ctx::HookContext, conv, mode::Symbol; pitch::Real=0.5, index_interval::Real=1.0)
    zid = _resolve_zone_id(ctx, conv)
    if zid > 0
        set_zone_attribute!(ctx.world, zid, "_conveyor_mode", mode)
        set_zone_attribute!(ctx.world, zid, "_conveyor_pitch", Float64(pitch))
        set_zone_attribute!(ctx.world, zid, "_conveyor_index_interval", Float64(index_interval))
        push!(ctx.commands, HookCommand(OP_SET_CONVEYOR_MODE; target_id=zid, float_arg=Float64(pitch), float_arg2=Float64(index_interval), sym_arg=mode))
    end
    return mode
end
function set_conveyor_mode!(ctx::HookContext, convs::AbstractVector{EntityHandle}, mode::Symbol; pitch::Real=0.5, index_interval::Real=1.0)
    for c in convs
        set_conveyor_mode!(ctx, c, mode; pitch=pitch, index_interval=index_interval)
    end
    return mode
end
set_conveyor_mode!(ctx::HookContext, mode::Symbol; pitch::Real=0.5, index_interval::Real=1.0) =
    set_conveyor_mode!(ctx, self(ctx), mode; pitch=pitch, index_interval=index_interval)
set_conveyor_mode!(conv, mode::Symbol; pitch::Real=0.5, index_interval::Real=1.0) =
    set_conveyor_mode!(current_ctx(), conv, mode; pitch=pitch, index_interval=index_interval)
set_conveyor_mode!(mode::Symbol; pitch::Real=0.5, index_interval::Real=1.0) =
    set_conveyor_mode!(current_ctx(), self(current_ctx()), mode; pitch=pitch, index_interval=index_interval)

"""
    path_length([ctx,] [target = self()]) -> Float64
"""
function path_length(ctx::HookContext, target=self(ctx))::Float64
    zid = _resolve_zone_id(ctx, target)
    return Float64(get_zone_attribute(ctx.world, zid, "_path_length", 5.0))
end
path_length(target) = path_length(current_ctx(), target)
path_length() = path_length(current_ctx(), self(current_ctx()))

"""
    distance([ctx,] [target = item()]) -> Float64

Return the current distance `[m]` traveled along the conveyor/path by `target`.
"""
function distance(ctx::HookContext, target=item(ctx))::Float64
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return 0.0
    uid = UInt64(h.id)
    k = get(ctx.world.entity_kinematics, uid, nothing)
    if k !== nothing
        return kinematics_distance(k, ctx.t)
    end
    ag = get_des_agent(ctx.world, uid)
    if ag !== nothing && isfinite(ag.service_start_time)
        spd = Float64(get_zone_attribute(ctx.world, ag.current_zone, "_nominal_speed", 1.5))
        len = Float64(get_zone_attribute(ctx.world, ag.current_zone, "_path_length", 5.0))
        return clamp((ctx.t - ag.service_start_time) * spd, 0.0, len)
    end
    return 0.0
end
distance(target) = distance(current_ctx(), target)
distance() = distance(current_ctx(), item(current_ctx()))

"""
    progress([ctx,] [target = item()]) -> Float64

Return normalized progress `s in [0.0, 1.0]` along the current conveyor/path.
"""
function progress(ctx::HookContext, target=item(ctx))::Float64
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return 0.0
    uid = UInt64(h.id)
    k = get(ctx.world.entity_kinematics, uid, nothing)
    if k !== nothing
        return kinematics_progress(k, ctx.t)
    end
    ag = get_des_agent(ctx.world, uid)
    if ag !== nothing && isfinite(ag.service_start_time)
        len = max(0.001, Float64(get_zone_attribute(ctx.world, ag.current_zone, "_path_length", 5.0)))
        return clamp(distance(ctx, h) / len, 0.0, 1.0)
    end
    return 0.0
end
progress(target) = progress(current_ctx(), target)
progress() = progress(current_ctx(), item(current_ctx()))

"""
    speed([ctx,] [target = self()]) -> Float64
"""
function speed(ctx::HookContext, target=self(ctx))::Float64
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return 0.0
    if h.kind == UInt8(2)
        k = get(ctx.world.entity_kinematics, UInt64(h.id), nothing)
        return k !== nothing ? k.current_speed : 0.0
    else
        zid = _resolve_zone_id(ctx, h)
        return Float64(get_zone_attribute(ctx.world, zid, "_nominal_speed", 1.5))
    end
end
speed(target) = speed(current_ctx(), target)
speed() = speed(current_ctx(), self(current_ctx()))

"""
    set_speed!([ctx,] [target = self(),] new_speed::Real)

Set the speed `[m/s]` of a conveyor, a flowing item, or a `Vector{EntityHandle}` of conveyors/items!
"""
function set_speed!(ctx::HookContext, target::EntityHandle, new_speed::Real)
    !isvalid(target) && return Float64(new_speed)
    spd = max(0.0, Float64(new_speed))
    if target.kind == UInt8(2)
        uid = UInt64(target.id)
        k = get(ctx.world.entity_kinematics, uid, nothing)
        if k !== nothing
            k.base_distance = kinematics_distance(k, ctx.t)
            k.last_update_time = ctx.t
            k.current_speed = spd
        end
        push!(ctx.commands, HookCommand(OP_SET_SPEED; target_id=Int64(uid), int_arg=2, float_arg=spd))
    else
        zid = _resolve_zone_id(ctx, target)
        if zid > 0
            set_zone_attribute!(ctx.world, zid, "_nominal_speed", spd)
            for (uid, k) in ctx.world.entity_kinematics
                if k.zone_id == zid
                    k.base_distance = kinematics_distance(k, ctx.t)
                    k.last_update_time = ctx.t
                    k.nominal_speed = spd
                    k.current_speed = spd
                end
            end
            push!(ctx.commands, HookCommand(OP_SET_SPEED; target_id=zid, int_arg=1, float_arg=spd))
        end
    end
    return spd
end

function set_speed!(ctx::HookContext, targets::AbstractVector{EntityHandle}, new_speed::Real)
    spd = max(0.0, Float64(new_speed))
    for h in targets
        set_speed!(ctx, h, spd)
    end
    return spd
end

set_speed!(ctx::HookContext, target::Union{String, Symbol}, new_speed::Real) =
    set_speed!(ctx, _resolve_handle(ctx, target), new_speed)
set_speed!(ctx::HookContext, new_speed::Real) =
    set_speed!(ctx, self(ctx), new_speed)
set_speed!(target::Union{EntityHandle, String, Symbol, AbstractVector{EntityHandle}}, new_speed::Real) =
    set_speed!(current_ctx(), target, new_speed)
set_speed!(new_speed::Real) =
    set_speed!(current_ctx(), self(current_ctx()), new_speed)

"""
    set_distance!([ctx,] [target = item(),] dist_m::Real)
"""
function set_distance!(ctx::HookContext, target::EntityHandle, dist_m::Real)
    !isvalid(target) && return 0.0
    uid = UInt64(target.id)
    d = max(0.0, Float64(dist_m))
    k = get(ctx.world.entity_kinematics, uid, nothing)
    if k !== nothing
        k.base_distance = clamp(d, 0.0, k.path_length)
        k.last_update_time = ctx.t
    end
    push!(ctx.commands, HookCommand(OP_SET_DISTANCE; target_id=Int64(uid), float_arg=d))
    return d
end
set_distance!(ctx::HookContext, dist_m::Real) = set_distance!(ctx, item(ctx), dist_m)
set_distance!(target::EntityHandle, dist_m::Real) = set_distance!(current_ctx(), target, dist_m)
set_distance!(dist_m::Real) = set_distance!(current_ctx(), item(current_ctx()), dist_m)

"""
    set_progress!([ctx,] [target = item(),] s_frac::Real)
"""
function set_progress!(ctx::HookContext, target::EntityHandle, s_frac::Real)
    !isvalid(target) && return 0.0
    uid = UInt64(target.id)
    s = clamp(Float64(s_frac), 0.0, 1.0)
    k = get(ctx.world.entity_kinematics, uid, nothing)
    len = k !== nothing ? k.path_length : path_length(ctx, self(ctx))
    set_distance!(ctx, target, s * len)
    return s
end
set_progress!(ctx::HookContext, s_frac::Real) = set_progress!(ctx, item(ctx), s_frac)
set_progress!(target::EntityHandle, s_frac::Real) = set_progress!(current_ctx(), target, s_frac)
set_progress!(s_frac::Real) = set_progress!(current_ctx(), item(current_ctx()), s_frac)

"""
    step_distance!([ctx,] [target = self(),] delta_m::Real)

Advance an item (or all items on a conveyor if `target` is a conveyor/station) by `delta_m` metres.
"""
function step_distance!(ctx::HookContext, target::EntityHandle, delta_m::Real)
    !isvalid(target) && return 0.0
    dm = Float64(delta_m)
    if target.kind == UInt8(2)
        cur = distance(ctx, target)
        return set_distance!(ctx, target, cur + dm)
    else
        zid = _resolve_zone_id(ctx, target)
        for h in entities_along_path(ctx, target)
            cur = distance(ctx, h)
            set_distance!(ctx, h, cur + dm)
        end
        push!(ctx.commands, HookCommand(OP_STEP_DISTANCE; target_id=zid, float_arg=dm))
        return dm
    end
end
step_distance!(ctx::HookContext, delta_m::Real) = step_distance!(ctx, self(ctx), delta_m)
step_distance!(target::EntityHandle, delta_m::Real) = step_distance!(current_ctx(), target, delta_m)
step_distance!(delta_m::Real) = step_distance!(current_ctx(), self(current_ctx()), delta_m)

"""
    entities_along_path([ctx,] [conv = self()]) -> Vector{EntityHandle}

Return all flowing items on `conv` sorted from front (closest to outlet, highest `distance`)
to back (closest to inlet, lowest `distance`).
"""
function entities_along_path(ctx::HookContext, conv=self(ctx))::Vector{EntityHandle}
    items = contained_entities(ctx, conv; filter=:in_service)
    sort!(items, by = h -> (-distance(ctx, h), h.id))
    return items
end
entities_along_path(conv) = entities_along_path(current_ctx(), conv)
entities_along_path() = entities_along_path(current_ctx(), self(current_ctx()))

"""
    entity_ahead([ctx,] [target = item()]) -> EntityHandle

Return the item immediately ahead of `target` on the same conveyor/path, or `INVALID_HANDLE`.
"""
function entity_ahead(ctx::HookContext, target=item(ctx))::EntityHandle
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return INVALID_HANDLE
    parent = container_entity(ctx, h)
    !isvalid(parent) && return INVALID_HANDLE
    ordered = entities_along_path(ctx, parent)
    idx = findfirst(==(h), ordered)
    (idx === nothing || idx <= 1) && return INVALID_HANDLE
    return ordered[idx - 1]
end
entity_ahead(target) = entity_ahead(current_ctx(), target)
entity_ahead() = entity_ahead(current_ctx(), item(current_ctx()))

"""
    entity_behind([ctx,] [target = item()]) -> EntityHandle

Return the item immediately behind `target` on the same conveyor/path, or `INVALID_HANDLE`.
"""
function entity_behind(ctx::HookContext, target=item(ctx))::EntityHandle
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return INVALID_HANDLE
    parent = container_entity(ctx, h)
    !isvalid(parent) && return INVALID_HANDLE
    ordered = entities_along_path(ctx, parent)
    idx = findfirst(==(h), ordered)
    (idx === nothing || idx >= length(ordered)) && return INVALID_HANDLE
    return ordered[idx + 1]
end
entity_behind(target) = entity_behind(current_ctx(), target)
entity_behind() = entity_behind(current_ctx(), item(current_ctx()))

"""
    gap_ahead([ctx,] [target = item()]) -> Float64

Return the physical distance `[m]` to the entity ahead on the path, or the remaining distance
to the end of the path if `target` is the leading entity.
"""
function gap_ahead(ctx::HookContext, target=item(ctx))::Float64
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return Inf
    my_d = distance(ctx, h)
    ahead = entity_ahead(ctx, h)
    if isvalid(ahead)
        return max(0.0, distance(ctx, ahead) - my_d)
    else
        parent = container_entity(ctx, h)
        len = isvalid(parent) ? path_length(ctx, parent) : path_length(ctx, self(ctx))
        return max(0.0, len - my_d)
    end
end
gap_ahead(target) = gap_ahead(current_ctx(), target)
gap_ahead() = gap_ahead(current_ctx(), item(current_ctx()))

"""
    world_pos([ctx,] [target = item()]) -> NTuple{3, Float64}
"""
function world_pos(ctx::HookContext, target=item(ctx))::NTuple{3, Float64}
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return (0.0, 0.0, 0.0)
    if h.kind == UInt8(2)
        k = get(ctx.world.entity_kinematics, UInt64(h.id), nothing)
        if k !== nothing && k.custom_pos_override
            return k.custom_pos
        end
        vis = get_entity_visuals(ctx.world, Int(h.id); create=false)
        if haskey(vis, "world_pos")
            return vis["world_pos"]
        end
    end
    zid = _resolve_zone_id(ctx, h)
    return get_zone_attribute(ctx.world, zid, "_spatial_pos", (0.0, 0.0, 0.0))
end
world_pos(target) = world_pos(current_ctx(), target)
world_pos() = world_pos(current_ctx(), item(current_ctx()))

"""
    set_world_pos!([ctx,] [target = item(),] x::Real, y::Real, z::Real = 0.0)
"""
function set_world_pos!(ctx::HookContext, target::EntityHandle, x::Real, y::Real, z::Real=0.0)
    !isvalid(target) && return (0.0, 0.0, 0.0)
    pos = (Float64(x), Float64(y), Float64(z))
    if target.kind == UInt8(2)
        uid = UInt64(target.id)
        set_entity_visual!(ctx.world, uid, "world_pos", pos)
        k = get(ctx.world.entity_kinematics, uid, nothing)
        if k !== nothing
            k.custom_pos_override = true
            k.custom_pos = pos
        end
    else
        zid = _resolve_zone_id(ctx, target)
        set_zone_attribute!(ctx.world, zid, "_spatial_pos", pos)
    end
    return pos
end
set_world_pos!(ctx::HookContext, x::Real, y::Real, z::Real=0.0) = set_world_pos!(ctx, item(ctx), x, y, z)
set_world_pos!(target::EntityHandle, x::Real, y::Real, z::Real=0.0) = set_world_pos!(current_ctx(), target, x, y, z)
set_world_pos!(x::Real, y::Real, z::Real=0.0) = set_world_pos!(current_ctx(), item(current_ctx()), x, y, z)

"""
    distance_between([ctx,] a, b) -> Float64
"""
function distance_between(ctx::HookContext, a, b)::Float64
    pa = world_pos(ctx, a)
    pb = world_pos(ctx, b)
    return sqrt((pa[1] - pb[1])^2 + (pa[2] - pb[2])^2 + (pa[3] - pb[3])^2)
end
distance_between(a, b) = distance_between(current_ctx(), a, b)

# ═════════════════════════════════════════════════════════════════════════════
# Category 12: Dynamic Entity & Component Creation
# ═════════════════════════════════════════════════════════════════════════════

"""
    define_entity_type!([ctx,] type_name::Symbol; mesh=:box, color=:cyan, size=1.0, default_attrs=Dict())
"""
function define_entity_type!(
    ctx::HookContext,
    type_name::Symbol;
    mesh::Union{Symbol, String} = :box,
    color = :cyan,
    size = 1.0,
    default_attrs = Dict{String, Any}()
)
    tpl = Dict{String, Any}(
        "mesh" => Symbol(mesh),
        "color" => color,
        "size" => size,
        "default_attrs" => Dict{String, Any}(string(k) => v for (k, v) in default_attrs)
    )
    ctx.world.entity_type_templates[type_name] = tpl
    return type_name
end
define_entity_type!(type_name::Symbol; kwargs...) = define_entity_type!(current_ctx(), type_name; kwargs...)

"""
    create_entity!([ctx,] entity_type::Symbol = :product; priority::Int = 0, attrs...) -> EntityHandle
"""
function create_entity!(ctx::HookContext, entity_type::Symbol=:product; priority::Int=0, attrs...)::EntityHandle
    uid = new_entity_id!(ctx.world)
    h = EntityHandle(Int32(uid), UInt8(2))
    ctx.world.entry_times[uid] = ctx.t
    bag = get_entity_attributes(ctx.world, uid; create=true)
    bag["entity_type"] = string(entity_type)
    bag["arrival_time"] = ctx.t
    bag["priority"] = priority

    if haskey(ctx.world.entity_type_templates, entity_type)
        tpl = ctx.world.entity_type_templates[entity_type]
        for (tk, tv) in tpl["default_attrs"]
            bag[tk] = tv
        end
        set_color!(ctx, h, tpl["color"])
        set_mesh!(ctx, h, tpl["mesh"])
        set_size!(ctx, h, tpl["size"])
    end

    for (k, v) in attrs
        bag[string(k)] = v
    end
    return h
end
create_entity!(entity_type::Symbol=:product; priority::Int=0, attrs...) =
    create_entity!(current_ctx(), entity_type; priority=priority, attrs...)

"""
    spawn_to_port!([ctx,] entity_type::Symbol = :product, out_port::Symbol = :out_flow; slot::Int = 1, priority::Int = 0, attrs...) -> EntityHandle
"""
function spawn_to_port!(
    ctx::HookContext,
    entity_type::Symbol = :product,
    out_port::Union{Symbol, String} = :out_flow;
    slot::Int = 1,
    priority::Int = 0,
    attrs...
)::EntityHandle
    h = create_entity!(ctx, entity_type; priority=priority, attrs...)
    peer = connected_entity(ctx, self(ctx), out_port, slot)
    dest_z = isvalid(peer) ? _resolve_zone_id(ctx, peer) : ctx.zone_id
    if dest_z > 0
        push!(ctx.commands, HookCommand(OP_SPAWN_TO_PORT; target_id=Int64(h.id), int_arg=dest_z, sym_arg=Symbol(priority)))
    end
    return h
end
spawn_to_port!(entity_type::Symbol=:product, out_port::Union{Symbol, String}=:out_flow; slot::Int=1, priority::Int=0, attrs...) =
    spawn_to_port!(current_ctx(), entity_type, out_port; slot=slot, priority=priority, attrs...)

"""
    destroy_entity!([ctx,] [target = item()])
"""
function destroy_entity!(ctx::HookContext, target=item(ctx))
    h = _resolve_handle(ctx, target)
    !isvalid(h) && return nothing
    if h.kind == UInt8(2)
        push!(ctx.commands, HookCommand(OP_DESTROY_ENTITY; target_id=Int64(h.id), int_arg=ctx.zone_id))
    end
    return nothing
end
destroy_entity!(target) = destroy_entity!(current_ctx(), target)
destroy_entity!() = destroy_entity!(current_ctx(), item(current_ctx()))

"""
    combine_entities!([ctx,] handles::Vector{EntityHandle}; new_type::Symbol = :assembly) -> EntityHandle
"""
function combine_entities!(ctx::HookContext, handles::AbstractVector{EntityHandle}; new_type::Symbol=:assembly)::EntityHandle
    parent = create_entity!(ctx, new_type; member_count=length(handles))
    for ch in handles
        put_inside!(ctx, parent, ch)
        destroy_entity!(ctx, ch)
    end
    return parent
end
combine_entities!(handles::AbstractVector{EntityHandle}; new_type::Symbol=:assembly) =
    combine_entities!(current_ctx(), handles; new_type=new_type)

"""
    split_entity!([ctx,] [parent = item(),] count::Int; child_type::Symbol = :subpart, out_port::Symbol = :out_flow) -> Vector{EntityHandle}
"""
function split_entity!(
    ctx::HookContext,
    parent::EntityHandle,
    count::Int;
    child_type::Symbol = :subpart,
    out_port::Union{Symbol, String} = :out_flow
)::Vector{EntityHandle}
    parent_attrs = isvalid(parent) ? copy(get_entity_attributes(ctx.world, Int(parent.id); create=false)) : Dict{String, Any}()
    res = EntityHandle[]
    for idx in 1:count
        ch = spawn_to_port!(ctx, child_type, out_port; split_index=idx, parent_id=Int(parent.id))
        for (k, v) in parent_attrs
            if !(k in ("entity_type", "arrival_time"))
                set_attr!(ctx, ch, k, v)
            end
        end
        push!(res, ch)
    end
    return res
end
split_entity!(ctx::HookContext, count::Int; child_type::Symbol=:subpart, out_port::Union{Symbol, String}=:out_flow) =
    split_entity!(ctx, item(ctx), count; child_type=child_type, out_port=out_port)
split_entity!(parent::EntityHandle, count::Int; child_type::Symbol=:subpart, out_port::Union{Symbol, String}=:out_flow) =
    split_entity!(current_ctx(), parent, count; child_type=child_type, out_port=out_port)
split_entity!(count::Int; child_type::Symbol=:subpart, out_port::Union{Symbol, String}=:out_flow) =
    split_entity!(current_ctx(), item(current_ctx()), count; child_type=child_type, out_port=out_port)

# ═════════════════════════════════════════════════════════════════════════════
# Category 13: Visuals, Randomness & Custom Telemetry
# ═════════════════════════════════════════════════════════════════════════════

const _NAMED_COLORS = Dict{Symbol, NTuple{3, Float64}}(
    :red     => (0.95, 0.20, 0.20),
    :green   => (0.20, 0.88, 0.35),
    :blue    => (0.20, 0.55, 0.98),
    :yellow  => (0.98, 0.85, 0.18),
    :orange  => (0.98, 0.55, 0.15),
    :purple  => (0.70, 0.30, 0.95),
    :cyan    => (0.20, 0.85, 0.95),
    :magenta => (0.95, 0.25, 0.80),
    :white   => (0.95, 0.95, 0.95),
    :gray    => (0.55, 0.58, 0.62),
    :grey    => (0.55, 0.58, 0.62),
    :gold    => (1.00, 0.82, 0.15),
    :crimson => (0.86, 0.08, 0.24),
    :teal    => (0.10, 0.75, 0.70),
)

function _parse_color_rgb(c)::NTuple{3, Float64}
    if c isa NTuple{3, Real}
        return (clamp(Float64(c[1]), 0.0, 1.0), clamp(Float64(c[2]), 0.0, 1.0), clamp(Float64(c[3]), 0.0, 1.0))
    elseif c isa Symbol || c isa AbstractString
        s = strip(string(c))
        if startswith(s, "#") && length(s) == 7
            r = something(tryparse(Int, s[2:3]; base=16), 76) / 255.0
            g = something(tryparse(Int, s[4:5]; base=16), 191) / 255.0
            b = something(tryparse(Int, s[6:7]; base=16), 255) / 255.0
            return (r, g, b)
        end
        sym = Symbol(lowercase(s))
        return get(_NAMED_COLORS, sym, (0.3, 0.75, 1.0))
    end
    return (0.3, 0.75, 1.0)
end

"""
    set_color!([ctx,] [target = item(),] color_or_r, [g, b])
"""
function set_color!(ctx::HookContext, target::EntityHandle, color)
    !isvalid(target) && return (0.3, 0.75, 1.0)
    rgb = _parse_color_rgb(color)
    if target.kind == UInt8(2)
        set_entity_visual!(ctx.world, Int(target.id), "color", rgb)
    else
        zid = _resolve_zone_id(ctx, target)
        set_zone_attribute!(ctx.world, zid, "visual_color", rgb)
    end
    return rgb
end
function set_color!(ctx::HookContext, targets::AbstractVector{EntityHandle}, color)
    rgb = _parse_color_rgb(color)
    for h in targets
        set_color!(ctx, h, rgb)
    end
    return rgb
end
set_color!(ctx::HookContext, target::EntityHandle, r::Real, g::Real, b::Real) =
    set_color!(ctx, target, (Float64(r), Float64(g), Float64(b)))
set_color!(ctx::HookContext, color) =
    set_color!(ctx, isvalid(item(ctx)) ? item(ctx) : self(ctx), color)
set_color!(ctx::HookContext, r::Real, g::Real, b::Real) =
    set_color!(ctx, isvalid(item(ctx)) ? item(ctx) : self(ctx), (Float64(r), Float64(g), Float64(b)))
set_color!(target::EntityHandle, color) = set_color!(current_ctx(), target, color)
set_color!(targets::AbstractVector{EntityHandle}, color) = set_color!(current_ctx(), targets, color)
set_color!(target::EntityHandle, r::Real, g::Real, b::Real) = set_color!(current_ctx(), target, r, g, b)
set_color!(color) = set_color!(current_ctx(), color)
set_color!(r::Real, g::Real, b::Real) = set_color!(current_ctx(), r, g, b)

"""
    set_mesh!([ctx,] [target = item(),] mesh_type::Union{Symbol, String})
"""
function set_mesh!(ctx::HookContext, target::EntityHandle, mesh_type::Union{Symbol, String})
    !isvalid(target) && return :box
    msym = Symbol(lowercase(string(mesh_type)))
    set_entity_visual!(ctx.world, Int(target.id), "mesh_type", msym)
    return msym
end
set_mesh!(ctx::HookContext, mesh_type::Union{Symbol, String}) = set_mesh!(ctx, item(ctx), mesh_type)
set_mesh!(target::EntityHandle, mesh_type::Union{Symbol, String}) = set_mesh!(current_ctx(), target, mesh_type)
set_mesh!(mesh_type::Union{Symbol, String}) = set_mesh!(current_ctx(), item(current_ctx()), mesh_type)

"""
    set_size!([ctx,] [target = item(),] scale_or_w::Real, [h::Real, d::Real])
"""
function set_size!(ctx::HookContext, target::EntityHandle, scale::Real)
    !isvalid(target) && return 1.0
    s = clamp(Float64(scale), 0.1, 10.0)
    set_entity_visual!(ctx.world, Int(target.id), "size_scale", s)
    return s
end
function set_size!(ctx::HookContext, target::EntityHandle, w::Real, h::Real, d::Real)
    !isvalid(target) && return (0.4, 0.4, 0.4)
    dims = (max(0.05, Float64(w)), max(0.05, Float64(h)), max(0.05, Float64(d)))
    set_entity_visual!(ctx.world, Int(target.id), "size_dims", dims)
    return dims
end
set_size!(ctx::HookContext, scale::Real) = set_size!(ctx, item(ctx), scale)
set_size!(ctx::HookContext, w::Real, h::Real, d::Real) = set_size!(ctx, item(ctx), w, h, d)
set_size!(target::EntityHandle, scale::Real) = set_size!(current_ctx(), target, scale)
set_size!(target::EntityHandle, w::Real, h::Real, d::Real) = set_size!(current_ctx(), target, w, h, d)
set_size!(scale::Real) = set_size!(current_ctx(), item(current_ctx()), scale)
set_size!(w::Real, h::Real, d::Real) = set_size!(current_ctx(), item(current_ctx()), w, h, d)

"""
    set_label!([ctx,] [target = item(),] text::AbstractString)
"""
function set_label!(ctx::HookContext, target::EntityHandle, text::AbstractString)
    !isvalid(target) && return ""
    s = String(text)
    if target.kind == UInt8(2)
        set_entity_visual!(ctx.world, Int(target.id), "label", s)
        set_entity_attribute!(ctx.world, Int(target.id), "label", s)
    else
        zid = _resolve_zone_id(ctx, target)
        set_zone_attribute!(ctx.world, zid, "badge_override", s)
    end
    return s
end
set_label!(ctx::HookContext, text::AbstractString) = set_label!(ctx, isvalid(item(ctx)) ? item(ctx) : self(ctx), text)
set_label!(target::EntityHandle, text::AbstractString) = set_label!(current_ctx(), target, text)
set_label!(text::AbstractString) = set_label!(current_ctx(), text)

"""
    highlight!([ctx,] [target = self(),] color = :gold; duration::Real = 2.0)
"""
function highlight!(ctx::HookContext, target=self(ctx), color=:gold; duration::Real=2.0)
    h = _resolve_handle(ctx, target)
    rgb = _parse_color_rgb(color)
    if h.kind == UInt8(2)
        set_entity_visual!(ctx.world, Int(h.id), "highlight", (rgb, ctx.t + Float64(duration)))
    else
        zid = _resolve_zone_id(ctx, h)
        set_zone_attribute!(ctx.world, zid, "highlight", (rgb, ctx.t + Float64(duration)))
    end
    return rgb
end
highlight!(ctx::HookContext, color::Union{Symbol, String}; duration::Real=2.0) =
    highlight!(ctx, self(ctx), color; duration=duration)
highlight!(color::Union{Symbol, String}=:gold; duration::Real=2.0) =
    highlight!(current_ctx(), self(current_ctx()), color; duration=duration)

# ── Clock & Seeded Randomness ────────────────────────────────────────────────

sim_time(ctx::HookContext)::Float64 = ctx.t
sim_time()::Float64 = sim_time(current_ctx())

rng(ctx::HookContext) = ctx.rng
rng() = rng(current_ctx())

@inline _rand(ctx::HookContext)::Float64 = ctx.rng === nothing ? rand() : rand(ctx.rng)
@inline _randn(ctx::HookContext)::Float64 = ctx.rng === nothing ? randn() : randn(ctx.rng)
@inline _randint(ctx::HookContext, r) = ctx.rng === nothing ? rand(r) : rand(ctx.rng, r)

rand_uniform(ctx::HookContext, lo::Real=0.0, hi::Real=1.0)::Float64 =
    Float64(lo) + _rand(ctx) * (Float64(hi) - Float64(lo))
rand_uniform(lo::Real=0.0, hi::Real=1.0)::Float64 = rand_uniform(current_ctx(), lo, hi)

rand_exp(ctx::HookContext, mean_val::Real=1.0)::Float64 =
    -max(1e-6, Float64(mean_val)) * log(max(1e-15, _rand(ctx)))
rand_exp(mean_val::Real=1.0)::Float64 = rand_exp(current_ctx(), mean_val)

rand_normal(ctx::HookContext, mean_val::Real=0.0, std_val::Real=1.0)::Float64 =
    Float64(mean_val) + max(1e-6, Float64(std_val)) * _randn(ctx)
rand_normal(mean_val::Real=0.0, std_val::Real=1.0)::Float64 = rand_normal(current_ctx(), mean_val, std_val)

function rand_triangular(ctx::HookContext, min_v::Real, mode_v::Real, max_v::Real)::Float64
    a = Float64(min_v)
    b = max(a + 1e-6, Float64(max_v))
    c = clamp(Float64(mode_v), a, b)
    u = _rand(ctx)
    fc = (c - a) / (b - a)
    return u < fc ? a + sqrt(u * (b - a) * (c - a)) : b - sqrt((1.0 - u) * (b - a) * (b - c))
end
rand_triangular(min_v::Real, mode_v::Real, max_v::Real)::Float64 =
    rand_triangular(current_ctx(), min_v, mode_v, max_v)

rand_int(ctx::HookContext, lo::Integer, hi::Integer)::Int = _randint(ctx, Int(lo):Int(hi))
rand_int(lo::Integer, hi::Integer)::Int = rand_int(current_ctx(), lo, hi)

function rand_choice(ctx::HookContext, items::AbstractVector, weights::Union{Nothing, AbstractVector{<:Real}}=nothing)
    isempty(items) && return nothing
    if weights === nothing
        return items[_randint(ctx, 1:length(items))]
    end
    tot = sum(Float64(w) for w in weights)
    tot <= 0.0 && return first(items)
    u = _rand(ctx) * tot
    cum = 0.0
    for (it, w) in zip(items, weights)
        cum += Float64(w)
        u <= cum && return it
    end
    return last(items)
end
rand_choice(items::AbstractVector, weights::Union{Nothing, AbstractVector{<:Real}}=nothing) =
    rand_choice(current_ctx(), items, weights)

coin_flip(ctx::HookContext, p::Real=0.5)::Bool = _rand(ctx) < Float64(p)
coin_flip(p::Real=0.5)::Bool = coin_flip(current_ctx(), p)

# ── Custom Telemetry, Metrics & Logging ──────────────────────────────────────

"""
    record_metric!([ctx,] name::Union{Symbol, String}, value::Real)
"""
function record_metric!(ctx::HookContext, name::Union{Symbol, String}, value::Real)
    sym = Symbol(name)
    v = Float64(value)
    ut = ctx.world.user_telemetry
    ut.gauges[sym] = v
    ts = get!(ut.timeseries, sym, Tuple{Float64, Float64}[])
    push!(ts, (ctx.t, v))
    return v
end
record_metric!(name::Union{Symbol, String}, value::Real) = record_metric!(current_ctx(), name, value)

"""
    increment_counter!([ctx,] name::Union{Symbol, String}, by::Integer = 1) -> Int64
"""
function increment_counter!(ctx::HookContext, name::Union{Symbol, String}, by::Integer=1)::Int64
    sym = Symbol(name)
    ut = ctx.world.user_telemetry
    nv = get(ut.counters, sym, Int64(0)) + Int64(by)
    ut.counters[sym] = nv
    return nv
end
increment_counter!(name::Union{Symbol, String}, by::Integer=1) = increment_counter!(current_ctx(), name, by)

"""
    set_gauge!([ctx,] name::Union{Symbol, String}, value::Real) -> Float64
"""
function set_gauge!(ctx::HookContext, name::Union{Symbol, String}, value::Real)::Float64
    sym = Symbol(name)
    v = Float64(value)
    ctx.world.user_telemetry.gauges[sym] = v
    return v
end
set_gauge!(name::Union{Symbol, String}, value::Real) = set_gauge!(current_ctx(), name, value)

"""
    record_histogram!([ctx,] name::Union{Symbol, String}, sample::Real) -> Float64
"""
function record_histogram!(ctx::HookContext, name::Union{Symbol, String}, sample::Real)::Float64
    sym = Symbol(name)
    v = Float64(sample)
    vec = get!(ctx.world.user_telemetry.histograms, sym, Float64[])
    push!(vec, v)
    return v
end
record_histogram!(name::Union{Symbol, String}, sample::Real) = record_histogram!(current_ctx(), name, sample)

"""
    record_tally!([ctx,] name::Union{Symbol, String}, sample::Real) -> Float64
"""
function record_tally!(ctx::HookContext, name::Union{Symbol, String}, sample::Real)::Float64
    sym = Symbol(name)
    v = Float64(sample)
    ut = ctx.world.user_telemetry
    s, c = get(ut.tally_sums, sym, (0.0, Int64(0)))
    ut.tally_sums[sym] = (s + v, c + 1)
    return (s + v) / (c + 1)
end
record_tally!(name::Union{Symbol, String}, sample::Real) = record_tally!(current_ctx(), name, sample)

"""
    log_event!([ctx,] message::AbstractString)
"""
function log_event!(ctx::HookContext, message::AbstractString)
    logs = ctx.world.user_telemetry.logs
    push!(logs, (ctx.t, self_id(ctx), String(message)))
    if length(logs) > 500
        popfirst!(logs)
    end
    return message
end
log_event!(message::AbstractString) = log_event!(current_ctx(), message)

# ── Populate Helper Metadata Catalog ─────────────────────────────────────────

function _init_simviz_helper_catalog!()
    empty!(HELPER_CATALOG)
    # Category 1: Identity & Selectors (12)
    register_simviz_helper!(:self, :identity, "self([ctx]) -> EntityHandle", "Handle of the entity owning the hook", "s = self()")
    register_simviz_helper!(:self_handle, :identity, "self_handle([ctx]) -> EntityHandle", "Alias for self()", "s = self_handle()")
    register_simviz_helper!(:self_id, :identity, "self_id([ctx]) -> String", "String ID of the entity owning the hook", "id = self_id()")
    register_simviz_helper!(:item, :identity, "item([ctx]) -> EntityHandle", "Handle of the flowing entity that triggered the hook", "it = item()")
    register_simviz_helper!(:item_handle, :identity, "item_handle([ctx]) -> EntityHandle", "Alias for item()", "it = item_handle()")
    register_simviz_helper!(:item_id, :identity, "item_id([ctx]) -> Int", "Numeric ID of the flowing entity", "id = item_id()")
    register_simviz_helper!(:entity_handle, :identity, "entity_handle([ctx,] name_or_id) -> EntityHandle", "Resolve O(1) EntityHandle from name or ID", "h = entity_handle(\"conveyor_1\")")
    register_simviz_helper!(:entity_name, :identity, "entity_name([ctx,] handle) -> String", "String name of an EntityHandle", "nm = entity_name(self())")
    register_simviz_helper!(:entity_kind, :identity, "entity_kind([ctx,] handle) -> Symbol", "Kind symbol (:server, :conveyor, :queue, :flowing_item)", "k = entity_kind(self())")
    register_simviz_helper!(:entities_of_kind, :identity, "entities_of_kind([ctx,] kind::Symbol) -> Vector{EntityHandle}", "All entities of a kind (:conveyor, :server, :queue)", "set_speed!(entities_of_kind(:conveyor), 2.0)")
    register_simviz_helper!(:entities_where, :identity, "entities_where([ctx,] pred::Function; kind=nothing) -> Vector{EntityHandle}", "All entities satisfying pred(e)", "busy = entities_where(e -> utilization(e) > 0.8)")
    register_simviz_helper!(:entities_in_group, :identity, "entities_in_group([ctx,] group_tag) -> Vector{EntityHandle}", "All entities in named group", "pack = entities_in_group(:Zone_A)")
    register_simviz_helper!(:all_entities, :identity, "all_entities([ctx]) -> Vector{EntityHandle}", "All registered station/conveyor/queue entities", "all_e = all_entities()")

    # Category 2: Ports & Connected-Entity Selectors (18)
    register_simviz_helper!(:ports, :ports, "ports([ctx,] [owner=self()]; dir=:all, domain=:all) -> Vector{Symbol}", "List ports on entity", "ps = ports(dir=:out)")
    register_simviz_helper!(:input_ports, :ports, "input_ports([ctx,] [owner=self()]; domain=:all) -> Vector{Symbol}", "List input ports (:in) on entity", "ins = input_ports()")
    register_simviz_helper!(:output_ports, :ports, "output_ports([ctx,] [owner=self()]; domain=:all) -> Vector{Symbol}", "List output ports (:out) on entity", "outs = output_ports()")
    register_simviz_helper!(:has_port, :ports, "has_port([ctx,] [owner=self(),] port_name) -> Bool", "Check whether entity has named port", "has_port(:out_flow)")
    register_simviz_helper!(:port_direction, :ports, "port_direction([ctx,] [owner=self(),] port_name) -> Symbol", "Port direction (:in or :out)", "port_direction(:out_flow)")
    register_simviz_helper!(:port_domain, :ports, "port_domain([ctx,] [owner=self(),] port_name) -> Symbol", "Port domain (:flow, :signal, :event, :metric)", "port_domain(:out_flow)")
    register_simviz_helper!(:port_cardinality, :ports, "port_cardinality([ctx,] [owner=self(),] port_name) -> Int", "Maximum wires allowed on port", "port_cardinality(:out_flow)")
    register_simviz_helper!(:is_connected, :ports, "is_connected([ctx,] [owner=self(),] port_name) -> Bool", "True if at least 1 wire is connected to port", "is_connected(:out_flow)")
    register_simviz_helper!(:connection_count, :ports, "connection_count([ctx,] [owner=self(),] port_name) -> Int", "Number of active wires on port", "n = connection_count(:in_flow)")
    register_simviz_helper!(:connected_ports, :ports, "connected_ports([ctx,] [owner=self(),] port_name) -> Vector{PortWireLink}", "Ordered wire links on port", "links = connected_ports(:out_flow)")
    register_simviz_helper!(:connected_entities, :ports, "connected_entities([ctx,] [owner,] port_name) -> Vector{EntityHandle}", "All peer entities wired to port in slot order [1..N]", "peers = connected_entities(:out_flow)")
    register_simviz_helper!(:connected_entity, :ports, "connected_entity([ctx,] [owner,] port_name, slot=1) -> EntityHandle", "Peer entity wired to specific 1-based slot on port", "rework = connected_entity(:out_flow, 2)")
    register_simviz_helper!(:connected_entity_where, :ports, "connected_entity_where([ctx,] [owner,] port_name, pred) -> EntityHandle", "First connected entity on port satisfying pred(e)", "e = connected_entity_where(:out_flow, x -> !is_full(x))")
    register_simviz_helper!(:connected_entities_where, :ports, "connected_entities_where([ctx,] [owner,] port_name, pred) -> Vector{EntityHandle}", "All connected entities on port satisfying pred(e)", "es = connected_entities_where(:out_flow, x -> !is_down(x))")
    register_simviz_helper!(:connected_entity_argmin, :ports, "connected_entity_argmin([ctx,] [owner,] port_name, score_fn) -> EntityHandle", "Connected entity minimizing score_fn(e)", "best = connected_entity_argmin(:out_flow, e -> queue_length(e))")
    register_simviz_helper!(:connected_entity_argmax, :ports, "connected_entity_argmax([ctx,] [owner,] port_name, score_fn) -> EntityHandle", "Connected entity maximizing score_fn(e)", "best = connected_entity_argmax(:out_flow, e -> free_capacity(e))")
    register_simviz_helper!(:upstream_entities, :ports, "upstream_entities([ctx,] [owner=self()]) -> Vector{EntityHandle}", "All upstream entities wired to :in_flow", "ups = upstream_entities()")
    register_simviz_helper!(:downstream_entities, :ports, "downstream_entities([ctx,] [owner=self()]) -> Vector{EntityHandle}", "All downstream entities wired to :out_flow", "dns = downstream_entities()")
    register_simviz_helper!(:send_signal!, :ports, "send_signal!([ctx,] out_port, value)", "Emit value out of an output signal port", "send_signal!(:out_signal, queue_length() >= 8)")
    register_simviz_helper!(:read_signal, :ports, "read_signal([ctx,] in_port, default=nothing)", "Read latest value on an input signal port", "jammed = read_signal(:in_signal, false)")
    register_simviz_helper!(:emit_port_event!, :ports, "emit_port_event!([ctx,] out_port, tag::Symbol; payload=nothing)", "Fire discrete event pulse across an event port", "emit_port_event!(:out_event, :batch_ready)")

    # Category 3: Containment Hierarchy (15)
    register_simviz_helper!(:container_entity, :containment, "container_entity([ctx,] [target=self()]) -> EntityHandle", "Immediate container holding target (or item())", "c = container_entity(item())")
    register_simviz_helper!(:root_container, :containment, "root_container([ctx,] [target=self()]) -> EntityHandle", "Outermost root container of target", "r = root_container()")
    register_simviz_helper!(:ancestors, :containment, "ancestors([ctx,] [target=self()]) -> Vector{EntityHandle}", "Chain of parent containers from immediate to root", "anc = ancestors(item())")
    register_simviz_helper!(:has_container, :containment, "has_container([ctx,] [target=self()]) -> Bool", "True if target is inside a container", "has_container(item())")
    register_simviz_helper!(:contained_entities, :containment, "contained_entities([ctx,] [holder=self()]; filter=:all) -> Vector{EntityHandle}", "All entities currently inside holder", "items = contained_entities(filter=:queued)")
    register_simviz_helper!(:contained_count, :containment, "contained_count([ctx,] [holder=self()]; filter=:all) -> Int", "Count of entities currently inside holder", "n = contained_count()")
    register_simviz_helper!(:contains_entity, :containment, "contains_entity([ctx,] [holder=self(),] child; recursive=false) -> Bool", "True if child is inside holder", "contains_entity(item())")
    register_simviz_helper!(:contained_entity, :containment, "contained_entity([ctx,] [holder=self(),] index=1; filter=:all) -> EntityHandle", "k-th contained entity inside holder", "first_it = contained_entity(1)")
    register_simviz_helper!(:first_contained, :containment, "first_contained([ctx,] [holder=self()]; filter=:all) -> EntityHandle", "First contained entity inside holder", "h = first_contained()")
    register_simviz_helper!(:last_contained, :containment, "last_contained([ctx,] [holder=self()]; filter=:all) -> EntityHandle", "Last contained entity inside holder", "t = last_contained()")
    register_simviz_helper!(:contained_entity_where, :containment, "contained_entity_where([ctx,] [holder,] pred; filter=:all) -> EntityHandle", "First contained entity satisfying pred(e)", "vip = contained_entity_where(e -> priority(e) > 5)")
    register_simviz_helper!(:contained_entities_where, :containment, "contained_entities_where([ctx,] [holder,] pred; filter=:all) -> Vector{EntityHandle}", "All contained entities satisfying pred(e)", "vips = contained_entities_where(e -> priority(e) > 5)")
    register_simviz_helper!(:contained_entity_argmin, :containment, "contained_entity_argmin([ctx,] [holder,] score_fn; filter=:all) -> EntityHandle", "Contained entity minimizing score_fn(e)", "urg = contained_entity_argmin(e -> due_date(e))")
    register_simviz_helper!(:contained_entity_argmax, :containment, "contained_entity_argmax([ctx,] [holder,] score_fn; filter=:all) -> EntityHandle", "Contained entity maximizing score_fn(e)", "old = contained_entity_argmax(e -> wait_time(e))")
    register_simviz_helper!(:put_inside!, :containment, "put_inside!([ctx,] container, child)", "Place child entity inside container entity", "put_inside!(pallet, part)")
    register_simviz_helper!(:take_out!, :containment, "take_out!([ctx,] container, [child])", "Remove child entity from container", "take_out!(pallet, part)")

    # Category 4: Multi-Queue Pull / Intake (11)
    register_simviz_helper!(:port_head_items, :intake, "port_head_items([ctx,] [owner,] in_port=:in_flow) -> Vector{PortCandidate}", "Head waiting item from each non-empty upstream queue on port", "cands = port_head_items(:in_flow)")
    register_simviz_helper!(:port_all_items, :intake, "port_all_items([ctx,] [owner,] in_port=:in_flow) -> Vector{PortCandidate}", "All waiting items across all upstream queues on port", "cands = port_all_items(:in_flow)")
    register_simviz_helper!(:pull_from_port!, :intake, "pull_from_port!([ctx,] in_port=:in_flow, slot=1) -> EntityHandle", "Pull head item from specific 1-based slot on input port", "pull_from_port!(:in_flow, 1)")
    register_simviz_helper!(:pull_from_port_slot_order!, :intake, "pull_from_port_slot_order!([ctx,] in_port=:in_flow) -> EntityHandle", "Pull from highest-priority non-empty slot [1..N]", "pull_from_port_slot_order!(:in_flow)")
    register_simviz_helper!(:pull_from_port_round_robin!, :intake, "pull_from_port_round_robin!([ctx,] in_port=:in_flow) -> EntityHandle", "Cyclic fair pull across non-empty upstream queues", "pull_from_port_round_robin!(:in_flow)")
    register_simviz_helper!(:pull_from_port_longest!, :intake, "pull_from_port_longest!([ctx,] in_port=:in_flow) -> EntityHandle", "Pull from upstream queue with largest queue_length", "pull_from_port_longest!(:in_flow)")
    register_simviz_helper!(:pull_from_port_highest_fill!, :intake, "pull_from_port_highest_fill!([ctx,] in_port=:in_flow) -> EntityHandle", "Pull from upstream queue with highest fill_ratio", "pull_from_port_highest_fill!(:in_flow)")
    register_simviz_helper!(:pull_from_port_where!, :intake, "pull_from_port_where!([ctx,] in_port, pred; scope=:heads) -> EntityHandle", "Pull first item satisfying pred(candidate)", "pull_from_port_where!(:in_flow, c -> attr(c, :grade) == \"VIP\")")
    register_simviz_helper!(:pull_from_port_argmin!, :intake, "pull_from_port_argmin!([ctx,] in_port, score_fn; scope=:heads) -> EntityHandle", "Pull waiting item minimizing score_fn across multi-queue input bus", "pull_from_port_argmin!(:in_flow, c -> due_date(c.item))")
    register_simviz_helper!(:pull_from_port_argmax!, :intake, "pull_from_port_argmax!([ctx,] in_port, score_fn; scope=:heads) -> EntityHandle", "Pull waiting item maximizing score_fn across multi-queue input bus", "pull_from_port_argmax!(:in_flow, c -> c.priority * 100 + c.wait_time)")
    register_simviz_helper!(:set_intake_mode!, :intake, "set_intake_mode!([ctx,] mode::Symbol)", "Set built-in multi-queue intake mode (:slot_order, :round_robin, :longest_queue, :highest_fill, :custom)", "set_intake_mode!(:longest_queue)")

    # Category 5: Attributes & Metadata (16)
    register_simviz_helper!(:attr, :attributes, "attr([ctx,] [target,] key, default=nothing)", "Read dynamic attribute from entity", "lot = attr(\"lot_id\", \"A\")")
    register_simviz_helper!(:get_attr, :attributes, "get_attr([ctx,] [target,] key, default=nothing)", "Alias for attr()", "lot = get_attr(:lot_id)")
    register_simviz_helper!(:num_attr, :attributes, "num_attr([ctx,] [target,] key, default=0.0) -> Float64", "Read numeric attribute as Float64", "w = num_attr(:weight_kg, 1.0)")
    register_simviz_helper!(:str_attr, :attributes, "str_attr([ctx,] [target,] key, default=\"\") -> String", "Read string attribute", "sku = str_attr(:sku, \"STD\")")
    register_simviz_helper!(:bool_attr, :attributes, "bool_attr([ctx,] [target,] key, default=false) -> Bool", "Read boolean attribute", "ok = bool_attr(:inspected, false)")
    register_simviz_helper!(:has_attr, :attributes, "has_attr([ctx,] [target,] key) -> Bool", "Check if entity has attribute key", "has_attr(:due_date)")
    register_simviz_helper!(:set_attr!, :attributes, "set_attr!([ctx,] [target,] key, value)", "Write dynamic attribute onto entity or batch of entities", "set_attr!(\"inspected\", true)")
    register_simviz_helper!(:inc_attr!, :attributes, "inc_attr!([ctx,] [target,] key, delta=1)", "Increment numeric attribute on entity", "inc_attr!(:rework_count, 1)")
    register_simviz_helper!(:delete_attr!, :attributes, "delete_attr!([ctx,] [target,] key)", "Delete attribute key from entity", "delete_attr!(:temp_tag)")
    register_simviz_helper!(:clear_attrs!, :attributes, "clear_attrs!([ctx,] [target])", "Remove all custom attributes from entity", "clear_attrs!()")
    register_simviz_helper!(:priority, :attributes, "priority([ctx,] [target=item()]) -> Int", "Priority level of entity", "p = priority()")
    register_simviz_helper!(:set_priority!, :attributes, "set_priority!([ctx,] [target=item(),] new_priority::Int)", "Update priority of entity or batch of entities", "set_priority!(10)")
    register_simviz_helper!(:arrival_time, :attributes, "arrival_time([ctx,] [target=item()]) -> Float64", "Time entity entered current station/queue", "t0 = arrival_time()")
    register_simviz_helper!(:wait_time, :attributes, "wait_time([ctx,] [target=item()]) -> Float64", "Elapsed waiting time in current station/queue", "w = wait_time()")
    register_simviz_helper!(:due_date, :attributes, "due_date([ctx,] [target=item()]) -> Float64", "Due date timestamp of entity", "dd = due_date()")
    register_simviz_helper!(:slack, :attributes, "slack([ctx,] [target=item()]) -> Float64", "Remaining slack time before due date", "sl = slack()")
    register_simviz_helper!(:critical_ratio, :attributes, "critical_ratio([ctx,] [target=item()]) -> Float64", "Critical ratio (due_date - t) / est_service", "cr = critical_ratio()")

    # Category 6: State & Capacity Queries (16)
    register_simviz_helper!(:queue_length, :state, "queue_length([ctx,] [target=self()]) -> Int", "Current number of items waiting in queue", "q = queue_length()")
    register_simviz_helper!(:in_service, :state, "in_service([ctx,] [target=self()]) -> Int", "Number of items currently in service", "b = in_service()")
    register_simviz_helper!(:num_servers, :state, "num_servers([ctx,] [target=self()]) -> Int", "Number of parallel servers at station", "c = num_servers()")
    register_simviz_helper!(:capacity, :state, "capacity([ctx,] [target=self()]) -> Int", "Maximum buffer capacity of station/queue", "cap = capacity()")
    register_simviz_helper!(:free_capacity, :state, "free_capacity([ctx,] [target=self()]) -> Int", "Available room before station/queue is full", "free = free_capacity()")
    register_simviz_helper!(:utilization, :state, "utilization([ctx,] [target=self()]) -> Float64", "Instantaneous server utilization in [0, 1]", "u = utilization()")
    register_simviz_helper!(:fill_ratio, :state, "fill_ratio([ctx,] [target=self()]) -> Float64", "Queue occupancy divided by capacity in [0, 1]", "fr = fill_ratio()")
    register_simviz_helper!(:is_full, :state, "is_full([ctx,] [target=self()]) -> Bool", "True if queue has reached capacity", "is_full()")
    register_simviz_helper!(:is_empty, :state, "is_empty([ctx,] [target=self()]) -> Bool", "True if queue and servers are empty", "is_empty()")
    register_simviz_helper!(:is_busy, :state, "is_busy([ctx,] [target=self()]) -> Bool", "True if all servers are busy", "is_busy()")
    register_simviz_helper!(:is_down, :state, "is_down([ctx,] [target=self()]) -> Bool", "True if station is failed or paused", "is_down()")
    register_simviz_helper!(:queued_entities, :state, "queued_entities([ctx,] [target=self()]) -> Vector{EntityHandle}", "Ordered handles of items waiting in queue", "q_items = queued_entities()")
    register_simviz_helper!(:head_entity, :state, "head_entity([ctx,] [target=self()]) -> EntityHandle", "First waiting item at head of queue", "hd = head_entity()")
    register_simviz_helper!(:tail_entity, :state, "tail_entity([ctx,] [target=self()]) -> EntityHandle", "Last waiting item at tail of queue", "tl = tail_entity()")
    register_simviz_helper!(:shortest_entity, :state, "shortest_entity([ctx,] candidates) -> EntityHandle", "Candidate with minimum queue_length", "s = shortest_entity(connected_entities(:out_flow))")
    register_simviz_helper!(:least_utilized_entity, :state, "least_utilized_entity([ctx,] candidates) -> EntityHandle", "Candidate with minimum utilization", "lu = least_utilized_entity(connected_entities(:out_flow))")

    # Category 7: Control & Actuation (7)
    register_simviz_helper!(:set_capacity!, :control, "set_capacity!([ctx,] [target=self(),] new_cap::Int)", "Dynamically resize buffer capacity", "set_capacity!(50)")
    register_simviz_helper!(:set_servers!, :control, "set_servers!([ctx,] [target=self(),] count::Int)", "Dynamically adjust parallel server count", "set_servers!(3)")
    register_simviz_helper!(:pause!, :control, "pause!([ctx,] [target=self()])", "Pause entity or batch of entities", "pause!(connected_entities(:in_flow))")
    register_simviz_helper!(:resume!, :control, "resume!([ctx,] [target=self()])", "Resume paused entity or batch of entities", "resume!()")
    register_simviz_helper!(:trigger_failure!, :control, "trigger_failure!([ctx,] [target=self(),] repair_duration=0.0)", "Force breakdown on station", "trigger_failure!(30.0)")
    register_simviz_helper!(:trigger_repair!, :control, "trigger_repair!([ctx,] [target=self()])", "Immediately repair failed station", "trigger_repair!()")
    register_simviz_helper!(:flush_queue!, :control, "flush_queue!([ctx,] [target=self()]; dest=:exit)", "Flush all waiting items to destination", "flush_queue!(dest=:exit)")

    # Category 8: Routing & Flow Control (11)
    register_simviz_helper!(:route_to!, :routing, "route_to!([ctx,] target)", "Redirect departing entity to target entity or :exit", "route_to!(connected_entity(:out_flow, 2))")
    register_simviz_helper!(:route_to_port!, :routing, "route_to_port!([ctx,] out_port=:out_flow, slot=1)", "Route departing entity via specific output port slot", "route_to_port!(:out_flow, 2)")
    register_simviz_helper!(:route_to_shortest!, :routing, "route_to_shortest!([ctx,] candidates=connected_entities(:out_flow))", "Route to candidate with shortest queue", "route_to_shortest!()")
    register_simviz_helper!(:route_to_fastest!, :routing, "route_to_fastest!([ctx,] candidates=connected_entities(:out_flow))", "Route to candidate with lowest utilization", "route_to_fastest!()")
    register_simviz_helper!(:exit_system!, :routing, "exit_system!([ctx])", "Route entity out of the simulation", "exit_system!()")
    register_simviz_helper!(:hold_entity!, :routing, "hold_entity!([ctx,] [target=item(),] duration::Real)", "Hold entity for extra duration seconds", "hold_entity!(5.0)")
    register_simviz_helper!(:release_entity!, :routing, "release_entity!([ctx,] [target=item()])", "Release held entity immediately", "release_entity!()")
    register_simviz_helper!(:preempt_server!, :routing, "preempt_server!([ctx,] [station=self()])", "Preempt active service at station", "preempt_server!()")
    register_simviz_helper!(:clone_entity!, :routing, "clone_entity!([ctx,] [target=item(),] dest; copy_attrs=true)", "Spawn clone of entity to destination", "clone_entity!(connected_entity(:out_flow, 2))")
    register_simviz_helper!(:batch_entities!, :routing, "batch_entities!([ctx,] count::Int; batch_attr=\"batch_size\")", "Batch count waiting items into current item", "batch_entities!(4)")
    register_simviz_helper!(:unbatch_entity!, :routing, "unbatch_entity!([ctx,] [target=item(),] dest)", "Release contained child items to destination", "unbatch_entity!(connected_entity(:out_flow, 1))")

    # Category 9: Custom Server Construction (8)
    register_simviz_helper!(:set_service_time!, :server, "set_service_time!([ctx,] duration)", "Override service duration for current entity", "set_service_time!(2.5)")
    register_simviz_helper!(:add_setup_time!, :server, "add_setup_time!([ctx,] extra_duration)", "Add sequence-dependent setup/changeover time", "add_setup_time!(4.0)")
    register_simviz_helper!(:start_service!, :server, "start_service!([ctx,] [target=item()]; duration=nothing)", "Explicitly start service on item", "start_service!(duration=3.0)")
    register_simviz_helper!(:complete_service!, :server, "complete_service!([ctx,] [target=item()])", "Immediately complete service on item", "complete_service!()")
    register_simviz_helper!(:seize_capacity!, :server, "seize_capacity!([ctx,] [station=self(),] units=1) -> Bool", "Seize server capacity units", "seize_capacity!(1)")
    register_simviz_helper!(:release_capacity!, :server, "release_capacity!([ctx,] [station=self(),] units=1)", "Release seized server capacity units", "release_capacity!(1)")
    register_simviz_helper!(:dequeue_where!, :server, "dequeue_where!([ctx,] [station=self(),] pred::Function) -> EntityHandle", "Dequeue first waiting item matching pred", "dequeue_where!(e -> attr(e, :family) == \"A\")")
    register_simviz_helper!(:last_processed_attr, :server, "last_processed_attr([ctx,] [station=self(),] key, default=nothing)", "Attribute value of previous item processed by station", "prev = last_processed_attr(:family, \"A\")")

    # Category 10: Low-Level DEVS Event Scheduling (10)
    register_simviz_helper!(:set_process_mode!, :events, "set_process_mode!([ctx,] [target=self(),] mode::Symbol)", "Set :standard or :custom FEL event mode", "set_process_mode!(:custom)")
    register_simviz_helper!(:schedule_event!, :events, "schedule_event!([ctx,] [owner,] tag, delay; payload=nothing)", "Schedule a custom event on the FEL", "schedule_event!(:shift_break, 60.0)")
    register_simviz_helper!(:schedule_at!, :events, "schedule_at!([ctx,] [owner,] tag, abs_time; payload=nothing)", "Schedule a custom event at absolute simulation time", "schedule_at!(:audit, 100.0)")
    register_simviz_helper!(:schedule_every!, :events, "schedule_every!([ctx,] [owner,] tag, interval; first_delay=interval, payload=nothing)", "Schedule a repeating periodic FEL event", "schedule_every!(:pulse, 5.0)")
    register_simviz_helper!(:cancel_event!, :events, "cancel_event!([ctx,] event_id)", "Cancel a scheduled FEL event by ID", "cancel_event!(ev_id)")
    register_simviz_helper!(:cancel_all_events!, :events, "cancel_all_events!([ctx,] [owner=self()])", "Cancel all custom FEL events for entity", "cancel_all_events!()")
    register_simviz_helper!(:event_tag, :events, "event_tag([ctx]) -> Symbol", "Tag of the currently firing CustomUserEvent", "tag = event_tag()")
    register_simviz_helper!(:event_payload, :events, "event_payload([ctx]) -> Any", "Payload carried by the currently firing CustomUserEvent", "p = event_payload()")
    register_simviz_helper!(:after!, :events, "after!(fn::Function, [ctx,] delay::Real)", "Schedule a callback closure after delay seconds", "after!(2.0) do c; resume!(c); end")
    register_simviz_helper!(:forward_entity!, :events, "forward_entity!([ctx,] [target=item()]; to=nothing, port=:out_flow, slot=1)", "Immediately dispatch item to downstream entity", "forward_entity!(port=:out_flow, slot=1)")

    # Category 11: Spatial & Conveyor Kinematics (16)
    register_simviz_helper!(:set_conveyor_mode!, :kinematics, "set_conveyor_mode!([ctx,] [conv,] mode; pitch=0.5, index_interval=1.0)", "Set conveyor physics mode (:free_flow, :accumulating, :indexing)", "set_conveyor_mode!(:accumulating, pitch=0.5)")
    register_simviz_helper!(:path_length, :kinematics, "path_length([ctx,] [conv=self()]) -> Float64", "Total physical arc-length [m] of conveyor", "L = path_length()")
    register_simviz_helper!(:distance, :kinematics, "distance([ctx,] [target=item()]) -> Float64", "Distance [m] traveled by item along conveyor", "d = distance()")
    register_simviz_helper!(:progress, :kinematics, "progress([ctx,] [target=item()]) -> Float64", "Normalized progress [0, 1] along conveyor", "s = progress()")
    register_simviz_helper!(:speed, :kinematics, "speed([ctx,] [target=self()]) -> Float64", "Current speed [m/s] of conveyor or item", "v = speed()")
    register_simviz_helper!(:set_distance!, :kinematics, "set_distance!([ctx,] [target=item(),] dist_m::Real)", "Set longitudinal position [m] of item on conveyor", "set_distance!(2.5)")
    register_simviz_helper!(:set_progress!, :kinematics, "set_progress!([ctx,] [target=item(),] s_frac::Real)", "Set normalized position [0, 1] of item on conveyor", "set_progress!(0.5)")
    register_simviz_helper!(:step_distance!, :kinematics, "step_distance!([ctx,] [target=self(),] delta_m::Real)", "Advance item or all items on conveyor by delta_m metres", "step_distance!(0.5)")
    register_simviz_helper!(:set_speed!, :kinematics, "set_speed!([ctx,] [target=self(),] new_speed)", "Set speed [m/s] of conveyor, item, or batch of conveyors", "set_speed!(entities_of_kind(:conveyor), 2.0)")
    register_simviz_helper!(:entities_along_path, :kinematics, "entities_along_path([ctx,] [conv=self()]) -> Vector{EntityHandle}", "Items on conveyor sorted front-to-back (outlet to inlet)", "ordered = entities_along_path()")
    register_simviz_helper!(:entity_ahead, :kinematics, "entity_ahead([ctx,] [target=item()]) -> EntityHandle", "Item immediately ahead on same conveyor", "ah = entity_ahead()")
    register_simviz_helper!(:entity_behind, :kinematics, "entity_behind([ctx,] [target=item()]) -> EntityHandle", "Item immediately behind on same conveyor", "bh = entity_behind()")
    register_simviz_helper!(:gap_ahead, :kinematics, "gap_ahead([ctx,] [target=item()]) -> Float64", "Physical clearance [m] to item ahead (or end of belt)", "g = gap_ahead()")
    register_simviz_helper!(:world_pos, :kinematics, "world_pos([ctx,] [target=item()]) -> NTuple{3, Float64}", "3D world coordinates (x, y, z) of entity", "pos = world_pos()")
    register_simviz_helper!(:set_world_pos!, :kinematics, "set_world_pos!([ctx,] [target=item(),] x, y, z=0.0)", "Override 3D world position of entity", "set_world_pos!(1.0, 0.5, 2.0)")
    register_simviz_helper!(:distance_between, :kinematics, "distance_between([ctx,] a, b) -> Float64", "Euclidean 3D distance between two entities", "d = distance_between(self(), item())")

    # Category 12: Dynamic Entity & Component Creation (6)
    register_simviz_helper!(:define_entity_type!, :creation, "define_entity_type!([ctx,] type_name; mesh=:box, color=:cyan, size=1.0, default_attrs=Dict())", "Register reusable runtime entity template", "define_entity_type!(:sub_tray, mesh=:box, color=:orange)")
    register_simviz_helper!(:create_entity!, :creation, "create_entity!([ctx,] entity_type=:product; priority=0, attrs...) -> EntityHandle", "Create a new flowing entity in SimWorld", "e = create_entity!(:pallet, lot=42)")
    register_simviz_helper!(:spawn_to_port!, :creation, "spawn_to_port!([ctx,] entity_type=:product, out_port=:out_flow; slot=1, priority=0, attrs...) -> EntityHandle", "Create and inject new entity out of port slot", "spawn_to_port!(:sub_tray, :out_flow, slot=1)")
    register_simviz_helper!(:destroy_entity!, :creation, "destroy_entity!([ctx,] [target=item()])", "Destroy and remove flowing entity", "destroy_entity!()")
    register_simviz_helper!(:combine_entities!, :creation, "combine_entities!([ctx,] handles; new_type=:assembly) -> EntityHandle", "Combine multiple entities into a composite assembly", "asm = combine_entities!(items)")
    register_simviz_helper!(:split_entity!, :creation, "split_entity!([ctx,] [parent=item(),] count; child_type=:subpart, out_port=:out_flow) -> Vector{EntityHandle}", "Split entity into count child entities", "split_entity!(3, child_type=:subpart)")

    # Category 13: Visuals, Randomness & Custom Telemetry (19)
    register_simviz_helper!(:set_color!, :visuals, "set_color!([ctx,] [target=item(),] color)", "Set 3D/2D color override (:red, :green, :gold, or RGB)", "set_color!(:red)")
    register_simviz_helper!(:set_mesh!, :visuals, "set_mesh!([ctx,] [target=item(),] mesh_type)", "Set 3D mesh (:box, :sphere, :cylinder, :capsule, :pallet)", "set_mesh!(:sphere)")
    register_simviz_helper!(:set_size!, :visuals, "set_size!([ctx,] [target=item(),] scale_or_w, [h, d])", "Set uniform scale or (w, h, d) dimensions", "set_size!(1.4)")
    register_simviz_helper!(:set_label!, :visuals, "set_label!([ctx,] [target=item(),] text)", "Set floating badge/label text on entity", "set_label!(\"VIP\")")
    register_simviz_helper!(:highlight!, :visuals, "highlight!([ctx,] [target=self(),] color=:gold; duration=2.0)", "Pulse visual highlight on entity", "highlight!(:gold, duration=2.0)")
    register_simviz_helper!(:sim_time, :random, "sim_time([ctx]) -> Float64", "Current simulation time [s]", "t = sim_time()")
    register_simviz_helper!(:rng, :random, "rng([ctx])", "Seeded simulation random number generator", "r = rng()")
    register_simviz_helper!(:rand_uniform, :random, "rand_uniform([ctx,] lo=0.0, hi=1.0) -> Float64", "Sample Uniform(lo, hi)", "u = rand_uniform(1.0, 5.0)")
    register_simviz_helper!(:rand_exp, :random, "rand_exp([ctx,] mean_val=1.0) -> Float64", "Sample Exponential(mean_val)", "d = rand_exp(2.0)")
    register_simviz_helper!(:rand_normal, :random, "rand_normal([ctx,] mean_val=0.0, std_val=1.0) -> Float64", "Sample Normal(mean_val, std_val)", "x = rand_normal(10.0, 1.5)")
    register_simviz_helper!(:rand_triangular, :random, "rand_triangular([ctx,] min_v, mode_v, max_v) -> Float64", "Sample Triangular(min_v, mode_v, max_v)", "s = rand_triangular(1.0, 2.0, 5.0)")
    register_simviz_helper!(:rand_int, :random, "rand_int([ctx,] lo, hi) -> Int", "Sample discrete uniform integer in lo:hi", "k = rand_int(1, 6)")
    register_simviz_helper!(:rand_choice, :random, "rand_choice([ctx,] items, [weights])", "Sample element from collection (optionally weighted)", "c = rand_choice([:A, :B], [0.7, 0.3])")
    register_simviz_helper!(:coin_flip, :random, "coin_flip([ctx,] p=0.5) -> Bool", "Bernoulli trial with probability p", "if coin_flip(0.1); set_color!(:red); end")
    register_simviz_helper!(:record_metric!, :telemetry, "record_metric!([ctx,] name, value)", "Record custom time-series metric sample", "record_metric!(:wip_score, queue_length())")
    register_simviz_helper!(:increment_counter!, :telemetry, "increment_counter!([ctx,] name, by=1) -> Int64", "Increment named custom counter", "increment_counter!(:parts_inspected)")
    register_simviz_helper!(:set_gauge!, :telemetry, "set_gauge!([ctx,] name, value) -> Float64", "Update named custom scalar gauge", "set_gauge!(:line_speed, speed())")
    register_simviz_helper!(:record_histogram!, :telemetry, "record_histogram!([ctx,] name, sample) -> Float64", "Append sample to named custom histogram", "record_histogram!(:cycle_times, wait_time())")
    register_simviz_helper!(:record_tally!, :telemetry, "record_tally!([ctx,] name, sample) -> Float64", "Update running mean tally with sample", "record_tally!(:avg_wait, wait_time())")
    register_simviz_helper!(:log_event!, :telemetry, "log_event!([ctx,] message)", "Append timestamped message to simulation event log", "log_event!(\"Changeover triggered\")")
    return nothing
end
_init_simviz_helper_catalog!()

"""
    helper_docs_markdown(; category::Union{Nothing, Symbol} = nothing) -> String

Generate a formatted Markdown reference of all registered `SimCore.SimViz` helper primitives
(optionally filtered by `category`).
"""
function helper_docs_markdown(; category::Union{Nothing, Symbol}=nothing)::String
    io = IOBuffer()
    println(io, "# SimViz Helper Library Reference\n")
    for meta in list_simviz_helpers(; category=category)
        println(io, "### `", meta.signature, "`")
        println(io, "- **Category:** `:", meta.category, "`")
        println(io, "- **Description:** ", meta.summary)
        if !isempty(meta.example)
            println(io, "- **Example:** `", meta.example, "`")
        end
        println(io)
    end
    return String(take!(io))
end

# Attach rich Julia REPL / IDE docstrings to all 114 catalog functions at precompile time
for _meta in HELPER_CATALOG
    if isdefined(@__MODULE__, _meta.name)
        _doc_str = string(
            "    ", _meta.signature, "\n\n",
            _meta.summary, ".\n\n",
            "- **Category:** `:", _meta.category, "`\n",
            "- **Hook Context:** Inside any hook (`on_entry`, `on_exit`, `on_service_start`, `on_service_complete`, `on_pull`, `on_event`), `ctx` is resolved automatically via `current_ctx()`. Station/structural queries default to `self()`, and item/visual/attribute helpers default to `item()`.\n",
            isempty(_meta.example) ? "" : string("\n# Example\n```julia\n", _meta.example, "\n```\n")
        )
        @eval @doc $_doc_str $(_meta.name)
    end
end

# ── SimViz Submodule (Clean Namespace for `using SimCore.SimViz`) ────────────

module SimViz
    using ..SimCore:
        EntityHandle, INVALID_HANDLE, EntityKinematics, PortDescriptor, PortWireLink,
        PortDirectory, UserTelemetryStore, EntityStateView,
        HookOpCode, HookCommand, PortCandidate, HookContext,
        current_ctx, with_hook_context, HelperFunctionMeta, HELPER_CATALOG,
        register_simviz_helper!, list_simviz_helpers, helper_docs_markdown,
        register_entity_handle!, register_port!, register_port_wire!,
        # Category 1: Identity & Selectors
        self, self_handle, self_id, item, item_handle, item_id,
        entity_handle, entity, entity_name, entity_kind,
        entities_of_kind, entities_where, entities_in_group, all_entities,
        # Category 2: Ports & Connected-Entity Selectors
        ports, input_ports, output_ports, has_port, port_direction, port_domain, port_cardinality,
        is_connected, connection_count, connected_ports, connected_entities, connected_entity,
        connected_entity_where, connected_entities_where, connected_entity_argmin, connected_entity_argmax,
        upstream_entities, downstream_entities, send_signal!, read_signal, emit_port_event!,
        # Category 3: Containment Hierarchy
        container_entity, root_container, ancestors, has_container,
        contained_entities, contained_count, contains_entity,
        contained_entity, first_contained, last_contained,
        contained_entity_where, contained_entities_where, contained_entity_argmin, contained_entity_argmax,
        put_inside!, take_out!,
        # Category 4: Multi-Queue Pull / Intake
        port_head_items, port_all_items,
        pull_from_port!, pull_from_port_slot_order!, pull_from_port_round_robin!,
        pull_from_port_longest!, pull_from_port_highest_fill!,
        pull_from_port_where!, pull_from_port_argmin!, pull_from_port_argmax!, set_intake_mode!,
        # Category 5: Attributes & Metadata
        attr, get_attr, num_attr, str_attr, bool_attr, has_attr, set_attr!, inc_attr!, delete_attr!, clear_attrs!,
        get_attribute, set_attribute!, increment_attribute!, has_attribute, delete_attribute!,
        priority, set_priority!, arrival_time, wait_time, due_date, slack, critical_ratio,
        # Category 6: State & Capacity Queries
        queue_length, in_service, num_servers, capacity, free_capacity, utilization, fill_ratio,
        is_full, is_empty, is_busy, is_down, queued_entities, head_entity, tail_entity,
        shortest_entity, least_utilized_entity, find_entity, filter_entities,
        zone_queue_length, zone_in_service, zone_num_servers, zone_capacity, zone_free_capacity,
        zone_utilization, is_zone_full, is_zone_busy, is_zone_down, shortest_zone, least_utilized_zone,
        # Category 7: Control & Actuation
        set_capacity!, set_servers!, pause!, resume!, trigger_failure!, trigger_repair!, flush_queue!,
        set_zone_capacity!, set_zone_servers!, pause_zone!, resume_zone!,
        # Category 8: Routing & Flow Control
        route_to!, route_to_port!, route_to_shortest!, route_to_fastest!, exit_system!,
        hold_entity!, release_entity!, preempt_server!, clone_entity!, batch_entities!, unbatch_entity!,
        # Category 9: Custom Server Construction
        set_service_time!, add_setup_time!, start_service!, complete_service!,
        seize_capacity!, release_capacity!, dequeue_where!, last_processed_attr,
        # Category 10: Low-Level DEVS Event Scheduling
        set_process_mode!, schedule_event!, schedule_at!, schedule_every!,
        cancel_event!, cancel_all_events!, event_tag, event_payload, after!, forward_entity!,
        # Category 11: Spatial & Conveyor Kinematics
        set_conveyor_mode!, path_length, distance, progress, speed,
        set_distance!, set_progress!, step_distance!, set_speed!,
        entities_along_path, entity_ahead, entity_behind, gap_ahead,
        world_pos, set_world_pos!, distance_between,
        # Category 12: Dynamic Entity Creation
        define_entity_type!, create_entity!, spawn_to_port!, destroy_entity!,
        combine_entities!, split_entity!,
        # Category 13: Visuals, Randomness & Telemetry
        set_color!, set_mesh!, set_size!, set_label!, highlight!,
        sim_time, rng, rand_uniform, rand_exp, rand_normal, rand_triangular, rand_int, rand_choice, coin_flip,
        record_metric!, increment_counter!, set_gauge!, record_histogram!, record_tally!, log_event!

    export EntityHandle, INVALID_HANDLE, EntityKinematics, PortDescriptor, PortWireLink,
        PortDirectory, UserTelemetryStore, EntityStateView,
        HookOpCode, HookCommand, PortCandidate, HookContext,
        current_ctx, with_hook_context, HelperFunctionMeta, HELPER_CATALOG,
        register_simviz_helper!, list_simviz_helpers, helper_docs_markdown,
        register_entity_handle!, register_port!, register_port_wire!,
        self, self_handle, self_id, item, item_handle, item_id,
        entity_handle, entity, entity_name, entity_kind,
        entities_of_kind, entities_where, entities_in_group, all_entities,
        ports, input_ports, output_ports, has_port, port_direction, port_domain, port_cardinality,
        is_connected, connection_count, connected_ports, connected_entities, connected_entity,
        connected_entity_where, connected_entities_where, connected_entity_argmin, connected_entity_argmax,
        upstream_entities, downstream_entities, send_signal!, read_signal, emit_port_event!,
        container_entity, root_container, ancestors, has_container,
        contained_entities, contained_count, contains_entity,
        contained_entity, first_contained, last_contained,
        contained_entity_where, contained_entities_where, contained_entity_argmin, contained_entity_argmax,
        put_inside!, take_out!,
        port_head_items, port_all_items,
        pull_from_port!, pull_from_port_slot_order!, pull_from_port_round_robin!,
        pull_from_port_longest!, pull_from_port_highest_fill!,
        pull_from_port_where!, pull_from_port_argmin!, pull_from_port_argmax!, set_intake_mode!,
        attr, get_attr, num_attr, str_attr, bool_attr, has_attr, set_attr!, inc_attr!, delete_attr!, clear_attrs!,
        get_attribute, set_attribute!, increment_attribute!, has_attribute, delete_attribute!,
        priority, set_priority!, arrival_time, wait_time, due_date, slack, critical_ratio,
        queue_length, in_service, num_servers, capacity, free_capacity, utilization, fill_ratio,
        is_full, is_empty, is_busy, is_down, queued_entities, head_entity, tail_entity,
        shortest_entity, least_utilized_entity, find_entity, filter_entities,
        zone_queue_length, zone_in_service, zone_num_servers, zone_capacity, zone_free_capacity,
        zone_utilization, is_zone_full, is_zone_busy, is_zone_down, shortest_zone, least_utilized_zone,
        set_capacity!, set_servers!, pause!, resume!, trigger_failure!, trigger_repair!, flush_queue!,
        set_zone_capacity!, set_zone_servers!, pause_zone!, resume_zone!,
        route_to!, route_to_port!, route_to_shortest!, route_to_fastest!, exit_system!,
        hold_entity!, release_entity!, preempt_server!, clone_entity!, batch_entities!, unbatch_entity!,
        set_service_time!, add_setup_time!, start_service!, complete_service!,
        seize_capacity!, release_capacity!, dequeue_where!, last_processed_attr,
        set_process_mode!, schedule_event!, schedule_at!, schedule_every!,
        cancel_event!, cancel_all_events!, event_tag, event_payload, after!, forward_entity!,
        set_conveyor_mode!, path_length, distance, progress, speed,
        set_distance!, set_progress!, step_distance!, set_speed!,
        entities_along_path, entity_ahead, entity_behind, gap_ahead,
        world_pos, set_world_pos!, distance_between,
        define_entity_type!, create_entity!, spawn_to_port!, destroy_entity!,
        combine_entities!, split_entity!,
        set_color!, set_mesh!, set_size!, set_label!, highlight!,
        sim_time, rng, rand_uniform, rand_exp, rand_normal, rand_triangular, rand_int, rand_choice, coin_flip,
        record_metric!, increment_counter!, set_gauge!, record_histogram!, record_tally!, log_event!
end
