# authoring_optim_feedback.gd
# Phase 7E-5: Window 2 (📊 Optimization Report & Live Feedback) + Full-Size Snapshot Lightbox Modal.
# Provides real-time & post-run optimization charts (Convergence Trajectory, 2D Pareto/Trade-Off Scatter,
# Constraint & SLA Margin Bars), the Top-K Hall-of-Fame Leaderboard, interactive 2D Schematic Snapshot
# preview with click-to-enlarge Lightbox, and 1-click loading into the main authoring canvas.
class_name SimVizAuthoringOptimFeedback
extends Control

const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const ConveyorCurve3D := preload("res://scripts/conveyor_curve_3d.gd")

signal closed
signal stop_optimization_requested
signal apply_solution_requested(candidate_scenespec: Dictionary, rank: int)
signal open_setup_requested

const BG := Color("#0e1520")
const PANEL := Color("#141d2b")
const PANEL_ALT := Color("#1a2638")
const CARD_BG := Color("#101824")
const CARD_SEL_BG := Color("#172a42")
const BORDER := Color("#2c3e55")
const BORDER_SEL := Color("#52c7a5")
const TEXT := Color("#e8f0f8")
const MUTED := Color("#8fa2b5")
const ACCENT := Color("#52c7a5")
const BLUE := Color("#58a6ff")
const WARNING := Color("#f39c12")
const DANGER := Color("#e74c3c")
const LIVE_GREEN := Color("#2ecc71")
const PURPLE := Color("#9b59b6")
const GOLD := Color("#f1c40f")

var doc_store: DocumentStore = null
var _latest_optim_state: Dictionary = {}
var _convergence_history: Array = []
var _scatter_points: Array = []
var _top_k_solutions: Array = []
var _selected_rank: int = 1

# Floating windows managed by this overlay
var _report_panel: PanelContainer = null
var _lightbox_panel: PanelContainer = null

# Dragging states
var _dragging_report: bool = false
var _drag_offset_report: Vector2 = Vector2.ZERO
var _dragging_lightbox: bool = false
var _drag_offset_lightbox: Vector2 = Vector2.ZERO

# Lightbox pan/zoom state
var _lightbox_zoom: float = 1.0
var _lightbox_pan: Vector2 = Vector2.ZERO
var _lightbox_panning: bool = false
var _lightbox_pan_start: Vector2 = Vector2.ZERO

# Header & Telemetry Strip Controls
var _lbl_problem_title: Label = null
var _lbl_class_badge: Label = null
var _lbl_status: Label = null
var _prog_bar: ProgressBar = null
var _lbl_evals: Label = null
var _lbl_best_summary: Label = null
var _btn_stop: Button = null
var _btn_open_setup: Button = null

# Left Split: 3 Live Charts
var _conv_chart: Control = null
var _scatter_chart: Control = null
var _sla_chart: Control = null

# Right Split: Top-K Leaderboard & 2D Schematic Snapshot
var _lbl_topk_count: Label = null
var _topk_vbox: VBoxContainer = null
var _lbl_snapshot_title: Label = null
var _snapshot_canvas: Control = null
var _btn_enlarge_snapshot: Button = null
var _btn_open_in_canvas: Button = null

# Lightbox Modal Controls
var _lbl_lightbox_title: Label = null
var _lightbox_canvas: Control = null
var _lbl_lightbox_zoom: Label = null

func _init(p_store: DocumentStore = null) -> void:
	doc_store = p_store
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _ready() -> void:
	_build_report_window()
	_build_lightbox_modal()
	if doc_store != null:
		doc_store.document_loaded.connect(func(_d): _refresh_header_from_doc())
		doc_store.document_modified.connect(func(): _refresh_header_from_doc())
	_refresh_header_from_doc()

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

func open_report() -> void:
	if _report_panel != null:
		_refresh_header_from_doc()
		_report_panel.visible = true
		move_to_front()
		_redraw_all_canvases()

func close_report() -> void:
	if _report_panel != null:
		_report_panel.visible = false
	closed.emit()

func toggle_report() -> void:
	if is_report_visible():
		close_report()
	else:
		open_report()

func is_report_visible() -> bool:
	return _report_panel != null and _report_panel.visible

func open_lightbox() -> void:
	if _lightbox_panel != null:
		_lightbox_zoom = 1.0
		_lightbox_pan = Vector2.ZERO
		_update_lightbox_title()
		_lightbox_panel.visible = true
		move_to_front()
		if _lightbox_canvas != null:
			_lightbox_canvas.queue_redraw()

func close_lightbox() -> void:
	if _lightbox_panel != null:
		_lightbox_panel.visible = false

func is_lightbox_visible() -> bool:
	return _lightbox_panel != null and _lightbox_panel.visible

func select_candidate_rank(rank: int) -> void:
	_selected_rank = max(1, rank)
	_last_topk_sig = ""
	_rebuild_topk_rows()
	_update_snapshot_header()
	_redraw_all_canvases()

func get_top_k_count() -> int:
	return _top_k_solutions.size()

func get_selected_rank() -> int:
	return _selected_rank

func _set_lightbox_zoom(z: float) -> void:
	_lightbox_zoom = clampf(z, 0.4, 4.0)
	_update_lightbox_zoom_label()
	if _lightbox_canvas != null:
		_lightbox_canvas.queue_redraw()

func get_selected_candidate() -> Dictionary:
	if _top_k_solutions.is_empty():
		return {}
	for item in _top_k_solutions:
		if item is Dictionary and int(item.get("rank", 0)) == _selected_rank:
			return item
	if _top_k_solutions[0] is Dictionary:
		return _top_k_solutions[0]
	return {}

func get_selected_candidate_scenespec() -> Dictionary:
	var cand := get_selected_candidate()
	if cand.is_empty():
		return {}
	if cand.get("scenespec") is Dictionary and not (cand["scenespec"] as Dictionary).is_empty():
		return cand["scenespec"]
	# Fallback: synthesize from active document + decision_dict if scenespec was omitted
	if doc_store != null and doc_store.active_document != null:
		var base_dict: Dictionary = doc_store.active_document.to_dict()
		var dec: Dictionary = cand.get("decision_dict", {}) if cand.get("decision_dict") is Dictionary else {}
		_apply_decision_dict_preview(base_dict, dec)
		return base_dict
	return {}

