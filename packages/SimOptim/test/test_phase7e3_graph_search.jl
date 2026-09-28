# packages/SimOptim/test/test_phase7e3_graph_search.jl
#
# Verification Suite for Sub-Phase 7E-3:
#   1. ConveyorNetworkGraph 3D coordinate extraction & 100m Linear Spine baseline physics (73.21s)
#   2. Physical & 3D Elevation Constraints (:constant_z, :preserve_node_z, :bounded_3d) & 1D Mutation Valley
#   3. Template-Free Bilevel Graph + 3D/2D Spatial Search on Problem 3 (100m Spine -> 60m Closed Loop, 48.21s)

using Test
using SciMLBase
using CommonSolve
using Graphs
using GodotBridge
using SimOptim

@testset "Sub-Phase 7E-3: Template-Free Bilevel Graph & 3D/2D Spatial Search (Problem 3)" begin

    # ── 1. Extract ConveyorNetworkGraph (3D) & Verify Baseline 100m Linear Spine ──
    @testset "1. Baseline 100m Linear Spine 3D Extraction & Physics" begin
        p3_doc = GodotBridge.get_example_scenespec("opt_p3_conveyor_topology")
        g_spine = extract_conveyor_graph(p3_doc)

        @test nv(g_spine.adj) == 4
        @test ne(g_spine.adj) == 3
        @test !Graphs.is_cyclic(g_spine.adj)
        @test !is_strongly_connected_loop(g_spine.adj)
        @test all_stations_reachable(g_spine.adj, 1)
        @test max_port_degree(g_spine.adj) == 1
        @test g_spine.layout_mode == :collinear_1d
        @test g_spine.spur_mode == :spurs_10m
        @test g_spine.z_constraint == :constant_z
        @test g_spine.z_fixed == 0.0
        @test all(c -> c isa NTuple{3, Float64} && c[3] == 0.0, g_spine.coords)
        @test max_z_elevation_deviation(g_spine) == 0.0
        @test isapprox(g_spine.arrival_rate, 8.0 / 60.0; atol = 1e-4)
        @test isapprox(g_spine.service_rate, 3.0 / 60.0; atol = 1e-4)
        @test isapprox(min_station_separation(g_spine.coords), 15.0; atol = 0.1)

        phys_spine = compute_conveyor_network_physics(g_spine)
        @test isapprox(phys_spine.total_belt_length, 100.0; atol = 0.1)
        @test isapprox(phys_spine.mean_transit_time, 47.5; atol = 0.1)
        @test isapprox(phys_spine.queue_wait_time, 5.71; atol = 0.1)
        @test isapprox(phys_spine.service_time, 20.0; atol = 0.1)
        @test isapprox(phys_spine.mean_sojourn_time, 73.21; atol = 0.15)
    end

    # ── 2. Physical Constraints, 3D Elevation Modes, Mutation Valley & Folding ───
    @testset "2. Physical Constraints, 3D Elevation Modes, Mutation Valley & Nelder-Mead Folding" begin
        p3_doc = GodotBridge.get_example_scenespec("opt_p3_conveyor_topology")
        g_base = extract_conveyor_graph(p3_doc)

        # (a) Finite induction buffer constraint: Open spine without 10m spurs deadlocks
        g_deadlock = copy(g_base)
        g_deadlock.spur_mode = :direct_ring
        feas_dl = check_topology_feasibility(g_deadlock)
        @test feas_dl.deadlock_free_spurs == 0.0
        @test !feas_dl.is_feasible

        # (b) Constant-z elevation constraint: Perturbing z when z_constraint == :constant_z is flagged infeasible
        g_bad_z = copy(g_base)
        g_bad_z.coords[2] = (g_bad_z.coords[2][1], g_bad_z.coords[2][2], 3.5)
        feas_z = check_topology_feasibility(g_bad_z)
        @test isapprox(feas_z.z_elevation_deviation, 3.5; atol = 1e-4)
        @test !feas_z.is_feasible

        # (c) Multi-floor 3D preservation (:preserve_node_z) & Bounded 3D (:bounded_3d)
        g_mezz = copy(g_base)
        g_mezz.z_constraint = :preserve_node_z
        g_mezz.initial_z = [0.0, 0.0, 4.5, 4.5]
        add_edge!(g_mezz.adj, 4, 1)
        g_mezz.layout_mode = :folded_2d
        g_mezz.spur_mode = :direct_ring
        # Before (x,y) re-optimization, check that 3D Euclidean belt length accounts for vertical climb dz = 4.5m
        g_mezz.coords = [(-7.5, -7.5, 0.0), (-7.5, 7.5, 0.0), (7.5, 7.5, 4.5), (7.5, -7.5, 4.5)]
        @test total_belt_length(g_mezz) > 61.0
        # After 3D-aware spatial optimization, z is preserved and 3D separation >= 15.0m holds
        optimize_spatial_coordinates!(g_mezz)
        @test g_mezz.coords[1][3] == 0.0
        @test g_mezz.coords[3][3] == 4.5
        @test max_z_elevation_deviation(g_mezz) == 0.0
        @test min_station_separation(g_mezz.coords) >= 15.0 - 0.05

        g_3d = copy(g_base)
        g_3d.z_constraint = :bounded_3d
        g_3d.z_bounds = (0.0, 8.0)
        g_3d.coords = [(-15.0, 0.0, 1.0), (0.0, 15.0, 3.0), (15.0, 0.0, 5.0), (0.0, -15.0, 2.0)]
        add_edge!(g_3d.adj, 4, 1)
        g_3d.layout_mode = :folded_2d
        g_3d.spur_mode = :direct_ring
        optimize_spatial_coordinates!(g_3d)
        @test all(p -> 0.0 <= p[3] <= 8.0, g_3d.coords)
        @test min_station_separation(g_3d.coords) >= 15.0 - 0.05

        # (d) Mutation Valley: Closing edge 4 -> 1 on 1D collinear spine requires 45m return belt (90m-130m total)
        g_valley = copy(g_base)
        add_edge!(g_valley.adj, 4, 1)
        g_valley.layout_mode = :collinear_1d
        optimize_spatial_coordinates!(g_valley)
        phys_valley = compute_conveyor_network_physics(g_valley)
        feas_valley = check_topology_feasibility(g_valley)
        @test Graphs.is_cyclic(g_valley.adj)
        @test phys_valley.total_belt_length >= 90.0
        @test !feas_valley.is_feasible

        # (e) Branched Binary Tree (1->2, 1->3, 2->4): 70m belt, 65.71s sojourn
        g_tree = copy(g_base)
        rem_edge!(g_tree.adj, 2, 3)
        rem_edge!(g_tree.adj, 3, 4)
        add_edge!(g_tree.adj, 1, 3)
        add_edge!(g_tree.adj, 2, 4)
        g_tree.layout_mode = :folded_2d
        g_tree.spur_mode = :spurs_10m
        optimize_spatial_coordinates!(g_tree)
        phys_tree = compute_conveyor_network_physics(g_tree)
        @test is_branched_tree(g_tree.adj)
        @test isapprox(phys_tree.total_belt_length, 70.0; atol = 0.5)
        @test isapprox(phys_tree.mean_sojourn_time, 65.71; atol = 0.2)

        # (f) Inner-Loop Coordinate Folding on Closed Loop with constant z=0: 15m x 15m ring (60m belt, 48.21s)
        g_loop = copy(g_base)
        add_edge!(g_loop.adj, 4, 1)
        g_loop.layout_mode = :folded_2d
        g_loop.spur_mode = :direct_ring
        optimize_spatial_coordinates!(g_loop)

        phys_loop = compute_conveyor_network_physics(g_loop)
        feas_loop = check_topology_feasibility(g_loop)

        @test is_strongly_connected_loop(g_loop.adj)
        @test feas_loop.is_feasible
        @test feas_loop.min_station_separation >= 15.0 - 0.05
        @test feas_loop.z_elevation_deviation == 0.0
        @test all(p -> p[3] == 0.0, g_loop.coords)
        @test feas_loop.max_port_degree == 1.0
        @test feas_loop.deadlock_free_spurs == 1.0
        @test isapprox(phys_loop.total_belt_length, 60.0; atol = 0.5)
        @test isapprox(phys_loop.mean_transit_time, 22.5; atol = 0.5)
        @test isapprox(phys_loop.mean_sojourn_time, 48.21; atol = 0.5)
    end

    # ── 3. Full Bilevel Graph & Spatial Search (100m Spine -> 60m Loop) ───
    @testset "3. End-to-End Template-Free Bilevel Discovery on Problem 3" begin
        p3_doc = GodotBridge.get_example_scenespec("opt_p3_conveyor_topology")
        progress_steps = Int[]

        sol, ctx = run_optimization!(
            p3_doc;
            on_progress = (c) -> push!(progress_steps, c.eval_count)
        )

        @test sol.retcode == SciMLBase.ReturnCode.Success
        @test !isempty(progress_steps)
        @test length(ctx.archive.candidates) == 5

        # Verify Iteration 1 evaluated the 100m Linear Spine (W ≈ 73.21s)
        iter1 = ctx.convergence_history[1]
        @test occursin("Linear Spine", iter1["summary"])
        @test isapprox(iter1["current_objective"], 73.21; atol = 0.5)

        # Verify Mutation Valley was encountered during search (1D unfolded loop / high penalized cost)
        has_valley_spike = any(h -> h["current_objective"] > 75.0 || h["current_penalized"] > 200.0, ctx.convergence_history)
        @test has_valley_spike

        # Verify Rank #1 in Top-K Hall of Fame is a 2D Closed Loop with 60m belt and 48.21s sojourn
        top1 = ctx.archive.candidates[1]
        println("  [P3 Baseline] Linear Spine (1D, Spurs10m) -> Belt = 100.0 m, W = 73.21 s")
        println("  [P3 Top-1]    Summary = $(top1.decision_summary)")
        println("                Belt = $(top1.metrics["total_conveyor_length"]) m, W = $(top1.primary_objective) s, Feasible = $(top1.is_feasible)")
        for cand in ctx.archive.candidates
            println("    Rank #$(cand.rank): $(cand.decision_summary) -> W = $(cand.primary_objective) s, Belt = $(cand.metrics["total_conveyor_length"]) m (feasible=$(cand.is_feasible))")
        end

        @test top1.is_feasible
        @test top1.metrics["is_cyclic"] == 1.0
        @test top1.metrics["is_strongly_connected"] == 1.0
        @test top1.metrics["z_elevation_deviation"] == 0.0
        @test isapprox(top1.metrics["total_conveyor_length"], 60.0; atol = 1.0)
        @test isapprox(top1.metrics["mean_transit_time"], 22.5; atol = 0.5)
        @test isapprox(top1.primary_objective, 48.21; atol = 0.5)

        # Verify Top-1 SceneSpec snapshot has 3D coordinates (x, y, z) with constant z=0, validates, and simulates in SimDES
        snap_spec = top1.scenespec_snapshot
        g_snap = extract_conveyor_graph(snap_spec)
        @test Graphs.is_cyclic(g_snap.adj)
        @test is_strongly_connected_loop(g_snap.adj)
        @test any(p -> abs(p[2]) > 5.0, g_snap.coords)
        @test all(p -> p[3] == 0.0, g_snap.coords)

        typed_snap = GodotBridge.parse_typed_scenespec(snap_spec)
        val_snap = GodotBridge.validate_scenespec(typed_snap)
        @test val_snap.is_valid

        comp_snap = GodotBridge.compile_scenespec(snap_spec)
        @test comp_snap.success
        inst_snap = GodotBridge.SimulationInstance(
            "p3_top1_verify", comp_snap.world, comp_snap.fel, comp_snap.zone_configs, comp_snap.source_map, comp_snap.execution_ir;
            seed = 99, clock_speed = Inf
        )
        GodotBridge.step_until!(inst_snap, 200.0; fast_forward = true)
        @test inst_snap.world.zone_stats[0].total_departures > 0

        # ── 4. Sub-Phase 7F-2: Verify Universal Junction Continuity across ALL Top-5 Archive Candidates ──
        for cand_rec in ctx.archive.candidates
            cspec = cand_rec.scenespec_snapshot
            cg = extract_conveyor_graph(cspec)
            comp_c = GodotBridge.compile_scenespec(cspec)
            @test comp_c.success
            curves = comp_c.execution_ir.conveyor_curves
            for e in edges(cg.adj)
                u_id = cg.conveyor_ids[src(e)]
                v_id = cg.conveyor_ids[dst(e)]
                @test haskey(curves, u_id)
                @test haskey(curves, v_id)
                cu = curves[u_id]
                cv = curves[v_id]
                # Every connected conveyor edge (u -> v) must have exact C0 endpoint coincidence (Γ_u(1) == Γ_v(0))
                pos_gap = hypot(
                    cu.outlet_pose.pos[1] - cv.inlet_pose.pos[1],
                    cu.outlet_pose.pos[2] - cv.inlet_pose.pos[2],
                    cu.outlet_pose.pos[3] - cv.inlet_pose.pos[3]
                )
                @test pos_gap < 0.05
            end
        end
    end
end
