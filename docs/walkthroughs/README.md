# Antigravity ABM Platform: Project Walkthroughs Archive

This directory contains the historical and current walkthroughs documenting the engineering progress, mathematical algorithms, performance benchmarks, and validation results across the development phases of the Hermes / SimViz / SimCrowd platform.

---

## Walkthrough Directory & Chronology

| Phase / Sprint | Document | Primary Focus & Milestones |
| :--- | :--- | :--- |
| **Phase 3A** | [`phase_03a_simcrowd_sfm_cpu.md`](./phase_03a_simcrowd_sfm_cpu.md) | CPU baseline for Social Force Model (Helbing & Molnár), Radix Sort + CSR spatial hash, Fast Marching navigation. |
| **Phase 3B** | [`phase_03b_gpu_acceleration.md`](./phase_03b_gpu_acceleration.md) | GPU acceleration with KernelAbstractions / CUDA, contiguous device buffer management, 10k+ agent force pipeline. |
| **Phase 3C (1)** | [`phase_03c_validation_summary.md`](./phase_03c_validation_summary.md) | Initial validation summary comparing CPU and GPU simulation dynamics. |
| **Phase 3C (2)** | [`phase_03c_quantitative_validation.md`](./phase_03c_quantitative_validation.md) | Numerical validation against theoretical limits: relaxation time, terminal speed, Coulomb friction, force balance. |
| **Phase 3C (3)** | [`phase_03c_empirical_validation.md`](./phase_03c_empirical_validation.md) | Empirical validation: fundamental diagrams (Weidmann), corridor flow, bottleneck throughput, lane formation. |
| **Phase 3C (4)** | [`phase_03c_physics_refinements.md`](./phase_03c_physics_refinements.md) | Sub-stepping integration, elimination of artificial jamming, isotropic wall repulsion fixes. |
| **Phase 5** | [`phase_05_orca_integration.md`](./phase_05_orca_integration.md) | Optimal Reciprocal Collision Avoidance (ORCA) 2D linear programming solver, static obstacle avoidance. |
| **Phase 6** | [`phase_06_simcrowd_bugfixes_parallelization.md`](./phase_06_simcrowd_bugfixes_parallelization.md) | Resolution of 6 mathematical force bugs, Tier 1 unit tests (22/22 pass), multi-threading benchmarks. |
| **Phases 6–8** | [`phase_06_08_simcrowd_full_development.md`](./phase_06_08_simcrowd_full_development.md) | Consolidated development report across Phases 6 through 8: bug fixes, circle-crossing tests, ORCA radius tuning. |
| **Tier 3** | [`phase_tier3_cross_library_validation.md`](./phase_tier3_cross_library_validation.md) | Cross-library benchmarks against JuPedSim, Menge, and RVO2 (flow rates, evacuation times, separation distances). |
| **Sprint 8C** | [`sprint_08c_session_handoff.md`](./sprint_08c_session_handoff.md) | Hybrid ECS architecture, DES queue-to-crowd agent spawning, session state persistence. |
| **Theory Manual** | [`theory_manual_walkthrough.md`](./theory_manual_walkthrough.md) | Synthesis of the 11 theoretical documentation chapters in `docs/theory_manual/`. |
| **Sprint 3N-b** | [`sprint_03n_b_navigation_field.md`](./sprint_03n_b_navigation_field.md) | Fast Marching Method (FMM) Eikonal distance field solver with obstacle boundary condition caching. |
| **Sprint 3Q–3S**| [`sprint_03q_3s_gpu_infrastructure.md`](./sprint_03q_3s_gpu_infrastructure.md) | Unified `BaseGPUContext`, wall-penetration correction sharing, CSM & Hybrid FSM GPU kernel dispatches. |
| **Sprint 3T** | [`sprint_03t_jacobi_correction.md`](./sprint_03t_jacobi_correction.md) | Model-agnostic Jacobi geometric non-penetration correction enforcing hard separation for all models. |
| **Sprint 3V** | [`sprint_03v_xpbd_implementation.md`](./sprint_03v_xpbd_implementation.md) | Extended Position-Based Dynamics (XPBD) compliance solver eliminating bottleneck overlap oscillations. |
| **Phase 7D** | [`phase_07d_scenespec_authoring_core.md`](./phase_07d_scenespec_authoring_core.md) | **Current**: SceneSpec authoring core, contracts, typed models, semantic validation, extensions, and hierarchical subgraph expansion. |

