"""
    runtests.jl — Sprint 4A unit tests for SimViz (headless)

These tests cover the headless layer only (viz_state, scenario_config, density).
GLMakie rendering tests are manual — a display server is not available in CI.

Run with:
    julia --project=packages/SimViz -e "using Pkg; Pkg.test()"
"""

# ── Bootstrap: load headless layer directly so GLMakie is never imported ──────
# We include the source files inside a test-local module to avoid conflicts
# with the `using SimViz` path that would drag in GLMakie.

module HeadlessLayer
    using Ark: World, Query
    using Observables: Observable
    using StaticArrays: SVector
    using SimCore: SimWorld, SimStats
    using SimCrowd:
        Position, Velocity, Force, Goal, WallSegment,
        AgentGeometry, MotionParams, SFMParams, ORCAParams,
        HybridFSMParams, AgentFSMState, CSMParams,
        AgentModel, SFMModel, ORCAModel, HybridModel,
        SimConfig, SimScene, JacobiCorrection, XPBDCorrection,
        VelocityImpulseParams, CPUNeighborSearch,
        ORCA_MODE, SFM_MODE, step!
    using Random: MersenneTwister
    using LinearAlgebra: norm

    include(joinpath(@__DIR__, "..", "src", "viz_state.jl"))
    include(joinpath(@__DIR__, "..", "src", "scenario_config.jl"))
    include(joinpath(@__DIR__, "..", "src", "density.jl"))
end

using Test

# ── Test helpers ──────────────────────────────────────────────────────────────

# Make short aliases so test bodies are clean
const HL   = HeadlessLayer
const Pos2 = NTuple{2, Float32}

# Build a minimal ScenarioContext for tests without spawning GLMakie
function make_ctx(; n=20, model=HL.MODEL_SFM, seed=42)
    cfg = HL.ScenarioConfig(n_agents=n, crowd_model=model, rng_seed=seed)
    return HL.build_world!(cfg), cfg
end

# ══════════════════════════════════════════════════════════════════════════════
# 4A-02 · viz_state.jl
# ══════════════════════════════════════════════════════════════════════════════

