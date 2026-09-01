module SimCrowd

using StaticArrays
using LinearAlgebra
using KernelAbstractions
using Eikonal
using Ark

using SimCore

export Position, Velocity, AgentGeometry, MotionParams, SFMParams, Goal, Force, WallSegment
export from_agent_params
export goal_seeking_force, agent_repulsion, wall_repulsion, gcf_force
export AbstractNeighborSearch, RadixSpatialHash, CPUNeighborSearch, build_grid!, get_neighbors, get_ka_backend
export AbstractNavigationField, NavigationField, build_navigation_field,
       get_nav_direction, get_desired_direction, to_device
export update_navigation_system!, update_social_forces_system!, integrate_physics_system!
export ORCAParams, update_orca_system!, compute_orca_line_wall, compute_orca_line_endpoint
export HybridFSMParams, AgentFSMState, update_hybrid_fsm_system!, ORCA_MODE, SFM_MODE
export CSMParams, AgentCSMState, update_csm_system!
export CSMParams_Classic, CSMParams_V3, CSMParams_JuPedSim
export nearest_point_on_segment, nearest_point_on_arc, csm_speed, csm_gap
export apply_wall_penetration_correction
export ContactModel, NoContact, Coulomb, Viscous
# §2.1 ForceModel trait
export ForceModel, SFMModel, ORCAModel, HybridModel, AgentModel
# §2.3 Shared GPU infrastructure (Sprint 3Q-arch)
export BaseGPUContext, stage_and_sort_base!
# Sprint 3R: CSM GPU context
export CSMGPUContext, compute_csm_kernel!
# Sprint 3S: Hybrid FSM GPU context
export HybridFSMGPUContext, compute_density_mode_kernel!, compute_hybrid_sfm_kernel!
# Sprint 3T: Geometric non-penetration correction (agent-agent + unified wall)
export apply_agent_pair_correction, apply_xpbd_pair_correction
export apply_agent_correction_cpu!, apply_agent_correction_gpu!
export apply_wall_correction_cpu!, integrate_positions_kernel!, integrate_vel_pos_kernel!
# Sprint 3V: Correction algorithm selectors
export AbstractCorrectionAlgorithm, JacobiCorrection, XPBDCorrection
# §2.4 SimConfig + SimScene
export SimConfig, SimScene, step!, run!
export apply_sfm_contact_subcycle!

# Components
struct Position{F<:AbstractFloat}
    p::SVector{2,F}
end

struct Velocity{F<:AbstractFloat}
    v::SVector{2,F}
end

struct Force{F<:AbstractFloat}
    f::SVector{2,F}
end

"""
    AgentGeometry{F<:AbstractFloat}

Physical geometry of an agent: personal space and body collision radii.

Used by:
- Social force kernel (SFM agent-agent + wall repulsion)
- Wall navigation

Fields:
- `social_radius`:    personal space radius (m). Agents start repelling each other at 2×r.
- `collision_radius`: body radius (m). Physical contact forces activate at r_i + r_j ≥ d.
                      Standard: `2/3 × social_radius` (Helbing 2000). Set 0 for NoContact.
"""
struct AgentGeometry{F<:AbstractFloat}
    social_radius::F
    collision_radius::F
end

# Convenience: auto collision_radius = 2/3 × social_radius (Helbing 2000 standard body ratio)
AgentGeometry(sr::F) where {F<:AbstractFloat} = AgentGeometry(sr, sr * F(2/3))

"""
    MotionParams{F<:AbstractFloat}

Locomotion parameters of an agent: mass, preferred speed, relaxation time, and velocity noise.

Used by:
- Physics integrator (`mass` → acceleration, `σ` → SDE fluctuation term)
- Goal-seeking and navigation forces (computes `mass × (v_pref⋅ê − v) / τ`)
- ORCA force conversion (mass, v_pref, τ for velocity → force)
"""
struct MotionParams{F<:AbstractFloat}
    mass::F    # body mass (kg). Typical pedestrian: 80 kg.
    v_pref::F  # preferred walking speed (m/s). Normal: 1.2–1.4 m/s; panic: 3–4 m/s.
    τ::F       # relaxation time (s). Helbing 2000: 0.5 s.
    σ::F       # velocity diffusion (m/s). 0.10 evacuation, 0.05 normal, 0.0 deterministic.
end

# Convenience: σ defaults to 0.1 m/s (Helbing 2000 evacuation calibration)
MotionParams(mass::F, v_pref::F, τ::F) where {F<:AbstractFloat} = MotionParams(mass, v_pref, τ, F(0.1))

