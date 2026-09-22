# authoring_rule_builder.gd
# No-code condition and routing rule builder with compatible metric browser for SceneSpec connections.
class_name SimVizAuthoringRuleBuilder
extends PanelContainer

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")

signal rule_saved(conn_id: String, condition: Dictionary)
signal closed()

const PANEL_BG := Color("#131d2a")
const SECTION_BG := Color("#182333")
const BORDER := Color("#243347")
const TEXT := Color("#e2e8f0")
const MUTED := Color("#94a3b8")
const ACCENT := Color("#52c7a5")
const LIVE_COLOR := Color("#2ecc71")
const METRIC_COLOR := Color("#9b59b6")

var doc_store: DocumentStore
var current_conn_id: String = ""

var _container: VBoxContainer
var _metric_btn: Button
var _op_opt: OptionButton
var _thresh_spin: SpinBox
var _unit_lbl: Label
var _metrics_list: VBoxContainer

var _active_metric: String = "queue_01.occupancy"
var _active_unit: String = "%"

func _init(p_store: DocumentStore = null) -> void:
	doc_store = p_store
	custom_minimum_size = Vector2(340, 420)
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	add_theme_stylebox_override("panel", style)

	_container = VBoxContainer.new()
	_container.add_theme_constant_override("separation", 10)
	add_child(_container)

	_build_ui()

func open_for_connection(conn_id: String) -> void:
	current_conn_id = conn_id
	var conn: SceneTypes.SceneConnection = _find_connection(conn_id)
	if conn != null and conn.condition is Dictionary and not conn.condition.is_empty():
		_active_metric = str(conn.condition.get("metric", "queue_01.occupancy"))
		_active_unit = str(conn.condition.get("unit", ""))
		var op_str: String = str(conn.condition.get("operator", ">="))
		var thresh_val: float = float(conn.condition.get("threshold", 80.0))
		_set_operator_selection(op_str)
		_thresh_spin.value = thresh_val
	else:
		_active_metric = _discover_default_metric()
		_active_unit = "%"
		_thresh_spin.value = 80.0
		_set_operator_selection(">=")

	_metric_btn.text = _active_metric
	_unit_lbl.text = _active_unit
	_refresh_metric_browser()
	visible = true

func _find_connection(conn_id: String) -> SceneTypes.SceneConnection:
	if doc_store == null or doc_store.active_document == null:
		return null
	for c in doc_store.active_document.connections:
		if c.id == conn_id:
			return c
	return null

func _build_ui() -> void:
	# 1. Header
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "ROUTING RULE BUILDER"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", TEXT)
	header.add_child(title)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(22, 20)
	close_btn.add_theme_font_size_override("font_size", 10)
	close_btn.pressed.connect(func():
		visible = false
		closed.emit()
	)
	header.add_child(close_btn)
	_container.add_child(header)

	_container.add_child(HSeparator.new())

	# 2. Expression Builder Row
	var expr_box := VBoxContainer.new()
	expr_box.add_theme_constant_override("separation", 6)

	var if_lbl := Label.new()
	if_lbl.text = "IF CONDITION IS MET:"
	if_lbl.add_theme_font_size_override("font_size", 10)
	if_lbl.add_theme_color_override("font_color", MUTED)
	expr_box.add_child(if_lbl)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	# Metric selector button
	_metric_btn = Button.new()
	_metric_btn.text = _active_metric
	_metric_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_metric_btn.add_theme_font_size_override("font_size", 10)
	_metric_btn.add_theme_color_override("font_color", METRIC_COLOR)
	row.add_child(_metric_btn)

	# Operator OptionButton
	_op_opt = OptionButton.new()
	_op_opt.add_item(">=", 0)
	_op_opt.add_item(">", 1)
	_op_opt.add_item("<=", 2)
	_op_opt.add_item("<", 3)
	_op_opt.add_item("==", 4)
	_op_opt.add_item("!=", 5)
	_op_opt.add_theme_font_size_override("font_size", 10)
	row.add_child(_op_opt)

	# Threshold SpinBox
	_thresh_spin = SpinBox.new()
	_thresh_spin.min_value = 0.0
	_thresh_spin.max_value = 10000.0
	_thresh_spin.step = 1.0
	_thresh_spin.value = 80.0
	_thresh_spin.custom_minimum_size.x = 70
	_thresh_spin.add_theme_font_size_override("font_size", 10)
	row.add_child(_thresh_spin)

	_unit_lbl = Label.new()
	_unit_lbl.text = "%"
	_unit_lbl.add_theme_font_size_override("font_size", 10)
	_unit_lbl.add_theme_color_override("font_color", MUTED)
	row.add_child(_unit_lbl)

	expr_box.add_child(row)
	_container.add_child(expr_box)

	_container.add_child(HSeparator.new())

	# 3. Compatible Metric Browser
	var br_lbl := Label.new()
	br_lbl.text = "DISCOVERED SCENE METRICS"
	br_lbl.add_theme_font_size_override("font_size", 10)
	br_lbl.add_theme_color_override("font_color", MUTED)
	_container.add_child(br_lbl)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 160
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_metrics_list = VBoxContainer.new()
	_metrics_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_metrics_list.add_theme_constant_override("separation", 3)
	scroll.add_child(_metrics_list)
	_container.add_child(scroll)

	_container.add_child(HSeparator.new())

	# 4. Action Buttons
	var act_row := HBoxContainer.new()
	act_row.add_theme_constant_override("separation", 6)

	var clear_btn := Button.new()
	clear_btn.text = "Unconditional (Clear)"
	clear_btn.add_theme_font_size_override("font_size", 10)
	clear_btn.pressed.connect(_on_clear_clicked)
	act_row.add_child(clear_btn)

	var save_btn := Button.new()
	save_btn.text = "Save Rule"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.add_theme_font_size_override("font_size", 10)
	save_btn.add_theme_color_override("font_color", ACCENT)
	save_btn.pressed.connect(_on_save_clicked)
	act_row.add_child(save_btn)

	_container.add_child(act_row)

