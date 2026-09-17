# Phase 7B.3.1: Example Adapter Implementations
# Three concrete implementations demonstrating all model types

include("registry.jl")

"""
    TestEngine (mock type for examples)
Placeholder for simulated engine instance in examples.
"""
mutable struct TestEngine
    current_time::Float64
    running::Bool
    elements::Vector{Dict}
    entities::Vector{Dict}
end

# ============================================================================
# EXAMPLE 1: DES-ONLY ADAPTER (Manufacturing System)
# ============================================================================

"""
    ManufacturingAdapter <: SimulationAdapter

Example DES-only adapter for a manufacturing system.
- NO agent-based modeling
- Infrastructure: machines, stations, queues
- Mobile objects: parts, work orders
- Typical scale: 50-100 machines, 1000-5000 parts

This demonstrates:
- Declaring NoABM capability
- Extracting elements (machines with occupancy)
- Extracting entities (parts with trajectories)
- Dispatching commands to the DES engine
"""
mutable struct ManufacturingAdapter <: SimulationAdapter
    engine::TestEngine
    start_time::Float64
end

function ManufacturingAdapter(engine::TestEngine)
    return new(engine, 0.0)
end

function abm_capability(::ManufacturingAdapter)
    return NoABM()  # Manufacturing is pure DES
end

function get_simulation_time(adapter::ManufacturingAdapter)
    return adapter.engine.current_time
end

function get_elements_snapshot(adapter::ManufacturingAdapter)
    # Extract machines/stations as elements
    # In real implementation, would query adapter.engine for actual data
    return [
        ElementState(
            id=elem["id"],
            type=Symbol(elem["type"]),
            occupancy=elem["occupancy"],
            capacity=elem["capacity"],
            metrics=Dict(
                "queue_wait" => elem["avg_wait"],
                "throughput" => elem["parts_per_minute"]
            )
        )
        for elem in adapter.engine.elements
    ]
end

function get_entities_snapshot(adapter::ManufacturingAdapter)
    # Extract parts/work_orders as entities
    return [
        EntitySnapshot(
            id=ent["id"],
            position=Point(ent["x"], ent["y"]),
            trajectory=get_entity_trajectory(adapter, ent["id"]),
            entity_type=Symbol(ent["type"]),
            color=ent["color"],
            speed=ent["speed"],
            properties=Dict(
                "order_id" => ent["order_id"],
                "priority" => ent["priority"],
                "time_in_system" => adapter.engine.current_time - ent["start_time"]
            )
        )
        for ent in adapter.engine.entities
    ]
end

function dispatch_command(adapter::ManufacturingAdapter, cmd::Any)
    try
        if cmd.command_type == :play
            adapter.engine.running = true
            return Dict("success" => true, "message" => "Manufacturing simulation running")
        
        elseif cmd.command_type == :pause
            adapter.engine.running = false
            return Dict("success" => true, "message" => "Manufacturing simulation paused")
        
        elseif cmd.command_type == :step
            # Execute one step of DES
            # adapter.engine.step()
            return Dict("success" => true, "message" => "Step executed")
        
        elseif cmd.command_type == :reset
            adapter.engine.current_time = 0.0
            return Dict("success" => true, "message" => "Reset to t=0")
        
        else
            return Dict(
                "success" => false, 
                "error" => "Command $(cmd.command_type) not supported by Manufacturing adapter"
            )
        end
    catch e
        return Dict("success" => false, "error" => string(e))
    end
end

function get_entity_trajectory(adapter::ManufacturingAdapter, entity_id::Int)
    # In real implementation, would fetch from history storage
    return [Point(0.0, 0.0), Point(1.0, 1.0)]
end

# ============================================================================
# EXAMPLE 2: HYBRID ADAPTER (Shopping Mall with ABM)
# ============================================================================

"""
    ShoppingMallAdapter <: SimulationAdapter

Example hybrid DES+ABM adapter for a shopping mall simulation.
- HAS agent-based modeling for pedestrian dynamics
- DES elements: shops, elevators, restrooms
- ABM agents: customers, employees
- Typical scale: 20-50 locations, 500-2000 agents

This demonstrates:
- Declaring SupportsABM capability
- Extracting elements from DES subsystem
- Extracting entities (customers) from ABM
- Providing ABM population state
- Dispatching commands to hybrid engine
"""
mutable struct ShoppingMallAdapter <: SimulationAdapter
    des_engine::TestEngine      # DES for shops/services
    abm_model::Any              # ABM for customers/pedestrians
    start_time::Float64
