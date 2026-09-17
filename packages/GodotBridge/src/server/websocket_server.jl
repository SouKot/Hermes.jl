"""
    websocket_server.jl

WebSocket server for Protocol v1 communication with Godot.
Manages connections, message dispatch, and snapshot streaming.
"""

import HTTP
const WS = HTTP.WebSockets
using ..GodotBridge  # Import parent module

# ============================================================================
# WebSocket Server Structure
# ============================================================================

"""
    GodotBridgeServer

WebSocket server for Julia-Godot communication.

**Fields**:
- `host::String` - Bind address (default "127.0.0.1")
- `port::Int` - Port number (default 9000)
- `snapshot_rate_hz::Int` - Snapshots per second (default 30)
- `debug::Bool` - Enable JSON debug logging
- `is_running::Bool` - Server state
- `clients::Dict` - Connected WebSocket clients
- `message_handlers::Dict` - Dispatch table for message types
"""
mutable struct GodotBridgeServer
    host::String
    port::Int
    snapshot_rate_hz::Int
    debug::Bool
    is_running::Bool
    clients::Dict{String, WS.WebSocket}
    message_handlers::Dict{String, Function}
    server_task::Union{Task, Nothing}
end

# ============================================================================
# Server Initialization
# ============================================================================

"""
    GodotBridgeServer(; kwargs...) -> GodotBridgeServer

Create a new WebSocket server instance.

**Keyword Arguments**:
- `host::String` - Listen address (default: "127.0.0.1")
- `port::Int` - Listen port (default: 9000)
- `snapshot_rate_hz::Int` - Update rate (default: 30)
- `debug::Bool` - Enable debug logging (default: false)

**Example**:
```julia
server = GodotBridgeServer(port=9000, snapshot_rate_hz=30, debug=false)
```
"""
function GodotBridgeServer(;
    host::String="127.0.0.1",
    port::Int=9000,
    snapshot_rate_hz::Int=30,
    debug::Bool=false,
)::GodotBridgeServer
    
    server = GodotBridgeServer(
        host,
        port,
        snapshot_rate_hz,
        debug,
        false,  # is_running
        Dict{String, WS.WebSocket}(),  # clients
        Dict{String, Function}(),  # message_handlers
        nothing,  # server_task
    )
    
    # Register default message handlers
    register_default_handlers!(server)
    
    server
end

# ============================================================================
# Message Handler Registration
# ============================================================================

"""
    register_handler!(server::GodotBridgeServer, kind::String, handler::Function)

Register a handler for a specific message type.

Arguments:
- `server`: Server instance
- `kind`: Message type (command, ack, error, etc.)
- `handler`: Function with signature (msg::Message) -> Message
"""
function register_handler!(server::GodotBridgeServer, kind::String, handler::Function)
    server.message_handlers[kind] = handler
end

"""
    register_default_handlers!(server::GodotBridgeServer)

Register default message handlers for standard message types.
"""
function register_default_handlers!(server::GodotBridgeServer)
    # Default command handler - just echo an Ack
    register_handler!(server, "command", function(msg)
        if server.debug
            log_message_debug(msg, label="CMD")
        end
        create_ack(msg.envelope.message_id, status="accepted", details="Command received")
    end)
    
    # Default ack handler - log it
    register_handler!(server, "ack", function(msg)
        if server.debug
            log_message_debug(msg, label="ACK")
        end
        nothing  # No response to ack
    end)
    
    # Default error handler - log it
    register_handler!(server, "error", function(msg)
        if server.debug
            log_message_debug(msg, label="ERR")
        end
        nothing  # No response to error
    end)
end

# ============================================================================
# Server Lifecycle
# ============================================================================

"""
    start(server::GodotBridgeServer)

Start the WebSocket server.

Behavior:
- Listens on server.host:server.port
- Accepts incoming WebSocket connections
- Routes messages to registered handlers
- Streams snapshots at configured rate

Note: This is a blocking call. Run in a Task for non-blocking behavior.
"""
function start(server::GodotBridgeServer)
    if server.is_running
        @warn "Server already running on $(server.host):$(server.port)"
        return
    end
    
    server.is_running = true
    println("Starting GodotBridge WebSocket server on ws://$(server.host):$(server.port)")
    
    try
        WS.listen!(server.host, server.port; check_origin=(_request -> true)) do ws
            handle_connection(server, ws)
        end
    catch e
        @error "Server error: $e"
        server.is_running = false
    end
end

"""
    stop(server::GodotBridgeServer)

Stop the WebSocket server and close all connections.
"""
function stop(server::GodotBridgeServer)
    if !server.is_running
        @warn "Server not running"
        return
    end
    
    server.is_running = false
    # Close all active connections
    for (id, ws) in server.clients
        try
            close(ws)
        catch
        end
    end
    empty!(server.clients)
    
    println("GodotBridge WebSocket server stopped")
