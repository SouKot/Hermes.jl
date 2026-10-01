# authoring_2d_canvas.gd
# Unified 2D Layout Canvas rendering CAD floorplan, entity blocks, conveyor tracks, and port connection splines (Phase 7G).
class_name SimVizAuthoring2DCanvas
extends Control

const BlockNode := preload("res://scripts/authoring_block_node.gd")
const ChannelPopup := preload("res://scripts/authoring_channel_popup.gd")
const WirePopup := preload("res://scripts/authoring_wire_popup.gd")
const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const ConveyorCurve3D := preload("res://scripts/conveyor_curve_3d.gd")
const OSWindowHost := preload("res://scripts/authoring_os_window_host.gd")

signal element_selected(element_id: String)
signal connection_created(conn: SceneTypes.SceneConnection)
signal floating_properties_requested(elem_id: String, screen_pos: Vector2)
signal wire_visibility_mode_changed(mode_int: int, mode_label: String)

enum WireVisibilityMode {
	ALL = 0,
	FOCUS = 1,
	OFF = 2
}

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
var wire_visibility_mode: int = WireVisibilityMode.ALL
var _channel_popup: ChannelPopup = null
var _wire_popup: WirePopup = null
var _hovered_channel_conn_id: String = ""
var _dragging_waypoint_conn_id: String = ""
var _dragging_waypoint_idx: int = -1

# Conveyor track dragging and interactive gizmo state
var _dragging_conveyor_elem_id: String = ""
var _conveyor_drag_prev_canvas_mouse: Vector2 = Vector2.ZERO
var _conveyor_active_gizmo_type: String = "" # "inlet", "outlet", "corner", "inflection", "spline_vertex", "midpoint_add", "width"
var _conveyor_active_gizmo_elem_id: String = ""
var _conveyor_active_gizmo_idx: int = -1
var _conveyor_geom_mode_elem_id: String = ""
var _conveyor_geometry_warning: String = ""
var _conveyor_drag_before: Dictionary = {}
var _conveyor_drag_locks: Dictionary = {}
signal conveyor_geometry_mode_changed(elem_id: String)
var _conveyor_rotation_pivot: Vector2 = Vector2.ZERO
var conveyor_rotation_pivot_mode: String = "center"
var _conveyor_rotation_accum_deg: float = 0.0
var _conveyor_rotation_applied_deg: float = 0.0

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
	if _wires_layer == null:
		_wires_layer = Control.new()
		_wires_layer.name = "WiresOverlay"
		_wires_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_wires_layer.z_index = 10
		_wires_layer.draw.connect(_on_wires_layer_draw)
		add_child(_wires_layer)

	if _agents_layer == null:
		_agents_layer = Control.new()
		_agents_layer.name = "AgentsOverlay"
		_agents_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_agents_layer.z_index = 8
		_agents_layer.draw.connect(_on_agents_layer_draw)
		add_child(_agents_layer)

	if _channel_popup == null:
		_channel_popup = ChannelPopup.new()
		_channel_popup.name = "ChannelPopup"
		_channel_popup.z_index = 50
		_channel_popup.channel_hovered.connect(func(cid: String):
			_hovered_channel_conn_id = cid
			_redraw_all()
		)
		_channel_popup.channel_deleted.connect(func(_cid: String):
			_sync_port_connection_counts()
			_redraw_all()
		)
		_channel_popup.channel_reordered.connect(func(_cid: String, _nidx: int):
			_sync_port_connection_counts()
			_redraw_all()
		)
		_channel_popup.disconnect_all_requested.connect(func(_eid: String, _pid: String):
			_sync_port_connection_counts()
			_redraw_all()
		)
		add_child(_channel_popup)
		OSWindowHost.attach(_channel_popup, "SimViz — Bus Channel Manager", Vector2i(320, 340), Vector2i(268, 200), func(): _channel_popup.close_popup(), Vector2i(180, 140))

	if _wire_popup == null:
		_wire_popup = WirePopup.new()
		_wire_popup.name = "WirePopup"
		_wire_popup.z_index = 50
		_wire_popup.wire_visual_changed.connect(func(_cid: String):
			_redraw_all()
		)
		_wire_popup.wire_deleted.connect(func(_cid: String):
			_sync_port_connection_counts()
			_redraw_all()
		)
		add_child(_wire_popup)
		OSWindowHost.attach(_wire_popup, "SimViz — Wire Shape & Appearance", Vector2i(360, 310), Vector2i(320, 240), func(): _wire_popup.close_popup(), Vector2i(220, 140))

func _ensure_wires_layer() -> void:
	_ensure_layers()

func get_wire_visibility_label() -> String:
	match wire_visibility_mode:
		WireVisibilityMode.ALL: return "All"
		WireVisibilityMode.FOCUS: return "Focus"
		WireVisibilityMode.OFF: return "Off"
		_: return "All"

func set_wire_visibility_mode(mode_val: int) -> void:
	wire_visibility_mode = posmod(mode_val, 3)
	_sync_port_connection_counts()
	wire_visibility_mode_changed.emit(wire_visibility_mode, get_wire_visibility_label())
	_redraw_all()

func cycle_wire_visibility_mode() -> int:
	set_wire_visibility_mode((wire_visibility_mode + 1) % 3)
	return wire_visibility_mode

func open_channel_popup(elem_id: String, port_id: String, is_output: bool, screen_pos: Vector2 = Vector2(120, 120)) -> void:
	_ensure_layers()
	if _channel_popup != null and doc_store != null:
		var local_pos := screen_pos
		if is_inside_tree():
			local_pos = get_global_transform().affine_inverse() * screen_pos
		_channel_popup.open_for_port(doc_store, elem_id, port_id, is_output, local_pos)
		if _channel_popup.get_parent() == self:
			move_child(_channel_popup, -1)

func get_channel_popup() -> ChannelPopup:
	_ensure_layers()
	return _channel_popup

func open_wire_popup(conn_id: String, screen_pos: Vector2 = Vector2(140, 140)) -> void:
	_ensure_layers()
	if _channel_popup != null and _channel_popup.visible:
		_channel_popup.close_popup()
	if _wire_popup != null and doc_store != null:
		var local_pos := screen_pos
		if is_inside_tree():
			local_pos = get_global_transform().affine_inverse() * screen_pos
		_wire_popup.open_for_connection(doc_store, conn_id, local_pos)
		if _wire_popup.get_parent() == self:
			move_child(_wire_popup, -1)

func get_wire_popup() -> WirePopup:
	_ensure_layers()
	return _wire_popup

func _sync_port_connection_counts() -> void:
	if doc_store == null or doc_store.active_document == null:
		for b in _block_nodes.values():
			if is_instance_valid(b):
				b.set_port_connection_counts({})
				b.set_wire_context(_is_dragging_wire, wire_visibility_mode)
		return

	var counts_by_elem: Dictionary = {}
	for conn in doc_store.active_document.connections:
		if not counts_by_elem.has(conn.source_element):
			counts_by_elem[conn.source_element] = {}
		counts_by_elem[conn.source_element][conn.source_port] = int(counts_by_elem[conn.source_element].get(conn.source_port, 0)) + 1

		if not counts_by_elem.has(conn.target_element):
			counts_by_elem[conn.target_element] = {}
		counts_by_elem[conn.target_element][conn.target_port] = int(counts_by_elem[conn.target_element].get(conn.target_port, 0)) + 1

	for eid in _block_nodes.keys():
		var b: BlockNode = _block_nodes[eid]
		if is_instance_valid(b):
			b.set_port_connection_counts(counts_by_elem.get(eid, {}))
			b.set_wire_context(_is_dragging_wire, wire_visibility_mode)

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

				var elem_id_ag: String = str(a.get("zone", ""))
				if elem_id_ag.is_empty() and a.has("properties") and a.properties is Dictionary:
					elem_id_ag = str(a.properties.get("element_id", ""))
				if not elem_id_ag.is_empty() and _block_nodes.has(elem_id_ag):
					var b_node: BlockNode = _block_nodes[elem_id_ag]
					if is_instance_valid(b_node) and b_node.element != null:
						if b_node.element.kind == "conveyor":
							if not _is_curved_or_joined_conveyor_elem(b_node.element) and is_zero_approx(b_node.rotation):
								var base_y_m: float = float(b_node.element.transform.position[1])
								var half_h_m: float = (b_node.size.y * 0.5) / 20.0
								if absf(py - base_y_m) < 0.05 or absf(py - (base_y_m + half_h_m)) < half_h_m + 0.1:
									py = base_y_m + half_h_m
						elif b_node.element.kind == "queue":
							var base_x_m: float = float(b_node.element.transform.position[0])
							var base_y_m: float = float(b_node.element.transform.position[1])
							var width_m: float = float(b_node.element.geometry.dimensions[0]) if b_node.element.geometry.dimensions.size() > 0 else 4.0
							var height_m: float = float(b_node.element.geometry.dimensions[1]) if b_node.element.geometry.dimensions.size() > 1 else 2.0
							if width_m >= height_m:
								py = base_y_m + height_m * 0.5
								px = clampf(px, base_x_m + 0.3, base_x_m + width_m - 0.3)
							else:
								px = base_x_m + width_m * 0.5
								py = clampf(py, base_y_m + 0.3, base_y_m + height_m - 0.3)

				var target_pt := Vector2(px, py)
				if _agent_target_positions.has(aid) and (_agent_target_positions[aid] as Vector2).distance_to(target_pt) > 2.0:
					_agent_smoothed_positions[aid] = target_pt
					_agent_trajectories[aid] = []
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
		if child == _wires_layer or child == _agents_layer or child == _channel_popup or child == _wire_popup:
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
		b.conveyor_geometry_mode_toggled.connect(func(eid: String):
			toggle_conveyor_geometry_mode(eid)
		)
		b.port_selected.connect(func(eid: String, pid: String):
			if doc_store != null:
				doc_store.select_port(eid, pid)
		)
		b.port_drag_started.connect(_on_port_drag_started)
		b.add_port_requested.connect(_on_add_port_requested)
		b.remove_port_requested.connect(_on_remove_port_requested)
		b.disconnect_port_requested.connect(_on_disconnect_port_requested)
		b.port_channel_popup_requested.connect(func(eid: String, pid: String, is_out: bool, spos: Vector2):
			open_channel_popup(eid, pid, is_out, spos)
		)
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
		b.port_channel_popup_requested.connect(func(eid: String, pid: String, is_out: bool, spos: Vector2):
			open_channel_popup(eid, pid, is_out, spos)
		)
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

	if _wires_layer != null and _wires_layer.get_parent() == self:
		move_child(_wires_layer, -1)
	if _agents_layer != null and _agents_layer.get_parent() == self:
		move_child(_agents_layer, -1)
	if _channel_popup != null and _channel_popup.get_parent() == self:
		move_child(_channel_popup, -1)
	if _wire_popup != null and _wire_popup.get_parent() == self:
		move_child(_wire_popup, -1)
	if not _conveyor_geom_mode_elem_id.is_empty():
		if doc_store.get_element(_conveyor_geom_mode_elem_id) == null:
			_conveyor_geom_mode_elem_id = ""
		else:
			_apply_conveyor_geometry_view()
	_sync_port_connection_counts()
	_redraw_all()

func _is_curved_or_joined_conveyor_elem(elem: SceneTypes.SceneElement) -> bool:
	if elem == null or elem.kind != "conveyor":
		return false
	var preset: String = str(elem.geometry.get("shape_preset", elem.properties.get("shape_preset", "straight"))).to_lower()
	if preset == "straight" or preset.is_empty():
		return false
	return true

func _compute_element_graph_position(elem: SceneTypes.SceneElement, b: BlockNode) -> Vector2:
	if _is_curved_or_joined_conveyor_elem(elem):
		var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 20)
		if pts_m.size() >= 2:
			var mid_idx: int = pts_m.size() / 2
			var mid_m: Vector2 = pts_m[mid_idx]
			# Place Midpoint Spine Pill directly ON the conveyor centerline midpoint (zero lateral offset!)
			return (mid_m * 20.0) - (b.size * 0.5)
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

	# Translate L-bend corner_pos if present
	var sp: Dictionary = elem.geometry.get("shape_params", {}) if (elem.geometry.get("shape_params") is Dictionary) else {}
	if sp.has("corner_pos") and sp["corner_pos"] is Array and sp["corner_pos"].size() >= 2:
		sp["corner_pos"][0] = float(sp["corner_pos"][0]) + dx
		sp["corner_pos"][1] = float(sp["corner_pos"][1]) + dy
	if elem.geometry.has("corner_pos") and elem.geometry["corner_pos"] is Array and elem.geometry["corner_pos"].size() >= 2:
		elem.geometry["corner_pos"][0] = float(elem.geometry["corner_pos"][0]) + dx
		elem.geometry["corner_pos"][1] = float(elem.geometry["corner_pos"][1]) + dy

	# Translate custom spline control_points if present
	var cpts = sp.get("control_points", [])
	if cpts is Array:
		for pt in cpts:
			if pt is Dictionary and pt.has("pos") and pt["pos"] is Array and pt["pos"].size() >= 2:
				pt["pos"][0] = float(pt["pos"][0]) + dx
				pt["pos"][1] = float(pt["pos"][1]) + dy
			elif pt is Array and pt.size() >= 2:
				pt[0] = float(pt[0]) + dx
				pt[1] = float(pt[1]) + dy

