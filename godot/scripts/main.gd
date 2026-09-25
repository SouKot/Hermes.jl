extends Control

const ConnectionManager := preload("res://scripts/connection_manager.gd")
const StateStore := preload("res://scripts/state_store.gd")
const ViewportController := preload("res://scripts/viewport_controller.gd")
const AuthoringShell := preload("res://scripts/authoring_shell.gd")

const BG := Color("#0b1018")
const PANEL := Color("#121b27")
const PANEL_ALT := Color("#172333")
const BORDER := Color("#26384b")
const TEXT := Color("#e5edf5")
const MUTED := Color("#8da2b5")
const ACCENT := Color("#52c7a5")
const WARNING := Color("#e6b85c")

var authoring_shell: Control
var status_label: Label
var simulation_label: Label
var viewport_panel: Control
var viewport_controller
var runtime_adapter_label: Label
var runtime_scene_label: Label
var inspector_element_label: Label
var inspector_entity_label: Label
var connection_endpoint_label: Label
var command_status_label: Label
var command_detail_label: Label
var inspector_selection_label: Label
var inspector_value_label: Label
var speed_label: Label
var speed_slider: HSlider
var fps_label: Label
var update_rate_label: Label
var warnings_label: Label
var layer_timing_label: Label
var density_info_label: Label
var entity_count := 0
var element_count := 0
var adapter_name := "Booting"
var scene_name := "waiting"
var endpoint_text := "127.0.0.1:9107"
var simulation_time := 0.0
var running := false
var is_sim_compiled := false
var connection_manager: ConnectionManager
var state_store: RefCounted
var pending_commands: Dictionary = {}
var selected_kind := ""
var selected_id := ""
var _status_tint: Color = WARNING
var _last_command_status := "idle"
var _fps: float = 0.0
var _update_rate: float = 0.0
var _frame_accum: int = 0
var _update_accum: int = 0
var _state_update_accum: int = 0
var _metric_timer: float = 0.0
var _last_metrics_time: float = 0.0
var _last_warning_count: int = 0

func _ready() -> void:
    pending_commands = {}
    connection_manager = ConnectionManager.new()
    add_child(connection_manager)
    state_store = StateStore.new()
    connection_manager.connection_state_changed.connect(_on_connection_state_changed)
    connection_manager.message_received.connect(_on_protocol_message)
    connection_manager.protocol_error.connect(_on_protocol_error)
    state_store.state_replaced.connect(_on_state_published)
    state_store.delta_applied.connect(_on_state_published)
    state_store.resync_required.connect(_on_resync_required)
    _build_authoring_shell()
    call_deferred("_auto_connect")

func _build_authoring_shell() -> void:
    authoring_shell = AuthoringShell.new()
    authoring_shell.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(authoring_shell)
    authoring_shell.play_requested.connect(_on_play)
    authoring_shell.pause_requested.connect(_on_pause)
    authoring_shell.step_requested.connect(_on_step)
    authoring_shell.reset_requested.connect(_on_reset)
    authoring_shell.speed_changed.connect(_on_speed_changed)
    if authoring_shell.doc_store != null:
        authoring_shell.doc_store.document_modified.connect(func():
            is_sim_compiled = false
        )

func _auto_connect() -> void:
    if connection_manager != null and connection_manager.state != ConnectionManager.ConnectionState.CONNECTED:
        connection_manager.connect_to("127.0.0.1", 9107, "/")

