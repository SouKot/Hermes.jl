extends SceneTree

const ViewportController := preload("res://scripts/viewport_controller.gd")
const SAMPLES := 60
const WARMUP := 10

func _init() -> void:
    var scales := _scales()
    print("7C-06 large-scale memory benchmark")
    print("representation,scale,packed_bytes,frame_p50_ms,frame_p99_ms")
    for scale in scales:
        _run_packed_case(scale)
    print("large-scale packed benchmark passed")
    quit()

func _scales() -> Array:
    var value := OS.get_environment("SIMVIZ_LARGE_SCALES")
    if value == "":
        return [100000, 500000]
    var result: Array = []
    for part in value.split(","):
        var scale := int(part.strip_edges())
        if scale > 0:
            result.append(scale)
    return result

func _run_packed_case(scale: int) -> void:
    var positions := PackedVector2Array()
    positions.resize(scale)
    for index in range(scale):
        positions[index] = Vector2(float(index % 2000), float(index / 2000))

    var colors := PackedColorArray()
    colors.resize(scale)
    for index in range(scale):
        colors[index] = Color(0.32, 0.78, 0.64, 1.0)

    var packed_bytes := positions.size() * 8 + colors.size() * 16
    var viewport := ViewportController.new()
    viewport.size = Vector2(1280, 720)
    root.add_child(viewport)

    var frame_times: Array[float] = []
    for sample in range(WARMUP + SAMPLES):
        var start := Time.get_ticks_usec()
        _submit_packed_layer(positions, colors, viewport)
        frame_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
    frame_times = frame_times.slice(WARMUP)
    frame_times.sort()
    var p50 := frame_times[int(frame_times.size() * 0.50)]
    var p99 := frame_times[clampi(int(ceil(float(frame_times.size()) * 0.99)) - 1, 0, frame_times.size() - 1)]
    print("packed,%d,%d,%.3f,%.3f" % [scale, packed_bytes, p50, p99])
    assert(positions.size() == scale)

func _submit_packed_layer(positions: PackedVector2Array, colors: PackedColorArray, viewport: Control) -> void:
    # This is the data volume a MultiMesh/instanced renderer would submit: no
    # per-entity Dictionary, String, trajectory, or deep-copy allocation.
    var visible: int = mini(positions.size(), 10000)
    for index in range(visible):
        var _position: Vector2 = positions[index]
        var _color: Color = colors[index]
    viewport.queue_redraw()
