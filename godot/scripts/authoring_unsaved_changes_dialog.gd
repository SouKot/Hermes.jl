# authoring_unsaved_changes_dialog.gd
# Compact, in-canvas modal dialog guarding against accidental data loss when creating, opening, or closing scenes with unsaved changes.
class_name SimVizAuthoringUnsavedChangesDialog
extends Control

signal save_confirmed(action_context: Dictionary)
signal discard_confirmed(action_context: Dictionary)
signal action_canceled(action_context: Dictionary)

var title: String = "Save Changes?"

var _backdrop: ColorRect
var _panel: PanelContainer
var _title_label: Label
var _details_label: Label
var _btn_save: Button
var _btn_dont_save: Button
var _btn_cancel: Button
var _btn_close: Button

var _action_context: Dictionary = {}

func _init() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()

func _build_ui() -> void:
	# 1. Semi-transparent backdrop to focus attention and block background input
	_backdrop = ColorRect.new()
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0.04, 0.07, 0.11, 0.65)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)

	# 2. Centered dialog panel
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(490, 180)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color("#141d2b")
	panel_style.border_color = Color("#2c3e55")
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(8)
	panel_style.shadow_color = Color(0, 0, 0, 0.7)
	panel_style.shadow_size = 20
	_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_panel)

	# Margins
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	margin.add_child(vbox)

	# Header (Title + Close Button)
	var header := HBoxContainer.new()
	vbox.add_child(header)

	_title_label = Label.new()
	_title_label.text = "⚠️  " + title
	_title_label.add_theme_font_size_override("font_size", 15)
	_title_label.add_theme_color_override("font_color", Color("#e8f0f8"))
	header.add_child(_title_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_btn_close = Button.new()
	_btn_close.text = "✕"
	_btn_close.flat = true
	_btn_close.add_theme_font_size_override("font_size", 14)
	_btn_close.add_theme_color_override("font_color", Color("#8fa2b5"))
	_btn_close.pressed.connect(_on_cancel_pressed)
	header.add_child(_btn_close)

	# Separator
	var sep := HSeparator.new()
	var sep_style := StyleBoxLine.new()
	sep_style.color = Color("#223043")
	sep.add_theme_stylebox_override("separator", sep_style)
	vbox.add_child(sep)

	# Message Body
	_details_label = Label.new()
	_details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details_label.add_theme_font_size_override("font_size", 13)
	_details_label.add_theme_color_override("font_color", Color("#c4d3e2"))
	_details_label.add_theme_constant_override("line_spacing", 4)
	vbox.add_child(_details_label)

	# Footer Action Buttons
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", 10)
	vbox.add_child(btn_row)

	# Cancel Button
	_btn_cancel = Button.new()
	_btn_cancel.text = "Cancel"
	_btn_cancel.custom_minimum_size = Vector2(85, 32)
	_style_button(_btn_cancel, Color("#1e293b"), Color("#3b4f68"), Color("#8fa2b5"), Color("#ffffff"))
	_btn_cancel.pressed.connect(_on_cancel_pressed)
	btn_row.add_child(_btn_cancel)

	# Don't Save Button
	_btn_dont_save = Button.new()
	_btn_dont_save.text = "Don't Save"
	_btn_dont_save.custom_minimum_size = Vector2(100, 32)
	_style_button(_btn_dont_save, Color("#8b2626"), Color("#b83232"), Color("#ffffff"), Color("#ffdada"))
	_btn_dont_save.pressed.connect(_on_dont_save_pressed)
	btn_row.add_child(_btn_dont_save)

	# Save Button (Primary action)
	_btn_save = Button.new()
	_btn_save.text = "Save"
	_btn_save.custom_minimum_size = Vector2(90, 32)
	_style_button(_btn_save, Color("#168065"), Color("#1abc9c"), Color("#ffffff"), Color("#e0fff7"))
	_btn_save.pressed.connect(_on_save_pressed)
	btn_row.add_child(_btn_save)

func _style_button(btn: Button, bg: Color, border: Color, font_color: Color, font_hover: Color) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = bg
	normal.border_color = border
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(4)

	var hover := StyleBoxFlat.new()
	hover.bg_color = bg.lightened(0.12)
	hover.border_color = border.lightened(0.2)
	hover.set_border_width_all(1)
	hover.set_corner_radius_all(4)

	var pressed := StyleBoxFlat.new()
	pressed.bg_color = bg.darkened(0.15)
	pressed.border_color = border
	pressed.set_border_width_all(1)
	pressed.set_corner_radius_all(4)

	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_color_override("font_color", font_color)
	btn.add_theme_color_override("font_hover_color", font_hover)
	btn.add_theme_font_size_override("font_size", 12)

func prompt_unsaved(scene_name: String, action_context: Dictionary) -> void:
	_action_context = action_context.duplicate()
	var action: String = str(action_context.get("action", ""))
	var action_desc := "proceeding"
	match action:
		"new_scene":
			action_desc = "creating a new blank scene"
		"open_file":
			action_desc = "opening another scene file"
		"open_bundle":
			action_desc = "opening another SimViz bundle"
		"open_recent":
			var target: String = str(action_context.get("target_name", action_context.get("path", "another scene")))
			action_desc = "opening '%s'" % target
		"quit":
			action_desc = "closing SimViz"

	_details_label.text = "Do you want to save the changes made to '%s' before %s?\n\nIf you choose Don't Save, all uncommitted changes since your last save will be discarded." % [scene_name, action_desc]
	visible = true
	move_to_front()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_on_cancel_pressed()
			get_viewport().set_input_as_handled()

func _on_save_pressed() -> void:
	visible = false
	save_confirmed.emit(_action_context)

func _on_dont_save_pressed() -> void:
	visible = false
	discard_confirmed.emit(_action_context)

func _on_cancel_pressed() -> void:
	visible = false
	action_canceled.emit(_action_context)
