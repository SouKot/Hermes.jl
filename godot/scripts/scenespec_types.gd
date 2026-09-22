class_name SimVizSceneTypes
extends RefCounted

# ============================================================================
# SceneTransform
# ============================================================================
class SceneTransform extends RefCounted:
	var position: Vector3 = Vector3.ZERO
	var rotation: Vector3 = Vector3.ZERO
	var scale: Vector3 = Vector3.ONE

	func _init(p: Vector3 = Vector3.ZERO, r: Vector3 = Vector3.ZERO, s: Vector3 = Vector3.ONE) -> void:
		position = p
		rotation = r
		scale = s

	static func from_dict(d: Dictionary) -> SceneTransform:
		var st := SceneTransform.new()
		if d.has("position") and d["position"] is Array and d["position"].size() >= 3:
			st.position = Vector3(float(d["position"][0]), float(d["position"][1]), float(d["position"][2]))
		if d.has("rotation") and d["rotation"] is Array and d["rotation"].size() >= 3:
			st.rotation = Vector3(float(d["rotation"][0]), float(d["rotation"][1]), float(d["rotation"][2]))
		if d.has("scale") and d["scale"] is Array and d["scale"].size() >= 3:
			st.scale = Vector3(float(d["scale"][0]), float(d["scale"][1]), float(d["scale"][2]))
		return st

	func to_dict() -> Dictionary:
		return {
			"position": [position.x, position.y, position.z],
			"rotation": [rotation.x, rotation.y, rotation.z],
			"scale": [scale.x, scale.y, scale.z]
		}

	func clone() -> SceneTransform:
		var c := SceneTransform.new()
		c.position = position
		c.rotation = rotation
		c.scale = scale
		return c

