# authoring_2d_canvas.gd
# Unified 2D Layout Canvas rendering CAD floorplan, entity blocks, and direct port connection splines.
class_name SimVizAuthoring2DCanvas
extends Control

const BlockNode := preload("res://scripts/authoring_block_node.gd")
const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const ConveyorCurve3D := preload("res://scripts/conveyor_curve_3d.gd")

signal element_selected(element_id: String)
signal connection_created(conn: SceneTypes.SceneConnection)
signal floating_properties_requested(elem_id: String, screen_pos: Vector2)

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
var _wire_rejection_reason: String = ""
var _wires_layer: Control = null
var _agents_layer: Control = null
var _active_agents: Array = []
var _live_agents: Array:
	get:
		return _active_agents
var _agent_trajectories: Dictionary = {} # agent_id -> Array[Vector2]
var _agent_target_positions: Dictionary = {} # agent_id -> Vector2
var _agent_smoothed_positions: Dictionary = {} # agent_id -> Vector2
var show_trajectories: bool = true
var show_agent_vectors: bool = false
var selected_agent_id: String = ""

func _ensure_layers() -> void:
	if _agents_layer == null:
		_agents_layer = Control.new()
		_agents_layer.name = "AgentsOverlay"
		_agents_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_agents_layer.z_index = 8
		_agents_layer.draw.connect(_on_agents_layer_draw)
		add_child(_agents_layer)

	if _wires_layer == null:
		_wires_layer = Control.new()
		_wires_layer.name = "WiresOverlay"
		_wires_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_wires_layer.z_index = 10
		_wires_layer.draw.connect(_on_wires_layer_draw)
		add_child(_wires_layer)

func _ensure_wires_layer() -> void:
	_ensure_layers()

func _redraw_all() -> void:
	queue_redraw()
	if _agents_layer != null and is_instance_valid(_agents_layer):
		_agents_layer.queue_redraw()
	if _wires_layer != null and is_instance_valid(_wires_layer):
		_wires_layer.queue_redraw()

func _process(delta: float) -> void:
	if _active_agents.is_empty():
		return
	
	var lerp_weight: float = clamp(delta * 25.0, 0.0, 1.0)
	var needs_redraw: bool = false
	for aid in _agent_target_positions.keys():
		var target: Vector2 = _agent_target_positions[aid]
		var cur: Vector2 = _agent_smoothed_positions.get(aid, target)
		var d2: float = cur.distance_squared_to(target)
		if d2 > 64.0:
			_agent_smoothed_positions[aid] = target
			needs_redraw = true
		elif d2 > 0.0001:
			_agent_smoothed_positions[aid] = cur.lerp(target, lerp_weight)
			needs_redraw = true

	if needs_redraw and _agents_layer != null and is_instance_valid(_agents_layer):
		_agents_layer.queue_redraw()

func update_agent_telemetry(agents: Array) -> void:
	_active_agents = agents
	var active_ids: Dictionary = {}

	for a in agents:
		if a is Dictionary:
			var aid: String = str(a.get("id", ""))
			if not aid.is_empty():
				active_ids[aid] = true
				var px: float = float(a.get("x", 0.0))
				var py: float = float(a.get("y", 0.0))
				if a.has("properties") and a.properties is Dictionary:
					if not a.has("x") and a.properties.has("x"): px = float(a.properties.x)
					if not a.has("y") and a.properties.has("y"): py = float(a.properties.y)
				if a.has("position") and a["position"] is Array and a["position"].size() >= 2:
					px = float(a["position"][0])
					py = float(a["position"][1])

				var target_pt := Vector2(px, py)
				_agent_target_positions[aid] = target_pt
				if not _agent_smoothed_positions.has(aid):
					_agent_smoothed_positions[aid] = target_pt

				if not _agent_trajectories.has(aid):
					_agent_trajectories[aid] = []
				var arr: Array = _agent_trajectories[aid]
				arr.append(target_pt)
				if arr.size() > 25:
					arr.pop_front()

	# Prune departed entities
	for old_id in _agent_smoothed_positions.keys():
		if not active_ids.has(old_id):
			_agent_smoothed_positions.erase(old_id)
			_agent_target_positions.erase(old_id)
			_agent_trajectories.erase(old_id)

func update_element_telemetry(elements_by_id: Dictionary) -> void:
	for elem_id in _block_nodes.keys():
		var node = _block_nodes[elem_id]
		if is_instance_valid(node) and elements_by_id.has(elem_id):
			var elem_data = elements_by_id[elem_id]
			if elem_data is Dictionary:
				var metrics: Dictionary = elem_data.get("metrics", elem_data.get("custom_metrics", {}))
				node.set_live_metrics(metrics)

	# Route signal connections to instrumentation scope blocks
	if doc_store != null and doc_store.active_document != null:
		for conn in doc_store.active_document.connections:
			var src_id: String = str(conn.source_element)
			var src_port: String = str(conn.source_port)
			var tgt_id: String = str(conn.target_element)
			var tgt_port: String = str(conn.target_port)

			if elements_by_id.has(src_id) and _block_nodes.has(tgt_id):
				var src_elem = elements_by_id[src_id]
				var src_metrics: Dictionary = src_elem.get("metrics", src_elem.get("custom_metrics", {}))
				var val: float = 0.0

				if src_port in ["length", "queue_length", "q_len"]:
					val = float(src_metrics.get("queue_length", src_metrics.get("length", 0.0)))
				elif src_port in ["occupancy", "occupancy_pct"]:
					val = float(src_metrics.get("occupancy_pct", src_metrics.get("queue_length", 0.0)))
				elif src_port in ["utilization", "util", "busy"]:
					var raw_u = float(src_metrics.get("utilization_pct", src_metrics.get("utilization", 0.0)))
					val = raw_u if raw_u > 1.0 else (raw_u * 100.0)
				elif src_port in ["wait_time", "wait_mean", "wait_mean_wq"]:
					val = float(src_metrics.get("wait_mean_wq", src_metrics.get("wait_time", 0.0)))
				elif src_port in ["in_transit", "transit_count", "items_in_transit"]:
					val = float(src_metrics.get("items_in_transit", src_metrics.get("in_transit", 0.0)))
				elif src_port in ["completed_count", "departures", "exited_total"]:
					val = float(src_metrics.get("completed_count", src_metrics.get("exited_total", 0.0)))
				elif src_port in ["spawned_count", "generation_count"]:
					val = float(src_metrics.get("spawned_count", src_metrics.get("generation_count", 0.0)))
				elif src_metrics.has(src_port):
					val = float(src_metrics[src_port])

				var tgt_node = _block_nodes[tgt_id]
				if is_instance_valid(tgt_node) and tgt_node.has_method("feed_signal_value"):
					tgt_node.feed_signal_value(tgt_port, val)

	if _agents_layer != null and is_instance_valid(_agents_layer):
		_agents_layer.queue_redraw()

