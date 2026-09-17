# Phase 7B.3.1: Adapter Registry & Factory
# Global registry for managing multiple simulation adapters

if !isdefined(@__MODULE__, :SimulationAdapter)
    include("interface.jl")
end

"""
    AdapterRegistry

Thread-safe registry for managing simulation adapters.

Adapters must be registered before they can be created and used by the bridge.
This allows:
- Multiple adapters loaded simultaneously (useful for testing)
- Dynamic adapter discovery at runtime
- Adapter versioning and compatibility checking

Usage:
    register_adapter("Manufacturing", ManufacturingAdapter)
    adapter = create_adapter("Manufacturing", engine_instance)
"""
mutable struct AdapterRegistry
    adapters::Dict{String, Type{<:SimulationAdapter}}
    instances::Dict{String, SimulationAdapter}
    active_instance::Union{String, Nothing}
    lock::ReentrantLock
    
    AdapterRegistry() = new(Dict(), Dict(), nothing, ReentrantLock())
end

"""
    GLOBAL_ADAPTER_REGISTRY::AdapterRegistry

Global instance of the adapter registry.
All adapters in the application register here.
"""
const GLOBAL_ADAPTER_REGISTRY = AdapterRegistry()

"""
    register_adapter(name::String, adapter_type::Type{<:SimulationAdapter})

Register an adapter class in the global registry.

After registration, the adapter can be instantiated with create_adapter(name, args...).
Thread-safe: uses lock to prevent race conditions.

Args:
    name: Unique identifier for this adapter (e.g., "Manufacturing", "EpidemicModel")
    adapter_type: The Julia type that implements SimulationAdapter

Raises:
    ErrorException if an adapter with this name already exists

Example:
    struct ManufacturingAdapter <: SimulationAdapter
        engine::Any
    end
    
    register_adapter("Manufacturing", ManufacturingAdapter)
"""
function register_adapter(name::String, adapter_type::Type{<:SimulationAdapter})
    lock(GLOBAL_ADAPTER_REGISTRY.lock) do
        if haskey(GLOBAL_ADAPTER_REGISTRY.adapters, name)
            error("Adapter '$name' already registered. " *
                  "Available: $(keys(GLOBAL_ADAPTER_REGISTRY.adapters))")
        end
        GLOBAL_ADAPTER_REGISTRY.adapters[name] = adapter_type
    end
end

"""
    create_adapter(name::String, args...)::SimulationAdapter

Instantiate a registered adapter by name.

Looks up the adapter in the registry and creates a new instance.
The new instance is stored in the registry and marked as active.
Thread-safe: uses lock for concurrent instantiation.

Args:
    name: Name previously passed to register_adapter()
    args...: Arguments to pass to the adapter's constructor

Returns:
    New instance of the adapter

Raises:
    ErrorException if adapter name not registered

Example:
    adapter = create_adapter("Manufacturing", engine_instance)
    
    # Later, retrieve the same instance:
    active = get_active_adapter()
"""
function create_adapter(name::String, args...)
    lock(GLOBAL_ADAPTER_REGISTRY.lock) do
        if !haskey(GLOBAL_ADAPTER_REGISTRY.adapters, name)
            available = join(keys(GLOBAL_ADAPTER_REGISTRY.adapters), ", ")
            error("Adapter '$name' not registered. Available: [$available]")
        end
        
        adapter_type = GLOBAL_ADAPTER_REGISTRY.adapters[name]
        instance = adapter_type(args...)
        
        GLOBAL_ADAPTER_REGISTRY.instances[name] = instance
        GLOBAL_ADAPTER_REGISTRY.active_instance = name
        
        return instance
    end
end

"""
    get_active_adapter()::SimulationAdapter

Retrieve the currently active simulation adapter.

The "active" adapter is the most recently created instance.
Useful when only one simulation should be running at a time.

Returns:
    The active SimulationAdapter instance

Raises:
    ErrorException if no adapters have been created

Example:
    create_adapter("Manufacturing", engine)
    active = get_active_adapter()  # Returns the Manufacturing adapter
"""
function get_active_adapter()
    lock(GLOBAL_ADAPTER_REGISTRY.lock) do
        if isnothing(GLOBAL_ADAPTER_REGISTRY.active_instance)
            error("No active adapter. Create one with create_adapter(name, args...).")
        end
        
        name = GLOBAL_ADAPTER_REGISTRY.active_instance
        return GLOBAL_ADAPTER_REGISTRY.instances[name]
    end
