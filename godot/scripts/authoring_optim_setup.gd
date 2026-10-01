# authoring_optim_setup.gd
# Phase 7E-4: Window 1 (⚡ Optimization Setup) & Compact Optimization Progress HUD.
# Provides a 4-tab declarative editor for SceneSpec["optimization"] and a compact
# floating progress window for live asynchronous optimization runs.
class_name SimVizAuthoringOptimSetup
extends Control

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const OSWindowHost := preload("res://scripts/authoring_os_window_host.gd")

signal closed
signal start_optimization_requested(scenespec: Dictionary, open_feedback: bool)
signal stop_optimization_requested
signal apply_solution_requested(candidate_scenespec: Dictionary, rank: int)
signal open_feedback_requested

const BG := Color("#0e1520")
const PANEL := Color("#141d2b")
const PANEL_ALT := Color("#1a2638")
const CARD_BG := Color("#101824")
const BORDER := Color("#2c3e55")
const TEXT := Color("#e8f0f8")
const MUTED := Color("#8fa2b5")
const ACCENT := Color("#52c7a5")
const BLUE := Color("#58a6ff")
const WARNING := Color("#f39c12")
const DANGER := Color("#e74c3c")
const LIVE_GREEN := Color("#2ecc71")

const PROBLEM_CLASSES := ["parameter", "policy", "topology"]
const VAR_TYPES := ["int", "float", "categorical", "policy", "grammar_edge"]
const SENSES := ["minimize", "maximize"]
const CONSTRAINT_KINDS := ["linear_sum", "metric_bound", "spatial_min_distance", "reachability", "no_dead_end"]
const RELATIONS := ["<=", "==", ">="]
const ALGORITHMS := [
	{"id": "eca", "label": "Evolutionary Centers / Adaptive DE (ECA)"},
	{"id": "mixed_ga", "label": "Mixed-Integer / Categorical GA"},
	{"id": "policy_search", "label": "State-Dependent Policy Search"},
	{"id": "bilevel_graph_sa", "label": "Bilevel 3D Graph Simulated Annealing + Spatial"},
	{"id": "exhaustive", "label": "Exhaustive / Smart Structured Grid"},
	{"id": "nelder_mead", "label": "SciML Optim.NelderMead"}
]
const COMMON_METRICS := [
	"expected_wait_time_wq",
	"std_wait_mean",
	"vip_wait_mean",
	"system_sojourn_mean",
	"total_conveyor_length",
	"vip_wait_time_wq",
	"standard_wait_time_wq",
	"max_edge_utilization",
	"total_belt_length",
	"std_wait_across_zones",
	"total_servers",
	"sojourn_mean",
	"throughput_eff",
	"wip_total"
]

var doc_store: DocumentStore = null
var _latest_optim_state: Dictionary = {}

# Two floating windows managed inside this overlay
var _setup_panel: PanelContainer = null
var _progress_panel: PanelContainer = null

# Dragging state for Setup Window
var _dragging_setup: bool = false
var _drag_offset_setup: Vector2 = Vector2.ZERO

# Dragging state for Progress HUD
var _dragging_progress: bool = false
var _drag_offset_progress: Vector2 = Vector2.ZERO

# Setup Window UI Controls
var _lbl_class_badge: Label = null
var _tabs: TabContainer = null

# Tab 0: Model & Variables
var _edit_title: LineEdit = null
var _edit_problem_id: LineEdit = null
var _opt_problem_class: OptionButton = null
var _vars_vbox: VBoxContainer = null
var _btn_add_var: Button = null
var _btn_autodetect_vars: Button = null

# Tab 1: Objective Function
var _opt_primary_sense: OptionButton = null
var _opt_primary_metric: OptionButton = null
var _edit_primary_metric: LineEdit = null
var _edit_obj_desc: LineEdit = null
var _opt_secondary_sense: OptionButton = null
var _edit_secondary_metric: LineEdit = null

# Tab 2: Constraints
var _constraints_vbox: VBoxContainer = null
var _btn_add_constraint: Button = null

# Tab 3: Algorithm & Settings
var _opt_algorithm: OptionButton = null
var _spin_max_evals: SpinBox = null
var _spin_replications: SpinBox = null
var _spin_horizon: SpinBox = null
var _spin_warmup: SpinBox = null
var _check_crn: CheckBox = null
var _spin_top_k: SpinBox = null
var _spin_seed: SpinBox = null

# Action Bar Buttons
var _btn_optimize: Button = null
var _btn_optimize_feedback: Button = null
var _btn_open_report: Button = null

# Compact Progress Window UI Controls
var _lbl_prog_status: Label = null
var _prog_bar: ProgressBar = null
var _lbl_prog_evals: Label = null
var _lbl_prog_best_score: Label = null
var _lbl_prog_best_config: Label = null
var _btn_prog_stop: Button = null
var _btn_prog_report: Button = null
var _btn_prog_apply: Button = null

var _updating_ui: bool = false

func _init(p_store: DocumentStore = null) -> void:
	doc_store = p_store
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = true
	_build_ui()
	if doc_store != null:
		doc_store.document_loaded.connect(_on_doc_loaded)
		doc_store.document_modified.connect(_on_doc_modified)

func _ready() -> void:
	refresh_from_document()

