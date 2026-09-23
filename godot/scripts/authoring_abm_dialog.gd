# authoring_abm_dialog.gd
# Interactive, Schema-Driven ABM & Hybrid Simulation Configuration Dialog.
class_name SimVizAuthoringABMDialog
extends PanelContainer

const SceneTypes := preload("res://scripts/scenespec_types.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")

signal closed

const BG := Color("#0e1520")
const PANEL := Color("#141d2b")
const PANEL_ALT := Color("#1a2638")
const BORDER := Color("#2c3e55")
const TEXT := Color("#e8f0f8")
const MUTED := Color("#8fa2b5")
const ACCENT := Color("#52c7a5")
const WARNING := Color("#f39c12")
const DANGER := Color("#e74c3c")
const LIVE_GREEN := Color("#2ecc71")

var doc_store: DocumentStore

# UI controls
var _check_enabled: CheckBox
var _opt_model: OptionButton
var _opt_backend: OptionButton
var _opt_fallback: OptionButton
var _migration_label: Label
var _params_container: VBoxContainer
var _custom_params_container: VBoxContainer
var _param_spinboxes: Dictionary = {} # param_key -> SpinBox
var _custom_param_rows: Dictionary = {} # param_key -> Control

# Model Definitions & Calibrated Schemas
const MODEL_REGISTRY: Dictionary = {
	"SFM": {
		"name": "Social Force Model (SFM)",
		"library": "SimCrowd",
		"version": "1.0.0",
		"description": "Continuous Newtonian physics simulation modeling socio-psychological repulsion, physical body compression, and sliding friction (Helbing-Molnar).",
		"presets": {
			"Standard Calibrated": {
				"A": 2000.0, "B": 0.08, "k": 12000.0, "kappa": 24000.0,
				"tau": 0.5, "sigma": 0.3, "v_pref_default": 1.34, "r_body_default": 0.20
			},
			"Dense Rush Hour": {
				"A": 2500.0, "B": 0.05, "k": 16000.0, "kappa": 30000.0,
				"tau": 0.4, "sigma": 0.25, "v_pref_default": 1.50, "r_body_default": 0.20
			},
			"Emergency Evacuation": {
				"A": 3200.0, "B": 0.04, "k": 20000.0, "kappa": 40000.0,
				"tau": 0.3, "sigma": 0.20, "v_pref_default": 2.20, "r_body_default": 0.20
			}
		},
		"params": [
			{"key": "A", "label": "Repulsion Strength (A)", "unit": "N", "default": 2000.0, "min": 100.0, "max": 10000.0, "step": 50.0, "tooltip": "Psychological repulsion force magnitude pushing agents apart."},
			{"key": "B", "label": "Interaction Range (B)", "unit": "m", "default": 0.08, "min": 0.01, "max": 1.00, "step": 0.01, "tooltip": "Exponential decay distance scale for interpersonal repulsion."},
			{"key": "k", "label": "Body Contact Stiffness (k)", "unit": "N/m", "default": 12000.0, "min": 1000.0, "max": 50000.0, "step": 500.0, "tooltip": "Elastic spring resistance when pedestrian bodies make physical contact."},
			{"key": "kappa", "label": "Sliding Friction (κ)", "unit": "kg/(m·s)", "default": 24000.0, "min": 1000.0, "max": 50000.0, "step": 500.0, "tooltip": "Tangential frictional resistance when bodies scrape past each other or walls."},
			{"key": "tau", "label": "Reaction Time (τ)", "unit": "s", "default": 0.50, "min": 0.05, "max": 2.50, "step": 0.05, "tooltip": "Acceleration relaxation time needed to adapt current velocity to desired velocity."},
			{"key": "sigma", "label": "Perception Field Anisotropy", "unit": "", "default": 0.30, "min": 0.0, "max": 1.0, "step": 0.05, "tooltip": "Weight for events behind the pedestrian (0.0 = forward vision only, 1.0 = omnidirectional)."},
			{"key": "v_pref_default", "label": "Preferred Walking Speed", "unit": "m/s", "default": 1.34, "min": 0.20, "max": 3.50, "step": 0.05, "tooltip": "Baseline free-flow walking speed in unobstructed conditions."},
			{"key": "r_body_default", "label": "Body Torso Radius", "unit": "m", "default": 0.20, "min": 0.10, "max": 0.60, "step": 0.02, "tooltip": "Effective physical radius of pedestrian cylinder (diameter = 2r)."}
		]
	},
	"ORCA": {
		"name": "Optimal Reciprocal Collision Avoidance (ORCA)",
		"library": "SimCrowd",
		"version": "1.0.0",
		"description": "Velocity obstacle optimization guaranteeing collision-free trajectories among multi-agent systems via linear programming.",
		"presets": {
			"Standard Calibrated": {
				"time_horizon": 5.0, "time_horizon_obst": 5.0,
				"neighbor_dist": 15.0, "max_neighbors": 10, "max_speed": 2.5, "r_body": 0.25
			},
			"High Density / Constrained": {
				"time_horizon": 3.0, "time_horizon_obst": 3.0,
				"neighbor_dist": 10.0, "max_neighbors": 15, "max_speed": 2.0, "r_body": 0.22
			}
		},
		"params": [
			{"key": "time_horizon", "label": "Agent Time Horizon", "unit": "s", "default": 5.0, "min": 0.5, "max": 20.0, "step": 0.5, "tooltip": "Lookahead time window over which other moving agents are guaranteed not to collide."},
			{"key": "time_horizon_obst", "label": "Obstacle Time Horizon", "unit": "s", "default": 5.0, "min": 0.5, "max": 20.0, "step": 0.5, "tooltip": "Lookahead time window for avoiding static boundary walls and obstacles."},
			{"key": "neighbor_dist", "label": "Neighbor Search Radius", "unit": "m", "default": 15.0, "min": 2.0, "max": 50.0, "step": 1.0, "tooltip": "KD-tree radius for tracking surrounding agents."},
			{"key": "max_neighbors", "label": "Max Tracked Neighbors", "unit": "peds", "default": 10, "min": 1, "max": 50, "step": 1, "tooltip": "Maximum number of nearby agents considered in the half-plane optimization."},
			{"key": "max_speed", "label": "Maximum Speed Cap", "unit": "m/s", "default": 2.5, "min": 0.5, "max": 5.0, "step": 0.1, "tooltip": "Absolute velocity magnitude ceiling for evasive maneuvers."},
			{"key": "r_body", "label": "Body Radius", "unit": "m", "default": 0.25, "min": 0.10, "max": 0.60, "step": 0.02, "tooltip": "Collision radius enclosing agent boundary."}
		]
	},
	"HybridFSM": {
		"name": "Hybrid State Machine (HybridFSM)",
		"library": "SimCrowd",
		"version": "1.0.0",
		"description": "Discrete-Event and Continuous Crowd bridge. Dynamically switches agents between continuous flow and discrete station queue states based on local congestion thresholds.",
		"presets": {
			"Airport / Concourse": {
				"rho_on": 1.5, "rho_off": 0.3, "k_contact": 12000.0, "v_pref": 1.2, "gate_clearance_sec": 0.5
			},
			"High Throughput Turnstiles": {
				"rho_on": 2.0, "rho_off": 0.5, "k_contact": 15000.0, "v_pref": 1.4, "gate_clearance_sec": 0.25
			}
		},
		"params": [
			{"key": "rho_on", "label": "Congestion Threshold (ρ_on)", "unit": "ped/m²", "default": 1.50, "min": 0.5, "max": 4.0, "step": 0.1, "tooltip": "Local density at which agents transition from free walking into queuing state."},
			{"key": "rho_off", "label": "Dispersal Threshold (ρ_off)", "unit": "ped/m²", "default": 0.30, "min": 0.1, "max": 1.0, "step": 0.05, "tooltip": "Low density threshold below which agents break queue and resume free walking."},
			{"key": "gate_clearance_sec", "label": "Portal Gate Clearance Delay", "unit": "s", "default": 0.50, "min": 0.05, "max": 5.0, "step": 0.05, "tooltip": "Physical transaction delay when passing through turnstiles."},
			{"key": "k_contact", "label": "Queue Contact Stiffness", "unit": "N/m", "default": 12000.0, "min": 1000.0, "max": 50000.0, "step": 500.0, "tooltip": "Physical compression resistance in queue line bottlenecks."},
			{"key": "v_pref", "label": "Dispersal Free Speed", "unit": "m/s", "default": 1.20, "min": 0.20, "max": 3.0, "step": 0.05, "tooltip": "Walking speed after departing hybrid turnstiles."}
		]
	},
	"CSM": {
		"name": "Continuous Steer Model (CSM)",
		"library": "SimCrowd",
		"version": "1.0.0",
		"description": "Reynolds steering force behaviors (separation, alignment, cohesion, arrival) with dynamic waypoint navigation.",
		"presets": {
			"Standard Flow": {
				"separation_weight": 1.5, "alignment_weight": 1.0, "cohesion_weight": 0.5, "max_force": 10.0, "max_speed": 2.0
			}
		},
		"params": [
			{"key": "separation_weight", "label": "Separation Weight", "unit": "", "default": 1.50, "min": 0.0, "max": 5.0, "step": 0.1, "tooltip": "Priority given to maintaining personal space buffer."},
			{"key": "alignment_weight", "label": "Stream Alignment Weight", "unit": "", "default": 1.00, "min": 0.0, "max": 5.0, "step": 0.1, "tooltip": "Tendency to align motion vector with surrounding pedestrians."},
			{"key": "cohesion_weight", "label": "Group Cohesion Weight", "unit": "", "default": 0.50, "min": 0.0, "max": 5.0, "step": 0.1, "tooltip": "Tendency for traveling groups to stay clustered together."},
			{"key": "max_force", "label": "Maximum Acceleration Force", "unit": "m/s²", "default": 10.0, "min": 1.0, "max": 30.0, "step": 1.0, "tooltip": "Steering force clamp."},
			{"key": "max_speed", "label": "Maximum Walking Speed", "unit": "m/s", "default": 2.00, "min": 0.5, "max": 4.0, "step": 0.1, "tooltip": "Speed limit."}
		]
	}
}