# ============================================================================
# SceneExtensible
# ============================================================================
class SceneExtensible extends RefCounted:
	var extensions: Dictionary = {}

	func has_extension(key: String) -> bool:
		if extensions.has(key):
			return true
		if extensions.has("extensions") and extensions["extensions"] is Dictionary:
			return extensions["extensions"].has(key)
		return false

	func get_extension(key: String, default_val: Variant = null) -> Variant:
		if extensions.has(key):
			return extensions[key]
		if extensions.has("extensions") and extensions["extensions"] is Dictionary:
			var sub: Dictionary = extensions["extensions"]
			if sub.has(key):
				return sub[key]
		return default_val

	func set_extension(key: String, value: Variant, in_nested_block: bool = false) -> void:
		if in_nested_block:
			if not extensions.has("extensions") or not (extensions["extensions"] is Dictionary):
				extensions["extensions"] = {}
			extensions["extensions"][key] = value
		else:
			if not extensions.has(key) and extensions.has("extensions") and (extensions["extensions"] is Dictionary) and extensions["extensions"].has(key):
				extensions["extensions"][key] = value
			else:
				extensions[key] = value

	func delete_extension(key: String) -> Variant:
		if extensions.has(key):
			var val = extensions[key]
			extensions.erase(key)
			return val
		if extensions.has("extensions") and extensions["extensions"] is Dictionary:
			var sub: Dictionary = extensions["extensions"]
			if sub.has(key):
				var val = sub[key]
				sub.erase(key)
				if sub.is_empty():
					extensions.erase("extensions")
				return val
		return null

	func list_extensions() -> Array:
		var s := {}
		for k in extensions.keys():
			if str(k) != "extensions":
				s[str(k)] = true
		if extensions.has("extensions") and extensions["extensions"] is Dictionary:
			for k in extensions["extensions"].keys():
				s[str(k)] = true
		var res: Array = s.keys()
		res.sort()
		return res

	func get_extension_path(path: String, default_val: Variant = null) -> Variant:
		var raw_tokens = path.split(".", false)
		var tokens: Array = []
		for tok in raw_tokens:
			for sub in tok.split("/", false):
				var st := sub.strip_edges()
				if not st.is_empty():
					tokens.append(st)
		if tokens.is_empty():
			return default_val

		var first_tok: String = tokens[0]
		var curr: Variant = get_extension(first_tok, null)
		var start_idx := 1
		if curr == null:
			if first_tok == "extensions" and tokens.size() > 1:
				curr = extensions.get("extensions", null)
				start_idx = 1
			else:
				return default_val
		else:
			start_idx = 1

		for i in range(start_idx, tokens.size()):
			if curr == null:
				return default_val
			var tok: String = tokens[i]
			if curr is Dictionary:
				if curr.has(tok):
					curr = curr[tok]
				else:
					return default_val
			elif curr is Array:
				if tok.is_valid_int():
					var idx := tok.to_int()
					if idx >= 0 and idx < curr.size():
						curr = curr[idx]
					else:
						return default_val
				else:
					return default_val
			else:
				return default_val
		return curr

	func set_extension_path(path: String, value: Variant) -> void:
		var raw_tokens = path.split(".", false)
		var tokens: Array = []
		for tok in raw_tokens:
			for sub in tok.split("/", false):
				var st := sub.strip_edges()
				if not st.is_empty():
					tokens.append(st)
		if tokens.is_empty():
			return

		if tokens.size() == 1:
			set_extension(tokens[0], value)
			return

		var start_idx := 1
		var curr: Dictionary
		var first_tok: String = tokens[0]
		if first_tok == "extensions":
			if not extensions.has("extensions") or not (extensions["extensions"] is Dictionary):
				extensions["extensions"] = {}
			curr = extensions["extensions"]
			start_idx = 1
		else:
			if extensions.has(first_tok) and extensions[first_tok] is Dictionary:
				curr = extensions[first_tok]
			elif extensions.has("extensions") and extensions["extensions"] is Dictionary and extensions["extensions"].has(first_tok) and extensions["extensions"][first_tok] is Dictionary:
				curr = extensions["extensions"][first_tok]
			else:
				curr = {}
				extensions[first_tok] = curr
			start_idx = 1

		for i in range(start_idx, tokens.size() - 1):
			var tok: String = tokens[i]
			if not curr.has(tok) or not (curr[tok] is Dictionary):
				curr[tok] = {}
			curr = curr[tok]

		var leaf_tok: String = tokens[tokens.size() - 1]
		curr[leaf_tok] = value

	func get_namespace(ns: String) -> Dictionary:
		var val = get_extension(ns, null)
		if val is Dictionary:
			return val.duplicate(true)
		return {}

	func set_namespace(ns: String, data: Dictionary) -> void:
		set_extension(ns, data.duplicate(true), true)

	func has_namespace(ns: String) -> bool:
		var val = get_extension(ns, null)
		return val is Dictionary

	func delete_namespace(ns: String) -> Variant:
		return delete_extension(ns)

	func merge_extensions(data: Dictionary) -> void:
		_deep_merge_dict(extensions, data)

	static func _deep_merge_dict(dest: Dictionary, src: Dictionary) -> void:
		for k in src.keys():
			var sk := str(k)
			var v = src[k]
			var target_dict: Dictionary = dest
			if not dest.has(sk) and dest.has("extensions") and (dest["extensions"] is Dictionary) and dest["extensions"].has(sk):
				target_dict = dest["extensions"]

			if target_dict.has(sk) and target_dict[sk] is Dictionary and v is Dictionary:
				_deep_merge_dict(target_dict[sk], v)
			elif v is Dictionary:
				target_dict[sk] = v.duplicate(true)
			elif v is Array:
				target_dict[sk] = v.duplicate(true)
			else:
				target_dict[sk] = v

# ============================================================================
# SceneEditorMeta
# ============================================================================
class SceneEditorMeta extends SceneExtensible:
	var graph_position: Vector2 = Vector2.ZERO
	var collapsed: bool = false
	var color: String = ""
	var notes: String = ""

	static func from_dict(d: Dictionary) -> SceneEditorMeta:
		var ed := SceneEditorMeta.new()
		if d.has("graph_position") and d["graph_position"] is Array and d["graph_position"].size() >= 2:
			ed.graph_position = Vector2(float(d["graph_position"][0]), float(d["graph_position"][1]))
		ed.collapsed = bool(d.get("collapsed", false))
		ed.color = str(d.get("color", ""))
		ed.notes = str(d.get("notes", ""))

		for k in d.keys():
			var sk := str(k)
			if sk not in ["graph_position", "collapsed", "color", "notes"]:
				if sk == "extensions" and d["extensions"] is Dictionary:
					ed.extensions["extensions"] = d["extensions"].duplicate(true)
				else:
					ed.extensions[sk] = d[k]
		return ed

	func to_dict() -> Dictionary:
		var out: Dictionary = {
			"graph_position": [graph_position.x, graph_position.y],
			"collapsed": collapsed
		}
		if not color.is_empty():
			out["color"] = color
		if not notes.is_empty():
			out["notes"] = notes

		for k in extensions.keys():
			if k == "extensions":
				out["extensions"] = extensions["extensions"].duplicate(true)
			else:
				out[k] = extensions[k]
		return out

	func clone() -> SceneEditorMeta:
		var c := SceneEditorMeta.new()
		c.graph_position = graph_position
		c.collapsed = collapsed
		c.color = color
		c.notes = notes
		c.extensions = extensions.duplicate(true)
		return c

