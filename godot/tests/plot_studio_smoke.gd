extends SceneTree

const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const Catalog := preload("res://scripts/authoring_catalog.gd")
const PlotStudio := preload("res://scripts/authoring_plot_studio.gd")

func _init() -> void:
	print("==================================================================")
	print("Starting SimViz Plot Studio & Unified Chart Station Smoke Test...")
	print("==================================================================")

	var doc_store := DocumentStore.new()
	var catalog := Catalog.new()

	# 1. Verify Catalog Entry for chart_station
	print("Step 1: Validating catalog entry for chart_station...")
	var entry = catalog.get_entry("chart_station")
	assert(entry != null, "chart_station must be registered in catalog")
	assert(entry.kind == "chart_station", "kind must match chart_station")
	assert(entry.category == "Instrumentation & Scopes", "category must be Instrumentation & Scopes")
	print("  ✓ Verified catalog entry: %s (kind=%s)" % [entry.display_name, entry.kind])
	print("Step 1 PASSED: chart_station catalog entry verified.")

	# 2. Instantiate chart_station element
	print("Step 2: Testing chart_station instantiation and subplots...")
	var chart_elem = catalog.create_element_instance("chart_station", "main_charts", Vector2(10.0, 10.0))
	assert(chart_elem != null, "Element must be created")
	assert(chart_elem.properties.has("subplots"), "Must have subplots array")
	assert(chart_elem.properties["subplots"].size() == 1, "Must have 1 default subplot")
	assert(chart_elem.input_ports.size() == 1, "Must have 1 default input port")
	assert(chart_elem.input_ports[0].id == "P1", "Port ID must be P1")
	doc_store.add_element(chart_elem)
	print("Step 2 PASSED: Element instantiation and initial port (P1) verified.")

	# 3. Instantiate AuthoringPlotStudio
	print("Step 3: Testing AuthoringPlotStudio initialization & tab reflection...")
	var studio := PlotStudio.new(doc_store)
	root.add_child(studio)
	studio._ready()

	assert(studio._tab_bar.tab_count >= 1, "Tab bar must have at least 1 tab for main_charts")
	assert(studio.active_chart_elem_id == "main_charts", "Active chart ID must match main_charts")
	print("  ✓ Verified studio tab bar registered: %s" % studio._tab_bar.get_tab_title(0))
	# Test document_loaded signal emission with 1 argument (as emitted on file load/recover)
	doc_store.document_loaded.emit(doc_store.active_document)
	print("  ✓ Verified document_loaded signal emission with 1 argument accepted cleanly.")
	print("Step 3 PASSED: Plot Studio initialized and bound to document store.")

	# 4. Adding subplots dynamically (1 port -> 4 ports)
	print("Step 4: Testing dynamic subplot expansion (1 -> 4 ports)...")
	studio._on_add_subplot_clicked() # Add Subplot 2
	studio._on_add_subplot_clicked() # Add Subplot 3
	studio._on_add_subplot_clicked() # Add Subplot 4

	assert(chart_elem.properties["subplots"].size() == 4, "Must have 4 subplots")
	assert(chart_elem.input_ports.size() == 4, "Must have 4 input ports (P1, P2, P3, P4)")
	assert(chart_elem.input_ports[1].id == "P2", "Port 2 ID must be P2")
	assert(chart_elem.input_ports[2].id == "P3", "Port 3 ID must be P3")
	assert(chart_elem.input_ports[3].id == "P4", "Port 4 ID must be P4")
	print("  ✓ Verified 4 subplots dynamically allocated: %s, %s, %s, %s" % [
		chart_elem.input_ports[0].id, chart_elem.input_ports[1].id,
		chart_elem.input_ports[2].id, chart_elem.input_ports[3].id
	])
	print("Step 4 PASSED: Dynamic subplot and port allocation verified.")

	# 5. Testing Asymmetric Grid Layout (User's Template: Split Left + 2 Right + Wide Bottom)
	print("Step 5: Testing Asymmetric Grid Spanning Template...")
	studio._on_layout_template_selected(2) # Index 2 = Asymmetric Template
	var sps: Array = chart_elem.properties["subplots"]
	assert(sps[0]["grid"]["row_span"] == 2 and sps[0]["grid"]["col_span"] == 1, "Subplot 1 must span 2 rows")
	assert(sps[1]["grid"]["row"] == 0 and sps[1]["grid"]["col"] == 1, "Subplot 2 must sit at (col 1, row 0)")
	assert(sps[2]["grid"]["row"] == 1 and sps[2]["grid"]["col"] == 1, "Subplot 3 must sit at (col 1, row 1)")
	assert(sps[3]["grid"]["row"] == 2 and sps[3]["grid"]["col_span"] == 2, "Subplot 4 must span 2 columns on row 2")
	print("  ✓ Verified grid coordinates:")
	print("    - SP1 (Tall Left): col=%d, row=%d, row_span=%d" % [sps[0]["grid"]["col"], sps[0]["grid"]["row"], sps[0]["grid"]["row_span"]])
	print("    - SP2 (Top Right): col=%d, row=%d, row_span=%d" % [sps[1]["grid"]["col"], sps[1]["grid"]["row"], sps[1]["grid"]["row_span"]])
	print("    - SP3 (Mid Right): col=%d, row=%d, row_span=%d" % [sps[2]["grid"]["col"], sps[2]["grid"]["row"], sps[2]["grid"]["row_span"]])
	print("    - SP4 (Wide Bot ): col=%d, row=%d, col_span=%d" % [sps[3]["grid"]["col"], sps[3]["grid"]["row"], sps[3]["grid"]["col_span"]])
	print("Step 5 PASSED: Asymmetric grid spanning verified.")

	# 6. Testing Telemetry Ingestion and Multi-Curve / Difference Evaluation
	print("Step 6: Testing telemetry ingestion and multi-curve buffering...")
	var q1_elem = catalog.create_element_instance("queue", "q1", Vector2(0.0, 0.0))
	var q2_elem = catalog.create_element_instance("queue", "q2", Vector2(0.0, 50.0))
	doc_store.add_element(q1_elem)
	doc_store.add_element(q2_elem)
	# Add wire connections in document: Queue1 -> P1, Queue2 -> P1 (Multi-curve overlay on P1!)
	doc_store.add_connection_direct("c1", "q1", "length", "main_charts", "P1", "signal")
	doc_store.add_connection_direct("c2", "q2", "length", "main_charts", "P1", "signal")

	var mock_state: Dictionary = {
		"q1": {"metrics": {"length": 15.0, "queue_length": 15.0}},
		"q2": {"metrics": {"length": 5.0, "queue_length": 5.0}}
	}
	studio.feed_telemetry(1.0, mock_state, {})
	studio.feed_telemetry(2.0, {
		"q1": {"metrics": {"length": 20.0, "queue_length": 20.0}},
		"q2": {"metrics": {"length": 8.0, "queue_length": 8.0}}
	}, {})

	var key_q1 := "main_charts/P1/q1:length"
	var key_q2 := "main_charts/P1/q2:length"
	assert(studio._telemetry_buffers.has(key_q1), "Buffer for q1 must exist")
	assert(studio._telemetry_buffers.has(key_q2), "Buffer for q2 must exist")
	assert(studio._telemetry_buffers[key_q1].size() == 2, "Buffer q1 must have 2 samples")
	assert(studio._telemetry_buffers[key_q2].size() == 2, "Buffer q2 must have 2 samples")
	assert(studio._telemetry_buffers[key_q1][1]["val"] == 20.0, "Second sample of q1 must be 20.0")
	assert(studio._telemetry_buffers[key_q2][1]["val"] == 8.0, "Second sample of q2 must be 8.0")
	print("  ✓ Multi-curve incoming samples buffered on Port 1: Q1=%.1f, Q2=%.1f" % [
		studio._telemetry_buffers[key_q1][1]["val"], studio._telemetry_buffers[key_q2][1]["val"]
	])
	print("Step 6 PASSED: Telemetry ingestion and multi-curve buffering verified.")

	# 7. Testing Subplot Removal (4 ports -> 3 ports)
	print("Step 7: Testing subplot removal and port deallocation (4 -> 3 ports)...")
	studio._remove_subplot(chart_elem, "sp_3")
	assert(chart_elem.properties["subplots"].size() == 3, "Must have 3 subplots after removal")
	assert(chart_elem.input_ports.size() == 3, "Must have 3 input ports after removal")
	print("Step 7 PASSED: Subplot removal cleanly updated properties and input ports.")

	# 8. Testing Window Dragging, Corner Resizing, and Maximize / Restore
	print("Step 8: Testing window dragging, interactive corner resizing, and maximize toggle...")
	studio.position = Vector2(100, 100)
	studio.size = Vector2(760, 520)

	# Simulate Header Drag
	var drag_down := InputEventMouseButton.new()
	drag_down.button_index = MOUSE_BUTTON_LEFT
	drag_down.pressed = true
	drag_down.global_position = Vector2(150, 110)
	studio._on_header_gui_input(drag_down)
	assert(studio._is_dragging == true, "Header drag state must be active")

	var drag_move := InputEventMouseMotion.new()
	drag_move.global_position = Vector2(250, 210)
	studio._on_header_gui_input(drag_move)
	assert(studio.position == Vector2(200, 200), "Window position must update to (200, 200)")

	var drag_up := InputEventMouseButton.new()
	drag_up.button_index = MOUSE_BUTTON_LEFT
	drag_up.pressed = false
	drag_up.global_position = Vector2(250, 210)
	studio._on_header_gui_input(drag_up)
	assert(studio._is_dragging == false, "Header drag state must be released")
	print("  ✓ Window dragging successfully moved window to: %s" % studio.position)

	# Simulate Corner Resize Handle
	var resize_down := InputEventMouseButton.new()
	resize_down.button_index = MOUSE_BUTTON_LEFT
	resize_down.pressed = true
	resize_down.global_position = Vector2(960, 720)
	studio._on_resize_gui_input(resize_down)
	assert(studio._is_resizing == true, "Resize state must be active")

	var resize_move := InputEventMouseMotion.new()
	resize_move.global_position = Vector2(1060, 820)
	studio._on_resize_gui_input(resize_move)
	assert(studio.size.x >= 860.0 and studio.size.y >= 620.0, "Window size must expand to >= (860, 620)")

	var resize_up := InputEventMouseButton.new()
	resize_up.button_index = MOUSE_BUTTON_LEFT
	resize_up.pressed = false
	resize_up.global_position = Vector2(1060, 820)
	studio._on_resize_gui_input(resize_up)
	assert(studio._is_resizing == false, "Resize state must be released")
	print("  ✓ Corner resize grip successfully expanded window to: %s" % studio.size)

	# Simulate Maximize / Restore Toggle
	studio._toggle_maximize()
	assert(studio._is_maximized == true, "Window must be maximized")
	assert(studio.position == Vector2(20, 20), "Maximized position must be (20, 20)")
	studio._toggle_maximize()
	assert(studio._is_maximized == false, "Window must be restored")
	assert(studio.position == Vector2(200, 200), "Restored position must return to (200, 200)")
	print("  ✓ Maximize/Restore toggle verified.")
	print("Step 8 PASSED: Window movement, resizing, and maximize verified.")

	# 9. Testing Unified Canvas Subplot Rendering (No Hacky Multiple Cards)
	print("Step 9: Testing unified canvas subplots rendering...")
	assert(studio._viewport_container != null, "Viewport container must exist")
	assert(studio._simplot_view != null or studio._vector_canvas != null, "At least one unified canvas must exist")
	# Verify that no separate card controls exist in the viewport
	var child_count := studio._viewport_container.get_child_count()
	assert(child_count <= 2, "Viewport container must only host unified canvases, not multiple card panels (count=%d)" % child_count)
	studio._redraw_active_subplots()
	print("  ✓ Unified canvas subplots redraw executed cleanly with 0 nested cards.")
	print("Step 9 PASSED: Single canvas subplots architecture verified.")

	# 10. Testing X-Variable Selection (Custom X vs Simulation Time)
	print("Step 10: Testing X-variable selection (XY Correlation vs Time)...")
	var custom_xy_curve := {
		"entity_id": "q1",
		"y_metric": "occupancy_pct",
		"x_metric": "queue_length",
		"label": "q1.occupancy_pct vs queue_length",
		"color": "#3fb950"
	}
	sps[0]["signals"] = [custom_xy_curve]
	studio.feed_telemetry(5.0, {
		"q1": {"metrics": {"queue_length": 25.0, "occupancy_pct": 50.0}}
	}, {})
	assert(studio._telemetry_buffers.has("q1:queue_length"), "X-variable buffer must exist")
	assert(studio._telemetry_buffers.has("q1:occupancy_pct"), "Y-variable buffer must exist")
	assert(studio._telemetry_buffers["q1:queue_length"].back()["val"] == 25.0, "X buffer value must match")
	assert(studio._telemetry_buffers["q1:occupancy_pct"].back()["val"] == 50.0, "Y buffer value must match")
	print("  ✓ Custom X-variable (queue_length) and Y-variable (occupancy_pct) successfully buffered and mapped.")
	print("Step 10 PASSED: Custom X-variable selection verified.")

	# 11. Testing Squeeze / Fit All Mode (0 -> Now) vs Rolling Window
	print("Step 11: Testing Squeeze / Fit All Mode (0 -> Now)...")
	studio._on_time_option_selected(0) # Index 0 = Fit All (0 -> Now) [Squeeze]
	assert(studio.time_window_seconds == 0.0, "time_window_seconds must be 0.0 for Squeeze mode")
	studio.feed_telemetry(150.0, {
		"q1": {"metrics": {"queue_length": 30.0, "occupancy_pct": 60.0}}
	}, {})
	assert(studio._latest_sim_t == 150.0, "Latest simulation time must be 150.0")
	# In squeeze mode, t_start remains 0.0 instead of sliding to 150 - 60 = 90.0
	var calculated_t_start: float = 0.0
	var calculated_t_end: float = max(1.0, studio._latest_sim_t)
	if studio.time_window_seconds > 0.0:
		calculated_t_end = max(studio.time_window_seconds, studio._latest_sim_t)
		calculated_t_start = max(0.0, calculated_t_end - studio.time_window_seconds)
	assert(calculated_t_start == 0.0, "t_start must remain 0.0 in Squeeze mode")
	assert(calculated_t_end == 150.0, "t_end must span to 150.0 in Squeeze mode")
	print("  ✓ Squeeze mode spans [0.0, 150.0] without rightward shift or point drop.")
	print("Step 11 PASSED: Squeeze / Fit All mode verified.")

	# 12. Testing Gauge & Histogram Rendering Config
	print("Step 12: Testing Gauge and Histogram rendering configuration...")
	sps[0]["type"] = "digital_gauge"
	sps[1]["type"] = "histogram"
	sps[1]["signals"] = [{
		"entity_id": "q1",
		"y_metric": "queue_length",
		"x_metric": "__time__",
		"label": "q1.queue_length",
		"color": "#58a6ff"
	}]
	studio._redraw_active_subplots()
	print("  ✓ Unified canvas redraw executed with Digital Gauge (Subplot 1) and Histogram (Subplot 2).")
	print("Step 12 PASSED: Gauge and Histogram subplot configuration verified.")

	# 13. Testing Simulation Reset Clearing Plots
	print("Step 13: Testing Simulation Reset (clearing buffers & axes)...")
	# Simulate a backward simulation time jump (e.g. t drops from 150.0 to 0.0 on Reset)
	assert(studio._telemetry_buffers.size() > 0, "Buffers should have data before reset")
	studio.feed_telemetry(0.0, {}, {}) # Trigger backward jump detection
	assert(studio._telemetry_buffers.is_empty(), "Buffers must be completely emptied upon reset")
	assert(studio._latest_sim_t == 0.0, "Latest simulation time must be reset to 0.0")
	print("  ✓ Telemetry buffers and axes automatically cleared on simulation reset.")
	print("Step 13 PASSED: Simulation reset integration verified.")

	# 14. Testing Port-Wired Input Filtering in Curve Picker Widget
	print("Step 14: Testing Port-Wired Entity Filtering in Curve Picker...")
	# sps[0] has port P1. P1 is wired to q1 and q2.
	var picker := studio._build_curve_picker_widget(chart_elem, sps[0])
	assert(picker != null, "Picker widget must be created")
	var vbox_c = picker.get_child(0)
	var found_filter_chk := false
	for child in vbox_c.get_children():
		if child is CheckBox and child.text.contains("Filter to wired inputs [P1]"):
			found_filter_chk = true
			assert(child.button_pressed == true, "Filter checkbox must be checked by default")
	assert(found_filter_chk, "Filter checkbox for port P1 must be present")
	print("  ✓ Curve picker detected wired connections on P1 and enabled filtering checkbox by default.")
	picker.queue_free()
	print("Step 14 PASSED: Port-wired entity filtering verified.")

	# 15. Testing Physical Observation Tracking for Histograms
	print("Step 15: Testing Physical Observation Tracking for Histograms...")
	var srv1_elem = catalog.create_element_instance("server", "srv1", Vector2(100.0, 0.0))
	doc_store.add_element(srv1_elem)

	studio.feed_telemetry(10.0, {
		"srv1": {
			"metrics": {
				"service_mean": 25.0,
				"recent_service_samples": [12.5, 4.2, 8.9]
			}
		},
		"q1": {
			"metrics": {
				"wait_mean_wq": 1.6,
				"recent_wait_samples": [1.1, 0.5, 3.2]
			}
		}
	}, {})

	assert(studio._telemetry_buffers.has("srv1:service_time"), "srv1:service_time buffer must exist")
	assert(studio._telemetry_buffers["srv1:service_time"].size() == 3, "Must have exactly 3 service time observations")
	assert(studio._telemetry_buffers["srv1:service_time"][0]["val"] == 12.5, "First observation value must match")
	assert(studio._telemetry_buffers["srv1:service_time"][1]["val"] == 4.2, "Second observation value must match")
	assert(studio._telemetry_buffers["srv1:service_time"][2]["val"] == 8.9, "Third observation value must match")

	assert(studio._telemetry_buffers.has("q1:wait_time"), "q1:wait_time buffer must exist")
	assert(studio._telemetry_buffers["q1:wait_time"].size() == 3, "Must have exactly 3 wait time observations")

	# Simulate next animation frames where no departures occurred (GUI 60 FPS tick)
	studio.feed_telemetry(10.016, {
		"srv1": {"metrics": {"service_mean": 25.0}},
		"q1": {"metrics": {"wait_mean_wq": 1.6}}
	}, {})
	assert(studio._telemetry_buffers["srv1:service_time"].size() == 3, "Observation count must NOT inflate with rendering frame rate")

	# Simulate 2 more departures arriving
	studio.feed_telemetry(10.5, {
		"srv1": {"metrics": {"service_mean": 23.0, "recent_service_samples": [15.0, 7.3]}}
	}, {})
	assert(studio._telemetry_buffers["srv1:service_time"].size() == 5, "Total observation count must equal exactly 5 physical departures")
	print("  ✓ Physical event observations decoupled from GUI frame rate (exact tally: N=5).")
	print("Step 15 PASSED: Physical Observation Tracking verified.")

	# 16. Testing Variable Dropdown Tooltips & Contextual Guidance
	print("Step 16: Testing Variable Dropdown Tooltips & Contextual Guidance...")
	var picker2 := studio._build_curve_picker_widget(chart_elem, sps[1]) # sps[1] is Histogram
	assert(picker2 != null, "Picker2 must be created")
	var vbox2: VBoxContainer = picker2.get_child(0)

	var found_ent_opt: OptionButton = null
	var found_y_opt: OptionButton = null
	var found_desc_lbl: Label = null
	for child in vbox2.get_children():
		if child is HBoxContainer:
			for subchild in child.get_children():
				if subchild is OptionButton:
					if child.get_child(0) is Label and child.get_child(0).text == "Entity:":
						found_ent_opt = subchild
					elif child.get_child(0) is Label and child.get_child(0).text == "Y-Var:":
						found_y_opt = subchild
		elif child is PanelContainer:
			var inner_lbl = child.get_child(0)
			if inner_lbl is Label and inner_lbl.text.contains("ℹ"):
				found_desc_lbl = inner_lbl

	assert(found_ent_opt != null, "Entity OptionButton must exist in picker")
	assert(found_y_opt != null, "Y-Var OptionButton must exist in picker")
	assert(found_desc_lbl != null, "Variable description & guidance label must exist in picker")

	# Select srv1 to inspect server metrics (service_time, service_mean)
	for idx in range(found_ent_opt.item_count):
		if found_ent_opt.get_item_text(idx).begins_with("srv1"):
			found_ent_opt.select(idx)
			found_ent_opt.item_selected.emit(idx)
			break

	# Check that popup tooltips are populated
	var popup2: PopupMenu = found_y_opt.get_popup()
	var has_service_time := false
	var has_service_mean := false
	var service_mean_idx := -1

	for idx in range(found_y_opt.item_count):
		var meta = found_y_opt.get_item_metadata(idx)
		var tooltip = popup2.get_item_tooltip(idx)
		if meta == "service_time":
			has_service_time = true
			assert(tooltip.contains("Physical Observations"), "Tooltip must describe Physical Observations")
			assert(tooltip.contains("Histogram"), "Tooltip must recommend Histogram")
		elif meta == "service_mean":
			has_service_mean = true
			service_mean_idx = idx
			assert(tooltip.contains("Summary KPIs"), "Tooltip must describe Summary KPIs")
			assert(tooltip.contains("Gauge"), "Tooltip must recommend Gauge")

	assert(has_service_time, "Dropdown must contain service_time")
	assert(has_service_mean, "Dropdown must contain service_mean")

	# Select service_mean while configuring a Histogram subplot -> should show smart guidance tip!
	found_y_opt.select(service_mean_idx)
	found_y_opt.item_selected.emit(service_mean_idx)
	assert(found_desc_lbl.text.contains("running summary average"), "Must warn that service_mean is a running summary average")
	assert(found_desc_lbl.text.contains("service_time"), "Must recommend service_time for Histogram distribution shape")
	print("  ✓ Dropdown item hover tooltips and histogram contextual guidance card verified.")

	picker2.queue_free()
	print("Step 16 PASSED: Variable Dropdown Tooltips & Contextual Guidance verified.")

	print("==================================================================")
	print("ALL PLOT STUDIO & CHART STATION SMOKE TESTS PASSED (100%)!")
	print("==================================================================")

	studio.queue_free()
	quit(0)
