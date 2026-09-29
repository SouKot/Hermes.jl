# authoring_block_node.gd
# Perimeter-edge interactive entity block for SceneSpec 2D authoring (Phase 7G).
# - Zero internal side-bay columns (left_w = 0, right_w = 0): 100% of block area is physical footprint.
# - Flow In on Left edge (x = 0), Flow Out on Right edge (x = size.x),
#   Signal/Control In on Top edge (y = 0), Metric Out on Bottom edge (y = size.y).
# - Straight conveyors render directly as a physical roller belt inside Rect2(0, 0, size.x, size.y)
#   with ports on their ends/rails and an inline spine label (never a separate block).
# - Curved conveyors render a compact Midpoint Spine Pill directly on the curve midpoint for
#   top/bottom Signal/Metric ports while Flow In/Out sit at the physical curve endpoints.
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
signal port_channel_popup_requested(element_id: String, port_id: String, is_output: bool, screen_pos: Vector2)
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

static func get_element_kind_accent(e_kind: String) -> Color:
	match e_kind:
		"source": return Color("#f39c12")
		"queue": return Color("#3498db")
		"server": return Color("#2ecc71")
		"conveyor": return Color("#2a9d8f")
		"sink": return Color("#e74c3c")
		_: return Color("#52c7a5")

const LEFT_BAY_WIDTH := 0.0
const RIGHT_BAY_WIDTH := 0.0
const PORT_HIT_MARGIN := 10.0

var element: SceneTypes.SceneElement
var subgraph: SceneTypes.SceneSubgraph
var is_selected: bool = false
var is_multi_selected: bool = false
var is_block_hovered: bool = false
var is_wire_drag_active: bool = false
var wires_visible_mode: int = 0 # 0=ALL, 1=FOCUS, 2=OFF
var port_connection_counts: Dictionary = {} # port_id -> int
var live_metrics: Dictionary = {}
var signal_values: Dictionary = {}
var signal_history: Array = []
const MAX_SPARKLINE_POINTS: int = 40
var hovered_port_id: String = ""
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _drag_start_node_pos: Vector2 = Vector2.ZERO
var _drag_start_canvas_mouse: Vector2 = Vector2.ZERO
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

var _port_sockets: Dictionary = {} # port_id -> { "pos": Vector2, "kind": String, "is_output": bool, "dir": String, "name": String, "edge": String }

func _init(p_elem: SceneTypes.SceneElement = null, p_sub: SceneTypes.SceneSubgraph = null) -> void:
	element = p_elem
	subgraph = p_sub
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(36, 24)
	mouse_entered.connect(func():
		is_block_hovered = true
		queue_redraw()
	)
	mouse_exited.connect(func():
		is_block_hovered = false
		if not hovered_port_id.is_empty():
			hovered_port_id = ""
		queue_redraw()
	)
	if element != null or subgraph != null:
		refresh_from_element()

func _ready() -> void:
	refresh_from_element()

func _has_point(point: Vector2) -> bool:
	return Rect2(-PORT_HIT_MARGIN, -PORT_HIT_MARGIN, size.x + PORT_HIT_MARGIN * 2.0, size.y + PORT_HIT_MARGIN * 2.0).has_point(point)

func get_node_id() -> String:
	if subgraph != null:
		return subgraph.id
	elif element != null:
		return element.id
	return ""

func _is_curved_or_joined_conveyor() -> bool:
	if element == null or element.kind != "conveyor":
		return false
	if element.geometry.has("inlet_pose") or element.geometry.has("outlet_pose"):
		return true
	var preset: String = str(element.geometry.get("shape_preset", "straight")).to_lower()
	return preset != "straight" and not preset.is_empty()

func uses_floating_nameplate() -> bool:
	if element != null and element.kind == "conveyor":
		return true
	if element != null and element.kind in ["chart_station", "scope_2d", "digital_meter", "histogram_sink", "state_space_3d", "xy_scatter"]:
		return false
	return size.x < 68.0

func should_show_port_socket(port_id: String) -> bool:
	if is_selected or is_multi_selected or is_block_hovered or is_wire_drag_active or hovered_port_id == port_id:
		return true
	var conn_count: int = int(port_connection_counts.get(port_id, 0))
	if conn_count > 0 and wires_visible_mode == 0:
		return true
	return false

func set_port_connection_counts(counts: Dictionary) -> void:
	port_connection_counts = counts.duplicate()
	queue_redraw()

func set_wire_context(drag_active: bool, vis_mode: int) -> void:
	if is_wire_drag_active != drag_active or wires_visible_mode != vis_mode:
		is_wire_drag_active = drag_active
		wires_visible_mode = vis_mode
		queue_redraw()

func refresh_from_element() -> void:
	if element != null and element.transform != null:
		rotation_degrees = 0.0 if _is_curved_or_joined_conveyor() else float(element.transform.rotation.z)
		pivot_offset = Vector2(0, 0)
	elif subgraph != null and subgraph.transform != null:
		rotation_degrees = float(subgraph.transform.rotation.z)
		pivot_offset = Vector2(0, 0)
	_recalculate_size()
	calculate_sockets()
	queue_redraw()

