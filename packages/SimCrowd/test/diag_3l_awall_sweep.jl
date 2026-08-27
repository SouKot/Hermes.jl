using SimCrowd, Ark, StaticArrays, LinearAlgebra, Printf, Random

include(joinpath(@__DIR__, "crowd_test_helpers.jl"))

const F = Float32
const N = 80; const ROOM_L=10f0; const ROOM_W=4f0; const DOOR_CY=2f0; const DOOR_HALF=0.5f0
const GOAL_PT = SVector(12f0, DOOR_CY)

function make_v2_world(a_wall::F)
    p = CSMParams_V2(F; a_neighbor=F(8), D_neighbor=F(0.2), T=F(0.8), a_wall=a_wall)
    world = World(Position{F}, Velocity{F}, Goal{F}, CSMParams{F}, WallSegment{F})
    dc=DOOR_CY; dh=DOOR_HALF
    new_entity!(world, (WallSegment(SVector(0f0,0f0), SVector(0f0,ROOM_W)),))
    new_entity!(world, (WallSegment(SVector(0f0,0f0), SVector(ROOM_L,0f0)),))
    new_entity!(world, (WallSegment(SVector(0f0,ROOM_W), SVector(ROOM_L,ROOM_W)),))
    new_entity!(world, (WallSegment(SVector(ROOM_L,0f0), SVector(ROOM_L,dc-dh)),))
    new_entity!(world, (WallSegment(SVector(ROOM_L,dc+dh), SVector(ROOM_L,ROOM_W)),))
    rng = MersenneTwister(42)
    cols = max(1, ceil(Int, sqrt(N*9f0/3.4f0))); rows = ceil(Int, N/cols)
    sp_x = 9f0/(cols+1); sp_y = 3.4f0/(rows+1)
    for k in 1:N
        row=(k-1)÷cols; col=(k-1)%cols
        x = 0.5f0+(col+1)*sp_x+0.05f0*(rand(rng,F)-0.5f0)
        y = 0.3f0+(row+1)*sp_y+0.05f0*(rand(rng,F)-0.5f0)
        x = clamp(x,0.3f0,9.7f0); y = clamp(y,0.3f0,3.7f0)
        new_entity!(world, (Position(SVector(x,y)), Velocity(zero(SVector{2,F})), Goal(GOAL_PT), p))
    end
    return world
end

cfg = CSMBottleneckConfig{F}()
println("\n=== V2 a_wall sweep (a_nbr=8, D_nbr=0.2, T=0.8, lateral filter) ===")
println("a_wall   flow(p/s)  t_exit   passed  status")
for a_wall in [F(0.0), F(0.3), F(0.5), F(1.0), F(1.5), F(2.0), F(3.0)]
    w = make_v2_world(a_wall)
    r = run_csm_bottleneck!(w, cfg)
    status = r.deadlock ? "DEADLOCK" : (r.flow_rate >= 1.22f0 ? "OK✅" : "low")
    @printf("  %-6.1f   %-9.3f  %-7.1f  %-6d  %s\n",
            a_wall, r.flow_rate, r.t_exit, r.n_passed, status)
end
println("\n(V1 reference: flow=1.453 ped/s, target ≥ 1.22)")
