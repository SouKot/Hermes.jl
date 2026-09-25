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
const DiffDialog := preload("res://scripts/authoring_diff_dialog.gd")
const AutosaveDialog := preload("res://scripts/authoring_autosave_dialog.gd")
const UnsavedChangesDialog := preload("res://scripts/authoring_unsaved_changes_dialog.gd")
const SceneDiff := preload("res://scripts/scenespec_diff.gd")
const SceneCodec := preload("res://scripts/scenespec_codec.gd")
const PlotStudio := preload("res://scripts/authoring_plot_studio.gd")
const AuthoringOutliner := preload("res://scripts/authoring_outliner.gd")

enum ViewMode { VIEW_2D, VIEW_3D }

signal play_requested
signal pause_requested
signal step_requested(duration: float, unit: String)
signal reset_requested
signal speed_changed(speed: float)
signal command_requested(msg: Dictionary)

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
var _autosave_status_label: Label
var _file_menu: MenuButton
var _recent_menu: PopupMenu
var _file_dialog: FileDialog
var _diff_dialog: DiffDialog
var _autosave_dialog: AutosaveDialog
var _unsaved_dialog: UnsavedChangesDialog
var _file_dialog_action: String = ""
var _after_save_action: Dictionary = {}
var _pending_import_path: String = ""
var _pending_import_doc: Variant = null

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
var _outliner: AuthoringOutliner = null  # populated in _build_left_dock

# Right Dock
var _inspector_panel: Inspector
var _floating_inspector: FloatingInspector
var _rule_builder: RuleBuilder
var _diagnostics_panel: DiagnosticsPanel
var _abm_dialog: ABMDialog
var _template_dialog: TemplateDialog
var _btn_abm: Button
var _abm_status_pill: Label
var _plot_studio: PlotStudio
var _btn_plots: Button

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
var _spin_step_duration: SpinBox
var _opt_step_unit: OptionButton
var _btn_reset: Button
var _clock_label: Label
var _kpi_strip_label: Label
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
	if DisplayServer.get_name() != "headless":
		get_tree().set_auto_accept_quit(false)
	_build_ui()
	_connect_signals()
	_update_view_toggle_ui()
	_update_title()
	_populate_catalog()
	_populate_inspector()
	_update_abm_status_pill()
	_check_startup_recovery()
	if doc_store != null and doc_store.active_document != null and doc_store.active_document.elements.is_empty():
		call_deferred("load_starter_demo_model")

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if doc_store != null and doc_store.is_dirty:
			_request_action_guarded({"action": "quit"})
		else:
			get_tree().quit()

