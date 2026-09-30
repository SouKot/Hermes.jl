# authoring_wire_popup.gd
# Expanded Floating Wire Pop-up (Option 1B) for configuring connection wire shape,
# curvature/corner radius, stroke style, line width, color override, and waypoints.
class_name SimVizAuthoringWirePopup
extends PanelContainer

const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const SceneTypes := preload("res://scripts/scenespec_types.gd")

signal wire_visual_changed(conn_id: String)
signal wire_deleted(conn_id: String)

const SHAPE_MODES: Array[String] = ["auto", "bezier", "orthogonal", "chamfer", "straight"]
const SHAPE_LABELS: Dictionary = {
	"auto": "Auto",
	"bezier": "∿ Curved",
	"orthogonal": "90° Ortho",
	"chamfer": "∠ 45°",
	"straight": "╱ Straight"
}

const STROKE_MODES: Array[String] = ["auto", "solid", "dashed", "dotted"]
const STROKE_LABELS: Array[String] = ["Auto (Port Default)", "Solid", "Dashed", "Dotted"]

var doc_store: DocumentStore = null
var current_conn_id: String = ""
var _is_syncing: bool = false

var _title_label: Label = null
var _subtitle_label: Label = null
var _shape_buttons: Dictionary = {} # mode_str -> Button
var _slider_title_label: Label = null
var _slider_value_label: Label = null
var _radius_slider: HSlider = null
var _stroke_opt: OptionButton = null
var _width_spin: SpinBox = null
var _color_picker: ColorPickerButton = null
var _color_hex_label: Label = null
var _btn_reset_color: Button = null
var _waypoints_label: Label = null
var _btn_reset_waypoints: Button = null
var _btn_delete_conn: Button = null

