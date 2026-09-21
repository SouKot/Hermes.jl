# ============================================================================
# SimVizSceneSubgraphs (Phase 7D-04)
#
# Hierarchical Subgraph Expansion, Two-Phase Compilation, Parameter Overrides,
# Port Rewiring, and Bidirectional Source Mapping in Godot.
# ============================================================================
class_name SimVizSceneSubgraphs extends RefCounted

const SceneTypes = preload("res://scripts/scenespec_types.gd")
const SpatialResolver = preload("res://scripts/scenespec_spatial.gd")

const MAX_SUBGRAPH_DEPTH = 16

# ─────────────────────────────────────────────────────────────────────────────
# Parameter Overrides
# ─────────────────────────────────────────────────────────────────────────────

static func _apply_parameter_overrides(
	props: Dictionary,
	local_id: String,
	overrides: Dictionary
) -> Dictionary:
	if overrides.is_empty():
		return props.duplicate(true)

	var out: Dictionary = props.duplicate(true)
	var prefix_exact: String = local_id + "."

	for k in overrides.keys():
		var sk := str(k)
		var val = overrides[k]
		if sk.begins_with(prefix_exact):
			var prop_name: String = sk.substr(prefix_exact.length())
			out[prop_name] = val
		elif sk.begins_with("*."):
			var prop_name: String = sk.substr(2)
			out[prop_name] = val
		elif out.has(sk):
			out[sk] = val

	return out

# ─────────────────────────────────────────────────────────────────────────────
# Exposed Port Target Resolution
# ─────────────────────────────────────────────────────────────────────────────

static func _resolve_exposed_port(ep: Dictionary) -> Dictionary:
	var pid := str(ep.get("id", ep.get("name", ep.get("port_id", ""))))
	var telem := str(ep.get("target_element", ep.get("internal_element", ep.get("element", ""))))
	var tport := str(ep.get("target_port", ep.get("internal_port", ep.get("port", ""))))
	return { "id": pid, "target_element": telem, "target_port": tport }

# ─────────────────────────────────────────────────────────────────────────────
# Subgraph Compilation & Expansion
# ─────────────────────────────────────────────────────────────────────────────

