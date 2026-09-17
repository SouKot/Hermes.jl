"""
Integration tests for Phase 7B.2 components.

Tests the complete flow:
- Snapshot building
- Delta computation
- Command dispatch
- Server integration (if running)
"""

import UUIDs: uuid4
using Test

# Include modules
include("../src/protocol/envelope.jl")
include("../src/protocol/serialization.jl")
include("../src/snapshot/snapshot_builder.jl")
include("../src/snapshot/delta_builder.jl")
include("../src/commands/command_handler.jl")

@testset "Phase 7B.2 Integration Tests" begin
    
    # ====================================================================
    # Test 1: Snapshot Builder - Building from scratch
    # ====================================================================
    @testset "Snapshot Builder - Basic" begin
        scene_id = "scene_001"
        sim_time = 100.5
        step_count = UInt64(1005)
        
        # Create element states
        element_states = [
            Dict("id" => "queue_1", "element_type" => "queue", 
                 "occupancy" => 5, "custom_metrics" => Dict("avg_wait" => 12.3))
        ]
        
        # Create entity snapshots
        entities = [
            Dict("id" => "ent_1", "entity_type" => "customer", 
                 "current_location" => "queue_1", "arrival_time" => 10.2,
                 "trajectory_2d" => [[1.0, 2.0], [1.1, 2.1]], 
                 "properties" => Dict("priority" => 1))
        ]
        
        # Build snapshot
        snapshot = SnapshotPayload(
            snapshot_id = string(uuid4()),
            scene_id = scene_id,
            simulation_time = sim_time,
            step_count = step_count,
            clock_speed = 1.0f0,
            simulation_state = "running",
            elements_state = element_states,
            entities = entities
        )
        
        @test snapshot.scene_id == scene_id
        @test snapshot.simulation_time == sim_time
        @test snapshot.step_count == step_count
        @test length(snapshot.elements_state) == 1
        @test length(snapshot.entities) == 1
        @test snapshot.simulation_state == "running"
    end
    
    # ====================================================================
    # Test 2: Delta Builder - Element changes
    # ====================================================================
    @testset "Delta Builder - Element Changes" begin
        # Create first snapshot
        snapshot1 = SnapshotPayload(
            snapshot_id = string(uuid4()),
            scene_id = "scene_001",
            simulation_time = 100.0,
            step_count = UInt64(1000),
            clock_speed = 1.0f0,
            simulation_state = "running",
            elements_state = [
                Dict("id" => "queue_1", "element_type" => "queue", 
                     "occupancy" => 5, "custom_metrics" => Dict("avg_wait" => 12.3))
            ],
            entities = []
        )
        
        # Create second snapshot with changed element
        snapshot2 = SnapshotPayload(
            snapshot_id = string(uuid4()),
            scene_id = "scene_001",
            simulation_time = 101.0,
            step_count = UInt64(1001),
            clock_speed = 1.0f0,
            simulation_state = "running",
            elements_state = [
                Dict("id" => "queue_1", "element_type" => "queue", 
                     "occupancy" => 7, "custom_metrics" => Dict("avg_wait" => 15.5))
            ],
            entities = []
        )
        
        # Compute delta
        delta = DeltaBuilder.build_delta(snapshot1, snapshot2)
        
        @test delta.parent_snapshot_id == snapshot1.snapshot_id
        @test length(delta.elements_changed) == 1
        @test delta.elements_changed[1].change_type == "updated"
        @test delta.elements_changed[1].occupancy_before == 5
        @test delta.elements_changed[1].occupancy_after == 7
        
        summary = DeltaBuilder.get_change_summary(delta)
        @test summary["elements_changed_count"] == 1
        @test summary["elements_updated_count"] == 1
    end
    
    # ====================================================================
    # Test 3: Delta Builder - Entity arrivals and departures
    # ====================================================================
    @testset "Delta Builder - Entity Lifecycle" begin
        # First snapshot with one entity
        snapshot1 = SnapshotPayload(
            snapshot_id = string(uuid4()),
            scene_id = "scene_001",
            simulation_time = 100.0,
            step_count = UInt64(1000),
            clock_speed = 1.0f0,
            simulation_state = "running",
            elements_state = [],
            entities = [
                Dict("id" => "ent_1", "entity_type" => "customer",
                     "current_location" => "queue_1", "arrival_time" => 50.0,
                     "trajectory_2d" => [[1.0, 2.0]], "properties" => Dict())
            ]
        )
        
        # Second snapshot with entity moved and new entity arrived
        snapshot2 = SnapshotPayload(
            snapshot_id = string(uuid4()),
            scene_id = "scene_001",
            simulation_time = 101.0,
            step_count = UInt64(1001),
            clock_speed = 1.0f0,
            simulation_state = "running",
            elements_state = [],
            entities = [
                Dict("id" => "ent_1", "entity_type" => "customer",
                     "current_location" => "queue_2", "arrival_time" => 50.0,
                     "trajectory_2d" => [[1.0, 2.0], [2.0, 3.0]], "properties" => Dict()),
                Dict("id" => "ent_2", "entity_type" => "customer",
                     "current_location" => "queue_1", "arrival_time" => 101.0,
                     "trajectory_2d" => [[3.0, 4.0]], "properties" => Dict())
            ]
        )
        
        delta = DeltaBuilder.build_delta(snapshot1, snapshot2)
        
        @test length(delta.entities_added) == 1  # ent_2 added
        @test delta.entities_added[1].entity_id == "ent_2"
        
        @test length(delta.entities_moved) == 1  # ent_1 moved
        @test delta.entities_moved[1].entity_id == "ent_1"
        @test delta.entities_moved[1].previous_location == "queue_1"
        @test delta.entities_moved[1].current_location == "queue_2"
        
        summary = DeltaBuilder.get_change_summary(delta)
        @test summary["entities_added_count"] == 1
        @test summary["entities_moved_count"] == 1
    end
    
    # ====================================================================
    # Test 4: Delta Builder - Entity departure
    # ====================================================================
    @testset "Delta Builder - Entity Departure" begin
        snapshot1 = SnapshotPayload(
            snapshot_id = string(uuid4()),
            scene_id = "scene_001",
            simulation_time = 100.0,
            step_count = UInt64(1000),
            clock_speed = 1.0f0,
            simulation_state = "running",
            elements_state = [],
            entities = [
                Dict("id" => "ent_1", "entity_type" => "customer",
                     "current_location" => "queue_1", "arrival_time" => 50.0,
                     "trajectory_2d" => [[1.0, 2.0]], "properties" => Dict())
            ]
        )
        
        # Entity is gone
        snapshot2 = SnapshotPayload(
            snapshot_id = string(uuid4()),
            scene_id = "scene_001",
            simulation_time = 101.0,
            step_count = UInt64(1001),
            clock_speed = 1.0f0,
            simulation_state = "running",
            elements_state = [],
            entities = []
        )
        
        delta = DeltaBuilder.build_delta(snapshot1, snapshot2)
        
        @test length(delta.entities_removed) == 1
        @test delta.entities_removed[1].entity_id == "ent_1"
        @test delta.entities_removed[1].change_type == "departed"
    end
    
    # ====================================================================
    # Test 5: Command Handler - Validation
    # ====================================================================
    @testset "Command Handler - Validation" begin
        # Valid play command
        play_cmd = CommandPayload(
            command_type = "play",
            command = Dict(),
            apply_at_time = nothing
        )
        is_valid, msg = CommandHandler.validate_command(play_cmd)
        @test is_valid
        
        # Invalid command type
        bad_cmd = CommandPayload(
            command_type = "invalid_action",
            command = Dict(),
            apply_at_time = nothing
        )
        is_valid, msg = CommandHandler.validate_command(bad_cmd)
        @test !is_valid
        @test contains(msg, "Unknown command type")
        
        # Valid set_clock_speed
        speed_cmd = CommandPayload(
            command_type = "set_clock_speed",
            command = Dict("speed" => 2.0),
            apply_at_time = nothing
        )
        is_valid, msg = CommandHandler.validate_command(speed_cmd)
        @test is_valid
        
        # Invalid set_clock_speed (missing speed)
        bad_speed_cmd = CommandPayload(
            command_type = "set_clock_speed",
            command = Dict(),
            apply_at_time = nothing
        )
        is_valid, msg = CommandHandler.validate_command(bad_speed_cmd)
        @test !is_valid
    end
    
    # ====================================================================
    # Test 6: Command Handler - Dispatch play/pause
    # ====================================================================
    @testset "Command Handler - Play/Pause Dispatch" begin
        # Play command
        ctx = CommandHandler.CommandContext(
            command_id = string(uuid4()),
            command_type = "play",
            parameters = Dict(),
            sender = "godot",
            timestamp = now(),
            execution_state = Dict()
        )
        
        result = CommandHandler.dispatch_command(ctx)
        @test result.success
        @test result.command_type == "play"
        @test result.status == "executed"
        @test result.result_data["new_state"] == "running"
        
        # Pause command
        ctx_pause = CommandHandler.CommandContext(
            command_id = string(uuid4()),
            command_type = "pause",
            parameters = Dict(),
            sender = "godot",
            timestamp = now(),
            execution_state = Dict()
        )
        
        result_pause = CommandHandler.dispatch_command(ctx_pause)
        @test result_pause.success
        @test result_pause.result_data["new_state"] == "paused"
    end
    
    # ====================================================================
    # Test 7: Command Handler - Clock speed dispatch
    # ====================================================================
    @testset "Command Handler - Clock Speed" begin
        # Valid clock speed
        ctx = CommandHandler.CommandContext(
            command_id = string(uuid4()),
            command_type = "set_clock_speed",
            parameters = Dict("speed" => 2.0),
            sender = "godot",
            timestamp = now(),
            execution_state = Dict()
        )
        
        result = CommandHandler.dispatch_command(ctx)
        @test result.success
        @test result.result_data["new_speed"] == 2.0
        
        # Invalid clock speed (too high)
        ctx_bad = CommandHandler.CommandContext(
            command_id = string(uuid4()),
            command_type = "set_clock_speed",
            parameters = Dict("speed" => 100.0),
            sender = "godot",
            timestamp = now(),
            execution_state = Dict()
        )
        
        result_bad = CommandHandler.dispatch_command(ctx_bad)
        @test !result_bad.success
        @test result_bad.error_code == "INVALID_SPEED"
    end
    
    # ====================================================================
    # Test 8: Command Handler - Message creation
    # ====================================================================
    @testset "Command Handler - Message Creation" begin
        ctx = CommandHandler.CommandContext(
            command_id = string(uuid4()),
            command_type = "play",
            parameters = Dict(),
            sender = "godot",
            timestamp = now(),
            execution_state = Dict()
        )
        
        result = CommandHandler.dispatch_command(ctx)
        
        # Create Ack message
        ack_msg = CommandHandler.create_command_ack(result)
        @test ack_msg.kind == "ack"
        @test ack_msg.payload.acknowledged_message_id == result.command_id
        @test ack_msg.payload.status == "executed"
        
        # Create error message
        error_result = CommandHandler.CommandResult(
            false, string(uuid4()), "reset", "error",
            Dict(), "RESET_FAILED", "Simulation locked", "Unlock simulation first"
        )
        error_msg = CommandHandler.create_command_error(error_result)
        @test error_msg.kind == "error"
        @test error_msg.payload.error_code == "RESET_FAILED"
        @test !isnothing(error_msg.payload.recovery_suggestion)
    end
    
    # ====================================================================
    # Test 9: Command Handler - Summary
    # ====================================================================
    @testset "Command Handler - Summary" begin
        ctx = CommandHandler.CommandContext(
            command_id = string(uuid4()),
            command_type = "step",
            parameters = Dict(),
            sender = "godot",
            timestamp = now(),
            execution_state = Dict()
        )
        
        result = CommandHandler.dispatch_command(ctx)
        summary = CommandHandler.get_command_summary(result)
        
        @test haskey(summary, "success")
        @test haskey(summary, "command_type")
        @test haskey(summary, "message")
        @test summary["success"] == true
        @test summary["command_type"] == "step"
    end
    
    # ====================================================================
    # Test 10: Full round-trip - Delta message creation
    # ====================================================================
    @testset "Full Round-trip - Delta Message" begin
        # Create two snapshots
        snapshot1 = SnapshotPayload(
            snapshot_id = string(uuid4()),
            scene_id = "scene_001",
            simulation_time = 100.0,
            step_count = UInt64(1000),
            clock_speed = 1.0f0,
            simulation_state = "running",
            elements_state = [
                Dict("id" => "q1", "element_type" => "queue",
                     "occupancy" => 5, "custom_metrics" => Dict("avg" => 10.0))
            ],
            entities = [
                Dict("id" => "e1", "entity_type" => "customer",
                     "current_location" => "q1", "arrival_time" => 50.0,
                     "trajectory_2d" => [[1.0, 2.0]], "properties" => Dict())
            ]
        )
        
        snapshot2 = SnapshotPayload(
            snapshot_id = string(uuid4()),
            scene_id = "scene_001",
            simulation_time = 101.0,
            step_count = UInt64(1001),
            clock_speed = 1.0f0,
            simulation_state = "running",
            elements_state = [
                Dict("id" => "q1", "element_type" => "queue",
                     "occupancy" => 6, "custom_metrics" => Dict("avg" => 11.0))
            ],
            entities = [
                Dict("id" => "e1", "entity_type" => "customer",
                     "current_location" => "q2", "arrival_time" => 50.0,
                     "trajectory_2d" => [[1.0, 2.0], [2.0, 3.0]], "properties" => Dict())
            ]
        )
        
        # Compute delta
        delta = DeltaBuilder.build_delta(snapshot1, snapshot2)
        
        # Create message
        msg = DeltaBuilder.create_delta_message(delta)
        
        @test msg.kind == "delta"
        @test msg.payload.parent_snapshot_id == snapshot1.snapshot_id
        @test !isempty(msg.payload.elements_changed)
        @test !isempty(msg.payload.entities_moved)
        
        # Serialize and deserialize
        encoded = encode_messagepack(msg)
        @test isa(encoded, Vector{UInt8})
        
        decoded = decode_messagepack(encoded)
        @test decoded.kind == "delta"
        @test decoded.payload.parent_snapshot_id == snapshot1.snapshot_id
    end
    
    # ====================================================================
    # Test 11: Protocol serialization round-trip
    # ====================================================================
    @testset "Protocol Serialization Round-trip" begin
        # Create snapshot payload
        payload = SnapshotPayload(
            snapshot_id = string(uuid4()),
            scene_id = "scene_001",
            simulation_time = 100.5,
            step_count = UInt64(1005),
            clock_speed = 1.0f0,
            simulation_state = "running",
            elements_state = [Dict("id" => "q1", "element_type" => "queue",
                                   "occupancy" => 5, "custom_metrics" => Dict())],
            entities = []
        )
        
        # Create message
        msg = Message(
            protocol_version = "1.0",
            message_id = string(uuid4()),
            timestamp = now(),
            sender = "bridge",
            receiver = "godot",
            kind = "snapshot",
            payload = payload
        )
        
        # Encode and decode
        encoded = encode_messagepack(msg)
        decoded = decode_messagepack(encoded)
        
        @test decoded.protocol_version == "1.0"
        @test decoded.sender == "bridge"
        @test decoded.receiver == "godot"
        @test decoded.kind == "snapshot"
        @test decoded.payload.scene_id == "scene_001"
        @test decoded.payload.simulation_time == 100.5
    end
    
end  # @testset

println("\n✓ All Phase 7B.2 integration tests passed!")
