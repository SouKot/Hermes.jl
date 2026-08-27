"""
diag_3l_v2_wall.jl — FULL V2 WALL REPULSION DIAGNOSTIC

Rule Zero: observe before fixing.

Shows per-agent, per-wall-segment repulsion contributions. Compares V1 vs V2
at identical initial state. Dumps everything at t=0, t=0.5, t=1, t=2, t=5s.

Output columns:
  Agent# | x    | y    | speed | gap  | v_x  | v_y  | dir_goal.x | dir_goal.y
  |rep_nbr| rep_nbr.x | rep_nbr.y  (nearest forward neighbor only)
  |W0_rep| W1_rep | W2_rep | W3_rep | W4_rep   (per wall segment)
  |tot_wall.x | tot_wall.y | total_rep.x | total_rep.y | |total|
  | raw.x | raw.y | e.x | e.y | AWAY?

Wall index:
  W0: (0,0)→(0,4)     left wall
  W1: (0,0)→(10,0)    bottom wall
  W2: (0,4)→(10,4)    top wall
  W3: (10,0)→(10,1.5) bottom door frame
  W4: (10,2.5)→(10,4) top door frame
"""

using SimCrowd, Ark, StaticArrays, LinearAlgebra, Printf, Random

const F = Float32
const N = 80
const ROOM_L = 10f0; const ROOM_W = 4f0; const DOOR_CY = 2f0; const DOOR_HALF = 0.5f0
const GOAL = SVector(12f0, DOOR_CY)
const EXIT_X = 10.5f0

# Wall segments (must match _make_csm_world / build_diag_world)
const WALLS = [
    (SVector(0f0,0f0), SVector(0f0,ROOM_W)),           # W0: left
    (SVector(0f0,0f0), SVector(ROOM_L,0f0)),           # W1: bottom
    (SVector(0f0,ROOM_W), SVector(ROOM_L,ROOM_W)),     # W2: top
    (SVector(ROOM_L,0f0), SVector(ROOM_L,DOOR_CY-DOOR_HALF)), # W3: door bottom
    (SVector(ROOM_L,DOOR_CY+DOOR_HALF), SVector(ROOM_L,ROOM_W)), # W4: door top
]
const WALL_NAMES = ["W0(left)", "W1(bot)", "W2(top)", "W3(door-bot)", "W4(door-top)"]

# Grid placement (matches _make_csm_world)
function grid_positions(N::Int)
    cols = max(1, ceil(Int, sqrt(N * (9.0f0 / 3.4f0))))
    rows = ceil(Int, N / cols)
    sp_x = F(9.0) / (cols + 1)
    sp_y = F(3.4) / (rows + 1)
    rng  = MersenneTwister(42)
    ps = SVector{2,F}[]
    for k in 1:N
        row = (k-1) ÷ cols; col = (k-1) % cols
        x = F(0.5) + (col+1)*sp_x + F(0.05)*(rand(rng,F)-F(0.5))
        y = F(0.3) + (row+1)*sp_y + F(0.05)*(rand(rng,F)-F(0.5))
        push!(ps, SVector(clamp(x,F(0.3),F(9.7)), clamp(y,F(0.3),F(3.7))))
    end
    return ps
end

# Full per-agent detail for V2 (wall by wall)
struct V2AgentDetail
    i       :: Int
    pos     :: SVector{2,F}
    vel     :: SVector{2,F}
    speed   :: F
    gap     :: F             # surface gap to nearest forward neighbor
    dir_goal :: SVector{2,F}
    nbr_d   :: F             # nearest forward neighbor distance
    nbr_j   :: Int
    rep_nbr :: SVector{2,F}  # neighbor repulsion vector
    rep_w   :: NTuple{5, F}  # per-wall magnitude (+ = magnitude, actual direction inferred from sign)
    rep_w_v :: NTuple{5, SVector{2,F}} # per-wall vectors
    wall_tot :: SVector{2,F} # total wall repulsion before cap
    total_rep :: SVector{2,F} # neighbor + wall (after cap)
    raw     :: SVector{2,F}  # dir_goal - total_rep (before normalize)
    e_final :: SVector{2,F}  # actual movement direction (normalized raw)
    dir_away :: Bool
    n_fwd   :: Int
end

