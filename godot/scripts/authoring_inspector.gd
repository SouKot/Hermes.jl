# authoring_inspector.gd
# Schema-driven Property Inspector for SceneSpec simulation authoring in Godot 4.
class_name SimVizAuthoringInspector
extends ScrollContainer

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const Catalog := preload("res://scripts/authoring_catalog.gd")
const RulePanel := preload("res://scripts/authoring_rule_panel.gd")
const ConveyorCurve3D := preload("res://scripts/conveyor_curve_3d.gd")

signal duplicate_requested(element_id: String)
signal delete_requested(element_id: String)
signal rule_builder_requested(conn_id: String)
signal open_floating_requested(element_id: String, screen_pos: Vector2)
signal conveyor_geometry_mode_requested(element_id: String)

const PANEL_BG := Color("#131d2a")
const SECTION_BG := Color("#182333")
const BORDER := Color("#243347")
const TEXT := Color("#e2e8f0")
const MUTED := Color("#94a3b8")
const ACCENT := Color("#52c7a5")
const LIVE_COLOR := Color("#2ecc71")
const RESTART_COLOR := Color("#f39c12")
const DANGER := Color("#e74c3c")

var doc_store: DocumentStore
var catalog: Catalog
var is_sim_running: bool = false
var _live_element_metrics: Dictionary = {}
var _live_status_label: Label = null
var _live_util_bar: ProgressBar = null
var _live_util_label: Label = null
var _live_metric_lbl_1: Label = null
var _live_metric_lbl_2: Label = null
var _live_metric_lbl_3: Label = null

var _container: VBoxContainer
var _spin_px: SpinBox = null
var _spin_py: SpinBox = null
var _spin_pz: SpinBox = null
var _spin_rot: SpinBox = null
var _name_input: LineEdit = null
var _is_refreshing: bool = false
var _refresh_pending: bool = false
var _rule_panel: RulePanel = null

func _init(p_store: DocumentStore = null, p_catalog: Catalog = null) -> void:
	doc_store = p_store
	catalog = p_catalog if p_catalog != null else Catalog.new()
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	_container = VBoxContainer.new()
	_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_container.add_theme_constant_override("separation", 8)
	add_child(_container)

	if doc_store != null:
		doc_store.selection_changed.connect(_on_selection_changed)
		doc_store.document_modified.connect(_on_document_modified)
		doc_store.document_loaded.connect(func(_doc): refresh())

	refresh()

func set_simulation_running(running: bool) -> void:
	is_sim_running = running
	refresh()

func _is_multi_selection() -> bool:
	return doc_store != null and doc_store.selected_elements.size() > 1

func _on_selection_changed(_id: String, _type: String) -> void:
	call_deferred("refresh")

func _on_document_modified() -> void:
	if doc_store != null and doc_store.selected_type == "element" and not doc_store.selected_id.is_empty():
		var sel_elem := doc_store.get_element(doc_store.selected_id)
		if sel_elem != null and _spin_px != null and is_instance_valid(_spin_px):
			if _name_input != null and is_instance_valid(_name_input) and not _name_input.has_focus():
				_name_input.text = sel_elem.name if not sel_elem.name.is_empty() else sel_elem.id
			if not _spin_px.has_focus():
				_spin_px.set_value_no_signal(float(sel_elem.transform.position.x))
			if _spin_py != null and is_instance_valid(_spin_py) and not _spin_py.has_focus():
				_spin_py.set_value_no_signal(float(sel_elem.transform.position.y))
			if _spin_pz != null and is_instance_valid(_spin_pz) and not _spin_pz.has_focus():
				var pz: float = float(sel_elem.transform.position.z)
				_spin_pz.set_value_no_signal(pz)
			if _spin_rot != null and is_instance_valid(_spin_rot) and not _spin_rot.has_focus():
				_spin_rot.set_value_no_signal(fposmod(float(sel_elem.transform.rotation.z), 360.0))
			return
	elif doc_store != null and doc_store.selected_id.is_empty() and _name_input != null and is_instance_valid(_name_input):
		if _name_input.has_focus():
			return
	call_deferred("refresh")

func focus_name_input() -> void:
	if _name_input != null and is_instance_valid(_name_input):
		_name_input.grab_focus()
		_name_input.select_all()

func refresh() -> void:
	if _container == null:
		return
	if _is_refreshing:
		_refresh_pending = true
		return
	_is_refreshing = true
	_do_refresh()
	_is_refreshing = false
	if _refresh_pending:
		_refresh_pending = false
		call_deferred("refresh")

func _do_refresh() -> void:
	for child in _container.get_children():
		child.queue_free()

	_spin_rot = null
	_name_input = null
	_rule_panel = null

	if doc_store == null or doc_store.active_document == null:
		_render_empty_state("No active document.")
		return

	# Determine selection state
	if doc_store.selected_elements.size() > 1:
		_render_multi_selection()
	elif doc_store.selected_type == "port" and not doc_store.selected_port_id.is_empty():
		_render_port_inspection()
	elif doc_store.selected_type == "element" and not doc_store.selected_id.is_empty():
		_render_single_element(doc_store.selected_id)
	elif doc_store.selected_type == "connection" and not doc_store.selected_id.is_empty():
		_render_connection(doc_store.selected_id)
	elif doc_store.selected_type == "subgraph" and not doc_store.selected_id.is_empty():
		_render_subgraph(doc_store.selected_id)
	else:
		_render_scene_properties()

func _render_scene_properties() -> void:
	if doc_store == null or doc_store.active_document == null:
		_render_empty_state("No active document.")
		return

	var sname: String = str(doc_store.active_document.scene.get("name", "Untitled Simulation"))
	var author: String = str(doc_store.active_document.scene.get("author", "Antigravity SimViz"))
	var fpath: String = doc_store.file_path
	var fname: String = fpath.get_file() if not fpath.is_empty() else "(Unsaved Scene)"

	# 1. Header Box
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 2)

	var title_row := HBoxContainer.new()
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.color = ACCENT
	title_row.add_child(dot)

	var title_lbl := Label.new()
	title_lbl.text = "SCENE PROPERTIES"
	title_lbl.add_theme_font_size_override("font_size", 12)
	title_lbl.add_theme_color_override("font_color", TEXT)
	title_row.add_child(title_lbl)

	var status_pill := Label.new()
	status_pill.text = " [GLOBAL] "
	status_pill.add_theme_font_size_override("font_size", 9)
	status_pill.add_theme_color_override("font_color", LIVE_COLOR)
	title_row.add_child(status_pill)
	header.add_child(title_row)

	var sub_lbl := Label.new()
	sub_lbl.text = "%s • Spec v%s" % [fname, str(doc_store.active_document.spec_version)]
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", MUTED)
	header.add_child(sub_lbl)
	_container.add_child(header)

	_container.add_child(HSeparator.new())

	# 2. Scene / Simulation Name Input
	var name_box := VBoxContainer.new()
	name_box.add_theme_constant_override("separation", 2)

	var name_lbl := Label.new()
	name_lbl.text = "SCENE / SIMULATION NAME"
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", MUTED)
	name_box.add_child(name_lbl)

	_name_input = LineEdit.new()
	_name_input.text = sname
	_name_input.placeholder_text = "Enter simulation scene name..."
	_name_input.custom_minimum_size.y = 26
	_name_input.add_theme_font_size_override("font_size", 11)
	_name_input.text_submitted.connect(func(new_text: String):
		var trimmed := new_text.strip_edges()
		if not trimmed.is_empty():
			doc_store.set_scene_name(trimmed)
	)
	_name_input.focus_exited.connect(func():
		if _name_input != null and is_instance_valid(_name_input) and not _name_input.is_queued_for_deletion():
			var trimmed := _name_input.text.strip_edges()
			if not trimmed.is_empty():
				doc_store.set_scene_name(trimmed)
	)
	name_box.add_child(_name_input)
	_container.add_child(name_box)

	# 3. Author Input
	var auth_box := VBoxContainer.new()
	auth_box.add_theme_constant_override("separation", 2)

	var auth_lbl := Label.new()
	auth_lbl.text = "AUTHOR / ORGANIZATION"
	auth_lbl.add_theme_font_size_override("font_size", 10)
	auth_lbl.add_theme_color_override("font_color", MUTED)
	auth_box.add_child(auth_lbl)

	var auth_input := LineEdit.new()
	auth_input.text = author
	auth_input.placeholder_text = "Author or team name..."
	auth_input.custom_minimum_size.y = 26
	auth_input.add_theme_font_size_override("font_size", 11)
	auth_input.text_submitted.connect(func(new_text: String):
		doc_store.set_scene_author(new_text.strip_edges())
	)
	auth_input.focus_exited.connect(func():
		if auth_input != null and is_instance_valid(auth_input) and not auth_input.is_queued_for_deletion():
			doc_store.set_scene_author(auth_input.text.strip_edges())
	)
	auth_box.add_child(auth_input)
	_container.add_child(auth_box)

	# 4. File Location (Read-only)
	var file_box := VBoxContainer.new()
	file_box.add_theme_constant_override("separation", 2)
	var file_lbl := Label.new()
	file_lbl.text = "FILE LOCATION"
	file_lbl.add_theme_font_size_override("font_size", 10)
	file_lbl.add_theme_color_override("font_color", MUTED)
	file_box.add_child(file_lbl)

	var path_disp := LineEdit.new()
	path_disp.text = fpath if not fpath.is_empty() else "(Unsaved - click File > Save to save)"
	path_disp.editable = false
	path_disp.custom_minimum_size.y = 24
	path_disp.add_theme_font_size_override("font_size", 10)
	path_disp.add_theme_color_override("font_color", MUTED)
	file_box.add_child(path_disp)
	_container.add_child(file_box)

	_container.add_child(HSeparator.new())

	# 5. Scene Statistics
	var stats_box := VBoxContainer.new()
	stats_box.add_theme_constant_override("separation", 4)
	var stats_title := Label.new()
	stats_title.text = "MODEL INVENTORY"
	stats_title.add_theme_font_size_override("font_size", 10)
	stats_title.add_theme_color_override("font_color", MUTED)
	stats_box.add_child(stats_title)

	var elem_cnt: int = doc_store.active_document.elements.size()
	var conn_cnt: int = doc_store.active_document.connections.size()
	var sub_cnt: int = doc_store.active_document.subgraphs.size()

	var stat_row1 := Label.new()
	stat_row1.text = "• Entity Blocks: %d\n• Flow Connections: %d\n• Subgraph Macros: %d" % [elem_cnt, conn_cnt, sub_cnt]
	stat_row1.add_theme_font_size_override("font_size", 10)
	stat_row1.add_theme_color_override("font_color", TEXT)
	stats_box.add_child(stat_row1)
	_container.add_child(stats_box)

	_container.add_child(HSeparator.new())

	var tip := Label.new()
	tip.text = "Tip: Select any block or queue on the canvas to inspect its operational properties."
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_font_size_override("font_size", 10)
	tip.add_theme_color_override("font_color", MUTED)
	_container.add_child(tip)

