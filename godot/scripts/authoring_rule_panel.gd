# authoring_rule_panel.gd
# Inline rule editor panel — plugged into the inspector for Queue/Server/Connection elements.
extends VBoxContainer

signal rule_changed(element_id: String, property_path: String, value)

const DISCIPLINE_OPTIONS := ["FIFO", "LIFO", "Priority (HOL)", "EDD", "SPT", "Custom (Comparator)"]
const DISCIPLINE_VALUES  := ["FIFO", "LIFO", "Priority", "EDD", "SPT", "Custom"]
const ROUTING_OPTIONS    := ["Fixed", "Probabilistic", "Shortest Queue", "Round Robin"]
const ROUTING_VALUES     := ["fixed", "prob", "shortest_queue", "round_robin"]

var _element_id: String = ""
var _kind: String = ""  # "queue", "server", "connection"

var _discipline_row: HBoxContainer = null
var _discipline_option: OptionButton = null
var _custom_disc_box: VBoxContainer = null
var _custom_disc_edit: LineEdit = null
var _routing_row: HBoxContainer = null
var _routing_option: OptionButton = null

func _init() -> void:
	_ensure_rows()

func _ready() -> void:
	_ensure_rows()

func _ensure_rows() -> void:
	if _discipline_row != null:
		return
	add_theme_constant_override("separation", 4)

	# ── Discipline row (for Queue blocks) ────────────────────────────────
	_discipline_row = HBoxContainer.new()
	_discipline_row.add_theme_constant_override("separation", 8)
	var lbl_d := Label.new()
	lbl_d.text = "Discipline:"
	lbl_d.custom_minimum_size.x = 80
	lbl_d.add_theme_font_size_override("font_size", 11)
	_discipline_row.add_child(lbl_d)
	_discipline_option = OptionButton.new()
	_discipline_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_discipline_option.add_theme_font_size_override("font_size", 11)
	for opt in DISCIPLINE_OPTIONS:
		_discipline_option.add_item(opt)
	_discipline_option.item_selected.connect(_on_discipline_selected)
	_discipline_row.add_child(_discipline_option)
	add_child(_discipline_row)

	# ── Custom Comparator Editor (shown when Custom discipline is active) ─
	_custom_disc_box = VBoxContainer.new()
	_custom_disc_box.add_theme_constant_override("separation", 3)
	_custom_disc_box.visible = false
	var lbl_c := Label.new()
	lbl_c.text = "Comparator (a before b):"
	lbl_c.add_theme_font_size_override("font_size", 10)
	lbl_c.add_theme_color_override("font_color", Color("#93c5fd"))
	_custom_disc_box.add_child(lbl_c)
	_custom_disc_edit = LineEdit.new()
	_custom_disc_edit.placeholder_text = "get_attribute(a, \"due_date\", Inf) < get_attribute(b, \"due_date\", Inf)"
	_custom_disc_edit.add_theme_font_size_override("font_size", 10)
	_custom_disc_edit.text_submitted.connect(func(txt: String):
		if not _element_id.is_empty():
			rule_changed.emit(_element_id, "custom_discipline", txt)
	)
	_custom_disc_box.add_child(_custom_disc_edit)
	add_child(_custom_disc_box)

	# ── Routing row (for Server/Connection blocks) ────────────────────────
	_routing_row = HBoxContainer.new()
	_routing_row.add_theme_constant_override("separation", 8)
	var lbl_r := Label.new()
	lbl_r.text = "Routing:"
	lbl_r.custom_minimum_size.x = 80
	lbl_r.add_theme_font_size_override("font_size", 11)
	_routing_row.add_child(lbl_r)
	_routing_option = OptionButton.new()
	_routing_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_routing_option.add_theme_font_size_override("font_size", 11)
	for opt in ROUTING_OPTIONS:
		_routing_option.add_item(opt)
	_routing_option.item_selected.connect(_on_routing_selected)
	_routing_row.add_child(_routing_option)
	add_child(_routing_row)

func configure(element_id: String, kind: String, props: Dictionary) -> void:
	_ensure_rows()
	_element_id = element_id
	_kind = kind

	# Show/hide rows based on element kind
	_discipline_row.visible = (kind == "queue")
	_routing_row.visible = (kind in ["server", "connection"])

	# Set current values from props
	if kind == "queue":
		var disc_raw: String = str(props.get("discipline", "FIFO")).strip_edges().to_lower()
		var idx: int = 0
		for i in range(DISCIPLINE_VALUES.size()):
			if DISCIPLINE_VALUES[i].to_lower() == disc_raw:
				idx = i
				break
		_discipline_option.selected = idx
		_custom_disc_box.visible = (DISCIPLINE_VALUES[idx] == "Custom")
		_custom_disc_edit.text = str(props.get("custom_discipline", ""))
	else:
		_custom_disc_box.visible = false

	if kind in ["server", "connection"]:
		var routing: String = str(props.get("routing_rule", "fixed")).to_lower()
		var idx := ROUTING_VALUES.find(routing)
		_routing_option.selected = max(0, idx)

func _on_discipline_selected(idx: int) -> void:
	if _element_id.is_empty(): return
	var val: String = DISCIPLINE_VALUES[idx]
	if _custom_disc_box != null:
		_custom_disc_box.visible = (val == "Custom")
	rule_changed.emit(_element_id, "discipline", val)

func _on_routing_selected(idx: int) -> void:
	if _element_id.is_empty(): return
	rule_changed.emit(_element_id, "routing_rule", ROUTING_VALUES[idx])

