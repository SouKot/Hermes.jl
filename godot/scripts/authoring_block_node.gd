# authoring_block_node.gd
# 3-part interactive entity block (Left Flow Bay, Center Body, Right Control Bay) for SceneSpec authoring.
class_name SimVizAuthoringBlockNode
extends Control

const SceneTypes := preload("res://scripts/scenespec_types.gd")

signal block_selected(element_id: String)
signal block_moved(element_id: String, new_pos: Vector2)
signal port_selected(element_id: String, port_id: String)
signal port_drag_started(element_id: String, port_id: String, port_kind: String, is_output: bool, global_pos: Vector2)
signal port_drag_ended(element_id: String, port_id: String)
signal add_port_requested(element_id: String, bay_action: String) # "flow_in", "flow_out", "signal_in", "metric_out"
signal remove_port_requested(element_id: String, bay_action: String) # "flow_in", "flow_out", "signal_in", "metric_out"
signal disconnect_port_requested(element_id: String, port_id: String)
signal element_resized(element_id: String, new_dims: Vector3)
signal element_resize_committed(element_id: String, new_dims: Vector3)
signal floating_properties_requested(element_id: String, screen_pos: Vector2)
signal subgraph_drilldown_requested(subgraph_id: String)

const BG_NORMAL := Color("#121b27")
const BG_SELECTED := Color("#17263c")
const BORDER_NORMAL := Color("#26384b")
const BORDER_SELECTED := Color("#52c7a5")
const TEXT_COLOR := Color("#e5edf5")
const MUTED_COLOR := Color("#8da2b5")
const BAY_BG := Color("#0d141e")

const COLOR_FLOW := Color("#2ecc71")
const COLOR_METRIC := Color("#9b59b6")
const COLOR_SIGNAL := Color("#3498db")
const COLOR_CONTROL := Color("#e67e22")
const COLOR_EVENT := Color("#e74c3c")

static func get_port_kind_color(p_kind: String) -> Color:
	match p_kind:
		"flow": return COLOR_FLOW
		"metric": return COLOR_METRIC
		"signal": return COLOR_SIGNAL
		"control": return COLOR_CONTROL
		"event": return COLOR_EVENT
		_: return Color("#95a5a6")

const LEFT_BAY_WIDTH := 64.0
const RIGHT_BAY_WIDTH := 64.0

var element: SceneTypes.SceneElement
var subgraph: SceneTypes.SceneSubgraph
var is_selected: bool = false
var is_multi_selected: bool = false
var hovered_port_id: String = ""
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
enum ResizeCorner {
	NONE,
	TOP_LEFT,
	TOP_RIGHT,
	BOTTOM_RIGHT,
	BOTTOM_LEFT
}

var _resizing: bool = false
var _active_resize_corner: ResizeCorner = ResizeCorner.NONE
var _resize_start_mouse: Vector2 = Vector2.ZERO
var _resize_start_global_mouse: Vector2 = Vector2.ZERO
var _resize_start_dims: Vector3 = Vector3.ZERO
var _resize_start_node_pos: Vector2 = Vector2.ZERO
var _resize_start_elem_pos: Vector3 = Vector3.ZERO

var _port_sockets: Dictionary = {} # port_id -> { "pos": Vector2, "kind": String, "is_output": bool, "dir": String, "name": String }

func _init(p_elem: SceneTypes.SceneElement = null, p_sub: SceneTypes.SceneSubgraph = null) -> void:
	element = p_elem
	subgraph = p_sub
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(36, 36)
	if element != null or subgraph != null:
		refresh_from_element()

func _ready() -> void:
	refresh_from_element()

func get_node_id() -> String:
	if subgraph != null:
		return subgraph.id
	elif element != null:
		return element.id
	return ""

func refresh_from_element() -> void:
	if element != null and element.transform != null:
		rotation_degrees = float(element.transform.rotation.z)
		pivot_offset = Vector2(0, 0)
	elif subgraph != null and subgraph.transform != null:
		rotation_degrees = float(subgraph.transform.rotation.z)
		pivot_offset = Vector2(0, 0)
	_recalculate_size()
	calculate_sockets()
	queue_redraw()

func set_selected(val: bool, multi: bool = false) -> void:
	is_selected = val
	is_multi_selected = multi
	queue_redraw()

func set_hovered_port(p_id: String) -> void:
	if hovered_port_id != p_id:
		hovered_port_id = p_id
		queue_redraw()

func get_port_local_position(port_id: String) -> Vector2:
	if _port_sockets.is_empty():
		calculate_sockets()
	if _port_sockets.has(port_id):
		return _port_sockets[port_id]["pos"]
	return size * 0.5

func get_port_canvas_position(port_id: String) -> Vector2:
	var local_pos := get_port_local_position(port_id)
	if rotation != 0.0:
		return position + pivot_offset + (local_pos - pivot_offset).rotated(rotation)
	return position + local_pos

func get_port_global_position(port_id: String) -> Vector2:
	if is_inside_tree():
		var local_pos := get_port_local_position(port_id)
		if rotation != 0.0:
			return global_position + pivot_offset + (local_pos - pivot_offset).rotated(rotation)
		return global_position + local_pos
	return get_port_canvas_position(port_id)

func get_port_info(port_id: String) -> Dictionary:
	if _port_sockets.is_empty():
		calculate_sockets()
	return _port_sockets.get(port_id, {})