# ============================================================================
# ScenePort
# ============================================================================
class ScenePort extends SceneExtensible:
	var id: String = ""
	var name: String = ""
	var direction: String = "input"
	var kind: String = "flow"
	var data_type: String = "entity"
	var cardinality: String = "many"
	var required: bool = true
	var unit: String = ""
	var description: String = ""

	static func from_dict(d: Dictionary) -> ScenePort:
		var p := ScenePort.new()
		p.id = str(d.get("id", ""))
		p.name = str(d.get("name", p.id))
		p.direction = str(d.get("direction", "input"))
		p.kind = str(d.get("kind", "flow"))
		p.data_type = str(d.get("data_type", "entity"))
		p.cardinality = str(d.get("cardinality", "many"))
		p.required = bool(d.get("required", true))
		p.unit = str(d.get("unit", ""))
		p.description = str(d.get("description", ""))

		for k in d.keys():
			var sk := str(k)
			if sk not in ["id", "name", "direction", "kind", "data_type", "cardinality", "required", "unit", "description"]:
				if sk == "extensions" and d["extensions"] is Dictionary:
					p.extensions["extensions"] = d["extensions"].duplicate(true)
				else:
					p.extensions[sk] = d[k]
		return p

	func to_dict() -> Dictionary:
		var out: Dictionary = {
			"id": id,
			"name": name,
			"direction": direction,
			"kind": kind,
			"data_type": data_type,
			"cardinality": cardinality,
			"required": required
		}
		if not unit.is_empty():
			out["unit"] = unit
		if not description.is_empty():
			out["description"] = description

		for k in extensions.keys():
			if k == "extensions":
				out["extensions"] = extensions["extensions"].duplicate(true)
			else:
				out[k] = extensions[k]
		return out

	func clone() -> ScenePort:
		var c := ScenePort.new()
		c.id = id
		c.name = name
		c.direction = direction
		c.kind = kind
		c.data_type = data_type
		c.cardinality = cardinality
		c.required = required
		c.unit = unit
		c.description = description
		c.extensions = extensions.duplicate(true)
		return c

# ============================================================================
# SceneLevel
# ============================================================================
class SceneLevel extends SceneExtensible:
	var id: String = ""
	var name: String = ""
	var elevation: float = 0.0
	var default_height: float = 3.0
	var visible: bool = true

	static func from_dict(d: Dictionary) -> SceneLevel:
		var l := SceneLevel.new()
		l.id = str(d.get("id", ""))
		l.name = str(d.get("name", l.id))
		l.elevation = float(d.get("elevation", 0.0))
		l.default_height = float(d.get("default_height", 3.0))
		l.visible = bool(d.get("visible", true))

		for k in d.keys():
			var sk := str(k)
			if sk not in ["id", "name", "elevation", "default_height", "visible"]:
				if sk == "extensions" and d["extensions"] is Dictionary:
					l.extensions["extensions"] = d["extensions"].duplicate(true)
				else:
					l.extensions[sk] = d[k]
		return l

	func to_dict() -> Dictionary:
		var out: Dictionary = {
			"id": id,
			"name": name,
			"elevation": elevation,
			"default_height": default_height,
			"visible": visible
		}
		for k in extensions.keys():
			if k == "extensions":
				out["extensions"] = extensions["extensions"].duplicate(true)
			else:
				out[k] = extensions[k]
		return out

	func clone() -> SceneLevel:
		var c := SceneLevel.new()
		c.id = id
		c.name = name
		c.elevation = elevation
		c.default_height = default_height
		c.visible = visible
		c.extensions = extensions.duplicate(true)
		return c