end

function ShoppingMallAdapter(des_engine::TestEngine, abm_model::Any)
    return new(des_engine, abm_model, 0.0)
end

function abm_capability(::ShoppingMallAdapter)
    return SupportsABM()  # Has both DES and ABM
end

function get_simulation_time(adapter::ShoppingMallAdapter)
    return adapter.des_engine.current_time
end

function get_elements_snapshot(adapter::ShoppingMallAdapter)
    # Extract shops, elevators, etc as elements
    return [
        ElementState(
            id=elem["id"],
            type=Symbol(elem["type"]),
            occupancy=elem["occupancy"],
            capacity=elem["capacity"],
            metrics=Dict(
                "attractiveness" => elem["attractiveness"],
                "traffic_flow" => elem["customer_flow"]
            )
        )
        for elem in adapter.des_engine.elements
    ]
end

function get_entities_snapshot(adapter::ShoppingMallAdapter)
    # Customers are entities (moved via ABM physics)
    return [
        EntitySnapshot(
            id=ent["id"],
            position=Point(ent["x"], ent["y"]),
            trajectory=get_entity_trajectory(adapter, ent["id"]),
            entity_type=:customer,
            color=ent["color"],
            speed=ent["speed"],
            properties=Dict(
                "destination" => ent["current_shop"],
                "shopping_list" => ent["num_items_needed"],
                "fatigue" => ent["fatigue"]
            )
        )
        for ent in adapter.abm_model.agents
    ]
end

function get_abm_snapshot(adapter::ShoppingMallAdapter)
    # Provide agent-specific population statistics
    agents_data = [
        Dict(
            "id" => agent["id"],
            "energy" => agent["energy"],
            "shopping_status" => agent["status"],
            "spent" => agent["money_spent"]
        )
        for agent in adapter.abm_model.agents
    ]
    
    # Spatial density: count agents per mall zone
    spatial_density = Dict()
    for agent in adapter.abm_model.agents
        zone = (Int(agent["x"] ÷ 10), Int(agent["y"] ÷ 10))  # 10x10 zones
        spatial_density[zone] = get(spatial_density, zone, 0) + 1
    end
    
    total_spent = sum(agent["money_spent"] for agent in adapter.abm_model.agents)
    avg_energy = mean(agent["energy"] for agent in adapter.abm_model.agents)
    
    return ABMStateSnapshot(
        agents=agents_data,
        spatial_density=spatial_density,
        properties=Dict(
            "total_agents" => length(adapter.abm_model.agents),
            "total_spent" => total_spent,
            "average_energy" => avg_energy,
            "shopping_completion" => sum(
                agent["status"] == :done for agent in adapter.abm_model.agents
            )
        )
    )
end

function dispatch_command(adapter::ShoppingMallAdapter, cmd::Any)
    try
        if cmd.command_type == :play
            adapter.des_engine.running = true
            return Dict("success" => true, "message" => "Shopping Mall simulation running")
        
        elseif cmd.command_type == :pause
            adapter.des_engine.running = false
            return Dict("success" => true, "message" => "Shopping Mall simulation paused")
        
        else
            return Dict(
                "success" => false,
                "error" => "Command $(cmd.command_type) not supported by ShoppingMall adapter"
            )
        end
    catch e
        return Dict("success" => false, "error" => string(e))
    end
end

function get_entity_trajectory(adapter::ShoppingMallAdapter, entity_id::Int)
    # In real implementation, would fetch from ABM history
    return [Point(10.0, 10.0), Point(11.0, 10.5), Point(12.0, 11.0)]
end

# ============================================================================
# EXAMPLE 3: PURE ABM ADAPTER (Epidemic Model)
# ============================================================================

