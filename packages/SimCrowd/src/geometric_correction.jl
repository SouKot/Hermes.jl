# geometric_correction.jl — Model-agnostic geometric non-penetration correction
#
# Sprint 3T (2026-09-01)
#
# Implements Jacobi position-based constraint enforcement for agent-agent pairs.
# Extends the existing `apply_wall_penetration_correction` (orca_math.jl) to
# agent-agent pairs using the identical constraint projection structure.
#
# ## Scientific basis
#
# Position-Based Dynamics (Müller et al. 2007). Used by:
#   - JuPedSim: "geometric update" post-step (Tordeux et al. 2016 §3.2)
#   - Menge:    proximity post-step §3.3 (Curtis & Manocha 2016)
#   - Vadere:   StepDisplacementCorrector §4.3
#   - UMANS:    correction pass after all velocity models §4 (Van Toll 2022)
#
# ## Why Jacobi (not Gauss-Seidel or direct)
#
# Each thread i reads neighbour positions (read-only snapshot) and accumulates
# Δp[i] into thread-local storage ONLY. No thread writes to another thread's slot.
# This makes it fully parallel with Threads.@threads (CPU) and one thread-per-agent
# GPU kernels — identical pattern to compute_orca_kernel! and compute_csm_kernel!.
#
# Gauss-Seidel would converge in fewer iterations but creates write races (thread i
# writes both pos_i and pos_j). Direct solvers (MUMPS) are inapplicable: the
# constraint is an LCP (inequality), the active contact set changes every dt, and
# the sparsity pattern refactors per step — see docs/2026-08-14_future_directions.md §7
# for a full analysis. PGS+graph-colouring is the recommended upgrade path if N>50k.
#
# ## n_iters recommendation
#
# n_iters=1: sufficient at normal densities (overlap < 5% of radius).
# n_iters=2: handles severe bottlenecks (15 agents, 0.244m gap vs 0.40m min).
# n_iters=3: extreme crush scenarios.
# Default: 2, configurable via SimConfig.agent_correction_iters.
#
# ## ORCA-only scenes
#
# Pure ORCA relies on the LP velocity solve to prevent penetration (Berg et al. 2011).
# At low-to-medium density (ρ < 3.5 ped/m²), this is sufficient.
# At extreme density (ρ ≥ 3.5 ped/m², τ_h → 0), the LP feasible region may be empty
# causing ORCA to fall back to the least-bad velocity — which CAN produce overlap.
# The SimConfig.agent_correction_iters field defaults to 0 for pure ORCA scenes.
# Enable by setting SimConfig(dt=..., agent_correction_iters=2).
#
# For agent-agent correction, see `apply_wall_penetration_correction` (orca_math.jl)
# for the wall-correction counterpart.

using StaticArrays
using LinearAlgebra
using KernelAbstractions

# ── §3T-a: Per-pair correction primitives ───────────────────────────────────

