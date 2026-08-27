# sprint3m_verify.jl
# Sprint 3M targeted T7 verification.
# Runs only 3L-a (Classic T7), 3L-b (JuPedSim reference), 3L-c (V3 rotational)
# from tier3_cross_library.jl -- avoiding the long 3B/3C/3J/3K tests.
#
# Usage:
#   julia --project test/sprint3m_verify.jl

using Pkg
Pkg.activate(".")

using SimCrowd
using Ark
using KernelAbstractions
using StaticArrays
using LinearAlgebra
using Random
using Test
using Printf

include("crowd_test_helpers.jl")

# ── World setup helper (copied from tier3_cross_library.jl) ──────────────────
function _make_csm_world_3m(::Type{F}, N, params::CSMParams{F}, v3::Bool=false) where {F<:AbstractFloat}
    comp_types = if v3
        (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, WallSegment{F}, AgentCSMState{F})
    else
        (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, WallSegment{F})
    end
    world = World(comp_types...)

    # Walls: 10×4m room with 1m door (center y=2) at x=10
    door_center = 2.0f0; door_half = 0.5f0
    new_entity!(world, (WallSegment(SVector(0f0,0f0), SVector(0f0,4f0)),))
    new_entity!(world, (WallSegment(SVector(0f0,0f0), SVector(10f0,0f0)),))
    new_entity!(world, (WallSegment(SVector(0f0,4f0), SVector(10f0,4f0)),))
    new_entity!(world, (WallSegment(SVector(10f0,0f0),
                                     SVector(10f0,door_center-door_half)),))
    new_entity!(world, (WallSegment(SVector(10f0,door_center+door_half),
                                     SVector(10f0,4f0)),))

    rng_3l = MersenneTwister(42)
    goal   = SVector(F(12), F(2))

    cols = max(1, ceil(Int, sqrt(N * (9.0f0 / 3.4f0))))
    rows = ceil(Int, N / cols)
    sp_x = F(9.0) / (cols + 1)
    sp_y = F(3.4) / (rows + 1)

    for k in 1:N
        row = (k-1) ÷ cols
        col = (k-1) % cols
        x   = F(0.5) + (col + 1) * sp_x + F(0.05) * (rand(rng_3l, F) - F(0.5))
        y   = F(0.3) + (row + 1) * sp_y + F(0.05) * (rand(rng_3l, F) - F(0.5))
        x = clamp(x, F(0.3), F(9.7))
        y = clamp(y, F(0.3), F(3.7))

        θ = atan(goal[2] - y, goal[1] - x)
        if v3
            new_entity!(world, (Position(SVector(x, y)),
                                Velocity(zero(SVector{2,F})),
                                Goal(goal),
                                params,
                                AgentCSMState{F}(θ)))
        else
            new_entity!(world, (Position(SVector(x, y)),
                                Velocity(zero(SVector{2,F})),
                                Goal(goal),
                                params))
        end
    end
    return world
end

# ── Parameter sweep (Classic) ─────────────────────────────────────────────────
function _classic_sweep(::Type{F}=Float32; verbose=true) where F
    N   = 80
    cfg = CSMBottleneckConfig{F}()
    a_vals = [F(5), F(8), F(10)]
    D_vals = [F(0.05), F(0.1), F(0.2)]
    T_vals = [F(0.8), F(1.0)]
    verbose && @printf("\n── Sprint 3M Classic Sweep (N=%d, 10×4m, 1m door) ──\n", N)
    verbose && @printf("%-6s %-6s %-6s  %-10s %-8s %-8s\n","a","D","T","flow(p/s)","t_exit","status")
    best_flow = zero(F); best_p = CSMParams_Classic(F)
    for a in a_vals, D in D_vals, T_gap in T_vals
        p  = CSMParams_Classic(F; a_neighbor=a, D_neighbor=D, T=T_gap)
        w  = _make_csm_world_3m(F, N, p, false)
        r  = run_csm_bottleneck!(w, cfg)
        verbose && @printf("%-6.1f %-6.3f %-6.3f  %-10.3f %-8.1f %-8s\n",
                           a, D, T_gap, r.flow_rate, r.t_exit,
                           r.deadlock ? "DEADLOCK" : "ok")
        if r.flow_rate > best_flow
            best_flow = r.flow_rate; best_p = p
        end
    end
    verbose && @printf("Best: a=%.1f D=%.3f T=%.3f -> flow=%.3f ped/s\n\n",
                       best_p.a_neighbor, best_p.D_neighbor, best_p.T, best_flow)
    return best_p, best_flow
end