function analyze_agent_v2(i::Int, pos_i::SVector{2,F}, vel_i::SVector{2,F},
                           all_pos::Vector{SVector{2,F}}, params::CSMParams{F})
    r_i = params.radius; cos_fov = cos(params.fov_half_angle)
    dg = GOAL - pos_i; dir_goal = dg / norm(dg)

    # Nearest forward neighbor
    min_d = typemax(F); best_j = 0; min_gap = typemax(F); n_fwd = 0
    for j in eachindex(all_pos)
        j == i && continue
        r_ij = all_pos[j] - pos_i; d = norm(r_ij)
        d > params.neighbor_radius && continue
        d > eps(F) || continue
        n = r_ij / d
        if dot(n, dir_goal) > cos_fov
            n_fwd += 1
            gap = max(d - r_i - params.radius, F(0))
            if d < min_d; min_d = d; best_j = j; end
            if gap < min_gap; min_gap = gap; end
        end
    end
    min_gap = min_gap == typemax(F) ? F(Inf) : min_gap

    # Neighbor repulsion (nearest forward only)
    rep_nbr = zero(SVector{2,F})
    if best_j > 0
        r_ij = all_pos[best_j] - pos_i; n = r_ij / min_d
        rep_nbr = (params.a_neighbor * exp(-min_d / params.D_neighbor)) * n
    end

    # Wall repulsion PER SEGMENT
    rep_w_v = ntuple(k -> zero(SVector{2,F}), 5)
    rep_w   = ntuple(k -> F(0), 5)
    wall_tot = zero(SVector{2,F})
    if params.a_wall > zero(F)
        for (wi, (p1, p2)) in enumerate(WALLS)
            pt, dw, _ = nearest_point_on_segment(p1, p2, pos_i)
            dw > params.neighbor_radius && continue
            dw < eps(F) && continue
            # NEW formula: toward wall
            n_w = (pt - pos_i) / dw
            wv  = (params.a_wall * exp(-dw / params.D_wall)) * n_w
            rep_w_v = Base.setindex(rep_w_v, wv, wi)
            rep_w   = Base.setindex(rep_w, params.a_wall * exp(-dw / params.D_wall), wi)
            wall_tot += wv
        end
    end

    # Total repulsion + safety cap
    total_rep = rep_nbr + wall_tot
    mag = norm(total_rep)
    if mag >= one(F)
        total_rep = total_rep * (F(0.99) / mag)
    end

    raw      = dir_goal - total_rep
    raw_norm = norm(raw)
    e_final  = raw_norm > eps(F) ? raw / raw_norm : dir_goal
    dir_away = e_final[1] < zero(F)
    speed    = norm(vel_i)

    return V2AgentDetail(i, pos_i, vel_i, speed, min_gap, dir_goal,
                         min_d, best_j, rep_nbr, rep_w, rep_w_v,
                         wall_tot, total_rep, raw, e_final, dir_away, n_fwd)
end

function print_v2_detail(d::V2AgentDetail)
    mark = d.dir_away ? "AWAY❌" : "ok✓"
    @printf("  A%-3d  pos=(%.2f,%.2f)  v=(%.3f,%.3f)  spd=%.3f  gap=%.3f  away=%s\n",
            d.i, d.pos[1], d.pos[2], d.vel[1], d.vel[2], d.speed, d.gap, mark)
    @printf("       dir_goal=(%.3f,%.3f)  n_fwd=%-3d  nbr_d=%.3f  rep_nbr=(%.3f,%.3f)|%.3f\n",
            d.dir_goal[1], d.dir_goal[2], d.n_fwd, d.nbr_d == typemax(F) ? 9.99f0 : d.nbr_d,
            d.rep_nbr[1], d.rep_nbr[2], norm(d.rep_nbr))
    for wi in 1:5
        wm = d.rep_w[wi]; wv = d.rep_w_v[wi]
        wm > 0.001f0 || continue
        @printf("       %s: |rep|=%.4f  vec=(%.4f,%.4f)\n",
                WALL_NAMES[wi], wm, wv[1], wv[2])
    end
    @printf("       wall_tot=(%.4f,%.4f)|%.4f  total_rep=(%.4f,%.4f)|%.4f\n",
            d.wall_tot[1], d.wall_tot[2], norm(d.wall_tot),
            d.total_rep[1], d.total_rep[2], norm(d.total_rep))
    @printf("       raw=(%.4f,%.4f)  e=(%.4f,%.4f)\n",
            d.raw[1], d.raw[2], d.e_final[1], d.e_final[2])
end