"""
    SFMParams{F<:AbstractFloat}

Social Force Model (Helbing & Molnar 1995 / Helbing, Farkas & Vicsek 2000) parameters.

Used only by the SFM force kernel. Agents using purely ORCA do not need this component.

Fields:
- `A`: social repulsion strength (N).  Helbing 2000: 2000 N.
- `B`: repulsion decay length (m).     Helbing 2000: 0.08 m.
- `λ`: anisotropy factor ∈ [0,1].     Helbing 2000: 0.5. λ=1 isotropic; λ=0.5 half attention behind.
- `μ`: Coulomb friction cap. 0=NoContact, Inf=Viscous (exact Helbing), 0.5=normal walking.
- `η`: §1.4 GCF speed-adaptation factor (s). 0.0 = Helbing (disabled), 0.5 = Chraibi 2010 circular.
         When η>0, the personal space range grows linearly with agent speed:
         `D_i = social_radius + η × ‖v_i‖`, giving elliptical personal space that stretches ahead.
- `τ_gap`: §1.5 GCFM-elliptical time-gap (s). 0.0 = circular/Helbing; 0.53 = Chraibi 2010 §III.
           When τ_gap>0, `gcf_force_elliptical` is dispatched instead of `gcf_force`.
- `b_min`: Minimum lateral semi-axis (m). At high speed. Chraibi 2010 §VII: **0.20m** (not 0.25m).
- `b_max`: Maximum lateral semi-axis (m). At rest. Chraibi 2010 §VII: **0.25m** (not 0.30m).
"""
struct SFMParams{F<:AbstractFloat}
    A::F
    B::F
    λ::F
    μ::F
    η::F      # §1.4 GCF speed-adaptation factor; 0.0 = Helbing behavior (GCF disabled)
    τ_gap::F   # §1.5 GCFM-elliptical time-gap; 0.0 = circular (gcf_force); >0 = elliptical
    b_min::F   # §1.5 lateral semi-axis minimum (m)
    b_max::F   # §1.5 lateral semi-axis maximum (m)
end

# Backward-compatible 5-arg constructor: τ_gap=0, b_min=b_max=0.25 (circular, GCF disabled)
SFMParams(A::F, B::F, λ::F, μ::F, η::F) where {F<:AbstractFloat} =
    SFMParams(A, B, λ, μ, η, zero(F), F(0.20), F(0.25))  # Chraibi 2010: b_min=0.20, b_max=0.25

# Backward-compatible 4-arg constructor: η=0, τ_gap=0 (Helbing SFM)
SFMParams(A::F, B::F, λ::F, μ::F) where {F<:AbstractFloat} =
    SFMParams(A, B, λ, μ, zero(F), zero(F), F(0.25), F(0.25))

# Convenience: supply only μ, Helbing 2000 defaults for A, B, λ, η=0, τ_gap=0
SFMParams(μ::F) where {F<:AbstractFloat} =
    SFMParams(F(2000), F(0.08), F(0.5), μ, zero(F), zero(F), F(0.25), F(0.25))

# All Helbing 2000 defaults
SFMParams{F}() where {F<:AbstractFloat} =
    SFMParams(F(2000), F(0.08), F(0.5), F(0.5), zero(F), zero(F), F(0.25), F(0.25))

"""
    ContactModel

Specifies how body-contact forces are modeled in the Helbing SFM.
The model is encoded in `SFMParams.μ` and `AgentGeometry.collision_radius` at construction time:

| ContactModel | `collision_radius`  | `μ` value | Physical meaning |
|--------------|---------------------|-----------|------------------|
| `NoContact`  | 0 (disabled)        | 0.0       | Social force only — low-density normal walking |
| `Coulomb`    | `2/3 × social_r`   | supplied  | Coulomb-capped viscous friction — default, good for lane formation |
| `Viscous`    | `2/3 × social_r`   | Inf       | Pure viscous κ×g×Δv_t — Helbing 2000 exact; enables Faster-is-Slower |
"""
@enum ContactModel::Int32 begin
    NoContact   # collision_radius = 0; μ = 0  → no body contact forces
    Coulomb     # collision_radius = 2/3 r; μ ∈ (0, ∞) → Coulomb-capped friction
    Viscous     # collision_radius = 2/3 r; μ = Inf → pure viscous, Helbing exact
end

"""
    from_agent_params(social_radius, mass, v_pref, τ [, μ=0.5 [, σ=0.1]]) → (AgentGeometry, MotionParams, SFMParams)
    from_agent_params(social_radius, collision_radius, mass, v_pref, τ, μ, σ)  → (AgentGeometry, MotionParams, SFMParams)

# DEPRECATED migration helper for §2.2

Converts old `AgentParams(…)` call patterns to the 3 ECS components introduced in §2.2.
Use by splatting the result directly into `new_entity!`:

```julia
new_entity!(world, (pos, vel, from_agent_params(r, 80f0, v0, τ, 0.5f0)…, goal, force))
```

This helper exists to ease migration. When all call sites use explicit `AgentGeometry`,
`MotionParams`, and `SFMParams` constructors, this helper can be removed.

See: §2.2 in `simcrowd_improvement_plan.md`.
"""
# 4/5-arg: auto cr = sr×2/3, σ = 0.1 default; η=0.0 (Helbing, GCF disabled), τ_gap=0 (circular)
function from_agent_params(sr::F, mass::F, v_pref::F, τ::F, μ::F=F(0.5);
                            σ::F=F(0.1), A::F=F(2000), B::F=F(0.08), λ::F=F(0.5),
                            η::F=zero(F), τ_gap::F=zero(F), b_min::F=F(0.25), b_max::F=F(0.25)) where {F<:AbstractFloat}
    return (AgentGeometry(sr, sr * F(2/3)), MotionParams(mass, v_pref, τ, σ), SFMParams(A, B, λ, μ, η, τ_gap, b_min, b_max))
end