func get_bay_layout() -> Dictionary:
	var flow_in := _get_flow_in_ports()
	var flow_out := _get_flow_out_ports()
	var sig_in := _get_signal_ports()
	var met_out := _get_metric_ports()

	var has_flow_in := flow_in.size() > 0
	var has_flow_out := flow_out.size() > 0
	var has_sig_in := sig_in.size() > 0
	var has_met_out := met_out.size() > 0

	# When wide enough (size.x >= 128.0), provide full 2-column bays (64px each)
	# with canonical positions (IN at 16, OUT at 46, SIG at size.x-48, MET at size.x-16).
	if size.x >= 128.0:
		return {
			"left_w": 64.0,
			"right_w": 64.0,
			"col_in_x": 16.0,
			"col_out_x": 46.0,
			"col_sig_x": size.x - 48.0,
			"col_met_x": size.x - 16.0,
			"has_flow_in": true,
			"has_flow_out": true,
			"has_sig_in": true,
			"has_met_out": true,
			"collapsed": false
		}

	# When compact (size.x < 128.0), collapse empty columns and contract active columns
	var left_cols: int = (1 if has_flow_in else 0) + (1 if has_flow_out else 0)
	var right_cols: int = (1 if has_sig_in else 0) + (1 if has_met_out else 0)
	var total_cols: int = max(1, left_cols + right_cols)

	var cw: float = clamp(size.x / float(total_cols), 16.0, 32.0)
	var left_w: float = float(left_cols) * cw
	var right_w: float = float(right_cols) * cw

	var col_in_x: float = -999.0
	var col_out_x: float = -999.0
	if has_flow_in and has_flow_out:
		col_in_x = cw * 0.5
		col_out_x = cw + (cw * 0.5)
	elif has_flow_in:
		col_in_x = cw * 0.5
	elif has_flow_out:
		col_out_x = cw * 0.5

	var col_sig_x: float = -999.0
	var col_met_x: float = -999.0
	if has_sig_in and has_met_out:
		col_sig_x = size.x - (cw * 1.5)
		col_met_x = size.x - (cw * 0.5)
	elif has_sig_in:
		col_sig_x = size.x - (cw * 0.5)
	elif has_met_out:
		col_met_x = size.x - (cw * 0.5)

	return {
		"left_w": left_w,
		"right_w": right_w,
		"col_in_x": col_in_x,
		"col_out_x": col_out_x,
		"col_sig_x": col_sig_x,
		"col_met_x": col_met_x,
		"has_flow_in": has_flow_in,
		"has_flow_out": has_flow_out,
		"has_sig_in": has_sig_in,
		"has_met_out": has_met_out,
		"collapsed": true
	}

func rebuild_ports() -> void:
	calculate_sockets()
	queue_redraw()

func calculate_sockets() -> void:
	_port_sockets.clear()
	var layout := get_bay_layout()
	var flow_in := _get_flow_in_ports()
	var flow_out := _get_flow_out_ports()
	var sig_in := _get_signal_ports()
	var met_out := _get_metric_ports()

	var max_ports: int = max(
		max(flow_in.size(), flow_out.size()),
		max(sig_in.size(), met_out.size())
	)
	var y_step: float = 22.0
	var y_start: float = 28.0
	if size.y < 70.0:
		y_step = clamp((size.y - 20.0) / float(max(1, max_ports)), 14.0, 22.0)
		y_start = 12.0 + (y_step * 0.5)

	# 1. Left Bay Column 1: Flow In
	if layout["has_flow_in"] and layout["col_in_x"] > 0:
		for i in range(flow_in.size()):
			var p = flow_in[i]
			var p_pos := Vector2(layout["col_in_x"], y_start + (i * y_step))
			_port_sockets[p.id] = {
				"pos": p_pos, "kind": p.kind, "is_output": false,
				"dir": "input", "name": p.name if not p.name.is_empty() else p.id,
				"cardinality": p.cardinality
			}

	# 2. Left Bay Column 2: Flow Out
	if layout["has_flow_out"] and layout["col_out_x"] > 0:
		for i in range(flow_out.size()):
			var p = flow_out[i]
			var p_pos := Vector2(layout["col_out_x"], y_start + (i * y_step))
			_port_sockets[p.id] = {
				"pos": p_pos, "kind": p.kind, "is_output": true,
				"dir": "output", "name": p.name if not p.name.is_empty() else p.id,
				"cardinality": p.cardinality
			}

	# 3. Right Bay Column 1: Signal In
	if layout["has_sig_in"] and layout["col_sig_x"] > 0:
		for i in range(sig_in.size()):
			var p = sig_in[i]
			var p_pos := Vector2(layout["col_sig_x"], y_start + (i * y_step))
			_port_sockets[p.id] = {
				"pos": p_pos, "kind": p.kind, "is_output": false,
				"dir": "input", "name": p.name if not p.name.is_empty() else p.id,
				"cardinality": p.cardinality
			}

	# 4. Right Bay Column 2: Metric Out
	if layout["has_met_out"] and layout["col_met_x"] > 0:
		for i in range(met_out.size()):
			var p = met_out[i]
			var p_pos := Vector2(layout["col_met_x"], y_start + (i * y_step))
			_port_sockets[p.id] = {
				"pos": p_pos, "kind": p.kind, "is_output": true,
				"dir": "output", "name": p.name if not p.name.is_empty() else p.id,
				"cardinality": p.cardinality
			}

