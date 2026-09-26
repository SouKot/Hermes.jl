"""
    scenespec_validator.jl

Authoritative semantic validation and diagnostics engine for SceneSpec v1.
Validates structural integrity, port compatibility, cardinality rules, graph topology
(cycle/deadlock detection in DES flows), spatial level constraints, and model capabilities.
Generates structured DiagnosticRecord items with human-readable suggested fixes.
"""

import Dates

"""
    validate_scenespec(spec::TypedSceneSpec; strict::Bool=false)::ValidationMetadataRecord

Performs comprehensive semantic validation on a `TypedSceneSpec`.
Returns a `ValidationMetadataRecord` containing the validation status (`is_valid`)
and a list of all detected `DiagnosticRecord` findings.
"""
function validate_scenespec(spec::TypedSceneSpec; strict::Bool=false, check_required::Bool=strict)::ValidationMetadataRecord
    diagnostics = DiagnosticRecord[]

    # Helper maps
    elements_by_id = Dict{String, ElementRecord}()
    levels_by_id = Dict{String, SpatialLevel}()
    
    # 1. ID Uniqueness & Indexing
    _validate_id_uniqueness!(diagnostics, spec, elements_by_id, levels_by_id)

    # 2. Spatial Level Constraints
    _validate_spatial_constraints!(diagnostics, spec, elements_by_id, levels_by_id)

    # 3. Subgraph & Template Rules
    _validate_subgraphs!(diagnostics, spec, elements_by_id)

    # 4. Connection & Port Rules
    _validate_connections_and_ports!(diagnostics, spec, elements_by_id; check_required=check_required)

    # 5. Graph Topology & Cycle / Livelock Detection
    _validate_graph_topology!(diagnostics, spec, elements_by_id)

    # 6. ABM Configuration Rules
    _validate_abm_config!(diagnostics, spec)

    # 7. Extension Governance Rules
    _validate_extensions!(diagnostics, spec)

    # Count errors vs warnings
    error_count = count(d -> d.severity == :error, diagnostics)
    is_valid = error_count == 0

    timestamp = Dates.format(Dates.now(Dates.UTC), Dates.ISODateTimeFormat) * "Z"

    return ValidationMetadataRecord(
        is_valid,
        length(diagnostics),
        timestamp,
        "1.0.0",
        diagnostics,
        Dict{String, Any}()
    )
end

"""
    validate_scenespec(payload::SceneSpecPayload; kwargs...)::ValidationMetadataRecord

Validates an untyped `SceneSpecPayload` by converting it to `TypedSceneSpec` first.
"""
function validate_scenespec(payload::SceneSpecPayload; kwargs...)::ValidationMetadataRecord
    typed = to_typed_scenespec(payload)
    return validate_scenespec(typed; kwargs...)
end

"""
    validate_scenespec(dict::AbstractDict; kwargs...)::ValidationMetadataRecord

Validates a dictionary by parsing and converting it to `TypedSceneSpec` first.
"""
function validate_scenespec(dict::AbstractDict; kwargs...)::ValidationMetadataRecord
    payload = parse_scenespec(dict)
    return validate_scenespec(payload; kwargs...)
end

"""
    apply_validation!(spec::TypedSceneSpec; kwargs...)::TypedSceneSpec

Validates `spec` and returns an updated `TypedSceneSpec` with fresh `validation_metadata`.
"""
function apply_validation!(spec::TypedSceneSpec; kwargs...)::TypedSceneSpec
    val_meta = validate_scenespec(spec; kwargs...)
    return TypedSceneSpec(
        spec.spec_version,
        spec.scene,
        spec.simulation,
        spec.abm_config,
        spec.spatial,
        spec.elements,
        spec.connections,
        spec.subgraphs,
        spec.overlays,
        val_meta,
        spec.extensions
    )
end

"""
    is_scene_valid(spec::Union{TypedSceneSpec, SceneSpecPayload, AbstractDict})::Bool

Convenience function returning `true` if the scene has zero validation errors.
"""
function is_scene_valid(spec::Union{TypedSceneSpec, SceneSpecPayload, AbstractDict})::Bool
    val = validate_scenespec(spec)
    return val.is_valid
end

# ─────────────────────────────────────────────────────────────────────────────
# Internal Pass 1: ID Uniqueness
# ─────────────────────────────────────────────────────────────────────────────

