extends SceneTree

const SCENESPEC_CODEC = preload("res://scripts/scenespec_codec.gd")

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("Usage: godot --headless --path godot --script res://tests/scenespec_cross_roundtrip.gd -- <input_msgpack> <output_msgpack>")
		quit(1)
		return

	var in_path := args[0]
	var out_path := args[1]

	if not FileAccess.file_exists(in_path):
		push_error("Input file not found: %s" % in_path)
		quit(1)
		return

	var in_file := FileAccess.open(in_path, FileAccess.READ)
	var in_bytes := in_file.get_buffer(in_file.get_length())
	in_file.close()

	var codec = SCENESPEC_CODEC.new()
	var spec: Dictionary = codec.decode_msgpack(in_bytes)
	if spec.is_empty():
		push_error("Failed to decode SceneSpec MessagePack from %s" % in_path)
		quit(1)
		return

	# Re-encode back to MessagePack
	var out_bytes := codec.encode_msgpack(spec)
	var out_file := FileAccess.open(out_path, FileAccess.WRITE)
	if out_file == null:
		push_error("Failed to open output file: %s" % out_path)
		quit(1)
		return
	out_file.store_buffer(out_bytes)
	out_file.close()

	quit(0)