var _last_state_sig: String = ""
var _last_topk_sig: String = ""

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
	var new_top_k: Array = optim_state.get("top_k_solutions", []) if optim_state.get("top_k_solutions") is Array else []
	var has_full_spec: bool = (not new_top_k.is_empty() and new_top_k[0] is Dictionary and new_top_k[0].get("scenespec") is Dictionary and not (new_top_k[0]["scenespec"] as Dictionary).is_empty())

	var state_sig: String = "%s|%d|%d|%d|%.6f|%s|%d|%s|%s" % [
		status, iter_n, max_n, feas_n, best_prim, best_lbl, new_top_k.size(), str(has_full_spec), str(optim_state.get("state_seq", -1))
	]
	if state_sig == _last_state_sig:
		return
	_last_state_sig = state_sig
	_latest_optim_state = optim_state

	var title_str: String = str(optim_state.get("title", ""))
	var pclass_str: String = str(optim_state.get("problem_class", ""))
	if not title_str.is_empty() and _lbl_problem_title != null:
		_lbl_problem_title.text = title_str
	if not pclass_str.is_empty() and _lbl_class_badge != null:
		_lbl_class_badge.text = "[%s]" % pclass_str.to_upper()

	if _lbl_status != null:
		_lbl_status.text = "● " + status.to_upper()
		if status == "running":
			_lbl_status.add_theme_color_override("font_color", WARNING)
		elif status == "completed":
			_lbl_status.add_theme_color_override("font_color", LIVE_GREEN)
		elif status == "error":
			_lbl_status.add_theme_color_override("font_color", DANGER)
		else:
			_lbl_status.add_theme_color_override("font_color", MUTED)

	if _btn_stop != null:
		_btn_stop.disabled = (status != "running")

	if _prog_bar != null:
		_prog_bar.value = clampf(pct, 0.0, 100.0)

	if _lbl_evals != null:
		_lbl_evals.text = "Evaluations: %d / %d   |   Elapsed: %.2fs   |   Feasible: %d" % [iter_n, max_n, elapsed, feas_n]

	if _lbl_best_summary != null:
		if iter_n > 0:
			_lbl_best_summary.text = "Best Objective: %.3f   |   Best Config: %s" % [best_prim, best_lbl]
		else:
			_lbl_best_summary.text = "Best Objective: —   |   Best Config: —"

	_convergence_history = optim_state.get("convergence_history", []) if optim_state.get("convergence_history") is Array else []
	_scatter_points = optim_state.get("scatter_points", []) if optim_state.get("scatter_points") is Array else []

	# Preserve any previously cached scenespec on matching candidate_id/decision_summary if intermediate tick omitted it
	var prev_specs_by_summary: Dictionary = {}
	for old_item in _top_k_solutions:
		if old_item is Dictionary:
			var s_key := str(old_item.get("decision_summary", ""))
			if not s_key.is_empty() and old_item.get("scenespec") is Dictionary and not (old_item["scenespec"] as Dictionary).is_empty():
				prev_specs_by_summary[s_key] = old_item["scenespec"]

	_top_k_solutions = []
	var topk_sig_parts := PackedStringArray()
	for item in new_top_k:
		if item is Dictionary:
			var dup_item: Dictionary = item.duplicate(false)
			var s_key := str(dup_item.get("decision_summary", ""))
			if (not dup_item.has("scenespec") or not (dup_item["scenespec"] is Dictionary) or (dup_item["scenespec"] as Dictionary).is_empty()) and prev_specs_by_summary.has(s_key):
				dup_item["scenespec"] = prev_specs_by_summary[s_key]
			_top_k_solutions.append(dup_item)
			topk_sig_parts.append("%d:%s:%.4f:%s" % [
				int(dup_item.get("rank", 0)),
				s_key,
				float(dup_item.get("primary_objective", 0.0)),
				str(dup_item.get("is_feasible", true))
			])

	if _selected_rank > _top_k_solutions.size() and not _top_k_solutions.is_empty():
		_selected_rank = 1

	var next_topk_sig: String = "%d|" % _selected_rank + "|".join(topk_sig_parts)
	if next_topk_sig != _last_topk_sig:
		_last_topk_sig = next_topk_sig
		_rebuild_topk_rows()

	_update_snapshot_header()
	if _btn_open_in_canvas != null:
		_btn_open_in_canvas.disabled = _top_k_solutions.is_empty()
	if _btn_enlarge_snapshot != null:
		_btn_enlarge_snapshot.disabled = _top_k_solutions.is_empty()

	_redraw_all_canvases()

# ─────────────────────────────────────────────────────────────────────────────
# UI Construction: Window 2 (Optimization Report & Live Feedback)
# ─────────────────────────────────────────────────────────────────────────────