func _connect_signals() -> void:
	doc_store.document_loaded.connect(_on_document_loaded)
	doc_store.document_modified.connect(_on_document_modified)
	doc_store.document_saved.connect(_on_document_saved)
	doc_store.selection_changed.connect(_on_selection_changed)
	doc_store.diagnostics_updated.connect(_on_diagnostics_updated)
	doc_store.scope_changed.connect(_on_scope_changed)
	doc_store.subgraphs_modified.connect(_on_subgraphs_modified)
	doc_store.autosave_completed.connect(_on_autosave_completed)
	doc_store.recovery_detected.connect(_on_recovery_detected)
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
	if doc_store != null:
		doc_store.tick_autosave(delta)

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
	if _outliner != null:
		_outliner.setup(doc_store)

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

	var center_split := VSplitContainer.new()
	center_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_split.split_offset = 500
	center_vbox.add_child(center_split)

	var view_area := Control.new()
	view_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_split.add_child(view_area)

	_canvas_2d = Canvas2D.new(doc_store)
	_canvas_2d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view_area.add_child(_canvas_2d)

	_viewport_3d = Viewport3D.new(doc_store)
	_viewport_3d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewport_3d.visible = false
	view_area.add_child(_viewport_3d)

	_plot_studio = PlotStudio.new(doc_store)
	_plot_studio.visible = false
	_plot_studio.closed.connect(func():
		_plot_studio.visible = false
		if _btn_plots != null: _btn_plots.modulate = Color.WHITE
	)
	add_child(_plot_studio)
	_plot_studio.position = Vector2(100, 60)
	# Detach to independent native OS desktop window so it can move anywhere on screen without bounds
	_plot_studio.detach_to_os_window.call_deferred()

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
	_floating_inspector.hook_apply_requested.connect(func(msg: Dictionary):
		command_requested.emit(msg)
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

	# 8. Diff Dialog
	_diff_dialog = DiffDialog.new()
	_diff_dialog.visible = false
	_diff_dialog.merge_confirmed.connect(_on_diff_dialog_confirmed)
	add_child(_diff_dialog)

	# 9. Autosave Recovery Dialog
	_autosave_dialog = AutosaveDialog.new()
	_autosave_dialog.visible = false
	_autosave_dialog.recover_selected.connect(func(p: String):
		doc_store.recover_from_autosave(p)
		_update_title()
	)
	_autosave_dialog.discard_selected.connect(func(_p: String):
		doc_store.clear_autosave(doc_store.file_path)
	)
	_autosave_dialog.preview_selected.connect(func(p: String):
		var codec := SceneCodec.new()
		var auto_bytes := FileAccess.get_file_as_bytes(p)
		var auto_doc = codec.load_document(auto_bytes.get_string_from_utf8())
		if auto_doc != null:
			var diff = SceneDiff.diff_documents(doc_store.active_document, auto_doc)
			_diff_dialog.set_diff(diff)
			_diff_dialog.popup_centered()
	)
	add_child(_autosave_dialog)

	# 10. FileDialog
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.file_selected.connect(_on_file_selected)
	_file_dialog.dir_selected.connect(_on_dir_selected)
	_file_dialog.canceled.connect(_on_file_dialog_canceled)
	add_child(_file_dialog)

	# 11. Unsaved Changes Guard Dialog
	_unsaved_dialog = UnsavedChangesDialog.new()
	_unsaved_dialog.visible = false
	_unsaved_dialog.save_confirmed.connect(_on_unsaved_save_confirmed)
	_unsaved_dialog.discard_confirmed.connect(_on_unsaved_discard_confirmed)
	_unsaved_dialog.action_canceled.connect(_on_unsaved_action_canceled)
	add_child(_unsaved_dialog)

func _build_header() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 52
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = BORDER
	style.border_width_bottom = 1
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
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
	_doc_title_label.text = "Untitled Simulation"
	_doc_title_label.add_theme_font_size_override("font_size", 13)
	_doc_title_label.add_theme_color_override("font_color", Color("#d8dee9"))
	_doc_title_label.tooltip_text = "Current simulation file and scene name. Select empty canvas to view and edit Scene Properties."
	row.add_child(_doc_title_label)

	# Autosave Status
	_autosave_status_label = Label.new()
	_autosave_status_label.text = ""
	_autosave_status_label.add_theme_font_size_override("font_size", 11)
	_autosave_status_label.add_theme_color_override("font_color", Color("#52c7a5"))
	row.add_child(_autosave_status_label)

	row.add_child(VSeparator.new())

	# File MenuButton
	_file_menu = MenuButton.new()
	_file_menu.text = "File"
	_file_menu.flat = false
	var popup: PopupMenu = _file_menu.get_popup()
	popup.add_item("New Scene", 1)
	popup.add_item("Open Scene...", 2)
	popup.add_item("Open SimViz Bundle...", 3)

	_recent_menu = PopupMenu.new()
	_recent_menu.name = "RecentMenu"
	_recent_menu.id_pressed.connect(_on_recent_item_pressed)
	popup.add_child(_recent_menu)
	popup.add_submenu_item("Recent Projects", "RecentMenu", 4)

	popup.add_separator()
	popup.add_item("Save", 10)
	popup.add_item("Save As...", 11)
	popup.add_separator()
	popup.add_item("Export Canonical JSON (.scenespec)...", 20)
	popup.add_item("Export Binary MessagePack (.scenespec.mp)...", 21)
	popup.add_item("Export SimViz Bundle (.simviz)...", 22)
	popup.add_separator()
	popup.add_item("Import & Merge Scene...", 30)

	popup.id_pressed.connect(_on_file_menu_id_pressed)
	popup.about_to_popup.connect(_refresh_recent_menu)
	row.add_child(_file_menu)

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

	_btn_plots = Button.new()
	_btn_plots.text = "📈 Charts"
	_btn_plots.tooltip_text = "Toggle real-time live telemetry waveforms & charts"
	_btn_plots.pressed.connect(func():
		if _plot_studio != null:
			_plot_studio.toggle_visibility()
			_btn_plots.modulate = ACCENT if _plot_studio.visible else Color.WHITE
	)
	row.add_child(_btn_plots)

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
	panel.custom_minimum_size.x = 38
	panel.clip_contents = true
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = BORDER
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	# ── Tab pill switcher: Catalog | Outliner ──────────────────────────────
	var pill_hbox := HBoxContainer.new()
	pill_hbox.add_theme_constant_override("separation", 2)
	vbox.add_child(pill_hbox)

	var btn_catalog := Button.new()
	btn_catalog.text = "🗂 Catalog"
	btn_catalog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_catalog.toggle_mode = true
	btn_catalog.button_pressed = true
	btn_catalog.add_theme_font_size_override("font_size", 11)
	pill_hbox.add_child(btn_catalog)

	var btn_outliner := Button.new()
	btn_outliner.text = "🌳 Outliner"
	btn_outliner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_outliner.toggle_mode = true
	btn_outliner.button_pressed = false
	btn_outliner.add_theme_font_size_override("font_size", 11)
	pill_hbox.add_child(btn_outliner)

	# ── Catalog container ─────────────────────────────────────────────────
	var catalog_wrap := VBoxContainer.new()
	catalog_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(catalog_wrap)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	catalog_wrap.add_child(scroll)

	_catalog_container = VBoxContainer.new()
	_catalog_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_catalog_container.add_theme_constant_override("separation", 4)
	scroll.add_child(_catalog_container)

	# ── Outliner container ────────────────────────────────────────────────
	_outliner = AuthoringOutliner.new()
	_outliner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_outliner.visible = false
	vbox.add_child(_outliner)

	# Wire up outliner click → canvas selection
	_outliner.element_clicked.connect(func(eid: String):
		if doc_store != null:
			doc_store.set_selected_elements([eid])
	)
	_outliner.entity_selected.connect(func(_eid: String):
		# Pass entity selection to floating inspector if available
		pass
	)

	# ── Tab toggle logic ───────────────────────────────────────────────────
	btn_catalog.toggled.connect(func(on: bool):
		if on:
			catalog_wrap.visible = true
			_outliner.visible = false
			btn_outliner.button_pressed = false
	)
	btn_outliner.toggled.connect(func(on: bool):
		if on:
			catalog_wrap.visible = false
			_outliner.visible = true
			btn_catalog.button_pressed = false
	)

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
		var dur: float = _spin_step_duration.value if _spin_step_duration != null else 1.0
		var unit: String = _opt_step_unit.get_item_text(_opt_step_unit.selected) if _opt_step_unit != null else "s"
		var mult: float = 1.0
		if unit == "m": mult = 60.0
		elif unit == "h": mult = 3600.0
		elif unit == "d": mult = 86400.0
		sim_time += dur * mult
		if _clock_label != null:
			_clock_label.text = "t = %.2f s" % sim_time
		step_requested.emit(dur, unit)
	)
	row.add_child(_btn_step)

	_spin_step_duration = SpinBox.new()
	_spin_step_duration.min_value = 0.01
	_spin_step_duration.max_value = 1000000.0
	_spin_step_duration.step = 0.5
	_spin_step_duration.value = 1.0
	_spin_step_duration.custom_minimum_size.x = 70
	_spin_step_duration.tooltip_text = "Step duration interval (unrestricted step size)"
	row.add_child(_spin_step_duration)

	_opt_step_unit = OptionButton.new()
	_opt_step_unit.add_item("s", 0)
	_opt_step_unit.add_item("m", 1)
	_opt_step_unit.add_item("h", 2)
	_opt_step_unit.add_item("d", 3)
	_opt_step_unit.selected = 0
	_opt_step_unit.tooltip_text = "Step duration unit: s (seconds), m (minutes), h (hours), d (days)"
	row.add_child(_opt_step_unit)

	_btn_reset = Button.new()
	_btn_reset.text = "⏹ RESET"
	_btn_reset.pressed.connect(func():
		is_sim_running = false
		sim_time = 0.0
		_clock_label.text = "t = 0.00 s"
		if _inspector_panel != null:
			_inspector_panel.set_simulation_running(false)
		if _plot_studio != null:
			_plot_studio.clear_all()
		reset_requested.emit()
	)
	row.add_child(_btn_reset)

	row.add_child(VSeparator.new())

	_clock_label = Label.new()
	_clock_label.text = "t = 0.00 s"
	_clock_label.add_theme_font_size_override("font_size", 14)
	_clock_label.add_theme_color_override("font_color", TEXT)
	row.add_child(_clock_label)

	row.add_child(VSeparator.new())

	_kpi_strip_label = Label.new()
	_kpi_strip_label.text = "WIP: 0  |  In: 0  |  Out: 0  |  Rate: 0.00/s  |  Flow: ● BALANCED"
	_kpi_strip_label.add_theme_font_size_override("font_size", 11)
	_kpi_strip_label.add_theme_color_override("font_color", ACCENT)
	row.add_child(_kpi_strip_label)

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