"""
    apply_agent_pair_correction(pos_i, vel_i, r_i, pos_j, r_j)
        → (Δpos_i::SVector{2,F}, Δvel_i::SVector{2,F})

Compute the Jacobi correction contribution to agent i from an overlapping
neighbour j. Returns `(Δpos_i, Δvel_i)` to be **accumulated** by the caller.
Agent j's correction is symmetric and handled when j's thread/kernel runs.

## Physics

Given overlap δ = (r_i + r_j) - ‖pos_i - pos_j‖ > 0 and separation unit normal n̂:

    Δpos_i = (δ / 2) × n̂         (push i outward by half the overlap)
    Δvel_i += v_into × n̂          (zero the inward velocity component to prevent
                                    re-penetration on the next step)

The symmetry guarantees momentum conservation in the Jacobi limit.

## Properties

- **GPU-safe**: `@inline`, no heap allocation, all inputs/outputs are `isbits`
  (`SVector{2,F}` and `F`). Callable from any KernelAbstractions kernel.
- **Idempotent accumulation**: if called twice for the same pair, the accumulated
  Δpos doubles; this is correct Jacobi behaviour (2 iters = 2× application).
- **Zero-correction guard**: returns `(zero, zero)` when d ≥ r_i + r_j (no overlap)
  or d < 1e-6 (degenerate coincident agents — pushes along +x to break symmetry).

## Relation to wall correction

`apply_wall_penetration_correction` (orca_math.jl) applies the same position + velocity
projection for a single (agent, wall) pair. This function is the agent-agent counterpart.
"""
@inline function apply_agent_pair_correction(
    pos_i::SVector{2,F},
    vel_i::SVector{2,F},
    r_i::F,
    pos_j::SVector{2,F},
    r_j::F
) :: Tuple{SVector{2,F}, SVector{2,F}} where {F<:AbstractFloat}
    rel     = pos_i - pos_j
    d       = norm(rel)
    r_sum   = r_i + r_j
    d >= r_sum && return zero(SVector{2,F}), zero(SVector{2,F})

    # Degenerate: coincident agents — push along +x to break symmetry
    n_hat = d < F(1e-6) ? SVector{2,F}(one(F), zero(F)) : rel / d

    # Position correction: push i outward by half the overlap
    delta    = r_sum - d
    dpos = (delta / 2) * n_hat

    # Velocity correction: cancel inward component to prevent re-penetration
    v_into = dot(vel_i, -n_hat)    # positive = agent moving INTO j
    dvel   = v_into > zero(F) ? v_into * n_hat : zero(SVector{2,F})

    return dpos, dvel
end

"""
    apply_xpbd_pair_correction(pos_i, vel_i, r_i, pos_j, r_j, λ_i, α_tilde)
        → (Δpos_i::SVector{2,F}, Δvel_i::SVector{2,F}, Δλ::F)

XPBD correction contribution to agent i from overlapping neighbour j.
Incorporates the accumulated Lagrange multiplier `λ_i` which grows across
iterations (reset to 0 at timestep start), self-limiting over-correction.

## Update rule

    C = dᵢⱼ − (rᵢ + rⱼ)           # constraint value: negative = violated
    w = 1/mᵢ + 1/mⱼ = 2             # equal unit mass
    Δλ = max(0, (−C − α̃·λᵢ) / (w + α̃))
    Δposᵢ = n̂ · Δλ                  # (1/mᵢ) · n̂ · Δλ, m=1

α̃ = α / dt² = 0 recovers exact Jacobi (`apply_agent_pair_correction`).
As λᵢ grows across iterations, subsequent corrections diminish — preventing
Jacobi oscillation in dense contact graphs.

## GPU-safety

`@inline`, no allocation, all inputs/outputs are `isbits`. Callable from KA kernels.
"""
@inline function apply_xpbd_pair_correction(
    pos_i    :: SVector{2,F},
    vel_i    :: SVector{2,F},
    r_i      :: F,
    pos_j    :: SVector{2,F},
    r_j      :: F,
    λ_i      :: F,
    α_tilde  :: F
) :: Tuple{SVector{2,F}, SVector{2,F}, F} where {F<:AbstractFloat}
    rel   = pos_i - pos_j
    d     = norm(rel)
    r_sum = r_i + r_j
    if d >= r_sum
        return zero(SVector{2,F}), zero(SVector{2,F}), zero(F)
    end

    n_hat = d < F(1e-6) ? SVector{2,F}(one(F), zero(F)) : rel / d

    # XPBD constraint: C = d - r_sum (negative when violated)
    C   = d - r_sum
    w   = F(2)   # 1/m_i + 1/m_j, equal unit mass
    Δλ  = max(zero(F), (-C - α_tilde * λ_i) / (w + α_tilde))

    dpos = n_hat * Δλ   # (1/m_i) · n̂ · Δλ

    # Velocity correction: same as Jacobi (cancel inward component)
    v_into = dot(vel_i, -n_hat)
    dvel   = v_into > zero(F) ? v_into * n_hat : zero(SVector{2,F})

    return dpos, dvel, Δλ
end

# ── §3T-b: CPU correction — model-agnostic ECS loop (Sprint 3T/3V) ─────────────

