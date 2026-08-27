"""
diag_3l_v3_rotation.jl — FULL V3 ROTATIONAL STEERING DIAGNOSTIC

Per-agent dump at each checkpoint:
  - position, velocity, speed, gap
  - dir_goal, current heading θ, heading angle vs goal angle
  - nearest forward neighbor (with distance and lateral offset)
  - θ_target, rotation, Δθ, θ_new
  - e_final (movement direction), AWAY flag
  - y-spread histogram (compression indicator)

Key questions to answer:
  1. Are agents moving at all? (speed > 0)
  2. What heading are they stuck at?
  3. Is lateral = perpendicular neighbor causing maximum rotation?
  4. Do all agents converge to same y (compression deadlock)?
"""

using SimCrowd, Ark, StaticArrays, LinearAlgebra, Printf, Random

const F = Float32
const N = 80; const ROOM_L=10f0; const ROOM_W=4f0; const DOOR_CY=2f0; const DOOR_HALF=0.5f0
const GOAL_PT = SVector(12f0, DOOR_CY)
const EXIT_X = 10.5f0

function analyze_agent_v3(i::Int, pos_i::SVector{2,F}, vel_i::SVector{2,F},
                           heading_old::F, all_pos::Vector{SVector{2,F}},
                           params::CSMParams{F}, dt::F)
    r_i = params.radius
    cos_fov = cos(params.fov_half_angle)

    dg = GOAL_PT - pos_i; dir_goal = dg / norm(dg)

    # 1. csm_gap: nearest neighbor (all directions since fov=π)
    min_gap = F(Inf); min_d_gap = F(Inf)
    for j in eachindex(all_pos)
        j == i && continue
        r_ij = all_pos[j] - pos_i; d = norm(r_ij)
        d > params.neighbor_radius && continue
        d < eps(F) && continue
        dot(r_ij/d, dir_goal) > cos_fov || continue
        gap = max(d - r_i - r_i, F(0))
        if gap < min_gap; min_gap = gap; min_d_gap = d; end
    end
    speed = csm_speed(min_gap, params.v₀, params.T)

    # 2. Nearest forward neighbor for rotational model
    min_d_rot = typemax(F); best_j = 0
    for j in eachindex(all_pos)
        j == i && continue
        r_ij = all_pos[j] - pos_i; d = norm(r_ij)
        d > params.neighbor_radius && continue
        d < eps(F) && continue
        dot(r_ij/d, dir_goal) > cos_fov || continue
        if d < min_d_rot; min_d_rot = d; best_j = j; end
    end

    # 3. Rotational target
    θ_goal = atan(dir_goal[2], dir_goal[1])
    lateral = F(0); rotation = F(0); θ_target = θ_goal
    if best_j > 0
        e_right = SVector{2,F}(dir_goal[2], -dir_goal[1])
        r_ij    = all_pos[best_j] - pos_i
        lateral = dot(r_ij, e_right)
        rotation = -F(π/4) * tanh(lateral / max(min_d_rot, F(1e-3)))
        θ_target = θ_goal + rotation
    end

    # 4. Heading relaxation
    τ  = params.heading_relaxation_τ
    Δθ = θ_target - heading_old
    Δθ -= F(2π) * round(Δθ / F(2π))
    α  = min(dt / max(τ, eps(F)), one(F))
    θ_new = heading_old + α * Δθ
    e_final = SVector{2,F}(cos(θ_new), sin(θ_new))

    # 5. What direction is the nearest neighbor relative to goal?
    nbr_angle_from_goal = F(0)  # angle of neighbor direction relative to dir_goal
    if best_j > 0
        r_ij = all_pos[best_j] - pos_i
        nbr_angle_from_goal = atan(r_ij[2], r_ij[1]) - θ_goal
        # Wrap to [-π, π]
        while nbr_angle_from_goal > F(π); nbr_angle_from_goal -= F(2π); end
        while nbr_angle_from_goal < -F(π); nbr_angle_from_goal += F(2π); end
    end

    dir_away = e_final[1] < 0f0

    return (i=i, pos=pos_i, vel=vel_i, speed=speed, gap=min_gap, dir_goal=dir_goal,
            θ_old=heading_old, θ_goal=θ_goal, θ_target=θ_target, θ_new=θ_new,
            rotation=rotation, Δθ=Δθ, α=α, e_final=e_final,
            best_j=best_j, min_d_rot=min_d_rot, lateral=lateral,
            nbr_angle_from_goal=nbr_angle_from_goal, dir_away=dir_away)
