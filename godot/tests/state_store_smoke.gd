extends SceneTree

const StateStore := preload("res://scripts/state_store.gd")

func _init() -> void:
    var store := StateStore.new()

    var snapshot := {
        "envelope_version": "1.0",
        "message_id": "snapshot-1",
        "timestamp": 1,
        "sender": "julia_runtime",
        "receiver": "godot_gui",
        "kind": "snapshot",
        "payload": {
            "snapshot_version": "1.0.0",
            "scene_id": "state-test",
            "simulation_time": 1.0,
            "step_count": 1,
            "clock_speed": 1.0,
            "simulation_state": "running",
            "elements_state": [{"element_id": "queue-1", "occupancy": 2}],
            "entities": [{"id": "entity-1", "current_location": "queue-1"}],
            "abm_state": null,
            "overlays": [],
            "warnings": [],
            "truncated": false
        }
    }
    assert(store.apply_message(snapshot))
    assert(store.elements_by_id.has("queue-1"))
    assert(store.entities_by_id.has("entity-1"))
    assert(store.revision == 1)

    var delta := {
        "envelope_version": "1.0",
        "message_id": "delta-1",
        "timestamp": 2,
        "sender": "julia_runtime",
        "receiver": "godot_gui",
        "kind": "delta",
        "payload": {
            "parent_message_id": "snapshot-1",
            "elements_changed": [{"element_id": "queue-1", "occupancy_after": 7}],
            "entities_added": [{"id": "entity-2", "current_location": "queue-1"}],
            "entities_removed": ["entity-1"],
            "entities_updated": [],
            "abm_state_delta": null,
            "overlay_updates": []
        }
    }
    assert(store.apply_message(delta))
    assert(store.elements_by_id["queue-1"]["occupancy_after"] == 7)
    assert(not store.entities_by_id.has("entity-1"))
    assert(store.entities_by_id.has("entity-2"))

    var stale := delta.duplicate(true)
    stale.message_id = "delta-stale"
    stale.payload.parent_message_id = "wrong-parent"
    assert(not store.apply_message(stale))
    assert(store.revision == 2)
    print("State store smoke test passed: revision=%d" % store.revision)
    quit(0)