"""
    apply_agent_correction_cpu!(world, search::CPUNeighborSearch, ::Type{F};
                                n_iters=8, tol=1f-3,
                                alg::AbstractCorrectionAlgorithm=JacobiCorrection())

Agent non-penetration correction via CellListMap pairwise! (O(N×k) per iter).
Dispatches on `alg`: `JacobiCorrection` (default, Sprint 3T) or `XPBDCorrection(α)` (Sprint 3V).
"""
function apply_agent_correction_cpu!(
    world   :: World,
    search  :: CPUNeighborSearch,
    ::Type{F};
    n_iters :: Int = 8,
    tol     :: F   = F(1e-3),
    alg     :: AbstractCorrectionAlgorithm = JacobiCorrection()
) where {F<:AbstractFloat}
    n_iters == 0 && return

    pos_arr  = SVector{2,F}[]
    vel_arr  = SVector{2,F}[]
    rad_arr  = F[]
    for (_, pos_col, vel_col, geo_col) in Query(world, (Position{F}, Velocity{F}, AgentGeometry{F}))
        for i in eachindex(pos_col)
            push!(pos_arr, pos_col[i].p)
            push!(vel_arr, vel_col[i].v)
            push!(rad_arr, geo_col[i].social_radius)
        end
    end
    N = length(pos_arr)
    N == 0 && return

    build_grid!(search, pos_arr, CPU())

    acc_pos       = [zero(SVector{2,F}) for _ in 1:N]
    acc_vel       = [zero(SVector{2,F}) for _ in 1:N]
    lk            = [Base.Threads.SpinLock() for _ in 1:N]
    atomic_max_ov = Threads.Atomic{F}(zero(F))

    use_xpbd = alg isa XPBDCorrection
    α_tilde  = use_xpbd ? F((alg::XPBDCorrection).α) : zero(F)
    λ_acc     = use_xpbd ? zeros(F, N) : F[]

    for _ in 1:n_iters
        fill!(acc_pos, zero(SVector{2,F}))
        fill!(acc_vel, zero(SVector{2,F}))
        Threads.atomic_xchg!(atomic_max_ov, zero(F))

        local_pos = pos_arr; local_vel = vel_arr; local_rad = rad_arr

        if use_xpbd
            local_λ = λ_acc
            function accumulate_pair_xpbd!(pair, _output)
                (; i, j, d) = pair
                d < F(1e-6) && return _output
                pi = local_pos[i]; vi = local_vel[i]; ri = local_rad[i]
                pj = local_pos[j]; vj = local_vel[j]; rj = local_rad[j]
                ov = ri + rj - d
                if ov > zero(F); Threads.atomic_max!(atomic_max_ov, ov); end
                lock(lk[i])
                    dp_i, dv_i, dλ_i = apply_xpbd_pair_correction(pi, vi, ri, pj, rj, local_λ[i], α_tilde)
                    acc_pos[i] = acc_pos[i] + dp_i; acc_vel[i] = acc_vel[i] + dv_i
                    local_λ[i] += dλ_i
                unlock(lk[i])
                lock(lk[j])
                    dp_j, dv_j, dλ_j = apply_xpbd_pair_correction(pj, vj, rj, pi, ri, local_λ[j], α_tilde)
                    acc_pos[j] = acc_pos[j] + dp_j; acc_vel[j] = acc_vel[j] + dv_j
                    local_λ[j] += dλ_j
                unlock(lk[j])
                return _output
            end
            CellListMap.pairwise!(accumulate_pair_xpbd!, search.psych_system)
        else
            function accumulate_pair_jacobi!(pair, _output)
                (; i, j, d) = pair
                d < F(1e-6) && return _output
                pi = local_pos[i]; vi = local_vel[i]; ri = local_rad[i]
                pj = local_pos[j]; vj = local_vel[j]; rj = local_rad[j]
                ov = ri + rj - d
                if ov > zero(F); Threads.atomic_max!(atomic_max_ov, ov); end
                dp_i, dv_i = apply_agent_pair_correction(pi, vi, ri, pj, rj)
                dp_j, dv_j = apply_agent_pair_correction(pj, vj, rj, pi, ri)
                lock(lk[i]); acc_pos[i] = acc_pos[i] + dp_i; acc_vel[i] = acc_vel[i] + dv_i; unlock(lk[i])
                lock(lk[j]); acc_pos[j] = acc_pos[j] + dp_j; acc_vel[j] = acc_vel[j] + dv_j; unlock(lk[j])
                return _output
            end
            CellListMap.pairwise!(accumulate_pair_jacobi!, search.psych_system)
        end

        Threads.@threads for i in 1:N
            pos_arr[i] = pos_arr[i] + acc_pos[i]
            vel_arr[i] = vel_arr[i] + acc_vel[i]
        end
        atomic_max_ov[] ≤ tol && break
    end

    idx = 1
    for (_, pos_col, vel_col, _geo_col) in Query(world, (Position{F}, Velocity{F}, AgentGeometry{F}))
        for i in eachindex(pos_col)
            pos_col[i] = Position(pos_arr[idx])
            vel_col[i] = Velocity(vel_arr[idx])
            idx += 1
        end
    end