func _box(bg: Color, border_c: Color = BORDER, radius: int = 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border_c
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	return sb

func _build_ui() -> void:
	_build_setup_window()
	_build_progress_window()

func _build_setup_window() -> void:
	_setup_panel = PanelContainer.new()
	_setup_panel.visible = false
	_setup_panel.z_index = 250
	_setup_panel.custom_minimum_size = Vector2(700, 560)
	_setup_panel.size = Vector2(700, 560)
	_setup_panel.position = Vector2(140, 70)
	_setup_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_setup_panel.add_theme_stylebox_override("panel", _box(BG, BORDER, 8))
	add_child(_setup_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.add_child(root)
	_setup_panel.add_child(margin)

	# 1. Draggable Title Bar
	var header := PanelContainer.new()
	header.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 6))
	header.gui_input.connect(_on_setup_header_gui_input)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	var hmargin := MarginContainer.new()
	hmargin.add_theme_constant_override("margin_left", 10)
	hmargin.add_theme_constant_override("margin_right", 10)
	hmargin.add_theme_constant_override("margin_top", 6)
	hmargin.add_theme_constant_override("margin_bottom", 6)
	hmargin.add_child(hbox)
	header.add_child(hmargin)

	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.color = ACCENT
	hbox.add_child(dot)

	var title := Label.new()
	title.text = "⚡ Optimization Setup (SimOptim)"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", TEXT)
	hbox.add_child(title)

	_lbl_class_badge = Label.new()
	_lbl_class_badge.text = "[PARAMETER]"
	_lbl_class_badge.add_theme_font_size_override("font_size", 11)
	_lbl_class_badge.add_theme_color_override("font_color", ACCENT)
	hbox.add_child(_lbl_class_badge)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(sp)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.add_theme_font_size_override("font_size", 12)
	close_btn.add_theme_color_override("font_color", MUTED)
	close_btn.pressed.connect(close_setup)
	hbox.add_child(close_btn)

	root.add_child(header)

	# 2. 4-Tab Container
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_tabs)

	_tabs.add_child(_build_tab_variables())
	_tabs.set_tab_title(0, "🎛 Model & Variables")

	_tabs.add_child(_build_tab_objective())
	_tabs.set_tab_title(1, "🎯 Objective Function")

	_tabs.add_child(_build_tab_constraints())
	_tabs.set_tab_title(2, "🛡 Constraints")

	_tabs.add_child(_build_tab_algorithm())
	_tabs.set_tab_title(3, "⚙ Algorithm & Settings")

	root.add_child(HSeparator.new())

	# 3. Bottom Action Bar
	var action_bar := HBoxContainer.new()
	action_bar.add_theme_constant_override("separation", 10)
	root.add_child(action_bar)

	_btn_optimize = Button.new()
	_btn_optimize.text = "▶ Optimize"
	_btn_optimize.tooltip_text = "Run optimization in the background with a compact progress HUD"
	_btn_optimize.custom_minimum_size = Vector2(145, 34)
	_btn_optimize.add_theme_color_override("font_color", LIVE_GREEN)
	_btn_optimize.pressed.connect(_on_optimize_clicked)
	action_bar.add_child(_btn_optimize)

	_btn_optimize_feedback = Button.new()
	_btn_optimize_feedback.text = "📊 Optimize + Feedback"
	_btn_optimize_feedback.tooltip_text = "Start optimization and immediately open Window 2 (Live Optimization Feedback & Report)"
	_btn_optimize_feedback.custom_minimum_size = Vector2(185, 34)
	_btn_optimize_feedback.add_theme_color_override("font_color", ACCENT)
	_btn_optimize_feedback.pressed.connect(_on_optimize_and_feedback_clicked)
	action_bar.add_child(_btn_optimize_feedback)

	var action_spacer := Control.new()
	action_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_bar.add_child(action_spacer)

	_btn_open_report = Button.new()
	_btn_open_report.text = "📋 Optimization Report"
	_btn_open_report.tooltip_text = "Open Window 2 (Live Optimization Feedback & Top-K Hall of Fame Report)"
	_btn_open_report.custom_minimum_size = Vector2(175, 34)
	_btn_open_report.pressed.connect(func():
		open_feedback_requested.emit()
	)
	action_bar.add_child(_btn_open_report)

func _build_tab_variables() -> Control:
	var scroll := ScrollContainer.new()
	scroll.name = "ModelAndVariables"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	# Problem Identity Row
	var meta_card := PanelContainer.new()
	meta_card.add_theme_stylebox_override("panel", _box(CARD_BG, BORDER, 6))
	var meta_vbox := VBoxContainer.new()
	meta_vbox.add_theme_constant_override("separation", 6)
	var meta_m := MarginContainer.new()
	meta_m.add_theme_constant_override("margin_left", 10)
	meta_m.add_theme_constant_override("margin_right", 10)
	meta_m.add_theme_constant_override("margin_top", 8)
	meta_m.add_theme_constant_override("margin_bottom", 8)
	meta_m.add_child(meta_vbox)
	meta_card.add_child(meta_m)

	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 8)
	var lbl_t := Label.new()
	lbl_t.text = "Problem Title:"
	lbl_t.custom_minimum_size.x = 105
	lbl_t.add_theme_font_size_override("font_size", 11)
	r1.add_child(lbl_t)

	_edit_title = LineEdit.new()
	_edit_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_title.placeholder_text = "e.g., ER Server Allocation"
	_edit_title.text_changed.connect(func(_v: String): _sync_header_fields_to_doc())
	r1.add_child(_edit_title)

	var lbl_c := Label.new()
	lbl_c.text = "Class:"
	lbl_c.add_theme_font_size_override("font_size", 11)
	r1.add_child(lbl_c)

	_opt_problem_class = OptionButton.new()
	for pc in PROBLEM_CLASSES:
		_opt_problem_class.add_item(pc.to_upper())
	_opt_problem_class.item_selected.connect(func(_idx: int): _sync_header_fields_to_doc())
	r1.add_child(_opt_problem_class)
	meta_vbox.add_child(r1)

	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 8)
	var lbl_id := Label.new()
	lbl_id.text = "Problem ID:"
	lbl_id.custom_minimum_size.x = 105
	lbl_id.add_theme_font_size_override("font_size", 11)
	r2.add_child(lbl_id)

	_edit_problem_id = LineEdit.new()
	_edit_problem_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_problem_id.placeholder_text = "custom_optim"
	_edit_problem_id.text_changed.connect(func(_v: String): _sync_header_fields_to_doc())
	r2.add_child(_edit_problem_id)
	meta_vbox.add_child(r2)

	vbox.add_child(meta_card)

	var hdr_row := HBoxContainer.new()
	var hdr_lbl := Label.new()
	hdr_lbl.text = "DECISION VARIABLES & SEARCH BOUNDS"
	hdr_lbl.add_theme_font_size_override("font_size", 11)
	hdr_lbl.add_theme_color_override("font_color", ACCENT)
	hdr_row.add_child(hdr_lbl)
	var hdr_sp := Control.new()
	hdr_sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(hdr_sp)

	_btn_autodetect_vars = Button.new()
	_btn_autodetect_vars.text = "🔍 Auto-Detect from Scene"
	_btn_autodetect_vars.add_theme_font_size_override("font_size", 11)
	_btn_autodetect_vars.pressed.connect(_on_autodetect_variables)
	hdr_row.add_child(_btn_autodetect_vars)

	_btn_add_var = Button.new()
	_btn_add_var.text = "+ Add Variable"
	_btn_add_var.add_theme_font_size_override("font_size", 11)
	_btn_add_var.pressed.connect(_on_add_variable)
	hdr_row.add_child(_btn_add_var)
	vbox.add_child(hdr_row)

	_vars_vbox = VBoxContainer.new()
	_vars_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vars_vbox.add_theme_constant_override("separation", 6)
	vbox.add_child(_vars_vbox)

	return scroll

