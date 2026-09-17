include("benchmark_dirty_tracking.jl")

function compare_direct(count=500_000; fraction=0.1, updates=5)
    adapter = make_adapter(count)
    builder = GodotBridge.AdaptiveSnapshotBuilder(adapter; full_interval=1000)
    GodotBridge.build_next_snapshot(builder; encoding=:generic)
    changed = round(Int, count * fraction)
    generic_times = Float64[]
    direct_times = Float64[]
    generic_sizes = Int[]
    direct_sizes = Int[]

    warmup_ids = ["element-$(mod1(index, count))" for index in 1:changed]
    adapter.pending = GodotBridge.DirtyState(elements_updated=warmup_ids, revision=2)
    GodotBridge.build_next_snapshot(builder; encoding=:generic)

    warmup_dirty = GodotBridge.DirtyState(elements_updated=warmup_ids, revision=2)
    warmup_current = GodotBridge.build_snapshot("benchmark", adapter.current_time,
        UInt64(2), 1.0f0, "running")
    warmup_generic_payload = GodotBridge.dirty_delta_payload(
        builder.incremental_cache, adapter, warmup_dirty, warmup_current
    )
    warmup_generic_message = GodotBridge.Message(
        GodotBridge.MessageEnvelope("1.0", "warmup", UInt64(1), "julia", "godot", "delta"),
        warmup_generic_payload
    )
    warmup_direct_payload = GodotBridge.direct_dirty_delta_payload(
        builder.incremental_cache, warmup_dirty, warmup_current
    )
    GodotBridge.encode_messagepack(warmup_generic_message)
    GodotBridge.encode_direct_delta(warmup_direct_payload)

    for update in 1:updates
        ids = ["element-$(mod1(index + update, count))" for index in 1:changed]
        for id in ids
            adapter.elements[id].occupancy += UInt32(1)
        end
        dirty = GodotBridge.DirtyState(elements_updated=ids, revision=update + 2)
        adapter.pending = dirty
        adapter.current_time += 0.1
        GodotBridge.apply_dirty_state!(builder.incremental_cache, adapter, dirty)
        current = GodotBridge.build_snapshot("benchmark", adapter.current_time,
            UInt64(update + 2), 1.0f0, "running")

        generic_payload = GodotBridge.dirty_delta_payload(
            builder.incremental_cache, adapter, dirty, current
        )
        generic_message = GodotBridge.Message(
            GodotBridge.MessageEnvelope("1.0", "generic", UInt64(1), "julia", "godot", "delta"),
            generic_payload
        )
        start = time_ns()
        generic_bytes = GodotBridge.encode_messagepack(generic_message)
        push!(generic_times, (time_ns() - start) / 1.0e6)
        push!(generic_sizes, length(generic_bytes))

        direct_payload = GodotBridge.direct_dirty_delta_payload(
            builder.incremental_cache, dirty, current
        )
        start = time_ns()
        direct_bytes = GodotBridge.encode_direct_delta(direct_payload)
        push!(direct_times, (time_ns() - start) / 1.0e6)
        push!(direct_sizes, length(direct_bytes))
    end
    return (
        generic_ms=mean(generic_times), direct_ms=mean(direct_times),
        generic_bytes=mean(generic_sizes), direct_bytes=mean(direct_sizes)
    )
end

println(compare_direct())