function _validate_id_uniqueness!(
    diagnostics::Vector{DiagnosticRecord},
    spec::TypedSceneSpec,
    elements_by_id::Dict{String, ElementRecord},
    levels_by_id::Dict{String, SpatialLevel}
)
    # Check elements
    seen_elem_ids = Set{String}()
    for elem in spec.elements
        if elem.id in seen_elem_ids
            push!(diagnostics, DiagnosticRecord(
                "ID_001_DUPLICATE",
                :error,
                "element",
                elem.id,
                "id",
                "Duplicate element ID '$(elem.id)' found in document",
                "Assign a unique identifier to the element"
            ))
        else
            push!(seen_elem_ids, elem.id)
            elements_by_id[elem.id] = elem
        end

        # Check port uniqueness within element
        seen_port_ids = Set{String}()
        all_ports = vcat(elem.input_ports, elem.output_ports, elem.metric_ports)
        for p in all_ports
            if p.id in seen_port_ids
                push!(diagnostics, DiagnosticRecord(
                    "ID_001_DUPLICATE",
                    :error,
                    "port",
                    p.id,
                    "id",
                    "Duplicate port ID '$(p.id)' found on element '$(elem.id)'",
                    "Assign a unique identifier to the port on this element"
                ))
            else
                push!(seen_port_ids, p.id)
            end
        end
    end

    # Check connections
    seen_conn_ids = Set{String}()
    for conn in spec.connections
        if conn.id in seen_conn_ids
            push!(diagnostics, DiagnosticRecord(
                "ID_001_DUPLICATE",
                :error,
                "connection",
                conn.id,
                "id",
                "Duplicate connection ID '$(conn.id)' found in document",
                "Assign a unique identifier to the connection"
            ))
        else
            push!(seen_conn_ids, conn.id)
        end
    end

    # Check levels
    if spec.spatial !== nothing
        seen_level_ids = Set{String}()
        for lvl in spec.spatial.levels
            if lvl.id in seen_level_ids
                push!(diagnostics, DiagnosticRecord(
                    "ID_001_DUPLICATE",
                    :error,
                    "level",
                    lvl.id,
                    "id",
                    "Duplicate spatial level ID '$(lvl.id)' found in spatial configuration",
                    "Assign a unique identifier to the spatial level"
                ))
            else
                push!(seen_level_ids, lvl.id)
                levels_by_id[lvl.id] = lvl
            end
        end
    end

    # Check subgraphs
    seen_sub_ids = Set{String}()
    for sub in spec.subgraphs
        if sub.id in seen_sub_ids || sub.id in seen_elem_ids
            push!(diagnostics, DiagnosticRecord(
                "ID_001_DUPLICATE",
                :error,
                "subgraph",
                sub.id,
                "id",
                "Duplicate subgraph ID '$(sub.id)' found in document",
                "Assign a unique identifier to the subgraph"
            ))
        else
            push!(seen_sub_ids, sub.id)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Internal Pass 2: Spatial Level Constraints
# ─────────────────────────────────────────────────────────────────────────────

function _validate_spatial_constraints!(
    diagnostics::Vector{DiagnosticRecord},
    spec::TypedSceneSpec,
    elements_by_id::Dict{String, ElementRecord},
    levels_by_id::Dict{String, SpatialLevel}
)
    if spec.spatial === nothing || isempty(spec.spatial.levels)
        return
    end

    avail_levels_str = join(["'$k'" for k in sort(collect(keys(levels_by_id)))], ", ")

    for elem in spec.elements
        # Check level existence
        if !isempty(elem.level_id) && !haskey(levels_by_id, elem.level_id)
            push!(diagnostics, DiagnosticRecord(
                "ELEM_001_LEVEL_NOT_FOUND",
                :error,
                "element",
                elem.id,
                "level_id",
                "Element '$(elem.id)' references non-existent spatial level '$(elem.level_id)'",
                "Assign level_id to one of: $avail_levels_str"
            ))
            continue
        end

        lvl = levels_by_id[elem.level_id]
        elem_z = elem.transform.position[3]

        # Elevation bounds check
        min_z = lvl.elevation - 1e-4
        max_z = lvl.elevation + lvl.default_height + 1e-4
        if elem_z < min_z || elem_z > max_z
            push!(diagnostics, DiagnosticRecord(
                "SPATIAL_001_ELEVATION_OUT_OF_BOUNDS",
                :warning,
                "element",
                elem.id,
                "transform.position[3]",
                "Element '$(elem.id)' elevation Z=$elem_z is outside level '$(lvl.id)' bounds [$(lvl.elevation), $(lvl.elevation + lvl.default_height)]",
                "Adjust element position Z or level elevation/height"
            ))
        end

        # Check multi-level connector
        if elem.vertical_extent !== nothing
            ve = elem.vertical_extent
            src_lvl = get(ve, "source_level_id", nothing)
            tgt_lvl = get(ve, "target_level_id", nothing)
            height = Float64(get(ve, "height", 0.0))

            if src_lvl !== nothing && tgt_lvl !== nothing
                src_str = string(src_lvl)
                tgt_str = string(tgt_lvl)
                if src_str == tgt_str || !haskey(levels_by_id, src_str) || !haskey(levels_by_id, tgt_str) || height <= 0.0
                    push!(diagnostics, DiagnosticRecord(
                        "SPATIAL_002_CONNECTOR_LEVEL_MISMATCH",
                        :error,
                        "element",
                        elem.id,
                        "vertical_extent",
                        "Vertical connector '$(elem.id)' references invalid, non-existent, or identical levels",
                        "Specify valid, distinct source_level_id and target_level_id with height > 0"
                    ))
                else
                    sl = levels_by_id[src_str]
                    tl = levels_by_id[tgt_str]
                    min_elev = min(sl.elevation, tl.elevation)
                    max_elev = max(sl.elevation, tl.elevation)
                    elem_z = elem.transform.position[3]
                    connector_top = elem_z + height
                    if elem_z > min_elev + 1e-4 || connector_top < max_elev - 1e-4
                        push!(diagnostics, DiagnosticRecord(
                            "SPATIAL_003_CONNECTOR_INACCESSIBLE",
                            :error,
                            "element",
                            elem.id,
                            "vertical_extent",
                            "Vertical connector '$(elem.id)' span [Z=$elem_z, $connector_top] does not span elevations of levels '$src_str' (elev $(sl.elevation)) and '$tgt_str' (elev $(tl.elevation))",
                            "Adjust connector position Z and height to bridge both level elevations"
                        ))
                    end
                end
            end
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Internal Pass 3: Subgraph & Template Rules
# ─────────────────────────────────────────────────────────────────────────────

