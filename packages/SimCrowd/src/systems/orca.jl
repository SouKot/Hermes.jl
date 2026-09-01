# ── ORCA System (Unified: O(N×k) spatial hash, CPU + GPU, walls + responsibility) ──
#
# This file is the SOLE ORCA implementation for SimCrowd.
# orca_cpu.jl was deleted in Sprint 3K-a. All features are ported here:
#   §1.7: Wall ORCA constraints  (MVector{W} for GPU/kernel compatibility)
#   §1.8: Non-reciprocal responsibility
#   Per-agent neighbor_dist and max_neighbors
#   LP3 profiling (return value from update_orca_system!)
#
# W = max wall segments visible to a single agent (compile-time, set via Val{W}).
# W=16 covers all RiMEA scenarios and typical building geometries.
# The scene construction helper `assert_wall_budget` verifies this spatially.

using Ark
using KernelAbstractions
using StaticArrays
using LinearAlgebra
using CellListMap

# ── Context Struct ─────────────────────────────────────────────────────────────

"""
    ORCAGPUContext

GPU staging context for the ORCA system. Embeds `BaseGPUContext` for the shared
positions/velocities/radii/wall fields (Sprint 3Q-arch). ORCA-specific fields
(v_prefs, lp_radii, taus, time_horizons, responsibilities, etc.) are separate.
"""
struct ORCAGPUContext{F, VCPU<:AbstractVector, SCPU<:AbstractVector, ICPU<:AbstractVector,
                         VGPU<:AbstractVector, SGPU<:AbstractVector, BGPU<:AbstractVector}
    N::Int
    # ── Shared base fields (positions, velocities, radii, walls, rebuild state) ─
    base::BaseGPUContext{F, VCPU, SCPU, VGPU, SGPU, BGPU}
    # ── ORCA-specific CPU staging ─────────────────────────────────────────────
    cpu_forces::VCPU
    cpu_v_prefs::VCPU          # preferred velocity vector (SVector{2}) — direction × scalar
    cpu_lp_radii::SCPU         # LP velocity-disc radius = v_pref scalar (max speed)
    cpu_taus::SCPU
    cpu_masses::SCPU
    cpu_time_horizons::SCPU       # per-agent agent-agent time horizon
    cpu_time_horizons_obst::SCPU  # §1.7: per-agent wall time horizon
    cpu_responsibilities::SCPU    # §1.8: per-agent velocity-change fraction
    cpu_neighbor_dists::SCPU      # per-agent search radius
    cpu_max_neighbors::ICPU       # per-agent neighbor cap (stored as Int32 for device)
    # ── ORCA-specific device buffers ──────────────────────────────────────────
    dev_forces::VGPU
    dev_v_prefs::VGPU
    dev_lp_radii::SGPU         # LP radius = v_pref scalar
    dev_taus::SGPU
    dev_masses::SGPU
    dev_time_horizons::SGPU
    dev_time_horizons_obst::SGPU  # §1.7
    dev_responsibilities::SGPU    # §1.8
    dev_neighbor_dists::SGPU
    dev_max_neighbors::SGPU       # stored as F on device (Int32 not available on all KA backends)
    # ── ORCA-specific sorted device buffers ───────────────────────────────────
    sorted_dev_v_prefs::VGPU
    sorted_dev_lp_radii::SGPU
    sorted_dev_taus::SGPU
    sorted_dev_masses::SGPU
    sorted_dev_time_horizons::SGPU
    sorted_dev_time_horizons_obst::SGPU  # §1.7
    sorted_dev_responsibilities::SGPU    # §1.8
    sorted_dev_neighbor_dists::SGPU
    sorted_dev_max_neighbors::SGPU
    # ── Grid rebuild: last-sorted positions (separate from base.last_build_positions) ─
    sorted_last_positions::VGPU
    max_wall_segs::Int     # allocated capacity (≥ actual n_walls in the scene)
end

