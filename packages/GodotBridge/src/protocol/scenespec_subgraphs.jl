# ============================================================================
# SceneSpec Hierarchical Subgraph Expansion Engine (Phase 7D-04)
#
# Implements Two-Phase Compilation (Zero-Cost Abstraction):
# - Full hierarchical flexibility and relative transforms during authoring
# - Flat, cache-aligned, integer/symbol-indexed memory during simulation
# - Bidirectional source mapping (runtime_id <-> hierarchical path)
# - Hardware-agnostic transform composition via KernelAbstractions.jl
# ============================================================================

"""
    SubgraphSourceMap

Bidirectional traceability mapping between compiled flat runtime entities
and authored hierarchical subgraphs and templates.
- `runtime_to_hierarchical`: `flat_id => (subgraph_id, local_id, template_id)`
- `hierarchical_to_runtime`: `(subgraph_id, local_id) => flat_id`
- `port_forwarding`: `(subgraph_id, exposed_port) => (internal_elem_id, internal_port)`
"""
struct SubgraphSourceMap
    runtime_to_hierarchical::Dict{String, Tuple{String, String, Union{String, Nothing}}}
    hierarchical_to_runtime::Dict{Tuple{String, String}, String}
    port_forwarding::Dict{Tuple{String, String}, Tuple{String, String}}
end

function SubgraphSourceMap()
    return SubgraphSourceMap(
        Dict{String, Tuple{String, String, Union{String, Nothing}}}(),
        Dict{Tuple{String, String}, String}(),
        Dict{Tuple{String, String}, Tuple{String, String}}()
    )
end

"""
    CompiledSceneGraph

The result of compiling a hierarchical `TypedSceneSpec`:
- `flat_spec`: The expanded, flat `TypedSceneSpec` ready for simulation
- `spatial_soa`: GPU-ready Structure-of-Arrays memory buffer
- `source_map`: Bidirectional trace mapping
- `hierarchy_tree`: Preserved hierarchical relationship tree for telemetry roll-ups
"""
struct CompiledSceneGraph
    flat_spec::TypedSceneSpec
    spatial_soa::SpatialBufferSoA
    source_map::SubgraphSourceMap
    hierarchy_tree::Dict{String, Any}
end

# ─────────────────────────────────────────────────────────────────────────────
# Parameter Override Resolution
# ─────────────────────────────────────────────────────────────────────────────

"""
    _apply_parameter_overrides(properties::Dict{String, Any}, local_id::String, overrides::Dict{String, Any})::Dict{String, Any}

Applies scoped parameter overrides to an element's property dictionary.
Supports:
1. Exact element scoped: `"srv_proc.service_time" => 5.0`
2. Wildcard scoped: `"*.capacity" => 100`
3. Direct property matching: `"service_time" => 5.0` (if matching key exists)
"""
function _apply_parameter_overrides(
    properties::Dict{String, Any},
    local_id::String,
    overrides::Dict{String, Any}
)::Dict{String, Any}
    if isempty(overrides)
        return copy(properties)
    end

    res = copy(properties)
    prefix_exact = local_id * "."

    for (k, v) in overrides
        if startswith(k, prefix_exact)
            prop_key = k[(length(prefix_exact) + 1):end]
            res[prop_key] = v
        elseif startswith(k, "*.")
            prop_key = k[3:end]
            res[prop_key] = v
        elseif haskey(res, k)
            res[k] = v
        end
    end

    return res
end

# ─────────────────────────────────────────────────────────────────────────────
# Port Target Resolution Helper
# ─────────────────────────────────────────────────────────────────────────────

function _resolve_exposed_port_target(exposed::Dict{String, Any})
    target_elem = string(get(exposed, "target_element", get(exposed, "internal_element", get(exposed, "element", ""))))
    target_port = string(get(exposed, "target_port", get(exposed, "internal_port", get(exposed, "port", ""))))
    port_id = string(get(exposed, "id", get(exposed, "name", get(exposed, "port_id", ""))))
    return (port_id, target_elem, target_port)
end

# ─────────────────────────────────────────────────────────────────────────────
# Recursive Subgraph Expansion
# ─────────────────────────────────────────────────────────────────────────────

const MAX_SUBGRAPH_DEPTH = 16

