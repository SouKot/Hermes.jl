extends SceneTree

const Codec := preload("res://scripts/protocol_codec.gd")

func _init() -> void:
    var codec := Codec.new()
    var message := {
        "envelope_version": "1.0",
        "message_id": "smoke-1",
        "timestamp": 123,
        "sender": "julia_runtime",
        "receiver": "godot_gui",
        "kind": "hello",
        "payload": {
            "protocol_version": "1.0.0",
            "capabilities": ["snapshot_streaming", "delta_updates"],
            "simulation_time": 12.5,
            "running": true
        }
    }
    var bytes := codec.encode(message)
    assert(bytes.size() > 0)
    var decoded: Variant = codec.decode(bytes)
    var validation := codec.validate_message(decoded)
    assert(validation.ok)
    assert(validation.kind == "hello")
    assert(validation.message.payload.simulation_time == 12.5)
    assert(validation.message.payload.running == true)
    print("Protocol smoke test passed: %d bytes" % bytes.size())
    quit(0)
