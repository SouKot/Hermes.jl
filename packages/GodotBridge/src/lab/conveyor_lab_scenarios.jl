# packages/GodotBridge/src/lab/conveyor_lab_scenarios.jl
#
# Conveyor Physics Lab: SceneSpec scenarios that stress every conveyor mode, each with live charts
# and quantitative physical checks. The same specs are exported as JSON for the Godot Examples menu.

_lab_dist(v::Real) = Dict{String, Any}("type" => "deterministic", "value" => Float64(v))

function _lab_signal(entity::String, metric::String, label::String)
    return Dict{String, Any}("entity_id" => entity, "y_metric" => metric, "x_metric" => "__time__", "label" => label)
end

function _lab_plot(idx::Int, title::String, ylabel::String, signals::Vector{Dict{String, Any}})
    return Dict{String, Any}(
        "id" => "sp_$idx", "port_id" => "P$idx", "title" => title, "type" => "time_series",
        "y_label" => ylabel, "autoscale" => true, "y_min" => 0.0, "y_max" => 100.0, "mode" => "overlay",
        "grid" => Dict{String, Any}("col" => (idx - 1) % 2, "row" => (idx - 1) ÷ 2, "col_span" => 1, "row_span" => 1),
        "signals" => signals,
    )
end

function _lab_chart(id::String, title::String, pos::Tuple{Float64, Float64, Float64}, plots::Vector{Dict{String, Any}})
    el = _ex_elem(id, title, "chart_station", pos, (10.0, 6.0, 1.2),
                  Dict{String, Any}("title" => title, "time_window" => 120.0, "grid_columns" => 2,
                                    "grid_rows" => cld(length(plots), 2), "subplots" => plots);
                  color = "#1f6feb")
    el["input_ports"] = [_ex_port("P$i", "Port $i (Subplot $i)", "input"; kind = "signal") for i in eachindex(plots)]
    return el
end

"""Source -> conveyor -> machine -> sink on one row; element ids carry the lane suffix `key`."""
function _lab_lane(key::String, y::Float64;
                   arrival = 1.0, mode = "free_flow", length = 10.0, speed = 1.0, capacity = 20,
                   pitch = 0.5, gap = 0.0, interval = 1.0, service = 4.0,
                   machine_props = Dict{String, Any}(), x0 = 0.0)
    x_belt = x0 + 3.0
    x_mc = x_belt + length + 1.0
    mc_props = Dict{String, Any}("servers" => 1, "service_time" => _lab_dist(service))
    merge!(mc_props, machine_props)
    gap_note = mode == "free_flow" ? (gap > 0 ? ", gap $(gap) m ignored" : "") : ", gap $(gap) m"
    els = Dict{String, Any}[
        _ex_elem("src$key", "Source$key", "source", (x0, y, 0.0), (2.5, 2.0, 1.2),
                 Dict{String, Any}("interarrival_time" => _lab_dist(arrival)); color = "#f39c12"),
        _ex_elem("belt$key", "Belt$key ($mode$gap_note)", "conveyor", (x_belt, y, 0.0), (length, 1.2, 0.8),
                 Dict{String, Any}("length" => length, "speed" => speed, "capacity" => capacity,
                                   "conveyor_mode" => mode, "accumulation_pitch" => pitch,
                                   "accumulation_gap" => gap, "index_interval" => interval); color = "#2ecc71"),
        _ex_elem("mc$key", "Machine$key", "server", (x_mc, y, 0.0), (3.0, 2.2, 1.8), mc_props; color = "#e67e22"),
        _ex_elem("snk$key", "Sink$key", "sink", (x_mc + 4.5, y, 0.0), (2.5, 2.0, 1.2),
                 Dict{String, Any}(); color = "#e74c3c"),
    ]
    conns = Dict{String, Any}[
        _ex_conn("c_src$key", "src$key", "belt$key"),
        _ex_conn("c_belt$key", "belt$key", "mc$key"),
        _ex_conn("c_mc$key", "mc$key", "snk$key"),
    ]
    return els, conns
end

function _lab_doc(id, title, description, els, conns, t_end)
    doc = _ex_base_doc(id, title, description, els, conns)
    doc["simulation"]["max_duration"] = Float64(t_end)
    return doc
end

_within(x, target, tol) = isfinite(x) && abs(x - target) <= tol * abs(target)
_r(x; d = 4) = round(x; digits = d)

"""Lanes of one scene stacked in rows `6 m` apart, with a chart station placed above them."""
function _lab_stack(specs::Vector, plots_fn, chart_title::String)
    els = Dict{String, Any}[]
    conns = Dict{String, Any}[]
    for (i, kw) in enumerate(specs)
        e, c = _lab_lane(kw.key, 6.0 * (i - 1); kw.args...)
        append!(els, e); append!(conns, c)
    end
    push!(els, _lab_chart("chart_lab", chart_title, (14.0, 6.0 * length(specs) + 4.0, 0.8), plots_fn()))
    return els, conns
end

_lane(key; args...) = (key = key, args = args)

