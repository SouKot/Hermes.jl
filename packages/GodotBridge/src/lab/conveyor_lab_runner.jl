# packages/GodotBridge/src/lab/conveyor_lab_runner.jl
#
# Headless runner for the Conveyor Physics Lab: steps a compiled scenario, records belt
# trajectories and element metrics, evaluates physical invariants, and writes CSV/SVG/HTML reports.

using Random

"""A named physical invariant; `f(trace) -> (passed::Bool, detail::String)`."""
struct LabCheck
    name::String
    f::Function
end

"""Scenario definition: a SceneSpec plus the physics it must satisfy."""
struct LabScenario
    id::String
    title::String
    description::String
    spec::Dict{String, Any}
    t_end::Float64
    sample_dt::Float64
    checks::Vector{LabCheck}
end

struct LabBelt
    mode::Symbol
    length::Float64
    speed::Float64
    spacing::Float64     # smallest allowed centre-to-centre distance
    capacity::Int
end

mutable struct LabTrace
    id::String
    t::Vector{Float64}
    metrics::Dict{String, Vector{Float64}}
    states::Dict{String, Vector{String}}
    tracks::Dict{String, Dict{UInt64, Vector{Tuple{Float64, Float64}}}}
    belts::Dict{String, LabBelt}
    entries::Int
    exits::Int
    in_system::Int
    blocked_count::Int
end

lab_series(tr::LabTrace, key::AbstractString) = get(tr.metrics, String(key), Float64[])

"""Average rate of a cumulative counter over `[t0, end]`."""
function lab_rate(tr::LabTrace, key::AbstractString, t0::Real)
    v = lab_series(tr, key)
    i0 = findfirst(>=(t0), tr.t)
    (isempty(v) || i0 === nothing) && return NaN
    return (v[end] - v[i0]) / (tr.t[end] - tr.t[i0])
end

"""First sample time at which `pred(value)` holds, or `Inf`."""
function lab_first_time(tr::LabTrace, key::AbstractString, pred::Function)
    v = lab_series(tr, key)
    i = findfirst(pred, v)
    return i === nothing ? Inf : tr.t[i]
end

function _lab_belts(spec::Dict{String, Any})
    belts = Dict{String, LabBelt}()
    for el in spec["elements"]
        el["kind"] == "conveyor" || continue
        p = el["properties"]
        mode = Symbol(get(p, "conveyor_mode", "free_flow"))
        pitch = Float64(get(p, "accumulation_pitch", 0.5))
        gap = Float64(get(p, "accumulation_gap", 0.0))
        belts[el["id"]] = LabBelt(mode, Float64(p["length"]), Float64(get(p, "speed", 1.5)),
                                  mode === :free_flow ? pitch : pitch + gap, Int(get(p, "capacity", 10)))
    end
    return belts
end

"""Run `sc` headlessly and sample metrics and product positions every `sample_dt` seconds."""
function run_lab_trace(sc::LabScenario; seed::Integer = 2024)::LabTrace
    Random.seed!(seed)
    mgr = RuntimeManager()
    ok, diags = stage_and_activate!(mgr, sc.spec)
    ok || error("Conveyor lab scenario '$(sc.id)' failed to compile: $(join([d.message for d in diags], "; "))")
    inst = mgr.active_instance
    world = inst.world
    ir = inst.execution_ir
    tr = LabTrace(sc.id, Float64[], Dict{String, Vector{Float64}}(), Dict{String, Vector{String}}(),
                  Dict{String, Dict{UInt64, Vector{Tuple{Float64, Float64}}}}(), _lab_belts(sc.spec), 0, 0, 0, 0)
    for step in 1:round(Int, sc.t_end / sc.sample_dt)
        GodotBridge.step!(mgr, sc.sample_dt, "s", t -> nothing)
        t = world.time
        push!(tr.t, t)
        snap = build_snapshot(inst)
        for el in snap.elements_state
            for (k, v) in el.custom_metrics
                if v isa Real
                    push!(get!(tr.metrics, "$(el.element_id).$k", Float64[]), Float64(v))
                elseif k == "state" && v isa AbstractString
                    push!(get!(tr.states, el.element_id, String[]), String(v))
                end
            end
        end
        for (uid, k) in world.entity_kinematics
            belt_id = get(ir.zone_to_element, k.zone_id, "")
            haskey(tr.belts, belt_id) || continue
            per_belt = get!(tr.tracks, belt_id, Dict{UInt64, Vector{Tuple{Float64, Float64}}}())
            push!(get!(per_belt, uid, Tuple{Float64, Float64}[]), (t, SimCore.kinematics_distance(k, t)))
        end
    end
    sys = world.zone_stats[0]
    held = Set{UInt64}()
    for bag in values(world.zone_attributes)
        for ev in get(bag, "_feeder_wait", ())
            push!(held, ev.entity_id)
        end
    end
    tr.entries = sys.total_arrivals
    tr.exits = sys.total_departures
    tr.in_system = length(union(Set(keys(world.des_agents)), held))
    tr.blocked_count = world.stats.blocked_count
    return tr
