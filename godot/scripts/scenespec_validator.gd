class_name SimVizSceneValidator
extends RefCounted

const SCENE_TYPES = preload("res://scripts/scenespec_types.gd")

const VALID_KIND_PAIRS := [
	["flow", "flow"],
	["metric", "signal"],
	["metric", "control"],
	["signal", "signal"],
	["signal", "control"],
	["event", "event"],
	["event", "control"],
	["control", "control"]
]

const KNOWN_ABM_MODELS := ["SFM", "ORCA", "HybridFSM", "SocialForce", "RuleBased"]

static func _prop(target: Variant, prop: String, default_val: Variant = null) -> Variant:
	if target == null:
		return default_val
	if target is Dictionary:
		return target.get(prop, default_val)
	if target is Object:
		var val = target.get(prop)
		if val == null:
			return default_val
		return val
	return default_val

func validate_document(doc: RefCounted, strict: bool = false, check_required: Variant = null) -> Dictionary:
	var do_check_req: bool = strict if check_required == null else bool(check_required)
	var diagnostics: Array = []
	var elems_by_id: Dictionary = {}
	var levels_by_id: Dictionary = {}

	# 1. ID Uniqueness & Indexing
	_validate_id_uniqueness(doc, diagnostics, elems_by_id, levels_by_id)

	# 2. Spatial Constraints
	_validate_spatial_constraints(doc, diagnostics, elems_by_id, levels_by_id)

	# 3. Connection & Port Rules
	_validate_connections_and_ports(doc, diagnostics, elems_by_id, do_check_req)

	# 4. Graph Topology & Cycle / Livelock Detection
	_validate_graph_topology(doc, diagnostics, elems_by_id)

	# 5. ABM Config Rules
	_validate_abm_config(doc, diagnostics)

	# 6. Extension Governance Rules
	_validate_extensions(doc, diagnostics)

	var error_count := 0
	for d in diagnostics:
		if d.get("severity", "") == "error":
			error_count += 1
	var is_valid := (error_count == 0)

	var timestamp := Time.get_datetime_string_from_system(true) + "Z"

	var val_meta: Dictionary = {
		"is_valid": is_valid,
		"diagnostic_count": diagnostics.size(),
		"last_validated_at": timestamp,
		"validator_version": "1.0.0",
		"diagnostics": diagnostics
	}

	doc.set("validation_metadata", val_meta.duplicate(true))
	return val_meta

func is_scene_valid(doc: RefCounted) -> bool:
	var res := validate_document(doc)
	return bool(res.get("is_valid", false))

# ─────────────────────────────────────────────────────────────────────────────
# 1. ID Uniqueness
# ─────────────────────────────────────────────────────────────────────────────

