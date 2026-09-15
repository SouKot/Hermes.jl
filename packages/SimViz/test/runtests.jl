"""
    runtests.jl — Sprint 4A unit tests for SimViz (headless)

These tests cover the headless layer only (viz_state, scenario_config, density).
GLMakie rendering tests are manual — a display server is not available in CI.

Run with (from workspace root ABM/):
    julia --project=. --compiled-modules=no -e "import Pkg; Pkg.test(\"SimViz\")"

NOTE (Julia 1.12 workspace): --project=packages/SimViz activates the WORKSPACE
ROOT (ABM/), not the SimViz subpackage. Pkg.test("SimViz") from the workspace
root correctly sets up the test env with SimViz's own [deps] (e.g. Observables).
"""

# ── Bootstrap: load headless layer directly so GLMakie is never imported ──────
# We include the source files inside a test-local module to avoid conflicts
# with the `using SimViz` path that would drag in GLMakie.

module HeadlessLayer
    using Ark: World, Query
    using Observables: Observable
    using StaticArrays: SVector
    using SimCore: SimWorld, SimStats, CrowdAgent, add_zone!, new_entity_id!,
                   StatsPipeline, WARMUP_NONE,
                   record_arrival!, record_departure!, record_queue_length!,
                   record_utilization!, record_idle!, sim_summary
    using SimCrowd:
        Position, Velocity, Force, Goal, WallSegment,
        AgentGeometry, MotionParams, SFMParams, ORCAParams,
        HybridFSMParams, AgentFSMState, CSMParams,
        AgentModel, SFMModel, ORCAModel, HybridModel,
        SimConfig, SimScene, JacobiCorrection, XPBDCorrection,
        VelocityImpulseParams, CPUNeighborSearch,
        ORCA_MODE, SFM_MODE, step!,
        apply_boundary!, AbsorbingBoundary, BoundaryCondition
    using Random: MersenneTwister
    using LinearAlgebra: norm

    include(joinpath(@__DIR__, "..", "src", "viz_state.jl"))
    include(joinpath(@__DIR__, "..", "src", "scenario_config.jl"))
    include(joinpath(@__DIR__, "..", "src", "density.jl"))
end

using SimCore
using SimDES
using Test
using Random: AbstractRNG, MersenneTwister

# ── Test helpers ──────────────────────────────────────────────────────────────

# Make short aliases so test bodies are clean
const HL   = HeadlessLayer
const Pos2 = NTuple{2, Float32}

# Build a minimal ScenarioContext for tests without spawning GLMakie
function make_ctx(; n=20, model=HL.MODEL_SFM, seed=42)
    cfg = HL.ScenarioConfig(n_agents=n, crowd_model=model, rng_seed=seed)
    return HL.build_world!(cfg), cfg
end

function _entity_sort_key(entity)
    T = typeof(entity)
    if hasfield(T, :_id)
        eid = Int(getfield(entity, :_id))
        egen = hasfield(T, :_gen) ? Int(getfield(entity, :_gen)) : 0
        return (eid, egen)
    end
    return (Int(hash(entity)), 0)
end

function _sorted_scene_entities(scene::HL.SimScene{F}) where {F}
    entities = Any[]
    for (ents, _) in HL.Query(scene.world, (HL.Position{F},))
        append!(entities, ents)
    end
    sort!(entities; by=_entity_sort_key)
    return entities
end

function _make_task24f_ctx(; dt=0.05, seed=24)
    room = HL.RoomGeometry(
        width=4.0,
        height=3.0,
        doors=[HL.DoorSpec(wall=:east, center=0.5, width=1.0)],
    )
    cfg = HL.ScenarioConfig(
        n_agents=2,
        crowd_model=HL.MODEL_ORCA,
        flux_boundary=false,
        room=room,
        dt=dt,
        rng_seed=seed,
    )
    ctx = HL.build_world!(cfg)

    F = Float32
    slot_targets = Dict(
        _sorted_scene_entities(ctx.scene)[1] => (
            pos = HL.SVector(F(0.0), F(-0.05)),
            goal = HL.SVector(F(0.0), F(-0.05)),
        ),
        _sorted_scene_entities(ctx.scene)[2] => (
            pos = HL.SVector(F(0.0), F(0.05)),
            goal = HL.SVector(F(0.0), F(0.05)),
        ),
    )

    for (entities, pos_col, vel_col, goal_col, motion_col) in HL.Query(
        ctx.ark_world,
        (HL.Position{F}, HL.Velocity{F}, HL.Goal{F}, HL.MotionParams{F}),
    )
        for i in eachindex(entities)
            target = get(slot_targets, entities[i], nothing)
            isnothing(target) && continue
            pos_col[i] = HL.Position(target.pos)
            vel_col[i] = HL.Velocity(zero(HL.SVector{2,F}))
            goal_col[i] = HL.Goal(target.goal)
            mp = motion_col[i]
            motion_col[i] = HL.MotionParams(mp.mass, zero(F), mp.τ, zero(F))
        end
    end

    return ctx