func _translate_conveyor_element(elem_id: String, dx: float, dy: float) -> void:
	if doc_store == null:
		return
	var elem := doc_store.get_element(elem_id)
	if elem == null:
		return
	var locks := ConveyorCurve3D.connected_endpoint_locks(elem_id, doc_store)
	if locks["inlet"] or locks["outlet"]:
		_conveyor_geometry_warning = "Connected conveyor: disconnect flow before moving the whole belt"
		_redraw_all()
		return
	elem.transform.position.x = snapped(elem.transform.position.x + dx, 0.05)
	elem.transform.position.y = snapped(elem.transform.position.y + dy, 0.05)
	elem.editor.graph_position = Vector2(elem.transform.position.x * 20.0, elem.transform.position.y * 20.0)
	_translate_conveyor_poses(elem, dx, dy)
	if _block_nodes.has(elem_id):
		var b: BlockNode = _block_nodes[elem_id]
		b.position = pan_offset + (_compute_element_graph_position(elem, b) * zoom_level)
	doc_store.is_dirty = true
	doc_store.document_modified.emit()

func _rotate_conveyor_element(elem_id: String, angle_deg: float, pivot: Vector2) -> void:
	if doc_store == null:
		return
	var elem := doc_store.get_element(elem_id)
	if elem == null or elem.kind != "conveyor":
		return
	var locks := ConveyorCurve3D.connected_endpoint_locks(elem_id, doc_store)
	if locks["inlet"] or locks["outlet"]:
		_conveyor_geometry_warning = "Connected conveyor: disconnect flow before rotating"
		_redraw_all()
		return
	var radians := deg_to_rad(angle_deg)
	var tr_pos := Vector2(elem.transform.position.x, elem.transform.position.y)
	tr_pos = pivot + (tr_pos - pivot).rotated(radians)
	elem.transform.position.x = tr_pos.x
	elem.transform.position.y = tr_pos.y
	elem.transform.rotation.z = fposmod(elem.transform.rotation.z + angle_deg, 360.0)
	elem.editor.graph_position = tr_pos * 20.0
	for pose_key in ["inlet_pose", "outlet_pose"]:
		var pose = elem.geometry.get(pose_key)
		if pose is Dictionary:
			var pos_arr = pose.get("position", pose.get("pos", []))
			if pos_arr is Array and pos_arr.size() >= 2:
				var xy := pivot + (Vector2(float(pos_arr[0]), float(pos_arr[1])) - pivot).rotated(radians)
				pos_arr[0] = xy.x
				pos_arr[1] = xy.y
			var tan_arr = pose.get("tangent", [])
			if tan_arr is Array and tan_arr.size() >= 2:
				var tan_xy := Vector2(float(tan_arr[0]), float(tan_arr[1])).rotated(radians)
				tan_arr[0] = tan_xy.x
				tan_arr[1] = tan_xy.y
	var sp: Dictionary = elem.geometry.get("shape_params", {}) if elem.geometry.get("shape_params") is Dictionary else {}
	for corner in [sp.get("corner_pos", []), elem.geometry.get("corner_pos", [])]:
		if corner is Array and corner.size() >= 2:
			var xy := pivot + (Vector2(float(corner[0]), float(corner[1])) - pivot).rotated(radians)
			corner[0] = xy.x
			corner[1] = xy.y
	var points = sp.get("control_points", [])
	if points is Array:
		for item in points:
			if item is Dictionary:
				for key in ["pos", "in_handle", "out_handle"]:
					var value = item.get(key, [])
					if value is Array and value.size() >= 2:
						var xy := Vector2(float(value[0]), float(value[1]))
						xy = pivot + (xy - pivot).rotated(radians) if key == "pos" else xy.rotated(radians)
						value[0] = xy.x
						value[1] = xy.y
	if _block_nodes.has(elem_id):
		var block: BlockNode = _block_nodes[elem_id]
		block.refresh_from_element()
		block.position = pan_offset + _compute_element_graph_position(elem, block) * zoom_level
	doc_store.is_dirty = true
	doc_store.document_modified.emit()

func _conveyor_pivot(elem: SceneTypes.SceneElement) -> Vector2:
	if conveyor_rotation_pivot_mode != "center":
		var baked := ConveyorCurve3D.sample_world_curve(elem, doc_store, 36)
		var end_point: Vector3 = baked["inlet_pos"] if conveyor_rotation_pivot_mode == "inlet" else baked["outlet_pos"]
		return Vector2(end_point.x, end_point.y)
	if not _is_curved_or_joined_conveyor_elem(elem):
		return _get_straight_conveyor_metrics(elem)["p_mid_m"]
	var baked := ConveyorCurve3D.sample_world_curve(elem, doc_store, 36)
	var midpoint: Vector3 = baked.get("midpoint", elem.transform.position)
	return Vector2(midpoint.x, midpoint.y)

func _finish_conveyor_geometry_edit(elem_id: String) -> bool:
	if doc_store == null:
		return false
	var elem := doc_store.get_element(elem_id)
	if elem == null:
		return false
	var diagnostics := ConveyorCurve3D.geometry_diagnostics(elem, doc_store)
	if not str(diagnostics["error"]).is_empty():
		doc_store.undo()
		rebuild_blocks()
		_conveyor_geometry_warning = diagnostics["error"]
		return false
	_conveyor_geometry_warning = str(diagnostics["warning"])
	doc_store.is_dirty = true
	doc_store.validate()
	doc_store.document_modified.emit()
	return true

func enter_conveyor_geometry_mode(elem_id: String) -> void:
	if elem_id.is_empty():
		return
	if doc_store == null or doc_store.get_element(elem_id) == null or doc_store.get_element(elem_id).kind != "conveyor":
		return
	_conveyor_geom_mode_elem_id = elem_id
	_conveyor_geometry_warning = ""
	conveyor_geometry_mode_changed.emit(elem_id)
	if doc_store != null:
		doc_store.select(elem_id, "element")
	_apply_conveyor_geometry_view()
	_redraw_all()

func _apply_conveyor_geometry_view() -> void:
	for bid in _block_nodes.keys():
		var b: BlockNode = _block_nodes[bid]
		b.is_geometry_mode_active = true
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if bid == _conveyor_geom_mode_elem_id:
			b.modulate = Color.WHITE
		else:
			b.modulate = Color(1.0, 1.0, 1.0, 0.35)
		b.queue_redraw()

func exit_conveyor_geometry_mode() -> void:
	if _conveyor_geom_mode_elem_id.is_empty():
		return
	_conveyor_geom_mode_elem_id = ""
	_conveyor_geometry_warning = ""
	conveyor_geometry_mode_changed.emit("")
	for bid in _block_nodes.keys():
		var b: BlockNode = _block_nodes[bid]
		b.is_geometry_mode_active = false
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		b.modulate = Color.WHITE
	_redraw_all()

func toggle_conveyor_geometry_mode(elem_id: String = "") -> void:
	if not _conveyor_geom_mode_elem_id.is_empty():
		if elem_id.is_empty() or elem_id == _conveyor_geom_mode_elem_id:
			exit_conveyor_geometry_mode()
		else:
			enter_conveyor_geometry_mode(elem_id)
	else:
		var target_id := elem_id
		if target_id.is_empty() and doc_store != null and doc_store.selected_type == "element":
			target_id = doc_store.selected_id
		if not target_id.is_empty():
			enter_conveyor_geometry_mode(target_id)

func is_in_conveyor_geometry_mode() -> bool:
	return not _conveyor_geom_mode_elem_id.is_empty()

func _on_document_reloaded(_doc: SceneTypes.SceneDocument) -> void:
	rebuild_blocks()

func _on_document_modified() -> void:
	for b in _block_nodes.values():
		b.refresh_from_element()
	_sync_port_connection_counts()
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
	_sync_port_connection_counts()
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
	_wire_source_pos = _resolve_port_position(elem_id, port_id) if _resolve_port_position(elem_id, port_id) != Vector2.ZERO else start_pos
	_wire_current_mouse = _wire_source_pos
	_wire_hovered_elem = ""
	_wire_hovered_port = ""
	_wire_is_compatible = false
	_sync_port_connection_counts()
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
		if not _conveyor_geom_mode_elem_id.is_empty():
			if not _conveyor_active_gizmo_type.is_empty() or not _dragging_conveyor_elem_id.is_empty():
				_conveyor_active_gizmo_type = ""
				_conveyor_active_gizmo_elem_id = ""
				_dragging_conveyor_elem_id = ""
				_conveyor_drag_before.clear()
				doc_store.undo()
				rebuild_blocks()
				_redraw_all()
				if is_inside_tree() and get_viewport() != null:
					get_viewport().set_input_as_handled()
				return
			exit_conveyor_geometry_mode()
			if is_inside_tree() and get_viewport() != null:
				get_viewport().set_input_as_handled()
			return
		if _channel_popup != null and _channel_popup.visible:
			_channel_popup.close_popup()
			if is_inside_tree() and get_viewport() != null:
				get_viewport().set_input_as_handled()
		elif _is_dragging_wire:
			_cancel_wire_drag()
			if is_inside_tree() and get_viewport() != null:
				get_viewport().set_input_as_handled()
		elif doc_store != null and (doc_store.selected_type == "connection" or doc_store.selected_type == "element" or doc_store.selected_type == "subgraph"):
			doc_store.clear_selection()
			_redraw_all()
			if is_inside_tree() and get_viewport() != null:
				get_viewport().set_input_as_handled()

	elif ik.keycode == KEY_G and ik.shift_pressed and not (ik.ctrl_pressed or ik.meta_pressed or ik.alt_pressed):
		toggle_conveyor_geometry_mode()
		if is_inside_tree() and get_viewport() != null:
			get_viewport().set_input_as_handled()

	elif ik.keycode == KEY_W and not (ik.ctrl_pressed or ik.meta_pressed or ik.alt_pressed):
		cycle_wire_visibility_mode()
		if is_inside_tree() and get_viewport() != null:
			get_viewport().set_input_as_handled()

	elif ik.keycode in [KEY_DELETE, KEY_BACKSPACE]:
		if doc_store != null:
			if doc_store.selected_type == "connection" and not doc_store.selected_id.is_empty():
				doc_store.remove_connection(doc_store.selected_id)
				_sync_port_connection_counts()
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

func _evaluate_port_compatibility(cand_elem: String, cand_port: String, tgt_kind: String, tgt_is_out: bool, tgt_card: String) -> void:
	var s_kind := _wire_source_kind
	var s_is_out := _wire_source_is_output
	var t_kind := tgt_kind
	var t_is_out := tgt_is_out

	var emitter_kind: String = s_kind if s_is_out else t_kind
	var receiver_kind: String = t_kind if s_is_out else s_kind
	var emitter_elem: String = _wire_source_elem if s_is_out else cand_elem
	var emitter_port: String = _wire_source_port if s_is_out else cand_port
	var receiver_elem: String = cand_elem if s_is_out else _wire_source_elem
	var receiver_port: String = cand_port if s_is_out else _wire_source_port
	var receiver_card: String = tgt_card if s_is_out else "many"

	if s_is_out == t_is_out:
		_wire_is_compatible = false
		_wire_rejection_reason = "Cannot connect %s" % ("output to output" if s_is_out else "input to input")
		return

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
		return

	if doc_store != null and doc_store.active_document != null:
		var out_cnt := doc_store.get_port_connections(emitter_elem, emitter_port, true).size()
		var in_cnt := doc_store.get_port_connections(receiver_elem, receiver_port, false).size()
		if out_cnt >= 64 or in_cnt >= 64:
			_wire_is_compatible = false
			_wire_rejection_reason = "Max 64 connections per port reached"
			return
		if receiver_card == "one" and in_cnt >= 1:
			_wire_is_compatible = false
			_wire_rejection_reason = "Port already connected (cardinality: one)"
			return

	_wire_is_compatible = true
	_wire_rejection_reason = ""

func _update_wire_hover() -> void:
	var canvas_mouse := get_local_mouse_position() if is_inside_tree() else _wire_current_mouse
	var prev_hover_elem := _wire_hovered_elem
	var prev_hover_port := _wire_hovered_port

	_wire_hovered_elem = ""
	_wire_hovered_port = ""
	_wire_is_compatible = false

	# 1. Check physical conveyor endpoint ports (flow_in at Γ(0), flow_out at Γ(1)) for curved conveyors first
	var conv_ep := _hit_test_conveyor_endpoint_port(canvas_mouse)
	if not conv_ep.is_empty() and str(conv_ep["elem_id"]) != _wire_source_elem:
		var cid: String = str(conv_ep["elem_id"])
		var cport: String = str(conv_ep["port_id"])
		var cis_out: bool = bool(conv_ep["is_output"])
		_evaluate_port_compatibility(cid, cport, "flow", cis_out, "many")
		_wire_hovered_elem = cid
		_wire_hovered_port = cport
		_wire_current_mouse = conv_ep["pos"]
	else:
		# 2. Check block node perimeter sockets (including straight conveyors!)
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
				var tgt_card: String = str(p_info.get("cardinality", "many"))
				_evaluate_port_compatibility(eid, hit_pid, tgt_kind, tgt_is_out, tgt_card)
				_wire_hovered_elem = eid
				_wire_hovered_port = hit_pid
				_wire_current_mouse = _resolve_port_position(eid, hit_pid)
				break

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
	_sync_port_connection_counts()
	_redraw_all()