function ORCAGPUContext(backend, F, N::Int, max_wall_segs::Int = 64)
    VCPU = Vector{SVector{2,F}}
    SCPU = Vector{F}
    ICPU = Vector{Int32}

    # Shared base (positions, velocities, radii, walls, rebuild tracking)
    base = BaseGPUContext(backend, F, N, max_wall_segs)

    # ORCA-specific CPU staging
    cpu_forces             = VCPU(undef, N)
    cpu_v_prefs            = VCPU(undef, N)
    cpu_lp_radii           = SCPU(undef, N)
    cpu_taus               = SCPU(undef, N)
    cpu_masses             = SCPU(undef, N)
    cpu_time_horizons      = SCPU(undef, N)
    cpu_time_horizons_obst = SCPU(undef, N)
    cpu_responsibilities   = SCPU(undef, N)
    cpu_neighbor_dists     = SCPU(undef, N)
    cpu_max_neighbors      = ICPU(undef, N)

    # ORCA-specific device buffers
    dev_forces             = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_v_prefs            = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    dev_lp_radii           = KernelAbstractions.zeros(backend, F, N)
    dev_taus               = KernelAbstractions.zeros(backend, F, N)
    dev_masses             = KernelAbstractions.zeros(backend, F, N)
    dev_time_horizons      = KernelAbstractions.zeros(backend, F, N)
    dev_time_horizons_obst = KernelAbstractions.zeros(backend, F, N)
    dev_responsibilities   = KernelAbstractions.zeros(backend, F, N)
    dev_neighbor_dists     = KernelAbstractions.zeros(backend, F, N)
    dev_max_neighbors      = KernelAbstractions.zeros(backend, F, N)  # F, not Int — KA-generic

    # ORCA-specific sorted device buffers
    sorted_dev_v_prefs            = KernelAbstractions.zeros(backend, SVector{2,F}, N)
    sorted_dev_lp_radii           = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_taus               = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_masses             = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_time_horizons      = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_time_horizons_obst = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_responsibilities   = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_neighbor_dists     = KernelAbstractions.zeros(backend, F, N)
    sorted_dev_max_neighbors      = KernelAbstractions.zeros(backend, F, N)

    sorted_last_positions = KernelAbstractions.zeros(backend, SVector{2,F}, N)

    VGPU = typeof(base.dev_positions)
    SGPU = typeof(base.dev_radii)
    BGPU = typeof(base.needs_rebuild)

    return ORCAGPUContext{F, VCPU, SCPU, ICPU, VGPU, SGPU, BGPU}(
        N, base,
        cpu_forces, cpu_v_prefs, cpu_lp_radii, cpu_taus, cpu_masses,
        cpu_time_horizons, cpu_time_horizons_obst,
        cpu_responsibilities, cpu_neighbor_dists, cpu_max_neighbors,
        dev_forces, dev_v_prefs, dev_lp_radii, dev_taus, dev_masses,
        dev_time_horizons, dev_time_horizons_obst,
        dev_responsibilities, dev_neighbor_dists, dev_max_neighbors,
        sorted_dev_v_prefs, sorted_dev_lp_radii, sorted_dev_taus, sorted_dev_masses,
        sorted_dev_time_horizons, sorted_dev_time_horizons_obst,
        sorted_dev_responsibilities, sorted_dev_neighbor_dists, sorted_dev_max_neighbors,
        sorted_last_positions, max_wall_segs
    )
end

const ORCA_GPU_CONTEXTS = IdDict{World, ORCAGPUContext}()
const ORCA_GPU_CONTEXTS_LOCK = Base.Threads.SpinLock()

function get_orca_gpu_context(world::World, backend, F, N::Int, max_wall_segs::Int)
    lock(ORCA_GPU_CONTEXTS_LOCK)
    try
        ctx = get(ORCA_GPU_CONTEXTS, world, nothing)
        if ctx === nothing || ctx.N != N || ctx.max_wall_segs < max_wall_segs
            ctx = ORCAGPUContext(backend, F, N, max_wall_segs)
            ORCA_GPU_CONTEXTS[world] = ctx
        end
        return ctx
    finally
        unlock(ORCA_GPU_CONTEXTS_LOCK)
    end