func _init(p_store: DocumentStore = null) -> void:
	doc_store = p_store
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_ensure_layers()

func _ready() -> void:
	_ensure_layers()
	if doc_store != null:
		doc_store.document_loaded.connect(_on_document_reloaded)
		doc_store.document_modified.connect(_on_document_modified)
		doc_store.selection_changed.connect(_on_selection_changed)
		doc_store.scope_changed.connect(func(_sid, _sname): rebuild_blocks())
		doc_store.subgraphs_modified.connect(func(): rebuild_blocks())
		rebuild_blocks()

func rebuild_blocks() -> void:
	_ensure_layers()
	for child in get_children():
		if child == _wires_layer or child == _agents_layer:
			continue
		child.queue_free()
	_block_nodes.clear()

	if doc_store == null or doc_store.active_document == null:
		_redraw_all()
		return

	# 1. Scoped Elements
	for elem in doc_store.get_scoped_elements():
		var b := BlockNode.new(elem, null)
		add_child(b)
		_block_nodes[elem.id] = b

		var gpos := _compute_element_graph_position(elem, b)
		b.position = pan_offset + (gpos * zoom_level)
		b.scale = Vector2(zoom_level, zoom_level)

		b.block_selected.connect(_on_block_selected)
		b.block_moved.connect(_on_block_moved)
		b.port_selected.connect(func(eid: String, pid: String):
			if doc_store != null:
				doc_store.select_port(eid, pid)
		)
		b.port_drag_started.connect(_on_port_drag_started)
		b.add_port_requested.connect(_on_add_port_requested)
		b.remove_port_requested.connect(_on_remove_port_requested)
		b.disconnect_port_requested.connect(_on_disconnect_port_requested)
		b.floating_properties_requested.connect(func(eid: String, spos: Vector2):
			floating_properties_requested.emit(eid, spos)
		)
		b.element_resized.connect(func(_eid: String, _dims: Vector3):
			_redraw_all()
		)
		b.element_resize_committed.connect(func(eid: String, dims: Vector3):
			if doc_store != null:
				var target_elem := doc_store.get_element(eid)
				if target_elem != null and target_elem.transform != null:
					var orig_dims: Vector3 = b._resize_start_dims
					var orig_pos: Vector3 = b._resize_start_elem_pos
					doc_store.update_element_geometry_and_position(eid, dims, target_elem.transform.position, orig_dims, orig_pos)
				else:
					doc_store.update_element_geometry(eid, dims)
		)

	# 2. Scoped Subgraphs (Compound nodes)
	for sub in doc_store.get_scoped_subgraphs():
		var b := BlockNode.new(null, sub)
		add_child(b)
		_block_nodes[sub.id] = b

		var gx: float = sub.editor.graph_position.x if sub.editor != null and sub.editor.graph_position != Vector2.ZERO else float(sub.transform.position.x) * 20.0
		var gy: float = sub.editor.graph_position.y if sub.editor != null and sub.editor.graph_position != Vector2.ZERO else float(sub.transform.position.y) * 20.0
		b.position = pan_offset + (Vector2(gx, gy) * zoom_level)
		b.scale = Vector2(zoom_level, zoom_level)

		b.block_selected.connect(_on_block_selected)
		b.block_moved.connect(_on_block_moved)
		b.port_selected.connect(func(eid: String, pid: String):
			if doc_store != null:
				doc_store.select_port(eid, pid)
		)
		b.port_drag_started.connect(_on_port_drag_started)
		b.subgraph_drilldown_requested.connect(func(sid: String):
			if doc_store != null:
				doc_store.enter_subgraph_scope(sid)
		)
		b.disconnect_port_requested.connect(_on_disconnect_port_requested)
		b.floating_properties_requested.connect(func(eid: String, spos: Vector2):
			floating_properties_requested.emit(eid, spos)
		)
		b.element_resized.connect(func(_eid: String, _dims: Vector3):
			_redraw_all()
		)
		b.element_resize_committed.connect(func(eid: String, dims: Vector3):
			if doc_store != null:
				var target_sub := doc_store.get_subgraph(eid)
				if target_sub != null and target_sub.transform != null:
					var orig_dims: Vector3 = b._resize_start_dims
					var orig_pos: Vector3 = b._resize_start_elem_pos
					doc_store.update_subgraph_geometry_and_position(eid, dims, target_sub.transform.position, orig_dims, orig_pos)
				else:
					doc_store.set_subgraph_dimensions(eid, dims)
		)

	move_child(_wires_layer, -1)
	_redraw_all()

func _is_curved_or_joined_conveyor_elem(elem: SceneTypes.SceneElement) -> bool:
	if elem == null or elem.kind != "conveyor":
		return false
	if elem.geometry.has("inlet_pose") or elem.geometry.has("outlet_pose"):
		return true
	var preset: String = str(elem.geometry.get("shape_preset", "straight")).to_lower()
	return preset != "straight" and not preset.is_empty()

func _compute_element_graph_position(elem: SceneTypes.SceneElement, b: BlockNode) -> Vector2:
	if _is_curved_or_joined_conveyor_elem(elem):
		var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 20)
		if pts_m.size() >= 2:
			var mid_idx: int = pts_m.size() / 2
			var mid_m: Vector2 = pts_m[mid_idx]
			var p_prev: Vector2 = pts_m[max(0, mid_idx - 1)]
			var p_next: Vector2 = pts_m[min(pts_m.size() - 1, mid_idx + 1)]
			var tan_v: Vector2 = (p_next - p_prev)
			if tan_v.length_squared() > 1e-6:
				tan_v = tan_v.normalized()
			else:
				tan_v = Vector2(1.0, 0.0)
			var norm_v := Vector2(tan_v.y, -tan_v.x)
			var offset_px: Vector2 = norm_v * 38.0 - (b.size * 0.5)
			return (mid_m * 20.0) + offset_px
	var gx: float = elem.editor.graph_position.x if elem.editor.graph_position != Vector2.ZERO else float(elem.transform.position[0]) * 20.0
	var gy: float = elem.editor.graph_position.y if elem.editor.graph_position != Vector2.ZERO else float(elem.transform.position[1]) * 20.0
	return Vector2(gx, gy)