# ── 1. Free-flow belt stops completely behind a busy machine ─────────────────────────────

function _lab_free_flow_stop_go()
    els, conns = _lab_stack([_lane(""; arrival = 1.0, mode = "free_flow", length = 10.0, speed = 1.0, service = 4.0)],
        () -> [
            _lab_plot(1, "Product positions on the belt (front to back)", "distance (m)",
                      [_lab_signal("belt", "pos_$r", n) for (r, n) in enumerate(("lead", "2nd", "3rd", "4th"))]),
            _lab_plot(2, "Belt state: moving / stopped / blocked at outlet", "count",
                      [_lab_signal("belt", "moving_count", "moving"), _lab_signal("belt", "stopped_count", "stopped"),
                       _lab_signal("belt", "blocked_at_outlet", "outlet blocked (0/1)")]),
            _lab_plot(3, "Smallest distance between neighbouring products", "metres",
                      [_lab_signal("belt", "min_spacing_m", "min spacing")]),
            _lab_plot(4, "Machine, belt load and stalled source", "count",
                      [_lab_signal("mc", "busy_servers", "machine busy"), _lab_signal("belt", "in_transit", "products on belt"),
                       _lab_signal("src", "stalled_products", "source stalled")]),
        ], "Free-flow stop-and-go")
    t_end = 300.0
    doc = _lab_doc("conv_lab_free_flow_stop_go", "Conveyor Lab 1: Free-Flow Stop-and-Go",
        "A free-flow belt (10 m, 1 m/s) feeds a machine that needs 4 s per product while the source delivers one per second. " *
        "The whole belt must halt the moment its lead product cannot enter the machine and restart together when the machine frees. " *
        "Expect flat position traces while blocked, no overlap, source stalls, and 0.25 products/s throughput.", els, conns, t_end)
    checks = [
        LabCheck("machine throughput equals its rate 1/4 per second", tr -> begin
            r = lab_rate(tr, "mc.total_served", 100.0); (_within(r, 0.25, 0.05), "measured $(_r(r)) /s")
        end),
        LabCheck("belt halts and restarts repeatedly", tr -> begin
            st = tr.states["belt"]; (count(==("BLOCKED"), st) > 20 && count(==("RUNNING"), st) > 20,
                                     "blocked samples $(count(==("BLOCKED"), st)), running samples $(count(==("RUNNING"), st))")
        end),
        LabCheck("source stalls while the belt is jammed", tr -> begin
            m = maximum(lab_series(tr, "src.stalled_products")); (m >= 1, "peak stalled products $(Int(m))")
        end),
    ]
    return LabScenario("conv_lab_free_flow_stop_go", "1. Free-flow stop-and-go", doc["scene"]["description"], doc, t_end, 0.25, checks)
end

# ── 2. Belt throughput is v / (pitch + gap) ──────────────────────────────────────────────

function _lab_gap_throughput()
    gaps = ("_a" => 0.0, "_b" => 0.5, "_c" => 1.5)
    lanes = [_lane(k; arrival = 0.2, mode = "accumulating", length = 10.0, speed = 1.0, capacity = 60, gap = g, service = 0.05) for (k, g) in gaps]
    push!(lanes, _lane("_d"; arrival = 0.2, mode = "free_flow", length = 10.0, speed = 1.0, capacity = 60, gap = 1.5, service = 0.05))
    names = ["gap 0", "gap 0.5", "gap 1.5", "free-flow (gap ignored)"]
    els, conns = _lab_stack(lanes, () -> [
            _lab_plot(1, "Products delivered (slope = throughput)", "products",
                      [_lab_signal("mc$k", "total_served", n) for (k, n) in zip(("_a", "_b", "_c", "_d"), names)]),
            _lab_plot(2, "Smallest distance between neighbouring products", "metres",
                      [_lab_signal("belt$k", "min_spacing_m", n) for (k, n) in zip(("_a", "_b", "_c", "_d"), names)]),
            _lab_plot(3, "Products on each belt", "count",
                      [_lab_signal("belt$k", "in_transit", n) for (k, n) in zip(("_a", "_b", "_c", "_d"), names)]),
            _lab_plot(4, "Sources waiting for room on the belt", "count",
                      [_lab_signal("src$k", "stalled_products", n) for (k, n) in zip(("_a", "_b", "_c", "_d"), names)]),
        ], "Gap vs throughput")
    t_end = 150.0
    doc = _lab_doc("conv_lab_gap_throughput", "Conveyor Lab 2: Product Gap Sets Belt Throughput",
        "Four fully-fed belts at 1 m/s with 0.5 m product pitch and a fast machine. An accumulating belt can discharge at most " *
        "speed / (pitch + gap): 2.0, 1.0 and 0.5 per second for gaps 0, 0.5 and 1.5 m. The free-flow belt ignores the gap and runs at speed / pitch = 2.0.", els, conns, t_end)
    expected = ("_a" => 2.0, "_b" => 1.0, "_c" => 0.5, "_d" => 2.0)
    checks = [LabCheck("lane$k delivers $(e) products/s (= speed / spacing)", tr -> begin
                  r = lab_rate(tr, "mc$k.total_served", 60.0); (_within(r, e, 0.05), "measured $(_r(r)) /s")
              end) for (k, e) in expected]
    return LabScenario("conv_lab_gap_throughput", "2. Gap sets throughput", doc["scene"]["description"], doc, t_end, 0.25, checks)
