class_name SimVizViewportController
extends PanelContainer

signal selection_changed(kind: String, id: String)

const BORDER := Color("#26384b")
const GRID := Color(0.18, 0.28, 0.36, 0.28)
const ELEMENT_COLOR := Color("#e6b85c")
const ENTITY_COLOR := Color("#52c7a5")
const SELECTED_COLOR := Color("#f08c6c")
const MAX_RENDER_ENTITIES := 10000

var render_state: Dictionary = {}
var camera_offset := Vector2.ZERO
var camera_zoom := 1.0
var selected_kind := ""
var selected_id := ""
var dragging := false
var drag_origin := Vector2.ZERO
var camera_origin := Vector2.ZERO

func _ready() -> void:
    add_theme_stylebox_override("panel", _panel_style())
    mouse_filter = Control.MOUSE_FILTER_STOP
    queue_redraw()

func set_render_state(next_state: Dictionary) -> void:
    render_state = next_state
    queue_redraw()

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
    for x in range(0, int(rect.x), 40):
        draw_line(Vector2(x, 0), Vector2(x, rect.y), GRID, 1.0)
    for y in range(0, int(rect.y), 40):
        draw_line(Vector2(0, y), Vector2(rect.x, y), GRID, 1.0)

    var center := rect * 0.5 + camera_offset
    var elements: Dictionary = render_state.get("elements_by_id", {})
    for element_id in elements:
        var element: Dictionary = elements[element_id]
        var position := _element_position(str(element_id), center)
        var occupancy: float = float(element.get("occupancy", element.get("occupancy_after", 0)))
        var radius: float = 10.0 + min(occupancy, 32.0) * 0.35
        draw_circle(position, radius, ELEMENT_COLOR)
        draw_string(ThemeDB.fallback_font, position + Vector2(12, 4), str(element_id),
            HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#dfeaf6"))

    var entities: Dictionary = render_state.get("entities_by_id", {})
    var rendered := 0
    for entity_id in entities:
        if rendered >= MAX_RENDER_ENTITIES:
            break
        var entity: Dictionary = entities[entity_id]
        var position := _entity_position(entity, center)
        var color := SELECTED_COLOR if str(entity_id) == selected_id else ENTITY_COLOR
        draw_circle(position, 4.0 if str(entity_id) != selected_id else 7.0, color)
        rendered += 1

    var count := entities.size()
    var label := "ENTITIES %d" % count
    if count > MAX_RENDER_ENTITIES:
        label += "  ·  RENDER CAP %d" % MAX_RENDER_ENTITIES
    draw_string(ThemeDB.fallback_font, Vector2(16, size.y - 18), label,
        HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#8da2b5"))
    draw_string(ThemeDB.fallback_font, Vector2(16, 24),
        "SIM VIEWPORT  /  ZOOM %.0f%%" % (camera_zoom * 100.0),
        HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#c9d6e3"))

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
    var closest := ""
    var closest_distance := 12.0
    for entity_id in entities:
        var distance := mouse_position.distance_to(_entity_position(entities[entity_id], center))
        if distance < closest_distance:
            closest_distance = distance
            closest = str(entity_id)
    return closest

func _panel_style() -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = Color("#0e1722")
    style.border_color = BORDER
    style.set_border_width_all(1)
    return style
