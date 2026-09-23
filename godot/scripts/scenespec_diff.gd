# scenespec_diff.gd
# Semantic Scene Comparison Engine for Antigravity SimViz SceneSpecs.
class_name SimVizSceneDiff
extends RefCounted

static func diff_documents(base_doc: Variant, target_doc: Variant) -> Dictionary:
	var base_dict: Dictionary = _to_dict(base_doc)
	var target_dict: Dictionary = _to_dict(target_doc)

	var diff_res := {
		"elements": {
			"added": [],
			"removed": [],
			"modified": []
		},
		"connections": {
			"added": [],
			"removed": [],
			"modified": []
		},
		"subgraphs": {
			"added": [],
			"removed": [],
			"modified": []
		},
		"spatial": [],
		"simulation": [],
		"has_changes": false,
		"added_count": 0,
		"removed_count": 0,
		"modified_count": 0,
		"summary": "",
		"detailed_report": ""
	}

	# 1. Elements Diff
	var base_elems: Dictionary = _index_by_id(base_dict.get("elements", []))
	var target_elems: Dictionary = _index_by_id(target_dict.get("elements", []))

	for id in target_elems.keys():
		if not base_elems.has(id):
			var elem: Dictionary = target_elems[id]
			diff_res.elements.added.append({
				"id": id,
				"name": elem.get("name", id),
				"type_name": elem.get("type_name", "Element")
			})
		else:
			var changes: Array[String] = _compare_elements(base_elems[id], target_elems[id])
			if not changes.is_empty():
				var elem: Dictionary = target_elems[id]
				diff_res.elements.modified.append({
					"id": id,
					"name": elem.get("name", id),
					"type_name": elem.get("type_name", "Element"),
					"changes": changes
				})

	for id in base_elems.keys():
		if not target_elems.has(id):
			var elem: Dictionary = base_elems[id]
			diff_res.elements.removed.append({
				"id": id,
				"name": elem.get("name", id),
				"type_name": elem.get("type_name", "Element")
			})

	# 2. Connections Diff
	var base_conns: Dictionary = _index_by_id(base_dict.get("connections", []))
	var target_conns: Dictionary = _index_by_id(target_dict.get("connections", []))

	for id in target_conns.keys():
		if not base_conns.has(id):
			var conn: Dictionary = target_conns[id]
			diff_res.connections.added.append({
				"id": id,
				"source": "%s:%s" % [conn.get("source_element", ""), conn.get("source_port", "")],
				"target": "%s:%s" % [conn.get("target_element", ""), conn.get("target_port", "")]
			})
		else:
			var changes: Array[String] = _compare_connections(base_conns[id], target_conns[id])
			if not changes.is_empty():
				var conn: Dictionary = target_conns[id]
				diff_res.connections.modified.append({
					"id": id,
					"source": "%s:%s" % [conn.get("source_element", ""), conn.get("source_port", "")],
					"target": "%s:%s" % [conn.get("target_element", ""), conn.get("target_port", "")],
					"changes": changes
				})

	for id in base_conns.keys():
		if not target_conns.has(id):
			var conn: Dictionary = base_conns[id]
			diff_res.connections.removed.append({
				"id": id,
				"source": "%s:%s" % [conn.get("source_element", ""), conn.get("source_port", "")],
				"target": "%s:%s" % [conn.get("target_element", ""), conn.get("target_port", "")]
			})

	# 3. Subgraphs Diff
	var base_subs: Dictionary = _index_by_id(base_dict.get("subgraphs", []))
	var target_subs: Dictionary = _index_by_id(target_dict.get("subgraphs", []))

	for id in target_subs.keys():
		if not base_subs.has(id):
			var sub: Dictionary = target_subs[id]
			diff_res.subgraphs.added.append({
				"id": id,
				"name": sub.get("name", id)
			})
		else:
			var changes: Array[String] = _compare_subgraphs(base_subs[id], target_subs[id])
			if not changes.is_empty():
				var sub: Dictionary = target_subs[id]
				diff_res.subgraphs.modified.append({
					"id": id,
					"name": sub.get("name", id),
					"changes": changes
				})

	for id in base_subs.keys():
		if not target_subs.has(id):
			var sub: Dictionary = base_subs[id]
			diff_res.subgraphs.removed.append({
				"id": id,
				"name": sub.get("name", id)
			})

	# 4. Spatial & Simulation Diff
	diff_res.spatial = _compare_dictionaries(base_dict.get("spatial", {}), target_dict.get("spatial", {}), "spatial")
	diff_res.simulation = _compare_dictionaries(base_dict.get("simulation", {}), target_dict.get("simulation", {}), "simulation")

	# Aggregates
	diff_res.added_count = diff_res.elements.added.size() + diff_res.connections.added.size() + diff_res.subgraphs.added.size()
	diff_res.removed_count = diff_res.elements.removed.size() + diff_res.connections.removed.size() + diff_res.subgraphs.removed.size()
	diff_res.modified_count = diff_res.elements.modified.size() + diff_res.connections.modified.size() + diff_res.subgraphs.modified.size() + diff_res.spatial.size() + diff_res.simulation.size()

	diff_res.has_changes = (diff_res.added_count > 0 or diff_res.removed_count > 0 or diff_res.modified_count > 0)

	# Format human-readable summary
	var summary_parts: Array[String] = []
	if diff_res.added_count > 0:
		summary_parts.append("+%d added" % diff_res.added_count)
	if diff_res.removed_count > 0:
		summary_parts.append("-%d removed" % diff_res.removed_count)
	if diff_res.modified_count > 0:
		summary_parts.append("~%d modified" % diff_res.modified_count)

	if summary_parts.is_empty():
		diff_res.summary = "No differences found (identical)"
	else:
		diff_res.summary = ", ".join(summary_parts)

	# Build detailed report
	var lines: Array[String] = []
	lines.append("=== SceneSpec Semantic Diff: %s ===" % diff_res.summary)
	if not diff_res.elements.added.is_empty():
		lines.append("Added Elements (%d):" % diff_res.elements.added.size())
		for e in diff_res.elements.added:
			lines.append("  + [%s] %s (%s)" % [e.id, e.name, e.type_name])
	if not diff_res.elements.removed.is_empty():
		lines.append("Removed Elements (%d):" % diff_res.elements.removed.size())
		for e in diff_res.elements.removed:
			lines.append("  - [%s] %s (%s)" % [e.id, e.name, e.type_name])
	if not diff_res.elements.modified.is_empty():
		lines.append("Modified Elements (%d):" % diff_res.elements.modified.size())
		for e in diff_res.elements.modified:
			lines.append("  ~ [%s] %s: %s" % [e.id, e.name, "; ".join(e.changes)])

	if not diff_res.connections.added.is_empty():
		lines.append("Added Connections (%d):" % diff_res.connections.added.size())
		for c in diff_res.connections.added:
			lines.append("  + [%s] %s -> %s" % [c.id, c.source, c.target])
	if not diff_res.connections.removed.is_empty():
		lines.append("Removed Connections (%d):" % diff_res.connections.removed.size())
		for c in diff_res.connections.removed:
			lines.append("  - [%s] %s -> %s" % [c.id, c.source, c.target])

	if not diff_res.subgraphs.added.is_empty():
		lines.append("Added Subgraphs (%d):" % diff_res.subgraphs.added.size())
		for s in diff_res.subgraphs.added:
			lines.append("  + [Subgraph %s] %s" % [s.id, s.name])
	if not diff_res.subgraphs.removed.is_empty():
		lines.append("Removed Subgraphs (%d):" % diff_res.subgraphs.removed.size())
		for s in diff_res.subgraphs.removed:
			lines.append("  - [Subgraph %s] %s" % [s.id, s.name])

	diff_res.detailed_report = "\n".join(lines)
	return diff_res

