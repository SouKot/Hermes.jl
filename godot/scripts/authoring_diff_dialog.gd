# authoring_diff_dialog.gd
# Interactive in-canvas modal dialog for previewing semantic differences before merging or replacing a scene.
class_name SimVizAuthoringDiffDialog
extends Control

signal merge_confirmed(replace: bool)

var title: String = "Scene Import & Merge Comparison"

var _backdrop: ColorRect
var _panel: PanelContainer
var _summary_label: Label
var _details_text: RichTextLabel
var _btn_cancel: Button
var _btn_replace: Button
var _btn_merge: Button
var _btn_close: Button
var _diff_data: Dictionary = {}

func _init() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()

func _build_ui() -> void:
	# 1. Backdrop
	_backdrop = ColorRect.new()
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0.04, 0.07, 0.11, 0.65)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)

	# 2. Centered panel
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(680, 460)
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

	# Header
	var header := HBoxContainer.new()
	vbox.add_child(header)

	var title_lbl := Label.new()
	title_lbl.text = "📊  " + title
	title_lbl.add_theme_font_size_override("font_size", 15)
	title_lbl.add_theme_color_override("font_color", Color("#e8f0f8"))
	header.add_child(title_lbl)

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

	# Summary label
	_summary_label = Label.new()
	_summary_label.add_theme_font_size_override("font_size", 13)
	_summary_label.add_theme_color_override("font_color", Color("#52c7a5"))
	vbox.add_child(_summary_label)

	# Diff details rich text
	var text_panel := PanelContainer.new()
	text_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var text_style := StyleBoxFlat.new()
	text_style.bg_color = Color("#0c121c")
	text_style.border_color = Color("#1e2c3e")
	text_style.set_border_width_all(1)
	text_style.set_corner_radius_all(4)
	text_panel.add_theme_stylebox_override("panel", text_style)

	var text_margin := MarginContainer.new()
	text_margin.add_theme_constant_override("margin_left", 12)
	text_margin.add_theme_constant_override("margin_right", 12)
	text_margin.add_theme_constant_override("margin_top", 10)
	text_margin.add_theme_constant_override("margin_bottom", 10)
	text_panel.add_child(text_margin)

	_details_text = RichTextLabel.new()
	_details_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_details_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details_text.bbcode_enabled = true
	_details_text.focus_mode = Control.FOCUS_NONE
	text_margin.add_child(_details_text)
	vbox.add_child(text_panel)

	# Footer buttons
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", 10)
	vbox.add_child(btn_row)

	_btn_cancel = Button.new()
	_btn_cancel.text = "Cancel"
	_btn_cancel.custom_minimum_size = Vector2(85, 32)
	_style_button(_btn_cancel, Color("#1e293b"), Color("#3b4f68"), Color("#8fa2b5"), Color("#ffffff"))
	_btn_cancel.pressed.connect(_on_cancel_pressed)
	btn_row.add_child(_btn_cancel)

	_btn_replace = Button.new()
	_btn_replace.text = "Replace Entire Scene"
	_btn_replace.custom_minimum_size = Vector2(160, 32)
	_style_button(_btn_replace, Color("#8b2626"), Color("#b83232"), Color("#ffffff"), Color("#ffdada"))
	_btn_replace.pressed.connect(_on_replace_pressed)
	btn_row.add_child(_btn_replace)

	_btn_merge = Button.new()
	_btn_merge.text = "Merge into Scene"
	_btn_merge.custom_minimum_size = Vector2(140, 32)
	_style_button(_btn_merge, Color("#168065"), Color("#1abc9c"), Color("#ffffff"), Color("#e0fff7"))
	_btn_merge.pressed.connect(_on_merge_pressed)
	btn_row.add_child(_btn_merge)

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

func set_diff(diff: Dictionary) -> void:
	_diff_data = diff
	var summary: String = str(diff.get("summary", "No changes detected"))
	_summary_label.text = "Summary: " + summary

	var bbcode := ""
	var elems: Dictionary = diff.get("elements", {})
	var added_e: Array = elems.get("added", [])
	var rem_e: Array = elems.get("removed", [])
	var mod_e: Array = elems.get("modified", [])

	if not added_e.is_empty():
		bbcode += "[color=#4ec9b0][b]Added Elements (%d):[/b][/color]\n" % added_e.size()
		for e in added_e:
			bbcode += "  + [b]%s[/b] (%s)\n" % [e.get("name", e.get("id")), e.get("type_name", "Element")]

	if not rem_e.is_empty():
		bbcode += "[color=#f14c4c][b]Removed Elements (%d):[/b][/color]\n" % rem_e.size()
		for e in rem_e:
			bbcode += "  - [b]%s[/b] (%s)\n" % [e.get("name", e.get("id")), e.get("type_name", "Element")]

	if not mod_e.is_empty():
		bbcode += "[color=#dcdcaa][b]Modified Elements (%d):[/b][/color]\n" % mod_e.size()
		for e in mod_e:
			bbcode += "  ~ [b]%s[/b]: %s\n" % [e.get("name", e.get("id")), "; ".join(e.get("changes", []))]

	var conns: Dictionary = diff.get("connections", {})
	var added_c: Array = conns.get("added", [])
	var rem_c: Array = conns.get("removed", [])
	if not added_c.is_empty():
		bbcode += "[color=#4ec9b0][b]Added Connections (%d):[/b][/color]\n" % added_c.size()
		for c in added_c:
			bbcode += "  + %s -> %s\n" % [c.get("source"), c.get("target")]
	if not rem_c.is_empty():
		bbcode += "[color=#f14c4c][b]Removed Connections (%d):[/b][/color]\n" % rem_c.size()
		for c in rem_c:
			bbcode += "  - %s -> %s\n" % [c.get("source"), c.get("target")]

	var subs: Dictionary = diff.get("subgraphs", {})
	var added_s: Array = subs.get("added", [])
	if not added_s.is_empty():
		bbcode += "[color=#4ec9b0][b]Added Subgraphs (%d):[/b][/color]\n" % added_s.size()
		for s in added_s:
			bbcode += "  + Subgraph [b]%s[/b]\n" % s.get("name", s.get("id"))

	if bbcode.is_empty():
		bbcode = "[color=#808080]Files are semantically identical.[/color]"

	_details_text.text = bbcode

func popup_centered(_minsz: Vector2i = Vector2i.ZERO) -> void:
	visible = true
	move_to_front()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_on_cancel_pressed()
			get_viewport().set_input_as_handled()

func _on_merge_pressed() -> void:
	visible = false
	merge_confirmed.emit(false)

func _on_replace_pressed() -> void:
	visible = false
	merge_confirmed.emit(true)

func _on_cancel_pressed() -> void:
	visible = false
