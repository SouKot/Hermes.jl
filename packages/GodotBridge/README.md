# GodotBridge.jl - Quick Reference

## Basic Usage

### 1. Create and Start Server

```julia
using GodotBridge

server = GodotBridgeServer(
    host="127.0.0.1",
    port=9000,
    snapshot_rate_hz=30,
    debug=false
)

@async start(server)
```

### 2. Send Hello (Auto on Client Connect)

```julia
hello = create_hello(
    runtime_version="0.1.0",
    capabilities=["snapshot_streaming", "delta_updates", "model_selection"]
)

broadcast_message(server, hello)  # Not yet implemented
```

### 3. Broadcast Snapshot

```julia
snapshot = SnapshotPayload(
    snapshot_version="1.0.0",
    scene_id="scene_001",
    simulation_time=100.5,
    step_count=1005,
    clock_speed=1.0f0,
    simulation_state="running",
    elements_state=[
        Dict("id" => "elem_1", "occupancy" => 5)
    ],
    entities=[
        Dict("id" => "ent_1", "position" => [1.0, 2.0])
    ],
    abm_state=nothing,
    overlays=[],
    warnings=[],
    truncated=false
)

broadcast_snapshot(server, snapshot)
```

### 4. Handle Commands

```julia
register_handler!(server, "command") do msg
    action = msg.payload.command["action"]
    
    if action == "play"
        # Signal simulation to play
        return create_ack(msg.envelope.message_id, status="accepted")
    elseif action == "pause"
        # Signal simulation to pause
        return create_ack(msg.envelope.message_id, status="accepted")
    elseif action == "step"
        # Do one step
        return create_ack(msg.envelope.message_id, status="accepted")
    elseif action == "reset"
        # Reset simulation
        return create_ack(msg.envelope.message_id, status="accepted")
    elseif action == "set_clock_speed"
        speed = msg.payload.command["value"]
        # Set simulation speed
        return create_ack(msg.envelope.message_id, status="accepted")
    else
        return create_error(
            msg.envelope.message_id,
            "UNKNOWN_ACTION",
            "Action not supported: $action"
        )
    end
end
```

### 5. Debug with JSON

```julia
# For development/diagnostics only
msg = create_hello()
json_str = to_debug_json(msg)
println(json_str)

# Or log messages
log_message_debug(msg, label="DEBUG")
```

### 6. Encoding/Decoding

```julia
# Encode message to MessagePack binary
msg = create_ack("msg_123")
binary = encode_messagepack(msg)

# Decode MessagePack binary to message
msg_restored = decode_messagepack(binary)
```

### 7. Stop Server

```julia
stop(server)
```

---

## Message Types Reference

### Hello
```julia
hello = create_hello(
    protocol_version="1.0.0",
    runtime_name="SimViz",
    runtime_version="0.1.0",
    capabilities=[...],
    supported_encodings=["json", "messagepack"],
    preferred_encoding="messagepack"
)
```

### Snapshot
Contains complete simulation state:
- `simulation_time`: Current sim clock
- `step_count`: Total steps
- `elements_state`: Queue/server occupancy, etc.
- `entities`: Individual entity positions
- `abm_state`: Crowd model state (if enabled)

### Delta
Contains only changes since last snapshot:
- `elements_changed`: Updated element state
- `entities_added`: New entities
- `entities_removed`: Removed entities
- `entities_updated`: Position/state changes

### Command
Control messages from Godot:
- `play`, `pause`, `step`, `reset`: Playback control
- `set_clock_speed`: Change simulation speed
- `parameter_update`: Change element parameters
- `set_crowd_model`: Switch ABM model

### Ack
Confirms receipt and processing:
- `status`: "accepted", "pending", "queued"
- `details`: Optional message

### Error
Reports failures:
- `error_code`: Machine-readable code
- `error_message`: Human-readable description
- `recoverable`: Whether user can fix it
- `recovery_suggestion`: How to fix

---

## Design Principles

1. **MessagePack Always**
   - Production wire protocol is ONLY MessagePack
   - JSON is strictly for debugging via `to_debug_json()`
   - Never auto-switch formats

2. **Type-Safe**
   - All messages are concrete Julia structs
   - Compile-time validation
   - No duck typing or dynamic dispatch

3. **Non-Blocking**
   - Server runs in background task
   - Doesn't block simulation engine
   - Handles multiple clients

4. **Extensible**
   - Custom handlers via `register_handler!()`
   - No need to modify core code
   - Error messages route to error handler

5. **Versioned**
   - Protocol v1.0 supports 1.x versions
   - Unknown fields are ignored
   - Graceful forward compatibility

---

## Performance Notes

- MessagePack payloads typically 100-500 bytes per snapshot
- Support Float32 and UInt8 for bandwidth efficiency
- Delta updates reduce bandwidth for moving crowds
- Server can handle 30 snapshots/second by default
- No allocations in encoding hot path (coming in Phase 7B.2)

---

## Troubleshooting

### Cannot connect to server
- Check `is_server_running(server)` returns true
- Verify port 9000 is not in use
- Check firewall settings
- Try `debug=true` for diagnostic output

### Messages not arriving
- Use `num_connected_clients(server)` to verify connection
- Enable `debug=true` to see message flow
- Check `to_debug_json()` output for message structure

### Deserialization errors
- Verify MessagePack version compatibility
- Check `check_protocol_version()` returns true
- Ensure sender/receiver fields are correct

---

## API Reference

### Server Functions
- `GodotBridgeServer()` - Create server
- `start(server)` - Start listening
- `stop(server)` - Stop and cleanup
- `register_handler!(server, kind, handler)` - Add message handler
- `broadcast_snapshot(server, snapshot)` - Send to all clients
- `num_connected_clients(server)` - Get active connections
- `is_server_running(server)` - Check state

### Message Functions
- `create_hello()` - Create Hello message
- `create_ack(id)` - Create Ack message
- `create_error(id, code, msg)` - Create Error message
- `Message(envelope, payload)` - Combine envelope + payload

### Encoding Functions
- `encode_messagepack(msg)` - Binary encode
- `decode_messagepack(data)` - Binary decode
- `to_debug_json(msg)` - JSON debug output
- `log_message_debug(msg)` - Print debug log

### Type Checking
- `check_protocol_version(version)` - Verify compatibility

---

## File Locations

- Main module: `/ABM/packages/GodotBridge/src/GodotBridge.jl`
- Protocol: `/ABM/packages/GodotBridge/src/protocol/`
- Server: `/ABM/packages/GodotBridge/src/server/`
- Tests: `/ABM/packages/GodotBridge/test/`