end

function _run_des_until!(world::SimWorld, fel::FutureEventList,
                         configs::Dict{Int,ZoneConfig},
                         clock::SimClock, rng::AbstractRNG,
                         t_end::Float64;
                         pipeline::Union{Nothing,StatsPipeline}=nothing,
                         sync_bufs::Union{Nothing,HybridSyncBuffers}=nothing)
    while peek_time(fel) <= t_end
        result = safe_dequeue!(fel)
        result === nothing && break
        cev, t = result
        throttle!(clock, t)
        world.time = t
        dispatch!(world, fel, configs, rng, cev.inner, t; pipeline=pipeline, sync_bufs=sync_bufs)
    end
    return world.stats
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

        # stats sub-NT must have these 5 legacy + 6 Sprint 4I pipeline fields
        s = snap.stats
        @test haskey(s, :total_events)
        @test haskey(s, :total_arrivals)
        @test haskey(s, :total_departures)
        @test haskey(s, :busy_time)
        @test haskey(s, :elapsed_sim_time)
        # Sprint 4I: pipeline fields (NaN sentinel when pipeline not active)
        @test haskey(s, :W)
        @test haskey(s, :Wq)
        @test haskey(s, :L)
        @test haskey(s, :Lq)
        @test haskey(s, :rho)
        @test haskey(s, :throughput)
        # Non-DES world: pipeline fields should be NaN
        @test isnan(s.W)
        @test isnan(s.Wq)
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
        # _random_positions uses margin = r_body * 1.1 (not 2.0).
        # Use the same formula here so the test checks actual spawn bounds.
        margin = Float32(cfg.r_body) * 1.1f0
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

    @testset "evac_alarm dispatch updates panic + motion" begin
        ev = HL.ScheduledEvent(
            time=0.0,
            type=:evac_alarm,
            params=(v_panic=1.8, panic_level=0.8),
        )
        cfg = HL.ScenarioConfig(
            n_agents=12,
            crowd_model=HL.MODEL_ORCA,
            events=[ev],
            rng_seed=11,
        )
        ctx = HL.build_world!(cfg)

        # Fire at t=0.0
        HL._dispatch_events!(ctx, 0.0)
        snap = HL.serialize_world_ctx(ctx)

        @test length(snap.panic_levels) == snap.n_agents
        @test all(p -> isapprox(p, 0.8f0; atol=1f-6), snap.panic_levels)
        @test snap.stats.total_events == 1

        # MotionParams.v_pref should be patched to panic speed for all agents
        all_panic_speed = true
        for (_, mp_col) in HL.Query(ctx.ark_world, (HL.MotionParams{Float32},))
            for mp in mp_col
                if !isapprox(mp.v_pref, 1.8f0; atol=1f-6)
                    all_panic_speed = false
                    break
                end
            end
        end
        @test all_panic_speed

        # One-shot event: re-dispatch at later t must not increment event count
        HL._dispatch_events!(ctx, 10.0)
        snap2 = HL.serialize_world_ctx(ctx)
        @test snap2.stats.total_events == 1

        # Reset clears panic overlay state
        HL.reset_scenario!(ctx; config=cfg)
        snap3 = HL.serialize_world_ctx(ctx)
        @test all(==(0.0f0), snap3.panic_levels)
    end

    @testset "MM1 + evac_alarm preserve total_events visibility" begin
        mm1_ev = HL.ScheduledEvent(
            time=0.0,
            type=:start_mm1_queue,
            params=(lambda=0.7, mu=1.0, warmup_mode=:none, warmup_n=0),
        )
        alarm_ev = HL.ScheduledEvent(
            time=0.0,
            type=:evac_alarm,
            params=(v_panic=1.8, panic_level=0.8),
        )
        cfg = HL.ScenarioConfig(
            n_agents=8,
            crowd_model=HL.MODEL_ORCA,
            events=[mm1_ev, alarm_ev],
            rng_seed=12,
        )
        ctx = HL.build_world!(cfg)

        # At t=0 both events fire: MM1 starts + one alarm event
        HL._dispatch_events!(ctx, 0.0)
        snap0 = HL.serialize_world_ctx(ctx)
        @test snap0.stats.total_events == 1
        @test all(p -> isapprox(p, 0.8f0; atol=1f-6), snap0.panic_levels)

        # Advance MM1 DES and verify alarm event is still included in total_events
        HL._dispatch_events!(ctx, 20.0)
        snap1 = HL.serialize_world_ctx(ctx)
        psm = HL.sim_summary(ctx._mm1_pipeline)
        @test snap1.stats.total_arrivals == psm.total_arrivals
        @test snap1.stats.total_departures == psm.total_departures
        @test snap1.stats.total_events == psm.total_events + 1
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