end

"""
    apply_agent_correction_cpu!(world, search::RadixSpatialHash, ::Type{F};
                                n_iters=8, tol=1f-3,
                                alg::AbstractCorrectionAlgorithm=JacobiCorrection())

Agent non-penetration correction using `RadixSpatialHash` (O(N×k) per iteration).
Dispatches on `alg`: `JacobiCorrection` (default, Sprint 3T) or `XPBDCorrection(α)` (Sprint 3V).

Thread-per-agent: each thread i writes to own slot only — no SpinLocks needed.
Per-thread max_overlap reduction; adaptive early exit when `max_overlap ≤ tol`.
"""
function apply_agent_correction_cpu!(
    world   :: World,
    search  :: RadixSpatialHash,
    ::Type{F};
    n_iters :: Int = 8,
    tol     :: F   = F(1e-3),
    alg     :: AbstractCorrectionAlgorithm = JacobiCorrection()
) where {F<:AbstractFloat}
    n_iters == 0 && return

    pos_arr  = SVector{2,F}[]
    vel_arr  = SVector{2,F}[]
    rad_arr  = F[]
    for (_, pos_col, vel_col, geo_col) in Query(world, (Position{F}, Velocity{F}, AgentGeometry{F}))
        for i in eachindex(pos_col)
            push!(pos_arr, pos_col[i].p)
            push!(vel_arr, vel_col[i].v)
            push!(rad_arr, geo_col[i].social_radius)
        end
    end
    N = length(pos_arr)
    N == 0 && return

    acc_pos      = Vector{SVector{2,F}}(undef, N)
    acc_vel      = Vector{SVector{2,F}}(undef, N)
    local_max_ov = Vector{F}(undef, N)

    use_xpbd = alg isa XPBDCorrection
    α_tilde  = use_xpbd ? F((alg::XPBDCorrection).α) : zero(F)
    # per-agent λ: reset per-timestep (outside loop), accumulated across iterations
    λ_acc     = use_xpbd ? zeros(F, N) : F[]

    for _ in 1:n_iters
        build_grid!(search, pos_arr, CPU())
        fill!(acc_pos, zero(SVector{2,F}))
        fill!(acc_vel, zero(SVector{2,F}))
        fill!(local_max_ov, zero(F))

        if use_xpbd
            local_λ = λ_acc
            Threads.@threads for i in 1:N
                pos_i = pos_arr[i]; vel_i = vel_arr[i]; r_i = rad_arr[i]
                dp_acc = zero(SVector{2,F})
                dv_acc = zero(SVector{2,F})
                max_ov_i = zero(F)
                dλ_acc   = zero(F)
                for j in get_neighbors(search, pos_i)
                    j == i && continue
                    r_j  = rad_arr[j]
                    d_ij = norm(pos_i - pos_arr[j])
                    ov   = r_i + r_j - d_ij
                    if ov > max_ov_i; max_ov_i = ov; end
                    dp, dv, dλ = apply_xpbd_pair_correction(pos_i, vel_i, r_i,
                                                             pos_arr[j], r_j,
                                                             local_λ[i], α_tilde)
                    dp_acc += dp; dv_acc += dv; dλ_acc += dλ
                end
                acc_pos[i]      = dp_acc
                acc_vel[i]      = dv_acc
                local_max_ov[i] = max_ov_i
                local_λ[i]     += dλ_acc   # thread i owns slot i — no race
            end
        else
            Threads.@threads for i in 1:N
                pos_i = pos_arr[i]; vel_i = vel_arr[i]; r_i = rad_arr[i]
                dp_acc = zero(SVector{2,F})
                dv_acc = zero(SVector{2,F})
                max_ov_i = zero(F)
                for j in get_neighbors(search, pos_i)
                    j == i && continue
                    r_j = rad_arr[j]
                    dp, dv = apply_agent_pair_correction(pos_i, vel_i, r_i, pos_arr[j], r_j)
                    dp_acc += dp; dv_acc += dv
                    d_ij = norm(pos_i - pos_arr[j])
                    ov   = r_i + r_j - d_ij
                    if ov > max_ov_i; max_ov_i = ov; end
                end
                acc_pos[i]      = dp_acc
                acc_vel[i]      = dv_acc
                local_max_ov[i] = max_ov_i
            end
        end

        Threads.@threads for i in 1:N
            pos_arr[i] = pos_arr[i] + acc_pos[i]
            vel_arr[i] = vel_arr[i] + acc_vel[i]
        end
        maximum(local_max_ov) ≤ tol && break
    end

    idx = 1
    for (_, pos_col, vel_col, _geo_col) in Query(world, (Position{F}, Velocity{F}, AgentGeometry{F}))
        for i in eachindex(pos_col)
            pos_col[i] = Position(pos_arr[idx])
            vel_col[i] = Velocity(vel_arr[idx])
            idx += 1
        end
    end
