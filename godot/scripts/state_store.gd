class_name SimVizStateStore
extends RefCounted

const PACKED_ENTITY_THRESHOLD := 10000

signal state_replaced(state: Dictionary)
signal delta_applied(state: Dictionary)
signal resync_required(reason: String)
signal state_error(detail: String)

var scene_id := ""
var snapshot_version := ""
var simulation_time := 0.0
var step_count := 0
var clock_speed := 1.0
var simulation_state := "stopped"
var elements_by_id: Dictionary = {}
var entities_by_id: Dictionary = {}
var packed_entity_positions := PackedVector2Array()
var packed_entity_ids := PackedStringArray()
var use_packed_entities := true
var abm_state: Variant = null
var overlays: Array = []
var warnings: Array = []
var truncated := false
var last_message_id := ""
var revision := 0

func apply_message(message: Dictionary) -> bool:
    var kind := str(message.get("kind", ""))
    match kind:
        "snapshot":
            return _apply_snapshot(message)
        "delta":
            return _apply_delta(message)
        "hello", "ack", "error":
            return true
        _:
            state_error.emit("Unsupported state message kind: %s" % kind)
            return false

func render_state() -> Dictionary:
    return {
        "scene_id": scene_id,
        "snapshot_version": snapshot_version,
        "simulation_time": simulation_time,
        "step_count": step_count,
        "clock_speed": clock_speed,
        "simulation_state": simulation_state,
        "elements_by_id": elements_by_id.duplicate(true),
        "entities_by_id": entities_by_id.duplicate(true),
        "entity_positions": packed_entity_positions,
        "entity_ids": packed_entity_ids,
        "abm_state": abm_state,
        "overlays": overlays.duplicate(true),
        "warnings": warnings.duplicate(true),
        "truncated": truncated,
        "last_message_id": last_message_id,
        "revision": revision
    }

func _apply_snapshot(message: Dictionary) -> bool:
    var payload: Dictionary = message.get("payload", {})
    var elements_raw = payload.get("elements_state", [])
    var entities_raw = payload.get("entities", [])
    var compact_positions: PackedByteArray = payload.get("entity_positions", PackedByteArray())
    var compact_entity_count: int = int(payload.get("entity_count", 0))
    if not elements_raw is Array:
        push_warning("Snapshot elements_state was not an Array: %s" % typeof(elements_raw))
        elements_raw = []
    if not entities_raw is Array and compact_positions.is_empty():
        push_warning("Snapshot entities was not an Array: %s" % typeof(entities_raw))
        entities_raw = []

    var next_elements := _index_records(elements_raw, "element_id")
    var next_entities: Dictionary = {}
    packed_entity_positions = PackedVector2Array()
    packed_entity_ids = PackedStringArray()
    if use_packed_entities and not compact_positions.is_empty():
        _pack_binary_entity_positions(compact_positions, compact_entity_count)
    elif use_packed_entities and entities_raw.size() >= PACKED_ENTITY_THRESHOLD:
        _pack_entity_positions(entities_raw)
    else:
        next_entities = _index_records(entities_raw, "id")
    print("STATE STORE: snapshot scene=%s elements=%d entities=%d" % [
        str(payload.get("scene_id", "")),
        next_elements.size(),
        next_entities.size()
    ])

    scene_id = str(payload.get("scene_id", ""))
    snapshot_version = str(payload.get("snapshot_version", ""))
    simulation_time = float(payload.get("simulation_time", 0.0))
    step_count = int(payload.get("step_count", 0))
    clock_speed = float(payload.get("clock_speed", 1.0))
    simulation_state = str(payload.get("simulation_state", "stopped"))
    elements_by_id = next_elements
    entities_by_id = next_entities
    abm_state = payload.get("abm_state", null)
    overlays = payload.get("overlays", [])
    warnings = payload.get("warnings", [])
    truncated = bool(payload.get("truncated", false))
    last_message_id = str(message.get("message_id", ""))
    revision += 1
    var state := render_state()
    state_replaced.emit(state)
    return true

func _apply_delta(message: Dictionary) -> bool:
    var payload: Dictionary = message.get("payload", {})
    print("STATE STORE: delta parent=%s elements_changed=%d entities_added=%d entities_updated=%d" % [
        str(payload.get("parent_message_id", "")),
        payload.get("elements_changed", []).size(),
        payload.get("entities_added", []).size(),
        payload.get("entities_updated", []).size()
    ])
    var parent := str(payload.get("parent_message_id", ""))
    if last_message_id != "" and parent != "" and parent != last_message_id and not parent.begins_with("revision-"):
        resync_required.emit("delta parent mismatch: expected %s, got %s" % [last_message_id, parent])
        return false

    var next_elements: Dictionary = elements_by_id.duplicate(true)
    var next_entities: Dictionary = entities_by_id.duplicate(true)
    for change in payload.get("elements_changed", []):
        if not change is Dictionary:
            continue
        var element_id := str(change.get("element_id", change.get("id", "")))
        if element_id == "":
            continue
        if str(change.get("change_type", "updated")) == "removed":
            next_elements.erase(element_id)
        else:
            var previous: Dictionary = next_elements.get(element_id, {})
            var updated: Dictionary = previous.duplicate(true)
            for key in change:
                updated[key] = change[key]
            next_elements[element_id] = updated

    for entity in payload.get("entities_added", []):
        if entity is Dictionary:
            next_entities[str(entity.get("id", entity.get("entity_id", "")))] = entity.duplicate(true)
    for entity in payload.get("entities_updated", []):
        if entity is Dictionary:
            var entity_id := str(entity.get("id", entity.get("entity_id", "")))
            var updated_entity: Dictionary = next_entities.get(entity_id, {}).duplicate(true)
            for key in entity:
                updated_entity[key] = entity[key]
            next_entities[entity_id] = updated_entity
    for entity_id in payload.get("entities_removed", []):
        next_entities.erase(str(entity_id))

    elements_by_id = next_elements
    entities_by_id = next_entities
    if payload.has("abm_state_delta") and payload.abm_state_delta != null:
        abm_state = payload.abm_state_delta
    if payload.has("overlay_updates"):
        overlays = payload.overlay_updates
    last_message_id = str(message.get("message_id", last_message_id))
    revision += 1
    var state := render_state()
    delta_applied.emit(state)
    return true

func _index_records(records: Array, id_key: String) -> Dictionary:
    var indexed := {}
    for record in records:
        if record is Dictionary:
            var id := str(record.get(id_key, ""))
            if id != "":
                indexed[id] = record.duplicate(true)
    return indexed

func _pack_entity_positions(records: Array) -> void:
    packed_entity_positions.resize(records.size())
    packed_entity_ids.resize(records.size())
    for index in range(records.size()):
        var record = records[index]
        if not record is Dictionary:
            continue
        packed_entity_ids[index] = str(record.get("id", "entity-%d" % index))
        var trajectory = record.get("trajectory_2d", [])
        if trajectory is Array and not trajectory.is_empty():
            var point = trajectory.back()
            if point is Array and point.size() >= 2:
                packed_entity_positions[index] = Vector2(float(point[0]), float(point[1]))

func _pack_binary_entity_positions(data: PackedByteArray, entity_count: int) -> void:
    var count: int = mini(entity_count, data.size() / 8)
    packed_entity_positions.resize(count)
    packed_entity_ids.resize(count)
    for index in range(count):
        var offset: int = index * 8
        packed_entity_positions[index] = Vector2(data.decode_float(offset), data.decode_float(offset + 4))
        packed_entity_ids[index] = "entity-%d" % index
