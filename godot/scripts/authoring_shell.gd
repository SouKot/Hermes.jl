# authoring_shell.gd
# Top-level Authoring Shell coordinating Two-View Architecture (2D and 3D), Component Catalog, and Inspector.
class_name SimVizAuthoringShell
extends Control

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const Catalog := preload("res://scripts/authoring_catalog.gd")
const Canvas2D := preload("res://scripts/authoring_2d_canvas.gd")
const Viewport3D := preload("res://scripts/authoring_3d_viewport.gd")
const DiagnosticsPanel := preload("res://scripts/authoring_diagnostics_panel.gd")
const Inspector := preload("res://scripts/authoring_inspector.gd")
const RuleBuilder := preload("res://scripts/authoring_rule_builder.gd")
const FloatingInspector := preload("res://scripts/authoring_floating_inspector.gd")
const ABMDialog := preload("res://scripts/authoring_abm_dialog.gd")
const TemplateDialog := preload("res://scripts/authoring_template_dialog.gd")

enum ViewMode { VIEW_2D, VIEW_3D }

signal play_requested
signal pause_requested
signal step_requested
signal reset_requested
signal speed_changed(speed: float)

const BG := Color("#0b1018")
const PANEL := Color("#121b27")
const PANEL_ALT := Color("#172333")
const BORDER := Color("#26384b")
const TEXT := Color("#e5edf5")
const MUTED := Color("#8da2b5")
const ACCENT := Color("#52c7a5")
const WARNING := Color("#e6b85c")

var doc_store: DocumentStore
var catalog: Catalog

var current_view: ViewMode = ViewMode.VIEW_2D

# UI References
var _doc_title_label: Label
var _btn_view_2d: Button
var _btn_view_3d: Button
var _outer_split: HSplitContainer
var _inner_split: HSplitContainer
var _center_container: Control
var _canvas_2d: Canvas2D
var _viewport_3d: Viewport3D
var _breadcrumb_bar: PanelContainer
var _btn_breadcrumb_root: Button
var _lbl_breadcrumb_sep: Label
var _lbl_breadcrumb_scope: Label
var _btn_breadcrumb_exit: Button
var _btn_group: Button
var _btn_ungroup: Button
var _btn_template: Button

# Left Dock
var _catalog_container: VBoxContainer
var _tree_container: VBoxContainer

# Right Dock
var _inspector_panel: Inspector
var _floating_inspector: FloatingInspector
var _rule_builder: RuleBuilder
var _diagnostics_panel: DiagnosticsPanel
var _abm_dialog: ABMDialog
var _template_dialog: TemplateDialog
var _btn_abm: Button
var _abm_status_pill: Label

# Backwards compatibility getters/setters
var inspector: Inspector:
	get:
		return _inspector_panel
var _inspector_container: VBoxContainer:
	get:
		return _inspector_panel._container if _inspector_panel != null else null
var _insp_spin_px: SpinBox:
	get:
		return _inspector_panel._spin_px if _inspector_panel != null else null
	set(v):
		if _inspector_panel != null: _inspector_panel._spin_px = v
var _insp_spin_py: SpinBox:
	get:
		return _inspector_panel._spin_py if _inspector_panel != null else null
	set(v):
		if _inspector_panel != null: _inspector_panel._spin_py = v
var _insp_spin_pz: SpinBox:
	get:
		return _inspector_panel._spin_pz if _inspector_panel != null else null
	set(v):
		if _inspector_panel != null: _inspector_panel._spin_pz = v
var _insp_spin_rot: SpinBox:
	get:
		return _inspector_panel._spin_rot if _inspector_panel != null else null
	set(v):
		if _inspector_panel != null: _inspector_panel._spin_rot = v

# Transport
var _btn_play: Button
var _btn_pause: Button
var _btn_step: Button
var _btn_reset: Button
var _clock_label: Label
var _speed_slider: HSlider
var _speed_label: Label

var sim_time: float = 0.0
var is_sim_running: bool = false
var sim_speed: float = 1.0