func _create_connection(src_e: String, src_p: String, src_kind: String, src_is_out: bool, tgt_e: String, tgt_p: String) -> void:
	var from_elem := src_e
	var from_port := src_p
	var to_elem := tgt_e
	var to_port := tgt_p

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
		_sync_port_connection_counts()
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
			port.cardinality = "many"
			port.name = "Flow In %d" % count
			elem.input_ports.append(port)
		"flow_out":
			var count := _count_ports(elem.output_ports, "flow") + 1
			port.id = "flow_out_%d" % count
			port.kind = "flow"
			port.direction = "output"
			port.cardinality = "many"
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
		_sync_port_connection_counts()
		_redraw_all()

func _count_ports(ports_arr: Array, kind: String) -> int:
	var c := 0
	for p in ports_arr:
		if p.kind == kind:
			c += 1
	return c

func _hit_test_conveyor_endpoint_port(canvas_mouse: Vector2) -> Dictionary:
	if doc_store == null or doc_store.active_document == null:
		return {}
	var m_scale: float = 20.0 * zoom_level
	var hit_r: float = clampf(9.0 * zoom_level, 7.0, 14.0)
	for elem in doc_store.get_scoped_elements():
		if not _is_curved_or_joined_conveyor_elem(elem):
			continue
		var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 24)
		if pts_m.size() < 2:
			continue
		var p_in := pan_offset + pts_m[0] * m_scale
		var p_out := pan_offset + pts_m[pts_m.size() - 1] * m_scale
		if canvas_mouse.distance_to(p_in) <= hit_r:
			var pid_in := "flow_in"
			for p in elem.input_ports:
				if p.kind == "flow":
					pid_in = p.id
					break
			return {"elem_id": elem.id, "port_id": pid_in, "is_output": false, "pos": p_in}
		if canvas_mouse.distance_to(p_out) <= hit_r:
			var pid_out := "flow_out"
			for p in elem.output_ports:
				if p.kind == "flow":
					pid_out = p.id
					break
			return {"elem_id": elem.id, "port_id": pid_out, "is_output": true, "pos": p_out}
	return {}

func _get_straight_conveyor_metrics(elem: SceneTypes.SceneElement) -> Dictionary:
	var gx: float = elem.editor.graph_position.x if elem.editor.graph_position != Vector2.ZERO else float(elem.transform.position[0]) * 20.0
	var gy: float = elem.editor.graph_position.y if elem.editor.graph_position != Vector2.ZERO else float(elem.transform.position[1]) * 20.0
	var rot_deg: float = float(elem.transform.rotation.z)
	var rot_rad: float = deg_to_rad(rot_deg)
	var dir := Vector2(cos(rot_rad), sin(rot_rad))
	var norm := Vector2(-sin(rot_rad), cos(rot_rad))
	var dims := _get_elem_dims(elem)
	var len_m: float = maxf(1.0, dims.x)
	var wid_m: float = maxf(0.4, dims.y)
	var orig_m := Vector2(gx / 20.0, gy / 20.0)
	var p_in_m := orig_m + norm * (wid_m * 0.5)
	var p_out_m := p_in_m + dir * len_m
	var p_mid_m := (p_in_m + p_out_m) * 0.5
	var rail_top_m := p_mid_m - norm * (wid_m * 0.5)
	var rail_bot_m := p_mid_m + norm * (wid_m * 0.5)
	return {
		"orig_m": orig_m,
		"dir": dir,
		"norm": norm,
		"len_m": len_m,
		"wid_m": wid_m,
		"p_in_m": p_in_m,
		"p_out_m": p_out_m,
		"p_mid_m": p_mid_m,
		"rail_top_m": rail_top_m,
		"rail_bot_m": rail_bot_m
	}

func _conveyor_width_key_frame(elem: SceneTypes.SceneElement, fraction: float) -> Dictionary:
	if not _is_curved_or_joined_conveyor_elem(elem):
		var metrics := _get_straight_conveyor_metrics(elem)
		return {"center": (metrics["p_in_m"] as Vector2) + (metrics["dir"] as Vector2) * float(metrics["len_m"]) * fraction, "normal": -(metrics["norm"] as Vector2)}
	var points := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 64)
	var index: int = clampi(int(round(fraction * float(points.size() - 1))), 0, points.size() - 1)
	var direction := (points[min(index + 1, points.size() - 1)] - points[max(index - 1, 0)]).normalized()
	return {"center": points[index], "normal": Vector2(-direction.y, direction.x)}

