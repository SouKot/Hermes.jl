"""
    test_scenespec_typed.jl

Comprehensive test suite for Phase 7D-01 strongly-typed SceneSpec domain models,
input safety guardrails, normalization, and migration hooks.
"""

using Test
using GodotBridge

@testset "SceneSpec Strongly-Typed Core (Phase 7D-01)" begin
    fixtures_dir = normpath(joinpath(@__DIR__, "..", "..", "..", "godot", "fixtures", "scenespec"))
    fixture_files = [
        "minimal_des.json",
        "minimal_abm.json",
        "minimal_hybrid.json",
        "two_level_spatial.json",
        "invalid_connections.json",
        "missing_library.json",
        "future_fields.json"
    ]

    @testset "Golden Fixture Round-Trip via TypedSceneSpec: $f" for f in fixture_files
        path = joinpath(fixtures_dir, f)
        @test isfile(path)
        
        json_str = read(path, String)
        p1 = decode_scenespec_json(json_str)
        
        # Convert to typed representation
        typed_spec = to_typed_scenespec(p1)
        @test typed_spec isa TypedSceneSpec
        @test typed_spec.spec_version == "1.0.0"
        @test !isempty(typed_spec.scene.id)

        # Convert back to interchange payload
        p2 = to_payload(typed_spec)
        @test p2 isa SceneSpecPayload

        # Verify normalized semantic equality
        is_eq, err = scenespec_semantic_equal(p1, p2)
        @test is_eq
        @test isempty(err)

        # Direct dictionary parse convenience function
        dict_raw = scenespec_to_dict(p1)
        typed_from_dict = parse_typed_scenespec(dict_raw)
        @test typed_from_dict.scene.id == typed_spec.scene.id
        @test length(typed_from_dict.elements) == length(typed_spec.elements)
    end

    @testset "Unknown-Field and Extension Retention in Typed Model" begin
        future_path = joinpath(fixtures_dir, "future_fields.json")
        future_payload = decode_scenespec_json(read(future_path, String))
        typed = to_typed_scenespec(future_payload)

        # Root extensions
        @test haskey(typed.extensions, "future_distributed_engine")
        @test typed.extensions["future_distributed_engine"] == true
        @test haskey(typed.extensions, "cluster_target_nodes")

        # Scene extensions
        @test haskey(typed.scene.extensions, "organization_id")
        @test typed.scene.extensions["organization_id"] == "deepmind-research-advanced"
        @test haskey(typed.scene.extensions, "extensions")
        @test typed.scene.extensions["extensions"]["ai_copilot"]["confidence_score"] == 0.985

        # Element extensions
        first_elem = typed.elements[1]
        @test haskey(first_elem.extensions, "thermal_dissipation_watts")
        @test first_elem.extensions["thermal_dissipation_watts"] == 450.0
        @test haskey(first_elem.extensions, "extensions")
        @test first_elem.extensions["extensions"]["custom_vendor_blob"]["retry_limit"] == 3

        # Port extensions
        out_port = first_elem.output_ports[1]
        @test haskey(out_port.extensions, "bus_channel_id")
        @test out_port.extensions["bus_channel_id"] == 4
        @test out_port.extensions["security_token_required"] == false

        # Reconstructed payload preserves all fields
        reconstructed = to_payload(typed)
        rec_dict = scenespec_to_dict(reconstructed)
        @test rec_dict["future_distributed_engine"] == true
        @test rec_dict["elements"][1]["thermal_dissipation_watts"] == 450.0
        @test rec_dict["elements"][1]["output_ports"][1]["bus_channel_id"] == 4
    end

    @testset "Input Safety Guardrails" begin
        base_path = joinpath(fixtures_dir, "minimal_des.json")
        p = decode_scenespec_json(read(base_path, String))

        # 1. Max elements limit
        @test_throws ArgumentError to_typed_scenespec(p; max_elements=2)

        # 2. Max string length limit
        @test_throws ArgumentError to_typed_scenespec(p; max_string_len=10)

        # 3. Invalid ID regex
        bad_elem_dict = deepcopy(scenespec_to_dict(p))
        bad_elem_dict["elements"][1]["id"] = "bad id with spaces!"
        bad_payload = parse_scenespec(bad_elem_dict)
        @test_throws ArgumentError to_typed_scenespec(bad_payload)

        # 4. Excessive nesting depth
        deep_dict = Dict{String, Any}("a" => 1)
        curr = deep_dict
        for i in 1:40
            curr["nested"] = Dict{String, Any}("val" => i)
            curr = curr["nested"]
        end
        deep_payload = deepcopy(p)
        deep_payload.extensions["deep"] = deep_dict
        @test_throws ArgumentError to_typed_scenespec(deep_payload; max_depth=30)
    end

    @testset "Minor-Version Migration Hooks" begin
        # Legacy/draft input missing spatial, version, and defaults
        legacy_doc = Dict{String, Any}(
            "spec_version" => "0.9.0-draft",
            "scene" => Dict{String, Any}(
                "id" => "legacy_scene_01"
            ),
            "elements" => [
                Dict{String, Any}(
                    "id" => "legacy_worker",
                    "transform" => Dict{String, Any}(
                        "position" => [10.0, 20.0, 0.0]
                    )
                )
            ]
        )

        migrated = migrate_scenespec(legacy_doc; target_version="1.0.0")

        # Check version upgraded
        @test migrated["spec_version"] == "1.0.0"

        # Check spatial block backfilled with right-handed Z-up
        @test haskey(migrated, "spatial")
        @test migrated["spatial"]["coordinate_system"] == "right_handed_z_up"
        @test migrated["spatial"]["length_unit"] == "meters"
        @test migrated["spatial"]["origin"] == [0.0, 0.0, 0.0]
        @test length(migrated["spatial"]["levels"]) == 1
        @test migrated["spatial"]["levels"][1]["id"] == "level_ground"

        # Check element defaults backfilled
        mig_elem = migrated["elements"][1]
        @test mig_elem["level_id"] == "level_ground"
        @test mig_elem["transform"]["scale"] == [1.0, 1.0, 1.0]
        @test mig_elem["transform"]["rotation"] == [0.0, 0.0, 0.0]
        @test mig_elem["geometry"]["shape"] == "box"
        @test mig_elem["editor"]["collapsed"] == false

        # Check validation metadata backfilled
        @test haskey(migrated, "validation_metadata")
        @test migrated["validation_metadata"]["is_valid"] == true

        # Verify migrated dict parses cleanly into TypedSceneSpec
        typed_migrated = parse_typed_scenespec(migrated)
        @test typed_migrated isa TypedSceneSpec
        @test typed_migrated.elements[1].transform.scale == (1.0, 1.0, 1.0)
    end
end