func set_live_metrics(p_metrics: Dictionary) -> void:
	live_metrics = p_metrics
	queue_redraw()

func feed_signal_value(port_id: String, val: float, _t: float = 0.0) -> void:
	signal_values[port_id] = val
	signal_history.append(val)
	if signal_history.size() > MAX_SPARKLINE_POINTS:
		signal_history.pop_front()
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
	return get_transform() * local_pos

func get_port_global_position(port_id: String) -> Vector2:
	var local_pos := get_port_local_position(port_id)
	if is_inside_tree():
		return get_global_transform() * local_pos
	return get_port_canvas_position(port_id)

func _event_canvas_mouse_pos(ev_pos: Vector2, ev_global_pos: Vector2) -> Vector2:
	if ev_global_pos != Vector2.ZERO:
		var p := get_parent()
		if p is CanvasItem and (p as CanvasItem).is_inside_tree():
			return (p as CanvasItem).get_global_transform().affine_inverse() * ev_global_pos
		return ev_global_pos
	return get_transform() * ev_pos

func get_port_info(port_id: String) -> Dictionary:
	if _port_sockets.is_empty():
		calculate_sockets()
	return _port_sockets.get(port_id, {})

func get_bay_layout() -> Dictionary:
	var flow_in := _get_flow_in_ports()
	var flow_out := _get_flow_out_ports()
	var sig_in := _get_signal_ports()
	var met_out := _get_metric_ports()

	return {
		"left_w": 0.0,
		"right_w": 0.0,
		"col_in_x": 0.0,
		"col_out_x": size.x,
		"col_sig_x": size.x * 0.5,
		"col_met_x": size.x * 0.5,
		"has_flow_in": flow_in.size() > 0,
		"has_flow_out": flow_out.size() > 0,
		"has_sig_in": sig_in.size() > 0,
		"has_met_out": met_out.size() > 0,
		"collapsed": false
	}

func rebuild_ports() -> void:
	_recalculate_size()
	calculate_sockets()
	queue_redraw()

func calculate_sockets() -> void:
	_port_sockets.clear()
	var flow_in := _get_flow_in_ports()
	var flow_out := _get_flow_out_ports()
	var sig_in := _get_signal_ports()
	var met_out := _get_metric_ports()

	var is_curved_conv := _is_curved_or_joined_conveyor()
	var is_instrument: bool = (element != null and element.kind in ["chart_station", "scope_2d", "digital_meter", "histogram_sink", "state_space_3d", "xy_scatter"])

	# 1. Left Perimeter Edge (x = 0): Flow In (or Signal In for dedicated instrument panels)
	if is_instrument:
		var n_sig := sig_in.size()
		for i in range(n_sig):
			var p = sig_in[i]
			var py: float = size.y * float(i + 1) / float(n_sig + 1)
			_port_sockets[p.id] = {
				"pos": Vector2(0.0, py), "kind": p.kind, "is_output": false,
				"dir": "input", "name": p.name if not p.name.is_empty() else p.id,
				"cardinality": p.cardinality, "edge": "left"
			}
		return

	if not is_curved_conv:
		var n_in := flow_in.size()
		for i in range(n_in):
			var p = flow_in[i]
			var py: float = size.y * float(i + 1) / float(n_in + 1)
			_port_sockets[p.id] = {
				"pos": Vector2(0.0, py), "kind": p.kind, "is_output": false,
				"dir": "input", "name": p.name if not p.name.is_empty() else p.id,
				"cardinality": p.cardinality, "edge": "left"
			}

		# 2. Right Perimeter Edge (x = size.x): Flow Out
		var n_out := flow_out.size()
		for i in range(n_out):
			var p = flow_out[i]
			var py: float = size.y * float(i + 1) / float(n_out + 1)
			_port_sockets[p.id] = {
				"pos": Vector2(size.x, py), "kind": p.kind, "is_output": true,
				"dir": "output", "name": p.name if not p.name.is_empty() else p.id,
				"cardinality": p.cardinality, "edge": "right"
			}

	# 3. Top Perimeter Edge (y = 0): Signal / Control In
	var n_sig := sig_in.size()
	for i in range(n_sig):
		var p = sig_in[i]
		var px: float = size.x * float(i + 1) / float(n_sig + 1)
		_port_sockets[p.id] = {
			"pos": Vector2(px, 0.0), "kind": p.kind, "is_output": false,
			"dir": "input", "name": p.name if not p.name.is_empty() else p.id,
			"cardinality": p.cardinality, "edge": "top"
		}

	# 4. Bottom Perimeter Edge (y = size.y): Metric Out
	var n_met := met_out.size()
	for i in range(n_met):
		var p = met_out[i]
		var px: float = size.x * float(i + 1) / float(n_met + 1)
		_port_sockets[p.id] = {
			"pos": Vector2(px, size.y), "kind": p.kind, "is_output": true,
			"dir": "output", "name": p.name if not p.name.is_empty() else p.id,
			"cardinality": p.cardinality, "edge": "bottom"
		}