func update_simulation_telemetry(state: Dictionary) -> void:
	var abm = state.get("abm_state", {})
	if abm is Dictionary and not abm.is_empty() and _kpi_strip_label != null:
		var wip: int = int(abm.get("wip_total", 0))
		var arr: int = int(abm.get("total_arrivals", 0))
		var dep: int = int(abm.get("total_departures", 0))
		var rate: float = float(abm.get("throughput_eff", 0.0))
		var cycle: float = float(abm.get("sojourn_mean", 0.0))
		var ll_status: String = str(abm.get("littles_law_status", "warming_up"))
		var ll_err: float = float(abm.get("littles_law_error_pct", 0.0))
		var ll_text: String = "● LL: " + ll_status.to_upper()
		if ll_status in ["valid", "converging"]:
			ll_text += " (%.1f%%)" % ll_err

		_kpi_strip_label.text = "WIP: %d  |  In: %d  |  Out: %d  |  Rate: %.2f/s  |  Cycle: %.1fs  |  %s" % [
			wip, arr, dep, rate, cycle, ll_text
		]

	var elems: Dictionary = state.get("elements_by_id", {})
	if _inspector_panel != null and _inspector_panel.has_method("update_live_element_metrics"):
		_inspector_panel.update_live_element_metrics(elems)
	if _canvas_2d != null and _canvas_2d.has_method("update_element_telemetry"):
		_canvas_2d.update_element_telemetry(elems)
	if _plot_studio != null and _plot_studio.has_method("feed_telemetry"):
		_plot_studio.feed_telemetry(sim_time, elems, abm if abm is Dictionary else {})
	if _outliner != null and is_instance_valid(_outliner):
		# Always collect entities; outliner skips Tree rebuild when not visible
		var entities: Array = []
		if state.has("entities_by_id") and state["entities_by_id"] is Dictionary:
			entities = state["entities_by_id"].values()
		elif state.has("entities") and state["entities"] is Array:
			entities = state["entities"]
		_outliner.feed_telemetry(elems, entities)

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

	var by_category: Dictionary = {}
	for entry in catalog.get_all_entries():
		var cat: String = entry.category if not entry.category.is_empty() else "General"
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append(entry)

	for cat in by_category.keys():
		var cat_lbl := Label.new()
		cat_lbl.text = "── %s ──" % cat.to_upper()
		cat_lbl.add_theme_font_size_override("font_size", 9)
		cat_lbl.add_theme_color_override("font_color", ACCENT)
		_catalog_container.add_child(cat_lbl)

		for entry in by_category[cat]:
			var btn := Button.new()
			btn.text = "+ " + entry.display_name
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			btn.add_theme_font_size_override("font_size", 11)
			btn.tooltip_text = entry.description
			btn.pressed.connect(func(): _instantiate_catalog_item(entry.kind))
			_catalog_container.add_child(btn)

		var spacer := Control.new()
		spacer.custom_minimum_size.y = 4
		_catalog_container.add_child(spacer)

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
	if _autosave_status_label != null:
		_autosave_status_label.text = "● Saved"
		_autosave_status_label.add_theme_color_override("font_color", Color("#52c7a5"))
	_diagnostics_panel.update_diagnostics(doc_store.last_diagnostics, doc_store.is_document_valid)
	_canvas_2d.rebuild_blocks()
	_viewport_3d.rebuild_3d_scene()