"""
    EpidemicAdapter <: SimulationAdapter

Example pure ABM adapter for epidemic modeling.
- NO discrete event simulation
- All dynamics via agent-based modeling
- Agents: susceptible, infected, recovered individuals
- Spatial dynamics: infection spread, movement patterns
- Typical scale: 1000-100000 agents

This demonstrates:
- Declaring SupportsABM capability (only ABM, no DES)
- Extracting populations as entities
- Providing rich ABM state (infection dynamics)
- No elements (only agents)
"""
mutable struct EpidemicAdapter <: SimulationAdapter
    abm_model::Any  # Pure ABM for agents
    start_time::Float64
end

function EpidemicAdapter(abm_model::Any)
    return new(abm_model, 0.0)
end

function abm_capability(::EpidemicAdapter)
    return SupportsABM()  # Pure ABM, but trait says supports (which is true)
end

function get_simulation_time(adapter::EpidemicAdapter)
    return adapter.abm_model.time
end

function get_elements_snapshot(adapter::EpidemicAdapter)
    # Pure ABM has no infrastructure elements
    return ElementState[]
end

function get_entities_snapshot(adapter::EpidemicAdapter)
    # All entities are agents (individuals in population)
    return [
        EntitySnapshot(
            id=agent["id"],
            position=Point(agent["x"], agent["y"]),
            trajectory=get_entity_trajectory(adapter, agent["id"]),
            entity_type=Symbol(agent["status"]),  # :susceptible, :infected, :recovered
            color=agent["color"],
            speed=agent["speed"],
            properties=Dict(
                "status" => agent["status"],
                "infection_time" => agent["infection_time"],
                "contacts_today" => agent["contacts"]
            )
        )
        for agent in adapter.abm_model.agents
    ]
end

function get_abm_snapshot(adapter::EpidemicAdapter)
    # Detailed epidemic dynamics
    agents_data = [
        Dict(
            "id" => agent["id"],
            "status" => agent["status"],
            "infection_time" => agent["infection_time"],
            "contacts" => agent["contacts"]
        )
        for agent in adapter.abm_model.agents
    ]
    
    # Spatial hotspots (areas with high infection)
    spatial_density = Dict()
    for agent in adapter.abm_model.agents
        zone = (Int(agent["x"] ÷ 5), Int(agent["y"] ÷ 5))  # 5x5 zones
        if !haskey(spatial_density, zone)
            spatial_density[zone] = Dict("total" => 0, "infected" => 0)
        end
        spatial_density[zone]["total"] += 1
        if agent["status"] == :infected
            spatial_density[zone]["infected"] += 1
        end
    end
    
    susceptible = sum(agent["status"] == :susceptible for agent in adapter.abm_model.agents)
    infected = sum(agent["status"] == :infected for agent in adapter.abm_model.agents)
    recovered = sum(agent["status"] == :recovered for agent in adapter.abm_model.agents)
    
    return ABMStateSnapshot(
        agents=agents_data,
        spatial_density=spatial_density,
        properties=Dict(
            "susceptible_count" => susceptible,
            "infected_count" => infected,
            "recovered_count" => recovered,
            "r_value" => adapter.abm_model.r_value,  # Infection rate
            "average_contacts" => mean(agent["contacts"] for agent in adapter.abm_model.agents)
        )
    )
end

function dispatch_command(adapter::EpidemicAdapter, cmd::Any)
    try
        if cmd.command_type == :play
            adapter.abm_model.running = true
            return Dict("success" => true, "message" => "Epidemic simulation running")
        
        elseif cmd.command_type == :pause
            adapter.abm_model.running = false
            return Dict("success" => true, "message" => "Epidemic simulation paused")
        
        elseif cmd.command_type == :step
            # Step the ABM
            return Dict("success" => true, "message" => "ABM step executed")
        
        else
            return Dict(
                "success" => false,
                "error" => "Command $(cmd.command_type) not supported by Epidemic adapter"
            )
        end
    catch e
        return Dict("success" => false, "error" => string(e))
    end
end

function get_entity_trajectory(adapter::EpidemicAdapter, entity_id::Int)
    # In real implementation, would fetch from agent history
    return [Point(50.0, 50.0), Point(50.5, 50.2), Point(51.0, 50.4)]
end

export ManufacturingAdapter, ShoppingMallAdapter, EpidemicAdapter
export TestEngine