func _render_empty_state(msg: String) -> void:
	var lbl := Label.new()
	lbl.text = msg
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", MUTED)
	_container.add_child(lbl)

# ============================================================================
# 1. Single Element Inspector
# ============================================================================
func _render_single_element(elem_id: String) -> void:
	var elem: SceneTypes.SceneElement = doc_store.get_element(elem_id)
	if elem == null:
		_render_empty_state("Element '%s' not found." % elem_id)
		return

	var entry: Catalog.CatalogEntry = catalog.get_entry(elem.kind)
	var cat_name := entry.category if entry != null else "Equipment"
	var disp_name := entry.display_name if entry != null else elem.kind.capitalize()

	# 1. Header Box
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 2)

	var title_row := HBoxContainer.new()
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.color = Color(elem.editor.color) if not elem.editor.color.is_empty() else ACCENT
	title_row.add_child(dot)

	var title_lbl := Label.new()
	title_lbl.text = elem.name if not elem.name.is_empty() else elem.id
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", TEXT)
	title_row.add_child(title_lbl)

	var kind_pill := Label.new()
	kind_pill.text = " [%s] " % elem.kind.to_upper()
	kind_pill.add_theme_font_size_override("font_size", 9)
	kind_pill.add_theme_color_override("font_color", MUTED)
	title_row.add_child(kind_pill)
	header.add_child(title_row)

	var sub_lbl := Label.new()
	sub_lbl.text = "%s • %s • ID: %s" % [disp_name, cat_name, elem.id]
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", MUTED)
	header.add_child(sub_lbl)
	_container.add_child(header)

	# Live Telemetry & Operational KPIs Section
	var live_card := _build_live_telemetry_card(elem)
	if live_card != null:
		_container.add_child(live_card)
		_container.add_child(HSeparator.new())

	# Name & Identification Section
	var name_box := VBoxContainer.new()
	name_box.add_theme_constant_override("separation", 2)

	var name_lbl := Label.new()
	name_lbl.text = "NAME / LABEL"
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", MUTED)
	name_box.add_child(name_lbl)

	_name_input = LineEdit.new()
	_name_input.text = elem.name if not elem.name.is_empty() else elem.id
	_name_input.placeholder_text = "Enter block display name..."
	_name_input.custom_minimum_size.y = 26
	_name_input.add_theme_font_size_override("font_size", 11)
	_name_input.text_submitted.connect(func(new_text: String):
		var trimmed := new_text.strip_edges()
		if not trimmed.is_empty() and trimmed != elem.name:
			doc_store.rename_element(elem.id, trimmed)
	)
	_name_input.focus_exited.connect(func():
		if _name_input != null and is_instance_valid(_name_input) and not _name_input.is_queued_for_deletion():
			var trimmed := _name_input.text.strip_edges()
			if not trimmed.is_empty() and trimmed != elem.name:
				doc_store.rename_element(elem.id, trimmed)
	)
	name_box.add_child(_name_input)
	_container.add_child(name_box)

	var open_float_btn := Button.new()
	open_float_btn.text = "⛶ Open Floating Tabs (Right-Click)"
	open_float_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_float_btn.add_theme_font_size_override("font_size", 10)
	open_float_btn.add_theme_color_override("font_color", ACCENT)
	open_float_btn.pressed.connect(func():
		open_floating_requested.emit(elem.id, Vector2.ZERO)
	)
	_container.add_child(open_float_btn)

	_container.add_child(HSeparator.new())

	# 2. Primary DES Parameter (High-Level Summary)
	if entry != null and not entry.property_schemas.is_empty():
		var pri_lbl := Label.new()
		pri_lbl.text = "PRIMARY PARAMETER"
		pri_lbl.add_theme_font_size_override("font_size", 10)
		pri_lbl.add_theme_color_override("font_color", MUTED)
		_container.add_child(pri_lbl)

		# Build only the primary operational parameter (first schema in catalog)
		var primary_schema: Dictionary = entry.property_schemas[0]
		_build_property_widget(elem, primary_schema)

		var note_lbl := Label.new()
		note_lbl.text = "Right-click machine or click above for all parameters, 3D CAD & ports."
		note_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note_lbl.add_theme_font_size_override("font_size", 9)
		note_lbl.add_theme_color_override("font_color", MUTED)
		_container.add_child(note_lbl)

		_container.add_child(HSeparator.new())


	if elem.kind in ["queue", "server", "conveyor"]:
		if _rule_panel == null:
			_rule_panel = RulePanel.new()
			_rule_panel.rule_changed.connect(_on_rule_changed)
			_container.add_child(_rule_panel)
		_rule_panel.configure(elem.id, elem.kind, elem.properties)
		_rule_panel.visible = true

	if elem.kind == "conveyor":
		_build_conveyor_shape_section(elem)
		_container.add_child(HSeparator.new())

	# 3. Position Coordinates (Compact X, Y, Z glance)
	var pos_lbl := Label.new()
	pos_lbl.text = "POSITION (X, Y, Z)"
	pos_lbl.add_theme_font_size_override("font_size", 10)
	pos_lbl.add_theme_color_override("font_color", MUTED)
	_container.add_child(pos_lbl)

	var px: float = float(elem.transform.position.x)
	var py: float = float(elem.transform.position.y)
	var pz: float = float(elem.transform.position.z)

	var pos_row := HBoxContainer.new()
	pos_row.add_theme_constant_override("separation", 6)
	_container.add_child(pos_row)

	_spin_px = _create_dock_mini_spin(pos_row, "X (m)", px, -500.0, 500.0, 0.5, func(v):
		elem.transform.position.x = v
		elem.editor.graph_position.x = v * 20.0
		doc_store.validate()
		doc_store.document_modified.emit()
	)
	_spin_py = _create_dock_mini_spin(pos_row, "Y (m)", py, -500.0, 500.0, 0.5, func(v):
		elem.transform.position.y = v
		elem.editor.graph_position.y = v * 20.0
		doc_store.validate()
		doc_store.document_modified.emit()
	)
	_spin_pz = _create_dock_mini_spin(pos_row, "Z (m)", pz, -500.0, 500.0, 0.5, func(v):
		elem.transform.position.z = v
		doc_store.validate()
		doc_store.document_modified.emit()
	)

	_container.add_child(HSeparator.new())

	# 4. Actions (Duplicate / Delete)
	var act_row := HBoxContainer.new()
	act_row.add_theme_constant_override("separation", 6)

	var dup_btn := Button.new()
	dup_btn.text = "Duplicate (Ctrl+D)"
	dup_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dup_btn.add_theme_font_size_override("font_size", 10)
	dup_btn.pressed.connect(func(): duplicate_requested.emit(elem.id))
	act_row.add_child(dup_btn)

	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.add_theme_font_size_override("font_size", 10)
	del_btn.add_theme_color_override("font_color", DANGER)
	del_btn.pressed.connect(func(): delete_requested.emit(elem.id))
	act_row.add_child(del_btn)

	_container.add_child(act_row)

func _build_live_telemetry_card(elem: SceneTypes.SceneElement) -> Control:
	var elem_id: String = elem.id
	var metrics: Dictionary = {}
	if _live_element_metrics.has(elem_id):
		var raw = _live_element_metrics[elem_id]
		if raw is Dictionary:
			metrics = raw.get("custom_metrics", {})

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#111a26")
	style.border_color = Color("#243347")
	style.border_width_left = 3
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_right = 4
	style.corner_radius_bottom_left = 4
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	vbox.add_theme_constant_override("margin_left", 8)
	vbox.add_theme_constant_override("margin_top", 6)
	vbox.add_theme_constant_override("margin_right", 8)
	vbox.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(vbox)

	var hdr := HBoxContainer.new()
	var tag := Label.new()
	tag.text = "LIVE TELEMETRY"
	tag.add_theme_font_size_override("font_size", 10)
	tag.add_theme_color_override("font_color", LIVE_COLOR)
	hdr.add_child(tag)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(spacer)

	_live_status_label = Label.new()
	_live_status_label.add_theme_font_size_override("font_size", 10)
	hdr.add_child(_live_status_label)
	vbox.add_child(hdr)

	_live_util_bar = ProgressBar.new()
	_live_util_bar.custom_minimum_size.y = 12
	_live_util_bar.show_percentage = false
	_live_util_bar.min_value = 0.0
	_live_util_bar.max_value = 100.0
	vbox.add_child(_live_util_bar)

	_live_util_label = Label.new()
	_live_util_label.add_theme_font_size_override("font_size", 10)
	_live_util_label.add_theme_color_override("font_color", TEXT)
	vbox.add_child(_live_util_label)

	_live_metric_lbl_1 = Label.new()
	_live_metric_lbl_1.add_theme_font_size_override("font_size", 10)
	_live_metric_lbl_1.add_theme_color_override("font_color", MUTED)
	vbox.add_child(_live_metric_lbl_1)

	_live_metric_lbl_2 = Label.new()
	_live_metric_lbl_2.add_theme_font_size_override("font_size", 10)
	_live_metric_lbl_2.add_theme_color_override("font_color", MUTED)
	vbox.add_child(_live_metric_lbl_2)

	_live_metric_lbl_3 = Label.new()
	_live_metric_lbl_3.add_theme_font_size_override("font_size", 10)
	_live_metric_lbl_3.add_theme_color_override("font_color", ACCENT)
	vbox.add_child(_live_metric_lbl_3)

	_update_live_card_fields(elem.kind, metrics)
	return panel