end

# ── §3T-c: Unified wall correction (model-agnostic) ──────────────────────────

"""
    apply_wall_correction_cpu!(world, walls, ::Type{F})

Model-agnostic wall non-penetration correction. Queries
`(Position{F}, Velocity{F}, AgentGeometry{F})` — works for **all** models
(SFM, ORCA, CSM, HybridFSM) with a single unified ECS loop.

This replaces the per-model `wall_penetration_correction!` overloads in
`hybrid_fsm.jl` and `csm.jl`. Those overloads remain as **deprecated thin
wrappers** (one sprint backward compat window, removed in Sprint 3U).

Uses `apply_wall_penetration_correction` (orca_math.jl) for each wall pair.

## Threading

Each agent's wall correction is independent (walls are static).
`Threads.@threads` over agents is race-free.
"""
function apply_wall_correction_cpu!(
    world :: World,
    walls :: Vector{NTuple{2, SVector{2,F}}},
    ::Type{F}
) where {F<:AbstractFloat}
    isempty(walls) && return

    for (_, pos_col, vel_col, geo_col) in Query(world, (Position{F}, Velocity{F}, AgentGeometry{F}))
        Threads.@threads for i in collect(eachindex(pos_col))
            pos = pos_col[i].p
            vel = vel_col[i].v
            r_i = geo_col[i].social_radius
            for (p1, p2) in walls
                pos, vel = apply_wall_penetration_correction(pos, vel, r_i, p1, p2)
            end
            pos_col[i] = Position(pos)
            vel_col[i] = Velocity(vel)
        end
    end
end

# ── §3T-d-pre: GPU position integration kernels ──────────────────────────────
#
# These kernels compute post-step positions on device BEFORE apply_agent_correction_gpu!
# so that the Jacobi correction operates on physically correct (integrated) positions,
# not pre-step sorted positions.
#
# CSM path:  sorted_pos[i] += sorted_new_vel[i] * dt
# HybridFSM: sorted_vel[i] += sorted_force[i] / sorted_mass[i] * dt
#             sorted_pos[i] += sorted_vel[i] * dt

"""
    integrate_positions_kernel!(sorted_positions, sorted_new_vels, dt, N)

GPU CSM position integration: updates sorted positions in-place using new velocities
from `compute_csm_kernel!` (already reordered to sorted order).

`sorted_positions[i] += sorted_new_vels[i] * dt`

Called after `compute_csm_kernel!` and velocity reordering, before
`apply_agent_correction_gpu!`. Makes sorted_dev_positions hold post-step positions
so the Jacobi correction acts on the physically correct state.
"""
@kernel function integrate_positions_kernel!(
    positions     :: AbstractVector,
    @Const(new_vels :: AbstractVector),
    dt            :: Float32,
    N             :: Int32
)
    i = @index(Global, Linear)
    if i <= N
        positions[i] = positions[i] + new_vels[i] * dt
    end