func _translate_conveyor_poses(elem: SceneTypes.SceneElement, dx: float, dy: float) -> void:
	if elem == null or elem.kind != "conveyor":
		return
	for pose_key in ["inlet_pose", "outlet_pose"]:
		if elem.geometry.has(pose_key) and elem.geometry[pose_key] is Dictionary:
			var pd: Dictionary = elem.geometry[pose_key]
			if pd.has("position") and pd["position"] is Array and pd["position"].size() >= 2:
				var pos_arr: Array = pd["position"]
				pos_arr[0] = float(pos_arr[0]) + dx
				pos_arr[1] = float(pos_arr[1]) + dy

func _on_document_reloaded(_doc: SceneTypes.SceneDocument) -> void:
	rebuild_blocks()

func _on_document_modified() -> void:
	for b in _block_nodes.values():
		b.refresh_from_element()
	_update_blocks_transform()
	_redraw_all()

func _update_blocks_transform() -> void:
	for id_val in _block_nodes.keys():
		var b: BlockNode = _block_nodes[id_val]
		var gpos := Vector2.ZERO
		if b.element != null:
			gpos = _compute_element_graph_position(b.element, b)
		elif b.subgraph != null:
			var gx: float = b.subgraph.editor.graph_position.x if b.subgraph.editor != null and b.subgraph.editor.graph_position != Vector2.ZERO else float(b.subgraph.transform.position.x) * 20.0
			var gy: float = b.subgraph.editor.graph_position.y if b.subgraph.editor != null and b.subgraph.editor.graph_position != Vector2.ZERO else float(b.subgraph.transform.position.y) * 20.0
			gpos = Vector2(gx, gy)
		b.position = pan_offset + (gpos * zoom_level)
		b.scale = Vector2(zoom_level, zoom_level)

func _on_selection_changed(sel_id: String, _sel_type: String) -> void:
	for id_val in _block_nodes.keys():
		var is_primary: bool = (id_val == sel_id)
		var is_multi: bool = (doc_store != null and doc_store.is_element_selected(id_val))
		_block_nodes[id_val].set_selected(is_primary, is_multi)
	_redraw_all()

func _on_block_selected(elem_id: String) -> void:
	if doc_store != null:
		var is_sub := (doc_store.get_subgraph(elem_id) != null)
		var type_val := "subgraph" if is_sub else "element"
		if Input.is_key_pressed(KEY_SHIFT):
			doc_store.toggle_select_element(elem_id)
		else:
			doc_store.select(elem_id, type_val)
	element_selected.emit(elem_id)

func _on_block_moved(elem_id: String, new_pos: Vector2) -> void:
	if not new_pos.is_finite():
		return
	var elem := doc_store.get_element(elem_id)
	var sub := doc_store.get_subgraph(elem_id) if elem == null else null
	if elem != null:
		var prev_x: float = float(elem.transform.position[0])
		var prev_y: float = float(elem.transform.position[1])

		var unscaled: Vector2 = (new_pos - pan_offset) / max(zoom_level, 0.01)
		var target_x: float = clamp(snapped(unscaled.x / 20.0, 0.05), -500.0, 500.0)
		var target_y: float = clamp(snapped(unscaled.y / 20.0, 0.05), -500.0, 500.0)

		var dims := _get_elem_dims(elem)
		var snap_dist := 0.35

		if doc_store != null and doc_store.active_document != null and not _is_curved_or_joined_conveyor_elem(elem):
			for other in doc_store.active_document.elements:
				if other.id == elem_id or (doc_store.is_element_selected(other.id) and doc_store.selected_elements.size() > 1):
					continue
				var ox: float = float(other.transform.position[0])
				var oy: float = float(other.transform.position[1])
				var odims := _get_elem_dims(other)

				var y_overlap: bool = (target_y < oy + odims.y + 0.5) and (target_y + dims.y > oy - 0.5)
				if y_overlap:
					if abs(target_x - (ox + odims.x)) < snap_dist:
						target_x = ox + odims.x
					elif abs((target_x + dims.x) - ox) < snap_dist:
						target_x = ox - dims.x

					if abs(target_y - oy) < snap_dist:
						target_y = oy

		var delta_x := target_x - prev_x
		var delta_y := target_y - prev_y

		elem.transform.position.x = target_x
		elem.transform.position.y = target_y
		elem.editor.graph_position = Vector2(target_x * 20.0, target_y * 20.0)
		_translate_conveyor_poses(elem, delta_x, delta_y)

		if _block_nodes.has(elem_id):
			var b_node: BlockNode = _block_nodes[elem_id]
			b_node.position = pan_offset + (_compute_element_graph_position(elem, b_node) * zoom_level)

		if doc_store != null and doc_store.is_element_selected(elem_id) and doc_store.selected_elements.size() > 1:
			for other_id in doc_store.selected_elements:
				if other_id == elem_id:
					continue
				var other := doc_store.get_element(other_id)
				if other != null:
					other.transform.position.x = snapped(other.transform.position.x + delta_x, 0.05)
					other.transform.position.y = snapped(other.transform.position.y + delta_y, 0.05)
					other.editor.graph_position = Vector2(other.transform.position.x * 20.0, other.transform.position.y * 20.0)
					_translate_conveyor_poses(other, delta_x, delta_y)
					if _block_nodes.has(other_id):
						var ob_node: BlockNode = _block_nodes[other_id]
						ob_node.position = pan_offset + (_compute_element_graph_position(other, ob_node) * zoom_level)

		if doc_store != null:
			doc_store.is_dirty = true
			doc_store.validate()
			doc_store.document_modified.emit()
		_redraw_all()
	elif sub != null:
		var prev_x: float = float(sub.transform.position.x)
		var prev_y: float = float(sub.transform.position.y)
		var unscaled: Vector2 = (new_pos - pan_offset) / max(zoom_level, 0.01)
		var target_x: float = clamp(snapped(unscaled.x / 20.0, 0.05), -500.0, 500.0)
		var target_y: float = clamp(snapped(unscaled.y / 20.0, 0.05), -500.0, 500.0)
		var delta_x: float = target_x - prev_x
		var delta_y: float = target_y - prev_y
		sub.transform.position.x = target_x
		sub.transform.position.y = target_y
		sub.editor.graph_position = Vector2(target_x * 20.0, target_y * 20.0)
		if _block_nodes.has(elem_id):
			_block_nodes[elem_id].position = pan_offset + (sub.editor.graph_position * zoom_level)
		if doc_store != null:
			for eid in sub.elements:
				var m_elem := doc_store.get_element(str(eid))
				if m_elem != null:
					m_elem.transform.position.x += delta_x
					m_elem.transform.position.y += delta_y
					m_elem.editor.graph_position = Vector2(m_elem.transform.position.x * 20.0, m_elem.transform.position.y * 20.0)
			doc_store.is_dirty = true
			doc_store.validate()
			doc_store.document_modified.emit()
		_redraw_all()