func _update_live_card_fields(kind: String, metrics: Dictionary) -> void:
	if _live_status_label == null or not is_instance_valid(_live_status_label):
		return

	if metrics.is_empty():
		_live_status_label.text = "STANDBY"
		_live_status_label.add_theme_color_override("font_color", MUTED)
		if _live_util_bar != null and is_instance_valid(_live_util_bar):
			_live_util_bar.value = 0.0
		if _live_util_label != null and is_instance_valid(_live_util_label):
			_live_util_label.text = "Waiting for simulation to run..."
		if _live_metric_lbl_1 != null and is_instance_valid(_live_metric_lbl_1): _live_metric_lbl_1.text = ""
		if _live_metric_lbl_2 != null and is_instance_valid(_live_metric_lbl_2): _live_metric_lbl_2.text = ""
		if _live_metric_lbl_3 != null and is_instance_valid(_live_metric_lbl_3): _live_metric_lbl_3.text = ""
		return

	match kind:
		"server":
			var state_str: String = str(metrics.get("state", "IDLE"))
			_live_status_label.text = "● " + state_str
			if state_str == "BUSY":
				_live_status_label.add_theme_color_override("font_color", LIVE_COLOR)
			elif state_str == "DOWN":
				_live_status_label.add_theme_color_override("font_color", DANGER)
			elif state_str == "PARTIAL":
				_live_status_label.add_theme_color_override("font_color", RESTART_COLOR)
			else:
				_live_status_label.add_theme_color_override("font_color", MUTED)

			var util_pct: float = float(metrics.get("utilization_pct", 0.0))
			_live_util_bar.value = util_pct
			_live_util_label.text = "Utilization: %.1f%%  (%d/%d busy)" % [
				util_pct, int(metrics.get("busy_servers", 0)), int(metrics.get("num_servers", 1))
			]
			_live_metric_lbl_1.text = "Total Completed: %d units" % int(metrics.get("total_served", 0))
			_live_metric_lbl_2.text = "Mean Service Time: %.2f s" % float(metrics.get("service_mean", 0.0))
			_live_metric_lbl_3.text = "Instantaneous Load: %.1f%%" % float(metrics.get("instant_util_pct", 0.0))

		"queue":
			var q_len: int = int(metrics.get("queue_length", 0))
			var cap: int = int(metrics.get("capacity", 20))
			var occ_pct: float = float(metrics.get("occupancy_pct", 0.0))
			_live_status_label.text = "%d / %d" % [q_len, cap]
			_live_status_label.add_theme_color_override("font_color", ACCENT if q_len < cap else DANGER)
			_live_util_bar.value = occ_pct
			_live_util_label.text = "Occupancy: %d / %d items (%.1f%%)" % [q_len, cap, occ_pct]
			_live_metric_lbl_1.text = "Mean Wait (Wq): %.2f s" % float(metrics.get("wait_mean_wq", 0.0))
			_live_metric_lbl_2.text = "Flow: In %d  |  Out %d" % [int(metrics.get("total_entered", 0)), int(metrics.get("total_departed", 0))]
			_live_metric_lbl_3.text = "Status: %s" % ("FULL / BLOCKED" if q_len >= cap else "FLOWING")

		"conveyor":
			var in_transit: int = int(metrics.get("items_in_transit", 0))
			var spd: float = float(metrics.get("speed", 1.5))
			var t_tau: float = float(metrics.get("transit_delay", 2.0))
			_live_status_label.text = "● RUNNING"
			_live_status_label.add_theme_color_override("font_color", LIVE_COLOR)
			_live_util_bar.value = clamp(float(in_transit) * 20.0, 0.0, 100.0)
			_live_util_label.text = "Active on Belt: %d cartons" % in_transit
			_live_metric_lbl_1.text = "Belt Speed: %.2f m/s (transit: %.2f s)" % [spd, t_tau]
			_live_metric_lbl_2.text = "Total Handed Over: %d items" % int(metrics.get("total_transited", 0))
			_live_metric_lbl_3.text = "Length: %.1f m" % float(metrics.get("length", 10.0))

		"sink":
			var dep_count: int = int(metrics.get("total_departures", 0))
			var rate_sec: float = float(metrics.get("throughput_per_sec", 0.0))
			var rate_min: float = float(metrics.get("throughput_per_min", 0.0))
			_live_status_label.text = "DRAINING"
			_live_status_label.add_theme_color_override("font_color", ACCENT)
			_live_util_bar.value = 100.0
			_live_util_label.text = "Total Absorbed: %d units" % dep_count
			_live_metric_lbl_1.text = "Throughput Rate: %.2f / sec" % rate_sec
			_live_metric_lbl_2.text = "Production Yield: %.1f units / min" % rate_min
			_live_metric_lbl_3.text = "Status: ACTIVE SINK"

		"source":
			var arr_count: int = int(metrics.get("total_arrivals", 0))
			var rate_sec: float = float(metrics.get("rate_per_sec", 0.0))
			_live_status_label.text = "FEEDING"
			_live_status_label.add_theme_color_override("font_color", LIVE_COLOR)
			_live_util_bar.value = 100.0
			_live_util_label.text = "Total Generated: %d units" % arr_count
			_live_metric_lbl_1.text = "Injection Rate: %.2f / sec" % rate_sec
			_live_metric_lbl_2.text = "Output Flow: %.1f units / min" % (rate_sec * 60.0)
			_live_metric_lbl_3.text = "Status: EMITTING"

		_:
			_live_status_label.text = "ACTIVE"
			_live_util_bar.value = 50.0
			_live_util_label.text = "Kind: " + kind
			_live_metric_lbl_1.text = ""
			_live_metric_lbl_2.text = ""
			_live_metric_lbl_3.text = ""

func update_live_element_metrics(elements_by_id: Dictionary) -> void:
	_live_element_metrics = elements_by_id
	if doc_store == null or doc_store.selected_type != "element" or doc_store.selected_id.is_empty():
		return
	var elem_id: String = doc_store.selected_id
	if elements_by_id.has(elem_id):
		var raw = elements_by_id[elem_id]
		if raw is Dictionary:
			var metrics: Dictionary = raw.get("custom_metrics", {})
			var elem := doc_store.get_element(elem_id)
			if elem != null:
				_update_live_card_fields(elem.kind, metrics)