@testset "4A-02 viz_state — serialize_world" begin

    @testset "Field types (SFM world — no FSM component)" begin
        ctx, cfg = make_ctx(n=15, model=HL.MODEL_SFM)
        snap = HL.serialize_world_ctx(ctx)

        @test snap isa NamedTuple
        @test haskey(snap, :sim_time)
        @test haskey(snap, :positions)
        @test haskey(snap, :velocities)
        @test haskey(snap, :panic_levels)
        @test haskey(snap, :fsm_modes)
        @test haskey(snap, :local_densities)
        @test haskey(snap, :n_agents)
        @test haskey(snap, :n_des_agents)
        @test haskey(snap, :stats)

        # Agent count matches config
        @test snap.n_agents == 15

        # positions / velocities must be NTuple{2,Float32}
        @test eltype(snap.positions)  === NTuple{2, Float32}
        @test eltype(snap.velocities) === NTuple{2, Float32}
        @test length(snap.positions)  == 15
        @test length(snap.velocities) == 15

        # panic levels must be Float32 ∈ [0,1]
        @test eltype(snap.panic_levels) === Float32
        @test all(0f0 .<= snap.panic_levels .<= 1f0)

        # fsm_modes: in pure-SFM world all sentinels (0xFF)
        @test eltype(snap.fsm_modes) === UInt8
        @test all(snap.fsm_modes .== 0xFF)

        # local_densities: Float32, all zeros for SFM world
        @test eltype(snap.local_densities) === Float32

        # sim_time stubbed at 0.0 initially
        @test snap.sim_time === 0.0

        # stats sub-NT must have these 5 fields
        s = snap.stats
        @test haskey(s, :total_events)
        @test haskey(s, :total_arrivals)
        @test haskey(s, :total_departures)
        @test haskey(s, :busy_time)
        @test haskey(s, :elapsed_sim_time)
    end

    @testset "Field types (ORCA world)" begin
        ctx, cfg = make_ctx(n=10, model=HL.MODEL_ORCA)
        snap = HL.serialize_world_ctx(ctx)
        @test snap.n_agents == 10
        @test eltype(snap.fsm_modes) === UInt8
        @test all(snap.fsm_modes .== 0xFF)  # ORCA world also has no FSM component
    end

    @testset "Field types (Hybrid-FSM world — has AgentFSMState)" begin
        ctx, cfg = make_ctx(n=12, model=HL.MODEL_HYBRID_FSM)
        # With the fixed _world_has_component, the FSM query runs correctly.
        # Agents start in ORCA_MODE (0x00) — all modes are valid {0=ORCA, 1=SFM} from the start.
        # (The old 0xFF sentinel was an artifact of the broken _world_has_component that
        # was skipping the FSM query pass entirely.)
        HL.step!(ctx.scene)
        ctx.sim_time += ctx.config.dt
        snap = HL.serialize_world_ctx(ctx)
        @test snap.n_agents == 12
        @test eltype(snap.fsm_modes) === UInt8
        @test all(m -> m == UInt8(HL.ORCA_MODE) || m == UInt8(HL.SFM_MODE), snap.fsm_modes)
        @test eltype(snap.local_densities) === Float32
        @test all(>=(0f0), snap.local_densities)
    end

    @testset "_world_has_component — SFM world" begin
        ctx, _ = make_ctx(model=HL.MODEL_SFM)
        # All components registered at World construction time
        @test  HL._world_has_component(ctx.ark_world, HL.Position{Float32})
        @test  HL._world_has_component(ctx.ark_world, HL.Velocity{Float32})
        # AgentFSMState is NOT registered in SFM world
        @test !HL._world_has_component(ctx.ark_world, HL.AgentFSMState{Float32})
    end

    @testset "_world_has_component — Hybrid-FSM world" begin
        ctx, _ = make_ctx(model=HL.MODEL_HYBRID_FSM)
        # AgentFSMState IS registered in HybridFSM world at construction time
        @test HL._world_has_component(ctx.ark_world, HL.AgentFSMState{Float32})
        @test HL._world_has_component(ctx.ark_world, HL.Position{Float32})
    end

    @testset "No Float64 leaks in snapshot" begin
        ctx, _ = make_ctx(n=5, model=HL.MODEL_SFM)
        snap = HL.serialize_world_ctx(ctx)
        for (x, y) in snap.positions
            @test x isa Float32
            @test y isa Float32
        end
        for (vx, vy) in snap.velocities
            @test vx isa Float32
            @test vy isa Float32
        end
        @test snap.panic_levels[1] isa Float32
        @test snap.local_densities[1] isa Float32
    end
end

