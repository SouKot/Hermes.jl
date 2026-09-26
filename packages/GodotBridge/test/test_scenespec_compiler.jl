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

# --- Test: ProductDefinition round-trip ---
begin
    using JSON
    println("[TEST] ProductDefinition round-trip...")
    # Build a scene spec JSON string with a product definition
    json_with_product = """
    {
      "version": "1.0",
      "elements": [
        {"id": "src1", "kind": "source",
         "properties": {"arrival_rate": 1.0, "distribution": "exponential"},
         "transform": {"position": [0,0,0], "dimensions": [2,2,1]}},
        {"id": "snk1", "kind": "sink",
         "properties": {},
         "transform": {"position": [5,0,0], "dimensions": [2,2,1]}}
      ],
      "connections": [{"id":"c1","source_element":"src1","source_port":"out","target_element":"snk1","target_port":"in"}],
      "product": {"mesh_type": "pallet", "color": [1.0, 0.8, 0.0], "width": 0.6, "height": 0.5, "depth": 0.3}
    }
    """
    ir_res = GodotBridge.compile_scenespec(JSON.parse(json_with_product))
    ir_prod = ir_res.execution_ir
    @assert ir_prod !== nothing "Expected non-nothing execution_ir"
    @assert ir_prod.product_def.mesh_type == :pallet "Expected :pallet, got $(ir_prod.product_def.mesh_type)"
    @assert ir_prod.product_def.color[1] ≈ 1.0 "Expected color_r=1.0"
    @assert ir_prod.product_def.color[2] ≈ 0.8 "Expected color_g=0.8"
    @assert ir_prod.product_def.width ≈ 0.6 "Expected width=0.6"
    println("  ✓ ProductDefinition round-trip OK")
end

# --- Test: Logic Catalog discipline parsing ---
begin
    println("[TEST] Logic Catalog: discipline parsing...")
    @assert GodotBridge.parse_discipline("FIFO") isa GodotBridge.FIFODiscipline
    @assert GodotBridge.parse_discipline(:priority) isa GodotBridge.PriorityHOLDiscipline
    @assert GodotBridge.parse_discipline("edd") isa GodotBridge.EarliestDueDateDiscipline
    @assert GodotBridge.parse_discipline("lifo") isa GodotBridge.LIFODiscipline
    @assert GodotBridge.parse_discipline("spt") isa GodotBridge.SPTDiscipline
    println("  ✓ discipline parsing OK")
end

# --- Test: ZoneHooks parse_hook_expr ---
begin
    println("[TEST] ZoneHooks: parse_hook_expr...")
    fn = GodotBridge.parse_hook_expr("nothing")
    @assert fn isa Function
    Base.invokelatest(fn, 1, "zone1", 0.5)  # must not throw
    println("  ✓ parse_hook_expr OK")
end

# --- Test: ZoneHooks call_hook! auto-disable on error ---
begin
    println("[TEST] ZoneHooks: auto-disable broken hook...")
    hooks = GodotBridge.ZoneHooks(on_entry = (e, z, t) -> error("intentional"))
    GodotBridge.call_hook!(hooks, :on_entry, 1, "z1", 0.0)  # must not throw
    @assert hooks.on_entry === nothing  # auto-disabled
    println("  ✓ auto-disable OK")
end

