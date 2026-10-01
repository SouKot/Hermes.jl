# record_simviz_highlights_video.gd
# Automated Movie Maker Showcase Director (v2 — 1,000 Frames / 100s Unhurried Walkthrough)
# Showcases the 4-Zone, 19-Element Smart Fulfillment, Parallel CNC Assembly & Vision QA Rework Plant
# across all 8 major capability areas of Antigravity SimViz.
extends Control

const AuthoringShell := preload("res://scripts/authoring_shell.gd")
const SceneTypes := preload("res://scripts/scenespec_types.gd")
const ConveyorCurve3D := preload("res://scripts/conveyor_curve_3d.gd")

var shell: Control = null
var frame_count: int = 0
const TOTAL_FRAMES: int = 1000

var _banner_panel: PanelContainer = null
var _lbl_chapter_pill: Label = null
var _lbl_title: Label = null
var _lbl_subtitle: Label = null
var _progress_bar: ProgressBar = null

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	shell = AuthoringShell.new()
	shell.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shell)

	_build_banner_overlay()
	_setup_complex_4zone_plant_scene()
	if shell._autosave_dialog != null:
		shell._autosave_dialog.hide()

	# Pre-warm 60 seconds of rich stochastic telemetry so Plot Studio is immediately full of history
	for warm_i in range(120):
		var warm_t: float = float(warm_i) * 0.5
		_feed_live_telemetry(warm_t, true)

func _build_banner_overlay() -> void:
	_banner_panel = PanelContainer.new()
	_banner_panel.z_index = 400
	_banner_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.08, 0.13, 0.94)
	style.border_color = Color("#52c7a5")
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.shadow_color = Color(0, 0, 0, 0.65)
	style.shadow_size = 14
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	_banner_panel.add_theme_stylebox_override("panel", style)
	_banner_panel.position = Vector2(210, 768)
	_banner_panel.custom_minimum_size = Vector2(980, 70)
	add_child(_banner_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	_banner_panel.add_child(vbox)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 10)
	vbox.add_child(top_row)

	_lbl_chapter_pill = Label.new()
	_lbl_chapter_pill.text = "● HIGHLIGHT 1 / 8"
	_lbl_chapter_pill.add_theme_font_size_override("font_size", 11)
	_lbl_chapter_pill.add_theme_color_override("font_color", Color("#52c7a5"))
	top_row.add_child(_lbl_chapter_pill)

	_lbl_title = Label.new()
	_lbl_title.text = "Antigravity SimViz — 4-Zone Industrial Digital Twin"
	_lbl_title.add_theme_font_size_override("font_size", 15)
	_lbl_title.add_theme_color_override("font_color", Color("#eef4f8"))
	_lbl_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(_lbl_title)

	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(140, 14)
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = float(TOTAL_FRAMES)
	_progress_bar.value = 0.0
	top_row.add_child(_progress_bar)

	_lbl_subtitle = Label.new()
	_lbl_subtitle.text = ""
	_lbl_subtitle.add_theme_font_size_override("font_size", 12)
	_lbl_subtitle.add_theme_color_override("font_color", Color("#9fb3c8"))
	vbox.add_child(_lbl_subtitle)

func _set_banner(ch_num: int, title_txt: String, sub_txt: String) -> void:
	_lbl_chapter_pill.text = "● HIGHLIGHT %d / 8" % ch_num
	_lbl_title.text = title_txt
	_lbl_subtitle.text = sub_txt

