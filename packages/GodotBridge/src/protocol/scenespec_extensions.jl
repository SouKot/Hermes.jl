"""
    scenespec_extensions.jl

Dynamic Extension Preservation & Custom Metadata API for SceneSpec v1 (Phase 7D-03).
Provides high-performance, type-stable, ergonomic methods for inspecting, mutating,
and navigating custom metadata and vendor extensions across all SceneSpec domain records
and raw dictionary payloads without touching core types.
"""

"""
    _resolve_ext_dict(obj)::Dict{String, Any}

Internal helper resolving the underlying mutable extensions dictionary for any
domain record or dictionary.
"""
function _resolve_ext_dict(obj::Any)::Dict{String, Any}
    if obj isa Dict{String, Any}
        return obj
    elseif obj isa AbstractDict
        return Dict{String, Any}(string(k) => v for (k, v) in obj)
    elseif hasproperty(obj, :extensions) && obj.extensions isa Dict{String, Any}
        return obj.extensions
    else
        throw(ArgumentError("Object of type $(typeof(obj)) does not support SceneSpec extensions"))
    end
end

"""
    has_extension(obj, key::AbstractString)::Bool

Returns `true` if `key` exists as a direct unknown extension property or within
the nested `extensions` block.
"""
function has_extension(obj::Any, key::AbstractString)::Bool
    skey = String(key)
    ext = _resolve_ext_dict(obj)
    if haskey(ext, skey)
        return true
    end
    if haskey(ext, "extensions") && ext["extensions"] isa AbstractDict
        return haskey(ext["extensions"], skey)
    end
    return false
end

"""
    get_extension(obj, key::AbstractString, default=nothing)

Retrieves an extension value by `key`. Transparently searches direct unknown properties
first, and falls back to the nested `extensions` dictionary.
"""
function get_extension(obj::Any, key::AbstractString, default::Any=nothing)::Any
    skey = String(key)
    ext = _resolve_ext_dict(obj)
    if haskey(ext, skey)
        return ext[skey]
    end
    if haskey(ext, "extensions") && ext["extensions"] isa AbstractDict
        sub = ext["extensions"]
        if haskey(sub, skey)
            return sub[skey]
        end
    end
    return default
end

"""
    set_extension!(obj, key::AbstractString, value; in_nested_block::Bool=false)

Sets an extension property on `obj`. If `in_nested_block` is `true`, stores inside
`obj.extensions["extensions"][key]`; otherwise stores at top-level `obj.extensions[key]`.
"""
function set_extension!(obj::Any, key::AbstractString, value::Any; in_nested_block::Bool=false)
    skey = String(key)
    ext = _resolve_ext_dict(obj)
    if in_nested_block
        if !haskey(ext, "extensions") || !(ext["extensions"] isa Dict{String, Any})
            ext["extensions"] = Dict{String, Any}()
        end
        ext["extensions"][skey] = value
    else
        # If key already existed in nested block, update it there
        if !haskey(ext, skey) && haskey(ext, "extensions") && (ext["extensions"] isa AbstractDict) && haskey(ext["extensions"], skey)
            ext["extensions"][skey] = value
        else
            ext[skey] = value
        end
    end
    return obj
end

"""
    delete_extension!(obj, key::AbstractString)

Deletes an extension property from `obj`. Searches both top-level unknown properties
and nested `extensions`. Returns the deleted value or `nothing` if not found.
"""
function delete_extension!(obj::Any, key::AbstractString)::Any
    skey = String(key)
    ext = _resolve_ext_dict(obj)
    if haskey(ext, skey)
        return pop!(ext, skey)
    end
    if haskey(ext, "extensions") && ext["extensions"] isa AbstractDict
        sub = ext["extensions"]
        if haskey(sub, skey)
            val = pop!(sub, skey)
            if isempty(sub)
                delete!(ext, "extensions")
            end
            return val
        end
    end
    return nothing
end

"""
    list_extensions(obj)::Vector{String}

Lists all distinct extension keys present on `obj`, combining direct properties
and nested extension dictionary keys (excluding the container key `"extensions"`).
"""
function list_extensions(obj::Any)::Vector{String}
    ext = _resolve_ext_dict(obj)
    keys_set = Set{String}()
    for k in keys(ext)
        if k != "extensions"
            push!(keys_set, k)
        end
    end
    if haskey(ext, "extensions") && ext["extensions"] isa AbstractDict
        for k in keys(ext["extensions"])
            push!(keys_set, string(k))
        end
    end
    res = collect(keys_set)
    sort!(res)
    return res
end

"""
    _parse_path_tokens(path::AbstractString)::Vector{String}

Splits a path string by `.` or `/` delimiters, trimming whitespace.
"""
function _parse_path_tokens(path::AbstractString)::Vector{String}
    raw = split(path, r"[./]")
    tokens = String[]
    for t in raw
        st = strip(t)
        if !isempty(st)
            push!(tokens, String(st))
        end
    end
    return tokens
end

