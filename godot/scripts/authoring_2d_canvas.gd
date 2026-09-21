# authoring_2d_canvas.gd
# Unified 2D Layout Canvas rendering CAD floorplan, entity blocks, and direct port connection splines.
class_name SimVizAuthoring2DCanvas
extends Control

const BlockNode := preload("res://scripts/authoring_block_node.gd")
const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")

signal element_selected(element_id: String)
signal connection_created(conn: SceneTypes.SceneConnection)

const BG_COLOR := Color("#0b1018")
const GRID_MAJOR := Color("#1a2636")
const GRID_MINOR := Color("#111a24")
const CAD_WALL_COLOR := Color("#2e4359")
const ROOM_LABEL_COLOR := Color("#415b76")
const FLOW_WIRE_COLOR := Color("#2ecc71")
const SIGNAL_WIRE_COLOR := Color("#f39c12")
const INCOMPATIBLE_WIRE_COLOR := Color("#e74c3c")

var doc_store: DocumentStore
var _block_nodes: Dictionary = {} # element_id -> SimVizAuthoringBlockNode

# Pan & Zoom transform
var pan_offset: Vector2 = Vector2(80, 80)
var zoom_level: float = 1.0
var _panning: bool = false
var _pan_start: Vector2 = Vector2.ZERO

# Wire drag state
var _is_dragging_wire: bool = false
var _wire_source_elem: String = ""
var _wire_source_port: String = ""
var _wire_source_kind: String = ""
var _wire_source_is_output: bool = true
var _wire_source_pos: Vector2 = Vector2.ZERO
var _wire_current_mouse: Vector2 = Vector2.ZERO
var _wire_hovered_elem: String = ""
var _wire_hovered_port: String = ""
var _wire_is_compatible: bool = false
var _wires_layer: Control = null

func _ensure_wires_layer() -> void:
	if _wires_layer == null:
		_wires_layer = Control.new()
		_wires_layer.name = "WiresOverlay"
		_wires_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_wires_layer.z_index = 10
		_wires_layer.draw.connect(_on_wires_layer_draw)
		add_child(_wires_layer)

func _redraw_all() -> void:
	queue_redraw()
	if _wires_layer != null and is_instance_valid(_wires_layer):
		_wires_layer.queue_redraw()

func _init(p_store: DocumentStore = null) -> void:
	doc_store = p_store
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_ensure_wires_layer()

func _ready() -> void:
	_ensure_wires_layer()
	if doc_store != null:
		doc_store.document_loaded.connect(_on_document_reloaded)
		doc_store.document_modified.connect(_on_document_modified)
		doc_store.selection_changed.connect(_on_selection_changed)
		rebuild_blocks()

func rebuild_blocks() -> void:
	_ensure_wires_layer()
	for child in get_children():
		if child == _wires_layer:
			continue
		child.queue_free()
	_block_nodes.clear()

	if doc_store == null or doc_store.active_document == null:
		_redraw_all()
		return

	for elem in doc_store.active_document.elements:
		var b := BlockNode.new(elem)
		add_child(b)
		_block_nodes[elem.id] = b

		# Position block on canvas from editor position or transform
		var gx: float = elem.editor.graph_position.x if elem.editor.graph_position != Vector2.ZERO else float(elem.transform.position[0]) * 20.0
		var gy: float = elem.editor.graph_position.y if elem.editor.graph_position != Vector2.ZERO else float(elem.transform.position[1]) * 20.0
		b.position = pan_offset + (Vector2(gx, gy) * zoom_level)

		b.block_selected.connect(_on_block_selected)
		b.block_moved.connect(_on_block_moved)
		b.port_drag_started.connect(_on_port_drag_started)
		b.add_port_requested.connect(_on_add_port_requested)
		b.remove_port_requested.connect(_on_remove_port_requested)
		b.disconnect_port_requested.connect(_on_disconnect_port_requested)

	move_child(_wires_layer, -1)
	_redraw_all()

func _on_document_reloaded(_doc: SceneTypes.SceneDocument) -> void:
	rebuild_blocks()

func _on_document_modified() -> void:
	_redraw_all()

func _on_selection_changed(sel_id: String, _sel_type: String) -> void:
	for id_val in _block_nodes.keys():
		_block_nodes[id_val].set_selected(id_val == sel_id)
	_redraw_all()