static func _to_dict(obj: Variant) -> Dictionary:
	if obj == null:
		return {}
	if obj is Dictionary:
		return obj
	if obj.has_method("to_dict"):
		return obj.to_dict()
	return {}

static func _index_by_id(arr: Array) -> Dictionary:
	var map := {}
	for item in arr:
		if item is Dictionary and item.has("id"):
			map[str(item["id"])] = item
		elif item != null and item.get("id") != null:
			if item.has_method("to_dict"):
				map[str(item.get("id"))] = item.to_dict()
			else:
				map[str(item.get("id"))] = item
	return map

static func _compare_elements(base_elem: Dictionary, target_elem: Dictionary) -> Array[String]:
	var changes: Array[String] = []
	if str(base_elem.get("name", "")) != str(target_elem.get("name", "")):
		changes.append("name: '%s' -> '%s'" % [str(base_elem.get("name")), str(target_elem.get("name"))])
	if str(base_elem.get("type_name", "")) != str(target_elem.get("type_name", "")):
		changes.append("type: '%s' -> '%s'" % [str(base_elem.get("type_name")), str(target_elem.get("type_name"))])
	if str(base_elem.get("level_id", "")) != str(target_elem.get("level_id", "")):
		changes.append("level: '%s' -> '%s'" % [str(base_elem.get("level_id")), str(target_elem.get("level_id"))])

	# Transform comparison
	var bt: Dictionary = base_elem.get("transform", {})
	var tt: Dictionary = target_elem.get("transform", {})
	if not _is_approx_vector(bt.get("position", []), tt.get("position", [])):
		changes.append("position changed")
	if not _is_approx_vector(bt.get("rotation", bt.get("rotation_deg", [])), tt.get("rotation", tt.get("rotation_deg", []))):
		changes.append("rotation changed")
	if not _is_approx_vector(bt.get("scale", []), tt.get("scale", [])):
		changes.append("scale changed")

	# Process parameters comparison
	var bp: Dictionary = base_elem.get("process", {})
	var tp: Dictionary = target_elem.get("process", {})
	for k in tp.keys():
		if not bp.has(k) or str(bp[k]) != str(tp[k]):
			changes.append("process.%s: %s -> %s" % [k, str(bp.get(k, "null")), str(tp[k])])
	for k in bp.keys():
		if not tp.has(k):
			changes.append("process.%s removed" % k)

	return changes

