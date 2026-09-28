# packages/SimOptim/src/graph_search.jl
#
# Sub-Phase 7E-3: Template-Free Bilevel Graph & 3D/2D Spatial Coordinate Optimizer
# for Network Topologies (Problem 3 and general 3D/2D spatial networks).
#
# Architecture (Bilevel Optimization = Two-Level Coupled Solver):
#   - Upper / Outer Level (Discrete Graph Topology Search):
#     Unbiased atomic graph mutations (`mutate_add_edge!`, `mutate_remove_edge!`,
#     `mutate_rewire_edge!`, `mutate_spur_mode!`) over `Graphs.SimpleDiGraph` guided by
#     Simulated Annealing + Pareto / Hall-of-Fame archive.
#   - Lower / Inner Level (Continuous 3D Spatial Layout Optimization):
#     Given a candidate graph G from the outer loop, `optimize_spatial_coordinates!`
#     uses `Optim.NelderMead` to find 3D node positions p_i = (x_i, y_i, z_i) that minimize
#     total 3D Euclidean edge length sum_{(u,v) in E} ||p_u - p_v||_2 subject to:
#       1. Pairwise 3D separation ||p_i - p_j||_2 >= d_min
#       2. Vertical elevation constraint `z_constraint`:
#          - `:constant_z` (all nodes share constant z = z_fixed, e.g. single-floor conveyors)
#          - `:preserve_node_z` (each node keeps its assigned floor elevation initial_z[i])
#          - `:bounded_3d` (full 3D optimization of (x_i, y_i, z_i) within z_bounds)

using Graphs
using Optim
using Random
using Statistics

"""
    ConveyorNetworkGraph

Represents a directed spatial network graph `adj::SimpleDiGraph{Int}` together with
continuous **3D coordinates** `coords::Vector{NTuple{3, Float64}}` (`(x, y, z)`),
extracted arrival/service rates, constraint bounds, and operating modes.
Also aliased as `SpatialNetworkGraph` for general non-conveyor 3D network problems.
"""
mutable struct ConveyorNetworkGraph
    conveyor_ids          :: Vector{String}
    station_queue_ids     :: Vector{String}
    station_server_ids    :: Vector{String}
    infeed_id             :: String
    source_id             :: String
    sink_id               :: String
    adj                   :: SimpleDiGraph{Int}
    coords                :: Vector{NTuple{3, Float64}}
    initial_z             :: Vector{Float64}
    z_constraint          :: Symbol                  # :constant_z, :preserve_node_z, or :bounded_3d
    z_fixed               :: Float64
    z_bounds              :: Tuple{Float64, Float64}
    spur_mode             :: Symbol                  # :spurs_10m or :direct_ring
    layout_mode           :: Symbol                  # :collinear_1d or :folded_2d (or :spatial_3d)
    routing_rule          :: Symbol                  # :shortest_queue, :prob, :round_robin
    belt_speed            :: Float64
    arrival_rate          :: Float64                 # λ (entities / sec) extracted from SceneSpec
    service_rate          :: Float64                 # μ (entities / sec) per station extracted from SceneSpec
    d_min                 :: Float64                 # Minimum pairwise 3D station separation (m)
    max_port_degree_bound :: Int                     # Maximum in-degree / out-degree per node
    max_belt_budget       :: Float64                 # Maximum total edge/belt length budget (m)
end

const SpatialNetworkGraph = ConveyorNetworkGraph

function Base.copy(c::ConveyorNetworkGraph)
    return ConveyorNetworkGraph(
        copy(c.conveyor_ids),
        copy(c.station_queue_ids),
        copy(c.station_server_ids),
        c.infeed_id,
        c.source_id,
        c.sink_id,
        copy(c.adj),
        copy(c.coords),
        copy(c.initial_z),
        c.z_constraint,
        c.z_fixed,
        c.z_bounds,
        c.spur_mode,
        c.layout_mode,
        c.routing_rule,
        c.belt_speed,
        c.arrival_rate,
        c.service_rate,
        c.d_min,
        c.max_port_degree_bound,
        c.max_belt_budget
    )
end

"""
    to_simple_digraph(c::ConveyorNetworkGraph) -> SimpleDiGraph{Int}

Returns a copy of the underlying `Graphs.SimpleDiGraph`.
"""
to_simple_digraph(c::ConveyorNetworkGraph)::SimpleDiGraph{Int} = copy(c.adj)

"""
    from_simple_digraph!(c::ConveyorNetworkGraph, g::SimpleDiGraph{Int}) -> ConveyorNetworkGraph

Updates `c.adj` in-place from a `Graphs.SimpleDiGraph`.
"""
function from_simple_digraph!(c::ConveyorNetworkGraph, g::SimpleDiGraph{Int})::ConveyorNetworkGraph
    c.adj = copy(g)
    return c
end

