class_name AuthoringPlotStudio
extends PanelContainer

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const Catalog := preload("res://scripts/authoring_catalog.gd")

signal closed
signal subplot_added(elem_id: String)
signal subplot_removed(elem_id: String, subplot_id: String)

const BG := Color("#0b0f14")
const PANEL := Color("#121820")
const CARD_BG := Color("#0d131a")
const BORDER := Color("#222d3d")
const TEXT := Color("#e6edf3")
const MUTED := Color("#8b949e")
const ACCENT := Color("#58a6ff")
const GREEN := Color("#3fb950")
const AMBER := Color("#d29922")
const RED := Color("#f85149")
const PURPLE := Color("#bc8cff")

const SERIES_COLORS := [
	Color("#58a6ff"), # blue
	Color("#3fb950"), # green
	Color("#d29922"), # amber
	Color("#bc8cff"), # purple
	Color("#f85149"), # red
	Color("#39c5cf"), # cyan
	Color("#e3b341"), # yellow
	Color("#f0883e"), # orange
]

var doc_store: DocumentStore = null
var catalog: Catalog = Catalog.new()
var active_chart_elem_id: String = ""
# time_window_seconds: 0.0 means Fit All / Squeeze (0 -> now). >0 means rolling window.
var time_window_seconds: float = 60.0
var is_frozen: bool = false
var use_implot: bool = true
var _has_implot: bool = false

# Series buffers:
# - Entity metric: "elem_id:metric_name" -> Array of { "t": float, "val": float }
# - Wired signal:  "tgt_id/tgt_port/src_id:src_port" -> Array of { "t": float, "val": float }
var _telemetry_buffers: Dictionary = {}
var _latest_sim_t: float = 0.0

# UI references
var _header_bar: PanelContainer
var _tab_bar: TabBar
var _btn_delete_chart: Button
var _time_option: OptionButton
var _layout_option: OptionButton
var _backend_btn: Button
var _freeze_btn: Button
var _clear_btn: Button
var _add_subplot_btn: Button
var _toggle_signals_btn: Button

# Viewport container & unified plot canvases
var _main_split: HSplitContainer
var _signals_panel: PanelContainer
var _subplots_list_vbox: VBoxContainer
var _viewport_container: PanelContainer
var _simplot_view: Control = null
var _vector_canvas: UnifiedVectorCanvas = null

# Dragging and Resizing window state
var _is_dragging: bool = false
var _drag_start_pos: Vector2 = Vector2.ZERO
var _is_resizing: bool = false
var _resize_start_size: Vector2 = Vector2.ZERO
var _resize_start_mouse: Vector2 = Vector2.ZERO
var _is_maximized: bool = false
var _restored_rect: Rect2 = Rect2(Vector2(60, 60), Vector2(880, 560))

# Multi-window Detach / Dock state
var _is_detached: bool = false
var _os_window: Window = null
var _shell_parent: Node = null
var _btn_detach: Button = null

# Subplot curve picker state
var _open_curve_picker_subplot_id: String = ""

var _ui_initialized: bool = false

func _init(p_store: DocumentStore = null) -> void:
	doc_store = p_store
	_has_implot = ClassDB.class_exists("SimPlotView")
	custom_minimum_size = Vector2(820, 540)
	z_index = 200

func _ready() -> void:
	if _ui_initialized: return
	_ui_initialized = true
	z_index = 200
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	if doc_store != null:
		if not doc_store.document_loaded.is_connected(_refresh_tabs):
			doc_store.document_loaded.connect(_refresh_tabs)
		if not doc_store.document_modified.is_connected(_refresh_tabs):
			doc_store.document_modified.connect(_refresh_tabs)
	_refresh_tabs()

