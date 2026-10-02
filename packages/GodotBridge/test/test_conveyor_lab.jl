using Test
using GodotBridge

@testset "Conveyor Physics Lab" begin
    scenarios = conveyor_lab_scenarios()
    @test length(scenarios) == 10

    @testset "Godot Examples scenes match the scenarios" begin
        mktempdir() do dir
            export_conveyor_lab_specs(dir)
            shipped = normpath(joinpath(@__DIR__, "..", "..", "..", "godot", "examples", "conveyor_lab"))
            for f in readdir(dir)
                @test isfile(joinpath(shipped, f))
                isfile(joinpath(shipped, f)) && @test read(joinpath(dir, f), String) == read(joinpath(shipped, f), String)
            end
        end
    end

    @testset "Snapshot draws a jammed free-flow belt without piling products up" begin
        sc = first(filter(s -> s.id == "conv_lab_free_flow_stop_go", scenarios))
        mgr = RuntimeManager()
        ok, _ = stage_and_activate!(mgr, sc.spec)
        @test ok
        GodotBridge.step!(mgr, 60.0, "s", t -> nothing)
        snap = build_snapshot(mgr.active_instance)
        on_belt = [e for e in snap.entities if e.current_location == "belt"]
        xs = sort([e.trajectory_2d[1][1] for e in on_belt]; rev = true)
        @test length(xs) >= 8
        @test all(diff(xs) .< -0.5 + 1e-6)          # at least one product footprint apart
        @test all(e.properties["speed"] == 0.0 for e in on_belt)   # jammed belt: nothing is moving
    end

    @testset "Routing recipes written as hooks never push into a busy machine" begin
        recipes = Dict(
            "round-robin" => "outs = connected_entities(:out_flow)\nn = length(outs)\nlast = attr(self(), :rr_last, 0)\nfor i in 1:n\n    k = mod1(last + i, n)\n    if free_capacity(outs[k]) > 0\n        route_to!(outs[k])\n        set_attr!(self(), :rr_last, k)\n        break\n    end\nend",
            "shortest" => "open = filter(e -> free_capacity(e) > 0, connected_entities(:out_flow))\nif !isempty(open)\n    route_to_shortest!(open)\nend",
            "random" => "open = filter(e -> free_capacity(e) > 0, connected_entities(:out_flow))\nif !isempty(open)\n    route_to!(rand_choice(open))\nend",
            "first open" => "for c in connected_entities(:out_flow)\n    if free_capacity(c) > 0\n        route_to!(c)\n        break\n    end\nend",
            "forced to slow machine" => "route_to!(\"mcA_p\")")
        base = first(filter(s -> s.id == "conv_lab_diverter_open_paths", scenarios))
        for (name, code) in recipes
            spec = deepcopy(base.spec)
            spec["elements"] = [e for e in spec["elements"] if e["kind"] != "chart_station" && endswith(e["id"], "_p")]
            spec["connections"] = [c for c in spec["connections"] if endswith(c["id"], "_p")]
            for e in spec["elements"]
                e["id"] == "belt_p" && (e["properties"]["hooks"] = Dict("on_exit" => code))
            end
            mgr = RuntimeManager()
            ok, diags = stage_and_activate!(mgr, spec)
            @test ok && isempty(diags)
            world = mgr.active_instance.world
            GodotBridge.step!(mgr, 400.0, "s", t -> nothing)
            @test world.stats.blocked_count == 0
            served_a = world.zone_stats[2].total_departures
            @test served_a <= 400 / 8 + 1               # the slow machine never exceeds 1 product per 8 s
            name == "forced to slow machine" || @test world.zone_stats[3].total_departures > served_a
        end
    end

    for sc in scenarios
        @testset "$(sc.title)" begin
            tr = run_lab_trace(sc)
            for (name, ok, detail) in lab_evaluate(sc, tr)
                @test ok
                ok || println("FAILED: ", sc.id, ": ", name, " [", detail, "]")
            end
        end
    end
end