func _recalculate_size() -> void:
	if element == null and subgraph == null:
		size = custom_minimum_size
		return

	if _is_curved_or_joined_conveyor():
		# Compact Midpoint Spine Pill for curved/joined conveyors (sits directly on belt midpoint)
		custom_minimum_size = Vector2(88.0, 24.0)
		size = Vector2(88.0, 24.0)
		return

	var dims := _get_physical_dimensions()
	var min_w: float = 36.0
	var min_h: float = 36.0

	if element != null and element.kind == "conveyor":
		min_w = 40.0
		min_h = 24.0
	elif element != null and element.kind in ["chart_station", "scope_2d", "digital_meter", "histogram_sink", "state_space_3d", "xy_scatter"]:
		var n_sub: int = element.properties.get("subplots", []).size() if element.properties.has("subplots") else 1
		min_w = max(min_w, 180.0)
		min_h = max(min_h, 42.0 + float(max(1, n_sub)) * 32.0)

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
				if mb.double_click:
					if subgraph != null:
						subgraph_drilldown_requested.emit(nid)
						accept_event()
						return
					elif element != null:
						block_selected.emit(nid)
						var mouse_pos: Vector2 = mb.global_position if mb.global_position != Vector2.ZERO else (get_global_mouse_position() if is_inside_tree() else mb.position)
						floating_properties_requested.emit(nid, mouse_pos)
						accept_event()
						return

				# 1. Check if clicked on a port badge (×N) -> open Channel Pop-Up Pill
				var hit_badge := _hit_test_port_badge(mb.position)
				if not hit_badge.is_empty():
					var p_info_b: Dictionary = _port_sockets[hit_badge]
					var spos_b: Vector2 = mb.global_position if mb.global_position != Vector2.ZERO else get_port_canvas_position(hit_badge)
					port_channel_popup_requested.emit(nid, hit_badge, bool(p_info_b.get("is_output", true)), spos_b)
					accept_event()
					return

				# 2. Check if clicked on a port socket
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

				# 3. Check if clicked on any of the 4 resize corners (not on curved conveyor spine pill)
				if not _is_curved_or_joined_conveyor():
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
				_drag_start_node_pos = position
				_drag_start_canvas_mouse = _event_canvas_mouse_pos(mb.position, mb.global_position)
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
			var hit_port := _hit_test_port(mb.position)
			if not hit_port.is_empty():
				var p_info: Dictionary = _port_sockets[hit_port]
				var conn_cnt: int = int(port_connection_counts.get(hit_port, 0))
				if conn_cnt > 1:
					var spos: Vector2 = mb.global_position if mb.global_position != Vector2.ZERO else get_port_canvas_position(hit_port)
					port_channel_popup_requested.emit(nid, hit_port, bool(p_info.get("is_output", true)), spos)
				else:
					disconnect_port_requested.emit(nid, hit_port)
				accept_event()
				return
			else:
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
			var cur_canvas_mouse := _event_canvas_mouse_pos(mm.position, mm.global_position)
			var desired_pos := _drag_start_node_pos + (cur_canvas_mouse - _drag_start_canvas_mouse)
			if desired_pos.is_finite():
				position = desired_pos
				block_moved.emit(nid, position)
			accept_event()
		else:
			var hit_p := _hit_test_port(mm.position)
			set_hovered_port(hit_p)
			if not hit_p.is_empty() or not _hit_test_port_badge(mm.position).is_empty():
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			else:
				var corner := _hit_test_resize_corner(mm.position)
				if corner == ResizeCorner.TOP_LEFT or corner == ResizeCorner.BOTTOM_RIGHT:
					mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
				elif corner == ResizeCorner.TOP_RIGHT or corner == ResizeCorner.BOTTOM_LEFT:
					mouse_default_cursor_shape = Control.CURSOR_BDIAGSIZE
				else:
					mouse_default_cursor_shape = Control.CURSOR_ARROW

func _get_corner_size() -> float:
	return clamp(min(size.x, size.y) * 0.22, 8.0, 14.0)

func _hit_test_resize_corner(local_pos: Vector2) -> ResizeCorner:
	if _is_curved_or_joined_conveyor():
		return ResizeCorner.NONE
	var hit_p := _hit_test_port(local_pos)
	if not hit_p.is_empty() and _port_sockets.has(hit_p):
		var p_pos: Vector2 = _port_sockets[hit_p]["pos"]
		if local_pos.distance_to(p_pos) <= 6.5:
			return ResizeCorner.NONE
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
	if _port_sockets.is_empty():
		calculate_sockets()
	var socket_r: float = 6.0
	var max_dist: float = socket_r + 4.0
	var best_id := ""
	var best_dist := max_dist
	for port_id in _port_sockets.keys():
		var spos: Vector2 = _port_sockets[port_id]["pos"]
		var d: float = local_pos.distance_to(spos)
		if d <= best_dist:
			best_dist = d
			best_id = port_id
	return best_id