end

function print_v3_detail(d)
    mark = d.dir_away ? "AWAY❌" : "ok✓"
    @printf("  A%-3d pos=(%.2f,%.2f)  v=(%.3f,%.3f)  spd=%.3f  gap=%.3f  %s\n",
            d.i, d.pos[1], d.pos[2], d.vel[1], d.vel[2], d.speed, d.gap, mark)
    @printf("       θ_old=%.3f  θ_goal=%.3f  θ_diff=%.3f  rotation=%.3f  θ_target=%.3f  θ_new=%.3f\n",
            d.θ_old, d.θ_goal, d.θ_old-d.θ_goal, d.rotation, d.θ_target, d.θ_new)
    @printf("       e_final=(%.3f,%.3f)  dir_goal=(%.3f,%.3f)\n",
            d.e_final[1], d.e_final[2], d.dir_goal[1], d.dir_goal[2])
    if d.best_j > 0
        @printf("       nbr=A%-3d  nbr_d=%.3f  lateral=%.3f  nbr_angle=%.3f rad (%.0f°)\n",
                d.best_j, d.min_d_rot, d.lateral, d.nbr_angle_from_goal,
                rad2deg(d.nbr_angle_from_goal))
    else
        @printf("       no forward neighbor\n")
    end
end

function run_v3_diag(; t_max=F(10), dump_times=[F(0.05),F(0.5),F(1.0),F(2.0),F(5.0),F(10.0)])
    p_v3 = CSMParams_V3(F; a_neighbor=F(8), D_neighbor=F(0.2), T=F(0.8))

    println("\n══════════════════════════════════════════════")
    println("V3 ROTATIONAL STEERING DIAGNOSTIC")
    println("τ=$(p_v3.heading_relaxation_τ)  a_wall=$(p_v3.a_wall)  fov=$(p_v3.fov_half_angle) rad")
    println("a_nbr=$(p_v3.a_neighbor)  D_nbr=$(p_v3.D_neighbor)  T=$(p_v3.T)  N=$N")
    println("══════════════════════════════════════════════\n")

    world = _make_v3_world(p_v3)

    dt = F(0.05); t = F(0)
    n_passed = 0

    while t <= t_max
        should_dump = any(abs(t - td) < dt/2 for td in dump_times)

        if should_dump
            all_pos = SVector{2,F}[]
            all_vel = SVector{2,F}[]
            all_θ   = F[]

            for (_, pos_c, vel_c, _, _, state_c) in
                    Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
                for i in eachindex(pos_c)
                    push!(all_pos, pos_c[i].p)
                    push!(all_vel, vel_c[i].v)
                    push!(all_θ,   state_c[i].heading)
                end
            end

            active = [i for i in eachindex(all_pos) if all_pos[i][1] < EXIT_X]
            n_active = length(active)

            details = [analyze_agent_v3(i, all_pos[i], all_vel[i], all_θ[i], all_pos, p_v3, dt)
                       for i in active]

            n_away = count(d -> d.dir_away, details)
            n_zero = count(d -> d.speed < 0.01f0, details)
            mean_spd = isempty(details) ? 0f0 : sum(d.speed for d in details)/length(details)

            # y-spread: std of y positions (compression indicator)
            ys = [d.pos[2] for d in details]
            y_mean = isempty(ys) ? 2f0 : sum(ys)/length(ys)
            y_std  = isempty(ys) ? 0f0 : sqrt(sum((y-y_mean)^2 for y in ys)/length(ys))

            # θ statistics
            θ_diffs = [abs(d.θ_old - d.θ_goal) for d in details]
            mean_θ_diff = isempty(θ_diffs) ? 0f0 : sum(θ_diffs)/length(θ_diffs)
            max_θ_diff  = isempty(θ_diffs) ? 0f0 : maximum(θ_diffs)

            # Lateral neighbor angle histogram
            nbr_angles = [d.nbr_angle_from_goal for d in details if d.best_j > 0]
            n_perp = count(a -> abs(a) > F(π/4), nbr_angles)  # >45° off-forward = lateral
            n_fwd  = count(a -> abs(a) <= F(π/4), nbr_angles)

            println("─────────────────────────────────────────────────────────")
            @printf("t=%.2fs  active=%-3d  AWAY=%-3d (%.0f%%)  zero_v=%-3d  v̄=%.3f\n",
                    t, n_active, n_away, 100*n_away/max(1,n_active), n_zero, mean_spd)
            @printf("         y_mean=%.3f  y_std=%.3f  passed=%d\n", y_mean, y_std, n_passed)
            @printf("         θ_diff: mean=%.3f  max=%.3f  (rad from goal direction)\n",
                    mean_θ_diff, max_θ_diff)
            @printf("         Neighbor angle: %d lateral (>45°)  %d forward (≤45°)\n",
                    n_perp, n_fwd)

            # Gap histogram
            gaps = [d.gap for d in details]
            g0   = count(g -> g < 0.01f0, gaps)
            g05  = count(g -> g < 0.5f0, gaps)
            @printf("         gaps<0.01m: %d  gaps<0.5m: %d\n", g0, g05)

            # Print ALL AWAY agents
            println("  --- AWAY agents ---")
            for d in filter(d -> d.dir_away, details)
                print_v3_detail(d)
            end

            # Print agents with speed=0
            println("  --- Stopped agents (speed<0.01) ---")
            for d in filter(d -> d.speed < 0.01f0, details)[1:min(end,5)]
                print_v3_detail(d)
            end

            # Print top 5 by |rotation| (most-rotated agents)
            by_rot = sort(details; by=d->abs(d.rotation), rev=true)
            println("  --- Top 5 by |rotation| (most steered away from goal) ---")
            for d in first(by_rot, 5)
                print_v3_detail(d)
            end

            # Print agents near door (x>8m)
            near_door = sort(filter(d -> d.pos[1] > 8f0, details); by=d->d.pos[1], rev=true)
            if !isempty(near_door)
                println("  --- Agents at x>8m (nearest to door) ---")
                for d in first(near_door, 5)
                    print_v3_detail(d)
                end
            end
        end

        # Advance world
        update_csm_system!(world, dt)
        t += dt

        # Count exits (without parking — just observe)
        for (_, pos_c, vel_c, goal_c, _, state_c) in
                Query(world, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, AgentCSMState{F}))
            for i in eachindex(pos_c)
                if pos_c[i].p[1] >= EXIT_X
                    n_passed += 1
                    pos_c[i]  = Position(SVector(-50f0, DOOR_CY))
                    vel_c[i]  = Velocity(zero(SVector{2,F}))
                    goal_c[i] = Goal(SVector(-150f0, DOOR_CY))  # park left
                end
            end
        end
    end

    @printf("\n=== FINAL (t=%.1fs)  passed=%d/%d ===\n", t_max, n_passed, N)
