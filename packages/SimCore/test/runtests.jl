using SimCore
using Test
using StaticArrays: SVector

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