func _get_port_badge_rect(port_id: String) -> Rect2:
	if not _port_sockets.has(port_id):
		return Rect2()
	var cnt: int = int(port_connection_counts.get(port_id, 0))
	if cnt <= 1:
		return Rect2()
	var p_info: Dictionary = _port_sockets[port_id]
	var p_pos: Vector2 = p_info["pos"]
	var edge: String = str(p_info.get("edge", "right"))
	var bw := 22.0
	var bh := 13.0
	match edge:
		"left":
			return Rect2(p_pos.x - bw - 6.0, p_pos.y - bh * 0.5, bw, bh)
		"right":
			return Rect2(p_pos.x + 6.0, p_pos.y - bh * 0.5, bw, bh)
		"top":
			return Rect2(p_pos.x - bw * 0.5, p_pos.y - bh - 6.0, bw, bh)
		_:
			return Rect2(p_pos.x - bw * 0.5, p_pos.y + 6.0, bw, bh)

func _hit_test_port_badge(local_pos: Vector2) -> String:
	for port_id in _port_sockets.keys():
		var r := _get_port_badge_rect(port_id)
		if r.size != Vector2.ZERO and r.grow(2.0).has_point(local_pos):
			return port_id
	return ""

func _hit_test_port_button(_local_pos: Vector2) -> Dictionary:
	return {}

func _hit_test_add_button(_local_pos: Vector2) -> String:
	return ""

func _hit_test_remove_button(_local_pos: Vector2) -> String:
	return ""

func _get_tooltip(at_position: Vector2) -> String:
	var hit_badge := _hit_test_port_badge(at_position)
	if not hit_badge.is_empty():
		var cnt: int = int(port_connection_counts.get(hit_badge, 0))
		return "Bus Port '%s' (%d channels)\nClick to inspect, reorder, or delete channels" % [hit_badge, cnt]

	var hit_port := _hit_test_port(at_position)
	if not hit_port.is_empty():
		var p_info: Dictionary = _port_sockets.get(hit_port, {})
		var dir_str: String = "Output" if p_info.get("is_output", false) else "Input"
		var kind_str: String = str(p_info.get("kind", "")).capitalize()
		var p_name: String = str(p_info.get("name", hit_port))
		var cnt: int = int(port_connection_counts.get(hit_port, 0))
		var base_tip := "%s %s: %s (ID: %s)" % [kind_str, dir_str, p_name, hit_port]
		if cnt > 0:
			base_tip += "\nConnected channels: %d" % cnt
		return base_tip + "\n(Drag to wire · Right-click to manage/disconnect)"

	if element != null:
		var name_str := element.name if not element.name.is_empty() else element.id
		var dims := _get_physical_dimensions()
		var tip := "%s [%s]\nID: %s\nSize: %.1fm × %.1fm" % [name_str, element.kind.capitalize(), element.id, dims.x, dims.y]
		return tip + "\n(Double-click or Right-click to edit properties)"
	elif subgraph != null:
		var name_str := subgraph.name if not subgraph.name.is_empty() else subgraph.id
		return "%s [%s]\nID: %s\n(Double-click to drill down)" % [name_str, subgraph.role.capitalize(), subgraph.id]

	return ""

