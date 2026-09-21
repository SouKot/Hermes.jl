# authoring_block_node.gd
# 3-part interactive entity block (Left Flow Bay, Center Body, Right Control Bay) for SceneSpec authoring.
class_name SimVizAuthoringBlockNode
extends Control

const SceneTypes := preload("res://scripts/scenespec_types.gd")

signal block_selected(element_id: String)
signal block_moved(element_id: String, new_pos: Vector2)
signal port_drag_started(element_id: String, port_id: String, port_kind: String, is_output: bool, global_pos: Vector2)
signal port_drag_ended(element_id: String, port_id: String)
signal add_port_requested(element_id: String, bay_action: String) # "flow_in", "flow_out", "signal_in", "metric_out"

const BG_NORMAL := Color("#121b27")
const BG_SELECTED := Color("#17263c")
const BORDER_NORMAL := Color("#26384b")
const BORDER_SELECTED := Color("#52c7a5")
const TEXT_COLOR := Color("#e5edf5")
const MUTED_COLOR := Color("#8da2b5")
const BAY_BG := Color("#0d141e")

const COLOR_FLOW := Color("#2ecc71")
const COLOR_METRIC := Color("#f39c12")
const COLOR_SIGNAL := Color("#e74c3c")
const COLOR_EVENT := Color("#9b59b6")

const LEFT_BAY_WIDTH := 64.0
const RIGHT_BAY_WIDTH := 64.0

var element: SceneTypes.SceneElement
var is_selected: bool = false
var hovered_port_id: String = ""
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO

var _port_sockets: Dictionary = {} # port_id -> { "pos": Vector2, "kind": String, "is_output": bool, "dir": String, "name": String }

func _init(p_elem: SceneTypes.SceneElement = null) -> void:
	element = p_elem
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(260, 96)

func _ready() -> void:
	_recalculate_size()
	calculate_sockets()
	queue_redraw()

func set_selected(val: bool) -> void:
	is_selected = val
	queue_redraw()

func set_hovered_port(p_id: String) -> void:
	if hovered_port_id != p_id:
		hovered_port_id = p_id
		queue_redraw()

func get_port_global_position(port_id: String) -> Vector2:
	if _port_sockets.is_empty():
		calculate_sockets()
	if _port_sockets.has(port_id):
		return global_position + _port_sockets[port_id]["pos"]
	return global_position + (size * 0.5)

func get_port_info(port_id: String) -> Dictionary:
	if _port_sockets.is_empty():
		calculate_sockets()
	return _port_sockets.get(port_id, {})

func calculate_sockets() -> void:
	_port_sockets.clear()
	var y_step := 22.0
	var y_start := 28.0

	# 1. Left Bay Column 1: Flow In (x = 16.0)
	var flow_in := _get_flow_in_ports()
	for i in range(flow_in.size()):
		var p = flow_in[i]
		var p_pos := Vector2(16.0, y_start + (i * y_step))
		_port_sockets[p.id] = {
			"pos": p_pos, "kind": p.kind, "is_output": false,
			"dir": "input", "name": p.name if not p.name.is_empty() else p.id
		}

	# 2. Left Bay Column 2: Flow Out (x = 46.0)
	var flow_out := _get_flow_out_ports()
	for i in range(flow_out.size()):
		var p = flow_out[i]
		var p_pos := Vector2(46.0, y_start + (i * y_step))
		_port_sockets[p.id] = {
			"pos": p_pos, "kind": p.kind, "is_output": true,
			"dir": "output", "name": p.name if not p.name.is_empty() else p.id
		}

	# 3. Right Bay Column 1: Signal In (x = size.x - 48.0)
	var sig_in := _get_signal_ports()
	for i in range(sig_in.size()):
		var p = sig_in[i]
		var p_pos := Vector2(size.x - 48.0, y_start + (i * y_step))
		_port_sockets[p.id] = {
			"pos": p_pos, "kind": p.kind, "is_output": false,
			"dir": "input", "name": p.name if not p.name.is_empty() else p.id
		}

	# 4. Right Bay Column 2: Metric Out (x = size.x - 16.0)
	var met_out := _get_metric_ports()
	for i in range(met_out.size()):
		var p = met_out[i]
		var p_pos := Vector2(size.x - 16.0, y_start + (i * y_step))
		_port_sockets[p.id] = {
			"pos": p_pos, "kind": p.kind, "is_output": true,
			"dir": "output", "name": p.name if not p.name.is_empty() else p.id
		}

