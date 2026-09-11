using SimViz
using SimCrowd: step!

function diag_dispatch!(ctx, t)
    n_before = length(ctx.sim_world.crowd_agents)
    for (i, ev) in enumerate(ctx.config.events)
        i in ctx._fired_events && continue
        if ev.time <= t
            println("  [DISPATCH] ev[$i] type=:$(ev.type) fire_time=$(ev.time) t=$(round(t,digits=3)) → FIRING NOW")
        end
    end
    SimViz._dispatch_events!(ctx, t)
    n_after = length(ctx.sim_world.crowd_agents)
    if n_after != n_before
        println("  [DISPATCH] crowd_agents changed: $n_before → $n_after")
    end
end

function print_ctx(label, ctx; show_agents=true)
    sc = ctx.sim_world.stats
    n  = length(ctx.sim_world.crowd_agents)
    println("  [$label] t=$(round(ctx.sim_time,digits=3))s  lambda=$(ctx._mm1_lambda)" *
            "  n_des=$n  arrivals=$(sc.total_arrivals)  departs=$(sc.total_departures)" *
            "  events=$(sc.total_events)  n_fel=$(length(ctx._mm1_fel))")
    if show_agents && n > 0
        for (k, ag) in ctx.sim_world.crowd_agents
            println("    agent id=$k  pos=$(round.(ag.position,digits=2))  speed=$(round(ag.desired_speed,digits=3))")
        end
    end
    if !isempty(ctx._mm1_fel)
        top = ctx._mm1_fel[1:min(end,3)]
        println("    FEL: ", [(round(t,digits=3), sym) for (t,sym,_) in top])
    end
end

sep(t) = println("\n", "="^65, "\n  ", t, "\n", "="^65)

function run_ticks!(ctx, n; label_prefix="TICK")
    prev_arr = ctx.sim_world.stats.total_arrivals
    prev_dep = ctx.sim_world.stats.total_departures
    prev_n   = length(ctx.sim_world.crowd_agents)
    for i in 1:n
        ok = true
        try
            step!(ctx.scene)
        catch e
            println("  [ERROR in step!] $e"); ok = false
        end
        if ok
            ctx.sim_time += ctx.config.dt
            try
                diag_dispatch!(ctx, ctx.sim_time)
            catch e
                println("  [ERROR in _dispatch_events!] $e"); ok = false
            end
        end
        sc    = ctx.sim_world.stats
        n_now = length(ctx.sim_world.crowd_agents)
        changed = (sc.total_arrivals != prev_arr || sc.total_departures != prev_dep || n_now != prev_n)
        if i <= 6 || changed
            print_ctx("$label_prefix $i", ctx; show_agents = changed && n_now > 0)
        end
        prev_arr = sc.total_arrivals
        prev_dep = sc.total_departures
        prev_n   = n_now
        !ok && break
    end
end

function main()
    # ── Phase 1: build_world ──────────────────────────────────────────────────
    sep("PHASE 1: build_world!")
    config = SimViz.mm1_scenario(lambda=0.9, mu=1.0, rng_seed=42)
    println("Config: n_agents=$(config.n_agents)  dt=$(config.dt)  room=$(config.room.width)x$(config.room.height)m")
    println("Scheduled events: ", [(ev.type, ev.time) for ev in config.events])

    ctx = SimViz.build_world!(config)
    print_ctx("POST-BUILD", ctx; show_agents=false)
    println("  _fired_events=$(ctx._fired_events)  _mm1_lambda=$(ctx._mm1_lambda)  mm1_fel=$(ctx._mm1_fel)")

    # ── Phase 2: 30 ticks ────────────────────────────────────────────────────
    sep("PHASE 2: 30 ticks after build_world (is_paused=false, running)")
    run_ticks!(ctx, 60; label_prefix="TICK")

    # ── Phase 3: Reset ────────────────────────────────────────────────────────
    sep("PHASE 3: Reset (mirrors Reset button callback: was_paused restored)")
    println("  State before reset: t=$(ctx.sim_time)  arrivals=$(ctx.sim_world.stats.total_arrivals)")
    SimViz.reset_scenario!(ctx; config=config)
    print_ctx("POST-RESET", ctx; show_agents=false)
    println("  _fired_events=$(ctx._fired_events)  _mm1_lambda=$(ctx._mm1_lambda)  mm1_fel=$(ctx._mm1_fel)")

    # ── Phase 4: 30 ticks post-Reset ─────────────────────────────────────────
    sep("PHASE 4: 30 ticks after Reset")
    run_ticks!(ctx, 60; label_prefix="POST-RST-TICK")

    # ── Phase 5: What update_viz! would read ──────────────────────────────────
    sep("PHASE 5: What scatter! / update_viz! would render")
    snap = SimViz.serialize_world_ctx(ctx)
    println("  snap.sim_time=$(snap.sim_time)  n_agents=$(snap.n_agents)  n_des_agents=$(snap.n_des_agents)")
    sc2 = snap.stats
    println("  stats: arrivals=$(sc2.total_arrivals)  departures=$(sc2.total_departures)  events=$(sc2.total_events)")
    n_des = length(ctx.sim_world.crowd_agents)
    println("  DES scatter dots ($n_des total):")
    for (k, ag) in ctx.sim_world.crowd_agents
        color = ag.desired_speed ≈ 1.34f0 ? "GREEN(waiting)" : "BLUE(in-service)"
        println("    id=$k  pos=$(round.(ag.position,digits=2))  $color")
    end
    sep("DIAGNOSTIC COMPLETE")
end

main()