func _process(delta: float) -> void:
    _metric_timer += delta
    _frame_accum += 1
    _update_accum += 1 if running else 0
    if _metric_timer >= 1.0:
        var elapsed: float = max(_metric_timer, 0.0001)
        _fps = _frame_accum / elapsed
        _update_rate = _state_update_accum / elapsed
        _frame_accum = 0
        _update_accum = 0
        _state_update_accum = 0
        _metric_timer = 0.0
        if fps_label != null:
            fps_label.text = "%.1f FPS" % _fps
        if update_rate_label != null:
            update_rate_label.text = "%.1f/s" % _update_rate
            if layer_timing_label != null and viewport_controller != null:
                var timings: Dictionary = viewport_controller.get_layer_timings_usec()
                layer_timing_label.text = "CPU us D/H/T: %d/%d/%d" % [
                    int(timings.get("density", 0)), int(timings.get("heatmap", 0)), int(timings.get("trajectories", 0))
                ]
            if density_info_label != null and viewport_controller != null:
                density_info_label.text = "Density cells: %d / 10000 cap" % viewport_controller.get_density_cell_count()
    if running:
        simulation_time += delta
        if simulation_label != null:
            simulation_label.text = "t = %.2f s" % simulation_time
        if authoring_shell != null:
            authoring_shell.update_sim_time(simulation_time)
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
    _update_status("booting", "booting live monitor")

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
    var adapter_row := _metric("Adapter", adapter_name)
    column.add_child(adapter_row)
    runtime_adapter_label = adapter_row.get_child(1)
    column.add_child(_metric("Protocol", "v1 / MessagePack"))
    var scene_row := _metric("Scene", scene_name)
    column.add_child(scene_row)
    runtime_scene_label = scene_row.get_child(1)
    column.add_spacer(false)
    column.add_child(_heading("SCENE TREE"))
    for item in ["Simulation", "  ├─ Queues", "  ├─ Entities", "  └─ Overlays"]:
        var label := Label.new()
        label.text = item
        label.add_theme_color_override("font_color", MUTED if item != "Simulation" else TEXT)
        label.add_theme_font_size_override("font_size", 13)
        column.add_child(label)
        var layer_row := _metric("Layer CPU", "0/0/0 us")
        column.add_child(layer_row)
        layer_timing_label = layer_row.get_child(1)
        var density_row := _metric("Density cells", "0 / 10000 cap")
        column.add_child(density_row)
        density_info_label = density_row.get_child(1)
    return panel

func _build_viewport() -> Control:
    viewport_controller = ViewportController.new()
    var panel: Control = viewport_controller
    panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
    viewport_controller.selection_changed.connect(_on_viewport_selection)
    return panel

func _on_viewport_selection(kind: String, id: String) -> void:
    selected_kind = kind
    selected_id = id
    if kind == "":
        if inspector_selection_label != null:
            inspector_selection_label.text = "None"
        if inspector_value_label != null:
            inspector_value_label.text = "-"
        if command_detail_label != null:
            command_detail_label.text = "No selection"
        return
    if status_label != null:
        status_label.text = "●  SELECTED %s" % id
        status_label.add_theme_color_override("font_color", ACCENT)
    _update_selection_details(kind, id)

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
    var selection_row := _metric("Selection", "None")
    column.add_child(selection_row)
    inspector_selection_label = selection_row.get_child(1)
    var selected_type_row := _metric("Type", "-")
    column.add_child(selected_type_row)
    inspector_value_label = selected_type_row.get_child(1)
    var element_row := _metric("Elements", "%d queues" % element_count)
    column.add_child(element_row)
    inspector_element_label = element_row.get_child(1)
    var entity_row := _metric("Entities", str(entity_count))
    column.add_child(entity_row)
    inspector_entity_label = entity_row.get_child(1)
    var cmd_status_row := _metric("Command", "idle")
    column.add_child(cmd_status_row)
    command_status_label = cmd_status_row.get_child(1)
    command_detail_label = Label.new()
    command_detail_label.text = "No recent command"
    command_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    command_detail_label.add_theme_color_override("font_color", MUTED)
    command_detail_label.add_theme_font_size_override("font_size", 11)
    column.add_child(command_detail_label)
    column.add_spacer(false)
    column.add_child(_heading("METRICS"))
    var fps_row := _metric("FPS", "0.0 FPS")
    column.add_child(fps_row)
    fps_label = fps_row.get_child(1)
    var update_row := _metric("Update rate", "0.0/s")
    column.add_child(update_row)
    update_rate_label = update_row.get_child(1)
    var warning_row := _metric("Warnings", "0")
    column.add_child(warning_row)
    warnings_label = warning_row.get_child(1)
    column.add_child(_metric("Update mode", "Typed delta"))
    column.add_spacer(false)
    column.add_child(_heading("CONNECTION"))
    var endpoint_row := _metric("Endpoint", endpoint_text)
    column.add_child(endpoint_row)
    connection_endpoint_label = endpoint_row.get_child(1)
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
    var speed_row := VBoxContainer.new()
    speed_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    var speed_title := Label.new()
    speed_title.text = "SPEED"
    speed_title.add_theme_font_size_override("font_size", 10)
    speed_title.add_theme_color_override("font_color", MUTED)
    speed_row.add_child(speed_title)
    speed_slider = HSlider.new()
    speed_slider.min_value = 0.25
    speed_slider.max_value = 4.0
    speed_slider.step = 0.25
    speed_slider.value = 1.0
    speed_slider.custom_minimum_size.x = 120
    speed_slider.value_changed.connect(_on_speed_changed)
    speed_row.add_child(speed_slider)
    row.add_child(speed_row)
    speed_label = Label.new()
    speed_label.text = "1.00x"
    speed_label.add_theme_color_override("font_color", TEXT)
    speed_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(speed_label)
    var spacer := Control.new()
    spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(spacer)
    simulation_label = Label.new()
    simulation_label.text = "t = 0.00 s"
    simulation_label.add_theme_color_override("font_color", TEXT)
    simulation_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(simulation_label)
    row.add_child(_layer_toggle("TRAJ", "trajectories"))
    row.add_child(_layer_toggle("GRID", "density"))
    row.add_child(_layer_toggle("HEAT", "heatmap"))
    return panel

