# packages/GodotBridge/test/test_conveyor_curves.jl
#
# Unit & Integration Test Suite for the General 3D/2D Parametric Conveyor Curve
# & Network Junction Alignment System.

using Test
using GodotBridge
using GodotBridge: Pose3D, sample_conveyor_curve, CONVEYOR_SHAPE_PRESETS, bake_conveyor_curve, register_conveyor_shape_preset!
using SimOptim
using Graphs
using JSON

@testset "General Parametric Conveyor Curve & Junction Alignment Suite" begin

    @testset "1. All 8 Shape Presets & Extensible Registry" begin
        inlet  = Pose3D((0.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        outlet = Pose3D((10.0, 5.0, 0.0), (0.0, 1.0, 0.0))
        params = Dict{String, Any}(
            "bend_radius" => 2.5,
            "sweep_angle_deg" => 90.0,
            "passes" => 3,
            "pass_spacing" => 2.0,
            "helix_radius" => 2.5,
            "helix_turns" => 1.5,
            "elevation_gain" => 3.0,
            "control_points" => [[0.0, 0.0, 0.0], [4.0, 2.0, 0.5], [8.0, -1.0, 1.0], [12.0, 0.0, 1.0]]
        )

        for preset_sym in (:straight, :s_curve, :l_bend, :u_turn, :circular_arc, :serpentine, :spiral_helix, :custom_spline)
            @test haskey(CONVEYOR_SHAPE_PRESETS, preset_sym)
            gen_fn = CONVEYOR_SHAPE_PRESETS[preset_sym]
            cpts = gen_fn(inlet, outlet, params)
            @test length(cpts) >= 2

            baked = bake_conveyor_curve(preset_sym, cpts; num_samples=64)
            @test baked.preset == preset_sym
            @test baked.total_length > 1.0
            @test length(baked.arc_lengths) == 65
            @test issorted(baked.arc_lengths)
            @test isapprox(baked.arc_lengths[1], 0.0; atol=1e-9)
            @test isapprox(baked.arc_lengths[end], baked.total_length; atol=1e-6)

            # Verify start and end evaluation
            p0, t0 = sample_conveyor_curve(baked, 0.0)
            p1, t1 = sample_conveyor_curve(baked, 1.0)
            @test hypot(hypot(p0[1] - cpts[1].pos[1], p0[2] - cpts[1].pos[2]), p0[3] - cpts[1].pos[3]) < 1e-5
            @test hypot(hypot(p1[1] - cpts[end].pos[1], p1[2] - cpts[end].pos[2]), p1[3] - cpts[end].pos[3]) < 1e-5
            @test isapprox(hypot(hypot(t0[1], t0[2]), t0[3]), 1.0; atol=1e-4)
            @test isapprox(hypot(hypot(t1[1], t1[2]), t1[3]), 1.0; atol=1e-4)
        end

        # Verify custom shape preset registration extensibility
        register_conveyor_shape_preset!(:dogleg_test, (in_p, out_p, prm) -> [
            SplineControlPoint3D(in_p.pos),
            SplineControlPoint3D((5.0, 0.0, 0.0)),
            SplineControlPoint3D(out_p.pos)
        ])
        @test haskey(CONVEYOR_SHAPE_PRESETS, :dogleg_test)
        delete!(CONVEYOR_SHAPE_PRESETS, :dogleg_test)

        controlled = [
            Dict("pos" => [0.0, 0.0, 0.0], "out_handle" => [3.0, 5.0, 0.0]),
            Dict("pos" => [10.0, 0.0, 0.0], "in_handle" => [-3.0, 5.0, 0.0])
        ]
        freeform = CONVEYOR_SHAPE_PRESETS[:custom_spline](inlet, outlet, Dict("control_points" => controlled))
        @test freeform[1].out_handle == (3.0, 5.0, 0.0)
        @test freeform[2].in_handle == (-3.0, 5.0, 0.0)
        freeform_baked = bake_conveyor_curve(:custom_spline, freeform)
        @test sample_conveyor_curve(freeform_baked, 0.5)[1][2] > 3.0

        short = CONVEYOR_SHAPE_PRESETS[:serpentine](inlet, outlet, Dict("passes" => 3, "pass_length" => 8.0))
        long = CONVEYOR_SHAPE_PRESETS[:serpentine](inlet, outlet, Dict("passes" => 3, "pass_length" => 12.0))
        @test bake_conveyor_curve(:serpentine, long).total_length > bake_conveyor_curve(:serpentine, short).total_length + 10.0
        @test length(CONVEYOR_SHAPE_PRESETS[:serpentine](inlet, outlet, Dict("passes" => 12, "pass_spacing" => 2.0, "pass_length" => 8.0))) == 35
        legacy_serp = CONVEYOR_SHAPE_PRESETS[:serpentine](inlet, outlet, Dict("passes" => 3, "pitch" => 2.4, "pass_length" => 8.0))
        @test isapprox(legacy_serp[end].pos[2] - inlet.pos[2], 4.8; atol=1e-6)
        serp_leads = CONVEYOR_SHAPE_PRESETS[:serpentine](inlet, outlet, Dict("passes" => 3, "pass_spacing" => 2.0, "pass_length" => 8.0, "infeed_length" => 2.0, "outfeed_length" => 3.0))
        @test length(serp_leads) == 10
        @test maximum(abs(serp_leads[1].pos[i] - (0.0, 0.0, 0.0)[i]) for i in 1:3) < 1e-6
        @test isapprox(serp_leads[end].pos[1], 13.0; atol=1e-6)
        turn_base = CONVEYOR_SHAPE_PRESETS[:u_turn](inlet, outlet, Dict("leg_length" => 6.0, "bend_radius" => 2.0))
        turn_short_return = CONVEYOR_SHAPE_PRESETS[:u_turn](inlet, outlet, Dict("leg_length" => 6.0, "return_leg_length" => 3.0, "bend_radius" => 2.0))
        @test isapprox(turn_short_return[end].pos[1] - turn_base[end].pos[1], 3.0; atol=1e-6)
        @test turn_short_return[3].pos == turn_base[3].pos
        flat_helix = CONVEYOR_SHAPE_PRESETS[:spiral_helix](inlet, outlet, Dict("helix_radius" => 2.0, "helix_turns" => 1.5, "elevation_gain" => 0.0))
        @test abs(flat_helix[end].pos[3] - inlet.pos[3]) < 1e-6

        fixed_end = CONVEYOR_SHAPE_PRESETS[:s_curve](inlet, outlet, Dict("preserve_endpoints" => true, "lateral_offset" => 5.0))
        @test fixed_end[end].pos == outlet.pos
        @test fixed_end[end].in_handle[2] < 0.0

        parity_cases = JSON.parsefile(joinpath(@__DIR__, "../../../godot/tests/conveyor_geometry_parity.json"))
        for case in parity_cases
            to_vec3(value) = (Float64(value[1]), Float64(value[2]), Float64(value[3]))
            in_pose = Pose3D(to_vec3(case["inlet"]), to_vec3(case["inlet_tangent"]))
            out_pose = Pose3D(to_vec3(case["outlet"]), to_vec3(case["outlet_tangent"]))
            preset = Symbol(case["preset"])
            curve = bake_conveyor_curve(preset, CONVEYOR_SHAPE_PRESETS[preset](in_pose, out_pose, case["params"]); num_samples=64)
            mid_pos, _ = sample_conveyor_curve(curve, 0.5)
            end_pos, _ = sample_conveyor_curve(curve, 1.0)
            @test sum((mid_pos[i] - case["midpoint"][i])^2 for i in 1:3) < 0.01
            @test sum((end_pos[i] - case["end"][i])^2 for i in 1:3) < 1e-4
            if haskey(case, "end_tangent")
                _, end_tangent = sample_conveyor_curve(curve, 1.0)
                @test sum(end_tangent[i] * case["end_tangent"][i] for i in 1:3) > 0.995
            end
        end
    end

    @testset "2. Constant-Speed Arc-Length Parameterization & Zero-Allocation Lookup" begin
        inlet  = Pose3D((0.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        outlet = Pose3D((12.0, 8.0, 0.0), (1.0, 0.0, 0.0))
        cpts   = CONVEYOR_SHAPE_PRESETS[:s_curve](inlet, outlet, Dict{String, Any}())
        baked  = bake_conveyor_curve(:s_curve, cpts; num_samples=64)

        # Sample at 10 equal intervals of t_frac and verify equal physical step distances
        N_steps = 10
        expected_ds = baked.total_length / N_steps
        prev_p, _ = sample_conveyor_curve(baked, 0.0)
        for k in 1:N_steps
            curr_p, _ = sample_conveyor_curve(baked, Float64(k) / Float64(N_steps))
            step_d = hypot(hypot(curr_p[1] - prev_p[1], curr_p[2] - prev_p[2]), curr_p[3] - prev_p[3])
            @test isapprox(step_d, expected_ds; rtol=0.05)
            prev_p = curr_p
        end

        # Verify zero heap allocation on hot-path sample_conveyor_curve
        sample_conveyor_curve(baked, 0.37)
        allocs = @allocated sample_conveyor_curve(baked, 0.37)
        @test allocs == 0
    end

    @testset "3. C⁰ Position & C¹ Tangent Continuity on Problem 3 Spine & Closed Loop" begin
        p3_doc = GodotBridge.get_example_scenespec("opt_p3_conveyor_topology")

        # (a) Initial 1D Linear Spine: Conveyor_West -> Conveyor_North -> Conveyor_East -> Conveyor_South
        comp_spine = GodotBridge.compile_scenespec(p3_doc)
        @test comp_spine.success
        ir_spine = comp_spine.execution_ir
        conv_order = ["Conveyor_West", "Conveyor_North", "Conveyor_East", "Conveyor_South"]
        for i in 1:3
            c_u = ir_spine.conveyor_curves[conv_order[i]]
            c_v = ir_spine.conveyor_curves[conv_order[i + 1]]
            p_end, t_end   = sample_conveyor_curve(c_u, 1.0)
            p_start, t_start = sample_conveyor_curve(c_v, 0.0)
            # Outlet of conveyor i must equal Inlet of conveyor i+1 (zero jump!)
            dist_jump = hypot(hypot(p_end[1] - p_start[1], p_end[2] - p_start[2]), p_end[3] - p_start[3])
            @test dist_jump < 1e-4
            # Both move strictly West -> East (+X)
            @test t_end[1] > 0.99
            @test t_start[1] > 0.99
        end

        # (b) Optimized 2D Closed-Loop Racetrack: West -> North -> East -> South -> West
        g_loop = extract_conveyor_graph(p3_doc)
        add_edge!(g_loop.adj, 4, 1)
        g_loop.layout_mode = :folded_2d
        g_loop.spur_mode = :direct_ring
        optimize_spatial_coordinates!(g_loop)

        loop_doc = deepcopy(p3_doc)
        apply_topology_to_scenespec!(loop_doc, g_loop)

        comp_loop = GodotBridge.compile_scenespec(loop_doc)
        @test comp_loop.success
        ir_loop = comp_loop.execution_ir

        for i in 1:4
            u_id = conv_order[i]
            v_id = conv_order[mod1(i + 1, 4)]
            c_u = ir_loop.conveyor_curves[u_id]
            c_v = ir_loop.conveyor_curves[v_id]
            @test c_u.preset == :l_bend

            p_end, t_end     = sample_conveyor_curve(c_u, 1.0)
            p_start, t_start = sample_conveyor_curve(c_v, 0.0)

            # Verify C⁰ position continuity (Outlet(u) == Inlet(v)) around the entire closed loop
            jump_err = hypot(hypot(p_end[1] - p_start[1], p_end[2] - p_start[2]), p_end[3] - p_start[3])
            @test jump_err < 1e-3

            # Verify C¹ tangent continuity (Tangent_out(u) == Tangent_in(v)) around the entire closed loop
            tan_dot = t_end[1]*t_start[1] + t_end[2]*t_start[2] + t_end[3]*t_start[3]
            @test tan_dot > 0.995
        end
    end
end
