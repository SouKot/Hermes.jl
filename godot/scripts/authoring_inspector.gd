# authoring_inspector.gd
# Schema-driven Property Inspector for SceneSpec simulation authoring in Godot 4.
class_name SimVizAuthoringInspector
extends ScrollContainer

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const Catalog := preload("res://scripts/authoring_catalog.gd")

signal duplicate_requested(element_id: String)
signal delete_requested(element_id: String)
signal rule_builder_requested(conn_id: String)
signal open_floating_requested(element_id: String, screen_pos: Vector2)

const PANEL_BG := Color("#131d2a")
const SECTION_BG := Color("#182333")
const BORDER := Color("#243347")
const TEXT := Color("#e2e8f0")
const MUTED := Color("#94a3b8")
const ACCENT := Color("#52c7a5")
const LIVE_COLOR := Color("#2ecc71")
const RESTART_COLOR := Color("#f39c12")
const DANGER := Color("#e74c3c")

var doc_store: DocumentStore
var catalog: Catalog
var is_sim_running: bool = false

var _container: VBoxContainer
var _spin_px: SpinBox = null
var _spin_py: SpinBox = null
var _spin_pz: SpinBox = null
var _spin_rot: SpinBox = null

func _init(p_store: DocumentStore = null, p_catalog: Catalog = null) -> void:
	doc_store = p_store
	catalog = p_catalog if p_catalog != null else Catalog.new()
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	_container = VBoxContainer.new()
	_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_container.add_theme_constant_override("separation", 8)
	add_child(_container)

	if doc_store != null:
		doc_store.selection_changed.connect(_on_selection_changed)
		doc_store.document_modified.connect(_on_document_modified)
		doc_store.document_loaded.connect(func(_doc): refresh())

	refresh()

func set_simulation_running(running: bool) -> void:
	is_sim_running = running
	refresh()

func _is_multi_selection() -> bool:
	return doc_store != null and doc_store.selected_elements.size() > 1

func _on_selection_changed(_id: String, _type: String) -> void:
	refresh()

func _on_document_modified() -> void:
	if doc_store != null and doc_store.selected_type == "element" and not doc_store.selected_id.is_empty():
		var sel_elem := doc_store.get_element(doc_store.selected_id)
		if sel_elem != null and _spin_px != null and is_instance_valid(_spin_px):
			if not _spin_px.has_focus():
				_spin_px.set_value_no_signal(float(sel_elem.transform.position.x))
			if _spin_py != null and is_instance_valid(_spin_py) and not _spin_py.has_focus():
				_spin_py.set_value_no_signal(float(sel_elem.transform.position.y))
			if _spin_pz != null and is_instance_valid(_spin_pz) and not _spin_pz.has_focus():
				var pz: float = float(sel_elem.transform.position.z)
				_spin_pz.set_value_no_signal(pz)
			if _spin_rot != null and is_instance_valid(_spin_rot) and not _spin_rot.has_focus():
				_spin_rot.set_value_no_signal(fposmod(float(sel_elem.transform.rotation.z), 360.0))
			return
	refresh()

func refresh() -> void:
	if _container == null:
		return
	for child in _container.get_children():
		child.queue_free()

	_spin_rot = null

	if doc_store == null or doc_store.active_document == null:
		_render_empty_state("No active document.")
		return

	# Determine selection state
	if doc_store.selected_elements.size() > 1:
		_render_multi_selection()
	elif doc_store.selected_type == "port" and not doc_store.selected_port_id.is_empty():
		_render_port_inspection()
	elif doc_store.selected_type == "element" and not doc_store.selected_id.is_empty():
		_render_single_element(doc_store.selected_id)
	elif doc_store.selected_type == "connection" and not doc_store.selected_id.is_empty():
		_render_connection(doc_store.selected_id)
	elif doc_store.selected_type == "subgraph" and not doc_store.selected_id.is_empty():
		_render_subgraph(doc_store.selected_id)
	else:
		_render_empty_state("Select an entity block or port on the canvas to inspect properties.")

func _render_empty_state(msg: String) -> void:
	var lbl := Label.new()
	lbl.text = msg
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", MUTED)
	_container.add_child(lbl)