func _on_document_modified() -> void:
	_update_title()
	_update_abm_status_pill()
	if _autosave_status_label != null and doc_store != null and doc_store.is_dirty:
		_autosave_status_label.text = "● Unsaved Changes"
		_autosave_status_label.add_theme_color_override("font_color", Color("#f1c40f"))
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
	if _autosave_status_label != null:
		_autosave_status_label.text = "● Saved"
		_autosave_status_label.add_theme_color_override("font_color", Color("#52c7a5"))

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
	var display_title := "Untitled Simulation"
	if doc_store != null:
		display_title = doc_store.get_display_title()
	var star := " *" if (doc_store != null and doc_store.is_dirty) else ""
	if _doc_title_label != null:
		_doc_title_label.text = "%s%s" % [display_title, star]
	if is_inside_tree() and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_title("%s%s — Antigravity SimViz" % [display_title, star])

func _on_save_clicked() -> void:
	if doc_store == null:
		return
	if doc_store.file_path.is_empty():
		_open_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, PackedStringArray(["*.scenespec ; Canonical JSON", "*.scenespec.mp ; MessagePack", "*.simviz ; SimViz Bundle"]), "save_file")
	else:
		doc_store.save_to_file(doc_store.file_path)

func _duplicate_element(eid: String) -> void:
	doc_store.duplicate_element(eid)
	if _canvas_2d != null: _canvas_2d.rebuild_blocks()
	if _viewport_3d != null: _viewport_3d.rebuild_3d_scene()