# ============================================================================
# SceneConnection
# ============================================================================
class SceneConnection extends SceneExtensible:
	var id: String = ""
	var source_element: String = ""
	var source_port: String = ""
	var target_element: String = ""
	var target_port: String = ""
	var link_type: String = "flow"
	var enabled: bool = true
	var ordering: int = 1
	var condition: Variant = null
	var latency: Variant = null
	var capacity: Variant = null

	static func from_dict(d: Dictionary) -> SceneConnection:
		var c := SceneConnection.new()
		c.id = str(d.get("id", ""))
		c.source_element = str(d.get("source_element", ""))
		c.source_port = str(d.get("source_port", ""))
		c.target_element = str(d.get("target_element", ""))
		c.target_port = str(d.get("target_port", ""))
		c.link_type = str(d.get("link_type", "flow"))
		c.enabled = bool(d.get("enabled", true))
		c.ordering = int(d.get("ordering", 1))
		c.condition = d.get("condition", null)
		c.latency = d.get("latency", null)
		c.capacity = d.get("capacity", null)

		for k in d.keys():
			var sk := str(k)
			if sk not in ["id", "source_element", "source_port", "target_element", "target_port", "link_type", "enabled", "ordering", "condition", "latency", "capacity"]:
				if sk == "extensions" and d["extensions"] is Dictionary:
					c.extensions["extensions"] = d["extensions"].duplicate(true)
				else:
					c.extensions[sk] = d[k]
		return c

	func to_dict() -> Dictionary:
		var out: Dictionary = {
			"id": id,
			"source_element": source_element,
			"source_port": source_port,
			"target_element": target_element,
			"target_port": target_port,
			"link_type": link_type,
			"enabled": enabled,
			"ordering": ordering
		}
		if condition != null:
			out["condition"] = condition
		if latency != null:
			out["latency"] = latency
		if capacity != null:
			out["capacity"] = capacity

		for k in extensions.keys():
			if k == "extensions":
				out["extensions"] = extensions["extensions"].duplicate(true)
			else:
				out[k] = extensions[k]
		return out

	func clone() -> SceneConnection:
		var c := SceneConnection.new()
		c.id = id
		c.source_element = source_element
		c.source_port = source_port
		c.target_element = target_element
		c.target_port = target_port
		c.link_type = link_type
		c.enabled = enabled
		c.ordering = ordering
		c.condition = condition.duplicate(true) if condition is Dictionary else condition
		c.latency = latency
		c.capacity = capacity
		c.extensions = extensions.duplicate(true)
		return c