# ══════════════════════════════════════════════════════════════════════════════
# Integration: flux_boundary pipeline
#
# These tests guard the exact integration gap that allowed a real bug to
# ship: flux_boundary=true was stored in ScenarioConfig but never wired
# through to build_world! or the step loop.  Agents accumulated at the
# door instead of being removed, so N agents never decreased.
#
# Each test exercises one level of the chain:
#   ScenarioConfig(flux_boundary=true)
#       → build_world!()          # must attach AbsorbingBoundary
#       → step!() × N + apply_boundary!()  # must remove arrivals
#       → n_agents < n_initial    # observable outcome
# ══════════════════════════════════════════════════════════════════════════════

@testset "Integration: flux_boundary pipeline" begin

    @testset "flux_boundary=false → boundaries is empty" begin
        cfg = HL.ScenarioConfig(n_agents=10, crowd_model=HL.MODEL_SFM,
                                flux_boundary=false, rng_seed=1)
        ctx = HL.build_world!(cfg)
        @test isempty(ctx.boundaries)
    end

    @testset "flux_boundary=true → AbsorbingBoundary attached" begin
        cfg = HL.ScenarioConfig(n_agents=10, crowd_model=HL.MODEL_SFM,
                                flux_boundary=true, rng_seed=1)
        ctx = HL.build_world!(cfg)
        @test length(ctx.boundaries) == 1
        @test ctx.boundaries[1] isa HL.AbsorbingBoundary{Float32}
    end

    @testset "flux_boundary=true wired for all crowd models" begin
        for model in (HL.MODEL_SFM, HL.MODEL_ORCA, HL.MODEL_HYBRID_FSM, HL.MODEL_CSM)
            @testset "$model" begin
                cfg = HL.ScenarioConfig(n_agents=5, crowd_model=model,
                                        flux_boundary=true, rng_seed=2)
                ctx = HL.build_world!(cfg)
                @test length(ctx.boundaries) == 1
            end
        end
    end

    @testset "reset_scenario! preserves boundaries" begin
        cfg = HL.ScenarioConfig(n_agents=10, crowd_model=HL.MODEL_SFM,
                                flux_boundary=true, rng_seed=3)
        ctx = HL.build_world!(cfg)
        @test length(ctx.boundaries) == 1
        HL.reset_scenario!(ctx)
        @test length(ctx.boundaries) == 1  # must survive reset
        @test ctx.boundaries[1] isa HL.AbsorbingBoundary{Float32}
    end

    @testset "Evacuation: n_agents decreases with apply_boundary! (SFM)" begin
        # Small room, wide door, few agents — guarantees some evacuate in ~600 steps
        # Room: 6m x 4m, door: east wall width=3m (half height), arrival_radius=1.5m
        # At v_pref=1.34m/s, dt=0.05s → ~90 steps to cross 6m without crowd effects.
        # 600 steps (30 s sim-time) is conservative even with congestion.
        room = HL.RoomGeometry(
            width  = 6.0,
            height = 4.0,
            doors  = [HL.DoorSpec(wall=:east, center=0.5, width=3.0)],
        )
        cfg = HL.ScenarioConfig(
            n_agents      = 10,
            crowd_model   = HL.MODEL_SFM,
            flux_boundary = true,
            room          = room,
            rng_seed      = 7,
        )
        ctx = HL.build_world!(cfg)
        n_initial = HL.serialize_world_ctx(ctx).n_agents
        @test n_initial == 10
        @test !isempty(ctx.boundaries)  # boundary must be wired

        for _ in 1:600
            HL.step!(ctx.scene)
            ctx.sim_time += ctx.config.dt
            for bc in ctx.boundaries
                HL.apply_boundary!(ctx.ark_world, bc)
            end
        end

        n_after = HL.serialize_world_ctx(ctx).n_agents
        @show n_after n_initial
        @test n_after < n_initial
    end

    @testset "Evacuation: n_agents decreases with apply_boundary! (Hybrid-FSM)" begin
        room = HL.RoomGeometry(
            width  = 6.0,
            height = 4.0,
            doors  = [HL.DoorSpec(wall=:east, center=0.5, width=3.0)],
        )
        cfg = HL.ScenarioConfig(
            n_agents      = 10,
            crowd_model   = HL.MODEL_HYBRID_FSM,
            flux_boundary = true,
            room          = room,
            rng_seed      = 8,
        )
        ctx = HL.build_world!(cfg)
        n_initial = HL.serialize_world_ctx(ctx).n_agents

        for _ in 1:600
            HL.step!(ctx.scene)
            ctx.sim_time += ctx.config.dt
            for bc in ctx.boundaries
                HL.apply_boundary!(ctx.ark_world, bc)
            end
        end

        n_after = HL.serialize_world_ctx(ctx).n_agents
        @show n_after n_initial
        @test n_after < n_initial
    end