func _get_elem_dims(elem: SceneTypes.SceneElement) -> Vector3:
	if elem != null and elem.geometry.has("dimensions"):
		var d = elem.geometry["dimensions"]
		if d is Array and d.size() >= 3:
			return Vector3(float(d[0]), float(d[1]), float(d[2]))
	return Vector3(4.0, 2.0, 1.0)

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

var _force_text_focus_for_test: bool = false

func _is_text_input_focused() -> bool:
	if _force_text_focus_for_test:
		return true
	if not is_inside_tree():
		return false
	var vp := get_viewport()
	if vp == null:
		return false
	var focus_owner := vp.gui_get_focus_owner()
	if focus_owner == null:
		return false
	return (focus_owner is LineEdit) or (focus_owner is TextEdit) or (focus_owner is CodeEdit) or (focus_owner is SpinBox)

func _handle_key_input(ik: InputEventKey) -> void:
	if not ik.pressed or ik.echo:
		return
	if _is_text_input_focused():
		return

	if ik.keycode == KEY_ESCAPE:
		if _is_dragging_wire:
			_cancel_wire_drag()
			if is_inside_tree() and get_viewport() != null:
				get_viewport().set_input_as_handled()
		elif doc_store != null and (doc_store.selected_type == "connection" or doc_store.selected_type == "element" or doc_store.selected_type == "subgraph"):
			doc_store.clear_selection()
			_redraw_all()
			if is_inside_tree() and get_viewport() != null:
				get_viewport().set_input_as_handled()

	elif ik.keycode in [KEY_DELETE, KEY_BACKSPACE]:
		if doc_store != null:
			if doc_store.selected_type == "connection" and not doc_store.selected_id.is_empty():
				doc_store.remove_connection(doc_store.selected_id)
				_redraw_all()
				if is_inside_tree() and get_viewport() != null:
					get_viewport().set_input_as_handled()
			elif doc_store.selected_type == "element":
				if doc_store.selected_elements.size() > 1:
					doc_store.remove_elements(doc_store.selected_elements)
				elif not doc_store.selected_id.is_empty():
					doc_store.remove_element(doc_store.selected_id)
				rebuild_blocks()
				if is_inside_tree() and get_viewport() != null:
					get_viewport().set_input_as_handled()

	elif ik.keycode == KEY_D and (ik.ctrl_pressed or ik.meta_pressed):
		if doc_store != null and doc_store.selected_type == "element" and not doc_store.selected_id.is_empty():
			doc_store.duplicate_element(doc_store.selected_id)
			rebuild_blocks()
			if is_inside_tree() and get_viewport() != null:
				get_viewport().set_input_as_handled()

	elif ik.keycode == KEY_R and not (ik.ctrl_pressed or ik.meta_pressed):
		if doc_store != null and doc_store.selected_type == "element" and not doc_store.selected_id.is_empty():
			var delta: float = 15.0 if ik.shift_pressed else 45.0
			doc_store.rotate_element(doc_store.selected_id, delta)
			if is_inside_tree() and get_viewport() != null:
				get_viewport().set_input_as_handled()

	elif ik.keycode == KEY_F and not (ik.ctrl_pressed or ik.meta_pressed):
		frame_all()
		if is_inside_tree() and get_viewport() != null:
			get_viewport().set_input_as_handled()

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		_handle_key_input(event as InputEventKey)
		return

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
		var lpos: Vector2 = b.get_transform().affine_inverse() * canvas_mouse
		var hit_pid: String = b._hit_test_port(lpos)
		if not hit_pid.is_empty():
			var p_info: Dictionary = b.get_port_info(hit_pid)
			var tgt_kind: String = str(p_info.get("kind", ""))
			var tgt_is_out: bool = bool(p_info.get("is_output", false))

			var s_kind := _wire_source_kind
			var s_is_out := _wire_source_is_output
			var t_kind := tgt_kind
			var t_is_out := tgt_is_out

			# Normalize: emitter (out) -> receiver (in)
			var emitter_kind: String = s_kind if s_is_out else t_kind
			var receiver_kind: String = t_kind if s_is_out else s_kind
			var receiver_elem: String = str(eid) if s_is_out else _wire_source_elem
			var receiver_port: String = str(hit_pid) if s_is_out else _wire_source_port
			var receiver_card: String = str(p_info.get("cardinality", "many"))

			if s_is_out == t_is_out:
				_wire_is_compatible = false
				_wire_rejection_reason = "Cannot connect %s" % ("output to output" if s_is_out else "input to input")
			else:
				var is_kind_compatible := false
				if emitter_kind == receiver_kind:
					is_kind_compatible = true
				elif emitter_kind == "metric" and receiver_kind in ["signal", "control"]:
					is_kind_compatible = true
				elif emitter_kind == "signal" and receiver_kind in ["signal", "control"]:
					is_kind_compatible = true
				elif emitter_kind == "event" and receiver_kind in ["event", "control"]:
					is_kind_compatible = true
				elif emitter_kind == "control" and receiver_kind == "control":
					is_kind_compatible = true

				if not is_kind_compatible:
					_wire_is_compatible = false
					_wire_rejection_reason = "Incompatible kinds: %s → %s" % [emitter_kind, receiver_kind]
				else:
					# Check cardinality="one"
					var is_occupied := false
					if receiver_card == "one" and doc_store != null and doc_store.active_document != null:
						for c in doc_store.active_document.connections:
							if c.target_element == receiver_elem and c.target_port == receiver_port:
								is_occupied = true
								break
					if is_occupied:
						_wire_is_compatible = false
						_wire_rejection_reason = "Port already connected (cardinality: one)"
					else:
						_wire_is_compatible = true
						_wire_rejection_reason = ""

			_wire_hovered_elem = eid
			_wire_hovered_port = hit_pid
			# Snap endpoint to target socket center
			_wire_current_mouse = b.get_port_canvas_position(hit_pid)
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

