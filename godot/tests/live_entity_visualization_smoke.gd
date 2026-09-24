extends SceneTree

const MainScene := preload("res://scripts/main.gd")

var main_node
var success := false

func _init() -> void:
	print("Starting Live Entity Visualization & Startup State Verification...")
	main_node = MainScene.new()
	get_root().add_child(main_node)

	create_timer(12.0).timeout.connect(func():
		if success:
			print("Live Entity Visualization Test PASSED 100%!")
			quit(0)
		else:
			push_error("Timeout waiting for live entity stream")
			quit(1)
	)

	# Wait 2 seconds for initial connection and paused state verification
	create_timer(2.0).timeout.connect(_verify_initial_paused_state)

func _verify_initial_paused_state() -> void:
	print("Step 1: Checking initial startup state (MUST BE PAUSED)...")
	var is_running: bool = main_node.running
	var sim_time: float = main_node.simulation_time
	print(" - main.running = ", is_running)
	print(" - main.simulation_time = ", sim_time)

	if is_running:
		push_error("FAIL: Simulation autostarted on startup! Expected running=false.")
		quit(1)
		return
	print("Step 1 PASSED: Simulation cleanly starts in PAUSED state at t = 0.00.")

	# Step 2: Build tandem model in doc_store
	print("Step 2: Building tandem model in authoring shell doc_store...")
	var doc_store = main_node.authoring_shell.doc_store
	if doc_store == null:
		push_error("FAIL: doc_store is null")
		quit(1)
		return

	# Add Source, Queue, Server, Conveyor, Sink
	var catalog = main_node.authoring_shell.catalog
	var src = catalog.create_element_instance("source", "src_vis", Vector2(5.0, 5.0))
	var q = catalog.create_element_instance("queue", "q_vis", Vector2(10.0, 5.0))
	var srv = catalog.create_element_instance("server", "srv_vis", Vector2(15.0, 5.0))
	var conv = catalog.create_element_instance("conveyor", "conv_vis", Vector2(20.0, 5.0))
	var snk = catalog.create_element_instance("sink", "snk_vis", Vector2(28.0, 5.0))

	doc_store.add_element(src)
	doc_store.add_element(q)
	doc_store.add_element(srv)
	doc_store.add_element(conv)
	doc_store.add_element(snk)

	doc_store.add_connection_direct("c1", "src_vis", "flow_out", "q_vis", "flow_in")
	doc_store.add_connection_direct("c2", "q_vis", "flow_out", "srv_vis", "flow_in")
	doc_store.add_connection_direct("c3", "srv_vis", "flow_out", "conv_vis", "flow_in")
	doc_store.add_connection_direct("c4", "conv_vis", "flow_out", "snk_vis", "flow_in")

	print("Step 2 PASSED: 5 elements and 4 connections staged.")

	# Step 3: Trigger Play
	print("Step 3: Triggering ▶ PLAY...")
	main_node._on_play()

	# Poll for entity streaming
	var check_timer := create_timer(1.0)
	check_timer.timeout.connect(_check_entities_streaming)

var poll_count := 0
func _check_entities_streaming() -> void:
	poll_count += 1
	var c2d = main_node.authoring_shell._canvas_2d
	var v3d = main_node.authoring_shell._viewport_3d

	var c2d_count = c2d._active_agents.size() if c2d != null else 0
	var v3d_count = v3d._active_agents.size() if v3d != null else 0
	var sim_t = main_node.simulation_time

	print("Poll #%d: sim_t=%.2f 2D_agents=%d 3D_agents=%d" % [poll_count, sim_t, c2d_count, v3d_count])

	if c2d_count > 0 and v3d_count > 0 and sim_t > 0.5:
		# Verify agent positions and smoothed coordinates are active and non-zero
		var first_a: Dictionary = c2d._active_agents[0]
		var px = float(first_a.get("x", 0.0))
		var py = float(first_a.get("y", 0.0))
		var aid: String = str(first_a.get("id", ""))
		var smooth_pos: Vector2 = c2d._agent_smoothed_positions.get(aid, Vector2.ZERO)
		var t3d: Transform3D = v3d.get_agent_transform_3d(0)
		print(" - Agent sample: id=%s x=%.2f y=%.2f smooth=(%.2f, %.2f) 3d_origin=(%.2f, %.2f, %.2f)" % [
			aid, px, py, smooth_pos.x, smooth_pos.y, t3d.origin.x, t3d.origin.y, t3d.origin.z
		])
		if px > 0.0 and py > 0.0 and smooth_pos != Vector2.ZERO and t3d.origin != Vector3.ZERO:
			print("Step 4 PASSED: Entities streaming cleanly with continuous 2D smoothing and 3D multimesh transforms!")
			success = true
			quit(0)
			return

	if poll_count < 8:
		create_timer(0.5).timeout.connect(_check_entities_streaming)
	else:
		push_error("FAIL: No entities received after 8 polls")
		quit(1)
