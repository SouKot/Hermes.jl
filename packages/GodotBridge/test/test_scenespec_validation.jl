"""
    test_scenespec_validation.jl

Unit tests for SceneSpec v1 Semantic Validation & Diagnostics Engine (Phase 7D-02).
Tests all 12 rule checks, fixture validation parity, suggested fixes, and metadata updates.
"""

using Test
using GodotBridge

@testset "SceneSpec Semantic Validation (Phase 7D-02)" begin
    fixtures_dir = normpath(joinpath(@__DIR__, "..", "..", "..", "godot", "fixtures", "scenespec"))

    @testset "Valid Golden Fixtures Have Zero Errors" begin
        valid_files = [
            "minimal_des.json",
            "minimal_abm.json",
            "minimal_hybrid.json",
            "two_level_spatial.json",
            "missing_library.json",
            "future_fields.json"
        ]

        for fname in valid_files
            path = joinpath(fixtures_dir, fname)
            payload = decode_scenespec_json(read(path, String))
            val_meta = validate_scenespec(payload)

            @test val_meta isa ValidationMetadataRecord
            @test val_meta.is_valid == true
            @test is_scene_valid(payload) == true
            @test isempty(val_meta.diagnostics)
            @test val_meta.diagnostic_count == 0
            @test !isempty(val_meta.last_validated_at)
        end
    end

    @testset "Golden Fixture Parity: invalid_connections.json" begin
        inv_path = joinpath(fixtures_dir, "invalid_connections.json")
        payload = decode_scenespec_json(read(inv_path, String))
        val_meta = validate_scenespec(payload)

        @test val_meta.is_valid == false
        @test is_scene_valid(payload) == false
        @test val_meta.diagnostic_count == 2
        @test length(val_meta.diagnostics) == 2

        d1 = val_meta.diagnostics[1]
        @test d1.rule_id == "PORT_001_NOT_FOUND"
        @test d1.severity == :error
        @test d1.object_kind == "connection"
        @test d1.object_id == "conn_bad_target_port"
        @test d1.property_path == "target_port"
        @test contains(d1.message, "non_existent_port_xyz")
        @test d1.suggested_fix == "Connect to 'flow_in'"

        d2 = val_meta.diagnostics[2]
        @test d2.rule_id == "PORT_002_KIND_MISMATCH"
        @test d2.severity == :error
        @test d2.object_kind == "connection"
        @test d2.object_id == "conn_incompatible_kinds"
        @test d2.property_path == "target_port"
        @test contains(d2.message, "Cannot connect flow output port to metric output port")
        @test d2.suggested_fix == "Connect to a compatible flow input port"
    end

    @testset "Rule: ID_001_DUPLICATE" begin
        base_dict = scenespec_to_dict(decode_scenespec_json(read(joinpath(fixtures_dir, "minimal_des.json"), String)))

        # Duplicate element ID
        d1 = deepcopy(base_dict)
        push!(d1["elements"], deepcopy(d1["elements"][1]))
        v1 = validate_scenespec(d1)
        @test v1.is_valid == false
        @test any(d -> d.rule_id == "ID_001_DUPLICATE" && d.object_kind == "element", v1.diagnostics)

        # Duplicate connection ID
        d2 = deepcopy(base_dict)
        dup_conn = deepcopy(d2["connections"][1])
        dup_conn["source_element"] = "elem_q_01"
        push!(d2["connections"], dup_conn)
        v2 = validate_scenespec(d2)
        @test any(d -> d.rule_id == "ID_001_DUPLICATE" && d.object_kind == "connection", v2.diagnostics)

        # Duplicate port ID within an element
        d3 = deepcopy(base_dict)
        dup_port = deepcopy(d3["elements"][1]["output_ports"][1])
        push!(d3["elements"][1]["output_ports"], dup_port)
        v3 = validate_scenespec(d3)
        @test any(d -> d.rule_id == "ID_001_DUPLICATE" && d.object_kind == "port", v3.diagnostics)
    end

    @testset "Rule: ELEM_001_LEVEL_NOT_FOUND" begin
        base_dict = scenespec_to_dict(decode_scenespec_json(read(joinpath(fixtures_dir, "minimal_des.json"), String)))
        base_dict["elements"][1]["level_id"] = "non_existent_level_404"
        v = validate_scenespec(base_dict)
        @test v.is_valid == false
        d = findfirst(d -> d.rule_id == "ELEM_001_LEVEL_NOT_FOUND", v.diagnostics)
        @test d !== nothing
        @test v.diagnostics[d].object_id == base_dict["elements"][1]["id"]
        @test contains(v.diagnostics[d].suggested_fix, "level_ground")
    end

    @testset "Rule: PORT_003_DIRECTION_MISMATCH" begin
        base_dict = scenespec_to_dict(decode_scenespec_json(read(joinpath(fixtures_dir, "minimal_des.json"), String)))
        # Connect output port to another output port
        base_dict["connections"][1]["target_port"] = "out"
        v = validate_scenespec(base_dict)
        @test v.is_valid == false
        d = findfirst(d -> d.rule_id == "PORT_003_DIRECTION_MISMATCH", v.diagnostics)
        @test d !== nothing
        @test contains(v.diagnostics[d].message, "direction 'output'")
    end

    @testset "Rule: PORT_004_CARDINALITY_EXCEEDED" begin
        base_dict = scenespec_to_dict(decode_scenespec_json(read(joinpath(fixtures_dir, "minimal_des.json"), String)))
        # elem_srv_01 input port "in" has cardinality "one". Add a second connection to it
        second_conn = Dict{String, Any}(
            "id" => "conn_second_into_server",
            "source_element" => "elem_src_01",
            "source_port" => "out",
            "target_element" => "elem_srv_01",
            "target_port" => "in",
            "link_type" => "flow",
            "enabled" => true,
            "ordering" => 2
        )
        push!(base_dict["connections"], second_conn)
        v = validate_scenespec(base_dict)
        @test v.is_valid == false
        d = findfirst(d -> d.rule_id == "PORT_004_CARDINALITY_EXCEEDED", v.diagnostics)
        @test d !== nothing
        @test v.diagnostics[d].object_id == "in"
        @test contains(v.diagnostics[d].message, "cardinality 'one'")
    end

    @testset "Rule: PORT_005_REQUIRED_UNCONNECTED (Strict Mode)" begin
        base_dict = scenespec_to_dict(decode_scenespec_json(read(joinpath(fixtures_dir, "minimal_des.json"), String)))
        # Remove all connections
        base_dict["connections"] = []
        # Non-strict mode permits draft scenes
        v_loose = validate_scenespec(base_dict; strict=false)
        @test !any(d -> d.rule_id == "PORT_005_REQUIRED_UNCONNECTED", v_loose.diagnostics)

        # Strict mode checks completeness
        v_strict = validate_scenespec(base_dict; strict=true)
        @test any(d -> d.rule_id == "PORT_005_REQUIRED_UNCONNECTED", v_strict.diagnostics)
    end

    @testset "Rule: GRAPH_002_ZERO_DELAY_CYCLE (Deadlock / Livelock)" begin
        # Construct 2 routers connected in a zero-delay feedback cycle
        router_a = Dict{String, Any}(
            "id" => "router_01", "name" => "Router A", "kind" => "router",
            "library" => "SimElements/DES", "library_version" => "0.1.0", "level_id" => "level_ground",
            "transform" => Dict("position" => [0.0, 0.0, 0.0], "rotation" => [0.0, 0.0, 0.0], "scale" => [1.0, 1.0, 1.0]),
            "geometry" => Dict("shape" => "box", "dimensions" => [1.0, 1.0, 1.0]),
            "editor" => Dict("graph_position" => [0.0, 0.0], "collapsed" => false),
            "properties" => Dict{String, Any}(),
            "input_ports" => [Dict("id" => "in", "name" => "in", "direction" => "input", "kind" => "flow", "data_type" => "entity", "cardinality" => "many", "required" => false)],
            "output_ports" => [Dict("id" => "out", "name" => "out", "direction" => "output", "kind" => "flow", "data_type" => "entity", "cardinality" => "many", "required" => false)],
            "metric_ports" => []
        )
        router_b = deepcopy(router_a)
        router_b["id"] = "router_02"
        router_b["name"] = "Router B"

        cycle_dict = Dict{String, Any}(
            "spec_version" => "1.0.0",
            "scene" => Dict("id" => "scene_cycle", "name" => "Cycle", "description" => "", "author" => "", "created_at" => "", "modified_at" => "", "revision" => 1, "required_libraries" => []),
            "simulation" => Dict("mode" => "des_only", "start_time" => 0.0, "end_time" => 10.0, "warmup_time" => 0.0, "random_seed" => 1, "time_unit" => "s", "space_unit" => "m"),
            "abm_config" => nothing,
            "spatial" => Dict("coordinate_system" => "right_handed_z_up", "length_unit" => "meters", "origin" => [0.0, 0.0, 0.0], "levels" => [Dict("id" => "level_ground", "name" => "Ground", "elevation" => 0.0, "default_height" => 3.0, "visible" => true)]),
            "elements" => [router_a, router_b],
            "connections" => [
                Dict("id" => "c_ab", "source_element" => "router_01", "source_port" => "out", "target_element" => "router_02", "target_port" => "in", "link_type" => "flow", "enabled" => true, "ordering" => 1, "latency" => 0.0),
                Dict("id" => "c_ba", "source_element" => "router_02", "source_port" => "out", "target_element" => "router_01", "target_port" => "in", "link_type" => "flow", "enabled" => true, "ordering" => 1, "latency" => 0.0)
            ],
            "subgraphs" => [],
            "overlays" => [],
            "validation_metadata" => Dict("is_valid" => true, "diagnostic_count" => 0, "diagnostics" => [], "last_validated_at" => "", "validator_version" => "1.0.0")
        )

        v_cycle = validate_scenespec(cycle_dict)
        @test v_cycle.is_valid == false
        d_cycle = findfirst(d -> d.rule_id == "GRAPH_002_ZERO_DELAY_CYCLE", v_cycle.diagnostics)
        @test d_cycle !== nothing
        @test contains(v_cycle.diagnostics[d_cycle].message, "router_01 -> router_02")

        # Now add positive latency to c_ab: should become valid!
        cycle_dict["connections"][1]["latency"] = 1.5
        v_buffered = validate_scenespec(cycle_dict)
        @test !any(d -> d.rule_id == "GRAPH_002_ZERO_DELAY_CYCLE", v_buffered.diagnostics)
    end

    @testset "Rule: SPATIAL_001_ELEVATION_OUT_OF_BOUNDS" begin
        base_dict = scenespec_to_dict(decode_scenespec_json(read(joinpath(fixtures_dir, "minimal_des.json"), String)))
        base_dict["elements"][1]["transform"]["position"] = [0.0, 0.0, 50.0]
        v = validate_scenespec(base_dict)
        d = findfirst(d -> d.rule_id == "SPATIAL_001_ELEVATION_OUT_OF_BOUNDS", v.diagnostics)
        @test d !== nothing
        @test v.diagnostics[d].severity == :warning
        @test contains(v.diagnostics[d].message, "outside level 'level_ground' bounds")
    end

    @testset "Rule: ABM_001_INVALID_MODEL" begin
        base_dict = scenespec_to_dict(decode_scenespec_json(read(joinpath(fixtures_dir, "minimal_abm.json"), String)))
        # Model name empty
        base_dict["abm_config"]["model_name"] = ""
        v = validate_scenespec(base_dict)
        @test v.is_valid == false
        @test any(d -> d.rule_id == "ABM_001_INVALID_MODEL", v.diagnostics)

        # Mode not abm_only or hybrid
        base_dict["abm_config"]["model_name"] = "SFM"
        base_dict["simulation"]["mode"] = "des_only"
        v2 = validate_scenespec(base_dict)
        @test v2.is_valid == false
        @test any(d -> d.rule_id == "ABM_001_INVALID_MODEL" && contains(d.message, "simulation.mode"), v2.diagnostics)
    end

    @testset "apply_validation! updates TypedSceneSpec" begin
        inv_path = joinpath(fixtures_dir, "invalid_connections.json")
        payload = decode_scenespec_json(read(inv_path, String))
        typed = to_typed_scenespec(payload)
        updated = apply_validation!(typed)

        @test updated isa TypedSceneSpec
        @test updated.validation_metadata.is_valid == false
        @test updated.validation_metadata.diagnostic_count == 2
        @test length(updated.validation_metadata.diagnostics) == 2
    end
end