# 6-arg positional: auto cr = sr×2/3, explicit σ
function from_agent_params(sr::F, mass::F, v_pref::F, τ::F, μ::F, σ::F;
                            A::F=F(2000), B::F=F(0.08), λ::F=F(0.5),
                            η::F=zero(F), τ_gap::F=zero(F), b_min::F=F(0.25), b_max::F=F(0.25)) where {F<:AbstractFloat}
    return (AgentGeometry(sr, sr * F(2/3)), MotionParams(mass, v_pref, τ, σ), SFMParams(A, B, λ, μ, η, τ_gap, b_min, b_max))
end

# 7-arg: explicit collision_radius and σ
function from_agent_params(sr::F, cr::F, mass::F, v_pref::F, τ::F, μ::F, σ::F;
                            A::F=F(2000), B::F=F(0.08), λ::F=F(0.5),
                            η::F=zero(F), τ_gap::F=zero(F), b_min::F=F(0.25), b_max::F=F(0.25)) where {F<:AbstractFloat}
    return (AgentGeometry(sr, cr), MotionParams(mass, v_pref, τ, σ), SFMParams(A, B, λ, μ, η, τ_gap, b_min, b_max))
end

struct ORCAParams{F<:AbstractFloat}
    time_horizon::F
    time_horizon_obst::F
    max_neighbors::Int
    neighbor_dist::F
    radius::F
    v_pref::F
    τ::F
    mass::F
    responsibility::F  # §1.8: fraction of ORCA velocity-change taken by agent i ∈ [0,1]
                       # 0.5 = reciprocal ORCA (standard — both agents share equally)
                       # 1.0 = full (use for walls or when j is known non-cooperative)
                       # values ∈ (0.5, 1.0] make agent i more conservative (safer under uncertainty)
end

"""
    ORCAParams(time_horizon, time_horizon_obst, max_neighbors, neighbor_dist,
               radius, v_pref, τ, mass [, responsibility=0.5])

Constructors for `ORCAParams`. The 8-arg form defaults `responsibility = 0.5` (standard
reciprocal ORCA). Pass `responsibility = 1.0` for agents that cannot rely on neighbours
to cooperate (e.g., robot in a pedestrian crowd, or agent approaching a wall boundary).
"""
# 8-arg backward-compatible: defaults responsibility = 0.5 (reciprocal ORCA)
ORCAParams(th::F, tho::F, mn::Int, nd::F, r::F, vp::F, τ::F, m::F) where {F<:AbstractFloat} =
    ORCAParams(th, tho, mn, nd, r, vp, τ, m, F(0.5))

struct WallSegment{F<:AbstractFloat}
    p1::SVector{2,F}
    p2::SVector{2,F}
end

struct Goal{F<:AbstractFloat}
    g::SVector{2,F}
end

# ── §3K-b: Hybrid FSM structs ─────────────────────────────────────────────────

"""
    HybridFSMParams{F<:AbstractFloat}

Density-triggered FSM parameters for per-agent ORCA↔SFM dispatch.
Based on the Menge architecture (Curtis, Best, Manocha 2016, §3).

All fields are primitive types → isbits ✅ → GPU-compatible.

Fields:
- `ρ_on`:           density threshold (ped/m²) for ORCA→SFM switch (high density).
- `ρ_off`:          density threshold (ped/m²) for SFM→ORCA switch (low density).
                    Must be < ρ_on. Hysteresis band [ρ_off, ρ_on] prevents chatter.
- `density_radius`: neighbourhood radius for local density estimation (m).
- `sfm_params`:     embedded SFMParams (used in SFM_MODE).
- `orca_params`:    embedded ORCAParams (used in ORCA_MODE).
"""
Base.@kwdef struct HybridFSMParams{F<:AbstractFloat}
    ρ_on           :: F             = F(3.5)    # ORCA→SFM at 3.5 ped/m²
    ρ_off          :: F             = F(2.5)    # SFM→ORCA at 2.5 ped/m²
    density_radius :: F             = F(2.0)    # density estimation radius (m)
    sfm_params     :: SFMParams{F}  = SFMParams{F}()
    orca_params    :: ORCAParams{F} = ORCAParams(F(2.0), F(0.5), 10, F(15.0),
                                                   F(0.2), F(1.4), F(0.5), F(80.0))
end

"""
    AgentFSMState{F<:AbstractFloat}

Immutable, fully isbits per-agent FSM state. Updated each step via
`state_col[i] = AgentFSMState{F}(new_mode, new_ρ, new_blend)`.

Fields:
- `mode`:          Int32. `ORCA_MODE` (0) or `SFM_MODE` (1).
- `ρ_ema`:         F. Exponential moving average of local density (ped/m²).
                   α=0.33 → time constant ≈ 3 steps.
- `blend_counter`: Int32. Reserved for future force-blend at mode switches (currently 0).

GPU upgrade path: `Storage{StructArray}` → `Storage{GPUStructArray{:CUDA}}` with zero struct changes.
"""
struct AgentFSMState{F<:AbstractFloat}
    mode          :: Int32
    ρ_ema         :: F
    blend_counter :: Int32
end

# Default constructor: start in ORCA_MODE, zero density, no blend
AgentFSMState{F}() where {F<:AbstractFloat} = AgentFSMState{F}(Int32(0), zero(F), Int32(0))

# Compile-time GPU-compatibility guard
@assert isbitstype(AgentFSMState{Float32}) "AgentFSMState must remain isbits for KA/GPU compatibility"

# ── §3L: CSM (Collision-Free Speed Model) structs ────────────────────────────

