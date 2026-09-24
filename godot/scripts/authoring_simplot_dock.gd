class_name AuthoringSimplotDock
extends PanelContainer

signal closed

const BG := Color("#0b0f14")
const PANEL := Color("#121820")
const BORDER := Color("#222d3d")
const TEXT := Color("#e6edf3")
const MUTED := Color("#8b949e")
const ACCENT := Color("#58a6ff")
const GREEN := Color("#3fb950")
const AMBER := Color("#d29922")
const RED := Color("#f85149")
const PURPLE := Color("#bc8cff")

const SERIES_COLORS := [
	Color("#58a6ff"), # blue
	Color("#3fb950"), # green
	Color("#d29922"), # amber
	Color("#bc8cff"), # purple
	Color("#f85149"), # red
	Color("#39c5cf"), # cyan
	Color("#e3b341"), # yellow
	Color("#f0883e"), # orange
]

enum PlotTab {
	QUEUES,
	UTILIZATION,
	THROUGHPUT,
	CYCLE_TIME,
	STATE_SPACE_3D
}

class WaveformCanvas extends Control:
	var dock: AuthoringSimplotDock
	func _init(p_dock: AuthoringSimplotDock) -> void:
		dock = p_dock
	func _draw() -> void:
		if dock != null:
			dock._render_plot(self)

var current_tab: PlotTab = PlotTab.QUEUES
var is_frozen: bool = false
var time_window_seconds: float = 60.0
const MAX_POINTS_PER_SERIES: int = 600

# Backend selection: ImPlot native GDExtension vs Native Godot Canvas
var use_implot: bool = true
var _has_implot: bool = false
var _simplot_view: Control = null

# Series data: key -> Array of { "t": float, "val": float }
var _series: Dictionary = {}
var _series_meta: Dictionary = {} # key -> { "label": String, "color": Color, "unit": String }

# UI elements
var _tab_queues_btn: Button
var _tab_util_btn: Button
var _tab_thru_btn: Button
var _tab_cycle_btn: Button
var _tab_3d_btn: Button
var _backend_btn: Button
var _freeze_btn: Button
var _clear_btn: Button
var _plot_canvas: WaveformCanvas
var _legend_label: Label
var _status_label: Label

var _hover_pos: Vector2 = Vector2(-1, -1)
var _is_hovered: bool = false
var _latest_sim_t: float = 0.0

func _init() -> void:
	custom_minimum_size.y = 200
	_has_implot = ClassDB.class_exists("SimPlotView")
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = BORDER
	style.border_width_top = 2
	style.border_width_bottom = 1
	add_theme_stylebox_override("panel", style)