end

# ── Invariants every scenario must satisfy ────────────────────────────────────

function lab_generic_checks(tr::LabTrace)::Vector{Tuple{String, Bool, String}}
    out = Tuple{String, Bool, String}[]
    for (bid, belt) in sort!(collect(tr.belts); by = first)
        spacing = lab_series(tr, "$bid.min_spacing_m")
        worst = isempty(spacing) ? Inf : minimum(spacing)
        push!(out, ("$bid: products never overlap (min spacing >= $(round(belt.spacing, digits=3)) m)",
                    worst >= belt.spacing - 1e-6, "smallest spacing seen $(round(worst, digits=4)) m"))

        occ = lab_series(tr, "$bid.in_transit")
        push!(out, ("$bid: never holds more than its capacity ($(belt.capacity))",
                    isempty(occ) || maximum(occ) <= belt.capacity, "peak $(isempty(occ) ? 0 : Int(maximum(occ)))"))

        tracks = get(tr.tracks, bid, Dict{UInt64, Vector{Tuple{Float64, Float64}}}())
        backwards = 0
        for (_, pts) in tracks, i in 2:length(pts)
            pts[i][2] < pts[i - 1][2] - 1e-9 && (backwards += 1)
        end
        push!(out, ("$bid: no product ever moves backwards", backwards == 0, "$backwards backward steps"))

        if belt.mode !== :accumulating
            # Rigid belt or bed: while the outlet is blocked nothing may move.
            states = get(tr.states, bid, String[])
            moved = 0
            for (_, pts) in tracks, j in 2:length(pts)
                i = searchsortedfirst(tr.t, pts[j][1])
                (i > 1 && states[i] == "BLOCKED" && states[i - 1] == "BLOCKED") || continue
                abs(pts[j][2] - pts[j - 1][2]) > 1e-6 && (moved += 1)
            end
            push!(out, ("$bid: nothing moves while the outlet is blocked", moved == 0, "$moved moving products while blocked"))
        end
    end
    push!(out, ("no product lost or created (entries = exits + in system)",
                tr.entries == tr.exits + tr.in_system,
                "entries=$(tr.entries) exits=$(tr.exits) in_system=$(tr.in_system)"))
    return out
end

function lab_evaluate(sc::LabScenario, tr::LabTrace)::Vector{Tuple{String, Bool, String}}
    results = lab_generic_checks(tr)
    for c in sc.checks
        ok, detail = c.f(tr)
        push!(results, (c.name, ok, detail))
    end
    return results
end

# ── Reporting: CSV, SVG charts, HTML index ────────────────────────────────────

const _LAB_COLORS = ["#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b", "#17becf", "#7f7f7f"]

_xml(s) = replace(replace(replace(string(s), "&" => "&amp;"), "<" => "&lt;"), ">" => "&gt;")