func _init() -> void:
	doc_store = DocumentStore.new()
	catalog = Catalog.new()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _ready() -> void:
	_build_ui()
	_connect_signals()
	_update_view_toggle_ui()
	_populate_catalog()
	_populate_inspector()
	_update_abm_status_pill()

func _connect_signals() -> void:
	doc_store.document_loaded.connect(_on_document_loaded)
	doc_store.document_modified.connect(_on_document_modified)
	doc_store.document_saved.connect(_on_document_saved)
	doc_store.selection_changed.connect(_on_selection_changed)
	doc_store.diagnostics_updated.connect(_on_diagnostics_updated)
	doc_store.scope_changed.connect(_on_scope_changed)
	doc_store.subgraphs_modified.connect(_on_subgraphs_modified)
	_diagnostics_panel.diagnostic_focused.connect(_on_diagnostic_focused)
	_diagnostics_panel.fix_requested.connect(_on_diagnostic_fix_requested)
	if _canvas_2d != null:
		_canvas_2d.floating_properties_requested.connect(_on_floating_properties_requested)
	if _viewport_3d != null:
		_viewport_3d.floating_properties_requested.connect(_on_floating_properties_requested)
	if _inspector_panel != null:
		_inspector_panel.open_floating_requested.connect(_on_floating_properties_requested)

func _process(delta: float) -> void:
	if is_sim_running:
		sim_time += delta * sim_speed
		_clock_label.text = "t = %.2f s" % sim_time

func _build_ui() -> void:
	var bg_rect := ColorRect.new()
	bg_rect.color = BG
	bg_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg_rect)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# 1. Top Header
	root.add_child(_build_header())

	# 2. Main Workspace (Resizable Splitters: Left Dock | Center Viewport | Right Dock)
	_outer_split = HSplitContainer.new()
	_outer_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_outer_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_outer_split.split_offset = 220
	root.add_child(_outer_split)

	_outer_split.add_child(_build_left_dock())

	_inner_split = HSplitContainer.new()
	_inner_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inner_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_outer_split.add_child(_inner_split)

	# Center Viewport Area
	_center_container = PanelContainer.new()
	_center_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_center_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_center_container.custom_minimum_size = Vector2(300, 200)
	var center_style := StyleBoxFlat.new()
	center_style.bg_color = BG
	center_style.border_color = BORDER
	center_style.set_border_width_all(1)
	_center_container.add_theme_stylebox_override("panel", center_style)
	_inner_split.add_child(_center_container)

	var center_vbox := VBoxContainer.new()
	center_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center_vbox.add_theme_constant_override("separation", 0)
	_center_container.add_child(center_vbox)

	center_vbox.add_child(_build_breadcrumb_bar())

	var view_area := Control.new()
	view_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_vbox.add_child(view_area)

	_canvas_2d = Canvas2D.new(doc_store)
	_canvas_2d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view_area.add_child(_canvas_2d)

	_viewport_3d = Viewport3D.new(doc_store)
	_viewport_3d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewport_3d.visible = false
	view_area.add_child(_viewport_3d)

	_inner_split.add_child(_build_right_dock())

	# 3. Persistent Bottom Transport
	root.add_child(_build_transport())

	# 4. Floating / Modal Rule Builder Overlay
	_rule_builder = RuleBuilder.new(doc_store)
	_rule_builder.visible = false
	_rule_builder.closed.connect(func(): _rule_builder.visible = false)
	_rule_builder.rule_saved.connect(func(conn_id: String, cond: Dictionary):
		doc_store.update_connection_condition(conn_id, cond)
		if _inspector_panel != null:
			_inspector_panel.refresh()
	)
	add_child(_rule_builder)

	# 5. Floating / Modal Tabbed Inspector Window
	_floating_inspector = FloatingInspector.new(doc_store, catalog)
	_floating_inspector.duplicate_requested.connect(_duplicate_element)
	_floating_inspector.delete_requested.connect(_delete_element)
	_floating_inspector.open_rule_builder_requested.connect(func(cid: String):
		_rule_builder.open_for_connection(cid)
	)
	add_child(_floating_inspector)

	# 6. Floating / Modal ABM & Hybrid Configuration Dialog
	_abm_dialog = ABMDialog.new(doc_store)
	_abm_dialog.visible = false
	_abm_dialog.closed.connect(func(): _abm_dialog.visible = false)
	add_child(_abm_dialog)

	# 7. Floating / Modal Template Packaging Dialog
	_template_dialog = TemplateDialog.new(doc_store)
	_template_dialog.visible = false
	_template_dialog.closed.connect(func(): _template_dialog.visible = false)
	_template_dialog.template_created.connect(func(tmpl: SceneTypes.SceneSubgraph):
		catalog.register_template_entry(tmpl)
		_populate_catalog()
		if _canvas_2d != null: _canvas_2d.rebuild_blocks()
	)
	add_child(_template_dialog)