"""
Compiles a hierarchical SceneDocument into a flat runtime SceneDocument:
- Expands compound subgraphs using their templates and relative transforms
- Bakes path-scoped parameter overrides
- Rewires boundary connections through exposed ports
- Produces bidirectional source mapping for diagnostics and inspection
"""
static func compile_scene_graph(doc: SceneTypes.SceneDocument, delimiter: String = "::") -> Dictionary:
	var templates: Dictionary = {}
	var compound_or_group: Array = []

	for s in doc.subgraphs:
		if s is SceneTypes.SceneSubgraph:
			if s.role == "template":
				templates[s.id] = s
			else:
				compound_or_group.append(s)
		elif s is Dictionary:
			var sub_obj := SceneTypes.SceneSubgraph.from_dict(s)
			if sub_obj.role == "template":
				templates[sub_obj.id] = sub_obj
			else:
				compound_or_group.append(sub_obj)

	var proto_elements: Dictionary = {}
	for e in doc.elements:
		if e is SceneTypes.SceneElement:
			proto_elements[e.id] = e

	var proto_connections: Dictionary = {}
	for c in doc.connections:
		if c is SceneTypes.SceneConnection:
			proto_connections[c.id] = c

	var template_elem_ids := {}
	var template_conn_ids := {}
	for tid in templates.keys():
		var t: SceneTypes.SceneSubgraph = templates[tid]
		for eid in t.elements:
			template_elem_ids[str(eid)] = true
		for cid in t.connections:
			template_conn_ids[str(cid)] = true

	var runtime_to_hierarchical: Dictionary = {}
	var hierarchical_to_runtime: Dictionary = {}
	var port_forwarding: Dictionary = {}
	var hierarchy_tree: Dictionary = {}

	var flat_elements: Array = []
	var flat_connections: Array = []

	# 1. Retain top-level non-template elements
	for e in doc.elements:
		if e is SceneTypes.SceneElement:
			if not template_elem_ids.has(e.id):
				flat_elements.append(e.clone())
				runtime_to_hierarchical[e.id] = { "subgraph_id": "", "local_id": e.id, "template_id": null }
				hierarchical_to_runtime["/" + e.id] = e.id

	# 2. Expand each compound / group subgraph
	for sub in compound_or_group:
		var s: SceneTypes.SceneSubgraph = sub if sub is SceneTypes.SceneSubgraph else SceneTypes.SceneSubgraph.from_dict(sub)
		var sub_path: String = s.id
		var sub_trans: SceneTypes.SceneTransform = s.transform if s.transform != null else SceneTypes.SceneTransform.new()
		var effective_level: String = s.level_id if s.level_id != null and s.level_id != "" else "level_ground"

		var tree_node := {
			"id": s.id,
			"path": sub_path,
			"name": s.name,
			"role": s.role,
			"template_id": s.template_id,
			"elements": [],
			"connections": []
		}

		# Register exposed ports
		for ep in s.exposed_ports:
			if ep is Dictionary:
				var resolved := _resolve_exposed_port(ep)
				if resolved.id != "" and resolved.target_element != "":
					var full_telem: String = sub_path + delimiter + resolved.target_element
					port_forwarding[sub_path + ":" + resolved.id] = { "element": full_telem, "port": resolved.target_port }

		# Look up template if specified
		var local_elems: Array = s.elements.duplicate(true)
		var local_conns: Array = s.connections.duplicate(true)

		if s.template_id != null and templates.has(s.template_id):
			var tmpl: SceneTypes.SceneSubgraph = templates[s.template_id]
			if local_elems.is_empty():
				local_elems = tmpl.elements.duplicate(true)
			if local_conns.is_empty():
				local_conns = tmpl.connections.duplicate(true)
			for ep in tmpl.exposed_ports:
				if ep is Dictionary:
					var resolved := _resolve_exposed_port(ep)
					var port_key: String = sub_path + ":" + resolved.id
					if not port_forwarding.has(port_key):
						var full_telem: String = sub_path + delimiter + resolved.target_element
						port_forwarding[port_key] = { "element": full_telem, "port": resolved.target_port }

		# Expand elements
		for eid in local_elems:
			var sid := str(eid)
			if proto_elements.has(sid):
				var proto: SceneTypes.SceneElement = proto_elements[sid]
				var flat_id: String = sub_path + delimiter + proto.id

				var elem_composed_trans := SpatialResolver.compose_transforms(sub_trans, proto.transform)
				var merged_props := _apply_parameter_overrides(proto.properties, proto.id, s.parameter_overrides)
				var elem_level: String = proto.level_id if (proto.level_id != "" and proto.level_id != "level_ground") else effective_level

				var new_elem: SceneTypes.SceneElement = proto.clone()
				new_elem.id = flat_id
				new_elem.name = s.name + " / " + proto.name
				new_elem.level_id = elem_level
				new_elem.transform = elem_composed_trans
				new_elem.properties = merged_props
				flat_elements.append(new_elem)

				runtime_to_hierarchical[flat_id] = {
					"subgraph_id": sub_path,
					"local_id": proto.id,
					"template_id": s.template_id
				}
				hierarchical_to_runtime[sub_path + "/" + proto.id] = flat_id
				tree_node["elements"].append(flat_id)

		# Expand internal connections
		for cid in local_conns:
			var scid := str(cid)
			if proto_connections.has(scid):
				var proto_conn: SceneTypes.SceneConnection = proto_connections[scid]
				var new_cid: String = sub_path + delimiter + proto_conn.id
				var new_src: String = sub_path + delimiter + proto_conn.source_element
				var new_tgt: String = sub_path + delimiter + proto_conn.target_element

				var new_conn: SceneTypes.SceneConnection = proto_conn.clone()
				new_conn.id = new_cid
				new_conn.source_element = new_src
				new_conn.target_element = new_tgt
				flat_connections.append(new_conn)
				tree_node["connections"].append(new_cid)

		hierarchy_tree[sub_path] = tree_node

	# 3. Process top-level connections and rewire boundary ports
	for c in doc.connections:
		if c is SceneTypes.SceneConnection:
			if template_conn_ids.has(c.id):
				continue

			var rewired_conn: SceneTypes.SceneConnection = c.clone()
			var src_key: String = c.source_element + ":" + c.source_port
			var tgt_key: String = c.target_element + ":" + c.target_port

			if port_forwarding.has(src_key):
				var fwd_src: Dictionary = port_forwarding[src_key]
				rewired_conn.source_element = fwd_src["element"]
				rewired_conn.source_port = fwd_src["port"]

			if port_forwarding.has(tgt_key):
				var fwd_tgt: Dictionary = port_forwarding[tgt_key]
				rewired_conn.target_element = fwd_tgt["element"]
				rewired_conn.target_port = fwd_tgt["port"]

			flat_connections.append(rewired_conn)

	var flat_doc: SceneTypes.SceneDocument = doc.clone()
	flat_doc.elements = flat_elements
	flat_doc.connections = flat_connections

	var source_map := {
		"runtime_to_hierarchical": runtime_to_hierarchical,
		"hierarchical_to_runtime": hierarchical_to_runtime
	}

	return {
		"flat_doc": flat_doc,
		"source_map": source_map,
		"port_forwarding": port_forwarding,
		"hierarchy_tree": hierarchy_tree
	}

"""
Convenience wrapper returning flat compiled SceneDocument.
"""
static func expand_subgraphs(doc: SceneTypes.SceneDocument, delimiter: String = "::") -> SceneTypes.SceneDocument:
	var compiled: Dictionary = compile_scene_graph(doc, delimiter)
	return compiled["flat_doc"]

"""
Resolves flat runtime element ID back to hierarchical metadata.
"""
static func resolve_runtime_source(source_map: Dictionary, flat_id: String) -> Dictionary:
	var r2h: Dictionary = source_map.get("runtime_to_hierarchical", {})
	if r2h.has(flat_id):
		return r2h[flat_id]
	return { "subgraph_id": "", "local_id": flat_id, "template_id": null }

"""
Roll-up helper aggregating scalar metrics across a subgraph's expanded elements.
"""
static func query_hierarchical_metric(
	source_map: Dictionary,
	subgraph_id: String,
	metrics_by_elem: Dictionary
) -> float:
	var total: float = 0.0
	var r2h: Dictionary = source_map.get("runtime_to_hierarchical", {})

	for eid in metrics_by_elem.keys():
		var seid := str(eid)
		if r2h.has(seid):
			var info: Dictionary = r2h[seid]
			if str(info.get("subgraph_id", "")) == subgraph_id:
				total += float(metrics_by_elem[eid])

	return total

