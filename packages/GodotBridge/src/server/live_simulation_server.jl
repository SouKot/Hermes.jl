# packages/GodotBridge/src/server/live_simulation_server.jl
#
# Production Live Simulation Server (Port 9107).
# Connects Godot Authoring Shell & Viewports with SimCore / SimDES dynamic compiler runtime.
# Supports real-time SceneSpec compilation in staging, atomic activation,
# and multi-unit stepping (seconds, minutes, hours, days).

using GodotBridge
using SimCore
import SimCore: pause!, set_speed!
using SimDES
using Distributions
using Random
import JSON
import MsgPack

const LIVE_SERVER_PORT = try parse(Int, get(ENV, "SIMVIZ_PORT", "9107")) catch; 9107 end

const VALID_HOOK_EVENTS = Dict(
    "on_entry"            => :on_entry,
    "on_service_start"    => :on_service_start,
    "on_service_complete" => :on_service_complete,
    "on_exit"             => :on_exit,
)

function _to_plain_dict(x)
    if x isa AbstractDict
        d = Dict{String, Any}()
        for (k, v) in x
            d[string(k)] = _to_plain_dict(v)
        end
        return d
    elseif x isa AbstractVector
        return Any[_to_plain_dict(v) for v in x]
    else
        return x
    end
end

function _ensure_simoptim_loaded()
    for (pkgid, mod) in Base.loaded_modules
        if pkgid.name == "SimOptim"
            return mod
        end
    end
    simoptim_dir = normpath(joinpath(@__DIR__, "..", "..", "..", "SimOptim"))
    if !(simoptim_dir in LOAD_PATH)
        push!(LOAD_PATH, simoptim_dir)
    end
    @eval Main using SimOptim
    for (pkgid, mod) in Base.loaded_modules
        if pkgid.name == "SimOptim"
            return mod
        end
    end
    error("Failed to load SimOptim module from $simoptim_dir")
end

function _default_optim_state()
    return Dict{String, Any}(
        "status" => "idle",
        "iteration" => 0,
        "max_iterations" => 0,
        "progress_pct" => 0.0,
        "elapsed_sec" => 0.0,
        "feasible_count" => 0,
        "best_score" => 0.0,
        "best_primary" => 0.0,
        "best_label" => "—",
        "convergence_history" => Any[],
        "scatter_points" => Any[],
        "top_k_solutions" => Any[]
    )
end

"""
    create_default_scene() -> Dict{String, Any}

Generates the default tandem M/M/1 queue & conveyor manufacturing cell.
"""
function create_default_scene()
    return Dict{String, Any}(
        "spec_version" => "1.0.0",
        "scene" => Dict(
            "id" => "phase7c_fixture",
            "name" => "Default Manufacturing Cell",
            "description" => "Default tandem queue and assembly station"
        ),
        "simulation" => Dict(
            "mode" => "des_only",
            "time_unit" => "seconds"
        ),
        "elements" => [
            Dict(
                "id" => "src_infeed",
                "kind" => "source",
                "properties" => Dict(
                    "interarrival_time" => Dict("type" => "exponential", "mean" => 2.5),
                    "entity_type" => "carton"
                ),
                "transform" => Dict("position" => [-6.0, 0.0, 0.8])
            ),
            Dict(
                "id" => "q_staging",
                "kind" => "queue",
                "properties" => Dict(
                    "capacity" => 20,
                    "discipline" => "FIFO"
                ),
                "transform" => Dict("position" => [-3.0, 0.0, 0.8])
            ),
            Dict(
                "id" => "srv_assembly",
                "kind" => "server",
                "properties" => Dict(
                    "servers" => 1,
                    "service_time" => Dict("type" => "exponential", "mean" => 2.0)
                ),
                "transform" => Dict("position" => [0.0, 0.0, 0.8])
            ),
            Dict(
                "id" => "conv_outfeed",
                "kind" => "conveyor",
                "properties" => Dict(
                    "length" => 8.0,
                    "speed" => 1.5,
                    "capacity" => 8
                ),
                "transform" => Dict("position" => [5.0, 0.0, 0.8])
            ),
            Dict(
                "id" => "snk_discharge",
                "kind" => "sink",
                "properties" => Dict(),
                "transform" => Dict("position" => [10.0, 0.0, 0.8])
            )
        ],
        "connections" => [
            Dict("id" => "c_in", "source_element" => "src_infeed", "source_port" => "flow_out", "target_element" => "q_staging", "target_port" => "flow_in"),
            Dict("id" => "c_feed", "source_element" => "q_staging", "source_port" => "flow_out", "target_element" => "srv_assembly", "target_port" => "flow_in"),
            Dict("id" => "c_conv", "source_element" => "srv_assembly", "source_port" => "flow_out", "target_element" => "conv_outfeed", "target_port" => "flow_in"),
            Dict("id" => "c_exit", "source_element" => "conv_outfeed", "source_port" => "flow_out", "target_element" => "snk_discharge", "target_port" => "flow_in")
        ]
    )