func _init() -> void:
	visible = false
	z_index = 62
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(320, 230)

	var style := StyleBoxFlat.new()
	style.bg_color = Color("#0f1823f5")
	style.border_color = Color("#00d2ff")
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 10
	add_theme_stylebox_override("panel", style)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 7)
	add_child(root_vbox)

	# 1. Header Row
	var header_hbox := HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 6)
	root_vbox.add_child(header_hbox)

	var title_vbox := VBoxContainer.new()
	title_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_vbox.add_theme_constant_override("separation", 1)
	header_hbox.add_child(title_vbox)

	_title_label = Label.new()
	_title_label.text = "WIRE SHAPE & APPEARANCE"
	_title_label.add_theme_font_size_override("font_size", 11)
	_title_label.add_theme_color_override("font_color", Color("#52c7a5"))
	title_vbox.add_child(_title_label)

	_subtitle_label = Label.new()
	_subtitle_label.text = ""
	_subtitle_label.add_theme_font_size_override("font_size", 9)
	_subtitle_label.add_theme_color_override("font_color", Color("#94a3b8"))
	title_vbox.add_child(_subtitle_label)

	var btn_close := Button.new()
	btn_close.text = "✕"
	btn_close.flat = true
	btn_close.add_theme_font_size_override("font_size", 11)
	btn_close.pressed.connect(func(): close_popup())
	header_hbox.add_child(btn_close)

	root_vbox.add_child(HSeparator.new())

	# 2. Shape Mode Segmented Buttons
	var shape_lbl := Label.new()
	shape_lbl.text = "Shape Mode"
	shape_lbl.add_theme_font_size_override("font_size", 10)
	shape_lbl.add_theme_color_override("font_color", Color("#e2e8f0"))
	root_vbox.add_child(shape_lbl)

	var shape_hbox := HBoxContainer.new()
	shape_hbox.add_theme_constant_override("separation", 4)
	root_vbox.add_child(shape_hbox)

	for mode_id in SHAPE_MODES:
		var b := Button.new()
		b.text = str(SHAPE_LABELS.get(mode_id, mode_id))
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 9)
		var captured_mode: String = mode_id
		b.pressed.connect(func():
			if _is_syncing:
				return
			set_shape_mode(captured_mode)
		)
		shape_hbox.add_child(b)
		_shape_buttons[mode_id] = b

	# 3. Curvature / Corner Radius Slider
	var slider_hdr := HBoxContainer.new()
	root_vbox.add_child(slider_hdr)

	_slider_title_label = Label.new()
	_slider_title_label.text = "Curvature / Corner Radius"
	_slider_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider_title_label.add_theme_font_size_override("font_size", 10)
	_slider_title_label.add_theme_color_override("font_color", Color("#e2e8f0"))
	slider_hdr.add_child(_slider_title_label)

	_slider_value_label = Label.new()
	_slider_value_label.text = "8 px"
	_slider_value_label.add_theme_font_size_override("font_size", 10)
	_slider_value_label.add_theme_color_override("font_color", Color("#52c7a5"))
	slider_hdr.add_child(_slider_value_label)

	_radius_slider = HSlider.new()
	_radius_slider.min_value = 0.0
	_radius_slider.max_value = 20.0
	_radius_slider.step = 1.0
	_radius_slider.value = 8.0
	_radius_slider.value_changed.connect(func(val: float):
		if _is_syncing:
			return
		set_radius_or_tension(val)
	)
	root_vbox.add_child(_radius_slider)

	# 4. Stroke Style & Width Row
	var stroke_row := HBoxContainer.new()
	stroke_row.add_theme_constant_override("separation", 8)
	root_vbox.add_child(stroke_row)

	var stroke_col := VBoxContainer.new()
	stroke_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stroke_col.add_theme_constant_override("separation", 2)
	stroke_row.add_child(stroke_col)

	var st_lbl := Label.new()
	st_lbl.text = "Stroke Style"
	st_lbl.add_theme_font_size_override("font_size", 10)
	st_lbl.add_theme_color_override("font_color", Color("#e2e8f0"))
	stroke_col.add_child(st_lbl)

	_stroke_opt = OptionButton.new()
	for i in range(STROKE_LABELS.size()):
		_stroke_opt.add_item(STROKE_LABELS[i], i)
	_stroke_opt.add_theme_font_size_override("font_size", 9)
	_stroke_opt.item_selected.connect(func(idx: int):
		if _is_syncing:
			return
		if idx >= 0 and idx < STROKE_MODES.size():
			set_stroke_style(STROKE_MODES[idx])
	)
	stroke_col.add_child(_stroke_opt)

	var width_col := VBoxContainer.new()
	width_col.add_theme_constant_override("separation", 2)
	stroke_row.add_child(width_col)

	var w_lbl := Label.new()
	w_lbl.text = "Width"
	w_lbl.add_theme_font_size_override("font_size", 10)
	w_lbl.add_theme_color_override("font_color", Color("#e2e8f0"))
	width_col.add_child(w_lbl)

	_width_spin = SpinBox.new()
	_width_spin.min_value = 1.5
	_width_spin.max_value = 4.0
	_width_spin.step = 0.5
	_width_spin.value = 2.0
	_width_spin.suffix = "px"
	_width_spin.custom_minimum_size.x = 84
	_width_spin.add_theme_font_size_override("font_size", 9)
	_width_spin.value_changed.connect(func(val: float):
		if _is_syncing:
			return
		set_wire_width(val)
	)
	width_col.add_child(_width_spin)

	# 5. Color Override Row
	var color_row := HBoxContainer.new()
	color_row.add_theme_constant_override("separation", 6)
	root_vbox.add_child(color_row)

	var col_lbl := Label.new()
	col_lbl.text = "Color Override:"
	col_lbl.add_theme_font_size_override("font_size", 10)
	col_lbl.add_theme_color_override("font_color", Color("#e2e8f0"))
	color_row.add_child(col_lbl)

	_color_picker = ColorPickerButton.new()
	_color_picker.custom_minimum_size = Vector2(36, 22)
	_color_picker.edit_alpha = false
	_color_picker.color_changed.connect(func(c: Color):
		if _is_syncing:
			return
		set_color_override("#" + c.to_html(false))
	)
	color_row.add_child(_color_picker)

	_color_hex_label = Label.new()
	_color_hex_label.text = "[Default]"
	_color_hex_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_color_hex_label.add_theme_font_size_override("font_size", 9)
	_color_hex_label.add_theme_color_override("font_color", Color("#94a3b8"))
	color_row.add_child(_color_hex_label)

	_btn_reset_color = Button.new()
	_btn_reset_color.text = "Reset"
	_btn_reset_color.add_theme_font_size_override("font_size", 9)
	_btn_reset_color.pressed.connect(func():
		if _is_syncing:
			return
		set_color_override("")
	)
	color_row.add_child(_btn_reset_color)

	root_vbox.add_child(HSeparator.new())

	# 6. Waypoints & Reset / Delete Footer
	var wp_row := HBoxContainer.new()
	wp_row.add_theme_constant_override("separation", 6)
	root_vbox.add_child(wp_row)

	_waypoints_label = Label.new()
	_waypoints_label.text = "0 active waypoints"
	_waypoints_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_waypoints_label.add_theme_font_size_override("font_size", 9)
	_waypoints_label.add_theme_color_override("font_color", Color("#94a3b8"))
	wp_row.add_child(_waypoints_label)

	_btn_reset_waypoints = Button.new()
	_btn_reset_waypoints.text = "↺ Reset Bends / Waypoints"
	_btn_reset_waypoints.add_theme_font_size_override("font_size", 9)
	_btn_reset_waypoints.pressed.connect(func():
		reset_bends_and_waypoints()
	)
	wp_row.add_child(_btn_reset_waypoints)

	_btn_delete_conn = Button.new()
	_btn_delete_conn.text = "🗑 Delete Connection"
	_btn_delete_conn.add_theme_font_size_override("font_size", 10)
	_btn_delete_conn.add_theme_color_override("font_color", Color("#ff7b72"))
	_btn_delete_conn.pressed.connect(func():
		delete_current_connection()
	)
	root_vbox.add_child(_btn_delete_conn)

