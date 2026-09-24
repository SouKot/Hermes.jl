# packages/GodotBridge/test/test_analytical_benchmarks.jl
#
# Unit tests for Analytical Queueing Benchmarks & Little's Law Invariant Engine.

using Test
using GodotBridge

@testset "Analytical Benchmarks & Mathematical Verification" begin
    @testset "M/M/1 Closed-Form Solution" begin
        # lambda = 1.0, mu = 2.0 -> rho = 0.5
        res = solve_mm1(1.0, 2.0)
        @test res.rho == 0.5
        @test res.L == 1.0
        @test res.Lq == 0.5
        @test res.W == 1.0
        @test res.Wq == 0.5

        # Check Little's Law identity: L = lambda * W, Lq = lambda * Wq
        @test isapprox(res.L, 1.0 * res.W)
        @test isapprox(res.Lq, 1.0 * res.Wq)
        @test isapprox(res.W, res.Wq + 1.0 / 2.0)

        # Unstable system throws ArgumentError
        @test_throws ArgumentError solve_mm1(2.0, 1.0)
        @test_throws ArgumentError solve_mm1(-1.0, 2.0)
    end

    @testset "M/M/c Multi-Server Closed-Form Solution" begin
        # lambda = 2.0, mu = 1.5, c = 2 -> c*mu = 3.0, rho = 2/3
        res = solve_mmc(2.0, 1.5, 2)
        @test isapprox(res.rho, 2.0 / 3.0, atol=1e-6)
        @test isapprox(res.L, 2.0 * res.W, atol=1e-6)
        @test isapprox(res.Lq, 2.0 * res.Wq, atol=1e-6)
        @test isapprox(res.W, res.Wq + (1.0 / 1.5), atol=1e-6)

        # c=1 should match M/M/1 exactly
        res_c1 = solve_mmc(1.0, 2.0, 1)
        res_mm1 = solve_mm1(1.0, 2.0)
        @test isapprox(res_c1.W, res_mm1.W, atol=1e-6)
        @test isapprox(res_c1.Lq, res_mm1.Lq, atol=1e-6)

        # Unstable throws ArgumentError
        @test_throws ArgumentError solve_mmc(5.0, 1.0, 3)
    end

    @testset "M/G/1 Pollaczek-Khinchine Formula" begin
        # For M/M/1 service (exponential with mean 0.5): var = (1/mu)^2 = 0.25
        res_exp = solve_mg1(1.0, 2.0, 0.25)
        res_mm1 = solve_mm1(1.0, 2.0)
        @test isapprox(res_exp.Wq, res_mm1.Wq, atol=1e-6)

        # For M/D/1 deterministic service (var = 0.0): Wq is exactly half of M/M/1
        res_det = solve_mg1(1.0, 2.0, 0.0)
        @test isapprox(res_det.Wq, res_mm1.Wq * 0.5, atol=1e-6)
        @test isapprox(res_det.L, 1.0 * res_det.W, atol=1e-6)
    end

    @testset "Jackson Tandem Network" begin
        tandem = solve_jackson_tandem(1.0, [2.0, 3.0, 4.0])
        @test length(tandem) == 3
        @test tandem[1].rho == 0.5
        @test tandem[2].rho == 1.0 / 3.0
        @test tandem[3].rho == 0.25

        # Total expected network sojourn is sum of station sojourns
        total_W = sum(s.W for s in tandem)
        @test isapprox(total_W, 1.0 + (1.0 / 2.0) + (1.0 / 3.0), atol=1e-6)
    end

    @testset "Little's Law Invariant Evaluator" begin
        # Perfect match
        err1, status1 = evaluate_littles_law(10.0, 2.0, 5.0)
        @test err1 == 0.0
        @test status1 == :valid

        # Small 1% error
        err2, status2 = evaluate_littles_law(10.1, 2.0, 5.0)
        @test err2 < 0.02
        @test status2 == :valid

        # 5% error -> converging
        err3, status3 = evaluate_littles_law(10.5, 2.0, 5.0)
        @test status3 == :converging

        # 20% error -> divergent
        err4, status4 = evaluate_littles_law(12.0, 2.0, 5.0)
        @test status4 == :divergent
    end

    @testset "Empirical Benchmark Validation Report" begin
        bench = solve_mm1(1.0, 2.0)
        sim_metrics = Dict{String, Float64}(
            "utilization" => 0.505,
            "sojourn_mean" => 1.02,
            "wait_mean" => 0.51,
            "wip_mean" => 1.01,
            "queue_mean" => 0.49
        )
        reports = validate_benchmark(sim_metrics, bench; tolerance=0.05)
        @test length(reports) == 5
        @test all(r -> r.passed, reports)
        @test all(r -> r.status == :pass, reports)
    end
end