end

# ── Scene Wall Budget Check ────────────────────────────────────────────────────

"""
    assert_wall_budget(walls, agent_start_positions, r_max, W)

Verify at scene construction time that no agent can simultaneously see more than W
wall segments within `r_max + 2m` (the ORCA wall interaction radius).

This is a spatial check — the global wall count alone is not sufficient because
walls spread across a large room may all be within 2.3m of a corner agent.

Arguments:
- `walls`: iterable of `(p1::SVector{2}, p2::SVector{2})` tuples
- `agent_start_positions`: iterable of `SVector{2}` initial positions
- `r_max`: maximum agent radius in the scene (m). Default: 0.4m
- `W`: compile-time MVector bound (must match Val{W} passed to kernel)

Throws `AssertionError` if any start position can see more than W walls.
"""
function assert_wall_budget(walls, agent_start_positions, W::Int; r_max::AbstractFloat = 0.4f0)
    interaction_radius = r_max + 2.0f0  # matches orca_cpu.jl §1.7 cutoff: r_i + 2m
    wall_list = collect(walls)
    max_visible = 0
    for pos in agent_start_positions
        visible = 0
        for (p1, p2) in wall_list
            seg = p2 - p1
            l2  = dot(seg, seg)
            t   = l2 < 1f-10 ? zero(eltype(pos)) : clamp(dot(pos - p1, seg) / l2, zero(eltype(pos)), one(eltype(pos)))
            q   = p1 + t * seg
            dist = norm(q - pos)
            if dist < interaction_radius
                visible += 1
            end
        end
        max_visible = max(max_visible, visible)
    end
    @assert max_visible <= W """
    Wall budget exceeded: an agent start position can see $max_visible wall segments simultaneously.
    W=$W (the MVector bound in compute_orca_kernel!). Either:
      1. Increase W (recompiles kernel — check register budget)
      2. Merge nearby wall segments to reduce local density
      3. Use the pre-pass kernel design for complex urban geometries
    """
end

# ── ORCA GPU Kernel ────────────────────────────────────────────────────────────