"""
    CSMParams{F<:AbstractFloat}

Unified Collision-Free Speed Model parameters (Classic / V3 via field selection).

Model variants:
  `use_rotational_steering=false` -> CSM-Classic (Tordeux 2016, isotropic repulsion)
  `use_rotational_steering=true`  -> CSM-V3      (heading relaxation, JuPedSim V3)

All fields are primitive types -> `isbits` -> GPU-compatible.

Sprint 3M changes (2026-08-27):
  - Removed: a_wall, D_wall (V2 wall repulsion in direction model -- no paper basis)
  - Added: strength_geo, range_geo (JuPedSim-style contact geometry constraint)
  - Changed: a_neighbor default 3.0->8.0, D_neighbor default 0.2->0.1 (Tordeux 2016)
  - Changed: heading_relaxation_tau (was heading_relaxation_tau with unicode) -- same semantics
  - Repulsion formula: now uses surface-to-surface gap (was center-to-center)

Fields:
- `v0`:                     desired free-flow speed (m/s). Weidmann: 1.34 m/s.
- `T`:                      time-gap parameter (s). Safety headway.
- `radius`:                 agent body radius (m). Body length l = 2r.
- `a_neighbor`:             neighbor repulsion strength (m/s). Tordeux: 8.0.
- `D_neighbor`:             neighbor repulsion decay length (m). Tordeux: 0.1.
- `fov_half_angle`:         forward-cone half-angle for SPEED model (rad). pi = full 180.
- `strength_geo`:           geometry contact constraint strength. JuPedSim: 5.0. 0.0=disabled.
- `range_geo`:              geometry contact constraint range (m). JuPedSim: 0.02.
- `use_rotational_steering`:true -> V3 (heading relaxation); false -> Classic.
- `heading_relaxation_tau`: heading smoothing time constant (s). JuPedSim V3: 0.3.
- `neighbor_radius`:        max neighbor search radius (m).
- `max_neighbors`:          informational; O(N) scan uses all within radius.
"""
Base.@kwdef struct CSMParams{F<:AbstractFloat}
    # -- Classic core ----------------------------------------------------------
    v0                     :: F    = F(1.34)  # desired free-flow speed (m/s)
    T                      :: F    = F(1.0)   # time-gap parameter (s)
    radius                 :: F    = F(0.20)  # agent body radius (m); l = 2r

    # -- Direction model -------------------------------------------------------
    a_neighbor             :: F    = F(8.0)   # neighbor repulsion strength (m/s) -- Tordeux 2016
    D_neighbor             :: F    = F(0.1)   # neighbor repulsion decay length (m) -- Tordeux 2016
    fov_half_angle         :: F    = F(pi)    # [LEGACY - unused since Sprint 3N-a] kept for isbits compat

    # -- Geometry contact constraint (JuPedSim approach) -----------------------
    # Replaces V2 wall repulsion. Contact-level only (range=0.02m).
    # Applied in ALL directions without filter. Negligible at dist > 0.30m from wall.
    strength_geo           :: F    = F(5.0)   # geometry constraint strength. 0.0=disabled.
    range_geo              :: F    = F(0.02)  # geometry constraint range (m). JuPedSim default.

    # -- V3: rotational steering -----------------------------------------------
    use_rotational_steering :: Bool = false
    heading_relaxation_tau  :: F    = F(0.3)  # heading smoothing tau (s). JuPedSim V3: 0.3s.

    # -- Neighbor search -------------------------------------------------------
    neighbor_radius        :: F    = F(2.0)   # max neighbor search radius (m)
    max_neighbors          :: Int  = 8        # informational; O(N) scan uses all within radius
end

# Compile-time GPU-compatibility guard
@assert isbitstype(CSMParams{Float32})  "CSMParams must remain isbits for KA/GPU compatibility"


"""CSM-Classic: Tordeux 2016 faithful implementation. Surface-to-surface gap,
all neighbors isotropic, contact geometry constraint. Default parameters match
JuPedSim reference defaults (a=8.0, D=0.1, T=1.0)."""
CSMParams_Classic(F=Float32; kw...) = CSMParams{F}(; use_rotational_steering=false, kw...)

"""CSM-V3: Classic + rotational heading relaxation (tau=0.3s). JuPedSim V3 approach.
Reduces T7 throughput vs Classic -- physical feature (turning cost), not a bug.
Use for dense crowds, tight corridors, and scenarios requiring physical turning realism."""
CSMParams_V3(F=Float32; kw...) = CSMParams{F}(; use_rotational_steering=true,
                                                heading_relaxation_tau=F(0.3), kw...)

"""JuPedSim reference parameters for cross-validation.
Physically equivalent to CSMParams_Classic with radius=0.15 (JuPedSim default)."""
CSMParams_JuPedSim(F=Float32) = CSMParams{F}(
    v0=F(1.34), T=F(1.0), radius=F(0.15),
    a_neighbor=F(8.0), D_neighbor=F(0.1),
    strength_geo=F(5.0), range_geo=F(0.02),
    use_rotational_steering=false
)