func _validate_id_uniqueness(doc: RefCounted, diagnostics: Array, elems_by_id: Dictionary, levels_by_id: Dictionary) -> void:
	var seen_elem_ids := {}
	var elems_val = _prop(doc, "elements", [])
	var elems: Array = elems_val if elems_val is Array else []
	for elem in elems:
		var eid: String = str(_prop(elem, "id", ""))
		if seen_elem_ids.has(eid):
			diagnostics.append({
				"rule_id": "ID_001_DUPLICATE",
				"severity": "error",
				"object_kind": "element",
				"object_id": eid,
				"property_path": "id",
				"message": "Duplicate element ID '%s' found in document" % eid,
				"suggested_fix": "Assign a unique identifier to the element"
			})
		else:
			seen_elem_ids[eid] = true
			elems_by_id[eid] = elem

		# Check ports on element
		var seen_port_ids := {}
		var all_ports: Array = []
		var in_ports = _prop(elem, "input_ports", [])
		if in_ports is Array:
			all_ports.append_array(in_ports)
		var out_ports = _prop(elem, "output_ports", [])
		if out_ports is Array:
			all_ports.append_array(out_ports)
		var met_ports = _prop(elem, "metric_ports", [])
		if met_ports is Array:
			all_ports.append_array(met_ports)

		for p in all_ports:
			var pid: String = str(_prop(p, "id", ""))
			if seen_port_ids.has(pid):
				diagnostics.append({
					"rule_id": "ID_001_DUPLICATE",
					"severity": "error",
					"object_kind": "port",
					"object_id": pid,
					"property_path": "id",
					"message": "Duplicate port ID '%s' found on element '%s'" % [pid, eid],
					"suggested_fix": "Assign a unique identifier to the port on this element"
				})
			else:
				seen_port_ids[pid] = true

	# Check connections
	var seen_conn_ids := {}
	var conns_val = _prop(doc, "connections", [])
	var conns: Array = conns_val if conns_val is Array else []
	for conn in conns:
		var cid: String = str(_prop(conn, "id", ""))
		if seen_conn_ids.has(cid):
			diagnostics.append({
				"rule_id": "ID_001_DUPLICATE",
				"severity": "error",
				"object_kind": "connection",
				"object_id": cid,
				"property_path": "id",
				"message": "Duplicate connection ID '%s' found in document" % cid,
				"suggested_fix": "Assign a unique identifier to the connection"
			})
		else:
			seen_conn_ids[cid] = true

	# Check levels
	var spatial = _prop(doc, "spatial", {})
	var levels_val = _prop(spatial, "levels", [])
	var levels: Array = levels_val if levels_val is Array else []
	var seen_level_ids := {}
	for lvl in levels:
		var lid: String = str(_prop(lvl, "id", ""))
		if seen_level_ids.has(lid):
			diagnostics.append({
				"rule_id": "ID_001_DUPLICATE",
				"severity": "error",
				"object_kind": "level",
				"object_id": lid,
				"property_path": "id",
				"message": "Duplicate spatial level ID '%s' found in spatial configuration" % lid,
				"suggested_fix": "Assign a unique identifier to the spatial level"
			})
		else:
			seen_level_ids[lid] = true
			levels_by_id[lid] = lvl

# ─────────────────────────────────────────────────────────────────────────────
# 2. Spatial Level Constraints
# ─────────────────────────────────────────────────────────────────────────────

func _validate_spatial_constraints(doc: RefCounted, diagnostics: Array, elems_by_id: Dictionary, levels_by_id: Dictionary) -> void:
	if levels_by_id.is_empty():
		return

	var avail_levels_list: Array = levels_by_id.keys()
	avail_levels_list.sort()
	var avail_str := ", ".join(avail_levels_list)

	var elems_val = _prop(doc, "elements", [])
	var elems: Array = elems_val if elems_val is Array else []
	for elem in elems:
		var eid: String = str(_prop(elem, "id", ""))
		var lid: String = str(_prop(elem, "level_id", ""))
		if not lid.is_empty() and not levels_by_id.has(lid):
			diagnostics.append({
				"rule_id": "ELEM_001_LEVEL_NOT_FOUND",
				"severity": "error",
				"object_kind": "element",
				"object_id": eid,
				"property_path": "level_id",
				"message": "Element '%s' references non-existent spatial level '%s'" % [eid, lid],
				"suggested_fix": "Assign level_id to one of: %s" % avail_str
			})
			continue

		var lvl = levels_by_id[lid]
		var l_elev: float = float(_prop(lvl, "elevation", 0.0))
		var l_height: float = float(_prop(lvl, "default_height", 3.0))

		var t = _prop(elem, "transform")
		var elem_z: float = 0.0
		if t is Dictionary:
			var pos = t.get("position", [0.0, 0.0, 0.0])
			if pos is Array and pos.size() >= 3:
				elem_z = float(pos[2])
		elif t != null and ("position" in t or t is Object):
			var pos = _prop(t, "position")
			if pos is Vector3:
				elem_z = pos.z
			elif pos is Array and pos.size() >= 3:
				elem_z = float(pos[2])

		var min_z := l_elev - 1e-4
		var max_z := l_elev + l_height + 1e-4
		if elem_z < min_z or elem_z > max_z:
			diagnostics.append({
				"rule_id": "SPATIAL_001_ELEVATION_OUT_OF_BOUNDS",
				"severity": "warning",
				"object_kind": "element",
				"object_id": eid,
				"property_path": "transform.position[3]",
				"message": "Element '%s' elevation Z=%f is outside level '%s' bounds [%f, %f]" % [eid, elem_z, lid, l_elev, l_elev + l_height],
				"suggested_fix": "Adjust element position Z or level elevation/height"
			})

		var ve = _prop(elem, "vertical_extent")
		if ve != null:
			var src_lvl = _prop(ve, "source_level_id", null)
			var tgt_lvl = _prop(ve, "target_level_id", null)
			var h := float(_prop(ve, "height", 0.0))
			if src_lvl != null and tgt_lvl != null:
				var s_str := str(src_lvl)
				var t_str := str(tgt_lvl)
				if s_str == t_str or not levels_by_id.has(s_str) or not levels_by_id.has(t_str) or h <= 0.0:
					diagnostics.append({
						"rule_id": "SPATIAL_002_CONNECTOR_LEVEL_MISMATCH",
						"severity": "error",
						"object_kind": "element",
						"object_id": eid,
						"property_path": "vertical_extent",
						"message": "Vertical connector '%s' references invalid, non-existent, or identical levels" % eid,
						"suggested_fix": "Specify valid, distinct source_level_id and target_level_id with height > 0"
					})