func _set_operator_selection(op: String) -> void:
	match op:
		">=": _op_opt.select(0)
		">": _op_opt.select(1)
		"<=": _op_opt.select(2)
		"<": _op_opt.select(3)
		"==": _op_opt.select(4)
		"!=": _op_opt.select(5)
		_: _op_opt.select(0)

func _get_selected_operator() -> String:
	match _op_opt.selected:
		0: return ">="
		1: return ">"
		2: return "<="
		3: return "<"
		4: return "=="
		5: return "!="
	return ">="

func _discover_default_metric() -> String:
	var metrics := get_available_metrics()
	if not metrics.is_empty():
		return metrics[0]["id"]
	return "queue_01.occupancy"

func get_available_metrics() -> Array:
	var res: Array = []
	if doc_store == null or doc_store.active_document == null:
		return res

	for elem in doc_store.active_document.elements:
		# Check metric_ports
		for p in elem.metric_ports:
			var m_id := "%s.%s" % [elem.id, p.id]
			res.append({
				"id": m_id,
				"elem_id": elem.id,
				"port_id": p.id,
				"name": p.name if not p.name.is_empty() else p.id,
				"unit": p.unit if not p.unit.is_empty() else "%"
			})
		# Check output ports of kind metric
		for p in elem.output_ports:
			if p.kind == "metric":
				var m_id := "%s.%s" % [elem.id, p.id]
				res.append({
					"id": m_id,
					"elem_id": elem.id,
					"port_id": p.id,
					"name": p.name if not p.name.is_empty() else p.id,
					"unit": p.unit if not p.unit.is_empty() else "%"
				})
	return res

func _refresh_metric_browser() -> void:
	for c in _metrics_list.get_children():
		c.queue_free()

	var metrics := get_available_metrics()
	if metrics.is_empty():
		var lbl := Label.new()
		lbl.text = "No metric ports discovered in document."
		lbl.add_theme_font_size_override("font_size", 9)
		lbl.add_theme_color_override("font_color", MUTED)
		_metrics_list.add_child(lbl)
		return

	for m in metrics:
		var btn := Button.new()
		btn.text = "%s (%s)" % [m["id"], m["name"]]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 9)
		btn.add_theme_color_override("font_color", METRIC_COLOR)
		var m_id: String = m["id"]
		var m_unit: String = m["unit"]
		btn.pressed.connect(func():
			_active_metric = m_id
			_active_unit = m_unit
			_metric_btn.text = _active_metric
			_unit_lbl.text = _active_unit
		)
		_metrics_list.add_child(btn)

func _on_save_clicked() -> void:
	if current_conn_id.is_empty() or doc_store == null:
		return
	var cond: Dictionary = {
		"metric": _active_metric,
		"operator": _get_selected_operator(),
		"threshold": _thresh_spin.value,
		"unit": _active_unit
	}
	doc_store.update_connection_condition(current_conn_id, cond)
	rule_saved.emit(current_conn_id, cond)
	visible = false
	closed.emit()

func _on_clear_clicked() -> void:
	if current_conn_id.is_empty() or doc_store == null:
		return
	doc_store.update_connection_condition(current_conn_id, {})
	rule_saved.emit(current_conn_id, {})
	visible = false
	closed.emit()

