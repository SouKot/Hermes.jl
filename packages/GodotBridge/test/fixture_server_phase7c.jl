using GodotBridge

const PORT = 9107
server = GodotBridgeServer(host="127.0.0.1", port=PORT, snapshot_rate_hz=30, debug=true)
server_task = @async GodotBridge.start(server)

# Allow the HTTP/WebSocket listener to bind before the client starts.
sleep(0.5)

snapshot = SnapshotPayload(
    snapshot_version="1.0.0",
    scene_id="phase7c_fixture",
    simulation_time=12.5,
    step_count=UInt64(125),
    clock_speed=1.0f0,
    simulation_state="running",
    elements_state=[Dict{String, Any}(
        "element_id" => "queue-1",
        "element_kind" => "queue",
        "occupancy" => UInt32(3),
        "custom_metrics" => Dict{String, Any}("throughput" => 1.5)
    )],
    entities=[Dict{String, Any}(
        "id" => "entity-1",
        "kind" => "customer",
        "current_location" => "queue-1",
        "arrival_time" => 4.0,
        "trajectory_2d" => [[1.0, 2.0]],
        "properties" => Dict{String, Any}("priority" => 2)
    )],
    abm_state=nothing,
    overlays=Dict{String, Any}[],
    warnings=String[],
    truncated=false
)

# Wait for the Godot client, then send a real binary snapshot.
for _ in 1:80
    !isempty(server.clients) && break
    sleep(0.1)
end
if server.is_running
    broadcast_snapshot(server, snapshot)
end
sleep(10.0)
stop(server)
wait(server_task)
println("Phase 7C fixture server stopped")
