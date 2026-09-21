"""
    test_scenespec_extensions.jl

Unit tests for SceneSpec v1 Dynamic Extension Preservation & Custom Metadata API (Phase 7D-03).
Tests direct unknown property access, nested path navigation, namespacing, deep merge,
MessagePack/JSON round-trip fidelity, and extension governance validation rules.
"""

using Test
using GodotBridge

@testset "SceneSpec Metadata & Extensions API (Phase 7D-03)" begin
    fixtures_dir = normpath(joinpath(@__DIR__, "..", "..", "..", "godot", "fixtures", "scenespec"))
    future_path = joinpath(fixtures_dir, "future_fields.json")

    @testset "Grounding Against future_fields.json" begin
        payload = decode_scenespec_json(read(future_path, String))
        spec = to_typed_scenespec(payload)

        # 1. Document-level unknown properties & extensions
        @test has_extension(spec, "future_distributed_engine") == true
        @test get_extension(spec, "future_distributed_engine") == true
        @test get_extension(spec, "cluster_target_nodes") == ["compute_worker_01", "compute_worker_02"]
        @test get_extension(spec, "root_level_extension_key") == "val_12345"
        @test get_extension_path(spec, "experimental_flags.enable_neural_surrogate") == true
        @test get_extension_path(spec, "cluster_target_nodes.1") == "compute_worker_01"
        @test get_extension_path(spec, "cluster_target_nodes.2") == "compute_worker_02"

        # 2. Scene-level metadata extensions
        @test has_extension(spec.scene, "organization_id") == true
        @test get_extension(spec.scene, "organization_id") == "deepmind-research-advanced"
        @test get_extension(spec.scene, "compliance_tags") == ["ISO-9001", "EU-AI-ACT-CLASS-2"]
        @test get_extension_path(spec.scene, "ai_copilot.authoring_session_id") == "sess_8943729"
        @test get_extension_path(spec.scene, "ai_copilot.confidence_score") == 0.985

        # 3. Simulation-level extensions
        @test get_extension(spec.simulation, "future_execution_mode") == "lockstep_multithreaded"
        @test get_extension_path(spec.simulation, "profiler_tracing.sample_interval_ms") == 10

        # 4. Spatial-level extensions
        @test spec.spatial !== nothing
        @test get_extension_path(spec.spatial, "global_geo_reference.latitude") == 37.7749
        @test get_extension_path(spec.spatial, "global_geo_reference.longitude") == -122.4194
        @test get_extension_path(spec.spatial, "bim_metadata/ifc_guid") == "3h8k9sDfk294KslaP0"

        lvl = spec.spatial.levels[1]
        @test get_extension(lvl, "acoustic_absorption_coeff") == 0.85

        # 5. Element-level extensions
        elem = spec.elements[1]
        @test get_extension(elem, "thermal_dissipation_watts") == 450.0
        @test get_extension(elem, "maintenance_schedule_url") == "https://telemetry.local/device/elem_future_source"
        @test get_extension(elem.editor, "custom_badge") == "SMART-V2"
        @test get_extension_path(elem, "custom_vendor_blob.can_bus_speed_kbps") == 500
        @test get_extension_path(elem, "custom_vendor_blob.retry_limit") == 3

        # 6. Port-level extensions
        port = elem.output_ports[1]
        @test get_extension(port, "bus_channel_id") == 4
        @test get_extension(port, "security_token_required") == false

        # 7. List extension keys
        doc_keys = list_extensions(spec)
        @test "future_distributed_engine" in doc_keys
        @test "cluster_target_nodes" in doc_keys
        @test "root_level_extension_key" in doc_keys
        @test "experimental_flags" in doc_keys

        elem_keys = list_extensions(elem)
        @test "thermal_dissipation_watts" in elem_keys
        @test "maintenance_schedule_url" in elem_keys
        @test "custom_vendor_blob" in elem_keys
    end

    @testset "Mutation and Path Navigation" begin
        payload = decode_scenespec_json(read(future_path, String))
        spec = to_typed_scenespec(payload)
        elem = spec.elements[1]

        # Flat setter
        set_extension!(elem, "cooling_system_type", "liquid_nitrogen")
        @test has_extension(elem, "cooling_system_type") == true
        @test get_extension(elem, "cooling_system_type") == "liquid_nitrogen"

        # Nested path setter
        set_extension_path!(elem, "custom_vendor_blob.can_bus_speed_kbps", 1000)
        @test get_extension_path(elem, "custom_vendor_blob.can_bus_speed_kbps") == 1000

        # Auto-create intermediate path dictionaries
        set_extension_path!(elem, "diagnostics.firmware.version", "4.2.1-rc1")
        @test get_extension_path(elem, "diagnostics.firmware.version") == "4.2.1-rc1"
        @test get_extension_path(elem, "diagnostics.firmware.missing", "fallback") == "fallback"

        # Deletion
        del_val = delete_extension!(elem, "maintenance_schedule_url")
        @test del_val == "https://telemetry.local/device/elem_future_source"
        @test has_extension(elem, "maintenance_schedule_url") == false
    end

    @testset "Namespaced Extension Operations" begin
        payload = decode_scenespec_json(read(future_path, String))
        spec = to_typed_scenespec(payload)
        elem = spec.elements[1]

        # Set namespace
        sensor_data = Dict{String, Any}("channel" => "ANALOG_01", "sample_rate_hz" => 250.0)
        set_namespace!(elem, "vendor:sensors", sensor_data)

        @test has_namespace(elem, "vendor:sensors") == true
        ns = get_namespace(elem, "vendor:sensors")
        @test ns["channel"] == "ANALOG_01"
        @test ns["sample_rate_hz"] == 250.0

        # Path access into namespace
        @test get_extension_path(elem, "vendor:sensors.channel") == "ANALOG_01"

        # Delete namespace
        delete_namespace!(elem, "vendor:sensors")
        @test has_namespace(elem, "vendor:sensors") == false
    end

    @testset "Deep Merge and Clone Isolation" begin
        payload = decode_scenespec_json(read(future_path, String))
        spec = to_typed_scenespec(payload)
        elem = spec.elements[1]

        # Deep merge
        merge_extensions!(elem, Dict{String, Any}(
            "custom_vendor_blob" => Dict{String, Any}("new_param" => 999),
            "telemetry_priority" => "HIGH"
        ))

        @test get_extension_path(elem, "custom_vendor_blob.new_param") == 999
        @test get_extension_path(elem, "custom_vendor_blob.retry_limit") == 3 # Preserved
        @test get_extension(elem, "telemetry_priority") == "HIGH"

        # Clone isolation
        cloned_ext = copy_extensions(elem)
        cloned_ext["telemetry_priority"] = "LOW"
        @test get_extension(elem, "telemetry_priority") == "HIGH" # Immutable original
    end

    @testset "Lossless MessagePack Round-Trip with Mutated Extensions" begin
        payload = decode_scenespec_json(read(future_path, String))
        spec = to_typed_scenespec(payload)

        # Mutate several hierarchy levels
        set_extension!(spec, "test_run_uuid", "123e4567-e89b-12d3-a456-426614174000")
        set_extension_path!(spec.elements[1], "custom_vendor_blob.retry_limit", 7)
        set_extension!(spec.elements[1].output_ports[1], "extra_metric", 42.5)

        # Roundtrip through MessagePack
        p_out = to_payload(spec)
        mp_bytes = encode_scenespec_msgpack(p_out)
        @test !isempty(mp_bytes)

        p_in = decode_scenespec_msgpack(mp_bytes)
        spec_restored = to_typed_scenespec(p_in)

        # Verify preserved mutations
        @test get_extension(spec_restored, "test_run_uuid") == "123e4567-e89b-12d3-a456-426614174000"
        @test get_extension_path(spec_restored.elements[1], "custom_vendor_blob.retry_limit") == 7
        @test get_extension(spec_restored.elements[1].output_ports[1], "extra_metric") == 42.5

        # Verify original untouched extensions remain intact
        @test get_extension(spec_restored, "future_distributed_engine") == true
        @test get_extension(spec_restored.elements[1], "thermal_dissipation_watts") == 450.0
    end

    @testset "Extension Governance Validation Rules" begin
        # 1. EXT_001_INVALID_KEY: whitespace or invalid characters in key
        bad_spec_payload = decode_scenespec_json(read(future_path, String))
        bad_spec = to_typed_scenespec(bad_spec_payload)
        set_extension!(bad_spec.elements[1], "invalid key with spaces", "bad")

        val1 = validate_scenespec(bad_spec)
        @test val1.is_valid == false
        @test any(d -> d.rule_id == "EXT_001_INVALID_KEY" && d.severity == :error, val1.diagnostics)

        # 2. EXT_002_RESERVED_KEY_CONFLICT: shadowing core property 'transform' on element
        bad_spec2_payload = decode_scenespec_json(read(future_path, String))
        bad_spec2 = to_typed_scenespec(bad_spec2_payload)
        set_extension!(bad_spec2.elements[1], "transform", Dict("fake" => 1))

        val2 = validate_scenespec(bad_spec2)
        @test val2.is_valid == false
        @test any(d -> d.rule_id == "EXT_002_RESERVED_KEY_CONFLICT" && d.severity == :error, val2.diagnostics)

        # 3. EXT_002_RESERVED_KEY_CONFLICT: shadowing 'spec_version' on document
        bad_spec3_payload = decode_scenespec_json(read(future_path, String))
        bad_spec3 = to_typed_scenespec(bad_spec3_payload)
        set_extension!(bad_spec3, "spec_version", "2.0.0")

        val3 = validate_scenespec(bad_spec3)
        @test val3.is_valid == false
        @test any(d -> d.rule_id == "EXT_002_RESERVED_KEY_CONFLICT" && d.severity == :error, val3.diagnostics)
    end
end