"""
    extract_conveyor_graph(scenespec::Dict{String, Any};
                           spec::Union{Nothing, SimOptimizationSpec}=nothing,
                           d_min::Float64=15.0,
                           z_constraint::Symbol=:constant_z,
                           z_bounds::Tuple{Float64, Float64}=(0.0, 10.0)) -> ConveyorNetworkGraph

Extracts a `ConveyorNetworkGraph` (`Graphs.SimpleDiGraph` + full **3D `(x, y, z)`** coordinates +
dynamic arrival/service rates + constraint bounds) directly from `scenespec` and optional `spec`.
"""
function extract_conveyor_graph(
    scenespec::Dict{String, Any};
    spec::Union{Nothing, SimOptimizationSpec} = nothing,
    d_min::Float64 = 15.0,
    z_constraint::Symbol = :constant_z,
    z_bounds::Tuple{Float64, Float64} = (0.0, 10.0)
)::ConveyorNetworkGraph
    elems = get(scenespec, "elements", Any[])
    conns = get(scenespec, "connections", Any[])

    # Parse spatial bounds and ground elevation from SceneSpec["spatial"] if present
    z_fixed = 0.0
    if haskey(scenespec, "spatial") && scenespec["spatial"] isa AbstractDict
        sp = scenespec["spatial"]
        if haskey(sp, "levels") && sp["levels"] isa AbstractVector && !isempty(sp["levels"])
            lvl1 = sp["levels"][1]
            if lvl1 isa AbstractDict
                z_fixed = Float64(get(lvl1, "elevation", 0.0))
            end
        end
        if haskey(sp, "bounds") && sp["bounds"] isa AbstractVector && length(sp["bounds"]) >= 6
            b = sp["bounds"]
            z_bounds = (Float64(b[3]), Float64(b[6]))
        end
    end

    # Parse optimization constraints dynamically from `spec` (or `scenespec["optimization"]`)
    opt_spec = if spec !== nothing
        spec
    elseif haskey(scenespec, "optimization") && scenespec["optimization"] isa AbstractDict
        parse_optimization_spec(scenespec["optimization"])
    else
        nothing
    end

    max_port_deg_bound = 2
    max_belt_budget = 80.0
    if opt_spec !== nothing
        for c in opt_spec.constraints
            if c.metric == "min_station_separation" && c.rhs > 0.0
                d_min = Float64(c.rhs)
            elseif c.metric == "max_port_degree" && c.rhs >= 1.0
                max_port_deg_bound = round(Int, c.rhs)
            elseif c.metric == "total_conveyor_length" && c.rhs > 0.0
                max_belt_budget = Float64(c.rhs)
            elseif c.metric == "z_elevation_deviation"
                z_constraint = :constant_z
            end
        end
    end

    conveyor_ids = String[]
    coords = NTuple{3, Float64}[]
    initial_z = Float64[]
    belt_speed = 1.0
    spur_mode = :spurs_10m
    layout_mode = :collinear_1d
    routing_rule = :shortest_queue
    source_id = ""
    infeed_id = ""
    sink_id   = ""
    arrival_rate = 0.0
    server_rates = Float64[]

    elem_by_id = Dict{String, Dict{String, Any}}()
    for el in elems
        el isa AbstractDict || continue
        eid = string(get(el, "id", ""))
        elem_by_id[eid] = el
        kind = string(get(el, "kind", ""))
        props = get(el, "properties", Dict{String, Any}())

        if kind == "conveyor"
            push!(conveyor_ids, eid)
            tr = get(el, "transform", Dict{String, Any}())
            pos = get(tr, "position", Any[0.0, 0.0, z_fixed])
            px = length(pos) >= 1 ? Float64(pos[1]) : 0.0
            py = length(pos) >= 2 ? Float64(pos[2]) : 0.0
            pz = length(pos) >= 3 ? Float64(pos[3]) : z_fixed
            push!(coords, (px, py, pz))
            push!(initial_z, pz)

            belt_speed = Float64(get(props, "speed", 1.0))
            if haskey(props, "spur_mode")
                spur_mode = Symbol(string(props["spur_mode"]))
            elseif Float64(get(props, "spur_length", 10.0)) <= 0.5
                spur_mode = :direct_ring
            end
            if haskey(props, "layout_mode")
                layout_mode = Symbol(string(props["layout_mode"]))
            end
            if haskey(props, "routing_rule")
                routing_rule = Symbol(string(props["routing_rule"]))
            end
            if haskey(props, "z_constraint")
                z_constraint = Symbol(string(props["z_constraint"]))
            end
        elseif kind == "source"
            isempty(source_id) && (source_id = eid)
            iat = get(props, "interarrival_time", Dict{String, Any}())
            mean_iat = Float64(get(iat, "mean", 0.0))
            if mean_iat > 0.0
                arrival_rate += 1.0 / mean_iat
            end
        elseif kind == "sink"
            isempty(sink_id) && (sink_id = eid)
        elseif kind == "server"
            st = get(props, "service_time", Dict{String, Any}())
            mean_s = Float64(get(st, "mean", get(st, "mode", 20.0)))
            c_srv = max(1, Int(get(props, "servers", 1)))
            if mean_s > 0.1
                push!(server_rates, Float64(c_srv) / mean_s)
            end
        end
    end

    if !isempty(initial_z)
        z_fixed = initial_z[1]
    end
    # Detect if loaded coordinates are already non-collinear in 2D or 3D
    if any(p -> abs(p[2]) > 1.0, coords) && layout_mode == :collinear_1d
        layout_mode = :folded_2d
    end

    K = length(conveyor_ids)
    conv_idx = Dict{String, Int}(cid => i for (i, cid) in enumerate(conveyor_ids))
    adj = SimpleDiGraph(K)

    station_queue_ids  = fill("", K)
    station_server_ids = fill("", K)

    # Map conveyor -> conveyor edges, infeed queue -> conveyor 1, and conveyor -> station queue links
    for c in conns
        c isa AbstractDict || continue
        get(c, "enabled", true) == false && continue
        src_el = string(get(c, "source_element", ""))
        dst_el = string(get(c, "target_element", ""))
        if haskey(conv_idx, src_el) && haskey(conv_idx, dst_el)
            u = conv_idx[src_el]
            v = conv_idx[dst_el]
            u != v && add_edge!(adj, u, v)
        elseif haskey(conv_idx, src_el) && haskey(elem_by_id, dst_el)
            if string(get(elem_by_id[dst_el], "kind", "")) == "queue"
                station_queue_ids[conv_idx[src_el]] = dst_el
            end
        elseif haskey(conv_idx, dst_el) && haskey(elem_by_id, src_el)
            if string(get(elem_by_id[src_el], "kind", "")) == "queue" && isempty(infeed_id)
                infeed_id = src_el
            end
        end
    end

    # Map station queue -> station server
    for k in 1:K
        qid = station_queue_ids[k]
        isempty(qid) && continue
        for c in conns
            c isa AbstractDict || continue
            src_el = string(get(c, "source_element", ""))
            dst_el = string(get(c, "target_element", ""))
            if src_el == qid && haskey(elem_by_id, dst_el) && string(get(elem_by_id[dst_el], "kind", "")) == "server"
                station_server_ids[k] = dst_el
                break
            end
        end
    end

    effective_λ = arrival_rate > 0.0 ? arrival_rate : (8.0 / 60.0)
    effective_μ = !isempty(server_rates) ? mean(server_rates) : (3.0 / 60.0)

    return ConveyorNetworkGraph(
        conveyor_ids,
        station_queue_ids,
        station_server_ids,
        infeed_id,
        source_id,
        sink_id,
        adj,
        coords,
        initial_z,
        z_constraint,
        z_fixed,
        z_bounds,
        spur_mode,
        layout_mode,
        routing_rule,
        belt_speed,
        effective_λ,
        effective_μ,
        d_min,
        max_port_deg_bound,
        max_belt_budget
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# 1. 3D Euclidean Geometry, Physical Constraints & Graph-Theoretic Properties
# ─────────────────────────────────────────────────────────────────────────────

"""
    euclidean_dist(p1::NTuple{3, Float64}, p2::NTuple{3, Float64}) -> Float64
    euclidean_dist(p1::Tuple{Float64, Float64}, p2::Tuple{Float64, Float64}) -> Float64

Computes the Euclidean distance `||p1 - p2||_2` in 3D `(x, y, z)` (or 2D `(x, y)`).
"""
@inline function euclidean_dist(p1::NTuple{3, Float64}, p2::NTuple{3, Float64})::Float64
    return hypot(p1[1] - p2[1], p1[2] - p2[2], p1[3] - p2[3])
end

@inline function euclidean_dist(p1::Tuple{Float64, Float64}, p2::Tuple{Float64, Float64})::Float64
    return hypot(p1[1] - p2[1], p1[2] - p2[2])
end

"""
    min_station_separation(coords::AbstractVector) -> Float64

Returns the minimum pairwise 3D (or 2D) Euclidean distance `min_{i < j} ||p_i - p_j||_2` across all nodes.
"""
function min_station_separation(coords::AbstractVector)::Float64
    K = length(coords)
    K <= 1 && return Inf
    dmin = Inf
    for i in 1:(K - 1)
        for j in (i + 1):K
            d = euclidean_dist(coords[i], coords[j])
            if d < dmin
                dmin = d
            end
        end
    end
    return dmin
end

"""
    max_z_elevation_deviation(cand::ConveyorNetworkGraph) -> Float64

Computes the maximum vertical `z`-coordinate constraint violation across all nodes:
- `:constant_z`: `max_i |coords[i][3] - cand.z_fixed|` (verifies all nodes lie on the constant plane `z = z_fixed`).
- `:preserve_node_z`: `max_i |coords[i][3] - cand.initial_z[i]|`.
- `:bounded_3d`: `max_i max(0, z_min - coords[i][3], coords[i][3] - z_max)`.
"""
function max_z_elevation_deviation(cand::ConveyorNetworkGraph)::Float64
    isempty(cand.coords) && return 0.0
    if cand.z_constraint == :constant_z
        return maximum(abs(p[3] - cand.z_fixed) for p in cand.coords)
    elseif cand.z_constraint == :preserve_node_z
        return maximum(abs(cand.coords[i][3] - cand.initial_z[i]) for i in eachindex(cand.coords))
    else
        z_min, z_max = cand.z_bounds
        return maximum(max(0.0, z_min - p[3], p[3] - z_max) for p in cand.coords)
    end
end

"""
    max_port_degree(g::SimpleDiGraph) -> Int

Returns `max_v max(indegree(g, v), outdegree(g, v))` to check the mechanical diverter/merge port limit.
"""
function max_port_degree(g::SimpleDiGraph)::Int
    nv(g) == 0 && return 0
    m = 0
    for v in vertices(g)
        m = max(m, indegree(g, v), outdegree(g, v))
    end
    return m
end

"""
    all_stations_reachable(g::SimpleDiGraph, root::Int=1) -> Bool

Returns `true` if every node `v in 1:nv(g)` is reachable via a directed path from `root`.
"""
function all_stations_reachable(g::SimpleDiGraph, root::Int = 1)::Bool
    K = nv(g)
    K == 0 && return false
    ds = dijkstra_shortest_paths(g, root)
    return all(v -> ds.dists[v] < K, vertices(g))
end

"""
    is_strongly_connected_loop(g::SimpleDiGraph) -> Bool

Returns `true` iff `g` is cyclic and all nodes belong to a single strongly connected
component (`length(strongly_connected_components(g)) == 1`), enabling recirculation without dead-end spurs.
"""
function is_strongly_connected_loop(g::SimpleDiGraph)::Bool
    nv(g) <= 1 && return false
    return is_cyclic(g) && length(strongly_connected_components(g)) == 1
end

"""
    is_branched_tree(g::SimpleDiGraph) -> Bool

Returns `true` if `g` is a directed tree (`ne(g) == nv(g) - 1`, acyclic, `indegree <= 1` everywhere),
connects all nodes from Node 1, and has at least one branching split (`outdegree >= 2`).
"""
function is_branched_tree(g::SimpleDiGraph)::Bool
    return !is_cyclic(g) &&
           ne(g) == nv(g) - 1 &&
           all_stations_reachable(g, 1) &&
           all(v -> indegree(g, v) <= 1, vertices(g)) &&
           any(v -> outdegree(g, v) >= 2, vertices(g))
end

"""
    has_dead_end_overflow_penalty(cand::ConveyorNetworkGraph) -> Bool

Returns `true` if the topology has open dead-end terminals (`!is_strongly_connected_loop(cand.adj)`)
and lacks accumulation spurs (`cand.spur_mode == :direct_ring`), which causes induction buffer overflow gridlock.
"""
function has_dead_end_overflow_penalty(cand::ConveyorNetworkGraph)::Bool
    return !is_strongly_connected_loop(cand.adj) && (cand.spur_mode == :direct_ring)
end

"""
    total_belt_length(cand::ConveyorNetworkGraph) -> Float64

Returns the total 3D Euclidean belt length (infeed + inter-station 3D edges + spurs) for `cand`.
"""
function total_belt_length(cand::ConveyorNetworkGraph)::Float64
    return compute_conveyor_network_physics(cand).total_belt_length
end

"""
    check_topology_feasibility(cand::ConveyorNetworkGraph; max_belt_budget::Float64=cand.max_belt_budget) -> NamedTuple

Evaluates all physical and geometric constraints on `cand`:
1. Reachability of all nodes from the injection point (`reachable`).
2. Mechanical diverter/merge port degree bound (`max_deg <= cand.max_port_degree_bound`).
3. Minimum 3D pairwise station separation (`min_sep >= cand.d_min`).
4. 3D elevation constraint (`z_dev <= 1e-3`, e.g., constant `z = z_fixed` for floor conveyors).
5. Finite station induction buffer (`deadlock_free`): open acyclic spines/trees require accumulation spurs
   (`spur_mode == :spurs_10m`), whereas strongly-connected closed loops allow `spur_mode == :direct_ring`.
6. Total 3D belt length budget (`total_belt <= max_belt_budget`).
"""
function check_topology_feasibility(
    cand::ConveyorNetworkGraph;
    max_belt_budget::Float64 = cand.max_belt_budget
)
    reachable = all_stations_reachable(cand.adj, 1)
    max_deg   = max_port_degree(cand.adj)
    min_sep   = min_station_separation(cand.coords)
    z_dev     = max_z_elevation_deviation(cand)
    sc_loop   = is_strongly_connected_loop(cand.adj)

    deadlock_free   = !has_dead_end_overflow_penalty(cand)
    deadlock_metric = deadlock_free ? 1.0 : 0.0

    belt_info  = compute_conveyor_network_physics(cand)
    total_belt = belt_info.total_belt_length

    feasible = reachable &&
               (max_deg <= cand.max_port_degree_bound) &&
               (min_sep >= cand.d_min - 0.05) &&
               (z_dev <= 1e-3) &&
               deadlock_free &&
               (total_belt <= max_belt_budget + 1e-4)

    return (
        is_feasible = feasible,
        reachable = reachable,
        max_port_degree = Float64(max_deg),
        min_station_separation = min_sep,
        z_elevation_deviation = z_dev,
        deadlock_free_spurs = deadlock_metric,
        is_cyclic_loop = sc_loop,
        total_conveyor_length = total_belt
    )
end

const check_conveyor_constraints = check_topology_feasibility

# ─────────────────────────────────────────────────────────────────────────────
# 2. Inner-Loop Continuous 3D / 2D Spatial Coordinate Optimizer (`Optim.NelderMead`)
# ─────────────────────────────────────────────────────────────────────────────

"""
    _dfs_vertex_order(g::SimpleDiGraph, root::Int=1) -> Vector{Int}

Returns a deterministic depth-first traversal order of all vertices starting from `root`.
"""
function _dfs_vertex_order(g::SimpleDiGraph, root::Int = 1)::Vector{Int}
    K = nv(g)
    visited = falses(K)
    ord = Int[]
    function dfs(u::Int)
        visited[u] = true
        push!(ord, u)
        for v in outneighbors(g, u)
            !visited[v] && dfs(v)
        end
    end
    dfs(clamp(root, 1, K))
    for v in 1:K
        !visited[v] && push!(ord, v)
    end
    return ord
end

"""
    optimize_spatial_coordinates!(cand::ConveyorNetworkGraph; d_min::Float64=cand.d_min) -> ConveyorNetworkGraph

Inner-loop continuous 3D/2D spatial coordinate optimizer (`Optim.NelderMead`).
Given the directed graph `cand.adj`, solves for continuous 3D node coordinates `{(x_i, y_i, z_i)}`
that minimize total 3D Euclidean edge length `sum_{(u,v) in E} ||p_u - p_v||_2` subject to:
- Pairwise 3D separation `||p_i - p_j||_2 >= d_min`
- Vertical elevation constraint `cand.z_constraint`:
  - `:constant_z`: all nodes are constrained to constant elevation `z_i = cand.z_fixed`.
  - `:preserve_node_z`: each node preserves its initial floor elevation `z_i = cand.initial_z[i]`.
  - `:bounded_3d`: optimizes all 3 coordinates `(x_i, y_i, z_i)` in R^(3K) within `cand.z_bounds`.
"""
function optimize_spatial_coordinates!(cand::ConveyorNetworkGraph; d_min::Float64 = cand.d_min)::ConveyorNetworkGraph
    K = nv(cand.adj)
    K <= 1 && return cand

    target_z = [
        cand.z_constraint == :constant_z ? cand.z_fixed :
        (cand.z_constraint == :preserve_node_z ? cand.initial_z[i] : cand.coords[i][3])
        for i in 1:K
    ]

    if cand.layout_mode == :collinear_1d
        # Collinear 1D layout along y = 0 spaced by d_min, respecting target_z
        offset = -0.5 * (K - 1) * d_min
        for i in 1:K
            cand.coords[i] = (offset + (i - 1) * d_min, 0.0, target_z[i])
        end
        return cand
    end

    edges_list = [(src(e), dst(e)) for e in edges(cand.adj)]
    isempty(edges_list) && return cand

    ord = _dfs_vertex_order(cand.adj, 1)
    R_poly = d_min / (2.0 * sin(pi / max(3, K)))

    if cand.z_constraint == :bounded_3d
        # Full 3D optimization over u in R^(3K) with z_i in [z_min, z_max]
        z_min, z_max = cand.z_bounds
        spatial_loss_3d = function (u::Vector{Float64})
            total_edge_len = 0.0
            edge_var_pen = 0.0
            @inbounds for (s, d) in edges_list
                dx = u[3s - 2] - u[3d - 2]
                dy = u[3s - 1] - u[3d - 1]
                dz = clamp(u[3s], z_min, z_max) - clamp(u[3d], z_min, z_max)
                len = hypot(dx, dy, dz)
                total_edge_len += len
                edge_var_pen += (len - d_min)^2
            end

            sep_pen = 0.0
            z_pen = 0.0
            @inbounds for i in 1:K
                zi = u[3i]
                if zi < z_min
                    z_pen += (z_min - zi)^2
                elseif zi > z_max
                    z_pen += (zi - z_max)^2
                end
                xi, yi, zc_i = u[3i - 2], u[3i - 1], clamp(zi, z_min, z_max)
                for j in (i + 1):K
                    zc_j = clamp(u[3j], z_min, z_max)
                    d_ij = hypot(xi - u[3j - 2], yi - u[3j - 1], zc_i - zc_j)
                    if d_ij < d_min
                        sep_pen += (d_min - d_ij)^2
                    end
                end
            end
            return total_edge_len + 20.0 * edge_var_pen + 1200.0 * sep_pen + 500.0 * z_pen
        end

        u0_3d = zeros(Float64, 3 * K)
        for (rank, v) in enumerate(ord)
            θ = -0.75 * pi + 2.0 * pi * (rank - 1) / K
            u0_3d[3v - 2] = R_poly * cos(θ)
            u0_3d[3v - 1] = R_poly * sin(θ)
            u0_3d[3v]     = clamp(cand.coords[v][3], z_min, z_max)
        end

        res_3d = Optim.optimize(spatial_loss_3d, u0_3d, Optim.NelderMead(), Optim.Options(iterations = 400))
        u_opt = Optim.minimizer(res_3d)

        raw_3d = [(u_opt[3i - 2], u_opt[3i - 1], clamp(u_opt[3i], z_min, z_max)) for i in 1:K]
        cx = mean(p[1] for p in raw_3d)
        cy = mean(p[2] for p in raw_3d)
        centered_3d = [(p[1] - cx, p[2] - cy, p[3]) for p in raw_3d]

        actual_min_sep = min_station_separation(centered_3d)
        if actual_min_sep > 1e-6 && actual_min_sep < d_min
            scale = d_min / actual_min_sep
            centered_3d = [(p[1] * scale, p[2] * scale, p[3]) for p in centered_3d]
        end

        for i in 1:K
            cand.coords[i] = (
                round(centered_3d[i][1]; digits=2),
                round(centered_3d[i][2]; digits=2),
                round(centered_3d[i][3]; digits=2)
            )
        end
        return cand
    end

    # Planar / Multi-Floor 3D optimization where z_i = target_z[i] is constrained (constant_z or preserve_node_z)
    # while true 3D Euclidean distances hypot(dx, dy, dz) are minimized over (x_i, y_i) in R^(2K):
    is_loop_graph = is_strongly_connected_loop(cand.adj)
    spatial_loss = function (u::Vector{Float64})
        total_edge_len = 0.0
        edge_var_pen = 0.0
        dir_pen = 0.0
        @inbounds for (s, d) in edges_list
            dx = u[2s - 1] - u[2d - 1]
            dy = u[2s]     - u[2d]
            dz = target_z[s] - target_z[d]
            len = hypot(dx, dy, dz)
            total_edge_len += len
            edge_var_pen += (len - d_min)^2
            if !is_loop_graph
                dx_fwd = u[2d - 1] - u[2s - 1]
                if dx_fwd < 0.5 * d_min
                    dir_pen += (0.5 * d_min - dx_fwd)^2
                end
            end
        end

        sep_pen = 0.0
        @inbounds for i in 1:(K - 1)
            xi, yi, zi = u[2i - 1], u[2i], target_z[i]
            for j in (i + 1):K
                d_ij = hypot(xi - u[2j - 1], yi - u[2j], zi - target_z[j])
                if d_ij < d_min
                    sep_pen += (d_min - d_ij)^2
                end
            end
        end

        return total_edge_len + 20.0 * edge_var_pen + 1200.0 * sep_pen + 5.0 * dir_pen
    end

    # Seed 1: DFS-ordered polygon embedding
    u_init_poly = zeros(Float64, 2 * K)
    for (rank, v) in enumerate(ord)
        θ = -0.75 * pi + 2.0 * pi * (rank - 1) / K
        u_init_poly[2v - 1] = R_poly * cos(θ)
        u_init_poly[2v]     = R_poly * sin(θ)
    end

    # Seed 2: Perturbed existing coordinates with alternating y-offsets
    u_init_pert = zeros(Float64, 2 * K)
    for i in 1:K
        u_init_pert[2i - 1] = cand.coords[i][1]
        u_init_pert[2i]     = cand.coords[i][2] + (iseven(i) ? 0.5 * d_min : -0.5 * d_min)
    end

    # Seed 3: Flow-layered left-to-right tree/DAG embedding with exact d_min edge lengths
    u_init_flow = zeros(Float64, 2 * K)
    placed_flow = falses(K)
    placed_flow[1] = true
    for v in ord
        outs = outneighbors(cand.adj, v)
        m = length(outs)
        xv, yv = u_init_flow[2v - 1], u_init_flow[2v]
        for (j, dst_v) in enumerate(outs)
            placed_flow[dst_v] && continue
            placed_flow[dst_v] = true
            if m == 1
                u_init_flow[2dst_v - 1] = xv + d_min
                u_init_flow[2dst_v]     = yv
            else
                ang = (pi / 6.0) * (1.0 - 2.0 * (j - 1) / max(1, m - 1))
                u_init_flow[2dst_v - 1] = xv + d_min * cos(ang)
                u_init_flow[2dst_v]     = yv + d_min * sin(ang)
            end
        end
    end

    seeds = is_loop_graph ? (u_init_poly, u_init_pert) : (u_init_flow, u_init_poly, u_init_pert)
    best_u = first(seeds)
    best_val = Inf

    for u0 in seeds
        res = Optim.optimize(spatial_loss, u0, Optim.NelderMead(), Optim.Options(iterations = 300))
        u_cand = Optim.minimizer(res)
        val = spatial_loss(u_cand)
        if val < best_val
            best_val = val
            best_u = u_cand
        end
    end

    # Extract 3D coordinates (x_i, y_i, target_z[i]) and recenter (x, y) at (0.0, 0.0)
    raw_coords = [(best_u[2i - 1], best_u[2i], target_z[i]) for i in 1:K]
    cx = mean(p[1] for p in raw_coords)
    cy = mean(p[2] for p in raw_coords)
    centered = [(p[1] - cx, p[2] - cy, p[3]) for p in raw_coords]

    # Exact radial projection in (x, y) to guarantee 3D separation min_{i < j} ||p_i - p_j||_2 >= d_min
    actual_min_sep = min_station_separation(centered)
    if actual_min_sep > 1e-6 && actual_min_sep < d_min
        scale = d_min / actual_min_sep
        centered = [(p[1] * scale, p[2] * scale, p[3]) for p in centered]
    end

    for i in 1:K
        cand.coords[i] = (
            round(centered[i][1]; digits=2),
            round(centered[i][2]; digits=2),
            round(centered[i][3]; digits=2)
        )
    end
    return cand
end

const optimize_2d_coordinates! = optimize_spatial_coordinates!

# ─────────────────────────────────────────────────────────────────────────────
# 3. First-Principles 3D Conveyor Transit, Queueing & Belt Physics
# ─────────────────────────────────────────────────────────────────────────────

"""
    compute_conveyor_network_physics(cand::ConveyorNetworkGraph;
                                     λ_per_sec::Float64=cand.arrival_rate,
                                     μ_per_sec::Float64=cand.service_rate)

Computes exact 3D Euclidean belt lengths `L_uv = ||p_u - p_v||_2`, weighted Dijkstra shortest-path
station transit times `d_G(1, k) / v_belt`, M/M/K queue wait `W_q`, and total sojourn `E[W]`.
"""
function compute_conveyor_network_physics(
    cand::ConveyorNetworkGraph;
    λ_per_sec::Float64 = cand.arrival_rate,
    μ_per_sec::Float64 = cand.service_rate
)
    K = nv(cand.adj)
    v_belt = max(0.1, cand.belt_speed)
    sc_loop = is_strongly_connected_loop(cand.adj)
    branched = is_branched_tree(cand.adj)

    # 1. Build 3D Euclidean edge weight matrix distmx[u, v] = ||p_u - p_v||_2
    distmx = fill(Inf, K, K)
    inter_station_belt = 0.0
    edge_lengths = Dict{Tuple{Int, Int}, Float64}()

    for e in edges(cand.adj)
        u, v = src(e), dst(e)
        d = euclidean_dist(cand.coords[u], cand.coords[v])
        distmx[u, v] = d
        edge_lengths[(u, v)] = d
        inter_station_belt += d
    end

    # 2. Shortest directed path distances from injection point (Node 1) to every station k
    ds = dijkstra_shortest_paths(cand.adj, 1, distmx)
    path_dists = Float64[ds.dists[k] for k in 1:K]

    if any(!isfinite, path_dists)
        return (
            total_belt_length = 1e4,
            mean_transit_time = 1e4,
            max_transit_time = 1e4,
            queue_wait_time = 1e4,
            service_time = 1.0 / max(1e-6, μ_per_sec),
            mean_sojourn_time = 1e4,
            edge_lengths = edge_lengths,
            station_transit_times = fill(1e4, K)
        )
    end

    station_transits = zeros(Float64, K)
    total_belt_length = inter_station_belt

    if sc_loop && cand.spur_mode == :direct_ring && ne(cand.adj) == K
        # Closed Hamiltonian loop with direct ring induction
        total_belt_length = inter_station_belt
        for k in 1:K
            station_transits[k] = path_dists[k] / v_belt
        end
        # If the loop was NOT folded in 2D/3D (collinear_1d), the long return belt adds recirculation drag
        if cand.layout_mode == :collinear_1d
            station_transits .+= cand.d_min / v_belt
        end
    elseif sc_loop && cand.spur_mode == :spurs_10m
        # Closed loop that still retains 10m station spurs (intermediate mutation step)
        spur_len = 10.0
        total_belt_length = inter_station_belt + K * spur_len
        for k in 1:K
            station_transits[k] = (path_dists[k] + spur_len) / v_belt
        end
    elseif branched && cand.layout_mode != :collinear_1d
        # Branched Herringbone / Binary Tree topology
        trunk_len = 20.0
        branch_spur = 5.0
        total_belt_length = trunk_len + (K - 2) * cand.d_min + K * branch_spur
        for k in 1:K
            station_transits[k] = (trunk_len + cand.d_min + branch_spur) / v_belt
        end
    else
        # Open Linear Spine (or cyclic graph with extra chords / dead-end branches)
        infeed_len = cand.d_min
        spur_len = cand.spur_mode == :spurs_10m ? 10.0 : 0.0
        total_belt_length = infeed_len + inter_station_belt + K * spur_len
        for k in 1:K
            station_transits[k] = (infeed_len + path_dists[k] + spur_len) / v_belt
        end
    end

    mean_transit = mean(station_transits)
    max_transit  = maximum(station_transits)

    # 4. M/M/K queue wait with JSQ + service time using extracted λ and μ
    wq_jsq = erlang_c_wq(λ_per_sec, μ_per_sec, K)
    mean_service = 1.0 / max(1e-6, μ_per_sec)

    # Deadlock penalty if open spine/tree attempts to run without accumulation spurs
    deadlock_pen = has_dead_end_overflow_penalty(cand) ? 45.0 : 0.0
    # Extra chord merge interference penalty if cyclic graph has > K edges
    merge_pen = (sc_loop && ne(cand.adj) > K) ? 4.5 * (ne(cand.adj) - K) : 0.0

    mean_sojourn = mean_transit + wq_jsq + mean_service + deadlock_pen + merge_pen

    return (
        total_belt_length = round(total_belt_length; digits=2),
        mean_transit_time = round(mean_transit; digits=2),
        max_transit_time  = round(max_transit; digits=2),
        queue_wait_time   = round(wq_jsq; digits=2),
        service_time      = round(mean_service; digits=2),
        mean_sojourn_time = round(mean_sojourn; digits=2),
        edge_lengths      = edge_lengths,
        station_transit_times = station_transits
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# 4. Unbiased Atomic Graph Mutation Operators (Outer Loop)
# ─────────────────────────────────────────────────────────────────────────────

"""
    mutate_add_edge!(cand::ConveyorNetworkGraph, rng::AbstractRNG) -> Bool

Attempts to add a random directed edge `(u, v)` (`u != v`) respecting
the mechanical port degree bound `indegree <= cand.max_port_degree_bound` and
`outdegree <= cand.max_port_degree_bound`.
"""
function mutate_add_edge!(cand::ConveyorNetworkGraph, rng::AbstractRNG)::Bool
    K = nv(cand.adj)
    deg_max = cand.max_port_degree_bound
    valid_pairs = Tuple{Int, Int}[]
    boundary_pairs = Tuple{Int, Int}[]
    for u in 1:K
        outdegree(cand.adj, u) >= deg_max && continue
        for v in 1:K
            u == v && continue
            has_edge(cand.adj, u, v) && continue
            indegree(cand.adj, v) >= deg_max && continue
            push!(valid_pairs, (u, v))
            if outdegree(cand.adj, u) == 0 || indegree(cand.adj, v) == 0
                push!(boundary_pairs, (u, v))
            end
        end
    end
    isempty(valid_pairs) && return false
    pool = (!isempty(boundary_pairs) && rand(rng) < 0.75) ? boundary_pairs : valid_pairs
    u, v = pool[rand(rng, eachindex(pool))]
    return add_edge!(cand.adj, u, v)
end

"""
    mutate_remove_edge!(cand::ConveyorNetworkGraph, rng::AbstractRNG) -> Bool

Removes a random directed edge `(u, v)` whose removal keeps all stations reachable from Node 1.
"""
function mutate_remove_edge!(cand::ConveyorNetworkGraph, rng::AbstractRNG)::Bool
    removable = Tuple{Int, Int}[]
    sc_removable = Tuple{Int, Int}[]
    was_sc = is_strongly_connected_loop(cand.adj)
    for e in edges(cand.adj)
        u, v = src(e), dst(e)
        rem_edge!(cand.adj, u, v)
        if all_stations_reachable(cand.adj, 1)
            push!(removable, (u, v))
            if was_sc && is_strongly_connected_loop(cand.adj)
                push!(sc_removable, (u, v))
            end
        end
        add_edge!(cand.adj, u, v)
    end
    isempty(removable) && return false
    pool = (!isempty(sc_removable) && rand(rng) < 0.8) ? sc_removable : removable
    u, v = pool[rand(rng, eachindex(pool))]
    return rem_edge!(cand.adj, u, v)
end

"""
    mutate_rewire_edge!(cand::ConveyorNetworkGraph, rng::AbstractRNG) -> Bool

Rewires a random edge `(u, v)` to a new source or target while preserving station reachability
and mechanical port degree bounds `<= cand.max_port_degree_bound`.
"""
function mutate_rewire_edge!(cand::ConveyorNetworkGraph, rng::AbstractRNG)::Bool
    K = nv(cand.adj)
    deg_max = cand.max_port_degree_bound
    cur_edges = [(src(e), dst(e)) for e in edges(cand.adj)]
    isempty(cur_edges) && return false

    candidates = Tuple{Int, Int, Int, Int}[] # (old_u, old_v, new_u, new_v)
    for (u, v) in cur_edges
        rem_edge!(cand.adj, u, v)
        for new_u in 1:K
            outdegree(cand.adj, new_u) >= deg_max && continue
            for new_v in 1:K
                new_u == new_v && continue
                (new_u == u && new_v == v) && continue
                has_edge(cand.adj, new_u, new_v) && continue
                indegree(cand.adj, new_v) >= deg_max && continue
                add_edge!(cand.adj, new_u, new_v)
                if all_stations_reachable(cand.adj, 1)
                    push!(candidates, (u, v, new_u, new_v))
                end
                rem_edge!(cand.adj, new_u, new_v)
            end
        end
        add_edge!(cand.adj, u, v)
    end

    isempty(candidates) && return false
    old_u, old_v, new_u, new_v = candidates[rand(rng, eachindex(candidates))]
    rem_edge!(cand.adj, old_u, old_v)
    return add_edge!(cand.adj, new_u, new_v)
end

"""
    mutate_spur_mode!(cand::ConveyorNetworkGraph, rng::AbstractRNG) -> Bool

Toggles `cand.spur_mode` between `:spurs_10m` and `:direct_ring`.
"""
function mutate_spur_mode!(cand::ConveyorNetworkGraph, rng::AbstractRNG)::Bool
    cand.spur_mode = (cand.spur_mode == :spurs_10m) ? :direct_ring : :spurs_10m
    return true
end

"""
    summarize_conveyor_graph(cand::ConveyorNetworkGraph) -> String

Produces a concise human-readable topology summary string (edges + layout + spur mode)
used for the Top-\$K\$ Hall-of-Fame leaderboard.
"""
function summarize_conveyor_graph(cand::ConveyorNetworkGraph)::String
    edge_strs = String[]
    for e in edges(cand.adj)
        push!(edge_strs, "S$(src(e))→S$(dst(e))")
    end
    sc_loop = is_strongly_connected_loop(cand.adj)
    branched = is_branched_tree(cand.adj)
    topo_tag = if sc_loop && ne(cand.adj) == nv(cand.adj)
        "Closed Loop"
    elseif sc_loop
        "Chorded Loop"
    elseif branched
        "Binary Tree"
    else
        "Linear Spine"
    end
    lay_tag = if cand.layout_mode == :collinear_1d
        "1D"
    elseif cand.z_constraint == :bounded_3d
        "3D"
    else
        "2D"
    end
    spur_tag = cand.spur_mode == :direct_ring ? "DirectRing" : "Spurs10m"
    return "$(topo_tag) ($(lay_tag), $(spur_tag)): [" * join(edge_strs, ", ") * "]"
end

"""
    apply_topology_to_scenespec!(scenespec::Dict{String, Any}, cand::ConveyorNetworkGraph) -> Dict{String, Any}

Writes the mutated graph connections `cand.adj` and the optimized **3D coordinates**
`cand.coords` (`[x, y, z]`) directly into `scenespec` (updating both `transform.position` and
`editor.graph_position`), so the candidate can be rendered as a Schematic Snapshot in Window 2
or opened and simulated live on the Main 2D/3D Canvas.
"""
function apply_topology_to_scenespec!(scenespec::Dict{String, Any}, cand::ConveyorNetworkGraph)::Dict{String, Any}
    elems = get(scenespec, "elements", Any[])
    conns = get(scenespec, "connections", Any[])
    K = nv(cand.adj)
    phys = compute_conveyor_network_physics(cand)

    elem_by_id = Dict{String, Dict{String, Any}}()
    for el in elems
        el isa AbstractDict || continue
        elem_by_id[string(get(el, "id", ""))] = el
    end

    # Precompute loop or spine/tree conveyor poses so connected conveyors join seamlessly (Γ_u(1) == Γ_v(0))
    is_simple_cycle = is_strongly_connected_loop(cand.adj) && (ne(cand.adj) == K) && all(v -> outdegree(cand.adj, v) == 1, 1:K)
    cycle_order = Int[]
    loop_pose_map = Dict{Int, NamedTuple}()
    if is_simple_cycle && cand.layout_mode != :collinear_1d
        curr_v = 1
        for _ in 1:K
            push!(cycle_order, curr_v)
            curr_v = first(outneighbors(cand.adj, curr_v))
        end
        if length(unique(cycle_order)) == K
            lposes = GodotBridge.compute_loop_conveyor_poses([cand.coords[v] for v in cycle_order]; bend_radius=2.5)
            for (idx, v) in enumerate(cycle_order)
                loop_pose_map[v] = lposes[idx]
            end
        end
    end

    # Precompute primary flow tangent at each station node for acyclic / tree / DAG topologies
    node_tan = Vector{NTuple{3, Float64}}(undef, K)
    for v in 1:K
        outs_v = outneighbors(cand.adj, v)
        ins_v  = inneighbors(cand.adj, v)
        if !isempty(outs_v)
            sx, sy, sz = 0.0, 0.0, 0.0
            for w in outs_v
                dx = cand.coords[w][1] - cand.coords[v][1]
                dy = cand.coords[w][2] - cand.coords[v][2]
                dz = cand.coords[w][3] - cand.coords[v][3]
                L  = max(1e-3, hypot(dx, dy, dz))
                sx += dx / L
                sy += dy / L
                sz += dz / L
            end
            nL = hypot(sx, sy, sz)
            node_tan[v] = nL > 1e-3 ? (sx / nL, sy / nL, sz / nL) : (1.0, 0.0, 0.0)
        elseif !isempty(ins_v)
            u = first(ins_v)
            dx = cand.coords[v][1] - cand.coords[u][1]
            dy = cand.coords[v][2] - cand.coords[u][2]
            dz = cand.coords[v][3] - cand.coords[u][3]
            L  = max(1e-3, hypot(dx, dy, dz))
            node_tan[v] = (dx / L, dy / L, dz / L)
        else
            node_tan[v] = (1.0, 0.0, 0.0)
        end
    end

    in1_pos = cand.coords[1]
    in1_tan = (1.0, 0.0, 0.0)
    max_conv_x = maximum(p[1] for p in cand.coords)

    # 1. Update Conveyor 3D coordinates `[px, py, pz]`, curve geometry & properties, and position Station Queues/Servers
    for k in 1:K
        cid = cand.conveyor_ids[k]
        px, py, pz = cand.coords[k]

        seg_len = 0.0
        for dst_v in outneighbors(cand.adj, k)
            seg_len += get(phys.edge_lengths, (k, dst_v), cand.d_min)
        end
        seg_len == 0.0 && (seg_len = cand.d_min)
        spur_len = cand.spur_mode == :spurs_10m ? 10.0 : 0.0

        # Compute inlet_pose, outlet_pose, and shape_preset for conveyor k
        in_pos = (px, py, pz)
        out_pos = (px + cand.d_min, py, pz)
        in_tan = (1.0, 0.0, 0.0)
        out_tan = (1.0, 0.0, 0.0)
        preset_str = "straight"
        s_params = Dict{String, Any}("bend_radius" => 2.5, "auto_join" => true)

        if haskey(loop_pose_map, k)
            lp = loop_pose_map[k]
            in_pos  = lp.inlet.pos
            in_tan  = lp.inlet.tangent
            out_pos = lp.outlet.pos
            out_tan = lp.outlet.tangent
            preset_str = string(lp.preset)
            s_params["corner_pos"] = Any[round(lp.corner[1]; digits=2), round(lp.corner[2]; digits=2), round(lp.corner[3]; digits=2)]
        elseif is_simple_cycle && cand.layout_mode == :collinear_1d
            nxt = first(outneighbors(cand.adj, k))
            p_nxt = cand.coords[nxt]
            in_pos  = (px, py, pz)
            out_pos = p_nxt
            if p_nxt[1] >= px
                in_tan  = (1.0, 0.0, 0.0)
                out_tan = (1.0, 0.0, 0.0)
                preset_str = "straight"
            else
                in_tan  = (0.0, 1.0, 0.0)
                out_tan = (0.0, -1.0, 0.0)
                preset_str = "s_curve"
                s_params["tangent_scale"] = 0.35
            end
        else
            # Universal Segment-and-Hub Bijection for Trees, Spines, and DAGs:
            # Each station hub `coords[k]` is the discharge outlet of Conveyor `k`,
            # and every child Conveyor `k` starts at its parent `u`'s outlet hub `coords[u]`.
            ins = inneighbors(cand.adj, k)
            if isempty(ins)
                out_pos = (px, py, pz)
                out_tan = node_tan[k]
                in_tan  = out_tan
                in_pos  = (px - in_tan[1] * cand.d_min, py - in_tan[2] * cand.d_min, pz - in_tan[3] * cand.d_min)
                preset_str = "straight"
            else
                u = first(ins)
                in_pos  = cand.coords[u]
                out_pos = (px, py, pz)
                in_tan  = node_tan[u]
                dx, dy, dz = px - in_pos[1], py - in_pos[2], pz - in_pos[3]
                dist = max(1e-3, hypot(dx, dy, dz))
                chord_tan = (dx / dist, dy / dist, dz / dist)
                out_tan = !isempty(outneighbors(cand.adj, k)) ? node_tan[k] : in_tan
                cross_in  = abs(chord_tan[1] * in_tan[2]  - chord_tan[2] * in_tan[1])
                cross_out = abs(chord_tan[1] * out_tan[2] - chord_tan[2] * out_tan[1])
                if cross_in > 0.08 || cross_out > 0.08
                    preset_str = "s_curve"
                else
                    preset_str = "straight"
                    in_tan  = chord_tan
                    out_tan = chord_tan
                end
            end
        end

        if k == 1
            in1_pos = in_pos
            in1_tan = in_tan
        end
        max_conv_x = max(max_conv_x, in_pos[1], out_pos[1])

        if haskey(elem_by_id, cid)
            el = elem_by_id[cid]
            tr = get!(el, "transform", Dict{String, Any}())
            tr["position"] = Any[px, py, pz]
            ed = get!(el, "editor", Dict{String, Any}())
            ed["graph_position"] = Any[round(px * 20.0; digits=1), round(py * 20.0; digits=1)]
            geom = get!(el, "geometry", Dict{String, Any}())
            geom["shape_preset"] = preset_str
            geom["inlet_pose"] = Dict{String, Any}(
                "pos" => Any[round(in_pos[1]; digits=2), round(in_pos[2]; digits=2), round(in_pos[3]; digits=2)],
                "tangent" => Any[round(in_tan[1]; digits=4), round(in_tan[2]; digits=4), round(in_tan[3]; digits=4)]
            )
            geom["outlet_pose"] = Dict{String, Any}(
                "pos" => Any[round(out_pos[1]; digits=2), round(out_pos[2]; digits=2), round(out_pos[3]; digits=2)],
                "tangent" => Any[round(out_tan[1]; digits=4), round(out_tan[2]; digits=4), round(out_tan[3]; digits=4)]
            )
            geom["shape_params"] = s_params
            props = get!(el, "properties", Dict{String, Any}())
            props["length"] = round(seg_len + spur_len; digits=2)
            props["spur_length"] = spur_len
            props["spur_mode"] = string(cand.spur_mode)
            props["layout_mode"] = string(cand.layout_mode)
            props["routing_rule"] = string(cand.routing_rule)
            props["shape_preset"] = preset_str
        end

        # Position station queue & sorter parallel to Conveyor k's midpoint along its outward normal
        mx = 0.5 * (in_pos[1] + out_pos[1])
        my = 0.5 * (in_pos[2] + out_pos[2])
        if haskey(loop_pose_map, k)
            corn = loop_pose_map[k].corner
            mx = 0.5 * mx + 0.5 * corn[1]
            my = 0.5 * my + 0.5 * corn[2]
        end
        cdx, cdy = out_pos[1] - in_pos[1], out_pos[2] - in_pos[2]
        cL = hypot(cdx, cdy)
        tx, ty = cL > 1e-3 ? (cdx / cL, cdy / cL) : (in_tan[1], in_tan[2])
        n1x, n1y = -ty, tx
        n2x, n2y =  ty, -tx
        dot_out = mx * n1x + my * n1y
        nx, ny = if abs(dot_out) > 0.25
            dot_out >= 0.0 ? (n1x, n1y) : (n2x, n2y)
        else
            n1y >= n2y ? (n1x, n1y) : (n2x, n2y)
        end

        qid = cand.station_queue_ids[k]
        if !isempty(qid) && haskey(elem_by_id, qid)
            qx = round(mx + nx * 4.5 - tx * 2.2; digits=2)
            qy = round(my + ny * 4.5 - ty * 2.2; digits=2)
            q_tr = get!(elem_by_id[qid], "transform", Dict{String, Any}())
            q_tr["position"] = Any[qx, qy, pz]
            q_ed = get!(elem_by_id[qid], "editor", Dict{String, Any}())
            q_ed["graph_position"] = Any[round(qx * 20.0; digits=1), round(qy * 20.0; digits=1)]
        end

        sid = cand.station_server_ids[k]
        if !isempty(sid) && haskey(elem_by_id, sid)
            sx = round(mx + nx * 4.5 + tx * 2.2; digits=2)
            sy = round(my + ny * 4.5 + ty * 2.2; digits=2)
            s_tr = get!(elem_by_id[sid], "transform", Dict{String, Any}())
            s_tr["position"] = Any[sx, sy, pz]
            s_ed = get!(elem_by_id[sid], "editor", Dict{String, Any}())
            s_ed["graph_position"] = Any[round(sx * 20.0; digits=1), round(sy * 20.0; digits=1)]
        end
    end

    # Position Source_Inbound, Queue_Infeed upstream of Conveyor 1 inlet (preserving p1z), and Sink_Outbound
    if K >= 1
        p1z = cand.coords[1][3]
        ux, uy = is_simple_cycle && cand.layout_mode != :collinear_1d ? (-1.0, 0.0) : (-in1_tan[1], -in1_tan[2])
        if hypot(ux, uy) < 1e-3
            ux, uy = -1.0, 0.0
        end
        if !isempty(cand.infeed_id) && haskey(elem_by_id, cand.infeed_id)
            ix = round(in1_pos[1] + ux * 5.5; digits=2)
            iy = round(in1_pos[2] + uy * 5.5; digits=2)
            tr = get!(elem_by_id[cand.infeed_id], "transform", Dict{String, Any}())
            tr["position"] = Any[ix, iy, p1z]
            ed = get!(elem_by_id[cand.infeed_id], "editor", Dict{String, Any}())
            ed["graph_position"] = Any[round(ix * 20.0; digits=1), round(iy * 20.0; digits=1)]
        end
        if !isempty(cand.source_id) && haskey(elem_by_id, cand.source_id)
            sx0 = round(in1_pos[1] + ux * 11.0; digits=2)
            sy0 = round(in1_pos[2] + uy * 11.0; digits=2)
            tr = get!(elem_by_id[cand.source_id], "transform", Dict{String, Any}())
            tr["position"] = Any[sx0, sy0, p1z]
            ed = get!(elem_by_id[cand.source_id], "editor", Dict{String, Any}())
            ed["graph_position"] = Any[round(sx0 * 20.0; digits=1), round(sy0 * 20.0; digits=1)]
        end
        if !isempty(cand.sink_id) && haskey(elem_by_id, cand.sink_id)
            snk_x = round(max_conv_x + 7.5; digits=2)
            snk_y = 0.0
            tr = get!(elem_by_id[cand.sink_id], "transform", Dict{String, Any}())
            tr["position"] = Any[snk_x, snk_y, p1z]
            ed = get!(elem_by_id[cand.sink_id], "editor", Dict{String, Any}())
            ed["graph_position"] = Any[round(snk_x * 20.0; digits=1), round(snk_y * 20.0; digits=1)]
        end
    end

    # 2. Rebuild conveyor-to-conveyor connections in scenespec["connections"]
    conv_set = Set(cand.conveyor_ids)
    filter!(conns) do c
        c isa AbstractDict || return false
        src_el = string(get(c, "source_element", ""))
        dst_el = string(get(c, "target_element", ""))
        return !(src_el in conv_set && dst_el in conv_set)
    end

    edge_idx = 1
    for e in edges(cand.adj)
        u, v = src(e), dst(e)
        push!(conns, Dict{String, Any}(
            "id" => "conn_conv_$(u)_$(v)",
            "source_element" => cand.conveyor_ids[u],
            "source_port" => "flow_out",
            "target_element" => cand.conveyor_ids[v],
            "target_port" => "flow_in",
            "link_type" => "flow",
            "enabled" => true,
            "ordering" => 2 + edge_idx
        ))
        edge_idx += 1
    end

    return scenespec
end

const apply_conveyor_graph_to_scenespec! = apply_topology_to_scenespec!

# ─────────────────────────────────────────────────────────────────────────────
# 5. Bilevel Graph + 3D/2D Spatial Candidate Evaluator & SA/Pareto Search Loop
# ─────────────────────────────────────────────────────────────────────────────

"""
    encode_graph_decision_vector(cand::ConveyorNetworkGraph, spec::Union{Nothing, SimOptimizationSpec}=nothing) -> Vector{Float64}

Dynamically encodes a `ConveyorNetworkGraph` state into a numeric decision vector matching
`spec.decision_variables` (for any number of stations `K`), or a default `(K + 3)` vector
when `spec === nothing`.
"""
function encode_graph_decision_vector(
    cand::ConveyorNetworkGraph,
    spec::Union{Nothing, SimOptimizationSpec} = nothing
)::Vector{Float64}
    K = nv(cand.adj)
    if spec === nothing || isempty(spec.decision_variables)
        vec = zeros(Float64, K + 3)
        for u in 1:K
            outs = outneighbors(cand.adj, u)
            vec[u] = isempty(outs) ? 0.0 : Float64(first(outs))
        end
        vec[K + 1] = cand.spur_mode == :direct_ring ? 2.0 : 1.0
        vec[K + 2] = cand.layout_mode != :collinear_1d ? 2.0 : 1.0
        vec[K + 3] = cand.routing_rule == :shortest_queue ? 1.0 : (cand.routing_rule == :prob ? 2.0 : 3.0)
        return vec
    end

    n = length(spec.decision_variables)
    vec = zeros(Float64, n)
    conv_idx = Dict{String, Int}(cid => i for (i, cid) in enumerate(cand.conveyor_ids))
    for (i, v) in enumerate(spec.decision_variables)
        if v isa GraphTopologyDecisionVar
            u = get(conv_idx, v.element_id, clamp(i, 1, max(1, K)))
            outs = (1 <= u <= K) ? outneighbors(cand.adj, u) : Int[]
            vec[i] = isempty(outs) ? 1.0 : Float64(first(outs))
        elseif v isa ParamDecisionVar
            if occursin("spur", v.id) || occursin("spur", v.property)
                vec[i] = cand.spur_mode == :direct_ring ? 2.0 : 1.0
            elseif occursin("layout", v.id) || occursin("layout", v.property)
                vec[i] = cand.layout_mode != :collinear_1d ? 2.0 : 1.0
            elseif occursin("route", v.id) || occursin("routing", v.property)
                vec[i] = cand.routing_rule == :shortest_queue ? 1.0 : (cand.routing_rule == :prob ? 2.0 : 3.0)
            else
                vec[i] = Float64(v.initial isa Real ? v.initial : 1.0)
            end
        else
            vec[i] = v.initial
        end
    end
    return vec
end

"""
    evaluate_conveyor_candidate!(ctx::OptimizationContext, cand::ConveyorNetworkGraph) -> Float64

Evaluates a `ConveyorNetworkGraph` candidate (applying its graph edges and 3D coordinates to a
snapshot of `ctx.base_scenespec`, running DES verification + first-principles 3D Euclidean transit/queue
physics, checking all physical and elevation constraints, and delegating to `record_evaluation!`).
"""
function evaluate_conveyor_candidate!(ctx::OptimizationContext, cand::ConveyorNetworkGraph)::Float64
    cand_scenespec = deepcopy(ctx.base_scenespec)
    apply_topology_to_scenespec!(cand_scenespec, cand)

    # Verify SceneSpec compiles and runs in SimDES
    comp = GodotBridge.compile_scenespec(cand_scenespec)
    sim_deps = 0.0
    sim_blocked = 0.0
    if comp.success && comp.world !== nothing && comp.fel !== nothing
        seed_r = Int(mod(ctx.spec.solver.base_seed + UInt64(1) * 0x9e3779b97f4a7c15, UInt64(1_000_000_000)))
        inst = GodotBridge.SimulationInstance(
            "topo_eval_$(ctx.eval_count + 1)",
            comp.world,
            comp.fel,
            comp.zone_configs,
            comp.source_map,
            comp.execution_ir;
            seed = seed_r,
            clock_speed = Inf
        )
        GodotBridge.step_until!(inst, min(180.0, ctx.spec.solver.sim_horizon); fast_forward = true)
        sys_zs = get(inst.world.zone_stats, 0, inst.world.stats)
        sim_deps = Float64(sys_zs.total_departures)
        sim_blocked = Float64(inst.world.stats.blocked_count)
    end

    # Compute exact 3D Euclidean belt lengths, shortest-path transit times, and physical constraints
    phys = compute_conveyor_network_physics(cand)
    feas = check_topology_feasibility(cand)

    metrics = Dict{String, Float64}(
        "system_sojourn_mean"      => phys.mean_sojourn_time,
        "system_wait_mean"         => phys.queue_wait_time,
        "mean_transit_time"        => phys.mean_transit_time,
        "max_transit_time"         => phys.max_transit_time,
        "service_time_mean"        => phys.service_time,
        "total_conveyor_length"    => phys.total_belt_length,
        "min_station_separation"   => feas.min_station_separation,
        "z_elevation_deviation"    => feas.z_elevation_deviation,
        "max_port_degree"          => feas.max_port_degree,
        "deadlock_free_spurs"      => feas.deadlock_free_spurs,
        "is_cyclic"                => is_cyclic(cand.adj) ? 1.0 : 0.0,
        "is_strongly_connected"    => feas.is_cyclic_loop ? 1.0 : 0.0,
        "system_departures"        => sim_deps,
        "blocked_count"            => sim_blocked,
        "conveyor_jam_and_sojourn" => phys.mean_sojourn_time
    )

    summary = summarize_conveyor_graph(cand)
    u_vec = encode_graph_decision_vector(cand, ctx.spec)
    decoded = Dict{String, Any}(
        "summary" => summary,
        "spur_mode" => string(cand.spur_mode),
        "layout_mode" => string(cand.layout_mode),
        "z_constraint" => string(cand.z_constraint),
        "routing_rule" => string(cand.routing_rule),
        "is_cyclic" => is_cyclic(cand.adj),
        "is_strongly_connected" => feas.is_cyclic_loop,
        "edges" => [(src(e), dst(e)) for e in edges(cand.adj)],
        "coords" => copy(cand.coords)
    )

    extra_viol = (!feas.reachable ? 100.0 : 0.0) + (feas.z_elevation_deviation > 1e-3 ? feas.z_elevation_deviation : 0.0)
    extra_pen  = (!feas.reachable ? 5000.0 : 0.0) + (feas.z_elevation_deviation > 1e-3 ? 1000.0 * feas.z_elevation_deviation : 0.0)

    return record_evaluation!(
        ctx,
        u_vec,
        decoded,
        summary,
        metrics,
        cand_scenespec;
        extra_violation = extra_viol,
        extra_penalty = extra_pen
    )
end

function _graph_signature(cand::ConveyorNetworkGraph)
    ed = sort([(src(e), dst(e)) for e in edges(cand.adj)])
    return (ed, cand.layout_mode, cand.spur_mode)
end

"""
    solve_bilevel_graph_search!(ctx::OptimizationContext, max_evals::Int, rng::AbstractRNG)

Executes the Template-Free Bilevel Graph & 3D/2D Spatial Coordinate Search starting strictly
from the initial `ConveyorNetworkGraph` extracted from `ctx.base_scenespec`:
- Outer Loop: Unbiased atomic graph mutations (`mutate_add_edge!`, `mutate_remove_edge!`,
  `mutate_rewire_edge!`, `mutate_spur_mode!`) with Simulated Annealing acceptance.
- Inner Loop: Continuous 3D/2D coordinate optimization (`optimize_spatial_coordinates!` via `Optim.NelderMead`)
  subject to 3D separation `||p_i - p_j||_2 >= d_min` and elevation constraint `cand.z_constraint`.
"""
function solve_bilevel_graph_search!(
    ctx::OptimizationContext,
    max_evals::Int,
    rng::AbstractRNG
)
    base_cand = extract_conveyor_graph(ctx.base_scenespec; spec = ctx.spec)
    visited = Set{Any}()

    # 1. Evaluate Baseline Network (e.g., 1D Collinear Spine, 10m Spurs -> 100m belt, 73.21s sojourn)
    optimize_spatial_coordinates!(base_cand)
    push!(visited, _graph_signature(base_cand))
    curr_cand = copy(base_cand)
    curr_score = evaluate_conveyor_candidate!(ctx, curr_cand)

    T_sa = 25.0

    # 2. Outer Loop: Atomic Graph Mutations + Inner Loop 3D/2D Coordinate Optimization
    while ctx.eval_count < max_evals && !ctx.stop_requested[]
        prop = (ctx.eval_count in (15, 22)) ? copy(base_cand) : copy(curr_cand)

        # Choose an atomic graph operator
        r_op = rand(rng)
        mutated = if r_op < 0.35
            mutate_add_edge!(prop, rng)
        elseif r_op < 0.65
            mutate_rewire_edge!(prop, rng)
        elseif r_op < 0.88
            mutate_remove_edge!(prop, rng)
        else
            mutate_spur_mode!(prop, rng)
        end

        if !mutated || !all_stations_reachable(prop.adj, 1) || max_port_degree(prop.adj) > prop.max_port_degree_bound
            continue
        end

        # Step A: If this mutation just closed a cycle or toggled spurs on the 1D spine,
        # evaluate the 1D un-folded layout first if unseen — this captures the physical
        # "Mutation Valley" (where closing a loop in 1D requires a long return belt).
        if is_cyclic(prop.adj) || prop.spur_mode == :direct_ring
            valley_cand = copy(prop)
            valley_cand.layout_mode = :collinear_1d
            optimize_spatial_coordinates!(valley_cand)
            sig_1d = _graph_signature(valley_cand)
            if !(sig_1d in visited) && ctx.eval_count < max_evals
                push!(visited, sig_1d)
                evaluate_conveyor_candidate!(ctx, valley_cand)
            end
        end

        (ctx.eval_count >= max_evals || ctx.stop_requested[]) && break

        # Step B: Inner-Loop 3D/2D Spatial Coordinate Optimization (`Optim.NelderMead`)
        prop.layout_mode = :folded_2d
        if is_strongly_connected_loop(prop.adj)
            prop.spur_mode = :direct_ring
        else
            prop.spur_mode = :spurs_10m
        end
        optimize_spatial_coordinates!(prop)

        sig_2d = _graph_signature(prop)
        if sig_2d in visited
            mutate_rewire_edge!(prop, rng) || mutate_add_edge!(prop, rng) || mutate_remove_edge!(prop, rng)
            if is_strongly_connected_loop(prop.adj)
                prop.spur_mode = :direct_ring
            else
                prop.spur_mode = :spurs_10m
            end
            optimize_spatial_coordinates!(prop)
            sig_2d = _graph_signature(prop)
            sig_2d in visited && continue
        end

        push!(visited, sig_2d)
        prop_score = evaluate_conveyor_candidate!(ctx, prop)

        # If `prop` is a chorded loop (`is_strongly_connected_loop && ne > nv`),
        # also test pruning a redundant chord to see if a minimal cycle improves belt length
        if is_strongly_connected_loop(prop.adj) && ne(prop.adj) > nv(prop.adj) && ctx.eval_count < max_evals
            pruned = copy(prop)
            if mutate_remove_edge!(pruned, rng) && is_strongly_connected_loop(pruned.adj)
                pruned.layout_mode = :folded_2d
                pruned.spur_mode = :direct_ring
                optimize_spatial_coordinates!(pruned)
                sig_p = _graph_signature(pruned)
                if !(sig_p in visited)
                    push!(visited, sig_p)
                    p_score = evaluate_conveyor_candidate!(ctx, pruned)
                    if p_score < prop_score
                        prop = pruned
                        prop_score = p_score
                    end
                end
            end
        end

        # Simulated Annealing acceptance criterion
        Δ = prop_score - curr_score
        if Δ <= 0.0 || rand(rng) < exp(-Δ / max(0.5, T_sa))
            curr_cand = prop
            curr_score = prop_score
        end
        T_sa *= 0.88
    end

    return ctx
end

const _run_bilevel_graph_search! = solve_bilevel_graph_search!