end

# ============================================================================
# Connection Handling
# ============================================================================

"""
    handle_connection(server::GodotBridgeServer, ws::WebSocket.WebSocket)

Handle a single WebSocket connection from a client.

**Lifecycle**:
1. Send Hello message
2. Receive and process incoming messages
3. Handle disconnection
"""
function handle_connection(server::GodotBridgeServer, ws::WS.WebSocket)
    client_id = string(gensym("client_"))
    server.clients[client_id] = ws
    
    if server.debug
        println("DEBUG: Client connected: $client_id")
    end
    
    try
        # Send hello on connect
        hello = create_hello()
        binary = encode_messagepack(hello)
        WS.send(ws, binary)
        
        if server.debug
            log_message_debug(hello, label="SEND")
        end
        
        # Main message loop
        while !WS.isclosed(ws)
            try
                data = WS.receive(ws)
                success = true
            if success && data isa Vector{UInt8}
                    # Decode incoming message
                    msg = decode_messagepack(data)
                    
                    if server.debug
                        log_message_debug(msg, label="RECV")
                    end
                    
                    # Dispatch to handler
                    response = dispatch_message(server, msg)
                    
                    # Send response if handler produced one
                    if !isnothing(response)
                        resp_binary = encode_messagepack(response)
                        WS.send(ws, resp_binary)
                        
                        if server.debug
                            log_message_debug(response, label="SEND")
                        end
                    end
                end
            catch e
                if !(e isa EOFError)
                    @warn "Error processing message: $e"
                end
                break
            end
        end
    finally
        # Cleanup on disconnect
        delete!(server.clients, client_id)
        if server.debug
            println("DEBUG: Client disconnected: $client_id")
        end
    end
end

# ============================================================================
# Message Dispatch
# ============================================================================

"""
    dispatch_message(server::GodotBridgeServer, msg::Message) -> Union{Message, Nothing}

Route an incoming message to the appropriate handler.

**Returns**: Response message, or nothing if no response needed.
"""
function dispatch_message(server::GodotBridgeServer, msg::Message)::Union{Message, Nothing}
    kind = msg.envelope.kind
    
    if haskey(server.message_handlers, kind)
        handler = server.message_handlers[kind]
        try
            response = handler(msg)
            return response
        catch e
            @error "Handler error for '$kind': $e"
            return create_error(
                msg.envelope.message_id,
                "HANDLER_ERROR",
                "Internal server error",
                recoverable=true
            )
        end
    else
        # Unknown message type
        if server.debug
            @warn "Unknown message type: $kind"
        end
        return create_error(
            msg.envelope.message_id,
            "UNKNOWN_MESSAGE_TYPE",
            "Server does not support message type: $kind",
            recoverable=true
        )
    end
end

# ============================================================================
# Snapshot Broadcasting
# ============================================================================

"""
    broadcast_snapshot(server::GodotBridgeServer, snapshot::SnapshotPayload)

Send a snapshot to all connected clients.

Arguments:
- `server`: Server instance
- `snapshot`: Snapshot payload to broadcast
"""
function broadcast_snapshot(server::GodotBridgeServer, snapshot::SnapshotPayload)
    msg = Message(
        MessageEnvelope(
            "1.0",
            "msg_snapshot_$(gensym())",
            UInt64(floor(time() * 1000)),
            "julia_runtime",
            "godot_gui",
            "snapshot"
        ),
        snapshot
    )
    
    binary = encode_messagepack(msg)
    
    disconnected = String[]
    for (client_id, ws) in server.clients
        try
            if !WS.isclosed(ws)
                WS.send(ws, binary)
            else
                push!(disconnected, client_id)
            end
        catch e
            @warn "Failed to send to $client_id: $e"
            push!(disconnected, client_id)
        end
    end
    
    # Clean up disconnected clients
    for client_id in disconnected
        delete!(server.clients, client_id)
    end
end

# ============================================================================
# Server Utilities
# ============================================================================

"""
    num_connected_clients(server::GodotBridgeServer) -> Int

Return the number of currently connected clients.
"""
function num_connected_clients(server::GodotBridgeServer)::Int
    return length(server.clients)
end

"""
    is_server_running(server::GodotBridgeServer) -> Bool

Check if the server is currently running.
"""
function is_server_running(server::GodotBridgeServer)::Bool
    return server.is_running
end

# ============================================================================
# Exports
# ============================================================================

export GodotBridgeServer
export start, stop
export register_handler!, broadcast_snapshot
export num_connected_clients, is_server_running
