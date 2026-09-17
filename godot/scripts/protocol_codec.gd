class_name SimVizProtocolCodec
extends RefCounted

const MAX_DEPTH := 64

func decode(data: PackedByteArray) -> Variant:
    var cursor := {"index": 0}
    var value = _decode_value(data, cursor, 0)
    if cursor.index != data.size():
        push_error("MessagePack trailing bytes: %d" % (data.size() - cursor.index))
    return value

func encode(value: Variant) -> PackedByteArray:
    var output := PackedByteArray()
    _encode_value(output, value)
    return output

func validate_message(value: Variant) -> Dictionary:
    if not value is Dictionary:
        return {"ok": false, "error": "MessagePack root is not a map"}
    var message: Dictionary = value
    for key in ["envelope_version", "message_id", "kind", "payload"]:
        if not message.has(key):
            return {"ok": false, "error": "Missing envelope field: %s" % key}
    if str(message.envelope_version).split(".")[0] != "1":
        return {"ok": false, "error": "Unsupported envelope version: %s" % message.envelope_version}
    return {"ok": true, "kind": str(message.kind), "message": message}

func _decode_value(data: PackedByteArray, cursor: Dictionary, depth: int) -> Variant:
    if depth > MAX_DEPTH:
        push_error("MessagePack nesting limit exceeded")
        return null
    var tag := _read_u8(data, cursor)
    if tag <= 0x7f:
        return tag
    if tag >= 0xe0:
        return tag - 256
    if tag >= 0xa0 and tag <= 0xbf:
        return _read_string(data, cursor, tag & 0x1f)
    if tag >= 0x90 and tag <= 0x9f:
        return _read_array(data, cursor, tag & 0x0f, depth)
    if tag >= 0x80 and tag <= 0x8f:
        return _read_map(data, cursor, tag & 0x0f, depth)
    match tag:
        0xc0: return null
        0xc2: return false
        0xc3: return true
        0xc1: return null
        0xcc: return _read_u8(data, cursor)
        0xcd: return _read_uint(data, cursor, 2)
        0xce: return _read_uint(data, cursor, 4)
        0xcf: return _read_uint(data, cursor, 8)
        0xd0: return _signed(_read_uint(data, cursor, 1), 8)
        0xd1: return _signed(_read_uint(data, cursor, 2), 16)
        0xd2: return _signed(_read_uint(data, cursor, 4), 32)
        0xd3: return _signed(_read_uint(data, cursor, 8), 64)
        0xca: return _read_float(data, cursor, 4)
        0xcb: return _read_float(data, cursor, 8)
        0xd9: return _read_string(data, cursor, _read_u8(data, cursor))
        0xda: return _read_string(data, cursor, _read_uint(data, cursor, 2))
        0xdb: return _read_string(data, cursor, _read_uint(data, cursor, 4))
        0xc4: return _read_bytes(data, cursor, _read_u8(data, cursor))
        0xc5: return _read_bytes(data, cursor, _read_uint(data, cursor, 2))
        0xc6: return _read_bytes(data, cursor, _read_uint(data, cursor, 4))
        0xdc: return _read_array(data, cursor, _read_uint(data, cursor, 2), depth)
        0xdd: return _read_array(data, cursor, _read_uint(data, cursor, 4), depth)
        0xde: return _read_map(data, cursor, _read_uint(data, cursor, 2), depth)
        0xdf: return _read_map(data, cursor, _read_uint(data, cursor, 4), depth)
        _: 
            push_error("Unsupported MessagePack tag: 0x%02x" % tag)
            return null

func _read_array(data: PackedByteArray, cursor: Dictionary, count: int, depth: int) -> Array:
    var values: Array = []
    values.resize(count)
    for index in count:
        values[index] = _decode_value(data, cursor, depth + 1)
    return values

func _read_map(data: PackedByteArray, cursor: Dictionary, count: int, depth: int) -> Dictionary:
    var result := {}
    for _index in count:
        var key = _decode_value(data, cursor, depth + 1)
        var value = _decode_value(data, cursor, depth + 1)
        result[key] = value
    return result

func _read_string(data: PackedByteArray, cursor: Dictionary, length: int) -> String:
    return _read_bytes(data, cursor, length).get_string_from_utf8()

