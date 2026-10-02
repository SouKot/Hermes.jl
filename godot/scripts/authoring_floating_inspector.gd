# authoring_floating_inspector.gd
# Draggable, Tabbed Floating Entity Properties Window for Antigravity SimViz.
class_name SimVizAuthoringFloatingInspector
extends PanelContainer

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const Catalog := preload("res://scripts/authoring_catalog.gd")
const Inspector := preload("res://scripts/authoring_inspector.gd")
const ConveyorCurve3D := preload("res://scripts/conveyor_curve_3d.gd")
const OSWindowHost := preload("res://scripts/authoring_os_window_host.gd")

signal closed
signal duplicate_requested(elem_id: String)
signal delete_requested(elem_id: String)
signal open_rule_builder_requested(conn_id: String)
signal hook_apply_requested(msg: Dictionary)
signal conveyor_geometry_mode_requested(elem_id: String)

const BG := Color("#0b121c")
const PANEL := Color("#121b27")
const PANEL_ALT := Color("#162334")
const BORDER := Color("#2e4259")
const TEXT := Color("#e5edf5")
const MUTED := Color("#8da2b5")
const ACCENT := Color("#52c7a5")
const WARNING := Color("#e6b85c")
const LIVE_COLOR := Color("#2ecc71")
const RESTART_COLOR := Color("#e67e22")
const DANGER := Color("#e74c3c")

var doc_store: DocumentStore
var catalog: Catalog
var current_elem_id: String = ""
var current_tab: int = 0
var is_sim_running: bool = false

# Dragging state
var _dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO

# UI nodes
var _header_bar: HBoxContainer
var _dot_rect: ColorRect
var _title_label: Label
var _kind_pill: Label
var _tab_row: HBoxContainer
var _tab_buttons: Array[Button] = []
var _pages_container: VBoxContainer
var _tab_pages: Array[Control] = []

# Tab 1: Spatial SpinBoxes
var _spin_px: SpinBox
var _spin_py: SpinBox
var _spin_pz: SpinBox
var _spin_rot: SpinBox
var _spin_len: SpinBox
var _spin_wid: SpinBox
var _spin_hgt: SpinBox
var _spin_zs: SpinBox
var _spin_ze: SpinBox
const HOOK_EVENTS := ["on_entry", "on_service_start", "on_service_complete", "on_exit", "on_pull", "on_event"]
var _hook_editors: Array = []
var _hook_enables: Array = []
var _hook_error_label: Label = null


func _init(p_store: DocumentStore = null, p_catalog: Catalog = null) -> void:
	doc_store = p_store
	catalog = p_catalog
	visible = false
	z_index = 100
	custom_minimum_size = Vector2(480, 420)

	var style := StyleBoxFlat.new()
	style.bg_color = BG
	style.border_color = BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.shadow_color = Color(0, 0, 0, 0.65)
	style.shadow_size = 12
	style.shadow_offset = Vector2(0, 4)
	add_theme_stylebox_override("panel", style)

	_build_base_ui()

	if doc_store != null:
		doc_store.document_modified.connect(_on_document_modified)
		doc_store.selection_changed.connect(_on_selection_changed)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

func _build_base_ui() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# 1. Header (Draggable Title Bar)
	var header_panel := PanelContainer.new()
	header_panel.custom_minimum_size.y = 36
	var h_style := StyleBoxFlat.new()
	h_style.bg_color = PANEL
	h_style.border_color = BORDER
	h_style.border_width_bottom = 1
	h_style.set_corner_radius_all(4)
	header_panel.add_theme_stylebox_override("panel", h_style)
	root.add_child(header_panel)

	_header_bar = HBoxContainer.new()
	_header_bar.add_theme_constant_override("separation", 8)
	_header_bar.add_theme_constant_override("margin_left", 10)
	_header_bar.add_theme_constant_override("margin_right", 8)
	header_panel.add_child(_header_bar)

	_header_bar.gui_input.connect(_on_header_gui_input)

	_dot_rect = ColorRect.new()
	_dot_rect.custom_minimum_size = Vector2(10, 10)
	_dot_rect.color = ACCENT
	_header_bar.add_child(_dot_rect)

	_title_label = Label.new()
	_title_label.text = "Entity Properties"
	_title_label.add_theme_font_size_override("font_size", 12)
	_title_label.add_theme_color_override("font_color", TEXT)
	_header_bar.add_child(_title_label)

	_kind_pill = Label.new()
	_kind_pill.text = "[EQUIPMENT]"
	_kind_pill.add_theme_font_size_override("font_size", 9)
	_kind_pill.add_theme_color_override("font_color", MUTED)
	_header_bar.add_child(_kind_pill)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_bar.add_child(spacer)

	var drag_hint := Label.new()
	drag_hint.text = "☵ Drag"
	drag_hint.add_theme_font_size_override("font_size", 9)
	drag_hint.add_theme_color_override("font_color", Color(MUTED.r, MUTED.g, MUTED.b, 0.4))
	_header_bar.add_child(drag_hint)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.custom_minimum_size = Vector2(24, 24)
	close_btn.add_theme_font_size_override("font_size", 11)
	close_btn.add_theme_color_override("font_color", MUTED)
	close_btn.add_theme_color_override("font_hover_color", Color("#e74c3c"))
	close_btn.pressed.connect(close)
	_header_bar.add_child(close_btn)

	# 2. Horizontal TabBar Strip
	var tab_bar_panel := PanelContainer.new()
	var t_style := StyleBoxFlat.new()
	t_style.bg_color = PANEL_ALT
	t_style.border_color = BORDER
	t_style.border_width_bottom = 1
	tab_bar_panel.add_theme_stylebox_override("panel", t_style)
	root.add_child(tab_bar_panel)

	_tab_row = HBoxContainer.new()
	_tab_row.add_theme_constant_override("separation", 2)
	_tab_row.add_theme_constant_override("margin_left", 6)
	_tab_row.add_theme_constant_override("margin_top", 4)
	_tab_row.add_theme_constant_override("margin_bottom", 4)
	tab_bar_panel.add_child(_tab_row)

	var tab_defs := [
		{"name": "⚙ Process & DES", "idx": 0},
		{"name": "📐 Spatial / CAD", "idx": 1},
		{"name": "🔌 Ports", "idx": 2},
		{"name": "⚡ Reliability & Rules", "idx": 3},
		{"name": "🔗 Hooks", "idx": 4}
	]

	for t_def in tab_defs:
		var btn := Button.new()
		btn.text = t_def["name"]
		btn.add_theme_font_size_override("font_size", 10)
		var tid: int = t_def["idx"]
		btn.pressed.connect(func(): _switch_tab(tid))
		_tab_row.add_child(btn)
		_tab_buttons.append(btn)

	# 3. Main Pages Container (Scrollable)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = 280
	root.add_child(scroll)

	_pages_container = VBoxContainer.new()
	_pages_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pages_container.add_theme_constant_override("separation", 10)
	_pages_container.add_theme_constant_override("margin_left", 14)
	_pages_container.add_theme_constant_override("margin_right", 14)
	_pages_container.add_theme_constant_override("margin_top", 12)
	_pages_container.add_theme_constant_override("margin_bottom", 12)
	scroll.add_child(_pages_container)

	# 4. Footer Actions
	var footer := PanelContainer.new()
	footer.custom_minimum_size.y = 40
	var f_style := StyleBoxFlat.new()
	f_style.bg_color = PANEL
	f_style.border_color = BORDER
	f_style.border_width_top = 1
	footer.add_theme_stylebox_override("panel", f_style)
	root.add_child(footer)

	var foot_row := HBoxContainer.new()
	foot_row.add_theme_constant_override("separation", 8)
	foot_row.add_theme_constant_override("margin_left", 12)
	foot_row.add_theme_constant_override("margin_right", 12)
	footer.add_child(foot_row)

	var dup_btn := Button.new()
	dup_btn.text = "Duplicate (Ctrl+D)"
	dup_btn.add_theme_font_size_override("font_size", 10)
	dup_btn.pressed.connect(func():
		if not current_elem_id.is_empty():
			duplicate_requested.emit(current_elem_id)
	)
	foot_row.add_child(dup_btn)

	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.add_theme_font_size_override("font_size", 10)
	del_btn.add_theme_color_override("font_color", Color("#e74c3c"))
	del_btn.pressed.connect(func():
		if not current_elem_id.is_empty():
			var eid := current_elem_id
			close()
			delete_requested.emit(eid)
	)
	foot_row.add_child(del_btn)

	var foot_spacer := Control.new()
	foot_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot_row.add_child(foot_spacer)

	var done_btn := Button.new()
	done_btn.text = "Close (Esc)"
	done_btn.add_theme_font_size_override("font_size", 10)
	done_btn.pressed.connect(close)
	foot_row.add_child(done_btn)