func _delete_element(eid: String) -> void:
	doc_store.remove_element(eid)
	if _canvas_2d != null: _canvas_2d.rebuild_blocks()
	if _viewport_3d != null: _viewport_3d.rebuild_3d_scene()

func _on_floating_properties_requested(elem_id: String, screen_pos: Vector2 = Vector2.ZERO) -> void:
	if doc_store != null:
		var elem = doc_store.get_element(elem_id)
		if elem != null and elem.kind in ["chart_station", "scope_2d", "digital_meter", "histogram_sink", "state_space_3d", "xy_scatter"]:
			if _plot_studio != null:
				_plot_studio.open_for_element(elem_id)
				if _btn_plots != null:
					_btn_plots.modulate = ACCENT
			return

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
		elif event.ctrl_pressed and event.keycode == KEY_S:
			_on_save_clicked()
			get_viewport().set_input_as_handled()
		elif event.ctrl_pressed and event.keycode == KEY_O:
			_request_action_guarded({"action": "open_file"})
			get_viewport().set_input_as_handled()
		elif event.ctrl_pressed and event.keycode == KEY_N:
			_request_action_guarded({"action": "new_scene"})
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F2:
			if _inspector_panel != null:
				_inspector_panel.focus_name_input()
				get_viewport().set_input_as_handled()