end

"""
    get_adapter(name::String)::SimulationAdapter

Retrieve a specific adapter instance by name.

Returns the previously created instance, or error if not found.

Args:
    name: Name of adapter to retrieve

Returns:
    The SimulationAdapter instance with given name

Raises:
    ErrorException if no instance with that name exists

Example:
    adapter1 = create_adapter("Manufacturing", engine1)
    adapter2 = create_adapter("Epidemic", engine2)
    
    mfg = get_adapter("Manufacturing")  # Returns adapter1
    epi = get_adapter("Epidemic")       # Returns adapter2
"""
function get_adapter(name::String)
    lock(GLOBAL_ADAPTER_REGISTRY.lock) do
        if !haskey(GLOBAL_ADAPTER_REGISTRY.instances, name)
            available = join(keys(GLOBAL_ADAPTER_REGISTRY.instances), ", ")
            error("No instance of adapter '$name'. Available: [$available]")
        end
        
        return GLOBAL_ADAPTER_REGISTRY.instances[name]
    end
end

"""
    list_registered_adapters()::Vector{String}

List all registered adapter types.

Returns:
    Vector of adapter names that have been register_adapter()'d

Example:
    register_adapter("Manufacturing", ManufacturingAdapter)
    register_adapter("Epidemic", EpidemicAdapter)
    
    list_registered_adapters()  # Returns ["Manufacturing", "Epidemic"]
"""
function list_registered_adapters()
    lock(GLOBAL_ADAPTER_REGISTRY.lock) do
        return collect(keys(GLOBAL_ADAPTER_REGISTRY.adapters))
    end
end

"""
    list_active_instances()::Vector{String}

List all instantiated adapters.

Returns:
    Vector of adapter instance names that have been create_adapter()'d

Example:
    create_adapter("Manufacturing", engine1)
    create_adapter("Epidemic", engine2)
    
    list_active_instances()  # Returns ["Manufacturing", "Epidemic"]
"""
function list_active_instances()
    lock(GLOBAL_ADAPTER_REGISTRY.lock) do
        return collect(keys(GLOBAL_ADAPTER_REGISTRY.instances))
    end
end

"""
    set_active_adapter(name::String)

Manually set which adapter is "active".

Normally, create_adapter() automatically sets active to the newly created
instance. This function allows switching between multiple adapters.

Args:
    name: Name of an existing instance to make active

Raises:
    ErrorException if instance doesn't exist

Example:
    create_adapter("Manufacturing", engine1)
    create_adapter("Epidemic", engine2)
    
    set_active_adapter("Manufacturing")
    get_active_adapter()  # Returns Manufacturing adapter
    
    set_active_adapter("Epidemic")
    get_active_adapter()  # Returns Epidemic adapter
"""
function set_active_adapter(name::String)
    lock(GLOBAL_ADAPTER_REGISTRY.lock) do
        if !haskey(GLOBAL_ADAPTER_REGISTRY.instances, name)
            error("No instance '$name'. Create it with create_adapter() first.")
        end
        
        GLOBAL_ADAPTER_REGISTRY.active_instance = name
    end
end

"""
    clear_adapter_registry()

Remove all registered adapters and instances.

Useful for testing or resetting the system to a clean state.
WARNING: This is destructive - all adapter references will be invalid after this call.

Example:
    register_adapter("Test", TestAdapter)
    create_adapter("Test", test_engine)
    
    clear_adapter_registry()
    
    list_registered_adapters()  # Returns []
    list_active_instances()     # Returns []
"""
function clear_adapter_registry()
    lock(GLOBAL_ADAPTER_REGISTRY.lock) do
        empty!(GLOBAL_ADAPTER_REGISTRY.adapters)
        empty!(GLOBAL_ADAPTER_REGISTRY.instances)
        GLOBAL_ADAPTER_REGISTRY.active_instance = nothing
    end
end

export AdapterRegistry, GLOBAL_ADAPTER_REGISTRY
export register_adapter, create_adapter, get_active_adapter, get_adapter
export list_registered_adapters, list_active_instances, set_active_adapter
export clear_adapter_registry