"""
    compute_orca_kernel!

One thread per agent. Computes ORCA velocity constraints from:
  §1.7 Wall segments  (MVector{W}: GPU-safe fixed-size, W=16 covers all RiMEA scenarios)
  Agent-agent ORCA    (MVector{K}: K=25 GPU, K=250 CPU)
  §1.8 Responsibility (per-agent fraction of velocity change)
  Per-agent neighbor_dist and max_neighbors

Wall lines prepended to constraint set → LP3 treats them as hard constraints.

Val{K}: compile-time agent-neighbor bound (25 GPU / 250 CPU, set by _update_orca_impl!)
Val{W}: compile-time wall-line bound (16 by default, configurable per scene)
"""
@kernel function compute_orca_kernel!(
    forces,
    @Const(sorted_positions), @Const(sorted_velocities), @Const(sorted_radii),
    @Const(sorted_v_prefs),
    @Const(sorted_lp_radii),       # LP velocity-disc radius = v_pref scalar (max speed)
    @Const(sorted_taus), @Const(sorted_masses),
    @Const(sorted_time_horizons),
    @Const(sorted_time_horizons_obst),   # §1.7: per-agent wall time horizon
    @Const(sorted_responsibilities),      # §1.8: per-agent velocity-change fraction
    @Const(sorted_neighbor_dists),        # per-agent search radius
    @Const(sorted_max_neighbors),         # per-agent cap (stored as F, cast to Int inside)
    @Const(sorted_last_positions),
    # Wall segments — shared read-only across all agents
    @Const(wall_p1s), @Const(wall_p2s), n_walls::Int,
    grid_min, grid_dims, cell_size,
    @Const(cell_starts), @Const(cell_ends), @Const(agent_indices),
    dt,
    ::Val{K},   # compile-time: max agent-agent neighbors
    ::Val{W},   # compile-time: max wall segments visible per agent
    ::Val{WE},  # compile-time: max wall ORCA lines (≤ 3×W: segment + up to 2 endpoints)
) where {K, W, WE}
    i = @index(Global, Linear)

    @inbounds begin
        original_i = agent_indices[i]

        pos_i      = sorted_positions[i]
        vel_i      = sorted_velocities[i]
        r_i        = sorted_radii[i]
        old_pos_i  = sorted_last_positions[i]
        v_pref_i      = sorted_v_prefs[i]       # preferred velocity vector
        lp_radius_i   = sorted_lp_radii[i]       # max speed = LP disc radius
        tau_i         = sorted_taus[i]
        mass_i     = sorted_masses[i]
        time_h_i   = sorted_time_horizons[i]
        time_h_obst_i = sorted_time_horizons_obst[i]  # §1.7
        resp_i     = sorted_responsibilities[i]        # §1.8
        nb_dist_i  = sorted_neighbor_dists[i]
        max_nb_i   = Int(sorted_max_neighbors[i])

        nb_dist_sq_i = nb_dist_i * nb_dist_i

        # ── §1.7: Wall ORCA lines (MVector: GPU-safe, no heap allocation) ─────────
        # Wall lines are PREPENDED so LP3 treats them as hard constraints
        # (wall cannot be passed through, unlike agent-agent constraints).
        # WE = 3×W: each segment emits ≤ 3 lines (segment + 2 endpoints).
        # See van den Berg 2011 §3.2 and compute_orca_line_endpoint in orca_math.jl.
        wall_lines     = MVector{WE, Line{typeof(r_i)}}(undef)
        num_wall_lines = 0
        interaction_r  = r_i + typeof(r_i)(2)   # 2m slack (same for segment + endpoints)

        for w in 1:n_walls
            p1 = wall_p1s[w]
            p2 = wall_p2s[w]
            seg = p2 - p1
            l2  = dot(seg, seg)
            t   = l2 < typeof(r_i)(1e-10) ? zero(typeof(r_i)) :
                  clamp(dot(pos_i - p1, seg) / l2, zero(typeof(r_i)), one(typeof(r_i)))
            q   = p1 + t * seg
            dist_to_wall = norm(q - pos_i)
            # Interaction radius: agent radius + 2m slack
            if dist_to_wall < interaction_r && num_wall_lines < WE
                num_wall_lines += 1
                wall_lines[num_wall_lines] = compute_orca_line_wall(
                    pos_i, vel_i, r_i, p1, p2, time_h_obst_i, dt)

                # §3P: endpoint vertex constraints (van den Berg 2011 §3.2)
                # Each exposed wall endpoint generates a separate point-obstacle VO.
                # This prevents agents from arcing through door corners when the
                # FMM preferred velocity is diagonal toward the corner.
                for qe in (p1, p2)
                    dist_ep = norm(qe - pos_i)
                    if dist_ep > typeof(r_i)(1e-6) && dist_ep < interaction_r && num_wall_lines < WE
                        num_wall_lines += 1
                        wall_lines[num_wall_lines] = compute_orca_line_endpoint(
                            pos_i, vel_i, r_i, qe, time_h_obst_i, dt)
                    end
                end
            end
        end

        # ── Agent-agent neighbor search (O(k) via SortedNeighborIterator) ─────────
        idx  = floor.(Int, (old_pos_i - grid_min) / cell_size)
        iter = SortedNeighborIterator(grid_min, grid_dims, cell_size, cell_starts, cell_ends, idx)

        best_d2    = MVector{K, typeof(r_i)}(undef)
        best_nb_idx = MVector{K, Int}(undef)
        best_count = 0

        for neighbor_idx in iter
            if neighbor_idx != i
                pos_j = sorted_positions[neighbor_idx]
                r_j   = sorted_radii[neighbor_idx]
                d2    = sum(abs2.(pos_i - pos_j))
                if d2 <= nb_dist_sq_i
                    if best_count < K
                        best_count += 1
                        best_d2[best_count]     = d2
                        best_nb_idx[best_count] = neighbor_idx
                        # Insertion sort: keep ascending by d2
                        c = best_count
                        while c > 1 && best_d2[c] < best_d2[c-1]
                            best_d2[c],     best_d2[c-1]     = best_d2[c-1],     best_d2[c]
                            best_nb_idx[c], best_nb_idx[c-1] = best_nb_idx[c-1], best_nb_idx[c]
                            c -= 1
                        end
                    elseif d2 < best_d2[K]
                        best_d2[K]     = d2
                        best_nb_idx[K] = neighbor_idx
                        c = K
                        while c > 1 && best_d2[c] < best_d2[c-1]
                            best_d2[c],     best_d2[c-1]     = best_d2[c-1],     best_d2[c]
                            best_nb_idx[c], best_nb_idx[c-1] = best_nb_idx[c-1], best_nb_idx[c]
                            c -= 1
                        end
                    end
                end
            end
        end

        # Per-agent max_neighbors cap (runtime clamp — MVector still sized at K)
        K_eff = min(best_count, max_nb_i)

        # ── Build combined constraint set: [wall lines | agent lines] ─────────────
        # Size: WE wall lines + K agent lines. Both bounds are compile-time → isbits.
        lines    = MVector{K + WE, Line{typeof(r_i)}}(undef)
        num_lines = 0

        # 1. Wall lines first (hard constraints in LP3)
        for w in 1:num_wall_lines
            num_lines += 1
            lines[num_lines] = wall_lines[w]
        end

        # 2. Agent-agent ORCA lines (soft constraints in LP3)
        for k in 1:K_eff
            n_idx = best_nb_idx[k]
            pos_j = sorted_positions[n_idx]
            vel_j = sorted_velocities[n_idx]
            r_j   = sorted_radii[n_idx]
            # §1.8: resp_i controls velocity-change fraction (0.5 = reciprocal, 1.0 = full)
            num_lines += 1
            lines[num_lines] = compute_orca_line(
                pos_i, vel_i, r_i, pos_j, vel_j, r_j, time_h_i, dt, resp_i)
        end

        # ── LP2 + LP3 ─────────────────────────────────────────────────────────────
        fail_line, v_opt = linear_program_2_len(
            lines, num_lines, lp_radius_i, v_pref_i, false, v_pref_i)

        if fail_line > 0
            # §1.7: num_wall_lines = hard-constraint boundary (walls non-relaxable)
            # LP3 only relaxes lines[num_wall_lines+1 .. num_lines]
            v_opt = linear_program_3_static(
                lines, num_lines, num_wall_lines, fail_line, lp_radius_i, v_opt)
        end

        # Safety net for floating-point edge cases
        if isnan(v_opt[1]) || isnan(v_opt[2]) || isinf(v_opt[1]) || isinf(v_opt[2])
            v_opt = zero(SVector{2, typeof(r_i)})
        end

        # Convert optimal velocity to steering force.
        # CRITICAL: use dt (not τ) here.
        # integrate_physics_system! applies: v_new = v_old + F/mass × dt
        # → v_new = v_old + (mass*(v_opt-v_old)/dt)/mass × dt = v_opt  ✓
        # Using τ instead gives: v_new = v_old + (v_opt-v_old)*dt/τ ≠ v_opt when τ≠dt,
        # which breaks ORCA's collision-free guarantee (agents can no longer snap to v_opt).
        # τ controls goal-seeking relaxation (physics.jl) — not the ORCA velocity step.
        F_orca = mass_i * (v_opt - vel_i) / dt
        forces[original_i] = F_orca
    end
