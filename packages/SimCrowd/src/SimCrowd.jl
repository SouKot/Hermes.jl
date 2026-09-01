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
export apply_agent_pair_correction, apply_agent_correction_cpu!, apply_agent_correction_gpu!
export apply_wall_correction_cpu!, integrate_positions_kernel!, integrate_vel_pos_kernel!
# §2.4 SimConfig + SimScene
export SimConfig, SimScene, step!, run!

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

# ── §2.4 SimConfig (defined here so physics.jl can reference it) ──────────────────

"""
    SimConfig{F<:AbstractFloat}

Simulation-level parameters shared across all system update calls.
Eliminates hardcoded constants from `physics.jl` and `social.jl`.

Fields:
- `dt`:                     timestep (s). Default: 0.05 s (20 Hz — good for SFM; use 0.01 s for ORCA).
- `max_speed`:              hard speed clamp applied after integration (m/s). Default: 5.0 (panic speed).
- `agent_correction_iters`: Jacobi agent non-penetration correction passes per step (Sprint 3T).
                            0 = disabled. Default: 2.

  **When to change `agent_correction_iters`**:
  - `2` (default): handles severe bottleneck crowding (N=80, 1m door, all agents converging
    simultaneously). Verified to reduce min body separation from 0.244m to ≥0.38m.
  - `1`: sufficient at normal densities (overlap < 5% of radius); half the correction cost.
  - `3`: for extreme crush scenarios (slam-door evacuations, N > 1000 at jam density).
  - `0`: pure ORCA scenes — the LP velocity solve (Berg et al. 2011) prevents penetration
    at low-to-medium density (ρ < 3.5 ped/m²). At extreme density (ρ ≥ 3.5 ped/m², τ_h → 0)
    the LP feasible region may be empty; set `agent_correction_iters=2` in that case.

  **GPU**: Uses `apply_agent_correction_gpu!` (geometric_correction.jl) with `BaseGPUContext`
  Jacobi buffers (`dev_delta_pos`, `dev_delta_vel`). No additional allocation per step.
"""
struct SimConfig{F<:AbstractFloat}
    dt                     :: F
    max_speed              :: F
    agent_correction_iters :: Int   # Jacobi max passes per step (0 = disabled)
    agent_correction_tol   :: F     # convergence criterion ε (metres of max body overlap)
                                    # CPU path: stops early when max_overlap ≤ tol.
                                    # GPU path: runs exactly agent_correction_iters passes
                                    #   (avoids per-iteration GPU→CPU sync for the check).
                                    # Set to 0 to always run the full max_iters.
end

# Convenience constructors — tol default = 1e-3 m (1mm, effectively zero physical overlap)
SimConfig{F}() where {F<:AbstractFloat} = SimConfig(F(0.05), F(5.0), 8, F(1e-3))
SimConfig() = SimConfig{Float32}()
SimConfig(dt::F) where {F<:AbstractFloat} = SimConfig(dt, F(5.0), 8, F(1e-3))
SimConfig(dt::F, max_speed::F) where {F<:AbstractFloat} = SimConfig(dt, max_speed, 8, F(1e-3))
SimConfig(dt::F, max_speed::F, iters::Int) where {F<:AbstractFloat} =
    SimConfig(dt, max_speed, iters, F(1e-3))

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
    dt  = scene.config.dt
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
    # RadixSpatialHash encodes backend in its array type parameter (AT).
    # CuArray → CUDA backend; Vector → KA CPU() backend.
    # CPUNeighborSearch always uses CellListMap (CPU-only).
    use_gpu_search = scene.search isa RadixSpatialHash
    # For RadixSpatialHash, derive the KernelAbstractions backend from the array type.
    # This avoids storing a separate backend field in SimScene.
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
        if n_hybrid > 0
            update_hybrid_fsm_system!(scene.world, scene.search, ka_backend, dt, scene.nav_field)
        end
        # 6. Integrate: velocity + position update with speed clamp from config
        integrate_physics_system!(scene.world, scene.config)
    end

    # ── CSM pipeline (first-order; sets vel+pos directly; no Force needed) ────
    if n_csm > 0
        if use_gpu_search
            update_csm_system!(scene.world, scene.search, ka_backend, dt)
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

    # 8. Agent body non-penetration correction (adaptive Jacobi; Sprint 3T-GPU-fix)
    #    CPU path: adaptive — stops early when max_overlap ≤ tol (from SimConfig).
    #    GPU path: handled inside update_csm_system!/update_hybrid_fsm_system! (fixed cap).
    if n_iters > 0
        apply_agent_correction_cpu!(scene.world, scene.search, F;
                                    n_iters=n_iters,
                                    tol=scene.config.agent_correction_tol)
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
