extends SceneTree

const StateStore := preload("res://scripts/state_store.gd")
const ViewportController := preload("res://scripts/viewport_controller.gd")
const Codec := preload("res://scripts/protocol_codec.gd")

const DEFAULT_SCALES := [10000, 100000, 500000]
const SAMPLES := 5

func _init() -> void:
    var scales := _configured_scales()
    var report: Array[String] = []
    report.append("7C-06 performance/resilience smoke")
    report.append("scale,decode_p99_ms,state_apply_p99_ms,render_state_p99_ms,viewport_submit_p99_ms,entity_count")
    for scale in scales:
        var result := _benchmark_scale(scale)
        report.append("%d,%.3f,%.3f,%.3f,%.3f,%d" % [
            scale,
            float(result.get("decode_p99_ms", 0.0)),
            float(result.get("state_apply_p99_ms", 0.0)),
            float(result.get("render_state_p99_ms", 0.0)),
            float(result.get("viewport_submit_p99_ms", 0.0)),
            int(result.get("entity_count", 0))
        ])
        assert(int(result.get("entity_count", 0)) == scale)
        assert(float(result.get("decode_p99_ms", -1.0)) >= 0.0)
        assert(float(result.get("state_apply_p99_ms", -1.0)) >= 0.0)
    _check_revision_recovery()
    _check_memory_stability()
    for line in report:
        print(line)
    print("7C-06 performance/resilience smoke passed")
    quit()

func _configured_scales() -> Array:
    var configured := OS.get_environment("SIMVIZ_BENCH_SCALES")
    if configured == "":
        return DEFAULT_SCALES
    var scales: Array[int] = []
    for value in configured.split(","):
        var scale := int(value.strip_edges())
        if scale > 0:
            scales.append(scale)
    return scales if not scales.is_empty() else DEFAULT_SCALES

func _benchmark_scale(scale: int) -> Dictionary:
    var message := _snapshot_message(scale)
    var state_store := StateStore.new()
    state_store.use_packed_entities = OS.get_environment("SIMVIZ_FORCE_GENERIC") != "1"
    var codec := Codec.new()
    var decode_samples: Array[float] = []
    var apply_samples: Array[float] = []
    var render_samples: Array[float] = []
    var viewport_samples: Array[float] = []
    var viewport := ViewportController.new()
    viewport.size = Vector2(1280, 720)
    root.add_child(viewport)

    for sample in range(SAMPLES + 1):
        var encoded: PackedByteArray = codec.encode(message)
        var decode_start := Time.get_ticks_usec()
        var decoded: Variant = codec.decode(encoded)
        decode_samples.append(float(Time.get_ticks_usec() - decode_start) / 1000.0)
        var apply_start := Time.get_ticks_usec()
        assert(state_store.apply_message(decoded))
        apply_samples.append(float(Time.get_ticks_usec() - apply_start) / 1000.0)
        var render_start := Time.get_ticks_usec()
        var state: Dictionary = state_store.render_state()
        render_samples.append(float(Time.get_ticks_usec() - render_start) / 1000.0)
        var viewport_start := Time.get_ticks_usec()
        viewport.set_render_state(state)
        viewport.queue_redraw()
        viewport_samples.append(float(Time.get_ticks_usec() - viewport_start) / 1000.0)
        var rendered_state: Dictionary = state_store.render_state()
        var rendered_count := state_store.entities_by_id.size()
        if rendered_state.get("entity_positions", PackedVector2Array()).size() > 0:
            rendered_count = rendered_state.entity_positions.size()
        assert(rendered_count == scale)
        if sample == 0:
            decode_samples.clear()
            apply_samples.clear()
            render_samples.clear()
    return {
        "decode_p99_ms": _p99(decode_samples),
        "state_apply_p99_ms": _p99(apply_samples),
        "render_state_p99_ms": _p99(render_samples),
        "viewport_submit_p99_ms": _p99(viewport_samples),
        "entity_count": state_store.entities_by_id.size() if state_store.entities_by_id.size() > 0 else state_store.packed_entity_positions.size()
    }

func _snapshot_message(entity_count: int) -> Dictionary:
    var entities: Array = []
    var compact := OS.get_environment("SIMVIZ_COMPACT_PROTOCOL") == "1"
    var compact_positions := PackedByteArray()
    if compact:
        compact_positions.resize(entity_count * 8)
        for index in range(entity_count):
            var x := float(index % 1000)
            var y := float(index / 1000)
            var x_bytes := _float_bytes(x)
            var y_bytes := _float_bytes(y)
            for byte_index in range(4):
                compact_positions[index * 8 + byte_index] = x_bytes[byte_index]
                compact_positions[index * 8 + 4 + byte_index] = y_bytes[byte_index]
    else:
        for index in range(entity_count):
            entities.append({
                "id": "entity-%d" % index,
                "kind": "benchmark",
                "current_location": "queue-1",
                "trajectory_2d": [[float(index % 1000), float(index / 1000)]],
                "properties": {"index": index}
            })
    return {
        "envelope_version": "1.0",
        "message_id": "benchmark-snapshot-%d" % entity_count,
        "timestamp": Time.get_ticks_msec(),
        "sender": "benchmark",
        "receiver": "godot_gui",
        "kind": "snapshot",
        "payload": {
            "snapshot_version": "1.0.0",
            "scene_id": "benchmark",
            "simulation_time": 1.0,
            "step_count": 1,
            "clock_speed": 1.0,
            "simulation_state": "running",
            "elements_state": [{"element_id": "queue-1", "element_kind": "queue", "occupancy": entity_count}],
            "entities": entities,
            "entity_count": entity_count,
            "entity_positions": compact_positions,
            "abm_state": null,
            "overlays": [],
            "warnings": [],
            "truncated": false
        }
    }

func _float_bytes(value: float) -> PackedByteArray:
    var stream := StreamPeerBuffer.new()
    stream.put_float(value)
    return stream.data_array

func _check_revision_recovery() -> void:
    var store := StateStore.new()
    var first := _snapshot_message(2)
    assert(store.apply_message(first))
    var stale_delta := {
        "kind": "delta",
        "message_id": "stale-delta",
        "payload": {
            "parent_message_id": "wrong-parent",
            "elements_changed": [],
            "entities_added": [],
            "entities_updated": [],
            "entities_removed": []
        }
    }
    var resync_requested := [false]
    store.resync_required.connect(func(_reason: String): resync_requested[0] = true)
    assert(not store.apply_message(stale_delta))
    assert(resync_requested[0])
    print("resync recovery check passed")

func _check_memory_stability() -> void:
    var store := StateStore.new()
    var message := _snapshot_message(10000)
    for iteration in range(3):
        message.message_id = "memory-check-%d" % iteration
        assert(store.apply_message(message))
        var count := store.entities_by_id.size() if store.entities_by_id.size() > 0 else store.packed_entity_positions.size()
        assert(count == 10000)
    var final_count := store.entities_by_id.size() if store.entities_by_id.size() > 0 else store.packed_entity_positions.size()
    print("bounded state replacement check passed: entities=%d" % final_count)

func _p99(values: Array[float]) -> float:
    values.sort()
    if values.is_empty():
        return 0.0
    var index := clampi(int(ceil(float(values.size()) * 0.99)) - 1, 0, values.size() - 1)
    return values[index]