function _validate_subgraphs!(
    diagnostics::Vector{DiagnosticRecord},
    spec::TypedSceneSpec,
    elements_by_id::Dict{String, ElementRecord}
)
    if isempty(spec.subgraphs)
        return
    end

    subgraphs_by_id = Dict{String, SubgraphRecord}()
    templates_by_id = Dict{String, SubgraphRecord}()
    for s in spec.subgraphs
        subgraphs_by_id[s.id] = s
        if s.role == :template
            templates_by_id[s.id] = s
        end
    end

    # 1. SUBGRAPH_003_TEMPLATE_NOT_FOUND
    for s in spec.subgraphs
        if s.template_id !== nothing && !isempty(s.template_id)
            if !haskey(templates_by_id, s.template_id)
                push!(diagnostics, DiagnosticRecord(
                    "SUBGRAPH_003_TEMPLATE_NOT_FOUND",
                    :error,
                    "subgraph",
                    s.id,
                    "template_id",
                    "Subgraph '$(s.id)' references non-existent template '$(s.template_id)'",
                    "Define a template with id '$(s.template_id)' or fix template_id reference"
                ))
            end
        end
    end

    # 2. SUBGRAPH_001_RECURSIVE_CYCLE
    visited = Dict{String, Int}() # 0=unvisited, 1=in-stack, 2=done
    for s in spec.subgraphs
        visited[s.id] = 0
    end

    function _detect_sub_cycle(curr_id::String, stack::Vector{String})
        visited[curr_id] = 1
        push!(stack, curr_id)

        curr_sub = get(subgraphs_by_id, curr_id, nothing)
        if curr_sub !== nothing && curr_sub.template_id !== nothing && haskey(subgraphs_by_id, curr_sub.template_id)
            target = curr_sub.template_id
            if get(visited, target, 0) == 1
                cycle_str = join(vcat(stack, [target]), " -> ")
                push!(diagnostics, DiagnosticRecord(
                    "SUBGRAPH_001_RECURSIVE_CYCLE",
                    :error,
                    "subgraph",
                    curr_id,
                    "template_id",
                    "Recursive template/subgraph cycle detected: $cycle_str",
                    "Break the cyclic template reference in subgraph '$curr_id'"
                ))
            elseif get(visited, target, 0) == 0
                _detect_sub_cycle(target, stack)
            end
        end

        pop!(stack)
        visited[curr_id] = 2
    end

    for s in spec.subgraphs
        if get(visited, s.id, 0) == 0
            _detect_sub_cycle(s.id, String[])
        end
    end

    # 3. SUBGRAPH_002_PORT_NOT_FOUND
    for s in spec.subgraphs
        avail_elem_ids = Set{String}(s.elements)
        if s.template_id !== nothing && haskey(templates_by_id, s.template_id)
            union!(avail_elem_ids, templates_by_id[s.template_id].elements)
        end

        for ep in s.exposed_ports
            pid = string(get(ep, "id", get(ep, "name", get(ep, "port_id", ""))))
            telem = string(get(ep, "target_element", get(ep, "internal_element", get(ep, "element", ""))))
            tport = string(get(ep, "target_port", get(ep, "internal_port", get(ep, "port", ""))))

            if isempty(telem) || !(telem in avail_elem_ids)
                push!(diagnostics, DiagnosticRecord(
                    "SUBGRAPH_002_PORT_NOT_FOUND",
                    :error,
                    "subgraph",
                    s.id,
                    "exposed_ports",
                    "Exposed port '$(pid)' references non-existent internal element '$(telem)' in subgraph '$(s.id)'",
                    "Reference a valid internal element defined in the subgraph or its template"
                ))
            else
                elem_rec = get(elements_by_id, telem, nothing)
                if elem_rec !== nothing
                    port_rec = _find_port_on_element(elem_rec, tport)
                    if port_rec === nothing
                        push!(diagnostics, DiagnosticRecord(
                            "SUBGRAPH_002_PORT_NOT_FOUND",
                            :error,
                            "subgraph",
                            s.id,
                            "exposed_ports",
                            "Exposed port '$(pid)' references non-existent internal port '$(tport)' on element '$(telem)'",
                            "Reference an existing port on internal element '$(telem)'"
                        ))
                    end
                end
            end
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Internal Pass 4: Connection & Port Rules
# ─────────────────────────────────────────────────────────────────────────────