func _layer_toggle(text: String, layer: String) -> CheckButton:
    var toggle := CheckButton.new()
    toggle.text = text
    toggle.button_pressed = true
    toggle.tooltip_text = "Toggle %s rendering layer" % layer
    toggle.toggled.connect(_on_layer_toggled.bind(layer))
    return toggle

func _on_layer_toggled(enabled: bool, layer: String) -> void:
    if viewport_controller != null:
        viewport_controller.set_layer_enabled(layer, enabled)

func _on_connect() -> void:
    connection_manager.connect_to()

func _on_connection_state_changed(state: String, detail: String) -> void:
    _update_status(state, detail)

func _on_protocol_message(message: Dictionary) -> void:
    var kind := str(message.get("kind", "unknown")).to_lower()
    _update_status("message", kind.to_upper())
    if kind == "ack":
        var payload: Dictionary = message.get("payload", {})
        var status := str(payload.get("status", "accepted"))
        var acknowledged_id := str(payload.get("acknowledged_message_id", "unknown"))
        _last_command_status = status
        if acknowledged_id in pending_commands:
            pending_commands.erase(acknowledged_id)
        _update_status("ack", status)
        if command_status_label != null:
            command_status_label.text = "ACK: %s" % status
        if command_detail_label != null:
            var detail := str(payload.get("details", "Command accepted"))
            command_detail_label.text = "%s -> %s" % [acknowledged_id, detail]
        return
    if kind == "error":
        var payload: Dictionary = message.get("payload", {})
        var code := str(payload.get("error_code", "protocol_error"))
        var offending_id := str(payload.get("causing_message_id", "unknown"))
        _last_command_status = "error"
        if offending_id in pending_commands:
            pending_commands.erase(offending_id)
        _update_status("protocol error", code)
        if command_status_label != null:
            command_status_label.text = "ERR: %s" % code
        if command_detail_label != null:
            var details := str(payload.get("error_message", "Command rejected"))
            command_detail_label.text = "%s -> %s" % [offending_id, details]
        return
    if state_store.apply_message(message):
        _update_status("message", kind.to_upper())

func _on_protocol_error(detail: String) -> void:
    _update_status("protocol error", detail)
    push_warning(detail)