@testset "Sub-Phase 7E-1: Engine Foundations & Examples Catalog" begin
    # 1. All 7 built-in examples validate, compile, and run
    ex_list = GodotBridge.list_examples()
    @test length(ex_list) == 7

    for ex_meta in ex_list
        ex_id = ex_meta["id"]
        spec_dict = GodotBridge.get_example_scenespec(ex_id)
        typed_spec = GodotBridge.parse_typed_scenespec(spec_dict)
        val_rec = GodotBridge.validate_scenespec(typed_spec)
        @test val_rec.is_valid

        comp = GodotBridge.compile_scenespec(spec_dict)
        @test comp.success
        @test !GodotBridge.has_errors(comp.diagnostics)

        inst = GodotBridge.SimulationInstance(
            ex_id, comp.world, comp.fel, comp.zone_configs, comp.source_map, comp.execution_ir;
            seed = 123, clock_speed = Inf
        )
        GodotBridge.step_until!(inst, 120.0; fast_forward = true)
        @test inst.world.time >= 120.0
        @test haskey(inst.world.zone_stats, 0)
        @test inst.world.zone_stats[0].total_departures > 0
        @test SimCore.mean_sojourn_time(inst.world.zone_stats[0]) > 0.0

        snap = GodotBridge.build_snapshot(inst; scene_id = ex_id)
        @test haskey(snap.abm_state, "system_sojourn_mean")
        @test snap.abm_state["system_departures"] > 0

        if ex_meta["category"] == "optimization"
            @test haskey(spec_dict, "optimization")
            @test !isempty(spec_dict["optimization"]["decision_variables"])
        end
    end

    # 2. ShortestQueueRoute & RoundRobinRoute compilation and execution
    sec_spec = GodotBridge.get_example_scenespec("hybrid_security_gate")
    comp_sq = GodotBridge.compile_scenespec(sec_spec)
    @test comp_sq.success
    has_sq_route = any(cfg -> cfg.routing isa SimDES.ShortestQueueRoute, values(comp_sq.zone_configs))
    @test has_sq_route

    # 3. Multi-source priority (CompositeArrivalProcess) & PRIORITY_HOL vs FIFO in Problem 2
    p2_fifo = GodotBridge.get_example_scenespec("opt_p2_vip_dispatch")
    comp_fifo = GodotBridge.compile_scenespec(p2_fifo)
    inst_fifo = GodotBridge.SimulationInstance(
        "p2_fifo", comp_fifo.world, comp_fifo.fel, comp_fifo.zone_configs, comp_fifo.source_map, comp_fifo.execution_ir;
        seed = 42, clock_speed = Inf
    )
    GodotBridge.step_until!(inst_fifo, 600.0; fast_forward = true)
    @test haskey(inst_fifo.world.zone_stats, -100) # Standard (priority 0)
    @test haskey(inst_fifo.world.zone_stats, -101) # VIP (priority 1)
    vip_wait_fifo = SimCore.mean_wait_time(inst_fifo.world.zone_stats[-101])

    # Now switch Queue_Dispatch and Pool queues to priority discipline
    p2_prio = deepcopy(p2_fifo)
    for el in p2_prio["elements"]
        if el["kind"] == "queue"
            el["properties"]["discipline"] = "priority"
        end
    end
    comp_prio = GodotBridge.compile_scenespec(p2_prio)
    inst_prio = GodotBridge.SimulationInstance(
        "p2_prio", comp_prio.world, comp_prio.fel, comp_prio.zone_configs, comp_prio.source_map, comp_prio.execution_ir;
        seed = 42, clock_speed = Inf
    )
    GodotBridge.step_until!(inst_prio, 600.0; fast_forward = true)
    vip_wait_prio = SimCore.mean_wait_time(inst_prio.world.zone_stats[-101])
    @test vip_wait_prio <= vip_wait_fifo

    # 4. Live ZoneHooks invocation during step_until!
    tandem_spec = GodotBridge.get_example_scenespec("des_tandem_cell")
    comp_t = GodotBridge.compile_scenespec(tandem_spec)
    inst_t = GodotBridge.SimulationInstance(
        "tandem_hooks", comp_t.world, comp_t.fel, comp_t.zone_configs, comp_t.source_map, comp_t.execution_ir;
        seed = 77, clock_speed = Inf
    )
    entry_count = Ref(0)
    exit_count = Ref(0)
    inst_t.zone_hooks["Server_CNC"] = GodotBridge.ZoneHooks(
        on_entry = (eid, zid, t) -> (entry_count[] += 1; nothing),
        on_exit  = (eid, zid, t) -> (exit_count[] += 1; nothing)
    )
    GodotBridge.step_until!(inst_t, 50.0; fast_forward = true)
    @test entry_count[] > 0
    @test exit_count[] > 0
end

