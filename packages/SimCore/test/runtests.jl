using SimCore
using Test
using StaticArrays: SVector
using Random

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 validation — SimCore test suite
# Covers: 1B-01 through 1B-06
# Design ref: §7.8 (SimClock), §7.11–7.12 (events, cancel)
# Validation test: DES-S-08 (event cancellation), DES-S-09 (clock fidelity)
# ─────────────────────────────────────────────────────────────────────────────

@testset "SimCore" begin

    # ── 1B-01: Package quality (Aqua) ────────────────────────────────────────
    @testset "Aqua quality checks" begin
        using Aqua
        Aqua.test_all(SimCore;
            ambiguities      = false,   # false positives from DataStructures
            unbound_args     = true,
            undefined_exports= true,
            project_extras   = true,
            stale_deps       = true,
            deps_compat      = (check_extras = false,),  # Test stdlib has no compat
            persistent_tasks = false,   # false positive: GLMakie async workers in precompile
        )
    end

    # ── Events ───────────────────────────────────────────────────────────────
    @testset "Event types" begin

        @testset "Concrete event construction" begin
            e1 = EntityArrival(UInt64(1), 2, 1.0)
            @test e1.entity_id == UInt64(1)
            @test e1.zone_id   == 2
            @test e1.time      == 1.0
            @test e1 isa SimEvent

            e2 = ProcessComplete(UInt64(1), 1, 5.0)
            @test e2.entity_id  == UInt64(1)
            @test e2.station_id == 1
            @test e2.time       == 5.0

            e3 = ResourceFailure(3, 0.5f0, 10.0)
            @test e3.resource_id == 3
            @test e3.severity    == 0.5f0

            e4 = ScheduledChange{:EvacAlarm}(1, 60.0)
            @test e4.zone_id == 1
            @test e4.time    == 60.0
            @test e4 isa ScheduledChange{:EvacAlarm}

            e5 = TransferOut(UInt64(2), 3, 7.5)
            @test e5.dest_zone == 3

            e6 = NullEvent()
            @test e6 isa SimEvent
        end

        @testset "ScheduledChange type parameter dispatch" begin
            # Ensure different symbols create distinguishable types
            ea = ScheduledChange{:EvacAlarm}(1, 60.0)
            er = ScheduledChange{:Repair}(1, 120.0)
            @test typeof(ea) != typeof(er)
            @test ea isa ScheduledChange{:EvacAlarm}
            @test er isa ScheduledChange{:Repair}
        end

        @testset "Event ID monotonically increases" begin
            id1 = next_event_id!()
            id2 = next_event_id!()
            id3 = next_event_id!()
            @test id2 > id1
            @test id3 > id2
        end

        @testset "CancellableEvent construction" begin
            ev  = EntityArrival(UInt64(1), 1, 1.0)
            cev = CancellableEvent(ev, 1.0)
            @test cev.inner === ev
            @test cev.time  == 1.0
            @test cev.id    > UInt64(0)
        end

        # 1B-05 / DES-S-08: Event cancellation
        @testset "Event cancellation (DES-S-08)" begin
            ev  = EntityArrival(UInt64(42), 1, 5.0)
            cev = CancellableEvent(ev, 5.0)
            id  = cev.id

            @test !is_cancelled(id)
            cancel!(id)
            @test is_cancelled(id)

            # Consuming removes from set
            SimCore._consume_cancelled!(id)
            @test !is_cancelled(id)
        end
    end

    # ── SimClock ──────────────────────────────────────────────────────────────
    @testset "SimClock" begin

        @testset "Construction" begin
            c1 = SimClock()
            @test sim_time(c1)  == 0.0
            @test c1.speed_factor == Inf
            @test !is_paused(c1)

            c2 = SimClock(1.0)
            @test c2.speed_factor == 1.0

            c3 = SimClock(0.5)
            @test c3.speed_factor == 0.5
        end

        # 1B-02: Fastest mode advances without sleeping
        @testset "Fastest mode (speed_factor=Inf) — no sleep (1B-02)" begin
            clock = SimClock(Inf)
            t_start = time()
            throttle!(clock, 100.0)   # advance 100 simulated seconds instantly
            elapsed = time() - t_start
            @test elapsed < 0.05          # should complete in < 50ms
            @test sim_time(clock) == 100.0
        end

        # 1B-03: Pause blocks, unpause resumes
        @testset "Pause and unpause (1B-03)" begin
            clock = SimClock(Inf)
            pause!(clock)
            @test is_paused(clock)

            # Unpause in background after 50ms
            @async begin
                sleep(0.05)
                unpause!(clock)
            end

            t_start = time()
            throttle!(clock, 200.0)      # should block ~50ms then proceed
            elapsed = time() - t_start
            @test elapsed >= 0.04        # was blocked
            @test !is_paused(clock)
            @test sim_time(clock) == 200.0
        end

        @testset "set_speed! validation" begin
            clock = SimClock()
            set_speed!(clock, 2.0)
            @test clock.speed_factor == 2.0

            set_speed!(clock, 0.0)    # 0.0 should pause
            @test is_paused(clock)
            unpause!(clock)

            @test_throws ArgumentError set_speed!(clock, -1.0)
        end

        @testset "step_once! advances one event then re-pauses" begin
            clock = SimClock(Inf)
            pause!(clock)
            @test is_paused(clock)

            step_once!(clock)                # sets step flag, unpauses
            throttle!(clock, 1.0)            # processes one event
            # After throttle!, clock should be paused again
            @test is_paused(clock)
            @test sim_time(clock) == 1.0
        end

        @testset "reset! clears state" begin
            clock = SimClock(Inf)
            throttle!(clock, 50.0)
            pause!(clock)
            reset!(clock)
            @test sim_time(clock) == 0.0
            @test !is_paused(clock)
        end

        # DES-S-09: Real-time speed fidelity — coarse check
        @testset "Real-time throttle fidelity (DES-S-09 coarse)" begin
            clock = SimClock(1.0)   # 1× real-time
            t_start = time()
            # Simulate advancing 0.1 simulated seconds — should take ~0.1 wall seconds
            throttle!(clock, 0.1)
            elapsed = time() - t_start
            # Allow generous tolerance (CI environments vary)
            @test elapsed >= 0.05
            @test elapsed <= 0.5
        end
    end

    # ── ECS Components ────────────────────────────────────────────────────────
    @testset "ECS components" begin

        @testset "DESAgent" begin
            a = DESAgent(0.0, 1)
            @test a.arrival_time       == 0.0
            @test a.current_zone       == 1
            @test a.priority           == 0
            @test a.service_start_time == Inf    # not yet served

            a2 = DESAgent(1.5, 2, 5)
            @test a2.priority           == 5
            @test a2.service_start_time == Inf

            # Explicit service_start_time (set when service begins)
            a3 = DESAgent(1.5, 2, 0, 2.0)
            @test a3.service_start_time == 2.0
        end

        @testset "CrowdAgent defaults" begin
            pos  = SVector{2,Float32}(1.0f0, 2.0f0)
            goal = SVector{2,Float32}(10.0f0, 10.0f0)
            ag   = CrowdAgent(pos, goal)
            @test ag.position      == pos
            @test ag.goal          == goal
            @test ag.desired_speed ≈ 1.34f0
            @test ag.panic_level   == 0.0f0
            @test ag.radius        ≈ 0.25f0
            @test ag.mass          ≈ 80.0f0
            @test ag.velocity      == zero(SVector{2,Float32})
        end

        @testset "FluidParticle defaults" begin
            pos = SVector{2,Float32}(5.0f0, 3.0f0)
            fp  = FluidParticle(pos)
            @test fp.position == pos
            @test fp.density  ≈ 1000.0f0
            @test fp.mass     ≈ 1.0f0
        end

        @testset "CrowdObstacle geometry helpers" begin
            obs = CrowdObstacle(0f0, 0f0, 4f0, 2f0)
            @test width(obs)  ≈ 4f0
            @test height(obs) ≈ 2f0
            c = center(obs)
            @test c[1] ≈ 2f0
            @test c[2] ≈ 1f0
        end
    end

    # ── SimWorld ──────────────────────────────────────────────────────────────
    @testset "SimWorld" begin

        @testset "Construction" begin
            w = SimWorld()
            c = entity_count(w)
            @test c.des_agents      == 0
            @test c.crowd_agents    == 0
            @test c.fluid_particles == 0
            @test c.obstacles       == 0
            @test w.time            == 0.0
        end

        @testset "Entity ID is monotonically increasing" begin
            w = SimWorld()
            id1 = new_entity_id!(w)
            id2 = new_entity_id!(w)
            @test id2 > id1
        end

        @testset "Add and retrieve crowd agent" begin
            w    = SimWorld()
            pos  = SVector{2,Float32}(1f0, 2f0)
            goal = SVector{2,Float32}(5f0, 5f0)
            ag   = CrowdAgent(pos, goal)
            id   = add_crowd_agent!(w, ag)
            @test entity_count(w).crowd_agents == 1
            retrieved = get_crowd_agent(w, id)
            @test retrieved !== nothing
            @test retrieved.position == pos
        end

        @testset "Update crowd agent" begin
            w    = SimWorld()
            pos  = SVector{2,Float32}(1f0, 2f0)
            goal = SVector{2,Float32}(5f0, 5f0)
            ag   = CrowdAgent(pos, goal)
            id   = add_crowd_agent!(w, ag)

            new_pos = SVector{2,Float32}(2f0, 3f0)
            new_ag  = CrowdAgent(new_pos, goal)
            update_crowd_agent!(w, id, new_ag)
            @test get_crowd_agent(w, id).position == new_pos
        end

        @testset "Remove entity" begin
            w  = SimWorld()
            id = add_crowd_agent!(w, CrowdAgent(SVector{2,Float32}(0f0,0f0),
                                                SVector{2,Float32}(1f0,1f0)))
            @test entity_count(w).crowd_agents == 1
            remove_entity!(w, id)
            @test entity_count(w).crowd_agents == 0
            @test get_crowd_agent(w, id) === nothing
        end

        @testset "Zone management" begin
            w = SimWorld()
            add_zone!(w, 1; capacity=10, num_servers=2)
            z = get_zone(w, 1)
            @test z.capacity     == 10
            @test z.num_servers  == 2
            @test z.queue_length == 0
            @test z.busy_servers == 0
            @test isempty(z.queue)     # FIFO queue starts empty
        end
    end

    # ── SimStats ──────────────────────────────────────────────────────────────
    @testset "SimStats" begin

        @testset "Empty stats return NaN" begin
            s = SimStats()
            @test isnan(mean_queue_length(s))
            @test isnan(mean_wait_time(s))
            @test isnan(utilization(s))
        end

        @testset "Recording and derived metrics" begin
            s = SimStats()
            s.warmup_complete = true

            record_arrival!(s)
            record_departure!(s, 0.5, 1.0)   # wait=0.5, sojourn=1.0
            record_queue_length!(s, 1, 1.0)   # L=1 for dt=1.0 sec
            record_utilization!(s, 0.8)       # busy for 0.8 sec

            @test s.total_arrivals  == 1
            @test s.total_departures == 1
            @test mean_wait_time(s)   ≈ 0.5
            @test mean_sojourn_time(s) ≈ 1.0
            @test mean_queue_length(s) ≈ 1.0
            @test utilization(s)       ≈ 0.8
        end

        @testset "Blocking probability" begin
            s = SimStats()
            s.warmup_complete = true
            record_arrival!(s)    # arrival 1
            record_arrival!(s)    # arrival 2
            record_blocked!(s)    # arrival 3 (attempt) — blocked, total_arrivals becomes 3
            @test s.total_arrivals == 3
            @test s.blocked_count  == 1
            @test blocking_probability(s) ≈ 1/3 atol=1e-10
        end

        @testset "reset_stats! zeroes everything" begin
            s = SimStats()
            s.warmup_complete = true
            record_arrival!(s)
            record_departure!(s, 1.0, 2.0)
            reset_stats!(s)
            @test s.total_arrivals == 0
            @test s.warmup_complete == false
            @test isnan(mean_wait_time(s))
        end

        @testset "sim_summary returns NamedTuple" begin
            s = SimStats()
            s.warmup_complete = true
            record_arrival!(s)
            record_departure!(s, 0.5, 1.0)
            record_queue_length!(s, 2, 0.5)
            record_utilization!(s, 0.4)

            sm = sim_summary(s)
            @test haskey(sm, :L)
            @test haskey(sm, :Wq)
            @test haskey(sm, :W)
            @test haskey(sm, :utilization)
            @test haskey(sm, :total_arrivals)
            @test sm.total_arrivals == 1
        end
    end