func _on_block_selected(elem_id: String) -> void:
	if doc_store != null:
		doc_store.select(elem_id, "element")
	element_selected.emit(elem_id)

func _on_block_moved(elem_id: String, new_pos: Vector2) -> void:
	var elem := doc_store.get_element(elem_id)
	if elem != null:
		# Convert canvas pixel position back to world coordinates
		var unscaled: Vector2 = (new_pos - pan_offset) / max(zoom_level, 0.01)
		elem.editor.graph_position = unscaled
		elem.transform.position.x = unscaled.x / 20.0
		elem.transform.position.y = unscaled.y / 20.0
		if doc_store != null:
			doc_store.is_dirty = true
			doc_store.validate()
	_redraw_all()

func _on_port_drag_started(elem_id: String, port_id: String, port_kind: String, is_output: bool, start_pos: Vector2) -> void:
	_is_dragging_wire = true
	_wire_source_elem = elem_id
	_wire_source_port = port_id
	_wire_source_kind = port_kind
	_wire_source_is_output = is_output
	_wire_source_pos = start_pos
	_wire_current_mouse = _wire_source_pos
	_wire_hovered_elem = ""
	_wire_hovered_port = ""
	_wire_is_compatible = false
	_redraw_all()

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ik := event as InputEventKey
		if ik.pressed:
			if ik.keycode == KEY_ESCAPE:
				if _is_dragging_wire:
					_cancel_wire_drag()
					if is_inside_tree() and get_viewport() != null:
						get_viewport().set_input_as_handled()
				elif doc_store != null and doc_store.selected_type == "connection":
					doc_store.clear_selection()
					_redraw_all()
					if is_inside_tree() and get_viewport() != null:
						get_viewport().set_input_as_handled()
			elif ik.keycode in [KEY_DELETE, KEY_BACKSPACE]:
				if doc_store != null and doc_store.selected_type == "connection" and not doc_store.selected_id.is_empty():
					doc_store.remove_connection(doc_store.selected_id)
					_redraw_all()
					if is_inside_tree() and get_viewport() != null:
						get_viewport().set_input_as_handled()

	if not _is_dragging_wire:
		return

	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_wire_current_mouse = get_local_mouse_position() if is_inside_tree() else mm.position
		_update_wire_hover()
		_redraw_all()
		if is_inside_tree() and get_viewport() != null:
			get_viewport().set_input_as_handled()

	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_finish_wire_drag()
			if is_inside_tree() and get_viewport() != null:
				get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_cancel_wire_drag()
			if is_inside_tree() and get_viewport() != null:
				get_viewport().set_input_as_handled()

func _update_wire_hover() -> void:
	var canvas_mouse := get_local_mouse_position() if is_inside_tree() else _wire_current_mouse
	var prev_hover_elem := _wire_hovered_elem
	var prev_hover_port := _wire_hovered_port

	_wire_hovered_elem = ""
	_wire_hovered_port = ""
	_wire_is_compatible = false

	for eid in _block_nodes.keys():
		if eid == _wire_source_elem:
			continue
		var b: BlockNode = _block_nodes[eid]
		var lpos: Vector2 = canvas_mouse - b.position
		var hit_pid: String = b._hit_test_port(lpos)
		if not hit_pid.is_empty():
			var p_info: Dictionary = b.get_port_info(hit_pid)
			var tgt_kind: String = str(p_info.get("kind", ""))
			var tgt_is_out: bool = bool(p_info.get("is_output", false))

			# Flow Out -> Flow In (or reverse)
			if _wire_source_kind == "flow" and tgt_kind == "flow":
				if (_wire_source_is_output and not tgt_is_out) or (not _wire_source_is_output and tgt_is_out):
					_wire_is_compatible = true
			# Metric Out -> Signal In
			elif _wire_source_kind == "metric" and _wire_source_is_output and tgt_kind in ["signal", "control"] and not tgt_is_out:
				_wire_is_compatible = true
			# Signal In <- Metric Out
			elif _wire_source_kind in ["signal", "control"] and not _wire_source_is_output and tgt_kind == "metric" and tgt_is_out:
				_wire_is_compatible = true

			_wire_hovered_elem = eid
			_wire_hovered_port = hit_pid
			# Snap endpoint to target socket center
			_wire_current_mouse = b.position + b.get_port_local_position(hit_pid)
			break

	# Update visual port hover halo on block nodes
	if prev_hover_elem != _wire_hovered_elem or prev_hover_port != _wire_hovered_port:
		for b in _block_nodes.values():
			b.set_hovered_port("")
		if _block_nodes.has(_wire_hovered_elem):
			_block_nodes[_wire_hovered_elem].set_hovered_port(_wire_hovered_port)