@testset "4A-02 viz_state — color helpers" begin

    @testset "_panic_to_color" begin
        c0 = HL._panic_to_color(0f0)   # calm → green-ish
        c1 = HL._panic_to_color(1f0)   # panic → red-ish
        cm = HL._panic_to_color(0.5f0) # mid → yellow-ish

        @test c0 isa NTuple{4, Float32}
        @test c1 isa NTuple{4, Float32}

        # Green: g > r at p=0
        @test c0[2] > c0[1]  # g > r
        # Red: r > g at p=1
        @test c1[1] > c1[2]  # r > g

        # All channels in [0,1]
        for c in (c0, c1, cm)
            @test all(0f0 .<= [c...] .<= 1f0)
        end

        # Alpha always 0.9
        @test c0[4] ≈ 0.9f0
        @test c1[4] ≈ 0.9f0

        # Clamp test: out-of-range inputs should not error
        @test HL._panic_to_color(-0.5f0) == HL._panic_to_color(0f0)
        @test HL._panic_to_color(1.5f0)  == HL._panic_to_color(1f0)
    end

    @testset "_fsm_to_color" begin
        c_orca = HL._fsm_to_color(UInt8(HL.ORCA_MODE))  # blue-ish
        c_sfm  = HL._fsm_to_color(UInt8(HL.SFM_MODE))   # red-ish
        c_none = HL._fsm_to_color(0xFF % UInt8)          # gray

        @test c_orca isa NTuple{4, Float32}
        @test c_sfm  isa NTuple{4, Float32}
        @test c_none isa NTuple{4, Float32}

        # ORCA → blue: b > r
        @test c_orca[3] > c_orca[1]
        # SFM → red/orange: r is dominant
        @test c_sfm[1] >= c_sfm[3]
        # Gray: r ≈ g ≈ b
        @test abs(c_none[1] - c_none[2]) < 0.05f0
        @test abs(c_none[1] - c_none[3]) < 0.05f0
    end

    @testset "_density_to_color" begin
        c_free  = HL._density_to_color(0.5f0)  # free flow → green
        c_dense = HL._density_to_color(6.0f0)  # jam → crimson

        @test c_free  isa NTuple{4, Float32}
        @test c_dense isa NTuple{4, Float32}

        # Free flow: green dominant
        @test c_free[2] > c_free[1]
        # Dense / jam: red dominant
        @test c_dense[1] > c_dense[2]
    end

    @testset "compute_agent_colors! — OVERLAY_PANIC" begin
        ctx, _ = make_ctx(n=8, model=HL.MODEL_SFM)
        snap = HL.serialize_world_ctx(ctx)
        colors = Vector{HL.RGBAfTuple}(undef, snap.n_agents)
        HL.compute_agent_colors!(colors, snap, HL.OVERLAY_PANIC)
        @test length(colors) == snap.n_agents
        @test all(c -> all(0f0 .<= [c...] .<= 1f0), colors)
    end

    @testset "compute_agent_colors! — OVERLAY_FSM" begin
        ctx, _ = make_ctx(n=8, model=HL.MODEL_HYBRID_FSM)
        snap = HL.serialize_world_ctx(ctx)
        colors = Vector{HL.RGBAfTuple}(undef, snap.n_agents)
        HL.compute_agent_colors!(colors, snap, HL.OVERLAY_FSM)
        @test length(colors) == snap.n_agents
    end

    @testset "compute_agent_colors! — OVERLAY_DENSITY" begin
        ctx, _ = make_ctx(n=8, model=HL.MODEL_SFM)
        snap = HL.serialize_world_ctx(ctx)
        colors = Vector{HL.RGBAfTuple}(undef, snap.n_agents)
        HL.compute_agent_colors!(colors, snap, HL.OVERLAY_DENSITY)
        @test length(colors) == snap.n_agents
        @test all(c -> all(0f0 .<= [c...] .<= 1f0), colors)
    end

    @testset "compute_agent_colors! auto-resizes" begin
        ctx, _ = make_ctx(n=10, model=HL.MODEL_SFM)
        snap = HL.serialize_world_ctx(ctx)
        colors = Vector{HL.RGBAfTuple}(undef, 5)  # wrong size initially
        HL.compute_agent_colors!(colors, snap, HL.OVERLAY_PANIC)
        @test length(colors) == 10
    end
end

# ══════════════════════════════════════════════════════════════════════════════
# 4A-03 · scenario_config.jl — build_world!
# ══════════════════════════════════════════════════════════════════════════════

