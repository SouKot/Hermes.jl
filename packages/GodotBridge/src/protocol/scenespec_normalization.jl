"""
    scenespec_normalization.jl

Normalization, input safety guardrails, migration hooks, and two-tier conversion
between untyped transport payloads (SceneSpecPayload) and strongly-typed domain records (TypedSceneSpec).
"""

# Regex for valid element, port, level, connection, and scene IDs
const SCENESPEC_ID_REGEX = r"^[a-zA-Z0-9_\-:]+$"

const KNOWN_SCENE_KEYS = Set{String}([
    "id", "name", "description", "author", "created_at", "modified_at",
    "revision", "required_libraries", "extensions"
])

const KNOWN_SIMULATION_KEYS = Set{String}([
    "mode", "start_time", "end_time", "warmup_time", "random_seed",
    "time_unit", "space_unit", "extensions"
])

const KNOWN_ABM_KEYS = Set{String}([
    "enabled", "model_name", "model_version", "model_library",
    "backend_preference", "fallback_policy", "parameters", "extensions"
])

const KNOWN_SPATIAL_KEYS = Set{String}([
    "coordinate_system", "length_unit", "origin", "levels", "extensions"
])

const KNOWN_LEVEL_KEYS = Set{String}([
    "id", "name", "elevation", "default_height", "visible", "extensions"
])

const KNOWN_ELEMENT_KEYS = Set{String}([
    "id", "name", "kind", "library", "library_version", "level_id",
    "transform", "geometry", "editor", "properties",
    "input_ports", "output_ports", "metric_ports",
    "vertical_extent", "visual", "extensions"
])

const KNOWN_GEOMETRY_KEYS = Set{String}([
    "shape", "dimensions", "vertices", "waypoints", "width", "height", "extensions"
])

const KNOWN_EDITOR_KEYS = Set{String}([
    "graph_position", "collapsed", "color", "notes", "extensions"
])

const KNOWN_PORT_KEYS = Set{String}([
    "id", "name", "direction", "kind", "data_type", "cardinality",
    "required", "unit", "description", "extensions"
])

const KNOWN_CONNECTION_KEYS = Set{String}([
    "id", "source_element", "source_port", "target_element", "target_port",
    "link_type", "enabled", "ordering", "condition", "latency", "capacity", "extensions"
])

const KNOWN_SUBGRAPH_KEYS = Set{String}([
    "id", "name", "role", "template_id", "template_version", "elements",
    "connections", "exposed_ports", "parameter_overrides", "extensions"
])

const KNOWN_OVERLAY_KEYS = Set{String}([
    "id", "name", "kind", "level_id", "visible", "properties", "extensions"
])

const KNOWN_VALIDATION_KEYS = Set{String}([
    "is_valid", "diagnostic_count", "last_validated_at", "validator_version",
    "diagnostics", "extensions"
])

function _extract_extensions(d::AbstractDict, known_keys::Set{String})::Dict{String, Any}
    ext = Dict{String, Any}()
    if haskey(d, "extensions") && d["extensions"] isa AbstractDict
        ext["extensions"] = Dict{String, Any}(string(ek) => ev for (ek, ev) in d["extensions"])
    end
    for (k, v) in d
        sk = string(k)
        if !(sk in known_keys)
            ext[sk] = v
        end
    end
    return ext
end

function _merge_extensions!(out::Dict{String, Any}, ext::Dict{String, Any})
    for (k, v) in ext
        if k == "extensions"
            out["extensions"] = v
        else
            out[k] = v
        end
    end
    return out
end

function _validate_id(id::AbstractString, context::String; max_len::Int=256)::String
    sid = String(id)
    if isempty(sid)
        throw(ArgumentError("Invalid empty ID in $context"))
    end
    if length(sid) > max_len
        throw(ArgumentError("ID exceeds maximum length of $max_len characters in $context: '$sid'"))
    end
    if !occursin(SCENESPEC_ID_REGEX, sid)
        throw(ArgumentError("ID contains forbidden characters in $context: '$sid'. Must match pattern $SCENESPEC_ID_REGEX"))
    end
    return sid
end

function _validate_string(s::AbstractString, field_name::String; max_len::Int=256)::String
    str = String(s)
    if length(str) > max_len
        throw(ArgumentError("Field '$field_name' exceeds maximum length of $max_len characters: length=$(length(str))"))
    end
    return str
end

function _check_depth(val::Any, current_depth::Int=0; max_depth::Int=32)
    if current_depth > max_depth
        throw(ArgumentError("Maximum nesting depth of $max_depth exceeded in SceneSpec payload"))
    end
    if val isa AbstractDict
        for (_, v) in val
            _check_depth(v, current_depth + 1; max_depth=max_depth)
        end
    elseif val isa AbstractVector
        for v in val
            _check_depth(v, current_depth + 1; max_depth=max_depth)
        end
    end