func _build_header() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 52
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = BORDER
	style.border_width_bottom = 1
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.add_theme_constant_override("margin_left", 14)
	row.add_theme_constant_override("margin_right", 14)
	panel.add_child(row)

	# App Title
	var title := Label.new()
	title.text = "ANTIGRAVITY / SIMVIZ"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", TEXT)
	row.add_child(title)

	# Document Name & Dirty Star
	_doc_title_label = Label.new()
	_doc_title_label.text = "Untitled Scene"
	_doc_title_label.add_theme_font_size_override("font_size", 13)
	_doc_title_label.add_theme_color_override("font_color", MUTED)
	row.add_child(_doc_title_label)

	row.add_child(VSeparator.new())

	# File Actions
	var btn_new := Button.new()
	btn_new.text = "New"
	btn_new.pressed.connect(func(): doc_store.new_document())
	row.add_child(btn_new)

	var btn_save := Button.new()
	btn_save.text = "Save"
	btn_save.pressed.connect(func(): _on_save_clicked())
	row.add_child(btn_save)

	var btn_val := Button.new()
	btn_val.text = "Validate"
	btn_val.pressed.connect(func(): doc_store.validate())
	row.add_child(btn_val)

	row.add_child(VSeparator.new())

	_btn_group = Button.new()
	_btn_group.text = "⚏ Group"
	_btn_group.tooltip_text = "Group selection into compound subsystem (Ctrl+G)"
	_btn_group.pressed.connect(_on_group_clicked)
	row.add_child(_btn_group)

	_btn_ungroup = Button.new()
	_btn_ungroup.text = "✕ Ungroup"
	_btn_ungroup.tooltip_text = "Ungroup selected compound subsystem (Ctrl+Shift+G)"
	_btn_ungroup.pressed.connect(_on_ungroup_clicked)
	row.add_child(_btn_ungroup)

	_btn_template = Button.new()
	_btn_template.text = "📦 Template"
	_btn_template.tooltip_text = "Package selected elements into reusable catalog template"
	_btn_template.pressed.connect(_on_package_template_clicked)
	row.add_child(_btn_template)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	# Auto-Layout DAG button
	var btn_layout := Button.new()
	btn_layout.text = "☷ Auto-Layout"
	btn_layout.pressed.connect(func():
		if _canvas_2d != null:
			_canvas_2d.auto_layout_dag()
		if _viewport_3d != null:
			_viewport_3d.rebuild_3d_scene()
			_viewport_3d.frame_scene()
	)
	row.add_child(btn_layout)

	# Frame All button
	var btn_frame := Button.new()
	btn_frame.text = "⛶ Frame All"
	btn_frame.pressed.connect(func():
		if current_view == ViewMode.VIEW_2D and _canvas_2d != null:
			_canvas_2d.frame_all()
		elif current_view == ViewMode.VIEW_3D and _viewport_3d != null:
			_viewport_3d.frame_scene()
	)
	row.add_child(btn_frame)

	row.add_child(VSeparator.new())

	# ABM Status & Settings
	_abm_status_pill = Label.new()
	_abm_status_pill.text = "[○ ABM: OFF]"
	_abm_status_pill.add_theme_font_size_override("font_size", 11)
	_abm_status_pill.add_theme_color_override("font_color", MUTED)
	row.add_child(_abm_status_pill)

	_btn_abm = Button.new()
	_btn_abm.text = "⚙ ABM Settings"
	_btn_abm.pressed.connect(_on_abm_button_pressed)
	row.add_child(_btn_abm)

	row.add_child(VSeparator.new())

	# TWO-VIEW SYSTEM TOGGLE BUTTONS
	var toggle_box := HBoxContainer.new()
	toggle_box.add_theme_constant_override("separation", 0)
	row.add_child(toggle_box)

	_btn_view_2d = Button.new()
	_btn_view_2d.text = "  [ 2D LAYOUT ]  "
	_btn_view_2d.pressed.connect(func(): switch_view(ViewMode.VIEW_2D))
	toggle_box.add_child(_btn_view_2d)

	_btn_view_3d = Button.new()
	_btn_view_3d.text = "  [ 3D LAYOUT ]  "
	_btn_view_3d.pressed.connect(func(): switch_view(ViewMode.VIEW_3D))
	toggle_box.add_child(_btn_view_3d)

	return panel