func _init(p_store: DocumentStore = null) -> void:
	doc_store = p_store
	visible = false
	custom_minimum_size = Vector2(560, 620)
	_build_ui()
	if doc_store != null:
		doc_store.document_loaded.connect(_on_doc_reloaded)
		doc_store.document_modified.connect(_on_doc_modified)

func _ready() -> void:
	refresh_from_document()

func _box(bg: Color, border_c: Color = BORDER, radius: int = 6) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border_c
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	return sb

func _build_ui() -> void:
	add_theme_stylebox_override("panel", _box(BG, BORDER, 8))
	
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	root.add_theme_constant_override("margin_left", 16)
	root.add_theme_constant_override("margin_right", 16)
	root.add_theme_constant_override("margin_top", 14)
	root.add_theme_constant_override("margin_bottom", 14)
	add_child(root)

	# 1. Header Bar
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.color = ACCENT
	header.add_child(dot)

	var title := Label.new()
	title.text = "Agent-Based Modeling (ABM) & Hybrid Configuration"
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", TEXT)
	header.add_child(title)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(sp)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.add_theme_font_size_override("font_size", 11)
	close_btn.add_theme_color_override("font_color", MUTED)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)
	root.add_child(header)

	root.add_child(HSeparator.new())

	# 2. Main Scroll Area
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)

	# Section A: Activation & Engine Model Selection
	var act_panel := PanelContainer.new()
	act_panel.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 6))
	var act_vbox := VBoxContainer.new()
	act_vbox.add_theme_constant_override("separation", 8)
	act_vbox.add_theme_constant_override("margin_left", 12)
	act_vbox.add_theme_constant_override("margin_right", 12)
	act_vbox.add_theme_constant_override("margin_top", 10)
	act_vbox.add_theme_constant_override("margin_bottom", 10)
	act_panel.add_child(act_vbox)

	_check_enabled = CheckBox.new()
	_check_enabled.text = "Enable Crowd Dynamics (SimCrowd / ABM Engine)"
	_check_enabled.add_theme_font_size_override("font_size", 11)
	_check_enabled.add_theme_color_override("font_color", TEXT)
	_check_enabled.toggled.connect(_on_enabled_toggled)
	act_vbox.add_child(_check_enabled)

	var model_row := HBoxContainer.new()
	model_row.add_theme_constant_override("separation", 10)
	var m_lbl := Label.new()
	m_lbl.text = "Crowd Model:"
	m_lbl.custom_minimum_size.x = 130
	m_lbl.add_theme_font_size_override("font_size", 10)
	m_lbl.add_theme_color_override("font_color", MUTED)
	model_row.add_child(m_lbl)

	_opt_model = OptionButton.new()
	_opt_model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_opt_model.add_theme_font_size_override("font_size", 10)
	for m_key in MODEL_REGISTRY.keys():
		_opt_model.add_item("%s — %s" % [m_key, MODEL_REGISTRY[m_key]["name"]], _opt_model.item_count)
	_opt_model.item_selected.connect(_on_model_selected)
	model_row.add_child(_opt_model)
	act_vbox.add_child(model_row)

	_migration_label = Label.new()
	_migration_label.text = "Model active."
	_migration_label.add_theme_font_size_override("font_size", 9)
	_migration_label.add_theme_color_override("font_color", ACCENT)
	_migration_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	act_vbox.add_child(_migration_label)
	content.add_child(act_panel)

	# Section B: Hardware Backend & Fallback
	var hw_panel := PanelContainer.new()
	hw_panel.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 6))
	var hw_vbox := VBoxContainer.new()
	hw_vbox.add_theme_constant_override("separation", 8)
	hw_vbox.add_theme_constant_override("margin_left", 12)
	hw_vbox.add_theme_constant_override("margin_right", 12)
	hw_vbox.add_theme_constant_override("margin_top", 10)
	hw_vbox.add_theme_constant_override("margin_bottom", 10)
	hw_panel.add_child(hw_vbox)

	var hw_hdr := Label.new()
	hw_hdr.text = "HARDWARE EXECUTION BACKEND"
	hw_hdr.add_theme_font_size_override("font_size", 9)
	hw_hdr.add_theme_color_override("font_color", MUTED)
	hw_vbox.add_child(hw_hdr)

	var b_row := HBoxContainer.new()
	var b_lbl := Label.new()
	b_lbl.text = "Execution Target:"
	b_lbl.custom_minimum_size.x = 130
	b_lbl.add_theme_font_size_override("font_size", 10)
	b_lbl.add_theme_color_override("font_color", MUTED)
	b_row.add_child(b_lbl)

	_opt_backend = OptionButton.new()
	_opt_backend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_opt_backend.add_theme_font_size_override("font_size", 10)
	_opt_backend.add_item("Auto-Detect (GPU if functional, else Multicore CPU)", 0)
	_opt_backend.add_item("Multicore CPU (KernelAbstractions / Threads)", 1)
	_opt_backend.add_item("Universal GPU (NVIDIA CUDA / AMD ROCm / Apple Metal / Intel oneAPI)", 2)
	_opt_backend.item_selected.connect(_on_backend_selected)
	b_row.add_child(_opt_backend)
	hw_vbox.add_child(b_row)

	var fb_row := HBoxContainer.new()
	var fb_lbl := Label.new()
	fb_lbl.text = "Fallback Policy:"
	fb_lbl.custom_minimum_size.x = 130
	fb_lbl.add_theme_font_size_override("font_size", 10)
	fb_lbl.add_theme_color_override("font_color", MUTED)
	fb_row.add_child(fb_lbl)

	_opt_fallback = OptionButton.new()
	_opt_fallback.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_opt_fallback.add_theme_font_size_override("font_size", 10)
	_opt_fallback.add_item("Allow Graceful Fallback to CPU", 0)
	_opt_fallback.add_item("Strict (Error and stop if preferred backend unavailable)", 1)
	_opt_fallback.item_selected.connect(_on_fallback_selected)
	fb_row.add_child(_opt_fallback)
	hw_vbox.add_child(fb_row)
	content.add_child(hw_panel)

	# Section C: Dynamic Physical Parameters
	var param_panel := PanelContainer.new()
	param_panel.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 6))
	var param_vbox := VBoxContainer.new()
	param_vbox.add_theme_constant_override("separation", 8)
	param_vbox.add_theme_constant_override("margin_left", 12)
	param_vbox.add_theme_constant_override("margin_right", 12)
	param_vbox.add_theme_constant_override("margin_top", 10)
	param_vbox.add_theme_constant_override("margin_bottom", 10)
	param_panel.add_child(param_vbox)

	var p_hdr_row := HBoxContainer.new()
	var p_hdr := Label.new()
	p_hdr.text = "MODEL PHYSICAL PARAMETERS"
	p_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p_hdr.add_theme_font_size_override("font_size", 9)
	p_hdr.add_theme_color_override("font_color", MUTED)
	p_hdr_row.add_child(p_hdr)

	# Presets dropdown
	var preset_btn := MenuButton.new()
	preset_btn.text = "⚡ Load Preset ▾"
	preset_btn.add_theme_font_size_override("font_size", 9)
	preset_btn.get_popup().id_pressed.connect(_on_preset_selected)
	p_hdr_row.add_child(preset_btn)
	param_vbox.add_child(p_hdr_row)

	_params_container = VBoxContainer.new()
	_params_container.add_theme_constant_override("separation", 6)
	param_vbox.add_child(_params_container)
	content.add_child(param_panel)

	# Section D: Custom User Parameters (Extensions)
	var custom_panel := PanelContainer.new()
	custom_panel.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 6))
	var custom_vbox := VBoxContainer.new()
	custom_vbox.add_theme_constant_override("separation", 8)
	custom_vbox.add_theme_constant_override("margin_left", 12)
	custom_vbox.add_theme_constant_override("margin_right", 12)
	custom_vbox.add_theme_constant_override("margin_top", 10)
	custom_vbox.add_theme_constant_override("margin_bottom", 10)
	custom_panel.add_child(custom_vbox)

	var cust_hdr_row := HBoxContainer.new()
	var cust_hdr := Label.new()
	cust_hdr.text = "CUSTOM EXPERIMENTAL PARAMETERS"
	cust_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cust_hdr.add_theme_font_size_override("font_size", 9)
	cust_hdr.add_theme_color_override("font_color", MUTED)
	cust_hdr_row.add_child(cust_hdr)

	var add_param_btn := Button.new()
	add_param_btn.text = "+ Add Custom Parameter"
	add_param_btn.add_theme_font_size_override("font_size", 9)
	add_param_btn.pressed.connect(_on_add_custom_param_pressed)
	cust_hdr_row.add_child(add_param_btn)
	custom_vbox.add_child(cust_hdr_row)

	_custom_params_container = VBoxContainer.new()
	_custom_params_container.add_theme_constant_override("separation", 4)
	custom_vbox.add_child(_custom_params_container)
	content.add_child(custom_panel)

	# 3. Footer
	var footer := HBoxContainer.new()
	var foot_note := Label.new()
	foot_note.text = "Changes are recorded in history (Ctrl+Z to undo)."
	foot_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot_note.add_theme_font_size_override("font_size", 9)
	foot_note.add_theme_color_override("font_color", MUTED)
	footer.add_child(foot_note)

	var done_btn := Button.new()
	done_btn.text = "Done"
	done_btn.custom_minimum_size.x = 80
	done_btn.add_theme_font_size_override("font_size", 10)
	done_btn.pressed.connect(close)
	footer.add_child(done_btn)
	root.add_child(footer)