@testset "4A-03 scenario_config — build_world!" begin

    @testset "SFM world: agent count" begin
        ctx, cfg = make_ctx(n=25, model=HL.MODEL_SFM)
        snap = HL.serialize_world_ctx(ctx)
        @test snap.n_agents == 25
    end

    @testset "ORCA world: agent count" begin
        ctx, cfg = make_ctx(n=30, model=HL.MODEL_ORCA)
        snap = HL.serialize_world_ctx(ctx)
        @test snap.n_agents == 30
    end

    @testset "Hybrid-FSM world: agent count + FSM presence" begin
        ctx, cfg = make_ctx(n=20, model=HL.MODEL_HYBRID_FSM)
        snap = HL.serialize_world_ctx(ctx)
        @test snap.n_agents == 20
        @test HL._world_has_component(ctx.ark_world, HL.AgentFSMState{Float32})
    end

    @testset "CSM world: agent count" begin
        ctx, cfg = make_ctx(n=15, model=HL.MODEL_CSM)
        snap = HL.serialize_world_ctx(ctx)
        @test snap.n_agents == 15
    end

    @testset "RNG reproducibility" begin
        ctx1, _ = make_ctx(n=10, model=HL.MODEL_SFM, seed=99)
        ctx2, _ = make_ctx(n=10, model=HL.MODEL_SFM, seed=99)
        snap1 = HL.serialize_world_ctx(ctx1)
        snap2 = HL.serialize_world_ctx(ctx2)
        @test snap1.positions == snap2.positions
    end

    @testset "Different seeds → different layouts" begin
        ctx1, _ = make_ctx(n=20, model=HL.MODEL_SFM, seed=1)
        ctx2, _ = make_ctx(n=20, model=HL.MODEL_SFM, seed=2)
        snap1 = HL.serialize_world_ctx(ctx1)
        snap2 = HL.serialize_world_ctx(ctx2)
        @test snap1.positions != snap2.positions
    end

    @testset "Agent positions within room bounds" begin
        cfg = HL.ScenarioConfig(n_agents=30, crowd_model=HL.MODEL_SFM, rng_seed=7)
        ctx = HL.build_world!(cfg)
        snap = HL.serialize_world_ctx(ctx)
        W = Float32(cfg.room.width)
        H = Float32(cfg.room.height)
        margin = Float32(cfg.r_body) * 2f0
        for (x, y) in snap.positions
            @test x >= margin - 0.1f0
            @test x <= W - margin + 0.1f0
            @test y >= margin - 0.1f0
            @test y <= H - margin + 0.1f0
        end
    end

    @testset "sim_time starts at zero" begin
        ctx, _ = make_ctx(n=5, model=HL.MODEL_SFM)
        @test ctx.sim_time == 0.0
    end

    @testset "Custom room geometry" begin
        room = HL.RoomGeometry(
            width  = 20.0,
            height = 8.0,
            doors  = [HL.DoorSpec(wall=:east, center=4.0, width=2.0)],
        )
        cfg = HL.ScenarioConfig(n_agents=10, crowd_model=HL.MODEL_SFM, room=room, rng_seed=1)
        ctx = HL.build_world!(cfg)
        snap = HL.serialize_world_ctx(ctx)
        @test snap.n_agents == 10
        for (x, _) in snap.positions
            @test x <= Float32(20.0) + 0.5f0
        end
    end

    @testset "reset_scenario! restores agent count" begin
        ctx, cfg = make_ctx(n=15, model=HL.MODEL_SFM, seed=1)
        snap_before = HL.serialize_world_ctx(ctx)
        HL.reset_scenario!(ctx; config=cfg)
        snap_after = HL.serialize_world_ctx(ctx)
        @test snap_after.n_agents == snap_before.n_agents
        @test ctx.sim_time == 0.0
    end

    @testset "reset_scenario! with new n_agents" begin
        ctx, cfg = make_ctx(n=10, model=HL.MODEL_SFM, seed=1)
        new_cfg = HL.ScenarioConfig(n_agents=20, crowd_model=HL.MODEL_SFM, rng_seed=2)
        HL.reset_scenario!(ctx; config=new_cfg)
        snap = HL.serialize_world_ctx(ctx)
        @test snap.n_agents == 20
    end
end

# ══════════════════════════════════════════════════════════════════════════════
# 4A-04 · density.jl
# ══════════════════════════════════════════════════════════════════════════════