func _build_tab_objective() -> Control:
	var scroll := ScrollContainer.new()
	scroll.name = "ObjectiveFunction"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	var card1 := PanelContainer.new()
	card1.add_theme_stylebox_override("panel", _box(CARD_BG, BORDER, 6))
	var c1_vbox := VBoxContainer.new()
	c1_vbox.add_theme_constant_override("separation", 8)
	var c1_m := MarginContainer.new()
	c1_m.add_theme_constant_override("margin_left", 12)
	c1_m.add_theme_constant_override("margin_right", 12)
	c1_m.add_theme_constant_override("margin_top", 10)
	c1_m.add_theme_constant_override("margin_bottom", 10)
	c1_m.add_child(c1_vbox)
	card1.add_child(c1_m)

	var t1 := Label.new()
	t1.text = "PRIMARY OBJECTIVE FUNCTION"
	t1.add_theme_font_size_override("font_size", 11)
	t1.add_theme_color_override("font_color", ACCENT)
	c1_vbox.add_child(t1)

	var row_sense := HBoxContainer.new()
	row_sense.add_theme_constant_override("separation", 8)
	var lbl_s := Label.new()
	lbl_s.text = "Optimization Sense:"
	lbl_s.custom_minimum_size.x = 140
	lbl_s.add_theme_font_size_override("font_size", 11)
	row_sense.add_child(lbl_s)

	_opt_primary_sense = OptionButton.new()
	for s in SENSES:
		_opt_primary_sense.add_item(s.to_upper())
	_opt_primary_sense.item_selected.connect(func(_idx: int): _sync_objective_to_doc())
	row_sense.add_child(_opt_primary_sense)
	c1_vbox.add_child(row_sense)

	var row_metric := HBoxContainer.new()
	row_metric.add_theme_constant_override("separation", 8)
	var lbl_m := Label.new()
	lbl_m.text = "Primary KPI Metric:"
	lbl_m.custom_minimum_size.x = 140
	lbl_m.add_theme_font_size_override("font_size", 11)
	row_metric.add_child(lbl_m)

	_opt_primary_metric = OptionButton.new()
	for m in COMMON_METRICS:
		_opt_primary_metric.add_item(m)
	_opt_primary_metric.item_selected.connect(func(idx: int):
		if _edit_primary_metric != null and idx >= 0 and idx < COMMON_METRICS.size():
			_edit_primary_metric.text = COMMON_METRICS[idx]
			_sync_objective_to_doc()
	)
	row_metric.add_child(_opt_primary_metric)

	_edit_primary_metric = LineEdit.new()
	_edit_primary_metric.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_primary_metric.placeholder_text = "expected_wait_time_wq"
	_edit_primary_metric.text_changed.connect(func(_v: String): _sync_objective_to_doc())
	row_metric.add_child(_edit_primary_metric)
	c1_vbox.add_child(row_metric)

	var row_desc := HBoxContainer.new()
	row_desc.add_theme_constant_override("separation", 8)
	var lbl_d := Label.new()
	lbl_d.text = "Description:"
	lbl_d.custom_minimum_size.x = 140
	lbl_d.add_theme_font_size_override("font_size", 11)
	row_desc.add_child(lbl_d)

	_edit_obj_desc = LineEdit.new()
	_edit_obj_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_obj_desc.placeholder_text = "Describe the objective function..."
	_edit_obj_desc.text_changed.connect(func(_v: String): _sync_objective_to_doc())
	row_desc.add_child(_edit_obj_desc)
	c1_vbox.add_child(row_desc)

	vbox.add_child(card1)

	# Secondary / Tie-Breaker Objective Card
	var card2 := PanelContainer.new()
	card2.add_theme_stylebox_override("panel", _box(CARD_BG, BORDER, 6))
	var c2_vbox := VBoxContainer.new()
	c2_vbox.add_theme_constant_override("separation", 8)
	var c2_m := MarginContainer.new()
	c2_m.add_theme_constant_override("margin_left", 12)
	c2_m.add_theme_constant_override("margin_right", 12)
	c2_m.add_theme_constant_override("margin_top", 10)
	c2_m.add_theme_constant_override("margin_bottom", 10)
	c2_m.add_child(c2_vbox)
	card2.add_child(c2_m)

	var t2 := Label.new()
	t2.text = "SECONDARY TIE-BREAKER / PARETO METRIC (OPTIONAL)"
	t2.add_theme_font_size_override("font_size", 11)
	t2.add_theme_color_override("font_color", BLUE)
	c2_vbox.add_child(t2)

	var row_sec := HBoxContainer.new()
	row_sec.add_theme_constant_override("separation", 8)
	var lbl_ss := Label.new()
	lbl_ss.text = "Secondary Metric:"
	lbl_ss.custom_minimum_size.x = 140
	lbl_ss.add_theme_font_size_override("font_size", 11)
	row_sec.add_child(lbl_ss)

	_opt_secondary_sense = OptionButton.new()
	for s in SENSES:
		_opt_secondary_sense.add_item(s.to_upper())
	_opt_secondary_sense.item_selected.connect(func(_idx: int): _sync_objective_to_doc())
	row_sec.add_child(_opt_secondary_sense)

	_edit_secondary_metric = LineEdit.new()
	_edit_secondary_metric.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_secondary_metric.placeholder_text = "e.g., total_belt_length or std_wait_across_zones"
	_edit_secondary_metric.text_changed.connect(func(_v: String): _sync_objective_to_doc())
	row_sec.add_child(_edit_secondary_metric)
	c2_vbox.add_child(row_sec)

	vbox.add_child(card2)
	return scroll

func _build_tab_constraints() -> Control:
	var scroll := ScrollContainer.new()
	scroll.name = "Constraints"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	var hdr_row := HBoxContainer.new()
	var hdr_lbl := Label.new()
	hdr_lbl.text = "RESOURCE BUDGETS, SPATIAL SEPARATION & SLA CONSTRAINTS"
	hdr_lbl.add_theme_font_size_override("font_size", 11)
	hdr_lbl.add_theme_color_override("font_color", ACCENT)
	hdr_row.add_child(hdr_lbl)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(sp)

	_btn_add_constraint = Button.new()
	_btn_add_constraint.text = "+ Add Constraint"
	_btn_add_constraint.add_theme_font_size_override("font_size", 11)
	_btn_add_constraint.pressed.connect(_on_add_constraint)
	hdr_row.add_child(_btn_add_constraint)
	vbox.add_child(hdr_row)

	_constraints_vbox = VBoxContainer.new()
	_constraints_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_constraints_vbox.add_theme_constant_override("separation", 6)
	vbox.add_child(_constraints_vbox)

	return scroll