"""
    AgentCSMState{F<:AbstractFloat}

Per-agent state for CSM V3 rotational steering. Updated each step via write-back.

Fields:
- `heading`: current walking direction angle (radians). Relaxes toward goal direction
  with time constant `τ = CSMParams.heading_relaxation_τ`.

isbits → GPU-compatible. Same design pattern as `AgentFSMState`.
Only required for V3 agents (`use_rotational_steering = true`).
"""
struct AgentCSMState{F<:AbstractFloat}
    heading :: F   # current heading angle (radians), initialised to goal direction angle
end

# Default: heading = 0 (due east). Caller should initialise from goal direction.
AgentCSMState(F=Float32) = AgentCSMState{F}(zero(F))
AgentCSMState{F}() where {F<:AbstractFloat} = AgentCSMState{F}(zero(F))

@assert isbitstype(AgentCSMState{Float32}) "AgentCSMState must remain isbits for KA/GPU compatibility"

# ── §3V: Correction algorithm selectors ─────────────────────────────────────────

"""
    AbstractCorrectionAlgorithm

Trait type selecting the agent non-penetration correction algorithm.
Passed via `SimConfig.correction_alg`. Two concrete subtypes:

| Type                | α effect       | Convergence       | Equivalent to   |
|---------------------|----------------|-------------------|-----------------|
| `JacobiCorrection`  | none (α=0)     | ~20–50 iterations | XPBD(α=0)       |
| `XPBDCorrection{F}` | compliance α   | ~5–8 iterations   | generalized     |

XPBD with α=0 is **mathematically identical** to Jacobi.
"""
abstract type AbstractCorrectionAlgorithm end

"""
    JacobiCorrection()

Standard Jacobi position-based correction (Sprint 3T). Each pass applies
the full half-overlap correction with no memory of previous iterations.
Equivalent to `XPBDCorrection(α=0f0)` at the mathematical level.

Default algorithm in `SimConfig`. Suitable for low-to-medium density scenes.
"""
struct JacobiCorrection <: AbstractCorrectionAlgorithm end

"""
    XPBDCorrection{F<:AbstractFloat}(; α::F = 1f-6)
    XPBDCorrection()      # F=Float32, α=1e-6
    XPBDCorrection(α=...)  # explicit compliance

Extended Position-Based Dynamics correction (Macklin et al. 2016).

## Parameter
- `α` — compliance coefficient (m²·s²/kg, dimensionlessly ≈ 0 for hard constraint).
  - `α=0`   : hard constraint, identical to `JacobiCorrection`.
  - `α=1e-6`: near-hard (default). Prevents over-correction in dense jams.
  - `α=1e-3`: soft (useful for debugging oscillations).

## Why XPBD converges faster than Jacobi

Jacobi in dense configurations (k=6–8 contacts per agent) applies corrections
that stack and overshoot — requiring ~50 iterations to settle.

XPBD introduces a per-agent accumulated Lagrange multiplier `λᵢ` (reset each
timestep, accumulated across iterations). The update becomes:

    α̃ = α / dt²
    Δλᵢⱼ = max(0, (-Cᵢⱼ - α̃·λᵢ) / (wᵢⱼ + α̃))   # Cᵢⱼ = d_ij - (rᵢ+rⱼ)
    Δxᵢ  += n̂ᵢⱼ · Δλᵢⱼ
    λᵢ   += Δλᵢⱼ

The `α̃·λᵢ` term grows as corrections accumulate, progressively shrinking
subsequent Δx — preventing oscillation. Converges in ~5–8 iterations for
the T7 bottleneck scenario (vs ~50 for Jacobi).

## Implementation note (per-agent λ approximation)

This implementation uses one λ per **agent** (not one per contact pair).
This is a diagonal/lumped approximation to exact per-contact XPBD, but
remains fully GPU-embarrassingly-parallel and gives ~3–5× faster convergence
than Jacobi. True per-contact λ (with variable-width CSR buffer) is deferred.
"""
struct XPBDCorrection{F<:AbstractFloat} <: AbstractCorrectionAlgorithm
    α :: F
end
# Keyword constructor — default α=1e-6 (near-hard; Jacobi at α=0)
# XPBDCorrection()        → XPBDCorrection{Float32}(1f-6)
# XPBDCorrection(α=1f-4) → XPBDCorrection{Float32}(1f-4)
XPBDCorrection(; α::F = Float32(1e-6)) where {F<:AbstractFloat} = XPBDCorrection{F}(α)

# ── §2.4 SimConfig (defined here so physics.jl can reference it) ──────────────────

