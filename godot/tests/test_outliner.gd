# tests/test_outliner.gd
# Headless smoke test for SimVizAuthoringOutliner.
extends SceneTree

const Outliner := preload("res://scripts/authoring_outliner.gd")

func _initialize() -> void:
	var passed := 0
	var failed := 0

	print("\n=== test_outliner.gd ===")

	# --- Test 1: Empty doc shows placeholder ---
	var out1 := Outliner.new()
	get_root().add_child(out1)
	# Allow _ready() to fire
	await process_frame
	out1.rebuild([])
	var tree1: Tree = out1.get_child(0) if out1.get_child_count() > 0 else null
	if tree1 == null:
		print("  FAIL  [1] Tree child not created after _ready()")
		failed += 1
	else:
		var root1 := tree1.get_root()
		if root1 != null and root1.get_text(0).contains("No document"):
			print("  PASS  [1] Empty doc shows placeholder")
			passed += 1
		else:
			print("  FAIL  [1] Expected placeholder, got: ", root1.get_text(0) if root1 != null else "null")
			failed += 1
	out1.queue_free()

	# --- Test 2: Outliner tree node created ---
	var out2 := Outliner.new()
	get_root().add_child(out2)
	await process_frame
	out2.rebuild([])  # no crash
	var tree2: Tree = out2.get_child(0) if out2.get_child_count() > 0 else null
	if tree2 != null:
		print("  PASS  [2] Outliner tree node created")
		passed += 1
	else:
		print("  FAIL  [2] Tree node missing after _ready()")
		failed += 1
	out2.queue_free()

	# --- Test 3: Feed telemetry with entity dicts - no crash ---
	var out3 := Outliner.new()
	get_root().add_child(out3)
	await process_frame
	var fake_entities: Array = [
		{"id": "ent_1", "element_id": "q1", "arrival_time": 0.5, "properties": {"in_service": false, "zone_kind": "queue"}},
		{"id": "ent_2", "element_id": "srv1", "arrival_time": 1.2, "properties": {"in_service": true, "zone_kind": "server"}}
	]
	out3.feed_telemetry({}, fake_entities)  # no crash
	print("  PASS  [3] feed_telemetry with entities: no crash")
	passed += 1
	out3.queue_free()

	print("\n=== Results: ", passed, " passed, ", failed, " failed ===")
	quit(failed)