func _draw() -> void:
	calculate_sockets()
	var rect := Rect2(Vector2.ZERO, size)
	var is_highlighted := is_selected or is_multi_selected

	# Special Case A: Curved/Joined Conveyor Midpoint Spine Pill (sits directly on the curve midpoint)
	if _is_curved_or_joined_conveyor():
		_draw_conveyor_midpoint_pill(rect, is_highlighted)
		_draw_perimeter_port_sockets()
		return

	# Special Case B: Straight Conveyor — draw the physical roller belt directly inside Rect2(0, 0, size.x, size.y)!
	if element != null and element.kind == "conveyor":
		_draw_straight_conveyor_belt(rect, is_highlighted)
		_draw_perimeter_port_sockets()
		return

	# 1. Main Block Background & Outer Border (100% full footprint — zero side bays)
	var accent_col := get_element_kind_accent(element.kind) if element != null else Color("#1abc9c")
	draw_rect(rect, BG_SELECTED if is_highlighted else BG_NORMAL, true)
	draw_rect(Rect2(0, 0, size.x, 3.0), Color(accent_col.r, accent_col.g, accent_col.b, 0.75), true)
	draw_rect(rect, BORDER_SELECTED if is_highlighted else BORDER_NORMAL, false, 2.0 if is_highlighted else 1.2)

	# 2. Body Content & Adaptive Nameplate
	if element != null:
		var dims := _get_physical_dimensions()
		var dim_str := "%.0f×%.0fm" % [dims.x, dims.y] if (is_equal_approx(dims.x, round(dims.x)) and is_equal_approx(dims.y, round(dims.y))) else "%.1f×%.1fm" % [dims.x, dims.y]
		var title: String = element.name if not element.name.is_empty() else element.id
		var cur_rot: float = fposmod(float(element.transform.rotation.z), 360.0) if element.transform != null else 0.0

		if element.kind == "chart_station":
			_draw_chart_station_body(title)
		elif element.kind == "scope_2d":
			_draw_scope_2d_body(title)
		elif element.kind == "digital_meter":
			_draw_digital_meter_body(title)
		elif element.kind == "histogram_sink":
			_draw_histogram_sink_body(title)
		elif element.kind in ["state_space_3d", "xy_scatter"]:
			_draw_scatter_body(title)
		else:
			if uses_floating_nameplate():
				# Compact block (e.g. 40×40px Source/Sink): unboxed floating caption above + clean icon/KPI inside
				_draw_floating_nameplate_caption(title, accent_col)
				var short_kind := _short_kind_tag(element.kind)
				draw_string(ThemeDB.fallback_font, Vector2(2.0, 16.0), short_kind, HORIZONTAL_ALIGNMENT_CENTER, int(size.x - 4.0), 9, accent_col)
				var kpi_compact := _format_compact_kpi()
				if not kpi_compact.is_empty():
					draw_string(ThemeDB.fallback_font, Vector2(2.0, size.y - 6.0), kpi_compact, HORIZONTAL_ALIGNMENT_CENTER, int(size.x - 4.0), 9, TEXT_COLOR)
				else:
					draw_string(ThemeDB.fallback_font, Vector2(2.0, size.y - 6.0), dim_str, HORIZONTAL_ALIGNMENT_CENTER, int(size.x - 4.0), 8, MUTED_COLOR)
			else:
				# Medium/Wide block (size.x >= 68px, e.g. 80×40 Queue/Server): all labels inside the block!
				if size.y >= 54.0:
					draw_string(ThemeDB.fallback_font, Vector2(8.0, 19.0), title, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 16.0), 11, TEXT_COLOR)
					var sub_str := "%s · %s" % [element.kind.to_upper(), dim_str]
					if cur_rot > 0.05:
						sub_str += " · ∡%.0f°" % cur_rot
					draw_string(ThemeDB.fallback_font, Vector2(8.0, 33.0), sub_str, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 16.0), 9, MUTED_COLOR)
					_draw_live_telemetry_bar(38.0)
				else:
					# Standard 40px-tall block (e.g. 80×40 Queue/Server): 2 crisp internal rows
					draw_string(ThemeDB.fallback_font, Vector2(6.0, 16.0), title, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 12.0), 10, TEXT_COLOR)
					var kpi_line := _format_compact_kpi()
					if not kpi_line.is_empty():
						draw_string(ThemeDB.fallback_font, Vector2(6.0, 31.0), "%s · %s" % [_short_kind_tag(element.kind), kpi_line], HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 12.0), 9, COLOR_FLOW)
					else:
						draw_string(ThemeDB.fallback_font, Vector2(6.0, 31.0), "%s · %s" % [_short_kind_tag(element.kind), dim_str], HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 12.0), 9, MUTED_COLOR)

	elif subgraph != null:
		_draw_subgraph_body(rect)

	# 3. Perimeter Port Sockets & Multi-Wire Bus Badges
	_draw_perimeter_port_sockets()