func _hit_test_conveyor_gizmo(canvas_mouse: Vector2) -> Dictionary:
	if doc_store == null or doc_store.active_document == null:
		return {}
	var sel_id := doc_store.selected_id
	if sel_id.is_empty():
		return {}
	var elem := doc_store.get_element(sel_id)
	if elem == null or elem.kind != "conveyor":
		return {}

	var m_scale: float = 20.0 * zoom_level
	var hit_tol: float = clampf(12.0 * zoom_level, 9.0, 16.0)
	if _conveyor_geom_mode_elem_id == elem.id:
		var ring_px := pan_offset + _conveyor_pivot(elem) * m_scale + Vector2(0, -48)
		if canvas_mouse.distance_to(ring_px) <= hit_tol:
			return {"type": "rotate", "elem_id": elem.id, "index": 0, "pos": ring_px}
		var width_keys = elem.geometry.get("width_profile", [])
		if width_keys is Array:
			for index in range(width_keys.size()):
				var item = width_keys[index]
				if not (item is Dictionary):
					continue
				var fraction := clampf(float(item.get("fraction", 0.5)), 0.0, 1.0)
				var frame := _conveyor_width_key_frame(elem, fraction)
				var pos_px := pan_offset + ((frame["center"] as Vector2) + (frame["normal"] as Vector2) * ConveyorCurve3D.width_at_fraction(elem, fraction) * 0.5) * m_scale
				if canvas_mouse.distance_to(pos_px) <= hit_tol * 0.7:
					return {"type": "width_key", "elem_id": elem.id, "index": index, "pos": pos_px}

	# 0. Straight Conveyor Gizmos (Inlet, Outlet, Width Rails)
	if not _is_curved_or_joined_conveyor_elem(elem):
		var m := _get_straight_conveyor_metrics(elem)
		var p_in_px := pan_offset + (m["p_in_m"] as Vector2) * m_scale
		var p_out_px := pan_offset + (m["p_out_m"] as Vector2) * m_scale
		var rail_top_px := pan_offset + (m["rail_top_m"] as Vector2) * m_scale
		var rail_bot_px := pan_offset + (m["rail_bot_m"] as Vector2) * m_scale

		if canvas_mouse.distance_to(rail_top_px) <= hit_tol + 5.0:
			return {"type": "width_rail", "elem_id": elem.id, "side": 1, "index": 0, "pos": rail_top_px}
		if canvas_mouse.distance_to(rail_bot_px) <= hit_tol + 5.0:
			return {"type": "width_rail", "elem_id": elem.id, "side": -1, "index": 1, "pos": rail_bot_px}
		if canvas_mouse.distance_to(p_in_px) <= hit_tol + 4.0:
			return {"type": "inlet", "elem_id": elem.id, "index": 0, "pos": p_in_px}
		if canvas_mouse.distance_to(p_out_px) <= hit_tol + 4.0:
			return {"type": "outlet", "elem_id": elem.id, "index": 1, "pos": p_out_px}
		return {}

	# Curved Conveyor Gizmos
	var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 36)
	if pts_m.size() < 2:
		return {}
	var n_pts: int = pts_m.size()
	var p_in_px := pan_offset + pts_m[0] * m_scale
	var p_out_px := pan_offset + pts_m[n_pts - 1] * m_scale

	var preset: String = str(elem.geometry.get("shape_preset", "straight")).strip_edges().to_lower()
	var sp: Dictionary = elem.geometry.get("shape_params", {}) if (elem.geometry.get("shape_params") is Dictionary) else {}

	# 1. Custom Spline Midpoint Adders & Vertices (test first so [+] can be clicked)
	if preset == "custom_spline":
		var cpts = sp.get("control_points", [])
		if cpts is Array and cpts.size() >= 2:
			for idx in range(cpts.size()):
				var item = cpts[idx]
				var v_pos := Vector2.ZERO
				if item is Dictionary and item.has("pos") and item["pos"] is Array and item["pos"].size() >= 2:
					v_pos = Vector2(float(item["pos"][0]), float(item["pos"][1]))
				elif item is Array and item.size() >= 2:
					v_pos = Vector2(float(item[0]), float(item[1]))
				var v_px := pan_offset + v_pos * m_scale
				if canvas_mouse.distance_to(v_px) <= hit_tol:
					return {"type": "spline_vertex", "elem_id": elem.id, "index": idx, "pos": v_px}
			for idx in range(cpts.size()):
				var item = cpts[idx]
				if not (item is Dictionary) or not (item.get("pos") is Array):
					continue
				for key in ["in_handle", "out_handle"]:
					var handle = item.get(key, [])
					if handle is Array and handle.size() >= 2:
						var handle_px := pan_offset + Vector2(float(item["pos"][0]) + float(handle[0]), float(item["pos"][1]) + float(handle[1])) * m_scale
						if canvas_mouse.distance_to(handle_px) <= hit_tol * 0.6:
							return {"type": key, "elem_id": elem.id, "index": idx, "pos": handle_px}
			for idx in range(cpts.size() - 1):
				var mid3: Vector3 = ConveyorCurve3D.custom_span_midpoint(elem, idx)
				var mid_px := pan_offset + Vector2(mid3.x, mid3.y) * m_scale
				if canvas_mouse.distance_to(mid_px) <= hit_tol:
					return {"type": "midpoint_add", "elem_id": elem.id, "index": idx, "pos": mid_px}

	# 2. L-Bend Corner handle
	if preset == "l_bend":
		var cp: Array = sp.get("corner_pos", [])
		if cp.size() >= 2:
			var corner_px := pan_offset + Vector2(float(cp[0]), float(cp[1])) * m_scale
			if canvas_mouse.distance_to(corner_px) <= hit_tol + 3.0:
				return {"type": "corner", "elem_id": elem.id, "index": 0, "pos": corner_px}

	# 3. S-Curve Inflection handle
	if preset == "s_curve":
		var mid_px := pan_offset + pts_m[n_pts / 2] * m_scale
		if canvas_mouse.distance_to(mid_px) <= hit_tol + 3.0:
			return {"type": "inflection", "elem_id": elem.id, "index": 0, "pos": mid_px}

	# 4. Belt Width Rail Handles (Amber handles on lateral edges at midpoint)
	var dims := _get_elem_dims(elem)
	var belt_w_px: float = maxf(6.0, dims.y * 20.0 * zoom_level)
	var half_w := belt_w_px * 0.5
	var mid_idx := n_pts / 2
	var mid_px := pan_offset + pts_m[mid_idx] * m_scale
	var t_m := (pts_m[min(mid_idx + 1, n_pts - 1)] - pts_m[max(0, mid_idx - 1)]).normalized() if n_pts > 2 else Vector2(1, 0)
	var n_m := Vector2(-t_m.y, t_m.x)
	var r_left := mid_px + n_m * half_w
	var r_right := mid_px - n_m * half_w
	if canvas_mouse.distance_to(r_left) <= hit_tol + 4.0:
		return {"type": "width_rail", "elem_id": elem.id, "side": 1, "index": 0, "pos": r_left}
	if canvas_mouse.distance_to(r_right) <= hit_tol + 4.0:
		return {"type": "width_rail", "elem_id": elem.id, "side": -1, "index": 1, "pos": r_right}

	# 5. Inlet & Outlet handles
	if canvas_mouse.distance_to(p_in_px) <= hit_tol:
		return {"type": "inlet", "elem_id": elem.id, "index": 0, "pos": p_in_px}
	if canvas_mouse.distance_to(p_out_px) <= hit_tol:
		return {"type": "outlet", "elem_id": elem.id, "index": 1, "pos": p_out_px}

	return {}

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _channel_popup != null and _channel_popup.visible and _channel_popup.get_parent() == self:
					var pop_rect := Rect2(_channel_popup.position, _channel_popup.size)
					if not pop_rect.has_point(mb.position):
						_channel_popup.close_popup()
				if _wire_popup != null and _wire_popup.visible and _wire_popup.get_parent() == self:
					var wpop_rect := Rect2(_wire_popup.position, _wire_popup.size)
					if not wpop_rect.has_point(mb.position):
						_wire_popup.close_popup()

				# Check if clicked on Geometry Mode Done button
				if not _conveyor_geom_mode_elem_id.is_empty():
					var bar_w: float = clampf(size.x - 40.0, 480.0, 620.0)
					var bar_x: float = (size.x - bar_w) * 0.5
					var bar_y: float = 12.0
					var btn_w := 76.0
					var btn_h := 22.0
					var btn_rect := Rect2(bar_x + bar_w - btn_w - 6.0, bar_y + 6.0, btn_w, btn_h)
					if btn_rect.has_point(mb.position):
						exit_conveyor_geometry_mode()
						accept_event()
						return

				# 0. Check interactive waypoint (●) or midpoint (⊕) handles on currently selected connection
				if _conveyor_geom_mode_elem_id.is_empty() and doc_store != null and doc_store.selected_type == "connection" and not doc_store.selected_id.is_empty():
					var sel_cid := doc_store.selected_id
					var hit_wp_idx := _hit_test_selected_wire_waypoint(sel_cid, mb.position)
					if hit_wp_idx >= 0:
						doc_store._record_undo()
						_dragging_waypoint_conn_id = sel_cid
						_dragging_waypoint_idx = hit_wp_idx
						accept_event()
						return
					var hit_mid_idx := _hit_test_selected_wire_midpoint(sel_cid, mb.position)
					if hit_mid_idx >= 0:
						var world_m := _canvas_to_world_m(mb.position)
						var new_idx := doc_store.insert_connection_waypoint(sel_cid, hit_mid_idx, world_m, true)
						if new_idx >= 0:
							_dragging_waypoint_conn_id = sel_cid
							_dragging_waypoint_idx = new_idx
							if _wire_popup != null and _wire_popup.visible:
								_wire_popup.refresh_ui()
							_redraw_all()
							accept_event()
							return

				# 1. Check interactive conveyor gizmo handles on selected conveyor
				var hit_gizmo := _hit_test_conveyor_gizmo(mb.position)
				if not hit_gizmo.is_empty():
					var gtype: String = str(hit_gizmo["type"])
					var geid: String = str(hit_gizmo["elem_id"])
					var gidx: int = int(hit_gizmo.get("index", 0))
					if gtype == "midpoint_add":
						var elem := doc_store.get_element(geid)
						if elem != null:
							doc_store._record_undo()
						if elem != null and ConveyorCurve3D.insert_custom_spline_point(elem, gidx):
								doc_store.is_dirty = true
								doc_store.validate()
								doc_store.document_modified.emit()
								_redraw_all()
								accept_event()
								return
					else:
						var endpoint_locks := ConveyorCurve3D.connected_endpoint_locks(geid, doc_store)
						if (gtype == "inlet" and endpoint_locks["inlet"]) or (gtype == "outlet" and endpoint_locks["outlet"]):
							_conveyor_geometry_warning = "Connected endpoint is locked; disconnect flow to move it"
							_redraw_all()
							accept_event()
							return
						if gtype == "rotate" and (endpoint_locks["inlet"] or endpoint_locks["outlet"]):
							_conveyor_geometry_warning = "Connected conveyor: disconnect flow before rotating"
							_redraw_all()
							accept_event()
							return
						_conveyor_drag_locks = endpoint_locks
						_conveyor_drag_before = ConveyorCurve3D.sample_world_curve(doc_store.get_element(geid), doc_store) if endpoint_locks["inlet"] or endpoint_locks["outlet"] else {}
						doc_store._record_undo()
						if not _conveyor_geom_mode_elem_id.is_empty() and gtype in ["inlet", "outlet"]:
							var endpoint_elem := doc_store.get_element(geid)
							if endpoint_elem != null and _is_curved_or_joined_conveyor_elem(endpoint_elem) and str(endpoint_elem.geometry.get("shape_preset", "")) != "custom_spline":
								ConveyorCurve3D.convert_element_to_custom_spline(endpoint_elem, doc_store)
								doc_store.is_dirty = true
								doc_store.document_modified.emit()
						_conveyor_active_gizmo_type = gtype
						_conveyor_active_gizmo_elem_id = geid
						_conveyor_active_gizmo_idx = gidx
						_conveyor_drag_prev_canvas_mouse = mb.position
						if gtype == "rotate":
							_conveyor_rotation_pivot = _conveyor_pivot(doc_store.get_element(geid))
							_conveyor_rotation_accum_deg = 0.0
							_conveyor_rotation_applied_deg = 0.0
						accept_event()
						return

				# 2. Check physical curved conveyor endpoint port drag start
				var hit_ep := _hit_test_conveyor_endpoint_port(mb.position) if _conveyor_geom_mode_elem_id.is_empty() else {}
				if not hit_ep.is_empty():
					var cid: String = str(hit_ep["elem_id"])
					var cport: String = str(hit_ep["port_id"])
					var cis_out: bool = bool(hit_ep["is_output"])
					if doc_store != null:
						doc_store.select_port(cid, cport)
					_on_port_drag_started(cid, cport, "flow", cis_out, hit_ep["pos"])
					accept_event()
					return

				# 3. Check conveyor track click & drag anywhere along belt
				var hit_track := _hit_test_conveyor_track(mb.position)
				if not hit_track.is_empty():
					if not _conveyor_geom_mode_elem_id.is_empty():
						enter_conveyor_geometry_mode(hit_track)
					else:
						_on_block_selected(hit_track)
					if mb.double_click:
						var spos: Vector2 = mb.global_position if mb.global_position != Vector2.ZERO else mb.position
						floating_properties_requested.emit(hit_track, spos)
					else:
						var move_locks := ConveyorCurve3D.connected_endpoint_locks(hit_track, doc_store)
						if move_locks["inlet"] or move_locks["outlet"]:
							_conveyor_geometry_warning = "Connected conveyor: disconnect flow before moving the whole belt"
						else:
							doc_store._record_undo()
							_dragging_conveyor_elem_id = hit_track
							_conveyor_drag_prev_canvas_mouse = mb.position
					_redraw_all()
					accept_event()
					return

				# 4. Check connection selection
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
			else:
				if not _dragging_waypoint_conn_id.is_empty():
					_dragging_waypoint_conn_id = ""
					_dragging_waypoint_idx = -1
					if _wire_popup != null and _wire_popup.visible:
						_wire_popup.refresh_ui()
					_redraw_all()
					accept_event()
					return

				if not _dragging_conveyor_elem_id.is_empty():
					var finished_id := _dragging_conveyor_elem_id
					_dragging_conveyor_elem_id = ""
					_finish_conveyor_geometry_edit(finished_id)
					_redraw_all()
					accept_event()
					return

				if not _conveyor_active_gizmo_type.is_empty():
					var finished_id := _conveyor_active_gizmo_elem_id
					_conveyor_active_gizmo_type = ""
					_conveyor_active_gizmo_elem_id = ""
					_conveyor_active_gizmo_idx = -1
					_conveyor_drag_before.clear()
					_finish_conveyor_geometry_edit(finished_id)
					_redraw_all()
					accept_event()
					return

		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			# Check if right-clicked on a spline vertex -> remove that vertex
			var hit_gizmo_r := _hit_test_conveyor_gizmo(mb.position)
			if not hit_gizmo_r.is_empty() and hit_gizmo_r["type"] == "spline_vertex":
				var geid: String = str(hit_gizmo_r["elem_id"])
				var gidx: int = int(hit_gizmo_r["index"])
				var elem := doc_store.get_element(geid)
				if elem != null and (elem.geometry.get("shape_params") is Dictionary):
					var sp: Dictionary = elem.geometry["shape_params"]
					var cpts = sp.get("control_points", [])
					if cpts is Array and cpts.size() > 2 and gidx > 0 and gidx < cpts.size() - 1:
						var locks := ConveyorCurve3D.connected_endpoint_locks(geid, doc_store)
						var before := ConveyorCurve3D.sample_world_curve(elem, doc_store) if locks["inlet"] or locks["outlet"] else {}
						doc_store._record_undo()
						cpts.remove_at(gidx)
						if not before.is_empty() and not ConveyorCurve3D.connected_endpoints_unchanged(before, ConveyorCurve3D.sample_world_curve(elem, doc_store), locks):
							doc_store.undo()
							rebuild_blocks()
							_conveyor_geometry_warning = "Removing this bend would move a connected endpoint"
							accept_event()
							return
						doc_store.is_dirty = true
						doc_store.validate()
						doc_store.document_modified.emit()
						_redraw_all()
						accept_event()
						return

			# Check if right-clicked on a waypoint handle (●) of the selected connection -> delete that single waypoint
			if doc_store != null and doc_store.selected_type == "connection" and not doc_store.selected_id.is_empty():
				var sel_cid := doc_store.selected_id
				var hit_wp_idx := _hit_test_selected_wire_waypoint(sel_cid, mb.position)
				if hit_wp_idx >= 0:
					doc_store.remove_connection_waypoint(sel_cid, hit_wp_idx, true)
					if _wire_popup != null and _wire_popup.visible:
						_wire_popup.refresh_ui()
					_redraw_all()
					accept_event()
					return

			var hit_ep := _hit_test_conveyor_endpoint_port(mb.position) if _conveyor_geom_mode_elem_id.is_empty() else {}
			if not hit_ep.is_empty():
				var cid: String = str(hit_ep["elem_id"])
				var cport: String = str(hit_ep["port_id"])
				var cis_out: bool = bool(hit_ep["is_output"])
				var cnt := doc_store.get_port_connections(cid, cport, cis_out).size() if doc_store != null else 0
				if cnt >= 1:
					var spos: Vector2 = mb.global_position if mb.global_position != Vector2.ZERO else mb.position
					open_channel_popup(cid, cport, cis_out, spos)
				accept_event()
				return

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
				if mb.shift_pressed:
					if _wire_popup != null and _wire_popup.visible and _wire_popup.current_conn_id == hit_conn:
						_wire_popup.close_popup()
					if doc_store != null:
						doc_store.remove_connection(hit_conn)
						_sync_port_connection_counts()
					_redraw_all()
				else:
					if doc_store != null:
						doc_store.select(hit_conn, "connection")
					var spos: Vector2 = mb.global_position if mb.global_position != Vector2.ZERO else mb.position
					open_wire_popup(hit_conn, spos)
					_redraw_all()
				accept_event()
				return

		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				var hit_conv := _hit_test_conveyor_track(mb.position)
				if not hit_conv.is_empty():
					toggle_conveyor_geometry_mode(hit_conv)
					accept_event()
					return
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
		if not _dragging_waypoint_conn_id.is_empty() and _dragging_waypoint_idx >= 0:
			if doc_store != null:
				var world_m := _canvas_to_world_m(mm.position)
				doc_store.move_connection_waypoint(_dragging_waypoint_conn_id, _dragging_waypoint_idx, world_m, false)
			_redraw_all()
			accept_event()
			return

		if not _dragging_conveyor_elem_id.is_empty():
			var delta_canvas := mm.position - _conveyor_drag_prev_canvas_mouse
			_conveyor_drag_prev_canvas_mouse = mm.position
			var m_scale: float = 20.0 * zoom_level
			var dx: float = delta_canvas.x / m_scale
			var dy: float = delta_canvas.y / m_scale
			_translate_conveyor_element(_dragging_conveyor_elem_id, dx, dy)
			_redraw_all()
			accept_event()
			return

		if not _conveyor_active_gizmo_type.is_empty() and doc_store != null:
			var elem := doc_store.get_element(_conveyor_active_gizmo_elem_id)
			if elem != null:
				if _conveyor_active_gizmo_type == "rotate":
					var pivot_px := pan_offset + _conveyor_rotation_pivot * 20.0 * zoom_level
					var from_dir := _conveyor_drag_prev_canvas_mouse - pivot_px
					var to_dir := mm.position - pivot_px
					if from_dir.length() > 10.0 and to_dir.length() > 10.0:
						_conveyor_rotation_accum_deg += rad_to_deg(from_dir.angle_to(to_dir))
						var target_deg: float = snapped(_conveyor_rotation_accum_deg, 15.0) if mm.shift_pressed else _conveyor_rotation_accum_deg
						_rotate_conveyor_element(elem.id, target_deg - _conveyor_rotation_applied_deg, _conveyor_rotation_pivot)
						_conveyor_rotation_applied_deg = target_deg
					_conveyor_drag_prev_canvas_mouse = mm.position
					_redraw_all()
					accept_event()
					return
				var m_world := _canvas_to_world_m(mm.position)
				var wx: float = snapped(m_world.x, 0.05)
				var wy: float = snapped(m_world.y, 0.05)
				var sp: Dictionary = elem.geometry.get("shape_params", {}) if (elem.geometry.get("shape_params") is Dictionary) else {}
				if not (elem.geometry.get("shape_params") is Dictionary):
					elem.geometry["shape_params"] = sp

				match _conveyor_active_gizmo_type:
					"inlet":
						if not _is_curved_or_joined_conveyor_elem(elem):
							var m := _get_straight_conveyor_metrics(elem)
							var dir: Vector2 = m["dir"]
							var p_out_m: Vector2 = m["p_out_m"]
							var new_len: float = clampf(snapped((p_out_m - Vector2(wx, wy)).dot(dir), 0.1), 1.0, 500.0)
							var delta_len: float = new_len - m["len_m"]
							var new_orig: Vector2 = m["orig_m"] - dir * delta_len
							elem.geometry["dimensions"][0] = new_len
							elem.transform.position.x = snapped(new_orig.x, 0.05)
							elem.transform.position.y = snapped(new_orig.y, 0.05)
							elem.editor.graph_position = Vector2(new_orig.x * 20.0, new_orig.y * 20.0)
							if _block_nodes.has(elem.id):
								var b: BlockNode = _block_nodes[elem.id]
								b._recalculate_size()
								b.position = pan_offset + (_compute_element_graph_position(elem, b) * zoom_level)
						else:
							if str(elem.geometry.get("shape_preset", "")) == "custom_spline":
								var points = sp.get("control_points", [])
								if points is Array and not points.is_empty() and points[0] is Dictionary:
									points[0]["pos"][0] = wx
									points[0]["pos"][1] = wy
							if not (elem.geometry.get("inlet_pose") is Dictionary):
								elem.geometry["inlet_pose"] = {"position": [wx, wy, 0.8], "tangent": [1, 0, 0]}
							elem.geometry["inlet_pose"]["position"] = [wx, wy, float(elem.geometry.get("elevation_start", 0.8))]
							elem.transform.position.x = wx
							elem.transform.position.y = wy
							elem.editor.graph_position = Vector2(wx * 20.0, wy * 20.0)
							ConveyorCurve3D.sample_world_curve(elem, doc_store)
					"outlet":
						if not _is_curved_or_joined_conveyor_elem(elem):
							var m := _get_straight_conveyor_metrics(elem)
							var dir: Vector2 = m["dir"]
							var p_in_m: Vector2 = m["p_in_m"]
							var new_len: float = clampf(snapped((Vector2(wx, wy) - p_in_m).dot(dir), 0.1), 1.0, 500.0)
							elem.geometry["dimensions"][0] = new_len
							if _block_nodes.has(elem.id):
								var b: BlockNode = _block_nodes[elem.id]
								b._recalculate_size()
						else:
							var curve_preset := str(elem.geometry.get("shape_preset", ""))
							if curve_preset == "custom_spline":
								var points = sp.get("control_points", [])
								if points is Array and not points.is_empty() and points[-1] is Dictionary:
									points[-1]["pos"][0] = wx
									points[-1]["pos"][1] = wy
							elif curve_preset == "s_curve":
								var start := Vector2(elem.transform.position.x, elem.transform.position.y)
								var tan := Vector2.RIGHT
								if elem.geometry.get("inlet_pose") is Dictionary:
									var ip: Dictionary = elem.geometry["inlet_pose"]
									var ipos = ip.get("position", [])
									var itan = ip.get("tangent", [])
									if ipos is Array and ipos.size() >= 2:
										start = Vector2(float(ipos[0]), float(ipos[1]))
									if itan is Array and itan.size() >= 2:
										tan = Vector2(float(itan[0]), float(itan[1])).normalized()
								var delta := Vector2(wx, wy) - start
								sp["forward_span"] = maxf(2.0, delta.dot(tan))
								sp["lateral_offset"] = delta.dot(Vector2(-tan.y, tan.x))
							if not (elem.geometry.get("outlet_pose") is Dictionary):
								elem.geometry["outlet_pose"] = {"position": [wx, wy, 0.8], "tangent": [1, 0, 0]}
							elem.geometry["outlet_pose"]["position"] = [wx, wy, float(elem.geometry.get("elevation_end", 0.8))]
							ConveyorCurve3D.sample_world_curve(elem, doc_store)
					"corner":
						sp["corner_pos"] = [wx, wy, 0.8]
						var in_pos := Vector2(float(elem.transform.position[0]), float(elem.transform.position[1]))
						var out_pos := in_pos + Vector2(10, 0)
						if elem.geometry.has("inlet_pose") and elem.geometry["inlet_pose"] is Dictionary and elem.geometry["inlet_pose"].has("position"):
							in_pos = Vector2(float(elem.geometry["inlet_pose"]["position"][0]), float(elem.geometry["inlet_pose"]["position"][1]))
						if elem.geometry.has("outlet_pose") and elem.geometry["outlet_pose"] is Dictionary and elem.geometry["outlet_pose"].has("position"):
							out_pos = Vector2(float(elem.geometry["outlet_pose"]["position"][0]), float(elem.geometry["outlet_pose"]["position"][1]))
						var corner_v := Vector2(wx, wy)
						var l1: float = in_pos.distance_to(corner_v)
						var l2: float = corner_v.distance_to(out_pos)
						sp["leg1_length"] = snapped(l1, 0.1)
						sp["leg2_length"] = snapped(l2, 0.1)
						var v1 := (corner_v - in_pos).normalized()
						var v2 := (out_pos - corner_v).normalized()
						var cos_a: float = clampf(v1.dot(v2), -0.995, 0.995)
						var ang_deg: float = rad_to_deg(acos(cos_a))
						sp["bend_angle_deg"] = snapped(ang_deg, 1.0)
						sp["turn_direction"] = "left" if (v1.x * v2.y - v1.y * v2.x) > 0.0 else "right"
						ConveyorCurve3D.sample_world_curve(elem, doc_store)
					"inflection":
						var in_p := Vector2(float(elem.transform.position[0]), float(elem.transform.position[1]))
						var t_in := Vector2(1, 0)
						if elem.geometry.has("inlet_pose") and elem.geometry["inlet_pose"] is Dictionary:
							var ipos = elem.geometry["inlet_pose"].get("position", [in_p.x, in_p.y])
							in_p = Vector2(float(ipos[0]), float(ipos[1]))
							var itan = elem.geometry["inlet_pose"].get("tangent", [1, 0])
							t_in = Vector2(float(itan[0]), float(itan[1])).normalized()
						var n_in := Vector2(-t_in.y, t_in.x)
						var m_pt := Vector2(wx, wy)
						var fwd: float = maxf(2.0, (m_pt - in_p).dot(t_in) * 2.0)
						var lat: float = (m_pt - in_p).dot(n_in) * 2.0
						sp["forward_span"] = snapped(fwd, 0.2)
						sp["lateral_offset"] = snapped(lat, 0.1)
						ConveyorCurve3D.sample_world_curve(elem, doc_store)
					"spline_vertex":
						var cpts = sp.get("control_points", [])
						if cpts is Array and _conveyor_active_gizmo_idx >= 0 and _conveyor_active_gizmo_idx < cpts.size():
							var item = cpts[_conveyor_active_gizmo_idx]
							if item is Dictionary:
								var pos_arr: Array = item.get("pos", [])
								if pos_arr.size() >= 3:
									if mm.shift_pressed:
										pos_arr[2] = snapped(float(pos_arr[2]) + (_conveyor_drag_prev_canvas_mouse.y - mm.position.y) / (20.0 * zoom_level), 0.05)
									else:
										pos_arr[0] = wx
										pos_arr[1] = wy
							elif item is Array:
								item[0] = wx
								item[1] = wy
						ConveyorCurve3D.sample_world_curve(elem, doc_store)
					"in_handle", "out_handle":
						var cpts = sp.get("control_points", [])
						if cpts is Array and _conveyor_active_gizmo_idx >= 0 and _conveyor_active_gizmo_idx < cpts.size():
							var item = cpts[_conveyor_active_gizmo_idx]
							if item is Dictionary and item.get("pos") is Array and item.get(_conveyor_active_gizmo_type) is Array:
								item[_conveyor_active_gizmo_type][0] = wx - float(item["pos"][0])
								item[_conveyor_active_gizmo_type][1] = wy - float(item["pos"][1])
						ConveyorCurve3D.sample_world_curve(elem, doc_store)
					"width_key":
						var width_keys = elem.geometry.get("width_profile", [])
						if width_keys is Array and _conveyor_active_gizmo_idx >= 0 and _conveyor_active_gizmo_idx < width_keys.size():
							var fraction := clampf(float(width_keys[_conveyor_active_gizmo_idx].get("fraction", 0.5)), 0.0, 1.0)
							var frame := _conveyor_width_key_frame(elem, fraction)
							var local_width: float = clampf(snapped(absf((Vector2(wx, wy) - (frame["center"] as Vector2)).dot(frame["normal"] as Vector2)) * 2.0, 0.05), 0.4, 8.0)
							width_keys[_conveyor_active_gizmo_idx]["scale"] = local_width / maxf(0.4, float(elem.geometry["dimensions"][1]))
					"width_rail":
						if not _is_curved_or_joined_conveyor_elem(elem):
							var m := _get_straight_conveyor_metrics(elem)
							var norm: Vector2 = m["norm"]
							var p_mid_m: Vector2 = m["p_mid_m"]
							var dist_m := absf((Vector2(wx, wy) - p_mid_m).dot(norm))
							var new_w := clampf(snapped(dist_m * 2.0, 0.05), 0.4, 8.0)
							if not (elem.geometry.get("dimensions") is Array):
								elem.geometry["dimensions"] = [8.0, new_w, 0.2]
							else:
								elem.geometry["dimensions"][1] = new_w
							if _block_nodes.has(elem.id):
								_block_nodes[elem.id]._recalculate_size()
						else:
							var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 20)
							if pts_m.size() >= 2:
								var mid_m := pts_m[pts_m.size() / 2]
								var dist_m := mid_m.distance_to(Vector2(wx, wy))
								var new_w := clampf(snapped(dist_m * 2.0, 0.05), 0.4, 8.0)
								if not (elem.geometry.get("dimensions") is Array):
									elem.geometry["dimensions"] = [8.0, new_w, 0.2]
								else:
									elem.geometry["dimensions"][1] = new_w
								ConveyorCurve3D.sample_world_curve(elem, doc_store)
								if _block_nodes.has(elem.id):
									_block_nodes[elem.id]._recalculate_size()
				_conveyor_drag_prev_canvas_mouse = mm.position
				if _block_nodes.has(elem.id):
					var b: BlockNode = _block_nodes[elem.id]
					b.position = pan_offset + (_compute_element_graph_position(elem, b) * zoom_level)
				if not _conveyor_drag_before.is_empty() and not ConveyorCurve3D.connected_endpoints_unchanged(_conveyor_drag_before, ConveyorCurve3D.sample_world_curve(elem, doc_store), _conveyor_drag_locks):
					_conveyor_active_gizmo_type = ""
					_conveyor_active_gizmo_elem_id = ""
					_conveyor_drag_before.clear()
					doc_store.undo()
					rebuild_blocks()
					_conveyor_geometry_warning = "Edit would move a connected endpoint; change reverted"
					_redraw_all()
					accept_event()
					return
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
				_redraw_all()
				accept_event()
				return

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
		if elem.kind == "conveyor" and _is_curved_or_joined_conveyor_elem(elem):
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

	# 3. Joined & Curved Conveyor Belt Tracks (Straight conveyors render inside their own BlockNode!)
	_draw_conveyor_tracks()

	# 4. Dedicated Conveyor Geometry Editing HUD Banner
	if not _conveyor_geom_mode_elem_id.is_empty():
		_draw_conveyor_geometry_banner()
		var active := doc_store.get_element(_conveyor_geom_mode_elem_id) if doc_store != null else null
		if active != null:
			var pivot_px := pan_offset + _conveyor_pivot(active) * 20.0 * zoom_level
			var ring_px := pivot_px + Vector2(0, -48)
			draw_line(pivot_px, ring_px, Color("#00d2ff"), 1.5)
			draw_arc(ring_px, 9.0, 0.0, TAU, 24, Color("#00d2ff"), 2.0)
			draw_string(ThemeDB.fallback_font, ring_px + Vector2(-4, 4), "R", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)