func close() -> void:
	visible = false
	closed.emit()

func open() -> void:
	visible = true
	refresh_from_document()

func refresh_from_document() -> void:
	if doc_store == null or doc_store.active_document == null:
		return
	
	var doc: SceneTypes.SceneDocument = doc_store.active_document
	var abm: Dictionary = doc.abm_config if doc.abm_config is Dictionary else {}
	var enabled: bool = bool(abm.get("enabled", false))
	_check_enabled.set_pressed_no_signal(enabled)

	var model_name: String = str(abm.get("model_name", "SFM"))
	var model_keys: Array = MODEL_REGISTRY.keys()
	var idx := model_keys.find(model_name)
	if idx >= 0:
		_opt_model.select(idx)
	else:
		_opt_model.select(0)

	var backend_pref: String = str(abm.get("backend_preference", "auto"))
	match backend_pref:
		"auto": _opt_backend.select(0)
		"cpu": _opt_backend.select(1)
		"gpu": _opt_backend.select(2)
		_: _opt_backend.select(0)

	var fallback: String = str(abm.get("fallback_policy", "allow"))
	_opt_fallback.select(0 if fallback == "allow" else 1)

	_render_model_parameters(get_current_model_name())

func get_current_model_name() -> String:
	var keys: Array = MODEL_REGISTRY.keys()
	var idx := _opt_model.selected
	if idx >= 0 and idx < keys.size():
		return keys[idx]
	return "SFM"