func _build_breadcrumb_bar() -> Control:
	_breadcrumb_bar = PanelContainer.new()
	_breadcrumb_bar.custom_minimum_size.y = 28
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = BORDER
	style.border_width_bottom = 1
	_breadcrumb_bar.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.add_theme_constant_override("margin_left", 10)
	hbox.add_theme_constant_override("margin_right", 10)
	_breadcrumb_bar.add_child(hbox)

	_btn_breadcrumb_root = Button.new()
	_btn_breadcrumb_root.text = "🏠 Root (Main Scene)"
	_btn_breadcrumb_root.flat = true
	_btn_breadcrumb_root.add_theme_font_size_override("font_size", 11)
	_btn_breadcrumb_root.add_theme_color_override("font_color", ACCENT)
	_btn_breadcrumb_root.pressed.connect(func(): doc_store.exit_to_root_scope())
	hbox.add_child(_btn_breadcrumb_root)

	_lbl_breadcrumb_sep = Label.new()
	_lbl_breadcrumb_sep.text = "›"
	_lbl_breadcrumb_sep.add_theme_font_size_override("font_size", 12)
	_lbl_breadcrumb_sep.add_theme_color_override("font_color", MUTED)
	_lbl_breadcrumb_sep.visible = false
	hbox.add_child(_lbl_breadcrumb_sep)

	_lbl_breadcrumb_scope = Label.new()
	_lbl_breadcrumb_scope.text = ""
	_lbl_breadcrumb_scope.add_theme_font_size_override("font_size", 11)
	_lbl_breadcrumb_scope.add_theme_color_override("font_color", TEXT)
	_lbl_breadcrumb_scope.visible = false
	hbox.add_child(_lbl_breadcrumb_scope)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	_btn_breadcrumb_exit = Button.new()
	_btn_breadcrumb_exit.text = "⤺ Return to Root"
	_btn_breadcrumb_exit.flat = true
	_btn_breadcrumb_exit.add_theme_font_size_override("font_size", 11)
	_btn_breadcrumb_exit.add_theme_color_override("font_color", ACCENT)
	_btn_breadcrumb_exit.visible = false
	_btn_breadcrumb_exit.pressed.connect(func(): doc_store.exit_to_root_scope())
	hbox.add_child(_btn_breadcrumb_exit)

	return _breadcrumb_bar