func _draw_straight_conveyor_belt(rect: Rect2, is_highlighted: bool) -> void:
	var dims := _get_physical_dimensions()
	var dim_str := "%.0f×%.0fm" % [dims.x, dims.y] if (is_equal_approx(dims.x, round(dims.x)) and is_equal_approx(dims.y, round(dims.y))) else "%.1f×%.1fm" % [dims.x, dims.y]
	var title: String = element.name if not element.name.is_empty() else element.id

	# Selection glow halo
	if is_highlighted:
		draw_rect(rect.grow(3.0), Color(0.0, 0.82, 1.0, 0.22), true)

	# 1. Dark rubber belt bed
	var bed_col := Color("#172736") if is_highlighted else Color("#121b26")
	draw_rect(rect, bed_col, true)

	# 2. Vertical roller crossbars along belt length
	var roller_step := 14.0
	var roller_col := Color(0.22, 0.34, 0.45, 0.55)
	var rx := 10.0
	while rx < size.x - 8.0:
		draw_line(Vector2(rx, 2.0), Vector2(rx, size.y - 2.0), roller_col, 1.0)
		rx += roller_step

	# 3. Directional flow chevrons (>>>) along belt centerline
	var cy := size.y * 0.5
	var chev_step := 30.0
	var chev_size: float = clampf(size.y * 0.26, 3.5, 7.0)
	var chev_col := Color(0.18, 0.85, 0.48, 0.85)
	var cx := 20.0
	while cx < size.x - 16.0:
		var tip := Vector2(cx + chev_size * 0.7, cy)
		var wing_t := Vector2(cx - chev_size * 0.6, cy - chev_size)
		var wing_b := Vector2(cx - chev_size * 0.6, cy + chev_size)
		draw_polyline(PackedVector2Array([wing_t, tip, wing_b]), chev_col, 1.6, true)
		cx += chev_step

	# 4. Top & Bottom Steel Side Rails
	var rail_col := Color("#52c7a5") if is_highlighted else Color("#2a9d8f")
	draw_line(Vector2(0.0, 1.0), Vector2(size.x, 1.0), rail_col, 2.2)
	draw_line(Vector2(0.0, size.y - 1.0), Vector2(size.x, size.y - 1.0), rail_col, 2.2)
	draw_line(Vector2(0.5, 0.0), Vector2(0.5, size.y), Color(rail_col.r, rail_col.g, rail_col.b, 0.6), 1.2)
	draw_line(Vector2(size.x - 0.5, 0.0), Vector2(size.x - 0.5, size.y), Color(rail_col.r, rail_col.g, rail_col.b, 0.6), 1.2)

	# 5. Floating Nameplate & Live Telemetry above the Top Rail (keeps belt centerline 100% clear for products!)
	var kpi_txt := _format_compact_kpi()
	var label_txt := "%s  %s" % [title, kpi_txt] if not kpi_txt.is_empty() else "%s · %s" % [title, dim_str]
	var font := ThemeDB.fallback_font
	var fsize := 10
	var tw: float = font.get_string_size(label_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
	var tx: float = (size.x - tw) * 0.5
	draw_string(font, Vector2(tx, -10.0), label_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, TEXT_COLOR)

func _draw_conveyor_midpoint_pill(_rect: Rect2, _is_highlighted: bool) -> void:
	var title: String = element.name if (element != null and not element.name.is_empty()) else (element.id if element != null else "CONV")
	var kpi := _format_compact_kpi()
	var text_line := "%s  %s" % [title, kpi] if not kpi.is_empty() else title
	var font := ThemeDB.fallback_font
	var fsize := 10
	var tw: float = font.get_string_size(text_line, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
	draw_string(font, Vector2((size.x - tw) * 0.5, -10.0), text_line.strip_edges(), HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, TEXT_COLOR)

func _draw_floating_nameplate_caption(title: String, _accent_col: Color) -> void:
	# Clean unboxed floating text caption above compact 40×40px blocks (never a bordered box!)
	var font := ThemeDB.fallback_font
	var fsize := 9
	var ts := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize)
	var w := clampf(ts.x + 8.0, 44.0, 140.0)
	var tx := (size.x - w) * 0.5
	var ty := -5.0
	draw_string(font, Vector2(tx + 1.0, ty + 1.0), title, HORIZONTAL_ALIGNMENT_CENTER, int(w), fsize, Color(0.0, 0.0, 0.0, 0.85))
	draw_string(font, Vector2(tx, ty), title, HORIZONTAL_ALIGNMENT_CENTER, int(w), fsize, TEXT_COLOR)

func _short_kind_tag(k: String) -> String:
	match k:
		"source": return "SRC"
		"queue": return "QUEUE"
		"server": return "SRV"
		"conveyor": return "CONV"
		"sink": return "SINK"
		_: return k.to_upper().substr(0, 5)

func _format_compact_kpi() -> String:
	if live_metrics.is_empty():
		return ""
	var badge_str: String = str(live_metrics.get("badge", ""))
	if not badge_str.is_empty():
		return badge_str
	if element != null:
		match element.kind:
			"source":
				if live_metrics.has("spawned_count"):
					return "n=%d" % int(live_metrics.get("spawned_count", 0))
			"queue":
				if live_metrics.has("queue_length"):
					return "Q=%d" % int(live_metrics.get("queue_length", 0))
			"server":
				if live_metrics.has("utilization_pct"):
					return "%.0f%%" % float(live_metrics.get("utilization_pct", 0.0))
			"conveyor":
				if live_metrics.has("items_in_transit"):
					return "%d items" % int(live_metrics.get("items_in_transit", 0))
			"sink":
				if live_metrics.has("completed_count"):
					return "Σ=%d" % int(live_metrics.get("completed_count", 0))
	return ""

func _draw_live_telemetry_bar(y_pos: float) -> void:
	if live_metrics.is_empty():
		return
	var badge_str: String = _format_compact_kpi()
	if badge_str.is_empty():
		return
	var badge_col := Color("#2ecc71")
	var s_state: String = str(live_metrics.get("state", ""))
	if s_state == "BUSY": badge_col = Color("#e74c3c")
	elif s_state == "DOWN": badge_col = Color("#e67e22")
	elif s_state == "IDLE": badge_col = Color("#95a5a6")
	elif s_state == "PARTIAL": badge_col = Color("#f1c40f")
	draw_string(ThemeDB.fallback_font, Vector2(8.0, min(size.y - 6.0, y_pos + 10.0)), badge_str, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 16.0), 9, badge_col)

