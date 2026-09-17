extends Control

const ConnectionManager := preload("res://scripts/connection_manager.gd")
const StateStore := preload("res://scripts/state_store.gd")
const ViewportController := preload("res://scripts/viewport_controller.gd")

const BG := Color("#0b1018")
const PANEL := Color("#121b27")
const PANEL_ALT := Color("#172333")
const BORDER := Color("#26384b")
const TEXT := Color("#e5edf5")
const MUTED := Color("#8da2b5")
const ACCENT := Color("#52c7a5")
const WARNING := Color("#e6b85c")

var status_label: Label
var simulation_label: Label
var viewport_panel: Control
var viewport_controller
var entity_count := 128
var simulation_time := 0.0
var running := false
var connection_manager: SimVizConnectionManager
var state_store: RefCounted

func _ready() -> void:
    connection_manager = ConnectionManager.new()
    add_child(connection_manager)
    state_store = StateStore.new()
    connection_manager.connection_state_changed.connect(_on_connection_state_changed)
    connection_manager.message_received.connect(_on_protocol_message)
    connection_manager.protocol_error.connect(_on_protocol_error)
    state_store.state_replaced.connect(_on_state_published)
    state_store.delta_applied.connect(_on_state_published)
    state_store.resync_required.connect(_on_resync_required)
    _build_shell()
    _build_placeholder_scene()

func _process(delta: float) -> void:
    if running:
        simulation_time += delta
        simulation_label.text = "t = %.2f s" % simulation_time
        queue_redraw()

func _build_shell() -> void:
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var background := ColorRect.new()
    background.color = BG
    background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(background)

    var root := VBoxContainer.new()
    root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    root.add_theme_constant_override("separation", 0)
    add_child(root)

    root.add_child(_build_header())

    var content := HBoxContainer.new()
    content.size_flags_vertical = Control.SIZE_EXPAND_FILL
    content.add_theme_constant_override("separation", 10)
    content.add_theme_constant_override("margin_left", 12)
    content.add_theme_constant_override("margin_right", 12)
    root.add_child(content)

    content.add_child(_build_left_panel())
    viewport_panel = _build_viewport()
    content.add_child(viewport_panel)
    content.add_child(_build_right_panel())

    root.add_child(_build_transport())

func _build_header() -> Control:
    var panel := PanelContainer.new()
    panel.custom_minimum_size.y = 58
    panel.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 0, 1))
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 16)
    row.add_theme_constant_override("margin_left", 18)
    row.add_theme_constant_override("margin_right", 18)
    panel.add_child(row)
    var title := Label.new()
    title.text = "ANTIGRAVITY  /  SIMVIZ"
    title.add_theme_font_size_override("font_size", 19)
    title.add_theme_color_override("font_color", TEXT)
    row.add_child(title)
    var phase := Label.new()
    phase.text = "PHASE 7C  ·  MONITORING SHELL"
    phase.add_theme_font_size_override("font_size", 12)
    phase.add_theme_color_override("font_color", MUTED)
    phase.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(phase)
    var spacer := Control.new()
    spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(spacer)
    status_label = Label.new()
    status_label.text = "●  OFFLINE FIXTURE"
    status_label.add_theme_color_override("font_color", WARNING)
    status_label.add_theme_font_size_override("font_size", 13)
    row.add_child(status_label)
    return panel

func _build_left_panel() -> Control:
    var panel := PanelContainer.new()
    panel.custom_minimum_size.x = 230
    panel.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 0, 1))
    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 10)
    column.add_theme_constant_override("margin_left", 14)
    column.add_theme_constant_override("margin_right", 14)
    column.add_theme_constant_override("margin_top", 14)
    column.add_theme_constant_override("margin_bottom", 14)
    panel.add_child(column)
    column.add_child(_heading("RUNTIME"))
    column.add_child(_metric("Adapter", "OfflineFixture"))
    column.add_child(_metric("Protocol", "v1 / MessagePack"))
    column.add_child(_metric("Scene", "acceptance_fixture"))
    column.add_spacer(false)
    column.add_child(_heading("SCENE TREE"))
    for item in ["Simulation", "  ├─ Queues", "  ├─ Entities", "  └─ Overlays"]:
        var label := Label.new()
        label.text = item
        label.add_theme_color_override("font_color", MUTED if item != "Simulation" else TEXT)
        label.add_theme_font_size_override("font_size", 13)
        column.add_child(label)
    return panel

func _build_viewport() -> Control:
    viewport_controller = ViewportController.new()
    var panel: Control = viewport_controller
    panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
    viewport_controller.selection_changed.connect(_on_viewport_selection)
    return panel

func _on_viewport_selection(kind: String, id: String) -> void:
    if kind == "":
        return
    status_label.text = "●  SELECTED %s" % id
    status_label.add_theme_color_override("font_color", ACCENT)