func _recalculate_size() -> void:
	if element == null and subgraph == null:
		size = custom_minimum_size
		return

	var dims := _get_physical_dimensions()
	var flow_in := _get_flow_in_ports()
	var flow_out := _get_flow_out_ports()
	var sig_in := _get_signal_ports()
	var met_out := _get_metric_ports()

	var left_cols: int = (1 if flow_in.size() > 0 else 0) + (1 if flow_out.size() > 0 else 0)
	var right_cols: int = (1 if sig_in.size() > 0 else 0) + (1 if met_out.size() > 0 else 0)
	var total_cols: int = left_cols + right_cols

	# Dynamic minimum width when middle gap is completely collapsed
	var min_w: float = max(36.0, float(total_cols) * 18.0)
	if total_cols >= 4:
		min_w = 72.0

	var max_ports: int = max(
		max(flow_in.size(), flow_out.size()),
		max(sig_in.size(), met_out.size())
	)
	var min_h: float = max(36.0, float(max_ports) * 18.0 + 18.0)
	if total_cols >= 4:
		min_h = max(min_h, 72.0)

	custom_minimum_size = Vector2(min_w, min_h)

	# Physical dimensions at 20px per meter (1m = 20px)
	var target_w: float = dims.x * 20.0
	var target_h: float = dims.y * 20.0

	size = Vector2(max(target_w, min_w), max(target_h, min_h))

func _get_physical_dimensions() -> Vector3:
	if element != null and element.geometry.has("dimensions"):
		var d = element.geometry["dimensions"]
		if d is Array and d.size() >= 3:
			return Vector3(float(d[0]), float(d[1]), float(d[2]))
	elif subgraph != null:
		if subgraph.editor != null and subgraph.editor.extensions.has("dimensions"):
			var d = subgraph.editor.extensions["dimensions"]
			if d is Array and d.size() >= 3:
				return Vector3(float(d[0]), float(d[1]), float(d[2]))
		if subgraph.transform != null and (subgraph.transform.scale.x > 0.1 or subgraph.transform.scale.y > 0.1):
			return Vector3(max(1.0, subgraph.transform.scale.x), max(1.0, subgraph.transform.scale.y), max(0.1, subgraph.transform.scale.z))
		return Vector3(8.0, 4.0, 2.0)
	return Vector3(4.0, 2.0, 1.0)

func _get_flow_in_ports() -> Array:
	var res: Array = []
	if element != null:
		for p in element.input_ports:
			if p.kind == "flow":
				res.append(p)
	elif subgraph != null:
		for ep in subgraph.exposed_ports:
			if ep.get("kind", "") == "flow" and ep.get("direction", "") == "input":
				var p := SceneTypes.ScenePort.new()
				p.id = str(ep.get("id", ep.get("port_id", "")))
				p.name = str(ep.get("name", p.id))
				p.kind = "flow"
				p.direction = "input"
				p.cardinality = str(ep.get("cardinality", "many"))
				res.append(p)
	return res

func _get_flow_out_ports() -> Array:
	var res: Array = []
	if element != null:
		for p in element.output_ports:
			if p.kind == "flow":
				res.append(p)
	elif subgraph != null:
		for ep in subgraph.exposed_ports:
			if ep.get("kind", "") == "flow" and ep.get("direction", "") == "output":
				var p := SceneTypes.ScenePort.new()
				p.id = str(ep.get("id", ep.get("port_id", "")))
				p.name = str(ep.get("name", p.id))
				p.kind = "flow"
				p.direction = "output"
				p.cardinality = str(ep.get("cardinality", "many"))
				res.append(p)
	return res

func _get_signal_ports() -> Array:
	var res: Array = []
	if element != null:
		for p in element.input_ports:
			if p.kind in ["signal", "control"]:
				res.append(p)
	elif subgraph != null:
		for ep in subgraph.exposed_ports:
			if ep.get("kind", "") in ["signal", "control"] and ep.get("direction", "") == "input":
				var p := SceneTypes.ScenePort.new()
				p.id = str(ep.get("id", ep.get("port_id", "")))
				p.name = str(ep.get("name", p.id))
				p.kind = ep.get("kind", "signal")
				p.direction = "input"
				p.cardinality = str(ep.get("cardinality", "many"))
				res.append(p)
	return res

func _get_metric_ports() -> Array:
	var res: Array = []
	if element != null:
		for p in element.metric_ports:
			res.append(p)
		for p in element.output_ports:
			if p.kind in ["metric", "signal"]:
				res.append(p)
	elif subgraph != null:
		for ep in subgraph.exposed_ports:
			if ep.get("kind", "") == "metric":
				var p := SceneTypes.ScenePort.new()
				p.id = str(ep.get("id", ep.get("port_id", "")))
				p.name = str(ep.get("name", p.id))
				p.kind = "metric"
				p.direction = "output"
				p.cardinality = str(ep.get("cardinality", "many"))
				res.append(p)
	return res