func open_for_element(elem_id: String, screen_pos: Vector2 = Vector2.ZERO) -> void:
	current_elem_id = elem_id
	if doc_store == null:
		return
	var elem := doc_store.get_element(elem_id)
	if elem == null:
		return

	# Update title & badge
	var title_text: String = elem.name if not elem.name.is_empty() else elem.id
	_title_label.text = "Properties: %s" % title_text
	_kind_pill.text = "[%s]" % elem.kind.to_upper()
	_dot_rect.color = Color(elem.editor.color) if not elem.editor.color.is_empty() else ACCENT

	var p_win := get_parent() as Window
	if p_win != null and (not is_inside_tree() or p_win != get_tree().root):
		p_win.title = "SimViz — %s (%s)" % [title_text, elem.kind.to_upper()]
		position = Vector2.ZERO
	elif screen_pos != Vector2.ZERO:
		var target_pos := screen_pos + Vector2(20, -20)
		var p_size := _get_bounding_area_size()
		target_pos.x = clamp(target_pos.x, 20.0, max(20.0, p_size.x - custom_minimum_size.x - 20.0))
		target_pos.y = clamp(target_pos.y, 20.0, max(20.0, p_size.y - custom_minimum_size.y - 20.0))
		position = target_pos
	else:
		# Center on screen
		var p_size := _get_bounding_area_size()
		position = Vector2(
			max(20.0, (p_size.x - custom_minimum_size.x) * 0.5),
			max(20.0, (p_size.y - custom_minimum_size.y) * 0.5)
		)

	visible = true
	_switch_tab(current_tab)

func _get_bounding_area_size() -> Vector2:
	var p := get_parent()
	if p is Control:
		return (p as Control).size
	if is_inside_tree():
		return get_viewport_rect().size
	return Vector2(1440, 900)

func close() -> void:
	visible = false
	current_elem_id = ""
	closed.emit()

func _switch_tab(idx: int) -> void:
	current_tab = idx
	for i in range(_tab_buttons.size()):
		var btn: Button = _tab_buttons[i]
		if i == current_tab:
			btn.add_theme_color_override("font_color", ACCENT)
		else:
			btn.add_theme_color_override("font_color", MUTED)

	refresh()

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

func refresh() -> void:
	if not visible or current_elem_id.is_empty() or doc_store == null:
		return

	var elem := doc_store.get_element(current_elem_id)
	if elem == null:
		close()
		return

	for child in _pages_container.get_children():
		child.queue_free()

	match current_tab:
		0: _render_process_tab(elem)
		1: _render_spatial_tab(elem)
		2: _render_ports_tab(elem)
		3: _render_rules_tab(elem)
		4: _render_hooks_tab(elem)

# ============================================================================
# Tab 0: Process & DES Parameters
# ============================================================================
func _render_process_tab(elem: SceneTypes.SceneElement) -> void:
	# Block Identity (Name & ID)
	var id_box := VBoxContainer.new()
	id_box.add_theme_constant_override("separation", 3)

	var id_hdr := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = "BLOCK NAME / LABEL"
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", MUTED)
	id_hdr.add_child(name_lbl)

	var id_note := Label.new()
	id_note.text = "(ID: %s)" % elem.id
	id_note.add_theme_font_size_override("font_size", 9)
	id_note.add_theme_color_override("font_color", Color(0.5, 0.6, 0.7, 0.8))
	id_hdr.add_child(id_note)
	id_box.add_child(id_hdr)

	var name_input := LineEdit.new()
	name_input.text = elem.name if not elem.name.is_empty() else elem.id
	name_input.placeholder_text = "Enter block display name..."
	name_input.custom_minimum_size.y = 26
	name_input.add_theme_font_size_override("font_size", 11)
	name_input.text_submitted.connect(func(new_text: String):
		var trimmed := new_text.strip_edges()
		if not trimmed.is_empty() and trimmed != elem.name:
			doc_store.rename_element(elem.id, trimmed)
			_title_label.text = "Properties: %s" % trimmed
	)
	name_input.focus_exited.connect(func():
		if name_input != null and is_instance_valid(name_input) and not name_input.is_queued_for_deletion():
			var trimmed := name_input.text.strip_edges()
			if not trimmed.is_empty() and trimmed != elem.name:
				doc_store.rename_element(elem.id, trimmed)
				_title_label.text = "Properties: %s" % trimmed
	)
	id_box.add_child(name_input)
	_pages_container.add_child(id_box)
	_pages_container.add_child(HSeparator.new())

	var entry: Catalog.CatalogEntry = catalog.get_entry(elem.kind) if catalog != null else null
	if entry == null or entry.property_schemas.is_empty():
		var no_props := Label.new()
		no_props.text = "No DES process parameters declared for %s." % elem.kind
		no_props.add_theme_font_size_override("font_size", 10)
		no_props.add_theme_color_override("font_color", MUTED)
		_pages_container.add_child(no_props)
		return

	var schemas_by_grp: Dictionary = entry.get_schemas_by_group()
	for grp in schemas_by_grp.keys():
		var g_lbl := Label.new()
		g_lbl.text = grp.to_upper()
		g_lbl.add_theme_font_size_override("font_size", 10)
		g_lbl.add_theme_color_override("font_color", MUTED)
		_pages_container.add_child(g_lbl)

		var schemas: Array = schemas_by_grp[grp]
		for s in schemas:
			var key: String = s.get("key", "")
			# Omit reliability keys here (they belong in Tab 3)
			if key in ["failure_model", "mtbf", "mttr", "failure_rate"]:
				continue
			_build_schema_widget(elem, s)

		_pages_container.add_child(HSeparator.new())

func _build_schema_widget(elem: SceneTypes.SceneElement, schema: Dictionary) -> void:
	var key: String = schema.get("key", "")
	var disp: String = schema.get("display_name", key.capitalize())
	var p_type: String = schema.get("type", "float")
	var unit: String = schema.get("unit", "")
	var is_live: bool = schema.get("edit_policy", "live") == "live"
	var cur_val = elem.properties.get(key, schema.get("default_value", 0.0))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name_lbl := Label.new()
	name_lbl.text = disp
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", TEXT)
	row.add_child(name_lbl)

	var badge := Label.new()
	badge.text = "[LIVE]" if is_live else "[RESTART]"
	badge.add_theme_font_size_override("font_size", 8)
	badge.add_theme_color_override("font_color", LIVE_COLOR if is_live else RESTART_COLOR)
	row.add_child(badge)
	_pages_container.add_child(row)

	if p_type == "distribution":
		_build_distribution_widget(elem, key, cur_val)
	elif p_type == "enum":
		var opts: Array = schema.get("enum_options", schema.get("options", []))
		if not opts.is_empty():
			var opt_btn := OptionButton.new()
			opt_btn.custom_minimum_size.x = 180
			opt_btn.add_theme_font_size_override("font_size", 9)
			var sel_idx := -1
			for i in range(opts.size()):
				var item = opts[i]
				var val_str: String = item.get("value", "") if item is Dictionary else str(item)
				var label_str: String = item.get("label", val_str) if item is Dictionary else str(item)
				opt_btn.add_item(label_str, i)
				if str(cur_val) == val_str:
					sel_idx = i
			if opt_btn.item_count > 0:
				if sel_idx < 0:
					sel_idx = 0
				opt_btn.select(sel_idx)
			opt_btn.item_selected.connect(func(idx):
				if idx >= 0 and idx < opts.size():
					var sel_item = opts[idx]
					var chosen = sel_item.get("value", str(sel_item)) if sel_item is Dictionary else str(sel_item)
					doc_store.set_element_property(elem.id, key, chosen)
			)
			_pages_container.add_child(opt_btn)
	elif p_type == "bool":
		var chk := CheckBox.new()
		chk.text = "Enabled"
		chk.button_pressed = bool(cur_val)
		chk.add_theme_font_size_override("font_size", 9)
		chk.toggled.connect(func(v):
			doc_store.set_element_property(elem.id, key, v)
		)
		_pages_container.add_child(chk)
	elif p_type == "string":
		var le := LineEdit.new()
		le.text = str(cur_val)
		le.custom_minimum_size.x = 180
		le.add_theme_font_size_override("font_size", 9)
		le.text_submitted.connect(func(new_text):
			doc_store.set_element_property(elem.id, key, new_text)
		)
		le.focus_exited.connect(func():
			doc_store.set_element_property(elem.id, key, le.text)
		)
		_pages_container.add_child(le)
	else:
		# Scalar float or int
		var range_arr: Array = schema.get("range", [0.0, 1000.0, 0.1])
		var min_v: float = range_arr[0] if range_arr.size() >= 1 else 0.0
		var max_v: float = range_arr[1] if range_arr.size() >= 2 else 1000.0
		var step_v: float = range_arr[2] if range_arr.size() >= 3 else 0.1
		var f_val: float = float(cur_val) if (cur_val is float or cur_val is int) else 0.0

		var sp := SpinBox.new()
		sp.min_value = min_v
		sp.max_value = max_v
		sp.step = step_v
		sp.value = f_val
		sp.suffix = unit
		sp.custom_minimum_size.x = 160
		sp.add_theme_font_size_override("font_size", 9)
		sp.value_changed.connect(func(v):
			var final_val = int(v) if p_type == "int" else v
			doc_store.set_element_property(elem.id, key, final_val)
		)
		_pages_container.add_child(sp)