func _draw_perimeter_port_sockets() -> void:
	var socket_r: float = 5.5
	for port_id in _port_sockets.keys():
		if not should_show_port_socket(port_id):
			continue
		var p_info: Dictionary = _port_sockets[port_id]
		var p_pos: Vector2 = p_info["pos"]
		var p_kind: String = p_info["kind"]
		var is_out: bool = p_info["is_output"]
		var is_hovered: bool = (port_id == hovered_port_id)
		var conn_cnt: int = int(port_connection_counts.get(port_id, 0))

		var p_col: Color = get_port_kind_color(p_kind)
		var bg_col := Color(p_col.r * 0.18, p_col.g * 0.18, p_col.b * 0.18, 0.95)
		var is_many: bool = (str(p_info.get("cardinality", "one")) == "many")

		if is_hovered:
			draw_circle(p_pos, socket_r + 4.0, Color(1.0, 1.0, 1.0, 0.25))
			draw_arc(p_pos, socket_r + 4.0, 0, TAU, 16, Color.WHITE, 1.5)

		draw_circle(p_pos, socket_r, bg_col)
		draw_arc(p_pos, socket_r, 0, TAU, 14, p_col, 1.4)
		if is_many:
			var sq_r := socket_r * 0.44
			draw_rect(Rect2(p_pos.x - sq_r, p_pos.y - sq_r, sq_r * 2.0, sq_r * 2.0), Color.WHITE if is_out else p_col, true)
		else:
			draw_circle(p_pos, socket_r * 0.48, Color.WHITE if is_out else p_col)

		# Multi-Wire Bus Count Badge (×N) when conn_cnt > 1
		if conn_cnt > 1:
			var b_rect := _get_port_badge_rect(port_id)
			if b_rect.size != Vector2.ZERO:
				var badge_bg := Color("#3d1f09f0") if conn_cnt > 32 else Color("#0d261cf0")
				var badge_border := Color("#f39c12") if conn_cnt > 32 else p_col
				draw_rect(b_rect, badge_bg, true)
				draw_rect(b_rect, badge_border, false, 1.0)
				draw_string(ThemeDB.fallback_font, Vector2(b_rect.position.x + 2.0, b_rect.position.y + 10.0), "×%d" % conn_cnt, HORIZONTAL_ALIGNMENT_CENTER, int(b_rect.size.x - 4.0), 8, Color.WHITE)

func _draw_chart_station_body(title: String) -> void:
	var subplots: Array = element.properties.get("subplots", [])
	var badge_str: String = "[%d Subplots]" % subplots.size()
	draw_string(ThemeDB.fallback_font, Vector2(8.0, 18.0), title, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 80.0), 10, TEXT_COLOR)
	draw_string(ThemeDB.fallback_font, Vector2(size.x - 70.0, 18.0), badge_str, HORIZONTAL_ALIGNMENT_RIGHT, 64, 9, COLOR_SIGNAL)

	var y_cursor: float = 34.0
	for i in range(subplots.size()):
		var sp = subplots[i]
		var sp_port: String = str(sp.get("port_id", "P%d" % (i + 1)))
		var sp_type: String = str(sp.get("type", "time_series"))
		var sp_title: String = str(sp.get("title", "Subplot %d" % (i + 1)))

		var row_rect := Rect2(6.0, y_cursor - 10.0, size.x - 12.0, 24.0)
		draw_rect(row_rect, Color("#0d131a"), true)
		draw_rect(row_rect, Color("#222d3d"), false, 1.0)

		var type_short: String = "SCOPE"
		if sp_type == "digital_gauge": type_short = "GAUGE"
		elif sp_type == "histogram": type_short = "HIST"
		elif sp_type == "xy_scatter": type_short = "SCATTER"
		elif sp_type == "state_space_3d": type_short = "3D"

		var line_txt := "%s [%s] %s" % [sp_port, type_short, sp_title]
		draw_string(ThemeDB.fallback_font, Vector2(10.0, y_cursor + 5.0), line_txt, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 20.0), 9, Color("#8b949e"))
		y_cursor += 28.0

func _draw_scope_2d_body(title: String) -> void:
	var screen_rect := Rect2(8.0, 24.0, max(10.0, size.x - 16.0), max(10.0, size.y - 32.0))
	draw_rect(screen_rect, Color("#071018"), true)
	draw_rect(screen_rect, Color("#1f6feb80"), false, 1.5)
	var mid_y := screen_rect.position.y + screen_rect.size.y * 0.5
	draw_line(Vector2(screen_rect.position.x, mid_y), Vector2(screen_rect.position.x + screen_rect.size.x, mid_y), Color(0.12, 0.3, 0.5, 0.3), 1.0)
	var s_max: float = 1.0
	for v in signal_history:
		s_max = max(s_max, float(v))
	if signal_history.size() >= 2:
		var s_pts := PackedVector2Array()
		var s_step: float = screen_rect.size.x / max(1.0, float(signal_history.size() - 1))
		for i in range(signal_history.size()):
			var sx: float = screen_rect.position.x + float(i) * s_step
			var sy: float = screen_rect.position.y + screen_rect.size.y - (clamp(float(signal_history[i]) / max(0.001, s_max), 0.0, 1.0) * (screen_rect.size.y - 8.0)) - 4.0
			s_pts.append(Vector2(sx, sy))
		draw_polyline(s_pts, Color("#00d2ff"), 2.0, true)
		draw_circle(s_pts[-1], 3.0, Color("#58a6ff"))
	var latest_val: float = float(signal_history.back()) if not signal_history.is_empty() else 0.0
	var y_label: String = str(element.properties.get("y_label", "Signal"))
	draw_string(ThemeDB.fallback_font, Vector2(8.0, 18.0), title, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 80.0), 10, TEXT_COLOR)
	draw_string(ThemeDB.fallback_font, Vector2(screen_rect.position.x + screen_rect.size.x - 70.0, 18.0), "%.1f %s" % [latest_val, y_label], HORIZONTAL_ALIGNMENT_RIGHT, 70, 10, Color("#00d2ff"))