func _finish_wire_drag() -> void:
	if _wire_is_compatible and not _wire_hovered_elem.is_empty() and not _wire_hovered_port.is_empty():
		_create_connection(
			_wire_source_elem, _wire_source_port, _wire_source_kind, _wire_source_is_output,
			_wire_hovered_elem, _wire_hovered_port
		)
	_cancel_wire_drag()

func _cancel_wire_drag() -> void:
	for b in _block_nodes.values():
		b.set_hovered_port("")
	_is_dragging_wire = false
	_wire_hovered_elem = ""
	_wire_hovered_port = ""
	_wire_is_compatible = false
	_redraw_all()

func _create_connection(src_e: String, src_p: String, src_kind: String, src_is_out: bool, tgt_e: String, tgt_p: String) -> void:
	var from_elem := src_e
	var from_port := src_p
	var to_elem := tgt_e
	var to_port := tgt_p
	var link_type := "flow" if src_kind == "flow" else "signal"

	# Normalize direction: source is output, target is input
	if not src_is_out:
		from_elem = tgt_e
		from_port = tgt_p
		to_elem = src_e
		to_port = src_p

	# Avoid duplicate connection
	if doc_store != null and doc_store.active_document != null:
		for c in doc_store.active_document.connections:
			if c.source_element == from_elem and c.source_port == from_port and c.target_element == to_elem and c.target_port == to_port:
				return

		var conn := SceneTypes.SceneConnection.new()
		conn.id = "%s_%s__%s_%s" % [from_elem, from_port, to_elem, to_port]
		conn.source_element = from_elem
		conn.source_port = from_port
		conn.target_element = to_elem
		conn.target_port = to_port
		conn.link_type = link_type

		doc_store.add_connection(conn)
		connection_created.emit(conn)

	_redraw_all()

func _on_add_port_requested(elem_id: String, bay_action: String) -> void:
	if doc_store == null:
		return
	var elem := doc_store.get_element(elem_id)
	if elem == null:
		return

	var port := SceneTypes.ScenePort.new()
	match bay_action:
		"flow_in":
			var count := _count_ports(elem.input_ports, "flow") + 1
			port.id = "flow_in_%d" % count
			port.kind = "flow"
			port.direction = "input"
			port.cardinality = "one"
			port.name = "Flow In %d" % count
			elem.input_ports.append(port)
		"flow_out":
			var count := _count_ports(elem.output_ports, "flow") + 1
			port.id = "flow_out_%d" % count
			port.kind = "flow"
			port.direction = "output"
			port.cardinality = "one"
			port.name = "Flow Out %d" % count
			elem.output_ports.append(port)
		"signal_in":
			var count := _count_ports(elem.input_ports, "signal") + 1
			port.id = "signal_in_%d" % count
			port.kind = "signal"
			port.direction = "input"
			port.cardinality = "one"
			port.name = "Signal %d" % count
			elem.input_ports.append(port)
		"metric_out":
			var count := elem.metric_ports.size() + 1
			port.id = "metric_out_%d" % count
			port.kind = "metric"
			port.direction = "output"
			port.cardinality = "many"
			port.name = "Metric %d" % count
			elem.metric_ports.append(port)

	doc_store.is_dirty = true
	doc_store.validate()
	rebuild_blocks()

func _on_remove_port_requested(elem_id: String, bay_action: String) -> void:
	if doc_store == null:
		return
	var ok := doc_store.remove_last_port_from_element(elem_id, bay_action)
	if ok:
		rebuild_blocks()

func _on_disconnect_port_requested(elem_id: String, port_id: String) -> void:
	if doc_store == null:
		return
	var count := doc_store.disconnect_port(elem_id, port_id)
	if count > 0:
		_redraw_all()