struct SubgraphExpansionContext
    delimiter::String
    templates::Dict{String, SubgraphRecord}
    all_subgraphs::Dict{String, SubgraphRecord}
    proto_elements::Dict{String, ElementRecord}
    proto_connections::Dict{String, ConnectionRecord}
    source_map::SubgraphSourceMap
    hierarchy_tree::Dict{String, Any}
end

function _expand_compound_instance!(
    ctx::SubgraphExpansionContext,
    sub::SubgraphRecord,
    parent_path::String,
    parent_transform::TransformRecord,
    parent_level::Union{String, Nothing},
    depth::Int,
    flat_elements::Vector{ElementRecord},
    flat_connections::Vector{ConnectionRecord},
    visited_templates::Set{String}
)
    if depth > MAX_SUBGRAPH_DEPTH
        error("Cyclic or excessively deep subgraph nesting detected at '$(sub.id)' (depth > $MAX_SUBGRAPH_DEPTH)")
    end

    current_path = isempty(parent_path) ? sub.id : string(parent_path, ctx.delimiter, sub.id)

    # Resolve active transform
    sub_trans = sub.transform !== nothing ? sub.transform : TransformRecord((0.0, 0.0, 0.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0))
    composed_transform = compose_transforms(parent_transform, sub_trans)

    # Resolve active level
    effective_level = sub.level_id !== nothing ? sub.level_id : (parent_level !== nothing ? parent_level : "level_ground")

    # Record hierarchy tree entry
    tree_node = Dict{String, Any}(
        "id" => sub.id,
        "path" => current_path,
        "name" => sub.name,
        "role" => string(sub.role),
        "template_id" => sub.template_id,
        "children" => Dict{String, Any}(),
        "elements" => String[],
        "connections" => String[]
    )

    # Map exposed boundary ports for this instance
    for ep in sub.exposed_ports
        pid, telem, tport = _resolve_exposed_port_target(ep)
        if !isempty(pid) && !isempty(telem) && !isempty(tport)
            full_telem = string(current_path, ctx.delimiter, telem)
            ctx.source_map.port_forwarding[(current_path, pid)] = (full_telem, tport)
        end
    end

    # Retrieve template if specified
    local_elem_ids = copy(sub.elements)
    local_conn_ids = copy(sub.connections)
    tmpl_record = nothing

    if sub.template_id !== nothing
        if sub.template_id in visited_templates
            error("Recursive template cycle detected in '$(sub.id)' referencing template '$(sub.template_id)'")
        end
        tmpl_record = get(ctx.templates, sub.template_id, nothing)
        if tmpl_record !== nothing
            # Inherit elements, connections, and exposed ports from template if not overridden
            if isempty(local_elem_ids)
                append!(local_elem_ids, tmpl_record.elements)
            end
            if isempty(local_conn_ids)
                append!(local_conn_ids, tmpl_record.connections)
            end
            for ep in tmpl_record.exposed_ports
                pid, telem, tport = _resolve_exposed_port_target(ep)
                if !isempty(pid) && !haskey(ctx.source_map.port_forwarding, (current_path, pid))
                    full_telem = string(current_path, ctx.delimiter, telem)
                    ctx.source_map.port_forwarding[(current_path, pid)] = (full_telem, tport)
                end
            end
        end
    end

    new_visited = copy(visited_templates)
    if sub.template_id !== nothing
        push!(new_visited, sub.template_id)
    end

    # Expand child elements
    for eid in local_elem_ids
        proto = get(ctx.proto_elements, eid, nothing)
        if proto !== nothing
            flat_id = string(current_path, ctx.delimiter, proto.id)
            
            # Compose physical transform
            elem_composed_trans = compose_transforms(composed_transform, proto.transform)

            # Apply parameter overrides
            merged_props = _apply_parameter_overrides(proto.properties, proto.id, sub.parameter_overrides)

            # Resolve level
            elem_level = !isempty(proto.level_id) && proto.level_id != "level_ground" ? proto.level_id : effective_level

            new_elem = ElementRecord(
                flat_id,
                string(sub.name, " / ", proto.name),
                proto.kind,
                proto.library,
                proto.library_version,
                elem_level,
                elem_composed_trans,
                proto.geometry,
                proto.editor,
                merged_props,
                proto.input_ports,
                proto.output_ports,
                proto.metric_ports,
                proto.vertical_extent,
                proto.visual,
                proto.extensions
            )
            push!(flat_elements, new_elem)

            # Record source mapping
            ctx.source_map.runtime_to_hierarchical[flat_id] = (current_path, proto.id, sub.template_id)
            ctx.source_map.hierarchical_to_runtime[(current_path, proto.id)] = flat_id
            push!(tree_node["elements"], flat_id)
        end
    end

    # Expand internal connections
    for cid in local_conn_ids
        proto_conn = get(ctx.proto_connections, cid, nothing)
        if proto_conn !== nothing
            new_cid = string(current_path, ctx.delimiter, proto_conn.id)
            new_src_elem = string(current_path, ctx.delimiter, proto_conn.source_element)
            new_tgt_elem = string(current_path, ctx.delimiter, proto_conn.target_element)

            new_conn = ConnectionRecord(
                new_cid,
                new_src_elem,
                proto_conn.source_port,
                new_tgt_elem,
                proto_conn.target_port,
                proto_conn.link_type,
                proto_conn.enabled,
                proto_conn.ordering,
                proto_conn.condition,
                proto_conn.latency,
                proto_conn.capacity,
                proto_conn.extensions
            )
            push!(flat_connections, new_conn)
            push!(tree_node["connections"], new_cid)
        end
    end

    ctx.hierarchy_tree[current_path] = tree_node
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# compile_scene_graph & expand_subgraphs API
# ─────────────────────────────────────────────────────────────────────────────