func _ready() -> void:
	_build_ui()

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	# 1. Header Toolbar
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	header.add_theme_constant_override("margin_left", 8)
	header.add_theme_constant_override("margin_right", 8)
	header.add_theme_constant_override("margin_top", 4)
	vbox.add_child(header)

	var title := Label.new()
	title.text = "📈 LIVE WAVEFORMS"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", ACCENT)
	header.add_child(title)

	header.add_child(VSeparator.new())

	# Tab buttons
	_tab_queues_btn = Button.new()
	_tab_queues_btn.text = "Queues Nq(t)"
	_tab_queues_btn.pressed.connect(func(): _switch_tab(PlotTab.QUEUES))
	header.add_child(_tab_queues_btn)

	_tab_util_btn = Button.new()
	_tab_util_btn.text = "Utilization ρ(t)"
	_tab_util_btn.pressed.connect(func(): _switch_tab(PlotTab.UTILIZATION))
	header.add_child(_tab_util_btn)

	_tab_thru_btn = Button.new()
	_tab_thru_btn.text = "Throughput λ(t)"
	_tab_thru_btn.pressed.connect(func(): _switch_tab(PlotTab.THROUGHPUT))
	header.add_child(_tab_thru_btn)

	_tab_cycle_btn = Button.new()
	_tab_cycle_btn.text = "Cycle Time W(t)"
	_tab_cycle_btn.pressed.connect(func(): _switch_tab(PlotTab.CYCLE_TIME))
	header.add_child(_tab_cycle_btn)

	if _has_implot:
		_tab_3d_btn = Button.new()
		_tab_3d_btn.text = "3D State Space"
		_tab_3d_btn.tooltip_text = "3D Phase Trajectory: Queue vs Utilization vs WIP"
		_tab_3d_btn.pressed.connect(func(): _switch_tab(PlotTab.STATE_SPACE_3D))
		header.add_child(_tab_3d_btn)

	if _has_implot:
		header.add_child(VSeparator.new())
		_backend_btn = Button.new()
		_backend_btn.text = "⚡ ImPlot (Native)" if use_implot else "🎨 Canvas (Godot)"
		_backend_btn.tooltip_text = "Toggle between Native ImPlot/ImPlot3D C++ engine and Godot Canvas renderer"
		_backend_btn.pressed.connect(_toggle_backend)
		header.add_child(_backend_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_status_label = Label.new()
	_status_label.text = "Window: 60s | 0 pts"
	_status_label.add_theme_font_size_override("font_size", 10)
	_status_label.add_theme_color_override("font_color", MUTED)
	header.add_child(_status_label)

	_freeze_btn = Button.new()
	_freeze_btn.text = "⏸ Freeze"
	_freeze_btn.tooltip_text = "Freeze chart scrolling for detailed inspection"
	_freeze_btn.pressed.connect(_toggle_freeze)
	header.add_child(_freeze_btn)

	_clear_btn = Button.new()
	_clear_btn.text = "⟲ Clear"
	_clear_btn.tooltip_text = "Clear time-series history"
	_clear_btn.pressed.connect(clear_all)
	header.add_child(_clear_btn)

	var btn_close := Button.new()
	btn_close.text = "✕"
	btn_close.tooltip_text = "Close waveform dock"
	btn_close.pressed.connect(func(): closed.emit())
	header.add_child(btn_close)

	# 2. Main Plot Drawing Canvas Container
	var plot_container := Control.new()
	plot_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plot_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(plot_container)

	_plot_canvas = WaveformCanvas.new(self)
	_plot_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_plot_canvas.mouse_filter = Control.MOUSE_FILTER_PASS
	_plot_canvas.gui_input.connect(_on_canvas_gui_input)
	_plot_canvas.mouse_entered.connect(func(): _is_hovered = true; _plot_canvas.queue_redraw())
	_plot_canvas.mouse_exited.connect(func(): _is_hovered = false; _plot_canvas.queue_redraw())
	plot_container.add_child(_plot_canvas)

	if _has_implot:
		_simplot_view = ClassDB.instantiate("SimPlotView")
		_simplot_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_simplot_view.visible = use_implot
		_plot_canvas.visible = !use_implot
		plot_container.add_child(_simplot_view)

	# 3. Legend / Status Strip
	_legend_label = Label.new()
	_legend_label.text = "No active series data"
	_legend_label.add_theme_font_size_override("font_size", 11)
	_legend_label.add_theme_color_override("font_color", MUTED)
	_legend_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_legend_label.clip_text = true
	vbox.add_child(_legend_label)

	_update_tab_styles()

func _switch_tab(tab: PlotTab) -> void:
	current_tab = tab
	_update_tab_styles()
	_sync_simplot_view()
	if _plot_canvas != null:
		_plot_canvas.queue_redraw()

func _update_tab_styles() -> void:
	if _tab_queues_btn == null: return
	_tab_queues_btn.modulate = Color(1.3, 1.3, 1.3, 1.0) if current_tab == PlotTab.QUEUES else Color(0.7, 0.7, 0.7, 1.0)
	_tab_util_btn.modulate = Color(1.3, 1.3, 1.3, 1.0) if current_tab == PlotTab.UTILIZATION else Color(0.7, 0.7, 0.7, 1.0)
	_tab_thru_btn.modulate = Color(1.3, 1.3, 1.3, 1.0) if current_tab == PlotTab.THROUGHPUT else Color(0.7, 0.7, 0.7, 1.0)
	_tab_cycle_btn.modulate = Color(1.3, 1.3, 1.3, 1.0) if current_tab == PlotTab.CYCLE_TIME else Color(0.7, 0.7, 0.7, 1.0)
	if _tab_3d_btn != null:
		_tab_3d_btn.modulate = Color(1.3, 1.3, 1.3, 1.0) if current_tab == PlotTab.STATE_SPACE_3D else Color(0.7, 0.7, 0.7, 1.0)

func _toggle_backend() -> void:
	use_implot = !use_implot
	if _backend_btn != null:
		_backend_btn.text = "⚡ ImPlot (Native)" if use_implot else "🎨 Canvas (Godot)"
	if _simplot_view != null:
		_simplot_view.visible = use_implot
	if _plot_canvas != null:
		_plot_canvas.visible = !use_implot
		_plot_canvas.queue_redraw()
	_sync_simplot_view()

func _toggle_freeze() -> void:
	is_frozen = !is_frozen
	if _freeze_btn != null:
		_freeze_btn.text = "▶ Resume" if is_frozen else "⏸ Freeze"
		_freeze_btn.modulate = AMBER if is_frozen else Color.WHITE

func clear_all() -> void:
	_series.clear()
	_series_meta.clear()
	if _simplot_view != null:
		_simplot_view.clear_all()
	if _plot_canvas != null:
		_plot_canvas.queue_redraw()
	if _legend_label != null:
		_legend_label.text = "History cleared"

func _get_active_series_keys() -> Array:
	var active_keys: Array = []
	for k in _series.keys():
		if current_tab == PlotTab.QUEUES and (k.begins_with("q_") or k.begins_with("conv_") or k == "sys_wip"):
			active_keys.append(k)
		elif current_tab == PlotTab.UTILIZATION and k.begins_with("srv_util_"):
			active_keys.append(k)
		elif current_tab == PlotTab.THROUGHPUT and (k == "sys_throughput" or k.begins_with("q_")):
			active_keys.append(k)
		elif current_tab == PlotTab.CYCLE_TIME and k == "sys_sojourn":
			active_keys.append(k)
	return active_keys

func _sync_simplot_view() -> void:
	if not _has_implot or _simplot_view == null or not _simplot_view.visible:
		return

	if current_tab == PlotTab.STATE_SPACE_3D:
		_simplot_view.set_3d_mode(true)
		_simplot_view.set_plot_title("3D State Space (Queue Nq × Utilization ρ × System WIP)")
		
		# Build 3D phase trajectory from queue, util, and wip
		var q_arr: Array = []
		var u_arr: Array = []
		var w_arr: Array = []
		for k in _series:
			if k.begins_with("q_") and q_arr.is_empty():
				q_arr = _series[k]
			elif k.begins_with("srv_util_") and u_arr.is_empty():
				u_arr = _series[k]
			elif k == "sys_wip" and w_arr.is_empty():
				w_arr = _series[k]
		
		var n_pts: int = mini(q_arr.size(), mini(u_arr.size(), w_arr.size()))
		if n_pts > 0:
			var xs := PackedFloat32Array()
			var ys := PackedFloat32Array()
			var zs := PackedFloat32Array()
			xs.resize(n_pts)
			ys.resize(n_pts)
			zs.resize(n_pts)
			for i in range(n_pts):
				xs[i] = float(q_arr[i].get("val", 0.0))
				ys[i] = float(u_arr[i].get("val", 0.0))
				zs[i] = float(w_arr[i].get("val", 0.0))
			_simplot_view.set_series_3d("PhaseTrajectory", xs, ys, zs)
		return

	_simplot_view.set_3d_mode(false)
	var active_keys: Array = _get_active_series_keys()
	var tab_title: String = ""
	var y_axis: String = ""

	match current_tab:
		PlotTab.QUEUES:
			tab_title = "Queue Lengths Nq(t)"
			y_axis = "Items"
		PlotTab.UTILIZATION:
			tab_title = "Server Utilization ρ(t)"
			y_axis = "Percent (%)"
		PlotTab.THROUGHPUT:
			tab_title = "System & Infeed Throughput λ(t)"
			y_axis = "Parts / s"
		PlotTab.CYCLE_TIME:
			tab_title = "Cycle & Sojourn Time W(t)"
			y_axis = "Seconds"

	var t_end: float = max(time_window_seconds, _latest_sim_t)
	var t_start: float = max(0.0, t_end - time_window_seconds)

	_simplot_view.set_plot_title(tab_title)
	_simplot_view.set_x_label("Sim Time (s)")
	_simplot_view.set_y_label(y_axis)
	_simplot_view.set_x_limits(t_start, t_end)
	if current_tab == PlotTab.UTILIZATION:
		_simplot_view.set_y_limits(0.0, 100.0)
	else:
		_simplot_view.set_auto_fit(true)

	for k in active_keys:
		var arr: Array = _series.get(k, [])
		if arr.is_empty(): continue
		var meta: Dictionary = _series_meta.get(k, {})
		var lbl: String = meta.get("label", k)
		var xs := PackedFloat32Array()
		var ys := PackedFloat32Array()
		xs.resize(arr.size())
		ys.resize(arr.size())
		for i in range(arr.size()):
			xs[i] = float(arr[i].get("t", 0.0))
			ys[i] = float(arr[i].get("val", 0.0))
		_simplot_view.set_series_2d(lbl, xs, ys)

func feed_point(series_id: String, label: String, t: float, val: float, color: Color, unit: String = "") -> void:
	if is_frozen: return
	_latest_sim_t = max(_latest_sim_t, t)
	if not _series.has(series_id):
		_series[series_id] = []
		_series_meta[series_id] = {
			"label": label,
			"color": color,
			"unit": unit
		}
	var arr: Array = _series[series_id]
	arr.append({"t": t, "val": val})
	if arr.size() > MAX_POINTS_PER_SERIES:
		arr.pop_front()

## Ingest incoming simulation snapshot telemetry
func feed_telemetry(t: float, elements_by_id: Dictionary, global_kpis: Dictionary) -> void:
	if is_frozen: return
	_latest_sim_t = max(_latest_sim_t, t)

	var color_idx: int = 0
	for elem_id in elements_by_id:
		var elem = elements_by_id[elem_id]
		var type_str: String = str(elem.get("type", "")).to_lower()
		var metrics: Dictionary = elem.get("metrics", {})

		# 1. Queue lengths
		if "queue" in type_str:
			var qlen: float = float(metrics.get("queue_length", 0))
			var col: Color = SERIES_COLORS[color_idx % SERIES_COLORS.size()]
			feed_point("q_" + elem_id, elem_id + " (Queue)", t, qlen, col, "items")
			color_idx += 1

		# 2. Server utilization
		elif "server" in type_str or "workstation" in type_str:
			var util: float = float(metrics.get("utilization", 0.0)) * 100.0
			var col: Color = SERIES_COLORS[color_idx % SERIES_COLORS.size()]
			feed_point("srv_util_" + elem_id, elem_id + " Util", t, util, col, "%")
			color_idx += 1

		# 3. Conveyors (transit count)
		elif "conveyor" in type_str:
			var transit: float = float(metrics.get("items_in_transit", 0))
			var col: Color = SERIES_COLORS[color_idx % SERIES_COLORS.size()]
			feed_point("conv_" + elem_id, elem_id + " In-Transit", t, transit, col, "cartons")
			color_idx += 1

	# Global Throughput & WIP
	if global_kpis.has("throughput_eff"):
		var thru: float = float(global_kpis.get("throughput_eff", 0.0))
		feed_point("sys_throughput", "System Throughput", t, thru, GREEN, "parts/s")

	if global_kpis.has("wip_total"):
		var wip: float = float(global_kpis.get("wip_total", 0.0))
		feed_point("sys_wip", "System WIP (L)", t, wip, ACCENT, "units")

	if global_kpis.has("sojourn_mean"):
		var w_mean: float = float(global_kpis.get("sojourn_mean", 0.0))
		feed_point("sys_sojourn", "Mean Sojourn W", t, w_mean, PURPLE, "s")

	if _has_implot and use_implot:
		_sync_simplot_view()
	if _plot_canvas != null and not use_implot:
		_plot_canvas.queue_redraw()

func _on_canvas_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover_pos = event.position
		if _plot_canvas != null:
			_plot_canvas.queue_redraw()

func _get_nice_y_max(raw: float) -> float:
	if raw <= 5.0: return 5.0
	if raw <= 10.0: return 10.0
	if raw <= 20.0: return 20.0
	if raw <= 50.0: return 50.0
	if raw <= 100.0: return 100.0
	var mag: float = pow(10.0, floor(log(raw) / log(10.0)))
	var norm: float = raw / mag
	if norm <= 1.0: return 1.0 * mag
	elif norm <= 2.0: return 2.0 * mag
	elif norm <= 5.0: return 5.0 * mag
	return 10.0 * mag

func _render_plot(canvas: CanvasItem) -> void:
	var rect := _plot_canvas.get_rect()
	var w: float = rect.size.x
	var h: float = rect.size.y
	if w <= 40 or h <= 40: return

	# Margins for axes
	var m_left: float = 55.0
	var m_right: float = 20.0
	var m_top: float = 15.0
	var m_bottom: float = 25.0
	var plot_w: float = max(w - m_left - m_right, 10.0)
	var plot_h: float = max(h - m_top - m_bottom, 10.0)

	# Background
	canvas.draw_rect(Rect2(0, 0, w, h), Color("#0a0e14"))
	canvas.draw_rect(Rect2(m_left, m_top, plot_w, plot_h), Color("#070a0e"))
	canvas.draw_rect(Rect2(m_left, m_top, plot_w, plot_h), BORDER, false, 1.0)

	# Determine active series for current tab
	var active_keys: Array = _get_active_series_keys()

	# Calculate ranges: stationary 60s window for first 60s, smooth scroll thereafter
	var t_end: float = max(time_window_seconds, _latest_sim_t)
	var t_start: float = max(0.0, t_end - time_window_seconds)

	var raw_y_max: float = 1.0
	if current_tab == PlotTab.UTILIZATION:
		raw_y_max = 100.0
	else:
		for k in active_keys:
			var arr: Array = _series.get(k, [])
			for pt in arr:
				if pt.t >= t_start:
					raw_y_max = max(raw_y_max, pt.val * 1.15)
	var y_max: float = 100.0 if current_tab == PlotTab.UTILIZATION else _get_nice_y_max(raw_y_max)

	# 1. Draw Grid Lines
	var default_font := ThemeDB.fallback_font
	var font_size: int = 10

	# Vertical grid (time)
	var time_step: float = 10.0
	if time_window_seconds > 120.0: time_step = 30.0
	var t_tick: float = ceil(t_start / time_step) * time_step
	while t_tick <= t_end:
		var frac_x: float = (t_tick - t_start) / max(t_end - t_start, 0.001)
		var gx: float = m_left + frac_x * plot_w
		canvas.draw_line(Vector2(gx, m_top), Vector2(gx, m_top + plot_h), Color(0.2, 0.25, 0.35, 0.3), 1.0)
		canvas.draw_string(default_font, Vector2(gx - 12, h - 8), "%.0fs" % t_tick, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, MUTED)
		t_tick += time_step

	# Horizontal grid (values)
	var y_divisions: int = 4
	for i in range(y_divisions + 1):
		var frac_y: float = float(i) / float(y_divisions)
		var val_y: float = frac_y * y_max
		var gy: float = m_top + plot_h - frac_y * plot_h
		canvas.draw_line(Vector2(m_left, gy), Vector2(m_left + plot_w, gy), Color(0.2, 0.25, 0.35, 0.3), 1.0)
		var label_str: String = "%.1f" % val_y if y_max < 10.0 else "%.0f" % val_y
		if current_tab == PlotTab.UTILIZATION: label_str += "%"
		canvas.draw_string(default_font, Vector2(6, gy + 4), label_str, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, MUTED)

	# 2. Plot Waveforms
	var total_points_drawn: int = 0
	var legend_items: Array[String] = []

	for k in active_keys:
		var arr: Array = _series[k]
		if arr.size() < 2: continue
		var meta: Dictionary = _series_meta.get(k, {})
		var col: Color = meta.get("color", ACCENT)
		var label: String = meta.get("label", k)
		var unit: String = meta.get("unit", "")

		var polyline: PackedVector2Array = PackedVector2Array()
		var latest_val: float = arr.back().val

		for pt in arr:
			if pt.t < t_start: continue
			var fx: float = (pt.t - t_start) / max(t_end - t_start, 0.001)
			var fy: float = pt.val / max(y_max, 0.001)
			var px: float = m_left + fx * plot_w
			var py: float = m_top + plot_h - clamp(fy, 0.0, 1.0) * plot_h
			polyline.append(Vector2(px, py))
			total_points_drawn += 1

		if polyline.size() >= 2:
			canvas.draw_polyline(polyline, col, 2.0, true)
			# Latest marker dot
			canvas.draw_circle(polyline[-1], 3.5, col)

		var val_disp: String = "%.1f %s" % [latest_val, unit] if y_max < 10.0 else "%.0f %s" % [latest_val, unit]
		legend_items.append("%s: %s" % [label, val_disp])

	# 3. Crosshair on Mouse Hover
	if _is_hovered and _hover_pos.x >= m_left and _hover_pos.x <= m_left + plot_w:
		var hover_x: float = _hover_pos.x
		canvas.draw_line(Vector2(hover_x, m_top), Vector2(hover_x, m_top + plot_h), Color(1.0, 1.0, 1.0, 0.6), 1.0)
		var h_frac: float = (hover_x - m_left) / plot_w
		var h_time: float = t_start + h_frac * (t_end - t_start)
		canvas.draw_string(default_font, Vector2(hover_x + 5, m_top + 15), "t=%.2fs" % h_time, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color.WHITE)

	# 4. Update Status & Legend Labels
	if _status_label != null:
		var freeze_txt: String = " [FROZEN]" if is_frozen else ""
		_status_label.text = "Window: %.0fs | Active: %d pts%s" % [time_window_seconds, total_points_drawn, freeze_txt]

	if _legend_label != null:
		if legend_items.is_empty():
			_legend_label.text = "No series active for current tab. Play simulation to populate."
		else:
			_legend_label.text = "  |  ".join(legend_items)

