extends SceneTree

const SimplotDock := preload("res://scripts/authoring_simplot_dock.gd")

func _init() -> void:
	print("==================================================================")
	print("Starting AuthoringSimplotDock & Waveforms Smoke Test...")
	print("==================================================================")

	var dock := SimplotDock.new()
	root.add_child(dock)
	dock._ready()

	print("Step 1: Checking initial state...")
	assert(dock.current_tab == SimplotDock.PlotTab.QUEUES, "Initial tab should be QUEUES")
	assert(!dock.is_frozen, "Initial state should not be frozen")
	print("Step 1 PASSED: Initial dock state verified.")

	print("Step 2: Ingesting streaming telemetry samples...")
	for step in range(30):
		var sim_t: float = float(step) * 0.5
		var elems := {
			"queue_1": {
				"type": "queue",
				"metrics": {
					"queue_length": 3 + (step % 5),
					"capacity": 20,
					"wait_mean": 2.1
				}
			},
			"server_1": {
				"type": "server",
				"metrics": {
					"utilization": 0.75 + 0.1 * sin(step * 0.2),
					"total_served": 10 + step
				}
			},
			"conv_1": {
				"type": "conveyor",
				"metrics": {
					"items_in_transit": 2 + (step % 3)
				}
			}
		}
		var global_kpis := {
			"wip_total": 5 + (step % 4),
			"throughput_eff": 1.25,
			"sojourn_mean": 4.12
		}
		dock.feed_telemetry(sim_t, elems, global_kpis)

	assert(dock._series.has("q_queue_1"), "Should have ingested queue series")
	assert(dock._series.has("srv_util_server_1"), "Should have ingested server utilization series")
	assert(dock._series.has("conv_conv_1"), "Should have ingested conveyor series")
	assert(dock._series.has("sys_throughput"), "Should have ingested system throughput")
	assert(dock._series.has("sys_wip"), "Should have ingested system WIP")
	assert(dock._series["q_queue_1"].size() == 30, "Should have exactly 30 points in queue series")
	print("Step 2 PASSED: 30 telemetry frames ingested across all series.")

	print("Step 3: Triggering canvas draw pass across all tabs...")
	# Simulate viewport layout
	dock._plot_canvas.custom_minimum_size = Vector2(800, 300)
	dock._plot_canvas.size = Vector2(800, 300)

	for tab in [
		SimplotDock.PlotTab.QUEUES,
		SimplotDock.PlotTab.UTILIZATION,
		SimplotDock.PlotTab.THROUGHPUT,
		SimplotDock.PlotTab.CYCLE_TIME
	]:
		dock._switch_tab(tab)
		dock._plot_canvas.notification(CanvasItem.NOTIFICATION_DRAW)
		print(" - Tab %s draw pass executed cleanly" % tab)
	print("Step 3 PASSED: All 4 waveform tabs rendered cleanly.")

	print("Step 4: Testing freeze and unfreeze...")
	dock._toggle_freeze()
	assert(dock.is_frozen, "Dock should be frozen")
	var prev_count: int = dock._series["q_queue_1"].size()
	dock.feed_point("q_queue_1", "Q1", 20.0, 99.0, Color.WHITE)
	assert(dock._series["q_queue_1"].size() == prev_count, "Frozen dock should reject new data points")

	dock._toggle_freeze()
	assert(!dock.is_frozen, "Dock should be resumed")
	dock.feed_point("q_queue_1", "Q1", 20.0, 99.0, Color.WHITE)
	assert(dock._series["q_queue_1"].size() == prev_count + 1, "Resumed dock should accept data points")
	print("Step 4 PASSED: Freeze / resume verified.")

	print("Step 5: Testing clear_all()...")
	dock.clear_all()
	assert(dock._series.is_empty(), "Series should be empty after clear")
	print("Step 5 PASSED: Clear all verified.")

	print("==================================================================")
	print("ALL AUTHORING SIMPLOT SMOKE TESTS PASSED 100%!")
	print("==================================================================")
	dock.free()
	quit(0)