end

"""
    integrate_vel_pos_kernel!(sorted_positions, sorted_velocities,
                              sorted_forces, sorted_masses, dt, N)

GPU HybridFSM vel+pos integration. Applies combined SFM+ORCA forces (uploaded
from CPU after CPU ORCA pass) to update sorted velocities and positions in-place:

    sorted_vel[i] += sorted_force[i] / sorted_mass[i] * dt
    sorted_pos[i] += sorted_vel[i] * dt

Called after combined CPU+GPU forces are uploaded to device and sorted, before
`apply_agent_correction_gpu!`.
"""
@kernel function integrate_vel_pos_kernel!(
    positions  :: AbstractVector,
    velocities :: AbstractVector,
    @Const(forces  :: AbstractVector),
    @Const(masses  :: AbstractVector),
    dt         :: Float32,
    N          :: Int32
)
    i = @index(Global, Linear)
    if i <= N
        m_i   = masses[i]
        v_new = velocities[i] + forces[i] * (dt / m_i)
        velocities[i] = v_new
        positions[i]  = positions[i] + v_new * dt
    end
end

# ── §3T-d: GPU Jacobi kernels ─────────────────────────────────────────────────

"""
    agent_correction_kernel!(out_delta_pos, out_delta_vel,
                              sorted_positions, sorted_velocities, sorted_radii,
                              cell_starts, cell_ends,
                              cell_origin, cell_size, grid_dims, N)

GPU Jacobi compute pass: each thread i computes Δpos[i] and Δvel[i] by
iterating its 3×3 cell neighbourhood (same spatial indexing as compute_csm_kernel!
and compute_orca_kernel!).

Read-only: sorted_positions, sorted_radii.
Write-only: out_delta_pos[i], out_delta_vel[i] — own slot only, no race.

Called by `apply_agent_correction_gpu!` (n_iters times).
"""
@kernel function agent_correction_kernel!(
    out_delta_pos   :: AbstractVector,
    out_delta_vel   :: AbstractVector,
    @Const(sorted_positions  :: AbstractVector),
    @Const(sorted_velocities :: AbstractVector),
    @Const(sorted_radii      :: AbstractVector),
    @Const(cell_starts       :: AbstractVector),
    @Const(cell_ends         :: AbstractVector),
    cell_origin :: SVector{2},
    cell_size   :: Float32,
    grid_dims   :: SVector{2, Int32},
    N           :: Int32
)
    i = @index(Global, Linear)
    if i <= N
        F = eltype(sorted_radii)
        pos_i = sorted_positions[i]
        vel_i = sorted_velocities[i]
        r_i   = sorted_radii[i]

        dp = zero(SVector{2,F})
        dv = zero(SVector{2,F})

        ci = floor(Int32, (pos_i[1] - cell_origin[1]) / cell_size)
        cj = floor(Int32, (pos_i[2] - cell_origin[2]) / cell_size)

        @inbounds for dci in Int32(-1):Int32(1), dcj in Int32(-1):Int32(1)
            ni = ci + dci; nj = cj + dcj
            if ni >= Int32(0) && ni < grid_dims[1] && nj >= Int32(0) && nj < grid_dims[2]
                cell_idx = ni * grid_dims[2] + nj + Int32(1)
                if cell_idx >= Int32(1) && cell_idx <= length(cell_starts)
                    cs = cell_starts[cell_idx]
                    ce = cell_ends[cell_idx]
                    if cs <= ce
                        for jj in cs:ce
                            if jj != i
                                pos_j = sorted_positions[jj]
                                r_j   = sorted_radii[jj]
                                dp_j, dv_j = apply_agent_pair_correction(pos_i, vel_i, r_i, pos_j, r_j)
                                dp = dp + dp_j
                                dv = dv + dv_j
                            end
                        end
                    end
                end
            end
        end

        out_delta_pos[i] = dp
        out_delta_vel[i] = dv
    end
