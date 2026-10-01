# authoring_os_window_host.gd
# Reusable Native OS Desktop Window Host for Antigravity SimViz Floating Panels.
# Automatically detaches floating panels into independent OS desktop Windows (when running
# interactively on a desktop display) so they are never confined within the main app window
# and can be freely dragged across the user's screen(s) or multi-monitor setup.
# Automatically stays docked in-viewport during headless unit tests or Movie Maker recording.
class_name SimVizOSWindowHost
extends RefCounted

var _panel: Control = null
var _title: String = "SimViz Window"
var _default_size: Vector2i = Vector2i(560, 480)
var _min_size: Vector2i = Vector2i(320, 240)
var _close_cb: Callable = Callable()
var _offset_from_main: Vector2i = Vector2i(100, 70)

var _is_detached: bool = false
var _os_window: Window = null
var _original_parent: Node = null
var _original_min_size: Vector2 = Vector2.ZERO
var _original_z_index: int = 100
var _positioned_once: bool = false
var _syncing_rect: bool = false

static func can_use_os_windows() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	if OS.has_feature("movie"):
		return false
	for arg in OS.get_cmdline_args():
		if arg == "--write-movie" or arg == "--headless" or arg.begins_with("--write-movie"):
			return false
	for arg in OS.get_cmdline_user_args():
		if arg == "--write-movie" or arg == "--headless" or arg.begins_with("--write-movie"):
			return false
	return true

static func attach(
	panel: Control,
	title_str: String,
	default_size: Vector2i,
	min_size: Vector2i,
	close_cb: Callable = Callable(),
	offset_from_main: Vector2i = Vector2i(100, 70)
):
	var script_res: GDScript = load("res://scripts/authoring_os_window_host.gd")
	var host = script_res.new()
	host.setup(panel, title_str, default_size, min_size, close_cb, offset_from_main)
	return host

func setup(
	panel: Control,
	title_str: String,
	default_size: Vector2i,
	min_size: Vector2i,
	close_cb: Callable = Callable(),
	offset_from_main: Vector2i = Vector2i(100, 70)
) -> void:
	_panel = panel
	_title = title_str
	_default_size = default_size
	_min_size = min_size
	_close_cb = close_cb
	_offset_from_main = offset_from_main
	if _panel != null:
		_original_min_size = _panel.custom_minimum_size
		_original_z_index = _panel.z_index
		_panel.visibility_changed.connect(_on_panel_visibility_changed)
		if _panel.visible:
			call_deferred("_on_panel_visibility_changed")

func is_detached() -> bool:
	return _is_detached and _os_window != null and is_instance_valid(_os_window)

func get_os_window() -> Window:
	return _os_window

func _on_panel_visibility_changed() -> void:
	if _panel == null or not is_instance_valid(_panel):
		return
	if _panel.visible:
		if can_use_os_windows():
			if not is_detached():
				detach_to_os_window()
			else:
				if not _os_window.visible:
					_os_window.show()
				_os_window.grab_focus()
	else:
		if is_detached() and _os_window.visible:
			_os_window.hide()

func detach_to_os_window(target_screen_pos: Vector2i = Vector2i(-1, -1)) -> void:
	if _panel == null or not is_instance_valid(_panel):
		return
	if not can_use_os_windows():
		return
	if is_detached():
		if target_screen_pos.x >= 0 and target_screen_pos.y >= 0:
			_os_window.position = target_screen_pos
		if _panel.visible and not _os_window.visible:
			_os_window.show()
		return

	var tree := _panel.get_tree()
	if tree == null or tree.root == null:
		return

	_original_parent = _panel.get_parent()
	_original_min_size = _panel.custom_minimum_size
	_original_z_index = _panel.z_index
	_is_detached = true

	tree.root.gui_embed_subwindows = false

	_os_window = Window.new()
	_os_window.title = _title
	var cur_w: int = maxi(_min_size.x, int(_panel.size.x) if _panel.size.x > 50 else _default_size.x)
	var cur_h: int = maxi(_min_size.y, int(_panel.size.y) if _panel.size.y > 50 else _default_size.y)
	_os_window.size = Vector2i(cur_w, cur_h)
	_os_window.min_size = _min_size
	_os_window.unresizable = false
	_os_window.transient = false
	_os_window.exclusive = false
	_os_window.wrap_controls = false

	if target_screen_pos.x >= 0 and target_screen_pos.y >= 0:
		_os_window.position = target_screen_pos
		_positioned_once = true
	elif not _positioned_once:
		var main_pos := DisplayServer.window_get_position()
		var desired_pos := Vector2i(int(_panel.position.x), int(_panel.position.y))
		if desired_pos.x > 10 and desired_pos.y > 10:
			_os_window.position = main_pos + desired_pos
		else:
			_os_window.position = main_pos + _offset_from_main
		_positioned_once = true

	_os_window.close_requested.connect(_on_os_window_close_requested)
	_os_window.size_changed.connect(_sync_panel_to_os_window)

	if _original_parent != null:
		_original_parent.remove_child(_panel)

	tree.root.add_child(_os_window)
	_panel.position = Vector2.ZERO
	_panel.custom_minimum_size = Vector2.ZERO
	_panel.size = Vector2(_os_window.size)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_os_window.add_child(_panel)
	_os_window.show()
	_sync_panel_to_os_window()

func _sync_panel_to_os_window() -> void:
	if _syncing_rect or not is_detached() or _panel == null or not is_instance_valid(_panel):
		return
	_syncing_rect = true
	var win_sz := Vector2(_os_window.size)
	_panel.position = Vector2.ZERO
	_panel.size = win_sz
	_panel.set_deferred("size", win_sz)
	_syncing_rect = false

func _on_os_window_close_requested() -> void:
	if _close_cb.is_valid():
		_close_cb.call()
	elif _panel != null and is_instance_valid(_panel):
		_panel.visible = false
	if _os_window != null and is_instance_valid(_os_window):
		_os_window.hide()

static func handle_header_drag(panel: Control, event: InputEvent) -> bool:
	if panel == null or not is_instance_valid(panel) or not panel.is_inside_tree():
		return false
	var parent_win := panel.get_parent()
	if not (parent_win is Window and parent_win != panel.get_tree().root):
		return false
	var os_win := parent_win as Window
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				panel.set_meta("_os_drag_active", true)
				panel.set_meta("_os_drag_win_start", os_win.position)
				panel.set_meta("_os_drag_mouse_start", DisplayServer.mouse_get_position())
				return true
			else:
				panel.set_meta("_os_drag_active", false)
				return true
	elif event is InputEventMouseMotion and bool(panel.get_meta("_os_drag_active", false)):
		var cur_mouse := DisplayServer.mouse_get_position()
		var start_mouse: Vector2i = panel.get_meta("_os_drag_mouse_start", cur_mouse)
		var start_win: Vector2i = panel.get_meta("_os_drag_win_start", os_win.position)
		os_win.position = start_win + (cur_mouse - start_mouse)
		return true
	return false