# ============================================================================
# 2. Port Properties Inspector
# ============================================================================
func _render_port_inspection() -> void:
	var elem: SceneTypes.SceneElement = doc_store.get_element(doc_store.selected_id)
	var port: SceneTypes.ScenePort = doc_store.get_selected_port()
	if elem == null or port == null:
		_render_empty_state("Port not found.")
		return

	# Header with Back button
	var back_btn := Button.new()
	back_btn.text = "← Back to %s" % elem.id
	back_btn.add_theme_font_size_override("font_size", 10)
	back_btn.pressed.connect(func(): doc_store.select(elem.id, "element"))
	_container.add_child(back_btn)

	var header := VBoxContainer.new()
	var title_lbl := Label.new()
	title_lbl.text = "%s.%s" % [elem.id, port.id]
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", TEXT)
	header.add_child(title_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = "Kind: %s • Direction: %s" % [port.kind.capitalize(), port.direction.capitalize()]
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", MUTED)
	header.add_child(sub_lbl)
	_container.add_child(header)

	_container.add_child(HSeparator.new())

	# Buffer & Chute Capacity
	var cur_cap: int = int(port.get_extension("chute_buffer_capacity", port.get_extension("chute_capacity", 0)))
	_add_spinbox("Chute Buffer Capacity", float(cur_cap), 0.0, 100.0, 1.0, func(v):
		doc_store.update_port_properties(elem.id, port.id, {"chute_buffer_capacity": int(v), "chute_capacity": int(v)})
	)

	# Transfer Latency
	var cur_lat: float = float(port.get_extension("conveyance_handshake_latency_sec", port.get_extension("latency", 0.0)))
	_add_spinbox("Transfer Latency (s)", cur_lat, 0.0, 60.0, 0.05, func(v):
		doc_store.update_port_properties(elem.id, port.id, {"conveyance_handshake_latency_sec": v, "latency": v})
	)

	# Cardinality
	var card_row := HBoxContainer.new()
	var card_lbl := Label.new()
	card_lbl.text = "Cardinality"
	card_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_lbl.add_theme_font_size_override("font_size", 10)
	card_lbl.add_theme_color_override("font_color", MUTED)
	card_row.add_child(card_lbl)

	var card_opt := OptionButton.new()
	card_opt.add_item("Single (one)", 0)
	card_opt.add_item("Multiple (many)", 1)
	card_opt.select(1 if port.cardinality == "many" else 0)
	card_opt.add_theme_font_size_override("font_size", 10)
	card_opt.item_selected.connect(func(idx):
		var val := "many" if idx == 1 else "one"
		doc_store.update_port_properties(elem.id, port.id, {"cardinality": val})
	)
	card_row.add_child(card_opt)
	_container.add_child(card_row)

	# Disconnect action
	var disc_btn := Button.new()
	disc_btn.text = "Disconnect Port"
	disc_btn.add_theme_font_size_override("font_size", 10)
	disc_btn.add_theme_color_override("font_color", DANGER)
	disc_btn.pressed.connect(func(): doc_store.disconnect_port(elem.id, port.id))
	_container.add_child(disc_btn)

# ============================================================================
# 3. Multi-Selection Inspector (Mixed Values)
# ============================================================================
func _render_multi_selection() -> void:
	var count := doc_store.selected_elements.size()
	var header := VBoxContainer.new()
	var title_lbl := Label.new()
	title_lbl.text = "%d Entities Selected" % count
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", TEXT)
	header.add_child(title_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = "Multi-Element Batch Editing"
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", MUTED)
	header.add_child(sub_lbl)
	_container.add_child(header)

	_container.add_child(HSeparator.new())

	# Find common property keys across all selected elements
	var common_props := {}
	var first_elem: SceneTypes.SceneElement = doc_store.get_element(doc_store.selected_elements[0])
	if first_elem != null:
		var entry: Catalog.CatalogEntry = catalog.get_entry(first_elem.kind)
		if entry != null:
			for s in entry.property_schemas:
				common_props[s["key"]] = s

	for i in range(1, doc_store.selected_elements.size()):
		var eid: String = doc_store.selected_elements[i]
		var elem: SceneTypes.SceneElement = doc_store.get_element(eid)
		if elem == null:
			continue
		var entry: Catalog.CatalogEntry = catalog.get_entry(elem.kind)
		var this_keys := {}
		if entry != null:
			for s in entry.property_schemas:
				this_keys[s["key"]] = true
		for k in common_props.keys():
			if not this_keys.has(k):
				common_props.erase(k)

	if common_props.is_empty():
		var no_common := Label.new()
		no_common.text = "Selected items do not share configurable schema properties."
		no_common.add_theme_font_size_override("font_size", 10)
		no_common.add_theme_color_override("font_color", MUTED)
		_container.add_child(no_common)
	else:
		var comm_lbl := Label.new()
		comm_lbl.text = "COMMON PROPERTIES"
		comm_lbl.add_theme_font_size_override("font_size", 10)
		comm_lbl.add_theme_color_override("font_color", MUTED)
		_container.add_child(comm_lbl)

		for k in common_props.keys():
			var schema: Dictionary = common_props[k]
			_build_multi_property_widget(doc_store.selected_elements, schema)

	_container.add_child(HSeparator.new())

	# Batch Delete
	var del_btn := Button.new()
	del_btn.text = "Delete All %d Elements" % count
	del_btn.add_theme_font_size_override("font_size", 10)
	del_btn.add_theme_color_override("font_color", DANGER)
	del_btn.pressed.connect(func(): doc_store.remove_elements(doc_store.selected_elements))
	_container.add_child(del_btn)

# ============================================================================
# 4. Connection Inspector
# ============================================================================
func _render_connection(conn_id: String) -> void:
	var target_conn: SceneTypes.SceneConnection = null
	for c in doc_store.active_document.connections:
		if c.id == conn_id:
			target_conn = c
			break
	if target_conn == null:
		_render_empty_state("Connection not found.")
		return

	var header := VBoxContainer.new()
	var title_lbl := Label.new()
	title_lbl.text = "Connection: %s" % target_conn.id
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", TEXT)
	header.add_child(title_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = "%s.%s → %s.%s (%s)" % [
		target_conn.source_element, target_conn.source_port,
		target_conn.target_element, target_conn.target_port,
		target_conn.link_type.capitalize()
	]
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", MUTED)
	header.add_child(sub_lbl)
	_container.add_child(header)

	_container.add_child(HSeparator.new())

	# Condition summary / Rule builder
	var cond_lbl := Label.new()
	cond_lbl.text = "ROUTING & DISPATCH CONDITION"
	cond_lbl.add_theme_font_size_override("font_size", 10)
	cond_lbl.add_theme_color_override("font_color", MUTED)
	_container.add_child(cond_lbl)

	if target_conn.condition != null and not (target_conn.condition is Dictionary and target_conn.condition.is_empty()):
		var cond_desc := Label.new()
		cond_desc.text = JSON.stringify(target_conn.condition)
		cond_desc.add_theme_font_size_override("font_size", 10)
		cond_desc.add_theme_color_override("font_color", LIVE_COLOR)
		_container.add_child(cond_desc)
	else:
		var no_cond := Label.new()
		no_cond.text = "Unconditional (Always Active)"
		no_cond.add_theme_font_size_override("font_size", 10)
		no_cond.add_theme_color_override("font_color", MUTED)
		_container.add_child(no_cond)


	if _rule_panel == null:
		_rule_panel = RulePanel.new()
		_rule_panel.rule_changed.connect(_on_rule_changed)
		_container.add_child(_rule_panel)
	var cond_dict = target_conn.condition if target_conn.condition is Dictionary else {}
	_rule_panel.configure(target_conn.id, "connection", cond_dict)
	_rule_panel.visible = true
	var rule_btn := Button.new()
	rule_btn.text = "Edit Condition / Rule..."
	rule_btn.add_theme_font_size_override("font_size", 10)
	rule_btn.pressed.connect(func(): rule_builder_requested.emit(target_conn.id))
	_container.add_child(rule_btn)

	var del_btn := Button.new()
	del_btn.text = "Delete Connection"
	del_btn.add_theme_font_size_override("font_size", 10)
	del_btn.add_theme_color_override("font_color", DANGER)
	del_btn.pressed.connect(func(): doc_store.remove_connection(target_conn.id))
	_container.add_child(del_btn)

# ============================================================================
# Dynamic Schema Widget Builders
# ============================================================================
func _build_property_widget(elem: SceneTypes.SceneElement, schema: Dictionary) -> void:
	var key: String = schema.get("key", "")
	var disp: String = schema.get("display_name", key.capitalize())
	var p_type: String = schema.get("type", "float")
	var unit: String = schema.get("unit", "")
	var is_live: bool = bool(schema.get("runtime_editable", false))
	var cur_val = elem.properties.get(key, schema.get("default_value"))

	# Progressive disclosure: Hide MTBF/MTTR/failure_rate when failure_model is None
	if key in ["mtbf", "mttr", "failure_rate"] and elem.properties.get("failure_model", "None") == "None":
		return

	# Live/Restart Badge Row
	var label_row := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = disp
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", TEXT)
	label_row.add_child(name_lbl)

	var badge := Label.new()
	badge.text = "[LIVE]" if is_live else "[RESTART]"
	badge.add_theme_font_size_override("font_size", 8)
	badge.add_theme_color_override("font_color", LIVE_COLOR if is_live else RESTART_COLOR)
	label_row.add_child(badge)
	_container.add_child(label_row)

	if p_type == "distribution":
		_build_distribution_editor(elem, key, cur_val, is_live)
	elif p_type == "enum":
		var opts: Array = schema.get("enum_options", schema.get("options", []))
		_build_enum_editor(elem, key, cur_val, opts, is_live)
	elif p_type == "bool":
		_build_bool_editor(elem, key, bool(cur_val), is_live)
	elif p_type == "string":
		var le := LineEdit.new()
		le.text = str(cur_val)
		le.custom_minimum_size.x = 160
		le.add_theme_font_size_override("font_size", 9)
		le.text_submitted.connect(func(new_text):
			doc_store.set_element_property(elem.id, key, new_text)
		)
		le.focus_exited.connect(func():
			doc_store.set_element_property(elem.id, key, le.text)
		)
		_container.add_child(le)
	else:
		# Numeric scalar float / int
		var range_arr: Array = schema.get("range", [0.0, 1000.0, 0.1])
		var min_v: float = range_arr[0] if range_arr.size() >= 1 else 0.0
		var max_v: float = range_arr[1] if range_arr.size() >= 2 else 1000.0
		var step_v: float = range_arr[2] if range_arr.size() >= 3 else 0.1

		var f_val := float(cur_val) if (cur_val is float or cur_val is int) else 0.0
		var sp := _add_spinbox(unit, f_val, min_v, max_v, step_v, func(v):
			var final_val = int(v) if p_type == "int" else v
			doc_store.set_element_property(elem.id, key, final_val)
		)
		if is_sim_running and not is_live:
			sp.editable = false

func _build_multi_property_widget(elem_ids: Array, schema: Dictionary) -> void:
	var key: String = schema.get("key", "")
	var disp: String = schema.get("display_name", key.capitalize())
	var p_type: String = schema.get("type", "float")
	var unit: String = schema.get("unit", "")

	# Check for mixed values
	var first_val = null
	var is_mixed := false
	for eid in elem_ids:
		var elem := doc_store.get_element(eid)
		if elem != null:
			var v = elem.properties.get(key, null)
			if first_val == null:
				first_val = v
			elif first_val != v:
				is_mixed = true
				break

	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = disp + (" [MIXED]" if is_mixed else "")
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", RESTART_COLOR if is_mixed else TEXT)
	row.add_child(lbl)

	if is_mixed:
		var edit := LineEdit.new()
		edit.placeholder_text = "— Mixed Values —"
		edit.custom_minimum_size.x = 100
		edit.add_theme_font_size_override("font_size", 9)
		edit.text_submitted.connect(func(t: String):
			if t.is_valid_float():
				var f := t.to_float()
				var final_val = int(f) if p_type == "int" else f
				doc_store.set_elements_property_batch(elem_ids, key, final_val)
		)
		row.add_child(edit)
	else:
		var f_val: float = float(first_val) if (first_val is float or first_val is int) else 0.0
		var range_arr: Array = schema.get("range", [0.0, 1000.0, 0.1])
		var sp := SpinBox.new()
		sp.min_value = range_arr[0] if range_arr.size() >= 1 else 0.0
		sp.max_value = range_arr[1] if range_arr.size() >= 2 else 1000.0
		sp.step = range_arr[2] if range_arr.size() >= 3 else 0.1
		sp.value = f_val
		sp.suffix = unit
		sp.custom_minimum_size.x = 100
		sp.add_theme_font_size_override("font_size", 9)
		sp.value_changed.connect(func(v):
			var final_val = int(v) if p_type == "int" else v
			doc_store.set_elements_property_batch(elem_ids, key, final_val)
		)
		row.add_child(sp)

	_container.add_child(row)

func _build_distribution_editor(elem: SceneTypes.SceneElement, prop_key: String, cur_val, is_live: bool) -> void:
	var dist_map := {}
	if cur_val is Dictionary:
		dist_map = cur_val
	else:
		dist_map = {"type": "constant", "value": float(cur_val) if cur_val != null else 4.0}

	var d_type: String = str(dist_map.get("type", "constant"))

	var type_row := HBoxContainer.new()
	var type_opt := OptionButton.new()
	type_opt.add_item("Triangular (PERT)", 0)
	type_opt.add_item("Exponential (M/M/c)", 1)
	type_opt.add_item("Normal (Gaussian)", 2)
	type_opt.add_item("Uniform", 3)
	type_opt.add_item("Constant", 4)
	type_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_opt.add_theme_font_size_override("font_size", 9)

	match d_type:
		"triangular": type_opt.select(0)
		"exponential": type_opt.select(1)
		"normal": type_opt.select(2)
		"uniform": type_opt.select(3)
		_: type_opt.select(4)

	type_opt.item_selected.connect(func(idx):
		var new_map := {}
		match idx:
			0: new_map = {"type": "triangular", "min": 2.0, "mode": 4.5, "max": 7.0}
			1: new_map = {"type": "exponential", "mean": 3.0}
			2: new_map = {"type": "normal", "mean": 4.5, "std_dev": 0.8}
			3: new_map = {"type": "uniform", "min": 2.0, "max": 6.0}
			_: new_map = {"type": "constant", "value": 4.5}
		doc_store.set_element_property(elem.id, prop_key, new_map)
	)
	type_row.add_child(type_opt)
	_container.add_child(type_row)

	# Parameter Inputs
	if d_type == "triangular":
		var p_row := HBoxContainer.new()
		p_row.add_theme_constant_override("separation", 2)
		_add_mini_spin(p_row, "Min", float(dist_map.get("min", 2.0)), func(v):
			dist_map["min"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_add_mini_spin(p_row, "Mode", float(dist_map.get("mode", 4.5)), func(v):
			dist_map["mode"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_add_mini_spin(p_row, "Max", float(dist_map.get("max", 7.0)), func(v):
			dist_map["max"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_container.add_child(p_row)
	elif d_type == "exponential":
		var p_row := HBoxContainer.new()
		_add_mini_spin(p_row, "Mean (s)", float(dist_map.get("mean", 3.0)), func(v):
			dist_map["mean"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_container.add_child(p_row)
	elif d_type == "normal":
		var p_row := HBoxContainer.new()
		_add_mini_spin(p_row, "Mean (μ)", float(dist_map.get("mean", 4.5)), func(v):
			dist_map["mean"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_add_mini_spin(p_row, "Std (σ)", float(dist_map.get("std_dev", 0.8)), func(v):
			dist_map["std_dev"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_container.add_child(p_row)
	else:
		var p_row := HBoxContainer.new()
		_add_mini_spin(p_row, "Value (s)", float(dist_map.get("value", 4.5)), func(v):
			dist_map["value"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_container.add_child(p_row)

	# Sparkline Preview
	var sparkline := DistributionSparkline.new(dist_map)
	sparkline.custom_minimum_size = Vector2(100, 24)
	_container.add_child(sparkline)

func _build_enum_editor(elem: SceneTypes.SceneElement, prop_key: String, cur_val, options: Array, is_live: bool) -> void:
	if options.is_empty():
		return

	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_theme_font_size_override("font_size", 9)
	_container.add_child(opt)

	var sel_idx := -1
	for i in range(options.size()):
		var item = options[i]
		var val_str: String = item.get("value", "") if item is Dictionary else str(item)
		var label_str: String = item.get("label", val_str) if item is Dictionary else str(item)
		opt.add_item(label_str, i)
		if val_str == str(cur_val):
			sel_idx = i

	if opt.item_count > 0:
		if sel_idx < 0:
			sel_idx = 0
		opt.selected = sel_idx

	opt.item_selected.connect(func(idx):
		if idx >= 0 and idx < options.size():
			var sel_item = options[idx]
			var val_str: String = sel_item.get("value", "") if sel_item is Dictionary else str(sel_item)
			doc_store.set_element_property(elem.id, prop_key, val_str)
	)
	if is_sim_running and not is_live:
		opt.disabled = true

func _build_bool_editor(elem: SceneTypes.SceneElement, prop_key: String, cur_val: bool, is_live: bool) -> void:
	var chk := CheckBox.new()
	chk.text = "Enabled"
	chk.button_pressed = cur_val
	chk.add_theme_font_size_override("font_size", 10)
	chk.toggled.connect(func(v: bool):
		doc_store.set_element_property(elem.id, prop_key, v)
	)
	if is_sim_running and not is_live:
		chk.disabled = true
	_container.add_child(chk)

# ============================================================================
# Helpers
# ============================================================================
func _add_spinbox(label_text: String, current_val: float, min_val: float, max_val: float, step_val: float, on_change: Callable) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", MUTED)
	row.add_child(lbl)

	var sp := SpinBox.new()
	sp.min_value = min_val
	sp.max_value = max_val
	sp.step = step_val
	sp.value = current_val
	sp.custom_minimum_size.x = 90
	sp.add_theme_font_size_override("font_size", 9)
	sp.value_changed.connect(on_change)
	row.add_child(sp)

	_container.add_child(row)
	return sp

func _add_mini_spin(parent: Control, label: String, val: float, on_change: Callable) -> void:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 8)
	l.add_theme_color_override("font_color", MUTED)
	vbox.add_child(l)

	var sp := SpinBox.new()
	sp.min_value = 0.05
	sp.max_value = 3600.0
	sp.step = 0.1
	sp.value = val
	sp.add_theme_font_size_override("font_size", 8)
	sp.value_changed.connect(on_change)
	vbox.add_child(sp)
	parent.add_child(vbox)

func _create_dock_mini_spin(parent: Control, label_text: String, val: float, min_v: float, max_v: float, step_v: float, on_change: Callable) -> SpinBox:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := Label.new()
	l.text = label_text
	l.add_theme_font_size_override("font_size", 8)
	l.add_theme_color_override("font_color", MUTED)
	vbox.add_child(l)

	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = step_v
	sp.value = val
	sp.add_theme_font_size_override("font_size", 8)
	sp.value_changed.connect(on_change)
	vbox.add_child(sp)
	parent.add_child(vbox)
	return sp

# ============================================================================
# Sparkline Visualizer Inner Class
# ============================================================================
class DistributionSparkline extends Control:
	var dist_map: Dictionary
	var dist_data: Dictionary:
		get: return dist_map
		set(v):
			dist_map = v
			queue_redraw()

	func _init(p_map: Dictionary = {}) -> void:
		dist_map = p_map
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_distribution(d: Dictionary) -> void:
		dist_map = d
		queue_redraw()

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		draw_rect(rect, Color("#09111be0"), true)
		draw_rect(rect, Color("#243347"), false, 1.0)

		var d_type: String = str(dist_map.get("type", dist_map.get("distribution", "constant")))
		var points: PackedVector2Array = []
		var steps := 24
		var h := size.y - 4.0
		var w := size.x - 4.0

		for i in range(steps + 1):
			var t: float = float(i) / float(steps)
			var y_norm: float = 0.0
			match d_type:
				"triangular":
					# peak at ~40%
					if t < 0.4:
						y_norm = t / 0.4
					else:
						y_norm = (1.0 - t) / 0.6
				"exponential":
					y_norm = exp(-3.0 * t)
				"normal":
					var z := (t - 0.5) * 4.0
					y_norm = exp(-0.5 * z * z)
				"uniform":
					y_norm = 0.7
				_:
					y_norm = 1.0 if abs(t - 0.5) < 0.1 else 0.0

			var pt := Vector2(2.0 + t * w, size.y - 2.0 - (y_norm * h * 0.85))
			points.append(pt)

		if points.size() >= 2:
			for i in range(points.size() - 1):
				draw_line(points[i], points[i + 1], Color("#52c7a5"), 1.2)

# ============================================================================
# Subgraph / Template Inspector
# ============================================================================
func _render_subgraph(sub_id: String) -> void:
	var sub: SceneTypes.SceneSubgraph = doc_store.get_subgraph(sub_id)
	if sub == null:
		_render_empty_state("Subgraph '%s' not found." % sub_id)
		return

	# 1. Header Box
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 2)

	var title_row := HBoxContainer.new()
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.color = Color("#1abc9c") if sub.role == "compound" else Color("#9b59b6")
	title_row.add_child(dot)

	var title_lbl := Label.new()
	title_lbl.text = sub.name if not sub.name.is_empty() else sub.id
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", TEXT)
	title_row.add_child(title_lbl)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(spacer)

	var role_pill := Label.new()
	role_pill.text = " [%s] " % sub.role.to_upper()
	role_pill.add_theme_font_size_override("font_size", 9)
	role_pill.add_theme_color_override("font_color", dot.color)
	title_row.add_child(role_pill)

	header.add_child(title_row)

	var sub_lbl := Label.new()
	sub_lbl.text = "Subsystem • ID: %s" % sub.id
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", MUTED)
	header.add_child(sub_lbl)
	_container.add_child(header)

	# Subgraph Name Edit Row
	var name_box := VBoxContainer.new()
	name_box.add_theme_constant_override("separation", 2)
	var name_lbl := Label.new()
	name_lbl.text = "SUBGRAPH NAME"
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", MUTED)
	name_box.add_child(name_lbl)

	var sub_name_input := LineEdit.new()
	sub_name_input.text = sub.name if not sub.name.is_empty() else sub.id
	sub_name_input.placeholder_text = "Subgraph display name..."
	sub_name_input.custom_minimum_size.y = 26
	sub_name_input.add_theme_font_size_override("font_size", 11)
	sub_name_input.text_submitted.connect(func(new_text: String):
		var trimmed := new_text.strip_edges()
		if not trimmed.is_empty() and trimmed != sub.name:
			doc_store.rename_subgraph(sub.id, trimmed)
	)
	sub_name_input.focus_exited.connect(func():
		if sub_name_input != null and is_instance_valid(sub_name_input) and not sub_name_input.is_queued_for_deletion():
			var trimmed := sub_name_input.text.strip_edges()
			if not trimmed.is_empty() and trimmed != sub.name:
				doc_store.rename_subgraph(sub.id, trimmed)
	)
	name_box.add_child(sub_name_input)
	_container.add_child(name_box)
	_container.add_child(HSeparator.new())

	# 2. Action Buttons (Drill Down, Detach, Ungroup)
	var actions_box := VBoxContainer.new()
	actions_box.add_theme_constant_override("separation", 6)

	var btn_drill := Button.new()
	btn_drill.text = "⤸ Drill Down (Edit Internals)"
	btn_drill.add_theme_font_size_override("font_size", 10)
	btn_drill.add_theme_color_override("font_color", ACCENT)
	btn_drill.pressed.connect(func(): doc_store.enter_subgraph_scope(sub.id))
	actions_box.add_child(btn_drill)

	if sub.role == "compound" and sub.template_id != null:
		var btn_detach := Button.new()
		btn_detach.text = "✂ Detach from Template"
		btn_detach.tooltip_text = "Convert to independent group with full parameter independence"
		btn_detach.add_theme_font_size_override("font_size", 10)
		btn_detach.pressed.connect(func(): doc_store.detach_subgraph(sub.id))
		actions_box.add_child(btn_detach)

	var btn_ungroup := Button.new()
	btn_ungroup.text = "✕ Ungroup Elements"
	btn_ungroup.tooltip_text = "Dissolve group boundary and return elements to root scope"
	btn_ungroup.add_theme_font_size_override("font_size", 10)
	btn_ungroup.pressed.connect(func(): doc_store.ungroup(sub.id))
	actions_box.add_child(btn_ungroup)

	_container.add_child(actions_box)
	_container.add_child(HSeparator.new())

	# 3. Hierarchy & Lineage
	var meta_hdr := Label.new()
	meta_hdr.text = "TEMPLATE & HIERARCHY"
	meta_hdr.add_theme_font_size_override("font_size", 10)
	meta_hdr.add_theme_color_override("font_color", MUTED)
	_container.add_child(meta_hdr)

	var meta_vbox := VBoxContainer.new()
	meta_vbox.add_theme_constant_override("separation", 4)

	var tmpl_str: String = "None (Independent Group)"
	if sub.template_id != null:
		tmpl_str = "%s (v%s)" % [str(sub.template_id), str(sub.template_version)]
	var tmpl_lbl := Label.new()
	tmpl_lbl.text = "Template: %s" % tmpl_str
	tmpl_lbl.add_theme_font_size_override("font_size", 10)
	meta_vbox.add_child(tmpl_lbl)

	var count_lbl := Label.new()
	count_lbl.text = "Members: %d Elements, %d Connections" % [sub.elements.size(), sub.connections.size()]
	count_lbl.add_theme_font_size_override("font_size", 10)
	meta_vbox.add_child(count_lbl)
	_container.add_child(meta_vbox)

	_container.add_child(HSeparator.new())

	# 4. Transform (Position)
	var trans_lbl := Label.new()
	trans_lbl.text = "TRANSFORM (POSITION)"
	trans_lbl.add_theme_font_size_override("font_size", 10)
	trans_lbl.add_theme_color_override("font_color", MUTED)
	_container.add_child(trans_lbl)

	var pos_row := HBoxContainer.new()
	pos_row.add_theme_constant_override("separation", 6)
	_container.add_child(pos_row)

	_create_dock_mini_spin(pos_row, "X (m)", sub.transform.position.x, -500.0, 500.0, 0.5, func(v):
		var p := sub.transform.position
		p.x = v
		doc_store.set_subgraph_position(sub.id, p)
	)
	_create_dock_mini_spin(pos_row, "Y (m)", sub.transform.position.y, -500.0, 500.0, 0.5, func(v):
		var p := sub.transform.position
		p.y = v
		doc_store.set_subgraph_position(sub.id, p)
	)
	_create_dock_mini_spin(pos_row, "Z (m)", sub.transform.position.z, -500.0, 500.0, 0.5, func(v):
		var p := sub.transform.position
		p.z = v
		doc_store.set_subgraph_position(sub.id, p)
	)

	# 4b. Dimensions (Size)
	_container.add_child(HSeparator.new())
	var dim_lbl := Label.new()
	dim_lbl.text = "DIMENSIONS (SIZE)"
	dim_lbl.add_theme_font_size_override("font_size", 10)
	dim_lbl.add_theme_color_override("font_color", MUTED)
	_container.add_child(dim_lbl)

	var dim_row := HBoxContainer.new()
	dim_row.add_theme_constant_override("separation", 6)
	_container.add_child(dim_row)

	var cur_w: float = float(sub.transform.scale.x) if sub.transform != null and sub.transform.scale.x > 0.1 else 8.0
	var cur_h: float = float(sub.transform.scale.y) if sub.transform != null and sub.transform.scale.y > 0.1 else 4.0
	var cur_z: float = float(sub.transform.scale.z) if sub.transform != null and sub.transform.scale.z > 0.05 else 2.0
	if sub.editor != null and sub.editor.extensions.has("dimensions"):
		var ed = sub.editor.extensions["dimensions"]
		if ed is Array and ed.size() >= 3:
			cur_w = float(ed[0])
			cur_h = float(ed[1])
			cur_z = float(ed[2])

	_create_dock_mini_spin(dim_row, "L (m)", cur_w, 1.0, 500.0, 0.5, func(v):
		var d := Vector3(v, cur_h, cur_z)
		doc_store.set_subgraph_dimensions(sub.id, d)
	)
	_create_dock_mini_spin(dim_row, "W (m)", cur_h, 1.0, 500.0, 0.5, func(v):
		var d := Vector3(cur_w, v, cur_z)
		doc_store.set_subgraph_dimensions(sub.id, d)
	)
	_create_dock_mini_spin(dim_row, "H (m)", cur_z, 0.1, 100.0, 0.1, func(v):
		var d := Vector3(cur_w, cur_h, v)
		doc_store.set_subgraph_dimensions(sub.id, d)
	)

	# 4c. Internal Members Manifest
	if not sub.elements.is_empty():
		_container.add_child(HSeparator.new())
		var mem_lbl := Label.new()
		mem_lbl.text = "INTERNAL MEMBERS (%d)" % sub.elements.size()
		mem_lbl.add_theme_font_size_override("font_size", 10)
		mem_lbl.add_theme_color_override("font_color", MUTED)
		_container.add_child(mem_lbl)

		var mem_vbox := VBoxContainer.new()
		mem_vbox.add_theme_constant_override("separation", 3)
		for eid in sub.elements:
			var m_elem := doc_store.get_element(str(eid))
			var m_row := HBoxContainer.new()
			var bullet := Label.new()
			bullet.text = "•"
			bullet.add_theme_color_override("font_color", ACCENT)
			m_row.add_child(bullet)

			var m_id := Label.new()
			m_id.text = str(eid)
			m_id.add_theme_font_size_override("font_size", 10)
			m_id.add_theme_color_override("font_color", TEXT)
			m_row.add_child(m_id)

			if m_elem != null:
				var m_kind := Label.new()
				m_kind.text = "(%s)" % m_elem.kind
				m_kind.add_theme_font_size_override("font_size", 9)
				m_kind.add_theme_color_override("font_color", MUTED)
				m_row.add_child(m_kind)

			mem_vbox.add_child(m_row)
		_container.add_child(mem_vbox)

	# 5. Boundary Ports
	if not sub.exposed_ports.is_empty():
		_container.add_child(HSeparator.new())
		var ports_lbl := Label.new()
		ports_lbl.text = "EXPOSED BOUNDARY PORTS (%d)" % sub.exposed_ports.size()
		ports_lbl.add_theme_font_size_override("font_size", 10)
		ports_lbl.add_theme_color_override("font_color", MUTED)
		_container.add_child(ports_lbl)

		var ports_vbox := VBoxContainer.new()
		ports_vbox.add_theme_constant_override("separation", 3)
		for ep in sub.exposed_ports:
			var p_row := HBoxContainer.new()
			var p_badge := Label.new()
			var p_dir: String = str(ep.get("direction", "input")).to_upper()
			var p_kind: String = str(ep.get("kind", "flow")).to_upper()
			p_badge.text = "[%s %s]" % [p_kind, p_dir]
			p_badge.add_theme_font_size_override("font_size", 9)
			p_badge.add_theme_color_override("font_color", ACCENT)
			p_row.add_child(p_badge)

			var p_name_lbl := Label.new()
			p_name_lbl.text = str(ep.get("name", ep.get("id", "")))
			p_name_lbl.add_theme_font_size_override("font_size", 10)
			p_row.add_child(p_name_lbl)

			ports_vbox.add_child(p_row)
		_container.add_child(ports_vbox)

	# 6. Parameter Overrides
	if not sub.parameter_overrides.is_empty() or sub.role == "compound":
		_container.add_child(HSeparator.new())
		var ov_lbl := Label.new()
		ov_lbl.text = "PARAMETER OVERRIDES"
		ov_lbl.add_theme_font_size_override("font_size", 10)
		ov_lbl.add_theme_color_override("font_color", MUTED)
		_container.add_child(ov_lbl)

		var ov_vbox := VBoxContainer.new()
		ov_vbox.add_theme_constant_override("separation", 4)
		if sub.parameter_overrides.is_empty():
			var empty_ov := Label.new()
			empty_ov.text = "No active overrides. Default template properties used."
			empty_ov.add_theme_font_size_override("font_size", 9)
			empty_ov.add_theme_color_override("font_color", MUTED)
			ov_vbox.add_child(empty_ov)
		else:
			for k in sub.parameter_overrides.keys():
				var r := HBoxContainer.new()
				var k_lbl := Label.new()
				k_lbl.text = str(k) + ":"
				k_lbl.add_theme_font_size_override("font_size", 10)
				r.add_child(k_lbl)

				var v_edit := LineEdit.new()
				v_edit.text = str(sub.parameter_overrides[k])
				v_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				v_edit.text_submitted.connect(func(new_text):
					var val: Variant = new_text
					if new_text.is_valid_float():
						val = new_text.to_float()
					elif new_text.is_valid_int():
						val = new_text.to_int()
					elif new_text.to_lower() == "true":
						val = true
					elif new_text.to_lower() == "false":
						val = false
					doc_store.set_subgraph_override(sub.id, str(k), val)
				)
				r.add_child(v_edit)
				ov_vbox.add_child(r)
		_container.add_child(ov_vbox)

func _on_rule_changed(element_id: String, property_path: String, value) -> void:
	if doc_store == null: return
	var elem = doc_store.get_element(element_id)
	if elem != null:
		doc_store.set_element_property(element_id, property_path, value)
		return
	
	if doc_store.active_document != null:
		var target_conn = null
		for c in doc_store.active_document.connections:
			if c.id == element_id:
				target_conn = c
				break
		if target_conn != null:
			var cond = target_conn.condition if target_conn.condition is Dictionary else {}
			cond[property_path] = value
			doc_store.update_connection_condition(element_id, cond)

func set_conveyor_shape_preset(elem_id: String, preset_id: String) -> void:
	if doc_store == null:
		return
	var elem := doc_store.get_element(elem_id)
	if elem == null or elem.kind != "conveyor":
		return
	var pid: String = preset_id.strip_edges().to_lower()
	var locks := ConveyorCurve3D.connected_endpoint_locks(elem_id, doc_store)
	if locks["inlet"] or locks["outlet"] or pid == str(elem.geometry.get("shape_preset", "straight")):
		return
	doc_store._record_undo()
	if pid != str(elem.geometry.get("shape_preset", "straight")):
		elem.geometry.erase("corner_pos")
		if elem.geometry.get("shape_params") is Dictionary:
			elem.geometry["shape_params"].erase("corner_pos")
	elem.geometry["shape_preset"] = pid
	if pid == "straight":
		elem.geometry.erase("corner_pos")
		if elem.geometry.has("inlet_pose") and elem.geometry.has("outlet_pose"):
			var p0 = elem.geometry["inlet_pose"]["position"]
			var p1 = elem.geometry["outlet_pose"]["position"]
			var v0 := Vector2(float(p0[0]), float(p0[1]))
			var v1 := Vector2(float(p1[0]), float(p1[1]))
			var dist_m := v0.distance_to(v1)
			if dist_m > 0.5:
				if not (elem.geometry.get("dimensions") is Array):
					elem.geometry["dimensions"] = [dist_m, 1.2, 0.8]
				else:
					elem.geometry["dimensions"][0] = snapped(dist_m, 0.1)
		elem.geometry.erase("inlet_pose")
		elem.geometry.erase("outlet_pose")
	else:
		if not (elem.geometry.get("shape_params") is Dictionary):
			elem.geometry["shape_params"] = {}
		var sp_dict: Dictionary = elem.geometry["shape_params"]
		if not sp_dict.has("lateral_offset"): sp_dict["lateral_offset"] = 2.5
		if not sp_dict.has("forward_span"): sp_dict["forward_span"] = 10.0
		if not sp_dict.has("bend_radius"): sp_dict["bend_radius"] = 2.0
		if not sp_dict.has("bend_angle_deg"): sp_dict["bend_angle_deg"] = 90.0
		if not sp_dict.has("turn_direction"): sp_dict["turn_direction"] = "right"
		if not sp_dict.has("leg1_length"): sp_dict["leg1_length"] = 6.0
		if not sp_dict.has("leg2_length"): sp_dict["leg2_length"] = 6.0
		ConveyorCurve3D.sample_world_curve(elem, doc_store)
	doc_store.is_dirty = true
	doc_store.validate()
	doc_store.document_modified.emit()
	call_deferred("refresh")

func _request_custom_spline_conversion(elem: SceneTypes.SceneElement, on_cancel: Callable = Callable()) -> void:
	if elem == null or elem.kind != "conveyor" or str(elem.geometry.get("shape_preset", "")) == "custom_spline":
		return
	var confirm := ConfirmationDialog.new()
	confirm.title = "Convert to Editable Spline?"
	confirm.dialog_text = "This conveyor will become a control-point spline. Keep the current shape as editable control points?"
	confirm.ok_button_text = "Keep Editable Spline"
	confirm.cancel_button_text = "Restore Previous Shape"
	add_child(confirm)
	confirm.confirmed.connect(func():
		doc_store._record_undo()
		ConveyorCurve3D.convert_element_to_custom_spline(elem, doc_store)
		doc_store.is_dirty = true
		doc_store.validate()
		doc_store.document_modified.emit()
		confirm.queue_free()
		call_deferred("refresh")
	)
	confirm.canceled.connect(func():
		confirm.queue_free()
		if on_cancel.is_valid():
			on_cancel.call()
	)
	if is_inside_tree():
		confirm.popup_centered()

func _build_conveyor_shape_section(elem: SceneTypes.SceneElement) -> void:
	var sec_lbl := Label.new()
	sec_lbl.text = "CONVEYOR SHAPE & CURVE GEOMETRY"
	sec_lbl.add_theme_font_size_override("font_size", 10)
	sec_lbl.add_theme_color_override("font_color", ACCENT)
	_container.add_child(sec_lbl)

	if not (elem.geometry.get("shape_params") is Dictionary):
		elem.geometry["shape_params"] = {
			"bend_radius": 2.0,
			"bend_angle_deg": 90.0,
			"sweep_angle_deg": 90.0,
			"passes": 3,
			"pass_spacing": 2.0,
			"helix_turns": 1.5
		}
	var sp: Dictionary = elem.geometry["shape_params"]
	if sp.has("pitch") and not sp.has("pass_spacing"):
		sp["pass_spacing"] = sp["pitch"]
	var cur_preset: String = str(elem.geometry.get("shape_preset", "straight")).strip_edges().to_lower()

	var p_row := HBoxContainer.new()
	p_row.add_theme_constant_override("separation", 6)
	var p_lbl := Label.new()
	p_lbl.text = "Shape Preset:"
	p_lbl.add_theme_font_size_override("font_size", 10)
	p_lbl.add_theme_color_override("font_color", TEXT)
	p_row.add_child(p_lbl)

	var opt_preset := OptionButton.new()
	opt_preset.name = "ConveyorPresetDropdown"
	opt_preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt_preset.add_theme_font_size_override("font_size", 10)
	var sel_idx := 0
	for i in range(ConveyorCurve3D.PRESET_IDS.size()):
		var pid: String = ConveyorCurve3D.PRESET_IDS[i]
		var plabel: String = str(ConveyorCurve3D.PRESET_LABELS.get(pid, pid.capitalize()))
		opt_preset.add_item(plabel, i)
		if pid == cur_preset:
			sel_idx = i
	opt_preset.selected = sel_idx
	var preset_locks := ConveyorCurve3D.connected_endpoint_locks(elem.id, doc_store)
	opt_preset.disabled = preset_locks["inlet"] or preset_locks["outlet"]
	if opt_preset.disabled:
		opt_preset.tooltip_text = "Disconnect flow to change the conveyor preset"
	opt_preset.item_selected.connect(func(idx: int):
		if idx >= 0 and idx < ConveyorCurve3D.PRESET_IDS.size():
			var target_preset: String = ConveyorCurve3D.PRESET_IDS[idx]
			if target_preset == "custom_spline" and cur_preset != "custom_spline":
				_request_custom_spline_conversion(elem, func(): opt_preset.select(sel_idx))
				return
			if cur_preset == "custom_spline" and target_preset != cur_preset:
				var confirm := ConfirmationDialog.new()
				confirm.title = "Reset Conveyor Geometry"
				confirm.dialog_text = "Replace the editable bends with this preset?"
				add_child(confirm)
				confirm.confirmed.connect(func():
					set_conveyor_shape_preset(elem.id, target_preset)
					confirm.queue_free()
				)
				confirm.canceled.connect(func():
					opt_preset.select(sel_idx)
					confirm.queue_free()
				)
				confirm.popup_centered()
			else:
				set_conveyor_shape_preset(elem.id, target_preset)
	)
	p_row.add_child(opt_preset)
	_container.add_child(p_row)

	# Dimensions (Belt Width & Length)
	var dims = elem.geometry.get("dimensions", [10.0, 1.2, 0.8])
	var cur_l: float = float(dims[0]) if dims is Array and dims.size() >= 1 else 10.0
	var cur_w: float = float(dims[1]) if dims is Array and dims.size() >= 2 else 1.2
	var cur_h: float = float(dims[2]) if dims is Array and dims.size() >= 3 else 0.8

	var dim_row := HBoxContainer.new()
	dim_row.add_theme_constant_override("separation", 6)
	_create_dock_mini_spin(dim_row, "Belt Width (m)", cur_w, 0.4, 8.0, 0.1, func(v):
		doc_store._record_undo()
		if not (elem.geometry.get("dimensions") is Array):
			elem.geometry["dimensions"] = [cur_l, v, cur_h]
		else:
			elem.geometry["dimensions"][1] = v
		doc_store.is_dirty = true
		doc_store.document_modified.emit()
	)
	if cur_preset == "straight":
		var length_spin := _create_dock_mini_spin(dim_row, "Length (m)", cur_l, 1.0, 500.0, 0.5, func(v):
			if ConveyorCurve3D.connected_endpoint_locks(elem.id, doc_store)["outlet"]:
				return
			doc_store._record_undo()
			if not (elem.geometry.get("dimensions") is Array):
				elem.geometry["dimensions"] = [v, cur_w, cur_h]
			else:
				elem.geometry["dimensions"][0] = v
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		length_spin.editable = not preset_locks["outlet"]
		if not length_spin.editable:
			length_spin.tooltip_text = "Disconnect outlet flow to change length"
	_container.add_child(dim_row)
	var width_profile: Array = elem.geometry.get("width_profile", []) if elem.geometry.get("width_profile") is Array else []
	var profile_row := HBoxContainer.new()
	var profile_label := Label.new()
	profile_label.text = "WIDTH ALONG PATH"
	profile_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	profile_row.add_child(profile_label)
	var add_width_key := Button.new()
	add_width_key.text = "+ Width Key"
	add_width_key.pressed.connect(func():
		doc_store._record_undo()
		if not (elem.geometry.get("width_profile") is Array):
			elem.geometry["width_profile"] = []
		var keys: Array = elem.geometry["width_profile"]
		var fraction := ConveyorCurve3D.next_width_key_fraction(elem)
		keys.append({"fraction": fraction, "scale": 1.0})
		doc_store.is_dirty = true
		doc_store.document_modified.emit()
		call_deferred("refresh")
	)
	profile_row.add_child(add_width_key)
	_container.add_child(profile_row)
	for key_index in range(width_profile.size()):
		var width_key = width_profile[key_index]
		if not (width_key is Dictionary):
			continue
		var key_row := HBoxContainer.new()
		_create_dock_mini_spin(key_row, "Position (%)", float(width_key.get("fraction", 0.5)) * 100.0, 0.0, 100.0, 1.0, func(value):
			doc_store._record_undo()
			width_key["fraction"] = value / 100.0
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		_create_dock_mini_spin(key_row, "Local Width (m)", ConveyorCurve3D.width_at_fraction(elem, float(width_key.get("fraction", 0.5))), 0.4, 8.0, 0.1, func(value):
			doc_store._record_undo()
			width_key["scale"] = value / maxf(0.4, float(elem.geometry["dimensions"][1]))
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		var remove_width_key := Button.new()
		remove_width_key.text = "×"
		remove_width_key.tooltip_text = "Remove width key"
		remove_width_key.pressed.connect(func():
			doc_store._record_undo()
			(elem.geometry["width_profile"] as Array).erase(width_key)
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
			call_deferred("refresh")
		)
		key_row.add_child(remove_width_key)
		_container.add_child(key_row)
	var rotation_row := HBoxContainer.new()
	var rotation_spin := _create_dock_mini_spin(rotation_row, "Rotate (°)", float(elem.transform.rotation.z), -360.0, 360.0, 5.0, func(v):
		var canvas = get_tree().root.find_child("Authoring2DCanvas", true, false)
		if canvas != null and canvas.has_method("_rotate_conveyor_element"):
			var rotation_locks := ConveyorCurve3D.connected_endpoint_locks(elem.id, doc_store)
			if rotation_locks["inlet"] or rotation_locks["outlet"]:
				return
			doc_store._record_undo()
			canvas._rotate_conveyor_element(elem.id, v - elem.transform.rotation.z, canvas._conveyor_pivot(elem))
	)
	rotation_spin.editable = not (preset_locks["inlet"] or preset_locks["outlet"])
	if not rotation_spin.editable:
		rotation_spin.tooltip_text = "Disconnect flow to rotate this conveyor"
	var pivot_select := OptionButton.new()
	pivot_select.tooltip_text = "Rotation pivot"
	for label in ["Center", "Inlet", "Outlet"]:
		pivot_select.add_item(label)
	var pivot_canvas = get_tree().root.find_child("Authoring2DCanvas", true, false) if is_inside_tree() else null
	if pivot_canvas != null:
		pivot_select.selected = ["center", "inlet", "outlet"].find(pivot_canvas.conveyor_rotation_pivot_mode)
	pivot_select.item_selected.connect(func(index: int):
		var canvas = get_tree().root.find_child("Authoring2DCanvas", true, false)
		if canvas != null:
			canvas.conveyor_rotation_pivot_mode = ["center", "inlet", "outlet"][index]
	)
	rotation_row.add_child(pivot_select)
	_container.add_child(rotation_row)

	# Dedicated Conveyor Geometry Mode Button (Ports Hidden)
	var btn_edit_geom := Button.new()
	btn_edit_geom.text = "📐 Edit Conveyor Geometry (Shift+G)"
	btn_edit_geom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_edit_geom.add_theme_font_size_override("font_size", 10)
	btn_edit_geom.add_theme_color_override("font_color", Color("#2ecc71"))
	btn_edit_geom.pressed.connect(func():
		conveyor_geometry_mode_requested.emit(elem.id)
		var canvas = get_tree().root.find_child("Authoring2DCanvas", true, false)
		if canvas != null and canvas.has_method("enter_conveyor_geometry_mode"):
			canvas.enter_conveyor_geometry_mode(elem.id)
	)
	_container.add_child(btn_edit_geom)

	# Auto-Join Connected Conveyors checkbox
	var chk_join := CheckBox.new()
	chk_join.text = "Auto-Join Connected Conveyors (C¹ Smooth)"
	chk_join.button_pressed = bool(sp.get("auto_join", elem.geometry.get("auto_join", true)))
	chk_join.add_theme_font_size_override("font_size", 10)
	chk_join.toggled.connect(func(on: bool):
		ConveyorCurve3D.update_shape_parameter(elem, "auto_join", on, doc_store)
		doc_store.is_dirty = true
		doc_store.validate()
		doc_store.document_modified.emit()
	)
	_container.add_child(chk_join)

	# Progressive disclosure of preset parameters
	if cur_preset == "l_bend":
		var row1 := HBoxContainer.new()
		row1.add_theme_constant_override("separation", 6)
		_create_dock_mini_spin(row1, "Radius (m)", float(sp.get("bend_radius", 2.0)), 0.3, 25.0, 0.1, func(v):
			ConveyorCurve3D.update_shape_parameter(elem, "bend_radius", v, doc_store)
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		_create_dock_mini_spin(row1, "Bend Angle (°)", float(sp.get("bend_angle_deg", 90.0)), 15.0, 165.0, 5.0, func(v):
			ConveyorCurve3D.update_shape_parameter(elem, "bend_angle_deg", v, doc_store)
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		var dir_vbox := VBoxContainer.new()
		dir_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var dir_lbl := Label.new()
		dir_lbl.text = "Turn Direction"
		dir_lbl.add_theme_font_size_override("font_size", 8)
		dir_lbl.add_theme_color_override("font_color", MUTED)
		dir_vbox.add_child(dir_lbl)
		var dir_opt := OptionButton.new()
		dir_opt.add_item("Right", 0)
		dir_opt.add_item("Left", 1)
		dir_opt.selected = 1 if str(sp.get("turn_direction", "right")).to_lower() == "left" else 0
		dir_opt.item_selected.connect(func(idx: int):
			ConveyorCurve3D.update_shape_parameter(elem, "turn_direction", "left" if idx == 1 else "right", doc_store)
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		dir_vbox.add_child(dir_opt)
		row1.add_child(dir_vbox)
		_container.add_child(row1)

		var row2 := HBoxContainer.new()
		row2.add_theme_constant_override("separation", 6)
		_create_dock_mini_spin(row2, "Leg 1 / Infeed (m)", float(sp.get("leg1_length", 5.0)), 1.0, 100.0, 0.5, func(v):
			ConveyorCurve3D.update_shape_parameter(elem, "leg1_length", v, doc_store)
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		_create_dock_mini_spin(row2, "Leg 2 / Outfeed (m)", float(sp.get("leg2_length", 5.0)), 1.0, 100.0, 0.5, func(v):
			ConveyorCurve3D.update_shape_parameter(elem, "leg2_length", v, doc_store)
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		_container.add_child(row2)

	elif cur_preset == "s_curve":
		var s_row := HBoxContainer.new()
		s_row.add_theme_constant_override("separation", 6)
		_create_dock_mini_spin(s_row, "Lateral Offset (m)", float(sp.get("lateral_offset", 2.5)), -50.0, 50.0, 0.2, func(v):
			ConveyorCurve3D.update_shape_parameter(elem, "lateral_offset", v, doc_store)
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		_create_dock_mini_spin(s_row, "Forward Span (m)", float(sp.get("forward_span", 8.0)), 2.0, 100.0, 0.5, func(v):
			ConveyorCurve3D.update_shape_parameter(elem, "forward_span", v, doc_store)
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		_create_dock_mini_spin(s_row, "Tangent Scale", float(sp.get("tangent_scale", 0.42)), 0.1, 1.5, 0.05, func(v):
			ConveyorCurve3D.update_shape_parameter(elem, "tangent_scale", v, doc_store)
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		_container.add_child(s_row)

	elif cur_preset == "custom_spline":
		var spl_row := HBoxContainer.new()
		spl_row.add_theme_constant_override("separation", 6)
		var cpts = sp.get("control_points", [])
		var n_cpts: int = cpts.size() if (cpts is Array) else 0
		var c_lbl := Label.new()
		c_lbl.text = "Spline Vertices: %d" % n_cpts
		c_lbl.add_theme_font_size_override("font_size", 10)
		c_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spl_row.add_child(c_lbl)

		var btn_add := Button.new()
		btn_add.text = "+ Add Point"
		btn_add.add_theme_font_size_override("font_size", 9)
		btn_add.pressed.connect(func():
			doc_store._record_undo()
			if not (sp.get("control_points") is Array):
				sp["control_points"] = []
			var arr: Array = sp["control_points"]
			var last_p := Vector3(10, 0, 0)
			if arr.size() > 0:
				var item = arr[arr.size() - 1]
				if item is Dictionary and item.has("pos") and item["pos"] is Array and item["pos"].size() >= 3:
					last_p = Vector3(float(item["pos"][0]) + 3.0, float(item["pos"][1]), float(item["pos"][2]))
			arr.append({"pos": [last_p.x, last_p.y, last_p.z]})
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
			call_deferred("refresh")
		)
		spl_row.add_child(btn_add)

		var btn_del := Button.new()
		btn_del.text = "✕ Remove Last"
		btn_del.add_theme_font_size_override("font_size", 9)
		btn_del.pressed.connect(func():
			if sp.get("control_points") is Array and (sp["control_points"] as Array).size() > 2:
				doc_store._record_undo()
				(sp["control_points"] as Array).pop_back()
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
				call_deferred("refresh")
		)
		spl_row.add_child(btn_del)
		_container.add_child(spl_row)

	elif cur_preset in ["u_turn", "circular_arc", "serpentine", "spiral_helix"]:
		var param_row := HBoxContainer.new()
		param_row.add_theme_constant_override("separation", 6)
		var radius_key := "helix_radius" if cur_preset == "spiral_helix" else "pass_spacing" if cur_preset == "serpentine" else "bend_radius"
		_create_dock_mini_spin(param_row, "Radius (m)" if cur_preset != "serpentine" else "Lane C-C (m)", float(sp.get(radius_key, 2.5 if cur_preset == "spiral_helix" else 2.0)), 1.2 if cur_preset == "serpentine" else 1.0 if cur_preset == "spiral_helix" else 0.5, 25.0, 0.1, func(v):
			ConveyorCurve3D.update_shape_parameter(elem, radius_key, v, doc_store)
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		if cur_preset == "circular_arc":
			_create_dock_mini_spin(param_row, "Sweep (°)", float(sp.get("sweep_angle_deg", 90.0)), -350.0, 350.0, 5.0, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "sweep_angle_deg", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
		elif cur_preset == "serpentine":
			_create_dock_mini_spin(param_row, "Bends", float(sp.get("passes", 3)) - 1.0, 1.0, 11.0, 1.0, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "passes", int(round(v)) + 1, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_create_dock_mini_spin(param_row, "Pass Length (m)", float(sp.get("pass_length", cur_l)), 3.0, 100.0, 0.2, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "pass_length", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			var end_run_limit: float = maxf(3.0, float(sp.get("pass_length", cur_l)))
			_create_dock_mini_spin(param_row, "Infeed Lead (m)", float(sp.get("infeed_length", 0.0)), 0.0, end_run_limit, 0.1, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "infeed_length", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_create_dock_mini_spin(param_row, "Outfeed Lead (m)", float(sp.get("outfeed_length", 0.0)), 0.0, end_run_limit, 0.1, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "outfeed_length", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
		elif cur_preset == "spiral_helix":
			_create_dock_mini_spin(param_row, "Turns", float(sp.get("helix_turns", 1.5)), 0.25, 6.0, 0.25, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "helix_turns", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_create_dock_mini_spin(param_row, "Rise (m)", float(sp.get("elevation_gain", 2.4)), -20.0, 20.0, 0.1, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "elevation_gain", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_create_dock_mini_spin(param_row, "Pitch (m/turn)", float(sp.get("elevation_gain", 2.4)) / maxf(0.25, float(sp.get("helix_turns", 1.5))), -20.0, 20.0, 0.1, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "elevation_gain", v * float(elem.geometry["shape_params"].get("helix_turns", 1.5)), doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
		elif cur_preset == "u_turn":
			_create_dock_mini_spin(param_row, "Leg Length (m)", float(sp.get("leg_length", 6.0)), 1.5, 100.0, 0.5, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "leg_length", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_create_dock_mini_spin(param_row, "Return Leg (m)", float(sp.get("return_leg_length", sp.get("leg_length", 6.0))), 1.5, 100.0, 0.5, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "return_leg_length", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
		_container.add_child(param_row)
		if cur_preset == "serpentine":
			var spacing: float = float(sp.get("pass_spacing", 2.0))
			var widest: float = ConveyorCurve3D.maximum_width(elem)
			var gap_label := Label.new()
			gap_label.text = "Footprint: %.2f m  |  Min lane gap: %.2f m" % [(float(sp.get("passes", 3)) - 1.0) * spacing + widest, spacing - widest]
			gap_label.add_theme_font_size_override("font_size", 9)
			gap_label.add_theme_color_override("font_color", Color("#f39c12") if spacing < widest else MUTED)
			_container.add_child(gap_label)

	# Convert to Editable Spline Button (available for all non-custom presets)
	if cur_preset != "custom_spline":
		var btn_convert := Button.new()
		btn_convert.text = "✏ Convert to Editable Spline"
		btn_convert.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn_convert.add_theme_font_size_override("font_size", 10)
		btn_convert.pressed.connect(func():
			_request_custom_spline_conversion(elem)
		)
		_container.add_child(btn_convert)