func _render_model_parameters(model_name: String) -> void:
	for c in _params_container.get_children():
		c.queue_free()
	_param_spinboxes.clear()

	if not MODEL_REGISTRY.has(model_name):
		return

	var m_def: Dictionary = MODEL_REGISTRY[model_name]
	var doc: SceneTypes.SceneDocument = doc_store.active_document
	var abm: Dictionary = doc.abm_config if (doc != null and doc.abm_config is Dictionary) else {}
	var current_params: Dictionary = abm.get("parameters", {}) if abm.get("parameters") is Dictionary else {}

	# Update preset menu
	var p_menu: PopupMenu = _params_container.get_parent().get_node_or_null("HBoxContainer/MenuButton").get_popup() if _params_container.get_parent().has_node("HBoxContainer/MenuButton") else null
	if p_menu != null:
		p_menu.clear()
		var presets: Dictionary = m_def.get("presets", {})
		var pid := 0
		for pname in presets.keys():
			p_menu.add_item(pname, pid)
			pid += 1

	for p in m_def.get("params", []):
		var p_key: String = p["key"]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var lbl := Label.new()
		var unit_str: String = " (%s)" % p["unit"] if not str(p["unit"]).is_empty() else ""
		lbl.text = "%s%s:" % [p["label"], unit_str]
		lbl.custom_minimum_size.x = 220
		lbl.add_theme_font_size_override("font_size", 9)
		lbl.add_theme_color_override("font_color", TEXT)
		lbl.tooltip_text = p["tooltip"]
		row.add_child(lbl)

		var spin := SpinBox.new()
		spin.min_value = p["min"]
		spin.max_value = p["max"]
		spin.step = p["step"]
		var cur_val: float = float(current_params.get(p_key, p["default"]))
		spin.value = cur_val
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.add_theme_font_size_override("font_size", 9)
		spin.tooltip_text = p["tooltip"]

		var pk: String = p_key
		spin.value_changed.connect(func(v: float):
			_on_param_value_changed(pk, v)
		)
		row.add_child(spin)
		_param_spinboxes[p_key] = spin
		_params_container.add_child(row)

	_render_custom_parameters(current_params, m_def.get("params", []))

