# Phase 7B.3.1: ABM Trait System
# Zero-cost abstractions for optional features

"""
    ABMCapability

Abstract base for ABM capability markers.
Used for compile-time dispatch to determine if adapter supports agent-based modeling.
"""
abstract type ABMCapability end

"""
    NoABM <: ABMCapability

Trait indicating this adapter is DES-only (no ABM support).
Zero-cost marker: ABM snapshot will be nothing, no computation performed.
"""
struct NoABM <: ABMCapability end

"""
    SupportsABM <: ABMCapability

Trait indicating this adapter supports ABM (either Hybrid DES+ABM or Pure ABM).
ABM snapshot will be populated from adapter's agent population.
"""
struct SupportsABM <: ABMCapability end

"""
    ProtocolVersion

Abstract base for protocol version markers.
Used to ensure protocol compatibility between client and server.
"""
abstract type ProtocolVersion end

"""
    V1 <: ProtocolVersion

Protocol version 1 (current, stable).
Frozen: 7 message types, MessagePack serialization, JSON debug-only.
"""
struct V1 <: ProtocolVersion end

"""
    FeatureCapability

Abstract base for optional feature capabilities.
Allows adapters to declare advanced features beyond core ABM support.
"""
abstract type FeatureCapability end

"""
    SupportsGPU <: FeatureCapability

Trait indicating this adapter uses GPU acceleration.
Godot GUI can optimize transmission for GPU-aware entities.
Example: GPU-accelerated particle systems, large entity counts.
"""
struct SupportsGPU <: FeatureCapability end

"""
    SupportsReplay <: FeatureCapability

Trait indicating this adapter supports replay/rewind functionality.
Godot GUI can offer timeline scrubbing, frame-by-frame navigation.
Requires adapter to maintain complete state history.
"""
struct SupportsReplay <: FeatureCapability end

"""
    SupportsParallelism <: FeatureCapability

Trait indicating this adapter uses parallel execution (multi-threaded simulation).
Godot GUI should serialize state extraction to avoid data races.
"""
struct SupportsParallelism <: FeatureCapability end

# Trait composition helpers
"""
    has_feature(adapter, feature_type::Type{<:FeatureCapability})::Bool

Check if adapter declares support for a feature.
Default: false (no features by default).
"""
function has_feature(adapter, ::Type{<:FeatureCapability})
    return false
end

"""
    protocol_version(adapter)::Type{<:ProtocolVersion}

Get the protocol version this adapter uses.
Default: V1.
"""
function protocol_version(adapter)
    return V1
end

export ABMCapability, NoABM, SupportsABM
export ProtocolVersion, V1
export FeatureCapability, SupportsGPU, SupportsReplay, SupportsParallelism
export has_feature, protocol_version