func _build_report_window() -> void:
	_report_panel = PanelContainer.new()
	_report_panel.name = "OptimFeedbackWindow"
	_report_panel.visible = false
	_report_panel.custom_minimum_size = Vector2(1120, 680)
	_report_panel.size = Vector2(1120, 680)
	_report_panel.position = Vector2(90, 56)
	_report_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style := StyleBoxFlat.new()
	style.bg_color = BG
	style.border_color = BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.shadow_color = Color(0, 0, 0, 0.55)
	style.shadow_size = 18
	_report_panel.add_theme_stylebox_override("panel", style)
	add_child(_report_panel)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 0)
	_report_panel.add_child(root_vbox)

	# 1. Draggable Title Bar
	var header_panel := PanelContainer.new()
	header_panel.custom_minimum_size.y = 44
	var h_style := StyleBoxFlat.new()
	h_style.bg_color = PANEL
	h_style.border_color = BORDER
	h_style.border_width_bottom = 1
	h_style.corner_radius_top_left = 6
	h_style.corner_radius_top_right = 6
	h_style.content_margin_left = 14
	h_style.content_margin_right = 12
	header_panel.add_theme_stylebox_override("panel", h_style)
	header_panel.gui_input.connect(_on_report_header_gui_input)
	root_vbox.add_child(header_panel)

	var header_hbox := HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 10)
	header_panel.add_child(header_hbox)

	var lbl_win_title := Label.new()
	lbl_win_title.text = "📊 Optimization Report & Live Feedback"
	lbl_win_title.add_theme_font_size_override("font_size", 15)
	lbl_win_title.add_theme_color_override("font_color", TEXT)
	header_hbox.add_child(lbl_win_title)

	_lbl_class_badge = Label.new()
	_lbl_class_badge.text = "[PARAMETER]"
	_lbl_class_badge.add_theme_font_size_override("font_size", 11)
	_lbl_class_badge.add_theme_color_override("font_color", ACCENT)
	header_hbox.add_child(_lbl_class_badge)

	_lbl_problem_title = Label.new()
	_lbl_problem_title.text = "Active Scene Optimization"
	_lbl_problem_title.add_theme_font_size_override("font_size", 12)
	_lbl_problem_title.add_theme_color_override("font_color", MUTED)
	_lbl_problem_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(_lbl_problem_title)

	_btn_open_setup = Button.new()
	_btn_open_setup.text = "⚡ Setup Window"
	_btn_open_setup.tooltip_text = "Open Window 1: Optimization Setup"
	_btn_open_setup.pressed.connect(func(): open_setup_requested.emit())
	header_hbox.add_child(_btn_open_setup)

	var btn_close := Button.new()
	btn_close.text = "✕"
	btn_close.custom_minimum_size = Vector2(28, 28)
	btn_close.pressed.connect(close_report)
	header_hbox.add_child(btn_close)

	# 2. Live Telemetry Status Strip
	var tele_panel := PanelContainer.new()
	var t_style := StyleBoxFlat.new()
	t_style.bg_color = PANEL_ALT
	t_style.border_color = BORDER
	t_style.border_width_bottom = 1
	t_style.content_margin_left = 14
	t_style.content_margin_right = 14
	t_style.content_margin_top = 8
	t_style.content_margin_bottom = 8
	tele_panel.add_theme_stylebox_override("panel", t_style)
	root_vbox.add_child(tele_panel)

	var tele_vbox := VBoxContainer.new()
	tele_vbox.add_theme_constant_override("separation", 6)
	tele_panel.add_child(tele_vbox)

	var tele_row1 := HBoxContainer.new()
	tele_row1.add_theme_constant_override("separation", 12)
	tele_vbox.add_child(tele_row1)

	_lbl_status = Label.new()
	_lbl_status.text = "● IDLE"
	_lbl_status.custom_minimum_size.x = 105
	_lbl_status.add_theme_font_size_override("font_size", 12)
	_lbl_status.add_theme_color_override("font_color", MUTED)
	tele_row1.add_child(_lbl_status)

	_prog_bar = ProgressBar.new()
	_prog_bar.min_value = 0.0
	_prog_bar.max_value = 100.0
	_prog_bar.value = 0.0
	_prog_bar.custom_minimum_size = Vector2(220, 18)
	_prog_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tele_row1.add_child(_prog_bar)

	_lbl_evals = Label.new()
	_lbl_evals.text = "Evaluations: 0 / 0   |   Elapsed: 0.00s   |   Feasible: 0"
	_lbl_evals.add_theme_font_size_override("font_size", 12)
	_lbl_evals.add_theme_color_override("font_color", TEXT)
	_lbl_evals.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tele_row1.add_child(_lbl_evals)

	_btn_stop = Button.new()
	_btn_stop.text = "⏹ Stop"
	_btn_stop.pressed.connect(func(): stop_optimization_requested.emit())
	tele_row1.add_child(_btn_stop)

	_lbl_best_summary = Label.new()
	_lbl_best_summary.text = "Best Objective: —   |   Best Config: —"
	_lbl_best_summary.add_theme_font_size_override("font_size", 12)
	_lbl_best_summary.add_theme_color_override("font_color", ACCENT)
	tele_vbox.add_child(_lbl_best_summary)

	# 3. Main Split Container (Left: 3 Optimization Charts | Right: Top-K Leaderboard + 2D Snapshot)
	var body_margin := MarginContainer.new()
	body_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_margin.add_theme_constant_override("margin_left", 12)
	body_margin.add_theme_constant_override("margin_right", 12)
	body_margin.add_theme_constant_override("margin_top", 10)
	body_margin.add_theme_constant_override("margin_bottom", 10)
	root_vbox.add_child(body_margin)

	var main_split := HSplitContainer.new()
	main_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_split.split_offset = 555
	body_margin.add_child(main_split)

	# ── Left Pane: 3 Real-Time & Post-Run Charts ──────────────────────────
	var left_vbox := VBoxContainer.new()
	left_vbox.custom_minimum_size.x = 500
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vbox.add_theme_constant_override("separation", 8)
	main_split.add_child(left_vbox)

	# Chart 1: Convergence Trajectory
	var conv_card := _make_card_panel()
	conv_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	conv_card.size_flags_stretch_ratio = 1.15
	left_vbox.add_child(conv_card)
	var conv_vbox := VBoxContainer.new()
	conv_vbox.add_theme_constant_override("separation", 4)
	conv_card.add_child(conv_vbox)
	var lbl_c1 := Label.new()
	lbl_c1.text = "📈 1. Objective Convergence Trajectory (Best-So-Far vs. Current Evaluation)"
	lbl_c1.add_theme_font_size_override("font_size", 12)
	lbl_c1.add_theme_color_override("font_color", TEXT)
	conv_vbox.add_child(lbl_c1)
	_conv_chart = Control.new()
	_conv_chart.custom_minimum_size = Vector2(460, 150)
	_conv_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_conv_chart.draw.connect(func(): _draw_convergence_chart(_conv_chart))
	conv_vbox.add_child(_conv_chart)

	# Chart 2: 2D Pareto Front & Trade-Off Scatter
	var scat_card := _make_card_panel()
	scat_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scat_card.size_flags_stretch_ratio = 1.05
	left_vbox.add_child(scat_card)
	var scat_vbox := VBoxContainer.new()
	scat_vbox.add_theme_constant_override("separation", 4)
	scat_card.add_child(scat_vbox)
	var lbl_c2 := Label.new()
	lbl_c2.text = "🎯 2. 2D Pareto Front & Objective Trade-Off Scatter"
	lbl_c2.add_theme_font_size_override("font_size", 12)
	lbl_c2.add_theme_color_override("font_color", TEXT)
	scat_vbox.add_child(lbl_c2)
	_scatter_chart = Control.new()
	_scatter_chart.custom_minimum_size = Vector2(460, 135)
	_scatter_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scatter_chart.draw.connect(func(): _draw_scatter_chart(_scatter_chart))
	scat_vbox.add_child(_scatter_chart)

	# Chart 3: Constraint & SLA Margin Utilization Bars
	var sla_card := _make_card_panel()
	sla_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sla_card.size_flags_stretch_ratio = 0.85
	left_vbox.add_child(sla_card)
	var sla_vbox := VBoxContainer.new()
	sla_vbox.add_theme_constant_override("separation", 4)
	sla_card.add_child(sla_vbox)
	var lbl_c3 := Label.new()
	lbl_c3.text = "🛡 3. Constraint & SLA Utilization / Margin Comparison (Top-K)"
	lbl_c3.add_theme_font_size_override("font_size", 12)
	lbl_c3.add_theme_color_override("font_color", TEXT)
	sla_vbox.add_child(lbl_c3)
	_sla_chart = Control.new()
	_sla_chart.custom_minimum_size = Vector2(460, 110)
	_sla_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sla_chart.draw.connect(func(): _draw_sla_chart(_sla_chart))
	sla_vbox.add_child(_sla_chart)

	# ── Right Pane: Top-K Leaderboard + 2D Schematic Snapshot + Loader ────
	var right_vbox := VBoxContainer.new()
	right_vbox.custom_minimum_size.x = 480
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_theme_constant_override("separation", 8)
	main_split.add_child(right_vbox)

	# Top-K Leaderboard Card
	var topk_card := _make_card_panel()
	topk_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	topk_card.size_flags_stretch_ratio = 1.05
	right_vbox.add_child(topk_card)

	var topk_outer := VBoxContainer.new()
	topk_outer.add_theme_constant_override("separation", 6)
	topk_card.add_child(topk_outer)

	var topk_hdr := HBoxContainer.new()
	topk_outer.add_child(topk_hdr)
	var lbl_tk := Label.new()
	lbl_tk.text = "🏆 Top-K Best Solutions Leaderboard (Click to Preview)"
	lbl_tk.add_theme_font_size_override("font_size", 12)
	lbl_tk.add_theme_color_override("font_color", TEXT)
	lbl_tk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	topk_hdr.add_child(lbl_tk)

	_lbl_topk_count = Label.new()
	_lbl_topk_count.text = "0 solutions"
	_lbl_topk_count.add_theme_font_size_override("font_size", 11)
	_lbl_topk_count.add_theme_color_override("font_color", ACCENT)
	topk_hdr.add_child(_lbl_topk_count)

	var topk_scroll := ScrollContainer.new()
	topk_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	topk_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	topk_outer.add_child(topk_scroll)

	_topk_vbox = VBoxContainer.new()
	_topk_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_topk_vbox.add_theme_constant_override("separation", 5)
	topk_scroll.add_child(_topk_vbox)

	# 2D Schematic Snapshot Preview Card
	var snap_card := _make_card_panel()
	snap_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	snap_card.size_flags_stretch_ratio = 1.15
	right_vbox.add_child(snap_card)

	var snap_vbox := VBoxContainer.new()
	snap_vbox.add_theme_constant_override("separation", 6)
	snap_card.add_child(snap_vbox)

	var snap_hdr := HBoxContainer.new()
	snap_hdr.add_theme_constant_override("separation", 8)
	snap_vbox.add_child(snap_hdr)

	var lbl_sn := Label.new()
	lbl_sn.text = "🗺 2D Schematic Snapshot:"
	lbl_sn.add_theme_font_size_override("font_size", 12)
	lbl_sn.add_theme_color_override("font_color", TEXT)
	snap_hdr.add_child(lbl_sn)

	_lbl_snapshot_title = Label.new()
	_lbl_snapshot_title.text = "(Select a Top-K solution)"
	_lbl_snapshot_title.add_theme_font_size_override("font_size", 11)
	_lbl_snapshot_title.add_theme_color_override("font_color", ACCENT)
	_lbl_snapshot_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_snapshot_title.clip_text = true
	snap_hdr.add_child(_lbl_snapshot_title)

	_btn_enlarge_snapshot = Button.new()
	_btn_enlarge_snapshot.text = "🔍 Enlarge"
	_btn_enlarge_snapshot.tooltip_text = "Open Full-Size Snapshot Lightbox with Zoom & Pan"
	_btn_enlarge_snapshot.disabled = true
	_btn_enlarge_snapshot.pressed.connect(open_lightbox)
	snap_hdr.add_child(_btn_enlarge_snapshot)

	_snapshot_canvas = Control.new()
	_snapshot_canvas.custom_minimum_size = Vector2(450, 195)
	_snapshot_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_snapshot_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_snapshot_canvas.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_snapshot_canvas.tooltip_text = "Click to open full-size interactive schematic lightbox"
	_snapshot_canvas.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and not _top_k_solutions.is_empty():
				open_lightbox()
				accept_event()
	)
	_snapshot_canvas.draw.connect(func():
		_draw_scenespec_schematic(_snapshot_canvas, get_selected_candidate_scenespec(), 1.0, Vector2.ZERO, false)
	)
	snap_vbox.add_child(_snapshot_canvas)

	# Bottom Button: Open Selected Solution in Main Canvas
	_btn_open_in_canvas = Button.new()
	_btn_open_in_canvas.text = "⤢ Open Selected Solution in Main Canvas"
	_btn_open_in_canvas.custom_minimum_size.y = 36
	_btn_open_in_canvas.disabled = true
	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color("#1b4338")
	btn_style.border_color = ACCENT
	btn_style.set_border_width_all(1)
	btn_style.set_corner_radius_all(5)
	_btn_open_in_canvas.add_theme_stylebox_override("normal", btn_style)
	_btn_open_in_canvas.add_theme_color_override("font_color", TEXT)
	_btn_open_in_canvas.pressed.connect(_on_open_selected_in_main_canvas)
	right_vbox.add_child(_btn_open_in_canvas)

	_rebuild_topk_rows()