end

# ── 3. Accumulating belts pack with exactly pitch + gap ──────────────────────────────────

function _lab_accumulation_packing()
    gaps = ("_a" => 0.0, "_b" => 0.25, "_c" => 1.0)
    lanes = [_lane(k; arrival = 0.5, mode = "accumulating", length = 8.0, speed = 1.0, capacity = 40, gap = g, service = 10000.0) for (k, g) in gaps]
    keys3 = ("_a", "_b", "_c"); names = ["gap 0", "gap 0.25", "gap 1.0"]
    els, conns = _lab_stack(lanes, () -> [
            _lab_plot(1, "Lead product position", "metres",
                      [_lab_signal("belt$k", "pos_1", n) for (k, n) in zip(keys3, names)]),
            _lab_plot(2, "Second product position (= belt length - spacing)", "metres",
                      [_lab_signal("belt$k", "pos_2", n) for (k, n) in zip(keys3, names)]),
            _lab_plot(3, "Products on each belt", "count",
                      [_lab_signal("belt$k", "in_transit", n) for (k, n) in zip(keys3, names)]),
            _lab_plot(4, "Smallest distance between neighbouring products", "metres",
                      [_lab_signal("belt$k", "min_spacing_m", n) for (k, n) in zip(keys3, names)]),
        ], "Accumulation packing")
    t_end = 90.0
    doc = _lab_doc("conv_lab_accumulation_packing", "Conveyor Lab 3: Accumulation Packing",
        "Three 8 m accumulating belts feed a machine that never frees. Products must stop one slot (pitch 0.5 + gap) apart behind the lead product: " *
        "spacing 0.5, 0.75 and 1.5 m, and the belt holds floor(8 / spacing) + 1 products.", els, conns, t_end)
    expect = ("_a" => 0.5, "_b" => 0.75, "_c" => 1.5)
    checks = LabCheck[]
    for (k, s) in expect
        push!(checks, LabCheck("lane$k: lead rests at the outlet (8 m)", tr -> begin
            v = lab_series(tr, "belt$k.pos_1")[end]; (abs(v - 8.0) < 1e-6, "lead at $(_r(v)) m")
        end))
        push!(checks, LabCheck("lane$k: resting spacing is exactly $s m", tr -> begin
            v = lab_series(tr, "belt$k.min_spacing_m")[end]; (abs(v - s) < 1e-6, "spacing $(_r(v, d = 6)) m")
        end))
        push!(checks, LabCheck("lane$k: belt holds floor(8 / $s) + 1 = $(floor(Int, 8.0 / s) + 1) products", tr -> begin
            v = Int(lab_series(tr, "belt$k.in_transit")[end]); (v == floor(Int, 8.0 / s) + 1, "holds $v")
        end))
    end
    return LabScenario("conv_lab_accumulation_packing", "3. Accumulation packing", doc["scene"]["description"], doc, t_end, 0.25, checks)
end

# ── 4. The three modes behind the same bottleneck ────────────────────────────────────────

function _lab_mode_comparison()
    lanes = [_lane("_ff"; arrival = 1.0, mode = "free_flow", length = 10.0, capacity = 12, service = 4.0),
             _lane("_ac"; arrival = 1.0, mode = "accumulating", length = 10.0, capacity = 12, gap = 0.25, service = 4.0),
             _lane("_ix"; arrival = 1.0, mode = "indexing", length = 10.0, capacity = 12, gap = 0.5, interval = 1.0, service = 4.0)]
    ks = ("_ff", "_ac", "_ix"); names = ["free-flow", "accumulating", "indexing"]
    els, conns = _lab_stack(lanes, () -> [
            _lab_plot(1, "Products on each belt", "count", [_lab_signal("belt$k", "in_transit", n) for (k, n) in zip(ks, names)]),
            _lab_plot(2, "Products delivered", "products", [_lab_signal("mc$k", "total_served", n) for (k, n) in zip(ks, names)]),
            _lab_plot(3, "Lead product held at outlet (0/1)", "state", [_lab_signal("belt$k", "blocked_at_outlet", n) for (k, n) in zip(ks, names)]),
            _lab_plot(4, "Products still moving", "count", [_lab_signal("belt$k", "moving_count", n) for (k, n) in zip(ks, names)]),
        ], "Mode comparison")
    t_end = 300.0
    doc = _lab_doc("conv_lab_mode_comparison", "Conveyor Lab 4: Free-Flow vs Accumulating vs Indexing",
        "Identical source (1/s) and machine (4 s) behind a free-flow, an accumulating and an indexing belt. Steady throughput is set by the " *
        "machine (0.25/s) in every mode; the modes differ in how many products wait, whether they keep moving, and how the line is held.", els, conns, t_end)
    checks = [LabCheck("$n lane delivers 0.25 products/s", tr -> begin
                  r = lab_rate(tr, "mc$k.total_served", 100.0); (_within(r, 0.25, 0.06), "measured $(_r(r)) /s")
              end) for (k, n) in zip(ks, names)]
    push!(checks, LabCheck("accumulating belt keeps moving products while others wait; free-flow and indexing never do", tr -> begin
        ff = lab_series(tr, "belt_ff.moving_count"); bl = lab_series(tr, "belt_ff.blocked_at_outlet")
        ok_ff = all(bl[i] == 0 || ff[i] == 0 for i in eachindex(bl))
        ac = lab_series(tr, "belt_ac.moving_count"); acb = lab_series(tr, "belt_ac.blocked_at_outlet")
        ok_ac = any(acb[i] == 1 && ac[i] > 0 for i in eachindex(acb))
        (ok_ff && ok_ac, "free-flow rigid=$ok_ff, accumulating shows moving products behind a held lead=$ok_ac")
    end))
    return LabScenario("conv_lab_mode_comparison", "4. Mode comparison", doc["scene"]["description"], doc, t_end, 0.25, checks)