end

"""
    start_live_server(; host="127.0.0.1", port=LIVE_SERVER_PORT, debug=false) -> Tuple{GodotBridgeServer, RuntimeManager}

Initializes and starts the production live simulation server.
"""
function start_live_server(; host::String="127.0.0.1", port::Int=LIVE_SERVER_PORT, debug::Bool=false, autostart_ws::Bool=true)
    server = GodotBridgeServer(host=host, port=port, snapshot_rate_hz=30, debug=debug)
    manager = RuntimeManager()

    # Pre-compile and activate default model
    default_spec = create_default_scene()
    stage_and_activate!(manager, default_spec)

    step_counter = Ref{UInt64}(0)
    optim_state_ref = Ref{Dict{String, Any}}(_default_optim_state())
    optim_stop_ref = Ref{Bool}(false)
    optim_task_ref = Ref{Any}(nothing)

    # Broadcast callback for simulation ticks
    function broadcast_current_snapshot(sim_t::Float64)
        if server.is_running && !isempty(server.clients)
            inst = manager.active_instance
            if inst !== nothing
                step_counter[] += 1
                snap = build_snapshot(inst; scene_id=inst.id, step_count=step_counter[])
                snap.abm_state["optim_state"] = optim_state_ref[]
                # Broadcast DirectSnapshotPayload to clients
                broadcast_snapshot(server, snap)
            end
        end
    end

    # Note: Do NOT autostart on boot. Simulation begins in PAUSED state (t = 0.00s)
    # waiting for the user to explicitly click ▶ PLAY in the Godot client.

    # Periodic background heartbeat to broadcast snapshot when paused
    @async begin
        while server.is_running
            if !isempty(server.clients) && manager.active_instance !== nothing && manager.active_instance.is_paused[]
                broadcast_current_snapshot(manager.active_instance.world.time)
            end
            sleep(0.5)
        end
    end

    # Command Handler
    register_handler!(server, "command", function(message)
        payload = message.payload
        cmd_type = String(payload.command_type)
        cmd_dict = payload.command isa AbstractDict ? payload.command : Dict{String, Any}()
        action = String(get(cmd_dict, "action", cmd_type))

        # Respect target scene_id if specified in incoming command
        if manager.active_instance !== nothing && !isempty(payload.scene_id)
            manager.active_instance.id = payload.scene_id
        end

        if cmd_type == "compile_and_run" || action == "compile_and_run"
            raw_spec = get(cmd_dict, "scenespec", cmd_dict)
            spd = Float64(get(cmd_dict, "speed", 1.0))
            success, diags = stage_and_activate!(manager, raw_spec; clock_speed=spd)

            if success
                # Broadcast immediately and start playing
                broadcast_current_snapshot(manager.active_instance.world.time)
                GodotBridge.play!(manager, broadcast_current_snapshot)
                return create_ack(message.envelope.message_id, status="accepted", details="SceneSpec compiled successfully into $(length(manager.active_instance.configs)) zones")
            else
                diag_messages = join([d.message for d in diags], "; ")
                @error "Scene compilation rejected" diagnostics=diag_messages
                return create_ack(message.envelope.message_id, status="rejected", details="Compilation failed: $diag_messages")
            end

        elseif cmd_type == "play" || action == "play"
            GodotBridge.play!(manager, broadcast_current_snapshot)
            if manager.active_instance !== nothing
                broadcast_current_snapshot(manager.active_instance.world.time)
            end
            return create_ack(message.envelope.message_id, status="accepted", details="Simulation running")

        elseif cmd_type == "pause" || action == "pause"
            GodotBridge.pause!(manager)
            if manager.active_instance !== nothing
                broadcast_current_snapshot(manager.active_instance.world.time)
            end
            return create_ack(message.envelope.message_id, status="accepted", details="Simulation paused")

        elseif cmd_type == "step" || action == "step"
            dur = Float64(get(cmd_dict, "duration", get(cmd_dict, "step_size", 1.0)))
            unit = String(get(cmd_dict, "unit", "s"))
            new_t = GodotBridge.step!(manager, dur, unit, broadcast_current_snapshot)
            broadcast_current_snapshot(new_t)
            return create_ack(message.envelope.message_id, status="accepted", details="Stepped to $new_t seconds")

        elseif cmd_type == "reset" || action == "reset"
            GodotBridge.pause!(manager)
            optim_stop_ref[] = true
            # Recompile current active or default scene to reset all state cleanly
            raw_spec = get(cmd_dict, "scenespec", default_spec)
            stage_and_activate!(manager, raw_spec)
            broadcast_current_snapshot(0.0)
            return create_ack(message.envelope.message_id, status="accepted", details="Simulation reset")

        elseif cmd_type == "set_clock_speed" || action == "set_clock_speed"
            spd = Float64(get(cmd_dict, "speed", 1.0))
            if manager.active_instance !== nothing
                GodotBridge.set_speed!(manager.active_instance, spd)
                broadcast_current_snapshot(manager.active_instance.world.time)
            end
            return create_ack(message.envelope.message_id, status="accepted", details="Clock speed updated to $spd")

        elseif cmd_type == "set_hook" || action == "set_hook"
            element_id = get(cmd_dict, "element_id", "")
            event_name = get(cmd_dict, "event", "")
            code_src   = get(cmd_dict, "code",  "")

            if isempty(element_id) || isempty(event_name)
                return create_ack(message.envelope.message_id, status="rejected", details="set_hook requires element_id and event")
            elseif !haskey(VALID_HOOK_EVENTS, event_name)
                return create_ack(message.envelope.message_id, status="rejected", details="Unknown hook event '$(event_name)'; valid: $(join(keys(VALID_HOOK_EVENTS), ", "))")
            elseif manager.active_instance === nothing
                return create_ack(message.envelope.message_id, status="rejected", details="No active simulation instance")
            else
                try
                    fn = isempty(code_src) ? nothing : parse_hook_expr(code_src)
                    hooks = get!(manager.active_instance.zone_hooks, element_id, ZoneHooks())
                    field = VALID_HOOK_EVENTS[event_name]
                    setfield!(hooks, field, fn)
                    manager.active_instance.zone_hooks[element_id] = hooks
                    return create_ack(message.envelope.message_id, status="accepted", details="Hook set for $(element_id)")
                catch e
                    return create_ack(message.envelope.message_id, status="rejected", details="Hook compile error: $(sprint(showerror, e))")
                end
            end

        elseif cmd_type == "load_example" || action == "load_example"
            ex_id = String(get(cmd_dict, "example_id", ""))
            try
                GodotBridge.pause!(manager)
                optim_stop_ref[] = true
                optim_state_ref[] = _default_optim_state()
                ex_spec = haskey(cmd_dict, "scenespec") && cmd_dict["scenespec"] isa AbstractDict ?
                          _to_plain_dict(cmd_dict["scenespec"]) : get_example_scenespec(ex_id)
                default_spec = ex_spec
                success, diags = stage_and_activate!(manager, ex_spec)
                if success
                    broadcast_current_snapshot(0.0)
                    return create_ack(message.envelope.message_id, status="accepted", details="Loaded example '$ex_id'")
                else
                    diag_messages = join([d.message for d in diags], "; ")
                    return create_ack(message.envelope.message_id, status="rejected", details="Example '$ex_id' failed to compile: $diag_messages")
                end
            catch e
                return create_ack(message.envelope.message_id, status="rejected", details="Failed to load example '$ex_id': $(sprint(showerror, e))")
            end

        elseif cmd_type in ("run_optimization", "start_optimization") || action in ("run_optimization", "start_optimization")
            try
                GodotBridge.pause!(manager)
                optim_stop_ref[] = true
                if optim_task_ref[] isa Task && !istaskdone(optim_task_ref[])
                    sleep(0.05)
                end

                simoptim_mod = _ensure_simoptim_loaded()
                raw_spec = haskey(cmd_dict, "scenespec") && cmd_dict["scenespec"] isa AbstractDict ?
                           _to_plain_dict(cmd_dict["scenespec"]) : deepcopy(default_spec)
                if haskey(cmd_dict, "optimization") && cmd_dict["optimization"] isa AbstractDict
                    raw_spec["optimization"] = _to_plain_dict(cmd_dict["optimization"])
                end

                if !haskey(raw_spec, "optimization") || !(raw_spec["optimization"] isa AbstractDict)
                    return create_ack(message.envelope.message_id, status="rejected", details="SceneSpec does not contain an 'optimization' specification")
                end

                optim_stop_ref[] = false
                optim_state_ref[] = merge(_default_optim_state(), Dict{String, Any}("status" => "running"))
                broadcast_current_snapshot(0.0)

                optim_task_ref[] = @async begin
                    try
                        progress_cb = function(ctx)
                            st = Base.invokelatest(simoptim_mod.optim_state_to_dict, ctx; status="running")
                            optim_state_ref[] = st
                            broadcast_current_snapshot(0.0)
                            yield()
                        end
                        _, final_ctx = Base.invokelatest(
                            simoptim_mod.run_optimization!,
                            raw_spec;
                            on_progress = progress_cb,
                            stop_requested = optim_stop_ref
                        )
                        final_status = optim_stop_ref[] ? "stopped" : "completed"
                        optim_state_ref[] = Base.invokelatest(simoptim_mod.optim_state_to_dict, final_ctx; status=final_status)
                        broadcast_current_snapshot(0.0)
                    catch err
                        @error "Async SimOptim task failed" exception=(err, catch_backtrace())
                        st_err = copy(optim_state_ref[])
                        st_err["status"] = "error"
                        st_err["error_message"] = sprint(showerror, err)
                        optim_state_ref[] = st_err
                        broadcast_current_snapshot(0.0)
                    end
                end

                return create_ack(message.envelope.message_id, status="accepted", details="Optimization started asynchronously")
            catch e
                return create_ack(message.envelope.message_id, status="rejected", details="Failed to start optimization: $(sprint(showerror, e))")
            end

        elseif cmd_type == "stop_optimization" || action == "stop_optimization"
            optim_stop_ref[] = true
            st = copy(optim_state_ref[])
            if get(st, "status", "idle") == "running"
                st["status"] = "stopped"
                optim_state_ref[] = st
            end
            broadcast_current_snapshot(0.0)
            return create_ack(message.envelope.message_id, status="accepted", details="Optimization stop requested")

        elseif cmd_type in ("apply_best_solution", "apply_solution") || action in ("apply_best_solution", "apply_solution")
            try
                GodotBridge.pause!(manager)
                cand_spec = nothing
                if haskey(cmd_dict, "scenespec") && cmd_dict["scenespec"] isa AbstractDict
                    cand_spec = _to_plain_dict(cmd_dict["scenespec"])
                else
                    rank = Int(get(cmd_dict, "rank", 1))
                    top_k = get(optim_state_ref[], "top_k_solutions", Any[])
                    for item in top_k
                        if item isa AbstractDict && Int(get(item, "rank", 0)) == rank && haskey(item, "scenespec")
                            cand_spec = _to_plain_dict(item["scenespec"])
                            break
                        end
                    end
                    if cand_spec === nothing && !isempty(top_k) && top_k[1] isa AbstractDict && haskey(top_k[1], "scenespec")
                        cand_spec = _to_plain_dict(top_k[1]["scenespec"])
                    end
                end

                if cand_spec === nothing
                    return create_ack(message.envelope.message_id, status="rejected", details="No candidate SceneSpec available to apply")
                end

                default_spec = cand_spec
                success, diags = stage_and_activate!(manager, cand_spec)
                if success
                    broadcast_current_snapshot(0.0)
                    return create_ack(message.envelope.message_id, status="accepted", details="Applied candidate solution to active simulation runtime")
                else
                    diag_messages = join([d.message for d in diags], "; ")
                    return create_ack(message.envelope.message_id, status="rejected", details="Candidate failed to compile: $diag_messages")
                end
            catch e
                return create_ack(message.envelope.message_id, status="rejected", details="Failed to apply candidate solution: $(sprint(showerror, e))")
            end
        end

        return create_ack(message.envelope.message_id, status="ignored", details="Unknown command $cmd_type")
    end)

    if autostart_ws
        @async GodotBridge.start(server)
        sleep(0.3)
    end
    return (server, manager)
end

# Standalone entrypoint
if abspath(PROGRAM_FILE) == @__FILE__
    println("==================================================================")
    println("Starting Hermes / SimCore Live Simulation Server on port $(LIVE_SERVER_PORT)...")
    println("==================================================================")
    server, manager = start_live_server(port=LIVE_SERVER_PORT, debug=true)
    println("Server listening on 127.0.0.1:$(LIVE_SERVER_PORT). Ready for Godot connections.")

    # Keep alive
    while server.is_running
        sleep(1.0)
    end
end