# ─────────────────────────────────────────────────────────────────────────────
# UI Construction: Full-Size Snapshot Lightbox Modal
# ─────────────────────────────────────────────────────────────────────────────

func _build_lightbox_modal() -> void:
	_lightbox_panel = PanelContainer.new()
	_lightbox_panel.name = "OptimSnapshotLightbox"
	_lightbox_panel.visible = false
	_lightbox_panel.custom_minimum_size = Vector2(900, 600)
	_lightbox_panel.size = Vector2(900, 600)
	_lightbox_panel.position = Vector2(180, 90)
	_lightbox_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style := StyleBoxFlat.new()
	style.bg_color = Color("#0a1018")
	style.border_color = ACCENT
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.shadow_color = Color(0, 0, 0, 0.7)
	style.shadow_size = 24
	_lightbox_panel.add_theme_stylebox_override("panel", style)
	add_child(_lightbox_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	_lightbox_panel.add_child(vbox)

	var hdr := PanelContainer.new()
	hdr.custom_minimum_size.y = 42
	var h_style := StyleBoxFlat.new()
	h_style.bg_color = PANEL
	h_style.border_color = BORDER
	h_style.border_width_bottom = 1
	h_style.content_margin_left = 14
	h_style.content_margin_right = 12
	hdr.add_theme_stylebox_override("panel", h_style)
	hdr.gui_input.connect(_on_lightbox_header_gui_input)
	vbox.add_child(hdr)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	hdr.add_child(hbox)

	_lbl_lightbox_title = Label.new()
	_lbl_lightbox_title.text = "🔍 Candidate Layout Schematic — Rank #1"
	_lbl_lightbox_title.add_theme_font_size_override("font_size", 14)
	_lbl_lightbox_title.add_theme_color_override("font_color", TEXT)
	_lbl_lightbox_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(_lbl_lightbox_title)

	var btn_z_out := Button.new()
	btn_z_out.text = "−"
	btn_z_out.custom_minimum_size = Vector2(28, 26)
	btn_z_out.pressed.connect(func():
		_lightbox_zoom = clampf(_lightbox_zoom * 0.85, 0.4, 4.0)
		_update_lightbox_zoom_label()
		if _lightbox_canvas != null: _lightbox_canvas.queue_redraw()
	)
	hbox.add_child(btn_z_out)

	_lbl_lightbox_zoom = Label.new()
	_lbl_lightbox_zoom.text = "100%"
	_lbl_lightbox_zoom.custom_minimum_size.x = 48
	_lbl_lightbox_zoom.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lbl_lightbox_zoom.add_theme_font_size_override("font_size", 11)
	hbox.add_child(_lbl_lightbox_zoom)

	var btn_z_in := Button.new()
	btn_z_in.text = "+"
	btn_z_in.custom_minimum_size = Vector2(28, 26)
	btn_z_in.pressed.connect(func():
		_lightbox_zoom = clampf(_lightbox_zoom * 1.18, 0.4, 4.0)
		_update_lightbox_zoom_label()
		if _lightbox_canvas != null: _lightbox_canvas.queue_redraw()
	)
	hbox.add_child(btn_z_in)

	var btn_fit := Button.new()
	btn_fit.text = "⛶ Reset View"
	btn_fit.pressed.connect(func():
		_lightbox_zoom = 1.0
		_lightbox_pan = Vector2.ZERO
		_update_lightbox_zoom_label()
		if _lightbox_canvas != null: _lightbox_canvas.queue_redraw()
	)
	hbox.add_child(btn_fit)

	var btn_close := Button.new()
	btn_close.text = "✕"
	btn_close.custom_minimum_size = Vector2(28, 26)
	btn_close.pressed.connect(close_lightbox)
	hbox.add_child(btn_close)

	_lightbox_canvas = Control.new()
	_lightbox_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lightbox_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lightbox_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_lightbox_canvas.gui_input.connect(_on_lightbox_canvas_input)
	_lightbox_canvas.draw.connect(func():
		_draw_scenespec_schematic(_lightbox_canvas, get_selected_candidate_scenespec(), _lightbox_zoom, _lightbox_pan, true)
	)
	vbox.add_child(_lightbox_canvas)

func _update_lightbox_zoom_label() -> void:
	if _lbl_lightbox_zoom != null:
		_lbl_lightbox_zoom.text = "%d%%" % int(round(_lightbox_zoom * 100.0))

func _update_lightbox_title() -> void:
	var cand := get_selected_candidate()
	if _lbl_lightbox_title != null:
		var rnk: int = int(cand.get("rank", _selected_rank))
		var summ: String = str(cand.get("decision_summary", ""))
		_lbl_lightbox_title.text = "🔍 Candidate Layout Schematic — Rank #%d   [%s]" % [rnk, summ]
	_update_lightbox_zoom_label()

func _on_lightbox_canvas_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_lightbox_zoom = clampf(_lightbox_zoom * 1.12, 0.4, 4.0)
			_update_lightbox_zoom_label()
			_lightbox_canvas.queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_lightbox_zoom = clampf(_lightbox_zoom * 0.89, 0.4, 4.0)
			_update_lightbox_zoom_label()
			_lightbox_canvas.queue_redraw()
			accept_event()
		elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
			if mb.pressed:
				_lightbox_panning = true
				_lightbox_pan_start = mb.position - _lightbox_pan
				accept_event()
			else:
				_lightbox_panning = false
				accept_event()
	elif event is InputEventMouseMotion and _lightbox_panning:
		var mm := event as InputEventMouseMotion
		_lightbox_pan = mm.position - _lightbox_pan_start
		_lightbox_canvas.queue_redraw()
		accept_event()

# ─────────────────────────────────────────────────────────────────────────────
# Top-K Leaderboard Rows & Selection
# ─────────────────────────────────────────────────────────────────────────────

func _rebuild_topk_rows() -> void:
	if _topk_vbox == null:
		return
	for ch in _topk_vbox.get_children():
		ch.queue_free()

	if _lbl_topk_count != null:
		_lbl_topk_count.text = "%d solution%s" % [_top_k_solutions.size(), "" if _top_k_solutions.size() == 1 else "s"]

	if _top_k_solutions.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No candidate solutions evaluated yet. Click [ ▶ Optimize ] or [ 📊 Optimize + Feedback ] in Window 1 to start."
		empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty_lbl.add_theme_font_size_override("font_size", 11)
		empty_lbl.add_theme_color_override("font_color", MUTED)
		_topk_vbox.add_child(empty_lbl)
		return

	for item in _top_k_solutions:
		if not (item is Dictionary):
			continue
		var rnk: int = int(item.get("rank", 1))
		var is_sel: bool = (rnk == _selected_rank)
		var is_feas: bool = bool(item.get("is_feasible", true))
		var prim_val: float = float(item.get("primary_objective", 0.0))
		var sec_val: float = float(item.get("secondary_objective", 0.0))
		var summ_str: String = str(item.get("decision_summary", "—"))

		var row_panel := PanelContainer.new()
		var r_style := StyleBoxFlat.new()
		r_style.bg_color = CARD_SEL_BG if is_sel else CARD_BG
		r_style.border_color = BORDER_SEL if is_sel else BORDER
		r_style.set_border_width_all(2 if is_sel else 1)
		r_style.set_corner_radius_all(5)
		r_style.content_margin_left = 8
		r_style.content_margin_right = 8
		r_style.content_margin_top = 6
		r_style.content_margin_bottom = 6
		row_panel.add_theme_stylebox_override("panel", r_style)
		row_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		var captured_rank := rnk
		row_panel.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton:
				var mb := ev as InputEventMouseButton
				if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
					select_candidate_rank(captured_rank)
		)
		_topk_vbox.add_child(row_panel)

		var row_vbox := VBoxContainer.new()
		row_vbox.add_theme_constant_override("separation", 3)
		row_panel.add_child(row_vbox)

		var top_line := HBoxContainer.new()
		top_line.add_theme_constant_override("separation", 8)
		row_vbox.add_child(top_line)

		var lbl_rank := Label.new()
		lbl_rank.text = ("★ #%d" % rnk) if rnk == 1 else ("#%d" % rnk)
		lbl_rank.add_theme_font_size_override("font_size", 12)
		lbl_rank.add_theme_color_override("font_color", GOLD if rnk == 1 else ACCENT)
		top_line.add_child(lbl_rank)

		var lbl_feas := Label.new()
		lbl_feas.text = "✔ FEASIBLE" if is_feas else "⚠ INFEASIBLE"
		lbl_feas.add_theme_font_size_override("font_size", 10)
		lbl_feas.add_theme_color_override("font_color", LIVE_GREEN if is_feas else DANGER)
		top_line.add_child(lbl_feas)

		var lbl_scores := Label.new()
		if absf(sec_val) > 1e-4:
			lbl_scores.text = "Obj1: %.2f  |  Obj2: %.2f" % [prim_val, sec_val]
		else:
			lbl_scores.text = "Objective: %.3f" % prim_val
		lbl_scores.add_theme_font_size_override("font_size", 11)
		lbl_scores.add_theme_color_override("font_color", TEXT)
		lbl_scores.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		top_line.add_child(lbl_scores)

		var btn_prev := Button.new()
		btn_prev.text = "👁 Preview"
		btn_prev.add_theme_font_size_override("font_size", 10)
		btn_prev.pressed.connect(func(): select_candidate_rank(captured_rank))
		top_line.add_child(btn_prev)

		var btn_apply := Button.new()
		btn_apply.text = "✔ Apply"
		btn_apply.add_theme_font_size_override("font_size", 10)
		btn_apply.pressed.connect(func():
			select_candidate_rank(captured_rank)
			_on_open_selected_in_main_canvas()
		)
		top_line.add_child(btn_apply)

		var lbl_summ := Label.new()
		lbl_summ.text = summ_str
		lbl_summ.add_theme_font_size_override("font_size", 11)
		lbl_summ.add_theme_color_override("font_color", MUTED)
		lbl_summ.clip_text = true
		row_vbox.add_child(lbl_summ)