end

# ── 5. Diverter: only open destinations are used ─────────────────────────────────────────

function _lab_diverter_lane(key::String, y::Float64, rule::String)
    x_belt, L = 3.0, 6.0
    xm = x_belt + L + 1.0
    props = Dict{String, Any}("length" => L, "speed" => 1.0, "capacity" => 20, "conveyor_mode" => "free_flow",
                              "routing_rule" => rule, "routing_weights" => Dict{String, Any}("mcA$key" => 0.5, "mcB$key" => 0.5))
    els = Dict{String, Any}[
        _ex_elem("src$key", "Source$key", "source", (0.0, y, 0.0), (2.5, 2.0, 1.2),
                 Dict{String, Any}("interarrival_time" => _lab_dist(2.0)); color = "#f39c12"),
        _ex_elem("belt$key", "Diverter Belt$key ($rule)", "conveyor", (x_belt, y, 0.0), (L, 1.2, 0.8), props; color = "#2ecc71"),
        _ex_elem("mcA$key", "Slow Machine A$key", "server", (xm, y + 2.5, 0.0), (3.0, 2.2, 1.8),
                 Dict{String, Any}("servers" => 1, "service_time" => _lab_dist(8.0)); color = "#e67e22"),
        _ex_elem("mcB$key", "Fast Machine B$key", "server", (xm, y - 2.5, 0.0), (3.0, 2.2, 1.8),
                 Dict{String, Any}("servers" => 1, "service_time" => _lab_dist(2.0)); color = "#e67e22"),
        _ex_elem("snk$key", "Sink$key", "sink", (xm + 4.5, y, 0.0), (2.5, 2.0, 1.2), Dict{String, Any}(); color = "#e74c3c"),
    ]
    conns = Dict{String, Any}[
        _ex_conn("c_src$key", "src$key", "belt$key"), _ex_conn("c_a$key", "belt$key", "mcA$key", ordering = 1),
        _ex_conn("c_b$key", "belt$key", "mcB$key", ordering = 2),
        _ex_conn("c_ma$key", "mcA$key", "snk$key"), _ex_conn("c_mb$key", "mcB$key", "snk$key"),
    ]
    return els, conns
end

function _lab_diverter_open_paths()
    els = Dict{String, Any}[]; conns = Dict{String, Any}[]
    for (i, (k, rule)) in enumerate(("_p" => "probabilistic", "_r" => "round_robin", "_s" => "shortest_queue"))
        e, c = _lab_diverter_lane(k, 8.0 * (i - 1), rule); append!(els, e); append!(conns, c)
    end
    ks = ("_p", "_r", "_s"); rn = ["probabilistic", "round-robin", "shortest-queue"]
    push!(els, _lab_chart("chart_lab", "Diverter to open destinations", (14.0, 30.0, 0.8), [
        _lab_plot(1, "Slow machine A: products delivered", "products", [_lab_signal("mcA$k", "total_served", n) for (k, n) in zip(ks, rn)]),
        _lab_plot(2, "Fast machine B: products delivered", "products", [_lab_signal("mcB$k", "total_served", n) for (k, n) in zip(ks, rn)]),
        _lab_plot(3, "Diverter belt: lead product held at outlet (0/1)", "state", [_lab_signal("belt$k", "blocked_at_outlet", n) for (k, n) in zip(ks, rn)]),
        _lab_plot(4, "Slow machine A utilization", "percent", [_lab_signal("mcA$k", "utilization_pct", n) for (k, n) in zip(ks, rn)]),
    ]))
    t_end = 500.0
    doc = _lab_doc("conv_lab_diverter_open_paths", "Conveyor Lab 5: Diverter Uses Only Open Destinations",
        "A belt delivers 0.5 products/s to a slow machine A (8 s) and a fast machine B (2 s), through probabilistic 50/50, round-robin and " *
        "shortest-queue routing. A product is never pushed into a busy machine: A can only take 1/8 per second, so B absorbs the rest and nothing is lost.", els, conns, t_end)
    checks = LabCheck[]
    for (k, n) in zip(ks, rn)
        push!(checks, LabCheck("$n: slow machine A never exceeds its rate 1/8", tr -> begin
            r = lab_rate(tr, "mcA$k.total_served", 100.0); (r <= 0.125 * 1.03 && r >= 0.09, "A delivers $(_r(r)) /s")
        end))
        push!(checks, LabCheck("$n: all offered flow (0.5/s) is served", tr -> begin
            a = lab_rate(tr, "mcA$k.total_served", 100.0); b = lab_rate(tr, "mcB$k.total_served", 100.0)
            (_within(a + b, 0.5, 0.05), "A+B deliver $(_r(a + b)) /s")
        end))
    end
    return LabScenario("conv_lab_diverter_open_paths", "5. Diverter to open paths", doc["scene"]["description"], doc, t_end, 0.5, checks)
