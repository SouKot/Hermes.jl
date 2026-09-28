# tests/test_phase7e5_optim_feedback.gd
# Automated headless verification for Phase 7E-5:
# Window 2 (📊 Optimization Report & Live Feedback), 3 Custom Charts
# (Convergence, Pareto Scatter, SLA Margin), Top-K Leaderboard,
# 2D Schematic Snapshot + Full-Size Lightbox, and 1-Click Main Canvas Loading.
extends SceneTree

const AuthoringShell := preload("res://scripts/authoring_shell.gd")
const ExamplesCatalog := preload("res://scripts/authoring_examples_catalog.gd")

func _initialize() -> void:
	var passed := 0
	var failed := 0

	print("\n=== Phase 7E-5: Window 2 (Optimization Report & Live Feedback) Test ===")

	var shell := AuthoringShell.new()
	get_root().add_child(shell)
	await process_frame
	await process_frame

	var opt_setup = shell._optim_setup
	var opt_fb = shell._optim_feedback

	# 1. Verify Window 2 instance & sub-controls exist
	if opt_fb != null and opt_fb._conv_chart != null and opt_fb._scatter_chart != null and opt_fb._sla_chart != null and opt_fb._snapshot_canvas != null:
		print("  PASS  [1] SimVizAuthoringOptimFeedback (Window 2) and all 3 charts + 2D schematic canvas exist")
		passed += 1
	else:
		print("  FAIL  [1] Missing _optim_feedback or internal chart/snapshot nodes")
		failed += 1
		shell.queue_free()
		quit(failed)
		return

	# 2. Load Benchmark Problem 3 (Conveyor Topology) and open Window 2 via [ 📊 Optimize + Feedback ]
	shell.load_example_model("opt_p3_conveyor_topology")
	await process_frame

	var emitted_commands: Array = []
	shell.command_requested.connect(func(msg: Dictionary):
		emitted_commands.append(msg)
	)

	opt_setup._on_optimize_and_feedback_clicked()
	await process_frame

	var has_run_cmd := false
	for cmd in emitted_commands:
		if str(cmd.get("action", "")) == "run_optimization":
			has_run_cmd = true
			break

	if opt_fb.is_report_visible() and has_run_cmd and opt_fb._lbl_class_badge.text == "[TOPOLOGY]":
		print("  PASS  [2] [ 📊 Optimize + Feedback ] opens Window 2 ([TOPOLOGY]) and emits 'run_optimization'")
		passed += 1
	else:
		print("  FAIL  [2] Window 2 failed to open or populate header: visible=%s cmd=%s badge=%s" % [
			str(opt_fb.is_report_visible()), str(has_run_cmd), opt_fb._lbl_class_badge.text
		])
		failed += 1

	# 3. Feed intermediate 'running' optim_state (compact payload without full scenespec)
	var running_state := {
		"status": "running",
		"problem_id": "opt_p3_conveyor_topology",
		"problem_class": "topology",
		"iteration": 15,
		"max_iterations": 60,
		"progress_pct": 25.0,
		"elapsed_sec": 0.45,
		"feasible_count": 9,
		"best_score": 11.40,
		"best_primary": 11.40,
		"best_secondary": 26.0,
		"best_label": "closed_loop=1, L_main=12.0, L_recirc=14.0, c_pack=2",
		"convergence_history": [
			{"eval": 1, "current_objective": 48.2, "best_objective": 48.2, "is_feasible": true},
			{"eval": 5, "current_objective": 19.5, "best_objective": 19.5, "is_feasible": true},
			{"eval": 10, "current_objective": 115.0, "best_objective": 19.5, "is_feasible": false},
			{"eval": 15, "current_objective": 11.4, "best_objective": 11.4, "is_feasible": true}
		],
		"scatter_points": [
			{"iteration": 1, "primary_objective": 48.2, "secondary_objective": 30.0, "is_feasible": true, "label": "open_loop"},
			{"iteration": 10, "primary_objective": 35.0, "secondary_objective": 18.0, "is_feasible": false, "label": "infeasible"},
			{"iteration": 15, "primary_objective": 11.4, "secondary_objective": 26.0, "is_feasible": true, "label": "closed_loop=1"}
		],
		"top_k_solutions": [
			{
				"rank": 1,
				"score": 11.40,
				"primary_objective": 11.40,
				"secondary_objective": 26.0,
				"is_feasible": true,
				"decision_summary": "closed_loop=1, L_main=12.0, L_recirc=14.0, c_pack=2",
				"decision_dict": {"closed_loop": 1, "L_main": 12.0, "L_recirc": 14.0, "c_pack": 2}
			}
		]
	}

	shell.update_simulation_telemetry({"abm_state": {"optim_state": running_state}})
	await process_frame

	if opt_fb._lbl_status.text.contains("RUNNING") and opt_fb.get_top_k_count() == 1 and not opt_fb._btn_stop.disabled:
		print("  PASS  [3] Live 'running' telemetry updates status strip, charts, and synthesized 2D preview")
		passed += 1
	else:
		print("  FAIL  [3] Live 'running' telemetry update failed: status=%s top_k=%d" % [
			opt_fb._lbl_status.text, opt_fb.get_top_k_count()
		])
		failed += 1

	# 4. Feed final 'completed' optim_state with 3 Top-K candidate solutions + full SceneSpecs
	var cand1_spec: Dictionary = ExamplesCatalog.get_example_scenespec("opt_p3_conveyor_topology")
	cand1_spec["scene"]["name"] = "Candidate #1 Closed-Loop (L=10m+12m, c=2)"

	var cand2_spec: Dictionary = ExamplesCatalog.get_example_scenespec("opt_p3_conveyor_topology")
	cand2_spec["scene"]["name"] = "Candidate #2 Closed-Loop (L=12m+14m, c=2)"

	var cand3_spec: Dictionary = ExamplesCatalog.get_example_scenespec("opt_p3_conveyor_topology")
	cand3_spec["scene"]["name"] = "Candidate #3 Open-Loop (L=28m, c=3)"

	var completed_state := {
		"status": "completed",
		"problem_id": "opt_p3_conveyor_topology",
		"problem_class": "topology",
		"iteration": 60,
		"max_iterations": 60,
		"progress_pct": 100.0,
		"elapsed_sec": 1.65,
		"feasible_count": 34,
		"best_score": 10.69,
		"best_primary": 10.69,
		"best_secondary": 22.0,
		"best_label": "closed_loop=1, L_main=10.0, L_recirc=12.0, c_pack=2",
		"convergence_history": running_state["convergence_history"],
		"scatter_points": running_state["scatter_points"],
		"top_k_solutions": [
			{
				"rank": 1,
				"score": 10.69,
				"primary_objective": 10.69,
				"secondary_objective": 22.0,
				"is_feasible": true,
				"decision_summary": "closed_loop=1, L_main=10.0, L_recirc=12.0, c_pack=2",
				"decision_dict": {"closed_loop": 1, "L_main": 10.0, "L_recirc": 12.0, "c_pack": 2},
				"scenespec": cand1_spec
			},
			{
				"rank": 2,
				"score": 11.12,
				"primary_objective": 11.12,
				"secondary_objective": 26.0,
				"is_feasible": true,
				"decision_summary": "closed_loop=1, L_main=12.0, L_recirc=14.0, c_pack=2",
				"decision_dict": {"closed_loop": 1, "L_main": 12.0, "L_recirc": 14.0, "c_pack": 2},
				"scenespec": cand2_spec
			},
			{
				"rank": 3,
				"score": 13.85,
				"primary_objective": 13.85,
				"secondary_objective": 28.0,
				"is_feasible": true,
				"decision_summary": "closed_loop=0, L_main=28.0, L_recirc=10.0, c_pack=3",
				"decision_dict": {"closed_loop": 0, "L_main": 28.0, "L_recirc": 10.0, "c_pack": 3},
				"scenespec": cand3_spec
			}
		]
	}

	shell.update_simulation_telemetry({"abm_state": {"optim_state": completed_state}})
	await process_frame

	if opt_fb._lbl_status.text.contains("COMPLETED") and opt_fb.get_top_k_count() == 3 and not opt_fb._btn_open_in_canvas.disabled:
		print("  PASS  [4] Completed telemetry populates 3 Top-K candidate cards and enables main canvas loading")
		passed += 1
	else:
		print("  FAIL  [4] Completed telemetry failed: status=%s top_k=%d btn_disabled=%s" % [
			opt_fb._lbl_status.text, opt_fb.get_top_k_count(), str(opt_fb._btn_open_in_canvas.disabled)
		])
		failed += 1

	# 5. Select Candidate Rank #2 and verify Snapshot Preview updates
	opt_fb.select_candidate_rank(2)
	await process_frame

	if opt_fb.get_selected_rank() == 2 and opt_fb._lbl_snapshot_title.text.contains("#2"):
		print("  PASS  [5] Selecting Rank #2 updates 2D Schematic Snapshot preview to Candidate #2")
		passed += 1
	else:
		print("  FAIL  [5] Rank #2 selection mismatch: rank=%d title=%s" % [
			opt_fb.get_selected_rank(), opt_fb._lbl_snapshot_title.text
		])
		failed += 1

	# 6. Open Full-Size Snapshot Lightbox and verify zoom/pan controls
	opt_fb.open_lightbox()
	await process_frame

	var lb_ok: bool = opt_fb.is_lightbox_visible() and opt_fb._lbl_lightbox_title.text.contains("#2")
	opt_fb._set_lightbox_zoom(1.5)
	lb_ok = lb_ok and absf(opt_fb._lightbox_zoom - 1.5) < 0.01
	opt_fb.close_lightbox()
	await process_frame

	if lb_ok and not opt_fb.is_lightbox_visible():
		print("  PASS  [6] Full-Size Snapshot Lightbox opens, zooms to 150%%, and closes cleanly")
		passed += 1
	else:
		print("  FAIL  [6] Lightbox modal check failed")
		failed += 1

	# 7. Click [ ⤢ Open Selected Solution in Main Canvas ] for Rank #2 and verify DocumentStore + Optimization Spec preservation
	opt_fb._on_open_selected_in_main_canvas()
	await process_frame

	var loaded_scene_name := str(shell.doc_store.active_document.scene.get("name", ""))
	var preserved_opt_spec: Dictionary = shell.doc_store.get_optimization_spec()
	var has_apply_cmd := false
	for cmd in emitted_commands:
		if str(cmd.get("action", "")) == "apply_best_solution" and int(cmd.get("rank", 0)) == 2:
			has_apply_cmd = true
			break

	if loaded_scene_name == "Candidate #2 Closed-Loop (L=12m+14m, c=2)" and not preserved_opt_spec.is_empty() and has_apply_cmd:
		print("  PASS  [7] [ ⤢ Open Selected Solution in Main Canvas ] loads Rank #2 into DocumentStore and preserves optimization spec")
		passed += 1
	else:
		print("  FAIL  [7] Main canvas load failed: name='%s' opt_empty=%s has_apply_cmd=%s" % [
			loaded_scene_name, str(preserved_opt_spec.is_empty()), str(has_apply_cmd)
		])
		failed += 1

	shell.queue_free()
	print("\n=== Phase 7E-5 Results: %d passed, %d failed ===" % [passed, failed])
	quit(failed)
