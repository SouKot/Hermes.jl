"""
    run_report.jl

Simulation Run Reporting, Statistical Audit & Validation Generator.
Extracts empirical performance metrics from a completed or running
simulation instance, audits mathematical invariants (Little's Law, Conservation of Flow),
and formats comprehensive ASCII and CSV summary reports.
"""
module Reporting

using Dates
using SimCore
using SimDES
using ..AnalyticalBenchmarks
import ..GodotBridge: IRSourceNode, IRQueueNode, IRServerNode, IRConveyorNode, IRSinkNode

export SimulationRunSummary, generate_run_summary, format_ascii_report, export_summary_csv

struct StationReport
    id::String
    type::String
    utilization_pct::Float64
    total_completed::Int
    queue_max::Int
    queue_mean::Float64
    mean_wait_sec::Float64
    in_transit::Int
end

struct SimulationRunSummary
    sim_time::Float64
    total_arrivals::Int
    total_departures::Int
    wip_total::Int
    effective_throughput::Float64
    sojourn_mean::Float64
    wait_mean::Float64
    flow_balance_error::Int
    flow_balance_ok::Bool
    littles_law_error_pct::Float64
    littles_law_status::String
    stations::Vector{StationReport}
    timestamp::DateTime
end

"""
    generate_run_summary(instance) -> SimulationRunSummary

Extracts high-fidelity empirical numbers and validation metrics from a SimulationInstance.
"""
function generate_run_summary(instance)::SimulationRunSummary
    world = instance.world
    curr_t = Float64(world.time)
    tot_arr = world.stats.total_arrivals
    tot_dep = world.stats.total_departures
    act_wip = length(world.des_agents)

    sojourn_mean = world.stats.sojourn_time_samples > 0 ? (world.stats.sojourn_time_sum / world.stats.sojourn_time_samples) : 0.0
    wait_mean = world.stats.wait_time_samples > 0 ? (world.stats.wait_time_sum / world.stats.wait_time_samples) : 0.0
    th_eff = curr_t > 0.0 ? (Float64(tot_dep) / curr_t) : 0.0

    flow_err = abs(tot_arr - (tot_dep + act_wip))
    flow_ok = (flow_err == 0)

    # Little's Law
    ll_err_frac, ll_sym = if tot_dep < 15
        (0.0, :warming_up)
    else
        evaluate_littles_law(Float64(act_wip), th_eff, sojourn_mean)
    end
    ll_err = ll_err_frac * 100.0
    ll_stat = string(ll_sym)

    stations = StationReport[]
    ir = instance.execution_ir
    source_map = instance.source_map

    for (elem_id, node) in ir.nodes
        type_str = if node isa IRSourceNode
            "source"
        elseif node isa IRQueueNode
            "queue"
        elseif node isa IRServerNode
            "server"
        elseif node isa IRConveyorNode
            "conveyor"
        elseif node isa IRSinkNode
            "sink"
        else
            string(nameof(typeof(node)))
        end
        util_pct = 0.0
        completed = 0
        q_max = 0
        q_mean = 0.0
        w_sec = 0.0
        in_tr = 0

        if haskey(source_map.by_element, elem_id)
            map_rec = source_map.by_element[elem_id]
            for zid in map_rec.zone_ids
                if haskey(world.zone_stats, zid)
                    z_st = world.zone_stats[zid]
                    completed += z_st.total_departures
                    if z_st.queue_length_samples > 0
                        q_mean = z_st.queue_length_sum / z_st.queue_length_samples
                    end
                    if z_st.wait_time_samples > 0
                        w_sec = z_st.wait_time_sum / z_st.wait_time_samples
                    end
                    if z_st.uptime > 0.0
                        util_pct = (z_st.busy_time / z_st.uptime) * 100.0
                    end
                end
                if haskey(world.zone_states, zid)
                    zs_st = world.zone_states[zid]
                    q_max = max(q_max, zs_st.queue_length)
                    if map_rec.role_in_zone == :conveyor_bed
                        in_tr += zs_st.busy_servers
                    end
                end
            end
        end

        push!(stations, StationReport(
            elem_id,
            type_str,
            round(util_pct, digits=1),
            completed,
            q_max,
            round(q_mean, digits=2),
            round(w_sec, digits=2),
            in_tr
        ))
    end

    return SimulationRunSummary(
        round(curr_t, digits=2),
        tot_arr,
        tot_dep,
        act_wip,
        round(th_eff, digits=3),
        round(sojourn_mean, digits=2),
        round(wait_mean, digits=2),
        flow_err,
        flow_ok,
        round(ll_err, digits=2),
        ll_stat,
        stations,
        now()
    )