end

"""
    apply_correction_kernel!(positions, velocities, delta_pos, delta_vel, N)

GPU write-back pass: applies accumulated Jacobi deltas to sorted positions and
velocities in-place. Separate from the compute pass so GPU synchronization between
the read-only compute and the write-back is explicit.
"""
@kernel function apply_correction_kernel!(
    positions  :: AbstractVector,
    velocities :: AbstractVector,
    @Const(delta_pos :: AbstractVector),
    @Const(delta_vel :: AbstractVector),
    N :: Int32
)
    i = @index(Global, Linear)
    if i <= N
        positions[i]  = positions[i]  + delta_pos[i]
        velocities[i] = velocities[i] + delta_vel[i]
    end
end

# ── §3V-GPU: XPBD GPU kernels ─────────────────────────────────────────────────

"""
    xpbd_correction_kernel!(out_delta_pos, out_delta_vel, out_delta_lambda,
                             sorted_positions, sorted_velocities, sorted_radii,
                             sorted_lambda, cell_starts, cell_ends,
                             grid_min, cell_size, grid_dims, N, alpha_tilde)

GPU XPBD compute pass: each thread i computes Δpos[i], Δvel[i], Δλ[i] using
the accumulated λ[i] from previous iterations.  Same 3×3 neighbourhood as
`agent_correction_kernel!`. α_tilde = α / dt² (passed as Float32).

At α_tilde=0 the update is identical to Jacobi.
"""
@kernel function xpbd_correction_kernel!(
    out_delta_pos    :: AbstractVector,
    out_delta_vel    :: AbstractVector,
    out_delta_lambda :: AbstractVector,
    @Const(sorted_positions  :: AbstractVector),
    @Const(sorted_velocities :: AbstractVector),
    @Const(sorted_radii      :: AbstractVector),
    @Const(sorted_lambda     :: AbstractVector),
    @Const(cell_starts       :: AbstractVector),
    @Const(cell_ends         :: AbstractVector),
    cell_origin :: SVector{2},
    cell_size   :: Float32,
    grid_dims   :: SVector{2, Int32},
    N           :: Int32,
    alpha_tilde :: Float32
)
    i = @index(Global, Linear)
    if i <= N
        F = eltype(sorted_radii)
        pos_i = sorted_positions[i]
        vel_i = sorted_velocities[i]
        r_i   = sorted_radii[i]
        λ_i   = sorted_lambda[i]

        dp = zero(SVector{2,F})
        dv = zero(SVector{2,F})
        dλ = zero(F)

        ci = floor(Int32, (pos_i[1] - cell_origin[1]) / cell_size)
        cj = floor(Int32, (pos_i[2] - cell_origin[2]) / cell_size)

        @inbounds for dci in Int32(-1):Int32(1), dcj in Int32(-1):Int32(1)
            ni = ci + dci; nj = cj + dcj
            if ni >= Int32(0) && ni < grid_dims[1] && nj >= Int32(0) && nj < grid_dims[2]
                cell_idx = ni * grid_dims[2] + nj + Int32(1)
                if cell_idx >= Int32(1) && cell_idx <= length(cell_starts)
                    cs = cell_starts[cell_idx]; ce = cell_ends[cell_idx]
                    if cs <= ce
                        for jj in cs:ce
                            if jj != i
                                pos_j = sorted_positions[jj]
                                r_j   = sorted_radii[jj]
                                dp_j, dv_j, dλ_j = apply_xpbd_pair_correction(
                                    pos_i, vel_i, r_i, pos_j, r_j, λ_i, alpha_tilde)
                                dp += dp_j; dv += dv_j; dλ += dλ_j
                            end
                        end
                    end
                end
            end
        end

        out_delta_pos[i]    = dp
        out_delta_vel[i]    = dv
        out_delta_lambda[i] = dλ
    end
end

