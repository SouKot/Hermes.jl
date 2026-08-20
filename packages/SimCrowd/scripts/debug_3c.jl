using Pkg
Pkg.activate(".")

using SimCrowd
using Ark
using KernelAbstractions
using StaticArrays
using Random
using Printf


function run_helbing_evacuation_debug(v0; seed=42, t_max=200f0)
    rng = MersenneTwister(seed)

    N          = 50
    dt         = 0.001f0
    room_W     = 6f0; room_H = 6f0
    door_width = 1.0f0
    door_y     = room_H / 2f0
    door_lo    = door_y - door_width/2f0
    door_hi    = door_y + door_width/2f0
    goal_x     = 9f0

    world = World(Position{Float32}, Velocity{Float32}, AgentGeometry{Float32},
                  MotionParams{Float32}, SFMParams{Float32},
                  ORCAParams{Float32}, Goal{Float32}, Force{Float32}, WallSegment{Float32})

    new_entity!(world, (WallSegment(SVector(0f0, 0f0),     SVector(room_W, 0f0)),))
    new_entity!(world, (WallSegment(SVector(0f0, room_H),  SVector(room_W, room_H)),))
    new_entity!(world, (WallSegment(SVector(0f0, 0f0),     SVector(0f0, room_H)),))
    new_entity!(world, (WallSegment(SVector(room_W, 0f0),     SVector(room_W, door_lo)),))
    new_entity!(world, (WallSegment(SVector(room_W, door_hi), SVector(room_W, room_H)),))

    positions_3c = place_on_grid(rng, N, 0.5f0, Float32(room_W - 0.5f0),
                                  0.5f0, Float32(room_H - 0.5f0))
    for i in 1:N
        pos = positions_3c[i]
        new_entity!(world, (
            Position(pos),
            Velocity(SVector(0f0, 0f0)),
            from_agent_params(0.25f0, 0.25f0, 80f0, v0, 0.5f0, Inf32, 0.1f0)...,
            Goal(SVector(room_W, door_y)),
            Force(SVector(0f0, 0f0))
        ))
    end

    sh = CPUNeighborSearch(N, SVector(-1f0,-1f0), SVector(goal_x+1f0, room_H+1f0), 3f0)

    function get_positions()
        positions = SVector{2,Float32}[]
        for (_, pos_col) in Query(world, (Position{Float32},))
            for p in pos_col
                push!(positions, p.p)
            end
        end
        return positions
    end

    function count_evacuated()
        c = 0
        for (_, pos_col) in Query(world, (Position{Float32},))
            for p in pos_col
                p.p[1] > room_W + 0.5f0 && (c += 1)
            end
        end
        return c
    end

    t = 0f0
    while count_evacuated() < N && t < t_max
        for (_, pos_col, vel_col, motion_col, goal_col, force_col) in
                Query(world, (Position{Float32}, Velocity{Float32}, MotionParams{Float32}, Goal{Float32}, Force{Float32}))
            for i in eachindex(pos_col)
                px = pos_col[i].p[1]
                goal_col[i] = px > room_W ? Goal(SVector(goal_x, door_y)) :
                                            Goal(SVector(room_W, door_y))
                F_drive = goal_seeking_force(pos_col[i].p, vel_col[i].v, goal_col[i].g,
                                              motion_col[i].v_pref, motion_col[i].τ, motion_col[i].mass)
                force_col[i] = Force(F_drive)
            end
        end
        update_social_forces_system!(world, sh, CPU())
        integrate_physics_system!(world, dt)
        t += dt
    end

    n_evac = count_evacuated()
    positions = get_positions()
    stuck = [pos for pos in positions if pos[1] <= room_W + 0.5f0]

    @printf("\nv₀=%.1f, t=%.1fs, evacuated=%d/50\n", v0, t, n_evac)
    @printf("Stuck agents (%d):\n", length(stuck))
    for pos in sort(stuck, by=p->p[1])
        @printf("  x=%.2f, y=%.2f\n", pos[1], pos[2])
    end
    @printf("Room: [0, %.1f] × [0, %.1f], door at x=%.1f, y∈[%.1f, %.1f]\n",
            room_W, room_H, room_W, door_lo, door_hi)
end

println("=== 3C Diagnostic: Stuck Agent Positions ===")
println("\nNormal speed (v₀=1.0):")
run_helbing_evacuation_debug(1.0f0; t_max=200f0)
println("\nPanic speed (v₀=4.0):")
run_helbing_evacuation_debug(4.0f0; t_max=200f0)