func _draw_conveyor_tracks() -> void:
	if doc_store == null or doc_store.active_document == null:
		return

	var m_scale: float = 20.0 * zoom_level
	for elem in doc_store.get_scoped_elements():
		# Straight conveyors render directly inside their BlockNode — only draw curved/joined tracks here!
		if not _is_curved_or_joined_conveyor_elem(elem):
			continue

		var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 0)
		if pts_m.size() < 2:
			continue

		var pts_px := PackedVector2Array()
		for pm in pts_m:
			pts_px.append(pan_offset + pm * m_scale)

		var dims := _get_elem_dims(elem)
		var belt_w_px: float = maxf(6.0, dims.y * 20.0 * zoom_level)
		var is_sel: bool = (doc_store.selected_id == elem.id) or doc_store.is_element_selected(elem.id)
		var is_in_geom_mode: bool = (_conveyor_geom_mode_elem_id == elem.id)

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
			var half_w: float = ConveyorCurve3D.width_at_fraction(elem, float(i) / float(n_pts - 1)) * m_scale * 0.5
			tangents.append(t_dir)
			left_px.append(pts_px[i] + n_dir * half_w)
			right_px.append(pts_px[i] - n_dir * half_w)

		if is_in_geom_mode:
			draw_polyline(pts_px, Color("#00d2ff"), belt_w_px + 8.0, true)
		elif is_sel:
			draw_polyline(pts_px, Color(0.0, 0.82, 1.0, 0.25), belt_w_px + 8.0, true)

		var bed_col := Color("#172736") if (is_sel or is_in_geom_mode) else Color("#121b26")
		for i in range(n_pts - 1):
			draw_colored_polygon(PackedVector2Array([left_px[i], left_px[i + 1], right_px[i + 1], right_px[i]]), bed_col)

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

		var rail_col := Color("#00d2ff") if is_in_geom_mode else (Color("#52c7a5") if is_sel else Color("#2a9d8f"))
		var rail_w: float = clampf(2.0 * zoom_level, 1.4, 3.2)
		draw_polyline(left_px, rail_col, rail_w, true)
		draw_polyline(right_px, rail_col, rail_w, true)

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

		# Physical Endpoint Flow Ports at Inlet Γ(0) and Outlet Γ(1) (hidden when in geometry mode)
		if _conveyor_geom_mode_elem_id.is_empty():
			var hub_r: float = clampf(belt_w_px * 0.42, 5.0, 9.5)
			var p_in_pos: Vector2 = pts_px[0]
			var p_out_pos: Vector2 = pts_px[n_pts - 1]
			for idx_ep in range(2):
				var endpoint: Vector2 = p_in_pos if idx_ep == 0 else p_out_pos
				var is_out_ep: bool = (idx_ep == 1)
				draw_circle(endpoint, hub_r, Color("#0d1822"))
				draw_arc(endpoint, hub_r, 0.0, TAU, 18, Color("#2ecc71"), 1.6)
				var sq := hub_r * 0.42
				draw_rect(Rect2(endpoint.x - sq, endpoint.y - sq, sq * 2.0, sq * 2.0), Color.WHITE if is_out_ep else Color("#2ecc71"), true)

		# Interactive On-Canvas Handles & Spline Gizmos for Selected Conveyor
		if is_in_geom_mode or (_conveyor_geom_mode_elem_id.is_empty() and is_sel):
			_draw_conveyor_gizmos(elem, pts_px, tangents, belt_w_px)

	# If in Geometry Mode for a straight conveyor, draw its geometry handles too!
	if not _conveyor_geom_mode_elem_id.is_empty():
		var geom_elem := doc_store.get_element(_conveyor_geom_mode_elem_id)
		if geom_elem != null and geom_elem.kind == "conveyor" and not _is_curved_or_joined_conveyor_elem(geom_elem):
			_draw_straight_conveyor_geometry_gizmos(geom_elem)