end

# ── 6. Backpressure through a chain of different belts ───────────────────────────────────

function _lab_chain_backpressure()
    L = 5.0
    belt(id, x, mode, gap) = _ex_elem(id, "$id ($mode)", "conveyor", (x, 0.0, 0.0), (L, 1.2, 0.8),
        Dict{String, Any}("length" => L, "speed" => 1.0, "capacity" => 10, "conveyor_mode" => mode,
                          "accumulation_pitch" => 0.5, "accumulation_gap" => gap, "index_interval" => 0.5); color = "#2ecc71")
    els = Dict{String, Any}[
        _ex_elem("src", "Source", "source", (0.0, 0.0, 0.0), (2.5, 2.0, 1.2), Dict{String, Any}("interarrival_time" => _lab_dist(1.0)); color = "#f39c12"),
        belt("belt1", 3.0, "free_flow", 0.0), belt("belt2", 3.0 + L + 0.5, "accumulating", 0.25), belt("belt3", 3.0 + 2 * (L + 0.5), "indexing", 0.5),
        _ex_elem("mc", "Machine", "server", (3.0 + 3 * (L + 0.5) + 0.5, 0.0, 0.0), (3.0, 2.2, 1.8),
                 Dict{String, Any}("servers" => 1, "service_time" => _lab_dist(10.0)); color = "#e67e22"),
        _ex_elem("snk", "Sink", "sink", (3.0 + 3 * (L + 0.5) + 5.0, 0.0, 0.0), (2.5, 2.0, 1.2), Dict{String, Any}(); color = "#e74c3c"),
    ]
    conns = Dict{String, Any}[_ex_conn("c1", "src", "belt1"), _ex_conn("c2", "belt1", "belt2"), _ex_conn("c3", "belt2", "belt3"),
                              _ex_conn("c4", "belt3", "mc"), _ex_conn("c5", "mc", "snk")]
    push!(els, _lab_chart("chart_lab", "Chain backpressure", (14.0, 8.0, 0.8), [
        _lab_plot(1, "Products on each belt", "count", [_lab_signal("belt$i", "in_transit", "belt $i") for i in 1:3]),
        _lab_plot(2, "Lead product held at outlet (0/1)", "state", [_lab_signal("belt$i", "blocked_at_outlet", "belt $i") for i in 1:3]),
        _lab_plot(3, "Smallest distance between neighbouring products", "metres", [_lab_signal("belt$i", "min_spacing_m", "belt $i") for i in 1:3]),
        _lab_plot(4, "Source waiting for room", "count", [_lab_signal("src", "stalled_products", "stalled products")]),
    ]))
    t_end = 200.0
    doc = _lab_doc("conv_lab_chain_backpressure", "Conveyor Lab 6: Backpressure Through a Belt Chain",
        "Free-flow, accumulating and indexing belts in series ahead of a 10 s machine. The jam must propagate upstream one belt at a time: " *
        "belt 3 blocks first, then belt 2, then belt 1, and finally the source stalls. No product is lost or overlaps at any hand-off.", els, conns, t_end)
    checks = [
        LabCheck("jam spreads upstream in order: belt 3, belt 2, belt 1, source", tr -> begin
            t3 = lab_first_time(tr, "belt3.blocked_at_outlet", >(0)); t2 = lab_first_time(tr, "belt2.blocked_at_outlet", >(0))
            t1 = lab_first_time(tr, "belt1.blocked_at_outlet", >(0)); ts = lab_first_time(tr, "src.stalled_products", >(0))
            (t3 < t2 < t1 < ts, "first blocked: belt3 t=$t3, belt2 t=$t2, belt1 t=$t1, source stalled t=$ts")
        end),
        LabCheck("machine delivers 0.1 products/s once saturated", tr -> begin
            r = lab_rate(tr, "mc.total_served", 100.0); (_within(r, 0.1, 0.06), "measured $(_r(r)) /s")
        end),
    ]
    return LabScenario("conv_lab_chain_backpressure", "6. Chain backpressure", doc["scene"]["description"], doc, t_end, 0.25, checks)
