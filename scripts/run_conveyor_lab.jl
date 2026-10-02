#!/usr/bin/env julia
# Regenerates the Godot Examples-menu scenes and runs the Conveyor Physics Lab, writing
# SVG charts, CSV data and HTML reports to reports/conveyor_lab/.
#
#   julia --project=packages/SimOptim scripts/run_conveyor_lab.jl

using GodotBridge

const ROOT = normpath(joinpath(@__DIR__, ".."))
export_conveyor_lab_specs(joinpath(ROOT, "godot", "examples", "conveyor_lab"))
results = run_conveyor_lab(conveyor_lab_scenarios(), joinpath(ROOT, "reports", "conveyor_lab"))

failed = 0
for (id, checks) in sort!(collect(results); by = first)
    println("== ", id)
    for (name, ok, detail) in checks
        println("  ", ok ? "PASS" : "FAIL", "  ", name, "  [", detail, "]")
        global failed += ok ? 0 : 1
    end
end
println("\nReport: ", joinpath(ROOT, "reports", "conveyor_lab", "index.html"))
exit(failed == 0 ? 0 : 1)