func _recalculate_size() -> void:
	if element == null:
		size = custom_minimum_size
		return

	var dims := _get_physical_dimensions()
	var w: float = max(dims.x * 20.0 + LEFT_BAY_WIDTH + RIGHT_BAY_WIDTH, 260.0)
	var max_ports: int = max(
		max(_get_flow_in_ports().size(), _get_flow_out_ports().size()),
		max(_get_signal_ports().size(), _get_metric_ports().size())
	)
	var h: float = max(dims.y * 20.0, max(96.0, max_ports * 22.0 + 52.0))
	size = Vector2(w, h)

func _get_physical_dimensions() -> Vector3:
	if element != null and element.geometry.has("dimensions"):
		var d = element.geometry["dimensions"]
		if d is Array and d.size() >= 3:
			return Vector3(float(d[0]), float(d[1]), float(d[2]))
	return Vector3(4.0, 2.0, 1.0)

func _get_flow_in_ports() -> Array:
	var res: Array = []
	if element == null:
		return res
	for p in element.input_ports:
		if p.kind == "flow":
			res.append(p)
	return res

func _get_flow_out_ports() -> Array:
	var res: Array = []
	if element == null:
		return res
	for p in element.output_ports:
		if p.kind == "flow":
			res.append(p)
	return res

func _get_signal_ports() -> Array:
	var res: Array = []
	if element == null:
		return res
	for p in element.input_ports:
		if p.kind in ["signal", "control"]:
			res.append(p)
	return res

func _get_metric_ports() -> Array:
	var res: Array = []
	if element == null:
		return res
	for p in element.metric_ports:
		res.append(p)
	for p in element.output_ports:
		if p.kind in ["metric", "signal"]:
			res.append(p)
	return res

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# 1. Check if clicked on a port socket
				var hit_port := _hit_test_port(mb.position)
				if not hit_port.is_empty():
					var p_info: Dictionary = _port_sockets[hit_port]
					port_drag_started.emit(
						element.id, hit_port, p_info["kind"], p_info["is_output"],
						global_position + p_info["pos"]
					)
					accept_event()
					return

				# 2. Check if clicked on a [+] button
				var hit_add := _hit_test_add_button(mb.position)
				if not hit_add.is_empty():
					add_port_requested.emit(element.id, hit_add)
					accept_event()
					return

				# 3. Center body clicked -> drag block
				_dragging = true
				_drag_offset = mb.position
				block_selected.emit(element.id)
				accept_event()
			else:
				if _dragging:
					_dragging = false
					accept_event()

	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		position += mm.position - _drag_offset
		block_moved.emit(element.id, position)
		accept_event()

func _hit_test_port(local_pos: Vector2) -> String:
	for port_id in _port_sockets.keys():
		var spos: Vector2 = _port_sockets[port_id]["pos"]
		if local_pos.distance_to(spos) <= 14.0:
			return port_id
	return ""

func _hit_test_add_button(local_pos: Vector2) -> String:
	var btn_h := 16.0
	var btn_y := size.y - btn_h - 4.0

	# Left Bay (Flow In / Flow Out)
	if Rect2(4.0, btn_y, 26.0, btn_h).has_point(local_pos):
		return "flow_in"
	if Rect2(34.0, btn_y, 26.0, btn_h).has_point(local_pos):
		return "flow_out"

	# Right Bay (Signal In / Metric Out)
	if Rect2(size.x - 60.0, btn_y, 26.0, btn_h).has_point(local_pos):
		return "signal_in"
	if Rect2(size.x - 30.0, btn_y, 26.0, btn_h).has_point(local_pos):
		return "metric_out"

	return ""

