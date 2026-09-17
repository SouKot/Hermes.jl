# Phase 7B.2 Quick Reference Guide

## Building Snapshots

### Simple snapshot with timing only
```julia
using GodotBridge.SnapshotBuilder

snapshot = build_simple_snapshot(
    scene_id="scene_001",
    sim_time=100.5,
    step_count=1005
)

msg = wrap_snapshot_in_message(snapshot)
```

### Full snapshot with elements and entities
```julia
elements = [
    ElementState("q1", "queue", UInt32(5), Dict("avg_wait" => 12.3))
]

entities = [
    EntitySnapshot("e1", "customer", "q1", 50.0, [[1.0, 2.0]], Dict())
]

snapshot = build_snapshot(
    scene_id="scene_001",
    simulation_time=100.5,
    step_count=UInt64(1005),
    elements_state=elements,
    entities=entities
)
```

### Snapshot with ABM state
```julia
abm_state = ABMStateSnapshot(
    model="crowd_sim",
    agents=[Agent(...)],  # Your agent type
    positions=[...],
    velocities=[...],
    density_field=[...],
    velocity_field=[...]
)

snapshot = build_snapshot(
    # ... other params ...
    abm_state=abm_state
)
```

## Computing Deltas

### Compare two snapshots
```julia
using GodotBridge.DeltaBuilder

delta = build_delta(previous_snapshot, current_snapshot)
```

### Check what changed
```julia
summary = get_change_summary(delta)
println("Elements changed: $(summary["elements_changed_count"])")
println("Entities moved: $(summary["entities_moved_count"])")
```

### Create delta message
```julia
delta_msg = create_delta_message(delta)

# Now serialize and send
encoded = encode_messagepack(delta_msg)
# Send encoded data via WebSocket
```

## Dispatching Commands

### Validate a command
```julia
using GodotBridge.CommandHandler

cmd = CommandPayload(
    command_type="set_clock_speed",
    command=Dict("speed" => 2.0)
)

is_valid, error_msg = validate_command(cmd)
if !is_valid
    println("Invalid: $error_msg")
end
```

### Dispatch a command
```julia
ctx = CommandContext(
    command_id=string(uuid4()),
    command_type="play",
    parameters=Dict(),
    sender="godot",
    timestamp=now(),
    execution_state=Dict()
)

result = dispatch_command(ctx)

if result.success
    ack_msg = create_command_ack(result)
else
    error_msg = create_command_error(result)
end
```

### Register custom command handler
```julia
# Custom handler for "play" command
custom_play_handler = (ctx) -> begin
    # Your custom logic here
    return CommandResult(true, ctx.command_id, "play", "executed", 
                        Dict("custom_field" => "value"), nothing, nothing, nothing)
end

result = dispatch_command(ctx, handler=custom_play_handler)
```

## Integration with WebSocket Server

### Send snapshot to all connected clients
```julia
using GodotBridge

server = GodotBridgeServer("127.0.0.1", 9000)
start(server)

snapshot = build_snapshot(...)
broadcast_snapshot(server, snapshot.payload)
```

### Handle incoming commands
```julia
# Register handler for commands
function my_command_handler(server::GodotBridgeServer, msg::Message)
    if msg.payload.command_type == "play"
        # Start your simulation
        println("Simulation started")
        return create_command_ack(CommandResult(...))
    end
    return nothing
end

register_handler!(server, "command", my_command_handler)
```

## Protocol Message Types

### Hello (on client connect)
```julia
HelloPayload(
    protocol_version="1.0",
    runtime_name="GodotBridge",
    capabilities=["snapshots", "deltas", "commands"],
    godot_version="4.2"
)
```

### Snapshot (state update)
```julia
SnapshotPayload(
    snapshot_id=uuid,
    scene_id="scene_001",
    simulation_time=100.5,
    step_count=1005,
    simulation_state="running",
    elements_state=[...],
    entities=[...],
    abm_state=nothing
)
```

### Delta (incremental update)
```julia
DeltaPayload(
    parent_snapshot_id=prev_uuid,
    elements_changed=[...],
    entities_added=[...],
    entities_removed=[...],
    entities_moved=[...],
    entities_updated=[...],
    abm_changes=Dict(...)
)
```