func _count_ports(ports_arr: Array, kind: String) -> int:
	var c := 0
	for p in ports_arr:
		if p.kind == kind:
			c += 1
	return c

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var hit_conn := _hit_test_connection(mb.position)
			if not hit_conn.is_empty():
				if doc_store != null:
					doc_store.select(hit_conn, "connection")
				_redraw_all()
				accept_event()
				return
			else:
				if doc_store != null and doc_store.selected_type == "connection":
					doc_store.clear_selection()
					_redraw_all()

		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var hit_conn := _hit_test_connection(mb.position)
			if not hit_conn.is_empty():
				if doc_store != null:
					doc_store.remove_connection(hit_conn)
				_redraw_all()
				accept_event()
				return

		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_panning = true
				_pan_start = mb.position - pan_offset
				accept_event()
			else:
				_panning = false
				accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_adjust_zoom(1.1, mb.position)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_adjust_zoom(0.9, mb.position)
			accept_event()

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning:
			pan_offset = mm.position - _pan_start
			_update_blocks_transform()
			_redraw_all()
			accept_event()

func _adjust_zoom(factor: float, pivot: Vector2) -> void:
	var old_zoom := zoom_level
	zoom_level = clamp(zoom_level * factor, 0.2, 4.0)
	pan_offset = pivot - (pivot - pan_offset) * (zoom_level / old_zoom)
	_update_blocks_transform()
	_redraw_all()

func _update_blocks_transform() -> void:
	if doc_store == null or doc_store.active_document == null:
		return
	for elem in doc_store.active_document.elements:
		if _block_nodes.has(elem.id):
			var b: BlockNode = _block_nodes[elem.id]
			var gx: float = elem.editor.graph_position.x if elem.editor.graph_position != Vector2.ZERO else float(elem.transform.position[0]) * 20.0
			var gy: float = elem.editor.graph_position.y if elem.editor.graph_position != Vector2.ZERO else float(elem.transform.position[1]) * 20.0
			b.position = pan_offset + (Vector2(gx, gy) * zoom_level)

func _draw() -> void:
	# 1. Background Fill
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR, true)

	# 2. CAD Floorplan Grid & Architectural Walls
	_draw_cad_background()

func _on_wires_layer_draw() -> void:
	if _wires_layer == null:
		return

	# 1. Connection Splines between Ports (Rendered on top of all blocks)
	_draw_connections()

	# 2. Live Drag Wire (Rendered on top of all blocks)
	if _is_dragging_wire:
		var wire_col := FLOW_WIRE_COLOR
		if not _wire_hovered_elem.is_empty():
			wire_col = (FLOW_WIRE_COLOR if _wire_source_kind == "flow" else SIGNAL_WIRE_COLOR) if _wire_is_compatible else INCOMPATIBLE_WIRE_COLOR
		else:
			wire_col = FLOW_WIRE_COLOR if _wire_source_kind == "flow" else SIGNAL_WIRE_COLOR
		_draw_spline(_wires_layer, _wire_source_pos, _wire_current_mouse, wire_col, 2.5, false)

func _draw_cad_background() -> void:
	var grid_size := 40.0 * zoom_level
	if grid_size > 8.0:
		var start_x: float = fmod(pan_offset.x, grid_size)
		var start_y: float = fmod(pan_offset.y, grid_size)
		var cur_x := start_x
		while cur_x < size.x:
			draw_line(Vector2(cur_x, 0), Vector2(cur_x, size.y), GRID_MINOR, 1.0)
			cur_x += grid_size
		var cur_y := start_y
		while cur_y < size.y:
			draw_line(Vector2(0, cur_y), Vector2(size.x, cur_y), GRID_MINOR, 1.0)
			cur_y += grid_size

	# Architectural Rooms & Perimeter lines
	var r1 := Rect2(pan_offset + Vector2(20, 20) * zoom_level, Vector2(400, 300) * zoom_level)
	draw_rect(r1, CAD_WALL_COLOR, false, 2.0)
	draw_string(ThemeDB.fallback_font, r1.position + Vector2(10, 20), "CAD ZONE: INFEED & RECEIVING", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ROOM_LABEL_COLOR)

	var r2 := Rect2(pan_offset + Vector2(460, 20) * zoom_level, Vector2(500, 300) * zoom_level)
	draw_rect(r2, CAD_WALL_COLOR, false, 2.0)
	draw_string(ThemeDB.fallback_font, r2.position + Vector2(10, 20), "CAD ZONE: MAIN PROCESSING & INSPECTION", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ROOM_LABEL_COLOR)