func open_for_connection(p_store: DocumentStore, conn_id: String, local_pos: Vector2) -> void:
	doc_store = p_store
	current_conn_id = conn_id
	position = local_pos
	visible = true
	refresh_ui()

func close_popup() -> void:
	if visible:
		visible = false

func set_shape_mode(mode_id: String) -> void:
	if doc_store == null or current_conn_id.is_empty():
		return
	doc_store.update_connection_visual(current_conn_id, {"routing_mode": mode_id}, true)
	refresh_ui()
	wire_visual_changed.emit(current_conn_id)

func set_radius_or_tension(val: float) -> void:
	if doc_store == null or current_conn_id.is_empty():
		return
	doc_store.update_connection_visual(current_conn_id, {"radius_or_tension": clampf(val, 0.0, 20.0)}, true)
	refresh_ui()
	wire_visual_changed.emit(current_conn_id)

func set_stroke_style(style_id: String) -> void:
	if doc_store == null or current_conn_id.is_empty():
		return
	doc_store.update_connection_visual(current_conn_id, {"stroke_style": style_id}, true)
	refresh_ui()
	wire_visual_changed.emit(current_conn_id)

func set_wire_width(w: float) -> void:
	if doc_store == null or current_conn_id.is_empty():
		return
	doc_store.update_connection_visual(current_conn_id, {"width": clampf(w, 1.5, 4.0)}, true)
	refresh_ui()
	wire_visual_changed.emit(current_conn_id)

func set_color_override(hex_col: String) -> void:
	if doc_store == null or current_conn_id.is_empty():
		return
	doc_store.update_connection_visual(current_conn_id, {"color": hex_col}, true)
	refresh_ui()
	wire_visual_changed.emit(current_conn_id)

func reset_bends_and_waypoints() -> void:
	if doc_store == null or current_conn_id.is_empty():
		return
	doc_store.update_connection_visual(current_conn_id, {"waypoints": [], "routing_mode": "auto"}, true)
	refresh_ui()
	wire_visual_changed.emit(current_conn_id)

func delete_current_connection() -> void:
	if doc_store == null or current_conn_id.is_empty():
		return
	var cid := current_conn_id
	close_popup()
	doc_store.remove_connection(cid)
	wire_deleted.emit(cid)

func refresh_ui() -> void:
	if doc_store == null or current_conn_id.is_empty():
		return
	var conn := doc_store.get_connection(current_conn_id)
	if conn == null:
		close_popup()
		return

	_is_syncing = true
	var vis: Dictionary = doc_store.get_connection_visual(current_conn_id)
	var eff_shape: String = doc_store.get_effective_wire_shape(current_conn_id)

	if _subtitle_label != null:
		_subtitle_label.text = "%s (%s.%s → %s.%s)" % [
			conn.id, conn.source_element, conn.source_port, conn.target_element, conn.target_port
		]

	var cur_mode: String = str(vis.get("routing_mode", "auto"))
	for mode_id in _shape_buttons.keys():
		var b: Button = _shape_buttons[mode_id]
		var is_active: bool = (mode_id == cur_mode)
		b.set_pressed_no_signal(is_active)
		b.modulate = Color("#52c7a5") if is_active else Color.WHITE

	var r_val: float = float(vis.get("radius_or_tension", 8.0))
	if _radius_slider != null:
		_radius_slider.set_value_no_signal(r_val)
	if _slider_title_label != null:
		match eff_shape:
			"bezier":
				_slider_title_label.text = "Curvature / Tension"
			"chamfer":
				_slider_title_label.text = "Chamfer Bevel Size"
			_:
				_slider_title_label.text = "Corner Radius"
	if _slider_value_label != null:
		_slider_value_label.text = "%d px" % int(round(r_val))

	var cur_stroke: String = str(vis.get("stroke_style", "auto"))
	var st_idx: int = STROKE_MODES.find(cur_stroke)
	if st_idx < 0:
		st_idx = 0
	if _stroke_opt != null:
		_stroke_opt.selected = st_idx

	var cur_w: float = float(vis.get("width", 2.0))
	if _width_spin != null:
		_width_spin.set_value_no_signal(cur_w)

	var col_str: String = str(vis.get("color", ""))
	var default_col := Color("#2ecc71") if conn.link_type == "flow" else Color("#f39c12")
	if _color_picker != null:
		_color_picker.color = Color.from_string(col_str, default_col) if not col_str.is_empty() else default_col
	if _color_hex_label != null:
		_color_hex_label.text = ("[" + col_str + "]") if not col_str.is_empty() else "[Default]"

	var wps: Array = vis.get("waypoints", [])
	if _waypoints_label != null:
		_waypoints_label.text = "%d active waypoint%s" % [wps.size(), "" if wps.size() == 1 else "s"]

	_is_syncing = false