end

# ══════════════════════════════════════════════════════════════════════════════
# Integration: DES + ORCA statistical consistency
# ══════════════════════════════════════════════════════════════════════════════

@testset "Integration: DES + ORCA operational-law checks" begin
    λ = 0.6
    μ = 1.0
    alarm_t = 20.0

    mm1_ev = HL.ScheduledEvent(
        time=0.0,
        type=:start_mm1_queue,
        params=(lambda=λ, mu=μ, warmup_mode=:none, warmup_n=0),
    )
    alarm_ev = HL.ScheduledEvent(
        time=alarm_t,
        type=:evac_alarm,
        params=(v_panic=1.8, panic_level=0.8),
    )

    cfg = HL.ScenarioConfig(
        n_agents=40,
        crowd_model=HL.MODEL_ORCA,
        events=[mm1_ev, alarm_ev],
        flux_boundary=false,
        dt=0.05,
        rng_seed=2026,
    )
    ctx = HL.build_world!(cfg)

    # Pre-alarm window — MM1 active, alarm off
    n_pre = Int(round(10.0 / ctx.config.dt))
    for _ in 1:n_pre
        HL.step!(ctx.scene)
        ctx.sim_time += ctx.config.dt
        HL._dispatch_events!(ctx, ctx.sim_time)
    end
    snap_pre = HL.serialize_world_ctx(ctx)
    @test maximum(snap_pre.panic_levels) == 0.0f0
    @test snap_pre.stats.total_arrivals > 0

    # Post-alarm horizon for queue metrics
    n_post = Int(round(90.0 / ctx.config.dt))
    for _ in 1:n_post
        HL.step!(ctx.scene)
        ctx.sim_time += ctx.config.dt
        HL._dispatch_events!(ctx, ctx.sim_time)
    end
    snap = HL.serialize_world_ctx(ctx)
    s = snap.stats

    # Alarm one-shot + event accounting
    @test all(p -> isapprox(p, 0.8f0; atol=1f-6), snap.panic_levels)
    @test s.total_events == s.total_arrivals + s.total_departures + 1

    # Pipeline fields active
    @test !isnan(s.W)
    @test !isnan(s.Wq)
    @test !isnan(s.L)
    @test !isnan(s.Lq)
    @test !isnan(s.rho)
    @test !isnan(s.throughput)

    # Invariants
    @test s.total_arrivals >= s.total_departures >= 0
    @test s.W >= s.Wq >= 0
    @test s.L >= s.Lq >= 0
    @test 0.0 <= s.rho <= 1.0
    @test s.throughput > 0

    # Operational laws (Little's law consistency)
    λ_eff = s.throughput
    @test isapprox(s.L,  λ_eff * s.W;  atol=max(0.5, 0.35 * s.L))
    @test isapprox(s.Lq, λ_eff * s.Wq; atol=max(0.5, 0.45 * s.Lq + 0.2))

    # M/M/1 steady-state sanity (finite-horizon loose tolerances)
    ρ_th  = λ / μ
    W_th  = 1 / (μ - λ)
    Wq_th = λ / (μ * (μ - λ))
    L_th  = λ / (μ - λ)
    Lq_th = λ^2 / (μ * (μ - λ))

    @test isapprox(s.rho,  ρ_th;  atol=0.25)
    @test isapprox(s.W,    W_th;  atol=1.5)
    @test isapprox(s.Wq,   Wq_th; atol=1.5)
    @test isapprox(s.L,    L_th;  atol=1.0)
    @test isapprox(s.Lq,   Lq_th; atol=1.0)
    @test isapprox(s.throughput, λ; atol=0.25)
