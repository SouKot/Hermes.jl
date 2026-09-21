# authoring_block_node.gd
# 3-part interactive entity block (Left Flow Bay, Center Body, Right Control Bay) for SceneSpec authoring.
class_name SimVizAuthoringBlockNode
extends Control

const SceneTypes := preload("res://scripts/scenespec_types.gd")

signal block_selected(element_id: String)
signal block_moved(element_id: String, new_pos: Vector2)
signal port_drag_started(element_id: String, port_id: String, port_kind: String, is_output: bool, global_pos: Vector2)
signal port_drag_ended(element_id: String, port_id: String)
signal add_port_requested(element_id: String, bay_type: String) # "flow" or "control"

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

var element: SceneTypes.SceneElement
var is_selected: bool = false
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO

var _port_sockets: Dictionary = {} # port_id -> { "pos": Vector2, "kind": String, "is_output": bool, "dir": String }

func _init(p_elem: SceneTypes.SceneElement = null) -> void:
	element = p_elem
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(220, 84)

func _ready() -> void:
	_recalculate_size()
	calculate_sockets()
	queue_redraw()

func set_selected(val: bool) -> void:
	is_selected = val
	queue_redraw()

func get_port_global_position(port_id: String) -> Vector2:
	if _port_sockets.is_empty():
		calculate_sockets()
	if _port_sockets.has(port_id):
		return global_position + _port_sockets[port_id]["pos"]
	return global_position + (size * 0.5)

func calculate_sockets() -> void:
	_port_sockets.clear()
	var left_bay_w := 38.0
	var right_bay_w := 38.0
	var y_step := 20.0
	var y_start := 18.0

	var flow_ports := _get_flow_ports()
	for i in range(flow_ports.size()):
		var p = flow_ports[i]
		var p_pos := Vector2(left_bay_w * 0.5, y_start + (i * y_step))
		var is_out: bool = (p.direction == "output")
		_port_sockets[p.id] = { "pos": p_pos, "kind": p.kind, "is_output": is_out, "dir": p.direction }

	var ctrl_ports := _get_control_ports()
	for i in range(ctrl_ports.size()):
		var p = ctrl_ports[i]
		var p_pos := Vector2(size.x - (right_bay_w * 0.5), y_start + (i * y_step))
		var is_out: bool = (p.direction == "output")
		_port_sockets[p.id] = { "pos": p_pos, "kind": p.kind, "is_output": is_out, "dir": p.direction }

func _recalculate_size() -> void:
	if element == null:
		size = custom_minimum_size
		return

	var dims := _get_physical_dimensions()
	# Map real meters to canvas display size, clamped to minimum readable bounds
	var w: float = max(dims.x * 20.0 + 80.0, 220.0) # 80px extra for left+right port bays
	var max_ports: int = max(
		_get_flow_ports().size(),
		_get_control_ports().size()
	)
	var h: float = max(dims.y * 20.0, max(84.0, max_ports * 22.0 + 36.0))
	size = Vector2(w, h)

func _get_physical_dimensions() -> Vector3:
	if element != null and element.geometry.has("dimensions"):
		var d = element.geometry["dimensions"]
		if d is Array and d.size() >= 3:
			return Vector3(float(d[0]), float(d[1]), float(d[2]))
	return Vector3(4.0, 2.0, 1.0)

func _get_flow_ports() -> Array:
	var res: Array = []
	if element == null:
		return res
	for p in element.input_ports:
		if p.kind == "flow":
			res.append(p)
	for p in element.output_ports:
		if p.kind == "flow":
			res.append(p)
	return res

func _get_control_ports() -> Array:
	var res: Array = []
	if element == null:
		return res
	# Metric outputs
	for p in element.metric_ports:
		res.append(p)
	# Signal/control inputs & outputs
	for p in element.input_ports:
		if p.kind in ["signal", "control"]:
			res.append(p)
	for p in element.output_ports:
		if p.kind in ["signal", "control", "event"]:
			res.append(p)
	return res

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# Check if clicked on a port socket
				var hit_port := _hit_test_port(mb.position)
				if not hit_port.is_empty():
					var p_info: Dictionary = _port_sockets[hit_port]
					port_drag_started.emit(
						element.id, hit_port, p_info["kind"], p_info["is_output"],
						global_position + p_info["pos"]
					)
					accept_event()
					return

				# Check if clicked on a [+] button
				var hit_add := _hit_test_add_button(mb.position)
				if not hit_add.is_empty():
					add_port_requested.emit(element.id, hit_add)
					accept_event()
					return

				# Center body clicked -> drag block
				_dragging = true
				_drag_offset = mb.position
				block_selected.emit(element.id)
				accept_event()
			else:
				if _dragging:
					_dragging = false
					accept_event()
				var hit_port_end := _hit_test_port(mb.position)
				if not hit_port_end.is_empty():
					port_drag_ended.emit(element.id, hit_port_end)
					accept_event()

	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		position += mm.position - _drag_offset
		block_moved.emit(element.id, position)
		accept_event()