"""
    get_extension_path(obj, path::AbstractString, default=nothing)

Traverses a nested metadata hierarchy using dot or slash notation (e.g.
`"ai_copilot.confidence_score"` or `"profiler_tracing/sample_interval_ms"`).
Supports 1-based array indexing if a path segment is an integer.
"""
function get_extension_path(obj::Any, path::AbstractString, default::Any=nothing)::Any
    tokens = _parse_path_tokens(path)
    if isempty(tokens)
        return default
    end

    # First token resolution: check direct extension or nested
    first_token = tokens[1]
    curr = get_extension(obj, first_token, nothing)
    if curr === nothing
        # Special case: if path starts with "extensions.", strip it
        if first_token == "extensions" && length(tokens) > 1
            ext = _resolve_ext_dict(obj)
            curr = haskey(ext, "extensions") ? ext["extensions"] : nothing
        else
            return default
        end
    end

    # Traverse remaining tokens
    for i in 2:length(tokens)
        if curr === nothing
            return default
        end
        token = tokens[i]
        if curr isa AbstractDict
            if haskey(curr, token)
                curr = curr[token]
            else
                return default
            end
        elseif curr isa AbstractVector
            idx = tryparse(Int, token)
            if idx !== nothing && 1 <= idx <= length(curr)
                curr = curr[idx]
            else
                return default
            end
        else
            return default
        end
    end
    return curr
end

"""
    set_extension_path!(obj, path::AbstractString, value)

Assigns a value deep into the metadata hierarchy, auto-creating intermediate
`Dict{String, Any}` maps as needed.
"""
function set_extension_path!(obj::Any, path::AbstractString, value::Any)
    tokens = _parse_path_tokens(path)
    if isempty(tokens)
        throw(ArgumentError("Extension path cannot be empty"))
    end

    if length(tokens) == 1
        return set_extension!(obj, tokens[1], value)
    end

    # If path starts with "extensions.", traverse into the nested block
    start_idx = 1
    ext = _resolve_ext_dict(obj)
    local curr::Dict{String, Any}

    first_token = tokens[1]
    if first_token == "extensions"
        if !haskey(ext, "extensions") || !(ext["extensions"] isa Dict{String, Any})
            ext["extensions"] = Dict{String, Any}()
        end
        curr = ext["extensions"]
        start_idx = 2
    else
        # Determine if first_token already exists
        if haskey(ext, first_token) && ext[first_token] isa Dict{String, Any}
            curr = ext[first_token]
        elseif haskey(ext, "extensions") && (ext["extensions"] isa AbstractDict) && haskey(ext["extensions"], first_token) && (ext["extensions"][first_token] isa Dict{String, Any})
            curr = ext["extensions"][first_token]
        else
            # Create new map at top-level
            curr = Dict{String, Any}()
            ext[first_token] = curr
        end
        start_idx = 2
    end

    # Traverse intermediate nodes
    for i in start_idx:(length(tokens) - 1)
        tok = tokens[i]
        if !haskey(curr, tok) || !(curr[tok] isa Dict{String, Any})
            curr[tok] = Dict{String, Any}()
        end
        curr = curr[tok]
    end

    # Set leaf value
    leaf_tok = tokens[end]
    curr[leaf_tok] = value
    return obj
end

"""
    get_namespace(obj, namespace::AbstractString)::Dict{String, Any}

Retrieves a namespaced dictionary (e.g. `vendor:analytics` or `ai_copilot`).
Returns an empty dictionary if the namespace does not exist.
"""
function get_namespace(obj::Any, namespace::AbstractString)::Dict{String, Any}
    ns = String(namespace)
    val = get_extension(obj, ns, nothing)
    if val isa AbstractDict
        return Dict{String, Any}(string(k) => v for (k, v) in val)
    end
    return Dict{String, Any}()
end

"""
    set_namespace!(obj, namespace::AbstractString, data::AbstractDict)

Sets a full dictionary under a namespace identifier.
"""
function set_namespace!(obj::Any, namespace::AbstractString, data::AbstractDict)
    ns = String(namespace)
    cloned = Dict{String, Any}(string(k) => v for (k, v) in data)
    set_extension!(obj, ns, cloned; in_nested_block=true)
    return obj
end

"""
    has_namespace(obj, namespace::AbstractString)::Bool

Checks if a namespace exists and is a dictionary.
"""
function has_namespace(obj::Any, namespace::AbstractString)::Bool
    val = get_extension(obj, namespace, nothing)
    return val isa AbstractDict
end

"""
    delete_namespace!(obj, namespace::AbstractString)

Removes an entire namespace block.
"""
function delete_namespace!(obj::Any, namespace::AbstractString)::Any
    return delete_extension!(obj, namespace)
end

"""
    merge_extensions!(target::Any, source_extensions::AbstractDict)

Recursively deep-merges source extensions into target object's extensions.
"""
function merge_extensions!(target::Any, source_extensions::AbstractDict)
    tgt_ext = _resolve_ext_dict(target)
    _deep_merge_dict!(tgt_ext, source_extensions)
    return target
end

function _deep_merge_dict!(dest::Dict{String, Any}, src::AbstractDict)
    for (k, v) in src
        sk = string(k)
        target_dict = dest
        if !haskey(dest, sk) && haskey(dest, "extensions") && (dest["extensions"] isa Dict{String, Any}) && haskey(dest["extensions"], sk)
            target_dict = dest["extensions"]
        end

        if haskey(target_dict, sk) && target_dict[sk] isa Dict{String, Any} && v isa AbstractDict
            _deep_merge_dict!(target_dict[sk], v)
        elseif v isa AbstractDict
            target_dict[sk] = Dict{String, Any}(string(subk) => subv for (subk, subv) in v)
        else
            target_dict[sk] = v
        end
    end
    return dest
end

"""
    copy_extensions(obj::Any)::Dict{String, Any}

Produces an isolated deep-copy of all extensions present on `obj`.
"""
function copy_extensions(obj::Any)::Dict{String, Any}
    ext = _resolve_ext_dict(obj)
    return deepcopy(ext)
end