end

@testset "Task 24F — end-to-end hybrid ORCA + DES" begin
    hybrid_cfg = HybridSyncConfig(dt=0.05, Δt_sync=0.10, max_agents=2,
                                  max_pending_departures=16, strict_invariants=true)
    service_zones = [ServiceZone(-0.2, 0.2, -0.5, 0.5, 1)]

    @testset "Closed-world mass conservation over repeated sync cycles" begin
        ctx = _make_task24f_ctx(dt=hybrid_cfg.dt)
        bufs = HybridSyncBuffers(hybrid_cfg)
        st = HybridSyncState()

        world = SimWorld()
        fel = FutureEventList()
        des_cfg = ZoneConfig(id=1, num_servers=1,
                             service_dist=deterministic_service(0.15),
                             arrival_rate=0.0, routing=ExitSystem())
        configs = Dict(1 => des_cfg)
        build_world!(world, des_cfg)

        pipe = StatsPipeline(warmup=WARMUP_FIXED, warmup_n=20)
        clock = SimClock(Inf)
        rng = MersenneTwister(2026)
        sim_time = 0.0
        steps_per_sync = Int(round(hybrid_cfg.Δt_sync / hybrid_cfg.dt))

        for _ in 1:120
            for _ in 1:steps_per_sync
                HL.step!(ctx.scene; sync_bufs=bufs, service_zones=service_zones)
                ctx.sim_time += ctx.config.dt
                sim_time = ctx.sim_time
            end

            sync_step!(bufs, st, sim_time;
                       cfg=hybrid_cfg,
                       on_arrival! = arrival_event -> schedule!(fel, arrival_event, arrival_event.time))

            _run_des_until!(world, fel, configs, clock, rng, sim_time;
                            pipeline=pipe, sync_bufs=bufs)

            free_abm = count(!, bufs.d_agent_in_service)
            des_active = length(world.des_agents)
            pending_release = length(bufs.pending_departures)
            @test free_abm + des_active + pending_release == 2
        end

        _run_des_until!(world, fel, configs, clock, rng, sim_time + 10.0;
                pipeline=pipe, sync_bufs=bufs)
        sync_step!(bufs, st, sim_time + 10.0;
                   cfg=hybrid_cfg,
                   on_arrival! = arrival_event -> schedule!(fel, arrival_event, arrival_event.time))

        @test count(!, bufs.d_agent_in_service) == 2
        @test isempty(bufs.pending_departures)
        @test isempty(world.des_agents)
        @test st.total_arrivals_injected == world.stats.total_arrivals
        @test st.total_departures_applied == world.stats.total_departures
        @test st.total_arrivals_injected == st.total_departures_applied

        sm = sim_summary(pipe)
        little_ok, little_err = check_littles_law(sm; tol=0.20)
        @test sm.total_arrivals > 20
        @test sm.total_departures > 20
        @test sm.warmup_complete == true
        @test sm.L > 0
        @test sm.W > 0
        @test little_ok
        @test little_err <= 0.20
        @test isapprox(sm.Lq, sm.throughput * sm.Wq; atol=max(0.2, 0.25 * sm.Lq + 0.1))
    end
end