func _draw_digital_meter_body(title: String) -> void:
	var screen_rect := Rect2(8.0, 24.0, max(10.0, size.x - 16.0), max(10.0, size.y - 32.0))
	draw_rect(screen_rect, Color("#07120b"), true)
	draw_rect(screen_rect, Color("#238636a0"), false, 1.5)
	var latest_val: float = float(signal_history.back()) if not signal_history.is_empty() else 0.0
	var meter_unit: String = str(element.properties.get("unit", ""))
	var disp_str := "%.1f %s" % [latest_val, meter_unit]
	draw_string(ThemeDB.fallback_font, Vector2(8.0, 18.0), title, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 16.0), 10, TEXT_COLOR)
	draw_string(ThemeDB.fallback_font, Vector2(screen_rect.position.x, screen_rect.position.y + screen_rect.size.y * 0.68), disp_str.strip_edges(), HORIZONTAL_ALIGNMENT_CENTER, int(screen_rect.size.x), 16, Color("#3fb950"))

func _draw_histogram_sink_body(title: String) -> void:
	var screen_rect := Rect2(8.0, 24.0, max(10.0, size.x - 16.0), max(10.0, size.y - 32.0))
	draw_rect(screen_rect, Color("#0e0818"), true)
	draw_rect(screen_rect, Color("#8957e580"), false, 1.2)
	var n_bars := 9
	var b_width: float = (screen_rect.size.x - 4.0) / float(n_bars)
	for b_idx in range(n_bars):
		var bar_h: float = (sin(float(b_idx) * 0.7 + 0.4) * 0.5 + 0.5) * (screen_rect.size.y - 10.0)
		var bx: float = screen_rect.position.x + 2.0 + float(b_idx) * b_width
		var by: float = screen_rect.position.y + screen_rect.size.y - bar_h - 2.0
		draw_rect(Rect2(bx, by, max(1.0, b_width - 2.0), bar_h), Color("#bc8cffaa"), true)
	draw_string(ThemeDB.fallback_font, Vector2(8.0, 18.0), title, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 16.0), 10, TEXT_COLOR)

func _draw_scatter_body(title: String) -> void:
	var screen_rect := Rect2(8.0, 24.0, max(10.0, size.x - 16.0), max(10.0, size.y - 32.0))
	draw_rect(screen_rect, Color("#151107"), true)
	draw_rect(screen_rect, Color("#d2992280"), false, 1.2)
	var cx := screen_rect.position.x + screen_rect.size.x * 0.5
	var cy := screen_rect.position.y + screen_rect.size.y * 0.5
	draw_line(Vector2(cx, screen_rect.position.y), Vector2(cx, screen_rect.position.y + screen_rect.size.y), Color(0.4, 0.35, 0.1, 0.4), 1.0)
	draw_line(Vector2(screen_rect.position.x, cy), Vector2(screen_rect.position.x + screen_rect.size.x, cy), Color(0.4, 0.35, 0.1, 0.4), 1.0)
	draw_circle(Vector2(cx + 10.0, cy - 8.0), 3.5, Color("#d29922"))
	draw_string(ThemeDB.fallback_font, Vector2(8.0, 18.0), title, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 16.0), 10, TEXT_COLOR)

func _draw_subgraph_body(rect: Rect2) -> void:
	var dims := _get_physical_dimensions()
	var title: String = subgraph.name if not subgraph.name.is_empty() else subgraph.id
	var role_str: String = "[%s]" % ("SUBSYSTEM" if subgraph.role in ["group", "compound"] else subgraph.role.to_upper())
	var sub_col := Color("#1abc9c") if subgraph.role == "compound" else Color("#9b59b6")

	var inset_rect := rect.grow(-3.0)
	draw_rect(inset_rect, Color(sub_col.r, sub_col.g, sub_col.b, 0.08), true)
	draw_rect(inset_rect, sub_col, false, 1.2)

	if uses_floating_nameplate():
		_draw_floating_nameplate_caption(title, sub_col)
		draw_string(ThemeDB.fallback_font, Vector2(4.0, size.y * 0.55), "SUB [%d]" % subgraph.elements.size(), HORIZONTAL_ALIGNMENT_CENTER, int(size.x - 8.0), 9, sub_col)
	else:
		draw_string(ThemeDB.fallback_font, Vector2(8.0, 20.0), title, HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 16.0), 11, TEXT_COLOR)
		draw_string(ThemeDB.fallback_font, Vector2(8.0, 34.0), "%s · %.1f×%.1fm (%d items)" % [role_str, dims.x, dims.y, subgraph.elements.size()], HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 16.0), 9, sub_col)

