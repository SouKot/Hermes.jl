"""Lightweight, dependency-free profiling for real adapter implementations."""
struct AdapterProfile
    iterations::Int
    extraction_ms::Float64
    extraction_p99_ms::Float64
    dirty_state_ms::Float64
    dirty_state_p99_ms::Float64
    full_snapshot_ms::Float64
    full_snapshot_p99_ms::Float64
    encoded_bytes::Int
    dirty_tracking::Bool
end

function _profile_p99(samples::Vector{Float64})
    isempty(samples) && return 0.0
    sorted = sort(samples)
    return sorted[clamp(ceil(Int, 0.99 * length(sorted)), 1, length(sorted))]
end

_profile_mean(samples::Vector{Float64}) = isempty(samples) ? 0.0 : sum(samples) / length(samples)

"""
    profile_adapter(adapter; iterations=5, scene_id="profile")

Profile adapter extraction and full snapshot construction without assuming an
engine-specific representation. Use this with a real DES, ABM, or hybrid adapter.
"""
function profile_adapter(
    adapter::SimulationAdapter;
    iterations::Int=5,
    scene_id::String="profile"
)::AdapterProfile
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    extraction = Float64[]
    dirty_times = Float64[]
    snapshot_times = Float64[]
    encoded_bytes = 0

    for iteration in 1:iterations
        start = time_ns()
        elements = get_elements_snapshot(adapter)
        entities = get_entities_snapshot(adapter)
        push!(extraction, (time_ns() - start) / 1.0e6)

        start = time_ns()
        dirty = dirty_state(adapter)
        push!(dirty_times, (time_ns() - start) / 1.0e6)

        start = time_ns()
        snapshot = build_snapshot(
            scene_id, Float64(get_simulation_time(adapter)), UInt64(iteration),
            1.0f0, "running", elements, entities
        )
        bytes = encode_direct_snapshot(snapshot)
        encoded_bytes = length(bytes)
        push!(snapshot_times, (time_ns() - start) / 1.0e6)

        dirty.full_scan || clear_dirty_state!(adapter, dirty.revision)
    end

    return AdapterProfile(
        iterations,
        _profile_mean(extraction), _profile_p99(extraction),
        _profile_mean(dirty_times), _profile_p99(dirty_times),
        _profile_mean(snapshot_times), _profile_p99(snapshot_times),
        encoded_bytes, supports_dirty_tracking(adapter)
    )
end

function profile_summary(profile::AdapterProfile)
    return Dict{Symbol, Any}(
        :iterations => profile.iterations,
        :extraction_ms => profile.extraction_ms,
        :extraction_p99_ms => profile.extraction_p99_ms,
        :dirty_state_ms => profile.dirty_state_ms,
        :dirty_state_p99_ms => profile.dirty_state_p99_ms,
        :full_snapshot_ms => profile.full_snapshot_ms,
        :full_snapshot_p99_ms => profile.full_snapshot_p99_ms,
        :encoded_bytes => profile.encoded_bytes,
        :dirty_tracking => profile.dirty_tracking
    )
end

export AdapterProfile, profile_adapter, profile_summary
