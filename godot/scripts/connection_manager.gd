class_name SimVizConnectionManager
extends Node

signal connection_state_changed(state: String, detail: String)
signal message_received(message: Dictionary)
signal protocol_error(detail: String)

const SimVizCodec = preload("res://scripts/protocol_codec.gd")

enum ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING, DEGRADED }

@export var host := "127.0.0.1"
@export var port := 9000
@export var reconnect_enabled := true
@export var max_reconnect_delay := 5.0

var state := ConnectionState.DISCONNECTED
var socket := WebSocketPeer.new()
var codec := SimVizCodec.new()
var reconnect_delay := 0.5
var reconnect_timer := 0.0
var endpoint_path := "/"

func _process(delta: float) -> void:
    if state == ConnectionState.CONNECTING or state == ConnectionState.CONNECTED:
        socket.poll()
        _drain_socket()
    elif state == ConnectionState.RECONNECTING:
        reconnect_timer -= delta
        if reconnect_timer <= 0.0:
            connect_to(host, port, endpoint_path)

func connect_to(target_host: String = host, target_port: int = port, path := "/") -> void:
    host = target_host
    port = target_port
    endpoint_path = path
    _set_state(ConnectionState.CONNECTING, "ws://%s:%d%s" % [host, port, endpoint_path])
    socket = WebSocketPeer.new()
    var error := socket.connect_to_url("ws://%s:%d%s" % [host, port, endpoint_path])
    if error != OK:
        _schedule_reconnect("connect error: %s" % error)

func disconnect_from_server() -> void:
    reconnect_enabled = false
    socket.close()
    _set_state(ConnectionState.DISCONNECTED, "client disconnect")

func send_message(message: Dictionary) -> Error:
    if state != ConnectionState.CONNECTED:
        return ERR_UNAVAILABLE
    var error := socket.send(codec.encode(message), WebSocketPeer.WRITE_MODE_BINARY)
    if error != OK:
        _schedule_reconnect("send error: %s" % error)
    return error

func _drain_socket() -> void:
    var peer_state := socket.get_ready_state()
    if peer_state == WebSocketPeer.STATE_CLOSED:
        print("websocket_closed code=", socket.get_close_code(), " reason=", socket.get_close_reason())
    if peer_state == WebSocketPeer.STATE_OPEN and state != ConnectionState.CONNECTED:
        reconnect_delay = 0.5
        _set_state(ConnectionState.CONNECTED, "connection open")
    elif peer_state == WebSocketPeer.STATE_CLOSING or peer_state == WebSocketPeer.STATE_CLOSED:
        _schedule_reconnect("connection closed")
        return

    while socket.get_available_packet_count() > 0:
        var packet := socket.get_packet()
        if socket.was_string_packet():
            protocol_error.emit("received text packet; binary MessagePack required")
            continue
        _handle_binary(packet)

func _handle_binary(packet: PackedByteArray) -> void:
    var decoded: Variant = codec.decode(packet)
    var validation := codec.validate_message(decoded)
    if not validation.ok:
        protocol_error.emit(validation.error)
        return
    message_received.emit(validation.message)

func _schedule_reconnect(detail: String) -> void:
    socket.close()
    if not reconnect_enabled:
        _set_state(ConnectionState.DISCONNECTED, detail)
        return
    reconnect_timer = reconnect_delay
    reconnect_delay = min(reconnect_delay * 2.0, max_reconnect_delay)
    _set_state(ConnectionState.RECONNECTING, detail)

func _set_state(next_state: ConnectionState, detail: String) -> void:
    state = next_state
    var names := ["disconnected", "connecting", "connected", "reconnecting", "degraded"]
    connection_state_changed.emit(names[state], detail)