end

# ── 7. Machine breakdown stops the belt behind it ────────────────────────────────────────

function _lab_server_failure()
    els, conns = _lab_stack([_lane(""; arrival = 1.5, mode = "free_flow", length = 8.0, capacity = 12, service = 3.0,
                                   machine_props = Dict{String, Any}("failure_model" => "mtbf_mttr", "mtbf" => 40.0, "mttr" => 15.0))],
        () -> [
            _lab_plot(1, "Machine channels busy and total served", "count",
                      [_lab_signal("mc", "busy_servers", "busy"), _lab_signal("mc", "num_servers", "servers up")]),
            _lab_plot(2, "Belt: lead product held at outlet (0/1)", "state", [_lab_signal("belt", "blocked_at_outlet", "outlet blocked")]),
            _lab_plot(3, "Products on belt and waiting at source", "count",
                      [_lab_signal("belt", "in_transit", "on belt"), _lab_signal("src", "stalled_products", "source stalled")]),
            _lab_plot(4, "Products delivered", "products", [_lab_signal("mc", "total_served", "served")]),
        ], "Machine failure")
    t_end = 500.0
    doc = _lab_doc("conv_lab_server_failure", "Conveyor Lab 7: Machine Breakdown and Repair",
        "A machine with random breakdowns (MTBF 40 s, MTTR 15 s) sits behind an 8 m free-flow belt. While the machine is down the belt must stop, the lead product waits, " *
        "and when it is repaired flow resumes with no product lost.", els, conns, t_end)
    checks = [
        LabCheck("machine goes down and comes back", tr -> begin
            st = tr.states["mc"]; first_down = findfirst(==("DOWN"), st)
            (first_down !== nothing && any(!=("DOWN"), st[first_down:end]), "down for $(count(==("DOWN"), st)) of $(length(st)) samples")
        end),
        LabCheck("belt is blocked while the machine is down", tr -> begin
            st = tr.states["mc"]; bl = tr.states["belt"]
            n = count(i -> st[i] == "DOWN" && bl[i] == "BLOCKED", eachindex(st)); (n > 0, "$n samples")
        end),
        LabCheck("nothing is delivered during an outage (at most the job in progress)", tr -> begin
            st = tr.states["mc"]; served = lab_series(tr, "mc.total_served")
            periods = count(i -> st[i] == "DOWN" && (i == 1 || st[i - 1] != "DOWN"), eachindex(st))
            extra = sum(served[i] - served[i - 1] for i in 2:length(st) if st[i] == "DOWN" && st[i - 1] == "DOWN"; init = 0.0)
            (extra <= periods, "$(Int(extra)) deliveries inside $periods outage(s)")
        end),
        LabCheck("no arrival is turned away", tr -> (tr.blocked_count == 0, "blocked count $(tr.blocked_count)")),
    ]
    return LabScenario("conv_lab_server_failure", "7. Machine breakdown", doc["scene"]["description"], doc, t_end, 0.5, checks)
end

# ── 8. A machine blocked by a full belt ahead of it ──────────────────────────────────────