end

function _to_tuple2(val::Any, default::NTuple{2, Float64}=(0.0, 0.0))::NTuple{2, Float64}
    if val isa AbstractVector && length(val) >= 2
        return (Float64(val[1]), Float64(val[2]))
    elseif val isa Tuple && length(val) >= 2
        return (Float64(val[1]), Float64(val[2]))
    end
    return default
end

function _to_tuple3(val::Any, default::NTuple{3, Float64}=(0.0, 0.0, 0.0))::NTuple{3, Float64}
    if val isa AbstractVector && length(val) >= 3
        return (Float64(val[1]), Float64(val[2]), Float64(val[3]))
    elseif val isa Tuple && length(val) >= 3
        return (Float64(val[1]), Float64(val[2]), Float64(val[3]))
    end
    return default
end

function _parse_port_records(ports_raw, default_dir::Symbol; max_string_len::Int=256)::Vector{PortRecord}
    res = PortRecord[]
    if ports_raw isa AbstractVector
        for p in ports_raw
            if p isa AbstractDict
                pid = _validate_id(string(p["id"]), "port.id"; max_len=max_string_len)
                pname = _validate_string(string(get(p, "name", pid)), "port.name"; max_len=max_string_len)
                pdir = Symbol(get(p, "direction", string(default_dir)))
                pkind = Symbol(get(p, "kind", "flow"))
                pdata = string(get(p, "data_type", "entity"))
                pcard = Symbol(get(p, "cardinality", "many"))
                preq = Bool(get(p, "required", true))
                punit = haskey(p, "unit") ? string(p["unit"]) : nothing
                pdesc = haskey(p, "description") ? string(p["description"]) : nothing
                pext = _extract_extensions(p, KNOWN_PORT_KEYS)
                push!(res, PortRecord(pid, pname, pdir, pkind, pdata, pcard, preq, punit, pdesc, pext))
            end
        end
    end
    return res
end

function _serialize_port_records(ports::Vector{PortRecord})::Vector{Dict{String, Any}}
    res = Dict{String, Any}[]
    for p in ports
        pd = Dict{String, Any}(
            "id" => p.id,
            "name" => p.name,
            "direction" => string(p.direction),
            "kind" => string(p.kind),
            "data_type" => p.data_type,
            "cardinality" => string(p.cardinality),
            "required" => p.required
        )
        if p.unit !== nothing
            pd["unit"] = p.unit
        end
        if p.description !== nothing
            pd["description"] = p.description
        end
        _merge_extensions!(pd, p.extensions)
        push!(res, pd)
    end
    return res
end

# ─────────────────────────────────────────────────────────────────────────────
# to_typed_scenespec: Convert Transport Payload -> Typed Domain Model
# ─────────────────────────────────────────────────────────────────────────────