func _build_ui() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = BG
	style.border_color = BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 14
	add_theme_stylebox_override("panel", style)

	var main_vbox := VBoxContainer.new()
	main_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_theme_constant_override("separation", 4)
	add_child(main_vbox)

	# 1. Window Header (Draggable)
	_header_bar = PanelContainer.new()
	_header_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	var h_style := StyleBoxFlat.new()
	h_style.bg_color = PANEL
	h_style.set_border_width_all(0)
	h_style.content_margin_left = 8
	h_style.content_margin_right = 8
	h_style.content_margin_top = 4
	h_style.content_margin_bottom = 4
	_header_bar.add_theme_stylebox_override("panel", h_style)
	_header_bar.gui_input.connect(_on_header_gui_input)

	var h_box := HBoxContainer.new()
	h_box.mouse_filter = Control.MOUSE_FILTER_PASS
	h_box.add_theme_constant_override("separation", 8)
	_header_bar.add_child(h_box)

	var title_lbl := Label.new()
	title_lbl.text = "📊 SimViz Plot Studio"
	title_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	title_lbl.add_theme_font_size_override("font_size", 12)
	title_lbl.add_theme_color_override("font_color", TEXT)
	h_box.add_child(title_lbl)

	var live_pill := Label.new()
	live_pill.text = "● LIVE"
	live_pill.mouse_filter = Control.MOUSE_FILTER_PASS
	live_pill.add_theme_font_size_override("font_size", 9)
	live_pill.add_theme_color_override("font_color", GREEN)
	h_box.add_child(live_pill)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_PASS
	h_box.add_child(spacer)

	_btn_detach = Button.new()
	_btn_detach.text = "🗗 Detach"
	_btn_detach.tooltip_text = "Pop out into an independent OS desktop window (movable across screens)"
	_btn_detach.mouse_filter = Control.MOUSE_FILTER_STOP
	_btn_detach.pressed.connect(_toggle_detached)
	h_box.add_child(_btn_detach)

	var btn_max := Button.new()
	btn_max.text = "⤢"
	btn_max.tooltip_text = "Maximize / Restore Window"
	btn_max.mouse_filter = Control.MOUSE_FILTER_STOP
	btn_max.pressed.connect(_toggle_maximize)
	h_box.add_child(btn_max)

	var btn_min := Button.new()
	btn_min.text = "−"
	btn_min.tooltip_text = "Minimize Studio"
	btn_min.mouse_filter = Control.MOUSE_FILTER_STOP
	btn_min.pressed.connect(func():
		if _is_detached and _os_window != null:
			_os_window.visible = false
		else:
			visible = false
	)
	h_box.add_child(btn_min)

	var btn_close := Button.new()
	btn_close.text = "✕"
	btn_close.tooltip_text = "Close Plot Studio"
	btn_close.mouse_filter = Control.MOUSE_FILTER_STOP
	btn_close.pressed.connect(func():
		if _is_detached and _os_window != null:
			_os_window.hide()
		visible = false
		closed.emit()
	)
	h_box.add_child(btn_close)
	main_vbox.add_child(_header_bar)

	# 2. Tab Bar for Chart Block Entities (with Close '✕' on Tabs and Delete Chart button)
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 6)

	_tab_bar = TabBar.new()
	_tab_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_bar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ACTIVE_ONLY
	_tab_bar.tab_changed.connect(_on_tab_changed)
	_tab_bar.tab_close_pressed.connect(_on_tab_close_pressed)
	tab_row.add_child(_tab_bar)

	var btn_new_chart := Button.new()
	btn_new_chart.text = "+ New Chart"
	btn_new_chart.tooltip_text = "Place a new Chart Station block into the scene"
	btn_new_chart.pressed.connect(_on_new_chart_clicked)
	tab_row.add_child(btn_new_chart)

	_btn_delete_chart = Button.new()
	_btn_delete_chart.text = "🗑 Delete Chart"
	_btn_delete_chart.tooltip_text = "Remove the active Chart Station entity from the scene"
	_btn_delete_chart.pressed.connect(_on_delete_active_chart_clicked)
	tab_row.add_child(_btn_delete_chart)

	main_vbox.add_child(tab_row)

	# 3. Toolbar (Time Window, Layout, Backend, Freeze, Clear, Export, Subplots)
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)

	_toggle_signals_btn = Button.new()
	_toggle_signals_btn.text = "☰ Signals & Curves"
	_toggle_signals_btn.tooltip_text = "Show/Hide the Subplots & Signals configuration sidebar"
	_toggle_signals_btn.pressed.connect(func():
		_signals_panel.visible = not _signals_panel.visible
		_toggle_signals_btn.modulate = ACCENT if _signals_panel.visible else Color.WHITE
	)
	toolbar.add_child(_toggle_signals_btn)

	var tw_lbl := Label.new()
	tw_lbl.text = "X-Axis:"
	tw_lbl.add_theme_font_size_override("font_size", 10)
	tw_lbl.add_theme_color_override("font_color", MUTED)
	toolbar.add_child(tw_lbl)

	_time_option = OptionButton.new()
	_time_option.add_item("Fit All (0 → Now) [Squeeze]", 0)
	_time_option.add_item("15s (Rolling)", 15)
	_time_option.add_item("30s (Rolling)", 30)
	_time_option.add_item("60s (Rolling)", 60)
	_time_option.add_item("120s (Rolling)", 120)
	_time_option.add_item("300s (Rolling)", 300)
	_time_option.select(3) # Default 60s
	_time_option.item_selected.connect(_on_time_option_selected)
	toolbar.add_child(_time_option)

	var lay_lbl := Label.new()
	lay_lbl.text = "Layout:"
	lay_lbl.add_theme_font_size_override("font_size", 10)
	lay_lbl.add_theme_color_override("font_color", MUTED)
	toolbar.add_child(lay_lbl)

	_layout_option = OptionButton.new()
	_layout_option.add_item("⊞ 2x2 Grid", 0)
	_layout_option.add_item("☰ Vertical Stack", 1)
	_layout_option.add_item("◫ Split Left + 2 Right + Bottom", 2)
	_layout_option.add_item("⊞ 1 Subplot (1x1)", 3)
	_layout_option.add_item("⊞ 2 Subplots (1x2 Cols)", 4)
	_layout_option.add_item("☰ 2 Subplots (2x1 Rows)", 5)
	_layout_option.add_item("🛠 Auto Grid", 6)
	_layout_option.select(0)
	_layout_option.item_selected.connect(_on_layout_template_selected)
	toolbar.add_child(_layout_option)

	_backend_btn = Button.new()
	_backend_btn.text = "GPU (ImPlot)" if (_has_implot and use_implot) else "2D Canvas"
	_backend_btn.tooltip_text = "Toggle hardware accelerated ImPlot rendering vs 2D vector canvas"
	_backend_btn.pressed.connect(_toggle_backend)
	toolbar.add_child(_backend_btn)

	_freeze_btn = Button.new()
	_freeze_btn.text = "⏸ Freeze"
	_freeze_btn.pressed.connect(_toggle_freeze)
	toolbar.add_child(_freeze_btn)

	_clear_btn = Button.new()
	_clear_btn.text = "⟲ Clear"
	_clear_btn.pressed.connect(clear_all)
	toolbar.add_child(_clear_btn)

	var btn_csv := Button.new()
	btn_csv.text = "💾 Export CSV"
	btn_csv.pressed.connect(_export_csv)
	toolbar.add_child(btn_csv)

	var tb_spacer := Control.new()
	tb_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(tb_spacer)

	_add_subplot_btn = Button.new()
	_add_subplot_btn.text = "+ Add Subplot"
	_add_subplot_btn.tooltip_text = "Add another subplot and input port to this chart station"
	_add_subplot_btn.pressed.connect(_on_add_subplot_clicked)
	toolbar.add_child(_add_subplot_btn)

	main_vbox.add_child(toolbar)
	main_vbox.add_child(HSeparator.new())

	# 4. Main Workspace Splitter (Left: Subplots & Signals Inspector | Right: Single Unified Plot Canvas)
	_main_split = HSplitContainer.new()
	_main_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_split.split_offset = 290
	main_vbox.add_child(_main_split)

	# Left Sidebar: Subplots & Signals Manager
	_signals_panel = PanelContainer.new()
	_signals_panel.custom_minimum_size.x = 260
	var sp_style := StyleBoxFlat.new()
	sp_style.bg_color = PANEL
	sp_style.border_color = BORDER
	sp_style.set_border_width_all(1)
	sp_style.set_corner_radius_all(4)
	_signals_panel.add_theme_stylebox_override("panel", sp_style)
	_main_split.add_child(_signals_panel)

	var sp_vbox := VBoxContainer.new()
	sp_vbox.add_theme_constant_override("separation", 6)
	_signals_panel.add_child(sp_vbox)

	var sp_header := HBoxContainer.new()
	sp_header.add_theme_constant_override("separation", 4)
	sp_vbox.add_child(sp_header)

	var sp_head_lbl := Label.new()
	sp_head_lbl.text = "SUBPLOTS & SIGNALS"
	sp_head_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp_head_lbl.add_theme_font_size_override("font_size", 10)
	sp_head_lbl.add_theme_color_override("font_color", MUTED)
	sp_header.add_child(sp_head_lbl)

	var side_add_btn := Button.new()
	side_add_btn.text = "+ Subplot"
	side_add_btn.tooltip_text = "Add a new subplot to this chart station"
	side_add_btn.pressed.connect(_on_add_subplot_clicked)
	sp_header.add_child(side_add_btn)

	var sp_scroll := ScrollContainer.new()
	sp_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sp_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sp_vbox.add_child(sp_scroll)

	_subplots_list_vbox = VBoxContainer.new()
	_subplots_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_subplots_list_vbox.add_theme_constant_override("separation", 8)
	sp_scroll.add_child(_subplots_list_vbox)

	# Right Area: Viewport Area (Hosts ONE Unified Plot Surface - No Hacky Multiple Cards)
	_viewport_container = PanelContainer.new()
	_viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viewport_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_container.custom_minimum_size = Vector2(480, 320)
	var vp_style := StyleBoxFlat.new()
	vp_style.bg_color = CARD_BG
	vp_style.border_color = BORDER
	vp_style.set_border_width_all(1)
	vp_style.set_corner_radius_all(4)
	_viewport_container.add_theme_stylebox_override("panel", vp_style)
	_main_split.add_child(_viewport_container)

	# Single Unified ImPlot View
	if _has_implot:
		_simplot_view = ClassDB.instantiate("SimPlotView")
		_simplot_view.name = "UnifiedSimPlotView"
		_simplot_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_simplot_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_simplot_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_viewport_container.add_child(_simplot_view)

	# Single Unified Vector Canvas Fallback
	_vector_canvas = UnifiedVectorCanvas.new(self)
	_vector_canvas.name = "UnifiedVectorCanvas"
	_vector_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vector_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vector_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewport_container.add_child(_vector_canvas)

	_update_backend_visibility()

	# 5. Bottom Status Bar with Interactive Resize Handle
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	main_vbox.add_child(footer)

	var status_lbl := Label.new()
	status_lbl.text = "SimViz Plot Studio · Unified ImPlot Subplots Canvas"
	status_lbl.add_theme_font_size_override("font_size", 9)
	status_lbl.add_theme_color_override("font_color", MUTED)
	footer.add_child(status_lbl)

	var f_spacer := Control.new()
	f_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	f_spacer.mouse_filter = Control.MOUSE_FILTER_PASS
	footer.add_child(f_spacer)

	var resize_grip := Label.new()
	resize_grip.text = "⤡"
	resize_grip.tooltip_text = "Drag to resize window"
	resize_grip.add_theme_font_size_override("font_size", 14)
	resize_grip.add_theme_color_override("font_color", ACCENT)
	resize_grip.mouse_filter = Control.MOUSE_FILTER_STOP
	resize_grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	resize_grip.gui_input.connect(_on_resize_gui_input)
	footer.add_child(resize_grip)

func _update_backend_visibility() -> void:
	var use_gpu: bool = _has_implot and use_implot
	if _simplot_view != null:
		_simplot_view.visible = use_gpu
	if _vector_canvas != null:
		_vector_canvas.visible = not use_gpu

func open_for_element(elem_id: String) -> void:
	if not _ui_initialized:
		_ready()
	if _is_detached and _os_window != null:
		_os_window.show()
	visible = true
	move_to_front()
	_refresh_tabs()
	if _tab_bar == null: return
	for i in range(_tab_bar.tab_count):
		if _tab_bar.get_tab_metadata(i) == elem_id:
			_tab_bar.current_tab = i
			_on_tab_changed(i)
			return

func toggle_visibility() -> void:
	if not _ui_initialized:
		_ready()
	if _is_detached and _os_window != null:
		_os_window.visible = not _os_window.visible
		visible = _os_window.visible
	else:
		visible = not visible
	if visible:
		move_to_front()
		_refresh_tabs()

func _refresh_tabs(_doc = null) -> void:
	if _tab_bar == null or doc_store == null or doc_store.active_document == null:
		return
	_tab_bar.clear_tabs()
	var chart_elems := _get_all_chart_elements()
	for i in range(chart_elems.size()):
		var el: SceneTypes.SceneElement = chart_elems[i]
		var d_title: String = str(el.properties.get("title", el.name if not el.name.is_empty() else el.id))
		_tab_bar.add_tab("📊 " + d_title)
		_tab_bar.set_tab_metadata(i, el.id)

	if chart_elems.is_empty():
		_tab_bar.add_tab("(No Chart Blocks)")
		active_chart_elem_id = ""
		_btn_delete_chart.disabled = true
		_rebuild_signals_dock()
		_redraw_active_subplots()
	else:
		_btn_delete_chart.disabled = false
		if active_chart_elem_id.is_empty() or not _element_exists(active_chart_elem_id):
			active_chart_elem_id = chart_elems[0].id
			_tab_bar.current_tab = 0
		_rebuild_signals_dock()
		_redraw_active_subplots()