func _setup_complex_4zone_plant_scene() -> void:
	var ds = shell.doc_store
	var cat = shell.catalog
	ds.new_document()
	ds.active_document.scene["name"] = "4-Zone Smart Fulfillment, CNC Assembly & Vision QA Plant"

	# ── 4 CAD ZONES (Contiguous Plant Layout) ────────────────────────────────
	ds.active_document.scene["cad_zones"] = [
		{"label": "ZONE 1: MULTI-DOCK RECEIVING & INDUCTION", "rect": [1.5, 1.5, 16.5, 16.5]},
		{"label": "ZONE 2A: S-CURVE EXPRESS BYPASS", "rect": [18.0, 1.5, 19.5, 5.0]},
		{"label": "ZONE 2B: MAINLINE & PARALLEL CNC CELLS", "rect": [18.0, 6.8, 19.5, 7.8]},
		{"label": "ZONE 3: VISION QA & REWORK", "rect": [37.5, 1.5, 7.5, 16.5]},
		{"label": "ZONE 4: OUTBOUND, SHIPPING & TELEMETRY", "rect": [45.0, 1.5, 22.0, 16.5]}
	]

	# ── ZONE 1: 3 Infeed Sources + 3 Contiguous Staging Queues + Sorter Hub ──
	# Each Source (2.0x2.0m) touches its Receiving Queue (4.0x2.0m) flush at X = 4.5m!
	var src_vip = cat.create_element_instance("source", "src_vip", Vector2(2.5, 3.0))
	src_vip.name = "VIP Air-Freight"
	src_vip.geometry["dimensions"] = [2.0, 2.0, 1.8]
	src_vip.properties["priority"] = 10
	src_vip.properties["default_attributes"] = {"order_tier": "VIP_AIR", "due_offset": 25.0, "fragile": true}

	var src_ecom = cat.create_element_instance("source", "src_ecom", Vector2(2.5, 8.5))
	src_ecom.name = "E-Commerce Dock"
	src_ecom.geometry["dimensions"] = [2.0, 2.0, 1.8]
	src_ecom.properties["priority"] = 5
	src_ecom.properties["default_attributes"] = {"order_tier": "ECOM_STD", "due_offset": 55.0}

	var src_bulk = cat.create_element_instance("source", "src_bulk", Vector2(2.5, 14.0))
	src_bulk.name = "Bulk Wholesale"
	src_bulk.geometry["dimensions"] = [2.0, 2.0, 1.8]
	src_bulk.properties["priority"] = 1
	src_bulk.properties["default_attributes"] = {"order_tier": "WHOLESALE", "batch_size": 12}

	var q_vip = cat.create_element_instance("queue", "q_vip", Vector2(4.5, 3.0))
	q_vip.name = "VIP Priority Buffer"
	q_vip.geometry["dimensions"] = [4.0, 2.0, 0.85]
	q_vip.properties["discipline"] = "Priority"
	q_vip.properties["capacity"] = 20

	var q_ecom = cat.create_element_instance("queue", "q_ecom", Vector2(4.5, 8.5))
	q_ecom.name = "E-Commerce Staging"
	q_ecom.geometry["dimensions"] = [4.0, 2.0, 0.85]
	q_ecom.properties["discipline"] = "Custom"
	q_ecom.properties["custom_discipline"] = "get_attribute(a, \"due_date\", Inf) < get_attribute(b, \"due_date\", Inf)"
	q_ecom.properties["capacity"] = 30

	var q_bulk = cat.create_element_instance("queue", "q_bulk", Vector2(4.5, 14.0))
	q_bulk.name = "Wholesale Pallet Q"
	q_bulk.geometry["dimensions"] = [4.0, 2.0, 0.85]
	q_bulk.properties["discipline"] = "FIFO"
	q_bulk.properties["capacity"] = 40

	# Automated Sorter Hub spans X: [14.5 .. 17.5], Y: [8.5 .. 10.5] (center Y = 9.5)
	var srv_induct = cat.create_element_instance("server", "srv_induct", Vector2(14.5, 8.5))
	srv_induct.name = "Automated Sorter Hub"
	srv_induct.geometry["dimensions"] = [3.0, 2.0, 1.8]
	srv_induct.properties["servers"] = 2
	srv_induct.properties["intake_mode"] = "custom"
	srv_induct.properties["hooks"] = {
		"on_pull": "# M-1 Multi-Queue Priority Pull with Aging\npull_from_port_argmax!(:in_flow, c -> c.priority * 10.0 + c.wait_time)",
		"on_entry": "wait_s = wait_time()\nif wait_s > 25.0\n    set_color!(:red)\nelseif priority() >= 8\n    set_color!(:cyan)\nelse\n    set_color!(:green)\nend\nrecord_metric!(\"sorter_wip\", queue_length() + in_service())",
		"on_service_start": "if last_processed_attr(:order_tier, \"\") != str_attr(:order_tier, \"\")\n    add_setup_time!(1.2)\nend"
	}

	# ── ZONE 2A: Upper S-Curve Express Bypass & High-Speed Robotic Cell ──────
	# Starts FLUSH at srv_induct right edge (X=17.5, Y=9.1) and ends FLUSH at srv_express left edge (X=25.5, Y=3.8)!
	var conv_express_in = cat.create_element_instance("conveyor", "conv_express_in", Vector2(17.5, 6.5))
	conv_express_in.name = "S-Curve Express Bypass"
	conv_express_in.geometry["shape_preset"] = "s_curve"
	conv_express_in.geometry["inlet_pose"] = {"position": [17.5, 9.1, 0.8], "tangent": [1.0, 0.0, 0.0]}
	conv_express_in.geometry["outlet_pose"] = {"position": [25.5, 3.8, 0.8], "tangent": [1.0, 0.0, 0.0]}
	conv_express_in.properties["shape_preset"] = "s_curve"
	conv_express_in.properties["speed"] = 2.8
	conv_express_in.properties["conveyor_mode"] = "free_flow"

	# Spans X: [25.5 .. 28.5], Y: [2.8 .. 4.8] (center Y = 3.8)
	var srv_express = cat.create_element_instance("server", "srv_express", Vector2(25.5, 2.8))
	srv_express.name = "High-Speed Robotic Cell"
	srv_express.geometry["dimensions"] = [3.0, 2.0, 1.8]
	srv_express.properties["servers"] = 2

	# Starts FLUSH at srv_express right edge (X=28.5, Y=3.8) and ends FLUSH at q_qa left edge (X=37.5, Y=9.1)!
	var conv_express_out = cat.create_element_instance("conveyor", "conv_express_out", Vector2(28.5, 3.8))
	conv_express_out.name = "S-Curve QA Merge"
	conv_express_out.geometry["shape_preset"] = "s_curve"
	conv_express_out.geometry["inlet_pose"] = {"position": [28.5, 3.8, 0.8], "tangent": [1.0, 0.0, 0.0]}
	conv_express_out.geometry["outlet_pose"] = {"position": [37.5, 9.1, 0.8], "tangent": [1.0, 0.0, 0.0]}
	conv_express_out.properties["shape_preset"] = "s_curve"
	conv_express_out.properties["speed"] = 2.6

	# ── ZONE 2B: Mainline Accumulating Conveyor & Contiguous CNC Cells A & B ─
	# Starts FLUSH at srv_induct right edge (X=17.5..25.5, Y=8.9..10.1, center Y=9.5)!
	var conv_main = cat.create_element_instance("conveyor", "conv_main", Vector2(17.5, 8.9))
	conv_main.name = "Accumulating Mainline Belt"
	conv_main.geometry["dimensions"] = [8.0, 1.2, 0.8]
	conv_main.properties["length"] = 8.0
	conv_main.properties["speed"] = 1.6
	conv_main.properties["conveyor_mode"] = "accumulating"

	# q_cnc_a (X=27.5..31.5) touches srv_cnc_a (X=31.5..34.5) FLUSH with 0.0m gap!
	var q_cnc_a = cat.create_element_instance("queue", "q_cnc_a", Vector2(27.5, 7.2))
	q_cnc_a.name = "CNC A Buffer"
	q_cnc_a.geometry["dimensions"] = [4.0, 2.0, 0.85]
	var srv_cnc_a = cat.create_element_instance("server", "srv_cnc_a", Vector2(31.5, 7.2))
	srv_cnc_a.name = "CNC Assembly Cell A"
	srv_cnc_a.geometry["dimensions"] = [3.0, 2.0, 1.8]

	# q_cnc_b (X=27.5..31.5) touches srv_cnc_b (X=31.5..34.5) FLUSH with 0.0m gap!
	var q_cnc_b = cat.create_element_instance("queue", "q_cnc_b", Vector2(27.5, 11.4))
	q_cnc_b.name = "CNC B Buffer"
	q_cnc_b.geometry["dimensions"] = [4.0, 2.0, 0.85]
	var srv_cnc_b = cat.create_element_instance("server", "srv_cnc_b", Vector2(31.5, 11.4))
	srv_cnc_b.name = "CNC Assembly Cell B"
	srv_cnc_b.geometry["dimensions"] = [3.0, 2.0, 1.8]

	# ── ZONE 3: Optical Vision QA Station & 12% Curved Rework Return Loop ────
	# q_qa (X=37.5..41.5) touches srv_qa (X=41.5..44.5) FLUSH with 0.0m gap!
	var q_qa = cat.create_element_instance("queue", "q_qa", Vector2(37.5, 8.5))
	q_qa.name = "QA Inspection Q"
	q_qa.geometry["dimensions"] = [4.0, 2.0, 0.85]
	var srv_qa = cat.create_element_instance("server", "srv_qa", Vector2(41.5, 8.5))
	srv_qa.name = "Optical Vision QA"
	srv_qa.geometry["dimensions"] = [3.0, 2.0, 1.8]
	srv_qa.properties["routing_rule"] = "prob"

	# Starts FLUSH at srv_qa outfeed (X=44.5, Y=10.0) and ends FLUSH at srv_rework right edge (X=36.5, Y=16.5)!
	var conv_rework = cat.create_element_instance("conveyor", "conv_rework", Vector2(40.0, 15.5))
	conv_rework.name = "Curved Rework Return Belt"
	conv_rework.geometry["shape_preset"] = "s_curve"
	conv_rework.geometry["inlet_pose"] = {"position": [44.5, 10.0, 0.8], "tangent": [-1.0, 0.2, 0.0]}
	conv_rework.geometry["outlet_pose"] = {"position": [36.5, 16.5, 0.8], "tangent": [-1.0, 0.0, 0.0]}
	conv_rework.properties["shape_preset"] = "s_curve"
	conv_rework.properties["speed"] = 1.5

	var srv_rework = cat.create_element_instance("server", "srv_rework", Vector2(33.5, 15.5))
	srv_rework.name = "Rework Calibration Bench"
	srv_rework.geometry["dimensions"] = [3.0, 2.0, 1.8]

	# ── ZONE 4: Outbound Conveyor, Auto-Palletizer, Dual Sinks & Telemetry ───
	# conv_out (X=44.5..49.5) touches srv_qa (X=44.5) and srv_pack (X=49.5..52.5) FLUSH with 0.0m gap!
	var conv_out = cat.create_element_instance("conveyor", "conv_out", Vector2(44.5, 8.9))
	conv_out.name = "Outbound Takeaway"
	conv_out.geometry["dimensions"] = [5.0, 1.2, 0.8]
	conv_out.properties["length"] = 5.0
	conv_out.properties["speed"] = 2.2

	var srv_pack = cat.create_element_instance("server", "srv_pack", Vector2(49.5, 8.5))
	srv_pack.name = "Auto-Palletizer"
	srv_pack.geometry["dimensions"] = [3.0, 2.0, 1.8]

	var snk_express = cat.create_element_instance("sink", "snk_express", Vector2(54.5, 5.8))
	snk_express.name = "Express Courier"
	snk_express.geometry["dimensions"] = [2.5, 2.0, 1.2]

	var snk_freight = cat.create_element_instance("sink", "snk_freight", Vector2(54.5, 11.2))
	snk_freight.name = "Freight Dock"
	snk_freight.geometry["dimensions"] = [2.5, 2.0, 1.2]

	# Multi-Subplot Chart Station placed cleanly on the right of Zone 4 so the entire lower canvas is open!
	var chart_hub = cat.create_element_instance("chart_station", "chart_hub", Vector2(59.0, 5.8))
	chart_hub.name = "Plant Live Telemetry"
	chart_hub.properties["title"] = "4-Zone Plant Real-Time Telemetry"
	chart_hub.properties["grid_rows"] = 2
	chart_hub.properties["grid_columns"] = 2
	chart_hub.properties["subplots"] = [
		{
			"id": "sp_1",
			"port_id": "P1",
			"title": "1. Receiving Queue Buffer Lengths (VIP, E-Com, Bulk)",
			"type": "time_series",
			"y_label": "Items (Lq)",
			"autoscale": true,
			"y_min": 0.0,
			"y_max": 15.0,
			"grid": {"col": 0, "row": 0, "col_span": 1, "row_span": 1},
			"mode": "overlay",
			"signals": [
				{"entity_id": "q_vip", "y_metric": "queue_length", "x_metric": "__time__", "label": "VIP Priority Q"},
				{"entity_id": "q_ecom", "y_metric": "queue_length", "x_metric": "__time__", "label": "E-Commerce Q"},
				{"entity_id": "q_bulk", "y_metric": "queue_length", "x_metric": "__time__", "label": "Bulk Pallet Q"}
			]
		},
		{
			"id": "sp_2",
			"port_id": "P2",
			"title": "2. Station Utilization % (Express Robot, CNC A, Vision QA)",
			"type": "time_series",
			"y_label": "Util (%)",
			"autoscale": false,
			"y_min": 0.0,
			"y_max": 100.0,
			"grid": {"col": 1, "row": 0, "col_span": 1, "row_span": 1},
			"mode": "overlay",
			"signals": [
				{"entity_id": "srv_express", "y_metric": "utilization_pct", "x_metric": "__time__", "label": "Express Robot %"},
				{"entity_id": "srv_cnc_a", "y_metric": "utilization_pct", "x_metric": "__time__", "label": "CNC Cell A %"},
				{"entity_id": "srv_qa", "y_metric": "utilization_pct", "x_metric": "__time__", "label": "Vision QA %"}
			]
		},
		{
			"id": "sp_3",
			"port_id": "P3",
			"title": "3. Customer Waiting Time Distribution (Wq Histogram)",
			"type": "histogram",
			"y_label": "Count",
			"autoscale": true,
			"y_min": 0.0,
			"y_max": 50.0,
			"grid": {"col": 0, "row": 1, "col_span": 1, "row_span": 1},
			"mode": "overlay",
			"signals": [
				{"entity_id": "q_ecom", "y_metric": "wait_time", "x_metric": "__time__", "label": "Wait Time Wq (s)"}
			]
		},
		{
			"id": "sp_4",
			"port_id": "P4",
			"title": "4. Outbound Throughput Rate & Rework Loop WIP",
			"type": "time_series",
			"y_label": "Rate / WIP",
			"autoscale": true,
			"y_min": 0.0,
			"y_max": 10.0,
			"grid": {"col": 1, "row": 1, "col_span": 1, "row_span": 1},
			"mode": "overlay",
			"signals": [
				{"entity_id": "snk_express", "y_metric": "throughput_per_sec", "x_metric": "__time__", "label": "Throughput (items/s)"},
				{"entity_id": "conv_rework", "y_metric": "items_in_transit", "x_metric": "__time__", "label": "Rework Loop WIP"}
			]
		}
	]

	for p_idx in [2, 3, 4]:
		var sp_port := SceneTypes.ScenePort.new()
		sp_port.id = "P%d" % p_idx
		sp_port.kind = "signal"
		sp_port.direction = "input"
		sp_port.cardinality = "many"
		sp_port.name = "Port %d (Subplot %d)" % [p_idx, p_idx]
		chart_hub.input_ports.append(sp_port)

	for elem in [
		src_vip, src_ecom, src_bulk,
		q_vip, q_ecom, q_bulk, srv_induct,
		conv_express_in, srv_express, conv_express_out,
		conv_main, q_cnc_a, srv_cnc_a, q_cnc_b, srv_cnc_b,
		q_qa, srv_qa, conv_rework, srv_rework,
		conv_out, srv_pack, snk_express, snk_freight, chart_hub
	]:
		ds.add_element(elem)

	# ── CONNECTIONS ──────────────────────────────────────────────────────────
	# Zone 1
	ds.add_connection_direct("c_src1", "src_vip", "flow_out", "q_vip", "flow_in")
	ds.add_connection_direct("c_src2", "src_ecom", "flow_out", "q_ecom", "flow_in")
	ds.add_connection_direct("c_src3", "src_bulk", "flow_out", "q_bulk", "flow_in")

	ds.add_connection_direct("c_in_1", "q_vip", "flow_out", "srv_induct", "flow_in")
	ds.add_connection_direct("c_in_2", "q_ecom", "flow_out", "srv_induct", "flow_in")
	ds.add_connection_direct("c_in_3", "q_bulk", "flow_out", "srv_induct", "flow_in")

	# Zone 1 -> Zone 2A (Express Bypass) & Zone 2B (Mainline)
	ds.add_connection_direct("c_bypass_in", "srv_induct", "flow_out", "conv_express_in", "flow_in")
	ds.add_connection_direct("c_main_in", "srv_induct", "flow_out", "conv_main", "flow_in")

	# Zone 2A
	ds.add_connection_direct("c_exp_srv", "conv_express_in", "flow_out", "srv_express", "flow_in")
	ds.add_connection_direct("c_exp_out", "srv_express", "flow_out", "conv_express_out", "flow_in")
	ds.add_connection_direct("c_exp_qa", "conv_express_out", "flow_out", "q_qa", "flow_in")

	# Zone 2B
	ds.add_connection_direct("c_m_a", "conv_main", "flow_out", "q_cnc_a", "flow_in")
	ds.add_connection_direct("c_m_b", "conv_main", "flow_out", "q_cnc_b", "flow_in")
	ds.add_connection_direct("c_a_srv", "q_cnc_a", "flow_out", "srv_cnc_a", "flow_in")
	ds.add_connection_direct("c_b_srv", "q_cnc_b", "flow_out", "srv_cnc_b", "flow_in")
	ds.add_connection_direct("c_a_qa", "srv_cnc_a", "flow_out", "q_qa", "flow_in")
	ds.add_connection_direct("c_b_qa", "srv_cnc_b", "flow_out", "q_qa", "flow_in")

	# Zone 3 (Vision QA & 12% Rework Loop)
	ds.add_connection_direct("c_qa_in", "q_qa", "flow_out", "srv_qa", "flow_in")
	ds.add_connection_direct("c_qa_pass", "srv_qa", "flow_out", "conv_out", "flow_in")
	ds.add_connection_direct("c_qa_rew", "srv_qa", "flow_out", "conv_rework", "flow_in")
	ds.add_connection_direct("c_rew_bench", "conv_rework", "flow_out", "srv_rework", "flow_in")
	ds.add_connection_direct("c_rew_return", "srv_rework", "flow_out", "q_qa", "flow_in")

	# Zone 4 (Outbound & Dual Sinks)
	ds.add_connection_direct("c_out_pack", "conv_out", "flow_out", "srv_pack", "flow_in")
	ds.add_connection_direct("c_pack_exp", "srv_pack", "flow_out", "snk_express", "flow_in")
	ds.add_connection_direct("c_pack_frt", "srv_pack", "flow_out", "snk_freight", "flow_in")

	# Dashed Telemetry Signal Wires routed cleanly along the top/bottom border of the zones
	ds.add_connection_direct("sig_1", "q_vip", "length", "chart_hub", "P1", "signal")
	ds.add_connection_direct("sig_2", "srv_induct", "utilization", "chart_hub", "P2", "signal")
	ds.add_connection_direct("sig_3", "q_ecom", "wait_time", "chart_hub", "P3", "signal")
	ds.add_connection_direct("sig_4", "srv_qa", "utilization", "chart_hub", "P4", "signal")

	var sig1_c = ds.get_connection("sig_1")
	if sig1_c != null: sig1_c.set_extension_path("visual.waypoints", [[6.5, 17.5], [57.8, 17.5], [57.8, 7.2]])
	var sig2_c = ds.get_connection("sig_2")
	if sig2_c != null: sig2_c.set_extension_path("visual.waypoints", [[16.0, 17.8], [58.1, 17.8], [58.1, 8.2]])
	var sig3_c = ds.get_connection("sig_3")
	if sig3_c != null: sig3_c.set_extension_path("visual.waypoints", [[6.5, 18.1], [58.4, 18.1], [58.4, 9.2]])
	var sig4_c = ds.get_connection("sig_4")
	if sig4_c != null: sig4_c.set_extension_path("visual.waypoints", [[43.0, 18.4], [58.7, 18.4], [58.7, 10.2]])

	# Add custom waypoints to c_in_3 so Chapter 3 shows interactive bend handles
	var conn_in3 = ds.get_connection("c_in_3")
	if conn_in3 != null:
		conn_in3.set_extension_path("visual.waypoints", [[11.0, 14.8], [12.5, 11.2]])

	ds.is_dirty = false
	shell._canvas_2d.rebuild_blocks()
	shell._canvas_2d.pan_offset = Vector2(10, 4)
	shell._canvas_2d.zoom_level = 0.69
	shell._canvas_2d._update_blocks_transform()
	shell._canvas_2d._redraw_all()
	shell._viewport_3d.rebuild_3d_scene()

