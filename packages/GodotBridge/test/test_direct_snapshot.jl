using Test
using GodotBridge
using MsgPack

@testset "Typed full snapshot transport" begin
    elements = [
        GodotBridge.ElementState("queue-1", "queue", UInt32(3), Dict{String, Any}("wait" => 1.5))
    ]
    entities = [
        GodotBridge.EntitySnapshot("agent-1", "customer", "queue-1", 2.0,
            [[1.0, 2.0], [2.0, 3.0]], Dict{String, Any}("priority" => 2))
    ]

    payload = direct_snapshot_payload("scene", 4.0, UInt64(7), elements, entities)
    @test payload.elements_state[1].element_id == "queue-1"
    @test payload.entities[1].id == "agent-1"

    bytes = encode_direct_snapshot(payload; message_id="snapshot-test")
    @test !isempty(bytes)
    decoded = MsgPack.unpack(bytes)
    @test decoded["kind"] == "snapshot"
    @test decoded["payload"]["scene_id"] == "scene"
    @test decoded["payload"]["elements_state"][1]["element_id"] == "queue-1"
    @test decoded["payload"]["entities"][1]["trajectory_2d"] == [[1.0, 2.0], [2.0, 3.0]]

    generic = GodotBridge.build_snapshot("scene", 4.0, UInt64(7), 1.0f0, "running", elements, entities)
    @test length(encode_direct_snapshot(generic)) > 0

end