func _update_snapshot_header() -> void:
	if _lbl_snapshot_title == null:
		return
	var cand := get_selected_candidate()
	if cand.is_empty():
		_lbl_snapshot_title.text = "(Select a Top-K solution)"
		return
	var rnk: int = int(cand.get("rank", _selected_rank))
	var summ: String = str(cand.get("decision_summary", "—"))
	_lbl_snapshot_title.text = "Rank #%d — %s" % [rnk, summ]
	_update_lightbox_title()

func _on_open_selected_in_main_canvas() -> void:
	var cand := get_selected_candidate()
	if cand.is_empty():
		return
	var rnk: int = int(cand.get("rank", _selected_rank))
	var cand_spec: Dictionary = get_selected_candidate_scenespec()
	if not cand_spec.is_empty():
		apply_solution_requested.emit(cand_spec, rnk)

# ─────────────────────────────────────────────────────────────────────────────
# Custom Chart 1: Convergence Trajectory (Best-So-Far + Current Evaluation)
# ─────────────────────────────────────────────────────────────────────────────

func _draw_convergence_chart(canvas: Control) -> void:
	var rect := Rect2(Vector2.ZERO, canvas.size)
	canvas.draw_rect(rect, Color("#0b111a"), true)
	canvas.draw_rect(rect, BORDER, false, 1.0)

	var font := ThemeDB.fallback_font
	if _convergence_history.is_empty():
		canvas.draw_string(font, Vector2(18, rect.size.y * 0.5), "Waiting for optimization evaluations...", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTED)
		return

	var pad_l := 48.0
	var pad_r := 14.0
	var pad_t := 22.0
	var pad_b := 22.0
	var plot_w := maxf(20.0, rect.size.x - pad_l - pad_r)
	var plot_h := maxf(20.0, rect.size.y - pad_t - pad_b)
	var plot_rect := Rect2(pad_l, pad_t, plot_w, plot_h)

	# Compute Y bounds from finite objective values
	var min_y := INF
	var max_y := -INF
	for pt in _convergence_history:
		if pt is Dictionary:
			var cur_v := float(pt.get("current_objective", 0.0))
			var bst_v := float(pt.get("best_objective", cur_v))
			if is_finite(cur_v) and absf(cur_v) < 1e6:
				min_y = minf(min_y, cur_v)
				max_y = maxf(max_y, cur_v)
			if is_finite(bst_v) and absf(bst_v) < 1e6:
				min_y = minf(min_y, bst_v)
				max_y = maxf(max_y, bst_v)

	if not is_finite(min_y) or not is_finite(max_y):
		min_y = 0.0
		max_y = 100.0
	if is_equal_approx(min_y, max_y):
		min_y -= 1.0
		max_y += 1.0
	var span_y := maxf(1e-4, max_y - min_y)

	# Grid lines
	for g in range(4):
		var frac := float(g) / 3.0
		var gy := plot_rect.position.y + frac * plot_rect.size.y
		canvas.draw_line(Vector2(plot_rect.position.x, gy), Vector2(plot_rect.end.x, gy), Color(0.18, 0.25, 0.35, 0.5), 1.0)
		var val_lbl := max_y - frac * span_y
		canvas.draw_string(font, Vector2(4, gy + 4), "%.1f" % val_lbl, HORIZONTAL_ALIGNMENT_LEFT, int(pad_l - 6), 9, MUTED)

	var n_pts := _convergence_history.size()
	var denom_x := float(max(1, n_pts - 1))
	var cur_poly: PackedVector2Array = []
	var best_poly: PackedVector2Array = []

	for i in range(n_pts):
		var pt = _convergence_history[i]
		if not (pt is Dictionary):
			continue
		var px := plot_rect.position.x + (float(i) / denom_x) * plot_rect.size.x
		var cur_v := clampf(float(pt.get("current_objective", min_y)), min_y, max_y)
		var bst_v := clampf(float(pt.get("best_objective", cur_v)), min_y, max_y)
		var cy := plot_rect.end.y - ((cur_v - min_y) / span_y) * plot_rect.size.y
		var by := plot_rect.end.y - ((bst_v - min_y) / span_y) * plot_rect.size.y

		cur_poly.append(Vector2(px, cy))
		best_poly.append(Vector2(px, by))

		var is_feas := bool(pt.get("is_feasible", true))
		canvas.draw_circle(Vector2(px, cy), 2.5, LIVE_GREEN if is_feas else DANGER)

	if cur_poly.size() >= 2:
		canvas.draw_polyline(cur_poly, Color(WARNING.r, WARNING.g, WARNING.b, 0.45), 1.3, true)
	if best_poly.size() >= 2:
		canvas.draw_polyline(best_poly, ACCENT, 2.4, true)

	# Legend & X-axis labels
	canvas.draw_string(font, Vector2(plot_rect.position.x, rect.size.y - 5), "Eval 1", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, MUTED)
	canvas.draw_string(font, Vector2(plot_rect.end.x - 52, rect.size.y - 5), "Eval %d" % n_pts, HORIZONTAL_ALIGNMENT_RIGHT, 52, 9, MUTED)
	canvas.draw_string(font, Vector2(plot_rect.end.x - 240, 14), "━ Best-So-Far   • Feasible   • Infeasible", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, ACCENT)

