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
function start_live_server(; host::String="127.0.0.1", port::Int=LIVE_SERVER_PORT, debug::Bool=false)
    server = GodotBridgeServer(host=host, port=port, snapshot_rate_hz=30, debug=debug)
    manager = RuntimeManager()

    # Pre-compile and activate default model
    default_spec = create_default_scene()
    stage_and_activate!(manager, default_spec)

    step_counter = Ref{UInt64}(0)

    # Broadcast callback for simulation ticks
    function broadcast_current_snapshot(sim_t::Float64)
        if server.is_running && !isempty(server.clients)
            inst = manager.active_instance
            if inst !== nothing
                step_counter[] += 1
                snap = build_snapshot(inst; scene_id=inst.id, step_count=step_counter[])
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
                ex_spec = haskey(cmd_dict, "scenespec") && cmd_dict["scenespec"] isa AbstractDict ?
                          cmd_dict["scenespec"] : get_example_scenespec(ex_id)
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
        end

        return create_ack(message.envelope.message_id, status="ignored", details="Unknown command $cmd_type")
    end)

    @async GodotBridge.start(server)
    sleep(0.3)
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
