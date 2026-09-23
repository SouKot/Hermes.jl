# authoring_autosave_dialog.gd
# Compact in-canvas modal dialog prompt shown when an autosaved draft is newer than the saved project.
class_name SimVizAuthoringAutosaveDialog
extends Control

signal recover_selected(autosave_path: String)
signal discard_selected(autosave_path: String)
signal preview_selected(autosave_path: String)

var title: String = "Crash Recovery / Unsaved Work Detected"

var _backdrop: ColorRect
var _panel: PanelContainer
var _info_label: Label
var _preview_button: Button
var _discard_button: Button
var _recover_button: Button
var _close_button: Button
var _recovery_info: Dictionary = {}

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
	_panel.custom_minimum_size = Vector2(540, 240)
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
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	# Header (Title + Close Button)
	var header := HBoxContainer.new()
	vbox.add_child(header)

	var title_lbl := Label.new()
	title_lbl.text = "🛡️  " + title
	title_lbl.add_theme_font_size_override("font_size", 15)
	title_lbl.add_theme_color_override("font_color", Color("#e8f0f8"))
	header.add_child(title_lbl)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_close_button = Button.new()
	_close_button.text = "✕"
	_close_button.flat = true
	_close_button.add_theme_font_size_override("font_size", 14)
	_close_button.add_theme_color_override("font_color", Color("#8fa2b5"))
	_close_button.pressed.connect(_on_discard_pressed)
	header.add_child(_close_button)

	# Separator
	var sep := HSeparator.new()
	var sep_style := StyleBoxLine.new()
	sep_style.color = Color("#223043")
	sep.add_theme_stylebox_override("separator", sep_style)
	vbox.add_child(sep)

	# Explanatory subtitle
	var sub := Label.new()
	sub.text = "An uncommitted autosave was found that is newer than your saved file."
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", Color("#c4d3e2"))
	vbox.add_child(sub)

	# Info card panel
	var card := PanelContainer.new()
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color("#0c121c")
	card_style.border_color = Color("#1e2c3e")
	card_style.set_border_width_all(1)
	card_style.set_corner_radius_all(4)
	card.add_theme_stylebox_override("panel", card_style)

	var card_margin := MarginContainer.new()
	card_margin.add_theme_constant_override("margin_left", 12)
	card_margin.add_theme_constant_override("margin_right", 12)
	card_margin.add_theme_constant_override("margin_top", 10)
	card_margin.add_theme_constant_override("margin_bottom", 10)
	card.add_child(card_margin)

	_info_label = Label.new()
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.add_theme_font_size_override("font_size", 12)
	_info_label.add_theme_color_override("font_color", Color("#9eb1c4"))
	_info_label.add_theme_constant_override("line_spacing", 4)
	card_margin.add_child(_info_label)
	vbox.add_child(card)

	# Footer Action Buttons
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", 10)
	vbox.add_child(btn_row)

	# Preview Diff Button
	_preview_button = Button.new()
	_preview_button.text = "Preview Diff"
	_preview_button.custom_minimum_size = Vector2(105, 32)
	_style_button(_preview_button, Color("#1e293b"), Color("#3b4f68"), Color("#8fa2b5"), Color("#ffffff"))
	_preview_button.pressed.connect(_on_preview_pressed)
	btn_row.add_child(_preview_button)

	# Discard Autosave Button
	_discard_button = Button.new()
	_discard_button.text = "Discard Autosave"
	_discard_button.custom_minimum_size = Vector2(130, 32)
	_style_button(_discard_button, Color("#8b2626"), Color("#b83232"), Color("#ffffff"), Color("#ffdada"))
	_discard_button.pressed.connect(_on_discard_pressed)
	btn_row.add_child(_discard_button)

	# Recover Autosaved Draft Button (Primary action)
	_recover_button = Button.new()
	_recover_button.text = "Recover Autosaved Draft"
	_recover_button.custom_minimum_size = Vector2(175, 32)
	_style_button(_recover_button, Color("#168065"), Color("#1abc9c"), Color("#ffffff"), Color("#e0fff7"))
	_recover_button.pressed.connect(_on_recover_pressed)
	btn_row.add_child(_recover_button)

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

func set_recovery_info(info: Dictionary) -> void:
	_recovery_info = info
	var file_p: String = str(info.get("file_path", "Untitled Scene"))
	var auto_time: int = int(info.get("autosave_time", 0))
	var file_time: int = int(info.get("file_time", 0))
	var elems: int = int(info.get("element_count", 0))

	var auto_dt := Time.get_datetime_dict_from_unix_time(auto_time)
	var file_dt := Time.get_datetime_dict_from_unix_time(file_time)

	var auto_str := "%04d-%02d-%02d %02d:%02d:%02d" % [auto_dt.year, auto_dt.month, auto_dt.day, auto_dt.hour, auto_dt.minute, auto_dt.second]
	var file_str := "%04d-%02d-%02d %02d:%02d:%02d" % [file_dt.year, file_dt.month, file_dt.day, file_dt.hour, file_dt.minute, file_dt.second] if file_time > 0 else "Never saved"

	_info_label.text = "File: %s\n• Last Saved: %s\n• Autosaved:  %s (Newer)\n• Entities in Autosave: %d" % [
		file_p, file_str, auto_str, elems
	]

func popup_centered(_minsz: Vector2i = Vector2i.ZERO) -> void:
	visible = true
	move_to_front()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_on_discard_pressed()
			get_viewport().set_input_as_handled()

func _on_recover_pressed() -> void:
	visible = false
	recover_selected.emit(str(_recovery_info.get("autosave_path", "")))

func _on_discard_pressed() -> void:
	visible = false
	discard_selected.emit(str(_recovery_info.get("autosave_path", "")))

func _on_preview_pressed() -> void:
	visible = false
	preview_selected.emit(str(_recovery_info.get("autosave_path", "")))