"""
    expand_subgraphs(spec::TypedSceneSpec; delimiter::String="::")::Tuple{TypedSceneSpec, SubgraphSourceMap, Dict{String, Any}}

Expands all compound subgraphs and groups in `spec`, rewiring boundary connections
and composing nested transforms.
Returns `(flat_spec, source_map, hierarchy_tree)`.
"""
function expand_subgraphs_with_meta(spec::TypedSceneSpec; delimiter::String="::")
    # Identify templates, subgraphs, and prototype element pools
    templates = Dict{String, SubgraphRecord}()
    all_subgraphs = Dict{String, SubgraphRecord}()
    compound_or_group = SubgraphRecord[]

    for s in spec.subgraphs
        all_subgraphs[s.id] = s
        if s.role == :template
            templates[s.id] = s
        else
            push!(compound_or_group, s)
        end
    end

    proto_elements = Dict{String, ElementRecord}()
    for e in spec.elements
        proto_elements[e.id] = e
    end

    proto_connections = Dict{String, ConnectionRecord}()
    for c in spec.connections
        proto_connections[c.id] = c
    end

    # Collect template element IDs so they are not emitted as standalone top-level elements
    template_elem_ids = Set{String}()
    template_conn_ids = Set{String}()
    for (_, tmpl) in templates
        union!(template_elem_ids, tmpl.elements)
        union!(template_conn_ids, tmpl.connections)
    end

    source_map = SubgraphSourceMap()
    hierarchy_tree = Dict{String, Any}()
    ctx = SubgraphExpansionContext(
        delimiter,
        templates,
        all_subgraphs,
        proto_elements,
        proto_connections,
        source_map,
        hierarchy_tree
    )

    flat_elements = ElementRecord[]
    flat_connections = ConnectionRecord[]

    # 1. Retain existing top-level elements that are not uninstantiated template blueprints
    for e in spec.elements
        if !(e.id in template_elem_ids)
            push!(flat_elements, e)
            source_map.runtime_to_hierarchical[e.id] = ("", e.id, nothing)
            source_map.hierarchical_to_runtime[("", e.id)] = e.id
        end
    end

    # 2. Expand each compound / group subgraph
    identity_transform = TransformRecord((0.0, 0.0, 0.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0))
    for sub in compound_or_group
        _expand_compound_instance!(
            ctx,
            sub,
            "",
            identity_transform,
            sub.level_id,
            1,
            flat_elements,
            flat_connections,
            Set{String}()
        )
    end

    # 3. Process top-level connections: retain non-template ones, and rewire subgraph boundary ports
    for c in spec.connections
        if c.id in template_conn_ids
            continue
        end

        src_elem = c.source_element
        src_port = c.source_port
        tgt_elem = c.target_element
        tgt_port = c.target_port

        # Check if source endpoint targets an exposed subgraph boundary port
        if haskey(source_map.port_forwarding, (src_elem, src_port))
            new_src_elem, new_src_port = source_map.port_forwarding[(src_elem, src_port)]
            src_elem = new_src_elem
            src_port = new_src_port
        end

        # Check if target endpoint targets an exposed subgraph boundary port
        if haskey(source_map.port_forwarding, (tgt_elem, tgt_port))
            new_tgt_elem, new_tgt_port = source_map.port_forwarding[(tgt_elem, tgt_port)]
            tgt_elem = new_tgt_elem
            tgt_port = new_tgt_port
        end

        rewired_conn = ConnectionRecord(
            c.id,
            src_elem,
            src_port,
            tgt_elem,
            tgt_port,
            c.link_type,
            c.enabled,
            c.ordering,
            c.condition,
            c.latency,
            c.capacity,
            c.extensions
        )
        push!(flat_connections, rewired_conn)
    end

    flat_spec = TypedSceneSpec(
        spec.spec_version,
        spec.scene,
        spec.simulation,
        spec.abm_config,
        spec.spatial,
        flat_elements,
        flat_connections,
        spec.subgraphs,
        spec.overlays,
        spec.validation_metadata,
        spec.extensions
    )

    return (flat_spec, source_map, hierarchy_tree)