func start_wire_drag(src_elem: String, src_port: String, src_kind: String, src_is_output: bool, start_pos: Vector2) -> void:
	_on_port_drag_started(src_elem, src_port, src_kind, src_is_output, start_pos)

func update_wire_hover_at(pos: Vector2) -> void:
	_wire_current_mouse = pos
	_update_wire_hover()

func finish_wire_drag() -> void:
	_finish_wire_drag()

func _cancel_wire_drag() -> void:
	for b in _block_nodes.values():
		b.set_hovered_port("")
	_is_dragging_wire = false
	_wire_hovered_elem = ""
	_wire_hovered_port = ""
	_wire_is_compatible = false
	_wire_rejection_reason = ""
	_redraw_all()

func _create_connection(src_e: String, src_p: String, src_kind: String, src_is_out: bool, tgt_e: String, tgt_p: String) -> void:
	var from_elem := src_e
	var from_port := src_p
	var to_elem := tgt_e
	var to_port := tgt_p

	# Normalize direction: source is output, target is input
	if not src_is_out:
		from_elem = tgt_e
		from_port = tgt_p
		to_elem = src_e
		to_port = src_p

	var link_type := "flow"
	if src_kind == "flow":
		link_type = "flow"
	elif src_kind in ["event"]:
		link_type = "event"
	elif src_kind in ["control"]:
		link_type = "control"
	else:
		link_type = "signal"

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
			var hit_track := _hit_test_conveyor_track(mb.position)
			if not hit_track.is_empty():
				if mb.double_click:
					_on_block_selected(hit_track)
					var spos: Vector2 = mb.global_position if mb.global_position != Vector2.ZERO else mb.position
					floating_properties_requested.emit(hit_track, spos)
				else:
					_on_block_selected(hit_track)
				_redraw_all()
				accept_event()
				return

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
			var hit_track := _hit_test_conveyor_track(mb.position)
			if not hit_track.is_empty():
				_on_block_selected(hit_track)
				var spos: Vector2 = mb.global_position if mb.global_position != Vector2.ZERO else mb.position
				floating_properties_requested.emit(hit_track, spos)
				_redraw_all()
				accept_event()
				return

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

func frame_all() -> void:
	if doc_store == null or doc_store.active_document == null:
		pan_offset = Vector2(40.0, 40.0)
		zoom_level = 1.0
		_update_blocks_transform()
		_redraw_all()
		return

	var elems = doc_store.active_document.elements
	if elems.is_empty():
		pan_offset = Vector2(40.0, 40.0)
		zoom_level = 1.0
		_update_blocks_transform()
		_redraw_all()
		return

	var min_p := Vector2(1e9, 1e9)
	var max_p := Vector2(-1e9, -1e9)

	for elem in elems:
		var px: float = float(elem.transform.position[0]) * 20.0
		var py: float = float(elem.transform.position[1]) * 20.0
		var dims: Vector3 = _get_elem_dims(elem)
		var pw: float = dims.x * 20.0
		var ph: float = dims.y * 20.0
		min_p.x = min(min_p.x, px)
		min_p.y = min(min_p.y, py)
		max_p.x = max(max_p.x, px + pw)
		max_p.y = max(max_p.y, py + ph)
		if elem.kind == "conveyor":
			var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 16)
			for pt_m in pts_m:
				var c_px := pt_m * 20.0
				min_p.x = min(min_p.x, c_px.x - 40.0)
				min_p.y = min(min_p.y, c_px.y - 40.0)
				max_p.x = max(max_p.x, c_px.x + 40.0)
				max_p.y = max(max_p.y, c_px.y + 40.0)

	var span := max_p - min_p
	span.x = max(span.x, 100.0)
	span.y = max(span.y, 100.0)

	var avail_size := size if size.x > 50 and size.y > 50 else Vector2(800, 600)
	var margin := 80.0
	var scale_x: float = (avail_size.x - margin * 2.0) / span.x
	var scale_y: float = (avail_size.y - margin * 2.0) / span.y
	zoom_level = clamp(min(scale_x, scale_y), 0.25, 2.5)

	var center := (min_p + max_p) * 0.5
	pan_offset = (avail_size * 0.5) - (center * zoom_level)

	_update_blocks_transform()
	_redraw_all()

func auto_layout_dag() -> void:
	if doc_store != null:
		doc_store.auto_layout_dag()
		_update_blocks_transform()
		frame_all()
		_redraw_all()

func _draw() -> void:
	# 1. Background Fill
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR, true)

	# 2. CAD Floorplan Grid & Architectural Walls
	_draw_cad_background()

	# 3. Joined & Curved Conveyor Belt Tracks
	_draw_conveyor_tracks()