func _sample_conveyor_pose(elem_id: String, prog: float) -> Dictionary:
	if shell == null or shell.doc_store == null:
		return {"pos": Vector2.ZERO, "tan": Vector2(1.0, 0.0)}
	var elem = shell.doc_store.get_element(elem_id)
	if elem == null:
		return {"pos": Vector2.ZERO, "tan": Vector2(1.0, 0.0)}
	var pts: PackedVector2Array = ConveyorCurve3D.sample_2d_polyline(elem, shell.doc_store, 32)
	var is_pose: bool = elem.geometry.has("inlet_pose") or elem.geometry.has("outlet_pose") or str(elem.geometry.get("shape_preset", elem.properties.get("shape_preset", "straight"))).to_lower() != "straight"
	var y_off: float = 0.0
	if not is_pose:
		var d = elem.geometry.get("dimensions", [8.0, 1.2, 0.8])
		if d is Array and d.size() >= 2:
			y_off = float(d[1]) * 0.5
	if pts.is_empty():
		return {"pos": Vector2(elem.transform.position.x, elem.transform.position.y + y_off), "tan": Vector2(1.0, 0.0)}
	if pts.size() == 1:
		return {"pos": pts[0] + Vector2(0.0, y_off), "tan": Vector2(1.0, 0.0)}
	var f: float = clampf(prog, 0.0, 1.0) * float(pts.size() - 1)
	var idx: int = clampi(int(floor(f)), 0, pts.size() - 2)
	var frac: float = f - float(idx)
	var p_interp: Vector2 = pts[idx].lerp(pts[idx + 1], frac) + Vector2(0.0, y_off)
	var t_dir: Vector2 = (pts[idx + 1] - pts[idx]).normalized()
	if t_dir.length_squared() < 1e-4:
		t_dir = Vector2(1.0, 0.0)
	return {"pos": p_interp, "tan": t_dir}