func _draw_straight_conveyor_geometry_gizmos(elem: SceneTypes.SceneElement) -> void:
	var m := _get_straight_conveyor_metrics(elem)
	var m_scale: float = 20.0 * zoom_level
	var orig_m: Vector2 = m["orig_m"]
	var dir: Vector2 = m["dir"]
	var norm: Vector2 = m["norm"]
	var len_m: float = m["len_m"]
	var wid_m: float = m["wid_m"]

	# 1. High-contrast CAD Boundary Outline (stroked 2px, glowing cyan, NO solid fill)
	var c1 := pan_offset + orig_m * m_scale
	var c2 := pan_offset + (orig_m + dir * len_m) * m_scale
	var c3 := pan_offset + (orig_m + dir * len_m + norm * wid_m) * m_scale
	var c4 := pan_offset + (orig_m + norm * wid_m) * m_scale
	draw_polyline(PackedVector2Array([c1, c2, c3, c4, c1]), Color("#00d2ff"), 2.0, true)

	# 2. Inlet Gizmo Handle (Green circle with outer ring)
	var p_in_px := pan_offset + (m["p_in_m"] as Vector2) * m_scale
	draw_circle(p_in_px, 7.5, Color("#2ecc71"))
	draw_arc(p_in_px, 9.5, 0.0, TAU, 16, Color.WHITE, 1.5)

	# 3. Outlet Gizmo Handle (Red circle with outer ring)
	var p_out_px := pan_offset + (m["p_out_m"] as Vector2) * m_scale
	draw_circle(p_out_px, 7.5, Color("#e74c3c"))
	draw_arc(p_out_px, 9.5, 0.0, TAU, 16, Color.WHITE, 1.5)

	# 4. Belt Width Rail Handles (Amber handles on top & bottom rails at midpoint)
	var rail_top_px := pan_offset + (m["rail_top_m"] as Vector2) * m_scale
	var rail_bot_px := pan_offset + (m["rail_bot_m"] as Vector2) * m_scale

	# Dashed dimension line across belt
	draw_dashed_line(rail_top_px, rail_bot_px, Color(1.0, 0.7, 0.2, 0.85), 1.5, 4.0)

	for r_pos in [rail_top_px, rail_bot_px]:
		draw_circle(r_pos, 6.0, Color("#f39c12"))
		draw_arc(r_pos, 7.5, 0.0, TAU, 16, Color.WHITE, 1.4)

	# Width text label
	var font := ThemeDB.fallback_font
	var w_str := "W: %.2fm" % wid_m
	draw_string(font, rail_top_px - norm * 14.0 + Vector2(-22, 4), w_str, HORIZONTAL_ALIGNMENT_CENTER, -1, 10, Color("#f39c12"))

func _draw_conveyor_gizmos(elem: SceneTypes.SceneElement, pts_px: PackedVector2Array, _tangents: PackedVector2Array, _belt_w_px: float) -> void:
	var n_pts: int = pts_px.size()
	if n_pts < 2:
		return
	var m_scale: float = 20.0 * zoom_level
	var preset: String = str(elem.geometry.get("shape_preset", "straight")).strip_edges().to_lower()
	var sp: Dictionary = elem.geometry.get("shape_params", {}) if (elem.geometry.get("shape_params") is Dictionary) else {}

	var p_in_px := pts_px[0]
	var p_out_px := pts_px[n_pts - 1]

	# 1. Inlet Gizmo Handle (Green circle with outer ring)
	draw_circle(p_in_px, 7.5, Color("#2ecc71"))
	draw_arc(p_in_px, 9.5, 0.0, TAU, 16, Color.WHITE, 1.5)

	# 2. Outlet Gizmo Handle (Red circle with outer ring)
	draw_circle(p_out_px, 7.5, Color("#e74c3c"))
	draw_arc(p_out_px, 9.5, 0.0, TAU, 16, Color.WHITE, 1.5)

	# 3. L-Bend Corner Apex Handle (Amber diamond with dashed guide lines)
	if preset == "l_bend":
		var cp: Array = sp.get("corner_pos", [])
		if cp.size() >= 2:
			var corner_px := pan_offset + Vector2(float(cp[0]), float(cp[1])) * m_scale
			draw_line(p_in_px, corner_px, Color(1.0, 0.75, 0.2, 0.45), 1.5)
			draw_line(corner_px, p_out_px, Color(1.0, 0.75, 0.2, 0.45), 1.5)
			var d_size := 8.5
			var diamond := PackedVector2Array([
				corner_px + Vector2(0, -d_size),
				corner_px + Vector2(d_size, 0),
				corner_px + Vector2(0, d_size),
				corner_px + Vector2(-d_size, 0)
			])
			draw_colored_polygon(diamond, Color("#f39c12"))
			draw_polyline(PackedVector2Array([diamond[0], diamond[1], diamond[2], diamond[3], diamond[0]]), Color.WHITE, 1.6, true)

	# 4. Belt Width Rail Handles (Amber handles on lateral edges at midpoint)
	var mid_idx := n_pts / 2
	var mid_px := pts_px[mid_idx]
	var t_mid: Vector2 = (pts_px[min(mid_idx + 1, n_pts - 1)] - pts_px[max(0, mid_idx - 1)]).normalized() if n_pts > 2 else Vector2(1, 0)
	var n_mid := Vector2(-t_mid.y, t_mid.x)
	var half_w := _belt_w_px * 0.5
	var rail_l := mid_px + n_mid * half_w
	var rail_r := mid_px - n_mid * half_w

	# Dashed dimension line across belt
	draw_dashed_line(rail_l, rail_r, Color(1.0, 0.7, 0.2, 0.75), 1.5, 4.0)

	# Rail handles
	for r_pos in [rail_l, rail_r]:
		draw_circle(r_pos, 6.0, Color("#f39c12"))
		draw_arc(r_pos, 7.5, 0.0, TAU, 16, Color.WHITE, 1.4)
	if _conveyor_geom_mode_elem_id == elem.id:
		var width_keys = elem.geometry.get("width_profile", [])
		if width_keys is Array:
			for item in width_keys:
				if item is Dictionary:
					var fraction := clampf(float(item.get("fraction", 0.5)), 0.0, 1.0)
					var frame := _conveyor_width_key_frame(elem, fraction)
					var key_pos := pan_offset + ((frame["center"] as Vector2) + (frame["normal"] as Vector2) * ConveyorCurve3D.width_at_fraction(elem, fraction) * 0.5) * (20.0 * zoom_level)
					draw_circle(key_pos, 6.0, Color("#e6b85c"))
					draw_arc(key_pos, 7.5, 0.0, TAU, 16, Color.WHITE, 1.2)

	# Width text label
	var font := ThemeDB.fallback_font
	var w_m: float = float(elem.geometry.get("dimensions", [8.0, 1.2, 0.2])[1])
	var w_str := "W: %.2fm" % w_m
	draw_string(font, rail_l + n_mid * 14.0 + Vector2(-22, 4), w_str, HORIZONTAL_ALIGNMENT_CENTER, -1, 10, Color("#f39c12"))

	# 5. S-Curve Inflection Handle (Cyan diamond at curve midpoint)
	if preset == "s_curve":
		var d_size := 8.0
		var diamond := PackedVector2Array([
			mid_px + Vector2(0, -d_size),
			mid_px + Vector2(d_size, 0),
			mid_px + Vector2(0, d_size),
			mid_px + Vector2(-d_size, 0)
		])
		draw_colored_polygon(diamond, Color("#00d2ff"))
		draw_polyline(PackedVector2Array([diamond[0], diamond[1], diamond[2], diamond[3], diamond[0]]), Color.WHITE, 1.6, true)

	# 6. Custom Spline Control Vertices & Midpoint [+] Insertion Handles
	if preset == "custom_spline":
		var cpts = sp.get("control_points", [])
		if cpts is Array:
			for idx in range(cpts.size()):
				var item = cpts[idx]
				var v_pos := Vector2.ZERO
				if item is Dictionary and item.has("pos") and item["pos"] is Array and item["pos"].size() >= 2:
					v_pos = Vector2(float(item["pos"][0]), float(item["pos"][1]))
				elif item is Array and item.size() >= 2:
					v_pos = Vector2(float(item[0]), float(item[1]))
				var v_px := pan_offset + v_pos * m_scale
				draw_circle(v_px, 7.0, Color("#9b59b6"))
				draw_arc(v_px, 7.0, 0.0, TAU, 16, Color.WHITE, 1.4)
				draw_string(font, v_px + Vector2(-3, 4), str(idx + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color.WHITE)
				if item is Dictionary:
					for key in ["in_handle", "out_handle"]:
						var handle = item.get(key, [])
						if handle is Array and handle.size() >= 2 and Vector2(float(handle[0]), float(handle[1])).length() > 0.1:
							var handle_px := v_px + Vector2(float(handle[0]), float(handle[1])) * m_scale
							draw_line(v_px, handle_px, Color("#a29bfe"), 1.0)
							draw_circle(handle_px, 4.5, Color("#a29bfe"))

			for idx in range(cpts.size() - 1):
				var mid3: Vector3 = ConveyorCurve3D.custom_span_midpoint(elem, idx)
				var mid_px_s := pan_offset + Vector2(mid3.x, mid3.y) * m_scale
				draw_circle(mid_px_s, 5.5, Color(0.1, 0.15, 0.22, 0.9))
				draw_arc(mid_px_s, 5.5, 0.0, TAU, 12, Color("#a29bfe"), 1.3)
				draw_string(font, mid_px_s + Vector2(-3, 4), "+", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color("#a29bfe"))

func _draw_conveyor_geometry_banner() -> void:
	if doc_store == null or _conveyor_geom_mode_elem_id.is_empty():
		return
	var elem := doc_store.get_element(_conveyor_geom_mode_elem_id)
	if elem == null:
		return
	var preset: String = str(elem.geometry.get("shape_preset", "straight")).capitalize()
	var dims := _get_elem_dims(elem)
	var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 36)
	var total_len_m: float = 0.0
	for i in range(pts_m.size() - 1):
		total_len_m += pts_m[i].distance_to(pts_m[i + 1])
	if total_len_m < 0.1 or not _is_curved_or_joined_conveyor_elem(elem):
		total_len_m = dims.x

	var bar_w: float = clampf(size.x - 40.0, 480.0, 640.0)
	var bar_h: float = 34.0
	var bar_x: float = (size.x - bar_w) * 0.5
	var bar_y: float = 12.0
	var banner_rect := Rect2(bar_x, bar_y, bar_w, bar_h)

	# Banner background with CAD theme
	draw_rect(banner_rect, Color(0.06, 0.10, 0.16, 0.95), true)
	draw_rect(banner_rect, Color("#00d2ff"), false, 1.5)

	var font := ThemeDB.fallback_font
	var title_str := "📐 CONVEYOR GEOMETRY MODE: %s [%s] · L: %.2fm · W: %.2fm" % [elem.id, preset, total_len_m, dims.y]
	draw_string(font, Vector2(bar_x + 14.0, bar_y + 22.0), title_str, HORIZONTAL_ALIGNMENT_LEFT, int(bar_w - 110.0), 11, Color.WHITE)

	# Done (Esc) Button
	var btn_w := 76.0
	var btn_h := 22.0
	var btn_rect := Rect2(bar_x + bar_w - btn_w - 6.0, bar_y + 6.0, btn_w, btn_h)
	draw_rect(btn_rect, Color("#2ecc71"), true)
	draw_rect(btn_rect, Color.WHITE, false, 1.0)
	draw_string(font, Vector2(btn_rect.position.x, btn_rect.position.y + 15.0), "Done (Esc)", HORIZONTAL_ALIGNMENT_CENTER, int(btn_w), 10, Color(0.05, 0.1, 0.05, 1.0))
	if not _conveyor_geometry_warning.is_empty():
		draw_string(font, Vector2(bar_x + 8.0, bar_y + bar_h + 17.0), _conveyor_geometry_warning, HORIZONTAL_ALIGNMENT_LEFT, int(bar_w), 11, Color("#f39c12"))

