# packages/SimOptim/src/SimOptim.jl
#
# Antigravity SimOptim — Simulation-Based Optimization Engine (Phase 7E)
# Supports Parameter Allocation, State-Dependent Policy Search, and Template-Free
# Bilevel Graph + 3D/2D Spatial Coordinate Optimization via SciMLBase.OptimizationProblem.

module SimOptim

include("spec.jl")
include("sciml_bridge.jl")
include("graph_search.jl")

export AbstractDecisionVar,
       ParamDecisionVar,
       PolicyDecisionVar,
       GraphTopologyDecisionVar,
       ConstraintSpec,
       ObjectiveSpec,
       SolverConfig,
       SimOptimizationSpec,
       HallOfFameCandidate,
       HallOfFameArchive,
       parse_optimization_spec,
       optimization_spec_to_dict,
       update_hall_of_fame!,
       hall_of_fame_to_dicts,
       erlang_c_wq,
       encode_initial_vector,
       decode_decision_vector,
       apply_decision_to_scenespec!,
       evaluate_scenespec,
       evaluate_constraints_and_objective,
       OptimizationContext,
       record_evaluation!,
       evaluate_candidate_vector!,
       build_sciml_problem,
       AbstractSimOptimAlg,
       SimOptimBBO,
       SimOptimMixedGA,
       SimOptimPolicySearch,
       SimOptimExhaustive,
       SimOptimNelderMead,
       SimOptimBilevelGraph,
       optim_state_to_dict,
       run_optimization!,
       # Sub-Phase 7E-3: Template-Free Bilevel Graph & 3D/2D Spatial Search
       ConveyorNetworkGraph,
       SpatialNetworkGraph,
       to_simple_digraph,
       from_simple_digraph!,
       extract_conveyor_graph,
       euclidean_dist,
       min_station_separation,
       max_z_elevation_deviation,
       max_port_degree,
       all_stations_reachable,
       is_strongly_connected_loop,
       is_branched_tree,
       has_dead_end_overflow_penalty,
       total_belt_length,
       check_topology_feasibility,
       check_conveyor_constraints,
       optimize_spatial_coordinates!,
       optimize_2d_coordinates!,
       compute_conveyor_network_physics,
       mutate_add_edge!,
       mutate_remove_edge!,
       mutate_rewire_edge!,
       mutate_spur_mode!,
       summarize_conveyor_graph,
       apply_topology_to_scenespec!,
       apply_conveyor_graph_to_scenespec!,
       encode_graph_decision_vector,
       evaluate_conveyor_candidate!,
       solve_bilevel_graph_search!,
       _run_bilevel_graph_search!

end # module SimOptim