func _feed_live_telemetry(sim_t: float, warmup_only: bool = false) -> void:
	shell.is_sim_running = true
	shell.update_sim_time(sim_t)

	var q1_len: int = 3 + int(round(abs(sin(sim_t * 0.18)) * 6.0 + cos(sim_t * 0.43) * 1.5))
	var q2_len: int = 5 + int(round(abs(cos(sim_t * 0.14)) * 7.0 + sin(sim_t * 0.31) * 2.0))
	var q3_len: int = 7 + int(round(abs(sin(sim_t * 0.11 + 1.0)) * 8.0))

	var u_induct: float = clampf(0.76 + 0.14 * sin(sim_t * 0.21), 0.45, 0.96)
	var u_exp: float = clampf(0.68 + 0.18 * cos(sim_t * 0.27), 0.35, 0.94)
	var u_cnc_a: float = clampf(0.84 + 0.10 * sin(sim_t * 0.16 + 0.8), 0.55, 0.98)
	var u_cnc_b: float = clampf(0.79 + 0.12 * cos(sim_t * 0.19), 0.50, 0.95)
	var u_qa: float = clampf(0.73 + 0.15 * sin(sim_t * 0.24 + 1.7), 0.40, 0.93)
	var u_pack: float = clampf(0.81 + 0.11 * cos(sim_t * 0.15), 0.50, 0.95)

	var tp_rate: float = 4.2 + 0.85 * sin(sim_t * 0.17)
	var rew_wip: int = 2 + int(abs(sin(sim_t * 0.22)) * 3.0)

	# Generate realistic wait time histogram samples
	var wait_samples: Array = [
		3.2 + 1.8 * sin(sim_t * 0.3),
		5.8 + 2.4 * cos(sim_t * 0.5),
		8.4 + 3.1 * sin(sim_t * 0.7 + 1.2),
		12.1 + 4.0 * cos(sim_t * 0.4 + 2.0)
	]

	var elems_by_id := {
		"src_vip": {"generated": int(sim_t * 1.4), "rate_per_sec": 1.4},
		"src_ecom": {"generated": int(sim_t * 2.1), "rate_per_sec": 2.1},
		"src_bulk": {"generated": int(sim_t * 1.1), "rate_per_sec": 1.1},
		"q_vip": {"queue_length": q1_len, "length": q1_len, "wait_mean_wq": 3.4, "occupancy_pct": float(q1_len) * 5.0},
		"q_ecom": {"queue_length": q2_len, "length": q2_len, "wait_mean_wq": 6.8, "occupancy_pct": float(q2_len) * 3.3, "recent_wait_samples": wait_samples},
		"q_bulk": {"queue_length": q3_len, "length": q3_len, "wait_mean_wq": 11.2, "occupancy_pct": float(q3_len) * 2.5},
		"srv_induct": {"utilization": u_induct, "utilization_pct": u_induct * 100.0, "in_service": 2, "state": "BUSY"},
		"conv_express_in": {"in_transit": 3, "items_in_transit": 3, "utilization": 0.65, "speed": 2.8},
		"srv_express": {"utilization": u_exp, "utilization_pct": u_exp * 100.0, "in_service": 2, "state": "BUSY"},
		"conv_express_out": {"in_transit": 2, "items_in_transit": 2, "utilization": 0.55, "speed": 2.6},
		"conv_main": {"in_transit": 4, "items_in_transit": 4, "utilization": 0.78, "speed": 1.6},
		"q_cnc_a": {"queue_length": 3, "length": 3, "wait_mean_wq": 4.5},
		"srv_cnc_a": {"utilization": u_cnc_a, "utilization_pct": u_cnc_a * 100.0, "in_service": 1, "state": "BUSY"},
		"q_cnc_b": {"queue_length": 2, "length": 2, "wait_mean_wq": 3.9},
		"srv_cnc_b": {"utilization": u_cnc_b, "utilization_pct": u_cnc_b * 100.0, "in_service": 1, "state": "BUSY"},
		"q_qa": {"queue_length": 3, "length": 3, "wait_mean_wq": 2.8},
		"srv_qa": {"utilization": u_qa, "utilization_pct": u_qa * 100.0, "in_service": 1, "state": "BUSY"},
		"conv_rework": {"in_transit": rew_wip, "items_in_transit": rew_wip, "utilization": 0.42, "speed": 1.5},
		"srv_rework": {"utilization": 0.54, "utilization_pct": 54.0, "in_service": 1, "state": "BUSY"},
		"conv_out": {"in_transit": 3, "items_in_transit": 3, "utilization": 0.72, "speed": 2.2},
		"srv_pack": {"utilization": u_pack, "utilization_pct": u_pack * 100.0, "in_service": 1, "state": "BUSY"},
		"snk_express": {"completed_count": int(sim_t * 2.4), "throughput_per_sec": tp_rate},
		"snk_freight": {"completed_count": int(sim_t * 1.8), "throughput_per_sec": tp_rate * 0.75}
	}

	if warmup_only:
		if shell._plot_studio != null:
			shell._plot_studio.feed_telemetry(sim_t, elems_by_id, {})
		return

	var agents_arr: Array = []
	var entities_arr: Array = []
	var colors := [
		Color("#ef4444"), # Red VIP Rush
		Color("#06b6d4"), # Cyan Priority
		Color("#f59e0b"), # Gold E-Com
		Color("#10b981"), # Emerald Standard
		Color("#a855f7")  # Purple Reworked
	]

	# 1. Products on S-Curve Express Bypass (conv_express_in) — centered on spline with tangent orientation!
	for i in range(3):
		var prog: float = fmod(sim_t * 0.09 + float(i) * 0.33, 1.0)
		var pose := _sample_conveyor_pose("conv_express_in", prog)
		var pt_m: Vector2 = pose["pos"]
		var tan_m: Vector2 = pose["tan"]
		var col: Color = colors[i % 2]
		var eid_str := "vip_exp_%d" % (101 + i)
		agents_arr.append({
			"id": eid_str, "kind": "product", "zone": "conv_express_in",
			"x": pt_m.x, "y": pt_m.y, "z": 0.87, "vx": tan_m.x, "vy": tan_m.y,
			"properties": {"color_r": col.r, "color_g": col.g, "color_b": col.b, "element_id": "conv_express_in"},
			"color": [col.r, col.g, col.b], "mesh_type": "box", "scale": 1.0
		})
		entities_arr.append({
			"id": eid_str, "element_id": "conv_express_in", "zone": "conv_express_in",
			"priority": 10,
			"properties": {
				"color_r": col.r, "color_g": col.g, "color_b": col.b,
				"mesh_type": "box", "priority": 10,
				"attributes": {"order_tier": "VIP_AIR", "lane": "express_s_curve", "due_date": 42.5}
			}
		})

	# 2. Products on S-Curve QA Merge (conv_express_out)
	for i in range(2):
		var prog: float = fmod(sim_t * 0.10 + float(i) * 0.5, 1.0)
		var pose := _sample_conveyor_pose("conv_express_out", prog)
		var pt_m: Vector2 = pose["pos"]
		var tan_m: Vector2 = pose["tan"]
		var col := Color("#06b6d4")
		agents_arr.append({
			"id": "vip_mrg_%d" % i, "kind": "product", "zone": "conv_express_out",
			"x": pt_m.x, "y": pt_m.y, "z": 0.87, "vx": tan_m.x, "vy": tan_m.y,
			"properties": {"color_r": col.r, "color_g": col.g, "color_b": col.b, "element_id": "conv_express_out"},
			"color": [col.r, col.g, col.b], "mesh_type": "box", "scale": 1.0
		})

	# 3. Products on Straight Accumulating Mainline Belt (conv_main) — centered on belt!
	for i in range(4):
		var prog: float = fmod(sim_t * 0.065 + float(i) * 0.24, 1.0)
		var pose := _sample_conveyor_pose("conv_main", prog)
		var pt_m: Vector2 = pose["pos"]
		var tan_m: Vector2 = pose["tan"]
		var col: Color = colors[2 + (i % 2)]
		var eid_str := "main_std_%d" % (201 + i)
		agents_arr.append({
			"id": eid_str, "kind": "product", "zone": "conv_main",
			"x": pt_m.x, "y": pt_m.y, "z": 0.87, "vx": tan_m.x, "vy": tan_m.y,
			"properties": {"color_r": col.r, "color_g": col.g, "color_b": col.b, "element_id": "conv_main"},
			"color": [col.r, col.g, col.b], "mesh_type": "box", "scale": 1.0
		})
		entities_arr.append({
			"id": eid_str, "element_id": "conv_main", "zone": "conv_main",
			"priority": 5 if i % 2 == 0 else 1,
			"properties": {
				"color_r": col.r, "color_g": col.g, "color_b": col.b,
				"mesh_type": "box", "priority": 5 if i % 2 == 0 else 1,
				"attributes": {"order_tier": "ECOM_STD", "batch_id": 400 + i}
			}
		})

	# 4. Products on Curved Rework Return Belt (conv_rework) — 12% defect loop!
	for i in range(2):
		var prog: float = fmod(sim_t * 0.075 + float(i) * 0.48, 1.0)
		var pose := _sample_conveyor_pose("conv_rework", prog)
		var pt_m: Vector2 = pose["pos"]
		var tan_m: Vector2 = pose["tan"]
		var col := Color("#a855f7")
		var eid_str := "rework_item_%d" % (301 + i)
		agents_arr.append({
			"id": eid_str, "kind": "product", "zone": "conv_rework",
			"x": pt_m.x, "y": pt_m.y, "z": 0.87, "vx": tan_m.x, "vy": tan_m.y,
			"properties": {"color_r": col.r, "color_g": col.g, "color_b": col.b, "element_id": "conv_rework"},
			"color": [col.r, col.g, col.b], "mesh_type": "cylinder", "scale": 1.0
		})
		entities_arr.append({
			"id": eid_str, "element_id": "conv_rework", "zone": "conv_rework",
			"priority": 8,
			"properties": {
				"color_r": col.r, "color_g": col.g, "color_b": col.b,
				"mesh_type": "cylinder", "priority": 8,
				"attributes": {"reworked": true, "defect_code": "VISION_ALIGN", "pass_attempt": 2}
			}
		})

	# 5. Products on Outbound Takeaway Belt (conv_out)
	for i in range(2):
		var prog: float = fmod(sim_t * 0.09 + float(i) * 0.5, 1.0)
		var pose := _sample_conveyor_pose("conv_out", prog)
		var pt_m: Vector2 = pose["pos"]
		var tan_m: Vector2 = pose["tan"]
		var col := Color("#10b981")
		agents_arr.append({
			"id": "out_item_%d" % i, "kind": "product", "zone": "conv_out",
			"x": pt_m.x, "y": pt_m.y, "z": 0.87, "vx": tan_m.x, "vy": tan_m.y,
			"properties": {"color_r": col.r, "color_g": col.g, "color_b": col.b, "element_id": "conv_out"},
			"color": [col.r, col.g, col.b], "mesh_type": "box", "scale": 1.0
		})

	# 6. Products actively being processed / buffered on Workstations & Queues (centered on tables!)
	var station_items := [
		{"id": "st_ind", "zone": "srv_induct", "x": 16.0, "y": 9.5, "col": Color("#06b6d4"), "in_service": true},
		{"id": "st_exp", "zone": "srv_express", "x": 27.0, "y": 3.8, "col": Color("#ef4444"), "in_service": true},
		{"id": "st_qa1", "zone": "q_cnc_a", "x": 29.5, "y": 8.2, "col": Color("#f59e0b"), "in_service": false},
		{"id": "st_ca1", "zone": "srv_cnc_a", "x": 33.0, "y": 8.2, "col": Color("#10b981"), "in_service": true},
		{"id": "st_qb1", "zone": "q_cnc_b", "x": 29.5, "y": 12.4, "col": Color("#f59e0b"), "in_service": false},
		{"id": "st_cb1", "zone": "srv_cnc_b", "x": 33.0, "y": 12.4, "col": Color("#10b981"), "in_service": true},
		{"id": "st_qqa", "zone": "q_qa", "x": 39.5, "y": 9.5, "col": Color("#06b6d4"), "in_service": false},
		{"id": "st_sqa", "zone": "srv_qa", "x": 43.0, "y": 9.5, "col": Color("#10b981"), "in_service": true},
		{"id": "st_rew", "zone": "srv_rework", "x": 35.0, "y": 16.5, "col": Color("#a855f7"), "in_service": true},
		{"id": "st_pck", "zone": "srv_pack", "x": 51.0, "y": 9.5, "col": Color("#10b981"), "in_service": true}
	]
	for si in station_items:
		var scol: Color = si["col"]
		agents_arr.append({
			"id": si["id"], "kind": "product", "zone": si["zone"],
			"x": float(si["x"]), "y": float(si["y"]), "z": 0.87, "vx": 1.0, "vy": 0.0,
			"properties": {
				"color_r": scol.r, "color_g": scol.g, "color_b": scol.b,
				"element_id": si["zone"], "in_service": bool(si["in_service"]),
				"zone_kind": "server" if bool(si["in_service"]) else "queue"
			}
		})

	# 7. Queued entities inside q_vip & q_ecom for Outliner inspection
	for q_i in range(3):
		var col := Color("#ef4444") if q_i == 0 else Color("#06b6d4")
		entities_arr.append({
			"id": "vip_q_ent_%d" % (10 + q_i),
			"element_id": "q_vip",
			"zone": "q_vip",
			"priority": 10,
			"properties": {
				"color_r": col.r, "color_g": col.g, "color_b": col.b,
				"mesh_type": "sphere", "priority": 10,
				"attributes": {"order_tier": "VIP_AIR", "sla_deadline": 30.0 + float(q_i) * 5.0, "fragile": true}
			}
		})

	var state_payload := {
		"abm_state": {
			"wip_total": q1_len + q2_len + q3_len + 18,
			"total_arrivals": int(sim_t * 4.6),
			"total_departures": max(0, int(sim_t * 4.6) - (q1_len + q2_len + q3_len + 18)),
			"throughput_eff": tp_rate,
			"sojourn_mean": 16.4 + 0.6 * sin(sim_t * 0.15),
			"littles_law_status": "valid",
			"littles_law_error_pct": 0.4
		},
		"elements_by_id": elems_by_id,
		"entities": entities_arr
	}

	shell.update_simulation_telemetry(state_payload)
	shell._canvas_2d.update_agent_telemetry(agents_arr)
	shell._viewport_3d.update_agent_telemetry(agents_arr)

