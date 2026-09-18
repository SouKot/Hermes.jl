extends SceneTree

const ConnectionManager := preload("res://scripts/connection_manager.gd")
const StateStore := preload("res://scripts/state_store.gd")

var client: SimVizConnectionManager
var store: RefCounted
var got_hello := false
var got_snapshot := false
var snapshot_count := 0
var deadline := 0.0

func _init() -> void:
    client = ConnectionManager.new()
    store = StateStore.new()
    root.add_child(client)
    client.message_received.connect(_on_message)
    client.protocol_error.connect(_on_protocol_error)
    deadline = Time.get_ticks_msec() / 1000.0 + 12.0
    create_timer(12.0).timeout.connect(_on_timeout)
    client.connect_to("127.0.0.1", 9107)

func _process(_delta: float) -> bool:
    if Time.get_ticks_msec() / 1000.0 > deadline:
        _on_timeout()
    return false

func _on_message(message: Dictionary) -> void:
    var kind := str(message.get("kind", ""))
    if kind == "hello":
        got_hello = true
    elif kind == "snapshot":
        got_snapshot = store.apply_message(message)
        snapshot_count += 1
    if got_hello and got_snapshot and snapshot_count >= 2:
        print("reconnect smoke observed live snapshots=%d" % snapshot_count)
        print("live reconnect smoke passed for current connection")
        quit(0)

func _on_protocol_error(detail: String) -> void:
    push_error(detail)
    quit(1)

func _on_timeout() -> void:
    push_error("Reconnect smoke timeout: hello=%s snapshot=%s count=%d" % [got_hello, got_snapshot, snapshot_count])
    quit(1)