static func _compare_connections(base_conn: Dictionary, target_conn: Dictionary) -> Array[String]:
	var changes: Array[String] = []
	if str(base_conn.get("source_element", "")) != str(target_conn.get("source_element", "")) or \
	   str(base_conn.get("source_port", "")) != str(target_conn.get("source_port", "")):
		changes.append("source endpoint changed")
	if str(base_conn.get("target_element", "")) != str(target_conn.get("target_element", "")) or \
	   str(base_conn.get("target_port", "")) != str(target_conn.get("target_port", "")):
		changes.append("target endpoint changed")
	if bool(base_conn.get("enabled", true)) != bool(target_conn.get("enabled", true)):
		changes.append("enabled state toggled")
	return changes

static func _compare_subgraphs(base_sub: Dictionary, target_sub: Dictionary) -> Array[String]:
	var changes: Array[String] = []
	if str(base_sub.get("name", "")) != str(target_sub.get("name", "")):
		changes.append("name: '%s' -> '%s'" % [str(base_sub.get("name")), str(target_sub.get("name"))])
	var b_elems = base_sub.get("elements", base_sub.get("internal_elements", []))
	var t_elems = target_sub.get("elements", target_sub.get("internal_elements", []))
	if b_elems.size() != t_elems.size():
		changes.append("internal elements count %d -> %d" % [b_elems.size(), t_elems.size()])
	return changes

static func _compare_dictionaries(a: Dictionary, b: Dictionary, prefix: String) -> Array[String]:
	var changes: Array[String] = []
	for k in b.keys():
		if not a.has(k):
			changes.append("%s.%s added" % [prefix, k])
		elif str(a[k]) != str(b[k]):
			changes.append("%s.%s modified" % [prefix, k])
	for k in a.keys():
		if not b.has(k):
			changes.append("%s.%s removed" % [prefix, k])
	return changes

static func _is_approx_vector(a: Array, b: Array, tol: float = 0.001) -> bool:
	if a.size() < 3 or b.size() < 3:
		return a == b
	for i in range(3):
		if abs(float(a[i]) - float(b[i])) > tol:
			return false
	return true

