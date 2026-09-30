# packages/GodotBridge/src/runtime/zone_hooks.jl
#
# ZoneHooks — user-supplied Julia closures fired at canonical lifecycle events.
# Supports both HookContext-based SimViz DSL (`self()`, `item()`, `set_speed!`, etc.)
# and legacy 3-argument `(entity_id, zone_id, t)` signatures.

using SimCore
using SimCore.SimViz
using SimDES

"""
    ZoneHooks

Mutable container of lifecycle hooks for a single simulation entity (station, queue, conveyor).
All fields default to `nothing` (disabled).
"""
@kwdef mutable struct ZoneHooks
    on_entry            ::Union{Nothing, Function} = nothing
    on_service_start    ::Union{Nothing, Function} = nothing
    on_service_complete ::Union{Nothing, Function} = nothing
    on_exit             ::Union{Nothing, Function} = nothing
    on_event            ::Union{Nothing, Function} = nothing
    on_pull             ::Union{Nothing, Function} = nothing
end

"""
    call_hook!(hooks::ZoneHooks, field::Symbol, ctx::SimCore.HookContext)
    call_hook!(hooks::ZoneHooks, field::Symbol, entity_id::Int, zone_id::String, t::Float64)

Safely invoke a lifecycle hook inside `SimCore.with_hook_context(ctx)`.
Catches all exceptions, logs a warning, and auto-disables the offending hook.
"""
function call_hook!(hooks::ZoneHooks, field::Symbol, ctx::SimCore.HookContext)
    fn = getfield(hooks, field)
    fn === nothing && return nothing
    try
        SimCore.with_hook_context(ctx) do active_ctx
            if applicable(fn, active_ctx, Int(active_ctx.entity_id), active_ctx.element_id, active_ctx.t)
                Base.invokelatest(fn, active_ctx, Int(active_ctx.entity_id), active_ctx.element_id, active_ctx.t)
            elseif applicable(fn, active_ctx)
                Base.invokelatest(fn, active_ctx)
            else
                Base.invokelatest(fn, Int(active_ctx.entity_id), active_ctx.element_id, active_ctx.t)
            end
        end
    catch e
        @warn "Hook :$(field) on entity $(ctx.element_id) threw an exception — auto-disabling" exception=(e, catch_backtrace())
        setfield!(hooks, field, nothing)
    end
    return nothing
end

function call_hook!(hooks::ZoneHooks, field::Symbol, entity_id::Int, zone_id::String, t::Float64)
    w = SimCore.SimWorld()
    w.time = t
    ctx = SimCore.HookContext(w, entity_id, 1, zone_id, t)
    return call_hook!(hooks, field, ctx)
end

"""
    apply_hook_mutations!(world, fel, configs, rng, ctx::SimCore.HookContext)

Apply any structural mutations or commands recorded on `ctx` during hook execution.
"""
function apply_hook_mutations!(
    world::SimCore.SimWorld,
    fel::SimDES.FutureEventList,
    configs::Dict{Int, SimDES.ZoneConfig},
    rng,
    ctx::SimCore.HookContext
)
    SimDES.apply_hook_commands!(world, fel, configs, rng, ctx)
    return nothing
end

# ── Expression evaluator ─────────────────────────────────────────────────────

"""
    parse_hook_expr(src::String) -> Function

Compile a user-supplied Julia expression string into a hook closure with full
access to the `SimCore.SimViz` helper library (`self()`, `item()`, `container_entity()`,
`contained_entities()`, `connected_entities()`, `pull_from_port_argmax!()`, `set_speed!()`,
`set_color!()`, `route_to!()`, `schedule_event!()`, etc.) as well as `ctx`, `entity_id`,
`zone_id`, and `t`.
"""
function parse_hook_expr(src::AbstractString)::Function
    full_src = """
    function _simviz_hook_fn(ctx::SimCore.HookContext, entity_id::Int=Int(ctx.entity_id), zone_id::String=ctx.element_id, t::Float64=ctx.t)
        $(src)
        return nothing
    end
    """
    expr = Meta.parse(full_src)
    mod = Module()
    Core.eval(mod, :(using SimCore))
    Core.eval(mod, :(using SimCore.SimViz))
    fn = Core.eval(mod, expr)
    # Also define 3-arg overload on the same function in `mod` for legacy direct callers
    legacy_expr = Meta.parse("""
    function _simviz_hook_fn(entity_id::Int, zone_id::String, t::Float64)
        w = SimCore.SimWorld()
        w.time = t
        ctx = SimCore.HookContext(w, entity_id, 1, zone_id, t)
        return SimCore.with_hook_context(c -> _simviz_hook_fn(c, entity_id, zone_id, t), ctx)
    end
    """)
    Core.eval(mod, legacy_expr)
    return fn
end

