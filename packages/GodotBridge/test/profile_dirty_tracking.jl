include("benchmark_dirty_tracking.jl")

adapter = make_adapter(100_000)
builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=1000)
GodotBridge.build_next_snapshot(builder; encoding=:generic)
ids = ["element-$(index)" for index in 1:1000]
for id in ids
    adapter.elements[id].occupancy += UInt32(1)
end
adapter.pending = GodotBridge.DirtyState(elements_updated=ids, revision=2)
adapter.current_time += 0.1

@time dirty = GodotBridge.dirty_state(adapter)
@time GodotBridge.apply_dirty_state!(builder.incremental_cache, adapter, dirty)
metadata = GodotBridge.build_snapshot("benchmark", adapter.current_time, UInt64(2), 1.0f0, "running")
@time payload = GodotBridge.dirty_delta_payload(builder.incremental_cache, adapter, dirty, metadata)
message = GodotBridge.Message(
    GodotBridge.MessageEnvelope("1.0", "profile", UInt64(1), "julia", "godot", "delta"),
    payload
)
@time bytes = GodotBridge.encode_messagepack(message)
println("delta_bytes=", length(bytes))
