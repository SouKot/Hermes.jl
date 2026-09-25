# authoring_rule_panel.gd
# Inline rule editor panel — plugged into the inspector for Queue/Server/Connection elements.
extends VBoxContainer

signal rule_changed(element_id: String, property_path: String, value)

const DISCIPLINE_OPTIONS := ["FIFO", "LIFO", "Priority (HOL)", "EDD", "SPT"]
const DISCIPLINE_VALUES  := ["fifo", "lifo", "priority", "edd", "spt"]
const ROUTING_OPTIONS    := ["Fixed", "Probabilistic", "Shortest Queue", "Round Robin"]
const ROUTING_VALUES     := ["fixed", "prob", "shortest_queue", "round_robin"]

var _element_id: String = ""
var _kind: String = ""  # "queue", "server", "connection"

var _discipline_row: HBoxContainer = null
var _discipline_option: OptionButton = null
var _routing_row: HBoxContainer = null
var _routing_option: OptionButton = null

func _ready() -> void:
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
	_element_id = element_id
	_kind = kind

	# Show/hide rows based on element kind
	_discipline_row.visible = (kind == "queue")
	_routing_row.visible = (kind in ["server", "connection"])

	# Set current values from props
	if kind == "queue":
		var disc: String = str(props.get("discipline", "fifo")).to_lower()
		var idx := DISCIPLINE_VALUES.find(disc)
		_discipline_option.selected = max(0, idx)

	if kind in ["server", "connection"]:
		var routing: String = str(props.get("routing_rule", "fixed")).to_lower()
		var idx := ROUTING_VALUES.find(routing)
		_routing_option.selected = max(0, idx)

func _on_discipline_selected(idx: int) -> void:
	if _element_id.is_empty(): return
	rule_changed.emit(_element_id, "discipline", DISCIPLINE_VALUES[idx])

func _on_routing_selected(idx: int) -> void:
	if _element_id.is_empty(): return
	rule_changed.emit(_element_id, "routing_rule", ROUTING_VALUES[idx])