func _gui_input(event: InputEvent) -> void:
	var nid := get_node_id()
	if nid.is_empty():
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click and subgraph != null:
					subgraph_drilldown_requested.emit(nid)
					accept_event()
					return

				# 1. Check if clicked on a port socket
				var hit_port := _hit_test_port(mb.position)
				if not hit_port.is_empty():
					var p_info: Dictionary = _port_sockets[hit_port]
					port_selected.emit(nid, hit_port)
					port_drag_started.emit(
						nid, hit_port, p_info["kind"], p_info["is_output"],
						get_port_canvas_position(hit_port)
					)
					accept_event()
					return

				# 2. Check if clicked on a [+] or [-] button
				var hit_btn := _hit_test_port_button(mb.position)
				if not hit_btn.is_empty():
					if hit_btn["action"] == "add":
						add_port_requested.emit(nid, hit_btn["bay"])
					else:
						remove_port_requested.emit(nid, hit_btn["bay"])
					accept_event()
					return

				# 3. Check if clicked on any of the 4 resize corners
				var hit_corner := _hit_test_resize_corner(mb.position)
				if hit_corner != ResizeCorner.NONE:
					_resizing = true
					_active_resize_corner = hit_corner
					_resize_start_mouse = mb.position
					_resize_start_global_mouse = mb.global_position if mb.global_position != Vector2.ZERO else (position + mb.position)
					_resize_start_dims = _get_physical_dimensions()
					_resize_start_node_pos = position
					if element != null and element.transform != null:
						_resize_start_elem_pos = Vector3(float(element.transform.position[0]), float(element.transform.position[1]), float(element.transform.position[2]))
					elif subgraph != null and subgraph.transform != null:
						_resize_start_elem_pos = Vector3(float(subgraph.transform.position[0]), float(subgraph.transform.position[1]), float(subgraph.transform.position[2]))
					else:
						_resize_start_elem_pos = Vector3.ZERO
					if not is_selected:
						block_selected.emit(nid)
					accept_event()
					return

				# 4. Center body clicked -> drag block
				_dragging = true
				_drag_offset = mb.position
				block_selected.emit(nid)
				accept_event()
			else:
				if _resizing:
					_resizing = false
					_active_resize_corner = ResizeCorner.NONE
					element_resize_committed.emit(nid, _get_physical_dimensions())
					accept_event()
				elif _dragging:
					_dragging = false
					accept_event()

		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			# Right-click on a port socket -> Disconnect attached wire(s)
			var hit_port := _hit_test_port(mb.position)
			if not hit_port.is_empty():
				disconnect_port_requested.emit(nid, hit_port)
				accept_event()
				return
			else:
				# Right-click on block body -> Open Floating Tabbed Properties Inspector!
				block_selected.emit(nid)
				var mouse_pos: Vector2 = mb.global_position if mb.global_position != Vector2.ZERO else (get_global_mouse_position() if is_inside_tree() else mb.position)
				floating_properties_requested.emit(nid, mouse_pos)
				accept_event()
				return

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _resizing:
			var mouse_pos: Vector2 = mm.global_position if mm.global_position != Vector2.ZERO else (position + mm.position)
			var global_delta: Vector2 = mouse_pos - _resize_start_global_mouse
			var canvas_scale: float = max(scale.x, 0.01)

			var local_delta: Vector2 = (global_delta / canvas_scale).rotated(-rotation)
			var delta_len_m: float = local_delta.x / 20.0
			var delta_wid_m: float = local_delta.y / 20.0

			var min_l: float = custom_minimum_size.x / 20.0
			var min_w: float = custom_minimum_size.y / 20.0

			var new_len: float = _resize_start_dims.x
			var new_wid: float = _resize_start_dims.y
			var delta_origin_local := Vector2.ZERO

			match _active_resize_corner:
				ResizeCorner.BOTTOM_RIGHT:
					new_len = max(min_l, snapped(_resize_start_dims.x + delta_len_m, 0.1))
					new_wid = max(min_w, snapped(_resize_start_dims.y + delta_wid_m, 0.1))
					delta_origin_local = Vector2.ZERO

				ResizeCorner.BOTTOM_LEFT:
					new_len = max(min_l, snapped(_resize_start_dims.x - delta_len_m, 0.1))
					new_wid = max(min_w, snapped(_resize_start_dims.y + delta_wid_m, 0.1))
					var dl: float = new_len - _resize_start_dims.x
					delta_origin_local = Vector2(-dl, 0.0)

				ResizeCorner.TOP_RIGHT:
					new_len = max(min_l, snapped(_resize_start_dims.x + delta_len_m, 0.1))
					new_wid = max(min_w, snapped(_resize_start_dims.y - delta_wid_m, 0.1))
					var dw: float = new_wid - _resize_start_dims.y
					delta_origin_local = Vector2(0.0, -dw)

				ResizeCorner.TOP_LEFT:
					new_len = max(min_l, snapped(_resize_start_dims.x - delta_len_m, 0.1))
					new_wid = max(min_w, snapped(_resize_start_dims.y - delta_wid_m, 0.1))
					var dl: float = new_len - _resize_start_dims.x
					var dw: float = new_wid - _resize_start_dims.y
					delta_origin_local = Vector2(-dl, -dw)

			if element != null and element.geometry.has("dimensions"):
				element.geometry["dimensions"][0] = new_len
				element.geometry["dimensions"][1] = new_wid
				if delta_origin_local != Vector2.ZERO and element.transform != null:
					var dpos := delta_origin_local.rotated(rotation)
					element.transform.position.x = snapped(_resize_start_elem_pos.x + dpos.x, 0.05)
					element.transform.position.y = snapped(_resize_start_elem_pos.y + dpos.y, 0.05)
					element.editor.graph_position = Vector2(element.transform.position.x * 20.0, element.transform.position.y * 20.0)
			elif subgraph != null:
				if subgraph.transform != null:
					subgraph.transform.scale = Vector3(new_len, new_wid, _resize_start_dims.z)
					if delta_origin_local != Vector2.ZERO:
						var dpos := delta_origin_local.rotated(rotation)
						subgraph.transform.position.x = snapped(_resize_start_elem_pos.x + dpos.x, 0.05)
						subgraph.transform.position.y = snapped(_resize_start_elem_pos.y + dpos.y, 0.05)
						if subgraph.editor != null:
							subgraph.editor.graph_position = Vector2(subgraph.transform.position.x * 20.0, subgraph.transform.position.y * 20.0)
				if subgraph.editor != null:
					subgraph.editor.extensions["dimensions"] = [new_len, new_wid, _resize_start_dims.z]

			if delta_origin_local != Vector2.ZERO:
				var d_pos_px: Vector2 = (delta_origin_local * 20.0).rotated(rotation) * canvas_scale
				position = _resize_start_node_pos + d_pos_px

			refresh_from_element()
			element_resized.emit(nid, Vector3(new_len, new_wid, _resize_start_dims.z))
			accept_event()
		elif _dragging:
			position += mm.position - _drag_offset
			block_moved.emit(nid, position)
			accept_event()
		else:
			var corner := _hit_test_resize_corner(mm.position)
			if corner == ResizeCorner.TOP_LEFT or corner == ResizeCorner.BOTTOM_RIGHT:
				mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
			elif corner == ResizeCorner.TOP_RIGHT or corner == ResizeCorner.BOTTOM_LEFT:
				mouse_default_cursor_shape = Control.CURSOR_BDIAGSIZE
			elif not _hit_test_port(mm.position).is_empty():
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			else:
				mouse_default_cursor_shape = Control.CURSOR_ARROW