# ─────────────────────────────────────────────────────────────────────────────
# 3. Connection & Port Rules
# ─────────────────────────────────────────────────────────────────────────────

func _find_port(elem: Variant, port_id: String) -> Variant:
	for p_group in ["output_ports", "input_ports", "metric_ports"]:
		var arr = _prop(elem, p_group)
		if arr is Array:
			for p in arr:
				if str(_prop(p, "id", "")) == port_id or str(_prop(p, "name", "")) == port_id:
					return p
	return null

func _validate_connections_and_ports(doc: RefCounted, diagnostics: Array, elems_by_id: Dictionary, check_required: bool) -> void:
	var port_connection_counts := {}

	var conns_val = _prop(doc, "connections", [])
	var conns: Array = conns_val if conns_val is Array else []
	for conn in conns:
		if not bool(_prop(conn, "enabled", true)):
			continue

		var cid: String = str(_prop(conn, "id", ""))
		var src_eid: String = str(_prop(conn, "source_element", ""))
		var tgt_eid: String = str(_prop(conn, "target_element", ""))
		var src_pid: String = str(_prop(conn, "source_port", ""))
		var tgt_pid: String = str(_prop(conn, "target_port", ""))

		# 1. Source element existence
		if not elems_by_id.has(src_eid):
			diagnostics.append({
				"rule_id": "PORT_001_NOT_FOUND",
				"severity": "error",
				"object_kind": "connection",
				"object_id": cid,
				"property_path": "source_element",
				"message": "Source element '%s' does not exist in elements" % src_eid,
				"suggested_fix": "Connect to an existing element"
			})
			continue

		# 2. Target element existence
		if not elems_by_id.has(tgt_eid):
			diagnostics.append({
				"rule_id": "PORT_001_NOT_FOUND",
				"severity": "error",
				"object_kind": "connection",
				"object_id": cid,
				"property_path": "target_element",
				"message": "Target element '%s' does not exist in elements" % tgt_eid,
				"suggested_fix": "Connect to an existing element"
			})
			continue

		var src_elem = elems_by_id[src_eid]
		var tgt_elem = elems_by_id[tgt_eid]

		# 3. Source port existence
		var src_port = _find_port(src_elem, src_pid)
		if src_port == null:
			var outs_val = _prop(src_elem, "output_ports", [])
			var outs: Array = outs_val if outs_val is Array else []
			var fix := "Add output port to source element"
			if not outs.is_empty():
				fix = "Connect from '%s'" % str(_prop(outs[0], "id", ""))
			diagnostics.append({
				"rule_id": "PORT_001_NOT_FOUND",
				"severity": "error",
				"object_kind": "connection",
				"object_id": cid,
				"property_path": "source_port",
				"message": "Source port '%s' does not exist on element '%s'" % [src_pid, src_eid],
				"suggested_fix": fix
			})
			continue

		# 4. Target port existence
		var tgt_port = _find_port(tgt_elem, tgt_pid)
		if tgt_port == null:
			var ins_val = _prop(tgt_elem, "input_ports", [])
			var ins: Array = ins_val if ins_val is Array else []
			var fix := "Add input port to target element"
			if not ins.is_empty():
				fix = "Connect to '%s'" % str(_prop(ins[0], "id", ""))
			diagnostics.append({
				"rule_id": "PORT_001_NOT_FOUND",
				"severity": "error",
				"object_kind": "connection",
				"object_id": cid,
				"property_path": "target_port",
				"message": "Target port '%s' does not exist on element '%s'" % [tgt_pid, tgt_eid],
				"suggested_fix": fix
			})
			continue

		var s_kind: String = str(_prop(src_port, "kind", "flow"))
		var t_kind: String = str(_prop(tgt_port, "kind", "flow"))
		var s_dir: String = str(_prop(src_port, "direction", "output"))
		var t_dir: String = str(_prop(tgt_port, "direction", "input"))

		# 5. Port Kinds Compatibility
		var is_compatible := false
		for pair in VALID_KIND_PAIRS:
			if pair[0] == s_kind and pair[1] == t_kind:
				is_compatible = true
				break

		if not is_compatible:
			diagnostics.append({
				"rule_id": "PORT_002_KIND_MISMATCH",
				"severity": "error",
				"object_kind": "connection",
				"object_id": cid,
				"property_path": "target_port",
				"message": "Cannot connect %s %s port to %s %s port '%s'" % [s_kind, s_dir, t_kind, t_dir, tgt_pid],
				"suggested_fix": "Connect to a compatible %s input port" % s_kind
			})
			continue

		# 6. Direction Mismatch
		if s_dir != "output":
			diagnostics.append({
				"rule_id": "PORT_003_DIRECTION_MISMATCH",
				"severity": "error",
				"object_kind": "connection",
				"object_id": cid,
				"property_path": "source_port",
				"message": "Source port '%s' has direction '%s', expected 'output'" % [str(_prop(src_port, "id", "")), s_dir],
				"suggested_fix": "Use an output port as connection source"
			})
		if t_dir != "input":
			diagnostics.append({
				"rule_id": "PORT_003_DIRECTION_MISMATCH",
				"severity": "error",
				"object_kind": "connection",
				"object_id": cid,
				"property_path": "target_port",
				"message": "Target port '%s' has direction '%s', expected 'input'" % [str(_prop(tgt_port, "id", "")), t_dir],
				"suggested_fix": "Use an input port as connection target"
			})

		var skey := "%s:%s:out" % [src_eid, str(_prop(src_port, "id", ""))]
		var tkey := "%s:%s:in" % [tgt_eid, str(_prop(tgt_port, "id", ""))]
		port_connection_counts[skey] = int(port_connection_counts.get(skey, 0)) + 1
		port_connection_counts[tkey] = int(port_connection_counts.get(tkey, 0)) + 1

	# 7. Cardinality Validation
	var elems_val = _prop(doc, "elements", [])
	var elems: Array = elems_val if elems_val is Array else []
	for elem in elems:
		var eid: String = str(_prop(elem, "id", ""))
		var ins_val = _prop(elem, "input_ports", [])
		var ins: Array = ins_val if ins_val is Array else []
		for p in ins:
			var pid: String = str(_prop(p, "id", ""))
			var card: String = str(_prop(p, "cardinality", "many"))
			var count: int = int(port_connection_counts.get("%s:%s:in" % [eid, pid], 0))
			if card == "one" and count > 1:
				diagnostics.append({
					"rule_id": "PORT_004_CARDINALITY_EXCEEDED",
					"severity": "error",
					"object_kind": "port",
					"object_id": pid,
					"property_path": "cardinality",
					"message": "Input port '%s' on element '%s' has cardinality 'one' but receives %d incoming connections" % [pid, eid, count],
					"suggested_fix": "Remove extra connections or set port cardinality to 'many'"
				})
			if check_required and bool(_prop(p, "required", true)) and count == 0:
				diagnostics.append({
					"rule_id": "PORT_005_REQUIRED_UNCONNECTED",
					"severity": "warning",
					"object_kind": "port",
					"object_id": pid,
					"property_path": "required",
					"message": "Required input port '%s' on element '%s' is not connected" % [pid, eid],
					"suggested_fix": "Connect an incoming link to '%s'" % pid
				})

		var outs_val = _prop(elem, "output_ports", [])
		var outs: Array = outs_val if outs_val is Array else []
		for p in outs:
			var pid: String = str(_prop(p, "id", ""))
			var card: String = str(_prop(p, "cardinality", "many"))
			var count: int = int(port_connection_counts.get("%s:%s:out" % [eid, pid], 0))
			if card == "one" and count > 1:
				diagnostics.append({
					"rule_id": "PORT_004_CARDINALITY_EXCEEDED",
					"severity": "error",
					"object_kind": "port",
					"object_id": pid,
					"property_path": "cardinality",
					"message": "Output port '%s' on element '%s' has cardinality 'one' but feeds %d outgoing connections" % [pid, eid, count],
					"suggested_fix": "Remove extra connections or set port cardinality to 'many'"
				})
			if check_required and bool(_prop(p, "required", true)) and count == 0:
				diagnostics.append({
					"rule_id": "PORT_005_REQUIRED_UNCONNECTED",
					"severity": "warning",
					"object_kind": "port",
					"object_id": pid,
					"property_path": "required",
					"message": "Required output port '%s' on element '%s' is not connected" % [pid, eid],
					"suggested_fix": "Connect an outgoing link from '%s'" % pid
				})