func _element_exists(id_val: String) -> bool:
	if doc_store == null or doc_store.active_document == null: return false
	for el in doc_store.active_document.elements:
		if el.id == id_val: return true
	return false

func _get_all_chart_elements() -> Array:
	var res: Array = []
	if doc_store == null or doc_store.active_document == null: return res
	for el in doc_store.active_document.elements:
		if el.kind in ["chart_station", "scope_2d", "digital_meter", "histogram_sink", "state_space_3d", "xy_scatter"]:
			res.append(el)
	return res

func _on_tab_changed(tab_idx: int) -> void:
	if tab_idx < 0 or tab_idx >= _tab_bar.tab_count: return
	var meta = _tab_bar.get_tab_metadata(tab_idx)
	if meta is String and not meta.is_empty():
		active_chart_elem_id = meta
		_open_curve_picker_subplot_id = ""
		_rebuild_signals_dock()
		_redraw_active_subplots()

func _on_tab_close_pressed(tab_idx: int) -> void:
	if tab_idx < 0 or tab_idx >= _tab_bar.tab_count: return
	var meta = _tab_bar.get_tab_metadata(tab_idx)
	if meta is String and not meta.is_empty():
		_delete_chart_station(meta)

func _on_delete_active_chart_clicked() -> void:
	if active_chart_elem_id.is_empty(): return
	_delete_chart_station(active_chart_elem_id)

func _delete_chart_station(elem_id: String) -> void:
	if doc_store == null or elem_id.is_empty(): return
	doc_store.remove_element(elem_id)
	doc_store.document_modified.emit()
	if active_chart_elem_id == elem_id:
		active_chart_elem_id = ""
	_refresh_tabs()

func _on_new_chart_clicked() -> void:
	if doc_store == null: return
	var new_id := "chart_%d" % (Time.get_ticks_msec() % 10000)
	var elem = catalog.create_element_instance("chart_station", new_id, Vector2(10.0, 10.0))
	doc_store.add_element(elem)
	doc_store.document_modified.emit()
	open_for_element(new_id)

func _on_add_subplot_clicked() -> void:
	if active_chart_elem_id.is_empty() or doc_store == null: return
	var elem = doc_store.get_element(active_chart_elem_id)
	if elem == null: return

	var subplots: Array = elem.properties.get("subplots", [])
	var new_idx := subplots.size() + 1
	var new_sp_id := "sp_%d" % new_idx
	var new_port_id := "P%d" % new_idx

	var sp_dict := {
		"id": new_sp_id,
		"port_id": new_port_id,
		"title": "Subplot %d" % new_idx,
		"type": "time_series",
		"y_label": "Value",
		"autoscale": true,
		"y_min": 0.0,
		"y_max": 100.0,
		"grid": {"col": (new_idx - 1) % 2, "row": int((new_idx - 1) / 2), "col_span": 1, "row_span": 1},
		"mode": "overlay",
		"signals": []
	}
	subplots.append(sp_dict)
	elem.properties["subplots"] = subplots

	# Dynamically add input port on element
	var has_p := false
	for p in elem.input_ports:
		if p.id == new_port_id:
			has_p = true
			break
	if not has_p:
		var port := SceneTypes.ScenePort.new()
		port.id = new_port_id
		port.kind = "signal"
		port.direction = "input"
		port.cardinality = "many"
		port.name = "Port %d (Subplot %d)" % [new_idx, new_idx]
		elem.input_ports.append(port)

	doc_store.document_modified.emit()
	subplot_added.emit(elem.id)
	_rebuild_signals_dock()
	_redraw_active_subplots()

func _remove_subplot(elem: SceneTypes.SceneElement, sp_id: String) -> void:
	var subplots: Array = elem.properties.get("subplots", [])
	var filtered: Array = []
	var port_to_remove: String = ""
	for sp in subplots:
		if sp.get("id", "") == sp_id:
			port_to_remove = str(sp.get("port_id", ""))
		else:
			filtered.append(sp)
	elem.properties["subplots"] = filtered

	if not port_to_remove.is_empty():
		_remove_port_from_elem(elem, port_to_remove)

	if doc_store != null:
		doc_store.document_modified.emit()
	subplot_removed.emit(elem.id, sp_id)
	_rebuild_signals_dock()
	_redraw_active_subplots()

func _remove_port_from_elem(elem: SceneTypes.SceneElement, port_id: String) -> void:
	for i in range(elem.input_ports.size() - 1, -1, -1):
		if elem.input_ports[i].id == port_id:
			elem.input_ports.remove_at(i)
			break

## Rebuilds the Subplots & Signals Inspector Sidebar
func _rebuild_signals_dock() -> void:
	if _subplots_list_vbox == null: return
	for c in _subplots_list_vbox.get_children():
		c.queue_free()

	if active_chart_elem_id.is_empty() or doc_store == null:
		var empty_lbl := Label.new()
		empty_lbl.text = "No active chart selected."
		empty_lbl.add_theme_font_size_override("font_size", 10)
		empty_lbl.add_theme_color_override("font_color", MUTED)
		_subplots_list_vbox.add_child(empty_lbl)
		return

	var elem = doc_store.get_element(active_chart_elem_id)
	if elem == null: return

	var subplots: Array = elem.properties.get("subplots", [])
	if subplots.is_empty():
		_ensure_default_subplots(elem)
		subplots = elem.properties.get("subplots", [])

	for i in range(subplots.size()):
		var sp: Dictionary = subplots[i]
		var card := _create_subplot_sidebar_card(elem, sp, i)
		_subplots_list_vbox.add_child(card)