func _get_corner_size() -> float:
	return clamp(min(size.x, size.y) * 0.25, 10.0, 16.0)

func _hit_test_resize_corner(local_pos: Vector2) -> ResizeCorner:
	var c := _get_corner_size()
	if local_pos.x < 0.0 or local_pos.y < 0.0 or local_pos.x > size.x or local_pos.y > size.y:
		return ResizeCorner.NONE

	var in_left := local_pos.x <= c
	var in_right := local_pos.x >= (size.x - c)
	var in_top := local_pos.y <= c
	var in_bottom := local_pos.y >= (size.y - c)

	if in_left and in_top:
		return ResizeCorner.TOP_LEFT
	elif in_right and in_top:
		return ResizeCorner.TOP_RIGHT
	elif in_right and in_bottom:
		return ResizeCorner.BOTTOM_RIGHT
	elif in_left and in_bottom:
		return ResizeCorner.BOTTOM_LEFT
	return ResizeCorner.NONE

func _hit_test_resize_handle(local_pos: Vector2) -> bool:
	return _hit_test_resize_corner(local_pos) != ResizeCorner.NONE

func hit_test_port(local_pos: Vector2) -> String:
	return _hit_test_port(local_pos)

func _hit_test_port(local_pos: Vector2) -> String:
	var socket_r: float = 6.5 if size.y >= 70.0 else clamp(size.y * 0.12, 4.0, 6.0)
	var max_dist: float = socket_r + 2.5
	var best_id := ""
	var best_dist := max_dist
	for port_id in _port_sockets.keys():
		var spos: Vector2 = _port_sockets[port_id]["pos"]
		var d: float = local_pos.distance_to(spos)
		if d <= best_dist:
			best_dist = d
			best_id = port_id
	return best_id

func _hit_test_port_button(local_pos: Vector2) -> Dictionary:
	if element == null:
		return {}
	var layout := get_bay_layout()
	if layout["collapsed"] or size.y < 50.0:
		return {}

	var btn_h := 16.0
	var btn_y := size.y - btn_h - 4.0
	if local_pos.y < btn_y or local_pos.y > btn_y + btn_h:
		return {}

	# Left Bay Col 1: Flow In ([+] and [-])
	if Rect2(2.0, btn_y, 13.0, btn_h).has_point(local_pos):
		return {"action": "add", "bay": "flow_in"}
	if Rect2(16.0, btn_y, 13.0, btn_h).has_point(local_pos):
		return {"action": "remove", "bay": "flow_in"}

	# Left Bay Col 2: Flow Out ([+] and [-])
	if Rect2(32.0, btn_y, 13.0, btn_h).has_point(local_pos):
		return {"action": "add", "bay": "flow_out"}
	if Rect2(46.0, btn_y, 13.0, btn_h).has_point(local_pos):
		return {"action": "remove", "bay": "flow_out"}

	# Right Bay Col 1: Signal In ([+] and [-])
	if Rect2(size.x - 62.0, btn_y, 13.0, btn_h).has_point(local_pos):
		return {"action": "add", "bay": "signal_in"}
	if Rect2(size.x - 48.0, btn_y, 13.0, btn_h).has_point(local_pos):
		return {"action": "remove", "bay": "signal_in"}

	# Right Bay Col 2: Metric Out ([+] and [-])
	if Rect2(size.x - 30.0, btn_y, 13.0, btn_h).has_point(local_pos):
		return {"action": "add", "bay": "metric_out"}
	if Rect2(size.x - 16.0, btn_y, 13.0, btn_h).has_point(local_pos):
		return {"action": "remove", "bay": "metric_out"}

	return {}

