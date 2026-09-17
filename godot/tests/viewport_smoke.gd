extends SceneTree

const ViewportController := preload("res://scripts/viewport_controller.gd")

func _init() -> void:
    var viewport = ViewportController.new()
    viewport.size = Vector2(640, 480)
    root.add_child(viewport)
    viewport.set_render_state({
        "revision": 3,
        "elements_by_id": {
            "queue-a": {"occupancy": 12},
        },
        "entities_by_id": {
            "entity-1": {"id": "entity-1", "trajectory_2d": [[-20.0, 10.0]]},
            "entity-2": {"id": "entity-2", "trajectory_2d": [[30.0, -15.0]]},
        },
    })
    assert(viewport.render_state.entities_by_id.size() == 2)
    assert(viewport.camera_zoom == 1.0)
    viewport.camera_zoom = 2.0
    assert(viewport.camera_zoom == 2.0)
    viewport.queue_redraw()
    print("Viewport smoke test passed: entities=%d" % viewport.render_state.entities_by_id.size())
    quit()