func _read_bytes(data: PackedByteArray, cursor: Dictionary, length: int) -> PackedByteArray:
    var start: int = cursor.index
    cursor.index += length
    return data.slice(start, cursor.index)

func _read_u8(data: PackedByteArray, cursor: Dictionary) -> int:
    var value: int = data[cursor.index]
    cursor.index += 1
    return value

func _read_uint(data: PackedByteArray, cursor: Dictionary, width: int) -> int:
    var value := 0
    for _index in width:
        value = (value << 8) | _read_u8(data, cursor)
    return value

func _read_float(data: PackedByteArray, cursor: Dictionary, width: int) -> float:
    var bytes := _read_bytes(data, cursor, width)
    bytes.reverse()
    var stream := StreamPeerBuffer.new()
    stream.data_array = bytes
    return stream.get_float() if width == 4 else stream.get_double()

func _signed(value: int, bits: int) -> int:
    var sign_bit := 1 << (bits - 1)
    return value - (1 << bits) if value & sign_bit else value

func _encode_value(output: PackedByteArray, value: Variant) -> void:
    if value == null:
        output.append(0xc0)
    elif value is bool:
        output.append(0xc3 if value else 0xc2)
    elif value is String:
        _encode_string(output, value)
    elif value is int:
        _encode_integer(output, value)
    elif value is float:
        output.append(0xcb)
        _append_uint(output, value_to_bytes(value), 8)
    elif value is Array:
        _encode_array(output, value)
    elif value is Dictionary:
        _encode_map(output, value)
    elif value is PackedByteArray:
        _encode_binary(output, value)
    else:
        push_error("Unsupported MessagePack value: %s" % typeof(value))
        output.append(0xc0)

func _encode_string(output: PackedByteArray, value: String) -> void:
    var bytes := value.to_utf8_buffer()
    var length := bytes.size()
    if length < 32:
        output.append(0xa0 | length)
    elif length <= 255:
        output.append(0xd9)
        output.append(length)
    else:
        output.append(0xda)
        _append_big_endian(output, length, 2)
    output.append_array(bytes)

func _encode_integer(output: PackedByteArray, value: int) -> void:
    if value >= 0 and value <= 127:
        output.append(value)
    elif value < 0 and value >= -32:
        output.append(256 + value)
    elif value >= 0 and value <= 255:
        output.append(0xcc)
        output.append(value)
    elif value >= 0 and value <= 65535:
        output.append(0xcd)
        _append_big_endian(output, value, 2)
    elif value >= 0:
        output.append(0xce)
        _append_big_endian(output, value, 4)
    elif value >= -128:
        output.append(0xd0)
        output.append(value & 255)
    elif value >= -32768:
        output.append(0xd1)
        _append_big_endian(output, value & 65535, 2)
    else:
        output.append(0xd2)
        _append_big_endian(output, value & 0xffffffff, 4)

func _encode_array(output: PackedByteArray, values: Array) -> void:
    var length := values.size()
    if length < 16:
        output.append(0x90 | length)
    else:
        output.append(0xdc)
        _append_big_endian(output, length, 2)
    for value in values:
        _encode_value(output, value)

func _encode_map(output: PackedByteArray, values: Dictionary) -> void:
    var length := values.size()
    if length < 16:
        output.append(0x80 | length)
    else:
        output.append(0xde)
        _append_big_endian(output, length, 2)
    for key in values:
        _encode_value(output, key)
        _encode_value(output, values[key])

func _encode_binary(output: PackedByteArray, value: PackedByteArray) -> void:
    output.append(0xc4)
    output.append(value.size())
    output.append_array(value)

func _append_big_endian(output: PackedByteArray, value: int, width: int) -> void:
    for shift in range((width - 1) * 8, -1, -8):
        output.append((value >> shift) & 255)

func _append_uint(output: PackedByteArray, bytes: PackedByteArray, width: int) -> void:
    for index in width:
        output.append(bytes[index])

func value_to_bytes(value: float) -> PackedByteArray:
    var stream := StreamPeerBuffer.new()
    stream.put_double(value)
    var bytes := stream.data_array
    bytes.reverse()
    return bytes
