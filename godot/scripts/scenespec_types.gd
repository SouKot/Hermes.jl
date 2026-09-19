class_name SimVizSceneTypes
extends RefCounted

# ============================================================================
# SceneTransform
# ============================================================================
class SceneTransform extends RefCounted:
	var position: Vector3 = Vector3.ZERO
	var rotation: Vector3 = Vector3.ZERO
	var scale: Vector3 = Vector3.ONE

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
# SceneEditorMeta
# ============================================================================
class SceneEditorMeta extends RefCounted:
	var graph_position: Vector2 = Vector2.ZERO
	var collapsed: bool = false
	var color: String = ""
	var notes: String = ""
	var extensions: Dictionary = {}

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
class ScenePort extends RefCounted:
	var id: String = ""
	var name: String = ""
	var direction: String = "input"
	var kind: String = "flow"
	var data_type: String = "entity"
	var cardinality: String = "many"
	var required: bool = true
	var unit: String = ""
	var description: String = ""
	var extensions: Dictionary = {}

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
class SceneLevel extends RefCounted:
	var id: String = ""
	var name: String = ""
	var elevation: float = 0.0
	var default_height: float = 3.0
	var visible: bool = true
	var extensions: Dictionary = {}

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
class SceneConnection extends RefCounted:
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
	var extensions: Dictionary = {}

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
		c.condition = condition
		c.latency = latency
		c.capacity = capacity
		c.extensions = extensions.duplicate(true)
		return c

# ============================================================================
# SceneElement
# ============================================================================
class SceneElement extends RefCounted:
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
	var extensions: Dictionary = {}

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
# SceneDocument
# ============================================================================
class SceneDocument extends RefCounted:
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
	var extensions: Dictionary = {}

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

		doc.subgraphs = d.get("subgraphs", []).duplicate(true)
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

		var out: Dictionary = {
			"spec_version": spec_version,
			"scene": scene.duplicate(true),
			"simulation": simulation.duplicate(true),
			"abm_config": abm_config.duplicate(true) if abm_config is Dictionary else abm_config,
			"elements": elems_arr,
			"connections": conns_arr,
			"subgraphs": subgraphs.duplicate(true),
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
		c.subgraphs = subgraphs.duplicate(true)
		c.overlays = overlays.duplicate(true)
		c.validation_metadata = validation_metadata.duplicate(true)
		c.extensions = extensions.duplicate(true)
		return c

