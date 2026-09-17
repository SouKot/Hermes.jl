"""
    runtests.jl

Test suite for GodotBridge package.
Tests protocol types, serialization, and server functionality.
"""

using Test
using GodotBridge

@testset "GodotBridge Protocol Tests" begin

    # ============================================================================
    # Test 1: Message Envelope Creation
    # ============================================================================
    @testset "MessageEnvelope Creation" begin
        env = MessageEnvelope("1.0", "msg_001", UInt64(1000), "julia", "godot", "hello")
        @test env.envelope_version == "1.0"
        @test env.message_id == "msg_001"
        @test env.sender == "julia"
    end

    # ============================================================================
    # Test 2: Hello Message Creation
    # ============================================================================
    @testset "Hello Message Creation" begin
        hello = create_hello(runtime_version="0.1.0")
        @test hello.envelope.kind == "hello"
        @test isa(hello.payload, HelloPayload)
        @test hello.payload.protocol_version == "1.0.0"
        @test hello.payload.runtime_version == "0.1.0"
        @test "snapshot_streaming" in hello.payload.capabilities
    end

    # ============================================================================
    # Test 3: Ack Message Creation
    # ============================================================================
    @testset "Ack Message Creation" begin
        ack = create_ack("msg_001", status="accepted", details="OK")
        @test ack.envelope.kind == "ack"
        @test isa(ack.payload, AckPayload)
        @test ack.payload.acknowledged_message_id == "msg_001"
        @test ack.payload.status == "accepted"
    end

    # ============================================================================
    # Test 4: Error Message Creation
    # ============================================================================
    @testset "Error Message Creation" begin
        error_msg = create_error(
            "msg_001",
            "VALIDATION_FAILED",
            "Invalid scene spec",
            recoverable=true
        )
        @test error_msg.envelope.kind == "error"
        @test isa(error_msg.payload, ErrorPayload)
        @test error_msg.payload.error_code == "VALIDATION_FAILED"
        @test error_msg.payload.recoverable == true
    end

    # ============================================================================
    # Test 5: Snapshot Message
    # ============================================================================
    @testset "Snapshot Message Creation" begin
        snapshot = SnapshotPayload(
            snapshot_version="1.0.0",
            scene_id="scene_001",
            simulation_time=10.5,
            step_count=UInt64(105),
            clock_speed=1.0f0,
            simulation_state="running",
            elements_state=[],
            entities=[],
            abm_state=nothing,
            overlays=[],
            warnings=[],
            truncated=false
        )
        @test isa(snapshot, SnapshotPayload)
        @test snapshot.scene_id == "scene_001"
        @test snapshot.simulation_time == 10.5
    end

    # ============================================================================
    # Test 6: MessagePack Round-Trip
    # ============================================================================
    @testset "MessagePack Serialization Round-Trip" begin
        # Create a hello message
        original = create_hello(runtime_version="0.2.0")
        
        # Encode to MessagePack
        binary = encode_messagepack(original)
        @test isa(binary, Vector{UInt8})
        @test length(binary) > 0
        
        # Decode back
        restored = decode_messagepack(binary)
        @test restored.envelope.kind == "hello"
        @test restored.payload.runtime_version == "0.2.0"
        @test restored.payload.protocol_version == original.payload.protocol_version
    end

    # ============================================================================
    # Test 7: Snapshot MessagePack Round-Trip
    # ============================================================================
    @testset "Snapshot MessagePack Round-Trip" begin
        snapshot = SnapshotPayload(
            snapshot_version="1.0.0",
            scene_id="scene_42",
            simulation_time=99.9,
            step_count=UInt64(999),
            clock_speed=2.5f0,
            simulation_state="paused",
            elements_state=Dict("elem_1" => 10),
            entities=Dict("ent_1" => "data"),
            abm_state=nothing,
            overlays=[Dict("overlay_id" => "ov_1")],
            warnings=["warning_1"],
            truncated=false
        )
        
        msg = Message(
            MessageEnvelope("1.0", "snap_msg", UInt64(floor(time() * 1000)), "julia", "godot", "snapshot"),
            snapshot
        )
        
        # Round trip
        binary = encode_messagepack(msg)
        restored = decode_messagepack(binary)
        
        @test restored.envelope.kind == "snapshot"
        @test restored.payload.scene_id == "scene_42"
        @test restored.payload.simulation_time == 99.9
        @test restored.payload.clock_speed == 2.5f0
    end

    # ============================================================================
    # Test 8: Command Message
    # ============================================================================
    @testset "Command Message Serialization" begin
        cmd = CommandPayload(
            command_version="1.0.0",
            command_type="control",
            command=Dict("action" => "play"),
            scene_id="scene_001",
            apply_at_time=nothing
        )
        
        msg = Message(
            MessageEnvelope("1.0", "cmd_msg", UInt64(floor(time() * 1000)), "godot", "julia", "command"),
            cmd
        )
        
        binary = encode_messagepack(msg)
        restored = decode_messagepack(binary)
        
        @test restored.payload.command_type == "control"
        @test restored.payload.command["action"] == "play"
    end

    # ============================================================================
    # Test 9: JSON Debug Output
    # ============================================================================
    @testset "JSON Debug Output" begin
        hello = create_hello()
        json_str = to_debug_json(hello, pretty=true)
        
        @test isa(json_str, String)
        @test contains(json_str, "hello")
        @test contains(json_str, "julia_runtime")
    end

    # ============================================================================
    # Test 10: Message to Debug Dict
    # ============================================================================
    @testset "Message Debug Dict Conversion" begin
        snapshot = SnapshotPayload(
            "1.0.0", "scene_1", 5.0, UInt64(50), 1.0f0, "running",
            [], [], nothing, [], [], false
        )
        msg = Message(
            MessageEnvelope("1.0", "msg_id", UInt64(1000), "j", "g", "snapshot"),
            snapshot
        )
        
        json_str = to_debug_json(msg, pretty=false)
        @test contains(json_str, "SnapshotPayload")
        @test contains(json_str, "scene_1")
    end

end  # End of testset

println("\n✓ All GodotBridge protocol tests passed!")