func _check_startup_recovery() -> void:
	if doc_store == null:
		return
	var rec := doc_store.check_recovery_available(doc_store.file_path)
	if rec.get("available", false):
		_on_recovery_detected(rec)

func load_starter_demo_model() -> void:
	if doc_store == null or catalog == null or doc_store.active_document == null:
		return
	if not doc_store.active_document.elements.is_empty():
		return

	# Pre-configured demonstration manufacturing line
	var src = catalog.create_element_instance("source", "src_infeed", Vector2(4.0, 6.0))
	var q = catalog.create_element_instance("queue", "q_staging", Vector2(13.0, 6.0))
	var srv = catalog.create_element_instance("server", "srv_assembly", Vector2(22.0, 6.0))
	var conv = catalog.create_element_instance("conveyor", "conv_outfeed", Vector2(31.0, 6.0))
	var snk = catalog.create_element_instance("sink", "snk_discharge", Vector2(42.0, 6.0))

	# Unified Multi-Port Chart Station (Universal Subplot Instrument)
	var chart_assembly = catalog.create_element_instance("chart_station", "chart_assembly", Vector2(22.0, 15.0))
	chart_assembly.name = "Assembly Cell Telemetry"
	chart_assembly.properties["title"] = "Assembly Cell Telemetry"
	chart_assembly.properties["grid_columns"] = 2
	chart_assembly.properties["grid_rows"] = 1
	chart_assembly.properties["subplots"] = [
		{
			"id": "sp_1",
			"port_id": "P1",
			"title": "Buffer Queue Length",
			"type": "time_series",
			"y_label": "items",
			"autoscale": true,
			"grid": {"col": 0, "row": 0, "col_span": 1, "row_span": 1},
			"mode": "overlay",
			"signals": []
		},
		{
			"id": "sp_2",
			"port_id": "P2",
			"title": "Station Duty Cycle",
			"type": "digital_gauge",
			"y_label": "%",
			"autoscale": true,
			"grid": {"col": 1, "row": 0, "col_span": 1, "row_span": 1},
			"mode": "overlay",
			"signals": []
		}
	]
	var p2 := SceneTypes.ScenePort.new()
	p2.id = "P2"
	p2.kind = "signal"
	p2.direction = "input"
	p2.cardinality = "many"
	p2.name = "Port 2 (Subplot 2)"
	chart_assembly.input_ports.append(p2)

	doc_store.add_element(src)
	doc_store.add_element(q)
	doc_store.add_element(srv)
	doc_store.add_element(conv)
	doc_store.add_element(snk)
	doc_store.add_element(chart_assembly)

	# Material flow connections
	doc_store.add_connection_direct("c_in", "src_infeed", "flow_out", "q_staging", "flow_in")
	doc_store.add_connection_direct("c_feed", "q_staging", "flow_out", "srv_assembly", "flow_in")
	doc_store.add_connection_direct("c_conv", "srv_assembly", "flow_out", "conv_outfeed", "flow_in")
	doc_store.add_connection_direct("c_exit", "conv_outfeed", "flow_out", "snk_discharge", "flow_in")

	# Signal connections to Multi-Port Chart Station
	doc_store.add_connection_direct("sig_chart_p1", "q_staging", "length", "chart_assembly", "P1", "signal")
	doc_store.add_connection_direct("sig_chart_p2", "srv_assembly", "utilization", "chart_assembly", "P2", "signal")

	doc_store.is_dirty = false
	if _canvas_2d != null:
		_canvas_2d.rebuild_blocks()
		_canvas_2d.call_deferred("frame_all")
	if _viewport_3d != null:
		_viewport_3d.rebuild_3d_scene()
		_viewport_3d.call_deferred("frame_scene")