# ─────────────────────────────────────────────────────────────────────────────
# Custom Chart 2: 2D Pareto Front & Objective Trade-Off Scatter
# ─────────────────────────────────────────────────────────────────────────────

func _draw_scatter_chart(canvas: Control) -> void:
	var rect := Rect2(Vector2.ZERO, canvas.size)
	canvas.draw_rect(rect, Color("#0b111a"), true)
	canvas.draw_rect(rect, BORDER, false, 1.0)

	var font := ThemeDB.fallback_font
	if _scatter_points.is_empty():
		canvas.draw_string(font, Vector2(18, rect.size.y * 0.5), "Waiting for trade-off scatter points...", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTED)
		return

	var pad_l := 48.0
	var pad_r := 14.0
	var pad_t := 20.0
	var pad_b := 22.0
	var plot_rect := Rect2(pad_l, pad_t, maxf(20.0, rect.size.x - pad_l - pad_r), maxf(20.0, rect.size.y - pad_t - pad_b))

	var min_x := INF
	var max_x := -INF
	var min_y := INF
	var max_y := -INF

	for i in range(_scatter_points.size()):
		var pt = _scatter_points[i]
		if pt is Dictionary:
			var xv := float(pt.get("secondary_objective", 0.0))
			if absf(xv) < 1e-6:
				xv = float(pt.get("iteration", i + 1))
			var yv := float(pt.get("primary_objective", 0.0))
			if is_finite(xv) and is_finite(yv) and absf(yv) < 1e6:
				min_x = minf(min_x, xv)
				max_x = maxf(max_x, xv)
				min_y = minf(min_y, yv)
				max_y = maxf(max_y, yv)

	if not is_finite(min_x) or not is_finite(min_y):
		return
	if is_equal_approx(min_x, max_x):
		min_x -= 1.0
		max_x += 1.0
	if is_equal_approx(min_y, max_y):
		min_y -= 1.0
		max_y += 1.0
	var span_x := maxf(1e-4, max_x - min_x)
	var span_y := maxf(1e-4, max_y - min_y)

	# Grid lines
	for g in range(3):
		var frac := float(g) / 2.0
		var gy := plot_rect.position.y + frac * plot_rect.size.y
		canvas.draw_line(Vector2(plot_rect.position.x, gy), Vector2(plot_rect.end.x, gy), Color(0.18, 0.25, 0.35, 0.45), 1.0)
		var val_y := max_y - frac * span_y
		canvas.draw_string(font, Vector2(4, gy + 4), "%.1f" % val_y, HORIZONTAL_ALIGNMENT_LEFT, int(pad_l - 6), 9, MUTED)

	var feas_screen_pts: Array = []
	var best_screen_pt := Vector2.ZERO
	var best_yv := INF

	for i in range(_scatter_points.size()):
		var pt = _scatter_points[i]
		if not (pt is Dictionary):
			continue
		var xv := float(pt.get("secondary_objective", 0.0))
		if absf(xv) < 1e-6:
			xv = float(pt.get("iteration", i + 1))
		var yv := float(pt.get("primary_objective", 0.0))
		if not is_finite(xv) or not is_finite(yv) or absf(yv) >= 1e6:
			continue

		var sx := plot_rect.position.x + ((xv - min_x) / span_x) * plot_rect.size.x
		var sy := plot_rect.end.y - ((yv - min_y) / span_y) * plot_rect.size.y
		var s_pt := Vector2(sx, sy)
		var is_feas := bool(pt.get("is_feasible", true))

		if is_feas:
			feas_screen_pts.append({"x": xv, "y": yv, "pos": s_pt})
			canvas.draw_circle(s_pt, 3.2, BLUE)
			if yv < best_yv:
				best_yv = yv
				best_screen_pt = s_pt
		else:
			canvas.draw_circle(s_pt, 2.6, Color(DANGER.r, DANGER.g, DANGER.b, 0.65))

	# Connect non-dominated Pareto front across feasible points
	if feas_screen_pts.size() >= 2:
		feas_screen_pts.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
		var pareto_poly: PackedVector2Array = []
		var running_min_y := INF
		for fp in feas_screen_pts:
			var fy := float(fp["y"])
			if fy <= running_min_y + 1e-4:
				running_min_y = fy
				pareto_poly.append(fp["pos"])
		if pareto_poly.size() >= 2:
			canvas.draw_polyline(pareto_poly, ACCENT, 1.8, true)

	if best_yv < INF:
		canvas.draw_arc(best_screen_pt, 6.5, 0.0, TAU, 20, GOLD, 2.0)
		canvas.draw_string(font, best_screen_pt + Vector2(8, 4), "★ #1", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, GOLD)

	canvas.draw_string(font, Vector2(plot_rect.position.x, rect.size.y - 5), "Min X: %.1f" % min_x, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, MUTED)
	canvas.draw_string(font, Vector2(plot_rect.end.x - 80, rect.size.y - 5), "Max X: %.1f" % max_x, HORIZONTAL_ALIGNMENT_RIGHT, 80, 9, MUTED)

# ─────────────────────────────────────────────────────────────────────────────
# Custom Chart 3: Constraint & SLA Margin Comparison Bars
# ─────────────────────────────────────────────────────────────────────────────