# ─────────────────────────────────────────────────────────────────────────────
# 4. Graph Topology & Cycle Detection
# ─────────────────────────────────────────────────────────────────────────────

func _validate_graph_topology(doc: RefCounted, diagnostics: Array, elems_by_id: Dictionary) -> void:
	var elems_val = _prop(doc, "elements", [])
	var elems: Array = elems_val if elems_val is Array else []
	if elems.size() < 2:
		return

	var flow_adj := {}
	var flow_degree := {}
	for elem in elems:
		var eid: String = str(_prop(elem, "id", ""))
		flow_adj[eid] = []
		flow_degree[eid] = 0

	var conns_val = _prop(doc, "connections", [])
	var conns: Array = conns_val if conns_val is Array else []
	for conn in conns:
		if not bool(_prop(conn, "enabled", true)) or str(_prop(conn, "link_type", "flow")) != "flow":
			continue
		var src: String = str(_prop(conn, "source_element", ""))
		var tgt: String = str(_prop(conn, "target_element", ""))
		if flow_adj.has(src) and flow_adj.has(tgt):
			var lat_val = _prop(conn, "latency")
			var lat: float = float(lat_val) if lat_val != null else 0.0
			flow_adj[src].append({"target": tgt, "latency": lat})
			flow_degree[src] = int(flow_degree.get(src, 0)) + 1
			flow_degree[tgt] = int(flow_degree.get(tgt, 0)) + 1

	# Disconnected island check
	for elem in elems:
		var eid: String = str(_prop(elem, "id", ""))
		var lib: String = str(_prop(elem, "library", ""))
		var kind: String = str(_prop(elem, "kind", ""))
		if lib.begins_with("SimElements/DES") or kind in ["source", "queue", "server", "sink", "router", "delay"]:
			if int(flow_degree.get(eid, 0)) == 0:
				diagnostics.append({
					"rule_id": "GRAPH_001_DISCONNECTED_ISLAND",
					"severity": "warning",
					"object_kind": "element",
					"object_id": eid,
					"property_path": "connections",
					"message": "Element '%s' is isolated with no incoming or outgoing connections" % eid,
					"suggested_fix": "Connect '%s' to the process flow graph or remove it" % eid
				})

	# Zero-delay cycle detection
	var stateful_kinds := ["queue", "server", "buffer", "delay", "station"]
	var visited := {}
	for elem in elems:
		visited[str(_prop(elem, "id", ""))] = 0

	for elem in elems:
		var eid: String = str(_prop(elem, "id", ""))
		if visited[eid] == 0:
			_dfs_cycle(eid, [], [], flow_adj, visited, elems_by_id, stateful_kinds, diagnostics)