func _render_custom_parameters(all_params: Dictionary, standard_params: Array) -> void:
	for c in _custom_params_container.get_children():
		c.queue_free()
	_custom_param_rows.clear()

	var standard_keys := {}
	for p in standard_params:
		standard_keys[p["key"]] = true

	for k in all_params.keys():
		if standard_keys.has(k):
			continue
		_add_custom_param_row(k, all_params[k])

func _add_custom_param_row(k: String, val) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var k_edit := LineEdit.new()
	k_edit.text = k
	k_edit.custom_minimum_size.x = 180
	k_edit.editable = false
	k_edit.add_theme_font_size_override("font_size", 9)
	row.add_child(k_edit)

	var v_spin := SpinBox.new()
	v_spin.min_value = -100000.0
	v_spin.max_value = 100000.0
	v_spin.step = 0.01
	v_spin.value = float(val) if (val is int or val is float) else 0.0
	v_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v_spin.add_theme_font_size_override("font_size", 9)
	var capture_key: String = k
	v_spin.value_changed.connect(func(v: float):
		_on_param_value_changed(capture_key, v)
	)
	row.add_child(v_spin)

	var del_btn := Button.new()
	del_btn.text = "✕"
	del_btn.add_theme_font_size_override("font_size", 9)
	del_btn.add_theme_color_override("font_color", DANGER)
	del_btn.pressed.connect(func():
		_remove_custom_param(capture_key)
	)
	row.add_child(del_btn)

	_custom_params_container.add_child(row)
	_custom_param_rows[k] = row