func _update_status(state: String, detail: String) -> void:
    var normalized := str(state).to_lower()
    var label := "●  %s" % normalized.to_upper()
    if detail != "" and detail != "booting live monitor":
        label = "●  %s  ·  %s" % [normalized.to_upper(), detail]
    match normalized:
        "connected":
            _status_tint = ACCENT
        "connecting":
            _status_tint = WARNING
        "reconnecting":
            _status_tint = WARNING
        "protocol error":
            _status_tint = WARNING
        "booting":
            _status_tint = WARNING
        "message":
            _status_tint = ACCENT
        _:
            _status_tint = WARNING
    if status_label != null:
        status_label.text = label
        status_label.add_theme_color_override("font_color", _status_tint)

func _on_state_published(state: Dictionary) -> void:
    _state_update_accum += 1
    element_count = state.get("elements_by_id", {}).size()
    entity_count = state.get("entities_by_id", {}).size()
    if state.has("scene_id") and str(state.scene_id) != "":
        scene_name = str(state.scene_id)
    if state.has("simulation_state"):
        var sim_st: String = str(state.simulation_state).to_lower()
        if sim_st == "running":
            running = true
            if authoring_shell != null:
                authoring_shell.is_sim_running = true
        elif sim_st in ["paused", "stopped"]:
            running = false
            if authoring_shell != null:
                authoring_shell.is_sim_running = false
    if state.has("simulation_time"):
        simulation_time = float(state.simulation_time)
        if simulation_label != null:
            simulation_label.text = "t = %.2f s" % simulation_time
        if authoring_shell != null:
            authoring_shell.update_sim_time(simulation_time)
    adapter_name = "LiveFixture" if state.has("scene_id") else "OfflineFixture"
    endpoint_text = "127.0.0.1:9107"
    var warning_count: int = int(state.get("warnings", []).size())
    if warnings_label != null:
        warnings_label.text = str(warning_count)
    if runtime_adapter_label != null:
        runtime_adapter_label.text = adapter_name
    if runtime_scene_label != null:
        runtime_scene_label.text = scene_name
    if inspector_element_label != null:
        inspector_element_label.text = "%d queues" % element_count
    if inspector_entity_label != null:
        inspector_entity_label.text = str(entity_count)
    if connection_endpoint_label != null:
        connection_endpoint_label.text = endpoint_text
    if viewport_controller:
        viewport_controller.set_render_state(state)
    if selected_kind != "":
        _update_selection_details(selected_kind, selected_id)

    # Forward entity telemetry to AuthoringShell (2D Canvas and 3D Viewport)
    var entity_list: Array = []
    var raw_entities: Array = []
    if state.has("entities_by_id") and state.entities_by_id is Dictionary:
        raw_entities = state.entities_by_id.values()
    elif state.has("entities") and state.entities is Array:
        raw_entities = state.entities

    for raw_ent in raw_entities:
        if raw_ent is Dictionary:
            var ent: Dictionary = raw_ent.duplicate(true)
            if ent.has("properties") and ent.properties is Dictionary:
                var p: Dictionary = ent.properties
                if not ent.has("x") and p.has("x"): ent["x"] = p.x
                if not ent.has("y") and p.has("y"): ent["y"] = p.y
                if not ent.has("z") and p.has("z"): ent["z"] = p.z
            if not ent.has("position"):
                ent["position"] = [float(ent.get("x", 0.0)), float(ent.get("y", 0.0)), float(ent.get("z", 0.0))]
            entity_list.append(ent)

    if authoring_shell != null:
        if authoring_shell.has_method("update_agent_telemetry"):
            authoring_shell.update_agent_telemetry(entity_list)
        if authoring_shell.has_method("update_simulation_telemetry"):
            authoring_shell.update_simulation_telemetry(state)

func _on_resync_required(reason: String) -> void:
    if status_label != null:
        status_label.text = "●  RESYNC REQUIRED"
        status_label.add_theme_color_override("font_color", WARNING)
    push_warning(reason)