function _svg_lines(title, xlabel, ylabel, series::Vector{<:Tuple}; legend::Bool = true,
                    stepped::Bool = false, w = 780, h = 400)
    xs_all = reduce(vcat, (s[2] for s in series); init = Float64[])
    ys_all = reduce(vcat, (s[3] for s in series); init = Float64[])
    isempty(xs_all) && return "<svg xmlns='http://www.w3.org/2000/svg' width='$w' height='60'><text x='10' y='30'>$(_xml(title)): no data</text></svg>"
    x0, x1 = extrema(xs_all)
    y0, y1 = min(0.0, minimum(ys_all)), maximum(ys_all)
    x1 == x0 && (x1 = x0 + 1.0)
    y1 <= y0 && (y1 = y0 + 1.0)
    y1 += 0.05 * (y1 - y0)
    ml, mr, mt, mb = 60, legend ? 190 : 20, 36, 44
    px(x) = ml + (x - x0) / (x1 - x0) * (w - ml - mr)
    py(y) = h - mb - (y - y0) / (y1 - y0) * (h - mt - mb)
    io = IOBuffer()
    println(io, "<svg xmlns='http://www.w3.org/2000/svg' width='$w' height='$h' font-family='sans-serif' font-size='11'>")
    println(io, "<rect width='$w' height='$h' fill='white'/>")
    println(io, "<text x='$(ml)' y='20' font-size='14' font-weight='bold'>$(_xml(title))</text>")
    for i in 0:5
        gx = x0 + (x1 - x0) * i / 5
        gy = y0 + (y1 - y0) * i / 5
        println(io, "<line x1='$(px(gx))' y1='$(mt)' x2='$(px(gx))' y2='$(h - mb)' stroke='#e5e5e5'/>")
        println(io, "<line x1='$(ml)' y1='$(py(gy))' x2='$(w - mr)' y2='$(py(gy))' stroke='#e5e5e5'/>")
        println(io, "<text x='$(px(gx))' y='$(h - mb + 16)' text-anchor='middle'>$(round(gx, sigdigits = 3))</text>")
        println(io, "<text x='$(ml - 6)' y='$(py(gy) + 4)' text-anchor='end'>$(round(gy, sigdigits = 3))</text>")
    end
    println(io, "<rect x='$(ml)' y='$(mt)' width='$(w - ml - mr)' height='$(h - mt - mb)' fill='none' stroke='#444'/>")
    println(io, "<text x='$(ml + (w - ml - mr) / 2)' y='$(h - 6)' text-anchor='middle'>$(_xml(xlabel))</text>")
    println(io, "<text x='14' y='$(mt + (h - mt - mb) / 2)' transform='rotate(-90 14 $(mt + (h - mt - mb) / 2))' text-anchor='middle'>$(_xml(ylabel))</text>")
    for (i, (label, xs, ys)) in enumerate(series)
        color = _LAB_COLORS[mod1(i, length(_LAB_COLORS))]
        pts = String[]
        for j in eachindex(xs)
            stepped && j > 1 && push!(pts, "$(px(xs[j])),$(py(ys[j - 1]))")
            push!(pts, "$(px(xs[j])),$(py(ys[j]))")
        end
        println(io, "<polyline fill='none' stroke='$color' stroke-width='$(legend ? 1.8 : 1.0)' points='$(join(pts, ' '))'/>")
        legend && println(io, "<rect x='$(w - mr + 12)' y='$(mt + 16 * (i - 1))' width='10' height='10' fill='$color'/><text x='$(w - mr + 28)' y='$(mt + 16 * (i - 1) + 9)'>$(_xml(label))</text>")
    end
    println(io, "</svg>")
    return String(take!(io))
end

