"""Build full snapshots or deltas according to measured payload efficiency."""
mutable struct AdaptiveSnapshotBuilder
    adapter::SimulationAdapter
    scene_id::String
    full_interval::Int
    update_count::Int
    last_snapshot::Union{SnapshotPayload, Nothing}
    tracker::SnapshotEfficiencyTracker
    element_cache::ElementStateCache
end

function AdaptiveSnapshotBuilder(
    adapter::SimulationAdapter;
    scene_id::String="default",
    full_interval::Int=10,
    delta_threshold::Float64=0.8
)
    full_interval > 0 || throw(ArgumentError("full_interval must be positive"))
    return AdaptiveSnapshotBuilder(
        adapter, scene_id, full_interval, 0, nothing,
        SnapshotEfficiencyTracker(threshold=delta_threshold),
        ElementStateCache()
    )
end

function build_snapshot_from_adapter(
    builder::AdaptiveSnapshotBuilder
)::SnapshotPayload
    return build_snapshot(
        builder.scene_id,
        Float64(get_simulation_time(builder.adapter)),
        UInt64(builder.update_count),
        1.0f0,
        "running",
        extract_elements_cached(builder.adapter, builder.element_cache;
            current_time=Float64(get_simulation_time(builder.adapter))),
        extract_entities_vectorized(builder.adapter)
    )
end

function _message_size(message::Message)
    return length(encode_messagepack(message))
end

function build_next_snapshot(builder::AdaptiveSnapshotBuilder)::Message
    builder.update_count += 1
    current = build_snapshot_from_adapter(builder)
    full_message = wrap_snapshot_in_message(current)
    full_size = _message_size(full_message)
    force_full = isnothing(builder.last_snapshot) ||
        (builder.update_count % builder.full_interval == 0)

    if force_full
        record_snapshot!(builder.tracker, false, full_size)
        builder.last_snapshot = current
        return full_message
    end

    delta = DeltaBuilder.build_delta(builder.last_snapshot, current)
    delta_message = DeltaBuilder.create_delta_message(
        delta;
        snapshot_version=current.snapshot_version,
        scene_id=current.scene_id,
        simulation_time=current.simulation_time,
        step_count=current.step_count
    )
    delta_size = _message_size(delta_message)

    if should_send_delta(builder.tracker, delta_size, full_size)
        record_snapshot!(builder.tracker, true, delta_size)
        return delta_message
    end

    record_snapshot!(builder.tracker, false, full_size)
    builder.last_snapshot = current
    return full_message
end

function adaptive_statistics(builder::AdaptiveSnapshotBuilder)
    report = efficiency_report(builder.tracker)
    report[:updates] = builder.update_count
    report[:updates_since_full] = builder.update_count % builder.full_interval
    return report
end

export AdaptiveSnapshotBuilder, build_snapshot_from_adapter, build_next_snapshot, adaptive_statistics