func _draw_viewport(panel: Control) -> void:
    var rect := panel.get_rect()
    var grid_color := Color(0.18, 0.28, 0.36, 0.28)
    for x in range(0, int(rect.size.x), 40):
        panel.draw_line(Vector2(x, 0), Vector2(x, rect.size.y), grid_color, 1)
    for y in range(0, int(rect.size.y), 40):
        panel.draw_line(Vector2(0, y), Vector2(rect.size.x, y), grid_color, 1)
    var center := rect.size * 0.5
    panel.draw_circle(center, 64, Color("#193348"))
    panel.draw_arc(center, 64, 0, TAU, 48, ACCENT, 2)
    for index in range(28):
        var angle := float(index) * TAU / 28.0 + simulation_time * 0.18
        var radius := 105.0 + float(index % 4) * 24.0
        var position := center + Vector2(cos(angle), sin(angle)) * radius
        panel.draw_circle(position, 4.0, ACCENT if index % 3 else WARNING)
    panel.draw_string(ThemeDB.fallback_font, Vector2(18, 28), "LIVE VIEWPORT  /  OFFLINE FIXTURE", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MUTED)

func _build_right_panel() -> Control:
    var panel := PanelContainer.new()
    panel.custom_minimum_size.x = 260
    panel.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 0, 1))
    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 10)
    column.add_theme_constant_override("margin_left", 14)
    column.add_theme_constant_override("margin_right", 14)
    column.add_theme_constant_override("margin_top", 14)
    column.add_theme_constant_override("margin_bottom", 14)
    panel.add_child(column)
    column.add_child(_heading("INSPECTOR"))
    column.add_child(_metric("Selection", "None"))
    column.add_child(_metric("Elements", "0 queues"))
    column.add_child(_metric("Entities", str(entity_count)))
    column.add_child(_metric("Update mode", "Typed delta"))
    column.add_spacer(false)
    column.add_child(_heading("CONNECTION"))
    column.add_child(_metric("Endpoint", "127.0.0.1:9000"))
    column.add_child(_metric("Transport", "MessagePack"))
    return panel

func _build_transport() -> Control:
    var panel := PanelContainer.new()
    panel.custom_minimum_size.y = 64
    panel.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 0, 1))
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 10)
    row.add_theme_constant_override("margin_left", 14)
    row.add_theme_constant_override("margin_right", 14)
    row.add_theme_constant_override("margin_top", 10)
    row.add_theme_constant_override("margin_bottom", 10)
    panel.add_child(row)
    var connect := Button.new()
    connect.text = "CONNECT"
    connect.pressed.connect(_on_connect)
    row.add_child(connect)
    var play := Button.new()
    play.text = "PLAY"
    play.pressed.connect(_on_play)
    row.add_child(play)
    var pause := Button.new()
    pause.text = "PAUSE"
    pause.pressed.connect(_on_pause)
    row.add_child(pause)
    var step := Button.new()
    step.text = "STEP"
    step.pressed.connect(_on_step)
    row.add_child(step)
    var reset := Button.new()
    reset.text = "RESET"
    reset.pressed.connect(_on_reset)
    row.add_child(reset)
    var spacer := Control.new()
    spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(spacer)
    simulation_label = Label.new()
    simulation_label.text = "t = 0.00 s"
    simulation_label.add_theme_color_override("font_color", TEXT)
    simulation_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(simulation_label)
    return panel

func _on_connect() -> void:
    connection_manager.connect_to()

func _on_connection_state_changed(state: String, detail: String) -> void:
    status_label.text = "●  %s" % state.to_upper()
    status_label.add_theme_color_override(
        "font_color", ACCENT if state == "connected" else WARNING
    )

func _on_protocol_message(message: Dictionary) -> void:
    if state_store.apply_message(message):
        status_label.text = "●  MESSAGE: %s" % str(message.get("kind", "unknown")).to_upper()
        status_label.add_theme_color_override("font_color", ACCENT)

func _on_protocol_error(detail: String) -> void:
    status_label.text = "●  PROTOCOL ERROR"
    status_label.add_theme_color_override("font_color", WARNING)
    push_warning(detail)

func _on_state_published(state: Dictionary) -> void:
    entity_count = state.entities_by_id.size()
    if viewport_controller:
        viewport_controller.set_render_state(state)

func _on_resync_required(reason: String) -> void:
    status_label.text = "●  RESYNC REQUIRED"
    status_label.add_theme_color_override("font_color", WARNING)
    push_warning(reason)

func _on_play() -> void:
    running = true

func _on_pause() -> void:
    running = false

func _on_step() -> void:
    simulation_time += 0.1
    simulation_label.text = "t = %.2f s" % simulation_time
    queue_redraw()

func _on_reset() -> void:
    running = false
    simulation_time = 0.0
    simulation_label.text = "t = 0.00 s"
    queue_redraw()

func _build_placeholder_scene() -> void:
    queue_redraw()

func _heading(text: String) -> Label:
    var label := Label.new()
    label.text = text
    label.add_theme_color_override("font_color", ACCENT)
    label.add_theme_font_size_override("font_size", 11)
    return label

func _metric(name: String, value: String) -> Control:
    var row := HBoxContainer.new()
    var key := Label.new()
    key.text = name
    key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    key.add_theme_color_override("font_color", MUTED)
    var val := Label.new()
    val.text = value
    val.add_theme_color_override("font_color", TEXT)
    row.add_child(key)
    row.add_child(val)
    return row

func _box(color: Color, border: Color, radius: int, width: int) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = color
    style.border_color = border
    style.set_border_width_all(width)
    style.set_corner_radius_all(radius)
    return style