end

function _make_v3_world(params::CSMParams{F}) where {F}
    world = World(Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, WallSegment{F}, AgentCSMState{F})
    dc=DOOR_CY; dh=DOOR_HALF
    new_entity!(world, (WallSegment(SVector(0f0,0f0), SVector(0f0,ROOM_W)),))
    new_entity!(world, (WallSegment(SVector(0f0,0f0), SVector(ROOM_L,0f0)),))
    new_entity!(world, (WallSegment(SVector(0f0,ROOM_W), SVector(ROOM_L,ROOM_W)),))
    new_entity!(world, (WallSegment(SVector(ROOM_L,0f0), SVector(ROOM_L,dc-dh)),))
    new_entity!(world, (WallSegment(SVector(ROOM_L,dc+dh), SVector(ROOM_L,ROOM_W)),))
    rng = MersenneTwister(42)
    cols = max(1, ceil(Int, sqrt(N*9f0/3.4f0))); rows = ceil(Int, N/cols)
    sp_x = 9f0/(cols+1); sp_y = 3.4f0/(rows+1)
    goal = GOAL_PT
    for k in 1:N
        row=(k-1)÷cols; col=(k-1)%cols
        x = 0.5f0+(col+1)*sp_x+0.05f0*(rand(rng,F)-0.5f0)
        y = 0.3f0+(row+1)*sp_y+0.05f0*(rand(rng,F)-0.5f0)
        x = clamp(x,0.3f0,9.7f0); y = clamp(y,0.3f0,3.7f0)
        θ = atan(goal[2]-y, goal[1]-x)
        new_entity!(world, (Position(SVector(x,y)), Velocity(zero(SVector{2,F})),
                             Goal(goal), params, AgentCSMState{F}(θ)))
    end
    return world
end

run_v3_diag(; t_max=F(10), dump_times=[F(0.05), F(0.5), F(1.0), F(2.0), F(5.0)])