@testset "4A-04 density — compute_density_grid!" begin

    @testset "density_grid_size: dimensions match cell_size" begin
        W, H = 10f0, 6f0
        cs    = 0.5f0
        nx, ny = HL.density_grid_size(W, H, cs)
        @test nx == Int(ceil(W / cs))
        @test ny == Int(ceil(H / cs))
    end

    @testset "mass conservation — SFM world" begin
        ctx, cfg = make_ctx(n=50, model=HL.MODEL_SFM, seed=3)
        snap = HL.serialize_world_ctx(ctx)
        W, H = Float32(cfg.room.width), Float32(cfg.room.height)
        cs   = 0.5f0
        nx, ny = HL.density_grid_size(W, H, cs)
        grid = zeros(Float32, nx, ny)
        HL.compute_density_grid!(grid, snap.positions, cs, W, H)

        # Sum × cell_area ≈ N (allow ±2 for agents at boundary / out-of-bounds clamp)
        mass = sum(grid) * cs^2
        @test abs(mass - 50) <= 2.0
    end

    @testset "mass conservation — Hybrid-FSM world" begin
        ctx, cfg = make_ctx(n=30, model=HL.MODEL_HYBRID_FSM, seed=4)
        snap = HL.serialize_world_ctx(ctx)
        W, H = Float32(cfg.room.width), Float32(cfg.room.height)
        cs   = 0.5f0
        nx, ny = HL.density_grid_size(W, H, cs)
        grid = zeros(Float32, nx, ny)
        HL.compute_density_grid!(grid, snap.positions, cs, W, H)
        mass = sum(grid) * cs^2
        @test abs(mass - 30) <= 2.0
    end

    @testset "non-negative values" begin
        ctx, cfg = make_ctx(n=20, model=HL.MODEL_SFM, seed=5)
        snap = HL.serialize_world_ctx(ctx)
        W, H = Float32(cfg.room.width), Float32(cfg.room.height)
        cs   = 0.5f0
        nx, ny = HL.density_grid_size(W, H, cs)
        grid = zeros(Float32, nx, ny)
        HL.compute_density_grid!(grid, snap.positions, cs, W, H)
        @test all(>=(0f0), grid)
    end

    @testset "empty agents → zero grid" begin
        W, H, cs = 8f0, 6f0, 0.5f0
        nx, ny = HL.density_grid_size(W, H, cs)
        grid = ones(Float32, nx, ny)  # start non-zero to confirm overwrite
        HL.compute_density_grid!(grid, NTuple{2,Float32}[], cs, W, H)
        @test all(==(0f0), grid)
    end

    @testset "single agent in center" begin
        W, H, cs = 10f0, 10f0, 1.0f0
        nx, ny = HL.density_grid_size(W, H, cs)
        grid = zeros(Float32, nx, ny)
        center = [(5.0f0, 5.0f0)]
        HL.compute_density_grid!(grid, center, cs, W, H)
        # Grid must be non-zero near center and total mass ≈ 1
        mass = sum(grid) * cs^2
        @test abs(mass - 1.0) <= 0.5
        @test maximum(grid) > 0f0
    end

    @testset "finer cell_size → smaller grid cells" begin
        W, H = 10f0, 6f0
        nx1, ny1 = HL.density_grid_size(W, H, 1.0f0)
        nx2, ny2 = HL.density_grid_size(W, H, 0.5f0)
        @test nx2 == 2 * nx1
        @test ny2 == 2 * ny1
    end
end

# ══════════════════════════════════════════════════════════════════════════════
# Integration smoke test: step! + serialize_world_ctx
# ══════════════════════════════════════════════════════════════════════════════

@testset "Integration: step! → serialize_world_ctx" begin

    @testset "SFM: 5 steps, positions change" begin
        ctx, _ = make_ctx(n=10, model=HL.MODEL_SFM, seed=10)
        snap0 = HL.serialize_world_ctx(ctx)
        for _ in 1:5
            HL.step!(ctx.scene)
            ctx.sim_time += ctx.config.dt
        end
        snap5 = HL.serialize_world_ctx(ctx)
        @test snap5.sim_time ≈ 5 * ctx.config.dt
        # Positions must have moved
        any_moved = any(snap5.positions .!= snap0.positions)
        @test any_moved
    end

    @testset "Hybrid-FSM: 5 steps, no crash" begin
        ctx, _ = make_ctx(n=12, model=HL.MODEL_HYBRID_FSM, seed=11)
        for _ in 1:5
            HL.step!(ctx.scene)
        end
        snap = HL.serialize_world_ctx(ctx)
        @test snap.n_agents == 12
        @test all(m -> m == UInt8(HL.ORCA_MODE) || m == UInt8(HL.SFM_MODE), snap.fsm_modes)
    end
end
