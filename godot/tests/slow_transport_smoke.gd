extends SceneTree

const ConnectionManager := preload("res://scripts/connection_manager.gd")

var client: SimVizConnectionManager
var snapshots := 0
var finished := false

func _init() -> void:
    client = ConnectionManager.new()
    root.add_child(client)
    client.message_received.connect(_on_message)
    client.protocol_error.connect(_on_error)
    create_timer(12.0).timeout.connect(_on_timeout)
    client.connect_to("127.0.0.1", 9107)

func _on_message(message: Dictionary) -> void:
    if str(message.get("kind", "")) == "snapshot":
        snapshots += 1

func _on_error(detail: String) -> void:
    if finished:
        return
    finished = true
    push_error(detail)
    quit(1)

func _on_timeout() -> void:
    if finished:
        return
    finished = true
    if snapshots >= 2:
        print("slow transport smoke passed: snapshots=%d" % snapshots)
        quit(0)
        return
    push_error("slow transport timeout: snapshots=%d" % snapshots)
    quit(1)