const VALID_KIND_PAIRS = Set{Tuple{Symbol, Symbol}}([
    (:flow, :flow),
    (:metric, :signal),
    (:metric, :control),
    (:signal, :signal),
    (:signal, :control),
    (:event, :event),
    (:event, :control),
    (:control, :control)
])

function _find_port_on_element(elem::ElementRecord, port_id_or_name::String)::Union{PortRecord, Nothing}
    # Check by id first
    for p in elem.output_ports
        if p.id == port_id_or_name || p.name == port_id_or_name
            return p
        end
    end
    for p in elem.input_ports
        if p.id == port_id_or_name || p.name == port_id_or_name
            return p
        end
    end
    for p in elem.metric_ports
        if p.id == port_id_or_name || p.name == port_id_or_name
            return p
        end
    end
    return nothing
end

function _find_port_on_subgraph(
    sub::SubgraphRecord,
    port_id_or_name::String,
    elements_by_id::Dict{String, ElementRecord},
    templates_by_id::Dict{String, SubgraphRecord}
)::Union{PortRecord, Nothing}
    # Check directly exposed ports
    for ep in sub.exposed_ports
        pid = string(get(ep, "id", get(ep, "name", get(ep, "port_id", ""))))
        if pid == port_id_or_name
            telem = string(get(ep, "target_element", get(ep, "internal_element", get(ep, "element", ""))))
            tport = string(get(ep, "target_port", get(ep, "internal_port", get(ep, "port", ""))))
            if haskey(elements_by_id, telem)
                internal_port = _find_port_on_element(elements_by_id[telem], tport)
                if internal_port !== nothing
                    return internal_port
                end
            end
            kind = Symbol(get(ep, "kind", "flow"))
            dir = Symbol(get(ep, "direction", "output"))
            card = Symbol(get(ep, "cardinality", "many"))
            return PortRecord(pid, pid, dir, kind, "any", card, false, nothing, nothing, Dict{String, Any}())
        end
    end

    # Check template exposed ports
    if sub.template_id !== nothing && haskey(templates_by_id, sub.template_id)
        tmpl = templates_by_id[sub.template_id]
        for ep in tmpl.exposed_ports
            pid = string(get(ep, "id", get(ep, "name", get(ep, "port_id", ""))))
            if pid == port_id_or_name
                telem = string(get(ep, "target_element", get(ep, "internal_element", get(ep, "element", ""))))
                tport = string(get(ep, "target_port", get(ep, "internal_port", get(ep, "port", ""))))
                if haskey(elements_by_id, telem)
                    internal_port = _find_port_on_element(elements_by_id[telem], tport)
                    if internal_port !== nothing
                        return internal_port
                    end
                end
                kind = Symbol(get(ep, "kind", "flow"))
                dir = Symbol(get(ep, "direction", "output"))
                card = Symbol(get(ep, "cardinality", "many"))
                return PortRecord(pid, pid, dir, kind, "any", card, false, nothing, nothing, Dict{String, Any}())
            end
        end
    end

    return nothing
end