"""
    SimConfig{F<:AbstractFloat}

Simulation-level parameters shared across all system update calls.

Fields:
- `dt`:                     Normal timestep (s). Used for ORCA_MODE agents. Default: 0.05 s.
- `dt_sfm`:                 Reduced timestep (s) used when any HybridFSM agent is in SFM_MODE.
                            Enables the body-contact spring (kₙ) to resolve overlap in one step
                            without globally shrinking dt for ORCA agents.
                            Default: same as `dt` (disabled — no adaptive switching).
                            Recommended for dense bottlenecks: 0.01 s (Helbing 2000 original dt).
- `max_speed`:              Hard speed clamp post-integration (m/s). Default: 5.0.
- `agent_correction_iters`: Max correction passes per step (0 = disabled). Default: 8.
- `agent_correction_tol`:   Early-exit convergence ε (metres). Default: 1e-3 m.
- `correction_alg`:         Algorithm — `JacobiCorrection()` (default) or
                            `XPBDCorrection(α=1f-6)` (Sprint 3V).

XPBD converges in ~5–8 iterations for dense bottleneck scenarios vs ~50 for Jacobi.
At α=0, XPBD is mathematically identical to Jacobi.

## Adaptive dt behaviour
Each call to `step!` checks whether any `HybridFSMParams` agent has `mode == SFM_MODE`.
If so, `dt_sfm` replaces `dt` for:
  - `update_hybrid_fsm_system!` (SFM force magnitude ∝ 1/τ, ORCA force ∝ 1/dt)
  - `integrate_physics_system!` (Δx = v·dt)
This ensures the contact spring resolves overlap within one sub-step without
affecting ORCA agents during normal walking.

## Contact subcycling (sfm_contact_substeps > 0)
When `sfm_contact_substeps = N > 0`, contact forces are NOT included in the main
force vector. Instead, `apply_sfm_contact_subcycle!` runs N mini-steps at
`dt_sub = dt / N` using Helbing's full k=120,000 N/m (stable at small dt_sub).
Goal-seeking and psychological forces still use the full `dt`. This decouples
the stiff contact spring from the smooth motivational forces.
"""
struct SimConfig{F<:AbstractFloat}
    dt                     :: F
    dt_sfm                 :: F   # reduced dt when any agent is in SFM_MODE (default = dt)
    max_speed              :: F
    agent_correction_iters :: Int
    agent_correction_tol   :: F
    correction_alg         :: AbstractCorrectionAlgorithm
    sfm_contact_substeps   :: Int  # 0 = disabled; N > 0 = subcycle contact N times at dt/N
end

# ── Convenience constructors — backward-compatible ────────────────────────────
# All short-form constructors default dt_sfm=dt, sfm_contact_substeps=0.
SimConfig{F}() where {F<:AbstractFloat} =
    SimConfig{F}(F(0.05), F(0.05), F(5.0), 8, F(1e-3), JacobiCorrection(), 0)
SimConfig() = SimConfig{Float32}()
SimConfig(dt::F) where {F<:AbstractFloat} =
    SimConfig{F}(dt, dt, F(5.0), 8, F(1e-3), JacobiCorrection(), 0)
SimConfig(dt::F, max_speed::F) where {F<:AbstractFloat} =
    SimConfig{F}(dt, dt, max_speed, 8, F(1e-3), JacobiCorrection(), 0)
SimConfig(dt::F, max_speed::F, iters::Int) where {F<:AbstractFloat} =
    SimConfig{F}(dt, dt, max_speed, iters, F(1e-3), JacobiCorrection(), 0)
SimConfig(dt::F, max_speed::F, iters::Int, tol::F) where {F<:AbstractFloat} =
    SimConfig{F}(dt, dt, max_speed, iters, tol, JacobiCorrection(), 0)
# Backward-compat 5-arg (dt, max_speed, iters, tol, alg) — dt_sfm=dt, n_sub=0:
SimConfig{F}(dt::F, max_speed::F, iters::Int, tol::F, alg::AbstractCorrectionAlgorithm) where {F<:AbstractFloat} =
    SimConfig{F}(dt, dt, max_speed, iters, tol, alg, 0)
# Backward-compat 6-arg (dt, dt_sfm, max_speed, iters, tol, alg) — n_sub=0:
SimConfig{F}(dt::F, dt_sfm::F, max_speed::F, iters::Int, tol::F, alg::AbstractCorrectionAlgorithm) where {F<:AbstractFloat} =
    SimConfig{F}(dt, dt_sfm, max_speed, iters, tol, alg, 0)
# Full 7-arg inner constructor (dt, dt_sfm, max_speed, iters, tol, alg, n_sub) is the struct default.


include("forces.jl")
include("neighbor_search.jl")
include("navigation.jl")
include("geometry.jl")

# Systems
include("systems/physics.jl")
include("gpu_context.jl")              # BaseGPUContext + stage_and_sort_base! (Sprint 3Q-arch)
include("geometric_correction.jl")     # Jacobi agent + wall correction (Sprint 3T)
include("systems/social.jl")
include("systems/orca_math.jl")
include("systems/orca.jl")
# Note: orca_cpu.jl was deleted in Sprint 3K-a — all features ported into orca.jl.
include("systems/hybrid_fsm.jl")
include("systems/csm.jl")

# ── §2.1 ForceModel Trait ─────────────────────────────────────────────────────
# Marker types that declare which force model an agent uses.
# Systems do NOT require this tag — they filter via Query on SFMParams/ORCAParams.
# AgentModel is additive metadata for introspection, logging, and future dispatch.

"""Abstract supertype for all force model markers."""
abstract type ForceModel end

"""Marker: agent uses the Helbing Social Force Model (SFM) + `SFMParams`."""
struct SFMModel  <: ForceModel end

"""Marker: agent uses Optimal Reciprocal Collision Avoidance (ORCA) + `ORCAParams`."""
struct ORCAModel <: ForceModel end

"""Marker: agent uses both SFM social forces and ORCA avoidance simultaneously."""
struct HybridModel <: ForceModel end

"""
    AgentModel{M<:ForceModel}

Zero-field ECS component that tags an agent with its force model intent.

This is OPTIONAL — existing systems query `SFMParams` / `ORCAParams` directly and
do not require this tag. Add it for introspection, debugging, or future dispatch:

```julia
new_entity!(world, (pos, vel, geom, motion, sfm_params, AgentModel{SFMModel}(), goal, force))
```
"""
struct AgentModel{M<:ForceModel} end