func _draw_conveyor_tracks() -> void:
	if doc_store == null or doc_store.active_document == null:
		return

	var m_scale: float = 20.0 * zoom_level
	for elem in doc_store.get_scoped_elements():
		if elem.kind != "conveyor":
			continue

		var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 36)
		if pts_m.size() < 2:
			continue

		var pts_px := PackedVector2Array()
		for pm in pts_m:
			pts_px.append(pan_offset + pm * m_scale)

		var dims := _get_elem_dims(elem)
		var belt_w_px: float = clampf(dims.y * 12.0 * zoom_level, 10.0, 30.0)
		var half_w: float = belt_w_px * 0.5
		var is_sel: bool = (doc_store.selected_id == elem.id) or doc_store.is_element_selected(elem.id)

		# Compute left & right rail polylines and local normals/tangents
		var left_px := PackedVector2Array()
		var right_px := PackedVector2Array()
		var tangents := PackedVector2Array()
		var n_pts: int = pts_px.size()

		for i in range(n_pts):
			var p_prev: Vector2 = pts_px[max(0, i - 1)]
			var p_next: Vector2 = pts_px[min(n_pts - 1, i + 1)]
			var d_vec: Vector2 = p_next - p_prev
			var t_dir: Vector2 = d_vec.normalized() if d_vec.length_squared() > 1e-6 else Vector2(1.0, 0.0)
			var n_dir := Vector2(-t_dir.y, t_dir.x)
			tangents.append(t_dir)
			left_px.append(pts_px[i] + n_dir * half_w)
			right_px.append(pts_px[i] - n_dir * half_w)

		# Selection halo
		if is_sel:
			draw_polyline(pts_px, Color(0.0, 0.82, 1.0, 0.25), belt_w_px + 8.0, true)

		# Rubber belt bed quad-strip
		var bed_col := Color("#172736") if is_sel else Color("#121b26")
		for i in range(n_pts - 1):
			var quad := PackedVector2Array([left_px[i], left_px[i + 1], right_px[i + 1], right_px[i]])
			draw_colored_polygon(quad, bed_col)

		# Roller crossbars along arc length
		var roller_step: float = maxf(10.0, 14.0 * zoom_level)
		var accum_px: float = 0.0
		var next_roller: float = roller_step * 0.5
		var roller_col := Color(0.22, 0.34, 0.45, 0.55)
		for i in range(n_pts - 1):
			var seg_len: float = pts_px[i].distance_to(pts_px[i + 1])
			while accum_px + seg_len >= next_roller and seg_len > 0.1:
				var f: float = clampf((next_roller - accum_px) / seg_len, 0.0, 1.0)
				var lp: Vector2 = left_px[i].lerp(left_px[i + 1], f)
				var rp: Vector2 = right_px[i].lerp(right_px[i + 1], f)
				draw_line(lp, rp, roller_col, 1.0)
				next_roller += roller_step
			accum_px += seg_len

		# Left & Right Steel Side Rails
		var rail_col := Color("#52c7a5") if is_sel else Color("#2a9d8f")
		var rail_w: float = clampf(2.0 * zoom_level, 1.4, 3.2)
		draw_polyline(left_px, rail_col, rail_w, true)
		draw_polyline(right_px, rail_col, rail_w, true)

		# Directional Flow Chevrons (>>>) pointing strictly along curve tangent
		var chev_step: float = maxf(22.0, 32.0 * zoom_level)
		var chev_accum: float = 0.0
		var next_chev: float = chev_step * 0.45
		var chev_size: float = clampf(belt_w_px * 0.30, 3.5, 8.5)
		var chev_col := Color(0.18, 0.85, 0.48, 0.90)
		for i in range(n_pts - 1):
			var seg_len: float = pts_px[i].distance_to(pts_px[i + 1])
			while chev_accum + seg_len >= next_chev and seg_len > 0.1:
				var f: float = clampf((next_chev - chev_accum) / seg_len, 0.0, 1.0)
				var cp: Vector2 = pts_px[i].lerp(pts_px[i + 1], f)
				var t_dir: Vector2 = tangents[i].lerp(tangents[i + 1], f).normalized()
				var n_dir := Vector2(-t_dir.y, t_dir.x)
				var tip: Vector2 = cp + t_dir * (chev_size * 0.7)
				var wing_l: Vector2 = cp - t_dir * (chev_size * 0.6) + n_dir * chev_size
				var wing_r: Vector2 = cp - t_dir * (chev_size * 0.6) - n_dir * chev_size
				draw_polyline(PackedVector2Array([wing_l, tip, wing_r]), chev_col, clampf(1.8 * zoom_level, 1.2, 2.6), true)
				next_chev += chev_step
			chev_accum += seg_len

		# Transfer Hub Coupler Rings at Inlet (pts_px[0]) and Outlet (pts_px[-1])
		var hub_r: float = clampf(belt_w_px * 0.42, 4.5, 11.0)
		for endpoint in [pts_px[0], pts_px[n_pts - 1]]:
			draw_circle(endpoint, hub_r, Color("#0d1822"))
			draw_arc(endpoint, hub_r, 0.0, TAU, 18, rail_col, 1.6)
			draw_circle(endpoint, hub_r * 0.38, Color("#2ecc71"))

		# Subtle leader line connecting curved track midpoint to its offset control badge
		if _is_curved_or_joined_conveyor_elem(elem) and _block_nodes.has(elem.id):
			var b_node: BlockNode = _block_nodes[elem.id]
			if is_instance_valid(b_node):
				var mid_px: Vector2 = pts_px[n_pts / 2]
				var badge_center: Vector2 = b_node.position + (b_node.size * 0.5) * zoom_level
				var leader_col := Color(0.32, 0.78, 0.65, 0.65) if is_sel else Color(0.25, 0.45, 0.55, 0.45)
				draw_line(mid_px, badge_center, leader_col, 1.2)
				draw_circle(mid_px, 3.0, rail_col)

func _hit_test_conveyor_track(canvas_mouse: Vector2) -> String:
	if doc_store == null or doc_store.active_document == null:
		return ""
	var m_scale: float = 20.0 * zoom_level
	var best_id := ""
	var best_dist := 1e9
	for elem in doc_store.get_scoped_elements():
		if not _is_curved_or_joined_conveyor_elem(elem):
			continue
		var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 28)
		if pts_m.size() < 2:
			continue
		var dims := _get_elem_dims(elem)
		var hit_tol: float = clampf(dims.y * 12.0 * zoom_level * 0.6, 8.0, 20.0)
		for i in range(pts_m.size() - 1):
			var a := pan_offset + pts_m[i] * m_scale
			var b := pan_offset + pts_m[i + 1] * m_scale
			var d := _dist_to_segment(canvas_mouse, a, b)
			if d <= hit_tol and d < best_dist:
				best_dist = d
				best_id = elem.id
	return best_id