func _build_left_dock() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 38 # ~1cm minimum collapsible width
	panel.clip_contents = true
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = BORDER
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var cat_title := Label.new()
	cat_title.text = "COMPONENT CATALOG"
	cat_title.add_theme_font_size_override("font_size", 12)
	cat_title.add_theme_color_override("font_color", TEXT)
	vbox.add_child(cat_title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_catalog_container = VBoxContainer.new()
	_catalog_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_catalog_container.add_theme_constant_override("separation", 4)
	scroll.add_child(_catalog_container)

	return panel

func _build_right_dock() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 38 # ~1cm minimum collapsible width
	panel.clip_contents = true
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = BORDER
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var insp_title := Label.new()
	insp_title.text = "ENTITY INSPECTOR"
	insp_title.add_theme_font_size_override("font_size", 12)
	insp_title.add_theme_color_override("font_color", TEXT)
	vbox.add_child(insp_title)

	_inspector_panel = Inspector.new(doc_store, catalog)
	_inspector_panel.duplicate_requested.connect(_duplicate_element)
	_inspector_panel.delete_requested.connect(_delete_element)
	_inspector_panel.rule_builder_requested.connect(func(conn_id: String):
		_open_rule_builder(conn_id)
	)
	vbox.add_child(_inspector_panel)

	# Bottom half: Diagnostics
	_diagnostics_panel = DiagnosticsPanel.new()
	vbox.add_child(_diagnostics_panel)

	return panel

func _build_transport() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 48
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = BORDER
	style.border_width_top = 1
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_theme_constant_override("margin_left", 16)
	row.add_theme_constant_override("margin_right", 16)
	panel.add_child(row)

	_btn_play = Button.new()
	_btn_play.text = "▶ PLAY"
	_btn_play.pressed.connect(func():
		is_sim_running = true
		if _inspector_panel != null:
			_inspector_panel.set_simulation_running(true)
		play_requested.emit()
	)
	row.add_child(_btn_play)

	_btn_pause = Button.new()
	_btn_pause.text = "⏸ PAUSE"
	_btn_pause.pressed.connect(func():
		is_sim_running = false
		if _inspector_panel != null:
			_inspector_panel.set_simulation_running(false)
		pause_requested.emit()
	)
	row.add_child(_btn_pause)

	_btn_step = Button.new()
	_btn_step.text = "⏭ STEP"
	_btn_step.pressed.connect(func():
		sim_time += 0.1
		_clock_label.text = "t = %.2f s" % sim_time
		step_requested.emit()
	)
	row.add_child(_btn_step)

	_btn_reset = Button.new()
	_btn_reset.text = "⏹ RESET"
	_btn_reset.pressed.connect(func():
		is_sim_running = false
		sim_time = 0.0
		_clock_label.text = "t = 0.00 s"
		if _inspector_panel != null:
			_inspector_panel.set_simulation_running(false)
		reset_requested.emit()
	)
	row.add_child(_btn_reset)

	row.add_child(VSeparator.new())

	_clock_label = Label.new()
	_clock_label.text = "t = 0.00 s"
	_clock_label.add_theme_font_size_override("font_size", 14)
	_clock_label.add_theme_color_override("font_color", TEXT)
	row.add_child(_clock_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_speed_label = Label.new()
	_speed_label.text = "Speed: 1.00x"
	_speed_label.add_theme_font_size_override("font_size", 12)
	_speed_label.add_theme_color_override("font_color", MUTED)
	row.add_child(_speed_label)

	_speed_slider = HSlider.new()
	_speed_slider.min_value = 0.25
	_speed_slider.max_value = 4.0
	_speed_slider.step = 0.25
	_speed_slider.value = 1.0
	_speed_slider.custom_minimum_size.x = 120
	_speed_slider.value_changed.connect(func(v: float):
		sim_speed = v
		_speed_label.text = "Speed: %.2fx" % v
		speed_changed.emit(v)
	)
	row.add_child(_speed_slider)

	return panel

func update_sim_time(t: float) -> void:
	sim_time = t
	if _clock_label != null:
		_clock_label.text = "t = %.2f s" % t

func switch_view(mode: ViewMode) -> void:
	current_view = mode
	_canvas_2d.visible = (current_view == ViewMode.VIEW_2D)
	_viewport_3d.visible = (current_view == ViewMode.VIEW_3D)
	_update_view_toggle_ui()
	if current_view == ViewMode.VIEW_3D and _viewport_3d != null:
		_viewport_3d.rebuild_3d_scene()
		_viewport_3d.frame_scene()

func _update_view_toggle_ui() -> void:
	if _btn_view_2d == null or _btn_view_3d == null:
		return
	if current_view == ViewMode.VIEW_2D:
		_btn_view_2d.modulate = Color.WHITE
		_btn_view_3d.modulate = Color("#7f8c8d")
	else:
		_btn_view_2d.modulate = Color("#7f8c8d")
		_btn_view_3d.modulate = Color.WHITE

func _populate_catalog() -> void:
	for child in _catalog_container.get_children():
		child.queue_free()

	for entry in catalog.get_all_entries():
		var btn := Button.new()
		btn.text = "+ " + entry.display_name
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 11)
		btn.pressed.connect(func(): _instantiate_catalog_item(entry.kind))
		_catalog_container.add_child(btn)

func _instantiate_catalog_item(kind: String) -> void:
	if doc_store == null:
		return
	var entry := catalog.get_entry(kind)
	if entry != null and entry.category == "Templates & Subgraphs":
		var count := doc_store.active_document.subgraphs.size() + 1
		var inst_name := "%s %d" % [entry.display_name, count]
		var offset_x := float((count % 4) * 16.0) + 15.0
		var offset_y := float((count / 4) * 10.0) + 15.0
		var inst := doc_store.instantiate_template(kind, inst_name, Vector3(offset_x, offset_y, 0.0))
		if inst != null:
			_canvas_2d.rebuild_blocks()
			_viewport_3d.rebuild_3d_scene()
		return

	var count := doc_store.active_document.elements.size() + 1
	var id_val := "%s_%02d" % [kind, count]
	var offset_x := float((count % 4) * 12.0) + 10.0
	var offset_y := float((count / 4) * 8.0) + 10.0
	var elem := catalog.create_element_instance(kind, id_val, Vector2(offset_x, offset_y))
	doc_store.add_element(elem)
	_canvas_2d.rebuild_blocks()
	_viewport_3d.rebuild_3d_scene()

func _populate_inspector() -> void:
	if _inspector_panel != null:
		_inspector_panel.refresh()

func _open_rule_builder(conn_id: String) -> void:
	if _rule_builder == null:
		return
	_rule_builder.open_for_connection(conn_id)
	var sz := _rule_builder.custom_minimum_size
	if size.x > sz.x and size.y > sz.y:
		_rule_builder.position = (size - sz) * 0.5
	else:
		_rule_builder.position = Vector2(50, 50)
	_rule_builder.visible = true
	_rule_builder.move_to_front()

func _on_document_loaded(doc: SceneTypes.SceneDocument) -> void:
	_update_title()
	_update_abm_status_pill()
	_diagnostics_panel.update_diagnostics(doc_store.last_diagnostics, doc_store.is_document_valid)
	_canvas_2d.rebuild_blocks()
	_viewport_3d.rebuild_3d_scene()

func _on_document_modified() -> void:
	_update_title()
	_update_abm_status_pill()
	_diagnostics_panel.update_diagnostics(doc_store.last_diagnostics, doc_store.is_document_valid)
	if _viewport_3d != null:
		_viewport_3d.rebuild_3d_scene()
	if doc_store != null and not doc_store.selected_id.is_empty() and doc_store.selected_type == "element":
		var sel_elem := doc_store.get_element(doc_store.selected_id)
		if sel_elem != null:
			if _insp_spin_px != null and is_instance_valid(_insp_spin_px) and not _insp_spin_px.has_focus():
				_insp_spin_px.set_value_no_signal(sel_elem.transform.position.x)
			if _insp_spin_py != null and is_instance_valid(_insp_spin_py) and not _insp_spin_py.has_focus():
				_insp_spin_py.set_value_no_signal(sel_elem.transform.position.y)
			if _insp_spin_pz != null and is_instance_valid(_insp_spin_pz) and not _insp_spin_pz.has_focus():
				_insp_spin_pz.set_value_no_signal(sel_elem.transform.position.z)
			if _insp_spin_rot != null and is_instance_valid(_insp_spin_rot) and not _insp_spin_rot.has_focus():
				_insp_spin_rot.set_value_no_signal(fposmod(float(sel_elem.transform.rotation.z), 360.0))

func _on_document_saved(_path: String) -> void:
	_update_title()

func _on_selection_changed(_id_val: String, _type_val: String) -> void:
	_insp_spin_px = null
	_insp_spin_py = null
	_insp_spin_pz = null
	_insp_spin_rot = null
	_populate_inspector()

func _on_diagnostics_updated(diagnostics: Array, is_valid: bool) -> void:
	_diagnostics_panel.update_diagnostics(diagnostics, is_valid)

func _on_diagnostic_focused(elem_id: String) -> void:
	doc_store.select(elem_id, "element")

func _on_diagnostic_fix_requested(diag: Dictionary) -> void:
	var rule: String = str(diag.get("rule_id", ""))
	if rule.begins_with("PORT_001") or rule.begins_with("PORT_002"):
		# Remove the faulty connection
		var src: String = str(diag.get("source_id", ""))
		for conn in doc_store.active_document.connections:
			if conn.id == src:
				doc_store.remove_connection(conn.id)
				_canvas_2d.rebuild_blocks()
				break
	elif rule.begins_with("GRAPH_001"):
		# Remove the isolated element
		var eid: String = str(diag.get("object_id", ""))
		if not eid.is_empty():
			doc_store.remove_element(eid)
			_canvas_2d.rebuild_blocks()
			_viewport_3d.rebuild_3d_scene()

func _update_title() -> void:
	var doc_name := "Untitled Scene"
	if doc_store != null and doc_store.active_document != null:
		doc_name = str(doc_store.active_document.scene.get("name", "Untitled Scene"))
	var star := " *" if (doc_store != null and doc_store.is_dirty) else ""
	_doc_title_label.text = "%s%s" % [doc_name, star]

func _on_save_clicked() -> void:
	var save_path := doc_store.file_path
	if save_path.is_empty():
		save_path = "user://authored_scene.json"
	doc_store.save_to_file(save_path)

func _duplicate_element(eid: String) -> void:
	doc_store.duplicate_element(eid)
	if _canvas_2d != null: _canvas_2d.rebuild_blocks()
	if _viewport_3d != null: _viewport_3d.rebuild_3d_scene()

func _delete_element(eid: String) -> void:
	doc_store.remove_element(eid)
	if _canvas_2d != null: _canvas_2d.rebuild_blocks()
	if _viewport_3d != null: _viewport_3d.rebuild_3d_scene()

func _on_floating_properties_requested(elem_id: String, screen_pos: Vector2 = Vector2.ZERO) -> void:
	if _floating_inspector != null:
		_floating_inspector.open_for_element(elem_id, screen_pos)

func _on_abm_button_pressed() -> void:
	if _abm_dialog != null:
		_abm_dialog.open()
		var sz := _abm_dialog.custom_minimum_size
		if size.x > sz.x and size.y > sz.y:
			_abm_dialog.position = (size - sz) * 0.5
		else:
			_abm_dialog.position = Vector2(80, 50)
		_abm_dialog.move_to_front()

func _update_abm_status_pill() -> void:
	if _abm_status_pill == null or doc_store == null or doc_store.active_document == null:
		return
	var doc: SceneTypes.SceneDocument = doc_store.active_document
	var sim: Dictionary = doc.simulation if doc.simulation is Dictionary else {}
	var mode: String = str(sim.get("mode", "des_only"))
	var abm: Dictionary = doc.abm_config if doc.abm_config is Dictionary else {}
	var enabled: bool = bool(abm.get("enabled", false))
	var model: String = str(abm.get("model_name", "SFM")).to_upper()
	if enabled or mode == "hybrid" or mode == "abm_only":
		_abm_status_pill.text = "[● ABM: %s]" % model
		_abm_status_pill.add_theme_color_override("font_color", ACCENT)
	else:
		_abm_status_pill.text = "[○ ABM: OFF]"
		_abm_status_pill.add_theme_color_override("font_color", MUTED)

func update_agent_telemetry(agents: Array) -> void:
	if _canvas_2d != null and _canvas_2d.has_method("update_agent_telemetry"):
		_canvas_2d.update_agent_telemetry(agents)
	if _viewport_3d != null and _viewport_3d.has_method("update_agent_telemetry"):
		_viewport_3d.update_agent_telemetry(agents)

func _on_scope_changed(scope_id: String, scope_name: String) -> void:
	if _btn_breadcrumb_root != null and _lbl_breadcrumb_sep != null and _lbl_breadcrumb_scope != null and _btn_breadcrumb_exit != null:
		if scope_id.is_empty():
			_btn_breadcrumb_root.text = "🏠 Root (Main Scene)"
			_lbl_breadcrumb_sep.visible = false
			_lbl_breadcrumb_scope.visible = false
			_btn_breadcrumb_exit.visible = false
		else:
			_btn_breadcrumb_root.text = "🏠 Root"
			_lbl_breadcrumb_sep.visible = true
			_lbl_breadcrumb_scope.visible = true
			_lbl_breadcrumb_scope.text = "📦 %s" % scope_name
			_btn_breadcrumb_exit.visible = true
	if _canvas_2d != null:
		_canvas_2d.rebuild_blocks()
	if _viewport_3d != null:
		_viewport_3d.rebuild_3d_scene()

func _on_subgraphs_modified() -> void:
	if _canvas_2d != null:
		_canvas_2d.rebuild_blocks()
	if _viewport_3d != null:
		_viewport_3d.rebuild_3d_scene()
	if _inspector_panel != null:
		_inspector_panel.refresh()

func _on_group_clicked() -> void:
	if doc_store == null:
		return
	var target_ids: Array = []
	if not doc_store.selected_elements.is_empty():
		for eid in doc_store.selected_elements:
			target_ids.append(eid)
	elif not doc_store.selected_id.is_empty() and doc_store.selected_type == "element":
		target_ids.append(doc_store.selected_id)
	if target_ids.is_empty():
		return
	var group_name := "Subsystem_%02d" % (doc_store.active_document.subgraphs.size() + 1)
	doc_store.group_elements(target_ids, group_name, "compound")
	if _canvas_2d != null: _canvas_2d.rebuild_blocks()
	if _viewport_3d != null: _viewport_3d.rebuild_3d_scene()

func _on_ungroup_clicked() -> void:
	if doc_store == null:
		return
	if doc_store.selected_type == "subgraph" and not doc_store.selected_id.is_empty():
		doc_store.ungroup(doc_store.selected_id)
		if _canvas_2d != null: _canvas_2d.rebuild_blocks()
		if _viewport_3d != null: _viewport_3d.rebuild_3d_scene()

func _on_package_template_clicked() -> void:
	if doc_store == null or _template_dialog == null:
		return
	var target_ids: Array = []
	if not doc_store.selected_elements.is_empty():
		for eid in doc_store.selected_elements:
			target_ids.append(eid)
	elif not doc_store.selected_id.is_empty() and doc_store.selected_type == "element":
		target_ids.append(doc_store.selected_id)
	elif doc_store.selected_type == "subgraph" and not doc_store.selected_id.is_empty():
		target_ids.append(doc_store.selected_id)

	if target_ids.is_empty():
		return

	_template_dialog.open_for_selection(target_ids)
	var sz := _template_dialog.custom_minimum_size
	if size.x > sz.x and size.y > sz.y:
		_template_dialog.position = (size - sz) * 0.5
	else:
		_template_dialog.position = Vector2(100, 60)
	_template_dialog.move_to_front()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.ctrl_pressed and event.shift_pressed and event.keycode == KEY_G:
			_on_ungroup_clicked()
			get_viewport().set_input_as_handled()
		elif event.ctrl_pressed and event.keycode == KEY_G:
			_on_group_clicked()
			get_viewport().set_input_as_handled()

