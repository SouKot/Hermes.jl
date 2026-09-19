"""
    scenespec.jl

Pure SceneSpec v1 schema codecs, unknown-field preservation, and semantic comparison.
Implements the canonical declarative contract for DES, ABM, and Hybrid simulation models.
"""

import JSON
import MsgPack

const SceneSpec = SceneSpecPayload

const KNOWN_SCENESPEC_ROOT_KEYS = Set{String}([
    "spec_version",
    "scene",
    "simulation",
    "abm_config",
    "spatial",
    "elements",
    "connections",
    "subgraphs",
    "overlays",
    "validation_metadata",
    "extensions"
])

"""
    parse_scenespec(data::AbstractDict)::SceneSpecPayload

Parses an untyped dictionary representation into a `SceneSpecPayload`.
All unknown root-level fields are preserved into the `extensions` dictionary.
Nested dictionaries and arrays retain unknown properties without loss.
"""
function parse_scenespec(data::AbstractDict)::SceneSpecPayload
    # Convert all string-like keys to standard String
    str_data = Dict{String, Any}(string(k) => v for (k, v) in data)

    spec_version = string(get(str_data, "spec_version", "1.0.0"))
    scene = Dict{String, Any}(string(k) => v for (k, v) in get(str_data, "scene", Dict{String, Any}()))
    simulation = Dict{String, Any}(string(k) => v for (k, v) in get(str_data, "simulation", Dict{String, Any}()))
    
    abm_raw = get(str_data, "abm_config", nothing)
    abm_config = abm_raw === nothing ? nothing : Dict{String, Any}(string(k) => v for (k, v) in abm_raw)

    spatial_raw = get(str_data, "spatial", nothing)
    spatial = spatial_raw === nothing ? nothing : Dict{String, Any}(string(k) => v for (k, v) in spatial_raw)

    elements = [Dict{String, Any}(string(k) => v for (k, v) in e) for e in get(str_data, "elements", Any[])]
    connections = [Dict{String, Any}(string(k) => v for (k, v) in c) for c in get(str_data, "connections", Any[])]
    subgraphs = [Dict{String, Any}(string(k) => v for (k, v) in s) for s in get(str_data, "subgraphs", Any[])]
    overlays = [Dict{String, Any}(string(k) => v for (k, v) in o) for o in get(str_data, "overlays", Any[])]
    validation_metadata = Dict{String, Any}(string(k) => v for (k, v) in get(str_data, "validation_metadata", Dict{String, Any}()))

    # Unknown fields and extensions preservation
    extensions = Dict{String, Any}()
    if haskey(str_data, "extensions") && str_data["extensions"] isa AbstractDict
        extensions["extensions"] = Dict{String, Any}(string(ek) => ev for (ek, ev) in str_data["extensions"])
    end
    for (k, v) in str_data
        if !(k in KNOWN_SCENESPEC_ROOT_KEYS)
            extensions[k] = v
        end
    end

    return SceneSpecPayload(
        spec_version,
        scene,
        simulation,
        abm_config,
        spatial,
        elements,
        connections,
        subgraphs,
        overlays,
        validation_metadata,
        extensions
    )
end

"""
    scenespec_to_dict(spec::SceneSpecPayload)::Dict{String, Any}

Converts a `SceneSpecPayload` back into a canonical dictionary.
Preserved unknown fields and extensions are re-emitted into the root payload.
"""
function scenespec_to_dict(spec::SceneSpecPayload)::Dict{String, Any}
    out = Dict{String, Any}(
        "spec_version" => spec.spec_version,
        "scene" => spec.scene,
        "simulation" => spec.simulation,
        "abm_config" => spec.abm_config,
        "elements" => spec.elements,
        "connections" => spec.connections,
        "subgraphs" => spec.subgraphs,
        "overlays" => spec.overlays,
        "validation_metadata" => spec.validation_metadata,
    )
    if spec.spatial !== nothing
        out["spatial"] = spec.spatial
    end

    # Emit extensions and preserved unknown root fields
    for (k, v) in spec.extensions
        if k == "extensions"
            out["extensions"] = v
        else
            out[k] = v
        end
    end

    return out
end

"""
    decode_scenespec_json(json_str::String)::SceneSpecPayload

Decodes a UTF-8 JSON string into a canonical `SceneSpecPayload`.
"""
function decode_scenespec_json(json_str::String)::SceneSpecPayload
    raw = JSON.parse(json_str)
    if !(raw isa AbstractDict)
        error("Invalid SceneSpec JSON root: expected object, got $(typeof(raw))")
    end
    return parse_scenespec(raw)
end

"""
    encode_scenespec_json(spec::SceneSpecPayload; pretty::Bool=true)::String

Encodes a `SceneSpecPayload` into a canonical UTF-8 JSON string.
"""
function encode_scenespec_json(spec::SceneSpecPayload; pretty::Bool=true)::String
    dict = scenespec_to_dict(spec)
    return pretty ? JSON.json(dict, 2) : JSON.json(dict)
end

"""
    encode_scenespec_msgpack(spec::SceneSpecPayload)::Vector{UInt8}

Encodes a `SceneSpecPayload` into binary MessagePack.
"""
function encode_scenespec_msgpack(spec::SceneSpecPayload)::Vector{UInt8}
    dict = scenespec_to_dict(spec)
    return MsgPack.pack(dict)
end