func _build_tab_algorithm() -> Control:
	var scroll := ScrollContainer.new()
	scroll.name = "AlgorithmAndSettings"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _box(CARD_BG, BORDER, 6))
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 8)
	var cm := MarginContainer.new()
	cm.add_theme_constant_override("margin_left", 12)
	cm.add_theme_constant_override("margin_right", 12)
	cm.add_theme_constant_override("margin_top", 10)
	cm.add_theme_constant_override("margin_bottom", 10)
	cm.add_child(cv)
	card.add_child(cm)

	var t := Label.new()
	t.text = "SCIML SOLVER & MONTE CARLO REPLICATION SETTINGS"
	t.add_theme_font_size_override("font_size", 11)
	t.add_theme_color_override("font_color", ACCENT)
	cv.add_child(t)

	# Algorithm Row
	var r_alg := HBoxContainer.new()
	var l_alg := Label.new()
	l_alg.text = "Solver Algorithm:"
	l_alg.custom_minimum_size.x = 180
	l_alg.add_theme_font_size_override("font_size", 11)
	r_alg.add_child(l_alg)

	_opt_algorithm = OptionButton.new()
	_opt_algorithm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for a in ALGORITHMS:
		_opt_algorithm.add_item(a["label"])
	_opt_algorithm.item_selected.connect(func(_idx: int): _sync_solver_to_doc())
	r_alg.add_child(_opt_algorithm)
	cv.add_child(r_alg)

	# Max Evaluations & Replications
	var r_evals := HBoxContainer.new()
	r_evals.add_theme_constant_override("separation", 12)
	var l_evals := Label.new()
	l_evals.text = "Max Evaluations:"
	l_evals.custom_minimum_size.x = 180
	l_evals.add_theme_font_size_override("font_size", 11)
	r_evals.add_child(l_evals)

	_spin_max_evals = SpinBox.new()
	_spin_max_evals.min_value = 5
	_spin_max_evals.max_value = 5000
	_spin_max_evals.step = 5
	_spin_max_evals.value = 60
	_spin_max_evals.value_changed.connect(func(_v: float): _sync_solver_to_doc())
	r_evals.add_child(_spin_max_evals)

	var l_reps := Label.new()
	l_reps.text = "Replications / Eval:"
	l_reps.add_theme_font_size_override("font_size", 11)
	r_evals.add_child(l_reps)

	_spin_replications = SpinBox.new()
	_spin_replications.min_value = 1
	_spin_replications.max_value = 50
	_spin_replications.step = 1
	_spin_replications.value = 3
	_spin_replications.value_changed.connect(func(_v: float): _sync_solver_to_doc())
	r_evals.add_child(_spin_replications)
	cv.add_child(r_evals)

	# Horizon & Warmup
	var r_hor := HBoxContainer.new()
	r_hor.add_theme_constant_override("separation", 12)
	var l_hor := Label.new()
	l_hor.text = "Simulation Horizon (s):"
	l_hor.custom_minimum_size.x = 180
	l_hor.add_theme_font_size_override("font_size", 11)
	r_hor.add_child(l_hor)

	_spin_horizon = SpinBox.new()
	_spin_horizon.min_value = 10.0
	_spin_horizon.max_value = 100000.0
	_spin_horizon.step = 50.0
	_spin_horizon.value = 500.0
	_spin_horizon.value_changed.connect(func(_v: float): _sync_solver_to_doc())
	r_hor.add_child(_spin_horizon)

	var l_warm := Label.new()
	l_warm.text = "Warm-up Time (s):"
	l_warm.add_theme_font_size_override("font_size", 11)
	r_hor.add_child(l_warm)

	_spin_warmup = SpinBox.new()
	_spin_warmup.min_value = 0.0
	_spin_warmup.max_value = 20000.0
	_spin_warmup.step = 10.0
	_spin_warmup.value = 50.0
	_spin_warmup.value_changed.connect(func(_v: float): _sync_solver_to_doc())
	r_hor.add_child(_spin_warmup)
	cv.add_child(r_hor)

	# Top-K Hall of Fame & CRN
	var r_topk := HBoxContainer.new()
	r_topk.add_theme_constant_override("separation", 12)
	var l_topk := Label.new()
	l_topk.text = "Store Top-K Solutions:"
	l_topk.custom_minimum_size.x = 180
	l_topk.add_theme_font_size_override("font_size", 11)
	r_topk.add_child(l_topk)

	_spin_top_k = SpinBox.new()
	_spin_top_k.min_value = 1
	_spin_top_k.max_value = 20
	_spin_top_k.step = 1
	_spin_top_k.value = 5
	_spin_top_k.value_changed.connect(func(_v: float): _sync_solver_to_doc())
	r_topk.add_child(_spin_top_k)

	_check_crn = CheckBox.new()
	_check_crn.text = "Use Common Random Numbers (CRN)"
	_check_crn.button_pressed = true
	_check_crn.toggled.connect(func(_on: bool): _sync_solver_to_doc())
	r_topk.add_child(_check_crn)

	var l_seed := Label.new()
	l_seed.text = "Seed:"
	l_seed.add_theme_font_size_override("font_size", 11)
	r_topk.add_child(l_seed)

	_spin_seed = SpinBox.new()
	_spin_seed.min_value = 1
	_spin_seed.max_value = 999999
	_spin_seed.step = 1
	_spin_seed.value = 12345
	_spin_seed.value_changed.connect(func(_v: float): _sync_solver_to_doc())
	r_topk.add_child(_spin_seed)
	cv.add_child(r_topk)

	vbox.add_child(card)
	return scroll

func _build_progress_window() -> void:
	_progress_panel = PanelContainer.new()
	_progress_panel.visible = false
	_progress_panel.custom_minimum_size = Vector2(400, 200)
	_progress_panel.size = Vector2(400, 200)
	_progress_panel.position = Vector2(420, 80)
	_progress_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_progress_panel.add_theme_stylebox_override("panel", _box(BG, ACCENT, 8))
	add_child(_progress_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 14)
	m.add_theme_constant_override("margin_right", 14)
	m.add_theme_constant_override("margin_top", 10)
	m.add_theme_constant_override("margin_bottom", 10)
	m.add_child(vbox)
	_progress_panel.add_child(m)

	# Title bar
	var hdr := PanelContainer.new()
	hdr.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 4))
	hdr.gui_input.connect(_on_progress_header_gui_input)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_left", 8)
	hm.add_theme_constant_override("margin_right", 8)
	hm.add_theme_constant_override("margin_top", 4)
	hm.add_theme_constant_override("margin_bottom", 4)
	hm.add_child(hbox)
	hdr.add_child(hm)

	var title := Label.new()
	title.text = "⚡ Optimization Progress"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", TEXT)
	hbox.add_child(title)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(sp)

	_lbl_prog_status = Label.new()
	_lbl_prog_status.text = "● IDLE"
	_lbl_prog_status.add_theme_font_size_override("font_size", 11)
	_lbl_prog_status.add_theme_color_override("font_color", MUTED)
	hbox.add_child(_lbl_prog_status)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.add_theme_font_size_override("font_size", 11)
	close_btn.pressed.connect(func(): _progress_panel.visible = false)
	hbox.add_child(close_btn)
	vbox.add_child(hdr)

	_prog_bar = ProgressBar.new()
	_prog_bar.min_value = 0.0
	_prog_bar.max_value = 100.0
	_prog_bar.value = 0.0
	_prog_bar.custom_minimum_size.y = 18
	vbox.add_child(_prog_bar)

	_lbl_prog_evals = Label.new()
	_lbl_prog_evals.text = "Evaluations: 0 / 0   |   Elapsed: 0.0s   |   Feasible: 0"
	_lbl_prog_evals.add_theme_font_size_override("font_size", 11)
	_lbl_prog_evals.add_theme_color_override("font_color", MUTED)
	vbox.add_child(_lbl_prog_evals)

	_lbl_prog_best_score = Label.new()
	_lbl_prog_best_score.text = "Best Objective: —"
	_lbl_prog_best_score.add_theme_font_size_override("font_size", 12)
	_lbl_prog_best_score.add_theme_color_override("font_color", LIVE_GREEN)
	vbox.add_child(_lbl_prog_best_score)

	_lbl_prog_best_config = Label.new()
	_lbl_prog_best_config.text = "Best Config: —"
	_lbl_prog_best_config.add_theme_font_size_override("font_size", 11)
	_lbl_prog_best_config.add_theme_color_override("font_color", TEXT)
	_lbl_prog_best_config.clip_text = true
	vbox.add_child(_lbl_prog_best_config)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	_btn_prog_stop = Button.new()
	_btn_prog_stop.text = "⏹ Stop"
	_btn_prog_stop.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_prog_stop.pressed.connect(func():
		stop_optimization_requested.emit()
	)
	btn_row.add_child(_btn_prog_stop)

	_btn_prog_report = Button.new()
	_btn_prog_report.text = "📋 Open Full Report"
	_btn_prog_report.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_prog_report.pressed.connect(func():
		open_feedback_requested.emit()
	)
	btn_row.add_child(_btn_prog_report)

	_btn_prog_apply = Button.new()
	_btn_prog_apply.text = "✔ Apply Best"
	_btn_prog_apply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_prog_apply.disabled = true
	_btn_prog_apply.pressed.connect(_on_apply_best_from_progress)
	btn_row.add_child(_btn_prog_apply)