func _hit_test_port(local_pos: Vector2) -> String:
	for port_id in _port_sockets.keys():
		var spos: Vector2 = _port_sockets[port_id]["pos"]
		if local_pos.distance_to(spos) <= 12.0:
			return port_id
	return ""

func _hit_test_add_button(local_pos: Vector2) -> String:
	var left_bay_w := 38.0
	var right_bay_w := 38.0
	var btn_h := 18.0
	var btn_y := size.y - btn_h - 4.0

	# Left [+] button (Flow)
	if Rect2(4.0, btn_y, left_bay_w - 8.0, btn_h).has_point(local_pos):
		return "flow"
	# Right [+] button (Control)
	if Rect2(size.x - right_bay_w + 4.0, btn_y, right_bay_w - 8.0, btn_h).has_point(local_pos):
		return "control"
	return ""

func _draw() -> void:
	calculate_sockets()
	var rect := Rect2(Vector2.ZERO, size)
	var left_bay_w := 38.0
	var right_bay_w := 38.0

	# 1. Main Block Background & Outer Border
	draw_rect(rect, BG_SELECTED if is_selected else BG_NORMAL, true)
	draw_rect(rect, BORDER_SELECTED if is_selected else BORDER_NORMAL, false, 2.0 if is_selected else 1.0)

	# 2. Left Bay (Flow Movement)
	var left_rect := Rect2(0, 0, left_bay_w, size.y)
	draw_rect(left_rect, BAY_BG, true)
	draw_line(Vector2(left_bay_w, 0), Vector2(left_bay_w, size.y), BORDER_NORMAL, 1.0)

	# 3. Right Bay (Control & Telemetry)
	var right_rect := Rect2(size.x - right_bay_w, 0, right_bay_w, size.y)
	draw_rect(right_rect, BAY_BG, true)
	draw_line(Vector2(size.x - right_bay_w, 0), Vector2(size.x - right_bay_w, size.y), BORDER_NORMAL, 1.0)

	# 4. Center Body (Physical Footprint & Title)
	if element != null:
		var title: String = element.id
		var dims := _get_physical_dimensions()
		var dim_str := "%.1fm × %.1fm" % [dims.x, dims.y]
		var kind_str: String = element.kind.to_upper()

		draw_string(ThemeDB.fallback_font, Vector2(left_bay_w + 10.0, 22.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT_COLOR)
		draw_string(ThemeDB.fallback_font, Vector2(left_bay_w + 10.0, 38.0), kind_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, MUTED_COLOR)
		draw_string(ThemeDB.fallback_font, Vector2(left_bay_w + 10.0, 54.0), dim_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COLOR_FLOW)

		# Elevation indicator if elevated
		var z_start: float = float(element.geometry.get("elevation_start", 0.8))
		var z_end: float = float(element.geometry.get("elevation_end", z_start))
		if abs(z_start - z_end) > 0.05 or z_start > 0.85:
			var elev_str := "Z: %.1fm → %.1fm" % [z_start, z_end]
			draw_string(ThemeDB.fallback_font, Vector2(left_bay_w + 10.0, 70.0), elev_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color("#e67e22"))

	# 5. Draw Left and Right Port Sockets
	for port_id in _port_sockets.keys():
		var p_info: Dictionary = _port_sockets[port_id]
		var p_pos: Vector2 = p_info["pos"]
		var p_kind: String = p_info["kind"]
		var is_out: bool = p_info["is_output"]

		var p_col := COLOR_FLOW if p_kind == "flow" else (COLOR_METRIC if p_kind == "metric" else (COLOR_SIGNAL if p_kind == "signal" else COLOR_EVENT))
		draw_circle(p_pos, 6.0, p_col)
		draw_circle(p_pos, 4.0, Color.WHITE if is_out else Color.BLACK)
		draw_arc(p_pos, 6.0, 0, TAU, 16, BORDER_NORMAL, 1.0)

	# Left Bay [+] Add Flow Button
	var btn_h := 16.0
	var left_add_rect := Rect2(4.0, size.y - btn_h - 4.0, left_bay_w - 8.0, btn_h)
	draw_rect(left_add_rect, Color("#172333"), true)
	draw_rect(left_add_rect, BORDER_NORMAL, false, 1.0)
	draw_string(ThemeDB.fallback_font, Vector2(left_add_rect.position.x + 8.0, left_add_rect.position.y + 12.0), "+", HORIZONTAL_ALIGNMENT_CENTER, -1, 13, COLOR_FLOW)

	# Right Bay [+] Add Control Button
	var right_add_rect := Rect2(size.x - right_bay_w + 4.0, size.y - btn_h - 4.0, right_bay_w - 8.0, btn_h)
	draw_rect(right_add_rect, Color("#172333"), true)
	draw_rect(right_add_rect, BORDER_NORMAL, false, 1.0)
	draw_string(ThemeDB.fallback_font, Vector2(right_add_rect.position.x + 8.0, right_add_rect.position.y + 12.0), "+", HORIZONTAL_ALIGNMENT_CENTER, -1, 13, COLOR_METRIC)