func _build_distribution_widget(elem: SceneTypes.SceneElement, key: String, cur_val) -> void:
	var dist_dict: Dictionary = {}
	if cur_val is Dictionary:
		dist_dict = cur_val.duplicate(true)
	else:
		dist_dict = {"distribution": "triangular", "min": 2.0, "mode": float(cur_val), "max": float(cur_val) * 1.5}

	var d_type: String = str(dist_dict.get("type", dist_dict.get("distribution", "triangular")))

	var type_row := HBoxContainer.new()
	var type_lbl := Label.new()
	type_lbl.text = "Distribution Model:"
	type_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_lbl.add_theme_font_size_override("font_size", 9)
	type_lbl.add_theme_color_override("font_color", MUTED)
	type_row.add_child(type_lbl)

	var opt := OptionButton.new()
	var dist_names := ["triangular", "exponential", "normal", "uniform", "constant"]
	for i in range(dist_names.size()):
		opt.add_item(dist_names[i].capitalize(), i)
		if dist_names[i] == d_type:
			opt.selected = i
	type_row.add_child(opt)
	_pages_container.add_child(type_row)

	# Dynamic parameters row
	var param_row := HBoxContainer.new()
	param_row.add_theme_constant_override("separation", 6)
	_pages_container.add_child(param_row)

	match d_type:
		"triangular":
			_add_mini_spin(param_row, "Min (s)", float(dist_dict.get("min", 2.0)), func(v):
				dist_dict["min"] = v
				doc_store.set_element_property(elem.id, key, dist_dict)
			)
			_add_mini_spin(param_row, "Mode (s)", float(dist_dict.get("mode", 4.5)), func(v):
				dist_dict["mode"] = v
				doc_store.set_element_property(elem.id, key, dist_dict)
			)
			_add_mini_spin(param_row, "Max (s)", float(dist_dict.get("max", 7.0)), func(v):
				dist_dict["max"] = v
				doc_store.set_element_property(elem.id, key, dist_dict)
			)
		"exponential":
			_add_mini_spin(param_row, "Mean (s)", float(dist_dict.get("mean", 3.0)), func(v):
				dist_dict["mean"] = v
				doc_store.set_element_property(elem.id, key, dist_dict)
			)
		"normal":
			_add_mini_spin(param_row, "Mean (s)", float(dist_dict.get("mean", 5.0)), func(v):
				dist_dict["mean"] = v
				doc_store.set_element_property(elem.id, key, dist_dict)
			)
			_add_mini_spin(param_row, "Std Dev", float(dist_dict.get("std_dev", 1.0)), func(v):
				dist_dict["std_dev"] = v
				doc_store.set_element_property(elem.id, key, dist_dict)
			)
		"uniform":
			_add_mini_spin(param_row, "Min (s)", float(dist_dict.get("min", 1.0)), func(v):
				dist_dict["min"] = v
				doc_store.set_element_property(elem.id, key, dist_dict)
			)
			_add_mini_spin(param_row, "Max (s)", float(dist_dict.get("max", 5.0)), func(v):
				dist_dict["max"] = v
				doc_store.set_element_property(elem.id, key, dist_dict)
			)
		_:
			_add_mini_spin(param_row, "Value (s)", float(dist_dict.get("value", 3.0)), func(v):
				dist_dict["value"] = v
				doc_store.set_element_property(elem.id, key, dist_dict)
			)

	# Inline Sparkline
	var spark := Inspector.DistributionSparkline.new(dist_dict)
	spark.custom_minimum_size = Vector2(0, 36)
	_pages_container.add_child(spark)

	opt.item_selected.connect(func(idx):
		var n: String = dist_names[idx]
		var new_d := {"distribution": n, "type": n}
		match n:
			"triangular": new_d["min"] = 2.0; new_d["mode"] = 4.5; new_d["max"] = 7.0
			"exponential": new_d["mean"] = 3.0
			"normal": new_d["mean"] = 5.0; new_d["std_dev"] = 1.0
			"uniform": new_d["min"] = 1.0; new_d["max"] = 5.0
			_: new_d["value"] = 3.0
		doc_store.set_element_property(elem.id, key, new_d)
		refresh()
	)