# ============================================================================
# 1. Single Element Inspector
# ============================================================================
func _render_single_element(elem_id: String) -> void:
	var elem: SceneTypes.SceneElement = doc_store.get_element(elem_id)
	if elem == null:
		_render_empty_state("Element '%s' not found." % elem_id)
		return

	var entry: Catalog.CatalogEntry = catalog.get_entry(elem.kind)
	var cat_name := entry.category if entry != null else "Equipment"
	var disp_name := entry.display_name if entry != null else elem.kind.capitalize()

	# 1. Header Box
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 2)

	var title_row := HBoxContainer.new()
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.color = Color(elem.editor.color) if not elem.editor.color.is_empty() else ACCENT
	title_row.add_child(dot)

	var title_lbl := Label.new()
	title_lbl.text = elem.id
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", TEXT)
	title_row.add_child(title_lbl)

	var kind_pill := Label.new()
	kind_pill.text = " [%s] " % elem.kind.to_upper()
	kind_pill.add_theme_font_size_override("font_size", 9)
	kind_pill.add_theme_color_override("font_color", MUTED)
	title_row.add_child(kind_pill)
	header.add_child(title_row)

	var sub_lbl := Label.new()
	sub_lbl.text = "%s • %s" % [disp_name, cat_name]
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", MUTED)
	header.add_child(sub_lbl)
	_container.add_child(header)

	var open_float_btn := Button.new()
	open_float_btn.text = "⛶ Open Floating Tabs (Right-Click)"
	open_float_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_float_btn.add_theme_font_size_override("font_size", 10)
	open_float_btn.add_theme_color_override("font_color", ACCENT)
	open_float_btn.pressed.connect(func():
		open_floating_requested.emit(elem.id, Vector2.ZERO)
	)
	_container.add_child(open_float_btn)

	_container.add_child(HSeparator.new())

	# 2. Primary DES Parameter (High-Level Summary)
	if entry != null and not entry.property_schemas.is_empty():
		var pri_lbl := Label.new()
		pri_lbl.text = "PRIMARY PARAMETER"
		pri_lbl.add_theme_font_size_override("font_size", 10)
		pri_lbl.add_theme_color_override("font_color", MUTED)
		_container.add_child(pri_lbl)

		# Build only the primary operational parameter (first schema in catalog)
		var primary_schema: Dictionary = entry.property_schemas[0]
		_build_property_widget(elem, primary_schema)

		var note_lbl := Label.new()
		note_lbl.text = "Right-click machine or click above for all parameters, 3D CAD & ports."
		note_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note_lbl.add_theme_font_size_override("font_size", 9)
		note_lbl.add_theme_color_override("font_color", MUTED)
		_container.add_child(note_lbl)

		_container.add_child(HSeparator.new())

	# 3. Position Coordinates (Compact X, Y, Z glance)
	var pos_lbl := Label.new()
	pos_lbl.text = "POSITION (X, Y, Z)"
	pos_lbl.add_theme_font_size_override("font_size", 10)
	pos_lbl.add_theme_color_override("font_color", MUTED)
	_container.add_child(pos_lbl)

	var px: float = float(elem.transform.position.x)
	var py: float = float(elem.transform.position.y)
	var pz: float = float(elem.transform.position.z)

	var pos_row := HBoxContainer.new()
	pos_row.add_theme_constant_override("separation", 6)
	_container.add_child(pos_row)

	_spin_px = _create_dock_mini_spin(pos_row, "X (m)", px, -500.0, 500.0, 0.5, func(v):
		elem.transform.position.x = v
		elem.editor.graph_position.x = v * 20.0
		doc_store.validate()
		doc_store.document_modified.emit()
	)
	_spin_py = _create_dock_mini_spin(pos_row, "Y (m)", py, -500.0, 500.0, 0.5, func(v):
		elem.transform.position.y = v
		elem.editor.graph_position.y = v * 20.0
		doc_store.validate()
		doc_store.document_modified.emit()
	)
	_spin_pz = _create_dock_mini_spin(pos_row, "Z (m)", pz, -500.0, 500.0, 0.5, func(v):
		elem.transform.position.z = v
		doc_store.validate()
		doc_store.document_modified.emit()
	)

	_container.add_child(HSeparator.new())

	# 4. Actions (Duplicate / Delete)
	var act_row := HBoxContainer.new()
	act_row.add_theme_constant_override("separation", 6)

	var dup_btn := Button.new()
	dup_btn.text = "Duplicate (Ctrl+D)"
	dup_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dup_btn.add_theme_font_size_override("font_size", 10)
	dup_btn.pressed.connect(func(): duplicate_requested.emit(elem.id))
	act_row.add_child(dup_btn)

	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.add_theme_font_size_override("font_size", 10)
	del_btn.add_theme_color_override("font_color", DANGER)
	del_btn.pressed.connect(func(): delete_requested.emit(elem.id))
	act_row.add_child(del_btn)

	_container.add_child(act_row)

