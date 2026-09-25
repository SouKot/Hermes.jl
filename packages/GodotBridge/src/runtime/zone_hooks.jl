# packages/GodotBridge/src/runtime/zone_hooks.jl
#
# ZoneHooks — user-supplied Julia closures fired at canonical lifecycle events.
# Hook functions must match the signature: (entity_id::Int, zone_id::String, t::Float64) -> Nothing
# (world is NOT passed for safety — hooks are read-only observers)

"""
    ZoneHooks

Mutable container of lifecycle hooks for a single simulation zone.
All fields default to `nothing` (disabled).

Set any field to a `Function` to enable that hook.
Hooks are called synchronously during `SimDES.dispatch!`.
Any exception thrown in a hook is caught, logged, and the hook is auto-disabled.
"""
@kwdef mutable struct ZoneHooks
    on_entry            ::Union{Nothing, Function} = nothing
    on_service_start    ::Union{Nothing, Function} = nothing
    on_service_complete ::Union{Nothing, Function} = nothing
    on_exit             ::Union{Nothing, Function} = nothing
end

"""
    call_hook(hooks, field, entity_id, zone_id, t)

Safely call a hook. Catches all exceptions, logs a warning, and auto-disables the hook.
"""
function call_hook!(hooks::ZoneHooks, field::Symbol, entity_id::Int, zone_id::String, t::Float64)
    fn = getfield(hooks, field)
    fn === nothing && return
    try
        fn(entity_id, zone_id, t)
    catch e
        @warn "Hook :$(field) on zone $(zone_id) threw an exception — auto-disabling" exception=(e, catch_backtrace())
        setfield!(hooks, field, nothing)
    end
end

# ── Expression evaluator ─────────────────────────────────────────────────────

"""
    parse_hook_expr(src::String) -> Function

Compile a user-supplied Julia expression string into a hook closure.

The expression must be a function body that accepts `(entity_id, zone_id, t)`.
It is evaluated inside an anonymous module for isolation.

Throws `ErrorException` if the expression fails to parse or compile.

Example:
    fn = parse_hook_expr("println(\"Entity \$entity_id entered \$zone_id at t=\$t\")")
"""
function parse_hook_expr(src::String)::Function
    # Wrap the user expression in a proper function signature
    full_src = """
    (entity_id::Int, zone_id::String, t::Float64) -> begin
        $(src)
        nothing
    end
    """
    expr = Meta.parse(full_src)
    # Evaluate in a fresh anonymous module for isolation
    mod = Module()
    fn = Core.eval(mod, expr)
    return fn
end