func _on_enabled_toggled(btn_pressed: bool) -> void:
	if doc_store == null or doc_store.active_document == null:
		return
	_ensure_abm_config_struct()
	doc_store.active_document.abm_config["enabled"] = btn_pressed
	if btn_pressed:
		# Ensure simulation mode is hybrid or abm_only
		if doc_store.active_document.simulation.mode != "abm_only" and doc_store.active_document.simulation.mode != "hybrid":
			doc_store.active_document.simulation.mode = "hybrid"
	doc_store.validate()
	doc_store.document_modified.emit()

func _on_model_selected(idx: int) -> void:
	var keys: Array = MODEL_REGISTRY.keys()
	if idx < 0 or idx >= keys.size():
		return
	if _opt_model != null and _opt_model.selected != idx:
		_opt_model.selected = idx
	var new_model: String = keys[idx]
	_ensure_abm_config_struct()
	var old_model: String = str(doc_store.active_document.abm_config.get("model_name", "SFM"))
	doc_store.active_document.abm_config["model_name"] = new_model
	doc_store.active_document.abm_config["model_library"] = MODEL_REGISTRY[new_model]["library"]
	doc_store.active_document.abm_config["model_version"] = MODEL_REGISTRY[new_model]["version"]

	# Migration Preview
	if old_model != new_model:
		_migration_label.text = "Switched model from %s to %s. Model-specific parameters loaded." % [old_model, new_model]
		_migration_label.add_theme_color_override("font_color", WARNING)
	else:
		_migration_label.text = "Model active: %s" % new_model
		_migration_label.add_theme_color_override("font_color", ACCENT)

	_render_model_parameters(new_model)
	doc_store.validate()
	doc_store.document_modified.emit()

