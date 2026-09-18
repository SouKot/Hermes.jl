class_name SimVizViewportController
extends PanelContainer

signal selection_changed(kind: String, id: String)

const BORDER := Color("#26384b")
const GRID := Color(0.18, 0.28, 0.36, 0.28)
const ELEMENT_COLOR := Color("#e6b85c")
const ENTITY_COLOR := Color("#52c7a5")
const SELECTED_COLOR := Color("#f08c6c")
const MAX_RENDER_ENTITIES := 10000
const MAX_DENSITY_CELLS := 10000

var render_state: Dictionary = {}
var camera_offset := Vector2.ZERO
var camera_zoom := 1.0
var selected_kind := ""
var selected_id := ""
var dragging := false
var drag_origin := Vector2.ZERO
var camera_origin := Vector2.ZERO
var show_trajectories := true
var show_density := true
var show_heatmap := true
var layer_timings_usec: Dictionary = {}
var _entity_multimesh_instance: MultiMeshInstance2D
var _entity_multimesh: MultiMesh

func _ready() -> void:
    add_theme_stylebox_override("panel", _panel_style())
    mouse_filter = Control.MOUSE_FILTER_STOP
    _entity_multimesh_instance = MultiMeshInstance2D.new()
    _entity_multimesh_instance.visible = false
    add_child(_entity_multimesh_instance)
    queue_redraw()

func set_render_state(next_state: Dictionary) -> void:
    render_state = next_state
    queue_redraw()

func set_layer_enabled(layer: String, enabled: bool) -> void:
    match layer.to_lower():
        "trajectories":
            show_trajectories = enabled
        "density":
            show_density = enabled
        "heatmap":
            show_heatmap = enabled
    queue_redraw()

func get_layer_timings_usec() -> Dictionary:
    return layer_timings_usec.duplicate()

func get_density_cell_count() -> int:
    return _density_cells().size()

func clear_selection() -> void:
    selected_kind = ""
    selected_id = ""
    selection_changed.emit("", "")
    queue_redraw()

func _gui_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
            var hit := _pick_entity(event.position)
            if hit != "":
                selected_kind = "entity"
                selected_id = hit
                selection_changed.emit(selected_kind, selected_id)
                accept_event()
                queue_redraw()
            else:
                var element_hit := _pick_element(event.position)
                if element_hit != "":
                    selected_kind = "element"
                    selected_id = element_hit
                    selection_changed.emit(selected_kind, selected_id)
                    accept_event()
                    queue_redraw()
                else:
                    clear_selection()
        elif event.button_index == MOUSE_BUTTON_MIDDLE:
            dragging = event.pressed
            drag_origin = event.position
            camera_origin = camera_offset
        elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
            camera_zoom = min(camera_zoom * 1.1, 8.0)
            queue_redraw()
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
            camera_zoom = max(camera_zoom / 1.1, 0.2)
            queue_redraw()
    elif event is InputEventMouseMotion and dragging:
        camera_offset = camera_origin + event.position - drag_origin
        queue_redraw()