function _lab_blocking_after_service()
    els = Dict{String, Any}[
        _ex_elem("src", "Source", "source", (0.0, 0.0, 0.0), (2.5, 2.0, 1.2), Dict{String, Any}("interarrival_time" => _lab_dist(1.0)); color = "#f39c12"),
        _ex_elem("qa", "Press Buffer", "queue", (3.0, 0.0, 0.0), (3.5, 2.0, 0.8), Dict{String, Any}("capacity" => 400, "discipline" => "fifo"); color = "#3498db"),
        _ex_elem("mcA", "Fast Press A", "server", (7.5, 0.0, 0.0), (3.0, 2.2, 1.8),
                 Dict{String, Any}("servers" => 1, "service_time" => _lab_dist(0.5)); color = "#e67e22"),
        _ex_elem("belt", "Short Belt (cap 3)", "conveyor", (11.5, 0.0, 0.0), (3.0, 1.2, 0.8),
                 Dict{String, Any}("length" => 3.0, "speed" => 1.0, "capacity" => 3, "conveyor_mode" => "free_flow", "accumulation_pitch" => 0.5); color = "#2ecc71"),
        _ex_elem("mcB", "Slow Machine B", "server", (15.5, 0.0, 0.0), (3.0, 2.2, 1.8),
                 Dict{String, Any}("servers" => 1, "service_time" => _lab_dist(4.0)); color = "#e67e22"),
        _ex_elem("snk", "Sink", "sink", (20.0, 0.0, 0.0), (2.5, 2.0, 1.2), Dict{String, Any}(); color = "#e74c3c"),
    ]
    conns = Dict{String, Any}[_ex_conn("c1", "src", "qa"), _ex_conn("c2", "qa", "mcA"), _ex_conn("c3", "mcA", "belt"),
                              _ex_conn("c4", "belt", "mcB"), _ex_conn("c5", "mcB", "snk")]
    push!(els, _lab_chart("chart_lab", "Blocking after service", (14.0, 8.0, 0.8), [
        _lab_plot(1, "Press A holding a finished product (blocked after service)", "count", [_lab_signal("mcA", "blocked_after_service", "held by press A")]),
        _lab_plot(2, "Press A utilization", "percent", [_lab_signal("mcA", "utilization_pct", "press A"), _lab_signal("mcB", "utilization_pct", "machine B")]),
        _lab_plot(3, "Products on the short belt (capacity 3)", "count", [_lab_signal("belt", "in_transit", "on belt")]),
        _lab_plot(4, "Products delivered by machine B", "products", [_lab_signal("mcB", "total_served", "served")]),
    ]))
    t_end = 120.0
    doc = _lab_doc("conv_lab_blocking_after_service", "Conveyor Lab 8: Machine Blocked by a Full Belt",
        "A fast press (0.5 s) feeds a short 3-product belt in front of a slow machine (4 s). When the belt is full the press must keep its finished product in its " *
        "slot (blocking after service) instead of dropping it; the belt never exceeds its capacity and throughput is set by machine B.", els, conns, t_end)
    checks = [
        LabCheck("press holds a finished product when the belt is full", tr -> begin
            m = maximum(lab_series(tr, "mcA.blocked_after_service")); (m >= 1, "peak held $(Int(m))")
        end),
        LabCheck("belt never holds more than 3 products", tr -> begin
            m = maximum(lab_series(tr, "belt.in_transit")); (m <= 3, "peak $(Int(m))")
        end),
        LabCheck("machine B delivers 0.25 products/s", tr -> begin
            r = lab_rate(tr, "mcB.total_served", 40.0); (_within(r, 0.25, 0.06), "measured $(_r(r)) /s")
        end),
        LabCheck("no product dropped", tr -> (tr.blocked_count == 0, "blocked count $(tr.blocked_count)")),
    ]
    return LabScenario("conv_lab_blocking_after_service", "8. Blocking after service", doc["scene"]["description"], doc, t_end, 0.25, checks)
end

# ── 9. Two sources compete for one inlet ─────────────────────────────────────────────────

function _lab_merge_inlet_spacing()
    L = 10.0
    els = Dict{String, Any}[
        _ex_elem("src1", "Source 1", "source", (0.0, 3.0, 0.0), (2.5, 2.0, 1.2), Dict{String, Any}("interarrival_time" => _lab_dist(1.0)); color = "#f39c12"),
        _ex_elem("src2", "Source 2", "source", (0.0, -3.0, 0.0), (2.5, 2.0, 1.2), Dict{String, Any}("interarrival_time" => _lab_dist(1.0)); color = "#f39c12"),
        _ex_elem("belt", "Merge Belt (pitch 0.8)", "conveyor", (3.0, 0.0, 0.0), (L, 1.2, 0.8),
                 Dict{String, Any}("length" => L, "speed" => 1.0, "capacity" => 40, "conveyor_mode" => "free_flow", "accumulation_pitch" => 0.8); color = "#2ecc71"),
        _ex_elem("mc", "Fast Machine", "server", (L + 4.0, 0.0, 0.0), (3.0, 2.2, 1.8), Dict{String, Any}("servers" => 1, "service_time" => _lab_dist(0.1)); color = "#e67e22"),
        _ex_elem("snk", "Sink", "sink", (L + 8.5, 0.0, 0.0), (2.5, 2.0, 1.2), Dict{String, Any}(); color = "#e74c3c"),
    ]
    conns = Dict{String, Any}[_ex_conn("c1", "src1", "belt"), _ex_conn("c2", "src2", "belt"), _ex_conn("c3", "belt", "mc"), _ex_conn("c4", "mc", "snk")]
    push!(els, _lab_chart("chart_lab", "Merge inlet spacing", (14.0, 8.0, 0.8), [
        _lab_plot(1, "Products delivered (slope = throughput)", "products", [_lab_signal("mc", "total_served", "served")]),
        _lab_plot(2, "Smallest distance between neighbouring products", "metres", [_lab_signal("belt", "min_spacing_m", "min spacing")]),
        _lab_plot(3, "Sources waiting for room at the inlet", "count", [_lab_signal("src1", "stalled_products", "source 1"), _lab_signal("src2", "stalled_products", "source 2")]),
        _lab_plot(4, "Products on the belt", "count", [_lab_signal("belt", "in_transit", "on belt")]),
    ]))
    t_end = 200.0
    doc = _lab_doc("conv_lab_merge_inlet_spacing", "Conveyor Lab 9: Two Sources Share One Inlet",
        "Two sources each offer 1 product/s to a belt whose 0.8 m product footprint at 1 m/s allows only 1.25 products/s through the inlet. " *
        "The sources must wait their turn: spacing never drops below 0.8 m and throughput equals speed / pitch.", els, conns, t_end)
    checks = [
        LabCheck("inlet limits throughput to speed / pitch = 1.25 per second", tr -> begin
            r = lab_rate(tr, "mc.total_served", 60.0); (_within(r, 1.25, 0.05), "measured $(_r(r)) /s")
        end),
        LabCheck("both sources wait for room at some time", tr -> begin
            a = maximum(lab_series(tr, "src1.stalled_products")); b = maximum(lab_series(tr, "src2.stalled_products"))
            (a >= 1 && b >= 1, "peaks $(Int(a)) and $(Int(b))")
        end),
    ]
    return LabScenario("conv_lab_merge_inlet_spacing", "9. Merge at the inlet", doc["scene"]["description"], doc, t_end, 0.25, checks)