func _draw_sla_chart(canvas: Control) -> void:
	var rect := Rect2(Vector2.ZERO, canvas.size)
	canvas.draw_rect(rect, Color("#0b111a"), true)
	canvas.draw_rect(rect, BORDER, false, 1.0)

	var font := ThemeDB.fallback_font
	if _top_k_solutions.is_empty():
		canvas.draw_string(font, Vector2(18, rect.size.y * 0.5), "Waiting for Top-K SLA & constraint margins...", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTED)
		return

	var n_bars := mini(5, _top_k_solutions.size())
	var pad_l := 68.0
	var pad_r := 110.0
	var pad_t := 10.0
	var pad_b := 10.0
	var track_w := maxf(40.0, rect.size.x - pad_l - pad_r)
	var row_h := maxf(16.0, (rect.size.y - pad_t - pad_b) / float(max(1, n_bars)))

	# Threshold line at 80% of track width (= 100% of SLA/budget limit)
	var thresh_x := pad_l + track_w * 0.80
	var y_cur := pad_t
	while y_cur < rect.size.y - pad_b:
		canvas.draw_line(Vector2(thresh_x, y_cur), Vector2(thresh_x, minf(y_cur + 5.0, rect.size.y - pad_b)), DANGER, 1.5)
		y_cur += 9.0

	var max_prim := 1.0
	for i in range(n_bars):
		var c = _top_k_solutions[i]
		if c is Dictionary:
			max_prim = maxf(max_prim, float(c.get("primary_objective", 1.0)))

	for i in range(n_bars):
		var c = _top_k_solutions[i]
		if not (c is Dictionary):
			continue
		var rnk: int = int(c.get("rank", i + 1))
		var is_feas: bool = bool(c.get("is_feasible", true))
		var viol: float = float(c.get("constraint_violation", 0.0))
		var prim: float = float(c.get("primary_objective", 0.0))

		# Utilization ratio relative to threshold (<= 0.80 track_w when feasible, > 0.80 when infeasible)
		var util_ratio := 0.0
		if is_feas:
			util_ratio = clampf((prim / maxf(1e-4, max_prim)) * 0.76, 0.15, 0.79)
		else:
			util_ratio = clampf(0.82 + minf(0.18, viol * 0.02), 0.82, 1.0)

		var by := pad_t + float(i) * row_h + 2.0
		var bh := maxf(10.0, row_h - 5.0)
		canvas.draw_string(font, Vector2(8, by + bh - 2), "Rank #%d" % rnk, HORIZONTAL_ALIGNMENT_LEFT, 56, 10, GOLD if rnk == _selected_rank else TEXT)
		canvas.draw_rect(Rect2(pad_l, by, track_w, bh), Color("#141e2c"), true)

		var bar_col := LIVE_GREEN if is_feas else DANGER
		if rnk == _selected_rank and is_feas:
			bar_col = ACCENT
		canvas.draw_rect(Rect2(pad_l, by, track_w * util_ratio, bh), bar_col, true)
		var status_txt := ("Obj: %.2f (OK)" % prim) if is_feas else ("Viol: +%.1f" % viol)
		canvas.draw_string(font, Vector2(pad_l + track_w + 6, by + bh - 2), status_txt, HORIZONTAL_ALIGNMENT_LEFT, 100, 9, LIVE_GREEN if is_feas else DANGER)

# ─────────────────────────────────────────────────────────────────────────────
# 2D Schematic Snapshot Renderer (Preview Card & Full-Size Lightbox)
# ─────────────────────────────────────────────────────────────────────────────

func _draw_scenespec_schematic(canvas: Control, spec_dict: Dictionary, zoom: float, pan: Vector2, is_large: bool) -> void:
	var rect := Rect2(Vector2.ZERO, canvas.size)
	canvas.draw_rect(rect, Color("#090f17"), true)
	canvas.draw_rect(rect, BORDER, false, 1.0)

	var font := ThemeDB.fallback_font
	var elems: Array = spec_dict.get("elements", []) if spec_dict.get("elements") is Array else []
	var conns: Array = spec_dict.get("connections", []) if spec_dict.get("connections") is Array else []

	if elems.is_empty():
		canvas.draw_string(font, Vector2(20, rect.size.y * 0.5), "No candidate SceneSpec selected for schematic preview.", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTED)
		return

	# Subtle background grid
	var grid_step := 28.0 * zoom
	if grid_step >= 10.0:
		var gx := fposmod(pan.x, grid_step)
		while gx < rect.size.x:
			canvas.draw_line(Vector2(gx, 0), Vector2(gx, rect.size.y), Color(0.12, 0.18, 0.26, 0.4), 1.0)
			gx += grid_step
		var gy := fposmod(pan.y, grid_step)
		while gy < rect.size.y:
			canvas.draw_line(Vector2(0, gy), Vector2(rect.size.x, gy), Color(0.12, 0.18, 0.26, 0.4), 1.0)
			gy += grid_step

	# Extract world 2D coordinates (in meters) for each element
	var pos_by_id: Dictionary = {}
	var elem_by_id: Dictionary = {}
	var conv_curves_by_id: Dictionary = {}
	var min_p := Vector2(1e9, 1e9)
	var max_p := Vector2(-1e9, -1e9)

	for e in elems:
		if not (e is Dictionary):
			continue
		var eid := str(e.get("id", ""))
		if eid.is_empty():
			continue
		elem_by_id[eid] = e
		var px := 0.0
		var py := 0.0
		if e.get("transform") is Dictionary and e["transform"].get("position") is Array:
			var p_arr: Array = e["transform"]["position"]
			if p_arr.size() >= 2:
				px = float(p_arr[0])
				py = float(p_arr[1])
		elif e.get("editor") is Dictionary and e["editor"].get("graph_position") is Array:
			var gp: Array = e["editor"]["graph_position"]
			if gp.size() >= 2:
				px = float(gp[0]) / 20.0
				py = float(gp[1]) / 20.0
		var pt := Vector2(px, py)
		var kind_lc := str(e.get("kind", "")).to_lower()
		if kind_lc == "conveyor":
			var pts_m := ConveyorCurve3D.sample_2d_polyline(e, null, 28)
			if pts_m.size() >= 2:
				conv_curves_by_id[eid] = pts_m
				pt = pts_m[pts_m.size() / 2]
				for cp_m in pts_m:
					min_p.x = minf(min_p.x, cp_m.x)
					min_p.y = minf(min_p.y, cp_m.y)
					max_p.x = maxf(max_p.x, cp_m.x)
					max_p.y = maxf(max_p.y, cp_m.y)
		pos_by_id[eid] = pt
		min_p.x = minf(min_p.x, pt.x)
		min_p.y = minf(min_p.y, pt.y)
		max_p.x = maxf(max_p.x, pt.x)
		max_p.y = maxf(max_p.y, pt.y)

	var pad_px := 48.0 if is_large else 32.0
	var avail_w := maxf(40.0, rect.size.x - pad_px * 2.0)
	var avail_h := maxf(40.0, rect.size.y - pad_px * 2.0)
	var span_x := maxf(6.0, max_p.x - min_p.x)
	var span_y := maxf(4.0, max_p.y - min_p.y)
	var scale_m := minf(avail_w / span_x, avail_h / span_y) * zoom
	var center_world := (min_p + max_p) * 0.5
	var center_screen := (rect.size * 0.5) + pan

	var screen_pos: Dictionary = {}
	for eid in pos_by_id.keys():
		var w_pt: Vector2 = pos_by_id[eid]
		screen_pos[eid] = center_screen + (w_pt - center_world) * scale_m

	# 0. Draw physical curved/joined conveyor belt tracks
	for cid in conv_curves_by_id.keys():
		var pts_m: PackedVector2Array = conv_curves_by_id[cid]
		var pts_scr := PackedVector2Array()
		for pm in pts_m:
			pts_scr.append(center_screen + (pm - center_world) * scale_m)
		var belt_w: float = clampf(1.2 * scale_m, 6.0, 18.0)
		canvas.draw_polyline(pts_scr, Color("#13202d"), belt_w, true)
		canvas.draw_polyline(pts_scr, Color("#9b59b6"), clampf(belt_w * 0.35, 2.0, 4.5), true)
		var n_scr: int = pts_scr.size()
		for s_idx in [n_scr / 4, n_scr / 2, (n_scr * 3) / 4]:
			if s_idx > 0 and s_idx < n_scr:
				_draw_arrow_tip(canvas, pts_scr[s_idx - 1], pts_scr[s_idx], Color("#2ecc71"))
		canvas.draw_circle(pts_scr[0], clampf(belt_w * 0.4, 3.0, 6.0), Color("#2ecc71"))
		canvas.draw_circle(pts_scr[n_scr - 1], clampf(belt_w * 0.4, 3.0, 6.0), Color("#2ecc71"))

	# 1. Draw directed connections (wires & arrows)
	for c in conns:
		if not (c is Dictionary):
			continue
		var src_id := str(c.get("source_element", ""))
		var tgt_id := str(c.get("target_element", ""))
		if not screen_pos.has(src_id) or not screen_pos.has(tgt_id):
			continue
		if conv_curves_by_id.has(src_id) and conv_curves_by_id.has(tgt_id):
			continue
		var p1: Vector2 = screen_pos[src_id]
		var p2: Vector2 = screen_pos[tgt_id]
		if conv_curves_by_id.has(src_id):
			var c_pts: PackedVector2Array = conv_curves_by_id[src_id]
			var s_in := center_screen + (c_pts[0] - center_world) * scale_m
			var s_out := center_screen + (c_pts[c_pts.size() - 1] - center_world) * scale_m
			p1 = s_in if s_in.distance_squared_to(p2) <= s_out.distance_squared_to(p2) else s_out
		elif conv_curves_by_id.has(tgt_id):
			var c_pts: PackedVector2Array = conv_curves_by_id[tgt_id]
			var t_in := center_screen + (c_pts[0] - center_world) * scale_m
			var t_out := center_screen + (c_pts[c_pts.size() - 1] - center_world) * scale_m
			p2 = t_in if t_in.distance_squared_to(p1) <= t_out.distance_squared_to(p1) else t_out
		if p1.distance_squared_to(p2) < 4.0:
			continue

		var is_back_edge: bool = (p2.x < p1.x - 4.0) and not (conv_curves_by_id.has(src_id) or conv_curves_by_id.has(tgt_id))
		var wire_col := ACCENT if is_back_edge else Color("#2ecc71")
		var wire_w := (2.4 if is_large else 1.8)

		if is_back_edge:
			# Curved arc for recirculation / loop closure edge so it stands out clearly
			var mid := (p1 + p2) * 0.5 + Vector2(0, -34.0 * zoom)
			var arc_pts: PackedVector2Array = []
			for s in range(17):
				var t := float(s) / 16.0
				var q0 := p1.lerp(mid, t)
				var q1 := mid.lerp(p2, t)
				arc_pts.append(q0.lerp(q1, t))
			canvas.draw_polyline(arc_pts, wire_col, wire_w, true)
			_draw_arrow_tip(canvas, arc_pts[arc_pts.size() - 2], p2, wire_col)
		else:
			canvas.draw_line(p1, p2, wire_col, wire_w, true)
			_draw_arrow_tip(canvas, p1, p2, wire_col)

	# 2. Draw element blocks & badges
	var box_w := (58.0 if is_large else 42.0) * clampf(zoom, 0.75, 1.6)
	var box_h := (32.0 if is_large else 22.0) * clampf(zoom, 0.75, 1.6)
	var font_sz := 11 if is_large else 9

	for eid in screen_pos.keys():
		var e: Dictionary = elem_by_id[eid]
		var kind := str(e.get("kind", "server")).to_lower()
		var sp: Vector2 = screen_pos[eid]
		var b_rect := Rect2(sp - Vector2(box_w * 0.5, box_h * 0.5), Vector2(box_w, box_h))

		var col := _color_for_kind(kind)
		canvas.draw_rect(b_rect, Color(col.r * 0.22, col.g * 0.22, col.b * 0.22, 0.94), true)
		canvas.draw_rect(b_rect, col, false, 1.8)

		var props: Dictionary = e.get("properties", {}) if e.get("properties") is Dictionary else {}
		var badge := ""
		if kind == "server":
			badge = "c=%d" % int(props.get("servers", 1))
		elif kind == "conveyor":
			badge = "%.0fm" % float(props.get("length", 10.0))
		elif kind == "queue":
			badge = str(props.get("discipline", "fifo")).to_upper().substr(0, 4)

		var label_txt: String = str(eid)
		if not badge.is_empty():
			label_txt = "%s (%s)" % [eid, badge]
		canvas.draw_string(font, Vector2(b_rect.position.x + 3, b_rect.position.y + box_h * 0.62), label_txt, HORIZONTAL_ALIGNMENT_CENTER, int(box_w - 6), font_sz, TEXT)

	if not is_large:
		canvas.draw_string(font, Vector2(8, rect.size.y - 6), "🔍 Click snapshot to open full-size zoomable view", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, MUTED)