func _hit_test_add_button(local_pos: Vector2) -> String:
	var hit := _hit_test_port_button(local_pos)
	if hit.get("action", "") == "add":
		return hit.get("bay", "")
	return ""

func _hit_test_remove_button(local_pos: Vector2) -> String:
	var hit := _hit_test_port_button(local_pos)
	if hit.get("action", "") == "remove":
		return hit.get("bay", "")
	return ""

func _get_tooltip(at_position: Vector2) -> String:
	var hit_btn := _hit_test_port_button(at_position)
	if not hit_btn.is_empty():
		var action_str := "Add" if hit_btn["action"] == "add" else "Remove last"
		var bay_str := str(hit_btn["bay"]).replace("_", " ").capitalize()
		return "%s %s port" % [action_str, bay_str]

	var hit_port := _hit_test_port(at_position)
	if not hit_port.is_empty():
		var p_info: Dictionary = _port_sockets.get(hit_port, {})
		var dir_str: String = "Output" if p_info.get("is_output", false) else "Input"
		var kind_str: String = str(p_info.get("kind", "")).capitalize()
		var p_name: String = str(p_info.get("name", hit_port))
		var base_tip := ""
		if p_info.get("kind", "") == "flow":
			base_tip = "Flow %s: %s\nID: %s\n(Drag to connect to %s)" % [dir_str, p_name, hit_port, "Flow In" if p_info.get("is_output", false) else "Flow Out"]
		elif p_info.get("kind", "") == "metric":
			base_tip = "Metric Output: %s\nID: %s\n(Connect to Signal In)" % [p_name, hit_port]
		elif p_info.get("kind", "") == "signal":
			base_tip = "Signal Input: %s\nID: %s\n(Receives Metric Signal)" % [p_name, hit_port]
		else:
			base_tip = "%s %s: %s\nID: %s" % [kind_str, dir_str, p_name, hit_port]
		return base_tip + "\n(Right-click to disconnect wires)"
	return ""

