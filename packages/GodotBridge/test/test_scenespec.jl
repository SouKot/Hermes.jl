using Test
using GodotBridge
import JSON

@testset "SceneSpec v1 Contract and Golden Fixtures" begin

    fixtures_dir = normpath(joinpath(@__DIR__, "../../../godot/fixtures/scenespec"))
    fixture_files = [
        "minimal_des.json",
        "minimal_abm.json",
        "minimal_hybrid.json",
        "two_level_spatial.json",
        "invalid_connections.json",
        "missing_library.json",
        "future_fields.json"
    ]

    @testset "Fixtures Exist" begin
        for f in fixture_files
            path = joinpath(fixtures_dir, f)
            @test isfile(path)
        end
    end

    @testset "Decode and Semantic Equality on All Fixtures" begin
        for f in fixture_files
            path = joinpath(fixtures_dir, f)
            json_str = read(path, String)
            raw_dict = JSON.parse(json_str)

            # 1. Parse into SceneSpecPayload
            spec = decode_scenespec_json(json_str)
            @test spec isa SceneSpecPayload
            @test spec.spec_version == "1.0.0"

            # 2. Semantic equality between raw dict and parsed spec
            eq, diff = scenespec_semantic_equal(raw_dict, spec)
            @test eq
            if !eq
                println("Mismatch in $f between raw JSON and spec: $diff")
            end

            # 3. JSON round-trip: spec -> json -> spec
            re_json = encode_scenespec_json(spec; pretty=true)
            re_spec = decode_scenespec_json(re_json)
            eq_json, diff_json = scenespec_semantic_equal(spec, re_spec)
            @test eq_json
            if !eq_json
                println("JSON round-trip mismatch in $f: $diff_json")
            end

            # 4. MessagePack round-trip: spec -> msgpack bytes -> spec
            mp_bytes = encode_scenespec_msgpack(spec)
            mp_spec = decode_scenespec_msgpack(mp_bytes)
            eq_mp, diff_mp = scenespec_semantic_equal(spec, mp_spec)
            @test eq_mp
            if !eq_mp
                println("MessagePack round-trip mismatch in $f: $diff_mp")
            end

            # 5. Full Message Envelope Round-trip
            env = MessageEnvelope(
                "1.0",
                "msg_test_$(f)",
                UInt64(floor(time() * 1000)),
                "test_suite",
                "godot_gui",
                "scene_spec"
            )
            msg = Message(env, spec)
            encoded_msg = encode_messagepack(msg)
            decoded_msg = decode_messagepack(encoded_msg)
            @test decoded_msg.payload isa SceneSpecPayload
            eq_env, diff_env = scenespec_semantic_equal(spec, decoded_msg.payload)
            @test eq_env
        end
    end

    @testset "Z-Up Coordinate System and Spatial Levels" begin
        path_des = joinpath(fixtures_dir, "minimal_des.json")
        spec_des = decode_scenespec_json(read(path_des, String))
        @test spec_des.spatial !== nothing
        @test spec_des.spatial["coordinate_system"] == "right_handed_z_up"
        @test length(spec_des.spatial["levels"]) == 1
        @test spec_des.spatial["levels"][1]["elevation"] == 0.0

        path_two_level = joinpath(fixtures_dir, "two_level_spatial.json")
        spec_two_level = decode_scenespec_json(read(path_two_level, String))
        @test spec_two_level.spatial !== nothing
        levels = spec_two_level.spatial["levels"]
        @test length(levels) == 2
        @test levels[1]["id"] == "level_ground" && levels[1]["elevation"] == 0.0
        @test levels[2]["id"] == "level_mezzanine" && levels[2]["elevation"] == 3.5

        # Check lift connector
        elems = Dict(e["id"] => e for e in spec_two_level.elements)
        @test haskey(elems, "elem_vertical_lift")
        lift = elems["elem_vertical_lift"]
        @test lift["vertical_extent"]["base_elevation"] == 0.0
        @test lift["vertical_extent"]["height"] == 3.5
        @test lift["vertical_extent"]["source_level_id"] == "level_ground"
        @test lift["vertical_extent"]["target_level_id"] == "level_mezzanine"
    end

    @testset "Unknown-Field Preservation (future_fields.json)" begin
        path_future = joinpath(fixtures_dir, "future_fields.json")
        json_str = read(path_future, String)
        spec = decode_scenespec_json(json_str)

        # Root unknown fields captured in extensions
        @test haskey(spec.extensions, "future_distributed_engine")
        @test spec.extensions["future_distributed_engine"] == true
        @test haskey(spec.extensions, "cluster_target_nodes")
        @test spec.extensions["cluster_target_nodes"] == ["compute_worker_01", "compute_worker_02"]

        # Element unknown fields preserved
        elem = spec.elements[1]
        @test haskey(elem, "thermal_dissipation_watts")
        @test elem["thermal_dissipation_watts"] == 450.0
        @test haskey(elem, "maintenance_schedule_url")

        # Port unknown fields preserved
        port = elem["output_ports"][1]
        @test haskey(port, "bus_channel_id")
        @test port["bus_channel_id"] == 4

        # Round-trip back to dict and re-check root keys
        dict = scenespec_to_dict(spec)
        @test haskey(dict, "future_distributed_engine")
        @test dict["future_distributed_engine"] == true
        @test haskey(dict, "cluster_target_nodes")

        # Re-encode and decode
        re_spec = decode_scenespec_json(encode_scenespec_json(spec))
        eq, diff = scenespec_semantic_equal(spec, re_spec)
        @test eq
    end

    @testset "Draft Error Preservation (invalid_connections.json)" begin
        path_invalid = joinpath(fixtures_dir, "invalid_connections.json")
        spec = decode_scenespec_json(read(path_invalid, String))
        @test spec.validation_metadata["is_valid"] == false
        @test spec.validation_metadata["diagnostic_count"] == 2
        @test length(spec.connections) == 2
        @test spec.connections[1]["target_port"] == "non_existent_port_xyz"

        # Round trip preserves invalid connections
        re_spec = decode_scenespec_json(encode_scenespec_json(spec))
        @test length(re_spec.connections) == 2
        @test re_spec.connections[1]["target_port"] == "non_existent_port_xyz"
    end

    @testset "Semantic Comparison Sensitivity & Invariances" begin
        path_des = joinpath(fixtures_dir, "minimal_des.json")
        spec_1 = decode_scenespec_json(read(path_des, String))
        spec_2 = decode_scenespec_json(read(path_des, String))

        # Identity
        eq, _ = scenespec_semantic_equal(spec_1, spec_2)
        @test eq

        # Invariant to element order in array
        spec_reversed = SceneSpecPayload(
            spec_1.spec_version,
            spec_1.scene,
            spec_1.simulation,
            spec_1.abm_config,
            spec_1.spatial,
            reverse(spec_1.elements),
            spec_1.connections,
            spec_1.subgraphs,
            spec_1.overlays,
            spec_1.validation_metadata,
            spec_1.extensions
        )
        eq_rev, _ = scenespec_semantic_equal(spec_1, spec_reversed)
        @test eq_rev

        # Sensitive to position mutation
        mutated_elems = deepcopy(spec_1.elements)
        mutated_elems[1]["transform"]["position"][1] += 5.0
        spec_mutated = SceneSpecPayload(
            spec_1.spec_version,
            spec_1.scene,
            spec_1.simulation,
            spec_1.abm_config,
            spec_1.spatial,
            mutated_elems,
            spec_1.connections,
            spec_1.subgraphs,
            spec_1.overlays,
            spec_1.validation_metadata,
            spec_1.extensions
        )
        eq_mut, reason = scenespec_semantic_equal(spec_1, spec_mutated)
        @test !eq_mut
        @test occursin("numeric mismatch", reason)
        @test occursin("elem_src_01", reason)
    end

end
