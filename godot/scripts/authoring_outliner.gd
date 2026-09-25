# authoring_outliner.gd
# Model Outliner: shows scene element hierarchy and live entity sub-items from telemetry.
extends VBoxContainer

const DocumentStore := preload("res://scripts/authoring_document_store.gd")

# Colors
const CLR_SOURCE   := Color("#f39c12")  # amber
const CLR_QUEUE    := Color("#3498db")  # blue
const CLR_SERVER   := Color("#2ecc71")  # green
const CLR_CONVEYOR := Color("#9b59b6")  # purple
const CLR_SINK     := Color("#e74c3c")  # red
const CLR_OTHER    := Color("#95a5a6")  # grey

# Element-kind icons (text prefix)
const ICON_SOURCE   := "▶ "
const ICON_QUEUE    := "⟨ "
const ICON_SERVER   := "⚙ "
const ICON_CONVEYOR := "→ "
const ICON_SINK     := "■ "
const ICON_ENTITY   := "  📦 "
const ICON_SERVING  := "  ⚙ "

signal element_clicked(element_id: String)
signal entity_selected(entity_id: String)

var _doc_store: DocumentStore = null
var _tree: Tree = null
var _last_snapshot: Dictionary = {}  # element_id -> metrics dict
var _last_entities: Array = []       # array of entity dicts from telemetry

func _ready() -> void:
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = false
	_tree.select_mode = Tree.SELECT_SINGLE
	_tree.item_selected.connect(_on_item_selected)
	add_child(_tree)

func _notification(what: int) -> void:
	# When the Outliner tab becomes visible, immediately rebuild from cached data
	if what == NOTIFICATION_VISIBILITY_CHANGED and visible:
		rebuild(_last_entities)


func setup(doc_store: DocumentStore) -> void:
	_doc_store = doc_store
	if _doc_store != null:
		_doc_store.document_loaded.connect(func(_doc): rebuild(_last_entities))
		_doc_store.document_modified.connect(func(): rebuild(_last_entities))
	rebuild([])

func feed_telemetry(elements_by_id: Dictionary, entities: Array) -> void:
	_last_snapshot = elements_by_id
	_last_entities = entities
	# Only do the expensive Tree rebuild when the outliner tab is actually visible
	if visible:
		rebuild(entities)

func rebuild(entities: Array) -> void:
	if _tree == null:
		return
	_tree.clear()

	if _doc_store == null or _doc_store.active_document == null:
		var empty_root := _tree.create_item()
		empty_root.set_text(0, "(No document loaded)")
		return

	var doc = _doc_store.active_document
	var doc_name: String = "Model"
	if doc.scene is Dictionary:
		doc_name = str(doc.scene.get("name", "Model"))

	# Root item = document name
	var root := _tree.create_item()
	root.set_text(0, "🗂 " + doc_name)
	root.set_selectable(0, false)

	# Group entities by element_id
	var ents_by_elem: Dictionary = {}  # element_id -> Array[dict]
	for ent in entities:
		if ent is Dictionary:
			# Julia sends element ref as "current_location" (top-level) or
			# "element_id" inside properties (added by telemetry_adapter B-1c)
			var eid: String = str(ent.get("element_id",
				ent.get("current_location",
				ent.get("element", ""))))
			# Also check properties dict if top-level key missing
			if eid.is_empty() and ent.has("properties") and ent["properties"] is Dictionary:
				eid = str(ent["properties"].get("element_id", ""))
			if not eid.is_empty():
				if not ents_by_elem.has(eid):
					ents_by_elem[eid] = []
				ents_by_elem[eid].append(ent)

	# Add each element as a tree item
	for elem in _doc_store.get_scoped_elements():
		var kind: String = str(elem.kind)
		var icon_prefix: String = _icon_for_kind(kind)
		var clr: Color = _color_for_kind(kind)
		var elem_label: String = icon_prefix + (elem.name if not elem.name.is_empty() else elem.id)

		var elem_item := _tree.create_item(root)
		elem_item.set_text(0, elem_label)
		elem_item.set_custom_color(0, clr)
		elem_item.set_metadata(0, {"type": "element", "id": elem.id})

		# Live metrics badge
		if _last_snapshot.has(elem.id):
			var metrics: Dictionary = _last_snapshot[elem.id].get("metrics", {})
			var badge: String = str(metrics.get("badge", ""))
			if not badge.is_empty():
				elem_item.set_text(0, elem_label + "  " + badge)

		# Live entity sub-items (queue/server entities)
		if ents_by_elem.has(elem.id):
			for ent in ents_by_elem[elem.id]:
				var ent_id: String = str(ent.get("id", ""))
				var props: Dictionary = ent.get("properties", {})
				var in_srv: bool = bool(props.get("in_service", false))
				var ent_label: String
				if in_srv:
					ent_label = ICON_SERVING + ent_id.replace("ent_", "#") + " | in service"
				else:
					ent_label = ICON_ENTITY + ent_id.replace("ent_", "#") + " | waiting"
				var ent_item := _tree.create_item(elem_item)
				ent_item.set_text(0, ent_label)
				ent_item.set_custom_color(0, Color("#7f8c8d"))
				ent_item.set_metadata(0, {"type": "entity", "id": ent_id, "element_id": elem.id})

func _on_item_selected() -> void:
	var selected := _tree.get_selected()
	if selected == null:
		return
	var meta = selected.get_metadata(0)
	if meta is Dictionary:
		if meta.get("type") == "element":
			element_clicked.emit(str(meta.get("id", "")))
		elif meta.get("type") == "entity":
			entity_selected.emit(str(meta.get("id", "")))

func _icon_for_kind(kind: String) -> String:
	match kind:
		"source": return ICON_SOURCE
		"queue": return ICON_QUEUE
		"server": return ICON_SERVER
		"conveyor": return ICON_CONVEYOR
		"sink": return ICON_SINK
		_: return ""

func _color_for_kind(kind: String) -> Color:
	match kind:
		"source": return CLR_SOURCE
		"queue": return CLR_QUEUE
		"server": return CLR_SERVER
		"conveyor": return CLR_CONVEYOR
		"sink": return CLR_SINK
		_: return CLR_OTHER