end

# ── ECS Data Extraction + Dispatch ────────────────────────────────────────────

"""
    update_orca_system!(world, search, backend, dt; W=16) → lp3_count::Int

Update ORCA velocities for all agents with `ORCAParams`.
Returns the number of LP3 fallback invocations this step (profiling: high values
indicate crowd density is exceeding ORCA's guaranteed-feasibility threshold).

`W`: max wall segments per agent (compile-time kernel parameter). Must match
the scene geometry. Use `assert_wall_budget` at scene construction to verify.
"""
function update_orca_system!(world::World, search::AbstractNeighborSearch, backend::Backend,
                              dt::AbstractFloat; W::Int = 16, WE::Int = 3*W)
    num_agents = count_entities(Query(world, (ORCAParams{Float32},)))
    if num_agents == 0
        return 0
    end

    F = typeof(search.cell_size)
    ctx = get_orca_gpu_context(world, backend, F, num_agents, 64)

    positions          = ctx.base.cpu_positions
    velocities         = ctx.base.cpu_velocities
    radii              = ctx.base.cpu_radii
    v_prefs            = ctx.cpu_v_prefs
    lp_radii           = ctx.cpu_lp_radii
    taus               = ctx.cpu_taus
    masses             = ctx.cpu_masses
    time_horizons      = ctx.cpu_time_horizons
    time_horizons_obst = ctx.cpu_time_horizons_obst
    responsibilities   = ctx.cpu_responsibilities
    neighbor_dists     = ctx.cpu_neighbor_dists
    max_neighbors      = ctx.cpu_max_neighbors

    idx = 1
    for (entities, pos_col, vel_col, params_col, goal_col) in
            Query(world, (Position{F}, Velocity{F}, ORCAParams{F}, Goal{F}))
        for i in eachindex(pos_col)
            p   = params_col[i]
            positions[idx]          = pos_col[i].p
            velocities[idx]         = vel_col[i].v
            radii[idx]              = p.radius
            taus[idx]               = p.τ
            masses[idx]             = p.mass
            time_horizons[idx]      = p.time_horizon
            time_horizons_obst[idx] = p.time_horizon_obst   # §1.7
            responsibilities[idx]   = p.responsibility       # §1.8
            neighbor_dists[idx]     = p.neighbor_dist
            max_neighbors[idx]      = Int32(p.max_neighbors)

            dir  = goal_col[i].g - pos_col[i].p
            dist = norm(dir)
            v_prefs[idx]            = dist > F(1e-3) ? (dir / dist) * p.v_pref : zero(SVector{2,F})
            lp_radii[idx]           = p.v_pref   # LP radius = max speed scalar

            idx += 1
        end
    end

    # Extract wall segments (static per scene — could be cached, but small cost)
    n_walls = 0
    for (_, wall_col) in Query(world, (WallSegment{F},))
        for i in eachindex(wall_col)
            n_walls += 1
            ctx.base.cpu_wall_p1s[n_walls] = wall_col[i].p1
            ctx.base.cpu_wall_p2s[n_walls] = wall_col[i].p2
        end
    end
    # n_walls == 0 is fine (no wall constraints generated)

    return _update_orca_impl!(world, search, positions, velocities, radii, v_prefs,
                               lp_radii, taus, masses, time_horizons, time_horizons_obst,
                               responsibilities, neighbor_dists, max_neighbors,
                               n_walls, F(dt), backend, ctx, Val(W), Val(WE))
