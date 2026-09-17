using BenchmarkTools
include("benchmark_dirty_tracking.jl")

adapter = make_adapter(500_000)
builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=1000)
GodotBridge.build_next_snapshot_message(builder)
ids = ["element-$index" for index in 1:50_000]
dirty = GodotBridge.DirtyState(elements_updated=ids, revision=2)
adapter.pending = dirty
adapter.current_time = 0.1
GodotBridge.apply_dirty_state!(builder.incremental_cache, adapter, dirty)
current = GodotBridge.build_snapshot("benchmark", adapter.current_time, UInt64(2),
    1.0f0, "running")
generic_payload = GodotBridge.dirty_delta_payload(
    builder.incremental_cache, adapter, dirty, current
)
generic_message = GodotBridge.Message(
    GodotBridge.MessageEnvelope("1.0", "generic", UInt64(1), "julia", "godot", "delta"),
    generic_payload
)
direct_payload = GodotBridge.direct_dirty_delta_payload(
    builder.incremental_cache, dirty, current
)

# Force compilation before timed samples.
GodotBridge.encode_messagepack(generic_message)
GodotBridge.encode_direct_delta(direct_payload)

generic_trial = @benchmark GodotBridge.encode_messagepack($generic_message) samples=20 evals=1
direct_trial = @benchmark GodotBridge.encode_direct_delta($direct_payload) samples=20 evals=1

summary(trial) = (
    median_ms=median(trial.times) / 1.0e6,
    p99_ms=quantile(trial.times, 0.99) / 1.0e6,
    allocations=allocs(trial),
    bytes=memory(trial)
)

println("generic=", summary(generic_trial))
println("typed=", summary(direct_trial))
println("median_speedup=", median(generic_trial.times) / median(direct_trial.times))