func _hit_test_conveyor_track(canvas_mouse: Vector2) -> String:
	if doc_store == null or doc_store.active_document == null:
		return ""
	var m_scale: float = 20.0 * zoom_level
	var best_id := ""
	var best_dist := 1e9
	for elem in doc_store.get_scoped_elements():
		if elem.kind != "conveyor":
			continue

		if not _is_curved_or_joined_conveyor_elem(elem):
			var m := _get_straight_conveyor_metrics(elem)
			var a := pan_offset + (m["p_in_m"] as Vector2) * m_scale
			var b := pan_offset + (m["p_out_m"] as Vector2) * m_scale
			var hit_tol: float = maxf(10.0, m["wid_m"] * 20.0 * zoom_level * 0.6)
			var d := _dist_to_segment(canvas_mouse, a, b)
			if d <= hit_tol and d < best_dist:
				best_dist = d
				best_id = elem.id
		else:
			var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 0)
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

		if is_product:
			var prod_w_m: float = float(props.get("prod_w", 0.4))
			var prod_h_m: float = float(props.get("prod_h", 0.4))
			var w_px: float = clamp(prod_w_m * m_scale, 6.0, 20.0)
			var h_px: float = clamp(prod_h_m * m_scale, 6.0, 20.0)

			var col: Color
			if props.has("color_r"):
				col = Color(float(props.get("color_r", 0.3)),
							float(props.get("color_g", 0.75)),
							float(props.get("color_b", 1.0)), 1.0)
			elif in_service:
				col = Color("2ecc71")
			elif zone_kind == "queue":
				col = Color("00d2ff")
			else:
				col = Color("f39c12")

			if show_trajectories and zone_kind == "" and not aid.is_empty() and _agent_trajectories.has(aid):
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
			continue

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
	layer.draw_rect(Rect2(local_rect.position + Vector2(1, 1), local_rect.size), Color(0, 0, 0, 0.35), true)
	layer.draw_rect(local_rect, col, true)
	layer.draw_rect(Rect2(local_rect.position, Vector2(local_rect.size.x, 2.0)), Color(1.0, 1.0, 1.0, 0.25), true)
	layer.draw_rect(local_rect, Color(0.05, 0.08, 0.12, 0.9), false, 1.0)
	layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if in_service or zone_kind == "server":
		var ring_alpha: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.001 * TAU)
		var r_glow: float = max(half_w, half_h) + 3.0
		layer.draw_arc(pos, r_glow, 0.0, TAU, 20, Color(0.18, 0.95, 0.47, ring_alpha), 1.8)

func _on_wires_layer_draw() -> void:
	if _wires_layer == null:
		return

	_draw_connections()

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

	var custom_zones: Array = []
	if doc_store != null and doc_store.active_document != null and doc_store.active_document.scene.get("cad_zones") is Array:
		custom_zones = doc_store.active_document.scene["cad_zones"]

	if not custom_zones.is_empty():
		var m_scale_z: float = 20.0 * zoom_level
		for zd in custom_zones:
			if zd is Dictionary and zd.get("rect") is Array and (zd["rect"] as Array).size() >= 4:
				var ra: Array = zd["rect"]
				var zr := Rect2(
					pan_offset + Vector2(float(ra[0]), float(ra[1])) * m_scale_z,
					Vector2(float(ra[2]), float(ra[3])) * m_scale_z
				)
				draw_rect(zr, CAD_WALL_COLOR, false, 2.0)
				draw_string(ThemeDB.fallback_font, zr.position + Vector2(8, 16), str(zd.get("label", "CAD ZONE")), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, ROOM_LABEL_COLOR)
	else:
		var r1 := Rect2(pan_offset + Vector2(20, 20) * zoom_level, Vector2(400, 300) * zoom_level)
		draw_rect(r1, CAD_WALL_COLOR, false, 2.0)
		draw_string(ThemeDB.fallback_font, r1.position + Vector2(10, 20), "CAD ZONE: INFEED & RECEIVING", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ROOM_LABEL_COLOR)

		var r2 := Rect2(pan_offset + Vector2(460, 20) * zoom_level, Vector2(500, 300) * zoom_level)
		draw_rect(r2, CAD_WALL_COLOR, false, 2.0)
		draw_string(ThemeDB.fallback_font, r2.position + Vector2(10, 20), "CAD ZONE: MAIN PROCESSING & INSPECTION", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ROOM_LABEL_COLOR)

func _should_draw_connection(conn: SceneTypes.SceneConnection) -> bool:
	if _is_dragging_wire:
		return true
	if str(conn.id) == _hovered_channel_conn_id and not _hovered_channel_conn_id.is_empty():
		return true
	if wire_visibility_mode == WireVisibilityMode.ALL:
		return true
	if wire_visibility_mode == WireVisibilityMode.OFF:
		return false
	# FOCUS mode: show wires connected to selected or hovered block/connection
	if doc_store != null:
		if doc_store.selected_type == "connection" and doc_store.selected_id == conn.id:
			return true
		if doc_store.selected_id in [conn.source_element, conn.target_element]:
			return true
		if doc_store.is_element_selected(conn.source_element) or doc_store.is_element_selected(conn.target_element):
			return true
	for eid in [conn.source_element, conn.target_element]:
		if _block_nodes.has(eid) and _block_nodes[eid].is_block_hovered:
			return true
	return false

func _world_m_to_canvas(pt_m: Vector2) -> Vector2:
	return pan_offset + pt_m * (20.0 * zoom_level)

func _canvas_to_world_m(canvas_pt: Vector2) -> Vector2:
	var m_scale: float = maxf(20.0 * zoom_level, 0.001)
	return (canvas_pt - pan_offset) / m_scale

func _resolve_port_pose(elem_id: String, port_id: String, is_output: bool = true) -> Dictionary:
	if doc_store != null:
		var elem := doc_store.get_element(elem_id)
		if elem != null and _is_curved_or_joined_conveyor_elem(elem):
			var is_flow_in := (port_id == "flow_in" or port_id == "in" or port_id.begins_with("flow_in"))
			var is_flow_out := (port_id == "flow_out" or port_id == "out" or port_id.begins_with("flow_out"))
			if is_flow_in or is_flow_out:
				var pts_m := ConveyorCurve3D.sample_2d_polyline(elem, doc_store, 20)
				if pts_m.size() >= 2:
					var m_scale: float = 20.0 * zoom_level
					if is_flow_in:
						var ep_in := pan_offset + pts_m[0] * m_scale
						var t_in := (pts_m[1] - pts_m[0]).normalized()
						var n_in := -t_in if t_in.length_squared() > 1e-4 else Vector2(-1, 0)
						return {"pos": ep_in, "normal": n_in, "edge": "left"}
					else:
						var n_pts := pts_m.size()
						var ep_out := pan_offset + pts_m[n_pts - 1] * m_scale
						var t_out := (pts_m[n_pts - 1] - pts_m[n_pts - 2]).normalized()
						var n_out := t_out if t_out.length_squared() > 1e-4 else Vector2(1, 0)
						return {"pos": ep_out, "normal": n_out, "edge": "right"}
	if _block_nodes.has(elem_id):
		var b: BlockNode = _block_nodes[elem_id]
		var pos := b.get_port_canvas_position(port_id)
		var p_info: Dictionary = b.get_port_info(port_id)
		var edge: String = str(p_info.get("edge", "right" if is_output else "left"))
		var local_n := Vector2(1, 0)
		match edge:
			"left": local_n = Vector2(-1, 0)
			"right": local_n = Vector2(1, 0)
			"top": local_n = Vector2(0, -1)
			"bottom": local_n = Vector2(0, 1)
		return {"pos": pos, "normal": local_n.rotated(b.rotation), "edge": edge}
	return {"pos": Vector2.ZERO, "normal": Vector2(1, 0) if is_output else Vector2(-1, 0), "edge": "right" if is_output else "left"}

func _resolve_port_position(elem_id: String, port_id: String) -> Vector2:
	return _resolve_port_pose(elem_id, port_id, true)["pos"]

func compute_connection_geometry(conn: SceneTypes.SceneConnection) -> Dictionary:
	var src_pose := _resolve_port_pose(conn.source_element, conn.source_port, true)
	var tgt_pose := _resolve_port_pose(conn.target_element, conn.target_port, false)
	var p1: Vector2 = src_pose["pos"]
	var p2: Vector2 = tgt_pose["pos"]
	var n1: Vector2 = src_pose["normal"]
	var n2: Vector2 = tgt_pose["normal"]

	var vis: Dictionary = doc_store.get_connection_visual(conn.id) if doc_store != null else {}
	var eff_mode: String = doc_store.get_effective_wire_shape(conn.id) if doc_store != null else "bezier"
	var slider_val: float = float(vis.get("radius_or_tension", 8.0))
	var raw_wps: Array = vis.get("waypoints", [])

	var wp_canvas: Array[Vector2] = []
	for wp in raw_wps:
		if wp is Array and wp.size() >= 2:
			wp_canvas.append(_world_m_to_canvas(Vector2(float(wp[0]), float(wp[1]))))
		elif wp is Vector2:
			wp_canvas.append(_world_m_to_canvas(wp))

	if p1 == Vector2.ZERO or p2 == Vector2.ZERO:
		return {
			"points": PackedVector2Array(),
			"waypoint_handles": wp_canvas,
			"midpoint_handles": [],
			"effective_mode": eff_mode,
			"start_normal": n1,
			"end_normal": n2
		}

	var anchors: Array[Vector2] = [p1]
	for wpt in wp_canvas:
		anchors.append(wpt)
	anchors.append(p2)

	var points := PackedVector2Array()
	var midpoints: Array[Vector2] = []
	var k_spans: int = anchors.size() - 1

	if eff_mode == "straight":
		for s in range(k_spans):
			midpoints.append(anchors[s].lerp(anchors[s + 1], 0.5))
		var raw_poly := PackedVector2Array(anchors)
		var r_px: float = slider_val * 1.4 * zoom_level
		points = _round_or_chamfer_polyline(raw_poly, r_px, false) if (r_px > 0.5 and anchors.size() > 2) else raw_poly

	elif eff_mode == "bezier":
		var tension: float = lerpf(0.22, 0.85, clampf(slider_val / 20.0, 0.0, 1.0))
		var tangents: Array[Vector2] = []
		for i in range(anchors.size()):
			if i == 0:
				tangents.append(n1.normalized())
			elif i == anchors.size() - 1:
				tangents.append((-n2).normalized())
			else:
				var d_vec := anchors[i + 1] - anchors[i - 1]
				tangents.append(d_vec.normalized() if d_vec.length_squared() > 1e-4 else Vector2(1, 0))

		var min_handle: float = 28.0 * zoom_level
		for s in range(k_spans):
			var a: Vector2 = anchors[s]
			var b: Vector2 = anchors[s + 1]
			var span_len: float = a.distance_to(b)
			var h_len: float = maxf(span_len * tension, min_handle)
			var cp1: Vector2 = a + tangents[s] * h_len
			var cp2: Vector2 = b - tangents[s + 1] * h_len
			midpoints.append(a.bezier_interpolate(cp1, cp2, b, 0.5))
			var segs := 20
			var start_i := 0 if s == 0 else 1
			for i in range(start_i, segs + 1):
				var t := float(i) / float(segs)
				points.append(a.bezier_interpolate(cp1, cp2, b, t))

	else:
		# "orthogonal" (90° Manhattan) or "chamfer" (45° Metro)
		var stub_len: float = 14.0 * zoom_level
		var s0: Vector2 = p1 + n1 * stub_len
		var e0: Vector2 = p2 + n2 * stub_len

		var guide_pts: Array[Vector2] = [s0]
		for wpt in wp_canvas:
			guide_pts.append(wpt)
		guide_pts.append(e0)

		var raw_ortho := PackedVector2Array([p1, s0])
		for s in range(guide_pts.size() - 1):
			var ga: Vector2 = guide_pts[s]
			var gb: Vector2 = guide_pts[s + 1]
			var span_pts := _build_orthogonal_span(ga, gb, n1 if s == 0 else Vector2.ZERO, n2 if s == guide_pts.size() - 2 else Vector2.ZERO, wp_canvas.is_empty())
			midpoints.append(_polyline_midpoint(span_pts))
			for idx_p in range(1, span_pts.size()):
				raw_ortho.append(span_pts[idx_p])
		raw_ortho.append(p2)

		var cleaned_ortho := _clean_collinear_points(raw_ortho)
		var r_px: float = slider_val * 1.4 * zoom_level
		if eff_mode == "chamfer":
			var bev_px: float = maxf(r_px, 4.0 * zoom_level)
			points = _round_or_chamfer_polyline(cleaned_ortho, bev_px, true)
		else:
			points = _round_or_chamfer_polyline(cleaned_ortho, r_px, false) if r_px > 0.5 else cleaned_ortho

	return {
		"points": points,
		"waypoint_handles": wp_canvas,
		"midpoint_handles": midpoints,
		"effective_mode": eff_mode,
		"start_normal": n1,
		"end_normal": n2
	}