# ─────────────────────────────────────────────────────────────────────────────
# Window Visibility & Dragging
# ─────────────────────────────────────────────────────────────────────────────

func open_setup() -> void:
	refresh_from_document()
	_setup_panel.visible = true
	_setup_panel.move_to_front()

func close_setup() -> void:
	_setup_panel.visible = false
	closed.emit()

func toggle_setup() -> void:
	if _setup_panel.visible:
		close_setup()
	else:
		open_setup()

func is_setup_visible() -> bool:
	return _setup_panel != null and _setup_panel.visible

func open_progress_hud() -> void:
	_progress_panel.visible = true
	_progress_panel.move_to_front()

func is_progress_visible() -> bool:
	return _progress_panel != null and _progress_panel.visible

func _on_setup_header_gui_input(event: InputEvent) -> void:
	if OSWindowHost.handle_header_drag(_setup_panel, event):
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging_setup = true
			_drag_offset_setup = _setup_panel.global_position - event.global_position
			_setup_panel.move_to_front()
		else:
			_dragging_setup = false
	elif event is InputEventMouseMotion and _dragging_setup:
		_setup_panel.global_position = event.global_position + _drag_offset_setup

func _on_progress_header_gui_input(event: InputEvent) -> void:
	if OSWindowHost.handle_header_drag(_progress_panel, event):
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging_progress = true
			_drag_offset_progress = _progress_panel.global_position - event.global_position
			_progress_panel.move_to_front()
		else:
			_dragging_progress = false
	elif event is InputEventMouseMotion and _dragging_progress:
		_progress_panel.global_position = event.global_position + _drag_offset_progress

# ─────────────────────────────────────────────────────────────────────────────
# Document Synchronization
# ─────────────────────────────────────────────────────────────────────────────

func _get_or_create_optim_dict() -> Dictionary:
	if doc_store == null or doc_store.active_document == null:
		return {}
	var ext: Dictionary = doc_store.active_document.extensions
	if not ext.has("optimization") or not (ext["optimization"] is Dictionary):
		ext["optimization"] = {
			"problem_id": "custom_optim",
			"problem_class": "parameter",
			"title": "Custom Simulation Optimization",
			"decision_variables": [],
			"objective": {
				"sense": "minimize",
				"primary_metric": "expected_wait_time_wq",
				"secondary_sense": "minimize",
				"secondary_metric": "total_servers",
				"description": "Minimize average waiting time"
			},
			"constraints": [],
			"solver": {
				"algorithm": "eca",
				"max_evaluations": 60,
				"population_size": 10,
				"replications_per_eval": 3,
				"sim_horizon": 500.0,
				"warmup_time": 50.0,
				"use_crn": true,
				"base_seed": 12345,
				"top_k": 5
			}
		}
	return ext["optimization"]

func _on_doc_loaded(_doc) -> void:
	refresh_from_document()

func _on_doc_modified() -> void:
	if not _updating_ui and _setup_panel != null and _setup_panel.visible:
		refresh_from_document()

func refresh_from_document() -> void:
	if _setup_panel == null or doc_store == null or doc_store.active_document == null:
		return
	_updating_ui = true
	var opt: Dictionary = _get_or_create_optim_dict()

	var pclass: String = str(opt.get("problem_class", "parameter")).to_lower()
	var pc_idx: int = max(0, PROBLEM_CLASSES.find(pclass))
	_opt_problem_class.selected = pc_idx
	_lbl_class_badge.text = "[%s]" % pclass.to_upper()

	_edit_title.text = str(opt.get("title", "Simulation Optimization"))
	_edit_problem_id.text = str(opt.get("problem_id", "custom_optim"))

	# Rebuild variables list
	_rebuild_variables_ui(opt.get("decision_variables", []))

	# Populate Objective
	var obj: Dictionary = opt.get("objective", {}) if opt.get("objective") is Dictionary else {}
	var sense_str: String = str(obj.get("sense", "minimize")).to_lower()
	_opt_primary_sense.selected = max(0, SENSES.find(sense_str))
	var p_metric: String = str(obj.get("metric", obj.get("primary_metric", "expected_wait_time_wq")))
	_edit_primary_metric.text = p_metric
	var m_idx: int = COMMON_METRICS.find(p_metric)
	if m_idx >= 0:
		_opt_primary_metric.selected = m_idx
	_edit_obj_desc.text = str(obj.get("description", ""))

	var sec_sense: String = str(obj.get("secondary_sense", "minimize")).to_lower()
	_opt_secondary_sense.selected = max(0, SENSES.find(sec_sense))
	_edit_secondary_metric.text = str(obj.get("secondary_metric", ""))

	# Rebuild constraints list
	_rebuild_constraints_ui(opt.get("constraints", []))

	# Populate Solver settings
	var solver: Dictionary = opt.get("solver", {}) if opt.get("solver") is Dictionary else {}
	var alg_str: String = str(solver.get("algorithm", "eca")).to_lower()
	var alg_idx := 0
	for i in range(ALGORITHMS.size()):
		if ALGORITHMS[i]["id"] == alg_str:
			alg_idx = i
			break
	_opt_algorithm.selected = alg_idx
	_spin_max_evals.set_value_no_signal(float(solver.get("max_evaluations", 60)))
	_spin_replications.set_value_no_signal(float(solver.get("replications_per_eval", 3)))
	_spin_horizon.set_value_no_signal(float(solver.get("sim_horizon", 500.0)))
	_spin_warmup.set_value_no_signal(float(solver.get("warmup_time", 50.0)))
	_check_crn.set_pressed_no_signal(bool(solver.get("use_crn", true)))
	_spin_top_k.set_value_no_signal(float(solver.get("top_k", 5)))
	_spin_seed.set_value_no_signal(float(solver.get("base_seed", 12345)))

	_updating_ui = false