function run_v2_diag(; t_max=F(10), dump_times=[F(0.05),F(0.5),F(1.0),F(2.0),F(5.0)])
    p_v1 = CSMParams_V1(F; a_neighbor=F(8), D_neighbor=F(0.2), T=F(0.8))
    p_v2 = CSMParams_V2(F; a_neighbor=F(8), D_neighbor=F(0.2), T=F(0.8))

    println("\n══════════════════════════════════════════════")
    println("V2 WALL DIAGNOSTIC  (a_wall=", p_v2.a_wall, "  D_wall=", p_v2.D_wall, ")")
    println("a_nbr=", p_v2.a_neighbor, "  D_nbr=", p_v2.D_neighbor, "  T=", p_v2.T)
    println("N=", N, "  room=", ROOM_L, "×", ROOM_W, "m  door=", 2*DOOR_HALF, "m")
    println("══════════════════════════════════════════════\n")

    # Print wall geometry
    println("=== WALL SEGMENTS ===")
    for (wi,(p1,p2)) in enumerate(WALLS)
        @printf("  %s: (%.1f,%.1f)→(%.1f,%.1f)\n", WALL_NAMES[wi], p1[1],p1[2], p2[1],p2[2])
    end
    println()

    # Build worlds
    world_v1 = _make_csm_world_diag(p_v1; v3=false)
    world_v2 = _make_csm_world_diag(p_v2; v3=false)

    t     = F(0)
    dt    = F(0.05)
    dump_set = Set(dump_times)
    passed_v1 = 0; passed_v2 = 0
    dump_idx  = 1

    while t <= t_max
        should_dump = any(abs(t - td) < dt/2 for td in dump_times)

        if should_dump
            # Collect positions and velocities using correct Ark Query pattern
            # Pattern: for (_, col1, col2, ...) in Query(world, (T1, T2, ...))
            pos_v1 = SVector{2,F}[]
            pos_v2 = SVector{2,F}[]
            vel_v2 = SVector{2,F}[]
            for (_, pos_c, vel_c, _, _) in Query(world_v1, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
                for i in eachindex(pos_c)
                    push!(pos_v1, pos_c[i].p)
                end
            end
            for (_, pos_c, vel_c, _, _) in Query(world_v2, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
                for i in eachindex(pos_c)
                    push!(pos_v2, pos_c[i].p)
                    push!(vel_v2, vel_c[i].v)
                end
            end


            n_v2 = length(pos_v2)
            details = [analyze_agent_v2(i, pos_v2[i], vel_v2[i], pos_v2, p_v2)
                       for i in 1:n_v2 if pos_v2[i][1] < EXIT_X]

            n_away = count(d -> d.dir_away, details)
            n_zero = count(d -> d.speed < 0.01f0, details)
            mean_speed = isempty(details) ? 0f0 : sum(d.speed for d in details)/length(details)
            x_gt8  = count(d -> d.pos[1] > 8f0, details)
            x_gt9  = count(d -> d.pos[1] > 9f0, details)

            # Gap histogram
            gaps = [d.gap for d in details if d.gap < Inf]
            g0   = count(g -> g < 0.05f0, gaps)
            g05  = count(g -> g < 0.5f0, gaps)

            # Per-wall summary
            w_contribs = [sum(d.rep_w[wi] for d in details) for wi in 1:5]
            max_by_wall = [maximum(d.rep_w[wi] for d in details; init=F(0)) for wi in 1:5]

            println("─────────────────────────────────────────────────────────")
            @printf("t=%.2fs  active=%d  AWAY=%d (%.0f%%)  zero_v=%d  v̄=%.3f\n",
                    t, length(details), n_away, 100*n_away/max(1,length(details)),
                    n_zero, mean_speed)
            @printf("         x>8m=%d  x>9m=%d  gaps<0.05m: %d  gaps<0.5m: %d\n",
                    x_gt8, x_gt9, g0, g05)
            println("  Per-wall total contrib & max agent contrib:")
            for wi in 1:5
                w_contribs[wi] > 0.001f0 || continue
                @printf("    %s: total=%.3f  max_per_agent=%.3f\n",
                        WALL_NAMES[wi], w_contribs[wi], max_by_wall[wi])
            end

            # FULL dump: all AWAY agents + all agents near door (x>8m) + worst wall contributors
            println("  --- AWAY agents ---")
            for d in filter(d -> d.dir_away, details)
                print_v2_detail(d)
            end

            println("  --- Agents at x>8m (door approach) ---")
            near_door = sort(filter(d -> d.pos[1] > 8.0f0, details); by=d->d.pos[1], rev=true)
            for d in first(near_door, 15)
                print_v2_detail(d)
            end

            println("  --- Top 5 agents by wall repulsion magnitude ---")
            by_wall = sort(details; by=d->norm(d.wall_tot), rev=true)
            for d in first(by_wall, 5)
                print_v2_detail(d)
            end

            println("  --- Compare V1 vs V2 direction for agents at x>8m (first 5) ---")
            pos_v1_set = Set(pos_v1)
            for d in first(near_door, 5)
                i = d.i
                if i <= length(pos_v1)
                    p1 = pos_v1[i]
                    gd1 = GOAL - p1; dg1 = gd1 / norm(gd1)
                    nbr1_rep = zero(SVector{2,F})  # V1: no wall, just nearest neighbor
                    min_d1 = typemax(F); best1 = 0
                    for j in eachindex(pos_v1)
                        j == i && continue
                        r_ij = pos_v1[j] - p1; dij = norm(r_ij)
                        dij > p_v1.neighbor_radius && continue
                        dij > eps(F) || continue
                        if dot(r_ij/dij, dg1) > cos(p_v1.fov_half_angle) && dij < min_d1
                            min_d1 = dij; best1 = j
                        end
                    end
                    if best1 > 0
                        r = pos_v1[best1] - p1
                        nbr1_rep = (p_v1.a_neighbor * exp(-min_d1/p_v1.D_neighbor)) * (r/min_d1)
                    end
                    e1 = let r = dg1 - nbr1_rep; n=norm(r); n>eps(F) ? r/n : dg1 end
                    @printf("  A%-3d V1_e=(%.3f,%.3f)  V2_e=(%.3f,%.3f)  ΔW=(%.3f,%.3f)\n",
                            i, e1[1], e1[2], d.e_final[1], d.e_final[2],
                            d.wall_tot[1], d.wall_tot[2])
                end
            end
        end

        # Advance both worlds
        update_csm_system!(world_v1, dt)
        update_csm_system!(world_v2, dt)
        t += dt
    end

    # Final summary — count agents that reached exit
    for (_, pos_c, _, _, _) in Query(world_v1, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
        for i in eachindex(pos_c)
            pos_c[i].p[1] >= EXIT_X && (passed_v1 += 1)
        end
    end
    for (_, pos_c, _, _, _) in Query(world_v2, (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}))
        for i in eachindex(pos_c)
            pos_c[i].p[1] >= EXIT_X && (passed_v2 += 1)
        end
    end
    @printf("\n=== FINAL (t=%.1fs) ===\n", t_max)
    @printf("  V1 passed=%d/%d\n", passed_v1, N)
    @printf("  V2 passed=%d/%d\n", passed_v2, N)
end

# Helper: _make_csm_world_diag (reuses same grid logic as _make_csm_world)
function _make_csm_world_diag(params::CSMParams{F}; v3=false)
    comp_types = v3 ?
        (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, WallSegment{F}, AgentCSMState{F}) :
        (Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, WallSegment{F})
    world = World(comp_types...)
    dc = DOOR_CY; dh = DOOR_HALF
    new_entity!(world, (WallSegment(SVector(0f0,0f0), SVector(0f0,ROOM_W)),))
    new_entity!(world, (WallSegment(SVector(0f0,0f0), SVector(ROOM_L,0f0)),))
    new_entity!(world, (WallSegment(SVector(0f0,ROOM_W), SVector(ROOM_L,ROOM_W)),))
    new_entity!(world, (WallSegment(SVector(ROOM_L,0f0), SVector(ROOM_L,dc-dh)),))
    new_entity!(world, (WallSegment(SVector(ROOM_L,dc+dh), SVector(ROOM_L,ROOM_W)),))

    rng  = MersenneTwister(42)
    cols = max(1, ceil(Int, sqrt(N * (9.0f0 / 3.4f0))))
    rows = ceil(Int, N / cols)
    sp_x = F(9.0) / (cols + 1); sp_y = F(3.4) / (rows + 1)
    for k in 1:N
        row = (k-1) ÷ cols; col = (k-1) % cols
        x = F(0.5) + (col+1)*sp_x + F(0.05)*(rand(rng,F)-F(0.5))
        y = F(0.3) + (row+1)*sp_y + F(0.05)*(rand(rng,F)-F(0.5))
        x = clamp(x,F(0.3),F(9.7)); y = clamp(y,F(0.3),F(3.7))
        θ = atan(GOAL[2]-y, GOAL[1]-x)
        if v3
            new_entity!(world, (Position(SVector(x,y)), Velocity(zero(SVector{2,F})),
                                Goal(GOAL), params, AgentCSMState{F}(θ)))
        else
            new_entity!(world, (Position(SVector(x,y)), Velocity(zero(SVector{2,F})),
                                Goal(GOAL), params))
        end
    end
    return world
end

# ── Main ───────────────────────────────────────────────────────────────────────
run_v2_diag(; t_max=F(10), dump_times=[F(0.05), F(0.5), F(1.0), F(2.0), F(5.0), F(10.0)])