end

"""
    expand_subgraphs(spec::TypedSceneSpec; delimiter::String="::")::TypedSceneSpec

Convenience wrapper expanding compound subgraphs and returning the flat `TypedSceneSpec`.
"""
function expand_subgraphs(spec::TypedSceneSpec; delimiter::String="::")::TypedSceneSpec
    flat_spec, _, _ = expand_subgraphs_with_meta(spec; delimiter=delimiter)
    return flat_spec
end

"""
    compile_scene_graph(spec::TypedSceneSpec; delimiter::String="::", backend=AutoBackend())::CompiledSceneGraph

Comprehensive two-phase compiler:
1. Expands compound subgraphs and resolves hierarchical boundary port rewirings.
2. Bakes parameter overrides.
3. Computes packed GPU/CPU Structure-of-Arrays memory buffer via `resolve_all_transforms`.
4. Assembles bidirectional trace map and hierarchy roll-up tree.
"""
function compile_scene_graph(
    spec::TypedSceneSpec;
    delimiter::String="::",
    backend::AbstractExecutionBackend=AutoBackend()
)::CompiledSceneGraph
    flat_spec, source_map, hierarchy_tree = expand_subgraphs_with_meta(spec; delimiter=delimiter)
    spatial_soa = resolve_all_transforms(flat_spec; backend=backend)
    return CompiledSceneGraph(flat_spec, spatial_soa, source_map, hierarchy_tree)
end

"""
    query_hierarchical_metric(
        compiled::CompiledSceneGraph,
        subgraph_id::String,
        metrics_by_elem::Dict{String, T}
    )::Float64 where {T<:Real}

Zero-cost roll-up helper aggregating child metrics for a subgraph across its flattened elements.
Sums the scalar values of all elements within `subgraph_id`.
"""
function query_hierarchical_metric(
    compiled::CompiledSceneGraph,
    subgraph_id::String,
    metrics_by_elem::Dict{String, T}
)::Float64 where {T<:Real}
    node = get(compiled.hierarchy_tree, subgraph_id, nothing)
    if node === nothing
        # Try matching by prefix in source_map
        total = 0.0
        for (elem_id, val) in metrics_by_elem
            if haskey(compiled.source_map.runtime_to_hierarchical, elem_id)
                sub_path, _, _ = compiled.source_map.runtime_to_hierarchical[elem_id]
                if sub_path == subgraph_id || startswith(sub_path, subgraph_id * "::")
                    total += Float64(val)
                end
            end
        end
        return total
    end

    elem_ids = get(node, "elements", String[])
    total = 0.0
    for eid in elem_ids
        if haskey(metrics_by_elem, eid)
            total += Float64(metrics_by_elem[eid])
        end
    end
    return total
end

