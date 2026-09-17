"""Track full-snapshot and delta payload sizes for adaptive transmission."""
mutable struct SnapshotEfficiencyTracker
    last_full_size::Int
    last_delta_size::Int
    full_count::Int
    delta_count::Int
    total_bytes::Int
    baseline_bytes::Int
    threshold::Float64
    lock::ReentrantLock
end

function SnapshotEfficiencyTracker(; threshold::Float64=0.8)
    0.0 < threshold <= 1.0 || throw(ArgumentError("threshold must be in (0, 1]"))
    return SnapshotEfficiencyTracker(0, 0, 0, 0, 0, 0, threshold, ReentrantLock())
end

function should_send_delta(tracker::SnapshotEfficiencyTracker, delta_size::Int, full_size::Int)
    full_size > 0 || return false
    return delta_size / full_size <= tracker.threshold
end

function record_snapshot!(tracker::SnapshotEfficiencyTracker, is_delta::Bool, size::Int)
    size >= 0 || throw(ArgumentError("snapshot size must be non-negative"))
    lock(tracker.lock) do
        if is_delta
            tracker.last_delta_size = size
            tracker.delta_count += 1
        else
            tracker.last_full_size = size
            tracker.full_count += 1
        end
        tracker.total_bytes += size
        tracker.baseline_bytes += tracker.last_full_size > 0 ? tracker.last_full_size : size
    end
    return tracker
end

function efficiency_report(tracker::SnapshotEfficiencyTracker)
    lock(tracker.lock) do
        savings = tracker.baseline_bytes == 0 ? 0.0 :
            100.0 * (tracker.baseline_bytes - tracker.total_bytes) / tracker.baseline_bytes
        return Dict{Symbol, Any}(
            :full_snapshots => tracker.full_count,
            :deltas => tracker.delta_count,
            :total_bytes => tracker.total_bytes,
            :last_full_bytes => tracker.last_full_size,
            :last_delta_bytes => tracker.last_delta_size,
            :estimated_savings_percent => savings
        )
    end
end

export SnapshotEfficiencyTracker, should_send_delta, record_snapshot!, efficiency_report