"""Write CSV, space-time diagrams, subplot charts and an HTML page for one scenario; returns the HTML path."""
function write_lab_report(sc::LabScenario, tr::LabTrace, results, dir::AbstractString)
    out = joinpath(dir, sc.id)
    mkpath(out)
    keys_sorted = sort!(collect(keys(tr.metrics)))
    open(joinpath(out, "data.csv"), "w") do io
        println(io, "time,", join(keys_sorted, ","))
        for i in eachindex(tr.t)
            println(io, tr.t[i], ",", join((tr.metrics[k][i] for k in keys_sorted), ","))
        end
    end
    open(joinpath(out, "tracks.csv"), "w") do io
        println(io, "belt,product,time,distance_m")
        for (bid, per) in sort!(collect(tr.tracks); by = first), (uid, pts) in sort!(collect(per); by = first), (t, d) in pts
            println(io, bid, ",", uid, ",", t, ",", d)
        end
    end
    images = Tuple{String, String}[]
    for (bid, per) in sort!(collect(tr.tracks); by = first)
        series = [("p$uid", first.(pts), last.(pts)) for (uid, pts) in sort!(collect(per); by = first)]
        belt = tr.belts[bid]
        fname = "spacetime_$bid.svg"
        write(joinpath(out, fname), _svg_lines("$bid ($(belt.mode)): position of every product vs time", "time (s)",
                                              "distance along belt (m), outlet = $(belt.length)", series; legend = false))
        push!(images, (fname, "Space-time diagram of $bid: horizontal segments are products at rest, parallel slopes are moving products, lines never cross."))
    end
    for el in sc.spec["elements"]
        el["kind"] == "chart_station" || continue
        for sp in el["properties"]["subplots"]
            series = Tuple{String, Vector{Float64}, Vector{Float64}}[]
            for sig in sp["signals"]
                v = lab_series(tr, "$(sig["entity_id"]).$(sig["y_metric"])")
                isempty(v) || push!(series, (sig["label"], tr.t, v))
            end
            fname = "chart_$(sp["id"]).svg"
            write(joinpath(out, fname), _svg_lines(sp["title"], "time (s)", sp["y_label"], series; stepped = true))
            push!(images, (fname, sp["title"]))
        end
    end
    html = IOBuffer()
    println(html, "<html><head><meta charset='utf-8'><title>$(_xml(sc.title))</title></head><body style='font-family:sans-serif;max-width:900px;margin:20px auto'>")
    println(html, "<h1>$(_xml(sc.title))</h1><p>$(_xml(sc.description))</p>")
    npass = count(r -> r[2], results)
    println(html, "<h2>Physical checks: $npass / $(length(results)) passed</h2><table border='1' cellpadding='4' style='border-collapse:collapse'>")
    for (name, ok, detail) in results
        println(html, "<tr><td style='color:$(ok ? "green" : "red")'><b>$(ok ? "PASS" : "FAIL")</b></td><td>$(_xml(name))</td><td>$(_xml(detail))</td></tr>")
    end
    println(html, "</table><p>Data: <a href='data.csv'>data.csv</a>, <a href='tracks.csv'>tracks.csv</a></p>")
    for (f, cap) in images
        println(html, "<h3>$(_xml(cap))</h3><img src='$f'/>")
    end
    println(html, "</body></html>")
    path = joinpath(out, "index.html")
    write(path, String(take!(html)))
    return path
end

"""Run every scenario, write all reports and a top-level index; returns `id => results`."""
function run_conveyor_lab(scenarios::Vector{LabScenario}, report_dir::AbstractString)
    mkpath(report_dir)
    all_results = Dict{String, Vector{Tuple{String, Bool, String}}}()
    rows = String[]
    for sc in scenarios
        tr = run_lab_trace(sc)
        results = lab_evaluate(sc, tr)
        all_results[sc.id] = results
        write_lab_report(sc, tr, results, report_dir)
        np = count(r -> r[2], results)
        push!(rows, "<tr><td><a href='$(sc.id)/index.html'>$(_xml(sc.title))</a></td><td>$np / $(length(results))</td><td>$(np == length(results) ? "PASS" : "FAIL")</td></tr>")
    end
    write(joinpath(report_dir, "index.html"),
          "<html><body style='font-family:sans-serif;max-width:900px;margin:20px auto'><h1>Conveyor Physics Lab</h1><table border='1' cellpadding='4' style='border-collapse:collapse'><tr><th>Scenario</th><th>Checks</th><th>Result</th></tr>" *
          join(rows) * "</table></body></html>")
    return all_results
end
