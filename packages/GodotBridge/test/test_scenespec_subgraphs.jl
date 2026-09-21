# ============================================================================
# test_scenespec_subgraphs.jl - Phase 7D-04 Subgraph & Spatial Layout Suite
# ============================================================================

using Test
using GodotBridge
using KernelAbstractions

@testset "SceneSpec Hierarchical Subgraphs & Spatial Layout (Phase 7D-04)" begin

    # ─────────────────────────────────────────────────────────────────────────
    # 1. Execution Backend Resolution & KernelAbstractions Abstraction
    # ─────────────────────────────────────────────────────────────────────────
    @testset "1. Execution Backend Resolution" begin
        # Auto backend
        auto_backend = resolve_execution_backend("auto")
        @test auto_backend isa AbstractExecutionBackend
        ka_be = get_ka_backend(auto_backend)
        @test ka_be isa KernelAbstractions.Backend

        # CPU backend
        cpu_backend = resolve_execution_backend("cpu")
        @test cpu_backend isa CPUBackend
        @test cpu_backend.ka_backend isa KernelAbstractions.CPU
        @test cpu_backend.nthreads >= 1

        # Fallback for invalid preference
        fallback_backend = resolve_execution_backend("unknown_pref")
        @test fallback_backend isa CPUBackend

        # Direct backend query
        gpu_detected = detect_available_gpu_backend()
        # On CPU-only test runners, gpu_detected will be nothing
        if gpu_detected !== nothing
            @test gpu_detected isa GPUBackend
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # 2. KernelAbstractions Transform Composition Kernel
    # ─────────────────────────────────────────────────────────────────────────
    @testset "2. KernelAbstractions Transform Kernel" begin
        # Single transform composition
        t_parent = TransformRecord((10.0, 20.0, 5.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0))
        t_child = TransformRecord((2.0, 3.0, 1.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0))
        t_composed = compose_transforms(t_parent, t_child)

        @test t_composed.position[1] ≈ 12.0
        @test t_composed.position[2] ≈ 23.0
        @test t_composed.position[3] ≈ 6.0

        # Dispatched KA kernel over 4 elements
        N = 4
        parent_pos = Float32[10, 20, 5,  10, 20, 5,  0, 0, 0,  0, 0, 0]
        parent_rot = zeros(Float32, 3N)
        parent_scl = ones(Float32, 3N)

        local_pos = Float32[1, 2, 3,  4, 5, 6,  7, 8, 9,  10, 11, 12]
        local_rot = zeros(Float32, 3N)
        local_scl = ones(Float32, 3N)

        out_pos = zeros(Float32, 3N)
        out_rot = zeros(Float32, 3N)
        out_scl = zeros(Float32, 3N)

        ka_cpu = KernelAbstractions.CPU()
        kernel! = compose_transforms_kernel!(ka_cpu, 256)
        ev = kernel!(out_pos, out_rot, out_scl, parent_pos, parent_rot, parent_scl, local_pos, local_rot, local_scl, N, ndrange=N)
        KernelAbstractions.synchronize(ka_cpu)

        # Element 1: (10+1, 20+2, 5+3) = (11, 22, 8)
        @test out_pos[1] ≈ 11.0f0
        @test out_pos[2] ≈ 22.0f0
        @test out_pos[3] ≈ 8.0f0

        # Element 2: (10+4, 20+5, 5+6) = (14, 25, 11)
        @test out_pos[4] ≈ 14.0f0
        @test out_pos[5] ≈ 25.0f0
        @test out_pos[6] ≈ 11.0f0

        # Element 3: (0+7, 0+8, 0+9) = (7, 8, 9)
        @test out_pos[7] ≈ 7.0f0
        @test out_pos[8] ≈ 8.0f0
        @test out_pos[9] ≈ 9.0f0
    end

    # ─────────────────────────────────────────────────────────────────────────
    # 3. Coordinate Conversion & SpatialBufferSoA Binary Transfer
    # ─────────────────────────────────────────────────────────────────────────
    @testset "3. Coordinate Systems & SoA Binary Blitting" begin
        # Right-handed Z-up (X=East, Y=North, Z=Height) to Godot 3D (X, Z, -Y)
        zup_pt = (5.0, 10.0, 2.5)
        godot_pt = zup_to_godot_position(zup_pt)
        @test godot_pt == (5.0, 2.5, -10.0)

        # Roundtrip back
        roundtrip = godot_to_zup_position(godot_pt)
        @test roundtrip == zup_pt

        # SoA Buffer creation
        soa = SpatialBufferSoA(
            2,
            Float32[1.0, 2.0, 3.0, 4.0, 5.0, 6.0],
            Float32[0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            Float32[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
            Int32[0, 1],
            String["elem_1", "elem_2"]
        )
        @test soa.count == 2
        @test length(soa.positions) == 6
        @test length(soa.level_indices) == 2

        # Byte serialization for Godot PackedByteArray
        bytes = to_godot_byte_array(soa)
        # Expected header: Int32(2) = 4 bytes
        # Positions: 6 * Float32 = 24 bytes
        # Rotations: 6 * Float32 = 24 bytes
        # Scales: 6 * Float32 = 24 bytes
        # Level indices: 2 * Int32 = 8 bytes
        # Total = 4 + 24 + 24 + 24 + 8 = 84 bytes
        @test length(bytes) == 84
        count_val = reinterpret(Int32, bytes[1:4])[1]
        @test count_val == 2
    end

    # ─────────────────────────────────────────────────────────────────────────
    # 4. Extensible Port Protocol Registry & Cardinality
    # ─────────────────────────────────────────────────────────────────────────
    @testset "4. Port Protocol Registry & Compatibility" begin
        # Core protocols initialized
        protocols = list_port_protocols()
        @test :flow in protocols
        @test :metric in protocols
        @test :signal in protocols
        @test :control in protocols
        @test :event in protocols

        # Compatibility checks
        @test is_connection_compatible(:flow, :flow) == true
        @test is_connection_compatible(:flow, :signal) == false
        @test is_connection_compatible(:metric, :signal) == true
        @test is_connection_compatible(:signal, :control) == true

        # Custom protocol registration
        register_port_protocol!(:fluid, [:fluid], bidirectional=false, description="Hydraulic or pneumatic pipeline")
        @test :fluid in list_port_protocols()
        @test is_connection_compatible(:fluid, :fluid) == true
        @test is_connection_compatible(:fluid, :flow) == false

        # Bidirectional protocol
        register_port_protocol!(:can_bus, [:can_bus], bidirectional=true, description="Controller Area Network bus")
        @test is_connection_compatible(:can_bus, :can_bus) == true

        # Cardinality checks
        @test check_cardinality(0, 0, 1) == true
        @test check_cardinality(1, 0, 1) == true
        @test check_cardinality(2, 0, 1) == false
        @test check_cardinality(5, 1, -1) == true # unlimited
        @test check_cardinality(0, 1, -1) == false # requires at least 1

        @test check_port_cardinality(1, :one) == true
        @test check_port_cardinality(2, :one) == false
        @test check_port_cardinality(50, :many) == true

        # Reset registry
        reset_port_protocols!()
        @test !(:fluid in list_port_protocols())
    end

    # ─────────────────────────────────────────────────────────────────────────
    # 5. Compound Subgraph Expansion & Parameter Overrides
    # ─────────────────────────────────────────────────────────────────────────
    @testset "5. Compound Subgraph Expansion" begin
        # Build prototype template with queue + server
        q_ports_in = [PortRecord("flow_in", "Inlet", :input, :flow, "item", :many, true, nothing, nothing, Dict{String, Any}())]
        q_ports_out = [PortRecord("flow_out", "Outlet", :output, :flow, "item", :one, true, nothing, nothing, Dict{String, Any}())]
        proto_q = ElementRecord(
            "tpl_q", "Template Queue", "queue", "SimElements/DES", "1.0.0", "level_ground",
            TransformRecord((0.0, 0.0, 0.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0)),
            GeometryRecord("box", [1.0, 1.0, 1.0], nothing, nothing, nothing, nothing, Dict{String, Any}()),
            EditorMetadata((0.0, 0.0), false, nothing, nothing, Dict{String, Any}()),
            Dict{String, Any}("capacity" => 10),
            q_ports_in, q_ports_out, PortRecord[], nothing, nothing, Dict{String, Any}()
        )

        srv_ports_in = [PortRecord("flow_in", "Inlet", :input, :flow, "item", :one, true, nothing, nothing, Dict{String, Any}())]
        srv_ports_out = [PortRecord("flow_out", "Outlet", :output, :flow, "item", :one, true, nothing, nothing, Dict{String, Any}())]
        proto_srv = ElementRecord(
            "tpl_srv", "Template Server", "server", "SimElements/DES", "1.0.0", "level_ground",
            TransformRecord((5.0, 0.0, 0.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0)),
            GeometryRecord("box", [1.0, 1.0, 1.0], nothing, nothing, nothing, nothing, Dict{String, Any}()),
            EditorMetadata((100.0, 0.0), false, nothing, nothing, Dict{String, Any}()),
            Dict{String, Any}("service_time" => 2.0),
            srv_ports_in, srv_ports_out, PortRecord[], nothing, nothing, Dict{String, Any}()
        )

        proto_conn = ConnectionRecord(
            "tpl_conn", "tpl_q", "flow_out", "tpl_srv", "flow_in",
            :flow, true, 1, nothing, 0.0, nothing, Dict{String, Any}()
        )

        # Template subgraph definition
        exposed_ports = [
            Dict{String, Any}("id" => "flow_in", "target_element" => "tpl_q", "target_port" => "flow_in"),
            Dict{String, Any}("id" => "flow_out", "target_element" => "tpl_srv", "target_port" => "flow_out")
        ]
        template_sub = SubgraphRecord(
            "station_template", "Processing Station Template", :template,
            nothing, "1.0.0", nothing, nothing,
            ["tpl_q", "tpl_srv"], ["tpl_conn"], exposed_ports,
            Dict{String, Any}(), Dict{String, Any}()
        )

        # Compound instance A: at (10, 0, 0)
        station_a = SubgraphRecord(
            "station_a", "Station Alpha", :compound,
            "station_template", "1.0.0", "level_ground",
            TransformRecord((10.0, 0.0, 0.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0)),
            String[], String[], exposed_ports,
            Dict{String, Any}(), Dict{String, Any}()
        )

        # Compound instance B: at (30, 0, 0) with parameter overrides!
        station_b = SubgraphRecord(
            "station_b", "Station Beta", :compound,
            "station_template", "1.0.0", "level_ground",
            TransformRecord((30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0)),
            String[], String[], exposed_ports,
            Dict{String, Any}("tpl_srv.service_time" => 5.5, "*.capacity" => 50),
            Dict{String, Any}()
        )

        # External connection linking station_a -> station_b via exposed boundary ports!
        inter_station_conn = ConnectionRecord(
            "conn_a_to_b", "station_a", "flow_out", "station_b", "flow_in",
            :flow, true, 1, nothing, 0.5, nothing, Dict{String, Any}()
        )

        spec = TypedSceneSpec(
            "1.0.0",
            SceneMetadata("test_subgraphs", "Test Subgraphs", "Test", "1.0.0", Dict{String, Any}(), Dict{String, Any}()),
            SimulationConfig("discrete_event", 1.0, 100.0, 0.01, 42, Dict{String, Any}()),
            nothing,
            SpatialConfig("right_handed_z_up", "meters", (0.0, 0.0, 0.0), [SpatialLevel("level_ground", "Ground Floor", 0.0, 3.5, true, Dict{String, Any}())], Dict{String, Any}()),
            [proto_q, proto_srv],
            [proto_conn, inter_station_conn],
            [template_sub, station_a, station_b],
            OverlayRecord[],
            ValidationMetadataRecord(true, 0, "", "1.0.0", DiagnosticRecord[], Dict{String, Any}()),
            Dict{String, Any}()
        )

        # Compile scene graph
        compiled = compile_scene_graph(spec)
        flat = compiled.flat_spec

        # 1. Verification of uninstantiated template blueprints
        # Template elements (tpl_q, tpl_srv) should NOT appear standalone in flat.elements
        elem_ids = [e.id for e in flat.elements]
        @test !("tpl_q" in elem_ids)
        @test !("tpl_srv" in elem_ids)

        # 2. Instantiated compound elements must appear with scoped path prefixes
        @test "station_a::tpl_q" in elem_ids
        @test "station_a::tpl_srv" in elem_ids
        @test "station_b::tpl_q" in elem_ids
        @test "station_b::tpl_srv" in elem_ids
        @test length(flat.elements) == 4

        # 3. Composed spatial transforms
        elem_map = Dict(e.id => e for e in flat.elements)
        # station_a::tpl_q: station_a is at (10, 0, 0), tpl_q is at (0, 0, 0) -> (10, 0, 0)
        @test elem_map["station_a::tpl_q"].transform.position[1] ≈ 10.0
        # station_a::tpl_srv: station_a is at (10, 0, 0), tpl_srv is at (5, 0, 0) -> (15, 0, 0)
        @test elem_map["station_a::tpl_srv"].transform.position[1] ≈ 15.0
        # station_b::tpl_q: station_b is at (30, 0, 0), tpl_q is at (0, 0, 0) -> (30, 0, 0)
        @test elem_map["station_b::tpl_q"].transform.position[1] ≈ 30.0
        # station_b::tpl_srv: station_b is at (30, 0, 0), tpl_srv is at (5, 0, 0) -> (35, 0, 0)
        @test elem_map["station_b::tpl_srv"].transform.position[1] ≈ 35.0

        # 4. Parameter overrides verification
        # station_a has default parameters: capacity=10, service_time=2.0
        @test elem_map["station_a::tpl_q"].properties["capacity"] == 10
        @test elem_map["station_a::tpl_srv"].properties["service_time"] == 2.0

        # station_b has overrides: tpl_srv.service_time=5.5, *.capacity=50
        @test elem_map["station_b::tpl_q"].properties["capacity"] == 50
        @test elem_map["station_b::tpl_srv"].properties["service_time"] == 5.5

        # 5. Connection rewiring verification
        conn_map = Dict(c.id => c for c in flat.connections)
        # Internal connection in station_a rewired
        @test haskey(conn_map, "station_a::tpl_conn")
        @test conn_map["station_a::tpl_conn"].source_element == "station_a::tpl_q"
        @test conn_map["station_a::tpl_conn"].target_element == "station_a::tpl_srv"

        # Internal connection in station_b rewired
        @test haskey(conn_map, "station_b::tpl_conn")
        @test conn_map["station_b::tpl_conn"].source_element == "station_b::tpl_q"
        @test conn_map["station_b::tpl_conn"].target_element == "station_b::tpl_srv"

        # External boundary connection rewired from station_a -> station_b
        # station_a.flow_out points to station_a::tpl_srv.flow_out
        # station_b.flow_in points to station_b::tpl_q.flow_in
        @test haskey(conn_map, "conn_a_to_b")
        @test conn_map["conn_a_to_b"].source_element == "station_a::tpl_srv"
        @test conn_map["conn_a_to_b"].source_port == "flow_out"
        @test conn_map["conn_a_to_b"].target_element == "station_b::tpl_q"
        @test conn_map["conn_a_to_b"].target_port == "flow_in"

        # 6. Bidirectional source map verification
        smap = compiled.source_map
        @test smap.runtime_to_hierarchical["station_a::tpl_q"] == ("station_a", "tpl_q", "station_template")
        @test smap.hierarchical_to_runtime[("station_a", "tpl_q")] == "station_a::tpl_q"
        @test smap.runtime_to_hierarchical["station_b::tpl_srv"] == ("station_b", "tpl_srv", "station_template")
        @test smap.hierarchical_to_runtime[("station_b", "tpl_srv")] == "station_b::tpl_srv"

        # 7. SpatialBufferSoA generation
        soa = compiled.spatial_soa
        @test soa.count == 4
        @test length(soa.positions) == 12

        # 8. Hierarchical metric roll-up query
        sim_metrics = Dict{String, Float64}(
            "station_a::tpl_q" => 3.0,
            "station_a::tpl_srv" => 1.0,
            "station_b::tpl_q" => 7.0,
            "station_b::tpl_srv" => 2.0
        )
        total_a = query_hierarchical_metric(compiled, "station_a", sim_metrics)
        @test total_a ≈ 4.0

        total_b = query_hierarchical_metric(compiled, "station_b", sim_metrics)
        @test total_b ≈ 9.0
    end

    # ─────────────────────────────────────────────────────────────────────────
    # 6. Validation Rules: Cycles, Missing Templates, Missing Ports
    # ─────────────────────────────────────────────────────────────────────────
    @testset "6. Subgraph Validation Rules" begin
        # 1. SUBGRAPH_003_TEMPLATE_NOT_FOUND
        bad_tmpl_sub = SubgraphRecord(
            "sub_orphan", "Orphan", :compound, "non_existent_tmpl", nothing,
            nothing, nothing, String[], String[], Dict{String, Any}[],
            Dict{String, Any}(), Dict{String, Any}()
        )
        spec_bad_tmpl = TypedSceneSpec(
            "1.0.0",
            SceneMetadata("bad_tmpl", "Bad Template", "Test", "1.0.0", Dict{String, Any}(), Dict{String, Any}()),
            SimulationConfig("discrete_event", 1.0, 100.0, 0.01, 42, Dict{String, Any}()),
            nothing, nothing, ElementRecord[], ConnectionRecord[], [bad_tmpl_sub], OverlayRecord[],
            ValidationMetadataRecord(true, 0, "", "1.0.0", DiagnosticRecord[], Dict{String, Any}()),
            Dict{String, Any}()
        )
        vm = validate_scenespec(spec_bad_tmpl)
        @test !vm.is_valid
        @test any(d -> d.rule_id == "SUBGRAPH_003_TEMPLATE_NOT_FOUND", vm.diagnostics)

        # 2. SUBGRAPH_001_RECURSIVE_CYCLE
        sub_c1 = SubgraphRecord("sub_c1", "C1", :template, "sub_c2", nothing, nothing, nothing, String[], String[], Dict{String, Any}[], Dict{String, Any}(), Dict{String, Any}())
        sub_c2 = SubgraphRecord("sub_c2", "C2", :template, "sub_c1", nothing, nothing, nothing, String[], String[], Dict{String, Any}[], Dict{String, Any}(), Dict{String, Any}())
        spec_cycle = TypedSceneSpec(
            "1.0.0",
            SceneMetadata("cycle", "Cycle", "Test", "1.0.0", Dict{String, Any}(), Dict{String, Any}()),
            SimulationConfig("discrete_event", 1.0, 100.0, 0.01, 42, Dict{String, Any}()),
            nothing, nothing, ElementRecord[], ConnectionRecord[], [sub_c1, sub_c2], OverlayRecord[],
            ValidationMetadataRecord(true, 0, "", "1.0.0", DiagnosticRecord[], Dict{String, Any}()),
            Dict{String, Any}()
        )
        vm_cycle = validate_scenespec(spec_cycle)
        @test !vm_cycle.is_valid
        @test any(d -> d.rule_id == "SUBGRAPH_001_RECURSIVE_CYCLE", vm_cycle.diagnostics)

        # 3. SUBGRAPH_002_PORT_NOT_FOUND
        bad_port_sub = SubgraphRecord(
            "sub_bad_port", "Bad Port", :group, nothing, nothing, nothing, nothing,
            String["e1"], String[],
            [Dict{String, Any}("id" => "exposed_x", "target_element" => "non_existent_e", "target_port" => "p1")],
            Dict{String, Any}(), Dict{String, Any}()
        )
        spec_bad_port = TypedSceneSpec(
            "1.0.0",
            SceneMetadata("bad_port", "Bad Port", "Test", "1.0.0", Dict{String, Any}(), Dict{String, Any}()),
            SimulationConfig("discrete_event", 1.0, 100.0, 0.01, 42, Dict{String, Any}()),
            nothing, nothing, ElementRecord[], ConnectionRecord[], [bad_port_sub], OverlayRecord[],
            ValidationMetadataRecord(true, 0, "", "1.0.0", DiagnosticRecord[], Dict{String, Any}()),
            Dict{String, Any}()
        )
        vm_port = validate_scenespec(spec_bad_port)
        @test !vm_port.is_valid
        @test any(d -> d.rule_id == "SUBGRAPH_002_PORT_NOT_FOUND", vm_port.diagnostics)

        # 4. SPATIAL_003_CONNECTOR_INACCESSIBLE
        bad_connector = ElementRecord(
            "bad_elevator", "Bad Elevator", "vertical_connector", "SimElements/Spatial", "1.0.0", "level_1",
            TransformRecord((0.0, 0.0, 1.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0)), # Z starts at 1.0, height is 1.0 -> spans [1.0, 2.0], but levels are at 0.0 and 4.0!
            GeometryRecord("box", [1.0, 1.0, 1.0], nothing, nothing, nothing, nothing, Dict{String, Any}()),
            EditorMetadata((0.0, 0.0), false, nothing, nothing, Dict{String, Any}()),
            Dict{String, Any}(), PortRecord[], PortRecord[], PortRecord[],
            Dict{String, Any}("source_level_id" => "level_1", "target_level_id" => "level_2", "height" => 1.0),
            nothing, Dict{String, Any}()
        )
        levels = [
            SpatialLevel("level_1", "L1", 0.0, 3.0, true, Dict{String, Any}()),
            SpatialLevel("level_2", "L2", 4.0, 3.0, true, Dict{String, Any}())
        ]
        spec_bad_conn = TypedSceneSpec(
            "1.0.0",
            SceneMetadata("bad_conn", "Bad Conn", "Test", "1.0.0", Dict{String, Any}(), Dict{String, Any}()),
            SimulationConfig("discrete_event", 1.0, 100.0, 0.01, 42, Dict{String, Any}()),
            nothing, SpatialConfig("right_handed_z_up", "meters", (0.0, 0.0, 0.0), levels, Dict{String, Any}()),
            [bad_connector], ConnectionRecord[], SubgraphRecord[], OverlayRecord[],
            ValidationMetadataRecord(true, 0, "", "1.0.0", DiagnosticRecord[], Dict{String, Any}()),
            Dict{String, Any}()
        )
        vm_conn = validate_scenespec(spec_bad_conn)
        @test !vm_conn.is_valid
        @test any(d -> d.rule_id == "SPATIAL_003_CONNECTOR_INACCESSIBLE", vm_conn.diagnostics)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # 7. Performance & Type Stability (@inferred, @allocated)
    # ─────────────────────────────────────────────────────────────────────────
    @testset "7. Performance & Type Stability" begin
        t1 = TransformRecord((10.0, 20.0, 5.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0))
        t2 = TransformRecord((2.0, 3.0, 1.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0))

        # Type inference checks
        @test @inferred(compose_transforms(t1, t2)) isa TransformRecord
        @test @inferred(zup_to_godot_position((1.0, 2.0, 3.0))) isa NTuple{3, Float64}
        @test @inferred(godot_to_zup_position((1.0, 3.0, -2.0))) isa NTuple{3, Float64}
        @test @inferred(is_connection_compatible(:flow, :flow)) isa Bool
        @test @inferred(check_cardinality(1, 0, 1)) isa Bool

        soa = SpatialBufferSoA(1, Float32[0, 0, 0], Float32[0, 0, 0], Float32[1, 1, 1], Int32[0], String["e1"])
        @test @inferred(to_godot_byte_array(soa)) isa Vector{UInt8}
    end
end