end  # @testset "SimCore"

# ─────────────────────────────────────────────────────────────────────────────
# Sprint 4I — StatsPipeline test suite
# Tasks 1-16: collectors, warmup, pipeline, analysis
# ─────────────────────────────────────────────────────────────────────────────

@testset "Sprint 4I — StatsPipeline" begin

    # ── Task 17: WelchDetector (moved to SimCore) ─────────────────────────────
    @testset "WelchDetector" begin
        wd = WelchDetector(window_size=5, threshold=0.05)
        @test !warmup_complete(wd)

        # Feed steady observations — should detect convergence after 3+ windows
        for _ in 1:14
            update!(wd, 3.0)   # 14 obs → 2 complete windows of 5 + 4 buffered
        end
        update!(wd, 3.0)   # 15th → 3rd window complete → CV ≈ 0 < 0.05
        @test warmup_complete(wd)

        # Once complete, update! is a no-op
        update!(wd, 999.0)
        @test warmup_complete(wd)

        # Zero queue → immediate steady state
        wd2 = WelchDetector(window_size=3, threshold=0.05)
        for _ in 1:9; update!(wd2, 0.0); end
        @test warmup_complete(wd2)
    end

    # ── Task 7: WarmupPolicy ─────────────────────────────────────────────────
    @testset "WarmupPolicy" begin

        @testset "WARMUP_NONE" begin
            p = WarmupPolicy(mode=WARMUP_NONE)
            @test p.complete == true
            @test tick_warmup!(p, 5.0, 0) == true
        end

        @testset "WARMUP_IMMEDIATE" begin
            p = WarmupPolicy(mode=WARMUP_IMMEDIATE)
            @test p.complete == true
        end

        @testset "WARMUP_FIXED" begin
            p = WarmupPolicy(mode=WARMUP_FIXED, warmup_n=3)
            @test tick_warmup!(p, 0.0, 1) == false
            @test tick_warmup!(p, 0.0, 2) == false
            @test tick_warmup!(p, 0.0, 3) == true
            @test tick_warmup!(p, 0.0, 4) == true   # stays true
            @test p.complete == true
        end

        @testset "WARMUP_AUTO" begin
            p = WarmupPolicy(mode=WARMUP_AUTO, welch_window_size=5, welch_threshold=0.05)
            @test p.complete == false
            @test p._welch !== nothing
            # Feed enough to trigger convergence
            for i in 1:15
                tick_warmup!(p, 3.0, i)
            end
            @test p.complete == true
        end
    end

    # ── Tasks 1-6: Collectors ────────────────────────────────────────────────
    @testset "MeanCollector" begin
        c = MeanCollector()
        @test isnan(value(c))

        fit!(c, 3.0); fit!(c, 5.0); fit!(c, 7.0)
        @test value(c) ≈ 5.0

        # merge! (exact parallel mean formula)
        a = MeanCollector(); fit!(a, 1.0); fit!(a, 2.0)   # mean=1.5, n=2
        b = MeanCollector(); fit!(b, 3.0); fit!(b, 4.0); fit!(b, 5.0)  # mean=4, n=3
        merge!(a, b)
        @test value(a) ≈ (1+2+3+4+5)/5   # = 3.0
        @test a.n == 5

        # merge! into empty dst
        e = MeanCollector()
        f = MeanCollector(); fit!(f, 7.0)
        merge!(e, f)
        @test value(e) ≈ 7.0

        # merge! with empty src is no-op
        g = MeanCollector(); fit!(g, 2.0)
        merge!(g, MeanCollector())
        @test value(g) ≈ 2.0

        # reset!
        reset!(a)
        @test isnan(value(a)) && a.n == 0
    end

    @testset "WeightedMeanCollector" begin
        c = WeightedMeanCollector()
        @test isnan(value(c))

        fit!(c, 3.0, 2.0); fit!(c, 7.0, 2.0)
        @test value(c) ≈ 5.0

        # merge!
        a = WeightedMeanCollector(); fit!(a, 2.0, 1.0)   # L*dt = 2
        b = WeightedMeanCollector(); fit!(b, 4.0, 1.0)   # L*dt = 4
        merge!(a, b)
        @test value(a) ≈ 3.0  # (2+4)/(1+1)

        # zero-weight guard
        z = WeightedMeanCollector()
        @test isnan(value(z))
        reset!(z)
        @test isnan(value(z))
    end

    @testset "P2QuantileCollector" begin
        c = P2QuantileCollector(0.5)   # median
        @test isnan(value(c))

        # Feed 10 samples; P² should estimate ~3.0 (median of 1..5 uniform)
        for x in [2.0,4.0,1.0,3.0,5.0,2.0,4.0,1.0,3.0,5.0]
            fit!(c, x)
        end
        @test 2.0 <= value(c) <= 4.0   # P² converges loosely

        # merge! should throw — P² algorithm cannot merge streams
        c2 = P2QuantileCollector(0.5)
        @test_throws ArgumentError merge!(c, c2)

        # reset! clears back to uninitialized
        reset!(c)
        @test isnan(value(c))
    end

    @testset "ExtremaCollector" begin
        c = ExtremaCollector()
        v = value(c)
        @test isnan(v.min) && isnan(v.max)

        fit!(c, 3.0); fit!(c, 1.0); fit!(c, 7.0)
        v = value(c)
        @test v.min == 1.0 && v.max == 7.0

        # merge!
        a = ExtremaCollector(); fit!(a, 2.0)
        b = ExtremaCollector(); fit!(b, 5.0)
        merge!(a, b)
        @test value(a).min == 2.0 && value(a).max == 5.0

        # merge into empty
        e = ExtremaCollector()
        f = ExtremaCollector(); fit!(f, 9.0)
        merge!(e, f)
        @test value(e).min == 9.0 && value(e).max == 9.0

        reset!(c)
        @test isnan(value(c).min)
    end

    @testset "CounterCollector" begin
        c = CounterCollector()
        @test value(c) == 0

        fit!(c, 1); fit!(c, 3)
        @test value(c) == 4

        # merge!
        a = CounterCollector(); fit!(a, 2)
        b = CounterCollector(); fit!(b, 3)
        merge!(a, b)
        @test value(a) == 5

        reset!(a)
        @test value(a) == 0
    end

    # ── Tasks 8-9: StatsPipeline record_*! ──────────────────────────────────
    @testset "StatsPipeline construction" begin
        p = StatsPipeline()
        @test p isa StatsPipeline
        @test p.warmup.mode == WARMUP_AUTO
        @test !p.warmup.complete

        # WARMUP_NONE is immediately open
        p2 = StatsPipeline(warmup=WARMUP_NONE)
        @test p2.warmup.complete

        # record_samples preallocates hint-sized buffers
        p3 = StatsPipeline(record_samples=true, max_samples=100)
        @test p3._record_samples == true
        @test p3._max_samples == 100
    end

    @testset "record_arrival! / record_blocked!" begin
        p = StatsPipeline(warmup=WARMUP_NONE)
        record_arrival!(p)
        record_arrival!(p)
        @test p._total_arrivals_raw == 2
        @test value(p.events) == 2
        @test value(p.arrivals) == 2

        record_blocked!(p)
        @test p._total_arrivals_raw == 3
        @test value(p.blocked) == 1
    end

    @testset "record_departure! gates on warmup" begin
        p = StatsPipeline(warmup=WARMUP_FIXED, warmup_n=2)

        # Departure 1: pre-warmup — sojourn should NOT be recorded
        record_departure!(p, 1.0, 2.0)
        @test isnan(value(p.sojourn))   # still NaN — gated

        # Departure 2: triggers warmup completion AND is recorded (warmup opens then falls through)
        record_departure!(p, 3.0, 4.0)
        @test p.warmup.complete == true
        @test value(p.sojourn) ≈ 4.0   # the triggering departure IS recorded
        @test value(p.wait) ≈ 3.0

        # Departure 3: post-warmup
        record_departure!(p, 5.0, 6.0)
        @test value(p.sojourn) ≈ (4.0 + 6.0) / 2   # mean of dep2 + dep3
        @test value(p.wait) ≈ (3.0 + 5.0) / 2
    end

    @testset "record_queue_length! (3-arg and 2-arg)" begin
        p = StatsPipeline(warmup=WARMUP_NONE)
        record_queue_length!(p, 3, 2, 5.0)   # 3-arg: sys=3, q=2, dt=5
        @test value(p.sys_size) ≈ 3.0
        @test value(p.q_size)   ≈ 2.0

        p2 = StatsPipeline(warmup=WARMUP_NONE)
        record_queue_length!(p2, 4, 5.0)     # 2-arg compat: q = max(0, 4-1) = 3
        @test value(p2.q_size) ≈ 3.0
    end

    @testset "record_utilization! / record_idle!" begin
        p = StatsPipeline(warmup=WARMUP_NONE)
        record_utilization!(p, 8.0)   # busy for 8s
        record_idle!(p, 2.0)          # idle for 2s
        @test value(p.util) ≈ 0.8     # busy_time / total_time = 8/(8+2)
    end

    @testset "record_samples buffering" begin
        p = StatsPipeline(warmup=WARMUP_NONE, record_samples=true, max_samples=5)
        for i in 1:7
            record_departure!(p, Float64(i), Float64(i) * 2.0)
        end
        @test length(p._sojourn_samples) == 5   # capped at max_samples
        @test length(p._wait_samples)    == 5
    end

    # ── Task 11: sim_summary ─────────────────────────────────────────────────
    @testset "sim_summary — backward-compat and new keys" begin
        p = StatsPipeline(warmup=WARMUP_NONE)
        record_arrival!(p)
        record_departure!(p, 2.0, 7.0)
        record_queue_length!(p, 1, 0, 5.0)
        record_queue_length!(p, 0, 0, 3.0)
        record_utilization!(p, 7.0)
        record_idle!(p, 3.0)

        sm = sim_summary(p)

        # Backward-compat keys
        @test haskey(sm, :L)              && !isnan(sm.L)
        @test haskey(sm, :Wq)             && sm.Wq ≈ 2.0
        @test haskey(sm, :W)              && sm.W  ≈ 7.0
        @test haskey(sm, :utilization)    && sm.utilization ≈ 0.7
        @test haskey(sm, :blocking_prob)
        @test haskey(sm, :total_arrivals) && sm.total_arrivals == 1
        @test haskey(sm, :total_departures) && sm.total_departures == 1
        @test haskey(sm, :blocked_count)  && sm.blocked_count == 0
        @test haskey(sm, :total_events)

        # New keys
        @test haskey(sm, :Lq)
        @test haskey(sm, :availability)
        @test haskey(sm, :throughput)
        @test haskey(sm, :W_quantile)
        @test haskey(sm, :Wq_quantile)
        @test haskey(sm, :queue_min)
        @test haskey(sm, :queue_max)
        @test haskey(sm, :warmup_complete) && sm.warmup_complete == true

        # Little's Law sanity: L̄ = (1*5+0*3)/(8) = 5/8, λ_eff = 1/8, W=7
        # L̄ ≠ λ_eff*W here because queue length and departure are tracked differently
        # (illustrative only — full Little's Law test below in Analysis section)
    end

    # ── Task 10: add_collector! ───────────────────────────────────────────────
    @testset "add_collector! — user extension API" begin
        p = StatsPipeline(warmup=WARMUP_NONE)

        # Add P99 sojourn collector
        p99 = P2QuantileCollector(0.99)
        add_collector!(p, :p99_sojourn, p99; trigger=:departure, extract=d -> d.sojourn)

        # Add peak queue collector
        peak = ExtremaCollector()
        add_collector!(p, :peak_queue, peak; trigger=:queue_change, extract=d -> Float64(d.sys))

        # Feed some data
        for i in 1:15
            record_arrival!(p)
            record_queue_length!(p, i, max(0, i-1), Float64(i))
            record_departure!(p, Float64(i)*0.1, Float64(i))
        end

        sm = sim_summary(p)
        @test haskey(sm, :p99_sojourn)
        @test haskey(sm, :peak_queue)
        v = sm.peak_queue
        @test v.max == 15.0   # max queue was 15

        # Invalid trigger should throw
        @test_throws ArgumentError add_collector!(p, :bad, MeanCollector(); trigger=:invalid, extract=identity)
    end

    # ── Task 12: reset! ───────────────────────────────────────────────────────
    @testset "reset! StatsPipeline" begin
        p = StatsPipeline(warmup=WARMUP_NONE, record_samples=true)
        record_arrival!(p)
        record_departure!(p, 1.0, 2.0)

        reset!(p)
        @test p._total_arrivals_raw == 0
        @test p._total_departures_raw == 0
        @test isnan(value(p.sojourn))
        @test isempty(p._sojourn_samples)
        @test p.warmup.complete == true   # WARMUP_NONE stays open after reset

        # WARMUP_FIXED: warmup re-arms after reset
        p2 = StatsPipeline(warmup=WARMUP_FIXED, warmup_n=5)
        for _ in 1:6; record_departure!(p2, 1.0, 2.0); end
        @test p2.warmup.complete == true
        reset!(p2)
        @test p2.warmup.complete == false   # re-armed

        # WARMUP_AUTO: WelchDetector is recreated
        p3 = StatsPipeline(warmup=WARMUP_AUTO, welch_window=5)
        for _ in 1:15; record_departure!(p3, 3.0, 3.0); end
        @test p3.warmup.complete == true
        reset!(p3)
        @test p3.warmup.complete == false   # re-armed
        @test p3.warmup._welch !== nothing
    end

    # ── Task 13: merge! ───────────────────────────────────────────────────────
    @testset "merge! StatsPipeline" begin
        p1 = StatsPipeline(warmup=WARMUP_NONE)
        p2 = StatsPipeline(warmup=WARMUP_NONE)

        record_departure!(p1, 1.0, 2.0)   # sojourn=2, wait=1
        record_departure!(p2, 3.0, 4.0)   # sojourn=4, wait=3

        merge!(p1, p2)

        @test value(p1.sojourn) ≈ 3.0   # (2+4)/2
        @test value(p1.wait)    ≈ 2.0   # (1+3)/2
        @test p1._total_departures_raw == 2
        @test p1._total_arrivals_raw   == 0

        # Warmup: complete if either is complete
        pa = StatsPipeline(warmup=WARMUP_FIXED, warmup_n=5)
        pb = StatsPipeline(warmup=WARMUP_NONE)   # immediately open
        @test pb.warmup.complete == true
        merge!(pa, pb)
        @test pa.warmup.complete == true   # pa now complete
    end

    # ── Tasks 14-16: Analysis ─────────────────────────────────────────────────
    @testset "check_littles_law" begin
        # Perfect Little's Law: L = λW, λ=2, W=1 → L=2 ✓
        sm = (L=2.0, W=1.0, throughput=2.0, Wq=0.5, utilization=0.8,
              total_arrivals=100, total_departures=100, blocked_count=0,
              total_events=200, Lq=1.0, availability=1.0,
              W_quantile=1.5, Wq_quantile=0.7,
              queue_min=0.0, queue_max=5.0, warmup_complete=true)
        ok, err = check_littles_law(sm)
        @test ok && err < 0.01

        # 20% error → violation at 10% tolerance
        sm2 = merge(sm, (L=2.4,))   # L_pred=2.0, L_meas=2.4 → err=0.167
        ok2, err2 = check_littles_law(sm2)
        @test !ok2

        # NaN throughput → skip check gracefully
        sm3 = merge(sm, (throughput=NaN,))
        ok3, err3 = check_littles_law(sm3)
        @test ok3 && isnan(err3)
    end

    @testset "batch_means_ci" begin
        # 300 samples with true mean=5.0
        rng_samples = [5.0 + 0.1 * sin(Float64(i)) for i in 1:300]
        ci = batch_means_ci(rng_samples; k=30)
        @test ci.n_batches == 30
        @test ci.batch_size == 10
        @test ci.ci_lo < ci.mean < ci.ci_hi
        @test 4.5 <= ci.mean <= 5.5

        # Too few samples → all NaN
        ci2 = batch_means_ci([1.0, 2.0]; k=10)
        @test isnan(ci2.mean)
        @test ci2.n_batches == 0

        # Exact constant series → CI of width 0
        ci3 = batch_means_ci(fill(7.0, 100); k=10)
        @test ci3.mean ≈ 7.0
        @test ci3.ci_lo ≈ 7.0 atol=1e-10
        @test ci3.ci_hi ≈ 7.0 atol=1e-10
    end

    @testset "replicate" begin
        # Synthetic: rep i returns W=i (seeds 1..5)
        result = replicate(5) do seed
            (W=Float64(seed), L=Float64(seed)*0.9, Wq=0.5,
             utilization=0.9, blocking_prob=0.0,
             total_arrivals=100, total_departures=90,
             blocked_count=0, total_events=190,
             Lq=0.0, availability=1.0, throughput=0.9,
             W_quantile=NaN, Wq_quantile=NaN,
             queue_min=0.0, queue_max=5.0, warmup_complete=true)
        end

        @test haskey(result, :W)
        @test result.W.mean ≈ 3.0   # (1+2+3+4+5)/5
        @test result.W.ci_lo < result.W.mean < result.W.ci_hi
        @test result.W.std_dev > 0.0

        # Numeric fields only; Bool (warmup_complete) should be skipped
        @test !haskey(result, :warmup_complete)

        # Minimum reps check
        @test_throws ArgumentError replicate(1) do seed; (W=1.0,); end
    end

    @testset "M/M/1 numerical accuracy (ρ=0.7)" begin
        # Run a short M/M/1 simulation with StatsPipeline to validate accuracy
        # Theory: λ=0.7, μ=1.0 → W = 1/(μ-λ) = 10/3, L = ρ/(1-ρ) = 7/3, ρ = 0.7
        rng    = MersenneTwister(42)
        λ, μ   = 0.7, 1.0
        N      = 50_000
        p      = StatsPipeline(warmup=WARMUP_FIXED, warmup_n=2_000)

        t      = 0.0
        queue  = 0
        server = false
        entry_times = Dict{Int,Float64}()
        next_arr = -log(rand(rng)) / λ
        next_dep = Inf
        id = 0

        for _ in 1:N
            if next_arr <= next_dep
                dt = next_arr - t
                t  = next_arr
                record_queue_length!(p, queue + (server ? 1 : 0), max(0, queue), dt)
                server ? (record_idle!(p, 0.0); record_utilization!(p, dt)) : record_idle!(p, dt)
                id += 1; entry_times[id] = t
                record_arrival!(p)
                if !server
                    server = true
                    next_dep = t - log(rand(rng)) / μ
                else
                    queue += 1
                end
                next_arr = t + (-log(rand(rng)) / λ)
            else
                dt = next_dep - t
                t  = next_dep
                record_queue_length!(p, queue + 1, queue, dt)
                record_utilization!(p, dt)
                sojourn = t - entry_times[id - queue]  # FIFO
                wait    = sojourn - (1/μ)
                record_departure!(p, max(0.0, wait), sojourn)
                delete!(entry_times, id - queue)
                if queue > 0
                    queue -= 1
                    next_dep = t - log(rand(rng)) / μ
                else
                    server = false
                    next_dep = Inf
                end
            end
        end

        sm = sim_summary(p)
        W_theory  = 1.0 / (μ - λ)        # 10/3 ≈ 3.333
        ρ_theory  = λ / μ                 # 0.7

        if sm.warmup_complete
            W_err = abs(sm.W - W_theory) / W_theory
            ρ_err = abs(sm.utilization - ρ_theory)
            # Generous 15% tolerance for 50k events
            @test W_err < 0.15   # W̄=$(round(sm.W,digits=3)) theory=$(round(W_theory,digits=3))
            @test ρ_err < 0.05   # ρ=$(round(sm.utilization,digits=3)) theory=$ρ_theory
        end
    end

end  # @testset "Sprint 4I — StatsPipeline"