func _on_autosave_completed(_path: String, _time: float) -> void:
	if _autosave_status_label != null:
		_autosave_status_label.text = "● Autosaved"
		_autosave_status_label.add_theme_color_override("font_color", Color("#52c7a5"))

func _on_recovery_detected(info: Dictionary) -> void:
	if _autosave_dialog != null:
		_autosave_dialog.set_recovery_info(info)
		_autosave_dialog.popup_centered()

func _refresh_recent_menu() -> void:
	if _recent_menu == null or doc_store == null or doc_store.repository == null:
		return
	_recent_menu.clear()
	var recents: Array = doc_store.repository.get_recent_scenes()
	if recents.is_empty():
		_recent_menu.add_item("No Recent Projects")
		_recent_menu.set_item_disabled(0, true)
	else:
		for i in range(recents.size()):
			var r: Dictionary = recents[i]
			var name_str := str(r.get("name", "Scene"))
			var path_str := str(r.get("path", ""))
			var fmt := str(r.get("format_type", ""))
			_recent_menu.add_item("%s [%s]" % [name_str, fmt], i)
			_recent_menu.set_item_tooltip(i, path_str)

func _on_recent_item_pressed(idx: int) -> void:
	if doc_store == null or doc_store.repository == null:
		return
	var recents: Array = doc_store.repository.get_recent_scenes()
	if idx >= 0 and idx < recents.size():
		var path: String = str(recents[idx].get("path", ""))
		var name_str: String = str(recents[idx].get("name", path.get_file()))
		if not path.is_empty():
			_request_action_guarded({"action": "open_recent", "path": path, "target_name": name_str})

func _open_file_dialog(mode: FileDialog.FileMode, filters: PackedStringArray, action: String) -> void:
	_file_dialog_action = action
	_file_dialog.file_mode = mode
	_file_dialog.filters = filters
	_file_dialog.popup_centered(Vector2i(700, 500))

func _on_file_dialog_canceled() -> void:
	_after_save_action.clear()

func _on_file_selected(path: String) -> void:
	match _file_dialog_action:
		"open_file":
			doc_store.load_from_file(path)
		"save_file":
			var ok := doc_store.save_to_file(path)
			if ok and not _after_save_action.is_empty():
				var action_data := _after_save_action.duplicate()
				_after_save_action.clear()
				_execute_guarded_action(action_data)
		"export_json":
			doc_store.save_to_file(path, "canonical_json")
		"export_msgpack":
			doc_store.save_to_file(path, "msgpack")
		"import_merge":
			_handle_import_merge(path)

func _on_dir_selected(dir_path: String) -> void:
	match _file_dialog_action:
		"open_bundle":
			doc_store.load_from_bundle(dir_path)
		"export_bundle":
			doc_store.save_to_bundle(dir_path, true)

func _handle_import_merge(path: String) -> void:
	var codec := SceneCodec.new()
	var candidate: SceneTypes.SceneDocument = null
	if path.ends_with(".mp") or path.ends_with(".scenespec.mp"):
		candidate = codec.load_from_msgpack_file(path)
	elif path.ends_with(".simviz") or DirAccess.dir_exists_absolute(path):
		var root_f := path.path_join("graph/root.scenespec")
		if not FileAccess.file_exists(root_f): root_f = path.path_join("root.scenespec")
		if FileAccess.file_exists(root_f):
			var f := FileAccess.open(root_f, FileAccess.READ)
			if f != null:
				candidate = codec.load_document(f.get_as_text())
				f.close()
	else:
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			candidate = codec.load_document(f.get_as_text())
			f.close()

	if candidate == null:
		return

	_pending_import_path = path
	_pending_import_doc = candidate
	var diff: Dictionary = SceneDiff.diff_documents(doc_store.active_document, candidate)
	_diff_dialog.set_diff(diff)
	_diff_dialog.popup_centered()

