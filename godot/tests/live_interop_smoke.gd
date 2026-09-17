extends SceneTree

const ConnectionManager := preload("res://scripts/connection_manager.gd")

var client: SimVizConnectionManager
var got_hello := false
var got_ack := false
var got_snapshot := false
var failed := false
var deadline := 0.0

func _init() -> void:
    client = ConnectionManager.new()
    get_root().add_child(client)
    client.connection_state_changed.connect(_on_state)
    client.message_received.connect(_on_message)
    client.protocol_error.connect(_on_error)
    deadline = Time.get_ticks_msec() / 1000.0 + 8.0
    create_timer(8.0).timeout.connect(_on_timeout)
    client.connect_to("127.0.0.1", 9107)

func _on_timeout() -> void:
    if got_hello and got_ack and got_snapshot:
        print("Live Julia/Godot interoperability passed")
        quit(0)
    push_error("Interop timeout: hello=%s ack=%s snapshot=%s" % [got_hello, got_ack, got_snapshot])
    quit(1)

func _on_state(state: String, detail: String) -> void:
    print("connection_state=", state, " detail=", detail)

func _on_error(detail: String) -> void:
    push_error(detail)
    failed = true
    quit(1)

func _on_message(message: Dictionary) -> void:
    var kind := str(message.get("kind", ""))
    print("received=", kind)
    if kind == "hello":
        got_hello = true
        var command := {
            "envelope_version": "1.0",
            "message_id": "godot-command-1",
            "timestamp": Time.get_ticks_msec(),
            "sender": "godot_gui",
            "receiver": "julia_runtime",
            "kind": "command",
            "payload": {
                "command_version": "1.0.0",
                "command_type": "control",
                "command": {"action": "pause"},
                "scene_id": "phase7c_fixture",
                "apply_at_time": null
            }
        }
        var send_error := client.send_message(command)
        if send_error != OK:
            _on_error("command send failed: %s" % send_error)
    elif kind == "ack":
        got_ack = true
    elif kind == "snapshot":
        got_snapshot = true
        var payload: Dictionary = message.get("payload", {})
        if payload.get("scene_id", "") != "phase7c_fixture":
            _on_error("unexpected snapshot scene")
    if got_hello and got_ack and got_snapshot:
        print("Live Julia/Godot interoperability passed")
        quit(0)
