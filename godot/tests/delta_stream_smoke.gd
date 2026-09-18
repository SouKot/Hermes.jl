extends SceneTree

const StateStore := preload("res://scripts/state_store.gd")

func _init() -> void:
    var store := StateStore.new()
    assert(store.apply_message(_snapshot()))
    assert(store.entities_by_id.size() == 2)

    var update := _delta("delta-update", "snapshot-1", {
        "entities_updated": [{"id": "entity-1", "trajectory_2d": [[20.0, 10.0]]}],
        "entities_added": [],
        "entities_removed": [],
        "elements_changed": []
    })
    assert(store.apply_message(update))
    assert(store.entities_by_id["entity-1"].trajectory_2d[0][0] == 20.0)

    var add_remove := _delta("delta-life", "delta-update", {
        "entities_updated": [],
        "entities_added": [{"id": "entity-3", "trajectory_2d": [[5.0, 5.0]]}],
        "entities_removed": ["entity-2"],
        "elements_changed": []
    })
    assert(store.apply_message(add_remove))
    assert(store.entities_by_id.size() == 2)
    assert(store.entities_by_id.has("entity-3"))
    assert(not store.entities_by_id.has("entity-2"))

    var resync := [false]
    store.resync_required.connect(func(_reason: String): resync[0] = true)
    assert(not store.apply_message(_delta("stale", "wrong-parent", {})))
    assert(resync[0])
    print("delta stream smoke passed: update/add/remove/resync")
    quit(0)

func _snapshot() -> Dictionary:
    return {
        "kind": "snapshot",
        "message_id": "snapshot-1",
        "payload": {
            "snapshot_version": "1.0.0",
            "scene_id": "delta-test",
            "simulation_time": 0.0,
            "step_count": 0,
            "clock_speed": 1.0,
            "simulation_state": "running",
            "elements_state": [{"element_id": "queue-1", "occupancy": 2}],
            "entities": [
                {"id": "entity-1", "trajectory_2d": [[0.0, 0.0]]},
                {"id": "entity-2", "trajectory_2d": [[1.0, 1.0]]}
            ],
            "abm_state": null,
            "overlays": [],
            "warnings": [],
            "truncated": false
        }
    }

func _delta(message_id: String, parent: String, changes: Dictionary) -> Dictionary:
    var payload := {
        "parent_message_id": parent,
        "elements_changed": [],
        "entities_added": [],
        "entities_updated": [],
        "entities_removed": []
    }
    for key in changes:
        payload[key] = changes[key]
    return {"kind": "delta", "message_id": message_id, "payload": payload}
