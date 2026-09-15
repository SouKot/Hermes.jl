using Profile
using Dates

const BENCH_SCRIPT = normpath(joinpath(@__DIR__, "..", "experiments", "scripts", "benchmarks", "task24_benchmark_matrix.jl"))
const OUT_DIR = normpath(joinpath(@__DIR__, "..", "experiments", "data", "benchmarks"))
mkpath(OUT_DIR)

function load_task24_helpers!()
    src = read(BENCH_SCRIPT, String)
    src = replace(src, r"\nmain\(\)\s*$" => "\n")
    Base.include_string(Main, src, BENCH_SCRIPT)
    return nothing
end

function profile_case(case_name::String, runner::Function; warmup_runner::Function)
    warmup_runner()
    Profile.clear()
    GC.gc()
    result = @profile runner()

    stamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    flat_path = joinpath(OUT_DIR, "task24_profile_$(case_name)_$(stamp)_flat.txt")
    tree_path = joinpath(OUT_DIR, "task24_profile_$(case_name)_$(stamp)_tree.txt")

    open(flat_path, "w") do io
        println(io, "case=$(case_name)")
        println(io, "captured_at=$(now())")
        println(io, "result=$(repr(result))")
        println(io)
        println(io, "=== PROFILE FLAT (sorted by count) ===")
        Profile.print(io; format=:flat, sortedby=:count, mincount=20)
    end

    open(tree_path, "w") do io
        println(io, "case=$(case_name)")
        println(io, "captured_at=$(now())")
        println(io, "result=$(repr(result))")
        println(io)
        println(io, "=== PROFILE TREE ===")
        Profile.print(io; format=:tree, mincount=20)
    end

    return (result=result, flat_path=flat_path, tree_path=tree_path)
end

load_task24_helpers!()

n_agents = 2000
sim_horizon_s = 120.0
utilization = 0.8
sync_cadence_ratio = 1
seed = 2026

abm = profile_case(
    "abm_only",
    () -> run_abm_only_case(; n_agents=n_agents, sim_horizon_s=sim_horizon_s, seed=seed, quiet=true);
    warmup_runner = () -> run_abm_only_case(; n_agents=n_agents, sim_horizon_s=5.0, seed=seed, quiet=true),
)

hook = profile_case(
    "hook_only",
    () -> run_hybrid_hook_only_case(; n_agents=n_agents, sim_horizon_s=sim_horizon_s, seed=seed, sync_cadence_ratio=sync_cadence_ratio, quiet=true);
    warmup_runner = () -> run_hybrid_hook_only_case(; n_agents=n_agents, sim_horizon_s=5.0, seed=seed, sync_cadence_ratio=sync_cadence_ratio, quiet=true),
)

active = profile_case(
    "active",
    () -> run_hybrid_active_case(; n_agents=n_agents, sim_horizon_s=sim_horizon_s, seed=seed, utilization=utilization, sync_cadence_ratio=sync_cadence_ratio, quiet=true);
    warmup_runner = () -> run_hybrid_active_case(; n_agents=n_agents, sim_horizon_s=5.0, seed=seed, utilization=utilization, sync_cadence_ratio=sync_cadence_ratio, quiet=true),
)

println("ABM flat: ", abm.flat_path)
println("ABM tree: ", abm.tree_path)
println("Hook flat: ", hook.flat_path)
println("Hook tree: ", hook.tree_path)
println("Active flat: ", active.flat_path)
println("Active tree: ", active.tree_path)