# ── §2.4 SimScene (defined after includes since it references NavigationField etc.) ───


"""
    SimScene{F, S<:AbstractNeighborSearch, N}

Top-level scene object that owns a simulation world, neighbor search, optional
navigation field, and configuration. Call `step!` or `run!` to advance it.

Creating a scene:
```julia
scene = SimScene(world, search, config)              # no nav field
scene = SimScene(world, search, nav_field, config)   # with nav field
```

Running a scene:
```julia
step!(scene)          # advance one timestep
run!(scene, 60.0f0)   # advance for T simulation seconds
```
"""
struct SimScene{F<:AbstractFloat, S<:AbstractNeighborSearch, N}
    world::World
    search::S
    nav_field::N    # Union{NavigationField{F}, Nothing} — Nothing for ORCA-only worlds
    config::SimConfig{F}
end

# Constructor without nav field (ORCA-only or manually-managed navigation)
SimScene(world::World, search::S, config::SimConfig{F}) where {F, S<:AbstractNeighborSearch} =
    SimScene{F, S, Nothing}(world, search, nothing, config)

# Constructor with nav field (SFM worlds with automatic Eikonal-based goal updates).
# N<:NavigationField{F} constraint needed to disambiguate from the struct's
# auto-generated outer constructor (which leaves N unconstrained).
SimScene(world::World, search::S, nav_field::N, config::SimConfig{F}) where {F<:AbstractFloat, S<:AbstractNeighborSearch, N<:NavigationField{F}} =
    SimScene{F, S, N}(world, search, nav_field, config)