"""
    apply_xpbd_kernel!(positions, velocities, lambda, delta_pos, delta_vel, delta_lambda, N)

GPU XPBD write-back: apply Δpos, Δvel and accumulate Δλ into the λ buffer.
λ is accumulated (not reset) — reset happens once per timestep before the loop.
"""
@kernel function apply_xpbd_kernel!(
    positions    :: AbstractVector,
    velocities   :: AbstractVector,
    lambda       :: AbstractVector,
    @Const(delta_pos    :: AbstractVector),
    @Const(delta_vel    :: AbstractVector),
    @Const(delta_lambda :: AbstractVector),
    N :: Int32
)
    i = @index(Global, Linear)
    if i <= N
        positions[i]  = positions[i]  + delta_pos[i]
        velocities[i] = velocities[i] + delta_vel[i]
        lambda[i]     = lambda[i]     + delta_lambda[i]
    end
end

"""
    apply_agent_correction_gpu!(base, search, backend; n_iters=8,
                                alg::AbstractCorrectionAlgorithm=JacobiCorrection())

GPU agent non-penetration correction. Dispatches on `alg`:
- `JacobiCorrection()` — original Jacobi kernel loop (Sprint 3T), unchanged.
- `XPBDCorrection(α)`  — XPBD kernel loop (Sprint 3V): resets `base.dev_lambda`
  at entry, then runs `xpbd_correction_kernel!` + `apply_xpbd_kernel!` per iteration.
  Converges in ~5–8 iterations for dense bottleneck scenarios.

Called after `stage_and_sort_base!` has populated `base.sorted_dev_positions`,
`base.sorted_dev_velocities`, `base.sorted_dev_radii`.

The corrected sorted positions/velocities must be scattered back to ECS by the
caller (same as the existing GPU model scatter-back pattern).
"""
function apply_agent_correction_gpu!(
    base    :: BaseGPUContext,
    search  :: RadixSpatialHash,
    backend;
    n_iters :: Int = 8,
    alg     :: AbstractCorrectionAlgorithm = JacobiCorrection()
)
    n_iters == 0 && return
    N = Int32(length(base.sorted_dev_positions))

    if alg isa XPBDCorrection
        # ── XPBD path (Sprint 3V) ────────────────────────────────────────────
        α_tilde = Float32((alg::XPBDCorrection).α)

        # Reset λ accumulator at timestep start
        fill!(base.dev_lambda, zero(eltype(base.dev_lambda)))
        KernelAbstractions.synchronize(backend)

        kern_compute = xpbd_correction_kernel!(backend)
        kern_apply   = apply_xpbd_kernel!(backend)

        for _ in 1:n_iters
            kern_compute(
                base.dev_delta_pos, base.dev_delta_vel, base.dev_delta_lambda,
                base.sorted_dev_positions, base.sorted_dev_velocities, base.sorted_dev_radii,
                base.dev_lambda,
                search.cell_starts, search.cell_ends,
                search.grid_min, search.cell_size, SVector{2,Int32}(search.grid_dims),
                N, α_tilde;
                ndrange = Int(N)
            )
            KernelAbstractions.synchronize(backend)

            kern_apply(
                base.sorted_dev_positions, base.sorted_dev_velocities, base.dev_lambda,
                base.dev_delta_pos, base.dev_delta_vel, base.dev_delta_lambda, N;
                ndrange = Int(N)
            )
            KernelAbstractions.synchronize(backend)
        end
    else
        # ── Jacobi path (Sprint 3T, default) ─────────────────────────────────
        kern_compute = agent_correction_kernel!(backend)
        kern_apply   = apply_correction_kernel!(backend)

        for _ in 1:n_iters
            kern_compute(
                base.dev_delta_pos, base.dev_delta_vel,
                base.sorted_dev_positions, base.sorted_dev_velocities, base.sorted_dev_radii,
                search.cell_starts, search.cell_ends,
                search.grid_min, search.cell_size, SVector{2,Int32}(search.grid_dims), N;
                ndrange = Int(N)
            )
            KernelAbstractions.synchronize(backend)

            kern_apply(
                base.sorted_dev_positions, base.sorted_dev_velocities,
                base.dev_delta_pos, base.dev_delta_vel, N;
                ndrange = Int(N)
            )
            KernelAbstractions.synchronize(backend)
        end
    end
end
