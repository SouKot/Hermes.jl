extends SceneTree

const ConnectionManager := preload("res://scripts/connection_manager.gd")

var client: SimVizConnectionManager
var got_hello := false
var got_compile_ack := false
var got_step_ack := false
var got_compiled_snapshot := false
var got_stepped_snapshot := false
var failed := false

func _init() -> void:
	client = ConnectionManager.new()
	get_root().add_child(client)
	client.connection_state_changed.connect(_on_state)
	client.message_received.connect(_on_message)
	client.protocol_error.connect(_on_error)
	create_timer(10.0).timeout.connect(_on_timeout)
	client.connect_to("127.0.0.1", 9107)

func _on_timeout() -> void:
	if got_hello and got_compile_ack and got_compiled_snapshot and got_step_ack and got_stepped_snapshot:
		print("Phase 7D-12A: Authoring compiler smoke test PASSED 100%")
		quit(0)
	push_error("Compiler smoke timeout: hello=%s compile_ack=%s snap=%s step_ack=%s stepped_snap=%s" % [
		got_hello, got_compile_ack, got_compiled_snapshot, got_step_ack, got_stepped_snapshot
	])
	quit(1)

func _on_state(state: String, detail: String) -> void:
	print("connection_state=", state, " detail=", detail)

func _on_error(detail: String) -> void:
	push_error(detail)
	failed = true
	quit(1)

func _on_message(message: Dictionary) -> void:
	var kind := str(message.get("kind", ""))
	if kind == "hello":
		got_hello = true
		# Send compile_and_run command with tandem model
		var scene_spec := {
			"spec_version": "1.0.0",
			"scene": {"id": "smoke_tandem", "name": "Smoke Tandem Model"},
			"simulation": {"mode": "des_only", "time_unit": "seconds"},
			"elements": [
				{"id": "src_1", "kind": "source", "properties": {"interarrival_time": {"type": "exponential", "mean": 1.5}}},
				{"id": "q_1", "kind": "queue", "properties": {"capacity": 10, "discipline": "FIFO"}},
				{"id": "srv_1", "kind": "server", "properties": {"servers": 1, "service_time": {"type": "triangular", "min": 0.8, "mode": 1.2, "max": 1.5}}},
				{"id": "conv_1", "kind": "conveyor", "properties": {"length": 6.0, "speed": 2.0, "capacity": 5}},
				{"id": "snk_1", "kind": "sink", "properties": {}}
			],
			"connections": [
				{"id": "c1", "source_element": "src_1", "source_port": "flow_out", "target_element": "q_1", "target_port": "flow_in"},
				{"id": "c2", "source_element": "q_1", "source_port": "flow_out", "target_element": "srv_1", "target_port": "flow_in"},
				{"id": "c3", "source_element": "srv_1", "source_port": "flow_out", "target_element": "conv_1", "target_port": "flow_in"},
				{"id": "c4", "source_element": "conv_1", "source_port": "flow_out", "target_element": "snk_1", "target_port": "flow_in"}
			]
		}

		var cmd := {
			"envelope_version": "1.0",
			"message_id": "godot-compile-1",
			"timestamp": Time.get_ticks_msec(),
			"sender": "godot_gui",
			"receiver": "julia_runtime",
			"kind": "command",
			"payload": {
				"command_version": "1.0.0",
				"command_type": "compile_and_run",
				"command": {
					"action": "compile_and_run",
					"scenespec": scene_spec,
					"speed": 1.0
				},
				"scene_id": "smoke_tandem",
				"apply_at_time": null
			}
		}
		var err := client.send_message(cmd)
		if err != OK:
			_on_error("Failed to send compile_and_run: %s" % err)

	elif kind == "ack":
		var payload: Dictionary = message.get("payload", {})
		var ack_id := str(payload.get("acknowledged_message_id", ""))
		var status := str(payload.get("status", ""))
		print("Received ACK for %s: status=%s" % [ack_id, status])
		if ack_id == "godot-compile-1" and status == "accepted":
			got_compile_ack = true
		elif ack_id == "godot-step-1" and status == "accepted":
			got_step_ack = true
			if got_stepped_snapshot:
				print("Phase 7D-12A: Authoring compiler smoke test PASSED 100%")
				quit(0)

	elif kind == "snapshot":
		var payload: Dictionary = message.get("payload", {})
		var sim_t := float(payload.get("simulation_time", 0.0))
		var elems: Array = payload.get("elements_state", [])
		var entities: Array = payload.get("entities", [])
		print("Received snapshot: t=%.2f elems=%d entities=%d" % [sim_t, elems.size(), entities.size()])

		if got_compile_ack and not got_compiled_snapshot:
			got_compiled_snapshot = true
			# Now test multi-unit stepping (5 seconds)
			var step_cmd := {
				"envelope_version": "1.0",
				"message_id": "godot-step-1",
				"timestamp": Time.get_ticks_msec(),
				"sender": "godot_gui",
				"receiver": "julia_runtime",
				"kind": "command",
				"payload": {
					"command_version": "1.0.0",
					"command_type": "step",
					"command": {
						"action": "step",
						"duration": 5.0,
						"unit": "s"
					},
					"scene_id": "smoke_tandem",
					"apply_at_time": null
				}
			}
			client.send_message(step_cmd)

		if sim_t >= 4.9:
			got_stepped_snapshot = true
			if got_step_ack:
				print("Phase 7D-12A: Authoring compiler smoke test PASSED 100%")
				quit(0)