function _validate_connections_and_ports!(
    diagnostics::Vector{DiagnosticRecord},
    spec::TypedSceneSpec,
    elements_by_id::Dict{String, ElementRecord};
    check_required::Bool=false
)
    # Track cardinality connection counts: (elem_id, port_id, direction) => count
    port_connection_counts = Dict{Tuple{String, String, Symbol}, Int}()

    subgraphs_by_id = Dict{String, SubgraphRecord}()
    templates_by_id = Dict{String, SubgraphRecord}()
    for s in spec.subgraphs
        subgraphs_by_id[s.id] = s
        if s.role == :template
            templates_by_id[s.id] = s
        end
    end

    for conn in spec.connections
        if !conn.enabled
            continue
        end

        src_elem = get(elements_by_id, conn.source_element, nothing)
        tgt_elem = get(elements_by_id, conn.target_element, nothing)
        src_sub = src_elem === nothing ? get(subgraphs_by_id, conn.source_element, nothing) : nothing
        tgt_sub = tgt_elem === nothing ? get(subgraphs_by_id, conn.target_element, nothing) : nothing

        # 1. Source element / subgraph existence
        if src_elem === nothing && src_sub === nothing
            push!(diagnostics, DiagnosticRecord(
                "PORT_001_NOT_FOUND",
                :error,
                "connection",
                conn.id,
                "source_element",
                "Source '$(conn.source_element)' does not exist in elements or subgraphs",
                "Connect to an existing element or subgraph"
            ))
            continue
        end

        # 2. Target element / subgraph existence
        if tgt_elem === nothing && tgt_sub === nothing
            push!(diagnostics, DiagnosticRecord(
                "PORT_001_NOT_FOUND",
                :error,
                "connection",
                conn.id,
                "target_element",
                "Target '$(conn.target_element)' does not exist in elements or subgraphs",
                "Connect to an existing element or subgraph"
            ))
            continue
        end

        # 3. Source port existence
        src_port = src_elem !== nothing ?
            _find_port_on_element(src_elem, conn.source_port) :
            _find_port_on_subgraph(src_sub, conn.source_port, elements_by_id, templates_by_id)

        if src_port === nothing
            parent_kind = src_elem !== nothing ? "element" : "subgraph"
            avail_outs = src_elem !== nothing ? [p.id for p in src_elem.output_ports] : [string(get(ep, "id", "")) for ep in src_sub.exposed_ports]
            fix = isempty(avail_outs) ? "Add output/exposed port to source $parent_kind" : "Connect from '$(avail_outs[1])'"
            push!(diagnostics, DiagnosticRecord(
                "PORT_001_NOT_FOUND",
                :error,
                "connection",
                conn.id,
                "source_port",
                "Source port '$(conn.source_port)' does not exist on $parent_kind '$(conn.source_element)'",
                fix
            ))
            continue
        end

        # 4. Target port existence
        tgt_port = tgt_elem !== nothing ?
            _find_port_on_element(tgt_elem, conn.target_port) :
            _find_port_on_subgraph(tgt_sub, conn.target_port, elements_by_id, templates_by_id)

        if tgt_port === nothing
            parent_kind = tgt_elem !== nothing ? "element" : "subgraph"
            avail_ins = tgt_elem !== nothing ? [p.id for p in tgt_elem.input_ports] : [string(get(ep, "id", "")) for ep in tgt_sub.exposed_ports]
            fix = isempty(avail_ins) ? "Add input/exposed port to target $parent_kind" : "Connect to '$(avail_ins[1])'"
            push!(diagnostics, DiagnosticRecord(
                "PORT_001_NOT_FOUND",
                :error,
                "connection",
                conn.id,
                "target_port",
                "Target port '$(conn.target_port)' does not exist on $parent_kind '$(conn.target_element)'",
                fix
            ))
            continue
        end

        # 5. Port Kinds Compatibility Check
        is_kind_compatible = is_connection_compatible(src_port.kind, tgt_port.kind) || ((src_port.kind, tgt_port.kind) in VALID_KIND_PAIRS)
        if !is_kind_compatible
            push!(diagnostics, DiagnosticRecord(
                "PORT_002_KIND_MISMATCH",
                :error,
                "connection",
                conn.id,
                "target_port",
                "Cannot connect $(src_port.kind) $(src_port.direction) port to $(tgt_port.kind) $(tgt_port.direction) port '$(tgt_port.id)'",
                "Connect to a compatible $(src_port.kind) input port"
            ))
            continue
        end

        # 6. Direction Mismatch Check (Source must be output, Target must be input)
        if src_port.direction != :output
            push!(diagnostics, DiagnosticRecord(
                "PORT_003_DIRECTION_MISMATCH",
                :error,
                "connection",
                conn.id,
                "source_port",
                "Source port '$(src_port.id)' has direction '$(src_port.direction)', expected 'output'",
                "Use an output port as connection source"
            ))
        end
        if tgt_port.direction != :input
            push!(diagnostics, DiagnosticRecord(
                "PORT_003_DIRECTION_MISMATCH",
                :error,
                "connection",
                conn.id,
                "target_port",
                "Target port '$(tgt_port.id)' has direction '$(tgt_port.direction)', expected 'input'",
                "Use an input port as connection target"
            ))
        end

        # Accumulate connection counts for cardinality check
        src_id = src_elem !== nothing ? src_elem.id : src_sub.id
        tgt_id = tgt_elem !== nothing ? tgt_elem.id : tgt_sub.id
        src_key = (src_id, src_port.id, :output)
        tgt_key = (tgt_id, tgt_port.id, :input)
        port_connection_counts[src_key] = get(port_connection_counts, src_key, 0) + 1
        port_connection_counts[tgt_key] = get(port_connection_counts, tgt_key, 0) + 1
    end

    # 7. Cardinality Validation (:one ports) & Required Ports Check
    for elem in spec.elements
        # Check input ports
        for p in elem.input_ports
            c_count = get(port_connection_counts, (elem.id, p.id, :input), 0)
            if p.cardinality == :one && c_count > 1
                push!(diagnostics, DiagnosticRecord(
                    "PORT_004_CARDINALITY_EXCEEDED",
                    :error,
                    "port",
                    p.id,
                    "cardinality",
                    "Input port '$(p.id)' on element '$(elem.id)' has cardinality 'one' but receives $c_count incoming connections",
                    "Remove extra connections or set port cardinality to 'many'"
                ))
            end
            if check_required && p.required && c_count == 0
                push!(diagnostics, DiagnosticRecord(
                    "PORT_005_REQUIRED_UNCONNECTED",
                    :warning,
                    "port",
                    p.id,
                    "required",
                    "Required input port '$(p.id)' on element '$(elem.id)' is not connected",
                    "Connect an incoming link to '$(p.id)'"
                ))
            end
        end

        # Check output ports
        for p in elem.output_ports
            c_count = get(port_connection_counts, (elem.id, p.id, :output), 0)
            if p.cardinality == :one && c_count > 1
                push!(diagnostics, DiagnosticRecord(
                    "PORT_004_CARDINALITY_EXCEEDED",
                    :error,
                    "port",
                    p.id,
                    "cardinality",
                    "Output port '$(p.id)' on element '$(elem.id)' has cardinality 'one' but feeds $c_count outgoing connections",
                    "Remove extra connections or set port cardinality to 'many'"
                ))
            end
            if check_required && p.required && c_count == 0
                push!(diagnostics, DiagnosticRecord(
                    "PORT_005_REQUIRED_UNCONNECTED",
                    :warning,
                    "port",
                    p.id,
                    "required",
                    "Required output port '$(p.id)' on element '$(elem.id)' is not connected",
                    "Connect an outgoing link from '$(p.id)'"
                ))
            end
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Internal Pass 4: Graph Topology & Cycle / Livelock Detection
# ─────────────────────────────────────────────────────────────────────────────

