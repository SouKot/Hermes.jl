# authoring_channel_popup.gd
# Screen-space scrollable & filterable multi-wire bus channel pop-up pill for Phase 7G.
class_name SimVizAuthoringChannelPopup
extends PanelContainer

const DocumentStore := preload("res://scripts/authoring_document_store.gd")
const SceneTypes := preload("res://scripts/scenespec_types.gd")

signal channel_hovered(conn_id: String)
signal channel_deleted(conn_id: String)
signal channel_reordered(conn_id: String, new_idx: int)
signal disconnect_all_requested(elem_id: String, port_id: String)

var doc_store: DocumentStore = null
var current_element_id: String = ""
var current_port_id: String = ""
var current_is_output: bool = true
var filter_query: String = ""

var _title_label: Label = null
var _search_input: LineEdit = null
var _scroll: ScrollContainer = null
var _rows_vbox: VBoxContainer = null
var _btn_disconnect_all: Button = null

func _init() -> void:
	visible = false
	z_index = 60
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(268, 120)

	var style := StyleBoxFlat.new()
	style.bg_color = Color("#0f1823f5")
	style.border_color = Color("#2ecc71")
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	add_theme_stylebox_override("panel", style)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	add_child(root_vbox)

	# Header Row
	var header_hbox := HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 6)
	root_vbox.add_child(header_hbox)

	_title_label = Label.new()
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.add_theme_font_size_override("font_size", 11)
	_title_label.add_theme_color_override("font_color", Color("#52c7a5"))
	header_hbox.add_child(_title_label)

	var btn_close := Button.new()
	btn_close.text = "✕"
	btn_close.flat = true
	btn_close.add_theme_font_size_override("font_size", 10)
	btn_close.pressed.connect(func(): close_popup())
	header_hbox.add_child(btn_close)

	# Filter Search Input (shown when N > 6 or when filter is non-empty)
	_search_input = LineEdit.new()
	_search_input.placeholder_text = "🔍 Filter target entity or #channel..."
	_search_input.clear_button_enabled = true
	_search_input.add_theme_font_size_override("font_size", 10)
	_search_input.text_changed.connect(func(new_txt: String):
		filter_query = new_txt.strip_edges()
		rebuild_rows()
	)
	root_vbox.add_child(_search_input)

	# Scrollable Channel List (capped at 8 visible rows ~220px)
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(250, 180)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_vbox.add_child(_scroll)

	_rows_vbox = VBoxContainer.new()
	_rows_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_vbox.add_theme_constant_override("separation", 3)
	_scroll.add_child(_rows_vbox)

	# Footer Row
	var footer_hbox := HBoxContainer.new()
	footer_hbox.add_theme_constant_override("separation", 6)
	root_vbox.add_child(footer_hbox)

	_btn_disconnect_all = Button.new()
	_btn_disconnect_all.text = "Disconnect All Channels"
	_btn_disconnect_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_disconnect_all.add_theme_font_size_override("font_size", 10)
	_btn_disconnect_all.add_theme_color_override("font_color", Color("#ff8888"))
	_btn_disconnect_all.pressed.connect(func():
		if doc_store != null and not current_element_id.is_empty() and not current_port_id.is_empty():
			doc_store.disconnect_port(current_element_id, current_port_id)
			disconnect_all_requested.emit(current_element_id, current_port_id)
			close_popup()
	)
	footer_hbox.add_child(_btn_disconnect_all)

func open_for_port(p_store: DocumentStore, elem_id: String, port_id: String, is_output: bool, screen_pos: Vector2) -> void:
	doc_store = p_store
	current_element_id = elem_id
	current_port_id = port_id
	current_is_output = is_output
	filter_query = ""
	if _search_input != null:
		_search_input.text = ""
	position = screen_pos
	visible = true
	rebuild_rows()

func close_popup() -> void:
	if visible:
		visible = false
		channel_hovered.emit("")

func get_visible_channel_rows() -> Array:
	var res: Array = []
	if _rows_vbox == null:
		return res
	for child in _rows_vbox.get_children():
		if child.has_meta("channel_info"):
			res.append(child.get_meta("channel_info"))
	return res