"""
    step!(scene::SimScene)

Advance the simulation by one timestep (`scene.config.dt`).

System order:
1. Navigation update (if nav_field is set) — updates `Goal` components from the potential field
2. SFM social forces — `update_social_forces_system!` (resets + accumulates Force)
3. ORCA velocity update — `update_orca_system!` (O(N×k) spatial hash; CPU+GPU; §1.7 walls, §1.8 responsibility)
4. Physics integration — `integrate_physics_system!` (vel/pos update + speed clamp)
5. Hybrid FSM dispatch — `update_hybrid_fsm_system!` (density-triggered ORCA↔SFM per agent)
6. CSM update — `update_csm_system!` (first-order; sets vel+pos directly; σ=0 deterministic)
7. Wall correction — `apply_wall_correction_cpu!` (unified, model-agnostic; Sprint 3T)
8. Agent correction — `apply_agent_correction_cpu!` (Jacobi; Sprint 3T)
   Dispatches on search type: `CPUNeighborSearch` → CellListMap pairwise!;
   `RadixSpatialHash` → Morton hash `get_neighbors` (lock-free per-thread Jacobi).
   Disabled if `scene.config.agent_correction_iters == 0`.

## Search-type dispatch (Sprint 3T-GPU)

When `scene.search isa RadixSpatialHash`, all model kernels and agent correction
use the `RadixSpatialHash` overloads. The backend is inferred from the hash's
array type: `CuArray` → CUDA backend; `Vector` → CPU (KernelAbstractions CPU()
used for testing without GPU hardware).

Note: GPU physics integration (positions updated on device) is a future sprint.
Currently, positions are always integrated on CPU (via `integrate_physics_system!`
for force-based models, or scatter-back for CSM). The `apply_agent_correction_cpu!`
on RadixSpatialHash runs post-scatter-back on the CPU-side ECS, using the Morton
hash for O(N×k) neighbour lookup.
"""
function step!(scene::SimScene{F}) where {F}
    dt      = scene.config.dt
    n_iters = scene.config.agent_correction_iters

    # ── Count agent types ──────────────────────────────────────────
    # Guard: Ark.Query throws ArgumentError if a component type was never registered.
    local n_force::Int  = 0
    local n_csm::Int    = 0
    try; n_force = count_entities(Query(scene.world, (Force{F},)));      catch e; e isa ArgumentError || rethrow(); end
    try; n_csm   = count_entities(Query(scene.world, (CSMParams{F},)));  catch e; e isa ArgumentError || rethrow(); end

    # Nothing to do if no force-based agents AND no CSM agents
    (n_force == 0 && n_csm == 0) && return scene

    # ── Collect wall segments once (shared by wall + agent correction) ────────
    walls_buf = NTuple{2, SVector{2,F}}[]
    try
        for (_, ws_col) in Query(scene.world, (WallSegment{F},))
            for j in eachindex(ws_col)
                push!(walls_buf, (ws_col[j].p1, ws_col[j].p2))
            end
        end
    catch e
        e isa ArgumentError || rethrow()
    end

    # ── Detect backend from search type ──────────────────────────────────────
    use_gpu_search = scene.search isa RadixSpatialHash
    ka_backend = use_gpu_search ? get_ka_backend(scene.search) : CPU()

    # ── Force-based pipeline (SFM / ORCA / Hybrid) ────────────────────────
    if n_force > 0
        # 1. Reset Force components to zero
        for (_, force_col) in Query(scene.world, (Force{F},))
            for i in eachindex(force_col)
                force_col[i] = Force(zero(SVector{2,F}))
            end
        end
        # 2. Navigation: ADD F_drive from Eikonal field (if present)
        if scene.nav_field !== nothing
            update_navigation_system!(scene.world, scene.nav_field)
        end
        # 3. SFM agent-agent + wall forces (only for agents with SFMParams)
        local n_sfm::Int = 0
        try; n_sfm = count_entities(Query(scene.world, (SFMParams{F},))); catch; n_sfm = 0; end
        if n_sfm > 0
            update_social_forces_system!(scene.world, scene.search, ka_backend)
        end
        # 4. ORCA velocity update (only for agents with ORCAParams)
        local n_orca::Int = 0
        try; n_orca = count_entities(Query(scene.world, (ORCAParams{F},))); catch; n_orca = 0; end
        if n_orca > 0
            update_orca_system!(scene.world, scene.search, ka_backend, dt; W=16)
        end
        # 5. Hybrid FSM dispatch (agents with HybridFSMParams — neither SFMParams nor ORCAParams)
        local n_hybrid::Int = 0
        try; n_hybrid = count_entities(Query(scene.world, (HybridFSMParams{F},))); catch; n_hybrid = 0; end

        # ── Adaptive dt: use dt_sfm when any Hybrid agent is in SFM_MODE ─────
        # SFM_MODE agents need a smaller dt for the body-contact spring to resolve
        # overlap in one step. ORCA_MODE agents are unaffected (velocity-level
        # constraints; dt only appears in force = mass×(v_opt−v)/dt).
        # When dt_sfm == dt (default), this check is a no-op and has zero overhead.
        dt_eff = dt   # effective dt for this step
        if n_hybrid > 0 && scene.config.dt_sfm < scene.config.dt
            any_sfm = false
            try
                for (_, state_col) in Query(scene.world, (AgentFSMState{F},))
                    for i in eachindex(state_col)
                        if state_col[i].mode == SFM_MODE
                            any_sfm = true
                            break
                        end
                    end
                    any_sfm && break
                end
            catch e
                e isa ArgumentError || rethrow()
            end
            any_sfm && (dt_eff = scene.config.dt_sfm)
        end

        if n_hybrid > 0
            update_hybrid_fsm_system!(scene.world, scene.search, ka_backend, dt_eff, scene.nav_field;
                                      skip_contact = scene.config.sfm_contact_substeps > 0)
        end
        # 5b. Contact subcycling: N substeps at dt_sub = dt/N, k=120,000 N/m (Helbing full)
        #     Activated when sfm_contact_substeps > 0. Contact is removed from the main
        #     force vector (skip_contact=true above) and handled here instead.
        #     Goal-seeking and psychological forces still use full dt_eff.
        if n_hybrid > 0 && scene.config.sfm_contact_substeps > 0
            dt_base = dt_eff  # dt or dt_sfm depending on adaptive-dt setting
            dt_sub  = dt_base / F(scene.config.sfm_contact_substeps)
            apply_sfm_contact_subcycle!(scene.world, scene.config.sfm_contact_substeps, dt_sub, F)
        end
        # 6. Integrate: velocity + position update with speed clamp from config
        # Use dt_eff (may be dt_sfm if any agent is in SFM_MODE this step).
        integrate_physics_system!(scene.world, scene.config, dt_eff)
    end

    # ── CSM pipeline (first-order; sets vel+pos directly; no Force needed) ────
    if n_csm > 0
        if use_gpu_search
            update_csm_system!(scene.world, scene.search, ka_backend, dt;
                               n_iters_corr = n_iters,
                               alg          = scene.config.correction_alg)
        else
            update_csm_system!(scene.world, dt)
        end
    end

    # ── Post-step geometric constraint enforcement (Sprint 3T) ────────────────
    # Order: wall correction FIRST (project to walls), THEN agent correction
    # (project away from agents). Both are Jacobi / geometric projections.
    #
    # 7. Unified wall correction (model-agnostic; replaces per-model overloads)
    #    Deprecated overloads: wall_penetration_correction!(world, walls, F)
    #    and wall_penetration_correction!(world, walls, F, CSMParams{F}) remain
    #    as thin wrappers in hybrid_fsm.jl / csm.jl — to be removed in Sprint 3U.
    apply_wall_correction_cpu!(scene.world, walls_buf, F)

    # 8. Agent body non-penetration correction (adaptive Jacobi/XPBD; Sprint 3T/3V)
    #    Algorithm selected by scene.config.correction_alg:
    #      JacobiCorrection() — default, Sprint 3T
    #      XPBDCorrection(α)  — Sprint 3V, faster convergence in dense jams
    #    CPU path: adaptive — stops early when max_overlap ≤ tol.
    #    GPU path: handled inside update_csm_system! (fixed n_iters cap).
    if n_iters > 0
        apply_agent_correction_cpu!(scene.world, scene.search, F;
                                    n_iters = n_iters,
                                    tol     = scene.config.agent_correction_tol,
                                    alg     = scene.config.correction_alg)
    end

    return scene
end

"""
    run!(scene::SimScene, T)

Run the simulation for `T` seconds of simulated time, calling `step!` each timestep.
Returns `scene` for chaining.
"""
function run!(scene::SimScene{F}, T::Real) where {F}
    t    = zero(F)
    T_F  = F(T)
    dt   = scene.config.dt
    while t < T_F
        step!(scene)
        t += dt
    end
    return scene
end

end