# ============================================================================
# 2. Port Properties Inspector
# ============================================================================
func _render_port_inspection() -> void:
	var elem: SceneTypes.SceneElement = doc_store.get_element(doc_store.selected_id)
	var port: SceneTypes.ScenePort = doc_store.get_selected_port()
	if elem == null or port == null:
		_render_empty_state("Port not found.")
		return

	# Header with Back button
	var back_btn := Button.new()
	back_btn.text = "← Back to %s" % elem.id
	back_btn.add_theme_font_size_override("font_size", 10)
	back_btn.pressed.connect(func(): doc_store.select(elem.id, "element"))
	_container.add_child(back_btn)

	var header := VBoxContainer.new()
	var title_lbl := Label.new()
	title_lbl.text = "%s.%s" % [elem.id, port.id]
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", TEXT)
	header.add_child(title_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = "Kind: %s • Direction: %s" % [port.kind.capitalize(), port.direction.capitalize()]
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", MUTED)
	header.add_child(sub_lbl)
	_container.add_child(header)

	_container.add_child(HSeparator.new())

	# Buffer & Chute Capacity
	var cur_cap: int = int(port.get_extension("chute_buffer_capacity", port.get_extension("chute_capacity", 0)))
	_add_spinbox("Chute Buffer Capacity", float(cur_cap), 0.0, 100.0, 1.0, func(v):
		doc_store.update_port_properties(elem.id, port.id, {"chute_buffer_capacity": int(v), "chute_capacity": int(v)})
	)

	# Transfer Latency
	var cur_lat: float = float(port.get_extension("conveyance_handshake_latency_sec", port.get_extension("latency", 0.0)))
	_add_spinbox("Transfer Latency (s)", cur_lat, 0.0, 60.0, 0.05, func(v):
		doc_store.update_port_properties(elem.id, port.id, {"conveyance_handshake_latency_sec": v, "latency": v})
	)

	# Cardinality
	var card_row := HBoxContainer.new()
	var card_lbl := Label.new()
	card_lbl.text = "Cardinality"
	card_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_lbl.add_theme_font_size_override("font_size", 10)
	card_lbl.add_theme_color_override("font_color", MUTED)
	card_row.add_child(card_lbl)

	var card_opt := OptionButton.new()
	card_opt.add_item("Single (one)", 0)
	card_opt.add_item("Multiple (many)", 1)
	card_opt.select(1 if port.cardinality == "many" else 0)
	card_opt.add_theme_font_size_override("font_size", 10)
	card_opt.item_selected.connect(func(idx):
		var val := "many" if idx == 1 else "one"
		doc_store.update_port_properties(elem.id, port.id, {"cardinality": val})
	)
	card_row.add_child(card_opt)
	_container.add_child(card_row)

	# Disconnect action
	var disc_btn := Button.new()
	disc_btn.text = "Disconnect Port"
	disc_btn.add_theme_font_size_override("font_size", 10)
	disc_btn.add_theme_color_override("font_color", DANGER)
	disc_btn.pressed.connect(func(): doc_store.disconnect_port(elem.id, port.id))
	_container.add_child(disc_btn)

# ============================================================================
# 3. Multi-Selection Inspector (Mixed Values)
# ============================================================================
func _render_multi_selection() -> void:
	var count := doc_store.selected_elements.size()
	var header := VBoxContainer.new()
	var title_lbl := Label.new()
	title_lbl.text = "%d Entities Selected" % count
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", TEXT)
	header.add_child(title_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = "Multi-Element Batch Editing"
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", MUTED)
	header.add_child(sub_lbl)
	_container.add_child(header)

	_container.add_child(HSeparator.new())

	# Find common property keys across all selected elements
	var common_props := {}
	var first_elem: SceneTypes.SceneElement = doc_store.get_element(doc_store.selected_elements[0])
	if first_elem != null:
		var entry: Catalog.CatalogEntry = catalog.get_entry(first_elem.kind)
		if entry != null:
			for s in entry.property_schemas:
				common_props[s["key"]] = s

	for i in range(1, doc_store.selected_elements.size()):
		var eid: String = doc_store.selected_elements[i]
		var elem: SceneTypes.SceneElement = doc_store.get_element(eid)
		if elem == null:
			continue
		var entry: Catalog.CatalogEntry = catalog.get_entry(elem.kind)
		var this_keys := {}
		if entry != null:
			for s in entry.property_schemas:
				this_keys[s["key"]] = true
		for k in common_props.keys():
			if not this_keys.has(k):
				common_props.erase(k)

	if common_props.is_empty():
		var no_common := Label.new()
		no_common.text = "Selected items do not share configurable schema properties."
		no_common.add_theme_font_size_override("font_size", 10)
		no_common.add_theme_color_override("font_color", MUTED)
		_container.add_child(no_common)
	else:
		var comm_lbl := Label.new()
		comm_lbl.text = "COMMON PROPERTIES"
		comm_lbl.add_theme_font_size_override("font_size", 10)
		comm_lbl.add_theme_color_override("font_color", MUTED)
		_container.add_child(comm_lbl)

		for k in common_props.keys():
			var schema: Dictionary = common_props[k]
			_build_multi_property_widget(doc_store.selected_elements, schema)

	_container.add_child(HSeparator.new())

	# Batch Delete
	var del_btn := Button.new()
	del_btn.text = "Delete All %d Elements" % count
	del_btn.add_theme_font_size_override("font_size", 10)
	del_btn.add_theme_color_override("font_color", DANGER)
	del_btn.pressed.connect(func(): doc_store.remove_elements(doc_store.selected_elements))
	_container.add_child(del_btn)

# ============================================================================
# 4. Connection Inspector
# ============================================================================
func _render_connection(conn_id: String) -> void:
	var target_conn: SceneTypes.SceneConnection = null
	for c in doc_store.active_document.connections:
		if c.id == conn_id:
			target_conn = c
			break
	if target_conn == null:
		_render_empty_state("Connection not found.")
		return

	var header := VBoxContainer.new()
	var title_lbl := Label.new()
	title_lbl.text = "Connection: %s" % target_conn.id
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", TEXT)
	header.add_child(title_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = "%s.%s → %s.%s (%s)" % [
		target_conn.source_element, target_conn.source_port,
		target_conn.target_element, target_conn.target_port,
		target_conn.link_type.capitalize()
	]
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", MUTED)
	header.add_child(sub_lbl)
	_container.add_child(header)

	_container.add_child(HSeparator.new())

	# Condition summary / Rule builder
	var cond_lbl := Label.new()
	cond_lbl.text = "ROUTING & DISPATCH CONDITION"
	cond_lbl.add_theme_font_size_override("font_size", 10)
	cond_lbl.add_theme_color_override("font_color", MUTED)
	_container.add_child(cond_lbl)

	if target_conn.condition != null and not (target_conn.condition is Dictionary and target_conn.condition.is_empty()):
		var cond_desc := Label.new()
		cond_desc.text = JSON.stringify(target_conn.condition)
		cond_desc.add_theme_font_size_override("font_size", 10)
		cond_desc.add_theme_color_override("font_color", LIVE_COLOR)
		_container.add_child(cond_desc)
	else:
		var no_cond := Label.new()
		no_cond.text = "Unconditional (Always Active)"
		no_cond.add_theme_font_size_override("font_size", 10)
		no_cond.add_theme_color_override("font_color", MUTED)
		_container.add_child(no_cond)

	var rule_btn := Button.new()
	rule_btn.text = "Edit Condition / Rule..."
	rule_btn.add_theme_font_size_override("font_size", 10)
	rule_btn.pressed.connect(func(): rule_builder_requested.emit(target_conn.id))
	_container.add_child(rule_btn)

	var del_btn := Button.new()
	del_btn.text = "Delete Connection"
	del_btn.add_theme_font_size_override("font_size", 10)
	del_btn.add_theme_color_override("font_color", DANGER)
	del_btn.pressed.connect(func(): doc_store.remove_connection(target_conn.id))
	_container.add_child(del_btn)

# ============================================================================
# Dynamic Schema Widget Builders
# ============================================================================
func _build_property_widget(elem: SceneTypes.SceneElement, schema: Dictionary) -> void:
	var key: String = schema.get("key", "")
	var disp: String = schema.get("display_name", key.capitalize())
	var p_type: String = schema.get("type", "float")
	var unit: String = schema.get("unit", "")
	var is_live: bool = bool(schema.get("runtime_editable", false))
	var cur_val = elem.properties.get(key, schema.get("default_value"))

	# Progressive disclosure: Hide MTBF/MTTR/failure_rate when failure_model is None
	if key in ["mtbf", "mttr", "failure_rate"] and elem.properties.get("failure_model", "None") == "None":
		return

	# Live/Restart Badge Row
	var label_row := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = disp
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", TEXT)
	label_row.add_child(name_lbl)

	var badge := Label.new()
	badge.text = "[LIVE]" if is_live else "[RESTART]"
	badge.add_theme_font_size_override("font_size", 8)
	badge.add_theme_color_override("font_color", LIVE_COLOR if is_live else RESTART_COLOR)
	label_row.add_child(badge)
	_container.add_child(label_row)

	if p_type == "distribution":
		_build_distribution_editor(elem, key, cur_val, is_live)
	elif p_type == "enum":
		var opts: Array = schema.get("enum_options", schema.get("options", []))
		_build_enum_editor(elem, key, cur_val, opts, is_live)
	elif p_type == "bool":
		_build_bool_editor(elem, key, bool(cur_val), is_live)
	else:
		# Numeric scalar float / int
		var range_arr: Array = schema.get("range", [0.0, 1000.0, 0.1])
		var min_v: float = range_arr[0] if range_arr.size() >= 1 else 0.0
		var max_v: float = range_arr[1] if range_arr.size() >= 2 else 1000.0
		var step_v: float = range_arr[2] if range_arr.size() >= 3 else 0.1

		var f_val := float(cur_val) if (cur_val is float or cur_val is int) else 0.0
		var sp := _add_spinbox(unit, f_val, min_v, max_v, step_v, func(v):
			var final_val = int(v) if p_type == "int" else v
			doc_store.set_element_property(elem.id, key, final_val)
		)
		if is_sim_running and not is_live:
			sp.editable = false

func _build_multi_property_widget(elem_ids: Array, schema: Dictionary) -> void:
	var key: String = schema.get("key", "")
	var disp: String = schema.get("display_name", key.capitalize())
	var p_type: String = schema.get("type", "float")
	var unit: String = schema.get("unit", "")

	# Check for mixed values
	var first_val = null
	var is_mixed := false
	for eid in elem_ids:
		var elem := doc_store.get_element(eid)
		if elem != null:
			var v = elem.properties.get(key, null)
			if first_val == null:
				first_val = v
			elif first_val != v:
				is_mixed = true
				break

	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = disp + (" [MIXED]" if is_mixed else "")
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", RESTART_COLOR if is_mixed else TEXT)
	row.add_child(lbl)

	if is_mixed:
		var edit := LineEdit.new()
		edit.placeholder_text = "— Mixed Values —"
		edit.custom_minimum_size.x = 100
		edit.add_theme_font_size_override("font_size", 9)
		edit.text_submitted.connect(func(t: String):
			if t.is_valid_float():
				var f := t.to_float()
				var final_val = int(f) if p_type == "int" else f
				doc_store.set_elements_property_batch(elem_ids, key, final_val)
		)
		row.add_child(edit)
	else:
		var f_val: float = float(first_val) if (first_val is float or first_val is int) else 0.0
		var range_arr: Array = schema.get("range", [0.0, 1000.0, 0.1])
		var sp := SpinBox.new()
		sp.min_value = range_arr[0] if range_arr.size() >= 1 else 0.0
		sp.max_value = range_arr[1] if range_arr.size() >= 2 else 1000.0
		sp.step = range_arr[2] if range_arr.size() >= 3 else 0.1
		sp.value = f_val
		sp.suffix = unit
		sp.custom_minimum_size.x = 100
		sp.add_theme_font_size_override("font_size", 9)
		sp.value_changed.connect(func(v):
			var final_val = int(v) if p_type == "int" else v
			doc_store.set_elements_property_batch(elem_ids, key, final_val)
		)
		row.add_child(sp)

	_container.add_child(row)

func _build_distribution_editor(elem: SceneTypes.SceneElement, prop_key: String, cur_val, is_live: bool) -> void:
	var dist_map := {}
	if cur_val is Dictionary:
		dist_map = cur_val
	else:
		dist_map = {"type": "constant", "value": float(cur_val) if cur_val != null else 4.0}

	var d_type: String = str(dist_map.get("type", "constant"))

	var type_row := HBoxContainer.new()
	var type_opt := OptionButton.new()
	type_opt.add_item("Triangular (PERT)", 0)
	type_opt.add_item("Exponential (M/M/c)", 1)
	type_opt.add_item("Normal (Gaussian)", 2)
	type_opt.add_item("Uniform", 3)
	type_opt.add_item("Constant", 4)
	type_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_opt.add_theme_font_size_override("font_size", 9)

	match d_type:
		"triangular": type_opt.select(0)
		"exponential": type_opt.select(1)
		"normal": type_opt.select(2)
		"uniform": type_opt.select(3)
		_: type_opt.select(4)

	type_opt.item_selected.connect(func(idx):
		var new_map := {}
		match idx:
			0: new_map = {"type": "triangular", "min": 2.0, "mode": 4.5, "max": 7.0}
			1: new_map = {"type": "exponential", "mean": 3.0}
			2: new_map = {"type": "normal", "mean": 4.5, "std_dev": 0.8}
			3: new_map = {"type": "uniform", "min": 2.0, "max": 6.0}
			_: new_map = {"type": "constant", "value": 4.5}
		doc_store.set_element_property(elem.id, prop_key, new_map)
	)
	type_row.add_child(type_opt)
	_container.add_child(type_row)

	# Parameter Inputs
	if d_type == "triangular":
		var p_row := HBoxContainer.new()
		p_row.add_theme_constant_override("separation", 2)
		_add_mini_spin(p_row, "Min", float(dist_map.get("min", 2.0)), func(v):
			dist_map["min"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_add_mini_spin(p_row, "Mode", float(dist_map.get("mode", 4.5)), func(v):
			dist_map["mode"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_add_mini_spin(p_row, "Max", float(dist_map.get("max", 7.0)), func(v):
			dist_map["max"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_container.add_child(p_row)
	elif d_type == "exponential":
		var p_row := HBoxContainer.new()
		_add_mini_spin(p_row, "Mean (s)", float(dist_map.get("mean", 3.0)), func(v):
			dist_map["mean"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_container.add_child(p_row)
	elif d_type == "normal":
		var p_row := HBoxContainer.new()
		_add_mini_spin(p_row, "Mean (μ)", float(dist_map.get("mean", 4.5)), func(v):
			dist_map["mean"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_add_mini_spin(p_row, "Std (σ)", float(dist_map.get("std_dev", 0.8)), func(v):
			dist_map["std_dev"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_container.add_child(p_row)
	else:
		var p_row := HBoxContainer.new()
		_add_mini_spin(p_row, "Value (s)", float(dist_map.get("value", 4.5)), func(v):
			dist_map["value"] = v
			doc_store.set_element_property(elem.id, prop_key, dist_map)
		)
		_container.add_child(p_row)

	# Sparkline Preview
	var sparkline := DistributionSparkline.new(dist_map)
	sparkline.custom_minimum_size = Vector2(100, 24)
	_container.add_child(sparkline)

func _build_enum_editor(elem: SceneTypes.SceneElement, prop_key: String, cur_val, options: Array, is_live: bool) -> void:
	if options.is_empty():
		return

	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_theme_font_size_override("font_size", 9)
	_container.add_child(opt)

	var sel_idx := -1
	for i in range(options.size()):
		var item = options[i]
		var val_str: String = item.get("value", "") if item is Dictionary else str(item)
		var label_str: String = item.get("label", val_str) if item is Dictionary else str(item)
		opt.add_item(label_str, i)
		if val_str == str(cur_val):
			sel_idx = i

	if opt.item_count > 0:
		if sel_idx < 0:
			sel_idx = 0
		opt.selected = sel_idx

	opt.item_selected.connect(func(idx):
		if idx >= 0 and idx < options.size():
			var sel_item = options[idx]
			var val_str: String = sel_item.get("value", "") if sel_item is Dictionary else str(sel_item)
			doc_store.set_element_property(elem.id, prop_key, val_str)
	)
	if is_sim_running and not is_live:
		opt.disabled = true

func _build_bool_editor(elem: SceneTypes.SceneElement, prop_key: String, cur_val: bool, is_live: bool) -> void:
	var chk := CheckBox.new()
	chk.text = "Enabled"
	chk.button_pressed = cur_val
	chk.add_theme_font_size_override("font_size", 10)
	chk.toggled.connect(func(v: bool):
		doc_store.set_element_property(elem.id, prop_key, v)
	)
	if is_sim_running and not is_live:
		chk.disabled = true
	_container.add_child(chk)

# ============================================================================
# Helpers
# ============================================================================
func _add_spinbox(label_text: String, current_val: float, min_val: float, max_val: float, step_val: float, on_change: Callable) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", MUTED)
	row.add_child(lbl)

	var sp := SpinBox.new()
	sp.min_value = min_val
	sp.max_value = max_val
	sp.step = step_val
	sp.value = current_val
	sp.custom_minimum_size.x = 90
	sp.add_theme_font_size_override("font_size", 9)
	sp.value_changed.connect(on_change)
	row.add_child(sp)

	_container.add_child(row)
	return sp

func _add_mini_spin(parent: Control, label: String, val: float, on_change: Callable) -> void:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 8)
	l.add_theme_color_override("font_color", MUTED)
	vbox.add_child(l)

	var sp := SpinBox.new()
	sp.min_value = 0.05
	sp.max_value = 3600.0
	sp.step = 0.1
	sp.value = val
	sp.add_theme_font_size_override("font_size", 8)
	sp.value_changed.connect(on_change)
	vbox.add_child(sp)
	parent.add_child(vbox)

func _create_dock_mini_spin(parent: Control, label_text: String, val: float, min_v: float, max_v: float, step_v: float, on_change: Callable) -> SpinBox:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := Label.new()
	l.text = label_text
	l.add_theme_font_size_override("font_size", 8)
	l.add_theme_color_override("font_color", MUTED)
	vbox.add_child(l)

	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = step_v
	sp.value = val
	sp.add_theme_font_size_override("font_size", 8)
	sp.value_changed.connect(on_change)
	vbox.add_child(sp)
	parent.add_child(vbox)
	return sp

# ============================================================================
# Sparkline Visualizer Inner Class
# ============================================================================
class DistributionSparkline extends Control:
	var dist_map: Dictionary
	var dist_data: Dictionary:
		get: return dist_map
		set(v):
			dist_map = v
			queue_redraw()

	func _init(p_map: Dictionary = {}) -> void:
		dist_map = p_map
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_distribution(d: Dictionary) -> void:
		dist_map = d
		queue_redraw()

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		draw_rect(rect, Color("#09111be0"), true)
		draw_rect(rect, Color("#243347"), false, 1.0)

		var d_type: String = str(dist_map.get("type", dist_map.get("distribution", "constant")))
		var points: PackedVector2Array = []
		var steps := 24
		var h := size.y - 4.0
		var w := size.x - 4.0

		for i in range(steps + 1):
			var t: float = float(i) / float(steps)
			var y_norm: float = 0.0
			match d_type:
				"triangular":
					# peak at ~40%
					if t < 0.4:
						y_norm = t / 0.4
					else:
						y_norm = (1.0 - t) / 0.6
				"exponential":
					y_norm = exp(-3.0 * t)
				"normal":
					var z := (t - 0.5) * 4.0
					y_norm = exp(-0.5 * z * z)
				"uniform":
					y_norm = 0.7
				_:
					y_norm = 1.0 if abs(t - 0.5) < 0.1 else 0.0

			var pt := Vector2(2.0 + t * w, size.y - 2.0 - (y_norm * h * 0.85))
			points.append(pt)

		if points.size() >= 2:
			for i in range(points.size() - 1):
				draw_line(points[i], points[i + 1], Color("#52c7a5"), 1.2)

# ============================================================================
# Subgraph / Template Inspector
# ============================================================================
func _render_subgraph(sub_id: String) -> void:
	var sub: SceneTypes.SceneSubgraph = doc_store.get_subgraph(sub_id)
	if sub == null:
		_render_empty_state("Subgraph '%s' not found." % sub_id)
		return

	# 1. Header Box
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 2)

	var title_row := HBoxContainer.new()
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.color = Color("#1abc9c") if sub.role == "compound" else Color("#9b59b6")
	title_row.add_child(dot)

	var title_lbl := Label.new()
	title_lbl.text = sub.id
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", TEXT)
	title_row.add_child(title_lbl)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(spacer)

	var role_pill := Label.new()
	role_pill.text = " [%s] " % sub.role.to_upper()
	role_pill.add_theme_font_size_override("font_size", 9)
	role_pill.add_theme_color_override("font_color", dot.color)
	title_row.add_child(role_pill)

	header.add_child(title_row)

	var sub_name_lbl := Label.new()
	sub_name_lbl.text = sub.name
	sub_name_lbl.add_theme_font_size_override("font_size", 10)
	sub_name_lbl.add_theme_color_override("font_color", MUTED)
	header.add_child(sub_name_lbl)

	_container.add_child(header)
	_container.add_child(HSeparator.new())

	# 2. Action Buttons (Drill Down, Detach, Ungroup)
	var actions_box := VBoxContainer.new()
	actions_box.add_theme_constant_override("separation", 6)

	var btn_drill := Button.new()
	btn_drill.text = "⤸ Drill Down (Edit Internals)"
	btn_drill.add_theme_font_size_override("font_size", 10)
	btn_drill.add_theme_color_override("font_color", ACCENT)
	btn_drill.pressed.connect(func(): doc_store.enter_subgraph_scope(sub.id))
	actions_box.add_child(btn_drill)

	if sub.role == "compound" and sub.template_id != null:
		var btn_detach := Button.new()
		btn_detach.text = "✂ Detach from Template"
		btn_detach.tooltip_text = "Convert to independent group with full parameter independence"
		btn_detach.add_theme_font_size_override("font_size", 10)
		btn_detach.pressed.connect(func(): doc_store.detach_subgraph(sub.id))
		actions_box.add_child(btn_detach)

	var btn_ungroup := Button.new()
	btn_ungroup.text = "✕ Ungroup Elements"
	btn_ungroup.tooltip_text = "Dissolve group boundary and return elements to root scope"
	btn_ungroup.add_theme_font_size_override("font_size", 10)
	btn_ungroup.pressed.connect(func(): doc_store.ungroup(sub.id))
	actions_box.add_child(btn_ungroup)

	_container.add_child(actions_box)
	_container.add_child(HSeparator.new())

	# 3. Hierarchy & Lineage
	var meta_hdr := Label.new()
	meta_hdr.text = "TEMPLATE & HIERARCHY"
	meta_hdr.add_theme_font_size_override("font_size", 10)
	meta_hdr.add_theme_color_override("font_color", MUTED)
	_container.add_child(meta_hdr)

	var meta_vbox := VBoxContainer.new()
	meta_vbox.add_theme_constant_override("separation", 4)

	var tmpl_str: String = "None (Independent Group)"
	if sub.template_id != null:
		tmpl_str = "%s (v%s)" % [str(sub.template_id), str(sub.template_version)]
	var tmpl_lbl := Label.new()
	tmpl_lbl.text = "Template: %s" % tmpl_str
	tmpl_lbl.add_theme_font_size_override("font_size", 10)
	meta_vbox.add_child(tmpl_lbl)

	var count_lbl := Label.new()
	count_lbl.text = "Members: %d Elements, %d Connections" % [sub.elements.size(), sub.connections.size()]
	count_lbl.add_theme_font_size_override("font_size", 10)
	meta_vbox.add_child(count_lbl)
	_container.add_child(meta_vbox)

	_container.add_child(HSeparator.new())

	# 4. Transform (Position)
	var trans_lbl := Label.new()
	trans_lbl.text = "TRANSFORM (POSITION)"
	trans_lbl.add_theme_font_size_override("font_size", 10)
	trans_lbl.add_theme_color_override("font_color", MUTED)
	_container.add_child(trans_lbl)

	var pos_row := HBoxContainer.new()
	pos_row.add_theme_constant_override("separation", 6)
	_container.add_child(pos_row)

	_create_dock_mini_spin(pos_row, "X (m)", sub.transform.position.x, -500.0, 500.0, 0.5, func(v):
		var p := sub.transform.position
		p.x = v
		doc_store.set_subgraph_position(sub.id, p)
	)
	_create_dock_mini_spin(pos_row, "Y (m)", sub.transform.position.y, -500.0, 500.0, 0.5, func(v):
		var p := sub.transform.position
		p.y = v
		doc_store.set_subgraph_position(sub.id, p)
	)
	_create_dock_mini_spin(pos_row, "Z (m)", sub.transform.position.z, -500.0, 500.0, 0.5, func(v):
		var p := sub.transform.position
		p.z = v
		doc_store.set_subgraph_position(sub.id, p)
	)

	# 5. Boundary Ports
	if not sub.exposed_ports.is_empty():
		_container.add_child(HSeparator.new())
		var ports_lbl := Label.new()
		ports_lbl.text = "EXPOSED BOUNDARY PORTS (%d)" % sub.exposed_ports.size()
		ports_lbl.add_theme_font_size_override("font_size", 10)
		ports_lbl.add_theme_color_override("font_color", MUTED)
		_container.add_child(ports_lbl)

		var ports_vbox := VBoxContainer.new()
		ports_vbox.add_theme_constant_override("separation", 3)
		for ep in sub.exposed_ports:
			var p_row := HBoxContainer.new()
			var p_badge := Label.new()
			var p_dir: String = str(ep.get("direction", "input")).to_upper()
			var p_kind: String = str(ep.get("kind", "flow")).to_upper()
			p_badge.text = "[%s %s]" % [p_kind, p_dir]
			p_badge.add_theme_font_size_override("font_size", 9)
			p_badge.add_theme_color_override("font_color", ACCENT)
			p_row.add_child(p_badge)

			var p_name_lbl := Label.new()
			p_name_lbl.text = str(ep.get("name", ep.get("id", "")))
			p_name_lbl.add_theme_font_size_override("font_size", 10)
			p_row.add_child(p_name_lbl)

			ports_vbox.add_child(p_row)
		_container.add_child(ports_vbox)

	# 6. Parameter Overrides
	if not sub.parameter_overrides.is_empty() or sub.role == "compound":
		_container.add_child(HSeparator.new())
		var ov_lbl := Label.new()
		ov_lbl.text = "PARAMETER OVERRIDES"
		ov_lbl.add_theme_font_size_override("font_size", 10)
		ov_lbl.add_theme_color_override("font_color", MUTED)
		_container.add_child(ov_lbl)

		var ov_vbox := VBoxContainer.new()
		ov_vbox.add_theme_constant_override("separation", 4)
		if sub.parameter_overrides.is_empty():
			var empty_ov := Label.new()
			empty_ov.text = "No active overrides. Default template properties used."
			empty_ov.add_theme_font_size_override("font_size", 9)
			empty_ov.add_theme_color_override("font_color", MUTED)
			ov_vbox.add_child(empty_ov)
		else:
			for k in sub.parameter_overrides.keys():
				var r := HBoxContainer.new()
				var k_lbl := Label.new()
				k_lbl.text = str(k) + ":"
				k_lbl.add_theme_font_size_override("font_size", 10)
				r.add_child(k_lbl)

				var v_edit := LineEdit.new()
				v_edit.text = str(sub.parameter_overrides[k])
				v_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				v_edit.text_submitted.connect(func(new_text):
					var val: Variant = new_text
					if new_text.is_valid_float():
						val = new_text.to_float()
					elif new_text.is_valid_int():
						val = new_text.to_int()
					elif new_text.to_lower() == "true":
						val = true
					elif new_text.to_lower() == "false":
						val = false
					doc_store.set_subgraph_override(sub.id, str(k), val)
				)
				r.add_child(v_edit)
				ov_vbox.add_child(r)
		_container.add_child(ov_vbox)