function _validate_graph_topology!(
    diagnostics::Vector{DiagnosticRecord},
    spec::TypedSceneSpec,
    elements_by_id::Dict{String, ElementRecord}
)
    if length(spec.elements) < 2
        return
    end

    # Build adjacency list for flow connections
    flow_adj = Dict{String, Vector{Tuple{String, Float64}}}()
    flow_degree = Dict{String, Int}()
    for elem in spec.elements
        flow_adj[elem.id] = Tuple{String, Float64}[]
        flow_degree[elem.id] = 0
    end
    for sub in spec.subgraphs
        flow_adj[sub.id] = Tuple{String, Float64}[]
        flow_degree[sub.id] = 0
    end

    for conn in spec.connections
        if !conn.enabled || conn.link_type != :flow
            continue
        end
        if haskey(flow_adj, conn.source_element) && haskey(flow_adj, conn.target_element)
            lat = conn.latency !== nothing ? conn.latency : 0.0
            push!(flow_adj[conn.source_element], (conn.target_element, lat))
            flow_degree[conn.source_element] = get(flow_degree, conn.source_element, 0) + 1
            flow_degree[conn.target_element] = get(flow_degree, conn.target_element, 0) + 1
        end
    end

    # 1. Disconnected island elements check
    for elem in spec.elements
        # Only check elements that belong to process flow libraries
        if startswith(elem.library, "SimElements/DES") || elem.kind in ["source", "queue", "server", "sink", "router", "delay"]
            if get(flow_degree, elem.id, 0) == 0
                push!(diagnostics, DiagnosticRecord(
                    "GRAPH_001_DISCONNECTED_ISLAND",
                    :warning,
                    "element",
                    elem.id,
                    "connections",
                    "Element '$(elem.id)' is isolated with no incoming or outgoing connections",
                    "Connect '$(elem.id)' to the process flow graph or remove it"
                ))
            end
        end
    end

    # 2. Zero-delay feedback cycle detection (causes discrete-event livelock)
    # Stateful buffers/stations that break zero-delay livelocks:
    stateful_kinds = Set{String}(["queue", "server", "conveyor", "buffer", "delay", "station"])

    visited = Dict{String, Int}() # 0=unvisited, 1=visiting (on stack), 2=visited
    for elem in spec.elements
        visited[elem.id] = 0
    end

    cycle_nodes = String[]
    has_delay_in_cycle = false

    function _dfs_cycle(node::String, path::Vector{String}, latencies::Vector{Float64})
        visited[node] = 1
        push!(path, node)

        for (neighbor, lat) in flow_adj[node]
            push!(latencies, lat)
            if visited[neighbor] == 1
                # Cycle detected!
                idx = findfirst(x -> x == neighbor, path)
                if idx !== nothing
                    actual_cycle = path[idx:end]
                    actual_latencies = latencies[idx:end]

                    # Check if cycle has stateful delay or buffer
                    has_buffer = any(n -> begin
                        e = get(elements_by_id, n, nothing)
                        e !== nothing && (e.kind in stateful_kinds)
                    end, actual_cycle)
                    has_latency = any(l -> l > 1e-6, actual_latencies)

                    if !has_buffer && !has_latency
                        cycle_str = join(vcat(actual_cycle, [neighbor]), " -> ")
                        push!(diagnostics, DiagnosticRecord(
                            "GRAPH_002_ZERO_DELAY_CYCLE",
                            :error,
                            "element",
                            actual_cycle[1],
                            "connections",
                            "Zero-delay feedback cycle detected along path: $cycle_str. This causes infinite discrete-event livelocks.",
                            "Add a queue, server, or positive latency (>0) along the feedback cycle"
                        ))
                    end
                end
            elseif visited[neighbor] == 0
                _dfs_cycle(neighbor, path, latencies)
            end
            pop!(latencies)
        end

        pop!(path)
        visited[node] = 2
    end

    for elem in spec.elements
        if visited[elem.id] == 0
            _dfs_cycle(elem.id, String[], Float64[])
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Internal Pass 5: ABM Configuration Rules
# ─────────────────────────────────────────────────────────────────────────────

