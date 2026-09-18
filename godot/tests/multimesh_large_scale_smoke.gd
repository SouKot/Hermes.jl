extends SceneTree

const SAMPLES := 30
const WARMUP := 5

func _init() -> void:
    var scale := int(OS.get_environment("SIMVIZ_MULTIMESH_SCALE"))
    if scale <= 0:
        scale = 500000

    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_2D
    multimesh.use_colors = true
    multimesh.instance_count = scale
    var quad := QuadMesh.new()
    quad.size = Vector2(2.0, 2.0)
    multimesh.mesh = quad

    for index in range(scale):
        var x := float(index % 2000)
        var y := float(index / 2000)
        multimesh.set_instance_transform_2d(index, Transform2D(0.0, Vector2(x, y)))
        multimesh.set_instance_color(index, Color(0.32, 0.78, 0.64, 1.0))

    var instance := MultiMeshInstance2D.new()
    instance.multimesh = multimesh
    root.add_child(instance)
    await process_frame

    var frame_times: Array[float] = []
    for sample in range(WARMUP + SAMPLES):
        var start := Time.get_ticks_usec()
        await process_frame
        frame_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
    frame_times = frame_times.slice(WARMUP)
    frame_times.sort()
    var p50 := frame_times[int(frame_times.size() * 0.50)]
    var p99 := frame_times[clampi(int(ceil(float(frame_times.size()) * 0.99)) - 1, 0, frame_times.size() - 1)]
    print("multimesh_instances=%d frame_p50_ms=%.3f frame_p99_ms=%.3f" % [scale, p50, p99])
    print("multimesh large-scale smoke passed")
    quit()
