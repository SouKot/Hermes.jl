extends SceneTree

func _init() -> void:
	print("--- Running GDExtension SimPlot & SimPlotView Smoke Test ---")
	
	if not ClassDB.class_exists("SimPlot"):
		printerr("FAIL: ClassDB does not contain SimPlot")
		quit(1)
		return

	if not ClassDB.class_exists("SimPlotView"):
		printerr("FAIL: ClassDB does not contain SimPlotView")
		quit(1)
		return

	print("PASS: ClassDB recognized SimPlot and SimPlotView.")

	# 1. Test SimPlot RefCounted Bridge
	var plotter = ClassDB.instantiate("SimPlot")
	if plotter == null:
		printerr("FAIL: Could not instantiate SimPlot")
		quit(1)
		return
	print("PASS: Instantiated SimPlot.")

	var started = plotter.begin_plot("Queue Length vs Time", Vector2(400, 300))
	assert(started, "begin_plot should return true")
	plotter.setup_axes_limits(0.0, 100.0, 0.0, 50.0)
	
	var xs = PackedFloat32Array([0.0, 10.0, 20.0, 30.0, 40.0])
	var ys = PackedFloat32Array([0.0, 2.0, 5.0, 3.0, 1.0])
	plotter.plot_line("N_q(t)", xs, ys)
	plotter.plot_scatter("Samples", xs, ys)
	plotter.plot_bars("Discrete", ys, 0.5)
	plotter.plot_histogram("Distribution", ys, 5)
	plotter.end_plot()
	print("PASS: 2D ImPlot calls executed cleanly.")

	# Test 3D Plotting
	var started_3d = plotter.begin_plot3d("3D State Space (Queue x Server x Time)", Vector2(500, 400))
	assert(started_3d, "begin_plot3d should return true")
	var zs = PackedFloat32Array([0.1, 0.4, 0.8, 0.6, 0.2])
	plotter.plot_line3d("Trajectory", xs, ys, zs)
	plotter.plot_scatter3d("States", xs, ys, zs)
	plotter.end_plot3d()
	print("PASS: 3D ImPlot3D calls executed cleanly.")

	# Test High-Throughput Ring Buffer Telemetry
	for i in range(100):
		plotter.push_telemetry("utilization", float(i), sin(float(i) * 0.1) * 0.5 + 0.5, 500)
	var count = plotter.get_series_point_count("utilization")
	assert(count == 100, "Ring buffer should retain 100 points, got %d" % count)
	plotter.clear_series("utilization")
	assert(plotter.get_series_point_count("utilization") == 0, "Ring buffer should clear")
	print("PASS: Zero-copy RingBuffer telemetry verified.")

	# 2. Test SimPlotView Control Node
	var view = ClassDB.instantiate("SimPlotView")
	if view == null:
		printerr("FAIL: Could not instantiate SimPlotView")
		quit(1)
		return
	print("PASS: Instantiated SimPlotView Control node.")

	view.plot_title = "WIP & Server Utilization"
	view.x_label = "Sim Time (s)"
	view.y_label = "WIP / Rho"
	view.set_series_2d("WIP", xs, ys)
	view.set_bars("Utilization", ys, 0.6)
	view.set_histogram("ServiceTimeDist", ys, 10)
	view.set_series_3d("PhasePortrait", xs, ys, zs)
	view.push_point("LiveFlow", 50.0, 4.0)

	assert(view.get_plot_title() == "WIP & Server Utilization")
	assert(view.get_x_label() == "Sim Time (s)")
	assert(view.get_y_label() == "WIP / Rho")

	# Test Native Subplots API on SimPlotView
	view.set_subplots_grid(2, 2)
	assert(view.get_subplot_rows() == 2, "Subplot rows must be 2")
	assert(view.get_subplot_cols() == 2, "Subplot cols must be 2")
	view.configure_subplot(0, "Queue Length", "items", true, 0.0, 50.0, "time_series")
	view.set_subplot_series_2d(0, "Q1", xs, ys)
	view.configure_subplot(1, "Server Utilization", "%", true, 0.0, 100.0, "digital_gauge")
	view.set_subplot_series_2d(1, "Util", xs, ys)
	assert(view.get_subplot_count() >= 2, "Must have at least 2 subplots")
	print("PASS: Native subplots API on SimPlotView verified.")

	view.clear_all()
	print("PASS: SimPlotView configuration and data feed verified.")

	print("\n>>> ALL SIMPLOT & SIMPLOT3D GDEXTENSION TESTS PASSED SUCCESSFULLY! <<<\n")
	quit(0)