"""
    to_typed_scenespec(payload::SceneSpecPayload; max_elements=50000, max_string_len=256, max_depth=32)::TypedSceneSpec

Validates bounds and transforms an untyped `SceneSpecPayload` into a strongly-typed `TypedSceneSpec`.
Enforces:
- Maximum element count (`max_elements`)
- Maximum ID and string lengths (`max_string_len`)
- Valid ID naming patterns (`SCENESPEC_ID_REGEX`)
- Maximum data nesting depth (`max_depth`)
- Right-handed Z-up coordinate system normalization
- Complete retention of unknown fields in `extensions`
"""
function to_typed_scenespec(
    payload::SceneSpecPayload;
    max_elements::Int=50000,
    max_string_len::Int=256,
    max_depth::Int=32
)::TypedSceneSpec
    # Guardrail 1: Element count
    num_elems = length(payload.elements)
    if num_elems > max_elements
        throw(ArgumentError("Document exceeds maximum element limit of $max_elements (got $num_elems)"))
    end

    # Guardrail 2: Nesting depth
    _check_depth(payload.scene, 1; max_depth=max_depth)
    _check_depth(payload.elements, 1; max_depth=max_depth)
    _check_depth(payload.extensions, 1; max_depth=max_depth)

    # 1. Scene Metadata
    scene_dict = payload.scene
    scene_id = _validate_id(string(get(scene_dict, "id", "scene_unnamed")), "scene.id"; max_len=max_string_len)
    scene_name = _validate_string(string(get(scene_dict, "name", "Unnamed Scene")), "scene.name"; max_len=max_string_len)
    scene_desc = string(get(scene_dict, "description", ""))
    scene_author = string(get(scene_dict, "author", ""))
    scene_created = string(get(scene_dict, "created_at", ""))
    scene_modified = string(get(scene_dict, "modified_at", ""))
    scene_rev = Int(get(scene_dict, "revision", 1))

    req_libs = LibraryRequirement[]
    if haskey(scene_dict, "required_libraries") && scene_dict["required_libraries"] isa AbstractVector
        for lib in scene_dict["required_libraries"]
            if lib isa AbstractDict
                lname = _validate_string(string(get(lib, "name", "")), "library.name"; max_len=max_string_len)
                lver = string(get(lib, "version", "*"))
                push!(req_libs, LibraryRequirement(lname, lver))
            end
        end
    end
    scene_ext = _extract_extensions(scene_dict, KNOWN_SCENE_KEYS)
    scene_meta = SceneMetadata(
        scene_id, scene_name, scene_desc, scene_author,
        scene_created, scene_modified, scene_rev, req_libs, scene_ext
    )

    # 2. Simulation Config
    sim_dict = payload.simulation
    sim_mode = Symbol(get(sim_dict, "mode", "des_only"))
    sim_start = Float64(get(sim_dict, "start_time", 0.0))
    sim_end = Float64(get(sim_dict, "end_time", 100.0))
    sim_warmup = Float64(get(sim_dict, "warmup_time", 0.0))
    sim_seed = UInt64(get(sim_dict, "random_seed", 42))
    sim_tunit = string(get(sim_dict, "time_unit", "seconds"))
    sim_sunit = string(get(sim_dict, "space_unit", "meters"))
    sim_ext = _extract_extensions(sim_dict, KNOWN_SIMULATION_KEYS)
    sim_config = SimulationConfig(
        sim_mode, sim_start, sim_end, sim_warmup, sim_seed, sim_tunit, sim_sunit, sim_ext
    )

    # 3. ABM Config (optional)
    abm_config = nothing
    if payload.abm_config !== nothing
        abm_dict = payload.abm_config
        abm_enabled = Bool(get(abm_dict, "enabled", false))
        abm_name = get(abm_dict, "model_name", nothing)
        abm_name_str = abm_name === nothing ? nothing : string(abm_name)
        abm_ver = get(abm_dict, "model_version", nothing)
        abm_ver_str = abm_ver === nothing ? nothing : string(abm_ver)
        abm_lib = get(abm_dict, "model_library", nothing)
        abm_lib_str = abm_lib === nothing ? nothing : string(abm_lib)
        abm_pref = haskey(abm_dict, "backend_preference") && abm_dict["backend_preference"] !== nothing ?
            Symbol(abm_dict["backend_preference"]) : nothing
        abm_fall = haskey(abm_dict, "fallback_policy") && abm_dict["fallback_policy"] !== nothing ?
            Symbol(abm_dict["fallback_policy"]) : nothing
        abm_params = Dict{String, Any}(string(k) => v for (k, v) in get(abm_dict, "parameters", Dict{String, Any}()))
        abm_ext = _extract_extensions(abm_dict, KNOWN_ABM_KEYS)
        abm_config = ABMConfig(
            abm_enabled, abm_name_str, abm_ver_str, abm_lib_str,
            abm_pref, abm_fall, abm_params, abm_ext
        )
    end

    # 4. Spatial Config (optional)
    spatial_config = nothing
    if payload.spatial !== nothing
        sp_dict = payload.spatial
        coord_sys = string(get(sp_dict, "coordinate_system", "right_handed_z_up"))
        length_unit = string(get(sp_dict, "length_unit", "meters"))
        sp_origin = _to_tuple3(get(sp_dict, "origin", [0.0, 0.0, 0.0]))
        
        levels = SpatialLevel[]
        if haskey(sp_dict, "levels") && sp_dict["levels"] isa AbstractVector
            for lvl in sp_dict["levels"]
                if lvl isa AbstractDict
                    lid = _validate_id(string(get(lvl, "id", "level_default")), "level.id"; max_len=max_string_len)
                    lname = _validate_string(string(get(lvl, "name", lid)), "level.name"; max_len=max_string_len)
                    lelev = Float64(get(lvl, "elevation", 0.0))
                    lheight = Float64(get(lvl, "default_height", 3.0))
                    lvis = Bool(get(lvl, "visible", true))
                    lext = _extract_extensions(lvl, KNOWN_LEVEL_KEYS)
                    push!(levels, SpatialLevel(lid, lname, lelev, lheight, lvis, lext))
                end
            end
        end
        sp_ext = _extract_extensions(sp_dict, KNOWN_SPATIAL_KEYS)
        spatial_config = SpatialConfig(coord_sys, length_unit, sp_origin, levels, sp_ext)
    end

    # 5. Elements
    typed_elements = ElementRecord[]
    for e in payload.elements
        eid = _validate_id(string(e["id"]), "element.id"; max_len=max_string_len)
        ename = _validate_string(string(get(e, "name", eid)), "element.name"; max_len=max_string_len)
        ekind = _validate_string(string(get(e, "kind", "generic")), "element.kind"; max_len=max_string_len)
        elib = string(get(e, "library", ""))
        elib_ver = string(get(e, "library_version", ""))
        elevel = string(get(e, "level_id", "level_ground"))

        # Transform
        t_dict = get(e, "transform", Dict{String, Any}())
        t_pos = _to_tuple3(get(t_dict, "position", [0.0, 0.0, 0.0]))
        t_rot = _to_tuple3(get(t_dict, "rotation", [0.0, 0.0, 0.0]))
        t_scl = _to_tuple3(get(t_dict, "scale", [1.0, 1.0, 1.0]), (1.0, 1.0, 1.0))
        t_rec = TransformRecord(t_pos, t_rot, t_scl)

        # Geometry
        g_dict = get(e, "geometry", Dict{String, Any}())
        g_shape = string(get(g_dict, "shape", "box"))
        g_dims = [Float64(d) for d in get(g_dict, "dimensions", Float64[])]
        g_verts = haskey(g_dict, "vertices") && g_dict["vertices"] isa AbstractVector ?
            [_to_tuple2(v) for v in g_dict["vertices"]] : nothing
        g_ways = haskey(g_dict, "waypoints") && g_dict["waypoints"] isa AbstractVector ?
            [_to_tuple3(w) for w in g_dict["waypoints"]] : nothing
        g_w = haskey(g_dict, "width") ? Float64(g_dict["width"]) : nothing
        g_h = haskey(g_dict, "height") ? Float64(g_dict["height"]) : nothing
        g_ext = _extract_extensions(g_dict, KNOWN_GEOMETRY_KEYS)
        g_rec = GeometryRecord(g_shape, g_dims, g_verts, g_ways, g_w, g_h, g_ext)

        # Editor
        ed_dict = get(e, "editor", Dict{String, Any}())
        ed_pos = _to_tuple2(get(ed_dict, "graph_position", [0.0, 0.0]))
        ed_col = Bool(get(ed_dict, "collapsed", false))
        ed_color = haskey(ed_dict, "color") ? string(ed_dict["color"]) : nothing
        ed_notes = haskey(ed_dict, "notes") ? string(ed_dict["notes"]) : nothing
        ed_ext = _extract_extensions(ed_dict, KNOWN_EDITOR_KEYS)
        ed_rec = EditorMetadata(ed_pos, ed_col, ed_color, ed_notes, ed_ext)

        # Properties
        props = Dict{String, Any}(string(k) => v for (k, v) in get(e, "properties", Dict{String, Any}()))

        in_ports = _parse_port_records(get(e, "input_ports", Any[]), :input; max_string_len=max_string_len)
        out_ports = _parse_port_records(get(e, "output_ports", Any[]), :output; max_string_len=max_string_len)
        met_ports = _parse_port_records(get(e, "metric_ports", Any[]), :output; max_string_len=max_string_len)

        vert_ext = haskey(e, "vertical_extent") && e["vertical_extent"] isa AbstractDict ?
            Dict{String, Any}(string(k) => v for (k, v) in e["vertical_extent"]) : nothing
        vis_meta = haskey(e, "visual") && e["visual"] isa AbstractDict ?
            Dict{String, Any}(string(k) => v for (k, v) in e["visual"]) : nothing

        elem_ext = _extract_extensions(e, KNOWN_ELEMENT_KEYS)
        push!(typed_elements, ElementRecord(
            eid, ename, ekind, elib, elib_ver, elevel,
            t_rec, g_rec, ed_rec, props, in_ports, out_ports, met_ports,
            vert_ext, vis_meta, elem_ext
        ))
    end

    # 6. Connections
    typed_conns = ConnectionRecord[]
    for c in payload.connections
        cid = _validate_id(string(c["id"]), "connection.id"; max_len=max_string_len)
        src_e = _validate_id(string(c["source_element"]), "connection.source_element"; max_len=max_string_len)
        src_p = _validate_id(string(c["source_port"]), "connection.source_port"; max_len=max_string_len)
        tgt_e = _validate_id(string(c["target_element"]), "connection.target_element"; max_len=max_string_len)
        tgt_p = _validate_id(string(c["target_port"]), "connection.target_port"; max_len=max_string_len)
        link = Symbol(get(c, "link_type", "flow"))
        enabled = Bool(get(c, "enabled", true))
        ordering = Int(get(c, "ordering", 1))
        cond = haskey(c, "condition") && c["condition"] !== nothing ? string(c["condition"]) : nothing
        latency = haskey(c, "latency") && c["latency"] !== nothing ? Float64(c["latency"]) : nothing
        capacity = haskey(c, "capacity") && c["capacity"] !== nothing ? Int(c["capacity"]) : nothing
        conn_ext = _extract_extensions(c, KNOWN_CONNECTION_KEYS)
        push!(typed_conns, ConnectionRecord(
            cid, src_e, src_p, tgt_e, tgt_p, link, enabled, ordering, cond, latency, capacity, conn_ext
        ))
    end

    # 7. Subgraphs
    typed_subs = SubgraphRecord[]
    for s in payload.subgraphs
        sid = _validate_id(string(s["id"]), "subgraph.id"; max_len=max_string_len)
        sname = _validate_string(string(get(s, "name", sid)), "subgraph.name"; max_len=max_string_len)
        role = Symbol(get(s, "role", "group"))
        tmpl_id = haskey(s, "template_id") && s["template_id"] !== nothing ? string(s["template_id"]) : nothing
        tmpl_ver = haskey(s, "template_version") && s["template_version"] !== nothing ? string(s["template_version"]) : nothing
        elems = [string(x) for x in get(s, "elements", Any[])]
        conns = [string(x) for x in get(s, "connections", Any[])]
        exposed = [Dict{String, Any}(string(k) => v for (k, v) in x) for x in get(s, "exposed_ports", Any[])]
        params = Dict{String, Any}(string(k) => v for (k, v) in get(s, "parameter_overrides", Dict{String, Any}()))
        sub_ext = _extract_extensions(s, KNOWN_SUBGRAPH_KEYS)
        push!(typed_subs, SubgraphRecord(
            sid, sname, role, tmpl_id, tmpl_ver, elems, conns, exposed, params, sub_ext
        ))
    end

    # 8. Overlays
    typed_overlays = OverlayRecord[]
    for o in payload.overlays
        oid = _validate_id(string(o["id"]), "overlay.id"; max_len=max_string_len)
        oname = _validate_string(string(get(o, "name", oid)), "overlay.name"; max_len=max_string_len)
        okind = string(get(o, "kind", "heatmap"))
        olevel = string(get(o, "level_id", "level_ground"))
        ovis = Bool(get(o, "visible", true))
        oprops = Dict{String, Any}(string(k) => v for (k, v) in get(o, "properties", Dict{String, Any}()))
        oext = _extract_extensions(o, KNOWN_OVERLAY_KEYS)
        push!(typed_overlays, OverlayRecord(oid, oname, okind, olevel, ovis, oprops, oext))
    end

    # 9. Validation Metadata
    vm_dict = payload.validation_metadata
    is_valid = Bool(get(vm_dict, "is_valid", true))
    diag_count = Int(get(vm_dict, "diagnostic_count", 0))
    last_val = string(get(vm_dict, "last_validated_at", ""))
    val_ver = string(get(vm_dict, "validator_version", "1.0.0"))

    diagnostics = DiagnosticRecord[]
    if haskey(vm_dict, "diagnostics") && vm_dict["diagnostics"] isa AbstractVector
        for d in vm_dict["diagnostics"]
            if d isa AbstractDict
                rid = string(get(d, "rule_id", "UNKNOWN"))
                sev = Symbol(get(d, "severity", "error"))
                okind = string(get(d, "object_kind", ""))
                oid = string(get(d, "object_id", ""))
                ppath = string(get(d, "property_path", ""))
                msg = string(get(d, "message", ""))
                fix = haskey(d, "suggested_fix") && d["suggested_fix"] !== nothing ? string(d["suggested_fix"]) : nothing
                push!(diagnostics, DiagnosticRecord(rid, sev, okind, oid, ppath, msg, fix))
            end
        end
    end
    vm_ext = _extract_extensions(vm_dict, KNOWN_VALIDATION_KEYS)
    val_meta = ValidationMetadataRecord(is_valid, diag_count, last_val, val_ver, diagnostics, vm_ext)

    return TypedSceneSpec(
        payload.spec_version,
        scene_meta,
        sim_config,
        abm_config,
        spatial_config,
        typed_elements,
        typed_conns,
        typed_subs,
        typed_overlays,
        val_meta,
        payload.extensions
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# to_payload: Convert Typed Domain Model -> Transport Payload
# ─────────────────────────────────────────────────────────────────────────────

"""
    to_payload(spec::TypedSceneSpec)::SceneSpecPayload

Transforms a strongly-typed `TypedSceneSpec` back into an interchange `SceneSpecPayload`.
Preserves all extensions, unknown fields, and nested metadata losslessly.
"""
function to_payload(spec::TypedSceneSpec)::SceneSpecPayload
    # 1. Scene
    sc = spec.scene
    scene_dict = Dict{String, Any}(
        "id" => sc.id,
        "name" => sc.name,
        "description" => sc.description,
        "author" => sc.author,
        "created_at" => sc.created_at,
        "modified_at" => sc.modified_at,
        "revision" => sc.revision,
        "required_libraries" => [
            Dict{String, Any}("name" => lib.name, "version" => lib.version)
            for lib in sc.required_libraries
        ]
    )
    _merge_extensions!(scene_dict, sc.extensions)

    # 2. Simulation
    sm = spec.simulation
    sim_dict = Dict{String, Any}(
        "mode" => string(sm.mode),
        "start_time" => sm.start_time,
        "end_time" => sm.end_time,
        "warmup_time" => sm.warmup_time,
        "random_seed" => sm.random_seed,
        "time_unit" => sm.time_unit,
        "space_unit" => sm.space_unit
    )
    _merge_extensions!(sim_dict, sm.extensions)

    # 3. ABM Config
    abm_dict = nothing
    if spec.abm_config !== nothing
        ab = spec.abm_config
        abm_dict = Dict{String, Any}(
            "enabled" => ab.enabled,
            "model_name" => ab.model_name,
            "model_version" => ab.model_version,
            "model_library" => ab.model_library,
            "parameters" => ab.parameters
        )
        if ab.backend_preference !== nothing
            abm_dict["backend_preference"] = string(ab.backend_preference)
        end
        if ab.fallback_policy !== nothing
            abm_dict["fallback_policy"] = string(ab.fallback_policy)
        end
        _merge_extensions!(abm_dict, ab.extensions)
    end

    # 4. Spatial Config
    spatial_dict = nothing
    if spec.spatial !== nothing
        sp = spec.spatial
        levels_vec = Dict{String, Any}[]
        for lvl in sp.levels
            ld = Dict{String, Any}(
                "id" => lvl.id,
                "name" => lvl.name,
                "elevation" => lvl.elevation,
                "default_height" => lvl.default_height,
                "visible" => lvl.visible
            )
            _merge_extensions!(ld, lvl.extensions)
            push!(levels_vec, ld)
        end
        spatial_dict = Dict{String, Any}(
            "coordinate_system" => sp.coordinate_system,
            "length_unit" => sp.length_unit,
            "origin" => collect(sp.origin),
            "levels" => levels_vec
        )
        _merge_extensions!(spatial_dict, sp.extensions)
    end

    # 5. Elements
    elements_vec = Dict{String, Any}[]
    for e in spec.elements
        # Transform
        t_dict = Dict{String, Any}(
            "position" => collect(e.transform.position),
            "rotation" => collect(e.transform.rotation),
            "scale" => collect(e.transform.scale)
        )

        # Geometry
        g_dict = Dict{String, Any}(
            "shape" => e.geometry.shape,
            "dimensions" => e.geometry.dimensions
        )
        if e.geometry.vertices !== nothing
            g_dict["vertices"] = [collect(v) for v in e.geometry.vertices]
        end
        if e.geometry.waypoints !== nothing
            g_dict["waypoints"] = [collect(w) for w in e.geometry.waypoints]
        end
        if e.geometry.width !== nothing
            g_dict["width"] = e.geometry.width
        end
        if e.geometry.height !== nothing
            g_dict["height"] = e.geometry.height
        end
        _merge_extensions!(g_dict, e.geometry.extensions)

        # Editor
        ed_dict = Dict{String, Any}(
            "graph_position" => collect(e.editor.graph_position),
            "collapsed" => e.editor.collapsed
        )
        if e.editor.color !== nothing
            ed_dict["color"] = e.editor.color
        end
        if e.editor.notes !== nothing
            ed_dict["notes"] = e.editor.notes
        end
        _merge_extensions!(ed_dict, e.editor.extensions)

        elem_dict = Dict{String, Any}(
            "id" => e.id,
            "name" => e.name,
            "kind" => e.kind,
            "library" => e.library,
            "library_version" => e.library_version,
            "level_id" => e.level_id,
            "transform" => t_dict,
            "geometry" => g_dict,
            "editor" => ed_dict,
            "properties" => e.properties,
            "input_ports" => _serialize_port_records(e.input_ports),
            "output_ports" => _serialize_port_records(e.output_ports),
            "metric_ports" => _serialize_port_records(e.metric_ports)
        )
        if e.vertical_extent !== nothing
            elem_dict["vertical_extent"] = e.vertical_extent
        end
        if e.visual !== nothing
            elem_dict["visual"] = e.visual
        end
        _merge_extensions!(elem_dict, e.extensions)
        push!(elements_vec, elem_dict)
    end

    # 6. Connections
    conns_vec = Dict{String, Any}[]
    for c in spec.connections
        cd = Dict{String, Any}(
            "id" => c.id,
            "source_element" => c.source_element,
            "source_port" => c.source_port,
            "target_element" => c.target_element,
            "target_port" => c.target_port,
            "link_type" => string(c.link_type),
            "enabled" => c.enabled,
            "ordering" => c.ordering
        )
        if c.condition !== nothing
            cd["condition"] = c.condition
        end
        if c.latency !== nothing
            cd["latency"] = c.latency
        end
        if c.capacity !== nothing
            cd["capacity"] = c.capacity
        end
        _merge_extensions!(cd, c.extensions)
        push!(conns_vec, cd)
    end

    # 7. Subgraphs
    subs_vec = Dict{String, Any}[]
    for s in spec.subgraphs
        sd = Dict{String, Any}(
            "id" => s.id,
            "name" => s.name,
            "role" => string(s.role),
            "elements" => s.elements,
            "connections" => s.connections,
            "exposed_ports" => s.exposed_ports,
            "parameter_overrides" => s.parameter_overrides
        )
        if s.template_id !== nothing
            sd["template_id"] = s.template_id
        end
        if s.template_version !== nothing
            sd["template_version"] = s.template_version
        end
        _merge_extensions!(sd, s.extensions)
        push!(subs_vec, sd)
    end

    # 8. Overlays
    overlays_vec = Dict{String, Any}[]
    for o in spec.overlays
        od = Dict{String, Any}(
            "id" => o.id,
            "name" => o.name,
            "kind" => o.kind,
            "level_id" => o.level_id,
            "visible" => o.visible,
            "properties" => o.properties
        )
        _merge_extensions!(od, o.extensions)
        push!(overlays_vec, od)
    end

    # 9. Validation Metadata
    vm = spec.validation_metadata
    diag_vec = Dict{String, Any}[]
    for d in vm.diagnostics
        dd = Dict{String, Any}(
            "rule_id" => d.rule_id,
            "severity" => string(d.severity),
            "object_kind" => d.object_kind,
            "object_id" => d.object_id,
            "property_path" => d.property_path,
            "message" => d.message
        )
        if d.suggested_fix !== nothing
            dd["suggested_fix"] = d.suggested_fix
        end
        push!(diag_vec, dd)
    end
    vm_dict = Dict{String, Any}(
        "is_valid" => vm.is_valid,
        "diagnostic_count" => vm.diagnostic_count,
        "last_validated_at" => vm.last_validated_at,
        "validator_version" => vm.validator_version,
        "diagnostics" => diag_vec
    )
    _merge_extensions!(vm_dict, vm.extensions)

    return SceneSpecPayload(
        spec.spec_version,
        scene_dict,
        sim_dict,
        abm_dict,
        spatial_dict,
        elements_vec,
        conns_vec,
        subs_vec,
        overlays_vec,
        vm_dict,
        spec.extensions
    )
end

"""
    scenespec_to_dict(spec::TypedSceneSpec)::Dict{String, Any}

Converts a `TypedSceneSpec` into a canonical SceneSpec dictionary.
"""
scenespec_to_dict(spec::TypedSceneSpec)::Dict{String, Any} = scenespec_to_dict(to_payload(spec))

"""
    parse_typed_scenespec(data::AbstractDict; kwargs...)::TypedSceneSpec

Parses a dictionary into a `TypedSceneSpec` with full validation and normalization.
"""
function parse_typed_scenespec(data::AbstractDict; kwargs...)::TypedSceneSpec
    payload = parse_scenespec(data)
    return to_typed_scenespec(payload; kwargs...)
end

# ─────────────────────────────────────────────────────────────────────────────
# Minor-Version Migration Hooks
# ─────────────────────────────────────────────────────────────────────────────

"""
    migrate_scenespec(raw::Dict{String, Any}; target_version="1.0.0")::Dict{String, Any}

Normalizes legacy drafts or minor-version updates of SceneSpec:
- Backfills `spec_version = target_version` if missing or draft.
- Backfills canonical right-handed Z-up spatial block if omitted.
- Normalizes element transforms with default unit scale `[1.0, 1.0, 1.0]`.
- Backfills missing element `level_id`, `geometry`, and `editor` properties.
- Backfills default validation metadata if missing.
"""
function migrate_scenespec(raw::Dict{String, Any}; target_version::String="1.0.0")::Dict{String, Any}
    out = deepcopy(raw)

    # 1. Version check and upgrade
    ver = string(get(out, "spec_version", ""))
    if isempty(ver) || startswith(ver, "0.") || occursis("-draft", ver) || ver == "draft"
        out["spec_version"] = target_version
    end

    # 2. Scene defaults
    if !haskey(out, "scene") || !(out["scene"] isa AbstractDict)
        out["scene"] = Dict{String, Any}(
            "id" => "scene_default",
            "name" => "Default Scene",
            "description" => "Auto-migrated SceneSpec",
            "author" => "Migrator",
            "created_at" => "",
            "modified_at" => "",
            "revision" => 1,
            "required_libraries" => Any[]
        )
    end

    # 3. Spatial normalization
    if !haskey(out, "spatial") || out["spatial"] === nothing || !(out["spatial"] isa AbstractDict)
        out["spatial"] = Dict{String, Any}(
            "coordinate_system" => "right_handed_z_up",
            "length_unit" => "meters",
            "origin" => [0.0, 0.0, 0.0],
            "levels" => [
                Dict{String, Any}(
                    "id" => "level_ground",
                    "name" => "Ground Floor",
                    "elevation" => 0.0,
                    "default_height" => 3.0,
                    "visible" => true
                )
            ]
        )
    else
        sp = out["spatial"]
        if !haskey(sp, "coordinate_system") || isempty(string(sp["coordinate_system"]))
            sp["coordinate_system"] = "right_handed_z_up"
        end
        if !haskey(sp, "length_unit") || isempty(string(sp["length_unit"]))
            sp["length_unit"] = "meters"
        end
        if !haskey(sp, "origin")
            sp["origin"] = [0.0, 0.0, 0.0]
        end
        if !haskey(sp, "levels") || isempty(sp["levels"])
            sp["levels"] = [
                Dict{String, Any}(
                    "id" => "level_ground",
                    "name" => "Ground Floor",
                    "elevation" => 0.0,
                    "default_height" => 3.0,
                    "visible" => true
                )
            ]
        end
    end

    # 4. Elements normalization
    if haskey(out, "elements") && out["elements"] isa AbstractVector
        for e in out["elements"]
            if e isa AbstractDict
                if !haskey(e, "level_id") || isempty(string(e["level_id"]))
                    e["level_id"] = "level_ground"
                end
                if !haskey(e, "transform") || !(e["transform"] isa AbstractDict)
                    e["transform"] = Dict{String, Any}(
                        "position" => [0.0, 0.0, 0.0],
                        "rotation" => [0.0, 0.0, 0.0],
                        "scale" => [1.0, 1.0, 1.0]
                    )
                else
                    t = e["transform"]
                    if !haskey(t, "position")
                        t["position"] = [0.0, 0.0, 0.0]
                    end
                    if !haskey(t, "rotation")
                        t["rotation"] = [0.0, 0.0, 0.0]
                    end
                    if !haskey(t, "scale")
                        t["scale"] = [1.0, 1.0, 1.0]
                    end
                end
                if !haskey(e, "geometry") || !(e["geometry"] isa AbstractDict)
                    e["geometry"] = Dict{String, Any}(
                        "shape" => "box",
                        "dimensions" => [1.0, 1.0, 1.0]
                    )
                end
                if !haskey(e, "editor") || !(e["editor"] isa AbstractDict)
                    e["editor"] = Dict{String, Any}(
                        "graph_position" => [0.0, 0.0],
                        "collapsed" => false
                    )
                end
                if !haskey(e, "properties") || !(e["properties"] isa AbstractDict)
                    e["properties"] = Dict{String, Any}()
                end
                if !haskey(e, "input_ports")
                    e["input_ports"] = Any[]
                end
                if !haskey(e, "output_ports")
                    e["output_ports"] = Any[]
                end
                if !haskey(e, "metric_ports")
                    e["metric_ports"] = Any[]
                end
            end
        end
    end

    # 5. Validation metadata
    if !haskey(out, "validation_metadata") || !(out["validation_metadata"] isa AbstractDict)
        out["validation_metadata"] = Dict{String, Any}(
            "is_valid" => true,
            "diagnostic_count" => 0,
            "diagnostics" => Any[],
            "last_validated_at" => "",
            "validator_version" => target_version
        )
    end

    return out
end
