using Test
using SimOptim
using GodotBridge

@testset "Phase 7E-4: Live Server Asynchronous Optimization & Apply Best Solution" begin
    server, manager = GodotBridge.start_live_server(autostart_ws=false)
    cmd_handler = server.message_handlers["command"]

    function make_cmd_msg(cmd_type::String, cmd_dict::Dict{String, Any})
        env = GodotBridge.MessageEnvelope("1.0", "msg_test_1", UInt64(0), "godot_gui", "julia_runtime", "command")
        payload = GodotBridge.CommandPayload("1.0", cmd_type, cmd_dict, "opt_p1_er_allocation", nothing)
        return GodotBridge.Message(env, payload)
    end

    # 1. Start async optimization on Problem 1 (ER Server Allocation)
    p1_spec = GodotBridge.get_example_scenespec("opt_p1_er_allocation")
    p1_spec["optimization"]["solver"]["max_evaluations"] = 12
    p1_spec["optimization"]["solver"]["replications_per_eval"] = 1

    ack_run = cmd_handler(make_cmd_msg("run_optimization", Dict{String, Any}(
        "action" => "run_optimization",
        "scenespec" => p1_spec
    )))
    @test ack_run.payload.status == "accepted"

    # Wait for async optimization task to complete (up to 10s for cold JIT)
    for _ in 1:100
        sleep(0.1)
        if manager.active_instance !== nothing
            # Keep yielding so async task progresses
        end
    end

    # 2. Apply best solution to active simulation runtime
    ack_apply = cmd_handler(make_cmd_msg("apply_best_solution", Dict{String, Any}(
        "action" => "apply_best_solution",
        "rank" => 1
    )))
    if ack_apply.payload.status != "accepted"
        sleep(2.0)
        ack_apply = cmd_handler(make_cmd_msg("apply_best_solution", Dict{String, Any}(
            "action" => "apply_best_solution",
            "rank" => 1
        )))
    end
    @test ack_apply.payload.status == "accepted"
    @test manager.active_instance !== nothing

    # 3. Verify stop_optimization command returns accepted
    ack_stop = cmd_handler(make_cmd_msg("stop_optimization", Dict{String, Any}(
        "action" => "stop_optimization"
    )))
    @test ack_stop.payload.status == "accepted"
end