# ════════════════════════════════════════════════════════════════════════════════
@testset "Sprint 3M: CSM Physics Verification" begin

    F = Float32; N = 80; cfg = CSMBottleneckConfig{F}()

    # ── 3L-a-3M: CSM-Classic T7 (Sprint 3M formula) ──────────────────────────
    @testset "3L-a-3M: Classic T7 (surface-to-surface, geo constraint)" begin
        best_p, best_flow = _classic_sweep(F; verbose=true)
        world = _make_csm_world_3m(F, N, best_p, false)
        r     = run_csm_bottleneck!(world, cfg)
        print_csm_result(r; label="3L-a-3M Classic", n_total=N)
        @printf("3L-a-3M: best a=%.1f D=%.3f T=%.3f -> flow=%.3f ped/s (target >=1.22)\n\n",
                best_p.a_neighbor, best_p.D_neighbor, best_p.T, r.flow_rate)

        # Sprint 3N-a: forward+corridor fix → 1.737 ped/s with best params.
        # Tordeux defaults (a=8, D=0.1, T=0.8) already give 1.681 ped/s > 1.22.
        @test r.n_passed == N         # All 80 agents must exit
        @test !r.deadlock             # No deadlock
        @test r.flow_rate >= F(1.22)  # T7 Weidmann lower bound (Classic achieves ~1.74)
    end

    # ── 3L-b-3M: JuPedSim reference (cross-validation) ───────────────────────
    @testset "3L-b-3M: JuPedSim reference (a=8, D=0.1, r=0.15)" begin
        p_jp  = CSMParams_JuPedSim(F)
        world = _make_csm_world_3m(F, N, p_jp, false)
        r     = run_csm_bottleneck!(world, cfg)
        print_csm_result(r; label="3L-b-3M JuPedSim", n_total=N)
        @printf("3L-b-3M: JuPedSim ref flow=%.3f ped/s (feasibility: >=0.50)\n\n", r.flow_rate)

        # Sprint 3N-a: JuPedSim ref achieves 2.162 ped/s, 80/80 exit.
        @test r.n_passed == N         # All 80 agents exit
        @test !r.deadlock             # No deadlock
        @test r.flow_rate >= F(1.22)  # T7 target met (JuPedSim params: 2.162 ped/s observed)
    end

    # ── 3L-c-3M: V3 rotational steering ──────────────────────────────────────
    @testset "3L-c-3M: V3 rotational steering (tau=0.3s)" begin
        p_v3  = CSMParams_V3(F; a_neighbor=F(8.0), D_neighbor=F(0.1), T=F(0.8))
        world = _make_csm_world_3m(F, N, p_v3, true)
        r     = run_csm_bottleneck!(world, cfg)
        print_csm_result(r; label="3L-c-3M V3", n_total=N)
        @printf("3L-c-3M: V3 (tau=%.2f) -> flow=%.3f ped/s (target >=0.80)\n\n",
                p_v3.heading_relaxation_tau, r.flow_rate)

        # Sprint 3N-a: V3 achieves 2.589 ped/s, 80/80 exit!
        # Rotational steering improves throughput vs Classic (smoother lane changes).
        @test r.n_passed == N         # All 80 agents exit
        @test !r.deadlock             # No deadlock
        @test r.flow_rate >= F(1.22)  # T7 target met (V3 observed: 2.589 ped/s)
    end

    # ── 3L-d-3N: NavigationField (FMM) + CSM Classic ─────────────────────────
    # Sprint 3N-b: build a NavigationField for the T7 geometry and run
    # update_csm_system!(world, dt, nav). Should match or improve on no-nav.
    @testset "3L-d-3N CSM + FMM NavigationField" begin
        # Build nav field for T7 room (10×4m, 1m door at x=10, y=1.5-2.5)
        t7_walls = NTuple{2, SVector{2,F}}[
            (SVector{2,F}(0, 0), SVector{2,F}(10, 0)),    # bottom
            (SVector{2,F}(0, 4), SVector{2,F}(10, 4)),    # top
            (SVector{2,F}(0, 0), SVector{2,F}(0,  4)),    # left
            (SVector{2,F}(10,0), SVector{2,F}(10,1.5)),   # right bottom (wall)
            (SVector{2,F}(10,2.5), SVector{2,F}(10, 4)),  # right top (wall)
        ]
        goal_nav = SVector{2,F}(12, 2)
        nav = build_navigation_field(t7_walls, goal_nav, F(0.05f0))
        @test nav.dims[1] > 0 && nav.dims[2] > 0   # field was built

        # Direction at door approach should point toward +x (right)
        d = get_nav_direction(nav, SVector{2,F}(5, 2))
        @test d[1] > F(0.5)                          # majority +x component

        # T7 run with nav — use _make_csm_world_3m and run inline with nav dispatch
        p_nav = CSMParams_Classic(F; v0=F(1.34), T=F(0.8),
                                  a_neighbor=F(8.0), D_neighbor=F(0.1), radius=F(0.2))
        world_nav = _make_csm_world_3m(F, N, p_nav, false)

        # Inline bottleneck loop with nav
        dt_nav = F(1/24); t_max_nav = F(120)
        t_nav = zero(F); n_nav = 0
        exit_x = F(10.1); park_x = F(-60); park_y = F(2)
        N_nav = count_entities(Query(world_nav, (CSMParams{F},)))
        while n_nav < N_nav && t_nav < t_max_nav
            update_csm_system!(world_nav, dt_nav, nav)
            t_nav += dt_nav
            for (_, pos_col, vel_col, goal_col) in
                    Query(world_nav, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
                for i in eachindex(pos_col)
                    if pos_col[i].p[1] >= exit_x
                        n_nav += 1
                        pos_col[i]  = Position(SVector(park_x, park_y))
                        vel_col[i]  = Velocity(zero(SVector{2,F}))
                        goal_col[i] = Goal(SVector(park_x - F(100), park_y))
                    end
                end
            end
        end
        deadlock_nav = t_nav >= t_max_nav && n_nav < N_nav
        flow_nav     = n_nav > 0 ? F(n_nav) / t_nav : zero(F)
        r_nav = CSMBottleneckResult{F}(flow_nav, t_nav, n_nav, deadlock_nav)
        print_csm_result(r_nav; label="3L-d-3N FMM nav", n_total=N)
        @printf("3L-d-3N: FMM nav flow=%.3f ped/s, n_passed=%d/%d\n\n",
                r_nav.flow_rate, r_nav.n_passed, N)

        @test r_nav.n_passed == N         # All 80 agents exit with FMM nav
        @test !r_nav.deadlock             # No deadlock
        @test r_nav.flow_rate >= F(1.22)  # T7 target (FMM nav)
    end

end
