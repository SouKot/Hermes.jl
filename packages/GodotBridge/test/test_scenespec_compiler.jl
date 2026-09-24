# packages/GodotBridge/test/test_scenespec_compiler.jl
#
# Comprehensive Test Suite for Phase 7D-12A:
# - SceneSpec Compiler (DES & Crowd lowering)
# - Queue/Server fusion into Kendall stations
# - Conveyor transit latency (tau = L / v)
# - Multi-unit stepping (s, m, h, d)
# - Staging sandbox and atomic pointer swap on compilation failure

using Test
using GodotBridge
using SimCore
using SimDES
using Distributions
using Random

@testset "Phase 7D-12A: SceneSpec Compiler & Live Runtime" begin

    @testset "1. M/M/1 Single Server Queue Model" begin
        mm1_spec = Dict{String, Any}(
            "spec_version" => "1.0.0",
            "scene" => Dict("id" => "mm1_model", "name" => "M/M/1 Model"),
            "simulation" => Dict("mode" => "des_only", "time_unit" => "seconds"),
            "elements" => [
                Dict("id" => "src", "kind" => "source", "properties" => Dict(
                    "arrival_rate" => 2.0, "entity_type" => "item"
                )),
                Dict("id" => "srv", "kind" => "server", "properties" => Dict(
                    "servers" => 1, "service_rate" => 3.0
                )),
                Dict("id" => "snk", "kind" => "sink", "properties" => Dict())
            ],
            "connections" => [
                Dict("id" => "c1", "source_element" => "src", "source_port" => "flow_out", "target_element" => "srv", "target_port" => "flow_in"),
                Dict("id" => "c2", "source_element" => "srv", "source_port" => "flow_out", "target_element" => "snk", "target_port" => "flow_in")
            ]
        )

        res = compile_scenespec(mm1_spec)
        @test res.success == true
        @test !has_errors(res.diagnostics)
        @test length(res.zone_configs) == 1
        
        # Verify zone config parameters
        srv_zid = first(keys(res.zone_configs))
        cfg = res.zone_configs[srv_zid]
        @test cfg.num_servers == 1
        @test cfg.routing isa ExitSystem
        @test cfg.arrival isa CustomArrivalProcess

        # Verify execution
        clock = SimClock(Inf)
        rng = Random.MersenneTwister(42)
        sim_loop!(res.world, res.fel, res.zone_configs, clock, rng; t_end=50.0)

        @test res.world.stats.total_arrivals > 30
        @test res.world.stats.total_departures > 25
    end

    @testset "2. Tandem Network with Queue-Server Fusion & Conveyor Latency" begin
        tandem_spec = Dict{String, Any}(
            "spec_version" => "1.0.0",
            "scene" => Dict("id" => "tandem_model", "name" => "Tandem Factory"),
            "simulation" => Dict("mode" => "des_only", "time_unit" => "seconds"),
            "elements" => [
                Dict("id" => "src1", "kind" => "source", "properties" => Dict(
                    "interarrival_time" => Dict("type" => "exponential", "mean" => 2.0)
                )),
                Dict("id" => "q1", "kind" => "queue", "properties" => Dict(
                    "capacity" => 10, "discipline" => "FIFO"
                )),
                Dict("id" => "srv1", "kind" => "server", "properties" => Dict(
                    "servers" => 1, "service_time" => Dict("type" => "triangular", "min" => 1.0, "mode" => 1.5, "max" => 2.0)
                )),
                Dict("id" => "conv1", "kind" => "conveyor", "properties" => Dict(
                    "length" => 10.0, "speed" => 2.0, "capacity" => 6
                )),
                Dict("id" => "snk1", "kind" => "sink", "properties" => Dict())
            ],
            "connections" => [
                Dict("id" => "c1", "source_element" => "src1", "source_port" => "flow_out", "target_element" => "q1", "target_port" => "flow_in"),
                Dict("id" => "c2", "source_element" => "q1", "source_port" => "flow_out", "target_element" => "srv1", "target_port" => "flow_in"),
                Dict("id" => "c3", "source_element" => "srv1", "source_port" => "flow_out", "target_element" => "conv1", "target_port" => "flow_in"),
                Dict("id" => "c4", "source_element" => "conv1", "source_port" => "flow_out", "target_element" => "snk1", "target_port" => "flow_in")
            ]
        )

        res = compile_scenespec(tandem_spec)
        @test res.success == true
        @test length(res.zone_configs) == 2 # 1 fused (q1+srv1) + 1 conveyor (conv1)

        # Check fusion
        fused_zid = res.source_map.by_element["srv1"].zone_ids[1]
        @test res.source_map.by_element["q1"].zone_ids[1] == fused_zid
        @test res.source_map.by_element["q1"].is_fused_station == true
        @test res.source_map.by_element["srv1"].is_fused_station == true

        conv_zid = res.source_map.by_element["conv1"].zone_ids[1]
        conv_cfg = res.zone_configs[conv_zid]
        # Conveyor latency tau = 10.0 / 2.0 = 5.0 seconds
        @test conv_cfg.service_dist.dist.value == 5.0
        @test conv_cfg.routing isa ExitSystem
    end

    @testset "3. Multi-Unit Stepping (s, m, h, d) and Snapshot Construction" begin
        default_spec = create_default_scene()
        mgr = RuntimeManager()
        success, diags = stage_and_activate!(mgr, default_spec)
        @test success == true
        @test isempty(diags)

        # Step 30 seconds
        t1 = step!(mgr, 30.0, "s", (t)->nothing)
        @test t1 ≈ 30.0 atol=1e-3

        # Step 2 minutes (120 seconds -> t = 150s)
        t2 = step!(mgr, 2.0, "m", (t)->nothing)
        @test t2 ≈ 150.0 atol=1e-3

        # Step 1 hour (3600 seconds -> t = 3750s)
        t3 = step!(mgr, 1.0, "h", (t)->nothing)
        @test t3 ≈ 3750.0 atol=1e-3

        # Build snapshot
        snap = GodotBridge.build_snapshot(mgr.active_instance; scene_id="unit_test")
        @test snap.simulation_time ≈ 3750.0 atol=1e-3
        @test length(snap.elements_state) == 5
        @test mgr.active_instance.world.stats.total_departures > 500
    end

    @testset "4. Staging Sandbox: Invalid Scene Rejected & Active Instance Preserved" begin
        valid_spec = create_default_scene()
        mgr = RuntimeManager()
        stage_and_activate!(mgr, valid_spec)
        initial_inst_id = mgr.active_instance.id

        # Step valid model
        step!(mgr, 10.0, "s", (t)->nothing)
        @test mgr.active_instance.world.time ≈ 10.0 atol=1e-3

        # Draft an INVALID scene (server count <= 0, disconnected source)
        invalid_spec = Dict{String, Any}(
            "spec_version" => "1.0.0",
            "scene" => Dict("id" => "broken_scene"),
            "elements" => [
                Dict("id" => "bad_src", "kind" => "source", "properties" => Dict()),
                Dict("id" => "bad_srv", "kind" => "server", "properties" => Dict("servers" => 0))
            ],
            "connections" => []
        )

        success, diags = stage_and_activate!(mgr, invalid_spec)
        @test success == false
        @test has_errors(diags)

        # CRITICAL: Verify active instance is untouched!
        @test mgr.active_instance !== nothing
        @test mgr.active_instance.id == initial_inst_id
        @test mgr.active_instance.world.time ≈ 10.0 atol=1e-3
    end

end