func _dfs_cycle(node: String, path: Array, latencies: Array, flow_adj: Dictionary, visited: Dictionary, elems_by_id: Dictionary, stateful_kinds: Array, diagnostics: Array) -> void:
	visited[node] = 1
	path.append(node)

	var neighbors: Array = flow_adj.get(node, [])
	for edge in neighbors:
		var n: String = str(edge.get("target", ""))
		var lat: float = float(edge.get("latency", 0.0))
		latencies.append(lat)

		if visited.get(n, 0) == 1:
			# Cycle detected
			var idx := path.find(n)
			if idx >= 0:
				var actual_cycle: Array = path.slice(idx)
				var actual_lats: Array = latencies.slice(idx)

				var has_buffer := false
				for c_node in actual_cycle:
					var e = elems_by_id.get(c_node, null)
					if e != null and str(_prop(e, "kind", "")) in stateful_kinds:
						has_buffer = true
						break

				var has_lat := false
				for l in actual_lats:
					if float(l) > 1e-6:
						has_lat = true
						break

				if not has_buffer and not has_lat:
					var display_cycle: Array = actual_cycle.duplicate()
					display_cycle.append(n)
					var cycle_str := " -> ".join(display_cycle)
					diagnostics.append({
						"rule_id": "GRAPH_002_ZERO_DELAY_CYCLE",
						"severity": "error",
						"object_kind": "element",
						"object_id": str(actual_cycle[0]),
						"property_path": "connections",
						"message": "Zero-delay feedback cycle detected along path: %s. This causes infinite discrete-event livelocks." % cycle_str,
						"suggested_fix": "Add a queue, server, or positive latency (>0) along the feedback cycle"
					})
		elif visited.get(n, 0) == 0:
			_dfs_cycle(n, path, latencies, flow_adj, visited, elems_by_id, stateful_kinds, diagnostics)

		latencies.pop_back()

	path.pop_back()
	visited[node] = 2