func _rebuild_variables_ui(vars_arr: Array) -> void:
	for child in _vars_vbox.get_children():
		child.queue_free()

	if vars_arr.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No decision variables defined yet. Click '+ Add Variable' or '🔍 Auto-Detect from Scene'."
		empty_lbl.add_theme_font_size_override("font_size", 11)
		empty_lbl.add_theme_color_override("font_color", MUTED)
		_vars_vbox.add_child(empty_lbl)
		return

	for idx in range(vars_arr.size()):
		var v: Dictionary = vars_arr[idx] if vars_arr[idx] is Dictionary else {}
		var row_card := PanelContainer.new()
		row_card.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 5))
		var rv := VBoxContainer.new()
		rv.add_theme_constant_override("separation", 4)
		var rm := MarginContainer.new()
		rm.add_theme_constant_override("margin_left", 8)
		rm.add_theme_constant_override("margin_right", 8)
		rm.add_theme_constant_override("margin_top", 6)
		rm.add_theme_constant_override("margin_bottom", 6)
		rm.add_child(rv)
		row_card.add_child(rm)

		var top_line := HBoxContainer.new()
		top_line.add_theme_constant_override("separation", 6)

		var ed_id := LineEdit.new()
		ed_id.text = str(v.get("id", "v_%d" % (idx + 1)))
		ed_id.custom_minimum_size.x = 110
		ed_id.tooltip_text = "Decision variable ID"
		ed_id.text_changed.connect(func(nv: String):
			v["id"] = nv
		)
		top_line.add_child(ed_id)

		var ed_elem := LineEdit.new()
		ed_elem.text = str(v.get("element_id", ""))
		ed_elem.custom_minimum_size.x = 110
		ed_elem.placeholder_text = "element_id"
		ed_elem.tooltip_text = "Target Scene Element ID"
		ed_elem.text_changed.connect(func(nv: String):
			v["element_id"] = nv
		)
		top_line.add_child(ed_elem)

		var ed_prop := LineEdit.new()
		ed_prop.text = str(v.get("property", "servers"))
		ed_prop.custom_minimum_size.x = 110
		ed_prop.placeholder_text = "property"
		ed_prop.tooltip_text = "Target property path (e.g., servers, capacity, discipline)"
		ed_prop.text_changed.connect(func(nv: String):
			v["property"] = nv
		)
		top_line.add_child(ed_prop)

		var opt_t := OptionButton.new()
		var vt_str: String = str(v.get("type", "int")).to_lower()
		for vt in VAR_TYPES:
			opt_t.add_item(vt)
		opt_t.selected = max(0, VAR_TYPES.find(vt_str))
		opt_t.item_selected.connect(func(t_idx: int):
			v["type"] = VAR_TYPES[t_idx]
			refresh_from_document()
		)
		top_line.add_child(opt_t)

		var ed_lbl := LineEdit.new()
		ed_lbl.text = str(v.get("label", v.get("id", "")))
		ed_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ed_lbl.placeholder_text = "Display Label"
		ed_lbl.text_changed.connect(func(nv: String):
			v["label"] = nv
		)
		top_line.add_child(ed_lbl)

		var btn_del := Button.new()
		btn_del.text = "✕"
		btn_del.flat = true
		btn_del.add_theme_color_override("font_color", DANGER)
		btn_del.pressed.connect(func():
			vars_arr.remove_at(idx)
			refresh_from_document()
		)
		top_line.add_child(btn_del)
		rv.add_child(top_line)

		# Bounds / Categories second line
		var bot_line := HBoxContainer.new()
		bot_line.add_theme_constant_override("separation", 8)
		if vt_str in ["categorical", "grammar_edge", "topology"]:
			var key_name := "candidates" if vt_str in ["grammar_edge", "topology"] else "categories"
			var arr_vals: Array = v.get(key_name, []) if v.get(key_name) is Array else []
			var joined := PackedStringArray()
			for item in arr_vals:
				joined.append(str(item))
			var lbl_cat := Label.new()
			lbl_cat.text = "Domain Options (comma-separated):"
			lbl_cat.add_theme_font_size_override("font_size", 11)
			bot_line.add_child(lbl_cat)

			var ed_cats := LineEdit.new()
			ed_cats.text = ", ".join(joined)
			ed_cats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ed_cats.text_changed.connect(func(nv: String):
				var parts := nv.split(",", false)
				var clean := []
				for p in parts:
					clean.append(p.strip_edges())
				v[key_name] = clean
			)
			bot_line.add_child(ed_cats)

			var lbl_init := Label.new()
			lbl_init.text = "Initial:"
			lbl_init.add_theme_font_size_override("font_size", 11)
			bot_line.add_child(lbl_init)

			var ed_init := LineEdit.new()
			ed_init.text = str(v.get("initial", ""))
			ed_init.custom_minimum_size.x = 90
			ed_init.text_changed.connect(func(nv: String):
				v["initial"] = nv
			)
			bot_line.add_child(ed_init)
		else:
			var is_int := (vt_str == "int")
			var step_val := 1.0 if is_int else 0.1

			var l_lo := Label.new()
			l_lo.text = "Lower:"
			l_lo.add_theme_font_size_override("font_size", 11)
			bot_line.add_child(l_lo)

			var sp_lo := SpinBox.new()
			sp_lo.min_value = -10000.0
			sp_lo.max_value = 10000.0
			sp_lo.step = step_val
			sp_lo.value = float(v.get("lower", 1.0))
			sp_lo.value_changed.connect(func(nv: float):
				v["lower"] = int(nv) if is_int else nv
			)
			bot_line.add_child(sp_lo)

			var l_hi := Label.new()
			l_hi.text = "Upper:"
			l_hi.add_theme_font_size_override("font_size", 11)
			bot_line.add_child(l_hi)

			var sp_hi := SpinBox.new()
			sp_hi.min_value = -10000.0
			sp_hi.max_value = 10000.0
			sp_hi.step = step_val
			sp_hi.value = float(v.get("upper", 5.0))
			sp_hi.value_changed.connect(func(nv: float):
				v["upper"] = int(nv) if is_int else nv
			)
			bot_line.add_child(sp_hi)

			var l_in := Label.new()
			l_in.text = "Initial:"
			l_in.add_theme_font_size_override("font_size", 11)
			bot_line.add_child(l_in)

			var sp_in := SpinBox.new()
			sp_in.min_value = -10000.0
			sp_in.max_value = 10000.0
			sp_in.step = step_val
			sp_in.value = float(v.get("initial", v.get("lower", 1.0)))
			sp_in.value_changed.connect(func(nv: float):
				v["initial"] = int(nv) if is_int else nv
			)
			bot_line.add_child(sp_in)

		rv.add_child(bot_line)
		_vars_vbox.add_child(row_card)

