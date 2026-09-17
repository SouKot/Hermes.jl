class_name SimVizFakeTransport
extends RefCounted

signal message_received(message: Dictionary)
signal connection_state_changed(state: String, detail: String)

const SimVizCodec = preload("res://scripts/protocol_codec.gd")

var codec := SimVizCodec.new()
var connected := false

func connect_fixture() -> void:
    connected = true
    connection_state_changed.emit("connected", "fake transport")

func disconnect_fixture() -> void:
    connected = false
    connection_state_changed.emit("disconnected", "fake transport")

func inject_message(message: Dictionary) -> void:
    if connected:
        message_received.emit(message)

func inject_bytes(bytes: PackedByteArray) -> void:
    var decoded = codec.decode(bytes)
    var validation := codec.validate_message(decoded)
    if validation.ok:
        message_received.emit(validation.message)
