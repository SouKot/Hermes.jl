# packages/SimOptim/test/test_phase7e2_sciml_p1_p2.jl
#
# Automated Verification Suite for Sub-Phase 7E-2:
# General SimOptim Core, SciML OptimizationProblem Bridge, Top-K Hall of Fame,
# and Problem 1 (ER Server Allocation) + Problem 2 (VIP Dispatcher Policy Search).

using Test
using SciMLBase
using CommonSolve
using GodotBridge
using SimCore
using SimDES
using SimOptim

@testset "Sub-Phase 7E-2: SimOptim Core, SciML Bridge & P1/P2 Solvers" begin

    # ── 1. Declarative Spec Round-Trip & SciMLBase.OptimizationProblem Interface ──
    @testset "1. SimOptimizationSpec & SciMLBase.OptimizationProblem Lowering" begin
        base_spec = GodotBridge.get_example_scenespec("des_tandem_cell")
        custom_spec = SimOptimizationSpec(
            problem_id = "custom_tandem_test",
            problem_class = :parameter,
            title = "Custom Tandem CNC + Assembly Tuning",
            decision_variables = [
                ParamDecisionVar(id="cnc_c", element_id="Server_CNC", property="servers", var_type=:int, lower=1, upper=4, initial=1),
                ParamDecisionVar(id="asm_c", element_id="Server_Assembly", property="servers", var_type=:int, lower=1, upper=4, initial=1),
                ParamDecisionVar(id="conv_spd", element_id="Conveyor_Transfer", property="speed", var_type=:float, lower=1.0, upper=3.0, initial=1.2)
            ],
            objectives = [
                ObjectiveSpec(sense=:minimize, metric="system_sojourn_mean", secondary_metric="total_servers")
            ],
            constraints = [
                ConstraintSpec(id="max_servers", kind=:linear_sum, variables=["cnc_c", "asm_c"], relation=:(<=), rhs=4.0, penalty_weight=50.0)
            ],
            solver = SolverConfig(algorithm=:bbo, max_evaluations=10, population_size=5, replications_per_eval=2, sim_horizon=150.0, warmup_time=20.0, top_k=3)
        )

        # Verify bidirectional Dict serialization
        as_dict = optimization_spec_to_dict(custom_spec)
        parsed_back = parse_optimization_spec(as_dict)
        @test parsed_back.problem_id == "custom_tandem_test"
        @test length(parsed_back.decision_variables) == 3
        @test length(parsed_back.constraints) == 1
        @test parsed_back.solver.top_k == 3

        # Build SciML OptimizationProblem and solve via CommonSolve.solve
        progress_calls = Ref(0)
        prob, ctx = build_sciml_problem(base_spec, parsed_back; on_progress = (_c) -> (progress_calls[] += 1))
        @test prob isa SciMLBase.OptimizationProblem
        @test length(prob.u0) == 3
        @test prob.lb == [1.0, 1.0, 1.0]
        @test prob.ub == [4.0, 4.0, 3.0]

        sol = CommonSolve.solve(prob, SimOptimBBO(population_size=5); maxiters=10)
        @test sol isa SciMLBase.OptimizationSolution
        @test sol.retcode == SciMLBase.ReturnCode.Success
        @test progress_calls[] == 10
        @test ctx.eval_count == 10
        @test !isempty(ctx.archive.candidates)
        @test length(ctx.archive.candidates) <= 3
        @test ctx.archive.candidates[1].rank == 1
        @test ctx.archive.candidates[1].is_feasible
    end

    # ── 2. Problem 1: ER Server Allocation (Spread [2,2,1] vs Stack [3,1,1]) ──
    @testset "2. Problem 1 — ER Server Allocation ([2,2,1] 26.3m vs [3,1,1] 48.1m)" begin
        # Verify Erlang-C building block (λ=8/hr = 8/60 min^-1, μ=10/hr = 10/60 min^-1)
        λ_min = 8.0 / 60.0
        μ_min = 10.0 / 60.0
        wq_c1 = erlang_c_wq(λ_min, μ_min, 1)
        wq_c2 = erlang_c_wq(λ_min, μ_min, 2)
        wq_c3 = erlang_c_wq(λ_min, μ_min, 3)

        @test isapprox(wq_c1, 24.0; atol=0.05)
        @test isapprox(wq_c2, 1.143; atol=0.05)
        @test isapprox(wq_c3, 0.141; atol=0.05)

        er_scenespec = GodotBridge.get_example_scenespec("opt_p1_er_allocation")
        er_opt_spec = parse_optimization_spec(er_scenespec["optimization"])
        # Use fast horizon for unit test speed while keeping full DES + Erlang-C evaluation
        er_fast_spec = SimOptimizationSpec(
            problem_id = er_opt_spec.problem_id,
            problem_class = er_opt_spec.problem_class,
            title = er_opt_spec.title,
            decision_variables = er_opt_spec.decision_variables,
            objectives = er_opt_spec.objectives,
            constraints = er_opt_spec.constraints,
            solver = SolverConfig(
                algorithm = :bbo,
                max_evaluations = 20,
                population_size = 8,
                replications_per_eval = 2,
                sim_horizon = 300.0,
                warmup_time = 50.0,
                use_crn = true,
                top_k = 5
            )
        )

        sol_p1, ctx_p1 = run_optimization!(er_scenespec; spec = er_fast_spec)
        @test sol_p1.retcode == SciMLBase.ReturnCode.Success
        @test length(ctx_p1.archive.candidates) == 5

        top1 = ctx_p1.archive.candidates[1]
        println("  [P1 Top-1] Summary = $(top1.decision_summary), W_q = $(round(top1.primary_objective; digits=2)) min, Feasible = $(top1.is_feasible)")
        for c in ctx_p1.archive.candidates
            println("    Rank #$(c.rank): $(c.decision_summary) -> W_q = $(round(c.primary_objective; digits=2)) min (feasible=$(c.is_feasible))")
        end

        # Top-1 must be one of the 2-spread configurations: [2, 2, 1], [2, 1, 2], or [1, 2, 2]
        @test top1.decision_summary in ("[2, 2, 1]", "[2, 1, 2]", "[1, 2, 2]")
        @test top1.is_feasible
        @test isapprox(top1.primary_objective, 26.285; atol=0.2)

        # All three 2-spread permutations ([2,2,1], [2,1,2], [1,2,2]) should outrank stacked [3,1,1] (~48.1 min)
        stacked_cands = filter(c -> c.decision_summary in ("[3, 1, 1]", "[1, 3, 1]", "[1, 1, 3]"), ctx_p1.archive.candidates)
        if !isempty(stacked_cands)
            @test isapprox(stacked_cands[1].primary_objective, 48.14; atol=0.2)
            @test top1.primary_objective < stacked_cands[1].primary_objective - 20.0
            @test top1.rank < stacked_cands[1].rank
        end

        # Verify Top-1 candidate carries a valid, compilable SceneSpec
        @test GodotBridge.is_scene_valid(top1.scenespec)
        comp_top1 = GodotBridge.compile_scenespec(top1.scenespec)
        @test comp_top1.success
    end

    # ── 3. Problem 2: VIP Support Dispatcher (State-Dependent Policy π*(s)) ──
    @testset "3. Problem 2 — VIP Support Dispatcher (VIP SLA <= 3.0 min & Std Wait Minimization)" begin
        vip_scenespec = GodotBridge.get_example_scenespec("opt_p2_vip_dispatch")
        vip_opt_spec = parse_optimization_spec(vip_scenespec["optimization"])

        vip_fast_spec = SimOptimizationSpec(
            problem_id = vip_opt_spec.problem_id,
            problem_class = vip_opt_spec.problem_class,
            title = vip_opt_spec.title,
            decision_variables = vip_opt_spec.decision_variables,
            objectives = vip_opt_spec.objectives,
            constraints = vip_opt_spec.constraints,
            solver = SolverConfig(
                algorithm = :policy_search,
                max_evaluations = 16,
                population_size = 8,
                replications_per_eval = 3,
                sim_horizon = 900.0,
                warmup_time = 120.0,
                use_crn = true,
                top_k = 5
            )
        )

        # Evaluate baseline (Iteration 1: prob routing, FIFO, 2+2)
        u0, _, _ = encode_initial_vector(vip_fast_spec)
        dec0, _ = decode_decision_vector(vip_fast_spec, u0)
        base_copy = deepcopy(vip_scenespec)
        apply_decision_to_scenespec!(base_copy, vip_fast_spec, dec0)
        base_metrics = evaluate_scenespec(base_copy, vip_fast_spec; decoded = dec0)
        println("  [P2 Baseline] VIP W_q = $(round(base_metrics["vip_wait_mean"]; digits=2)) min, Std W_q = $(round(base_metrics["std_wait_mean"]; digits=2)) min")

        sol_p2, ctx_p2 = run_optimization!(vip_scenespec; spec = vip_fast_spec)
        @test sol_p2.retcode == SciMLBase.ReturnCode.Success
        @test !isempty(ctx_p2.archive.candidates)

        top1_p2 = ctx_p2.archive.candidates[1]
        vip_wq_best = top1_p2.metrics["vip_wait_mean"]
        std_wq_best = top1_p2.metrics["std_wait_mean"]
        println("  [P2 Top-1] Summary = $(top1_p2.decision_summary)")
        println("             VIP W_q = $(round(vip_wq_best; digits=2)) min (SLA <= 3.0m), Std W_q = $(round(std_wq_best; digits=2)) min, Feasible = $(top1_p2.is_feasible)")

        @test top1_p2.is_feasible
        @test vip_wq_best <= 3.0
        @test top1_p2.metrics["total_servers"] <= 4.0
        @test std_wq_best < base_metrics["std_wait_mean"]
        @test GodotBridge.is_scene_valid(top1_p2.scenespec)

        # Verify optim_state_to_dict telemetry structure for GUI consumption
        state_dict = optim_state_to_dict(ctx_p2; status="completed")
        @test state_dict["status"] == "completed"
        @test state_dict["iteration"] == ctx_p2.eval_count
        @test length(state_dict["top_k_solutions"]) == length(ctx_p2.archive.candidates)
        @test length(state_dict["convergence_history"]) == ctx_p2.eval_count
    end

end