func _process(_delta: float) -> void:
	frame_count += 1
	_progress_bar.value = float(frame_count)
	var sim_t: float = 60.0 + float(frame_count) * 0.35

	if frame_count < 760:
		_feed_live_telemetry(sim_t, false)

	var cur_frame := frame_count

	# ── CHAPTER 1 (Frames 1..110 = 11s): 4-Zone Complex Plant Overview ───────
	if cur_frame == 1:
		_set_banner(
			1,
			"1. 4-Zone Contiguous Digital Twin — 2D Floorplan, S-Curve Bypass & Vision QA Loop",
			"Zone 1: 3-Dock Receiving → Zone 2: S-Curve Express Bypass + Parallel CNC Cells → Zone 3: Vision QA & 12% Rework Loop → Zone 4: Outbound."
		)
		shell.switch_view(shell.ViewMode.VIEW_2D)
		shell._canvas_2d.pan_offset = Vector2(10, 4)
		shell._canvas_2d.zoom_level = 0.69
		shell._canvas_2d._update_blocks_transform()
		shell._canvas_2d._redraw_all()
		shell.doc_store.select("srv_induct", "element")

	elif cur_frame == 55:
		shell.doc_store.select("srv_qa", "element")

	# ── CHAPTER 2 (Frames 110..200 = 9s): Multi-Wire Bus & Port Channel Manager
	# Plant sits in upper half of canvas; popup sits in the open lower half without covering any machines or wires!
	elif cur_frame == 110:
		_set_banner(
			2,
			"2. Multi-Wire Bus Cardinality & Right-Click Port Channel Manager",
			"Right-click any multi-wire port (3-in / 2-out on Automated Sorter Hub) to inspect, reorder (▲/▼), or delete individual channels."
		)
		shell._canvas_2d.pan_offset = Vector2(10, 2)
		shell._canvas_2d.zoom_level = 0.69
		shell._canvas_2d._update_blocks_transform()
		shell._canvas_2d._redraw_all()
		shell.doc_store.select("srv_induct", "element")
		shell._canvas_2d.open_channel_popup("srv_induct", "flow_in", false, Vector2(540, 385))

	elif cur_frame == 160:
		shell.doc_store.reorder_port_channel("srv_induct", "flow_in", false, 3, 1)
		shell._canvas_2d.open_channel_popup("srv_induct", "flow_in", false, Vector2(540, 385))

	# ── CHAPTER 3 (Frames 200..310 = 11s): Port-Normal Wire Routing Shapes & Waypoints
	# Keep popup in the open lower canvas area so all 3 incoming wires and blocks are 100% unobstructed!
	elif cur_frame == 200:
		var cp = shell._canvas_2d.get_channel_popup()
		if cp != null:
			cp.close_popup()
		_set_banner(
			3,
			"3. Port-Normal Wire Routing Shapes, Waypoint Handles & Styling Popup",
			"Compare Curved Bezier, 90° Orthogonal, and 45° Metro Chamfer wires with draggable waypoint handles (●) and custom stroke styles."
		)
		shell.doc_store.set_default_wire_shape("curved")
		shell.doc_store.select("c_in_3", "connection")
		shell._canvas_2d.open_wire_popup("c_in_3", Vector2(540, 380))

	elif cur_frame == 228:
		shell.doc_store.set_default_wire_shape("orthogonal")
		shell._canvas_2d._redraw_all()

	elif cur_frame == 256:
		shell.doc_store.set_default_wire_shape("chamfer")
		shell._canvas_2d._redraw_all()

	elif cur_frame == 284:
		var conn = shell.doc_store.get_connection("c_in_3")
		if conn != null:
			conn.set_extension_path("visual.stroke_style", "dashed")
			conn.set_extension_path("visual.width", 3.5)
		shell.doc_store.set_default_wire_shape("curved")
		shell._canvas_2d._redraw_all()

	# ── CHAPTER 4 (Frames 310..430 = 12s): Synchronized 3D Factory Viewport ──
	elif cur_frame == 310:
		var wp = shell._canvas_2d.get_wire_popup()
		if wp != null:
			wp.close_popup()
		shell._canvas_2d.pan_offset = Vector2(10, 4)
		shell._canvas_2d.zoom_level = 0.69
		shell._canvas_2d._update_blocks_transform()
		shell._canvas_2d._redraw_all()
		_set_banner(
			4,
			"4. Synchronized 3D Factory Viewport — Contiguous 4-Zone Plant & On-Belt Products",
			"Contiguous 3D workstations, steel roller transfer bridges, S-Curve Express Bypass, and products centered on every belt."
		)
		shell.switch_view(shell.ViewMode.VIEW_3D)
		if shell._viewport_3d._cam_pivot != null:
			shell._viewport_3d._cam_pivot.position = Vector3(29.0, 0.8, -9.5)
		shell._viewport_3d._cam_distance = 32.0
		shell._viewport_3d._cam_pitch = 0.56
		shell._viewport_3d._cam_yaw = -0.42
		shell._viewport_3d._update_camera_transform()

	elif cur_frame > 310 and cur_frame < 430:
		var t_3d: float = float(cur_frame - 310) / 120.0
		shell._viewport_3d._cam_yaw = -0.42 + t_3d * 0.84
		shell._viewport_3d._cam_pitch = 0.56 + sin(t_3d * PI) * 0.12
		shell._viewport_3d._cam_distance = 32.0 - sin(t_3d * PI) * 5.5
		shell._viewport_3d._update_camera_transform()

	# ── CHAPTER 5 (Frames 430..520 = 9s): Live Outliner & Entity Attribute Trees
	elif cur_frame == 430:
		_set_banner(
			5,
			"5. Live Outliner — Real-Time Entity Priorities, Color Swatches & Attribute Trees",
			"Inspect in-flight entities inside queues and curved conveyors with priority badges ([P10]), custom colors, and key-value attributes."
		)
		shell.switch_view(shell.ViewMode.VIEW_2D)
		shell._canvas_2d.pan_offset = Vector2(10, 4)
		shell._canvas_2d.zoom_level = 0.69
		shell._canvas_2d._update_blocks_transform()
		shell._canvas_2d._redraw_all()
		shell.set_left_dock_tab(1)
		shell.doc_store.select("q_vip", "element")

	# ── CHAPTER 6 (Frames 520..640 = 12s): 5-Tab Floating Inspector & SimCore.SimViz Hooks
	# Plant sits cleanly in upper half of canvas; Floating Inspector sits in the open lower half!
	elif cur_frame == 520:
		shell.set_left_dock_tab(0)
		_set_banner(
			6,
			"6A. Floating Inspector — 6 Queue Disciplines & Custom Comparator Expressions",
			"Configure FIFO, LIFO, Priority, EDD, SPT, or a custom Julia comparator expression comparing entity attributes."
		)
		shell._canvas_2d.pan_offset = Vector2(10, 2)
		shell._canvas_2d.zoom_level = 0.69
		shell._canvas_2d._update_blocks_transform()
		shell._canvas_2d._redraw_all()
		shell.doc_store.select("q_ecom", "element")
		shell._floating_inspector.custom_minimum_size = Vector2(560, 385)
		shell._floating_inspector.open_for_element("q_ecom", Vector2(410, 365))
		shell._floating_inspector.position = Vector2(410, 365)
		shell._floating_inspector.size = Vector2(560, 390)
		shell._floating_inspector._switch_tab(3) # Rules / Policy tab

	elif cur_frame == 580:
		_set_banner(
			6,
			"6B. Floating Inspector — SimCore.SimViz Helper Library Hooks (Milestone M-1)",
			"Author readable Julia hooks with pull_from_port_argmax!, set_color!, add_setup_time!, and record_metric!."
		)
		shell.doc_store.select("srv_induct", "element")
		shell._floating_inspector.custom_minimum_size = Vector2(560, 385)
		shell._floating_inspector.open_for_element("srv_induct", Vector2(410, 365))
		shell._floating_inspector.position = Vector2(410, 365)
		shell._floating_inspector.size = Vector2(560, 390)
		shell._floating_inspector._switch_tab(4) # Hooks (SimCore.SimViz) tab

	# ── CHAPTER 7 (Frames 640..760 = 12s): Multi-Subplot Plot Studio (4 Live Charts)
	# Centered at X=100, Width=1240 so 100 + 1240 = 1340 < 1440 (100px margin on both left and right!)
	elif cur_frame == 640:
		shell._floating_inspector.close()
		_set_banner(
			7,
			"7. Universal Multi-Subplot Plot Studio — 4 Live Synchronized Telemetry Charts",
			"2×2 grid: (1) 3-Queue Buffer Lengths, (2) Station Utilization %, (3) Waiting Time Histogram Wq, and (4) Throughput & Rework WIP."
		)
		if shell._plot_studio != null:
			shell._plot_studio.use_implot = false
			shell._plot_studio._update_backend_visibility()
			shell._plot_studio.time_window_seconds = 60.0
			shell._plot_studio.open_for_element("chart_hub")
			shell._plot_studio.position = Vector2(100, 68)
			shell._plot_studio.custom_minimum_size = Vector2(1240, 670)
			shell._plot_studio.size = Vector2(1240, 670)
			shell._plot_studio._redraw_active_subplots()

	# ── CHAPTER 8A (Frames 760..860 = 10s): Optimization Studio Window 1 (Setup & Live Progress)
	elif cur_frame == 760:
		if shell._plot_studio != null:
			shell._plot_studio.visible = false
		_set_banner(
			8,
			"8A. Simulation-Based Optimization Studio — Window 1 (Decision Variables & Setup)",
			"Configure Parameter, Policy, or Topology decision variables, multi-metric objectives, SLA constraints, and SciML / BBO solvers."
		)
		shell.load_example_model("opt_p2_vip_dispatch")
		if shell._optim_feedback != null:
			shell._optim_feedback.close_report()
		if shell._optim_setup != null:
			shell._optim_setup.open_setup()
			shell._optim_setup._setup_panel.position = Vector2(340, 85)
			shell._optim_setup._tabs.current_tab = 0 # Tab 1: Model & Variables

	elif cur_frame == 795:
		if shell._optim_setup != null and shell._optim_setup._tabs != null:
			shell._optim_setup._tabs.current_tab = 1 # Tab 2: Objective Function

	elif cur_frame == 812:
		if shell._optim_setup != null and shell._optim_setup._tabs != null:
			shell._optim_setup._tabs.current_tab = 2 # Tab 3: SLA Constraints

	elif cur_frame == 828:
		_set_banner(
			8,
			"8A. Optimization Studio — Compact Live Evaluation Progress HUD",
			"Real-time optimization progress tracking candidate evaluations, feasible count, and best-so-far objective improvements."
		)
		if shell._optim_setup != null:
			shell._optim_setup.close_setup()
			shell._optim_setup._progress_panel.visible = true
			shell._optim_setup._progress_panel.z_index = 260
			shell._optim_setup._progress_panel.position = Vector2(460, 250)
			_feed_progress_tick(16, 40, 40.0, 6.85)

	elif cur_frame == 844:
		_feed_progress_tick(30, 40, 75.0, 4.95)

	elif cur_frame == 855:
		_feed_progress_tick(40, 40, 100.0, 4.82)

	# ── CHAPTER 8B (Frames 860..1000 = 14s): Optimization Studio Window 2 (Report, Pareto, Top-K & Lightbox)
	elif cur_frame == 860:
		if shell._optim_setup != null:
			shell._optim_setup._progress_panel.visible = false
		_set_banner(
			8,
			"8B. Optimization Studio — Window 2 (Convergence, Pareto Scatter, SLA & Top-K Leaderboard)",
			"Inspect objective convergence, 2D Pareto trade-off scatter, SLA margin bars, Top-K Hall of Fame solutions, and 2D candidate schematics."
		)
		if shell._optim_feedback != null:
			shell._optim_feedback.open_report()
			shell._optim_feedback._report_panel.position = Vector2(160, 68)
			_populate_demo_optimization_report()

	elif cur_frame == 910:
		_set_banner(
			8,
			"8B. Optimization Studio — Interactive Top-K Candidate Comparison (Rank #1 vs Rank #2)",
			"Click any candidate in the Top-K Hall of Fame Leaderboard to preview its topology/policy configuration and 2D schematic."
		)
		if shell._optim_feedback != null:
			shell._optim_feedback.select_candidate_rank(2)

	elif cur_frame == 950:
		_set_banner(
			8,
			"8B. Optimization Studio — Full-Size Zoomable Candidate Schematic Lightbox",
			"Enlarge any Top-K candidate schematic into a full-size interactive lightbox with zoom/pan before applying to the main canvas."
		)
		if shell._optim_feedback != null:
			shell._optim_feedback.select_candidate_rank(1)
			shell._optim_feedback.open_lightbox()
			shell._optim_feedback._lightbox_panel.position = Vector2(260, 95)

	elif cur_frame == 988:
		if shell._optim_feedback != null:
			shell._optim_feedback.close_lightbox()

	if cur_frame >= TOTAL_FRAMES:
		get_tree().quit()