const KNOWN_ABM_MODELS = Set{String}(["SFM", "ORCA", "HybridFSM", "SocialForce", "RuleBased"])

function _validate_abm_config!(
    diagnostics::Vector{DiagnosticRecord},
    spec::TypedSceneSpec
)
    if spec.abm_config === nothing || !spec.abm_config.enabled
        return
    end

    abm = spec.abm_config

    # Model name check
    if abm.model_name === nothing || isempty(strip(abm.model_name))
        push!(diagnostics, DiagnosticRecord(
            "ABM_001_INVALID_MODEL",
            :error,
            "abm_config",
            "abm_config",
            "model_name",
            "ABM is enabled but model_name is not specified",
            "Specify a registered model_name (e.g. 'SFM', 'ORCA', 'HybridFSM')"
        ))
    elseif !(abm.model_name in KNOWN_ABM_MODELS)
        push!(diagnostics, DiagnosticRecord(
            "ABM_001_INVALID_MODEL",
            :warning,
            "abm_config",
            "abm_config",
            "model_name",
            "Unregistered ABM model_name '$(abm.model_name)'",
            "Verify that model library '$(abm.model_library)' is installed"
        ))
    end

    # Simulation mode check
    if spec.simulation.mode != :abm_only && spec.simulation.mode != :hybrid
        push!(diagnostics, DiagnosticRecord(
            "ABM_001_INVALID_MODEL",
            :error,
            "abm_config",
            "abm_config",
            "simulation.mode",
            "ABM is enabled but simulation.mode is set to '$(spec.simulation.mode)'",
            "Change simulation.mode to 'abm_only' or 'hybrid'"
        ))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# 6. Extension Governance Rules
# ─────────────────────────────────────────────────────────────────────────────

const RESERVED_DOCUMENT_KEYS = Set{String}([
    "spec_version", "scene", "simulation", "abm_config", "spatial",
    "elements", "connections", "subgraphs", "overlays", "validation_metadata"
])

const RESERVED_ELEMENT_KEYS = Set{String}([
    "id", "name", "kind", "library", "library_version", "level_id",
    "transform", "geometry", "editor", "properties", "input_ports",
    "output_ports", "metric_ports", "vertical_extent", "visual"
])

const RESERVED_PORT_KEYS = Set{String}([
    "id", "name", "direction", "kind", "data_type", "cardinality",
    "required", "unit", "description"
])