func _on_backend_selected(idx: int) -> void:
	_ensure_abm_config_struct()
	var target: String = "auto"
	match idx:
		0: target = "auto"
		1: target = "cpu"
		2: target = "gpu"
	doc_store.active_document.abm_config["backend_preference"] = target
	doc_store.document_modified.emit()

func _on_fallback_selected(idx: int) -> void:
	_ensure_abm_config_struct()
	var fb: String = "allow" if idx == 0 else "strict"
	doc_store.active_document.abm_config["fallback_policy"] = fb
	doc_store.document_modified.emit()

func _on_param_value_changed(param_key: String, val: float) -> void:
	_ensure_abm_config_struct()
	var p_dict: Dictionary = doc_store.active_document.abm_config["parameters"]
	p_dict[param_key] = val
	doc_store.validate()
	doc_store.document_modified.emit()

func _on_preset_selected(id: int) -> void:
	var m_name := get_current_model_name()
	if not MODEL_REGISTRY.has(m_name):
		return
	var presets: Dictionary = MODEL_REGISTRY[m_name].get("presets", {})
	var pnames := presets.keys()
	if id >= 0 and id < pnames.size():
		var pname: String = pnames[id]
		var p_vals: Dictionary = presets[pname]
		_ensure_abm_config_struct()
		for k in p_vals.keys():
			doc_store.active_document.abm_config["parameters"][k] = p_vals[k]
			if _param_spinboxes.has(k):
				_param_spinboxes[k].set_value_no_signal(p_vals[k])
		_migration_label.text = "Applied preset '%s' to %s." % [pname, m_name]
		_migration_label.add_theme_color_override("font_color", ACCENT)
		doc_store.validate()
		doc_store.document_modified.emit()

func _on_add_custom_param_pressed() -> void:
	_ensure_abm_config_struct()
	var p_dict: Dictionary = doc_store.active_document.abm_config["parameters"]
	var base_key := "custom_param_%02d" % (p_dict.size() + 1)
	p_dict[base_key] = 1.0
	_render_model_parameters(get_current_model_name())
	doc_store.document_modified.emit()

func _remove_custom_param(param_key: String) -> void:
	_ensure_abm_config_struct()
	var p_dict: Dictionary = doc_store.active_document.abm_config["parameters"]
	if p_dict.has(param_key):
		p_dict.erase(param_key)
		_render_model_parameters(get_current_model_name())
		doc_store.document_modified.emit()

func _ensure_abm_config_struct() -> void:
	if doc_store == null or doc_store.active_document == null:
		return
	var doc: SceneTypes.SceneDocument = doc_store.active_document
	if not (doc.abm_config is Dictionary):
		doc.abm_config = {}
	if not doc.abm_config.has("enabled"):
		doc.abm_config["enabled"] = false
	if not doc.abm_config.has("model_name"):
		doc.abm_config["model_name"] = "SFM"
	if not doc.abm_config.has("model_library"):
		doc.abm_config["model_library"] = "SimCrowd"
	if not doc.abm_config.has("model_version"):
		doc.abm_config["model_version"] = "1.0.0"
	if not doc.abm_config.has("backend_preference"):
		doc.abm_config["backend_preference"] = "auto"
	if not doc.abm_config.has("fallback_policy"):
		doc.abm_config["fallback_policy"] = "allow"
	if not (doc.abm_config.get("parameters") is Dictionary):
		doc.abm_config["parameters"] = {}

func _on_doc_reloaded(_doc: Variant = null) -> void:
	refresh_from_document()

func _on_doc_modified() -> void:
	pass
