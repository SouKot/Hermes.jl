extends SceneTree

const StateStore := preload("res://scripts/state_store.gd")
const ViewportController := preload("res://scripts/viewport_controller.gd")
const Codec := preload("res://scripts/protocol_codec.gd")

func _init() -> void:
    var codec := Codec.new()
    var hello := _message("hello", {"runtime": "fixture"})
    var encoded := codec.encode(hello)
    var decoded: Variant = codec.decode(encoded)
    assert(codec.validate_message(decoded).ok)
    print("acceptance: protocol hello decode passed")

    var store := StateStore.new()
    var snapshot := _snapshot()
    assert(store.apply_message(snapshot))
    assert(store.entities_by_id.size() == 2)
    assert(store.elements_by_id.size() == 1)
    print("acceptance: snapshot state passed")

    var viewport := ViewportController.new()
    viewport.size = Vector2(800, 600)
    root.add_child(viewport)
    viewport.set_render_state(store.render_state())
    viewport.queue_redraw()
    assert(viewport.render_state.entities_by_id.size() == 2)
    print("acceptance: viewport state passed")

    var stale_delta := _message("delta", {
        "parent_message_id": "wrong-parent",
        "elements_changed": [],
        "entities_added": [],
        "entities_updated": [],
        "entities_removed": []
    })
    var resync := [false]
    store.resync_required.connect(func(_reason: String): resync[0] = true)
    assert(not store.apply_message(stale_delta))
    assert(resync[0])
    print("acceptance: stale-delta recovery passed")

    print("Phase 7C automated acceptance smoke passed")
    quit(0)

func _snapshot() -> Dictionary:
    return _message("snapshot", {
        "snapshot_version": "1.0.0",
        "scene_id": "acceptance",
        "simulation_time": 1.0,
        "step_count": 10,
        "clock_speed": 1.0,
        "simulation_state": "running",
        "elements_state": [{"element_id": "queue-1", "element_kind": "queue", "occupancy": 2}],
        "entities": [
            {"id": "entity-1", "kind": "customer", "trajectory_2d": [[0.0, 0.0]]},
            {"id": "entity-2", "kind": "customer", "trajectory_2d": [[20.0, 10.0]]}
        ],
        "abm_state": null,
        "overlays": [],
        "warnings": [],
        "truncated": false
    })

func _message(kind: String, payload: Dictionary) -> Dictionary:
    return {
        "envelope_version": "1.0",
        "message_id": "acceptance-%s-%d" % [kind, Time.get_ticks_usec()],
        "timestamp": Time.get_ticks_msec(),
        "sender": "acceptance",
        "receiver": "godot_gui",
        "kind": kind,
        "payload": payload
    }