end

"""
    format_ascii_report(summary::SimulationRunSummary) -> String

Generates an industrial-grade formatted text summary audit report using pure Base string manipulation.
"""
function format_ascii_report(s::SimulationRunSummary)::String
    io = IOBuffer()
    println(io, "================================================================================")
    println(io, "                     ANTIGRAVITY SIMVIZ - SIMULATION RUN AUDIT REPORT           ")
    println(io, "================================================================================")
    println(io, " Generated at: ", Dates.format(s.timestamp, "yyyy-mm-dd HH:MM:SS"), "          Simulation Time: ", s.sim_time, " s")
    println(io, "--------------------------------------------------------------------------------")
    println(io, " GLOBAL EMPIRICAL OPERATIONAL METRICS:")
    println(io, "   • Total Infeed (Arrivals)     : ", s.total_arrivals, " units")
    println(io, "   • Total Output (Departures)   : ", s.total_departures, " units")
    println(io, "   • Current Work-in-Process (L) : ", s.wip_total, " units")
    println(io, "   • Effective Throughput (λ_eff): ", s.effective_throughput, " parts/sec (", round(s.effective_throughput * 60.0, digits=1), " parts/min)")
    println(io, "   • Mean Cycle / Sojourn (W)    : ", s.sojourn_mean, " sec")
    println(io, "   • Mean Queue Wait Time (W_q)  : ", s.wait_mean, " sec")
    println(io, "--------------------------------------------------------------------------------")
    println(io, " MATHEMATICAL VALIDATION & INVARIANT AUDIT:")
    
    flow_status_str = s.flow_balance_ok ? "PASSED (0 units lost/unaccounted)" : "FAILED ($(s.flow_balance_error) units discrepancy)"
    println(io, "   • Conservation of Flow        : [", s.flow_balance_ok ? "✓" : "✗", "] ", flow_status_str)
    
    ll_symbol = s.littles_law_status == "valid" ? "✓" : (s.littles_law_status == "converging" ? "●" : "⚠")
    println(io, "   • Little's Law Invariant      : [", ll_symbol, "] Status: ", uppercase(s.littles_law_status), " (Error: ", s.littles_law_error_pct, "%)")
    println(io, "     Formula: |L - λW| / L       : |", s.wip_total, " - (", s.effective_throughput, " × ", s.sojourn_mean, ")| / ", max(1, s.wip_total), " = ", s.littles_law_error_pct, "%")
    println(io, "--------------------------------------------------------------------------------")
    println(io, " PER-STATION PERFORMANCE BREAKDOWN:")
    println(io, "  ", rpad("Station ID", 18), " ", rpad("Type", 12), " ", lpad("Util %", 8), " ", lpad("Completed", 10), " ", lpad("Peak Q", 8), " ", lpad("Mean Q", 8), " ", lpad("Wait(s)", 8), " ", lpad("In-Transit", 10))
    println(io, "  ", "-"^88)
    for st in s.stations
        println(io, "  ",
            rpad(st.id, 18), " ",
            rpad(st.type, 12), " ",
            lpad(string(st.utilization_pct, "%"), 8), " ",
            lpad(string(st.total_completed), 10), " ",
            lpad(string(st.queue_max), 8), " ",
            lpad(string(st.queue_mean), 8), " ",
            lpad(string(st.mean_wait_sec), 8), " ",
            lpad(string(st.in_transit), 10)
        )
    end
    println(io, "================================================================================")
    return String(take!(io))
end

"""
    export_summary_csv(summary::SimulationRunSummary) -> String

Exports tidy CSV representation of station metrics.
"""
function export_summary_csv(s::SimulationRunSummary)::String
    io = IOBuffer()
    println(io, "station_id,element_type,utilization_pct,completed,queue_max,queue_mean,mean_wait_sec,in_transit")
    for st in s.stations
        println(io, string(
            st.id, ",",
            st.type, ",",
            st.utilization_pct, ",",
            st.total_completed, ",",
            st.queue_max, ",",
            st.queue_mean, ",",
            st.mean_wait_sec, ",",
            st.in_transit
        ))
    end
    return String(take!(io))
end

end # module Reporting