func _on_agents_layer_draw() -> void:
	if _agents_layer == null or _active_agents.is_empty():
		return

	var m_scale: float = 20.0 * zoom_level

	for agent in _active_agents:
		if not (agent is Dictionary):
			continue
		var aid: String = str(agent.get("id", ""))
		var raw_pos = agent.get("position", [0.0, 0.0])
		var px: float = 0.0
		var py: float = 0.0
		if not aid.is_empty() and _agent_smoothed_positions.has(aid):
			var spos: Vector2 = _agent_smoothed_positions[aid]
			px = spos.x
			py = spos.y
		elif agent.has("x") and agent.has("y"):
			px = float(agent["x"])
			py = float(agent["y"])
		elif agent.has("properties") and agent.properties is Dictionary and agent.properties.has("x") and agent.properties.has("y"):
			px = float(agent.properties.x)
			py = float(agent.properties.y)
		elif raw_pos is Array and raw_pos.size() >= 2:
			px = float(raw_pos[0])
			py = float(raw_pos[1])
		elif raw_pos is Vector2 or raw_pos is Vector3:
			px = raw_pos.x
			py = raw_pos.y

		var canvas_pos := pan_offset + Vector2(px, py) * m_scale
		var kind: String = str(agent.get("kind", "product"))
		var is_product: bool = (kind == "product" or kind == "carton" or kind == "item")
		var in_service: bool = false
		var zone_kind: String = ""
		var props: Dictionary = {}
		if agent.has("properties") and agent.properties is Dictionary:
			props = agent.properties
			in_service = bool(props.get("in_service", false))
			zone_kind = str(props.get("zone_kind", ""))

		var vel = agent.get("velocity", [0.0, 0.0])
		var vx: float = 0.0
		var vy: float = 0.0
		if agent.has("vx") and agent.has("vy"):
			vx = float(agent["vx"])
			vy = float(agent["vy"])
		elif vel is Array and vel.size() >= 2:
			vx = float(vel[0])
			vy = float(vel[1])
		elif vel is Vector2 or vel is Vector3:
			vx = vel.x
			vy = vel.y

		# B-2/B-3: DES product entities — physical rect rendering ─────────────
		if is_product:
			# Product dimensions (sim-metres) clamped to pixel bounds
			var prod_w_m: float = float(props.get("prod_w", 0.4))
			var prod_h_m: float = float(props.get("prod_h", 0.4))
			var w_px: float = clamp(prod_w_m * m_scale, 6.0, 20.0)
			var h_px: float = clamp(prod_h_m * m_scale, 6.0, 20.0)

			# Product color: snapshot → zone-state heuristic
			var col: Color
			if props.has("color_r"):
				col = Color(float(props.get("color_r", 0.3)),
							float(props.get("color_g", 0.75)),
							float(props.get("color_b", 1.0)), 1.0)
			elif in_service:
				col = Color("2ecc71")   # emerald — in service
			elif zone_kind == "queue":
				col = Color("00d2ff")   # cyan — waiting
			else:
				col = Color("f39c12")   # amber — conveyor / transit

			# Trajectory ribbon
			if show_trajectories and not aid.is_empty() and _agent_trajectories.has(aid):
				var t_pts: Array = _agent_trajectories[aid]
				if t_pts.size() > 1:
					var poly: PackedVector2Array = []
					for pt in t_pts:
						poly.append(pan_offset + Vector2(pt.x, pt.y) * m_scale)
					_agents_layer.draw_polyline(poly, Color(col.r, col.g, col.b, 0.35), 1.5, true)

			var heading_rad: float = atan2(vy, vx) if (vx * vx + vy * vy > 0.001) else 0.0
			_draw_product_entity(_agents_layer, canvas_pos, w_px, h_px, col, in_service, zone_kind, heading_rad)

			if aid == selected_agent_id and not aid.is_empty():
				var r_sel: float = max(w_px, h_px) * 0.5 + 3.0
				_agents_layer.draw_arc(canvas_pos, r_sel, 0.0, TAU, 24, Color("00d2ff"), 2.0)
			continue  # skip legacy crowd-sim path

		# Legacy crowd-sim / ABM pedestrian rendering ─────────────────────────
		var r_body: float = float(agent.get("r_body", agent.get("radius", 0.20)))
		var r_px: float = max(r_body * m_scale, 4.0)

		var speed: float = sqrt(vx * vx + vy * vy)
		var state: String = str(agent.get("state", "walking"))

		var col_ped: Color = Color("2ecc71")
		if state == "queuing":
			col_ped = Color("3498db")
		elif speed < 0.35:
			col_ped = Color("e74c3c")
		elif speed < 1.0:
			col_ped = Color("f1c40f")

		if show_trajectories:
			var t_points: PackedVector2Array = []
			if agent.has("trajectory") and agent["trajectory"] is Array and agent["trajectory"].size() > 1:
				for tp in agent["trajectory"]:
					if tp is Array and tp.size() >= 2:
						t_points.append(pan_offset + Vector2(float(tp[0]), float(tp[1])) * m_scale)
					elif tp is Vector2:
						t_points.append(pan_offset + tp * m_scale)
			elif not aid.is_empty() and _agent_trajectories.has(aid) and _agent_trajectories[aid].size() > 1:
				for pt in _agent_trajectories[aid]:
					t_points.append(pan_offset + pt * m_scale)
			if t_points.size() > 1:
				_agents_layer.draw_polyline(t_points, Color(col_ped.r, col_ped.g, col_ped.b, 0.45), 2.0, true)

		_agents_layer.draw_circle(canvas_pos, r_px, col_ped)
		_agents_layer.draw_arc(canvas_pos, r_px, 0, TAU, 16, Color(0.05, 0.08, 0.12, 0.85), 1.2)

		if speed > 0.05:
			var heading := Vector2(vx, vy).normalized()
			var tip := canvas_pos + heading * (r_px * 0.85)
			var left := canvas_pos - heading * (r_px * 0.4) + Vector2(-heading.y, heading.x) * (r_px * 0.5)
			var right := canvas_pos - heading * (r_px * 0.4) - Vector2(-heading.y, heading.x) * (r_px * 0.5)
			_agents_layer.draw_colored_polygon(PackedVector2Array([tip, left, right]), Color(0.05, 0.08, 0.12, 0.9))
		else:
			_agents_layer.draw_circle(canvas_pos, r_px * 0.4, Color(0.05, 0.08, 0.12, 0.7))

		if aid == selected_agent_id and not aid.is_empty():
			_agents_layer.draw_arc(canvas_pos, r_px + 3.0, 0, TAU, 24, Color("00d2ff"), 2.0)

## B-2: Physical product entity renderer.
## Draws a colored carton rectangle at [pos] (canvas space), oriented along [heading_rad].
func _draw_product_entity(
		layer: CanvasItem,
		pos: Vector2,
		w_px: float,
		h_px: float,
		col: Color,
		in_service: bool,
		zone_kind: String,
		heading_rad: float = 0.0
) -> void:
	var half_w := w_px * 0.5
	var half_h := h_px * 0.5
	var local_rect := Rect2(Vector2(-half_w, -half_h), Vector2(w_px, h_px))

	layer.draw_set_transform(pos, heading_rad, Vector2.ONE)

	# Drop-shadow (1 px offset, semi-transparent)
	layer.draw_rect(Rect2(local_rect.position + Vector2(1, 1), local_rect.size), Color(0, 0, 0, 0.35), true)

	# Filled body
	layer.draw_rect(local_rect, col, true)

	# Top-edge highlight for 3-D carton depth
	layer.draw_rect(Rect2(local_rect.position, Vector2(local_rect.size.x, 2.0)), Color(1.0, 1.0, 1.0, 0.25), true)

	# Outline stroke
	layer.draw_rect(local_rect, Color(0.05, 0.08, 0.12, 0.9), false, 1.0)

	layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Active-service animated glow ring (oscillates at ~1 Hz)
	if in_service or zone_kind == "server":
		var ring_alpha: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.001 * TAU)
		var r_glow: float = max(half_w, half_h) + 3.0
		layer.draw_arc(pos, r_glow, 0.0, TAU, 20, Color(0.18, 0.95, 0.47, ring_alpha), 1.8)

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

		if not _wire_is_compatible and not _wire_rejection_reason.is_empty():
			var tooltip_pos := _wire_current_mouse + Vector2(14, 14)
			var text := "🚫 " + _wire_rejection_reason
			var font := ThemeDB.fallback_font
			var font_size := 11
			var string_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
			var pad := Vector2(8, 4)
			var box_rect := Rect2(tooltip_pos, string_size + pad * 2.0)
			_wires_layer.draw_rect(box_rect, Color(0.1, 0.05, 0.05, 0.9), true)
			_wires_layer.draw_rect(box_rect, Color("#e74c3c"), false, 1.5)
			_wires_layer.draw_string(font, tooltip_pos + Vector2(pad.x, pad.y + font_size), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color("#ff8888"))

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

