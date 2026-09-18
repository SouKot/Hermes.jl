using GodotBridge

const PORT = 9107
server = GodotBridgeServer(host="127.0.0.1", port=PORT, snapshot_rate_hz=30, debug=true)
snapshot_delay_ms = try parse(Int, get(ENV, "SIMVIZ_SNAPSHOT_DELAY_MS", "0")) catch; 0 end
drop_every = try parse(Int, get(ENV, "SIMVIZ_DROP_EVERY", "0")) catch; 0 end
snapshot_sequence = Ref(0)
simulation_time_ref = Ref(12.5)
clock_speed_ref = Ref(1.0)
paused_ref = Ref(false)

register_handler!(server, "command", function(message)
    command_type = String(message.payload.command_type)
    if command_type == "play"
        paused_ref[] = false
    elseif command_type == "pause"
        paused_ref[] = true
    elseif command_type == "step"
        paused_ref[] = true
        simulation_time_ref[] += 0.1
    elseif command_type == "reset"
        paused_ref[] = true
        simulation_time_ref[] = 0.0
    elseif command_type == "set_clock_speed"
        requested_speed = get(message.payload.command, "speed", 1.0)
        clock_speed_ref[] = clamp(Float64(requested_speed), 0.25, 4.0)
    end
    if command_type == "step" || command_type == "reset" || command_type == "pause" || command_type == "set_clock_speed"
        if server.is_running && !isempty(server.clients)
            broadcast_snapshot(server, make_snapshot(simulation_time_ref[]))
        end
    end
    create_ack(message.envelope.message_id, status="accepted", details="$(command_type) applied")
end)

server_task = @async GodotBridge.start(server)

# Allow the HTTP/WebSocket listener to bind before the client starts.
sleep(0.5)

function make_entity(entity_id::String, phase::Float64, simulation_time::Float64)
    trajectory = [[95.0 * cos((t + phase) * 1.4), 65.0 * sin((t + phase) * 1.4)] for t in range(max(0.0, simulation_time - 4.0), simulation_time; length=16)]
    return Dict{String, Any}(
        "id" => entity_id,
        "kind" => "customer",
        "current_location" => "queue-1",
        "arrival_time" => 4.0 + phase,
        "trajectory_2d" => trajectory,
        "properties" => Dict{String, Any}("priority" => 1 + Int(round(phase)))
    )
end

function entity_position(phase::Float64, simulation_time::Float64)
    angle = (simulation_time + phase) * 1.4
    return (95.0 * cos(angle), 65.0 * sin(angle))
end

function density_from_entities(phases, simulation_time::Float64)
    origin_x = -120.0
    origin_y = -100.0
    cell_size = 40.0
    width = 7
    height = 5
    sigma = 28.0
    positions = [entity_position(phase, simulation_time) for phase in phases]
    return [[sum(exp(-((origin_x + (column - 0.5) * cell_size - position[1])^2 +
                       (origin_y + (row - 0.5) * cell_size - position[2])^2) / (2.0 * sigma^2))
                    for position in positions)
              for column in 1:width]
             for row in 1:height]
end

function make_snapshot(simulation_time::Float64)
    phases = [0.0, 0.8, 1.6, 2.4, 3.2, 4.0]
    density_field = density_from_entities(phases, simulation_time)
    return SnapshotPayload(
        snapshot_version="1.0.0",
        scene_id="phase7c_fixture",
        simulation_time=simulation_time,
        step_count=UInt64(round(simulation_time * 10)),
        clock_speed=Float32(clock_speed_ref[]),
        simulation_state=paused_ref[] ? "paused" : "running",
        elements_state=[Dict{String, Any}(
            "element_id" => "queue-1",
            "element_kind" => "queue",
            "occupancy" => UInt32(3),
            "custom_metrics" => Dict{String, Any}("throughput" => 1.5)
        )],
        entities=[make_entity("entity-1", 0.0, simulation_time),
            make_entity("entity-2", 0.8, simulation_time),
            make_entity("entity-3", 1.6, simulation_time),
            make_entity("entity-4", 2.4, simulation_time),
            make_entity("entity-5", 3.2, simulation_time),
            make_entity("entity-6", 4.0, simulation_time)],
        abm_state=Dict{String, Any}(
            "density_field" => density_field,
            "density_min" => 0.0,
            "density_max" => 6.0,
            "grid_origin" => [-120.0, -100.0],
            "cell_size" => 40.0
        ),
        overlays=Dict{String, Any}[],
        warnings=String[],
        truncated=false
    )
end

function broadcast_test_snapshot(simulation_time::Float64)
    snapshot_sequence[] += 1
    if drop_every > 0 && snapshot_sequence[] % drop_every == 0
        return
    end
    if snapshot_delay_ms > 0
        sleep(snapshot_delay_ms / 1000.0)
    end
    broadcast_snapshot(server, make_snapshot(simulation_time))
end

# Wait for the Godot client, then send a real binary snapshot.
for _ in 1:80
    !isempty(server.clients) && break
    sleep(0.1)
end
if server.is_running && !isempty(server.clients)
    broadcast_test_snapshot(simulation_time_ref[])
end
println("Fixture running. Press Ctrl-C to stop.")
last_snapshot_time = time()
while server.is_running
    current_time = time()
    elapsed = current_time - last_snapshot_time
    if !isempty(server.clients) && !paused_ref[] && elapsed >= (1.0 / 30.0)
        simulation_time_ref[] += elapsed * clock_speed_ref[]
            broadcast_test_snapshot(simulation_time_ref[])
        global last_snapshot_time = current_time
    end
    sleep(1.0 / 60.0)
end
println("Phase 7C fixture server stopped")