# ============================================================================
# Tab 1: Spatial & CAD Footprint (Compact 3-Column Grid)
# ============================================================================
func _render_spatial_tab(elem: SceneTypes.SceneElement) -> void:
	var info_lbl := Label.new()
	info_lbl.text = "PHYSICAL COORDINATES & BOUNDS (1m = 20px)"
	info_lbl.add_theme_font_size_override("font_size", 10)
	info_lbl.add_theme_color_override("font_color", MUTED)
	_pages_container.add_child(info_lbl)

	# 1. Position X, Y, Z (Single 3-column row)
	var pos_lbl := Label.new()
	pos_lbl.text = "Position Coordinates (m):"
	pos_lbl.add_theme_font_size_override("font_size", 9)
	pos_lbl.add_theme_color_override("font_color", TEXT)
	_pages_container.add_child(pos_lbl)

	var px: float = float(elem.transform.position.x)
	var py: float = float(elem.transform.position.y)
	var pz: float = float(elem.transform.position.z)

	var pos_row := HBoxContainer.new()
	pos_row.add_theme_constant_override("separation", 6)
	_pages_container.add_child(pos_row)

	_spin_px = _create_coord_spin(pos_row, "X (m)", px, -500.0, 500.0, 0.5, func(v):
		elem.transform.position.x = v
		elem.editor.graph_position.x = v * 20.0
		doc_store.validate()
		doc_store.document_modified.emit()
	)
	_spin_py = _create_coord_spin(pos_row, "Y (m)", py, -500.0, 500.0, 0.5, func(v):
		elem.transform.position.y = v
		elem.editor.graph_position.y = v * 20.0
		doc_store.validate()
		doc_store.document_modified.emit()
	)
	_spin_pz = _create_coord_spin(pos_row, "Z (m)", pz, -50.0, 500.0, 0.5, func(v):
		elem.transform.position.z = v
		doc_store.validate()
		doc_store.document_modified.emit()
	)

	_pages_container.add_child(HSeparator.new())

	# 2. Dimensions Length, Width, Height (Single 3-column row)
	var dims = elem.geometry.get("dimensions", [3.0, 2.0, 1.0])
	var cur_l: float = float(dims[0]) if dims is Array and dims.size() >= 1 else 3.0
	var cur_w: float = float(dims[1]) if dims is Array and dims.size() >= 2 else 2.0
	var cur_h: float = float(dims[2]) if dims is Array and dims.size() >= 3 else 1.0
	var zs: float = float(elem.geometry.get("elevation_start", 0.8))
	var ze: float = float(elem.geometry.get("elevation_end", zs))

	var dim_lbl := Label.new()
	dim_lbl.text = "Bounding Dimensions (m):"
	dim_lbl.add_theme_font_size_override("font_size", 9)
	dim_lbl.add_theme_color_override("font_color", TEXT)
	_pages_container.add_child(dim_lbl)

	var dim_row := HBoxContainer.new()
	dim_row.add_theme_constant_override("separation", 6)
	_pages_container.add_child(dim_row)

	_spin_len = _create_coord_spin(dim_row, "Length", cur_l, 0.5, 100.0, 0.1, func(v):
		doc_store.update_element_geometry(elem.id, Vector3(v, cur_w, cur_h), zs, ze)
	)
	_spin_wid = _create_coord_spin(dim_row, "Width", cur_w, 0.2, 50.0, 0.1, func(v):
		doc_store.update_element_geometry(elem.id, Vector3(cur_l, v, cur_h), zs, ze)
	)
	_spin_hgt = _create_coord_spin(dim_row, "Height", cur_h, 0.1, 50.0, 0.1, func(v):
		doc_store.update_element_geometry(elem.id, Vector3(cur_l, cur_w, v), zs, ze)
	)

	_pages_container.add_child(HSeparator.new())

	# 3. Orientation & Elevation Start / End (Single 3-column row)
	var cur_rot: float = fposmod(float(elem.transform.rotation.z), 360.0)

	var ori_lbl := Label.new()
	ori_lbl.text = "Orientation & Elevation Profile:"
	ori_lbl.add_theme_font_size_override("font_size", 9)
	ori_lbl.add_theme_color_override("font_color", TEXT)
	_pages_container.add_child(ori_lbl)

	var ori_row := HBoxContainer.new()
	ori_row.add_theme_constant_override("separation", 6)
	_pages_container.add_child(ori_row)

	_spin_rot = _create_coord_spin(ori_row, "Rotation (°)", cur_rot, 0.0, 360.0, 1.0, func(v):
		doc_store.set_element_rotation(elem.id, v)
	)
	_spin_zs = _create_coord_spin(ori_row, "Elev Z1 (m)", zs, 0.0, 50.0, 0.1, func(v):
		doc_store.update_element_geometry(elem.id, Vector3(cur_l, cur_w, cur_h), v, ze)
	)
	_spin_ze = _create_coord_spin(ori_row, "Elev Z2 (m)", ze, 0.0, 50.0, 0.1, func(v):
		doc_store.update_element_geometry(elem.id, Vector3(cur_l, cur_w, cur_h), zs, v)
	)

	if elem.kind == "conveyor":
		_pages_container.add_child(HSeparator.new())
		var conv_lbl := Label.new()
		conv_lbl.text = "CONVEYOR SHAPE PRESET & CURVE PARAMETERS"
		conv_lbl.add_theme_font_size_override("font_size", 10)
		conv_lbl.add_theme_color_override("font_color", ACCENT)
		_pages_container.add_child(conv_lbl)

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
		p_row.add_theme_constant_override("separation", 8)
		var p_lbl := Label.new()
		p_lbl.text = "Shape Preset:"
		p_lbl.add_theme_font_size_override("font_size", 10)
		p_lbl.add_theme_color_override("font_color", TEXT)
		p_row.add_child(p_lbl)

		var opt_preset := OptionButton.new()
		opt_preset.name = "FloatingConveyorPresetDropdown"
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
		var reset_confirmed := [false]
		opt_preset.item_selected.connect(func(idx: int):
			if idx >= 0 and idx < ConveyorCurve3D.PRESET_IDS.size():
				var locks := ConveyorCurve3D.connected_endpoint_locks(elem.id, doc_store)
				if locks["inlet"] or locks["outlet"]:
					return
				var pid: String = ConveyorCurve3D.PRESET_IDS[idx]
				if pid == str(elem.geometry.get("shape_preset", "straight")):
					return
				if pid == "custom_spline" and cur_preset != "custom_spline":
					_request_custom_spline_conversion(elem, func(): opt_preset.select(sel_idx))
					return
				if cur_preset == "custom_spline" and not reset_confirmed[0]:
					var confirm := ConfirmationDialog.new()
					confirm.title = "Reset Conveyor Geometry"
					confirm.dialog_text = "Replace the editable bends with this preset?"
					add_child(confirm)
					confirm.confirmed.connect(func():
						confirm.queue_free()
						reset_confirmed[0] = true
						opt_preset.item_selected.emit(idx)
						reset_confirmed[0] = false
					)
					confirm.canceled.connect(func():
						opt_preset.select(sel_idx)
						confirm.queue_free()
					)
					confirm.popup_centered()
					return
				doc_store._record_undo()
				var previous_length := float(ConveyorCurve3D.sample_world_curve(elem, doc_store)["total_length"])
				if pid != str(elem.geometry.get("shape_preset", "straight")):
					elem.geometry.erase("corner_pos")
					if elem.geometry.get("shape_params") is Dictionary:
						elem.geometry["shape_params"].erase("corner_pos")
				elem.geometry["shape_preset"] = pid
				if pid == "straight":
					elem.geometry.erase("inlet_pose")
					elem.geometry.erase("outlet_pose")
					if not (elem.geometry.get("dimensions") is Array):
						elem.geometry["dimensions"] = [previous_length, 1.2, 0.2]
					else:
						elem.geometry["dimensions"][0] = previous_length
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
		)
		p_row.add_child(opt_preset)
		_pages_container.add_child(p_row)

		# Belt Width (m) adjustment directly in floating inspector
		var cur_dims: Array = elem.geometry.get("dimensions", [8.0, 1.2, 0.2]) if (elem.geometry.get("dimensions") is Array) else [8.0, 1.2, 0.2]
		var conv_belt_w: float = float(cur_dims[1]) if cur_dims.size() >= 2 else 1.2
		var conv_dim_row := HBoxContainer.new()
		conv_dim_row.add_theme_constant_override("separation", 6)
		_create_coord_spin(conv_dim_row, "Belt Width (m)", conv_belt_w, 0.4, 8.0, 0.1, func(v):
			doc_store._record_undo()
			if not (elem.geometry.get("dimensions") is Array):
				elem.geometry["dimensions"] = [8.0, v, 0.2]
			else:
				elem.geometry["dimensions"][1] = v
			ConveyorCurve3D.sample_world_curve(elem, doc_store)
			doc_store.is_dirty = true
			doc_store.document_modified.emit()
		)
		_pages_container.add_child(conv_dim_row)
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
		_pages_container.add_child(profile_row)
		for key_index in range(width_profile.size()):
			var width_key = width_profile[key_index]
			if not (width_key is Dictionary):
				continue
			var key_row := HBoxContainer.new()
			_create_coord_spin(key_row, "Position (%)", float(width_key.get("fraction", 0.5)) * 100.0, 0.0, 100.0, 1.0, func(value):
				doc_store._record_undo()
				width_key["fraction"] = value / 100.0
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_create_coord_spin(key_row, "Local Width (m)", ConveyorCurve3D.width_at_fraction(elem, float(width_key.get("fraction", 0.5))), 0.4, 8.0, 0.1, func(value):
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
			_pages_container.add_child(key_row)
		var rotation_row := HBoxContainer.new()
		var rotation_spin := _create_coord_spin(rotation_row, "Rotate (°)", float(elem.transform.rotation.z), -360.0, 360.0, 5.0, func(v):
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
		if cur_preset == "straight":
			var length_spin := _create_coord_spin(rotation_row, "Length (m)", float(cur_dims[0]), 1.0, 500.0, 0.5, func(v):
				if ConveyorCurve3D.connected_endpoint_locks(elem.id, doc_store)["outlet"]:
					return
				doc_store._record_undo()
				elem.geometry["dimensions"][0] = v
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			length_spin.editable = not preset_locks["outlet"]
			if not length_spin.editable:
				length_spin.tooltip_text = "Disconnect outlet flow to change length"
		_pages_container.add_child(rotation_row)

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
		_pages_container.add_child(btn_edit_geom)

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
		_pages_container.add_child(chk_join)

		# Progressive disclosure of preset parameters
		if cur_preset == "l_bend":
			var row1 := HBoxContainer.new()
			row1.add_theme_constant_override("separation", 6)
			_create_coord_spin(row1, "Radius (m)", float(sp.get("bend_radius", 2.0)), 0.3, 25.0, 0.1, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "bend_radius", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_create_coord_spin(row1, "Bend Angle (°)", float(sp.get("bend_angle_deg", 90.0)), 15.0, 165.0, 5.0, func(v):
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
			_pages_container.add_child(row1)

			var row2 := HBoxContainer.new()
			row2.add_theme_constant_override("separation", 6)
			_create_coord_spin(row2, "Leg 1 / Infeed (m)", float(sp.get("leg1_length", 5.0)), 1.0, 100.0, 0.5, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "leg1_length", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_create_coord_spin(row2, "Leg 2 / Outfeed (m)", float(sp.get("leg2_length", 5.0)), 1.0, 100.0, 0.5, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "leg2_length", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_pages_container.add_child(row2)

		elif cur_preset == "s_curve":
			var s_row := HBoxContainer.new()
			s_row.add_theme_constant_override("separation", 6)
			_create_coord_spin(s_row, "Lateral Offset (m)", float(sp.get("lateral_offset", 2.5)), -50.0, 50.0, 0.2, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "lateral_offset", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_create_coord_spin(s_row, "Forward Span (m)", float(sp.get("forward_span", 8.0)), 2.0, 100.0, 0.5, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "forward_span", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_create_coord_spin(s_row, "Tangent Scale", float(sp.get("tangent_scale", 0.42)), 0.1, 1.5, 0.05, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, "tangent_scale", v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			_pages_container.add_child(s_row)

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
				ConveyorCurve3D.sample_world_curve(elem, doc_store)
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
					ConveyorCurve3D.sample_world_curve(elem, doc_store)
					doc_store.is_dirty = true
					doc_store.document_modified.emit()
					call_deferred("refresh")
			)
			spl_row.add_child(btn_del)
			_pages_container.add_child(spl_row)

		elif cur_preset in ["u_turn", "circular_arc", "serpentine", "spiral_helix"]:
			var param_row := HBoxContainer.new()
			param_row.add_theme_constant_override("separation", 6)
			var radius_key := "helix_radius" if cur_preset == "spiral_helix" else "pass_spacing" if cur_preset == "serpentine" else "bend_radius"
			_create_coord_spin(param_row, "Radius (m)" if cur_preset != "serpentine" else "Lane C-C (m)", float(sp.get(radius_key, 2.5 if cur_preset == "spiral_helix" else 2.0)), 1.2 if cur_preset == "serpentine" else 1.0 if cur_preset == "spiral_helix" else 0.5, 25.0, 0.1, func(v):
				ConveyorCurve3D.update_shape_parameter(elem, radius_key, v, doc_store)
				doc_store.is_dirty = true
				doc_store.document_modified.emit()
			)
			if cur_preset == "circular_arc":
				_create_coord_spin(param_row, "Sweep (°)", float(sp.get("sweep_angle_deg", 90.0)), -350.0, 350.0, 5.0, func(v):
					ConveyorCurve3D.update_shape_parameter(elem, "sweep_angle_deg", v, doc_store)
					doc_store.is_dirty = true
					doc_store.document_modified.emit()
				)
			elif cur_preset == "serpentine":
				_create_coord_spin(param_row, "Bends", float(sp.get("passes", 3)) - 1.0, 1.0, 11.0, 1.0, func(v):
					ConveyorCurve3D.update_shape_parameter(elem, "passes", int(round(v)) + 1, doc_store)
					doc_store.is_dirty = true
					doc_store.document_modified.emit()
				)
				_create_coord_spin(param_row, "Pass Length (m)", float(sp.get("pass_length", float(cur_dims[0]))), 3.0, 100.0, 0.2, func(v):
					ConveyorCurve3D.update_shape_parameter(elem, "pass_length", v, doc_store)
					doc_store.is_dirty = true
					doc_store.document_modified.emit()
				)
				var end_run_limit: float = maxf(3.0, float(sp.get("pass_length", float(cur_dims[0]))))
				_create_coord_spin(param_row, "Infeed Lead (m)", float(sp.get("infeed_length", 0.0)), 0.0, end_run_limit, 0.1, func(v):
					ConveyorCurve3D.update_shape_parameter(elem, "infeed_length", v, doc_store)
					doc_store.is_dirty = true
					doc_store.document_modified.emit()
				)
				_create_coord_spin(param_row, "Outfeed Lead (m)", float(sp.get("outfeed_length", 0.0)), 0.0, end_run_limit, 0.1, func(v):
					ConveyorCurve3D.update_shape_parameter(elem, "outfeed_length", v, doc_store)
					doc_store.is_dirty = true
					doc_store.document_modified.emit()
				)
			elif cur_preset == "spiral_helix":
				_create_coord_spin(param_row, "Turns", float(sp.get("helix_turns", 1.5)), 0.25, 6.0, 0.25, func(v):
					ConveyorCurve3D.update_shape_parameter(elem, "helix_turns", v, doc_store)
					doc_store.is_dirty = true
					doc_store.document_modified.emit()
				)
				_create_coord_spin(param_row, "Rise (m)", float(sp.get("elevation_gain", 2.4)), -20.0, 20.0, 0.1, func(v):
					ConveyorCurve3D.update_shape_parameter(elem, "elevation_gain", v, doc_store)
					doc_store.is_dirty = true
					doc_store.document_modified.emit()
				)
				_create_coord_spin(param_row, "Pitch (m/turn)", float(sp.get("elevation_gain", 2.4)) / maxf(0.25, float(sp.get("helix_turns", 1.5))), -20.0, 20.0, 0.1, func(v):
					ConveyorCurve3D.update_shape_parameter(elem, "elevation_gain", v * float(elem.geometry["shape_params"].get("helix_turns", 1.5)), doc_store)
					doc_store.is_dirty = true
					doc_store.document_modified.emit()
				)
			elif cur_preset == "u_turn":
				_create_coord_spin(param_row, "Leg Length (m)", float(sp.get("leg_length", 6.0)), 1.5, 100.0, 0.5, func(v):
					ConveyorCurve3D.update_shape_parameter(elem, "leg_length", v, doc_store)
					doc_store.is_dirty = true
					doc_store.document_modified.emit()
				)
				_create_coord_spin(param_row, "Return Leg (m)", float(sp.get("return_leg_length", sp.get("leg_length", 6.0))), 1.5, 100.0, 0.5, func(v):
					ConveyorCurve3D.update_shape_parameter(elem, "return_leg_length", v, doc_store)
					doc_store.is_dirty = true
					doc_store.document_modified.emit()
				)
			_pages_container.add_child(param_row)
			if cur_preset == "serpentine":
				var spacing: float = float(sp.get("pass_spacing", 2.0))
				var widest: float = ConveyorCurve3D.maximum_width(elem)
				var gap_label := Label.new()
				gap_label.text = "Footprint: %.2f m  |  Min lane gap: %.2f m" % [(float(sp.get("passes", 3)) - 1.0) * spacing + widest, spacing - widest]
				gap_label.add_theme_font_size_override("font_size", 9)
				gap_label.add_theme_color_override("font_color", Color("#f39c12") if spacing < widest else MUTED)
				_pages_container.add_child(gap_label)

		# Convert to Editable Spline Button (available for all non-custom presets)
		if cur_preset != "custom_spline":
			var btn_convert := Button.new()
			btn_convert.text = "✏ Convert to Editable Spline"
			btn_convert.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn_convert.add_theme_font_size_override("font_size", 10)
			btn_convert.pressed.connect(func():
				_request_custom_spline_conversion(elem)
			)
			_pages_container.add_child(btn_convert)


# ============================================================================
# Tab 2: Ports & Interfaces
# ============================================================================
func _render_ports_tab(elem: SceneTypes.SceneElement) -> void:
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 6)
	_pages_container.add_child(top_row)

	var info_lbl := Label.new()
	info_lbl.text = "SOCKET INTERFACES & CHUTE CAPACITIES"
	info_lbl.add_theme_font_size_override("font_size", 10)
	info_lbl.add_theme_color_override("font_color", MUTED)
	info_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(info_lbl)

	# Dynamic Bay Add / Remove Port Buttons
	var add_in_btn := Button.new()
	add_in_btn.text = "+ Infeed"
	add_in_btn.add_theme_font_size_override("font_size", 9)
	add_in_btn.pressed.connect(func(): _add_dynamic_port(elem, "flow_in"))
	top_row.add_child(add_in_btn)

	var add_out_btn := Button.new()
	add_out_btn.text = "+ Outfeed"
	add_out_btn.add_theme_font_size_override("font_size", 9)
	add_out_btn.pressed.connect(func(): _add_dynamic_port(elem, "flow_out"))
	top_row.add_child(add_out_btn)

	var rem_port_btn := Button.new()
	rem_port_btn.text = "- Remove Last"
	rem_port_btn.add_theme_font_size_override("font_size", 9)
	rem_port_btn.pressed.connect(func(): _remove_dynamic_port(elem))
	top_row.add_child(rem_port_btn)

	_pages_container.add_child(HSeparator.new())

	var all_ports: Array = []
	for p in elem.input_ports: all_ports.append({"p": p, "dir": "IN"})
	for p in elem.output_ports: all_ports.append({"p": p, "dir": "OUT"})
	for p in elem.metric_ports: all_ports.append({"p": p, "dir": "MET"})

	if all_ports.is_empty():
		var no_p := Label.new()
		no_p.text = "No active ports configured for this element."
		no_p.add_theme_font_size_override("font_size", 10)
		no_p.add_theme_color_override("font_color", MUTED)
		_pages_container.add_child(no_p)
		return

	for item in all_ports:
		var p: SceneTypes.ScenePort = item["p"]
		var dir_str: String = item["dir"]

		var card := PanelContainer.new()
		var c_style := StyleBoxFlat.new()
		c_style.bg_color = PANEL_ALT
		c_style.border_color = BORDER
		c_style.set_border_width_all(1)
		c_style.set_corner_radius_all(4)
		card.add_theme_stylebox_override("panel", c_style)
		_pages_container.add_child(card)

		var card_box := VBoxContainer.new()
		card_box.add_theme_constant_override("separation", 6)
		card_box.add_theme_constant_override("margin_left", 8)
		card_box.add_theme_constant_override("margin_right", 8)
		card_box.add_theme_constant_override("margin_top", 6)
		card_box.add_theme_constant_override("margin_bottom", 6)
		card.add_child(card_box)

		# Row 1: Header (Kind Dot, Direction Badge, Port ID, Cardinality Selector)
		var r1 := HBoxContainer.new()
		r1.add_theme_constant_override("separation", 6)

		var p_col_hex := "#2ecc71" if p.kind == "flow" else ("#9b59b6" if p.kind == "metric" else "#3498db")
		var p_dot := ColorRect.new()
		p_dot.custom_minimum_size = Vector2(8, 8)
		p_dot.color = Color(p_col_hex)
		r1.add_child(p_dot)

		var dir_badge := Label.new()
		dir_badge.text = "[%s]" % dir_str
		dir_badge.add_theme_font_size_override("font_size", 9)
		dir_badge.add_theme_color_override("font_color", Color(p_col_hex))
		r1.add_child(dir_badge)

		var p_id_lbl := Label.new()
		p_id_lbl.text = p.id
		p_id_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		p_id_lbl.add_theme_font_size_override("font_size", 10)
		p_id_lbl.add_theme_color_override("font_color", TEXT)
		r1.add_child(p_id_lbl)

		# Interactive Cardinality Dropdown
		var card_opt := OptionButton.new()
		card_opt.add_item("Single Link (one)", 0)
		card_opt.add_item("Multi-Link (many)", 1)
		card_opt.select(1 if p.cardinality == "many" else 0)
		card_opt.add_theme_font_size_override("font_size", 9)
		var pid_card: String = p.id
		card_opt.item_selected.connect(func(idx):
			var val := "many" if idx == 1 else "one"
			doc_store.update_port_properties(elem.id, pid_card, {"cardinality": val})
		)
		r1.add_child(card_opt)

		card_box.add_child(r1)

		# Row 2: Editable Port Name / Display Alias
		var r2 := HBoxContainer.new()
		r2.add_theme_constant_override("separation", 6)

		var name_lbl := Label.new()
		name_lbl.text = "Display Name:"
		name_lbl.add_theme_font_size_override("font_size", 9)
		name_lbl.add_theme_color_override("font_color", MUTED)
		r2.add_child(name_lbl)

		var name_edit := LineEdit.new()
		name_edit.text = p.name if not p.name.is_empty() else p.id
		name_edit.placeholder_text = "Display Name / Alias"
		name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_edit.add_theme_font_size_override("font_size", 9)
		var pid_name: String = p.id
		name_edit.text_submitted.connect(func(new_text: String):
			doc_store.update_port_properties(elem.id, pid_name, {"name": new_text})
		)
		name_edit.focus_exited.connect(func():
			if name_edit != null and is_instance_valid(name_edit) and not name_edit.is_queued_for_deletion() and name_edit.text != p.name:
				doc_store.update_port_properties(elem.id, pid_name, {"name": name_edit.text})
		)
		r2.add_child(name_edit)
		card_box.add_child(r2)

		# Row 3: Kinematics (Chute Buffer Capacity & Handshake Latency)
		if p.kind == "flow":
			var r3 := HBoxContainer.new()
			r3.add_theme_constant_override("separation", 8)

			var cur_cap: int = int(p.get_extension("chute_buffer_capacity", p.get_extension("chute_capacity", 5)))
			var cap_lbl := Label.new()
			cap_lbl.text = "Buffer Capacity:"
			cap_lbl.add_theme_font_size_override("font_size", 9)
			cap_lbl.add_theme_color_override("font_color", MUTED)
			r3.add_child(cap_lbl)

			var cap_sp := SpinBox.new()
			cap_sp.min_value = 1
			cap_sp.max_value = 500
			cap_sp.step = 1
			cap_sp.value = cur_cap
			cap_sp.suffix = " items"
			cap_sp.add_theme_font_size_override("font_size", 9)
			var pid_cap: String = p.id
			cap_sp.value_changed.connect(func(v):
				doc_store.update_port_properties(elem.id, pid_cap, {
					"chute_buffer_capacity": int(v),
					"chute_capacity": int(v)
				})
			)
			r3.add_child(cap_sp)

			var cur_lat: float = float(p.get_extension("conveyance_handshake_latency_sec", p.get_extension("latency", 0.2)))
			var lat_lbl := Label.new()
			lat_lbl.text = "Handshake:"
			lat_lbl.add_theme_font_size_override("font_size", 9)
			lat_lbl.add_theme_color_override("font_color", MUTED)
			r3.add_child(lat_lbl)

			var lat_sp := SpinBox.new()
			lat_sp.min_value = 0.0
			lat_sp.max_value = 60.0
			lat_sp.step = 0.05
			lat_sp.value = cur_lat
			lat_sp.suffix = " s"
			lat_sp.add_theme_font_size_override("font_size", 9)
			var pid_lat: String = p.id
			lat_sp.value_changed.connect(func(v):
				doc_store.update_port_properties(elem.id, pid_lat, {
					"conveyance_handshake_latency_sec": v,
					"latency": v
				})
			)
			r3.add_child(lat_sp)

			card_box.add_child(r3)
		elif p.kind in ["signal", "metric"]:
			var r3 := HBoxContainer.new()
			r3.add_theme_constant_override("separation", 8)

			var cur_lat: float = float(p.get_extension("conveyance_handshake_latency_sec", p.get_extension("latency", 0.0)))
			var lat_lbl := Label.new()
			lat_lbl.text = "Signal Latency:"
			lat_lbl.add_theme_font_size_override("font_size", 9)
			lat_lbl.add_theme_color_override("font_color", MUTED)
			r3.add_child(lat_lbl)

			var lat_sp := SpinBox.new()
			lat_sp.min_value = 0.0
			lat_sp.max_value = 10.0
			lat_sp.step = 0.01
			lat_sp.value = cur_lat
			lat_sp.suffix = " s"
			lat_sp.add_theme_font_size_override("font_size", 9)
			var pid_sig: String = p.id
			lat_sp.value_changed.connect(func(v):
				doc_store.update_port_properties(elem.id, pid_sig, {
					"conveyance_handshake_latency_sec": v,
					"latency": v
				})
			)
			r3.add_child(lat_sp)

			card_box.add_child(r3)

		# Row 4: Connected Wires (Detailed Routing)
		var attached_conns: Array = []
		if doc_store != null and doc_store.active_document != null:
			for c in doc_store.active_document.connections:
				if (c.source_element == elem.id and c.source_port == p.id) or \
				   (c.target_element == elem.id and c.target_port == p.id):
					attached_conns.append(c)

		if attached_conns.is_empty():
			var no_conn := Label.new()
			no_conn.text = "○ No active wires connected"
			no_conn.add_theme_font_size_override("font_size", 8)
			no_conn.add_theme_color_override("font_color", MUTED)
			card_box.add_child(no_conn)
		else:
			for c in attached_conns:
				var c_row := HBoxContainer.new()
				c_row.add_theme_constant_override("separation", 6)

				var c_lbl := Label.new()
				var cond_str := ""
				if c.condition is Dictionary and not c.condition.is_empty():
					cond_str = " [IF %s %s %s]" % [c.condition.get("metric", ""), c.condition.get("operator", ""), str(c.condition.get("threshold", ""))]
				if c.source_element == elem.id and c.source_port == p.id:
					c_lbl.text = "→ OUT to %s.%s%s" % [c.target_element, c.target_port, cond_str]
				else:
					c_lbl.text = "← IN from %s.%s%s" % [c.source_element, c.source_port, cond_str]
				c_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				c_lbl.add_theme_font_size_override("font_size", 8)
				c_lbl.add_theme_color_override("font_color", TEXT)
				c_row.add_child(c_lbl)

				var disc_wire_btn := Button.new()
				disc_wire_btn.text = "Sever Wire"
				disc_wire_btn.add_theme_font_size_override("font_size", 8)
				disc_wire_btn.add_theme_color_override("font_color", DANGER)
				var cid: String = c.id
				disc_wire_btn.pressed.connect(func():
					doc_store.remove_connection(cid)
					refresh()
				)
				c_row.add_child(disc_wire_btn)
				card_box.add_child(c_row)

			if attached_conns.size() > 1:
				var disc_all_btn := Button.new()
				disc_all_btn.text = "Disconnect All Attached Wires (%d)" % attached_conns.size()
				disc_all_btn.add_theme_font_size_override("font_size", 8)
				disc_all_btn.add_theme_color_override("font_color", DANGER)
				var pid_all: String = p.id
				disc_all_btn.pressed.connect(func():
					_disconnect_port_wires(elem.id, pid_all)
				)
				card_box.add_child(disc_all_btn)

func _add_dynamic_port(elem: SceneTypes.SceneElement, bay: String) -> void:
	if doc_store == null:
		return
	var port := SceneTypes.ScenePort.new()
	match bay:
		"flow_in":
			var count := 1
			for p in elem.input_ports:
				if p.kind == "flow": count += 1
			port.id = "flow_in_%d" % count
			port.kind = "flow"
			port.direction = "input"
			port.cardinality = "one"
			port.name = "Flow In %d" % count
			doc_store.add_port_to_element(elem.id, port)
		"flow_out":
			var count := 1
			for p in elem.output_ports:
				if p.kind == "flow": count += 1
			port.id = "flow_out_%d" % count
			port.kind = "flow"
			port.direction = "output"
			port.cardinality = "one"
			port.name = "Flow Out %d" % count
			doc_store.add_port_to_element(elem.id, port)
	refresh()

func _remove_dynamic_port(elem: SceneTypes.SceneElement) -> void:
	if doc_store == null:
		return
	var ok := doc_store.remove_last_port_from_element(elem.id, "flow_out")
	if not ok:
		doc_store.remove_last_port_from_element(elem.id, "flow_in")
	refresh()

func _disconnect_port_wires(elem_id: String, port_id: String) -> void:
	if doc_store == null or doc_store.active_document == null:
		return
	var to_remove: Array[String] = []
	for c in doc_store.active_document.connections:
		if (c.source_element == elem_id and c.source_port == port_id) or \
		   (c.target_element == elem_id and c.target_port == port_id):
			to_remove.append(c.id)
	for cid in to_remove:
		doc_store.remove_connection(cid)
	refresh()

# ============================================================================
# Tab 3: Reliability & Routing Rules
# ============================================================================
func _render_rules_tab(elem: SceneTypes.SceneElement) -> void:
	var rel_title := Label.new()
	rel_title.text = "RELIABILITY & STOCHASTIC DOWNTIME"
	rel_title.add_theme_font_size_override("font_size", 10)
	rel_title.add_theme_color_override("font_color", MUTED)
	_pages_container.add_child(rel_title)

	var cur_model: String = str(elem.properties.get("failure_model", "None"))

	var m_row := HBoxContainer.new()
	var m_lbl := Label.new()
	m_lbl.text = "Failure Model:"
	m_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m_lbl.add_theme_font_size_override("font_size", 10)
	m_lbl.add_theme_color_override("font_color", TEXT)
	m_row.add_child(m_lbl)

	var opt := OptionButton.new()
	opt.add_item("None (100% Availability)", 0)
	opt.add_item("MTBF / MTTR Breakdowns", 1)
	opt.selected = 1 if cur_model == "MTBF_MTTR" else 0
	opt.item_selected.connect(func(idx):
		var chosen := "MTBF_MTTR" if idx == 1 else "None"
		doc_store.set_element_property(elem.id, "failure_model", chosen)
		refresh()
	)
	m_row.add_child(opt)
	_pages_container.add_child(m_row)

	# Progressive disclosure: Only show MTBF, MTTR, and Failure Rate if MTBF_MTTR
	if cur_model == "MTBF_MTTR":
		var mtbf_val: float = float(elem.properties.get("mtbf", 3600.0))
		var mttr_val: float = float(elem.properties.get("mttr", 120.0))
		var fail_val: float = float(elem.properties.get("failure_rate", 0.001))

		var rel_row := HBoxContainer.new()
		rel_row.add_theme_constant_override("separation", 6)
		_pages_container.add_child(rel_row)

		_add_mini_spin(rel_row, "MTBF (s)", mtbf_val, func(v):
			doc_store.set_element_property(elem.id, "mtbf", v)
		)
		_add_mini_spin(rel_row, "MTTR (s)", mttr_val, func(v):
			doc_store.set_element_property(elem.id, "mttr", v)
		)
		_add_mini_spin(rel_row, "Fail Rate (1/s)", fail_val, func(v):
			doc_store.set_element_property(elem.id, "failure_rate", v)
		)
	else:
		var note := Label.new()
		note.text = "Equipment operates at 100% uptime with zero unscheduled maintenance breakdowns."
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_font_size_override("font_size", 9)
		note.add_theme_color_override("font_color", MUTED)
		_pages_container.add_child(note)

	_pages_container.add_child(HSeparator.new())

	# Routing Rules Section
	var rules_title := Label.new()
	rules_title.text = "DOWNSTREAM ROUTING CONDITIONS & RULES"
	rules_title.add_theme_font_size_override("font_size", 10)
	rules_title.add_theme_color_override("font_color", MUTED)
	_pages_container.add_child(rules_title)

	var conns: Array = []
	if doc_store != null and doc_store.active_document != null:
		for c in doc_store.active_document.connections:
			if c.source_element == elem.id:
				conns.append(c)

	if conns.is_empty():
		var no_c := Label.new()
		no_c.text = "No outbound flow connections attached to this machine."
		no_c.add_theme_font_size_override("font_size", 9)
		no_c.add_theme_color_override("font_color", MUTED)
		_pages_container.add_child(no_c)
	else:
		for c in conns:
			var c_row := HBoxContainer.new()
			var c_desc := Label.new()
			var cond_text := ""
			if c.condition is Dictionary and not c.condition.is_empty():
				cond_text = " [IF %s %s %s]" % [c.condition.get("metric", ""), c.condition.get("operator", ""), str(c.condition.get("threshold", ""))]
			c_desc.text = "→ %s (%s)%s" % [c.target_element, c.target_port, cond_text]
			c_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			c_desc.add_theme_font_size_override("font_size", 9)
			c_desc.add_theme_color_override("font_color", TEXT)
			c_row.add_child(c_desc)

			var edit_rule_btn := Button.new()
			edit_rule_btn.text = "Edit Rule..."
			edit_rule_btn.add_theme_font_size_override("font_size", 9)
			var cid: String = c.id
			edit_rule_btn.pressed.connect(func():
				open_rule_builder_requested.emit(cid)
			)
			c_row.add_child(edit_rule_btn)
			_pages_container.add_child(c_row)

# ============================================================================
# Helpers
# ============================================================================
func _create_coord_spin(parent: Control, label_text: String, val: float, min_v: float, max_v: float, step_v: float, on_change: Callable) -> SpinBox:
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

func _add_mini_spin(parent: Control, label: String, val: float, on_change: Callable) -> void:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 8)
	l.add_theme_color_override("font_color", MUTED)
	vbox.add_child(l)

	var sp := SpinBox.new()
	sp.min_value = 0.0001
	sp.max_value = 86400.0
	sp.step = 0.1
	sp.value = val
	sp.add_theme_font_size_override("font_size", 8)
	sp.value_changed.connect(on_change)
	vbox.add_child(sp)
	parent.add_child(vbox)

# ============================================================================
# Dragging & Mouse Events
# ============================================================================
func _on_header_gui_input(event: InputEvent) -> void:
	if OSWindowHost.handle_header_drag(self, event):
		accept_event()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_drag_start = mb.position
				accept_event()
			else:
				_dragging = false
				accept_event()

	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var new_pos := position + (mm.position - _drag_start)
		var p_size := _get_bounding_area_size()
		new_pos.x = clamp(new_pos.x, 0.0, max(0.0, p_size.x - size.x))
		new_pos.y = clamp(new_pos.y, 0.0, max(0.0, p_size.y - size.y))
		position = new_pos
		accept_event()

func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey:
		var ik := event as InputEventKey
		if ik.pressed and ik.keycode == KEY_ESCAPE:
			close()
			accept_event()

func _on_document_modified() -> void:
	if visible and not current_elem_id.is_empty():
		call_deferred("refresh")

func _on_selection_changed(sel_id: String, sel_type: String) -> void:
	if visible and sel_type == "element" and not sel_id.is_empty() and sel_id != current_elem_id:
		current_elem_id = sel_id
		call_deferred("refresh")

# ============================================================================
# Tab 4: Hooks
# ============================================================================
const SIMVIZ_RECIPES := [
	{"label": "📚 Insert SimViz Recipe...", "code": ""},
	{"label": "VIP Color & Priority 10 (item)", "code": "if rand_uniform() < 0.35\n    set_priority!(10)\n    set_color!(:red)\n    set_label!(\"VIP\")\nelse\n    set_color!(:green)\nend"},
	{"label": "Route to Shortest Connected Queue (:out_flow)", "code": "best = connected_entity_argmin(:out_flow, e -> queue_length(e))\nif isvalid(best)\n    route_to!(best)\nend"},
	{"label": "Pull Highest-Priority Item Across All Input Queues", "code": "pull_from_port_argmax!(:in_flow, c -> c.priority)"},
	{"label": "Pull from Longest Connected Input Queue", "code": "pull_from_port_longest!(:in_flow)"},
	{"label": "Sequence-Dependent Setup Penalty (+2.5s)", "code": "if last_processed_attr(:family, :A) != get_attr(:family, :A)\n    add_setup_time!(2.5)\nend"},
	{"label": "Throttle Conveyor by Downstream Fill Ratio", "code": "dn = connected_entity(:out_flow, 1)\nif isvalid(dn) && fill_ratio(dn) > 0.7\n    set_speed!(0.5)\nelse\n    set_speed!(2.0)\nend"},
	{"label": "Batch Update Speed of All Conveyors (O(N))", "code": "set_speed!(entities_of_kind(:conveyor), 2.5)"},
	{"label": "Check Container / Subgraph Utilization", "code": "if has_container() && utilization(container_entity()) > 0.8\n    set_color!(item(), :orange)\nend"},
	{"label": "Schedule Periodic Custom Event (:heartbeat)", "code": "schedule_every!(5.0, :heartbeat)"},
	{"label": "Routing: Round-Robin over Open Outputs (on_exit)", "code": "outs = connected_entities(:out_flow)\nn = length(outs)\nlast = attr(self(), :rr_last, 0)\nfor i in 1:n\n    k = mod1(last + i, n)\n    if free_capacity(outs[k]) > 0\n        route_to!(outs[k])\n        set_attr!(self(), :rr_last, k)\n        break\n    end\nend"},
	{"label": "Routing: Shortest Queue among Open Outputs (on_exit)", "code": "open = filter(e -> free_capacity(e) > 0, connected_entities(:out_flow))\nif !isempty(open)\n    route_to_shortest!(open)\nend"},
	{"label": "Routing: Random over Open Outputs (on_exit)", "code": "open = filter(e -> free_capacity(e) > 0, connected_entities(:out_flow))\nif !isempty(open)\n    route_to!(rand_choice(open))\nend"},
	{"label": "Routing: First Open Output, in port order (on_exit)", "code": "for c in connected_entities(:out_flow)\n    if free_capacity(c) > 0\n        route_to!(c)\n        break\n    end\nend"}
]

func _render_hooks_tab(elem: SceneTypes.SceneElement) -> void:
	_hook_editors.clear()
	_hook_enables.clear()
	
	var info_lbl := Label.new()
	info_lbl.text = "EVENT HOOKS (SimViz DSL: self(), item(), set_color!, route_to!, set_speed!, pull_from_port_argmax!...)"
	info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_lbl.add_theme_font_size_override("font_size", 10)
	info_lbl.add_theme_color_override("font_color", MUTED)
	_pages_container.add_child(info_lbl)
	_pages_container.add_child(HSeparator.new())
	
	var hooks_dict = elem.properties.get("hooks", {})
	
	for i in range(HOOK_EVENTS.size()):
		var event_name = HOOK_EVENTS[i]
		var section := VBoxContainer.new()
		section.add_theme_constant_override("separation", 4)
		
		var hdr := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = event_name + ":"
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", 11)
		hdr.add_child(lbl)

		var recipe_opt := OptionButton.new()
		recipe_opt.add_theme_font_size_override("font_size", 9)
		for r_idx in range(SIMVIZ_RECIPES.size()):
			recipe_opt.add_item(SIMVIZ_RECIPES[r_idx]["label"], r_idx)
		hdr.add_child(recipe_opt)
		
		var chk := CheckBox.new()
		chk.text = "Enable"
		var existing_code = hooks_dict.get(event_name, "")
		chk.button_pressed = existing_code.length() > 0
		hdr.add_child(chk)
		_hook_enables.append(chk)
		section.add_child(hdr)
		
		var code_edit := CodeEdit.new()
		code_edit.custom_minimum_size.y = 80
		code_edit.text = existing_code
		code_edit.add_theme_font_size_override("font_size", 10)
		_hook_editors.append(code_edit)
		section.add_child(code_edit)

		var cap_edit := code_edit
		var cap_chk := chk
		var cap_opt := recipe_opt
		recipe_opt.item_selected.connect(func(r_idx: int):
			if r_idx > 0 and r_idx < SIMVIZ_RECIPES.size():
				cap_edit.text = SIMVIZ_RECIPES[r_idx]["code"]
				cap_chk.button_pressed = true
				cap_opt.select(0)
		)
		
		var apply_btn := Button.new()
		apply_btn.text = "Apply Hook"
		apply_btn.add_theme_font_size_override("font_size", 10)
		var capture_idx = i
		apply_btn.pressed.connect(func(): _on_apply_hook(capture_idx))
		section.add_child(apply_btn)
		
		_pages_container.add_child(section)
		_pages_container.add_child(HSeparator.new())
		
	_hook_error_label = Label.new()
	_hook_error_label.add_theme_color_override("font_color", DANGER)
	_hook_error_label.add_theme_font_size_override("font_size", 10)
	_hook_error_label.visible = false
	_pages_container.add_child(_hook_error_label)

func _on_apply_hook(event_idx: int) -> void:
	var event_name: String = HOOK_EVENTS[event_idx]
	var enabled: bool = _hook_enables[event_idx].button_pressed
	var code: String = _hook_editors[event_idx].text if enabled else ""
	var msg := {
		"type": "set_hook",
		"element_id": current_elem_id,
		"event": event_name,
		"code": code
	}
	# Update local state too so it persists
	var elem = doc_store.get_element(current_elem_id)
	if elem != null:
		var hooks_dict = elem.properties.get("hooks", {})
		if not (hooks_dict is Dictionary): hooks_dict = {}
		hooks_dict[event_name] = code
		doc_store.set_element_property(current_elem_id, "hooks", hooks_dict)
		
	hook_apply_requested.emit(msg)
