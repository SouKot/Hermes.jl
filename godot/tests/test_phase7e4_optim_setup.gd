# tests/test_phase7e4_optim_setup.gd
# Automated headless verification for Phase 7E-4:
# Window 1 (⚡ Optimization Setup) & Compact Optimization Progress HUD.
extends SceneTree

const AuthoringShell := preload("res://scripts/authoring_shell.gd")
const ExamplesCatalog := preload("res://scripts/authoring_examples_catalog.gd")

func _initialize() -> void:
	var passed := 0
	var failed := 0

	print("\n=== Phase 7E-4: Window 1 (Optimization Setup) & Progress HUD Test ===")

	var shell := AuthoringShell.new()
	get_root().add_child(shell)
	await process_frame
	await process_frame

	# 1. Verify Toolbar Buttons & OptimSetup Instance
	if shell._btn_optimize != null and shell._btn_opt_report != null and shell._optim_setup != null:
		print("  PASS  [1] Toolbar ⚡ Optimize & 📋 Report buttons and _optim_setup exist")
		passed += 1
	else:
		print("  FAIL  [1] Missing optimization toolbar buttons or _optim_setup instance")
		failed += 1

	var opt_ui = shell._optim_setup

	# 2. Verify 4 Tabs exist in Window 1
	if opt_ui._tabs != null and opt_ui._tabs.get_tab_count() == 4:
		print("  PASS  [2] Window 1 has all 4 tabs (Model & Variables, Objective, Constraints, Algorithm)")
		passed += 1
	else:
		print("  FAIL  [2] Expected 4 tabs in Window 1")
		failed += 1

	# 3. Load Benchmark Problem 1 (ER Allocation) and verify UI population
	shell.load_example_model("opt_p1_er_allocation")
	opt_ui.open_setup()
	await process_frame

	if opt_ui.is_setup_visible() and opt_ui._lbl_class_badge.text == "[PARAMETER]" and opt_ui._vars_vbox.get_child_count() == 3:
		print("  PASS  [3] Problem 1 loaded into Window 1 with 3 integer decision variable cards")
		passed += 1
	else:
		print("  FAIL  [3] Problem 1 population mismatch: visible=%s badge=%s vars=%d" % [
			str(opt_ui.is_setup_visible()), opt_ui._lbl_class_badge.text, opt_ui._vars_vbox.get_child_count()
		])
		failed += 1

	# 4. Load Benchmark Problem 2 (VIP Policy) and Problem 3 (Conveyor Topology)
	shell.load_example_model("opt_p2_vip_dispatch")
	await process_frame
	var p2_ok: bool = (opt_ui._lbl_class_badge.text == "[POLICY]" and opt_ui._edit_primary_metric.text == "std_wait_mean")

	shell.load_example_model("opt_p3_conveyor_topology")
	await process_frame
	var p3_ok: bool = (opt_ui._lbl_class_badge.text == "[TOPOLOGY]" and opt_ui._edit_primary_metric.text == "system_sojourn_mean")

	if p2_ok and p3_ok:
		print("  PASS  [4] Problem 2 ([POLICY]) and Problem 3 ([TOPOLOGY]) populate Window 1 accurately")
		passed += 1
	else:
		print("  FAIL  [4] Problem 2/3 population failed: p2_ok=%s (%s) p3_ok=%s (%s)" % [
			str(p2_ok), opt_ui._edit_primary_metric.text, str(p3_ok), opt_ui._edit_primary_metric.text
		])
		failed += 1

	# 5. Modify Solver settings in Tab 3 and verify SceneDocument round-trip
	opt_ui._spin_top_k.value = 8
	opt_ui._spin_max_evals.value = 95
	opt_ui._sync_solver_to_doc()
	var exported_spec: Dictionary = shell.doc_store.active_document.to_dict()
	var solver_dict: Dictionary = exported_spec.get("optimization", {}).get("solver", {})
	if int(solver_dict.get("top_k", 0)) == 8 and int(solver_dict.get("max_evaluations", 0)) == 95:
		print("  PASS  [5] Editing Window 1 controls updates SceneDocument['optimization']['solver'] round-trip")
		passed += 1
	else:
		print("  FAIL  [5] Solver dict did not update: ", solver_dict)
		failed += 1

	# 6. Click [ ▶ Optimize ] and verify signal emission + Compact Progress HUD opens
	var emitted_commands: Array = []
	shell.command_requested.connect(func(msg: Dictionary):
		emitted_commands.append(msg)
	)
	opt_ui._on_optimize_clicked()
	await process_frame

	var has_run_cmd := false
	for cmd in emitted_commands:
		if str(cmd.get("action", "")) == "run_optimization":
			has_run_cmd = true
			break

	if opt_ui.is_progress_visible() and has_run_cmd:
		print("  PASS  [6] Clicking [ ▶ Optimize ] opens Compact Progress HUD and emits 'run_optimization'")
		passed += 1
	else:
		print("  FAIL  [6] Compact Progress HUD or 'run_optimization' command missing")
		failed += 1

	# 7. Feed live optim_state telemetry and verify Progress HUD & [ ✔ Apply Best ]
	var best_cand_spec: Dictionary = ExamplesCatalog.get_example_scenespec("opt_p1_er_allocation")
	best_cand_spec["scene"]["name"] = "Applied Optimal ER Layout [4, 2, 2]"

	var mock_optim_state := {
		"status": "completed",
		"iteration": 60,
		"max_iterations": 60,
		"progress_pct": 100.0,
		"elapsed_sec": 1.42,
		"feasible_count": 21,
		"best_score": 2.06,
		"best_primary": 2.06,
		"best_label": "c_triage=4, c_trauma=2, c_fasttrack=2",
		"top_k_solutions": [
			{
				"rank": 1,
				"primary_objective": 2.06,
				"decision_summary": "c_triage=4, c_trauma=2, c_fasttrack=2",
				"scenespec": best_cand_spec
			}
		]
	}

	shell.update_simulation_telemetry({"abm_state": {"optim_state": mock_optim_state}})
	await process_frame

	var hud_ok: bool = (
		absf(opt_ui._prog_bar.value - 100.0) < 0.1 and
		opt_ui._lbl_prog_status.text.contains("COMPLETED") and
		opt_ui._lbl_prog_best_config.text.contains("c_triage=4") and
		not opt_ui._btn_prog_apply.disabled
	)
	if hud_ok:
		print("  PASS  [7] Compact Progress HUD updates live from abm_state['optim_state']")
		passed += 1
	else:
		print("  FAIL  [7] Compact Progress HUD telemetry mismatch")
		failed += 1

	# 8. Click [ ✔ Apply Best ] and verify active document updates
	opt_ui._on_apply_best_from_progress()
	await process_frame

	var new_scene_name := str(shell.doc_store.active_document.scene.get("name", ""))
	if new_scene_name == "Applied Optimal ER Layout [4, 2, 2]":
		print("  PASS  [8] [ ✔ Apply Best ] loads optimal candidate SceneSpec into DocumentStore")
		passed += 1
	else:
		print("  FAIL  [8] Expected applied scene name, got: ", new_scene_name)
		failed += 1

	shell.queue_free()
	print("\n=== Phase 7E-4 Results: %d passed, %d failed ===" % [passed, failed])
	quit(failed)
