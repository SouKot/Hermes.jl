# Tests for Phase 7B.3.1: Adapter Interface System

using Test
using GodotBridge

# Mock types for testing
struct MockSimulationCommand
    command_type::Symbol
    param::Any
end

struct MockCommandResult
    success::Bool
    message::String = ""
    error::String = ""
end

@testset "Phase 7B.3.1: Adapter Interface System" begin
    
    # ========================================================================
    # TEST SUITE 1: TRAIT SYSTEM
    # ========================================================================
    
    @testset "Trait System" begin
        
        @testset "ABM Trait Types" begin
            # NoABM instance
            no_abm = NoABM()
            @test no_abm isa ABMCapability
            
            # SupportsABM instance
            supports_abm = SupportsABM()
            @test supports_abm isa ABMCapability
            
            # Distinguish between them
            @test no_abm isa NoABM
            @test supports_abm isa SupportsABM
            @test !(no_abm isa SupportsABM)
            @test !(supports_abm isa NoABM)
        end
        
        @testset "Protocol Version Trait" begin
            v1 = V1()
            @test v1 isa ProtocolVersion
        end
        
        @testset "Feature Capability Traits" begin
            gpu = SupportsGPU()
            replay = SupportsReplay()
            parallel = SupportsParallelism()
            
            @test gpu isa FeatureCapability
            @test replay isa FeatureCapability
            @test parallel isa FeatureCapability
            
            @test gpu isa SupportsGPU
            @test !(gpu isa SupportsReplay)
        end
        
        @testset "has_feature defaults to false" begin
            @test !has_feature(nothing, SupportsGPU)
            @test !has_feature(nothing, SupportsReplay)
            @test !has_feature(nothing, SupportsParallelism)
        end
        
        @testset "protocol_version defaults to V1" begin
            @test protocol_version(nothing) == V1
        end
    end
    
    # ========================================================================
    # TEST SUITE 2: ADAPTER REGISTRY
    # ========================================================================
    
    @testset "Adapter Registry" begin
        
        @testset "register_adapter" begin
            clear_adapter_registry()
            register_adapter("Test", ManufacturingAdapter)
            
            # Check it's registered
            @test "Test" in list_registered_adapters()
        end
        
        @testset "create_adapter" begin
            clear_adapter_registry()
            register_adapter("Test", ManufacturingAdapter)
            
            engine = TestEngine(0.0, false, [], [])
            adapter = create_adapter("Test", engine)
            
            @test adapter isa ManufacturingAdapter
            @test adapter.engine === engine
        end
        
        @testset "get_active_adapter" begin
            clear_adapter_registry()
            register_adapter("Test", ManufacturingAdapter)
            
            engine = TestEngine(0.0, false, [], [])
            created = create_adapter("Test", engine)
            active = get_active_adapter()
            
            @test active === created
        end
        
        @testset "get_adapter by name" begin
            clear_adapter_registry()
            register_adapter("Test", ManufacturingAdapter)
            
            engine = TestEngine(0.0, false, [], [])
            create_adapter("Test", engine)
            
            retrieved = get_adapter("Test")
            @test retrieved isa ManufacturingAdapter
        end
        
        @testset "list_registered_adapters" begin
            clear_adapter_registry()
            
            register_adapter("Mfg", ManufacturingAdapter)
            register_adapter("Mall", ShoppingMallAdapter)
            register_adapter("Epi", EpidemicAdapter)
            
            adapters = list_registered_adapters()
            @test length(adapters) == 3
            @test "Mfg" in adapters
            @test "Mall" in adapters
            @test "Epi" in adapters
        end
        
        @testset "list_active_instances" begin
            clear_adapter_registry()
            register_adapter("Mfg", ManufacturingAdapter)
            register_adapter("Epi", EpidemicAdapter)
            
            engine = TestEngine(0.0, false, [], [])
            create_adapter("Mfg", engine)
            create_adapter("Epi", Dict())
            
            instances = list_active_instances()
            @test length(instances) == 2
            @test "Mfg" in instances
            @test "Epi" in instances
        end
        
        @testset "set_active_adapter" begin
            clear_adapter_registry()
            register_adapter("Mfg", ManufacturingAdapter)
            register_adapter("Epi", EpidemicAdapter)
            
            engine = TestEngine(0.0, false, [], [])
            mfg_adapter = create_adapter("Mfg", engine)
            epi_adapter = create_adapter("Epi", Dict())
            
            @test get_active_adapter() === epi_adapter
            
            set_active_adapter("Mfg")
            @test get_active_adapter() === mfg_adapter
        end
        
        @testset "Error handling: register duplicate" begin
            clear_adapter_registry()
            register_adapter("Test", ManufacturingAdapter)
            
            @test_throws ErrorException register_adapter("Test", ManufacturingAdapter)
        end
        
        @testset "Error handling: create unregistered" begin
            clear_adapter_registry()
            
            @test_throws ErrorException create_adapter("NonExistent", nothing)
        end
        
        @testset "Error handling: get unregistered instance" begin
            clear_adapter_registry()
            
            @test_throws ErrorException get_adapter("NonExistent")
        end
        
        @testset "Error handling: get_active_adapter with none created" begin
            clear_adapter_registry()
            
            @test_throws ErrorException get_active_adapter()
        end
        
        @testset "Error handling: set_active_adapter nonexistent" begin
            clear_adapter_registry()
            
            @test_throws ErrorException set_active_adapter("NonExistent")
        end
        
        @testset "clear_adapter_registry clears all" begin
            clear_adapter_registry()
            register_adapter("Test", ManufacturingAdapter)
            engine = TestEngine(0.0, false, [], [])
            create_adapter("Test", engine)
            
            @test length(list_registered_adapters()) == 1
            @test length(list_active_instances()) == 1
            
            clear_adapter_registry()
            
            @test length(list_registered_adapters()) == 0
            @test length(list_active_instances()) == 0
        end
    end
    
    # ========================================================================
    # TEST SUITE 3: MANUFACTURING ADAPTER (DES-Only)
    # ========================================================================
    
    @testset "ManufacturingAdapter (DES-Only)" begin
        clear_adapter_registry()
        register_adapter("Mfg", ManufacturingAdapter)
        
        engine = TestEngine(0.0, false, 
            [Dict("id" => 1, "type" => "station", "occupancy" => 5, 
                  "capacity" => 10, "avg_wait" => 2.3, "parts_per_minute" => 0.5)],
            [Dict("id" => 101, "type" => "part", "x" => 10.5, "y" => 20.3,
                  "color" => :blue, "speed" => 0.5, "order_id" => 1, 
                  "priority" => 1, "start_time" => -10.0)]
        )
        
        adapter = create_adapter("Mfg", engine)
        
        @testset "abm_capability returns NoABM" begin
            cap = abm_capability(adapter)
            @test cap isa NoABM
        end
        
        @testset "get_simulation_time" begin
            @test get_simulation_time(adapter) == 0.0
            
            adapter.engine.current_time = 100.5
            @test get_simulation_time(adapter) == 100.5
        end
        
        @testset "get_elements_snapshot" begin
            elements = get_elements_snapshot(adapter)
            
            @test length(elements) == 1
            @test elements[1].id == 1
            @test elements[1].type == :station
            @test elements[1].occupancy == 5
            @test elements[1].capacity == 10
            @test haskey(elements[1].metrics, "queue_wait")
        end
        
        @testset "get_entities_snapshot" begin
            entities = get_entities_snapshot(adapter)
            
            @test length(entities) == 1
            @test entities[1].id == 101
            @test entities[1].entity_type == :part
            @test entities[1].speed == 0.5
            @test haskey(entities[1].properties, "order_id")
            @test haskey(entities[1].properties, "time_in_system")
        end
        
        @testset "get_abm_snapshot returns nothing" begin
            # Should not be called for NoABM, but if it is, returns nothing
            result = get_abm_snapshot(adapter)
            @test result === nothing
        end
        
        @testset "dispatch_command: play" begin
            cmd = MockSimulationCommand(:play, 1)
            result = dispatch_command(adapter, cmd)
            @test result.success == true
            @test adapter.engine.running == true
        end
        
        @testset "dispatch_command: pause" begin
            adapter.engine.running = true
            cmd = MockSimulationCommand(:pause, 1)
            result = dispatch_command(adapter, cmd)
            @test result.success == true
            @test adapter.engine.running == false
        end
        
        @testset "dispatch_command: reset" begin
            adapter.engine.current_time = 100.0
            cmd = MockSimulationCommand(:reset, 1)
            result = dispatch_command(adapter, cmd)
            @test result.success == true
            @test adapter.engine.current_time == 0.0
        end
        
        @testset "dispatch_command: unsupported" begin
            cmd = MockSimulationCommand(:query_state, 1)
            result = dispatch_command(adapter, cmd)
            @test result.success == false
            @test contains(result.error, "not supported")
        end
    end
    
    # ========================================================================
    # TEST SUITE 4: ADAPTER POLYMORPHISM
    # ========================================================================
    
    @testset "Adapter Polymorphism" begin
        clear_adapter_registry()
        
        register_adapter("Mfg", ManufacturingAdapter)
        
        engine = TestEngine(0.0, false, [], [])
        mfg = create_adapter("Mfg", engine)
        
        @testset "All adapters implement required interface" begin
            @test applicable(abm_capability, mfg)
            @test applicable(get_simulation_time, mfg)
            @test applicable(get_elements_snapshot, mfg)
            @test applicable(get_entities_snapshot, mfg)
            @test applicable(dispatch_command, mfg)
        end
        
        @testset "Generic adapter function" begin
            # Function that works with any adapter
            function test_adapter_generic(adapter::SimulationAdapter)
                time = get_simulation_time(adapter)
                elements = get_elements_snapshot(adapter)
                entities = get_entities_snapshot(adapter)
                
                # Only query ABM if supported
                if abm_capability(adapter) isa SupportsABM
                    abm = get_abm_snapshot(adapter)
                    return (time, length(elements), length(entities), abm !== nothing)
                else
                    return (time, length(elements), length(entities), false)
                end
            end
            
            result = test_adapter_generic(mfg)
            @test result[4] == false  # No ABM for manufacturing
        end
    end
end