func _rebuild_constraints_ui(cons_arr: Array) -> void:
	for child in _constraints_vbox.get_children():
		child.queue_free()

	if cons_arr.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No constraints configured. Click '+ Add Constraint' to add a budget, spatial, or SLA constraint."
		empty_lbl.add_theme_font_size_override("font_size", 11)
		empty_lbl.add_theme_color_override("font_color", MUTED)
		_constraints_vbox.add_child(empty_lbl)
		return

	for idx in range(cons_arr.size()):
		var c: Dictionary = cons_arr[idx] if cons_arr[idx] is Dictionary else {}
		var row_card := PanelContainer.new()
		row_card.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 5))
		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", 4)
		var cm := MarginContainer.new()
		cm.add_theme_constant_override("margin_left", 8)
		cm.add_theme_constant_override("margin_right", 8)
		cm.add_theme_constant_override("margin_top", 6)
		cm.add_theme_constant_override("margin_bottom", 6)
		cm.add_child(cv)
		row_card.add_child(cm)

		var line1 := HBoxContainer.new()
		line1.add_theme_constant_override("separation", 6)

		var ed_id := LineEdit.new()
		ed_id.text = str(c.get("id", "c_%d" % (idx + 1)))
		ed_id.custom_minimum_size.x = 120
		ed_id.text_changed.connect(func(nv: String): c["id"] = nv)
		line1.add_child(ed_id)

		var opt_k := OptionButton.new()
		var k_str := str(c.get("kind", "metric_bound")).to_lower()
		for ck in CONSTRAINT_KINDS:
			opt_k.add_item(ck)
		opt_k.selected = max(0, CONSTRAINT_KINDS.find(k_str))
		opt_k.item_selected.connect(func(k_idx: int):
			c["kind"] = CONSTRAINT_KINDS[k_idx]
		)
		line1.add_child(opt_k)

		var ed_target := LineEdit.new()
		ed_target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if k_str == "linear_sum" and c.has("variables") and c["variables"] is Array:
			var parts := PackedStringArray()
			for item in c["variables"]:
				parts.append(str(item))
			ed_target.text = ", ".join(parts)
			ed_target.placeholder_text = "var1, var2, ..."
		else:
			ed_target.text = str(c.get("metric", ""))
			ed_target.placeholder_text = "metric name"
		ed_target.text_changed.connect(func(nv: String):
			if str(c.get("kind", "")) == "linear_sum":
				var arr := []
				for p in nv.split(",", false):
					arr.append(p.strip_edges())
				c["variables"] = arr
			else:
				c["metric"] = nv
		)
		line1.add_child(ed_target)

		var opt_rel := OptionButton.new()
		var rel_str := str(c.get("relation", "<="))
		for r in RELATIONS:
			opt_rel.add_item(r)
		opt_rel.selected = max(0, RELATIONS.find(rel_str))
		opt_rel.item_selected.connect(func(r_idx: int):
			c["relation"] = RELATIONS[r_idx]
		)
		line1.add_child(opt_rel)

		var sp_rhs := SpinBox.new()
		sp_rhs.min_value = -10000.0
		sp_rhs.max_value = 100000.0
		sp_rhs.step = 0.5
		sp_rhs.value = float(c.get("rhs", 10.0))
		sp_rhs.value_changed.connect(func(nv: float): c["rhs"] = nv)
		line1.add_child(sp_rhs)

		var btn_del := Button.new()
		btn_del.text = "✕"
		btn_del.flat = true
		btn_del.add_theme_color_override("font_color", DANGER)
		btn_del.pressed.connect(func():
			cons_arr.remove_at(idx)
			refresh_from_document()
		)
		line1.add_child(btn_del)
		cv.add_child(line1)

		var line2 := HBoxContainer.new()
		line2.add_theme_constant_override("separation", 6)
		var l_desc := Label.new()
		l_desc.text = "Description:"
		l_desc.add_theme_font_size_override("font_size", 11)
		line2.add_child(l_desc)

		var ed_desc := LineEdit.new()
		ed_desc.text = str(c.get("description", ""))
		ed_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ed_desc.text_changed.connect(func(nv: String): c["description"] = nv)
		line2.add_child(ed_desc)

		var l_pen := Label.new()
		l_pen.text = "Penalty:"
		l_pen.add_theme_font_size_override("font_size", 11)
		line2.add_child(l_pen)

		var sp_pen := SpinBox.new()
		sp_pen.min_value = 1.0
		sp_pen.max_value = 100000.0
		sp_pen.step = 50.0
		sp_pen.value = float(c.get("penalty_weight", 500.0))
		sp_pen.value_changed.connect(func(nv: float): c["penalty_weight"] = nv)
		line2.add_child(sp_pen)

		cv.add_child(line2)
		_constraints_vbox.add_child(row_card)

func _sync_header_fields_to_doc() -> void:
	if _updating_ui:
		return
	var opt := _get_or_create_optim_dict()
	opt["title"] = _edit_title.text
	opt["problem_id"] = _edit_problem_id.text
	var pclass: String = PROBLEM_CLASSES[clampi(_opt_problem_class.selected, 0, PROBLEM_CLASSES.size() - 1)]
	opt["problem_class"] = pclass
	_lbl_class_badge.text = "[%s]" % pclass.to_upper()

func _sync_objective_to_doc() -> void:
	if _updating_ui:
		return
	var opt := _get_or_create_optim_dict()
	if not (opt.get("objective") is Dictionary):
		opt["objective"] = {}
	var obj: Dictionary = opt["objective"]
	obj["sense"] = SENSES[clampi(_opt_primary_sense.selected, 0, SENSES.size() - 1)]
	obj["metric"] = _edit_primary_metric.text
	obj["primary_metric"] = _edit_primary_metric.text
	obj["description"] = _edit_obj_desc.text
	obj["secondary_sense"] = SENSES[clampi(_opt_secondary_sense.selected, 0, SENSES.size() - 1)]
	obj["secondary_metric"] = _edit_secondary_metric.text