func rebuild_rows() -> void:
	if _rows_vbox == null:
		return
	for child in _rows_vbox.get_children():
		_rows_vbox.remove_child(child)
		child.queue_free()

	if doc_store == null or current_element_id.is_empty() or current_port_id.is_empty():
		return

	var conns := doc_store.get_port_connections(current_element_id, current_port_id, current_is_output)
	var total_n := conns.size()
	var dir_label := "OUT" if current_is_output else "IN"
	if _title_label != null:
		_title_label.text = "%s · %s (%s ×%d)" % [current_element_id, current_port_id, dir_label, total_n]

	if _search_input != null:
		_search_input.visible = (total_n > 6) or (not filter_query.is_empty())

	if _scroll != null:
		var visible_count: int = clampi(total_n, 1, 8)
		_scroll.custom_minimum_size.y = float(visible_count * 26 + 6)

	var q_lower := filter_query.to_lower()
	for i in range(total_n):
		var c: SceneTypes.SceneConnection = conns[i]
		var ch_num: int = i + 1
		var peer_elem_id: String = c.target_element if current_is_output else c.source_element
		var peer_port_id: String = c.target_port if current_is_output else c.source_port
		var peer_name := peer_elem_id
		var peer_elem := doc_store.get_element(peer_elem_id)
		if peer_elem != null and not peer_elem.name.is_empty():
			peer_name = peer_elem.name

		var arrow_str := "→" if current_is_output else "←"
		var label_text := "#%d  %s %s (%s)" % [ch_num, arrow_str, peer_name, peer_port_id]
		if not q_lower.is_empty():
			var hay := ("%d #%d %s %s %s" % [ch_num, ch_num, peer_elem_id, peer_name, peer_port_id]).to_lower()
			if not hay.contains(q_lower):
				continue

		var row_panel := PanelContainer.new()
		var r_style := StyleBoxFlat.new()
		r_style.bg_color = Color("#162332")
		r_style.set_corner_radius_all(3)
		r_style.content_margin_left = 6
		r_style.content_margin_right = 4
		r_style.content_margin_top = 2
		r_style.content_margin_bottom = 2
		row_panel.add_theme_stylebox_override("panel", r_style)
		row_panel.set_meta("channel_info", {
			"channel": ch_num,
			"conn_id": c.id,
			"peer_element": peer_elem_id,
			"peer_port": peer_port_id
		})

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		row_panel.add_child(row)

		var lbl := Label.new()
		lbl.text = label_text
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.add_theme_color_override("font_color", Color("#e5edf5"))
		row.add_child(lbl)

		var conn_id_capt: String = c.id
		row_panel.mouse_entered.connect(func(): channel_hovered.emit(conn_id_capt))
		row_panel.mouse_exited.connect(func(): channel_hovered.emit(""))

		# Move Up [▲]
		var btn_up := Button.new()
		btn_up.text = "▲"
		btn_up.disabled = (ch_num <= 1)
		btn_up.flat = true
		btn_up.add_theme_font_size_override("font_size", 9)
		btn_up.pressed.connect(func():
			if doc_store != null:
				doc_store.reorder_port_channel(current_element_id, current_port_id, current_is_output, ch_num, ch_num - 1)
				channel_reordered.emit(conn_id_capt, ch_num - 1)
				rebuild_rows()
		)
		row.add_child(btn_up)

		# Move Down [▼]
		var btn_dn := Button.new()
		btn_dn.text = "▼"
		btn_dn.disabled = (ch_num >= total_n)
		btn_dn.flat = true
		btn_dn.add_theme_font_size_override("font_size", 9)
		btn_dn.pressed.connect(func():
			if doc_store != null:
				doc_store.reorder_port_channel(current_element_id, current_port_id, current_is_output, ch_num, ch_num + 1)
				channel_reordered.emit(conn_id_capt, ch_num + 1)
				rebuild_rows()
		)
		row.add_child(btn_dn)

		# Delete Channel [✕]
		var btn_del := Button.new()
		btn_del.text = "✕"
		btn_del.flat = true
		btn_del.add_theme_font_size_override("font_size", 9)
		btn_del.add_theme_color_override("font_color", Color("#ff7b72"))
		btn_del.pressed.connect(func():
			if doc_store != null:
				doc_store.delete_port_channel_by_index(current_element_id, current_port_id, current_is_output, ch_num)
				channel_deleted.emit(conn_id_capt)
				rebuild_rows()
		)
		row.add_child(btn_del)

		_rows_vbox.add_child(row_panel)