func _on_diff_dialog_confirmed(replace: bool) -> void:
	if replace:
		doc_store.load_from_file(_pending_import_path)
	else:
		doc_store.merge_document(_pending_import_doc, Vector3(10.0, 0.0, 0.0))
		if _canvas_2d != null: _canvas_2d.rebuild_blocks()
		if _viewport_3d != null: _viewport_3d.rebuild_3d_scene()

func _on_file_menu_id_pressed(id: int) -> void:
	match id:
		1:
			_request_action_guarded({"action": "new_scene"})
		2:
			_request_action_guarded({"action": "open_file"})
		3:
			_request_action_guarded({"action": "open_bundle"})
		10:
			_on_save_clicked()
		11:
			_open_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, PackedStringArray(["*.scenespec ; Canonical JSON", "*.scenespec.mp ; MessagePack", "*.simviz ; SimViz Bundle"]), "save_file")
		20:
			_open_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, PackedStringArray(["*.scenespec, *.json ; Canonical SceneSpec JSON"]), "export_json")
		21:
			_open_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, PackedStringArray(["*.scenespec.mp, *.mp ; Binary MessagePack"]), "export_msgpack")
		22:
			_open_file_dialog(FileDialog.FILE_MODE_OPEN_DIR, PackedStringArray(["* ; SimViz Bundle Directory"]), "export_bundle")
		30:
			_open_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, PackedStringArray(["*.scenespec, *.json ; SceneSpec JSON", "*.scenespec.mp, *.mp ; MessagePack"]), "import_merge")

func _request_action_guarded(action_data: Dictionary) -> void:
	if doc_store != null and doc_store.is_dirty:
		var scene_name: String = "Untitled Scene"
		if doc_store.active_document != null and doc_store.active_document.scene.has("name"):
			scene_name = str(doc_store.active_document.scene.get("name", "Untitled Scene"))
		if not doc_store.file_path.is_empty():
			scene_name = doc_store.file_path.get_file()
		_unsaved_dialog.prompt_unsaved(scene_name, action_data)
	else:
		_execute_guarded_action(action_data)

func _execute_guarded_action(action_data: Dictionary) -> void:
	var action: String = str(action_data.get("action", ""))
	match action:
		"new_scene":
			doc_store.new_document()
		"open_file":
			_open_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, PackedStringArray(["*.scenespec, *.json ; SceneSpec Files", "*.scenespec.mp, *.mp ; MessagePack Files", "*.* ; All Files"]), "open_file")
		"open_bundle":
			_open_file_dialog(FileDialog.FILE_MODE_OPEN_DIR, PackedStringArray(["* ; Directories"]), "open_bundle")
		"open_recent":
			var path: String = str(action_data.get("path", ""))
			if not path.is_empty():
				doc_store.load_from_file(path)
		"quit":
			get_tree().quit()

func _on_unsaved_save_confirmed(action_context: Dictionary) -> void:
	if doc_store == null:
		return
	if doc_store.file_path.is_empty():
		_after_save_action = action_context.duplicate()
		_open_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, PackedStringArray(["*.scenespec ; Canonical JSON", "*.scenespec.mp ; MessagePack", "*.simviz ; SimViz Bundle"]), "save_file")
	else:
		var ok := doc_store.save_to_file(doc_store.file_path)
		if ok:
			_execute_guarded_action(action_context)

func _on_unsaved_discard_confirmed(action_context: Dictionary) -> void:
	_execute_guarded_action(action_context)

func _on_unsaved_action_canceled(_action_context: Dictionary) -> void:
	_after_save_action.clear()