func _sync_solver_to_doc() -> void:
	if _updating_ui:
		return
	var opt := _get_or_create_optim_dict()
	if not (opt.get("solver") is Dictionary):
		opt["solver"] = {}
	var solver: Dictionary = opt["solver"]
	var alg_idx := clampi(_opt_algorithm.selected, 0, ALGORITHMS.size() - 1)
	solver["algorithm"] = ALGORITHMS[alg_idx]["id"]
	solver["max_evaluations"] = int(_spin_max_evals.value)
	solver["replications_per_eval"] = int(_spin_replications.value)
	solver["sim_horizon"] = float(_spin_horizon.value)
	solver["warmup_time"] = float(_spin_warmup.value)
	solver["use_crn"] = bool(_check_crn.button_pressed)
	solver["top_k"] = int(_spin_top_k.value)
	solver["base_seed"] = int(_spin_seed.value)

func _on_add_variable() -> void:
	var opt := _get_or_create_optim_dict()
	if not (opt.get("decision_variables") is Array):
		opt["decision_variables"] = []
	var arr: Array = opt["decision_variables"]
	var next_idx := arr.size() + 1
	var first_elem_id := ""
	if doc_store != null and doc_store.active_document != null and not doc_store.active_document.elements.is_empty():
		first_elem_id = doc_store.active_document.elements[0].id
	arr.append({
		"id": "v_%d" % next_idx,
		"element_id": first_elem_id,
		"property": "servers",
		"type": "int",
		"lower": 1,
		"upper": 5,
		"initial": 1,
		"label": "Decision Variable %d" % next_idx
	})
	refresh_from_document()

func _on_autodetect_variables() -> void:
	if doc_store == null or doc_store.active_document == null:
		return
	var opt := _get_or_create_optim_dict()
	var arr: Array = []
	for elem in doc_store.active_document.elements:
		if elem.kind == "server":
			var init_s: int = int(elem.properties.get("servers", 1))
			arr.append({
				"id": "c_%s" % elem.id,
				"element_id": elem.id,
				"property": "servers",
				"type": "int",
				"lower": 1,
				"upper": max(6, init_s * 2),
				"initial": init_s,
				"label": "%s Capacity" % (elem.name if not elem.name.is_empty() else elem.id)
			})
	opt["decision_variables"] = arr
	refresh_from_document()

func _on_add_constraint() -> void:
	var opt := _get_or_create_optim_dict()
	if not (opt.get("constraints") is Array):
		opt["constraints"] = []
	var arr: Array = opt["constraints"]
	var next_idx := arr.size() + 1
	arr.append({
		"id": "c_%d" % next_idx,
		"kind": "metric_bound",
		"metric": "max_utilization",
		"relation": "<=",
		"rhs": 0.95,
		"penalty_weight": 500.0,
		"description": "Custom constraint %d" % next_idx
	})
	refresh_from_document()

# ─────────────────────────────────────────────────────────────────────────────
# Optimization Actions & Live Progress Updates
# ─────────────────────────────────────────────────────────────────────────────

func _on_optimize_clicked() -> void:
	_sync_header_fields_to_doc()
	_sync_objective_to_doc()
	_sync_solver_to_doc()
	open_progress_hud()
	if doc_store != null and doc_store.active_document != null:
		var spec_dict: Dictionary = doc_store.active_document.to_dict()
		start_optimization_requested.emit(spec_dict, false)

func _on_optimize_and_feedback_clicked() -> void:
	_sync_header_fields_to_doc()
	_sync_objective_to_doc()
	_sync_solver_to_doc()
	open_progress_hud()
	if doc_store != null and doc_store.active_document != null:
		var spec_dict: Dictionary = doc_store.active_document.to_dict()
		start_optimization_requested.emit(spec_dict, true)
	open_feedback_requested.emit()

var _last_state_sig: String = ""

func feed_optim_state(optim_state: Dictionary) -> void:
	if optim_state.is_empty():
		return

	var status: String = str(optim_state.get("status", "idle")).to_lower()
	var iter_n: int = int(optim_state.get("iteration", 0))
	var max_n: int = int(optim_state.get("max_iterations", 0))
	var pct: float = float(optim_state.get("progress_pct", 0.0))
	var elapsed: float = float(optim_state.get("elapsed_sec", 0.0))
	var feas_n: int = int(optim_state.get("feasible_count", 0))
	var best_prim: float = float(optim_state.get("best_primary", 0.0))
	var best_lbl: String = str(optim_state.get("best_label", "—"))
	var top_k: Array = optim_state.get("top_k_solutions", []) if optim_state.get("top_k_solutions") is Array else []
	var has_full_spec: bool = (not top_k.is_empty() and top_k[0] is Dictionary and top_k[0].get("scenespec") is Dictionary and not (top_k[0]["scenespec"] as Dictionary).is_empty())

	var state_sig: String = "%s|%d|%d|%d|%.6f|%s|%d|%s|%s" % [
		status, iter_n, max_n, feas_n, best_prim, best_lbl, top_k.size(), str(has_full_spec), str(optim_state.get("state_seq", -1))
	]
	if state_sig == _last_state_sig:
		return
	_last_state_sig = state_sig
	_latest_optim_state = optim_state

	if _lbl_prog_status != null:
		_lbl_prog_status.text = "● " + status.to_upper()
		if status == "running":
			_lbl_prog_status.add_theme_color_override("font_color", WARNING)
		elif status == "completed":
			_lbl_prog_status.add_theme_color_override("font_color", LIVE_GREEN)
		elif status == "error":
			_lbl_prog_status.add_theme_color_override("font_color", DANGER)
		else:
			_lbl_prog_status.add_theme_color_override("font_color", MUTED)

	if _prog_bar != null:
		_prog_bar.value = clampf(pct, 0.0, 100.0)

	if _lbl_prog_evals != null:
		_lbl_prog_evals.text = "Evaluations: %d / %d   |   Elapsed: %.2fs   |   Feasible: %d" % [iter_n, max_n, elapsed, feas_n]

	if _lbl_prog_best_score != null:
		if iter_n > 0:
			_lbl_prog_best_score.text = "Best Primary Objective: %.3f" % best_prim
		else:
			_lbl_prog_best_score.text = "Best Primary Objective: —"

	if _lbl_prog_best_config != null:
		_lbl_prog_best_config.text = "Best Config: %s" % best_lbl

	if _btn_prog_apply != null:
		_btn_prog_apply.disabled = top_k.is_empty()

func _on_apply_best_from_progress() -> void:
	var top_k: Array = _latest_optim_state.get("top_k_solutions", []) if _latest_optim_state.get("top_k_solutions") is Array else []
	if top_k.is_empty():
		return
	var best_entry: Dictionary = top_k[0] if top_k[0] is Dictionary else {}
	var cand_spec: Dictionary = best_entry.get("scenespec", {}) if best_entry.get("scenespec") is Dictionary else {}
	if not cand_spec.is_empty():
		apply_solution_requested.emit(cand_spec, 1)