func _on_play() -> void:
    running = true
    if authoring_shell != null:
        authoring_shell.is_sim_running = true
        if not is_sim_compiled and authoring_shell.doc_store != null:
            var scene_doc: Dictionary = {}
            if authoring_shell.doc_store.has_method("export_to_dictionary"):
                scene_doc = authoring_shell.doc_store.export_to_dictionary()
            elif authoring_shell.doc_store.active_document != null and authoring_shell.doc_store.active_document.has_method("to_dict"):
                scene_doc = authoring_shell.doc_store.active_document.to_dict()
            var elems: Array = scene_doc.get("elements", [])
            if not elems.is_empty():
                is_sim_compiled = true
                _send_command("compile_and_run", {
                    "action": "compile_and_run",
                    "scenespec": scene_doc,
                    "speed": authoring_shell.sim_speed
                })
                return
    _send_command("play", {"action": "play"})

func _on_pause() -> void:
    running = false
    if authoring_shell != null:
        authoring_shell.is_sim_running = false
    _send_command("pause", {"action": "pause"})

func _on_step(duration: float = 1.0, unit: String = "s") -> void:
    running = false
    if authoring_shell != null:
        authoring_shell.is_sim_running = false
    _send_command("step", {"action": "step", "duration": duration, "unit": unit})
    queue_redraw()

func _on_reset() -> void:
    running = false
    is_sim_compiled = false
    if authoring_shell != null:
        authoring_shell.is_sim_running = false
    simulation_time = 0.0
    if simulation_label != null:
        simulation_label.text = "t = 0.00 s"
    if authoring_shell != null:
        authoring_shell.update_sim_time(0.0)
    _send_command("reset", {"action": "reset"})
    queue_redraw()

func _on_speed_changed(value: float) -> void:
    if speed_label != null:
        speed_label.text = "%.2fx" % value
    if authoring_shell != null:
        authoring_shell.sim_speed = value
    _send_command("set_clock_speed", {"speed": value})

func _send_command(command_type: String, command: Dictionary) -> void:
    if connection_manager == null:
        return
    var message_id := "godot-command-%s-%d" % [command_type, Time.get_ticks_msec()]
    pending_commands[message_id] = command_type
    var message := {
        "envelope_version": "1.0",
        "message_id": message_id,
        "timestamp": Time.get_ticks_msec(),
        "sender": "godot_gui",
        "receiver": "julia_runtime",
        "kind": "command",
        "payload": {
            "command_version": "1.0.0",
            "command_type": command_type,
            "command": command,
            "scene_id": scene_name if scene_name != "waiting" else "phase7c_fixture",
            "apply_at_time": null
        }
    }
    var error_code: int = connection_manager.send_message(message)
    if error_code == OK:
        _last_command_status = command_type
        _update_status("command", command_type)
        if command_status_label != null:
            command_status_label.text = "CMD: %s" % command_type
        if command_detail_label != null:
            command_detail_label.text = "%s pending" % message_id
    else:
        pending_commands.erase(message_id)
        _update_status("protocol error", "send_failed")
        if command_status_label != null:
            command_status_label.text = "CMD ERR: %s" % error_code
        if command_detail_label != null:
            command_detail_label.text = "Send failed: %s" % error_code

func _update_selection_details(kind: String, id: String) -> void:
    if inspector_selection_label == null:
        return
    inspector_selection_label.text = id
    if inspector_value_label == null:
        return
    var state: Dictionary = {}
    if state_store != null and state_store.has_method("render_state"):
        state = state_store.render_state()
    var target: Dictionary = {}
    if kind == "entity":
        target = state.get("entities_by_id", {}).get(id, {})
        inspector_value_label.text = "Entity"
    elif kind == "element":
        target = state.get("elements_by_id", {}).get(id, {})
        inspector_value_label.text = "Element"
    else:
        inspector_value_label.text = "-"
    if target.is_empty():
        if command_detail_label != null:
            command_detail_label.text = "No details for %s" % id
        return
    var summary := "id=%s" % id
    if target.has("current_location"):
        summary += "\nlocation=%s" % str(target.get("current_location", "n/a"))
    if target.has("kind"):
        summary += "\nkind=%s" % str(target.get("kind", "n/a"))
    if target.has("properties"):
        var props: Dictionary = target.get("properties", {})
        if props is Dictionary and not props.is_empty():
            summary += "\nprops=%s" % str(props)
    if command_detail_label != null:
        command_detail_label.text = summary

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