# ─────────────────────────────────────────────────────────────────────────────
# 5. ABM Config Rules
# ─────────────────────────────────────────────────────────────────────────────

func _validate_abm_config(doc: RefCounted, diagnostics: Array) -> void:
	var abm = _prop(doc, "abm_config")
	if abm == null:
		return
	if not bool(_prop(abm, "enabled", false)):
		return

	var mname: String = str(_prop(abm, "model_name", "")).strip_edges()
	if mname.is_empty():
		diagnostics.append({
			"rule_id": "ABM_001_INVALID_MODEL",
			"severity": "error",
			"object_kind": "abm_config",
			"object_id": "abm_config",
			"property_path": "model_name",
			"message": "ABM is enabled but model_name is not specified",
			"suggested_fix": "Specify a registered model_name (e.g. 'SFM', 'ORCA', 'HybridFSM')"
		})
	elif not (mname in KNOWN_ABM_MODELS):
		diagnostics.append({
			"rule_id": "ABM_001_INVALID_MODEL",
			"severity": "warning",
			"object_kind": "abm_config",
			"object_id": "abm_config",
			"property_path": "model_name",
			"message": "Unregistered ABM model_name '%s'" % mname,
			"suggested_fix": "Verify that model library '%s' is installed" % str(_prop(abm, "model_library", ""))
		})

	var sim = _prop(doc, "simulation")
	var mode: String = "des_only"
	if sim != null:
		mode = str(_prop(sim, "mode", "des_only"))

	if mode != "abm_only" and mode != "hybrid":
		diagnostics.append({
			"rule_id": "ABM_001_INVALID_MODEL",
			"severity": "error",
			"object_kind": "abm_config",
			"object_id": "abm_config",
			"property_path": "simulation.mode",
			"message": "ABM is enabled but simulation.mode is set to '%s'" % mode,
			"suggested_fix": "Change simulation.mode to 'abm_only' or 'hybrid'"
		})

# ─────────────────────────────────────────────────────────────────────────────
# 6. Extension Governance Rules
# ─────────────────────────────────────────────────────────────────────────────

const RESERVED_DOCUMENT_KEYS := [
	"spec_version", "scene", "simulation", "abm_config", "spatial",
	"elements", "connections", "subgraphs", "overlays", "validation_metadata"
]

const RESERVED_ELEMENT_KEYS := [
	"id", "name", "kind", "library", "library_version", "level_id",
	"transform", "geometry", "editor", "properties", "input_ports",
	"output_ports", "metric_ports", "vertical_extent", "visual"
]

const RESERVED_PORT_KEYS := [
	"id", "name", "direction", "kind", "data_type", "cardinality",
	"required", "unit", "description"
]

const RESERVED_CONNECTION_KEYS := [
	"id", "source_element", "source_port", "target_element", "target_port",
	"link_type", "enabled", "ordering", "condition", "latency", "capacity"
]

const RESERVED_LEVEL_KEYS := [
	"id", "name", "elevation", "default_height", "visible"
]

static var _ext_key_regex: RegEx = null

static func _get_ext_key_regex() -> RegEx:
	if _ext_key_regex == null:
		_ext_key_regex = RegEx.new()
		_ext_key_regex.compile("^[a-zA-Z0-9_\\-:/.]+$")
	return _ext_key_regex

