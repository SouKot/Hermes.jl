# authoring_template_dialog.gd
# Dialog to package selected elements into reusable versioned templates for SceneSpec authoring.
class_name SimVizAuthoringTemplateDialog
extends PanelContainer

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")

signal template_created(template: SceneTypes.SceneSubgraph)
signal closed()

const BG_COLOR := Color("#0e1622")
const PANEL_BG := Color("#15202e")
const BORDER_COLOR := Color("#2a3f55")
const ACCENT_COLOR := Color("#1abc9c")
const TEXT_COLOR := Color("#e5edf5")
const MUTED_COLOR := Color("#8da2b5")

var doc_store: DocumentStore
var _target_element_ids: Array = []

var _name_edit: LineEdit
var _id_edit: LineEdit
var _version_edit: LineEdit
var _desc_edit: TextEdit
var _ports_container: VBoxContainer
var _detected_ports: Array = []

func _init(p_store: DocumentStore = null) -> void:
	doc_store = p_store
	custom_minimum_size = Vector2(460, 420)
	_build_ui()

func _build_ui() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = ACCENT_COLOR
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.shadow_color = Color(0, 0, 0, 0.6)
	style.shadow_size = 12
	add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 12)
	margin.add_child(root_vbox)

	# 1. Title Header
	var header := HBoxContainer.new()
	root_vbox.add_child(header)

	var title_lbl := Label.new()
	title_lbl.text = "📦 Package Selection as Template"
	title_lbl.add_theme_font_size_override("font_size", 14)
	title_lbl.add_theme_color_override("font_color", ACCENT_COLOR)
	header.add_child(title_lbl)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.pressed.connect(func():
		visible = false
		closed.emit()
	)
	header.add_child(close_btn)

	root_vbox.add_child(HSeparator.new())

	# 2. Form Grid
	var form_grid := GridContainer.new()
	form_grid.columns = 2
	form_grid.add_theme_constant_override("h_separation", 12)
	form_grid.add_theme_constant_override("v_separation", 8)
	root_vbox.add_child(form_grid)

	# Template Name
	var name_lbl := Label.new()
	name_lbl.text = "Template Name:"
	name_lbl.add_theme_font_size_override("font_size", 11)
	form_grid.add_child(name_lbl)

	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text = "Custom Workcell"
	_name_edit.text_changed.connect(_on_name_changed)
	form_grid.add_child(_name_edit)

	# Template ID
	var id_lbl := Label.new()
	id_lbl.text = "Template ID:"
	id_lbl.add_theme_font_size_override("font_size", 11)
	form_grid.add_child(id_lbl)

	_id_edit = LineEdit.new()
	_id_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_id_edit.text = "tpl_custom_workcell"
	form_grid.add_child(_id_edit)

	# Version
	var ver_lbl := Label.new()
	ver_lbl.text = "Version:"
	ver_lbl.add_theme_font_size_override("font_size", 11)
	form_grid.add_child(ver_lbl)

	_version_edit = LineEdit.new()
	_version_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_version_edit.text = "1.0.0"
	form_grid.add_child(_version_edit)

	# Description
	var desc_lbl := Label.new()
	desc_lbl.text = "Description:"
	desc_lbl.add_theme_font_size_override("font_size", 11)
	form_grid.add_child(desc_lbl)

	_desc_edit = TextEdit.new()
	_desc_edit.custom_minimum_size.y = 48
	_desc_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_desc_edit.text = "Reusable modular workcell template."
	form_grid.add_child(_desc_edit)

	# 3. Exposed Boundary Ports Preview
	var ports_lbl := Label.new()
	ports_lbl.text = "Exposed Boundary Ports (Visible on Compound Sockets):"
	ports_lbl.add_theme_font_size_override("font_size", 11)
	ports_lbl.add_theme_color_override("font_color", TEXT_COLOR)
	root_vbox.add_child(ports_lbl)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 100
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(scroll)

	_ports_container = VBoxContainer.new()
	_ports_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_ports_container)

	# 4. Action Buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	root_vbox.add_child(btn_row)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func():
		visible = false
		closed.emit()
	)
	btn_row.add_child(cancel_btn)

	var save_btn := Button.new()
	save_btn.text = "✔ Save to Catalog"
	save_btn.add_theme_color_override("font_color", ACCENT_COLOR)
	save_btn.pressed.connect(_on_save_pressed)
	btn_row.add_child(save_btn)

func open_for_selection(element_ids: Array) -> void:
	_target_element_ids = element_ids.duplicate()
	if _target_element_ids.is_empty():
		return

	# Generate default template name from elements
	var def_name := "Workstation"
	if _target_element_ids.size() == 1:
		var elem = doc_store.get_element(_target_element_ids[0])
		if elem != null:
			def_name = "%s Subsystem" % elem.name
	elif _target_element_ids.size() > 1:
		def_name = "Cell with %d Units" % _target_element_ids.size()

	_name_edit.text = def_name
	_id_edit.text = "tpl_" + def_name.to_snake_case()
	_version_edit.text = "1.0.0"
	_desc_edit.text = "Reusable template comprising %d elements." % _target_element_ids.size()

	_populate_ports()
	visible = true

func _on_name_changed(new_name: String) -> void:
	if not new_name.is_empty():
		_id_edit.text = "tpl_" + new_name.to_snake_case()

func _populate_ports() -> void:
	for child in _ports_container.get_children():
		child.queue_free()

	_detected_ports.clear()
	if doc_store == null:
		return

	_detected_ports = doc_store._synthesize_exposed_ports(_target_element_ids)
	if _detected_ports.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No open boundary ports detected."
		empty_lbl.add_theme_color_override("font_color", MUTED_COLOR)
		_ports_container.add_child(empty_lbl)
		return

	for ep in _detected_ports:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var chk := CheckBox.new()
		chk.button_pressed = true
		row.add_child(chk)

		var kind_str: String = ep.get("kind", "flow").to_upper()
		var dir_str: String = ep.get("direction", "input").to_upper()
		var p_name: String = str(ep.get("name", ep.get("id", "")))

		var info_lbl := Label.new()
		info_lbl.text = "[%s %s] %s (%s)" % [kind_str, dir_str, p_name, ep.get("id", "")]
		info_lbl.add_theme_font_size_override("font_size", 10)
		row.add_child(info_lbl)

		_ports_container.add_child(row)

func _on_save_pressed() -> void:
	if doc_store == null:
		return

	var tmpl_id: String = _id_edit.text.strip_edges()
	if tmpl_id.is_empty():
		tmpl_id = "tpl_" + str(Time.get_ticks_msec())
	var tmpl_name: String = _name_edit.text.strip_edges()
	if tmpl_name.is_empty():
		tmpl_name = tmpl_id
	var version: String = _version_edit.text.strip_edges()
	if version.is_empty():
		version = "1.0.0"
	var desc: String = _desc_edit.text.strip_edges()

	var tmpl := doc_store.package_as_template(_target_element_ids, tmpl_id, tmpl_name, version, desc)
	if tmpl != null:
		template_created.emit(tmpl)

	visible = false
	closed.emit()
