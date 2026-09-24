# authoring_kpi_smoke.gd
# Headless smoke test for Phase 7D-12D In-Engine Live Telemetry & KPI Display.
extends SceneTree

const AuthoringShell := preload("res://scripts/authoring_shell.gd")
const SceneTypes := preload("res://scripts/scenespec_types.gd")

func _init() -> void:
	print("Starting Phase 7D-12D In-Engine Live Telemetry & KPI Smoke Test...")
	
	var shell := AuthoringShell.new()
	shell._build_ui()
	shell._connect_signals()
	
	# Step 1: Verify Initial Transport Bar & KPI Strip
	print("Step 1: Checking Initial Transport Bar & Global KPI Strip...")
	assert(shell._kpi_strip_label != null, "KPI strip label must be instantiated")
	print(" - Initial KPI strip text: '%s'" % shell._kpi_strip_label.text)
	assert(shell._kpi_strip_label.text.contains("WIP: 0"), "Initial WIP should be 0")
	print("Step 1 PASSED: Transport KPI strip initialized cleanly.")

	# Step 2: Build tandem model in doc_store
	print("Step 2: Building tandem test model...")
	var ds = shell.doc_store
	var s := SceneTypes.SceneElement.new()
	s.id = "src1"; s.kind = "source"; s.name = "Infeed"
	s.transform.position = Vector3(0.0, 0.0, 0.0)
	var q := SceneTypes.SceneElement.new()
	q.id = "q1"; q.kind = "queue"; q.name = "Buffer"
	q.transform.position = Vector3(5.0, 0.0, 0.0)
	var srv := SceneTypes.SceneElement.new()
	srv.id = "srv1"; srv.kind = "server"; srv.name = "Machine"
	srv.transform.position = Vector3(10.0, 0.0, 0.0)
	var conv := SceneTypes.SceneElement.new()
	conv.id = "conv1"; conv.kind = "conveyor"; conv.name = "Belt"
	conv.transform.position = Vector3(15.0, 0.0, 0.0)
	var snk := SceneTypes.SceneElement.new()
	snk.id = "snk1"; snk.kind = "sink"; snk.name = "Exit"
	snk.transform.position = Vector3(25.0, 0.0, 0.0)

	ds.add_element(s)
	ds.add_element(q)
	ds.add_element(srv)
	ds.add_element(conv)
	ds.add_element(snk)
	shell._canvas_2d.rebuild_blocks()
	print("Step 2 PASSED: 5 elements created in document store and canvas blocks built.")

	# Step 3: Simulate incoming rich telemetry snapshot
	print("Step 3: Simulating incoming rich live telemetry snapshot...")
	var mock_state: Dictionary = {
		"simulation_time": 42.5,
		"abm_state": {
			"wip_total": 7,
			"total_arrivals": 50,
			"total_departures": 43,
			"throughput_eff": 1.012,
			"throughput_per_min": 60.7,
			"sojourn_mean": 4.25,
			"wait_mean": 1.10,
			"flow_balance_error": 0,
			"flow_balance_ok": true,
			"warmup_complete": true,
			"littles_law_error_pct": 0.45,
			"littles_law_status": "valid"
		},
		"elements_by_id": {
			"src1": {
				"element_id": "src1",
				"element_kind": "source",
				"occupancy": 0,
				"custom_metrics": {
					"kind": "source",
					"total_arrivals": 50,
					"rate_per_sec": 1.18,
					"badge": "[ 50 in ]"
				}
			},
			"q1": {
				"element_id": "q1",
				"element_kind": "queue",
				"occupancy": 3,
				"custom_metrics": {
					"kind": "queue",
					"queue_length": 3,
					"capacity": 20,
					"occupancy_pct": 15.0,
					"wait_mean_wq": 1.10,
					"total_entered": 50,
					"total_departed": 47,
					"badge": "[ 3/20 ]"
				}
			},
			"srv1": {
				"element_id": "srv1",
				"element_kind": "server",
				"occupancy": 1,
				"custom_metrics": {
					"kind": "server",
					"state": "BUSY",
					"busy_servers": 1,
					"num_servers": 1,
					"utilization_pct": 78.4,
					"instant_util_pct": 100.0,
					"total_served": 46,
					"service_mean": 2.15,
					"badge": "[ 78% BUSY ]"
				}
			},
			"conv1": {
				"element_id": "conv1",
				"element_kind": "conveyor",
				"occupancy": 3,
				"custom_metrics": {
					"kind": "conveyor",
					"items_in_transit": 3,
					"speed": 1.5,
					"length": 10.0,
					"transit_delay": 6.67,
					"total_transited": 43,
					"badge": "[ 3 transit ]"
				}
			},
			"snk1": {
				"element_id": "snk1",
				"element_kind": "sink",
				"occupancy": 0,
				"custom_metrics": {
					"kind": "sink",
					"total_departures": 43,
					"throughput_per_sec": 1.01,
					"throughput_per_min": 60.7,
					"badge": "[ 43 done ]"
				}
			}
		}
	}

	shell.update_simulation_telemetry(mock_state)

	# Verify KPI Strip updated
	print(" - Updated KPI strip: '%s'" % shell._kpi_strip_label.text)
	assert(shell._kpi_strip_label.text.contains("WIP: 7"), "WIP should be 7")
	assert(shell._kpi_strip_label.text.contains("In: 50"), "In arrivals should be 50")
	assert(shell._kpi_strip_label.text.contains("Out: 43"), "Out departures should be 43")
	assert(shell._kpi_strip_label.text.contains("VALID (0.5%)"), "Little's Law status should be valid")
	print("Step 3 PASSED: Global KPI Strip updated accurately.")

	# Step 4: Verify Canvas Block Badges
	print("Step 4: Checking Canvas 2D Block Badges...")
	var c2d = shell._canvas_2d
	assert(c2d != null, "Canvas 2D must exist")
	var srv_node = c2d._block_nodes.get("srv1", null)
	assert(srv_node != null, "Server block node must exist")
	assert(srv_node.live_metrics.get("badge") == "[ 78% BUSY ]", "Server badge should match")

	var q_node = c2d._block_nodes.get("q1", null)
	assert(q_node != null, "Queue block node must exist")
	assert(q_node.live_metrics.get("badge") == "[ 3/20 ]", "Queue badge should match")

	var conv_node = c2d._block_nodes.get("conv1", null)
	assert(conv_node != null, "Conveyor block node must exist")
	assert(conv_node.live_metrics.get("badge") == "[ 3 transit ]", "Conveyor badge should match")

	var snk_node = c2d._block_nodes.get("snk1", null)
	assert(snk_node != null, "Sink block node must exist")
	assert(snk_node.live_metrics.get("badge") == "[ 43 done ]", "Sink badge should match")
	print("Step 4 PASSED: Canvas 2D Block Badges populated on all stations.")

	# Step 5: Verify Inspector Live Telemetry Card
	print("Step 5: Checking Inspector Live Telemetry Card for selected element...")
	var insp = shell._inspector_panel
	assert(insp != null, "Inspector panel must exist")

	# Select Server
	ds.select("srv1", "element")
	insp.refresh()
	# Apply live metrics to newly refreshed inspector card
	insp.update_live_element_metrics(mock_state.elements_by_id)
	assert(insp._live_status_label != null, "Inspector live status label must exist")
	assert(insp._live_status_label.text == "● BUSY", "Server live status should be ● BUSY")
	assert(insp._live_util_bar.value == 78.4, "Server utilization bar value should be 78.4%")
	assert(insp._live_metric_lbl_1.text.contains("46 units"), "Total served should be 46 units")
	print(" - Server Inspector live card: status='%s', util=%.1f%%, %s" % [
		insp._live_status_label.text, insp._live_util_bar.value, insp._live_metric_lbl_1.text
	])

	# Select Queue
	ds.select("q1", "element")
	insp.refresh()
	insp.update_live_element_metrics(mock_state.elements_by_id)
	assert(insp._live_status_label.text == "3 / 20", "Queue live status should be 3 / 20")
	assert(insp._live_util_bar.value == 15.0, "Queue occupancy bar should be 15%")
	assert(insp._live_metric_lbl_1.text.contains("1.10 s"), "Queue mean wait should be 1.10 s")
	print(" - Queue Inspector live card: status='%s', occ=%.1f%%, %s" % [
		insp._live_status_label.text, insp._live_util_bar.value, insp._live_metric_lbl_1.text
	])

	# Select Conveyor
	ds.select("conv1", "element")
	insp.refresh()
	insp.update_live_element_metrics(mock_state.elements_by_id)
	assert(insp._live_status_label.text == "● RUNNING", "Conveyor live status should be ● RUNNING")
	assert(insp._live_metric_lbl_1.text.contains("1.50 m/s"), "Conveyor speed should be 1.50 m/s")
	print(" - Conveyor Inspector live card: status='%s', %s" % [
		insp._live_status_label.text, insp._live_metric_lbl_1.text
	])

	# Select Sink
	ds.select("snk1", "element")
	insp.refresh()
	insp.update_live_element_metrics(mock_state.elements_by_id)
	assert(insp._live_status_label.text == "DRAINING", "Sink live status should be DRAINING")
	assert(insp._live_metric_lbl_1.text.contains("1.01 / sec"), "Throughput rate should be 1.01 / sec")
	print(" - Sink Inspector live card: status='%s', %s" % [
		insp._live_status_label.text, insp._live_metric_lbl_1.text
	])

	print("Step 5 PASSED: Inspector Live Telemetry Card verified across all station types!")

	print("\n========================================================================")
	print("ALL PHASE 7D-12D IN-ENGINE TELEMETRY & KPI TESTS PASSED 100%!")
	print("========================================================================")
	quit(0)
