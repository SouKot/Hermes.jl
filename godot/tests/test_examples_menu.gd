extends SceneTree

const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const ExamplesCatalog := preload("res://scripts/authoring_examples_catalog.gd")
const AuthoringShell := preload("res://scripts/authoring_shell.gd")

func _init() -> void:
	var passed := 0
	var failed := 0
	print("\n=== test_examples_menu.gd (Sub-Phase 7E-1) ===")

	var ex_list: Array = ExamplesCatalog.list_examples()
	if ex_list.size() == 7:
		print("  PASS  [1] ExamplesCatalog has 7 examples")
		passed += 1
	else:
		print("  FAIL  [1] Expected 7 examples, got ", ex_list.size())
		failed += 1

	var store := DocumentStore.new()
	for item in ex_list:
		var eid: String = str(item.get("id", ""))
		var cat: String = str(item.get("category", ""))
		var spec: Dictionary = ExamplesCatalog.get_example_scenespec(eid)
		var ok: bool = store.load_from_dictionary(spec)
		if ok and store.is_document_valid:
			print("  PASS  [load+validate] ", eid)
			passed += 1
		else:
			print("  FAIL  [load+validate] ", eid, " ok=", ok, " valid=", store.is_document_valid, " diags=", store.last_diagnostics)
			failed += 1

		if cat == "optimization":
			var opt: Dictionary = store.get_optimization_spec()
			var exported: Dictionary = store.export_to_dictionary()
			if not opt.is_empty() and exported.has("optimization"):
				print("  PASS  [optimization preserved] ", eid, " vars=", opt.get("decision_variables", []).size())
				passed += 1
			else:
				print("  FAIL  [optimization preserved] ", eid)
				failed += 1

	var shell := AuthoringShell.new()
	root.add_child(shell)
	var header := shell._build_header()
	shell.add_child(header)
	var emitted_cmds: Array = []
	shell.command_requested.connect(func(msg: Dictionary): emitted_cmds.append(msg))
	var loaded_ok: bool = shell.load_example_model("opt_p1_er_allocation")
	var has_menu: bool = shell._examples_menu != null and shell._examples_menu.get_popup().item_count >= 3
	if loaded_ok and has_menu and emitted_cmds.size() == 1 and str(emitted_cmds[0].get("example_id", "")) == "opt_p1_er_allocation":
		print("  PASS  [shell.load_example_model] loaded opt_p1_er_allocation, built Examples menu, and emitted command")
		passed += 1
	else:
		print("  FAIL  [shell.load_example_model] loaded_ok=", loaded_ok, " has_menu=", has_menu, " cmds_count=", emitted_cmds.size())
		failed += 1

	shell.queue_free()
	print("\n=== Results: ", passed, " passed, ", failed, " failed ===")
	quit(failed)