func _draw() -> void:
    var rect := size
    var background := Color("#0d1a24")
    draw_rect(Rect2(Vector2.ZERO, rect), background)

    var center := rect * 0.5 + camera_offset
    var density_start := Time.get_ticks_usec()
    if show_density:
        _draw_density_grid(center)
    layer_timings_usec["density"] = Time.get_ticks_usec() - density_start
    var heatmap_start := Time.get_ticks_usec()
    if show_heatmap:
        _draw_heatmap_layer(center)
    layer_timings_usec["heatmap"] = Time.get_ticks_usec() - heatmap_start

    var elements: Dictionary = render_state.get("elements_by_id", {})
    for element_id in elements:
        var element: Dictionary = elements[element_id]
        var position := _element_position(str(element_id), center)
        var occupancy: float = float(element.get("occupancy", element.get("occupancy_after", 0)))
        var radius: float = 10.0 + min(occupancy, 32.0) * 0.35
        var selected := selected_kind == "element" and str(element_id) == selected_id
        if selected:
            draw_circle(position, radius + 5.0, SELECTED_COLOR)
        draw_circle(position, radius, ELEMENT_COLOR)
        draw_string(ThemeDB.fallback_font, position + Vector2(12, 4), str(element_id),
            HORIZONTAL_ALIGNMENT_LEFT, -1, 11, SELECTED_COLOR if selected else Color("#dfeaf6"))

    var entities: Dictionary = render_state.get("entities_by_id", {})
    var packed_positions: PackedVector2Array = render_state.get("entity_positions", PackedVector2Array())
    _update_packed_entities(packed_positions, center)
    var trajectory_start := Time.get_ticks_usec()
    if show_trajectories:
        _draw_trajectories(entities, center)
    layer_timings_usec["trajectories"] = Time.get_ticks_usec() - trajectory_start

    var rendered := 0
    for entity_id in entities:
        if rendered >= MAX_RENDER_ENTITIES:
            break
        var entity: Dictionary = entities[entity_id]
        var position := _entity_position(entity, center)
        var selected := selected_kind == "entity" and str(entity_id) == selected_id
        if selected:
            draw_circle(position, 9.0, SELECTED_COLOR)
        draw_circle(position, 4.0, ENTITY_COLOR)
        rendered += 1

    var count := entities.size()
    if not packed_positions.is_empty():
        count = packed_positions.size()
    var label := "ENTITIES %d" % count
    if count > MAX_RENDER_ENTITIES:
        label += "  ·  RENDER CAP %d" % MAX_RENDER_ENTITIES
    draw_string(ThemeDB.fallback_font, Vector2(16, size.y - 18), label,
        HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#8da2b5"))
    draw_string(ThemeDB.fallback_font, Vector2(16, 24),
        "SIM VIEWPORT  /  ZOOM %.0f%%" % (camera_zoom * 100.0),
        HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#c9d6e3"))

    var layer_label := "LAYERS  T:%s D:%s H:%s" % [
        "on" if show_trajectories else "off",
        "on" if show_density else "off",
        "on" if show_heatmap else "off"
    ]
    draw_string(ThemeDB.fallback_font, Vector2(16, 42), layer_label,
        HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#8da2b5"))
    draw_string(ThemeDB.fallback_font, Vector2(16, 60),
        "GREEN entities  /  YELLOW elements  /  RED selected",
        HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#8da2b5"))
    draw_string(ThemeDB.fallback_font, Vector2(16, 78),
        "HEATMAP density: cool low  ->  warm high",
        HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#8da2b5"))

    var warnings: Array = render_state.get("warnings", [])
    if not warnings.is_empty():
        var banner := "WARNINGS: %d" % warnings.size()
        var banner_color := Color("#f0bf69")
        draw_rect(Rect2(Vector2(14, 42), Vector2(220, 26)), Color(0.06, 0.11, 0.15, 0.8))
        draw_string(ThemeDB.fallback_font, Vector2(22, 60), banner,
            HORIZONTAL_ALIGNMENT_LEFT, -1, 12, banner_color)

func _draw_trajectories(entities: Dictionary, center: Vector2) -> void:
    for entity_id in entities:
        var entity: Dictionary = entities[entity_id]
        var trajectory: Array = entity.get("trajectory_2d", [])
        if trajectory.size() < 2:
            continue
        var points: PackedVector2Array = PackedVector2Array()
        for point in trajectory:
            if point is Array and point.size() >= 2:
                var px: float = float(point[0])
                var py: float = float(point[1])
                points.append(center + Vector2(px, py) * camera_zoom + camera_offset)
        if points.size() >= 2:
            draw_polyline(points, ENTITY_COLOR, 1.5, true)

func _draw_density_grid(center: Vector2) -> void:
    var cells := _density_cells()
    if cells.is_empty():
        return
    for cell in cells:
        var position := center + Vector2(float(cell.get("x", 0.0)), float(cell.get("y", 0.0))) * camera_zoom + camera_offset
        var cell_size := float(cell.get("size", 36.0)) * camera_zoom
        draw_rect(Rect2(position - Vector2.ONE * cell_size * 0.5, Vector2.ONE * cell_size), Color(0.3, 0.5, 0.6, 0.18), false, 1.0)

func _draw_heatmap_layer(center: Vector2) -> void:
    var cells := _density_cells()
    if cells.is_empty():
        return
    var range_values := _density_range(cells)
    var minimum: float = range_values.x
    var maximum: float = range_values.y
    for cell in cells:
        var value: float = float(cell.get("value", 0.0))
        var intensity: float = inverse_lerp(minimum, maximum, value)
        var color := Color.from_hsv(0.66 - intensity * 0.66, 0.82, 0.92, 0.16 + intensity * 0.42)
        var position := center + Vector2(float(cell.get("x", 0.0)), float(cell.get("y", 0.0))) * camera_zoom + camera_offset
        var cell_size := float(cell.get("size", 36.0)) * camera_zoom
        draw_rect(Rect2(position - Vector2.ONE * cell_size * 0.5, Vector2.ONE * cell_size), color, true)

func _density_range(cells: Array) -> Vector2:
    var abm_variant = render_state.get("abm_state", null)
    if abm_variant is Dictionary:
        var abm: Dictionary = abm_variant
        if abm.has("density_min") and abm.has("density_max"):
            var declared_min := float(abm.get("density_min", 0.0))
            var declared_max := float(abm.get("density_max", 1.0))
            if declared_max > declared_min:
                return Vector2(declared_min, declared_max)
    var minimum := INF
    var maximum := -INF
    for cell in cells:
        var value: float = float(cell.get("value", 0.0))
        minimum = min(minimum, value)
        maximum = max(maximum, value)
    if not is_finite(minimum) or not is_finite(maximum) or maximum <= minimum:
        return Vector2(0.0, 1.0)
    return Vector2(minimum, maximum)

func _density_cells() -> Array:
    var abm_variant = render_state.get("abm_state", null)
    if not abm_variant is Dictionary:
        return []
    var abm: Dictionary = abm_variant
    var raw = abm.get("density_field", abm.get("crowd_density_grid", []))
    if raw is Dictionary:
        raw = raw.get("values", raw.get("cells", []))
    if not raw is Array:
        return []
    var cells: Array = []
    var origin: Vector2 = _vector2_from_value(abm.get("grid_origin", abm.get("origin", [0.0, 0.0])))
    var cell_size: float = float(abm.get("cell_size", abm.get("grid_cell_size", 36.0)))
    if raw.is_empty():
        return cells
    if raw[0] is Array:
        for row_index in range(raw.size()):
            var row = raw[row_index]
            if not row is Array:
                continue
            for column_index in range(row.size()):
                cells.append({
                    "x": origin.x + (float(column_index) + 0.5) * cell_size,
                    "y": origin.y + (float(row_index) + 0.5) * cell_size,
                    "value": float(row[column_index]),
                    "size": cell_size
                })
                if cells.size() >= MAX_DENSITY_CELLS:
                    return cells
    else:
        var width: int = int(abm.get("grid_width", abm.get("width", 0)))
        if width <= 0:
            width = int(ceil(sqrt(float(raw.size()))))
        for index in range(raw.size()):
            cells.append({
                "x": origin.x + (float(index % width) + 0.5) * cell_size,
                "y": origin.y + (float(index / width) + 0.5) * cell_size,
                "value": float(raw[index]),
                "size": cell_size
            })
            if cells.size() >= MAX_DENSITY_CELLS:
                return cells
    return cells

func _vector2_from_value(value: Variant) -> Vector2:
    if value is Array and value.size() >= 2:
        return Vector2(float(value[0]), float(value[1]))
    return Vector2.ZERO


func _element_position(element_id: String, center: Vector2) -> Vector2:
    var hash_value: int = abs(element_id.hash())
    var column: int = hash_value % 5
    var row: int = (hash_value / 5) % 5
    return center + Vector2(float(column - 2) * 110.0, float(row - 2) * 70.0) * camera_zoom

func _entity_position(entity: Dictionary, center: Vector2) -> Vector2:
    var trajectory = entity.get("trajectory_2d", [])
    if trajectory is Array and not trajectory.is_empty():
        var point = trajectory.back()
        if point is Array and point.size() >= 2:
            return center + Vector2(float(point[0]), float(point[1])) * camera_zoom + camera_offset
    var id_hash: int = abs(str(entity.get("id", "")).hash())
    var angle: float = float(id_hash % 360) * PI / 180.0
    var radius: float = 80.0 + float(id_hash % 180)
    return center + Vector2(cos(angle), sin(angle)) * radius * camera_zoom

func _pick_entity(mouse_position: Vector2) -> String:
    var center := size * 0.5 + camera_offset
    var entities: Dictionary = render_state.get("entities_by_id", {})
    if entities.is_empty():
        return ""
    var closest := ""
    var closest_distance := 24.0
    for entity_id in entities:
        var distance := mouse_position.distance_to(_entity_position(entities[entity_id], center))
        if distance < closest_distance:
            closest_distance = distance
            closest = str(entity_id)
    return closest

func _pick_element(mouse_position: Vector2) -> String:
    var center := size * 0.5 + camera_offset
    var elements: Dictionary = render_state.get("elements_by_id", {})
    var closest := ""
    var closest_distance := 26.0
    for element_id in elements:
        var distance := mouse_position.distance_to(_element_position(str(element_id), center))
        if distance < closest_distance:
            closest_distance = distance
            closest = str(element_id)
    return closest

func _panel_style() -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = Color("#0e1722")
    style.border_color = BORDER
    style.set_border_width_all(1)
    return style

func _update_packed_entities(positions: PackedVector2Array, center: Vector2) -> void:
    if positions.is_empty():
        _entity_multimesh_instance.visible = false
        return
    if _entity_multimesh == null or _entity_multimesh.instance_count != positions.size():
        _entity_multimesh = MultiMesh.new()
        _entity_multimesh.transform_format = MultiMesh.TRANSFORM_2D
        _entity_multimesh.use_colors = true
        _entity_multimesh.instance_count = positions.size()
        var quad := QuadMesh.new()
        quad.size = Vector2(8.0, 8.0)
        _entity_multimesh.mesh = quad
        _entity_multimesh_instance.multimesh = _entity_multimesh
    _entity_multimesh_instance.position = center + camera_offset
    for index in range(positions.size()):
        _entity_multimesh.set_instance_transform_2d(index, Transform2D(0.0, positions[index] * camera_zoom))
        _entity_multimesh.set_instance_color(index, ENTITY_COLOR)
    _entity_multimesh_instance.visible = true