"""
    decode_scenespec_msgpack(bytes::Vector{UInt8})::SceneSpecPayload

Decodes binary MessagePack into a `SceneSpecPayload`.
"""
function decode_scenespec_msgpack(bytes::Vector{UInt8})::SceneSpecPayload
    raw = MsgPack.unpack(bytes)
    if !(raw isa AbstractDict)
        error("Invalid SceneSpec MessagePack root: expected map, got $(typeof(raw))")
    end
    return parse_scenespec(raw)
end

# ─────────────────────────────────────────────────────────────────────────────
# Normalized Semantic Equality
# ─────────────────────────────────────────────────────────────────────────────

function _is_keyed_collection(vec::AbstractVector)::Bool
    !isempty(vec) && all(item -> (item isa AbstractDict && haskey(item, "id")), vec)
end

function _clean_dict_keys(d::AbstractDict)::Dict{String, Any}
    Dict{String, Any}(string(k) => v for (k, v) in d)
end

"""
    scenespec_semantic_equal(a, b; atol=1e-6, path="root")::Tuple{Bool, String}

Performs recursive, normalized semantic comparison between two SceneSpecs or nested records:
1. Map key-order is ignored.
2. Numeric values are compared with tolerance `atol`. Integers and floats with identical values match.
3. Collections of entities with unique `"id"`s are sorted by `"id"` before comparison.
4. Preserved unknown fields and extensions are compared under the same rules.
Returns `(true, "")` on match, or `(false, failure_path_and_reason)` on mismatch.
"""
function scenespec_semantic_equal(
    a::Union{SceneSpecPayload, AbstractDict},
    b::Union{SceneSpecPayload, AbstractDict};
    atol::Float64=1e-6,
    path::String="root"
)::Tuple{Bool, String}
    da = a isa SceneSpecPayload ? scenespec_to_dict(a) : _clean_dict_keys(a)
    db = b isa SceneSpecPayload ? scenespec_to_dict(b) : _clean_dict_keys(b)

    keys_a = Set(keys(da))
    keys_b = Set(keys(db))

    all_keys = union(keys_a, keys_b)
    for k in sort(collect(all_keys))
        in_a = haskey(da, k)
        in_b = haskey(db, k)

        if !in_a
            # Allow empty dict or null if other side is also effectively empty
            val_b = db[k]
            if val_b === nothing || (val_b isa AbstractDict && isempty(val_b)) || (val_b isa AbstractVector && isempty(val_b))
                continue
            end
            return (false, "$path: key '$k' missing in first operand")
        end

        if !in_b
            val_a = da[k]
            if val_a === nothing || (val_a isa AbstractDict && isempty(val_a)) || (val_a isa AbstractVector && isempty(val_a))
                continue
            end
            return (false, "$path: key '$k' missing in second operand")
        end

        va = da[k]
        vb = db[k]
        subpath = path == "root" ? k : "$path.$k"
        ok, reason = _compare_values(va, vb; atol=atol, path=subpath)
        if !ok
            return (false, reason)
        end
    end

    return (true, "")
end

function _compare_values(va::Any, vb::Any; atol::Float64=1e-6, path::String="")::Tuple{Bool, String}
    if va === nothing && vb === nothing
        return (true, "")
    elseif va === nothing || vb === nothing
        return (false, "$path: null mismatch ($va vs $vb)")
    end

    if va isa Bool && vb isa Bool
        return va == vb ? (true, "") : (false, "$path: boolean mismatch ($va vs $vb)")
    end

    if va isa Number && vb isa Number
        fa = Float64(va)
        fb = Float64(vb)
        if isnan(fa) && isnan(fb)
            return (true, "")
        end
        if abs(fa - fb) <= atol * (1.0 + max(abs(fa), abs(fb)))
            return (true, "")
        else
            return (false, "$path: numeric mismatch ($va vs $vb, diff=$(abs(fa - fb)))")
        end
    end

    if va isa AbstractString && vb isa AbstractString
        return va == vb ? (true, "") : (false, "$path: string mismatch ('$va' != '$vb')")
    end

    if va isa AbstractDict && vb isa AbstractDict
        return scenespec_semantic_equal(va, vb; atol=atol, path=path)
    end

    if va isa AbstractVector && vb isa AbstractVector
        if _is_keyed_collection(va) && _is_keyed_collection(vb)
            # Sort by "id"
            sorted_a = sort(collect(va), by=x -> string(x["id"]))
            sorted_b = sort(collect(vb), by=x -> string(x["id"]))
            if length(sorted_a) != length(sorted_b)
                return (false, "$path: collection length mismatch ($(length(sorted_a)) vs $(length(sorted_b)))")
            end
            for i in 1:length(sorted_a)
                id_val = string(sorted_a[i]["id"])
                ok, reason = _compare_values(sorted_a[i], sorted_b[i]; atol=atol, path="$path[id=$id_val]")
                if !ok
                    return (false, reason)
                end
            end
            return (true, "")
        else
            if length(va) != length(vb)
                return (false, "$path: array length mismatch ($(length(va)) vs $(length(vb)))")
            end
            for i in 1:length(va)
                ok, reason = _compare_values(va[i], vb[i]; atol=atol, path="$path[$i]")
                if !ok
                    return (false, reason)
                end
            end
            return (true, "")
        end
    end

    return (false, "$path: type mismatch ($(typeof(va)) vs $(typeof(vb)))")
end
