extends SceneTree

const ConnectionManager := preload("res://scripts/connection_manager.gd")
const StateStore := preload("res://scripts/state_store.gd")

var client: SimVizConnectionManager
var store: RefCounted
var hello_count := 0
var snapshot_count := 0
var last_entity_count := 0
var deadline := 0.0
var forced_reconnect := false

func _init() -> void:
    client = ConnectionManager.new()
    store = StateStore.new()
    root.add_child(client)
    client.message_received.connect(_on_message)
    client.protocol_error.connect(_on_error)
    deadline = Time.get_ticks_msec() / 1000.0 + 15.0
    create_timer(15.0).timeout.connect(_on_timeout)
    client.connect_to("127.0.0.1", 9107)

func _process(_delta: float) -> bool:
    if Time.get_ticks_msec() / 1000.0 > deadline:
        _on_timeout()
    return false

func _on_message(message: Dictionary) -> void:
    var kind := str(message.get("kind", ""))
    if kind == "hello":
        hello_count += 1
    elif kind == "snapshot" and store.apply_message(message):
        snapshot_count += 1
        last_entity_count = store.entities_by_id.size()
        if not forced_reconnect:
            forced_reconnect = true
            client.disconnect_from_server()
            create_timer(0.5).timeout.connect(_reconnect)

func _reconnect() -> void:
    client.reconnect_enabled = true
    client.connect_to("127.0.0.1", 9107)

func _on_error(detail: String) -> void:
    push_error(detail)
    quit(1)

func _on_timeout() -> void:
    if hello_count >= 2 and snapshot_count >= 2 and last_entity_count == 6:
        print("full recovery smoke passed: hellos=%d snapshots=%d entities=%d" % [hello_count, snapshot_count, last_entity_count])
        quit(0)
        return
    push_error("full recovery timeout: hellos=%d snapshots=%d entities=%d" % [hello_count, snapshot_count, last_entity_count])
    quit(1)