func _feed_progress_tick(iter_n: int, max_n: int, pct: float, best_val: float) -> void:
	var st := {
		"status": "completed" if iter_n >= max_n else "running",
		"title": "VIP vs Standard Support Dispatch Policy",
		"problem_class": "policy",
		"iteration": iter_n,
		"max_iterations": max_n,
		"progress_pct": pct,
		"elapsed_sec": pct * 0.142,
		"feasible_count": max(1, iter_n - 2),
		"best_primary": best_val,
		"best_label": "VIP=2.0s, Util=82%, Shared=4",
		"state_seq": iter_n
	}
	if shell._optim_setup != null and shell._optim_setup.has_method("feed_optim_state"):
		shell._optim_setup.feed_optim_state(st)

func _populate_demo_optimization_report() -> void:
	var base_spec: Dictionary = shell.doc_store.active_document.to_dict()
	var opt_state := {
		"status": "completed",
		"title": "VIP vs Standard Support Dispatch Policy",
		"problem_class": "policy",
		"iteration": 40,
		"max_iterations": 40,
		"progress_pct": 100.0,
		"elapsed_sec": 14.2,
		"feasible_count": 38,
		"best_primary": 4.82,
		"best_label": "VIP=2.0s, Util=82%, Shared=4",
		"state_seq": 99,
		"convergence_history": [
			{"evaluation": 1, "current_objective": 14.6, "best_objective": 14.6},
			{"evaluation": 4, "current_objective": 12.1, "best_objective": 12.1},
			{"evaluation": 8, "current_objective": 13.8, "best_objective": 12.1},
			{"evaluation": 12, "current_objective": 9.4, "best_objective": 9.4},
			{"evaluation": 16, "current_objective": 10.7, "best_objective": 9.4},
			{"evaluation": 20, "current_objective": 7.2, "best_objective": 7.2},
			{"evaluation": 25, "current_objective": 8.5, "best_objective": 7.2},
			{"evaluation": 30, "current_objective": 5.6, "best_objective": 5.6},
			{"evaluation": 35, "current_objective": 4.95, "best_objective": 4.95},
			{"evaluation": 40, "current_objective": 4.82, "best_objective": 4.82}
		],
		"scatter_points": [
			{"secondary_objective": 3.8, "primary_objective": 12.4, "is_feasible": true, "rank": 0},
			{"secondary_objective": 3.2, "primary_objective": 10.9, "is_feasible": true, "rank": 0},
			{"secondary_objective": 2.8, "primary_objective": 9.1, "is_feasible": true, "rank": 0},
			{"secondary_objective": 2.4, "primary_objective": 6.10, "is_feasible": true, "rank": 3},
			{"secondary_objective": 1.9, "primary_objective": 7.40, "is_feasible": true, "rank": 0},
			{"secondary_objective": 1.6, "primary_objective": 5.45, "is_feasible": true, "rank": 2},
			{"secondary_objective": 1.12, "primary_objective": 4.82, "is_feasible": true, "rank": 1},
			{"secondary_objective": 4.1, "primary_objective": 15.2, "is_feasible": false, "rank": 0},
			{"secondary_objective": 4.6, "primary_objective": 16.8, "is_feasible": false, "rank": 0}
		],
		"sla_margins": [
			{"label": "VIP Wait <= 2.0s", "value": 1.12, "limit": 2.0, "satisfied": true},
			{"label": "Std Wait <= 8.0s", "value": 4.82, "limit": 8.0, "satisfied": true},
			{"label": "Pool Util <= 90%", "value": 0.81, "limit": 0.90, "satisfied": true}
		],
		"top_k_solutions": [
			{
				"rank": 1,
				"candidate_id": "cand_01",
				"decision_summary": "VIP Thresh: 2.0s | Pool Util: 82% | Shared Srv: 4",
				"primary_objective": 4.82,
				"secondary_objective": 1.12,
				"is_feasible": true,
				"decision_variables": {"vip_queue_threshold": 2.0, "pool_util_threshold": 0.82, "shared_servers": 4},
				"parameters": {"vip_queue_threshold": 2.0, "pool_util_threshold": 0.82, "shared_servers": 4},
				"metrics": {"std_wait_mean": 4.82, "vip_wait_mean": 1.12, "throughput_eff": 4.15},
				"scenespec": base_spec
			},
			{
				"rank": 2,
				"candidate_id": "cand_02",
				"decision_summary": "VIP Thresh: 3.0s | Pool Util: 78% | Shared Srv: 3",
				"primary_objective": 5.45,
				"secondary_objective": 1.60,
				"is_feasible": true,
				"decision_variables": {"vip_queue_threshold": 3.0, "pool_util_threshold": 0.78, "shared_servers": 3},
				"parameters": {"vip_queue_threshold": 3.0, "pool_util_threshold": 0.78, "shared_servers": 3},
				"metrics": {"std_wait_mean": 5.45, "vip_wait_mean": 1.60, "throughput_eff": 4.10},
				"scenespec": base_spec
			},
			{
				"rank": 3,
				"candidate_id": "cand_03",
				"decision_summary": "VIP Thresh: 1.0s | Pool Util: 88% | Shared Srv: 2",
				"primary_objective": 6.10,
				"secondary_objective": 2.40,
				"is_feasible": true,
				"decision_variables": {"vip_queue_threshold": 1.0, "pool_util_threshold": 0.88, "shared_servers": 2},
				"parameters": {"vip_queue_threshold": 1.0, "pool_util_threshold": 0.88, "shared_servers": 2},
				"metrics": {"std_wait_mean": 6.10, "vip_wait_mean": 2.40, "throughput_eff": 3.88},
				"scenespec": base_spec
			}
		]
	}
	if shell._optim_setup != null and shell._optim_setup.has_method("feed_optim_state"):
		shell._optim_setup.feed_optim_state(opt_state)
	if shell._optim_feedback != null and shell._optim_feedback.has_method("feed_optim_state"):
		shell._optim_feedback.feed_optim_state(opt_state)
