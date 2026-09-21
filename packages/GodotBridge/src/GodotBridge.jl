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
include("protocol/scenespec.jl")
include("protocol/scenespec_types.jl")
include("protocol/scenespec_normalization.jl")
include("protocol/scenespec_validator.jl")
include("protocol/scenespec_extensions.jl")
include("protocol/serialization.jl")
include("protocol/direct_delta.jl")
include("protocol/debug.jl")
include("snapshot/snapshot_builder.jl")
include("protocol/direct_snapshot.jl")
include("snapshot/delta_builder.jl")

# Adapter module (Phase 7B.3)
include("adapters/traits.jl")
include("adapters/interface.jl")
include("adapters/dirty_state.jl")
include("adapters/registry.jl")
include("adapters/examples.jl")

# Extraction module (Phase 7B.3.2)
include("extraction/element_cache.jl")
include("extraction/parallel_elements.jl")
include("extraction/ring_buffer.jl")
include("extraction/entity_batch.jl")
include("extraction/dense_numeric.jl")

# Command execution module (Phase 7B.3.3)
include("commands/futures.jl")
include("commands/thread_pool.jl")

# Adaptive update module (Phase 7B.3.4)
include("updates/efficiency_tracker.jl")
include("updates/incremental_cache.jl")
include("updates/adaptive_builder.jl")

# Profiling module (adapter-specific measurement)
include("profiling/adapter_profiler.jl")

# Server module
include("server/websocket_server.jl")

# Re-export key protocol items
export Message, MessageEnvelope, MessagePayload
export HelloPayload, SnapshotPayload, DeltaPayload, CommandPayload
export SceneSpecPayload, AckPayload, ErrorPayload
export SceneSpec, parse_scenespec, scenespec_to_dict
export encode_scenespec_json, decode_scenespec_json
export encode_scenespec_msgpack, decode_scenespec_msgpack
export scenespec_semantic_equal
export LibraryRequirement, SceneMetadata, SimulationConfig, ABMConfig
export SpatialLevel, SpatialConfig, TransformRecord, GeometryRecord, EditorMetadata
export PortRecord, ElementRecord, ConnectionRecord, SubgraphRecord, DiagnosticRecord
export ValidationMetadataRecord, OverlayRecord, TypedSceneSpec
export to_typed_scenespec, to_payload, parse_typed_scenespec, migrate_scenespec
export validate_scenespec, apply_validation!, is_scene_valid
export get_extension, set_extension!, has_extension, delete_extension!, list_extensions
export get_extension_path, set_extension_path!
export get_namespace, set_namespace!, has_namespace, delete_namespace!
export merge_extensions!, copy_extensions
export create_hello, create_ack, create_error
export encode_messagepack, decode_messagepack
export MessagePackWorkspace, encode_messagepack!
export DirectElementDelta, DirectAddedEntity, DirectUpdatedEntity
export DirectDeltaPayload, DirectDeltaMessage, encode_direct_delta
export DirectSnapshotElement, DirectSnapshotEntity, DirectSnapshotPayload
export DirectSnapshotMessage, direct_snapshot_element, direct_snapshot_entity
export direct_snapshot_payload, encode_direct_snapshot
export to_debug_json, log_message_debug

# Re-export adapter items
export SimulationAdapter
export abm_capability, get_simulation_time
export get_elements_snapshot, get_entities_snapshot, get_abm_snapshot
export dispatch_command
export DirtyState, supports_dirty_tracking, dirty_state
export get_element_state, get_entity_state, clear_dirty_state!
export supports_parallel_state_fetch, get_element_states, get_entity_states
export supports_gpu_state_fetch, synchronize_gpu_state!
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
export DenseNumericState, advance_positions_scalar!, advance_positions_simd!
export supports_simd, dense_numeric_state, advance_dense_numeric!
export CommandWorkItem, CommandWorkerPool, start_pool!, stop_pool!, submit_command
export CommandResponse, CommandFuture, is_command_ready, wait_result, command_latency
export get_latency_stats
export SnapshotEfficiencyTracker, should_send_delta, record_snapshot!, efficiency_report
export AdaptiveSnapshotBuilder, build_snapshot_from_adapter, build_next_snapshot
export build_next_snapshot_message, build_next_snapshot_bytes
export DEFAULT_TYPED_DELTA_THRESHOLD
export AdapterProfile, profile_adapter, profile_summary
export adaptive_statistics
export IncrementalStateCache, seed_cache!, apply_dirty_state!
export cached_elements, cached_entities, dirty_delta_payload
export direct_dirty_delta_payload, encode_direct_dirty_delta

# Re-export server items
export GodotBridgeServer
export start, stop
export register_handler!, broadcast_snapshot
export num_connected_clients, is_server_running

# Version info
const VERSION = v"0.1.0"

end # module GodotBridge