func _create_subplot_sidebar_card(elem: SceneTypes.SceneElement, sp: Dictionary, idx: int) -> Control:
	var sp_id = str(sp.get("id", "sp_%d" % (idx + 1)))
	var sp_port = str(sp.get("port_id", "P%d" % (idx + 1)))

	var card := PanelContainer.new()
	var c_style := StyleBoxFlat.new()
	c_style.bg_color = CARD_BG
	c_style.border_color = BORDER
	c_style.set_border_width_all(1)
	c_style.set_corner_radius_all(4)
	c_style.content_margin_left = 6
	c_style.content_margin_right = 6
	c_style.content_margin_top = 4
	c_style.content_margin_bottom = 4
	card.add_theme_stylebox_override("panel", c_style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	card.add_child(vbox)

	# 1. Header: [P1] + Title Edit + Delete [🗑]
	var h_row := HBoxContainer.new()
	h_row.add_theme_constant_override("separation", 4)
	vbox.add_child(h_row)

	var p_badge := Label.new()
	p_badge.text = "[%s]" % sp_port
	p_badge.add_theme_font_size_override("font_size", 9)
	p_badge.add_theme_color_override("font_color", ACCENT)
	h_row.add_child(p_badge)

	var title_edit := LineEdit.new()
	title_edit.text = str(sp.get("title", "Subplot %d" % (idx + 1)))
	title_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_edit.add_theme_font_size_override("font_size", 10)
	title_edit.text_changed.connect(func(new_text):
		sp["title"] = new_text
		doc_store.document_modified.emit()
		_redraw_active_subplots()
	)
	h_row.add_child(title_edit)

	var del_sp_btn := Button.new()
	del_sp_btn.text = "🗑"
	del_sp_btn.tooltip_text = "Delete this Subplot"
	del_sp_btn.flat = true
	del_sp_btn.add_theme_color_override("font_color", RED)
	del_sp_btn.pressed.connect(func():
		_remove_subplot(elem, sp_id)
	)
	h_row.add_child(del_sp_btn)

	# 2. Controls: Plot Type + Y-Unit + Autoscale
	var ctrl_row := HBoxContainer.new()
	ctrl_row.add_theme_constant_override("separation", 4)
	vbox.add_child(ctrl_row)

	var type_opt := OptionButton.new()
	type_opt.add_item("📈 Time Series", 0)
	type_opt.add_item("🔢 Gauge", 1)
	type_opt.add_item("📊 Histogram", 2)
	type_opt.add_item("⤢ Scatter", 3)
	var cur_type = str(sp.get("type", "time_series"))
	if cur_type == "digital_gauge": type_opt.select(1)
	elif cur_type == "histogram": type_opt.select(2)
	elif cur_type == "xy_scatter": type_opt.select(3)
	else: type_opt.select(0)
	type_opt.item_selected.connect(func(opt_idx):
		match opt_idx:
			0: sp["type"] = "time_series"
			1: sp["type"] = "digital_gauge"
			2: sp["type"] = "histogram"
			3: sp["type"] = "xy_scatter"
		doc_store.document_modified.emit()
		_rebuild_signals_dock()
		_redraw_active_subplots()
	)
	ctrl_row.add_child(type_opt)

	var y_edit := LineEdit.new()
	y_edit.text = str(sp.get("y_label", "Value"))
	y_edit.placeholder_text = "Unit"
	y_edit.custom_minimum_size.x = 44
	y_edit.add_theme_font_size_override("font_size", 9)
	y_edit.text_changed.connect(func(new_u):
		sp["y_label"] = new_u
		doc_store.document_modified.emit()
		_redraw_active_subplots()
	)
	ctrl_row.add_child(y_edit)

	var auto_chk := CheckBox.new()
	auto_chk.text = "Auto"
	auto_chk.button_pressed = bool(sp.get("autoscale", true))
	auto_chk.add_theme_font_size_override("font_size", 9)
	auto_chk.toggled.connect(func(pressed):
		sp["autoscale"] = pressed
		doc_store.document_modified.emit()
		_redraw_active_subplots()
	)
	ctrl_row.add_child(auto_chk)

	# 3. Signals / Curves List
	var curves_lbl := Label.new()
	curves_lbl.text = "Plotted Variables / Curves:"
	curves_lbl.add_theme_font_size_override("font_size", 9)
	curves_lbl.add_theme_color_override("font_color", MUTED)
	vbox.add_child(curves_lbl)

	var curves: Array = sp.get("signals", [])
	for c_i in range(curves.size()):
		var curve = curves[c_i]
		var c_row := HBoxContainer.new()
		c_row.add_theme_constant_override("separation", 4)
		vbox.add_child(c_row)

		var dot := Label.new()
		dot.text = "●"
		var col_str = str(curve.get("color", "#58a6ff"))
		dot.add_theme_color_override("font_color", Color(col_str))
		c_row.add_child(dot)

		var c_lbl := Label.new()
		var e_id = str(curve.get("entity_id", ""))
		var y_m = str(curve.get("y_metric", ""))
		var x_m = str(curve.get("x_metric", "__time__"))
		if x_m != "__time__":
			c_lbl.text = "%s.%s (vs %s)" % [e_id, y_m, x_m]
		else:
			c_lbl.text = "%s → %s" % [e_id, y_m]
		c_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c_lbl.add_theme_font_size_override("font_size", 9)
		c_lbl.add_theme_color_override("font_color", TEXT)
		c_row.add_child(c_lbl)

		var del_curve_btn := Button.new()
		del_curve_btn.text = "✕"
		del_curve_btn.flat = true
		del_curve_btn.add_theme_font_size_override("font_size", 8)
		del_curve_btn.pressed.connect(func():
			curves.remove_at(c_i)
			sp["signals"] = curves
			doc_store.document_modified.emit()
			_rebuild_signals_dock()
			_redraw_active_subplots()
		)
		c_row.add_child(del_curve_btn)

	# If no explicit curves, check if wired
	if curves.is_empty():
		var wired_row := _get_wired_row_for_port(elem.id, sp_port)
		if wired_row != null:
			vbox.add_child(wired_row)
		else:
			var no_c_lbl := Label.new()
			no_c_lbl.text = "(No variables selected · Click + Add below)"
			no_c_lbl.add_theme_font_size_override("font_size", 8)
			no_c_lbl.add_theme_color_override("font_color", MUTED)
			vbox.add_child(no_c_lbl)

	# 4. Add Curve Button / Expanded Picker
	if _open_curve_picker_subplot_id == sp_id:
		var picker := _build_curve_picker_widget(elem, sp)
		vbox.add_child(picker)
	else:
		var add_c_btn := Button.new()
		add_c_btn.text = "+ Add Variable / Curve"
		add_c_btn.add_theme_font_size_override("font_size", 9)
		add_c_btn.pressed.connect(func():
			_open_curve_picker_subplot_id = sp_id
			_rebuild_signals_dock()
		)
		vbox.add_child(add_c_btn)

	return card

func _get_wired_row_for_port(elem_id: String, port_id: String) -> Control:
	if doc_store == null or doc_store.active_document == null: return null
	for conn in doc_store.active_document.connections:
		if conn.target_element == elem_id and conn.target_port == port_id:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			var w_dot := Label.new(); w_dot.text = "●"; w_dot.add_theme_color_override("font_color", ACCENT)
			var w_lbl := Label.new()
			w_lbl.text = "[Wired] %s → %s" % [conn.source_element, conn.source_port]
			w_lbl.add_theme_font_size_override("font_size", 9)
			w_lbl.add_theme_color_override("font_color", MUTED)
			row.add_child(w_dot)
			row.add_child(w_lbl)
			return row
	return null

## Inline Curve Picker Widget allowing user to expose ANY variable for ANY entity
func _build_curve_picker_widget(elem: SceneTypes.SceneElement, sp: Dictionary) -> Control:
	var sp_port = str(sp.get("port_id", "P1"))
	var container := PanelContainer.new()
	var p_style := StyleBoxFlat.new()
	p_style.bg_color = PANEL
	p_style.border_color = ACCENT
	p_style.set_border_width_all(1)
	p_style.set_corner_radius_all(3)
	container.add_theme_stylebox_override("panel", p_style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	container.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = "Expose Entity Variable:"
	title_lbl.add_theme_font_size_override("font_size", 9)
	title_lbl.add_theme_color_override("font_color", ACCENT)
	vbox.add_child(title_lbl)

	# 1. Check if there are wired entities connected to this port
	var wired_entities: Array = []
	if doc_store != null and doc_store.active_document != null:
		for conn in doc_store.active_document.connections:
			if conn.target_element == elem.id and conn.target_port == sp_port:
				var src_el = doc_store.get_element(conn.source_element)
				if src_el != null and not wired_entities.has(src_el):
					wired_entities.append(src_el)

	var filter_chk: CheckBox = null
	if not wired_entities.is_empty():
		filter_chk = CheckBox.new()
		filter_chk.text = "Filter to wired inputs [%s]" % sp_port
		filter_chk.button_pressed = true
		filter_chk.add_theme_font_size_override("font_size", 8)
		vbox.add_child(filter_chk)

	# Entity Dropdown
	var ent_row := HBoxContainer.new()
	var ent_lbl := Label.new(); ent_lbl.text = "Entity:"; ent_lbl.add_theme_font_size_override("font_size", 9)
	var ent_opt := OptionButton.new()
	ent_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ent_opt.add_theme_font_size_override("font_size", 9)
	ent_row.add_child(ent_lbl)
	ent_row.add_child(ent_opt)
	vbox.add_child(ent_row)

	# X Variable Dropdown (Always available)
	var x_row := HBoxContainer.new()
	var x_lbl := Label.new(); x_lbl.text = "X-Var:"; x_lbl.add_theme_font_size_override("font_size", 9)
	var x_opt := OptionButton.new()
	x_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	x_opt.add_theme_font_size_override("font_size", 9)
	x_row.add_child(x_lbl)
	x_row.add_child(x_opt)
	vbox.add_child(x_row)

	# Y Variable Dropdown
	var y_row := HBoxContainer.new()
	var y_lbl := Label.new(); y_lbl.text = "Y-Var:"; y_lbl.add_theme_font_size_override("font_size", 9)
	var y_opt := OptionButton.new()
	y_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	y_opt.add_theme_font_size_override("font_size", 9)
	y_row.add_child(y_lbl)
	y_row.add_child(y_opt)
	vbox.add_child(y_row)

	var current_entities: Array = []

	var populate_variables = func(sel_idx: int):
		y_opt.clear()
		x_opt.clear()
		x_opt.add_item("⏱ Sim Time (s)", 0)
		if sel_idx < 0 or sel_idx >= current_entities.size(): return
		var sel_el: SceneTypes.SceneElement = current_entities[sel_idx]
		var metrics := _get_metrics_for_entity(sel_el)
		for j in range(metrics.size()):
			var m = metrics[j]
			y_opt.add_item(str(m), j)
			x_opt.add_item(str(m), j + 1)
		if y_opt.item_count > 0:
			y_opt.select(0)
		x_opt.select(0)

	var populate_entities = func():
		ent_opt.clear()
		current_entities.clear()
		if filter_chk != null and filter_chk.button_pressed:
			current_entities.append_array(wired_entities)
		else:
			current_entities.append_array(_get_plottable_entities())

		for i in range(current_entities.size()):
			var el: SceneTypes.SceneElement = current_entities[i]
			var label_str: String = "%s (%s)" % [el.id, el.kind.capitalize()]
			ent_opt.add_item(label_str, i)

		if not current_entities.is_empty():
			ent_opt.select(0)
			populate_variables.call(0)
		else:
			y_opt.clear()
			x_opt.clear()
			x_opt.add_item("⏱ Sim Time (s)", 0)

	ent_opt.item_selected.connect(populate_variables)
	if filter_chk != null:
		filter_chk.toggled.connect(func(_p): populate_entities.call())

	populate_entities.call()

	# Action Buttons: [✓ Add Curve] [✕ Cancel]
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)

	var add_btn := Button.new()
	add_btn.text = "✓ Add Curve"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.add_theme_font_size_override("font_size", 9)
	add_btn.pressed.connect(func():
		var sel_ent_idx = ent_opt.selected
		if sel_ent_idx < 0 or sel_ent_idx >= current_entities.size(): return
		var sel_el: SceneTypes.SceneElement = current_entities[sel_ent_idx]
		var y_metric_str = y_opt.get_item_text(y_opt.selected) if y_opt.item_count > 0 else "value"
		var x_metric_str = "__time__"
		if x_opt.selected > 0:
			x_metric_str = x_opt.get_item_text(x_opt.selected)

		var curves: Array = sp.get("signals", [])
		var color_idx = curves.size() % SERIES_COLORS.size()
		var hex_color: String = "#" + SERIES_COLORS[color_idx].to_html(false)

		var curve_def := {
			"entity_id": sel_el.id,
			"y_metric": y_metric_str,
			"x_metric": x_metric_str,
			"label": "%s.%s" % [sel_el.id, y_metric_str] if x_metric_str == "__time__" else ("%s.%s vs %s" % [sel_el.id, y_metric_str, x_metric_str]),
			"color": hex_color
		}
		curves.append(curve_def)
		sp["signals"] = curves

		if doc_store != null:
			doc_store.document_modified.emit()
		_open_curve_picker_subplot_id = ""
		_rebuild_signals_dock()
		_redraw_active_subplots()
	)
	btn_row.add_child(add_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "✕"
	cancel_btn.add_theme_font_size_override("font_size", 9)
	cancel_btn.pressed.connect(func():
		_open_curve_picker_subplot_id = ""
		_rebuild_signals_dock()
	)
	btn_row.add_child(cancel_btn)

	vbox.add_child(btn_row)
	return container

func _get_plottable_entities() -> Array:
	var list: Array = []
	var seen_ids: Dictionary = {}
	if doc_store != null and doc_store.active_document != null:
		for el in doc_store.active_document.elements:
			if el.kind in ["chart_station", "scope_2d", "digital_meter", "histogram_sink"]: continue
			seen_ids[el.id] = true
			list.append(el)
	# Also include any live telemetry entities not explicitly in document
	for k in _telemetry_buffers.keys():
		if ":" in k and not "/" in k:
			var eid = k.split(":")[0]
			if not seen_ids.has(eid):
				seen_ids[eid] = true
				var virtual_el = SceneTypes.SceneElement.new()
				virtual_el.id = eid
				virtual_el.kind = "agent"
				virtual_el.name = eid
				list.append(virtual_el)
	return list

func _get_metrics_for_entity(el: SceneTypes.SceneElement) -> Array:
	var metrics: Array = []
	var seen: Dictionary = {}

	# 1. Any metric ports from catalog
	var cat_entry = catalog.get_entry(el.kind) if catalog != null else null
	if cat_entry != null:
		for p in cat_entry.default_metric_ports:
			var pid: String = str(p.get("id", ""))
			if not pid.is_empty() and not seen.has(pid):
				seen[pid] = true
				metrics.append(pid)

	# 2. Known standard metrics by entity kind
	var known_map := {
		"queue": ["queue_length", "length", "occupancy_pct", "wait_mean_wq", "total_entered", "total_departed"],
		"server": ["utilization", "utilization_pct", "busy_servers", "service_mean", "total_served"],
		"conveyor": ["in_transit", "items_in_transit", "occupancy", "speed", "transit_delay", "total_transited"],
		"source": ["rate_per_sec", "total_arrivals"],
		"sink": ["throughput_per_sec", "total_departures"]
	}
	for m in known_map.get(el.kind, []):
		if not seen.has(m):
			seen[m] = true
			metrics.append(m)

	# 3. Any live telemetry keys buffered for this entity
	for k in _telemetry_buffers.keys():
		if k.begins_with(el.id + ":"):
			var m = k.substr(el.id.length() + 1)
			if not seen.has(m):
				seen[m] = true
				metrics.append(m)

	# 4. Any numeric properties in el.properties
	if el.properties != null:
		for prop_k in el.properties.keys():
			if prop_k in ["title", "name", "id", "kind", "position", "size", "color", "icon", "subplots", "grid_rows", "grid_columns"]: continue
			var val = el.properties[prop_k]
			if (val is int or val is float) and not seen.has(prop_k):
				seen[prop_k] = true
				metrics.append(prop_k)

	if metrics.is_empty():
		metrics = ["value", "count", "state"]

	return metrics

func _on_time_option_selected(idx: int) -> void:
	if _time_option != null and idx >= 0 and idx < _time_option.item_count:
		time_window_seconds = float(_time_option.get_item_id(idx))
	else:
		match idx:
			0: time_window_seconds = 0.0 # Fit All / Squeeze
			1: time_window_seconds = 15.0
			2: time_window_seconds = 30.0
			3: time_window_seconds = 60.0
			4: time_window_seconds = 120.0
			5: time_window_seconds = 300.0
			_: time_window_seconds = 60.0
	_redraw_active_subplots()

func _on_layout_template_selected(idx: int) -> void:
	if active_chart_elem_id.is_empty() or doc_store == null: return
	var elem = doc_store.get_element(active_chart_elem_id)
	if elem == null: return

	match idx:
		0: # ⊞ 2x2 Grid
			elem.properties["grid_rows"] = 2
			elem.properties["grid_columns"] = 2
		1: # ☰ Vertical Stack
			var sp_count: int = elem.properties.get("subplots", []).size()
			elem.properties["grid_rows"] = max(1, sp_count)
			elem.properties["grid_columns"] = 1
		2: # ◫ Split Left + 2 Right + Bottom (User's Asymmetric Layout)
			elem.properties["grid_columns"] = 2
			elem.properties["grid_rows"] = 3
			var subplots: Array = elem.properties.get("subplots", [])
			if subplots.size() >= 1:
				subplots[0]["grid"] = {"col": 0, "row": 0, "col_span": 1, "row_span": 2}
			if subplots.size() >= 2:
				subplots[1]["grid"] = {"col": 1, "row": 0, "col_span": 1, "row_span": 1}
			if subplots.size() >= 3:
				subplots[2]["grid"] = {"col": 1, "row": 1, "col_span": 1, "row_span": 1}
			if subplots.size() >= 4:
				subplots[3]["grid"] = {"col": 0, "row": 2, "col_span": 2, "row_span": 1}
		3: # 1x1
			elem.properties["grid_rows"] = 1
			elem.properties["grid_columns"] = 1
		4: # 1x2 (1 Row, 2 Cols)
			elem.properties["grid_rows"] = 1
			elem.properties["grid_columns"] = 2
		5: # 2x1 (2 Rows, 1 Col)
			elem.properties["grid_rows"] = 2
			elem.properties["grid_columns"] = 1
		6: # Auto
			elem.properties["grid_rows"] = 0
			elem.properties["grid_columns"] = 0

	doc_store.document_modified.emit()
	_redraw_active_subplots()

func _toggle_backend() -> void:
	if not _has_implot: return
	use_implot = !use_implot
	_backend_btn.text = "GPU (ImPlot)" if use_implot else "2D Canvas"
	_update_backend_visibility()
	_redraw_active_subplots()

func _toggle_freeze() -> void:
	is_frozen = !is_frozen
	_freeze_btn.text = "▶ Resume" if is_frozen else "⏸ Freeze"
	_freeze_btn.modulate = AMBER if is_frozen else Color.WHITE

func clear_all() -> void:
	_telemetry_buffers.clear()
	_latest_sim_t = 0.0
	if _simplot_view != null:
		_simplot_view.clear_all()
	_redraw_active_subplots()

func _export_csv() -> void:
	var f := FileAccess.open("user://simplot_export_%d.csv" % Time.get_unix_time_from_system(), FileAccess.WRITE)
	if f == null: return
	f.store_line("timestamp,series_key,value")
	for k in _telemetry_buffers.keys():
		var arr: Array = _telemetry_buffers[k]
		for pt in arr:
			f.store_line("%f,%s,%f" % [float(pt.get("t", 0.0)), k, float(pt.get("val", 0.0))])
	f.close()

## Telemetry Ingestion from Simulation State
func feed_telemetry(t: float, elements_by_id: Dictionary, _global_kpis: Dictionary) -> void:
	if is_frozen: return
	# Automatic detection of simulation reset
	if t < _latest_sim_t - 0.5:
		clear_all()
	_latest_sim_t = t

	if doc_store == null or doc_store.active_document == null: return
	var doc = doc_store.active_document

	# 1. Store entity-specific telemetry for ANY entity and ANY metric
	for e_id in elements_by_id.keys():
		var src_elem = elements_by_id[e_id]
		var src_metrics: Dictionary = src_elem.get("metrics", src_elem.get("custom_metrics", {}))
		for m_name in src_metrics.keys():
			var val: float = float(src_metrics[m_name])
			var key := "%s:%s" % [e_id, m_name]
			_feed_buffer_point(key, t, val)

	# 2. Also map wire connections directly into subplots
	for conn in doc.connections:
		var src_id: String = str(conn.source_element)
		var src_port: String = str(conn.source_port)
		var tgt_id: String = str(conn.target_element)
		var tgt_port: String = str(conn.target_port)

		if elements_by_id.has(src_id):
			var src_elem = elements_by_id[src_id]
			var src_metrics: Dictionary = src_elem.get("metrics", src_elem.get("custom_metrics", {}))
			var val: float = _resolve_metric_value(src_port, src_metrics)
			var key := "%s/%s/%s:%s" % [tgt_id, tgt_port, src_id, src_port]
			_feed_buffer_point(key, t, val)

	_redraw_active_subplots()

func _resolve_metric_value(port_name: String, metrics: Dictionary) -> float:
	if port_name in ["length", "queue_length", "q_len"]:
		return float(metrics.get("queue_length", metrics.get("length", 0.0)))
	elif port_name in ["occupancy", "occupancy_pct"]:
		return float(metrics.get("occupancy_pct", metrics.get("queue_length", 0.0)))
	elif port_name in ["utilization", "util", "busy"]:
		var raw_u = float(metrics.get("utilization_pct", metrics.get("utilization", 0.0)))
		return raw_u if raw_u > 1.0 else (raw_u * 100.0)
	elif port_name in ["wait_time", "wait_mean", "wait_mean_wq"]:
		return float(metrics.get("wait_mean_wq", metrics.get("wait_time", 0.0)))
	elif port_name in ["in_transit", "transit_count", "items_in_transit"]:
		return float(metrics.get("items_in_transit", metrics.get("in_transit", 0.0)))
	elif port_name in ["completed_count", "departures", "exited_total"]:
		return float(metrics.get("completed_count", metrics.get("exited_total", 0.0)))
	elif metrics.has(port_name):
		return float(metrics[port_name])
	return 0.0

func _feed_buffer_point(key: String, t: float, val: float) -> void:
	if not _telemetry_buffers.has(key):
		_telemetry_buffers[key] = []
	var arr: Array = _telemetry_buffers[key]
	arr.append({"t": t, "val": val})
	if arr.size() > 20000:
		arr.pop_front()

func _ensure_default_subplots(elem: SceneTypes.SceneElement) -> void:
	var subplots: Array = elem.properties.get("subplots", [])
	if not subplots.is_empty(): return

	var legacy_type: String = "time_series"
	if elem.kind == "digital_meter": legacy_type = "digital_gauge"
	elif elem.kind == "histogram_sink": legacy_type = "histogram"
	elif elem.kind == "xy_scatter": legacy_type = "xy_scatter"
	elif elem.kind == "state_space_3d": legacy_type = "state_space_3d"

	subplots = [{
		"id": "sp_1",
		"port_id": "P1" if elem.kind == "chart_station" else "sig_in",
		"title": str(elem.properties.get("chart_title", elem.properties.get("title", elem.name))),
		"type": legacy_type,
		"y_label": str(elem.properties.get("y_label", "Value")),
		"autoscale": bool(elem.properties.get("autoscale", true)),
		"y_min": 0.0,
		"y_max": 100.0,
		"grid": {"col": 0, "row": 0, "col_span": 1, "row_span": 1},
		"mode": "overlay",
		"signals": []
	}]
	elem.properties["subplots"] = subplots

## Unified Rendering of All Subplots on Single Canvas
func _redraw_active_subplots() -> void:
	if not visible or active_chart_elem_id.is_empty() or doc_store == null: return
	var elem = doc_store.get_element(active_chart_elem_id)
	if elem == null: return

	var subplots: Array = elem.properties.get("subplots", [])
	if subplots.is_empty():
		_ensure_default_subplots(elem)
		subplots = elem.properties.get("subplots", [])

	var count: int = subplots.size()
	var rows: int = int(elem.properties.get("grid_rows", 0))
	var cols: int = int(elem.properties.get("grid_columns", 0))

	if rows <= 0 or cols <= 0:
		if count <= 1:
			rows = 1; cols = 1
		elif count == 2:
			rows = 2; cols = 1
		elif count in [3, 4]:
			rows = 2; cols = 2
		elif count in [5, 6]:
			rows = 3; cols = 2
		else:
			cols = 3; rows = int(ceil(float(count) / 3.0))

	# X-Axis range: Squeeze (Fit All 0 -> now) if time_window_seconds <= 0.0, else Rolling Window
	var t_start: float = 0.0
	var t_end: float = max(1.0, _latest_sim_t)
	if time_window_seconds > 0.0:
		t_end = max(time_window_seconds, _latest_sim_t)
		t_start = max(0.0, t_end - time_window_seconds)

	# 1. Native ImPlot GPU Subplots Rendering
	if _has_implot and use_implot and _simplot_view != null:
		_simplot_view.clear_subplots()
		_simplot_view.set_subplots_grid(rows, cols)
		_simplot_view.set_x_limits(t_start, t_end)

		for i in range(count):
			var sp: Dictionary = subplots[i]
			var s_title: String = str(sp.get("title", "Subplot %d" % (i + 1)))
			var s_port: String = str(sp.get("port_id", "P%d" % (i + 1)))
			var s_type: String = str(sp.get("type", "time_series"))
			var s_ylabel: String = str(sp.get("y_label", "Value"))
			var s_auto: bool = bool(sp.get("autoscale", true))
			var s_min: float = float(sp.get("y_min", 0.0))
			var s_max: float = float(sp.get("y_max", 100.0))

			_simplot_view.configure_subplot(i, s_title, s_ylabel, s_auto, s_min, s_max, s_type)

			var explicit_signals: Array = sp.get("signals", [])
			if not explicit_signals.is_empty():
				# Render explicitly chosen signals for any entity
				for s_idx in range(explicit_signals.size()):
					var sig = explicit_signals[s_idx]
					var ent_id = str(sig.get("entity_id", ""))
					var ym = str(sig.get("y_metric", ""))
					var xm = str(sig.get("x_metric", "__time__"))
					var s_label = str(sig.get("label", "%s.%s" % [ent_id, ym]))

					var key_y := "%s:%s" % [ent_id, ym]
					var arr_y: Array = _telemetry_buffers.get(key_y, [])
					if arr_y.is_empty():
						if s_type == "digital_gauge":
							_simplot_view.set_subplot_series_2d(i, s_label, PackedFloat32Array([0.0]), PackedFloat32Array([0.0]))
						continue

					if s_type == "digital_gauge":
						var latest_v: float = float(arr_y.back().get("val", 0.0))
						var xs := PackedFloat32Array([0.0])
						var ys := PackedFloat32Array([latest_v])
						_simplot_view.set_subplot_series_2d(i, s_label, xs, ys)
					elif s_type == "histogram":
						var vals := PackedFloat32Array()
						vals.resize(arr_y.size())
						for j in range(arr_y.size()):
							vals[j] = float(arr_y[j].get("val", 0.0))
						_simplot_view.set_subplot_histogram(i, s_label, vals, 15)
					elif s_type == "xy_scatter" or xm != "__time__":
						var key_x := "%s:%s" % [ent_id, xm]
						var arr_x: Array = _telemetry_buffers.get(key_x, [])
						var pt_count = mini(arr_x.size(), arr_y.size())
						var xs := PackedFloat32Array()
						var ys := PackedFloat32Array()
						xs.resize(pt_count); ys.resize(pt_count)
						for j in range(pt_count):
							xs[j] = float(arr_x[j].get("val", 0.0))
							ys[j] = float(arr_y[j].get("val", 0.0))
						_simplot_view.set_subplot_series_2d(i, s_label, xs, ys)
					else:
						var xs := PackedFloat32Array()
						var ys := PackedFloat32Array()
						xs.resize(arr_y.size()); ys.resize(arr_y.size())
						for j in range(arr_y.size()):
							xs[j] = float(arr_y[j].get("t", 0.0))
							ys[j] = float(arr_y[j].get("val", 0.0))
						_simplot_view.set_subplot_series_2d(i, s_label, xs, ys)
			else:
				# Fallback to wired signals into this port
				var prefix := "%s/%s/" % [active_chart_elem_id, s_port]
				var series_keys: Array = []
				for k in _telemetry_buffers.keys():
					if k.begins_with(prefix):
						series_keys.append(k)

				for s_idx in range(series_keys.size()):
					var k = series_keys[s_idx]
					var arr: Array = _telemetry_buffers[k]
					if arr.is_empty(): continue
					var parts = k.split("/")
					var s_label: String = parts[-1] if parts.size() >= 3 else k

					if s_type == "digital_gauge":
						var latest_v: float = float(arr.back().get("val", 0.0))
						var xs := PackedFloat32Array([0.0])
						var ys := PackedFloat32Array([latest_v])
						_simplot_view.set_subplot_series_2d(i, s_label, xs, ys)
					elif s_type == "histogram":
						var vals := PackedFloat32Array()
						vals.resize(arr.size())
						for j in range(arr.size()):
							vals[j] = float(arr[j].get("val", 0.0))
						_simplot_view.set_subplot_histogram(i, s_label, vals, 15)
					else:
						var xs := PackedFloat32Array()
						var ys := PackedFloat32Array()
						xs.resize(arr.size()); ys.resize(arr.size())
						for j in range(arr.size()):
							xs[j] = float(arr[j].get("t", 0.0))
							ys[j] = float(arr[j].get("val", 0.0))
						_simplot_view.set_subplot_series_2d(i, s_label, xs, ys)

	# 2. Unified Vector Canvas Fallback Redraw
	if _vector_canvas != null and _vector_canvas.visible:
		_vector_canvas.queue_redraw()

# Detach to OS Desktop Window vs Dock to Main Viewport
func _toggle_detached() -> void:
	if _is_detached:
		dock_to_main_window()
	else:
		detach_to_os_window()

func detach_to_os_window() -> void:
	if _is_detached: return
	_shell_parent = get_parent()
	if _shell_parent == null: return

	var cur_global_pos := global_position
	var cur_sz := size

	_os_window = Window.new()
	_os_window.title = "SimViz Plot Studio"
	_os_window.size = Vector2i(max(640, int(cur_sz.x)), max(480, int(cur_sz.y)))

	var main_win_pos := Vector2i.ZERO
	if DisplayServer.get_name() != "headless":
		main_win_pos = DisplayServer.window_get_position()
	_os_window.position = main_win_pos + Vector2i(int(cur_global_pos.x), int(cur_global_pos.y))
	_os_window.transient = false
	_os_window.exclusive = false
	_os_window.wrap_controls = true
	_os_window.close_requested.connect(func():
		_os_window.hide()
		visible = false
		closed.emit()
	)

	var root_node: Node = null
	if _shell_parent.is_inside_tree() and _shell_parent.get_tree() != null:
		root_node = _shell_parent.get_tree().root
	elif _shell_parent is Window:
		root_node = _shell_parent

	if root_node != null:
		root_node.add_child(_os_window)
	else:
		_shell_parent.add_child(_os_window)

	_shell_parent.remove_child(self)
	_os_window.add_child(self)

	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	position = Vector2.ZERO
	custom_minimum_size = Vector2(520, 360)
	if visible:
		_os_window.show()
	else:
		_os_window.hide()

	_is_detached = true
	if _btn_detach != null:
		_btn_detach.text = "🗗 Dock"
		_btn_detach.tooltip_text = "Dock back inside the primary application window"

func dock_to_main_window() -> void:
	if not _is_detached: return
	if _os_window == null: return

	var win = _os_window
	_os_window = null

	win.remove_child(self)
	if _shell_parent != null and is_instance_valid(_shell_parent):
		_shell_parent.add_child(self)

	win.queue_free()
	_is_detached = false

	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2(60, 60)
	custom_minimum_size = Vector2(820, 540)
	size = custom_minimum_size
	z_index = 200

	if _btn_detach != null:
		_btn_detach.text = "🗗 Detach"
		_btn_detach.tooltip_text = "Pop out into an independent OS desktop window (movable across screens)"

# Draggable Window Handling
func _on_header_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if _is_detached and _os_window != null:
					if DisplayServer.has_method("window_start_drag") and _os_window.get_window_id() != -1:
						DisplayServer.window_start_drag(_os_window.get_window_id())
						return
					_drag_start_pos = event.global_position
				else:
					_drag_start_pos = event.global_position - position
				_is_dragging = true
			else:
				_is_dragging = false
	elif event is InputEventMouseMotion and _is_dragging:
		if _is_detached and _os_window != null:
			var rel := Vector2i(int(event.relative.x), int(event.relative.y))
			_os_window.position += rel
		else:
			var new_pos = event.global_position - _drag_start_pos
			if is_inside_tree() and get_viewport_rect().size != Vector2.ZERO:
				var vp_sz = get_viewport_rect().size
				new_pos.x = clamp(new_pos.x, -size.x + 120.0, max(0.0, vp_sz.x - 80.0))
				new_pos.y = clamp(new_pos.y, 0.0, max(0.0, vp_sz.y - 40.0))
			position = new_pos

# Resizing Window Handling
func _on_resize_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_resizing = event.pressed
			if _is_detached and _os_window != null:
				_resize_start_size = Vector2(_os_window.size.x, _os_window.size.y)
			else:
				_resize_start_size = size
			_resize_start_mouse = event.global_position
	elif event is InputEventMouseMotion and _is_resizing:
		var delta = event.global_position - _resize_start_mouse
		var new_w = max(520.0, _resize_start_size.x + delta.x)
		var new_h = max(360.0, _resize_start_size.y + delta.y)
		if _is_detached and _os_window != null:
			_os_window.size = Vector2i(int(new_w), int(new_h))
		else:
			if is_inside_tree() and get_viewport_rect().size != Vector2.ZERO:
				var vp_sz = get_viewport_rect().size
				new_w = clamp(new_w, 520.0, max(520.0, vp_sz.x - position.x))
				new_h = clamp(new_h, 360.0, max(360.0, vp_sz.y - position.y))
			custom_minimum_size = Vector2(new_w, new_h)
			size = custom_minimum_size

func _toggle_maximize() -> void:
	_is_maximized = not _is_maximized
	if _is_detached and _os_window != null:
		_os_window.mode = Window.MODE_MAXIMIZED if _is_maximized else Window.MODE_WINDOWED
		return

	if _is_maximized:
		_restored_rect = Rect2(position, size)
		var vp_sz := get_viewport_rect().size if (is_inside_tree() and get_viewport_rect().size != Vector2.ZERO) else Vector2(1280, 720)
		position = Vector2(20, 20)
		custom_minimum_size = vp_sz - Vector2(40, 40)
		size = custom_minimum_size
	else:
		position = _restored_rect.position
		custom_minimum_size = _restored_rect.size
		size = custom_minimum_size

## Unified Vector Canvas for 2D Fallback
class UnifiedVectorCanvas extends Control:
	var studio: AuthoringPlotStudio

	func _init(p_studio: AuthoringPlotStudio) -> void:
		studio = p_studio
		mouse_filter = Control.MOUSE_FILTER_PASS

	func _draw() -> void:
		if studio == null or studio.doc_store == null or studio.active_chart_elem_id.is_empty():
			return
		var elem = studio.doc_store.get_element(studio.active_chart_elem_id)
		if elem == null: return

		var rect := get_rect()
		var w: float = rect.size.x
		var h: float = rect.size.y
		if w <= 30.0 or h <= 30.0: return

		draw_rect(Rect2(0, 0, w, h), Color("#0a0e14"))

		var subplots: Array = elem.properties.get("subplots", [])
		if subplots.is_empty(): return
		var count: int = subplots.size()

		var rows: int = int(elem.properties.get("grid_rows", 0))
		var cols: int = int(elem.properties.get("grid_columns", 0))
		if rows <= 0 or cols <= 0:
			if count <= 1: rows = 1; cols = 1
			elif count == 2: rows = 2; cols = 1
			elif count in [3, 4]: rows = 2; cols = 2
			else: cols = 2; rows = int(ceil(float(count) / 2.0))

		var cell_w: float = (w - 8.0) / float(max(1, cols))
		var cell_h: float = (h - 8.0) / float(max(1, rows))

		for idx in range(count):
			var r: int = idx / cols
			var c: int = idx % cols
			var sp: Dictionary = subplots[idx]

			var cell_rect := Rect2(4.0 + float(c) * cell_w, 4.0 + float(r) * cell_h, cell_w - 4.0, cell_h - 4.0)
			_draw_subplot_cell(cell_rect, elem.id, sp)

	func _draw_subplot_cell(cell: Rect2, elem_id: String, sp: Dictionary) -> void:
		draw_rect(cell, Color("#0d131a"))
		draw_rect(cell, Color("#1f2937"), false, 1.0)

		var title: String = str(sp.get("title", "Subplot"))
		var port_id: String = str(sp.get("port_id", "P1"))
		var sp_type: String = str(sp.get("type", "time_series"))
		var y_label: String = str(sp.get("y_label", "Value"))

		# Title bar
		var header_text := "[%s] %s" % [port_id, title]
		draw_string(ThemeDB.fallback_font, Vector2(cell.position.x + 8.0, cell.position.y + 16.0), header_text, HORIZONTAL_ALIGNMENT_LEFT, int(cell.size.x - 16.0), 11, TEXT)

		# Data Series
		var explicit_signals: Array = sp.get("signals", [])
		var series_data: Array = []

		if not explicit_signals.is_empty():
			for sig in explicit_signals:
				var eid = str(sig.get("entity_id", ""))
				var ym = str(sig.get("y_metric", ""))
				var k := "%s:%s" % [eid, ym]
				if studio._telemetry_buffers.has(k):
					series_data.append(studio._telemetry_buffers[k])
		else:
			var prefix := "%s/%s/" % [elem_id, port_id]
			for k in studio._telemetry_buffers.keys():
				if k.begins_with(prefix):
					series_data.append(studio._telemetry_buffers[k])

		var plot_area := Rect2(cell.position.x + 36.0, cell.position.y + 24.0, cell.size.x - 44.0, cell.size.y - 32.0)

		if sp_type == "digital_gauge":
			var latest_v: float = 0.0
			var has_val: bool = false
			var s_name: String = ""
			if not series_data.is_empty():
				var arr: Array = series_data[0]
				if not arr.is_empty():
					latest_v = float(arr.back().get("val", 0.0))
					has_val = true
				if not explicit_signals.is_empty():
					s_name = str(explicit_signals[0].get("y_metric", ""))

			var g_min: float = float(sp.get("y_min", 0.0))
			var g_max: float = float(sp.get("y_max", 100.0))
			if g_max <= g_min: g_max = g_min + 100.0

			var center := Vector2(cell.position.x + cell.size.x * 0.5, cell.position.y + cell.size.y * 0.56)
			var radius: float = clampf(minf(cell.size.x * 0.36, cell.size.y * 0.38), 24.0, 160.0)
			var thickness: float = clampf(radius * 0.16, 6.0, 14.0)

			var pct: float = clampf((latest_v - g_min) / (g_max - g_min), 0.0, 1.0)
			var a_start: float = deg_to_rad(150.0)
			var a_span: float = deg_to_rad(240.0)
			var a_end: float = a_start + a_span
			var a_cur: float = a_start + pct * a_span

			var col_track := Color("#1a2432")
			var col_prog: Color
			if pct < 0.75:
				col_prog = GREEN
			elif pct < 0.90:
				col_prog = AMBER
			else:
				col_prog = RED

			# 1. Background Track Arc
			draw_arc(center, radius, a_start, a_end, 48, col_track, thickness, true)

			# 2. Active Progress Arc
			if pct > 0.002:
				draw_arc(center, radius, a_start, a_cur, 48, col_prog, thickness, true)

			# 3. Radial Ticks at 0%, 25%, 50%, 75%, 100%
			for t in range(5):
				var t_pct: float = float(t) * 0.25
				var t_ang: float = a_start + t_pct * a_span
				var r_in: float = radius - thickness * 0.9
				var r_out: float = radius + thickness * 0.9
				var p_in := center + Vector2(cos(t_ang), sin(t_ang)) * r_in
				var p_out := center + Vector2(cos(t_ang), sin(t_ang)) * r_out
				draw_line(p_in, p_out, Color(0.35, 0.45, 0.58, 0.7), 1.5, true)

			# 4. Indicator Needle Beacon
			var tip := center + Vector2(cos(a_cur), sin(a_cur)) * radius
			draw_circle(tip, thickness * 0.65, Color.WHITE)
			draw_arc(tip, thickness * 0.75, 0.0, TAU, 16, col_prog, 2.0, true)

			# 5. Central Digital Readout
			var val_str := ("%.2f" if abs(latest_v) < 10.0 else "%.1f") % latest_v
			var val_font_sz: int = int(clampf(radius * 0.38, 14.0, 26.0))
			draw_string(ThemeDB.fallback_font, Vector2(cell.position.x, center.y - 4.0), val_str, HORIZONTAL_ALIGNMENT_CENTER, int(cell.size.x), val_font_sz, col_prog)

			var unit_str := y_label if not y_label.is_empty() else "Value"
			draw_string(ThemeDB.fallback_font, Vector2(cell.position.x, center.y + float(val_font_sz) * 0.75), unit_str, HORIZONTAL_ALIGNMENT_CENTER, int(cell.size.x), 10, Color("#8c9eb9"))

			# 6. Min and Max Range Callouts
			var r_lbl := radius + thickness + 12.0
			var min_pos := center + Vector2(cos(a_start), sin(a_start)) * r_lbl
			var max_pos := center + Vector2(cos(a_end), sin(a_end)) * r_lbl
			draw_string(ThemeDB.fallback_font, min_pos - Vector2(16, -4), "%.0f" % g_min, HORIZONTAL_ALIGNMENT_CENTER, 32, 9, Color("#6e829b"))
			draw_string(ThemeDB.fallback_font, max_pos - Vector2(16, -4), "%.0f" % g_max, HORIZONTAL_ALIGNMENT_CENTER, 32, 9, Color("#6e829b"))

			# 7. Bound Signal Name at Top
			if not s_name.is_empty():
				draw_string(ThemeDB.fallback_font, Vector2(cell.position.x, cell.position.y + 30.0), s_name, HORIZONTAL_ALIGNMENT_CENTER, int(cell.size.x), 10, Color("#00d2ffcc"))

			if not has_val:
				var hint := "(Awaiting simulation data...)" if not explicit_signals.is_empty() else "(No variable selected — add in left dock)"
				draw_string(ThemeDB.fallback_font, Vector2(cell.position.x, center.y + float(val_font_sz) * 1.5), hint, HORIZONTAL_ALIGNMENT_CENTER, int(cell.size.x), 9, Color("#8b949e"))

		elif sp_type == "histogram":
			var n_bars := 12
			var b_w: float = plot_area.size.x / float(n_bars)
			var hist_vals: Array = []
			if not series_data.is_empty():
				var arr: Array = series_data[0]
				for pt in arr: hist_vals.append(float(pt.get("val", 0.0)))

			var counts := []
			counts.resize(n_bars)
			for bi in range(n_bars): counts[bi] = 0

			if not hist_vals.is_empty():
				var v_min: float = hist_vals[0]
				var v_max: float = hist_vals[0]
				for v in hist_vals:
					v_min = min(v_min, v)
					v_max = max(v_max, v)
				var v_range = max(0.001, v_max - v_min)
				for v in hist_vals:
					var b_idx = mini(n_bars - 1, int(((v - v_min) / v_range) * float(n_bars)))
					counts[b_idx] += 1
				var max_c: int = 1
				for c in counts: max_c = max(max_c, c)
				for bi in range(n_bars):
					var bh = (float(counts[bi]) / float(max_c)) * (plot_area.size.y - 10.0)
					draw_rect(Rect2(plot_area.position.x + float(bi) * b_w, plot_area.position.y + plot_area.size.y - bh, b_w - 2.0, bh), Color("#bc8cffaa"))
			else:
				for bi in range(n_bars):
					draw_rect(Rect2(plot_area.position.x + float(bi) * b_w, plot_area.position.y + plot_area.size.y - 4.0, b_w - 2.0, 4.0), Color("#1b2533"))
		else:
			# Axes grid lines
			draw_line(Vector2(plot_area.position.x, plot_area.position.y + plot_area.size.y * 0.5), Vector2(plot_area.position.x + plot_area.size.x, plot_area.position.y + plot_area.size.y * 0.5), Color(0.2, 0.3, 0.4, 0.25))
			draw_line(Vector2(plot_area.position.x, plot_area.position.y + plot_area.size.y), Vector2(plot_area.position.x + plot_area.size.x, plot_area.position.y + plot_area.size.y), Color(0.2, 0.3, 0.4, 0.4))

			for s_i in range(series_data.size()):
				var arr: Array = series_data[s_i]
				if arr.size() < 2: continue
				var col: Color = SERIES_COLORS[s_i % SERIES_COLORS.size()]
				var pts := PackedVector2Array()
				var s_max: float = 1.0
				for pt in arr: s_max = max(s_max, float(pt.get("val", 0.0)))
				for j in range(arr.size()):
					var sx: float = plot_area.position.x + (float(j) / max(1.0, float(arr.size() - 1))) * plot_area.size.x
					var sy: float = plot_area.position.y + plot_area.size.y - (clamp(float(arr[j].get("val", 0.0)) / max(0.001, s_max), 0.0, 1.0) * plot_area.size.y)
					pts.append(Vector2(sx, sy))
				draw_polyline(pts, col, 1.5, true)
				draw_circle(pts[-1], 2.5, col)