func _draw_connections() -> void:
	if doc_store == null or doc_store.active_document == null or _wires_layer == null:
		return

	var sel_conn_id := doc_store.selected_id if (doc_store != null and doc_store.selected_type == "connection") else ""

	for conn in doc_store.active_document.connections:
		var p1 := _resolve_port_position(conn.source_element, conn.source_port)
		var p2 := _resolve_port_position(conn.target_element, conn.target_port)
		if p1 != Vector2.ZERO and p2 != Vector2.ZERO:
			var is_conn_sel: bool = (str(conn.id) == sel_conn_id)
			if is_conn_sel:
				# Highlight selected connection with cyan glow and bright spline
				_draw_spline(_wires_layer, p1, p2, Color(0.0, 0.82, 1.0, 0.45), 6.0, false)
				_draw_spline(_wires_layer, p1, p2, Color("#00d2ff"), 2.5, false)
			else:
				var col := FLOW_WIRE_COLOR if conn.link_type == "flow" else SIGNAL_WIRE_COLOR
				var dashed: bool = (conn.link_type != "flow")
				_draw_spline(_wires_layer, p1, p2, col, 2.0, dashed)

func _hit_test_connection(canvas_mouse: Vector2) -> String:
	if doc_store == null or doc_store.active_document == null:
		return ""

	var best_conn_id := ""
	var best_dist := 10.0

	for conn in doc_store.active_document.connections:
		var p1 := _resolve_port_position(conn.source_element, conn.source_port)
		var p2 := _resolve_port_position(conn.target_element, conn.target_port)
		if p1 == Vector2.ZERO or p2 == Vector2.ZERO:
			continue

		var dx := (p2.x - p1.x) * 0.5
		var cp1 := p1 + Vector2(max(abs(dx), 40.0), 0)
		var cp2 := p2 - Vector2(max(abs(dx), 40.0), 0)

		var prev_pt := p1
		var segments := 16
		for i in range(1, segments + 1):
			var t := float(i) / float(segments)
			var cur_pt := p1.bezier_interpolate(cp1, cp2, p2, t)
			var d := _dist_to_segment(canvas_mouse, prev_pt, cur_pt)
			if d < best_dist:
				best_dist = d
				best_conn_id = conn.id
			prev_pt = cur_pt

	return best_conn_id

func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var l2: float = a.distance_squared_to(b)
	if l2 == 0.0:
		return p.distance_to(a)
	var t: float = clamp((p - a).dot(b - a) / l2, 0.0, 1.0)
	var proj: Vector2 = a + (b - a) * t
	return p.distance_to(proj)

func _resolve_port_position(elem_id: String, port_id: String) -> Vector2:
	if _block_nodes.has(elem_id):
		var b: BlockNode = _block_nodes[elem_id]
		return b.position + b.get_port_local_position(port_id)
	return Vector2.ZERO

func _draw_spline(target: CanvasItem, from: Vector2, to: Vector2, col: Color, width: float, dashed: bool) -> void:
	var dx := (to.x - from.x) * 0.5
	var cp1 := from + Vector2(max(abs(dx), 40.0), 0)
	var cp2 := to - Vector2(max(abs(dx), 40.0), 0)

	var points: PackedVector2Array = []
	var segments := 24
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var pt := from.bezier_interpolate(cp1, cp2, to, t)
		points.append(pt)

	if dashed:
		for i in range(0, points.size() - 1, 2):
			target.draw_line(points[i], points[i + 1], col, width)
	else:
		target.draw_polyline(points, col, width, true)

	# Draw arrowhead at target
	if points.size() >= 2:
		var dir := (to - points[points.size() - 2]).normalized()
		var perp := Vector2(-dir.y, dir.x) * 5.0
		var a1 := to - (dir * 10.0) + perp
		var a2 := to - (dir * 10.0) - perp
		target.draw_colored_polygon(PackedVector2Array([to, a1, a2]), col)
