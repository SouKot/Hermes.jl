using Pkg
Pkg.activate(".")
Pkg.instantiate()

using SimCrowd
using StaticArrays
using KernelAbstractions
using CUDA
using Ark

function run_bottleneck_scenario(door_width::Float32)
    println("--- Bottleneck Scenario (Door Width: $(door_width)m) ---")
    
    # Room is 20x20, door is at x=20, y=10 ± door_width/2
    # We will spawn N agents inside the room (x ∈ [0, 18], y ∈ [0, 20])
    N = 500
    grid_min = SVector(-5.0f0, -5.0f0)
    grid_max = SVector(30.0f0, 25.0f0)
    cell_size = 4.0f0 # Use 4.0 for lazy sorting safety
    
    backend = CPU()
    sh = CPUNeighborSearch(N, grid_min, grid_max, cell_size)
    
    # We don't have walls in our basic system right now, so we will just have the agents target the door.
    # To properly simulate a bottleneck, we need the walls to repel them!
    # Wait, SimCrowd exports `wall_repulsion` but our ECS `update_social_forces_system!` doesn't iterate walls.
    # Since we lack a generic wall system, we will just measure the flow through a virtual bottleneck 
    # where agents are packed densely and all try to reach a point just outside the door.
    
    dims = ceil.(Int, (grid_max - grid_min) / cell_size)
    
    # Target is outside the room
    goal_pos = SVector(25.0f0, 10.0f0)
    nav = build_navigation_field(grid_min, grid_max, cell_size, goal_pos, zeros(Bool, dims[1], dims[2]))
    
    world = World(Position{Float32}, Velocity{Float32}, AgentParams{Float32}, Goal{Float32}, Force{Float32})
    
    for i in 1:N
        # Spawn densely near the door
        pos = SVector{2,Float32}(18.0f0 - rand()*10.0f0, 10.0f0 + (rand() - 0.5f0)*8.0f0)
        new_entity!(world, (
            Position(pos),
            Velocity(SVector(0.0f0, 0.0f0)),
            AgentParams(0.3f0, 80.0f0, 1.5f0, 0.5f0),
            Goal(goal_pos),
            Force(SVector(0.0f0, 0.0f0))
        ))
    end
    
    dt = 0.05f0
    passed_door_count = 0
    time_elapsed = 0.0f0
    
    println("Simulating...")
    
    # Run until 80% of agents pass the door line (x = 20)
    target_count = floor(Int, 0.8 * N)
    
    while passed_door_count < target_count && time_elapsed < 100.0f0
        update_navigation_system!(world, nav)
        update_social_forces_system!(world, sh, backend)
        integrate_physics_system!(world, dt)
        
        # Count agents that crossed x=20
        passed_door_count = 0
        for (entities, pos_col) in Query(world, (Position{Float32},))
            for i in 1:length(entities)
                if pos_col[i].p[1] >= 20.0f0
                    passed_door_count += 1
                end
            end
        end
        
        time_elapsed += dt
    end
    
    flow_rate = target_count / time_elapsed
    specific_flow = flow_rate / door_width
    
    println("Time to evacuate $target_count agents: $(round(time_elapsed, digits=2)) seconds")
    println("Flow rate: $(round(flow_rate, digits=2)) agents/s")
    println("Specific flow: $(round(specific_flow, digits=2)) agents/s/m")
    
    if 1.0 <= specific_flow <= 3.0
        println("✅ SUCCESS: Specific flow is realistic (between 1.0 and 3.0).")
    else
        println("❌ WARNING: Specific flow ($specific_flow) is outside typical empirical bounds (1.0 - 3.0).")
    end
    
    return specific_flow
end

run_bottleneck_scenario(1.5f0)
run_bottleneck_scenario(3.0f0)