func _build_orthogonal_span(ga: Vector2, gb: Vector2, n_start: Vector2, n_end: Vector2, is_single_span: bool) -> PackedVector2Array:
	var pts := PackedVector2Array([ga])
	var dx: float = gb.x - ga.x
	var dy: float = gb.y - ga.y
	if absf(dx) < 0.5 or absf(dy) < 0.5:
		pts.append(gb)
		return pts

	if is_single_span and n_start != Vector2.ZERO and n_end != Vector2.ZERO:
		var start_horiz: bool = absf(n_start.x) >= absf(n_start.y)
		var end_horiz: bool = absf(n_end.x) >= absf(n_end.y)
		if start_horiz and end_horiz:
			if dx * n_start.x > 0.0:
				var mid_x: float = ga.x + dx * 0.5
				pts.append(Vector2(mid_x, ga.y))
				pts.append(Vector2(mid_x, gb.y))
			else:
				var step_y: float = (48.0 * zoom_level) if absf(dy) < 40.0 * zoom_level else 0.0
				var mid_y: float = (ga.y + gb.y) * 0.5 - step_y
				pts.append(Vector2(ga.x, mid_y))
				pts.append(Vector2(gb.x, mid_y))
		elif start_horiz and not end_horiz:
			pts.append(Vector2(gb.x, ga.y))
		elif not start_horiz and end_horiz:
			pts.append(Vector2(ga.x, gb.y))
		else:
			var mid_y: float = ga.y + dy * 0.5
			pts.append(Vector2(ga.x, mid_y))
			pts.append(Vector2(gb.x, mid_y))
	else:
		if absf(dx) >= absf(dy):
			var mid_x: float = ga.x + dx * 0.5
			pts.append(Vector2(mid_x, ga.y))
			pts.append(Vector2(mid_x, gb.y))
		else:
			var mid_y: float = ga.y + dy * 0.5
			pts.append(Vector2(ga.x, mid_y))
			pts.append(Vector2(gb.x, mid_y))

	pts.append(gb)
	return pts

func _polyline_midpoint(poly: PackedVector2Array) -> Vector2:
	if poly.is_empty():
		return Vector2.ZERO
	if poly.size() == 1:
		return poly[0]
	var total_len := 0.0
	for i in range(poly.size() - 1):
		total_len += poly[i].distance_to(poly[i + 1])
	if total_len < 1e-3:
		return poly[0]
	var half := total_len * 0.5
	var accum := 0.0
	for i in range(poly.size() - 1):
		var seg := poly[i].distance_to(poly[i + 1])
		if accum + seg >= half and seg > 1e-4:
			var f := clampf((half - accum) / seg, 0.0, 1.0)
			return poly[i].lerp(poly[i + 1], f)
		accum += seg
	return poly[poly.size() - 1]

func _clean_collinear_points(poly: PackedVector2Array) -> PackedVector2Array:
	if poly.size() <= 2:
		return poly
	var out := PackedVector2Array([poly[0]])
	for i in range(1, poly.size() - 1):
		var prev: Vector2 = out[out.size() - 1]
		var cur: Vector2 = poly[i]
		var nxt: Vector2 = poly[i + 1]
		if prev.distance_to(cur) < 0.5:
			continue
		var d1 := (cur - prev).normalized()
		var d2 := (nxt - cur).normalized()
		if absf(d1.cross(d2)) < 0.01 and d1.dot(d2) > 0.98:
			continue
		out.append(cur)
	if out[out.size() - 1].distance_to(poly[poly.size() - 1]) >= 0.5:
		out.append(poly[poly.size() - 1])
	return out

func _round_or_chamfer_polyline(poly: PackedVector2Array, radius_px: float, is_chamfer: bool) -> PackedVector2Array:
	if poly.size() <= 2 or radius_px <= 0.5:
		return poly
	var out := PackedVector2Array([poly[0]])
	for i in range(1, poly.size() - 1):
		var p_prev: Vector2 = poly[i - 1]
		var p_cur: Vector2 = poly[i]
		var p_next: Vector2 = poly[i + 1]
		var v_in := p_prev - p_cur
		var v_out := p_next - p_cur
		var len_in := v_in.length()
		var len_out := v_out.length()
		if len_in < 2.0 or len_out < 2.0:
			out.append(p_cur)
			continue
		var cut: float = minf(radius_px, minf(len_in, len_out) * 0.45)
		var p_a := p_cur + (v_in / len_in) * cut
		var p_b := p_cur + (v_out / len_out) * cut
		if is_chamfer:
			out.append(p_a)
			out.append(p_b)
		else:
			var arc_steps := 6
			for s in range(arc_steps + 1):
				var t := float(s) / float(arc_steps)
				var q0 := p_a.lerp(p_cur, t)
				var q1 := p_cur.lerp(p_b, t)
				out.append(q0.lerp(q1, t))
	out.append(poly[poly.size() - 1])
	return out

func _draw_connections() -> void:
	if doc_store == null or doc_store.active_document == null or _wires_layer == null:
		return

	var sel_conn_id := doc_store.selected_id if (doc_store != null and doc_store.selected_type == "connection") else ""

	for conn in doc_store.active_document.connections:
		if not _should_draw_connection(conn):
			continue
		var geom := compute_connection_geometry(conn)
		var pts: PackedVector2Array = geom["points"]
		if pts.size() < 2:
			continue

		var vis := doc_store.get_connection_visual(conn.id)
		var stroke_style: String = str(vis.get("stroke_style", "auto"))
		if stroke_style == "auto":
			stroke_style = "solid" if conn.link_type == "flow" else "dashed"
		var width: float = float(vis.get("width", 2.0))
		var col_str: String = str(vis.get("color", ""))
		var base_col := FLOW_WIRE_COLOR if conn.link_type == "flow" else SIGNAL_WIRE_COLOR
		if not col_str.is_empty():
			base_col = Color.from_string(col_str, base_col)

		var is_conn_sel: bool = (str(conn.id) == sel_conn_id) or (str(conn.id) == _hovered_channel_conn_id and not _hovered_channel_conn_id.is_empty())
		if is_conn_sel:
			_draw_styled_polyline(_wires_layer, pts, Color(0.0, 0.82, 1.0, 0.40), width + 4.0, "solid")
			var fg_col := Color("#00d2ff") if col_str.is_empty() else base_col
			_draw_styled_polyline(_wires_layer, pts, fg_col, maxf(width, 2.5), stroke_style)
			if str(conn.id) == sel_conn_id:
				_draw_wire_handles(_wires_layer, geom)
		else:
			_draw_styled_polyline(_wires_layer, pts, base_col, width, stroke_style)

func _draw_styled_polyline(target: CanvasItem, points: PackedVector2Array, col: Color, width: float, stroke_style: String) -> void:
	if points.size() < 2:
		return
	if stroke_style == "solid":
		target.draw_polyline(points, col, width, true)
	else:
		var dash_len: float = 8.0 if stroke_style == "dashed" else 2.5
		var gap_len: float = 5.0 if stroke_style == "dashed" else 4.5
		var cycle: float = dash_len + gap_len
		var dist_accum: float = 0.0
		for i in range(points.size() - 1):
			var a: Vector2 = points[i]
			var b: Vector2 = points[i + 1]
			var seg_len: float = a.distance_to(b)
			if seg_len < 0.1:
				continue
			var dir: Vector2 = (b - a) / seg_len
			var d_cur: float = 0.0
			while d_cur < seg_len:
				var phase: float = fmod(dist_accum + d_cur, cycle)
				if phase < dash_len:
					var draw_rem: float = minf(dash_len - phase, seg_len - d_cur)
					target.draw_line(a + dir * d_cur, a + dir * (d_cur + draw_rem), col, width)
					d_cur += draw_rem
				else:
					var skip_rem: float = minf(cycle - phase, seg_len - d_cur)
					d_cur += maxf(skip_rem, 0.5)
			dist_accum += seg_len

	# Draw arrowhead at destination port
	var to: Vector2 = points[points.size() - 1]
	var seg_vec: Vector2 = to - points[points.size() - 2]
	if seg_vec.length_squared() < 1e-4:
		seg_vec = to - points[0]
	if seg_vec.length_squared() >= 1e-4:
		var dir := seg_vec.normalized()
		var perp := Vector2(-dir.y, dir.x) * 5.0
		var a1 := to - (dir * 10.0) + perp
		var a2 := to - (dir * 10.0) - perp
		if abs((a1 - to).cross(a2 - to)) > 1.0:
			target.draw_colored_polygon(PackedVector2Array([to, a1, a2]), col)

func _draw_wire_handles(target: CanvasItem, geom: Dictionary) -> void:
	var mid_handles: Array = geom.get("midpoint_handles", [])
	for mp in mid_handles:
		var mpos: Vector2 = mp
		target.draw_circle(mpos, 5.5, Color("#0f1823"))
		target.draw_arc(mpos, 5.5, 0.0, TAU, 16, Color("#00d2ff"), 1.3)
		target.draw_line(mpos - Vector2(2.8, 0), mpos + Vector2(2.8, 0), Color("#00d2ff"), 1.3)
		target.draw_line(mpos - Vector2(0, 2.8), mpos + Vector2(0, 2.8), Color("#00d2ff"), 1.3)

	var wp_handles: Array = geom.get("waypoint_handles", [])
	for wp in wp_handles:
		var wpos: Vector2 = wp
		target.draw_circle(wpos, 6.5, Color(1.0, 1.0, 1.0, 0.9))
		target.draw_circle(wpos, 4.8, Color("#00d2ff"))

func _hit_test_selected_wire_waypoint(conn_id: String, canvas_mouse: Vector2) -> int:
	if doc_store == null:
		return -1
	var conn := doc_store.get_connection(conn_id)
	if conn == null:
		return -1
	var geom := compute_connection_geometry(conn)
	var wps: Array = geom.get("waypoint_handles", [])
	for i in range(wps.size()):
		if canvas_mouse.distance_to(wps[i]) <= 9.5:
			return i
	return -1

func _hit_test_selected_wire_midpoint(conn_id: String, canvas_mouse: Vector2) -> int:
	if doc_store == null:
		return -1
	var conn := doc_store.get_connection(conn_id)
	if conn == null:
		return -1
	var geom := compute_connection_geometry(conn)
	var mps: Array = geom.get("midpoint_handles", [])
	for i in range(mps.size()):
		if canvas_mouse.distance_to(mps[i]) <= 9.5:
			return i
	return -1

func _hit_test_connection(canvas_mouse: Vector2) -> String:
	if doc_store == null or doc_store.active_document == null:
		return ""
	if wire_visibility_mode == WireVisibilityMode.OFF:
		return ""

	var best_conn_id := ""
	var best_dist := 10.0

	for conn in doc_store.active_document.connections:
		if not _should_draw_connection(conn):
			continue
		var geom := compute_connection_geometry(conn)
		var pts: PackedVector2Array = geom["points"]
		if pts.size() < 2:
			continue
		for i in range(pts.size() - 1):
			var d := _dist_to_segment(canvas_mouse, pts[i], pts[i + 1])
			if d < best_dist:
				best_dist = d
				best_conn_id = conn.id

	return best_conn_id

func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var l2: float = a.distance_squared_to(b)
	if l2 == 0.0:
		return p.distance_to(a)
	var t: float = clamp((p - a).dot(b - a) / l2, 0.0, 1.0)
	var proj: Vector2 = a + (b - a) * t
	return p.distance_to(proj)

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
		points.append(from.bezier_interpolate(cp1, cp2, to, t))
	_draw_styled_polyline(target, points, col, width, "dashed" if dashed else "solid")