func _check_dict_keys(diagnostics: Array, ext: Variant, object_kind: String, object_id: String, path_prefix: String, reserved: Array) -> void:
	if not (ext is Dictionary):
		return
	var dict: Dictionary = ext
	for k in dict.keys():
		var sk := str(k)
		var v = dict[k]
		if sk == "extensions":
			if v is Dictionary:
				_check_dict_keys(diagnostics, v, object_kind, object_id, "extensions" if path_prefix.is_empty() else "%s.extensions" % path_prefix, [])
			continue

		var prop_path := sk if path_prefix.is_empty() else "%s.%s" % [path_prefix, sk]

		# EXT_001_INVALID_KEY
		if sk.is_empty() or _get_ext_key_regex().search(sk) == null:
			diagnostics.append({
				"rule_id": "EXT_001_INVALID_KEY",
				"severity": "error",
				"object_kind": object_kind,
				"object_id": object_id,
				"property_path": prop_path,
				"message": "Invalid extension key '%s' on %s '%s'" % [sk, object_kind, object_id],
				"suggested_fix": "Use alphanumeric, underscore, hyphen, colon, or dot characters without spaces"
			})

		# EXT_002_RESERVED_KEY_CONFLICT
		if sk in reserved:
			diagnostics.append({
				"rule_id": "EXT_002_RESERVED_KEY_CONFLICT",
				"severity": "error",
				"object_kind": object_kind,
				"object_id": object_id,
				"property_path": prop_path,
				"message": "Extension key '%s' conflicts with reserved core schema field on %s '%s'" % [sk, object_kind, object_id],
				"suggested_fix": "Rename extension key or nest under a vendor namespace"
			})

		if v is Dictionary:
			_check_dict_keys(diagnostics, v, object_kind, object_id, prop_path, [])

func _validate_extensions(doc: RefCounted, diagnostics: Array) -> void:
	var doc_id: String = ""
	var scene_val = _prop(doc, "scene")
	if scene_val != null:
		doc_id = str(_prop(scene_val, "id", ""))

	_check_dict_keys(diagnostics, _prop(doc, "extensions"), "document", doc_id, "extensions", RESERVED_DOCUMENT_KEYS)
	if scene_val != null:
		_check_dict_keys(diagnostics, _prop(scene_val, "extensions"), "scene", doc_id, "scene.extensions", [])

	var sim_val = _prop(doc, "simulation")
	if sim_val != null:
		_check_dict_keys(diagnostics, _prop(sim_val, "extensions"), "simulation", "simulation", "simulation.extensions", [])

	var sp_val = _prop(doc, "spatial")
	if sp_val != null:
		_check_dict_keys(diagnostics, _prop(sp_val, "extensions"), "spatial", "spatial", "spatial.extensions", [])
		var lvls_val = _prop(sp_val, "levels", [])
		if lvls_val is Array:
			for lvl in lvls_val:
				var lid: String = str(_prop(lvl, "id", ""))
				_check_dict_keys(diagnostics, _prop(lvl, "extensions"), "level", lid, "spatial.levels[%s].extensions" % lid, RESERVED_LEVEL_KEYS)

	var elems_val = _prop(doc, "elements", [])
	if elems_val is Array:
		for elem in elems_val:
			var eid: String = str(_prop(elem, "id", ""))
			_check_dict_keys(diagnostics, _prop(elem, "extensions"), "element", eid, "elements[%s].extensions" % eid, RESERVED_ELEMENT_KEYS)
			for p_group in ["input_ports", "output_ports", "metric_ports"]:
				var ports_val = _prop(elem, p_group, [])
				if ports_val is Array:
					for p in ports_val:
						var pid: String = str(_prop(p, "id", ""))
						_check_dict_keys(diagnostics, _prop(p, "extensions"), "port", pid, "elements[%s].%s[%s].extensions" % [eid, p_group, pid], RESERVED_PORT_KEYS)

	var conns_val = _prop(doc, "connections", [])
	if conns_val is Array:
		for conn in conns_val:
			var cid: String = str(_prop(conn, "id", ""))
			_check_dict_keys(diagnostics, _prop(conn, "extensions"), "connection", cid, "connections[%s].extensions" % cid, RESERVED_CONNECTION_KEYS)