func _get_tooltip(at_position: Vector2) -> String:
	var hit_port := _hit_test_port(at_position)
	if not hit_port.is_empty():
		var p_info: Dictionary = _port_sockets.get(hit_port, {})
		var dir_str: String = "Output" if p_info.get("is_output", false) else "Input"
		var kind_str: String = str(p_info.get("kind", "")).capitalize()
		var p_name: String = str(p_info.get("name", hit_port))
		if p_info.get("kind", "") == "flow":
			return "Flow %s: %s\nID: %s\n(Drag to connect to %s)" % [dir_str, p_name, hit_port, "Flow In" if p_info.get("is_output", false) else "Flow Out"]
		elif p_info.get("kind", "") == "metric":
			return "Metric Output: %s\nID: %s\n(Connect to Signal In)" % [p_name, hit_port]
		elif p_info.get("kind", "") == "signal":
			return "Signal Input: %s\nID: %s\n(Receives Metric Signal)" % [p_name, hit_port]
		return "%s %s: %s\nID: %s" % [kind_str, dir_str, p_name, hit_port]
	return ""

func _draw() -> void:
	calculate_sockets()
	var rect := Rect2(Vector2.ZERO, size)

	# 1. Main Block Background & Outer Border
	draw_rect(rect, BG_SELECTED if is_selected else BG_NORMAL, true)
	draw_rect(rect, BORDER_SELECTED if is_selected else BORDER_NORMAL, false, 2.0 if is_selected else 1.0)

	# 2. Left Bay (Flow Movement: 2 Columns - IN and OUT)
	var left_rect := Rect2(0, 0, LEFT_BAY_WIDTH, size.y)
	draw_rect(left_rect, BAY_BG, true)
	draw_line(Vector2(LEFT_BAY_WIDTH, 0), Vector2(LEFT_BAY_WIDTH, size.y), BORDER_NORMAL, 1.0)
	draw_line(Vector2(30.0, 0), Vector2(30.0, size.y), Color(0.12, 0.18, 0.25, 0.5), 1.0)

	# Left Bay Column Headers
	draw_string(ThemeDB.fallback_font, Vector2(10.0, 14.0), "IN", HORIZONTAL_ALIGNMENT_CENTER, -1, 9, Color("#2ecc71"))
	draw_string(ThemeDB.fallback_font, Vector2(38.0, 14.0), "OUT", HORIZONTAL_ALIGNMENT_CENTER, -1, 9, Color("#a8d5ba"))

	# 3. Right Bay (Control & Telemetry: 2 Columns - SIG and MET)
	var right_rect := Rect2(size.x - RIGHT_BAY_WIDTH, 0, RIGHT_BAY_WIDTH, size.y)
	draw_rect(right_rect, BAY_BG, true)
	draw_line(Vector2(size.x - RIGHT_BAY_WIDTH, 0), Vector2(size.x - RIGHT_BAY_WIDTH, size.y), BORDER_NORMAL, 1.0)
	draw_line(Vector2(size.x - 34.0, 0), Vector2(size.x - 34.0, size.y), Color(0.12, 0.18, 0.25, 0.5), 1.0)

	# Right Bay Column Headers
	draw_string(ThemeDB.fallback_font, Vector2(size.x - 56.0, 14.0), "SIG", HORIZONTAL_ALIGNMENT_CENTER, -1, 9, COLOR_SIGNAL)
	draw_string(ThemeDB.fallback_font, Vector2(size.x - 24.0, 14.0), "MET", HORIZONTAL_ALIGNMENT_CENTER, -1, 9, COLOR_METRIC)

	# 4. Center Body (Physical Footprint & Title)
	if element != null:
		var title: String = element.id
		var dims := _get_physical_dimensions()
		var dim_str := "%.1fm × %.1fm" % [dims.x, dims.y]
		var kind_str: String = element.kind.to_upper()

		draw_string(ThemeDB.fallback_font, Vector2(LEFT_BAY_WIDTH + 10.0, 24.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT_COLOR)
		draw_string(ThemeDB.fallback_font, Vector2(LEFT_BAY_WIDTH + 10.0, 42.0), kind_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, MUTED_COLOR)
		draw_string(ThemeDB.fallback_font, Vector2(LEFT_BAY_WIDTH + 10.0, 60.0), dim_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COLOR_FLOW)

		# Elevation indicator if elevated
		var z_start: float = float(element.geometry.get("elevation_start", 0.8))
		var z_end: float = float(element.geometry.get("elevation_end", z_start))
		if abs(z_start - z_end) > 0.05 or z_start > 0.85:
			var elev_str := "Z: %.1fm → %.1fm" % [z_start, z_end]
			draw_string(ThemeDB.fallback_font, Vector2(LEFT_BAY_WIDTH + 10.0, 78.0), elev_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color("#e67e22"))

	# 5. Draw Left and Right Port Sockets
	for port_id in _port_sockets.keys():
		var p_info: Dictionary = _port_sockets[port_id]
		var p_pos: Vector2 = p_info["pos"]
		var p_kind: String = p_info["kind"]
		var is_out: bool = p_info["is_output"]
		var is_hovered: bool = (port_id == hovered_port_id)

		var p_col := COLOR_FLOW if p_kind == "flow" else (COLOR_METRIC if p_kind == "metric" else COLOR_SIGNAL)
		var bg_col := Color("#13291d") if p_kind == "flow" else (Color("#2c2010") if p_kind == "metric" else Color("#2b1614"))

		# Glow halo if hovered during wire drag
		if is_hovered:
			draw_circle(p_pos, 11.0, Color(1.0, 1.0, 1.0, 0.25))
			draw_arc(p_pos, 11.0, 0, TAU, 20, Color.WHITE, 2.0)

		# Outer socket ring
		draw_circle(p_pos, 7.0, bg_col)
		draw_arc(p_pos, 7.0, 0, TAU, 16, p_col, 1.5)

		# Inner socket core (White for Output emitter, Solid color for Input target)
		draw_circle(p_pos, 3.5, Color.WHITE if is_out else p_col)

	# 6. Bottom Add Buttons
	var btn_h := 16.0
	var btn_y := size.y - btn_h - 4.0

	# Left Bay: [+ IN] button
	var btn_in_rect := Rect2(4.0, btn_y, 24.0, btn_h)
	draw_rect(btn_in_rect, Color("#172333"), true)
	draw_rect(btn_in_rect, BORDER_NORMAL, false, 1.0)
	draw_string(ThemeDB.fallback_font, Vector2(btn_in_rect.position.x + 8.0, btn_in_rect.position.y + 12.0), "+", HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color("#2ecc71"))

	# Left Bay: [+ OUT] button
	var btn_out_rect := Rect2(32.0, btn_y, 24.0, btn_h)
	draw_rect(btn_out_rect, Color("#172333"), true)
	draw_rect(btn_out_rect, BORDER_NORMAL, false, 1.0)
	draw_string(ThemeDB.fallback_font, Vector2(btn_out_rect.position.x + 8.0, btn_out_rect.position.y + 12.0), "+", HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color("#a8d5ba"))

	# Right Bay: [+ SIG] button
	var btn_sig_rect := Rect2(size.x - 60.0, btn_y, 24.0, btn_h)
	draw_rect(btn_sig_rect, Color("#172333"), true)
	draw_rect(btn_sig_rect, BORDER_NORMAL, false, 1.0)
	draw_string(ThemeDB.fallback_font, Vector2(btn_sig_rect.position.x + 8.0, btn_sig_rect.position.y + 12.0), "+", HORIZONTAL_ALIGNMENT_CENTER, -1, 12, COLOR_SIGNAL)

	# Right Bay: [+ MET] button
	var btn_met_rect := Rect2(size.x - 32.0, btn_y, 24.0, btn_h)
	draw_rect(btn_met_rect, Color("#172333"), true)
	draw_rect(btn_met_rect, BORDER_NORMAL, false, 1.0)
	draw_string(ThemeDB.fallback_font, Vector2(btn_met_rect.position.x + 8.0, btn_met_rect.position.y + 12.0), "+", HORIZONTAL_ALIGNMENT_CENTER, -1, 12, COLOR_METRIC)