end

# ── Core Implementation ────────────────────────────────────────────────────────
# Note: check_rebuild_kernel! and reorder_array_kernel! are defined in social.jl
# and shared across the SimCrowd module — do not redefine them here.

function _update_orca_impl!(
    world::World, search::RadixSpatialHash{AT,F},
    positions, velocities, radii, v_prefs, lp_radii,
    taus, masses, time_horizons, time_horizons_obst,
    responsibilities, neighbor_dists, max_neighbors,
    n_walls::Int, dt::F, backend, ctx::ORCAGPUContext,
    ::Val{W}, ::Val{WE}
) where {AT, F, W, WE}
    N = length(positions)

    # Upload per-agent data to device
    # 1. Shared base fields (positions, velocities, radii, walls) → stage_and_sort_base!
    #    stage_and_sort_base! also handles the lazy grid rebuild (build_grid! before reorder!)
    stage_and_sort_base!(ctx.base, positions, velocities, radii,
                         ctx.base.cpu_wall_p1s, ctx.base.cpu_wall_p2s, n_walls,
                         search, backend, ctx.sorted_last_positions)

    # 2. ORCA-specific fields
    copyto!(ctx.dev_v_prefs,            v_prefs)
    copyto!(ctx.dev_lp_radii,           lp_radii)
    copyto!(ctx.dev_taus,               taus)
    copyto!(ctx.dev_masses,             masses)
    copyto!(ctx.dev_time_horizons,      time_horizons)
    copyto!(ctx.dev_time_horizons_obst, time_horizons_obst)
    copyto!(ctx.dev_responsibilities,   responsibilities)
    copyto!(ctx.dev_neighbor_dists,     neighbor_dists)
    # max_neighbors: Int32 → F for device (KA-generic; cast back to Int inside kernel)
    for i in 1:N
        ctx.dev_max_neighbors[i] = F(max_neighbors[i])
    end

    # 3. Reorder ORCA-specific arrays (base arrays + rebuild handled by stage_and_sort_base!)
    kernel_reorder! = reorder_array_kernel!(backend)
    kernel_reorder!(ctx.sorted_dev_v_prefs,            ctx.dev_v_prefs,            search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_lp_radii,           ctx.dev_lp_radii,           search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_taus,               ctx.dev_taus,               search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_masses,             ctx.dev_masses,             search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_time_horizons,      ctx.dev_time_horizons,      search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_time_horizons_obst, ctx.dev_time_horizons_obst, search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_responsibilities,   ctx.dev_responsibilities,   search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_neighbor_dists,     ctx.dev_neighbor_dists,     search.agent_indices, ndrange=N)
    kernel_reorder!(ctx.sorted_dev_max_neighbors,      ctx.dev_max_neighbors,      search.agent_indices, ndrange=N)

    # K: compile-time agent-neighbor bound. 250 on CPU (handles large search radii),
    # 25 on GPU (register budget). Matches original orca.jl convention.
    K = backend isa CPU ? 250 : 25

    kernel! = compute_orca_kernel!(backend)
    kernel!(
        ctx.dev_forces,
        ctx.base.sorted_dev_positions, ctx.base.sorted_dev_velocities, ctx.base.sorted_dev_radii,
        ctx.sorted_dev_v_prefs, ctx.sorted_dev_lp_radii, ctx.sorted_dev_taus, ctx.sorted_dev_masses,
        ctx.sorted_dev_time_horizons,
        ctx.sorted_dev_time_horizons_obst,   # §1.7
        ctx.sorted_dev_responsibilities,      # §1.8
        ctx.sorted_dev_neighbor_dists,
        ctx.sorted_dev_max_neighbors,
        ctx.sorted_last_positions,
        ctx.base.dev_wall_p1s, ctx.base.dev_wall_p2s, n_walls,
        search.grid_min, search.grid_dims, search.cell_size,
        search.cell_starts, search.cell_ends, search.agent_indices,
        dt,
        Val(K),
        Val(W),
        Val(WE),   # §3P: total wall-line budget = 3×W (segment + 2 endpoints)
        ndrange=N
    )
    KernelAbstractions.synchronize(backend)

    cpu_forces = ctx.cpu_forces
    copyto!(cpu_forces, ctx.dev_forces)

    # Write forces back to ECS
    idx = 1
    for (entities, pos_col, vel_col, params_col, goal_col, force_col) in
            Query(world, (Position{F}, Velocity{F}, ORCAParams{F}, Goal{F}, Force{F}))
        for i in eachindex(force_col)
            force_col[i] = Force(cpu_forces[idx])  # ORCA sets, not accumulates
            idx += 1
        end
    end

    # LP3 profiling: not yet tracked in the GPU kernel path (requires GPU atomic or
    # separate readback pass). Returns 0 for API compatibility with orca_cpu.jl callers.
    # TODO: add LP3 atomic counter in a future sprint if profiling is needed.
    return 0
end
