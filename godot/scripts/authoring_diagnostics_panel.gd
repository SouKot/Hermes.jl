# authoring_diagnostics_panel.gd
# Real-time diagnostics list with severity badges, element focus, and suggested fix execution.
class_name SimVizAuthoringDiagnosticsPanel
extends PanelContainer

signal diagnostic_focused(element_id: String)
signal fix_requested(diagnostic: Dictionary)

const BG := Color("#121b27")
const BORDER := Color("#26384b")
const TEXT := Color("#e5edf5")
const MUTED := Color("#8da2b5")
const ERR_COLOR := Color("#e74c3c")
const WARN_COLOR := Color("#f39c12")
const INFO_COLOR := Color("#3498db")
const SUCCESS_COLOR := Color("#2ecc71")

var _header_label: Label
var _status_badge: Label
var _item_container: VBoxContainer
var _empty_label: Label

func _init() -> void:
	custom_minimum_size = Vector2(280, 160)
	var style := StyleBoxFlat.new()
	style.bg_color = BG
	style.border_color = BORDER
	style.set_border_width_all(1)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	add_theme_stylebox_override("panel", style)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# Header bar
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)

	_header_label = Label.new()
	_header_label.text = "DIAGNOSTICS"
	_header_label.add_theme_font_size_override("font_size", 12)
	_header_label.add_theme_color_override("font_color", TEXT)
	_header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_header_label)

	_status_badge = Label.new()
	_status_badge.text = "● 0 ERRORS"
	_status_badge.add_theme_font_size_override("font_size", 11)
	_status_badge.add_theme_color_override("font_color", SUCCESS_COLOR)
	header.add_child(_status_badge)

	# Scrollable diagnostic list
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	_item_container = VBoxContainer.new()
	_item_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_item_container.add_theme_constant_override("separation", 4)
	scroll.add_child(_item_container)

	_empty_label = Label.new()
	_empty_label.text = "No validation issues found.\nSceneSpec is fully valid."
	_empty_label.add_theme_font_size_override("font_size", 11)
	_empty_label.add_theme_color_override("font_color", MUTED)
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_item_container.add_child(_empty_label)

func update_diagnostics(diagnostics: Array, is_valid: bool) -> void:
	for child in _item_container.get_children():
		child.queue_free()

	if diagnostics.is_empty():
		_status_badge.text = "● VALID"
		_status_badge.add_theme_color_override("font_color", SUCCESS_COLOR)
		var ok_lbl := Label.new()
		ok_lbl.text = "All semantic rules passed.\nZero errors."
		ok_lbl.add_theme_font_size_override("font_size", 11)
		ok_lbl.add_theme_color_override("font_color", MUTED)
		ok_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_item_container.add_child(ok_lbl)
		return

	var err_count := 0
	var warn_count := 0

	for d_var in diagnostics:
		var diag: Dictionary = d_var if d_var is Dictionary else {}
		var sev: String = str(diag.get("severity", "error")).to_lower()
		if sev == "error":
			err_count += 1
		else:
			warn_count += 1
		_item_container.add_child(_create_diagnostic_row(diag))

	if err_count > 0:
		_status_badge.text = "● %d ERRORS, %d WARN" % [err_count, warn_count]
		_status_badge.add_theme_color_override("font_color", ERR_COLOR)
	else:
		_status_badge.text = "● %d WARNINGS" % [warn_count]
		_status_badge.add_theme_color_override("font_color", WARN_COLOR)

func _create_diagnostic_row(diag: Dictionary) -> Control:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#172333")
	style.border_color = Color("#26384b")
	style.set_border_width_all(1)
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	card.add_theme_stylebox_override("panel", style)

	var row_v := VBoxContainer.new()
	row_v.add_theme_constant_override("separation", 2)
	card.add_child(row_v)

	var top_row := HBoxContainer.new()
	row_v.add_child(top_row)

	var sev: String = str(diag.get("severity", "error")).to_lower()
	var sev_color := ERR_COLOR if sev == "error" else (WARN_COLOR if sev == "warning" else INFO_COLOR)

	var badge := Label.new()
	badge.text = "[%s]" % sev.to_upper()
	badge.add_theme_font_size_override("font_size", 10)
	badge.add_theme_color_override("font_color", sev_color)
	top_row.add_child(badge)

	var rule_lbl := Label.new()
	rule_lbl.text = str(diag.get("rule_id", "DIAG"))
	rule_lbl.add_theme_font_size_override("font_size", 10)
	rule_lbl.add_theme_color_override("font_color", TEXT)
	rule_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(rule_lbl)

	var target_elem: String = str(diag.get("element", diag.get("source_id", "")))
	if not target_elem.is_empty():
		var btn_focus := Button.new()
		btn_focus.text = "Focus"
		btn_focus.add_theme_font_size_override("font_size", 9)
		btn_focus.pressed.connect(func(): diagnostic_focused.emit(target_elem))
		top_row.add_child(btn_focus)

	var msg_lbl := Label.new()
	msg_lbl.text = str(diag.get("message", ""))
	msg_lbl.add_theme_font_size_override("font_size", 10)
	msg_lbl.add_theme_color_override("font_color", MUTED)
	msg_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row_v.add_child(msg_lbl)

	var fix: String = str(diag.get("suggested_fix", ""))
	if not fix.is_empty():
		var fix_row := HBoxContainer.new()
		row_v.add_child(fix_row)

		var fix_lbl := Label.new()
		fix_lbl.text = "Suggested: " + fix
		fix_lbl.add_theme_font_size_override("font_size", 9)
		fix_lbl.add_theme_color_override("font_color", SUCCESS_COLOR)
		fix_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fix_row.add_child(fix_lbl)

		var fix_btn := Button.new()
		fix_btn.text = "Fix"
		fix_btn.add_theme_font_size_override("font_size", 9)
		fix_btn.pressed.connect(func(): fix_requested.emit(diag))
		fix_row.add_child(fix_btn)

	return card

