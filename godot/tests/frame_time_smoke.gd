extends SceneTree

const ViewportController := preload("res://scripts/viewport_controller.gd")

const SAMPLE_FRAMES := 180

var viewport: Control
var frame_times: Array[float] = []
var started := false

func _init() -> void:
    viewport = ViewportController.new()
    viewport.size = Vector2(1280, 720)
    root.add_child(viewport)
    viewport.set_render_state(_synthetic_state(10000))
    process_frame.connect(_on_frame)

func _on_frame() -> void:
    if not started:
        started = true
        return
    var frame_start := Time.get_ticks_usec()
    viewport.queue_redraw()
    await process_frame
    frame_times.append(float(Time.get_ticks_usec() - frame_start) / 1000.0)
    if frame_times.size() >= SAMPLE_FRAMES:
        frame_times.sort()
        var p50 := frame_times[int(frame_times.size() * 0.50)]
        var p99_index := clampi(int(ceil(float(frame_times.size()) * 0.99)) - 1, 0, frame_times.size() - 1)
        var p99 := frame_times[p99_index]
        print("frame_time_ms_p50=%.3f frame_time_ms_p99=%.3f samples=%d" % [p50, p99, frame_times.size()])
        print("frame-time smoke passed")
        quit()

func _synthetic_state(entity_count: int) -> Dictionary:
    var entities: Dictionary = {}
    for index in range(entity_count):
        entities["entity-%d" % index] = {
            "id": "entity-%d" % index,
            "trajectory_2d": [[float(index % 1000), float(index / 1000)]]
        }
    return {"elements_by_id": {}, "entities_by_id": entities, "warnings": []}