const RESERVED_CONNECTION_KEYS = Set{String}([
    "id", "source_element", "source_port", "target_element", "target_port",
    "link_type", "enabled", "ordering", "condition", "latency", "capacity"
])

const RESERVED_LEVEL_KEYS = Set{String}([
    "id", "name", "elevation", "default_height", "visible"
])

const RESERVED_SUBGRAPH_KEYS = Set{String}([
    "id", "name", "role", "template_id", "template_version", "level_id", "transform",
    "elements", "connections", "exposed_ports", "parameter_overrides"
])

const VALID_EXTENSION_KEY_REGEX = r"^[a-zA-Z0-9_\-:/.]+$"

function _check_dict_keys!(diagnostics::Vector{DiagnosticRecord}, ext::AbstractDict, object_kind::String, object_id::String, path_prefix::String, reserved::Set{String})
    for (k, v) in ext
        sk = string(k)
        if sk == "extensions"
            if v isa AbstractDict
                _check_dict_keys!(diagnostics, v, object_kind, object_id, isempty(path_prefix) ? "extensions" : "$(path_prefix).extensions", Set{String}())
            end
            continue
        end

        prop_path = isempty(path_prefix) ? sk : "$(path_prefix).$(sk)"

        # EXT_001_INVALID_KEY: key format
        if isempty(sk) || !occursin(VALID_EXTENSION_KEY_REGEX, sk)
            push!(diagnostics, DiagnosticRecord(
                "EXT_001_INVALID_KEY",
                :error,
                object_kind,
                object_id,
                prop_path,
                "Invalid extension key '$(sk)' on $(object_kind) '$(object_id)'",
                "Use alphanumeric, underscore, hyphen, colon, or dot characters without spaces"
            ))
        end

        # EXT_002_RESERVED_KEY_CONFLICT: collision with schema
        if sk in reserved
            push!(diagnostics, DiagnosticRecord(
                "EXT_002_RESERVED_KEY_CONFLICT",
                :error,
                object_kind,
                object_id,
                prop_path,
                "Extension key '$(sk)' conflicts with reserved core schema field on $(object_kind) '$(object_id)'",
                "Rename extension key or nest under a vendor namespace"
            ))
        end

        # If v is a nested dictionary, validate its keys recursively
        if v isa AbstractDict
            _check_dict_keys!(diagnostics, v, object_kind, object_id, prop_path, Set{String}())
        end
    end
end

function _validate_extensions!(diagnostics::Vector{DiagnosticRecord}, spec::TypedSceneSpec)
    # 1. Document level extensions
    _check_dict_keys!(diagnostics, spec.extensions, "document", spec.scene.id, "extensions", RESERVED_DOCUMENT_KEYS)
    _check_dict_keys!(diagnostics, spec.scene.extensions, "scene", spec.scene.id, "scene.extensions", Set{String}())
    _check_dict_keys!(diagnostics, spec.simulation.extensions, "simulation", "simulation", "simulation.extensions", Set{String}())
    if spec.spatial !== nothing
        _check_dict_keys!(diagnostics, spec.spatial.extensions, "spatial", "spatial", "spatial.extensions", Set{String}())
        for lvl in spec.spatial.levels
            _check_dict_keys!(diagnostics, lvl.extensions, "level", lvl.id, "spatial.levels[$(lvl.id)].extensions", RESERVED_LEVEL_KEYS)
        end
    end

    # 2. Elements & Ports
    for elem in spec.elements
        _check_dict_keys!(diagnostics, elem.extensions, "element", elem.id, "elements[$(elem.id)].extensions", RESERVED_ELEMENT_KEYS)
        for p in elem.input_ports
            _check_dict_keys!(diagnostics, p.extensions, "port", p.id, "elements[$(elem.id)].input_ports[$(p.id)].extensions", RESERVED_PORT_KEYS)
        end
        for p in elem.output_ports
            _check_dict_keys!(diagnostics, p.extensions, "port", p.id, "elements[$(elem.id)].output_ports[$(p.id)].extensions", RESERVED_PORT_KEYS)
        end
        for p in elem.metric_ports
            _check_dict_keys!(diagnostics, p.extensions, "port", p.id, "elements[$(elem.id)].metric_ports[$(p.id)].extensions", RESERVED_PORT_KEYS)
        end
    end

    # 3. Connections
    for conn in spec.connections
        _check_dict_keys!(diagnostics, conn.extensions, "connection", conn.id, "connections[$(conn.id)].extensions", RESERVED_CONNECTION_KEYS)
    end

    # 4. Subgraphs
    for s in spec.subgraphs
        _check_dict_keys!(diagnostics, s.extensions, "subgraph", s.id, "subgraphs[$(s.id)].extensions", RESERVED_SUBGRAPH_KEYS)
    end
end