end

# ── 10. Indexing bed steps in whole slots and holds ──────────────────────────────────────

function _lab_indexing_hold()
    lanes = [_lane("_a"; arrival = 0.5, mode = "indexing", length = 8.0, capacity = 20, gap = 0.5, interval = 1.5, service = 0.1),
             _lane("_b"; arrival = 1.0, mode = "indexing", length = 8.0, capacity = 20, gap = 0.5, interval = 1.5, service = 10000.0)]
    ks = ("_a", "_b"); names = ["fast machine", "blocked machine"]
    els, conns = _lab_stack(lanes, () -> [
            _lab_plot(1, "Lead product position (steps of 1 m)", "metres", [_lab_signal("belt$k", "pos_1", n) for (k, n) in zip(ks, names)]),
            _lab_plot(2, "Second product position", "metres", [_lab_signal("belt$k", "pos_2", n) for (k, n) in zip(ks, names)]),
            _lab_plot(3, "Products on each belt", "count", [_lab_signal("belt$k", "in_transit", n) for (k, n) in zip(ks, names)]),
            _lab_plot(4, "Products delivered", "products", [_lab_signal("mc$k", "total_served", n) for (k, n) in zip(ks, names)]),
        ], "Indexing steps and hold")
    t_end = 120.0
    doc = _lab_doc("conv_lab_indexing_hold", "Conveyor Lab 10: Indexing Steps and Hold",
        "Indexing beds advance every product by one slot (0.5 pitch + 0.5 gap = 1 m) each 1.5 s pulse. Positions must always be whole slots. " *
        "With a free machine, throughput is one product per pulse (0.667/s); with a blocked machine the lead stops at the outlet and the whole bed stops pulsing, so nothing moves until the machine frees.", els, conns, t_end)
    checks = [
        LabCheck("every product always sits on a whole 1 m slot", tr -> begin
            bad = 0
            for (_, per) in tr.tracks, (_, pts) in per, (_, d) in pts
                abs(d - round(d)) > 1e-6 && (bad += 1)
            end
            (bad == 0, "$bad off-slot samples")
        end),
        LabCheck("free bed delivers one product per pulse (0.667 per second)", tr -> begin
            r = lab_rate(tr, "mc_a.total_served", 40.0); (_within(r, 1 / 1.5, 0.05), "measured $(_r(r)) /s")
        end),
        LabCheck("blocked bed rests with its lead at the outlet and nothing moves afterwards", tr -> begin
            p1 = lab_series(tr, "belt_b.pos_1"); p2 = lab_series(tr, "belt_b.pos_2"); n = length(p1)
            tail = (n - 239):n
            ok = abs(p1[end] - 8.0) < 1e-6 && all(==(p1[end]), p1[tail]) && all(==(p2[end]), p2[tail])
            (ok, "lead at $(_r(p1[end])) m, second at $(_r(p2[end])) m, unchanged for the last 60 s: $(all(==(p1[end]), p1[tail]) && all(==(p2[end]), p2[tail]))")
        end),
    ]
    return LabScenario("conv_lab_indexing_hold", "10. Indexing steps and hold", doc["scene"]["description"], doc, t_end, 0.25, checks)
end

"""All Conveyor Physics Lab scenarios, in menu order."""
function conveyor_lab_scenarios()::Vector{LabScenario}
    return LabScenario[
        _lab_free_flow_stop_go(), _lab_gap_throughput(), _lab_accumulation_packing(), _lab_mode_comparison(),
        _lab_diverter_open_paths(), _lab_chain_backpressure(), _lab_server_failure(), _lab_blocking_after_service(),
        _lab_merge_inlet_spacing(), _lab_indexing_hold(),
    ]
end

"""Write each scenario as `<id>.scenespec.json` plus `manifest.json` for the Godot Examples menu."""
function export_conveyor_lab_specs(dir::AbstractString)
    mkpath(dir)
    manifest = Dict{String, Any}[]
    for sc in conveyor_lab_scenarios()
        open(joinpath(dir, sc.id * ".scenespec.json"), "w") do io
            JSON.print(io, sc.spec, 2)
        end
        push!(manifest, Dict{String, Any}("id" => sc.id, "title" => sc.title, "category" => "conveyor", "description" => sc.description))
    end
    open(joinpath(dir, "manifest.json"), "w") do io
        JSON.print(io, manifest, 2)
    end
    return dir
end