# ============================================================================
# SceneElement
# ============================================================================
class SceneElement extends SceneExtensible:
	var id: String = ""
	var name: String = ""
	var kind: String = ""
	var library: String = ""
	var library_version: String = ""
	var level_id: String = ""
	var transform: SceneTransform = SceneTransform.new()
	var geometry: Dictionary = {}
	var editor: SceneEditorMeta = SceneEditorMeta.new()
	var properties: Dictionary = {}
	var input_ports: Array = []
	var output_ports: Array = []
	var metric_ports: Array = []
	var vertical_extent: Variant = null
	var visual: Variant = null

	static func from_dict(d: Dictionary) -> SceneElement:
		var elem := SceneElement.new()
		elem.id = str(d.get("id", ""))
		elem.name = str(d.get("name", elem.id))
		elem.kind = str(d.get("kind", ""))
		elem.library = str(d.get("library", ""))
		elem.library_version = str(d.get("library_version", ""))
		elem.level_id = str(d.get("level_id", "level_ground"))

		if d.has("transform") and d["transform"] is Dictionary:
			elem.transform = SceneTransform.from_dict(d["transform"])
		if d.has("geometry") and d["geometry"] is Dictionary:
			elem.geometry = d["geometry"].duplicate(true)
		if d.has("editor") and d["editor"] is Dictionary:
			elem.editor = SceneEditorMeta.from_dict(d["editor"])
		if d.has("properties") and d["properties"] is Dictionary:
			elem.properties = d["properties"].duplicate(true)

		elem.input_ports = _parse_ports(d.get("input_ports", []))
		elem.output_ports = _parse_ports(d.get("output_ports", []))
		elem.metric_ports = _parse_ports(d.get("metric_ports", []))

		if d.has("vertical_extent"):
			elem.vertical_extent = d["vertical_extent"].duplicate(true) if d["vertical_extent"] is Dictionary else d["vertical_extent"]
		if d.has("visual"):
			elem.visual = d["visual"].duplicate(true) if d["visual"] is Dictionary else d["visual"]

		for k in d.keys():
			var sk := str(k)
			if sk not in ["id", "name", "kind", "library", "library_version", "level_id", "transform", "geometry", "editor", "properties", "input_ports", "output_ports", "metric_ports", "vertical_extent", "visual"]:
				if sk == "extensions" and d["extensions"] is Dictionary:
					elem.extensions["extensions"] = d["extensions"].duplicate(true)
				else:
					elem.extensions[sk] = d[k]
		return elem

	static func _parse_ports(arr: Variant) -> Array:
		var out: Array = []
		if arr is Array:
			for item in arr:
				if item is Dictionary:
					out.append(ScenePort.from_dict(item))
		return out

	func to_dict() -> Dictionary:
		var in_arr: Array = []
		for p in input_ports:
			in_arr.append(p.to_dict() if p is ScenePort else p)
		var out_arr: Array = []
		for p in output_ports:
			out_arr.append(p.to_dict() if p is ScenePort else p)
		var met_arr: Array = []
		for p in metric_ports:
			met_arr.append(p.to_dict() if p is ScenePort else p)

		var out: Dictionary = {
			"id": id,
			"name": name,
			"kind": kind,
			"library": library,
			"library_version": library_version,
			"level_id": level_id,
			"transform": transform.to_dict(),
			"geometry": geometry.duplicate(true),
			"editor": editor.to_dict(),
			"properties": properties.duplicate(true),
			"input_ports": in_arr,
			"output_ports": out_arr,
			"metric_ports": met_arr
		}
		if vertical_extent != null:
			out["vertical_extent"] = vertical_extent
		if visual != null:
			out["visual"] = visual

		for k in extensions.keys():
			if k == "extensions":
				out["extensions"] = extensions["extensions"].duplicate(true)
			else:
				out[k] = extensions[k]
		return out

	func clone() -> SceneElement:
		var c := SceneElement.new()
		c.id = id
		c.name = name
		c.kind = kind
		c.library = library
		c.library_version = library_version
		c.level_id = level_id
		c.transform = transform.clone()
		c.geometry = geometry.duplicate(true)
		c.editor = editor.clone()
		c.properties = properties.duplicate(true)
		for p in input_ports:
			c.input_ports.append(p.clone() if p is ScenePort else p)
		for p in output_ports:
			c.output_ports.append(p.clone() if p is ScenePort else p)
		for p in metric_ports:
			c.metric_ports.append(p.clone() if p is ScenePort else p)
		c.vertical_extent = vertical_extent.duplicate(true) if vertical_extent is Dictionary else vertical_extent
		c.visual = visual.duplicate(true) if visual is Dictionary else visual
		c.extensions = extensions.duplicate(true)
		return c