func _draw() -> void:
	calculate_sockets()
	var rect := Rect2(Vector2.ZERO, size)
	var layout := get_bay_layout()

	# 1. Main Block Background & Outer Border
	var is_highlighted := is_selected or is_multi_selected
	draw_rect(rect, BG_SELECTED if is_highlighted else BG_NORMAL, true)
	draw_rect(rect, BORDER_SELECTED if is_highlighted else BORDER_NORMAL, false, 2.0 if is_highlighted else 1.0)

	var left_w: float = float(layout["left_w"])
	var right_w: float = float(layout["right_w"])
	var mid_w: float = max(0.0, size.x - left_w - right_w)

	# 2. Left Bay
	if left_w > 0.0:
		var left_rect := Rect2(0, 0, left_w, size.y)
		draw_rect(left_rect, BAY_BG, true)
		draw_line(Vector2(left_w, 0), Vector2(left_w, size.y), BORDER_NORMAL, 1.0)
		if not layout["collapsed"] and left_w >= 60.0:
			draw_line(Vector2(30.0, 0), Vector2(30.0, size.y), Color(0.12, 0.18, 0.25, 0.5), 1.0)
			draw_string(ThemeDB.fallback_font, Vector2(10.0, 14.0), "IN", HORIZONTAL_ALIGNMENT_CENTER, -1, 9, Color("#2ecc71"))
			draw_string(ThemeDB.fallback_font, Vector2(38.0, 14.0), "OUT", HORIZONTAL_ALIGNMENT_CENTER, -1, 9, Color("#a8d5ba"))

	# 3. Right Bay
	if right_w > 0.0:
		var right_rect := Rect2(size.x - right_w, 0, right_w, size.y)
		draw_rect(right_rect, BAY_BG, true)
		draw_line(Vector2(size.x - right_w, 0), Vector2(size.x - right_w, size.y), BORDER_NORMAL, 1.0)
		if not layout["collapsed"] and right_w >= 60.0:
			draw_line(Vector2(size.x - 34.0, 0), Vector2(size.x - 34.0, size.y), Color(0.12, 0.18, 0.25, 0.5), 1.0)
			draw_string(ThemeDB.fallback_font, Vector2(size.x - 56.0, 14.0), "SIG", HORIZONTAL_ALIGNMENT_CENTER, -1, 9, COLOR_SIGNAL)
			draw_string(ThemeDB.fallback_font, Vector2(size.x - 24.0, 14.0), "MET", HORIZONTAL_ALIGNMENT_CENTER, -1, 9, COLOR_METRIC)

	# 4. Center Body (Adaptive Display)
	if element != null:
		var dims := _get_physical_dimensions()
		var dim_str := "%.1fm × %.1fm" % [dims.x, dims.y]
		var title: String = element.id
		var cur_rot: float = fposmod(float(element.transform.rotation.z), 360.0) if element.transform != null else 0.0

		if mid_w >= 70.0:
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 8.0, 24.0), title, HORIZONTAL_ALIGNMENT_LEFT, int(mid_w - 12.0), 12, TEXT_COLOR)
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 8.0, 40.0), element.kind.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, int(mid_w - 12.0), 9, MUTED_COLOR)
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 8.0, 56.0), dim_str, HORIZONTAL_ALIGNMENT_LEFT, int(mid_w - 12.0), 10, COLOR_FLOW)

			if cur_rot > 0.05:
				var rot_str := "∡ %.1f°" % cur_rot
				draw_string(ThemeDB.fallback_font, Vector2(left_w + mid_w - 52.0, 24.0), rot_str, HORIZONTAL_ALIGNMENT_RIGHT, 50, 9, Color("#f1c40f"))

			var z_start: float = float(element.geometry.get("elevation_start", 0.8))
			var z_end: float = float(element.geometry.get("elevation_end", z_start))
			if abs(z_start - z_end) > 0.05 or z_start > 0.85:
				var elev_str := "Z: %.1f→%.1f" % [z_start, z_end]
				draw_string(ThemeDB.fallback_font, Vector2(left_w + 8.0, 72.0), elev_str, HORIZONTAL_ALIGNMENT_LEFT, int(mid_w - 12.0), 8, Color("#e67e22"))
		elif mid_w >= 28.0:
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 4.0, 22.0), title, HORIZONTAL_ALIGNMENT_CENTER, int(mid_w - 8.0), 10, TEXT_COLOR)
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 4.0, 38.0), "%.1f×%.1f" % [dims.x, dims.y], HORIZONTAL_ALIGNMENT_CENTER, int(mid_w - 8.0), 8, COLOR_FLOW)
			if cur_rot > 0.05:
				draw_string(ThemeDB.fallback_font, Vector2(left_w + 4.0, 50.0), "∡%.0f°" % cur_rot, HORIZONTAL_ALIGNMENT_CENTER, int(mid_w - 8.0), 8, Color("#f1c40f"))
		else:
			# Fully collapsed center: Left and right bays touch with 0 gap.
			# Render compact top badge pill so machine ID is always clearly identifiable.
			var badge_rect := Rect2(2.0, 2.0, size.x - 4.0, 13.0)
			draw_rect(badge_rect, Color("#09111be0"), true)
			draw_rect(badge_rect, BORDER_NORMAL, false, 1.0)
			var badge_title := "%s %s" % [title, ("∡%.0f°" % cur_rot) if cur_rot > 0.05 else ""]
			draw_string(ThemeDB.fallback_font, Vector2(4.0, 12.0), badge_title.strip_edges(), HORIZONTAL_ALIGNMENT_CENTER, int(size.x - 8.0), 8, TEXT_COLOR)
	elif subgraph != null:
		var dims := _get_physical_dimensions()
		var title: String = subgraph.name if not subgraph.name.is_empty() else subgraph.id
		var role_str: String = "[%s]" % ("SUBSYSTEM" if subgraph.role in ["group", "compound"] else subgraph.role.to_upper())
		var sub_col := Color("#1abc9c") if subgraph.role == "compound" else Color("#9b59b6")

		# Draw subtle inner outline for subsystem
		var inset_rect := rect.grow(-3.0)
		draw_rect(inset_rect, Color(sub_col.r, sub_col.g, sub_col.b, 0.08), true)
		draw_rect(inset_rect, sub_col, false, 1.2)

		if mid_w >= 70.0:
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 8.0, 22.0), title, HORIZONTAL_ALIGNMENT_LEFT, int(mid_w - 12.0), 12, TEXT_COLOR)
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 8.0, 36.0), role_str, HORIZONTAL_ALIGNMENT_LEFT, int(mid_w - 12.0), 9, sub_col)
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 8.0, 50.0), "%.1fm × %.1fm" % [dims.x, dims.y], HORIZONTAL_ALIGNMENT_LEFT, int(mid_w - 12.0), 9, COLOR_FLOW)

			# Internal members manifest preview card
			var card_y := 58.0
			var avail_h := size.y - card_y - 20.0
			if avail_h >= 24.0:
				var card_rect := Rect2(left_w + 6.0, card_y, mid_w - 12.0, avail_h)
				draw_rect(card_rect, Color(0.06, 0.1, 0.16, 0.75), true)
				draw_rect(card_rect, Color(sub_col.r, sub_col.g, sub_col.b, 0.35), false, 1.0)

				var n_elems: int = subgraph.elements.size()
				var n_conns: int = subgraph.connections.size()
				var header_text := "INSIDE: %d ENTIT%s" % [n_elems, "IES" if n_elems != 1 else "Y"]
				if n_conns > 0:
					header_text += " · %d WIRE%s" % [n_conns, "S" if n_conns != 1 else ""]
				draw_string(ThemeDB.fallback_font, Vector2(card_rect.position.x + 6.0, card_rect.position.y + 13.0), header_text, HORIZONTAL_ALIGNMENT_LEFT, int(card_rect.size.x - 12.0), 8, Color("#a8d5ba"))

				var line_y := card_rect.position.y + 26.0
				var max_lines: int = int((avail_h - 18.0) / 13.0)
				var shown := 0
				for eid in subgraph.elements:
					if shown >= max_lines:
						var remaining := n_elems - shown
						draw_string(ThemeDB.fallback_font, Vector2(card_rect.position.x + 8.0, line_y), "+ %d more..." % remaining, HORIZONTAL_ALIGNMENT_LEFT, int(card_rect.size.x - 16.0), 8, MUTED_COLOR)
						break
					draw_string(ThemeDB.fallback_font, Vector2(card_rect.position.x + 8.0, line_y), "• %s" % str(eid), HORIZONTAL_ALIGNMENT_LEFT, int(card_rect.size.x - 16.0), 8, TEXT_COLOR)
					line_y += 13.0
					shown += 1

			draw_string(ThemeDB.fallback_font, Vector2(left_w + 8.0, size.y - 6.0), "⤢ Double-click to open", HORIZONTAL_ALIGNMENT_LEFT, int(mid_w - 12.0), 8, Color("#3498db"))
		elif mid_w >= 28.0:
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 4.0, 20.0), title, HORIZONTAL_ALIGNMENT_CENTER, int(mid_w - 8.0), 10, TEXT_COLOR)
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 4.0, 34.0), role_str, HORIZONTAL_ALIGNMENT_CENTER, int(mid_w - 8.0), 8, sub_col)
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 4.0, 48.0), "%.1f×%.1f" % [dims.x, dims.y], HORIZONTAL_ALIGNMENT_CENTER, int(mid_w - 8.0), 8, COLOR_FLOW)
			var n_elems: int = subgraph.elements.size()
			draw_string(ThemeDB.fallback_font, Vector2(left_w + 4.0, 62.0), "%d items" % n_elems, HORIZONTAL_ALIGNMENT_CENTER, int(mid_w - 8.0), 8, MUTED_COLOR)
		else:
			var badge_rect := Rect2(2.0, 2.0, size.x - 4.0, 13.0)
			draw_rect(badge_rect, Color("#09111be0"), true)
			draw_rect(badge_rect, sub_col, false, 1.0)
			var badge_title := "%s [%d]" % [title, subgraph.elements.size()]
			draw_string(ThemeDB.fallback_font, Vector2(4.0, 12.0), badge_title.strip_edges(), HORIZONTAL_ALIGNMENT_CENTER, int(size.x - 8.0), 8, TEXT_COLOR)

	# 5. Draw Left and Right Port Sockets
	var socket_r: float = 6.5 if size.y >= 70.0 else clamp(size.y * 0.12, 4.0, 6.0)
	for port_id in _port_sockets.keys():
		var p_info: Dictionary = _port_sockets[port_id]
		var p_pos: Vector2 = p_info["pos"]
		var p_kind: String = p_info["kind"]
		var is_out: bool = p_info["is_output"]
		var is_hovered: bool = (port_id == hovered_port_id)

		var p_col: Color = get_port_kind_color(p_kind)
		var bg_col := Color(p_col.r * 0.18, p_col.g * 0.18, p_col.b * 0.18, 0.95)
		var is_many: bool = (str(p_info.get("cardinality", "one")) == "many")

		if is_hovered:
			draw_circle(p_pos, socket_r + 4.0, Color(1.0, 1.0, 1.0, 0.25))
			draw_arc(p_pos, socket_r + 4.0, 0, TAU, 16, Color.WHITE, 1.5)

		draw_circle(p_pos, socket_r, bg_col)
		draw_arc(p_pos, socket_r, 0, TAU, 14, p_col, 1.2)
		if is_many:
			var sq_r := socket_r * 0.45
			draw_rect(Rect2(p_pos.x - sq_r, p_pos.y - sq_r, sq_r * 2.0, sq_r * 2.0), Color.WHITE if is_out else p_col, true)
		else:
			draw_circle(p_pos, socket_r * 0.5, Color.WHITE if is_out else p_col)

	# 6. Bottom Port Buttons ([+] and [-]) when spacious
	if element != null and not layout["collapsed"] and size.y >= 50.0:
		var btn_h := 16.0
		var btn_y := size.y - btn_h - 4.0
		var col_btn_sub := Color("#e74c3c")

		_draw_port_btn_pair(Rect2(2.0, btn_y, 13.0, btn_h), Rect2(16.0, btn_y, 13.0, btn_h), Color("#2ecc71"), col_btn_sub)
		_draw_port_btn_pair(Rect2(32.0, btn_y, 13.0, btn_h), Rect2(46.0, btn_y, 13.0, btn_h), Color("#a8d5ba"), col_btn_sub)
		_draw_port_btn_pair(Rect2(size.x - 62.0, btn_y, 13.0, btn_h), Rect2(size.x - 48.0, btn_y, 13.0, btn_h), COLOR_SIGNAL, col_btn_sub)
		_draw_port_btn_pair(Rect2(size.x - 30.0, btn_y, 13.0, btn_h), Rect2(size.x - 16.0, btn_y, 13.0, btn_h), COLOR_METRIC, col_btn_sub)


func _draw_port_btn_pair(r_add: Rect2, r_sub: Rect2, add_col: Color, sub_col: Color) -> void:
	# Add button [+]
	draw_rect(r_add, Color("#172333"), true)
	draw_rect(r_add, BORDER_NORMAL, false, 1.0)
	draw_string(ThemeDB.fallback_font, Vector2(r_add.position.x + 3.0, r_add.position.y + 12.0), "+", HORIZONTAL_ALIGNMENT_CENTER, -1, 11, add_col)

	# Remove button [-]
	draw_rect(r_sub, Color("#172333"), true)
	draw_rect(r_sub, BORDER_NORMAL, false, 1.0)
	draw_string(ThemeDB.fallback_font, Vector2(r_sub.position.x + 3.0, r_sub.position.y + 11.0), "−", HORIZONTAL_ALIGNMENT_CENTER, -1, 11, sub_col)
