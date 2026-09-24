# packages/GodotBridge/src/compiler/source_map_diagnostics.jl
#
# Compiler Diagnostics & Source Mapping System for SceneSpec v1.
# Provides structured diagnostic records (errors, warnings, info)
# mapped directly to source element IDs and property paths for Godot UI highlighting.

"""
    DiagnosticSeverity

Severity level for compiler diagnostics.
"""
@enum DiagnosticSeverity begin
    DIAG_INFO    = 1
    DIAG_WARNING = 2
    DIAG_ERROR   = 3
end

"""
    CompilerDiagnostic

Structured diagnostic produced during compilation or validation of an authored scene.
"""
struct CompilerDiagnostic
    rule_id::String
    element_id::String
    property_path::String
    severity::DiagnosticSeverity
    message::String
    suggested_fix::String
end

function CompilerDiagnostic(
    rule_id::AbstractString,
    element_id::AbstractString,
    message::AbstractString;
    property_path::AbstractString = "",
    severity::DiagnosticSeverity = DIAG_ERROR,
    suggested_fix::AbstractString = ""
)
    return CompilerDiagnostic(
        string(rule_id),
        string(element_id),
        string(property_path),
        severity,
        string(message),
        string(suggested_fix)
    )
end

"""
    to_dict(diag::CompilerDiagnostic) -> Dict{String, Any}

Serializes diagnostic into a JSON/MsgPack compatible dictionary matching Protocol v1.
"""
function to_dict(diag::CompilerDiagnostic)
    sev_str = diag.severity == DIAG_ERROR ? "error" :
              diag.severity == DIAG_WARNING ? "warning" : "info"
    return Dict{String, Any}(
        "rule_id" => diag.rule_id,
        "element_id" => diag.element_id,
        "property_path" => diag.property_path,
        "severity" => sev_str,
        "message" => diag.message,
        "suggested_fix" => diag.suggested_fix
    )
end

"""
    has_errors(diagnostics::Vector{CompilerDiagnostic}) -> Bool

Returns true if any diagnostic has severity `DIAG_ERROR`.
"""
function has_errors(diagnostics::Vector{CompilerDiagnostic})::Bool
    return any(d -> d.severity == DIAG_ERROR, diagnostics)
end

"""
    SourceMapRecord

Bi-directional mapping between authored SceneSpec element IDs and compiled execution runtime entities.
"""
struct SourceMapRecord
    element_id::String
    element_kind::String
    zone_ids::Vector{Int}
    is_fused_station::Bool
    fused_partner_id::Union{Nothing, String}
    role_in_zone::Symbol  # :standalone, :queue_buffer, :server_workstation, :conveyor_bed, :sink_drain
end

function SourceMapRecord(element_id::AbstractString, kind::AbstractString, zone_id::Int, role::Symbol=:standalone)
    return SourceMapRecord(string(element_id), string(kind), [zone_id], false, nothing, role)
end

"""
    SourceMap

Complete bi-directional registry linking authored element IDs and compiled runtime zones.
"""
struct SourceMap
    by_element::Dict{String, SourceMapRecord}
    by_zone::Dict{Int, Vector{SourceMapRecord}}
end

function SourceMap()
    return SourceMap(
        Dict{String, SourceMapRecord}(),
        Dict{Int, Vector{SourceMapRecord}}()
    )
end

function register_mapping!(sm::SourceMap, rec::SourceMapRecord)
    sm.by_element[rec.element_id] = rec
    for zid in rec.zone_ids
        if !haskey(sm.by_zone, zid)
            sm.by_zone[zid] = SourceMapRecord[]
        end
        push!(sm.by_zone[zid], rec)
    end
end