### Command (user action)
```julia
CommandPayload(
    command_type="set_clock_speed",
    command=Dict("speed" => 2.0),
    apply_at_time=nothing
)
```

### Ack (success response)
```julia
AckPayload(
    acknowledged_message_id=cmd_uuid,
    status="executed",
    details=Dict("new_speed" => 2.0)
)
```

### Error (failure response)
```julia
ErrorPayload(
    error_code="INVALID_SPEED",
    error_message="Speed must be 0-10",
    recoverable=true,
    recovery_suggestion="Try speed 2.0"
)
```

## Common Workflows

### Workflow 1: Periodic Full Snapshots
```julia
# Every N steps, send full snapshot
if step_count % 10 == 0
    snapshot = build_snapshot(scene_id, sim_time, step_count, 
                             elements=get_elements(), entities=get_entities())
    msg = wrap_snapshot_in_message(snapshot)
    broadcast_snapshot(server, msg.payload)
end
```

### Workflow 2: Full Snapshot + Deltas
```julia
# Send full snapshot every 100 steps
# Send delta every step in between
previous_snapshot = nothing

for step in 1:1000
    current_snapshot = build_snapshot(...)
    
    if step % 100 == 0
        # Full snapshot
        msg = wrap_snapshot_in_message(current_snapshot)
        broadcast_snapshot(server, msg.payload)
    elseif !isnothing(previous_snapshot)
        # Delta
        delta = build_delta(previous_snapshot, current_snapshot)
        msg = create_delta_message(delta)
        broadcast_snapshot(server, msg.payload)
    end
    
    previous_snapshot = current_snapshot
end
```

### Workflow 3: Command Dispatch
```julia
register_handler!(server, "command", function(s, msg)
    ctx = CommandContext(
        command_id=msg.message_id,
        command_type=msg.payload.command_type,
        parameters=msg.payload.command,
        sender=msg.sender,
        timestamp=msg.timestamp,
        execution_state=Dict()
    )
    
    result = dispatch_command(ctx)
    
    if result.success
        return create_command_ack(result)
    else
        return create_command_error(result)
    end
end)
```

## Performance Tips

1. **Use Deltas for frequent updates**
   - Full snapshot: ~10KB for 100 elements, 1000 entities
   - Delta: ~2KB for typical update (20% of snapshot)
   - Result: 5x bandwidth savings

2. **Batch entity updates**
   - Don't send snapshot every step
   - Accumulate changes and send every N steps
   - Reduces overhead and improves responsiveness

3. **Compression strategies**
   - Use delta for high-frequency updates
   - Use full snapshot when delta would be large (>80% of snapshot)
   - Track "last sent" snapshot for comparison

4. **Command execution**
   - Queue long-running commands (reset, jump_to_time)
   - Execute immediate commands directly (play, pause, speed)
   - Don't block on command execution

## Debugging

### Enable debug output
```julia
using GodotBridge.Debug

# Convert message to JSON for inspection
json_str = to_debug_json(msg)
println(json_str)

# Log message
log_message_debug(msg, label="Snapshot received")
```

### Check message structure
```julia
# After decoding MessagePack
decoded = decode_messagepack(binary_data)
println("Message kind: $(decoded.kind)")
println("Payload type: $(typeof(decoded.payload))")
```

### Test round-trip
```julia
original = Message(...)
encoded = encode_messagepack(original)
decoded = decode_messagepack(encoded)
@test original.message_id == decoded.message_id
@test original.kind == decoded.kind
```

## Error Handling

### Handle invalid commands
```julia
is_valid, error_msg = validate_command(cmd)
if !is_valid
    err_payload = ErrorPayload(
        error_code="INVALID_COMMAND",
        error_message=error_msg,
        recoverable=true,
        recovery_suggestion="Check command format"
    )
end
```

### Handle dispatch errors
```julia
result = dispatch_command(ctx)
if !result.success
    println("Error: $(result.error_message)")
    println("Recovery: $(result.recovery_suggestion)")
end
```

### Handle serialization errors
```julia
try
    encoded = encode_messagepack(msg)
    # Use encoded data
catch e
    println("Serialization failed: $(e.message)")
    # Fallback to JSON debug output?
    json_str = to_debug_json(msg)
end
```

---

For complete API documentation, see [PHASE_7B2_SUMMARY.md](PHASE_7B2_SUMMARY.md)
