using Test
using GodotBridge
using MessagePack
using JSON

@testset "GodotBridge Protocol Tests" begin
    
    # ========================================================================
    # Test 1: Message Envelope Creation
    # ========================================================================
    @testset "Message Envelope Creation" begin
        env = MessageEnvelope(
            "1.0",
            "test_msg_001",
            UInt64(1694868600000),
            "julia_runtime",
            "godot_gui",
            "hello"
        )
        
        @test env.envelope_version == "1.0"
        @test env.message_id == "test_msg_001"
        @test env.kind == "hello"
        @test env.sender == "julia_runtime"
    end
    
    # ========================================================================
    # Test 2: Create Hello Message
    # ========================================================================
    @testset "Create Hello Message" begin
        hello = create_hello()
        
        @test hello.envelope.kind == "hello"
        @test isa(hello.payload, HelloPayload)
        @test hello.payload.protocol_version == "1.0.0"
        @test hello.payload.runtime_name == "SimViz"
        @test "snapshot_streaming" in hello.payload.capabilities
    end
    
    # ========================================================================
    # Test 3: Create Ack Message
    # ========================================================================
    @testset "Create Ack Message" begin
        ack = create_ack("msg_test_001", status="accepted")
        
        @test ack.envelope.kind == "ack"
        @test isa(ack.payload, AckPayload)
        @test ack.payload.acknowledged_message_id == "msg_test_001"
        @test ack.payload.status == "accepted"
    end
    
    # ========================================================================
    # Test 4: Create Error Message
    # ========================================================================
    @testset "Create Error Message" begin
        error_msg = create_error(
            "msg_bad_001",
            "VALIDATION_FAILED",
            "Invalid scene specification"
        )
        
        @test error_msg.envelope.kind == "error"
        @test isa(error_msg.payload, ErrorPayload)
        @test error_msg.payload.error_code == "VALIDATION_FAILED"
        @test error_msg.payload.recoverable == true
    end
    
    # ========================================================================
    # Test 5: MessagePack Encoding/Decoding - Hello
    # ========================================================================
    @testset "MessagePack Round-trip: Hello" begin
        msg = create_hello()
        
        # Encode
        binary = encode_messagepack(msg)
        @test isa(binary, Vector{UInt8})
        @test length(binary) > 0
        
        # Decode
        msg_restored = decode_messagepack(binary)
        @test msg_restored.envelope.kind == "hello"
        @test msg_restored.payload.protocol_version == msg.payload.protocol_version
        @test msg_restored.payload.runtime_name == msg.payload.runtime_name
    end
    
    # ========================================================================
    # Test 6: MessagePack Round-trip - Ack
    # ========================================================================
    @testset "MessagePack Round-trip: Ack" begin
        msg = create_ack("msg_test_123")
        
        binary = encode_messagepack(msg)
        msg_restored = decode_messagepack(binary)
        
        @test msg_restored.payload.acknowledged_message_id == "msg_test_123"
        @test msg_restored.payload.status == "accepted"
    end
    
    # ========================================================================
    # Test 7: MessagePack Round-trip - Error
    # ========================================================================
    @testset "MessagePack Round-trip: Error" begin
        msg = create_error("msg_err_456", "TEST_ERROR", "This is a test error")
        
        binary = encode_messagepack(msg)
        msg_restored = decode_messagepack(binary)
        
        @test msg_restored.payload.error_code == "TEST_ERROR"
        @test msg_restored.payload.error_message == "This is a test error"
        @test msg_restored.payload.recoverable == true
    end
    
    # ========================================================================
    # Test 8: Snapshot Payload
    # ========================================================================
    @testset "Snapshot Payload" begin
        snapshot = SnapshotPayload(
            "1.0.0",
            "scene_001",
            100.5,
            1000,
            1.0f0,
            "running",
            Dict{String, Any}[],
            Dict{String, Any}[],
            nothing,
            Dict{String, Any}[],
            String[],
            false
        )
        
        @test snapshot.simulation_time == 100.5
        @test snapshot.step_count == 1000
        @test snapshot.simulation_state == "running"
        @test length(snapshot.entities) == 0
    end
    
    # ========================================================================
    # Test 9: MessagePack Round-trip - Snapshot
    # ========================================================================
    @testset "MessagePack Round-trip: Snapshot" begin
        snapshot = SnapshotPayload(
            "1.0.0",
            "scene_002",
            50.25,
            500,
            0.5f0,
            "paused",
            Dict{String, Any}[Dict("id" => "elem_1", "occupancy" => 5)],
            Dict{String, Any}[Dict("id" => "ent_1", "position" => [1.0, 2.0])],
            nothing,
            Dict{String, Any}[],
            String[],
            false
        )
        
        env = MessageEnvelope(
            "1.0",
            "msg_snap_001",
            UInt64(floor(time() * 1000)),
            "julia_runtime",
            "godot_gui",
            "snapshot"
        )
        
        msg = Message(env, snapshot)
        binary = encode_messagepack(msg)
        msg_restored = decode_messagepack(binary)
        
        @test msg_restored.envelope.kind == "snapshot"
        @test msg_restored.payload.simulation_time == 50.25
        @test msg_restored.payload.step_count == 500
        @test length(msg_restored.payload.elements_state) == 1
    end
    
    # ========================================================================
    # Test 10: Delta Payload
    # ========================================================================
    @testset "Delta Payload" begin
        delta = DeltaPayload(
            "1.0.0",
            "scene_001",
            100.75,
            1001,
            "msg_snap_001",
            Dict{String, Any}[Dict("id" => "elem_1", "occupancy" => 6)],
            Dict{String, Any}[Dict("id" => "ent_2", "position" => [1.1, 2.1])],
            String[],
            Dict{String, Any}[],
            nothing,
            Dict{String, Any}[]
        )
        
        env = MessageEnvelope(
            "1.0",
            "msg_delta_001",
            UInt64(floor(time() * 1000)),
            "julia_runtime",
            "godot_gui",
            "delta"
        )
        
        msg = Message(env, delta)
        binary = encode_messagepack(msg)
        msg_restored = decode_messagepack(binary)
        
        @test msg_restored.envelope.kind == "delta"
        @test msg_restored.payload.parent_message_id == "msg_snap_001"
        @test length(msg_restored.payload.elements_changed) == 1
    end
    
    # ========================================================================
    # Test 11: Command Payload
    # ========================================================================
    @testset "Command Payload" begin
        cmd_payload = CommandPayload(
            "1.0.0",
            "control",
            Dict("action" => "play"),
            "scene_001",
            nothing
        )
        
        env = MessageEnvelope(
            "1.0",
            "msg_cmd_001",
            UInt64(floor(time() * 1000)),
            "godot_gui",
            "julia_runtime",
            "command"
        )
        
        msg = Message(env, cmd_payload)
        binary = encode_messagepack(msg)
        msg_restored = decode_messagepack(binary)
        
        @test msg_restored.envelope.kind == "command"
        @test msg_restored.payload.command_type == "control"
        @test msg_restored.payload.command["action"] == "play"
    end
    
    # ========================================================================
    # Test 12: JSON Debug Output
    # ========================================================================
    @testset "JSON Debug Output" begin
        msg = create_hello()
        json_str = to_debug_json(msg)
        
        @test isa(json_str, String)
        @test contains(json_str, "hello")
        @test contains(json_str, "protocol_version")
        
        # Verify it's valid JSON
        parsed = JSON.parse(json_str)
        @test parsed["kind"] == "hello"
    end
    
    # ========================================================================
    # Test 13: Protocol Version Checking
    # ========================================================================
    @testset "Protocol Version Checking" begin
        @test check_protocol_version("1.0") == true
        @test check_protocol_version("1.1") == true
        @test check_protocol_version("1.99") == true
        @test check_protocol_version("2.0") == false
        @test check_protocol_version("0.1") == false
    end
    
    # ========================================================================
    # Test 14: Message Round-trip with Complex Data
    # ========================================================================
    @testset "Complex Snapshot Round-trip" begin
        elements = [
            Dict("id" => "elem_1", "type" => "queue", "occupancy" => 5),
            Dict("id" => "elem_2", "type" => "server", "num_busy" => 2),
        ]
        
        entities = [
            Dict("id" => "ent_1", "position" => [1.0, 2.0], "velocity" => [0.5, 0.3]),
            Dict("id" => "ent_2", "position" => [2.0, 3.0], "velocity" => [0.2, 0.1]),
        ]
        
        snapshot = SnapshotPayload(
            "1.0.0",
            "scene_complex",
            123.45,
            1234,
            2.0f0,
            "running",
            elements,
            entities,
            nothing,
            Dict{String, Any}[],
            String[],
            false
        )
        
        env = MessageEnvelope(
            "1.0",
            "msg_complex_001",
            UInt64(floor(time() * 1000)),
            "julia_runtime",
            "godot_gui",
            "snapshot"
        )
        
        msg = Message(env, snapshot)
        binary = encode_messagepack(msg)
        msg_restored = decode_messagepack(binary)
        
        @test length(msg_restored.payload.elements_state) == 2
        @test length(msg_restored.payload.entities) == 2
        @test msg_restored.payload.entities[1]["position"] == [1.0, 2.0]
    end
    
end  # testset