# ============================================================================
# SceneSubgraph
# ============================================================================
class SceneSubgraph extends SceneExtensible:
	var id: String = ""
	var name: String = ""
	var role: String = "group" # "group", "template", "compound"
	var template_id: Variant = null
	var template_version: Variant = null
	var level_id: Variant = null
	var transform: SceneTransform = null
	var editor: SceneEditorMeta = null
	var elements: Array = []
	var connections: Array = []
	var exposed_ports: Array = []
	var parameter_overrides: Dictionary = {}

	func _init() -> void:
		transform = SceneTransform.new()
		editor = SceneEditorMeta.new()

	static func from_dict(d: Dictionary) -> SceneSubgraph:
		var s := SceneSubgraph.new()
		s.id = str(d.get("id", ""))
		s.name = str(d.get("name", s.id))
		s.role = str(d.get("role", "group"))
		if d.has("template_id") and d["template_id"] != null:
			s.template_id = str(d["template_id"])
		if d.has("template_version") and d["template_version"] != null:
			s.template_version = str(d["template_version"])
		if d.has("level_id") and d["level_id"] != null:
			s.level_id = str(d["level_id"])
		if d.has("transform") and d["transform"] is Dictionary:
			s.transform = SceneTransform.from_dict(d["transform"])
		else:
			s.transform = SceneTransform.new()

		if d.has("editor") and d["editor"] is Dictionary:
			s.editor = SceneEditorMeta.from_dict(d["editor"])
		else:
			s.editor = null

		s.elements = d.get("elements", []).duplicate(true)
		s.connections = d.get("connections", []).duplicate(true)
		s.exposed_ports = d.get("exposed_ports", []).duplicate(true)
		s.parameter_overrides = d.get("parameter_overrides", {}).duplicate(true)

		for k in d.keys():
			var sk := str(k)
			if sk not in ["id", "name", "role", "template_id", "template_version", "level_id", "transform", "editor", "elements", "connections", "exposed_ports", "parameter_overrides"]:
				if sk == "extensions" and d["extensions"] is Dictionary:
					s.extensions["extensions"] = d["extensions"].duplicate(true)
				else:
					s.extensions[sk] = d[k]
		return s

	func to_dict() -> Dictionary:
		var out: Dictionary = {
			"id": id,
			"name": name,
			"role": role,
			"elements": elements.duplicate(true),
			"connections": connections.duplicate(true),
			"exposed_ports": exposed_ports.duplicate(true),
			"parameter_overrides": parameter_overrides.duplicate(true)
		}
		if template_id != null:
			out["template_id"] = template_id
		if template_version != null:
			out["template_version"] = template_version
		if level_id != null:
			out["level_id"] = level_id
		if transform != null:
			out["transform"] = transform.to_dict()
		if editor != null:
			out["editor"] = editor.to_dict()

		for k in extensions.keys():
			if k == "extensions":
				out["extensions"] = extensions["extensions"].duplicate(true)
			else:
				out[k] = extensions[k]
		return out

	func clone() -> SceneSubgraph:
		var c := SceneSubgraph.new()
		c.id = id
		c.name = name
		c.role = role
		c.template_id = template_id
		c.template_version = template_version
		c.level_id = level_id
		c.transform = transform.clone() if transform != null else null
		c.editor = editor.clone() if editor != null else SceneEditorMeta.new()
		c.elements = elements.duplicate(true)
		c.connections = connections.duplicate(true)
		c.exposed_ports = exposed_ports.duplicate(true)
		c.parameter_overrides = parameter_overrides.duplicate(true)
		c.extensions = extensions.duplicate(true)
		return c

# ============================================================================
# SceneDocument
# ============================================================================
class SceneDocument extends SceneExtensible:
	var spec_version: String = "1.0.0"
	var scene: Dictionary = {}
	var simulation: Dictionary = {}
	var abm_config: Variant = null
	var spatial: Dictionary = {}
	var elements: Array = []
	var connections: Array = []
	var subgraphs: Array = []
	var overlays: Array = []
	var validation_metadata: Dictionary = {}

	static func from_dict(d: Dictionary) -> SceneDocument:
		var doc := SceneDocument.new()
		doc.spec_version = str(d.get("spec_version", "1.0.0"))
		doc.scene = d.get("scene", {}).duplicate(true)
		doc.simulation = d.get("simulation", {}).duplicate(true)
		
		if d.has("abm_config"):
			doc.abm_config = d["abm_config"].duplicate(true) if d["abm_config"] is Dictionary else d["abm_config"]
		if d.has("spatial") and d["spatial"] is Dictionary:
			doc.spatial = d["spatial"].duplicate(true)

		var raw_elems = d.get("elements", [])
		if raw_elems is Array:
			for e in raw_elems:
				if e is Dictionary:
					doc.elements.append(SceneElement.from_dict(e))

		var raw_conns = d.get("connections", [])
		if raw_conns is Array:
			for c in raw_conns:
				if c is Dictionary:
					doc.connections.append(SceneConnection.from_dict(c))

		var raw_subs = d.get("subgraphs", [])
		if raw_subs is Array:
			for s in raw_subs:
				if s is Dictionary:
					doc.subgraphs.append(SceneSubgraph.from_dict(s))
				elif s is SceneSubgraph:
					doc.subgraphs.append(s.clone())
				else:
					doc.subgraphs.append(s)

		doc.overlays = d.get("overlays", []).duplicate(true)
		doc.validation_metadata = d.get("validation_metadata", {}).duplicate(true)

		for k in d.keys():
			var sk := str(k)
			if sk not in ["spec_version", "scene", "simulation", "abm_config", "spatial", "elements", "connections", "subgraphs", "overlays", "validation_metadata"]:
				if sk == "extensions" and d["extensions"] is Dictionary:
					doc.extensions["extensions"] = d["extensions"].duplicate(true)
				else:
					doc.extensions[sk] = d[k]
		return doc

	func to_dict() -> Dictionary:
		var elems_arr: Array = []
		for e in elements:
			elems_arr.append(e.to_dict() if e is SceneElement else e)

		var conns_arr: Array = []
		for c in connections:
			conns_arr.append(c.to_dict() if c is SceneConnection else c)

		var subs_arr: Array = []
		for s in subgraphs:
			subs_arr.append(s.to_dict() if s is SceneSubgraph else s)

		var out: Dictionary = {
			"spec_version": spec_version,
			"scene": scene.duplicate(true),
			"simulation": simulation.duplicate(true),
			"abm_config": abm_config.duplicate(true) if abm_config is Dictionary else abm_config,
			"elements": elems_arr,
			"connections": conns_arr,
			"subgraphs": subs_arr,
			"overlays": overlays.duplicate(true),
			"validation_metadata": validation_metadata.duplicate(true)
		}
		if not spatial.is_empty():
			out["spatial"] = spatial.duplicate(true)

		for k in extensions.keys():
			if k == "extensions":
				out["extensions"] = extensions["extensions"].duplicate(true)
			else:
				out[k] = extensions[k]
		return out

	func clone() -> SceneDocument:
		var c := SceneDocument.new()
		c.spec_version = spec_version
		c.scene = scene.duplicate(true)
		c.simulation = simulation.duplicate(true)
		c.abm_config = abm_config.duplicate(true) if abm_config is Dictionary else abm_config
		c.spatial = spatial.duplicate(true)
		for e in elements:
			c.elements.append(e.clone() if e is SceneElement else e)
		for conn in connections:
			c.connections.append(conn.clone() if conn is SceneConnection else conn)
		for s in subgraphs:
			c.subgraphs.append(s.clone() if s is SceneSubgraph else s)
		c.overlays = overlays.duplicate(true)
		c.validation_metadata = validation_metadata.duplicate(true)
		c.extensions = extensions.duplicate(true)
		return c

