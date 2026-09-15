using Dates
using Printf

const BENCH_SCRIPT = normpath(joinpath(@__DIR__, "..", "experiments", "scripts", "benchmarks", "task24_benchmark_matrix.jl"))

function load_task24_helpers!()
    src = read(BENCH_SCRIPT, String)
    src = replace(src, r"\nmain\(\)\s*$" => "\n")
    Base.include_string(Main, src, BENCH_SCRIPT)
    return nothing
end

function sorted_timing_pairs(dict)
    pairs_vec = collect(pairs(dict))
    sort!(pairs_vec; by = pair -> last(pair), rev = true)
    return pairs_vec
end

function print_timing_breakdown(title::String, elapsed_s::Float64, timing)
    println()
    println(title)
    println("total_elapsed_s = ", round(elapsed_s, digits=6))
    for (key, value) in sorted_timing_pairs(timing)
        pct = elapsed_s > 0 ? 100 * value / elapsed_s : NaN
        @printf("  %-28s %10.6f s   (%6.2f%%)\n", String(key), value, pct)
    end
end

load_task24_helpers!()

n_agents = 2000
sim_horizon_s = 120.0
utilization = 0.8
sync_cadence_ratio = 1
seed = 2026

run_abm_only_case(; n_agents=n_agents, sim_horizon_s=5.0, seed=seed, quiet=true)
run_hybrid_hook_only_case(; n_agents=n_agents, sim_horizon_s=5.0, seed=seed, sync_cadence_ratio=sync_cadence_ratio, quiet=true)
run_hybrid_active_case(; n_agents=n_agents, sim_horizon_s=5.0, seed=seed, utilization=utilization, sync_cadence_ratio=sync_cadence_ratio, quiet=true)

hook_timing = Dict{Symbol,Float64}()
active_timing = Dict{Symbol,Float64}()

abm = run_abm_only_case(; n_agents=n_agents, sim_horizon_s=sim_horizon_s, seed=seed, quiet=true)
hook = run_hybrid_hook_only_case(; n_agents=n_agents, sim_horizon_s=sim_horizon_s, seed=seed, sync_cadence_ratio=sync_cadence_ratio, quiet=true, timing=hook_timing)
active = run_hybrid_active_case(; n_agents=n_agents, sim_horizon_s=sim_horizon_s, seed=seed, utilization=utilization, sync_cadence_ratio=sync_cadence_ratio, quiet=true, timing=active_timing)

println("Task24 timed breakdown run")
println("captured_at = ", now())
println("n_agents = ", n_agents)
println("utilization = ", utilization)
println("sync_cadence_ratio = ", sync_cadence_ratio)
println("abm_elapsed_s = ", abm["elapsed_s"])
println("hook_elapsed_s = ", hook["elapsed_s"])
println("active_elapsed_s = ", active["elapsed_s"])
println("hook_vs_abm = ", hook["elapsed_s"] / abm["elapsed_s"])
println("active_vs_abm = ", active["elapsed_s"] / abm["elapsed_s"])
println("active_vs_hook = ", active["elapsed_s"] / hook["elapsed_s"])
println("active_sync_step_timed_s = ", get(active_timing, :active_sync_step_s, NaN))

print_timing_breakdown("Hook-only timing breakdown", hook["elapsed_s"], hook_timing)
print_timing_breakdown("Active timing breakdown", active["elapsed_s"], active_timing)

hook_hybrid = get(hook_timing, :hybrid_slot_map_s, 0.0) +
              get(hook_timing, :hybrid_prefreeze_scan_s, 0.0) +
              get(hook_timing, :hybrid_frozen_restore_s, 0.0) +
              get(hook_timing, :hybrid_zone_scan_s, 0.0) +
              get(hook_timing, :hook_sync_step_s, 0.0)

active_hybrid = get(active_timing, :hybrid_slot_map_s, 0.0) +
                get(active_timing, :hybrid_prefreeze_scan_s, 0.0) +
                get(active_timing, :hybrid_frozen_restore_s, 0.0) +
                get(active_timing, :hybrid_zone_scan_s, 0.0) +
                get(active_timing, :active_sync_step_s, 0.0)

println()
println("Derived summary")
@printf("  hook_increment_vs_abm     %.6f s\n", hook["elapsed_s"] - abm["elapsed_s"])
@printf("  active_increment_vs_abm   %.6f s\n", active["elapsed_s"] - abm["elapsed_s"])
@printf("  active_increment_vs_hook  %.6f s\n", active["elapsed_s"] - hook["elapsed_s"])
@printf("  hook_hybrid_timed_sum     %.6f s\n", hook_hybrid)
@printf("  active_hybrid_timed_sum   %.6f s\n", active_hybrid)
@printf("  active_des_until_s        %.6f s\n", get(active_timing, :active_des_until_s, 0.0) + get(active_timing, :active_final_des_drain_s, 0.0))
