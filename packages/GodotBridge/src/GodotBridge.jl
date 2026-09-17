"""
    GodotBridge.jl

Julia WebSocket server for communicating with Godot 4 visualization engine.

This package implements Protocol v1 for bidirectional communication between
a Julia simulation runtime and a Godot GUI. The protocol uses MessagePack
for production wire traffic and provides JSON debugging support.

**Key Components**:
- Protocol types (Message, Envelope, Payload types)
- MessagePack serialization (production)
- JSON debug output (development/diagnostics only)
- WebSocket server scaffold
- Snapshot and command handlers

**Design Philosophy**:
- MessagePack is the ONLY production serialization format
- JSON exists strictly for debugging and diagnostics
- No automatic format switching or fallback to JSON in production
- Type-stable for high performance
"""
module GodotBridge

# Protocol module
include("protocol/envelope.jl")
include("protocol/serialization.jl")
include("protocol/debug.jl")
include("snapshot/snapshot_builder.jl")

# Adapter module (Phase 7B.3)
include("adapters/traits.jl")
include("adapters/interface.jl")
include("adapters/registry.jl")
include("adapters/examples.jl")

# Extraction module (Phase 7B.3.2)
include("extraction/element_cache.jl")
include("extraction/parallel_elements.jl")
include("extraction/ring_buffer.jl")
include("extraction/entity_batch.jl")

# Command execution module (Phase 7B.3.3)
include("commands/futures.jl")
include("commands/thread_pool.jl")

# Server module
include("server/websocket_server.jl")

# Re-export key protocol items
export Message, MessageEnvelope, MessagePayload
export HelloPayload, SnapshotPayload, DeltaPayload, CommandPayload
export SceneSpecPayload, AckPayload, ErrorPayload
export create_hello, create_ack, create_error
export encode_messagepack, decode_messagepack
export to_debug_json, log_message_debug

# Re-export adapter items
export SimulationAdapter
export abm_capability, get_simulation_time
export get_elements_snapshot, get_entities_snapshot, get_abm_snapshot
export dispatch_command
export ABMCapability, NoABM, SupportsABM
export FeatureCapability, SupportsGPU, SupportsReplay, SupportsParallelism
export register_adapter, create_adapter, get_active_adapter, get_adapter
export list_registered_adapters, list_active_instances, set_active_adapter
export clear_adapter_registry
export ManufacturingAdapter, ShoppingMallAdapter, EpidemicAdapter
export ElementState, EntitySnapshot, ABMStateSnapshot
export ElementStateCache, get_cached_element, clear_expired, clear_expired!
export clear!, cache_stats, extract_elements_parallel, extract_elements_cached
export TrajectoryRingBuffer, add_point!, add_point, trajectory, get_trajectory
export memory_usage, extract_entities_vectorized, batch_get_trajectories
export CommandWorkerPool, start_pool!, stop_pool!, submit_command
export CommandFuture, is_command_ready, wait_result, command_latency
export get_latency_stats

# Re-export server items
export GodotBridgeServer
export start, stop
export register_handler!, broadcast_snapshot
export num_connected_clients, is_server_running

# Version info
const VERSION = v"0.1.0"

end # module GodotBridge