func _draw_arrow_tip(canvas: Control, from_pt: Vector2, to_pt: Vector2, col: Color) -> void:
	var seg := to_pt - from_pt
	if seg.length_squared() < 4.0:
		return
	var dir := seg.normalized()
	var tip := to_pt - dir * 14.0
	var perp := Vector2(-dir.y, dir.x) * 4.5
	var a1 := tip - dir * 8.0 + perp
	var a2 := tip - dir * 8.0 - perp
	if absf((a1 - tip).cross(a2 - tip)) > 0.5:
		canvas.draw_colored_polygon(PackedVector2Array([tip, a1, a2]), col)

func _color_for_kind(kind: String) -> Color:
	match kind:
		"source": return WARNING
		"queue": return BLUE
		"server": return LIVE_GREEN
		"conveyor": return PURPLE
		"sink": return DANGER
		_: return MUTED

# ─────────────────────────────────────────────────────────────────────────────
# Helpers & Window Dragging
# ─────────────────────────────────────────────────────────────────────────────

func _apply_decision_dict_preview(spec_dict: Dictionary, dec: Dictionary) -> void:
	if dec.is_empty() or not (spec_dict.get("elements") is Array):
		return
	var opt: Dictionary = spec_dict.get("optimization", {}) if spec_dict.get("optimization") is Dictionary else {}
	var dvars: Array = opt.get("decision_variables", []) if opt.get("decision_variables") is Array else []
	var elem_map: Dictionary = {}
	for e in spec_dict["elements"]:
		if e is Dictionary and e.has("id"):
			elem_map[str(e["id"])] = e
	for dv in dvars:
		if dv is Dictionary:
			var vid := str(dv.get("id", ""))
			var eid := str(dv.get("element_id", ""))
			var prop := str(dv.get("property", ""))
			if dec.has(vid) and elem_map.has(eid):
				var target_e: Dictionary = elem_map[eid]
				if not (target_e.get("properties") is Dictionary):
					target_e["properties"] = {}
				target_e["properties"][prop] = dec[vid]

func _refresh_header_from_doc() -> void:
	if doc_store == null or doc_store.active_document == null:
		return
	var opt: Dictionary = doc_store.get_optimization_spec()
	if not opt.is_empty():
		var t_str := str(opt.get("title", ""))
		var c_str := str(opt.get("problem_class", "parameter"))
		if _lbl_problem_title != null and not t_str.is_empty():
			_lbl_problem_title.text = t_str
		if _lbl_class_badge != null and not c_str.is_empty():
			_lbl_class_badge.text = "[%s]" % c_str.to_upper()

func _redraw_all_canvases() -> void:
	if _conv_chart != null:
		_conv_chart.queue_redraw()
	if _scatter_chart != null:
		_scatter_chart.queue_redraw()
	if _sla_chart != null:
		_sla_chart.queue_redraw()
	if _snapshot_canvas != null:
		_snapshot_canvas.queue_redraw()
	if _lightbox_canvas != null and is_lightbox_visible():
		_lightbox_canvas.queue_redraw()

func _make_card_panel() -> PanelContainer:
	var p := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = PANEL
	s.border_color = BORDER
	s.set_border_width_all(1)
	s.set_corner_radius_all(6)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	p.add_theme_stylebox_override("panel", s)
	return p

func _on_report_header_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging_report = true
				_drag_offset_report = mb.global_position - _report_panel.global_position
				move_to_front()
			else:
				_dragging_report = false
	elif event is InputEventMouseMotion and _dragging_report:
		var mm := event as InputEventMouseMotion
		_report_panel.global_position = mm.global_position - _drag_offset_report

func _on_lightbox_header_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging_lightbox = true
				_drag_offset_lightbox = mb.global_position - _lightbox_panel.global_position
				move_to_front()
			else:
				_dragging_lightbox = false
	elif event is InputEventMouseMotion and _dragging_lightbox:
		var mm := event as InputEventMouseMotion
		_lightbox_panel.global_position = mm.global_position - _drag_offset_lightbox