# ============================================================================
# Static Extension & Metadata Helpers
# ============================================================================
static func get_extension(obj: Variant, key: String, default_val: Variant = null) -> Variant:
	if obj == null:
		return default_val
	if obj is SceneExtensible:
		return obj.get_extension(key, default_val)
	if obj is Dictionary:
		if obj.has(key):
			return obj[key]
		if obj.has("extensions") and obj["extensions"] is Dictionary and obj["extensions"].has(key):
			return obj["extensions"][key]
	return default_val

static func set_extension(obj: Variant, key: String, value: Variant) -> void:
	if obj == null:
		return
	if obj is SceneExtensible:
		obj.set_extension(key, value)
	elif obj is Dictionary:
		obj[key] = value

static func has_extension(obj: Variant, key: String) -> bool:
	if obj == null:
		return false
	if obj is SceneExtensible:
		return obj.has_extension(key)
	if obj is Dictionary:
		if obj.has(key):
			return true
		if obj.has("extensions") and obj["extensions"] is Dictionary:
			return obj["extensions"].has(key)
	return false

static func delete_extension(obj: Variant, key: String) -> Variant:
	if obj == null:
		return null
	if obj is SceneExtensible:
		return obj.delete_extension(key)
	if obj is Dictionary:
		if obj.has(key):
			var val = obj[key]
			obj.erase(key)
			return val
		if obj.has("extensions") and obj["extensions"] is Dictionary and obj["extensions"].has(key):
			var val = obj["extensions"][key]
			obj["extensions"].erase(key)
			return val
	return null

static func get_extension_path(obj: Variant, path: String, default_val: Variant = null) -> Variant:
	if obj == null:
		return default_val
	if obj is SceneExtensible:
		return obj.get_extension_path(path, default_val)
	if obj is Dictionary:
		var dummy := SceneExtensible.new()
		dummy.extensions = obj
		return dummy.get_extension_path(path, default_val)
	return default_val

static func set_extension_path(obj: Variant, path: String, value: Variant) -> void:
	if obj == null:
		return
	if obj is SceneExtensible:
		obj.set_extension_path(path, value)
	elif obj is Dictionary:
		var dummy := SceneExtensible.new()
		dummy.extensions = obj
		dummy.set_extension_path(path, value)

static func list_extensions(obj: Variant) -> Array:
	if obj == null:
		return []
	if obj is SceneExtensible:
		return obj.list_extensions()
	if obj is Dictionary:
		var dummy := SceneExtensible.new()
		dummy.extensions = obj
		return dummy.list_extensions()
	return []