func _resolve_conveyor_curve_anchor(conv_elem: SceneTypes.SceneElement, other_pos_px: Vector2, is_source_end: bool) -> Vector2:
	var pts_m := ConveyorCurve3D.sample_2d_polyline(conv_elem, doc_store, 16)
	if pts_m.is_empty():
		return Vector2.ZERO
	var m_scale: float = 20.0 * zoom_level
	if other_pos_px != Vector2.ZERO:
		var best_p := pan_offset + pts_m[0] * m_scale
		var best_d2 := best_p.distance_squared_to(other_pos_px)
		for i in range(1, pts_m.size()):
			var cand_p := pan_offset + pts_m[i] * m_scale
			var d2 := cand_p.distance_squared_to(other_pos_px)
			if d2 < best_d2:
				best_d2 = d2
				best_p = cand_p
		return best_p
	return pan_offset + (pts_m[pts_m.size() - 1] if is_source_end else pts_m[0]) * m_scale

func _draw_connections() -> void:
	if doc_store == null or doc_store.active_document == null or _wires_layer == null:
		return

	var sel_conn_id := doc_store.selected_id if (doc_store != null and doc_store.selected_type == "connection") else ""
	var m_scale: float = 20.0 * zoom_level

	for conn in doc_store.active_document.connections:
		var src_elem := doc_store.get_element(conn.source_element)
		var tgt_elem := doc_store.get_element(conn.target_element)
		var is_conn_sel: bool = (str(conn.id) == sel_conn_id)

		if conn.link_type == "flow" and src_elem != null and tgt_elem != null:
			var src_curved := _is_curved_or_joined_conveyor_elem(src_elem)
			var tgt_curved := _is_curved_or_joined_conveyor_elem(tgt_elem)
			if src_curved and tgt_curved:
				var s_pts := ConveyorCurve3D.sample_2d_polyline(src_elem, doc_store, 8)
				var t_pts := ConveyorCurve3D.sample_2d_polyline(tgt_elem, doc_store, 8)
				if s_pts.size() >= 2 and t_pts.size() >= 2:
					var p_out := pan_offset + s_pts[s_pts.size() - 1] * m_scale
					var p_in := pan_offset + t_pts[0] * m_scale
					if p_out.distance_to(p_in) <= 16.0 * zoom_level:
						var j_pt := (p_out + p_in) * 0.5
						if is_conn_sel:
							_wires_layer.draw_arc(j_pt, 10.0 * zoom_level, 0.0, TAU, 20, Color("#00d2ff"), 2.5)
						continue
					else:
						var c_col := Color("#00d2ff") if is_conn_sel else FLOW_WIRE_COLOR
						_draw_spline(_wires_layer, p_out, p_in, c_col, 2.5 if is_conn_sel else 2.0, false)
						continue
			elif src_curved and not tgt_curved:
				var p2_port := _resolve_port_position(conn.target_element, conn.target_port)
				var p1_hub := _resolve_conveyor_curve_anchor(src_elem, p2_port, true)
				if p1_hub != Vector2.ZERO and p2_port != Vector2.ZERO:
					if is_conn_sel:
						_draw_spline(_wires_layer, p1_hub, p2_port, Color(0.0, 0.82, 1.0, 0.45), 6.0, false)
						_draw_spline(_wires_layer, p1_hub, p2_port, Color("#00d2ff"), 2.5, false)
					else:
						_draw_spline(_wires_layer, p1_hub, p2_port, FLOW_WIRE_COLOR, 2.0, false)
					continue
			elif tgt_curved and not src_curved:
				var p1_port := _resolve_port_position(conn.source_element, conn.source_port)
				var p2_hub := _resolve_conveyor_curve_anchor(tgt_elem, p1_port, false)
				if p1_port != Vector2.ZERO and p2_hub != Vector2.ZERO:
					if is_conn_sel:
						_draw_spline(_wires_layer, p1_port, p2_hub, Color(0.0, 0.82, 1.0, 0.45), 6.0, false)
						_draw_spline(_wires_layer, p1_port, p2_hub, Color("#00d2ff"), 2.5, false)
					else:
						_draw_spline(_wires_layer, p1_port, p2_hub, FLOW_WIRE_COLOR, 2.0, false)
					continue

		var p1 := _resolve_port_position(conn.source_element, conn.source_port)
		var p2 := _resolve_port_position(conn.target_element, conn.target_port)
		if p1 != Vector2.ZERO and p2 != Vector2.ZERO:
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
		return b.get_port_canvas_position(port_id)
	return Vector2.ZERO

func _draw_spline(target: CanvasItem, from: Vector2, to: Vector2, col: Color, width: float, dashed: bool) -> void:
	if not from.is_finite() or not to.is_finite():
		return
	if from.distance_squared_to(to) < 1.0:
		return

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
		var seg_vec := to - points[points.size() - 2]
		if seg_vec.length_squared() < 1e-4:
			seg_vec = to - from
		if seg_vec.length_squared() >= 1e-4:
			var dir := seg_vec.normalized()
			var perp := Vector2(-dir.y, dir.x) * 5.0
			var a1 := to - (dir * 10.0) + perp
			var a2 := to - (dir * 10.0) - perp
			if abs((a1 - to).cross(a2 - to)) > 1.0:
				target.draw_colored_polygon(PackedVector2Array([to, a1, a2]), col)
